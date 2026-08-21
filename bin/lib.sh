#!/usr/bin/env bash
# Shared helpers for the Wamarchy poller and action scripts.
#
# Sourced, never executed. Every function here is expected to be usable from a
# script running under `set -uo pipefail` with `umask 077`.

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
  printf '%s' "${WAMARCHY_CONFIG:-$HOME/.config/omarchy/wamarchy/config.json}"
}

config_defaults='{"mode":"all","allow":[],"seen":{},"seenAll":0}'

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
  [[ -e "$path" ]] || return 0
  st="$(stat -c '%a %U' -- "$path" 2>/dev/null)" || emit_error "cannot stat $path"
  mode="${st%% *}"
  owner="${st#* }"
  [[ "$owner" == "$(id -un)" ]] \
    || emit_error "config file is not owned by you: $path"
  (( 8#$mode & 8#022 )) \
    && emit_error "config file is writable by group/others — chmod 600 it: $path"
  return 0
}

read_config() {
  # Always prints a complete, well-typed config object: a hand-edited file
  # with a missing key or a wrong type must degrade to the default for that
  # key rather than propagate `null` into the widget's counting logic.
  local path raw
  path="$(config_path)"
  raw=""
  if [[ -r "$path" ]]; then
    raw="$(cat -- "$path" 2>/dev/null)"
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
  [[ "${1-}" =~ ^[A-Za-z0-9_-]{1,128}$ ]]
}

is_uint() {
  [[ "${1-}" =~ ^[0-9]{1,19}$ ]]
}
