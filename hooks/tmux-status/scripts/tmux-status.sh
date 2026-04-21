#!/usr/bin/env bash
#
# tmux-status: reflect Claude Code session state in the current tmux window.
#
# Writes a per-window user option @claude_status that tmux.conf formats
# into a small colored dot in window-status-format. On SessionEnd it
# clears the option so the dot disappears.
#
# Status values: starting | working | waiting | background | idle | error

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
target=()
if [[ -n "${TMUX_PANE:-}" ]]; then
  target=(-t "${TMUX_PANE}")
fi

input="$(cat)"

event="$(jq --raw-output '.hook_event_name // empty' <<<"${input}")"
session_id="$(jq --raw-output '.session_id // empty' <<<"${input}")"
message="$(jq --raw-output '.message // empty' <<<"${input}")"

if [[ -z "${event}" ]]; then
  exit 0
fi

# SessionEnd: clear status option so the dot disappears.
if [[ "${event}" == "SessionEnd" ]]; then
  tmux set-window-option "${target[@]}" -u @claude_status >/dev/null 2>&1 || true
  exit 0
fi

# Detect whether claude currently has any background activity:
#   1. Non-system child processes of the claude PID (catches Bash run_in_background)
#   2. Any ~/.claude/tasks/<uuid>/.lock held exclusively (catches background agent tasks)
# Returns 0 (true) if anything is found, 1 otherwise.
has_background() {
  local sid="${1:-}"
  [[ -z "${sid}" ]] && return 1

  # Resolve claude PID via the session state file whose sessionId matches.
  local claude_pid="" f
  for f in "${HOME}"/.claude/sessions/*.json; do
    [[ -f "${f}" ]] || continue
    if [[ "$(jq -r '.sessionId // empty' "${f}" 2>/dev/null)" == "${sid}" ]]; then
      claude_pid="$(jq -r '.pid // empty' "${f}" 2>/dev/null)"
      break
    fi
  done

  if [[ -n "${claude_pid}" ]]; then
    # Exclude the zsh wrapper that spawned this hook script — it's a
    # transient child of claude, not a background task.
    local my_wrapper_pid
    my_wrapper_pid="$(ps -p $$ -o ppid= 2>/dev/null | tr -d ' ')"

    local cpid cmd
    while read -r cpid; do
      [[ -z "${cpid}" ]] && continue
      [[ "${cpid}" == "${my_wrapper_pid}" ]] && continue
      cmd="$(ps -p "${cpid}" -o command= 2>/dev/null)"
      case "${cmd}" in
        *caffeinate*) continue ;;
        *.claude/hooks/*) continue ;;
        *) return 0 ;;
      esac
    done < <(pgrep -P "${claude_pid}" 2>/dev/null)
  fi

  # Background agent tasks hold an exclusive flock on their .lock file
  # while active. If we can grab a shared lock non-blockingly, nothing
  # holds it (task idle).
  local lockdir lockfile
  for lockdir in "${HOME}"/.claude/tasks/*/; do
    lockfile="${lockdir}.lock"
    [[ -f "${lockfile}" ]] || continue
    if ! flock -n -s "${lockfile}" -c true 2>/dev/null; then
      return 0
    fi
  done

  return 1
}

turn_end_status() {
  if has_background "${session_id}"; then
    printf 'background'
  else
    printf 'idle'
  fi
}

status=""
case "${event}" in
  SessionStart)
    status="starting"
    ;;
  UserPromptSubmit | PreToolUse | PostToolUse)
    status="working"
    ;;
  PreCompact)
    # Compaction is a long-running background operation blocking the
    # model. Flag it as "background" (blue) so the user sees a distinct
    # state from plain working yellow. The next hook event (PreToolUse /
    # Stop / Notification) naturally overwrites when compaction is done.
    status="background"
    ;;
  Stop)
    status="$(turn_end_status)"
    ;;
  Notification)
    # Claude Code fires Notification both for "waiting for your input"
    # after a plain turn (semantically a turn end) and for real blocking
    # gates (permission prompt, plan approval, elicitation). Only the
    # latter need the user's active attention — those get "waiting".
    # Lowercase via tr: ${var,,} is Bash 4+, macOS ships 3.2.
    message_lc="$(printf '%s' "${message}" | tr '[:upper:]' '[:lower:]')"
    case "${message_lc}" in
      *"waiting for your input"*)
        status="$(turn_end_status)"
        ;;
      *)
        status="waiting"
        ;;
    esac
    ;;
  StopFailure)
    status="error"
    ;;
  *)
    exit 0
    ;;
esac

tmux set-window-option "${target[@]}" @claude_status "${status}" >/dev/null 2>&1 || true
