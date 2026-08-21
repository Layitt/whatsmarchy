#!/usr/bin/env bash
# Read-only WhatsApp "what's new" poller for the Wamarchy Omarchy bar widget.
#
# Reads wacli's local SQLite mirror (wacli.db) with a read-only connection and
# reports which allowed chats have messages the user has not acknowledged in
# this widget yet. It never connects to WhatsApp, never opens session.db, and
# never writes to the wacli store.
#
# Contract: always exits 0, always emits exactly one JSON object on stdout.
#   success -> {"ok":true,"mode":"..","paused":..,"syncRunning":..,
#               "totalNew":N,"chatCount":N,"topSender":"..","chats":[..]}
#   failure -> {"ok":false,"error":".."}
#
# A failure must never be rendered as "0 new messages": the widget
# distinguishes ok=false (shows a fault marker) from ok=true with totalNew=0.
#
# Usage: wa-status.sh [previewLimit] [includeChannels:0|1]
set -uo pipefail
umask 077

# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { printf '{"ok":false,"error":"jq is not installed"}\n'; exit 0; }
require_cmd sqlite3

PREVIEW_LIMIT="${1:-4}"
INCLUDE_CHANNELS="${2:-0}"
is_uint "$PREVIEW_LIMIT" || PREVIEW_LIMIT=4
(( PREVIEW_LIMIT > 20 )) && PREVIEW_LIMIT=20
[[ "$INCLUDE_CHANNELS" == "1" ]] || INCLUDE_CHANNELS=0

# Hard cap on rows pulled out of SQLite per poll. Well above any realistic
# backlog the widget would display, low enough that a store with a year of
# group history can't turn one poll into a multi-second query.
SCAN_LIMIT=500

STORE_DIR="$(resolve_store_dir)" \
  || emit_error "wacli store not found (looked in \$WACLI_STORE_DIR, ~/.local/state/wacli, ~/.wacli) — is wacli installed and paired?"
DB="$STORE_DIR/wacli.db"
[[ -r "$DB" ]] || emit_error "cannot read $DB"

assert_config_safe
CONFIG="$(read_config)"
MODE="$(printf '%s' "$CONFIG" | jq -r '.mode')"

# --- is anything actually feeding the database? -----------------------------
# wacli.db only grows while `wacli sync --follow` is running. Without it the
# widget would sit at a permanently stale count and look like it works, so the
# state is reported explicitly and surfaced in the panel.
sync_running=false
HEARTBEAT="$STORE_DIR/HEARTBEAT"
if [[ -f "$HEARTBEAT" ]]; then
  hb_mtime="$(stat -c '%Y' -- "$HEARTBEAT" 2>/dev/null)"
  if is_uint "${hb_mtime:-}" && (( $(date +%s) - hb_mtime < 300 )); then
    sync_running=true
  fi
fi
if [[ "$sync_running" == false ]] && command -v pgrep >/dev/null 2>&1; then
  # -x pins the process name to exactly `wacli` so this can't match the
  # widget's own scripts or an editor with "wacli sync" in a buffer title.
  if pgrep -u "$(id -u)" -a -x wacli 2>/dev/null | grep -q ' sync'; then
    sync_running=true
  fi
fi

# --- first run --------------------------------------------------------------
# A fresh install must not open with several thousand "new" messages from the
# entire synced history. The first poll stamps a watermark at now and reports
# a quiet widget; everything after that timestamp counts normally.
SEEN_ALL="$(printf '%s' "$CONFIG" | jq -r '.seenAll')"
if [[ "$SEEN_ALL" == "0" ]]; then
  now="$(date +%s)"
  CONFIG="$(printf '%s' "$CONFIG" | jq -c --argjson n "$now" '.seenAll = $n')"
  write_config "$CONFIG" || emit_error "cannot write $(config_path)"
  SEEN_ALL="$now"
fi
is_uint "$SEEN_ALL" || emit_error "corrupt watermark in $(config_path)"

if [[ "$MODE" == "paused" ]]; then
  jq -cn --arg m "$MODE" --argjson s "$sync_running" \
    '{ok:true, mode:$m, paused:true, syncRunning:$s, totalNew:0, chatCount:0, topSender:"", chats:[]}'
  exit 0
fi

# Only scan back as far as the oldest watermark in play. Per-chat watermarks
# are applied in the jq pass below; this is purely a cheap SQL-side bound.
MIN_TS="$(printf '%s' "$CONFIG" | jq -r '[.seenAll] + ([.seen[]] // []) | min | floor')"
is_uint "$MIN_TS" || MIN_TS="$SEEN_ALL"

if [[ "$INCLUDE_CHANNELS" == "1" ]]; then
  KIND_FILTER="'dm','group','newsletter'"
else
  KIND_FILTER="'dm','group'"
fi

# MIN_TS / SCAN_LIMIT / PREVIEW_LIMIT are the only interpolated values and each
# has been checked to be a bare unsigned integer; KIND_FILTER is a fixed
# literal chosen from two hard-coded alternatives. No caller-controlled string
# reaches the SQL text.
SQL="
SELECT COALESCE(json_group_array(json_object(
  'chatJid',   chat_jid,
  'chatName',  chat_name,
  'kind',      kind,
  'id',        msg_id,
  'ts',        ts,
  'sender',    sender,
  'text',      body,
  'mediaType', mtype,
  'mime',      mime,
  'filename',  fname,
  'localPath', lpath
)), '[]')
FROM (
  SELECT
    m.chat_jid AS chat_jid,
    m.msg_id   AS msg_id,
    m.ts       AS ts,
    COALESCE(NULLIF(m.sender_name,''), NULLIF(ct.push_name,''), NULLIF(ct.full_name,''),
             NULLIF(ct.first_name,''), '')                                      AS sender,
    COALESCE(NULLIF(m.text,''), NULLIF(m.media_caption,''), NULLIF(m.display_text,''), '') AS body,
    COALESCE(m.media_type,'') AS mtype,
    COALESCE(m.mime_type,'')  AS mime,
    COALESCE(m.filename,'')   AS fname,
    COALESCE(m.local_path,'') AS lpath,
    COALESCE(NULLIF(c.name,''), NULLIF(g.name,''), NULLIF(cc.push_name,''),
             NULLIF(cc.full_name,''), NULLIF(cc.business_name,''), m.chat_jid)  AS chat_name,
    c.kind AS kind
  FROM messages m
  JOIN chats c        ON c.jid  = m.chat_jid
  LEFT JOIN contacts ct ON ct.jid = m.sender_jid
  LEFT JOIN contacts cc ON cc.jid = m.chat_jid
  LEFT JOIN groups g    ON g.jid  = m.chat_jid
  WHERE m.from_me = 0
    AND m.ts > $MIN_TS
    AND m.deleted_at IS NULL
    AND m.revoked = 0
    AND m.deleted_for_me = 0
    AND m.payload_purged_at IS NULL
    AND m.reaction_to_id IS NULL
    AND m.chat_jid <> 'status@broadcast'
    AND c.kind IN ($KIND_FILTER)
  ORDER BY m.ts DESC
  LIMIT $SCAN_LIMIT
);
"

# -readonly opens the connection SQLITE_OPEN_READONLY: the poller physically
# cannot mutate wacli's mirror, even if a future query were wrong.
rows="$(sqlite3 -readonly -noheader -batch -- "$DB" "$SQL" 2>&1)"
sqlite_status=$?
if (( sqlite_status != 0 )); then
  emit_error "sqlite read failed: ${rows:-unknown error}"
fi
printf '%s' "$rows" | jq -e 'type == "array"' >/dev/null 2>&1 \
  || emit_error "unexpected query result from $DB"

printf '%s' "$rows" | jq -c \
  --argjson cfg "$CONFIG" \
  --argjson limit "$PREVIEW_LIMIT" \
  --argjson syncRunning "$sync_running" '
  ($cfg.seenAll) as $seenAll
  | ($cfg.seen)  as $seen
  | ($cfg.mode)  as $mode
  | ($cfg.allow | map({key: ., value: true}) | from_entries) as $allowSet
  # Per-chat watermark: the chat has its own timestamp once it has been
  # acknowledged, otherwise the global one set on first run.
  | map(select(.ts > ($seen[.chatJid] // $seenAll)))
  | map(select($mode == "all" or ($allowSet[.chatJid] // false)))
  | group_by(.chatJid)
  | map(
      (. | sort_by(.ts)) as $msgs
      | {
          jid:    $msgs[0].chatJid,
          name:   ($msgs[-1].chatName // $msgs[0].chatJid),
          kind:   ($msgs[0].kind // "dm"),
          count:  ($msgs | length),
          lastTs: ($msgs[-1].ts),
          messages: [ $msgs[-($limit):][] | {
            id:        .id,
            ts:        .ts,
            sender:    .sender,
            text:      .text,
            mediaType: .mediaType,
            mime:      .mime,
            filename:  .filename,
            localPath: .localPath,
            hasMedia:  ((.mediaType // "") | IN("image","video","gif","audio","document","sticker")),
            # wacli stores voice notes and plain audio attachments alike as
            # media_type=audio; only the OGG/Opus mime marks a PTT recording.
            isVoice:   (((.mediaType // "") == "audio")
                        and (((.mime // "") | ascii_downcase) | test("ogg|opus")))
          } ]
        }
    )
  | sort_by(-.lastTs)
  | { ok: true,
      mode: $mode,
      paused: false,
      syncRunning: $syncRunning,
      totalNew:  (map(.count) | add // 0),
      chatCount: length,
      topSender: (if length > 0 then .[0].name else "" end),
      chats: . }
' 2>/dev/null || emit_error "could not build status payload"
