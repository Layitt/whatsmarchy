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

command -v jq >/dev/null 2>&1 || { printf '{"ok":false,"error":"jq is not installed"}\n'; exit 0; }

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-whatsmarchy"
MEDIA_CACHE="$CACHE_DIR/media"
# Voice notes the user records here, before they are sent. Kept apart from the
# media cache: that holds other people's attachments and is pruned lazily, this
# holds the user's own microphone and must be emptied eagerly.
VOICE_DIR="$CACHE_DIR/outgoing"
# WhatsApp itself allows far longer, but this is a bar-widget quick reply, not a
# recording studio, and an unbounded cap means a forgotten click records until
# the disk fills. The panel counts down to the same ceiling and stops there.
VOICE_MAX_SECONDS=120
# Captured at the device's native rate so nothing resamples on the way in;
# libopus takes 48 kHz directly.
VOICE_RATE=48000
VOICE_BYTES_PER_SEC=$((VOICE_RATE * 2))   # mono s16
# A recording that is still on disk hours later was never sent and never
# discarded — a crash, a logout, an OOM kill. It is microphone audio, so it goes.
VOICE_MAX_AGE_MINUTES=180
# Ceiling for anything handed to an image decoder, a media player, or a viewer.
MAX_MEDIA_BYTES=$((500 * 1024 * 1024))
# Ceiling for remote profile picture (avatar) downloads from WhatsApp CDN.
MAX_AVATAR_BYTES=$((2 * 1024 * 1024))
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
  # SQL_NAME_MAX (from lib.sh) is a fixed integer constant, not caller-controlled
  # data, so interpolating it here doesn't reopen the injection risk this heredoc
  # otherwise avoids by keeping every WhatsApp-controlled value out of the SQL text.
  rows="$( { sqlite3 -readonly -noheader -batch -- "$db" <<SQL 2>&1
    SELECT COALESCE(json_group_array(json_object(
      'value', jid, 'label',
        replace(replace(replace(label, '<', ' '), '>', ' '), '&', ' '),
      'description', descr
    )), '[]')
    FROM (
      SELECT
        c.jid AS jid,
        substr(COALESCE(NULLIF(c.name,''), NULLIF(g.name,''), NULLIF(ct.push_name,''),
                 NULLIF(ct.full_name,''), NULLIF(ct.business_name,''),
                 NULLIF(ct.phone,''), c.jid), 1, $SQL_NAME_MAX) AS label,
        CASE c.kind
          WHEN 'group'      THEN 'Group'
          WHEN 'dm'         THEN 'Direct message'
          WHEN 'newsletter' THEN 'Channel'
          ELSE substr(COALESCE(c.kind,'Chat'), 1, $SQL_NAME_MAX)
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
  } | head -c "$SQL_OUTPUT_MAX" )" || emit_error "sqlite read failed: $rows"

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

# Real WhatsApp read receipts, on top of this widget's own local watermark.
#
# wacli's store lock is held exclusively for the entire lifetime of
# `wacli sync --follow` — confirmed by hand: `wacli send` works fine
# alongside it, `wacli chats mark-read` does not (an asymmetry in wacli
# itself, nothing to route around from here). So marking read for real means
# briefly stopping the sync service, sending the receipt(s), and starting it
# back up. A few seconds without new messages arriving, traded for the phone
# actually showing "read" — an accepted, deliberate tradeoff.
#
# Best-effort and silent on failure: this must never block or fail the local
# watermark update, which is the part the widget's own state depends on.
mark_read_remote() {
  command -v systemctl >/dev/null 2>&1 || return 0
  command -v wacli >/dev/null 2>&1 || return 0
  local jid count=0
  trap 'systemctl --user start whatsmarchy-sync >/dev/null 2>&1' EXIT INT TERM RETURN
  systemctl --user stop whatsmarchy-sync >/dev/null 2>&1
  while IFS= read -r jid; do
    [[ -n "$jid" ]] || continue
    is_jid "$jid" || continue
    (( count >= 30 )) && break
    (( count++ ))
    timeout 5s wacli chats mark-read --chat "$jid" --json --lock-wait 3s >/dev/null 2>&1 || true
  done
  return 0
}

# mark-seen moves a chat's acknowledgement watermark forward. Never backward:
# a stale panel payload replaying an old timestamp must not resurrect messages
# the user already dismissed.
cmd_mark_seen() {
  local jid="${1-}" ts="${2-}" remote="${3:-1}" cfg now
  is_jid "$jid" || emit_error "invalid chat id"
  is_uint "$ts" || emit_error "invalid timestamp"
  now="$(date +%s)"
  (( ts > now )) && ts="$now"
  cfg="$(read_config | jq -c --slurpfile j <(json_arg "$(json_string "$jid")") --argjson t "$ts" \
    '.seen[$j[0]] = ([(.seen[$j[0]] // 0), $t] | max)')" || emit_error "could not update config"
  write_config "$cfg" || emit_error "cannot write $(config_path)"
  if [[ "$remote" != "0" ]]; then
    ( printf '%s\n' "$jid" | mark_read_remote ) >/dev/null 2>&1 &
  fi
  emit_ok --argjson done true
}

# ---------------------------------------------------------------------------
# send — quick text reply. Always a human typing into the panel and pressing
# send; this plugin has no autonomous or scheduled send path of any kind.
# ---------------------------------------------------------------------------
cmd_send() {
  local jid="${1-}" reply_to="${2-}" reply_sender="${3-}" msg out
  is_jid "$jid" || emit_error "invalid chat id"
  require_cmd wacli
  msg="$(cat)"
  msg="${msg%$'\n'}"
  [[ -n "$msg" ]] || emit_error "empty message"
  (( ${#msg} <= 8000 )) || emit_error "message too long"

  local extra_flags=()
  if [[ -n "$reply_to" ]]; then
    is_msg_id "$reply_to" || emit_error "invalid reply message id"
    extra_flags+=(--reply-to "$reply_to")
    if [[ -n "$reply_sender" ]]; then
      is_jid "$reply_sender" || emit_error "invalid reply sender id"
      extra_flags+=(--reply-to-sender "$reply_sender")
    fi
  fi

  out="$(wacli send text --to "$jid" --message "$msg" "${extra_flags[@]}" --post-send-wait 0 --lock-wait 3s --no-preview --json 2>&1)"
  if (( $? != 0 )); then
    emit_error "send failed: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
  fi
  emit_ok --argjson sent true
}

# ---------------------------------------------------------------------------
# pick-file — opens desktop file dialog and returns chosen file info
# ---------------------------------------------------------------------------
cmd_pick_file() {
  local path="${1-}"
  if [[ -z "$path" ]]; then
    if command -v zenity >/dev/null 2>&1; then
      path="$(zenity --file-selection --title="Seleccionar archivo para enviar" 2>/dev/null || true)"
    elif command -v kdialog >/dev/null 2>&1; then
      path="$(kdialog --getopenfilename --title="Seleccionar archivo para enviar" 2>/dev/null || true)"
    fi
  fi
  if [[ -n "$path" && -f "$path" && -r "$path" ]]; then
    local size fname mime
    size="$(stat -c '%s' -- "$path" 2>/dev/null || printf '0')"
    fname="$(basename -- "$path")"
    mime="$(file --brief --mime-type -- "$path" 2>/dev/null || printf 'application/octet-stream')"
    emit_ok --arg path "$path" --arg name "$fname" --argjson size "$size" --arg mime "$mime"
  else
    emit_ok --arg path ""
  fi
}

# ---------------------------------------------------------------------------
# send-file — sends a file to the recipient via wacli
# ---------------------------------------------------------------------------
cmd_send_file() {
  local jid="${1-}" path="${2-}" caption="${3-}" out rc
  is_jid "$jid" || emit_error "invalid chat id"
  [[ -f "$path" && -r "$path" ]] || emit_error "file not found or not readable"
  require_cmd wacli

  local flags=(send file --to "$jid" --file "$path" --post-send-wait 0 --lock-wait 3s --json)
  if [[ -n "$caption" ]]; then
    (( ${#caption} <= 8000 )) || emit_error "caption too long"
    flags+=(--caption "$caption")
  fi

  out="$(wacli "${flags[@]}" 2>&1)"
  rc=$?
  if (( rc != 0 )); then
    emit_error "send file failed: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
  fi
  emit_ok --argjson sent true
}

# ---------------------------------------------------------------------------
# voice — record a reply from the microphone, listen back, then send it.
#
# Same rule as the text reply: a human holds the whole loop. Recording starts
# on a click, stops on a click, and nothing leaves this machine until the user
# has had the chance to play it back and press Send. There is no path here that
# records or sends without one.
#
# The panel never sees the recording's path. `voice-record` hands back an opaque
# token and every later step rebuilds the path from VOICE_DIR, so no argument
# from the QML side can point at a file this plugin did not create.
# ---------------------------------------------------------------------------
# Kept separate from ensure_voice_dir so `voice-status` can call it too. The
# panel probes voice-status on every open, so a recording orphaned by a crash is
# swept the next time the panel is looked at, rather than only if and when the
# user happens to record again. Symlinks are swept alongside files: a stray
# `.send-*` link left behind by a failed hand-off is not a regular file.
sweep_voice_dir() {
  [[ -d "$VOICE_DIR" && ! -L "$VOICE_DIR" ]] || return 0
  find "$VOICE_DIR" -maxdepth 1 \( -type f -o -type l \) \
    -mmin "+$VOICE_MAX_AGE_MINUTES" -delete 2>/dev/null
  return 0
}

ensure_voice_dir() {
  # Refused rather than followed, the same way lib.sh refuses a symlinked config
  # file: `mkdir -p` is perfectly happy with a symlink to a directory, and the
  # chmod below — plus every recording after it — would land on its target.
  [[ -L "$VOICE_DIR" ]] && emit_error "refusing to use a symlinked $VOICE_DIR"
  mkdir -p -- "$VOICE_DIR" 2>/dev/null || emit_error "cannot create $VOICE_DIR"
  chmod 700 -- "$CACHE_DIR" "$VOICE_DIR" 2>/dev/null
  sweep_voice_dir
  return 0
}

# parecord is tried first even though pw-record is the PipeWire-native tool:
# pw-record asks the session manager for a capture node and will not link to a
# monitor, so on a machine whose chosen default input *is* a monitor it fails
# outright with "no target node available". parecord takes whatever the server
# reports as the default source, which is the device the user actually picked in
# their audio settings. Neither is given an explicit --target: choosing the
# input device is the desktop's job, not this widget's.
pick_recorder() {
  local bin
  for bin in parecord pw-record; do
    command -v "$bin" >/dev/null 2>&1 && { printf '%s' "$bin"; return 0; }
  done
  return 1
}

have_libopus() {
  # ffmpeg also ships a native "opus" encoder, but it is the experimental one;
  # WhatsApp voice notes are libopus territory, so the check is specific.
  # Not `grep -q`: this script runs under `set -o pipefail`, and a -q that exits
  # on the first match SIGPIPEs ffmpeg, which then fails the whole pipeline —
  # reporting a perfectly good encoder as missing.
  ffmpeg -hide_banner -encoders 2>/dev/null | grep '[[:space:]]libopus[[:space:]]' >/dev/null
}

cmd_voice_status() {
  local rec
  # Not ensure_voice_dir: its mkdir failure path emits an error, which would
  # turn a permissions problem into "voice replies are unavailable" instead of
  # saying what is actually wrong.
  sweep_voice_dir
  command -v ffmpeg >/dev/null 2>&1 \
    || emit_ok --argjson available false --arg reason "ffmpeg" \
               --arg detail "ffmpeg is not installed"
  have_libopus \
    || emit_ok --argjson available false --arg reason "opus" \
               --arg detail "this ffmpeg has no libopus encoder"
  rec="$(pick_recorder)" \
    || emit_ok --argjson available false --arg reason "recorder" \
               --arg detail "no recorder found (pw-record from pipewire, or parecord)"
  emit_ok --argjson available true --arg recorder "$rec" \
          --argjson maxSeconds "$VOICE_MAX_SECONDS"
}

# Records until the caller closes this script's stdin, or until the ceiling.
#
# stdin is the stop channel, and nothing is ever read from it. That is not a
# trick for its own sake: it makes "the panel went away" and "the user pressed
# Stop" the same event. A recorder that had to be stopped by a second, separate
# command would keep the microphone open if the shell that was going to send it
# ever died — and a hot microphone nobody can see is the one failure this
# feature is not allowed to have.
cmd_voice_record() {
  local max="${1-}" rec out raw tok rec_pid size secs peak silent
  is_uint "$max" || max="$VOICE_MAX_SECONDS"
  (( max < 1 )) && max=1
  (( max > VOICE_MAX_SECONDS )) && max="$VOICE_MAX_SECONDS"
  require_cmd ffmpeg
  have_libopus || emit_error "this ffmpeg has no libopus encoder"
  rec="$(pick_recorder)" || emit_error "no recorder found (pw-record from pipewire, or parecord)"
  ensure_voice_dir

  out="$(mktemp "$VOICE_DIR/rec-XXXXXXXXXXXX.ogg")" || emit_error "cannot create a recording file"
  chmod 600 -- "$out" 2>/dev/null
  tok="${out##*/rec-}"; tok="${tok%.ogg}"
  is_rec_token "$tok" || { rm -f -- "$out"; emit_error "cannot create a recording file"; }
  # Raw mono PCM, so there is no header to finalise: a capture cut off at any
  # instant is still exactly the audio recorded up to that instant.
  # mktemp again rather than a name derived from $tok: an O_EXCL create cannot
  # be talked into following a symlink someone left in the directory first,
  # which a plain `> "$VOICE_DIR/.raw-$tok"` could.
  raw="$(mktemp "$VOICE_DIR/.raw-XXXXXXXXXXXX")" \
    || { rm -f -- "$out"; emit_error "cannot create the capture buffer"; }
  chmod 600 -- "$raw" 2>/dev/null

  # Armed the instant the buffer exists and never disarmed: the raw PCM is
  # microphone audio and must not survive this process however it ends.
  trap 'rm -f -- "$raw" 2>/dev/null' EXIT

  rec_pid=""
  # Signals reach this script, not the recorder, so the microphone is closed
  # explicitly on every exit path. The half-written recording goes with it —
  # a killed recording was never confirmed by anyone. emit_error rather than a
  # bare exit: the panel parses stdout, and this script's contract is one JSON
  # object, never an empty stream that reads as a parse failure. This stays
  # armed through the encode below, which is seconds of real time on a long
  # take and used to be an unguarded window.
  trap 'kill -TERM "$rec_pid" 2>/dev/null; rm -f -- "$out" 2>/dev/null; emit_error "recording was interrupted"' TERM INT HUP QUIT

  # `timeout` is the backstop for the one signal bash cannot trap. Every other
  # stop path runs *in this script* — the read below, the kill after it, the
  # trap above — so a SIGKILL here (OOM, `pkill -9`) would otherwise orphan the
  # recorder onto init with the microphone still open and nothing to close it:
  # it never reads stdin, so the EOF that stops everything else means nothing to
  # it. With this it ends on its own even with no parent left alive. timeout
  # forwards SIGTERM to its child, so the explicit kill below still works.
  # --latency bounds how much audio is still in flight when that kill lands. At
  # the default it is most of a second, and that second is the end of the user's
  # sentence.
  case "$rec" in
    parecord)
      timeout -k 2 "$(( max + 5 ))" \
        parecord --raw --rate="$VOICE_RATE" --channels=1 --format=s16le \
          --latency-msec=100 "$raw" >/dev/null 2>&1 &
      ;;
    pw-record)
      timeout -k 2 "$(( max + 5 ))" \
        pw-record --raw --rate="$VOICE_RATE" --channels=1 --format=s16 \
          --latency=100ms "$raw" >/dev/null 2>&1 &
      ;;
  esac
  rec_pid=$!

  # Returns on EOF (the panel closed stdin), on any line written to it, or at
  # the ceiling. All three mean the same thing: stop now.
  read -r -t "$max" _ <&0

  kill -TERM "$rec_pid" 2>/dev/null
  wait "$rec_pid" 2>/dev/null
  rec_pid=""

  size="$(stat -c '%s' -- "$raw" 2>/dev/null || printf '0')"
  is_uint "$size" || size=0
  # A quarter second of audio is a misclick, and an empty capture usually means
  # there was no usable input device at all. Either way there is nothing worth
  # offering to send, and saying so beats a preview that plays nothing.
  if (( size < VOICE_BYTES_PER_SEC / 4 )); then
    rm -f -- "$out"
    emit_error "nothing was captured — check which input device your audio settings default to"
  fi
  secs=$(( size / VOICE_BYTES_PER_SEC ))

  # -application voip is the Opus mode tuned for speech, which is what a voice
  # note is. 32 kbit/s mono is comfortably transparent for it.
  ffmpeg -nostdin -loglevel error -y -f s16le -ar "$VOICE_RATE" -ac 1 -i "$raw" \
    -c:a libopus -b:a 32k -vbr on -application voip -f ogg "$out" >/dev/null 2>&1 \
    || { rm -f -- "$out"; emit_error "could not encode the recording (ffmpeg failed)"; }

  # A recording that captured only silence is the common outcome when the
  # default input is a monitor or a muted device, and it is indistinguishable
  # from a good one until someone plays it. The panel says so next to Play
  # rather than letting the user find out after sending.
  #
  # Three states, not two. If the measurement itself fails — ffmpeg errors, the
  # log format shifts — folding that into `false` would silently retire the one
  # warning whose whole job is to stop a blank note being sent. "Unknown" says
  # so instead. (An all-zero capture reports max_volume: -91.0 dB, not -inf, so
  # the ordinary silent case does parse.)
  silent=null
  peak="$(ffmpeg -nostdin -hide_banner -f s16le -ar "$VOICE_RATE" -ac 1 -i "$raw" \
            -af volumedetect -f null - 2>&1 \
          | sed -n 's/.*max_volume:[[:space:]]*\(-\{0,1\}[0-9.]*\)[[:space:]]*dB.*/\1/p' | tail -n 1)"
  if [[ -n "$peak" ]]; then
    # Piped rather than `awk -v p=…`: the peak level is a measurement of the
    # user's microphone, and this codebase does not put microphone data on a
    # command line even when it is only one number.
    if printf '%s\n' "$peak" | awk '{ exit !($1 <= -50) }'; then silent=true; else silent=false; fi
  fi

  emit_ok --arg token "$tok" --argjson seconds "$secs" --argjson silent "$silent"
}

cmd_voice_play() {
  local tok="${1-}" path
  is_rec_token "$tok" || emit_error "invalid recording id"
  path="$VOICE_DIR/rec-$tok.ogg"
  # -L as well as -f: VOICE_DIR is the user's own, but a symlink dropped in it
  # would otherwise turn Play into "open whatever this points at".
  #
  # Unlike the config read (lib.sh, which decides on the descriptor it reads
  # from) and unlike voice-send below (which renames the file out from under
  # its predictable name before handing it to wacli), this check still
  # describes the path rather than the file the player will open: the path is
  # looked up a second time by mpv itself, and a same-user process could swap
  # it in that gap. Left as it is deliberately — the whole outcome of winning
  # that race is that a file the user already owns gets played through their
  # own speakers, in a 0700 directory, by a player invoked with --no-config
  # and --load-unsafe-playlists=no. Nothing leaves the machine and nothing is
  # written; the two paths where the stake is higher — the authorization
  # config, and sending a file to a contact — are closed properly.
  [[ -f "$path" && ! -L "$path" && -s "$path" ]] || emit_error "that recording is no longer available"
  spawn_player "$path"
  emit_ok --arg token "$tok"
}

cmd_voice_send() {
  local jid="${1-}" tok="${2-}" path staged out rc
  is_jid "$jid"       || emit_error "invalid chat id"
  is_rec_token "$tok" || emit_error "invalid recording id"
  require_cmd wacli
  path="$VOICE_DIR/rec-$tok.ogg"
  [[ -f "$path" && ! -L "$path" && -s "$path" ]] || emit_error "that recording is no longer available"

  # That check describes what $path is *now*. `rec-<token>.ogg` is a name the
  # panel knows and could be predicted, so another process running as this user
  # could still swap it for a symlink in the gap before wacli opens it — turning
  # Send into "hand an arbitrary file to a WhatsApp contact". Renaming it under a
  # name nothing has ever seen closes the window from both ends: a swap before
  # the rename is caught by the re-check (mv renames a symlink, it does not
  # follow it), and after the rename there is no name left to race.
  staged="$(mktemp "$VOICE_DIR/.send-XXXXXXXXXXXX.ogg")" || emit_error "cannot stage the recording"
  mv -f -- "$path" "$staged" 2>/dev/null \
    || { rm -f -- "$staged"; emit_error "cannot stage the recording"; }
  [[ -f "$staged" && ! -L "$staged" && -s "$staged" ]] \
    || { rm -f -- "$staged"; emit_error "that recording is no longer available"; }

  # `send voice` is wacli's shortcut for `send file --ptt`; it wants OGG/Opus,
  # which is exactly what cmd_voice_record produced. The mime is spelled out
  # because WhatsApp only renders a voice bubble when the codecs parameter is
  # present — a bare audio/ogg arrives as a file attachment instead.
  # Unlike a reply body, the arguments here are a path this plugin generated and
  # a JID the panel already puts on this script's own command line, so nothing
  # new is exposed in `ps` by passing them.
  out="$(wacli send voice --to "$jid" --file "$staged" --post-send-wait 0 --lock-wait 3s --json 2>&1)"
  rc=$?
  if (( rc != 0 )); then
    # Moved back under the name the panel knows, so Send can be pressed again.
    # If even that fails the recording is dropped rather than left under a name
    # nothing can ever reach.
    mv -f -- "$staged" "$path" 2>/dev/null || rm -f -- "$staged"
    emit_error "send failed: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
  fi
  rm -f -- "$staged"
  emit_ok --argjson sent true
}

cmd_voice_discard() {
  local tok="${1-}" path removed=false
  is_rec_token "$tok" || emit_error "invalid recording id"
  path="$VOICE_DIR/rec-$tok.ogg"
  [[ -L "$path" ]] && emit_error "refusing to follow a symlink in $VOICE_DIR"
  # Reported honestly rather than always true, so "deleted it" and "there was
  # nothing there" stay distinguishable in a log or a bug report.
  [[ -e "$path" ]] && removed=true
  rm -f -- "$path"
  emit_ok --argjson discarded "$removed"
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
  local store db row local_path mime target out actual_chat_jid tmp dl_chat size real_store real_file
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
        'chatJid',   COALESCE(chat_jid,''),
        'localPath', COALESCE(local_path,''),
        'mime',      COALESCE(mime_type,''),
        'type',      COALESCE(media_type,'')
      )
      FROM messages
      WHERE msg_id = :mid
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

  actual_chat_jid="$(printf '%s' "$row" | jq -r '.chatJid')"
  local_path="$(printf '%s' "$row" | jq -r '.localPath')"
  mime="$(printf '%s' "$row" | jq -r '.mime')"

  # A local_path recorded by wacli is trusted only after confirming it really
  # resolves inside wacli's own store directory. The column is data, and a
  # path outside the store would mean handing an arbitrary file to a media
  # player on a click.
  if [[ -n "$local_path" && -f "$local_path" ]]; then
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
  dl_chat="${actual_chat_jid:-$jid}"
  is_jid "$dl_chat" || emit_error "invalid chat id for media download"
  tmp="$(mktemp "$MEDIA_CACHE/.dl.XXXXXX")" || emit_error "cannot create a download temp file"
  chmod 600 -- "$tmp" 2>/dev/null
  trap 'rm -f -- "$tmp"' RETURN
  # --read-only keeps this out of session.db and off the store lock, so it
  # cannot disturb a running `wacli sync --follow`. Media is fetched straight
  # from WhatsApp's CDN using the key already stored in wacli.db.
  out="$(wacli --read-only media download --chat "$dl_chat" --id "$msg_id" --output "$tmp" 2>&1)"
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

# Plain playback of the raw file — no transcoding, no extra dependency beyond a
# player that is already on essentially every desktop.
# The bytes are attacker-supplied and mpv identifies a file by content, not by
# the extension this cache gave it: an "audio/mpeg" attachment whose body is
# `#EXTM3U` + a URL would otherwise be opened as a playlist and its entries
# fetched on a Play click. --no-config also keeps the user's mpv.conf and any
# user Lua scripts out of the picture. Recordings made here go through the same
# invocation: the flags cost nothing and one playback path is one path to audit.
# Called only from a cmd_* body in the main shell, so its emit_error is the
# script's whole answer rather than a string captured in a substitution.
spawn_player() {
  local path="$1"
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
}

cmd_play() {
  local jid="${1-}" msg_id="${2-}" path
  is_jid "$jid"       || emit_error "invalid chat id"
  is_msg_id "$msg_id" || emit_error "invalid message id"
  resolve_media_path "$jid" "$msg_id"
  path="$RESOLVED_MEDIA"
  [[ -n "$path" && -s "$path" ]] || emit_error "attachment is not available locally"
  spawn_player "$path"
  emit_ok --arg path "$path"
}

cmd_open() {
  local jid="${1-}" msg_id="${2-}" path ext
  is_jid "$jid"       || emit_error "invalid chat id"
  is_msg_id "$msg_id" || emit_error "invalid message id"
  resolve_media_path "$jid" "$msg_id"
  path="$RESOLVED_MEDIA"
  [[ -n "$path" && -s "$path" ]] || emit_error "attachment is not available locally"
  ext="$(printf '%s' "${path##*.}" | tr 'A-Z' 'a-z')"
  case "$ext" in
    desktop | directory | sh | bash | zsh | fish | csh | ksh | command | \
    py | pl | rb | php | js | cjs | mjs | exe | appimage | run | com | bat | \
    cmd | bin | jar | service | timer | socket | deb | rpm | apk | pkg* | msi | vbs | ps1)
      emit_error "refusing to open executable file type ($ext) for security"
      ;;
  esac
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
# ---------------------------------------------------------------------------
# all-chats — lists all conversations in wacli.db (recent/active chats)
# ---------------------------------------------------------------------------
cmd_all_chats() {
  require_cmd sqlite3
  local limit="${1:-50}" query="${2:-}" store db rows
  is_uint "$limit" || limit=50
  (( limit > 200 )) && limit=200

  store="$(resolve_store_dir)" || emit_error "wacli store not found"
  db="$store/wacli.db"
  [[ -r "$db" ]] || emit_error "cannot read $db"

  local clean_query pattern esc_query
  clean_query="$(printf '%s' "$query" | tr -cd '[:alnum:] @._-')"
  if [[ -n "$clean_query" ]]; then
    pattern="%${clean_query}%"
  else
    pattern=""
  fi
  esc_query="${pattern//\'/\'\'}"

  rows="$( { printf ".parameter set :lim %d\n" "$limit"
            printf ".parameter set :query '%s'\n" "$esc_query"
            printf ".parameter set :name_max %d\n" "$SQL_NAME_MAX"
            printf ".parameter set :field_max %d\n" "$SQL_FIELD_MAX"
            cat <<'SQL'
    SELECT COALESCE(json_group_array(json_object(
      'jid', jid,
      'name', replace(replace(replace(name, '<', ' '), '>', ' '), '&', ' '),
      'kind', kind,
      'lastTs', last_ts,
      'unread', unread_cnt,
      'snippet', replace(replace(replace(snippet, '<', ' '), '>', ' '), '&', ' '),
      'lastSender', replace(replace(replace(last_sender, '<', ' '), '>', ' '), '&', ' ')
    )), '[]')
    FROM (
      SELECT
        c.jid AS jid,
        substr(COALESCE(NULLIF(g.name,''), NULLIF(NULLIF(c.name,''), c.jid), NULLIF(ct.push_name,''),
                 NULLIF(ct.full_name,''), NULLIF(ct.business_name,''), c.jid), 1, :name_max) AS name,
        c.kind AS kind,
        COALESCE(c.last_message_ts, 0) AS last_ts,
        c.unread_count AS unread_cnt,
        substr(COALESCE(NULLIF(m.text,''), NULLIF(m.media_caption,''), NULLIF(m.display_text,''),
                 CASE WHEN m.media_type IS NOT NULL AND m.media_type <> '' THEN '[' || m.media_type || ']' ELSE '' END), 1, :field_max) AS snippet,
        substr(COALESCE(NULLIF(m.sender_name,''), NULLIF(mct.push_name,''), NULLIF(mct.full_name,''), ''), 1, :name_max) AS last_sender
      FROM chats c
      LEFT JOIN groups g ON g.jid = c.jid
      LEFT JOIN contacts ct ON ct.jid = c.jid
      LEFT JOIN messages m ON m.rowid = (
        SELECT m2.rowid FROM messages m2
        WHERE m2.chat_jid = c.jid AND m2.deleted_at IS NULL AND m2.revoked = 0
        ORDER BY m2.ts DESC LIMIT 1
      )
      LEFT JOIN contacts mct ON mct.jid = m.sender_jid
      WHERE c.jid <> 'status@broadcast'
        AND c.kind IN ('dm', 'group', 'newsletter')
        AND (
          :query = ''
          OR c.jid LIKE :query
          OR c.name LIKE :query
          OR g.name LIKE :query
          OR ct.push_name LIKE :query
          OR ct.full_name LIKE :query
          OR ct.first_name LIKE :query
        )
      ORDER BY COALESCE(c.last_message_ts, 0) DESC
      LIMIT :lim
    );
SQL
  } | sqlite3 -readonly -noheader -batch -- "$db" 2>&1 | head -c "$SQL_OUTPUT_MAX" )" || emit_error "sqlite read failed: $rows"

  printf '%s' "$rows" | jq -e 'type == "array"' >/dev/null 2>&1 \
    || emit_error "unexpected query result"

  printf '{"ok":true,"chats":%s}\n' "$rows"
  exit 0
}

# ---------------------------------------------------------------------------
# chat-messages — retrieves recent messages for a specific chat
# ---------------------------------------------------------------------------
cmd_chat_messages() {
  require_cmd sqlite3
  local jid="${1:-}" limit="${2:-40}" search="${3-}" store db rows
  is_jid "$jid" || emit_error "invalid JID: $jid"
  is_uint "$limit" || limit=40
  (( limit > 100 )) && limit=100

  store="$(resolve_store_dir)" || emit_error "wacli store not found"
  db="$store/wacli.db"
  [[ -r "$db" ]] || emit_error "cannot read $db"

  local clean_search pattern="" esc_search esc_jid
  clean_search="$(printf '%s' "$search" | tr -cd '[:alnum:] @._-')"
  if [[ -n "$clean_search" ]]; then
    pattern="%${clean_search}%"
  fi
  esc_search="${pattern//\'/\'\'}"
  esc_jid="${jid//\'/\'\'}"

  rows="$( { printf ".parameter set :jid '%s'\n" "$esc_jid"
            printf ".parameter set :lim %d\n" "$limit"
            printf ".parameter set :search '%s'\n" "$esc_search"
            cat <<'SQL'
    WITH target_jids AS (
      SELECT :jid AS jid
      UNION
      SELECT c2.jid FROM chats c1 JOIN chats c2 ON c1.name = c2.name WHERE c1.jid = :jid AND c1.name IS NOT NULL AND c1.name != ''
      UNION
      SELECT c2.jid FROM contacts c1 JOIN contacts c2 ON (c1.push_name = c2.push_name OR c1.full_name = c2.full_name) WHERE c1.jid = :jid AND ((c1.push_name IS NOT NULL AND c1.push_name != '') OR (c1.full_name IS NOT NULL AND c1.full_name != ''))
    )
    SELECT COALESCE(json_group_array(json_object(
      'id',             m.msg_id,
      'chatJid',        m.chat_jid,
      'ts',             m.ts,
      'fromMe',         m.from_me = 1,
      'sender',         replace(replace(replace(COALESCE(NULLIF(m.sender_name,''), NULLIF(ct.push_name,''), NULLIF(ct.full_name,''), CASE WHEN m.from_me = 1 THEN 'Tú' ELSE '' END), '<', ' '), '>', ' '), '&', ' '),
      'senderJid',      COALESCE(m.sender_jid, ''),
      'text',           COALESCE(NULLIF(m.text,''), NULLIF(m.media_caption,''), CASE WHEN m.display_text NOT IN ('(message)', 'Sent image', 'Sent video', 'Sent sticker', '[Audio]') THEN NULLIF(m.display_text,'') ELSE '' END, ''),
      'mediaType',      COALESCE(m.media_type,''),
      'mime',           COALESCE(m.mime_type,''),
      'filename',       COALESCE(m.filename,''),
      'localPath',      COALESCE(m.local_path,''),
      'hasMedia',       CASE WHEN m.media_type IN ('image','video','gif','audio','document','sticker') THEN 1 ELSE 0 END,
      'isVoice',        CASE WHEN m.media_type = 'audio' OR (LOWER(COALESCE(m.mime_type, '')) LIKE '%ogg%' OR LOWER(COALESCE(m.mime_type, '')) LIKE '%opus%') THEN 1 ELSE 0 END,
      'quotedId',       COALESCE(m.quoted_msg_id, ''),
      'quotedSender',   COALESCE(NULLIF(q.sender_name,''), NULLIF(qct.push_name,''), NULLIF(qct.full_name,''), CASE WHEN q.from_me = 1 THEN 'Tú' ELSE '' END, ''),
      'quotedText',     COALESCE(NULLIF(q.text,''), NULLIF(q.media_caption,''), NULLIF(q.display_text,''), CASE WHEN q.media_type IS NOT NULL AND q.media_type != '' THEN '[' || q.media_type || ']' ELSE '' END, ''),
      'quotedMediaType',COALESCE(q.media_type, ''),
      'reactions',      COALESCE((
        SELECT json_group_array(json_object(
          'emoji', r.reaction_emoji,
          'sender', COALESCE(NULLIF(r.sender_name,''), NULLIF(rct.push_name,''), NULLIF(rct.full_name,''), CASE WHEN r.from_me = 1 THEN 'Tú' ELSE '' END, ''),
          'fromMe', r.from_me = 1
        ))
        FROM messages r
        LEFT JOIN contacts rct ON rct.jid = r.sender_jid
        WHERE r.chat_jid = m.chat_jid AND r.reaction_to_id = m.msg_id AND r.deleted_at IS NULL AND r.reaction_emoji IS NOT NULL AND r.reaction_emoji != ''
      ), json('[]'))
    )), '[]')
    FROM (
      SELECT *
      FROM (
        SELECT *
        FROM messages m
        WHERE m.chat_jid IN (SELECT jid FROM target_jids)
          AND m.deleted_at IS NULL
          AND m.revoked = 0
          AND (
            :search = ''
            OR m.text LIKE :search
            OR m.media_caption LIKE :search
            OR m.display_text LIKE :search
            OR m.filename LIKE :search
          )
        ORDER BY m.ts DESC
        LIMIT :lim
      )
      ORDER BY ts ASC
    ) m
    LEFT JOIN contacts ct ON ct.jid = m.sender_jid
    LEFT JOIN messages q ON q.chat_jid = m.chat_jid AND q.msg_id = m.quoted_msg_id
    LEFT JOIN contacts qct ON qct.jid = COALESCE(q.sender_jid, m.quoted_sender_jid);
SQL
  } | sqlite3 -readonly -noheader -batch -- "$db" 2>&1 | head -c "$SQL_OUTPUT_MAX" )" || emit_error "sqlite read failed: $rows"

  printf '{"ok":true,"jid":"%s","messages":%s}\n' "$jid" "$rows"
  exit 0
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

cmd_avatar() {
  local jid="${1-}" hash cache_dir target none_flag
  is_jid "$jid" || emit_error "invalid chat id"
  require_cmd sha256sum
  cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-whatsmarchy/avatars"
  [[ -L "$cache_dir" ]] && emit_error "refusing to use a symlinked $cache_dir"
  mkdir -p "$cache_dir" 2>/dev/null || emit_error "cannot create $cache_dir"
  chmod 700 "$cache_dir" 2>/dev/null || true
  hash="$(printf '%s' "$jid" | sha256sum | cut -d' ' -f1)"
  target="$cache_dir/$hash.jpg"
  none_flag="$cache_dir/$hash.none"

  if [[ -s "$target" && ! -L "$target" ]]; then
    emit_ok --arg path "$target"
    return 0
  fi
  if [[ -f "$none_flag" && ! -L "$none_flag" ]]; then
    emit_ok --arg path ""
    return 0
  fi
  emit_ok --arg path ""
}

cmd_sync_avatars() {
  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-whatsmarchy/avatars"
  [[ -L "$cache_dir" ]] && emit_error "refusing to use a symlinked $cache_dir"
  mkdir -p "$cache_dir" 2>/dev/null || emit_error "cannot create $cache_dir"
  chmod 700 "$cache_dir" 2>/dev/null || true
  require_cmd sqlite3
  require_cmd sha256sum
  require_cmd jq
  require_cmd curl
  local store db jids missing="" j hash json url count=0 tmp_dl
  store="$(resolve_store_dir)" || emit_error "wacli store not found"
  db="$store/wacli.db"
  [[ -r "$db" ]] || emit_error "cannot read $db"

  # Prune avatars older than 30 days
  find "$cache_dir" -maxdepth 1 -type f -mtime +30 -delete 2>/dev/null || true

  jids="$(sqlite3 -readonly -batch -noheader "$db" "SELECT jid FROM chats WHERE kind IN ('dm','group') ORDER BY last_message_ts DESC LIMIT 20;" 2>/dev/null || true)"
  for j in $jids; do
    [[ -n "$j" ]] || continue
    is_jid "$j" || continue
    hash="$(printf '%s' "$j" | sha256sum | cut -d' ' -f1)"
    if [[ ! -s "$cache_dir/$hash.jpg" && ! -f "$cache_dir/$hash.none" ]]; then
      missing="$missing $j"
    fi
  done

  if [[ -n "$missing" ]]; then
    trap 'systemctl --user start whatsmarchy-sync >/dev/null 2>&1' EXIT INT TERM RETURN
    systemctl --user stop whatsmarchy-sync >/dev/null 2>&1 || true
    for j in $missing; do
      [[ -n "$j" ]] || continue
      is_jid "$j" || continue
      (( count >= 10 )) && break
      (( count++ ))
      hash="$(printf '%s' "$j" | sha256sum | cut -d' ' -f1)"
      json="$(timeout 3s wacli profile picture-info --jid "$j" --json 2>/dev/null || true)"
      url="$(printf '%s' "$json" | jq -r '.data.url // empty' 2>/dev/null || true)"
      if [[ -n "$url" && "$url" != "null" && "$url" =~ ^https:// ]]; then
        tmp_dl="$(mktemp "$cache_dir/.dl.XXXXXX")" 2>/dev/null || continue
        chmod 600 "$tmp_dl" 2>/dev/null || true
        # Strict security rules for remote downloads:
        # - HTTPS only for initial and redirect destinations (--proto =https --proto-redir =https)
        # - Strict response-size cap (--max-filesize)
        # - HTTP error failure flag (--fail)
        # - Download to atomic staging temp file, removed immediately on any failure
        if curl --proto =https --proto-redir =https -s -L -f -m 4 --max-filesize "$MAX_AVATAR_BYTES" -- "$url" -o "$tmp_dl" 2>/dev/null \
           && [[ -s "$tmp_dl" ]]; then
          mv -f -- "$tmp_dl" "$cache_dir/$hash.jpg" 2>/dev/null || rm -f -- "$tmp_dl"
        else
          rm -f -- "$tmp_dl" 2>/dev/null
          touch "$cache_dir/$hash.none" 2>/dev/null || true
        fi
      else
        touch "$cache_dir/$hash.none" 2>/dev/null || true
      fi
    done
    systemctl --user start whatsmarchy-sync >/dev/null 2>&1 || true
  fi
  emit_ok --argjson synced true
}

cmd_react() {
  local jid="${1-}" msg_id="${2-}" emoji="${3-}" sender="${4-}" out
  is_jid "$jid" || emit_error "invalid chat id"
  is_msg_id "$msg_id" || emit_error "invalid message id"
  [[ -n "$emoji" ]] || emit_error "empty reaction emoji"
  [[ "$emoji" =~ ^- ]] && emit_error "invalid reaction emoji"
  local flags=(send react --to "$jid" --id "$msg_id" --reaction "$emoji" --post-send-wait 0 --lock-wait 5s --json)
  if [[ -n "$sender" ]]; then
    is_jid "$sender" || emit_error "invalid sender id"
    flags+=(--sender "$sender")
  fi
  require_cmd wacli
  out="$(wacli "${flags[@]}" 2>&1)"
  if (( $? != 0 )); then
    emit_error "react failed: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
  fi
  emit_ok --argjson reacted true
}

cmd_presence() {
  local jid="${1-}" state="${2:-typing}" media="${3-}"
  is_jid "$jid" || emit_error "invalid chat id"
  case "$state" in
    typing | paused) ;;
    *) emit_error "invalid presence state: expected typing or paused" ;;
  esac
  local flags=(presence "$state" --to "$jid" --lock-wait 2s --json)
  if [[ -n "$media" ]]; then
    case "$media" in
      audio) flags+=(--media "$media") ;;
      *) emit_error "invalid presence media: expected audio" ;;
    esac
  fi
  require_cmd wacli
  wacli "${flags[@]}" >/dev/null 2>&1 &
  emit_ok --arg presence "$state"
}

# ---------------------------------------------------------------------------
# `recipients` reads only wacli.db and never touches the plugin config, and its
# consumer (MultiSelect's optionsCommand) expects a bare JSON array — an
# {"ok":false} object would be rendered as a literal option row instead of an
# error. It is dispatched ahead of the config gate so it cannot emit that shape.
[[ "${1-}" == "recipients" ]] && { shift; cmd_recipients "$@"; }

case "${1-}" in
  all-chats)       shift; cmd_all_chats "$@" ;;
  chat-messages)   shift; cmd_chat_messages "$@" ;;
  config-get)      assert_config_safe; shift; cmd_config_get "$@" ;;
  set-mode)        assert_config_safe; shift; cmd_set_mode "$@" ;;
  set-allow)       assert_config_safe; shift; cmd_set_allow "$@" ;;
  mark-seen)       shift; cmd_mark_seen "$@" ;;
  send)            shift; cmd_send "$@" ;;
  react)           shift; cmd_react "$@" ;;
  presence)        shift; cmd_presence "$@" ;;
  pick-file)       shift; cmd_pick_file "$@" ;;
  send-file)       shift; cmd_send_file "$@" ;;
  voice-status)    shift; cmd_voice_status "$@" ;;
  voice-record)    shift; cmd_voice_record "$@" ;;
  voice-play)      shift; cmd_voice_play "$@" ;;
  voice-send)      shift; cmd_voice_send "$@" ;;
  voice-discard)   shift; cmd_voice_discard "$@" ;;
  media)           shift; cmd_media "$@" ;;
  avatar)          shift; cmd_avatar "$@" ;;
  sync-avatars)    shift; cmd_sync_avatars "$@" ;;
  play)            shift; cmd_play "$@" ;;
  open)            shift; cmd_open "$@" ;;
  webapp)          shift; cmd_webapp "$@" ;;
  *) emit_error "unknown subcommand: ${1:-<none>}" ;;
esac
