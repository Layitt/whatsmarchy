#!/usr/bin/env bash
# Shared helpers for the Whatsmarchy poller and action scripts.
#
# Sourced, never executed. Every function here is expected to be usable from a
# script running under `set -uo pipefail` with `umask 077`.

# The validators below use ranges like [A-Za-z0-9]. Under a UTF-8 locale those
# collate loosely — fr_FR.UTF-8 matches "é", "İ" and friends inside [A-Za-z].
# Nothing dangerous collates in (no quote, slash, or whitespace does), but these
# patterns are meant to be byte-exact, so the collation is pinned rather than
# left to whatever locale the desktop session happens to carry.
export LC_ALL=C

# --- JSON output ------------------------------------------------------------
# Both entry points share one contract: exit 0, print exactly one JSON object.
# A widget that has to distinguish "script crashed" from "no messages" on
# stderr is a widget that will eventually render a wrong count.

json_string() {
  # Encode "$1" as a JSON string. Falls back to a quoted constant rather than
  # emitting invalid JSON if jq is somehow missing mid-run.
  printf '%s' "${1-}" | jq -Rs . 2>/dev/null || printf '"internal"'
}

emit_error() {
  printf '{"ok":false,"error":%s}\n' "$(json_string "${1-unknown error}")"
  exit 0
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || emit_error "$1 is not installed"
}

# --- wacli store ------------------------------------------------------------
# Layout (docs/install.md): $WACLI_STORE_DIR, else ~/.local/state/wacli on
# Linux, else the legacy ~/.wacli. `wacli.db` holds messages/chats/contacts;
# `session.db` holds the WhatsApp keys and is deliberately never touched here.

resolve_store_dir() {
  local candidate
  for candidate in "${WACLI_STORE_DIR:-}" "$HOME/.local/state/wacli" "$HOME/.wacli"; do
    [[ -n "$candidate" ]] || continue
    [[ -f "$candidate/wacli.db" ]] || continue
    printf '%s' "$candidate"
    return 0
  done
  return 1
}

# --- plugin config ----------------------------------------------------------
# Lives outside the plugin folder so a `git pull` on the plugin can never
# clobber it, and so the repo can never accidentally carry a contact list.
#
# Shape:
#   { "mode": "paused|all|custom",
#     "allow": ["<jid>", ...],
#     "seen":  { "<jid>": <unix seconds> },
#     "seenAll": <unix seconds> }

config_path() {
  printf '%s' "${WHATSMARCHY_CONFIG:-$HOME/.config/omarchy/whatsmarchy/config.json}"
}

config_defaults='{"mode":"all","allow":[],"seen":{},"seenAll":0}'

# --- size caps ----------------------------------------------------------
# Everything below ultimately comes from either a hand-editable config file
# or WhatsApp-controlled data (message text, contact/business names,
# filenames) relayed through wacli's SQLite mirror. None of those sources is
# bounded by anything on this machine — a corrupted config or a single
# oversized field from a chat could otherwise be loaded whole into a bash
# command substitution (which has no size limit of its own) and exhaust the
# poller or wedge the long-lived shell. These are generous ceilings for any
# real preview/list use, not a tuned "legitimate maximum".
CONFIG_MAX_BYTES=262144    # 256 KiB cap on how much of config.json is ever read
SQL_FIELD_MAX=4000         # per-field cap for message/body text pulled from SQLite
SQL_NAME_MAX=256           # per-field cap for names/labels (sender, chat, contact)
SQL_PATH_MAX=512           # per-field cap for filenames/paths/mime strings
SQL_OUTPUT_MAX=4194304     # 4 MiB cap on total sqlite3 stdout, belt-and-braces on top
                           # of the per-field caps above and each query's row LIMIT

# Must be called once from the *main shell* of each entry point, before any
# read_config. This file decides which chats may notify and which JIDs later
# reach a `wacli` argument list, so a file owned by someone else — or writable
# by group/other — is refused rather than used.
#
# Deliberately not folded into read_config: that runs inside a command
# substitution, where an emit_error would only kill the subshell and its
# `{"ok":false}` JSON would be captured as if it were the config. A refusal has
# to reach stdout as the script's whole answer.
assert_config_safe() {
  local path st mode owner
  path="$(config_path)"
  [[ -e "$path" || -L "$path" ]] || return 0
  # Refused explicitly rather than as a side effect of a symlink's 777 mode
  # happening to trip the check below: that only works because GNU stat does
  # not dereference by default, and a later switch to `stat -L` would silently
  # reopen a symlink-swap on $WHATSMARCHY_CONFIG.
  [[ -L "$path" ]] && emit_error "config file is a symlink, refusing to use it: $path"
  st="$(stat -c '%a %U' -- "$path" 2>/dev/null)" || emit_error "cannot stat $path"
  mode="${st%% *}"
  owner="${st#* }"
  # An unparseable mode must not sail through: `(( 8#$mode & ... ))` on garbage
  # raises an arithmetic error, and `((` reports that as *false*, which would
  # read as "permissions are fine".
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || emit_error "cannot read permissions of $path"
  [[ "$owner" == "$(id -un)" ]] \
    || emit_error "config file is not owned by you: $path"
  (( 8#$mode & 8#022 )) \
    && emit_error "config file is writable by group/others — chmod 600 it: $path"
  return 0
}

read_config() {
  # Always prints a complete, well-typed config object: a hand-edited file
  # with a missing key or a wrong type must degrade to the default for that
  # key rather than propagate `null` into the widget's counting logic. A file
  # that has grown past CONFIG_MAX_BYTES (corrupt, or something other than
  # this plugin writing to it) is treated the same as an unreadable one — its
  # size alone is reason enough not to load it whole into this shell.
  local path raw size
  path="$(config_path)"
  raw=""
  if [[ -r "$path" ]]; then
    size="$(stat -c '%s' -- "$path" 2>/dev/null)"
    if is_uint "${size:-}" && (( size <= CONFIG_MAX_BYTES )); then
      raw="$(cat -- "$path" 2>/dev/null)"
    fi
  fi
  printf '%s' "${raw:-$config_defaults}" | jq -c --argjson d "$config_defaults" '
    (if type == "object" then . else {} end) as $c
    | {
        mode:    (if ($c.mode | type) == "string" and (["paused","all","custom"] | index($c.mode)) != null
                  then $c.mode else $d.mode end),
        allow:   (if ($c.allow | type) == "array" then [$c.allow[] | select(type == "string")] else [] end),
        seen:    (if ($c.seen | type) == "object" then ($c.seen | with_entries(select(.value | type == "number"))) else {} end),
        seenAll: (if ($c.seenAll | type) == "number" then $c.seenAll else 0 end)
      }
  ' 2>/dev/null || printf '%s' "$config_defaults"
}

write_config() {
  # Atomic replace via a same-directory temp file, so a crash mid-write can
  # never leave a half-written config that read_config would silently reset
  # (which would drop the whole allow-list and start notifying for everyone).
  local path dir tmp payload="$1"
  path="$(config_path)"
  dir="$(dirname -- "$path")"
  mkdir -p -- "$dir" 2>/dev/null || return 1
  chmod 700 -- "$dir" 2>/dev/null
  printf '%s' "$payload" | jq -e . >/dev/null 2>&1 || return 1
  tmp="$(mktemp "$dir/config.XXXXXX")" || return 1
  chmod 600 -- "$tmp" 2>/dev/null
  printf '%s\n' "$payload" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$path" || { rm -f -- "$tmp"; return 1; }
  return 0
}

# --- validation -------------------------------------------------------------
# Everything that reaches an `exec` argument is checked against an allow-list
# pattern first. These values originate in a QML click handler, but they are
# derived from WhatsApp-controlled data (JIDs, message IDs, file names), so
# they are treated as untrusted input throughout.

is_jid() {
  # user@s.whatsapp.net, 1203630...@g.us, ...@lid, ...@newsletter, ...@broadcast
  [[ "${1-}" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}@[a-z][a-z.]{0,31}$ ]]
}

is_msg_id() {
  # WhatsApp message IDs are hex-ish/base32-ish; keep it strict and printable.
  # The first character may not be "-": `wacli media download --id -o` would
  # otherwise hand a flag-shaped value to a Go flag parser. spf13/pflag happens
  # to consume it as a value today, but that is upstream's choice, not a
  # guarantee. "=" is allowed because base64-ish IDs really do carry padding.
  [[ "${1-}" =~ ^[A-Za-z0-9_][A-Za-z0-9_=-]{0,127}$ ]]
}

is_uint() {
  [[ "${1-}" =~ ^[0-9]{1,19}$ ]]
}

is_rec_token() {
  # Handle for an outgoing voice recording this plugin made itself. The panel
  # never learns the file's path — it gets this token back and hands it to
  # play/send/discard, which rebuild the path from a fixed directory. A token
  # that cannot express a separator or a dot cannot escape that directory, so
  # "send this recording" can never become "send this arbitrary file".
  [[ "${1-}" =~ ^[A-Za-z0-9]{6,32}$ ]]
}
