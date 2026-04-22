#!/usr/bin/env bash
#
# tmux-status resolver: iterates all per-pane state files written by
# the tmux-status hook and computes the live @claude_status value for
# each pane, combining:
#
#   * last hook event + timestamp           (from the state file)
#   * transcript JSONL mtime                (heartbeat signal — proves
#                                            the model is streaming
#                                            output even when no hook
#                                            has fired for a while)
#   * CPU% of the claude process            (catches "thinking" —
#                                            internal reasoning with
#                                            no streamed output)
#   * background bash / subagent presence   (Bash run_in_background,
#                                            ~/.claude/tasks lock)
#   * transcript tail for an interrupt      ([Request interrupted by
#                                            user] marker → error)
#
# Called periodically from tmux's status-left/status-right (every
# status-interval seconds) so state is always fresh — no stale
# background/working dots left over after a hook fails to fire.
# Outputs nothing; the side effect is `tmux set-window-option
# @claude_status` on each tracked pane.
#
# Stale panes (file exists but the pane was closed) are cleaned up.

set -o errexit
set -o nounset
set -o pipefail

readonly STATUS_DIR="/tmp/kvaps-tmux-status.$(id -u)"
[[ -d "${STATUS_DIR}" ]] || exit 0

readonly FRESH_HEARTBEAT_S=3      # heartbeat within this -> "working"
readonly STALE_HEARTBEAT_S=30     # heartbeat older AND low cpu -> "stuck"
readonly CPU_ACTIVE_THRESHOLD=1   # cpu% above -> "thinking"
readonly CPU_IDLE_THRESHOLD=1     # cpu% below -> consider idle/stuck

now_s="$(date +%s)"

pane_exists() {
  tmux display-message -p -t "$1" '#{pane_id}' >/dev/null 2>&1
}

# Resolve the claude process PID from ~/.claude/sessions/*.json whose
# sessionId matches. Prints nothing if not found.
find_claude_pid() {
  local sid="$1" f pid
  [[ -z "${sid}" ]] && return
  for f in "${HOME}"/.claude/sessions/*.json; do
    [[ -f "${f}" ]] || continue
    if [[ "$(jq -r '.sessionId // empty' "${f}" 2>/dev/null)" == "${sid}" ]]; then
      pid="$(jq -r '.pid // empty' "${f}" 2>/dev/null)"
      # Verify process is still alive.
      if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
        printf '%s' "${pid}"
      fi
      return
    fi
  done
}

# Integer CPU% of pid (BSD ps returns float like " 12.3"; strip decimal
# and whitespace, default to 0).
cpu_pct_int() {
  local pid="$1" raw
  [[ -z "${pid}" ]] && { printf '0'; return; }
  raw="$(ps -p "${pid}" -o %cpu= 2>/dev/null | tr -d ' ' || true)"
  [[ -z "${raw}" ]] && { printf '0'; return; }
  printf '%s' "${raw%.*}"
}

has_background() {
  local claude_pid="$1"
  [[ -z "${claude_pid}" ]] && return 1

  local cpid cmd
  while read -r cpid; do
    [[ -z "${cpid}" ]] && continue
    cmd="$(ps -p "${cpid}" -o command= 2>/dev/null)"
    case "${cmd}" in
      *caffeinate*) continue ;;
      *.claude/hooks/*) continue ;;
      *.claude/local-plugins/*) continue ;;
      *.claude/plugins/marketplaces/*) continue ;;
      *) return 0 ;;
    esac
  done < <(pgrep -P "${claude_pid}" 2>/dev/null)

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

# Checks ONLY the last JSONL entry — once the user sends another
# message, the marker line is no longer the tail, so the flag clears
# naturally. Avoids getting stuck at error because some earlier turn
# was interrupted hours ago.
has_recent_interrupt_marker() {
  local transcript="$1"
  [[ -f "${transcript}" ]] || return 1
  tail -n 1 "${transcript}" 2>/dev/null | grep -q '\[Request interrupted by user\]'
}

mtime_of() {
  stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null || echo 0
}

# Resolution table — priority order:
#
#   error     StopFailure OR interrupted marker in transcript
#   starting  SessionStart
#   background  PreCompact  (compaction in progress)
#   waiting   Notification that's NOT "waiting for your input"
#   (turn-end branch: Stop or Notification "waiting for your input")
#     background  when a bg bash task / subagent is still running
#     idle        otherwise
#   (work branch: UserPromptSubmit / PreToolUse / PostToolUse)
#     working     heartbeat_age < 3s  (model is streaming output)
#     stuck       heartbeat_age > 30s AND cpu < 1%
#     thinking    cpu > 1%  (model processing, not streaming)
#     stuck       ambiguous middle band -> flag for attention
#   idle      unknown event
resolve_status() {
  local event="$1"
  local event_s="$2"
  local transcript="$3"
  local message="$4"
  local claude_pid="$5"
  local bg_flag="$6"
  local interrupted="$7"

  # Fast-path for clearly-terminal events.
  if [[ "${event}" == "StopFailure" ]]; then
    printf 'error'; return
  fi
  if [[ "${event}" == "SessionStart" ]]; then
    printf 'starting'; return
  fi
  if [[ "${event}" == "PreCompact" ]]; then
    printf 'background'; return
  fi

  # A fresh user-interrupt at the tail of the transcript means the turn
  # just ended from a user action — semantically the same as Stop.
  # Route through the turn-end branch below so it becomes idle/background
  # instead of a red "error".
  if [[ "${interrupted}" -eq 1 ]]; then
    event="Stop"
  fi

  if [[ "${event}" == "Notification" ]]; then
    local msg_lc
    msg_lc="$(printf '%s' "${message}" | tr '[:upper:]' '[:lower:]')"
    case "${msg_lc}" in
      *"waiting for your input"*) : ;;  # fall through to turn-end logic
      *) printf 'waiting'; return ;;
    esac
    # Treat "waiting for your input" as a turn end.
    event="Stop"
  fi

  if [[ "${event}" == "Stop" ]]; then
    if [[ "${bg_flag}" -eq 1 ]]; then
      printf 'background'
    else
      printf 'idle'
    fi
    return
  fi

  # Work branch.
  if [[ "${event}" == "UserPromptSubmit" || "${event}" == "PreToolUse" || "${event}" == "PostToolUse" ]]; then
    local heartbeat_s="${event_s}"
    if [[ -n "${transcript}" ]] && [[ -f "${transcript}" ]]; then
      local t_mtime
      t_mtime="$(mtime_of "${transcript}")"
      [[ "${t_mtime}" -gt "${heartbeat_s}" ]] && heartbeat_s="${t_mtime}"
    fi
    local heartbeat_age=$(( now_s - heartbeat_s ))

    local cpu
    cpu="$(cpu_pct_int "${claude_pid}")"

    if [[ "${heartbeat_age}" -lt "${FRESH_HEARTBEAT_S}" ]]; then
      printf 'working'
    elif [[ "${heartbeat_age}" -gt "${STALE_HEARTBEAT_S}" ]] && [[ "${cpu}" -lt "${CPU_IDLE_THRESHOLD}" ]]; then
      printf 'stuck'
    elif [[ "${cpu}" -ge "${CPU_ACTIVE_THRESHOLD}" ]]; then
      printf 'thinking'
    else
      # Middle band, ambiguous.
      printf 'stuck'
    fi
    return
  fi

  # Unknown event.
  printf 'idle'
}

for status_file in "${STATUS_DIR}"/*.json; do
  [[ -f "${status_file}" ]] || continue

  pane_id="$(jq -r '.pane_id // empty' "${status_file}" 2>/dev/null)"
  if [[ -z "${pane_id}" ]]; then
    rm -f -- "${status_file}"
    continue
  fi

  if ! pane_exists "${pane_id}"; then
    rm -f -- "${status_file}"
    continue
  fi

  event="$(jq -r '.last_event // empty' "${status_file}")"
  event_s="$(jq -r '.last_event_s // 0' "${status_file}")"
  session_id="$(jq -r '.session_id // empty' "${status_file}")"
  transcript="$(jq -r '.transcript_path // empty' "${status_file}")"
  message="$(jq -r '.message // empty' "${status_file}")"

  claude_pid="$(find_claude_pid "${session_id}")"

  # If the claude process is gone (abrupt quit, no SessionEnd hook),
  # drop the state file and clear the dot instead of showing stale
  # "stuck".
  if [[ -z "${claude_pid}" ]] && [[ -n "${session_id}" ]]; then
    rm -f -- "${status_file}"
    tmux set-window-option -t "${pane_id}" -u @claude_status >/dev/null 2>&1 || true
    continue
  fi

  interrupted=0
  has_recent_interrupt_marker "${transcript}" && interrupted=1

  bg_flag=0
  has_background "${claude_pid}" && bg_flag=1

  status="$(resolve_status \
    "${event}" "${event_s}" "${transcript}" "${message}" \
    "${claude_pid}" "${bg_flag}" "${interrupted}")"

  tmux set-window-option -t "${pane_id}" @claude_status "${status}" >/dev/null 2>&1 || true
done
