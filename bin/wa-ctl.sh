#!/usr/bin/env bash
# User-initiated actions for the Whatsmarchy Omarchy bar widget.
#
# Everything in here runs because a human clicked something in the panel. The
# poller (wa-status.sh) is strictly read-only; this script is the only place
# that writes plugin config, fetches media, or asks wacli to send anything.
#
# Contract: always exits 0, always emits exactly one JSON object on stdout.
#   success -> {"ok":true, ...}
#   failure -> {"ok":false,"error":".."}
#
# Usage: wa-ctl.sh <subcommand> [args...]
set -uo pipefail
umask 077

# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

command -v jq >/dev/null 2>&1 || { printf '{"ok":false,"error":"jq is not installed"}\n'; exit 0; }

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-whatsmarchy"
MEDIA_CACHE="$CACHE_DIR/media"
# Ceiling for anything handed to an image decoder, a media player, or a viewer.
# 25 MiB is far above any preview worth showing and far below "fills the disk".
MAX_MEDIA_BYTES=$((25 * 1024 * 1024))
# Previewed attachments are a cache, not a mailbox: without a bound, a group
# that posts photos all day fills the disk with files the user merely glanced at.
MEDIA_CACHE_MAX_AGE_DAYS=14
MEDIA_CACHE_MAX_FILES=400

ensure_cache() {
  mkdir -p -- "$MEDIA_CACHE" 2>/dev/null || emit_error "cannot create $MEDIA_CACHE"
  chmod 700 -- "$CACHE_DIR" "$MEDIA_CACHE" 2>/dev/null
  prune_media_cache
}

prune_media_cache() {
  # Age first, then a hard file count, oldest-accessed first. Both are
  # best-effort: a failure to prune must never stop the action the user asked
  # for, so every step here swallows its own errors.
  find "$MEDIA_CACHE" -maxdepth 1 -type f -mtime "+$MEDIA_CACHE_MAX_AGE_DAYS" -delete 2>/dev/null
  local count
  count="$(find "$MEDIA_CACHE" -maxdepth 1 -type f -printf '.' 2>/dev/null | wc -c)"
  is_uint "${count:-}" || return 0
  (( count > MEDIA_CACHE_MAX_FILES )) || return 0
  find "$MEDIA_CACHE" -maxdepth 1 -type f -printf '%A@ %p\0' 2>/dev/null \
    | sort -zn \
    | head -z -n "$(( count - MEDIA_CACHE_MAX_FILES ))" \
    | cut -z -d' ' -f2- \
    | xargs -0r rm -f -- 2>/dev/null
  return 0
}

emit_ok() {
  # jq failing here (a malformed --argjson, for instance) would otherwise print
  # nothing and exit 0 — an empty stdout that still reads as success and breaks
  # the "always exactly one JSON object" contract.
  local out
  out="$(jq -cn "$@" '$ARGS.named + {ok: true}' 2>/dev/null)"
  [[ -n "$out" ]] || emit_error "could not build the response payload"
  printf '%s\n' "$out"
  exit 0
}

# jq arguments land in /proc/<pid>/cmdline, readable by any other process
# running as this user for the life of the call. Chat JIDs are phone numbers and
# the allow-list is the user's contact selection, so any jq invocation carrying
# them takes them through a pipe instead. Usage:
#   cfg="$(read_config | jq -c --slurpfile a <(json_arg "$doc") '...$a[0]...')"
json_arg() { printf '%s' "$1"; }

# ---------------------------------------------------------------------------
# recipients — option list for the panel's "who may notify me" picker.
# Reads chats/contacts/groups straight from the mirror, read-only.
# ---------------------------------------------------------------------------
cmd_recipients() {
  require_cmd sqlite3
  local store db rows
  store="$(resolve_store_dir)" || emit_error "wacli store not found — is wacli installed and paired?"
  db="$store/wacli.db"
  [[ -r "$db" ]] || emit_error "cannot read $db"

  # Ordered the way the picker should read: most recently active first, so the
  # chats a user actually wants to allow are at the top of a long list.
  # The label is a contact or group name, i.e. a string chosen by whoever is
  # messaging this user. It ends up in Omarchy's shared MultiSelect, whose Text
  # elements do not pin textFormat and therefore default to Text.AutoText — so a
  # push_name of `<img src="https://evil.tld/p.png">` would fire an outbound
  # request the moment the picker is opened, and `<table width=...>` would let
  # one contact overrun another's row. The shared component is not this plugin's
  # to depend on, so the markup characters are stripped here at the source, the
  # same way BarWidget does for the bar label.
  rows="$( sqlite3 -readonly -noheader -batch -- "$db" <<'SQL' 2>&1
    SELECT COALESCE(json_group_array(json_object(
      'value', jid, 'label',
        replace(replace(replace(label, '<', ' '), '>', ' '), '&', ' '),
      'description', descr
    )), '[]')
    FROM (
      SELECT
        c.jid AS jid,
        COALESCE(NULLIF(c.name,''), NULLIF(g.name,''), NULLIF(ct.push_name,''),
                 NULLIF(ct.full_name,''), NULLIF(ct.business_name,''),
                 NULLIF(ct.phone,''), c.jid) AS label,
        CASE c.kind
          WHEN 'group'      THEN 'Group'
          WHEN 'dm'         THEN 'Direct message'
          WHEN 'newsletter' THEN 'Channel'
          ELSE COALESCE(c.kind,'Chat')
        END AS descr
      FROM chats c
      LEFT JOIN groups   g  ON g.jid  = c.jid
      LEFT JOIN contacts ct ON ct.jid = c.jid
      WHERE c.jid <> 'status@broadcast'
        AND c.kind IN ('dm','group','newsletter')
      ORDER BY COALESCE(c.last_message_ts, 0) DESC
      LIMIT 500
    );
SQL
  )" || emit_error "sqlite read failed: $rows"

  printf '%s' "$rows" | jq -e 'type == "array"' >/dev/null 2>&1 \
    || emit_error "unexpected recipient query result"
  # MultiSelect's optionsCommand consumes a bare JSON array, not the
  # {ok:..} envelope every other subcommand returns.
  printf '%s\n' "$rows"
  exit 0
}

# ---------------------------------------------------------------------------
# config — read and mutate the plugin's own settings file.
# ---------------------------------------------------------------------------
cmd_config_get() {
  local cfg
  cfg="$(read_config)"
  printf '%s' "$cfg" | jq -c '{ok: true, mode: .mode, allow: .allow}'
  exit 0
}

cmd_set_mode() {
  local mode="${1-}" cfg
  case "$mode" in
    paused | all | custom) ;;
    *) emit_error "invalid mode: expected paused, all, or custom" ;;
  esac
  cfg="$(read_config | jq -c --arg m "$mode" '.mode = $m')" || emit_error "could not update config"
  write_config "$cfg" || emit_error "cannot write $(config_path)"
  emit_ok --arg mode "$mode"
}

cmd_set_allow() {
  # The JID list arrives on stdin as JSON. Keeping it off argv means a long
  # contact list can't be truncated by ARG_MAX and doesn't land in `ps` output
  # for every other local process to read.
  local raw allow cfg
  raw="$(cat)"
  allow="$(printf '%s' "$raw" | jq -c 'if type == "array" then [.[] | select(type == "string")] else empty end' 2>/dev/null)" \
    || emit_error "expected a JSON array of JIDs on stdin"
  [[ -n "$allow" ]] || emit_error "expected a JSON array of JIDs on stdin"

  # Every entry is shape-checked before it can be persisted and later reach a
  # `wacli` argument list.
  local jid
  while IFS= read -r jid; do
    [[ -n "$jid" ]] || continue
    is_jid "$jid" || emit_error "refusing to store malformed JID"
  done < <(printf '%s' "$allow" | jq -r '.[]')

  cfg="$(read_config | jq -c --slurpfile a <(json_arg "$allow") '.allow = $a[0]')" \
    || emit_error "could not update config"
  write_config "$cfg" || emit_error "cannot write $(config_path)"
  # Only the count is reported back; echoing the list would put it straight
  # back on a command line via emit_ok.
  emit_ok --argjson count "$(printf '%s' "$allow" | jq 'length')"
}

# mark-seen moves a chat's acknowledgement watermark forward. Never backward:
# a stale panel payload replaying an old timestamp must not resurrect messages
# the user already dismissed.
cmd_mark_seen() {
  local jid="${1-}" ts="${2-}" cfg now
  is_jid "$jid" || emit_error "invalid chat id"
  is_uint "$ts" || emit_error "invalid timestamp"
  # The timestamp comes from a WhatsApp message and the merge below is
  # deliberately monotonic-forward. A message dated in the future would
  # therefore pin this chat's watermark to the future and hide every genuine
  # message from that contact from then on — permanently, since mark-all-seen
  # is written to preserve entries above the global watermark. Clamped to now.
  now="$(date +%s)"
  (( ts > now )) && ts="$now"
  cfg="$(read_config | jq -c --slurpfile j <(json_arg "$(json_string "$jid")") --argjson t "$ts" \
    '.seen[$j[0]] = ([(.seen[$j[0]] // 0), $t] | max)')" || emit_error "could not update config"
  write_config "$cfg" || emit_error "cannot write $(config_path)"
  emit_ok --argjson done true
}

cmd_mark_all_seen() {
  local ts="${1:-}" cfg
  [[ -n "$ts" ]] || ts="$(date +%s)"
  is_uint "$ts" || emit_error "invalid timestamp"
  # Bumping seenAll alone would leave stale per-chat entries below it in place;
  # they are dropped so the file does not grow without bound.
  cfg="$(read_config | jq -c --argjson t "$ts" \
    '.seenAll = ([.seenAll, $t] | max)
     | .seen = (.seen | with_entries(select(.value > $t)))')" || emit_error "could not update config"
  write_config "$cfg" || emit_error "cannot write $(config_path)"
  emit_ok --argjson seenAll "$ts"
}

# ---------------------------------------------------------------------------
# send — quick text reply. Always a human typing into the panel and pressing
# send; this plugin has no autonomous or scheduled send path of any kind.
# ---------------------------------------------------------------------------
cmd_send() {
  local jid="${1-}" msg out
  is_jid "$jid" || emit_error "invalid chat id"
  require_cmd wacli
  # Message body on stdin, not argv: reply text is the user's private content
  # and does not belong in this script's /proc/<pid>/cmdline.
  msg="$(cat)"
  msg="${msg%$'\n'}"
  [[ -n "$msg" ]] || emit_error "empty message"
  (( ${#msg} <= 8000 )) || emit_error "message too long"

  # `--` is not accepted by the wacli flag parser, but --message takes its
  # value as a separate argv entry, so a body starting with '-' is still
  # passed as data rather than parsed as a flag.
  # NOTE: `wacli` takes the recipient and the message body as command-line
  # arguments, so for the second or so the send is in flight they are visible in
  # `ps` to other processes running as this user. That is wacli's interface and
  # cannot be avoided from here; it is called out in the README rather than
  # papered over. Everything on *this* side of the boundary stays off argv.
  out="$(wacli send text --to "$jid" --message "$msg" --json 2>&1)"
  if (( $? != 0 )); then
    emit_error "send failed: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
  fi
  emit_ok --argjson sent true
}

# ---------------------------------------------------------------------------
# media — make a message's attachment available as a local file.
# ---------------------------------------------------------------------------

# WhatsApp controls mime_type and filename, so neither is ever used to build a
# path. The cache name is derived from the (chat, message) pair and the
# extension comes from this fixed table.
ext_for_mime() {
  case "$(printf '%s' "${1-}" | tr 'A-Z' 'a-z')" in
    image/jpeg* | image/jpg*) printf 'jpg' ;;
    image/png*)               printf 'png' ;;
    image/webp*)              printf 'webp' ;;
    image/gif*)               printf 'gif' ;;
    video/mp4*)               printf 'mp4' ;;
    video/webm*)              printf 'webm' ;;
    video/3gpp*)              printf '3gp' ;;
    audio/ogg* | audio/opus*) printf 'ogg' ;;
    audio/mpeg* | audio/mp3*) printf 'mp3' ;;
    audio/mp4* | audio/aac* | audio/x-m4a*) printf 'm4a' ;;
    audio/wav* | audio/x-wav*) printf 'wav' ;;
    application/pdf*)         printf 'pdf' ;;
    *)                        printf 'bin' ;;
  esac
}

# Resolves a message's attachment to a real local file, downloading it only if
# there isn't one yet, and assigns it to the global RESOLVED_MEDIA.
#
# The result is deliberately *not* returned on stdout: called as
# `path=$(resolve_media_path ...)`, an emit_error inside it would only kill the
# subshell, and its `{"ok":false,...}` JSON would be captured as the path and
# then re-emitted inside an `{"ok":true}` envelope. A failure must surface as a
# failure, not as a fabricated path.
RESOLVED_MEDIA=""
resolve_media_path() {
  local jid="$1" msg_id="$2"
  RESOLVED_MEDIA=""
  require_cmd sqlite3
  local store db row local_path mime target out
  store="$(resolve_store_dir)" || emit_error "wacli store not found"
  db="$store/wacli.db"
  [[ -r "$db" ]] || emit_error "cannot read $db"

  # Bound as SQL parameters rather than interpolated into the query, so a JID
  # or message ID can never be read as SQL. Both the .parameter lines and the
  # query go in over stdin: a chat JID is a phone number, and sqlite3's argv is
  # readable by any other process running as this user.
  local esc_jid="${jid//\'/\'\'}" esc_mid="${msg_id//\'/\'\'}"
  row="$( { printf ".parameter set :jid '%s'\n" "$esc_jid"
            printf ".parameter set :mid '%s'\n" "$esc_mid"
            cat <<'SQL'
      SELECT json_object(
        'localPath', COALESCE(local_path,''),
        'mime',      COALESCE(mime_type,''),
        'type',      COALESCE(media_type,'')
      )
      FROM messages
      WHERE chat_jid = :jid AND msg_id = :mid
        AND deleted_at IS NULL AND payload_purged_at IS NULL
      LIMIT 1;
SQL
          } | sqlite3 -readonly -noheader -batch -- "$db" 2>&1 )" \
    || emit_error "sqlite read failed: $row"
  [[ -n "$row" ]] || emit_error "message not found in the local store"
  # sqlite3 exits 0 even when a .parameter line fails to parse, printing a usage
  # banner instead of a row. Without this check both fields would silently
  # become "" and the code would fall through to a fresh download with a .bin
  # extension, reporting a fault as an ordinary cache miss.
  printf '%s' "$row" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || emit_error "unexpected media lookup result"

  local_path="$(printf '%s' "$row" | jq -r '.localPath')"
  mime="$(printf '%s' "$row" | jq -r '.mime')"

  # A local_path recorded by wacli is trusted only after confirming it really
  # resolves inside wacli's own store directory. The column is data, and a
  # path outside the store would mean handing an arbitrary file to a media
  # player on a click.
  if [[ -n "$local_path" && -f "$local_path" ]]; then
    local real_store real_file
    real_store="$(realpath -e -- "$store" 2>/dev/null)"
    real_file="$(realpath -e -- "$local_path" 2>/dev/null)"
    if [[ -n "$real_store" && -n "$real_file" && "$real_file" == "$real_store"/* ]]; then
      RESOLVED_MEDIA="$real_file"
      return 0
    fi
  fi

  require_cmd sha256sum
  ensure_cache
  target="$MEDIA_CACHE/$(printf '%s\n%s' "$jid" "$msg_id" | sha256sum | cut -d' ' -f1).$(ext_for_mime "$mime")"
  if [[ -s "$target" ]]; then
    RESOLVED_MEDIA="$target"
    return 0
  fi

  require_cmd wacli
  # Downloaded to a temp name and renamed into place only once it is complete.
  # Writing straight to $target would mean that a download killed part-way —
  # Quickshell tearing the Process down when the panel closes, a logout, an OOM
  # kill — leaves a truncated file that the `[[ -s ]]` check above then serves
  # forever as a valid attachment. The rename is atomic, so two callers racing
  # on the same message cannot see a half-written file either.
  local tmp
  tmp="$(mktemp "$MEDIA_CACHE/.dl.XXXXXX")" || emit_error "cannot create a download temp file"
  chmod 600 -- "$tmp" 2>/dev/null
  trap 'rm -f -- "$tmp"' RETURN
  # --read-only keeps this out of session.db and off the store lock, so it
  # cannot disturb a running `wacli sync --follow`. Media is fetched straight
  # from WhatsApp's CDN using the key already stored in wacli.db.
  out="$(wacli --read-only media download --chat "$jid" --id "$msg_id" --output "$tmp" 2>&1)"
  if (( $? != 0 )) || [[ ! -s "$tmp" ]]; then
    emit_error "media download failed: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
  fi
  # A decoder handed an enormous file is a denial of service in itself, so the
  # ceiling is enforced before the path is ever returned to the panel.
  local size
  size="$(stat -c '%s' -- "$tmp" 2>/dev/null || printf '0')"
  if ! is_uint "$size" || (( size > MAX_MEDIA_BYTES )); then
    emit_error "attachment is larger than the ${MAX_MEDIA_BYTES} byte preview limit"
  fi
  mv -f -- "$tmp" "$target" || emit_error "could not store the downloaded attachment"
  RESOLVED_MEDIA="$target"
}

cmd_media() {
  local jid="${1-}" msg_id="${2-}" path
  is_jid "$jid"       || emit_error "invalid chat id"
  is_msg_id "$msg_id" || emit_error "invalid message id"
  resolve_media_path "$jid" "$msg_id"
  path="$RESOLVED_MEDIA"
  [[ -n "$path" && -s "$path" ]] || emit_error "attachment is not available locally"
  emit_ok --arg path "$path"
}

cmd_play() {
  local jid="${1-}" msg_id="${2-}" path
  is_jid "$jid"       || emit_error "invalid chat id"
  is_msg_id "$msg_id" || emit_error "invalid message id"
  resolve_media_path "$jid" "$msg_id"
  path="$RESOLVED_MEDIA"
  [[ -n "$path" && -s "$path" ]] || emit_error "attachment is not available locally"

  # Plain playback of the raw file — no transcoding, no extra dependency
  # beyond a player that is already on essentially every desktop.
  # The bytes are attacker-supplied and mpv identifies a file by content, not by
  # the extension this cache gave it: an "audio/mpeg" attachment whose body is
  # `#EXTM3U` + a URL would otherwise be opened as a playlist and its entries
  # fetched on a Play click. --no-config also keeps the user's mpv.conf and any
  # user Lua scripts out of the picture.
  if command -v mpv >/dev/null 2>&1; then
    setsid mpv --no-config --no-video --really-quiet --no-terminal \
      --load-unsafe-playlists=no --demuxer=lavf -- "$path" >/dev/null 2>&1 &
  elif command -v ffplay >/dev/null 2>&1; then
    setsid ffplay -nodisp -autoexit -loglevel quiet -- "$path" >/dev/null 2>&1 &
  elif command -v paplay >/dev/null 2>&1; then
    setsid paplay -- "$path" >/dev/null 2>&1 &
  else
    emit_error "no audio player found — install mpv (or ffmpeg for ffplay)"
  fi
  emit_ok --arg path "$path"
}

cmd_open() {
  local jid="${1-}" msg_id="${2-}" path
  is_jid "$jid"       || emit_error "invalid chat id"
  is_msg_id "$msg_id" || emit_error "invalid message id"
  resolve_media_path "$jid" "$msg_id"
  path="$RESOLVED_MEDIA"
  [[ -n "$path" && -s "$path" ]] || emit_error "attachment is not available locally"
  command -v xdg-open >/dev/null 2>&1 || emit_error "xdg-open is not installed"
  setsid xdg-open "$path" >/dev/null 2>&1 &
  emit_ok --arg path "$path"
}

# ---------------------------------------------------------------------------
# webapp — hand off to the official WhatsApp Web app.
#
# WhatsApp Web has no stable deep link to a specific existing conversation
# (wa.me/<number> only opens a *new* chat compose and does nothing for groups),
# so this deliberately opens the inbox and stops there rather than pretending
# to jump to the clicked thread.
# ---------------------------------------------------------------------------
cmd_webapp() {
  local url="https://web.whatsapp.com/"
  if command -v omarchy-launch-or-focus-webapp >/dev/null 2>&1; then
    setsid omarchy-launch-or-focus-webapp "web.whatsapp.com" "$url" >/dev/null 2>&1 &
  elif command -v omarchy-launch-webapp >/dev/null 2>&1; then
    setsid omarchy-launch-webapp "$url" >/dev/null 2>&1 &
  else
    emit_error "omarchy-launch-webapp not found"
  fi
  emit_ok --arg url "$url"
}

# ---------------------------------------------------------------------------
# whisper — optional, entirely local voice-note transcription.
#
# Nothing here installs anything. `whisper-status` only looks; installing is a
# separate subcommand that opens a terminal and asks the user to confirm.
# ---------------------------------------------------------------------------
find_whisper_model() {
  [[ -n "${WHATSMARCHY_WHISPER_MODEL:-}" && -r "${WHATSMARCHY_WHISPER_MODEL}" ]] && {
    printf '%s' "$WHATSMARCHY_WHISPER_MODEL"; return 0; }
  local dir f
  for dir in \
    "${XDG_DATA_HOME:-$HOME/.local/share}/whatsmarchy/models" \
    "${XDG_DATA_HOME:-$HOME/.local/share}/whisper.cpp/models" \
    "$HOME/.cache/whisper.cpp/models" \
    "/usr/share/whisper.cpp/models"
  do
    [[ -d "$dir" ]] || continue
    f="$(find "$dir" -maxdepth 1 -type f -name 'ggml-*.bin' -print 2>/dev/null | sort | head -1)"
    [[ -n "$f" ]] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

detect_whisper() {
  # Prints "<tool> <binary> <model-or-empty>" and returns 0, or returns 1.
  local bin model
  for bin in whisper-cli whisper-cpp main; do
    command -v "$bin" >/dev/null 2>&1 || continue
    # `main` is generic enough that it must not be picked up from a random
    # project directory just because it happens to be on PATH.
    [[ "$bin" == "main" && ! -e /usr/share/whisper.cpp ]] && continue
    if model="$(find_whisper_model)"; then
      printf '%s %s %s' "whisper.cpp" "$bin" "$model"
      return 0
    fi
  done
  if command -v whisper >/dev/null 2>&1; then
    printf '%s %s %s' "openai-whisper" "whisper" ""
    return 0
  fi
  return 1
}

cmd_whisper_status() {
  local info tool bin model
  if info="$(detect_whisper)"; then
    read -r tool bin model <<<"$info"
    emit_ok --argjson available true --arg tool "$tool" --arg bin "$bin" --arg model "${model:-}"
  fi
  # Distinguish "no engine at all" from "engine present but no model", because
  # the fixes are completely different and the panel says so.
  if command -v whisper-cli >/dev/null 2>&1 || command -v whisper-cpp >/dev/null 2>&1; then
    emit_ok --argjson available false --arg reason "model" \
      --arg detail "whisper.cpp is installed but no ggml model was found"
  fi
  emit_ok --argjson available false --arg reason "engine" \
    --arg detail "no local transcription engine found"
}

cmd_transcribe() {
  local jid="${1-}" msg_id="${2-}" path info tool bin model tmp wav text
  is_jid "$jid"       || emit_error "invalid chat id"
  is_msg_id "$msg_id" || emit_error "invalid message id"
  info="$(detect_whisper)" || emit_error "no local transcription engine found"
  read -r tool bin model <<<"$info"

  resolve_media_path "$jid" "$msg_id"
  path="$RESOLVED_MEDIA"
  [[ -n "$path" && -s "$path" ]] || emit_error "attachment is not available locally"

  tmp="$(mktemp -d "$CACHE_DIR/tx.XXXXXX")" || emit_error "cannot create work directory"
  chmod 700 -- "$tmp" 2>/dev/null
  trap 'rm -rf -- "$tmp"' EXIT

  if [[ "$tool" == "whisper.cpp" ]]; then
    require_cmd ffmpeg
    wav="$tmp/audio.wav"
    # whisper.cpp only reads 16 kHz mono PCM.
    ffmpeg -nostdin -loglevel error -y -i "$path" -ar 16000 -ac 1 -c:a pcm_s16le "$wav" >/dev/null 2>&1 \
      || emit_error "could not decode the voice note (ffmpeg failed)"
    text="$("$bin" -m "$model" -f "$wav" -nt -np 2>/dev/null)" \
      || emit_error "transcription failed"
  else
    "$bin" "$path" --output_format txt --output_dir "$tmp" --verbose False >/dev/null 2>&1 \
      || emit_error "transcription failed"
    text="$(cat -- "$tmp"/*.txt 2>/dev/null)"
  fi

  text="$(printf '%s' "$text" | tr -s '[:space:]' ' ' | sed 's/^ *//; s/ *$//')"
  [[ -n "$text" ]] || emit_error "transcription produced no text"
  # Piped, not passed with --arg: a transcript is the literal contents of a
  # private voice note and must not sit in jq's /proc/<pid>/cmdline.
  printf '%s' "$text" | jq -Rs --arg tool "$tool" '{ok: true, tool: $tool, text: .}'
  exit 0
}

cmd_install_whisper() {
  # Deliberately does not install anything. It opens a terminal running an
  # interactive script that shows the exact commands and refuses to proceed
  # without a typed confirmation. The panel gates this behind its own
  # confirmation dialog first, so the user agrees twice.
  local helper="$SELF_DIR/wa-install-whisper.sh"
  [[ -x "$helper" ]] || emit_error "installer helper missing or not executable"
  if command -v omarchy-launch-floating-terminal-with-presentation >/dev/null 2>&1; then
    setsid omarchy-launch-floating-terminal-with-presentation "$helper" >/dev/null 2>&1 &
  elif command -v omarchy-launch-terminal >/dev/null 2>&1; then
    setsid omarchy-launch-terminal -e "$helper" >/dev/null 2>&1 &
  else
    emit_error "no terminal launcher found — run $helper yourself"
  fi
  emit_ok --arg helper "$helper"
}

# ---------------------------------------------------------------------------
# `recipients` reads only wacli.db and never touches the plugin config, and its
# consumer (MultiSelect's optionsCommand) expects a bare JSON array — an
# {"ok":false} object would be rendered as a literal option row instead of an
# error. It is dispatched ahead of the config gate so it cannot emit that shape.
[[ "${1-}" == "recipients" ]] && { shift; cmd_recipients "$@"; }

# Checked once, here in the main shell, so a refusal is the script's answer
# rather than a string captured inside a command substitution.
assert_config_safe

case "${1-}" in
  config-get)      shift; cmd_config_get "$@" ;;
  set-mode)        shift; cmd_set_mode "$@" ;;
  set-allow)       shift; cmd_set_allow "$@" ;;
  mark-seen)       shift; cmd_mark_seen "$@" ;;
  mark-all-seen)   shift; cmd_mark_all_seen "$@" ;;
  send)            shift; cmd_send "$@" ;;
  media)           shift; cmd_media "$@" ;;
  play)            shift; cmd_play "$@" ;;
  open)            shift; cmd_open "$@" ;;
  webapp)          shift; cmd_webapp "$@" ;;
  whisper-status)  shift; cmd_whisper_status "$@" ;;
  transcribe)      shift; cmd_transcribe "$@" ;;
  install-whisper) shift; cmd_install_whisper "$@" ;;
  *) emit_error "unknown subcommand: ${1:-<none>}" ;;
esac
