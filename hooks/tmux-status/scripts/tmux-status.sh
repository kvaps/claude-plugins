#!/usr/bin/env bash
#
# tmux-status hook: records a raw event for the current pane into a
# per-pane JSON file, so tmux-status-resolve.sh (called periodically
# from tmux's status-interval tick) can compute the live state using
# additional signals (transcript mtime, CPU%, background tasks).
#
# State file: ~/.claude/tmux-status/<pane_id>.json
#
# On SessionEnd the file is removed and @claude_status is cleared.

set -o errexit
set -o nounset
set -o pipefail

# Nothing to do outside a tmux session.
if [[ -z "${TMUX:-}" ]] || [[ -z "${TMUX_PANE:-}" ]]; then
  exit 0
fi

readonly STATUS_DIR="/tmp/kvaps-tmux-status.$(id -u)"
mkdir -p -- "${STATUS_DIR}"

# Sanitize pane_id for filename — pane IDs look like "%42".
pane_id="${TMUX_PANE}"
# Escape the leading % — in bash/zsh, an unescaped % at the start of
# a substitution pattern is treated as an end-anchor, not a literal.
file_id="${pane_id//\%/pct}"
status_file="${STATUS_DIR}/${file_id}.json"

input="$(cat)"

event="$(jq --raw-output '.hook_event_name // empty' <<<"${input}")"
session_id="$(jq --raw-output '.session_id // empty' <<<"${input}")"
cwd="$(jq --raw-output '.cwd // empty' <<<"${input}")"
transcript_path="$(jq --raw-output '.transcript_path // empty' <<<"${input}")"
message="$(jq --raw-output '.message // empty' <<<"${input}")"

if [[ -z "${event}" ]]; then
  exit 0
fi

# SessionEnd: clean up and clear the window option.
if [[ "${event}" == "SessionEnd" ]]; then
  rm -f -- "${status_file}"
  tmux set-window-option -t "${pane_id}" -u @claude_status >/dev/null 2>&1 || true
  exit 0
fi

now_s="$(date +%s)"

# Atomic write via tmp+rename so the resolver never reads a half-written
# file.
jq --null-input \
  --arg pane "${pane_id}" \
  --arg sid "${session_id}" \
  --arg cwd "${cwd}" \
  --arg transcript "${transcript_path}" \
  --arg event "${event}" \
  --arg message "${message}" \
  --argjson now "${now_s}" \
  '{
    pane_id:         $pane,
    session_id:      $sid,
    cwd:             $cwd,
    transcript_path: $transcript,
    last_event:      $event,
    message:         $message,
    last_event_s:    $now
  }' >"${status_file}.tmp.$$" \
  && mv "${status_file}.tmp.$$" "${status_file}"
