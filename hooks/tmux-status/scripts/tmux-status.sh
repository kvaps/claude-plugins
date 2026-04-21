#!/usr/bin/env bash
#
# tmux-status: reflect Claude Code session state in the current tmux window.
#
# Writes a per-window user option @claude_status that tmux.conf formats
# into a small colored dot in window-status-format. On SessionEnd it
# clears the option so the dot disappears.
#
# Status values: starting | working | waiting | idle | error

set -o errexit
set -o nounset
set -o pipefail

# Nothing to do outside a tmux session.
if [[ -z "${TMUX:-}" ]]; then
  exit 0
fi

# Target the pane claude is running in, not the currently-focused window.
# TMUX_PANE is exported by tmux into every pane's shell and inherited by
# child processes — so the hook, spawned by claude, sees claude's pane.
# Passing -t scopes the window option to the right window when the user
# is focused elsewhere.
target=()
if [[ -n "${TMUX_PANE:-}" ]]; then
  target=(-t "${TMUX_PANE}")
fi

input="$(cat)"

event="$(jq --raw-output '.hook_event_name // empty' <<<"${input}")"
message="$(jq --raw-output '.message // empty' <<<"${input}")"

if [[ -z "${event}" ]]; then
  exit 0
fi

# SessionEnd: clear status option so the dot disappears.
if [[ "${event}" == "SessionEnd" ]]; then
  tmux set-window-option "${target[@]}" -u @claude_status >/dev/null 2>&1 || true
  exit 0
fi

status=""
case "${event}" in
  SessionStart)
    status="starting"
    ;;
  UserPromptSubmit | PreToolUse | PostToolUse)
    status="working"
    ;;
  Notification)
    # Claude Code fires Notification for both "need your input after a
    # finished turn" (semantically idle) and real blocking gates like
    # permission prompts (semantically waiting). Distinguish by message.
    # Lowercase via tr because ${var,,} needs Bash 4+ and macOS ships 3.2.
    message_lc="$(printf '%s' "${message}" | tr '[:upper:]' '[:lower:]')"
    case "${message_lc}" in
      *"waiting for your input"*)
        status="idle"
        ;;
      *)
        status="waiting"
        ;;
    esac
    ;;
  Stop)
    status="idle"
    ;;
  StopFailure)
    status="error"
    ;;
  *)
    exit 0
    ;;
esac

tmux set-window-option "${target[@]}" @claude_status "${status}" >/dev/null 2>&1 || true
