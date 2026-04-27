#!/usr/bin/env bash
#
# tmux-status resolver: iterates all per-pane state files written by
# the tmux-status hook, computes a live status per pane, groups panes
# by window, and sets @claude_status on each window to a pre-rendered
# string of one colored dot per active claude pane (adjacent, no
# spaces between). Windows that no longer have any claude pane have
# @claude_status cleared.
#
# Called periodically from tmux's status-left via #() so state is
# always fresh — no stale background/working dots when background
# tasks finish, compact ends, or the model hangs.
#
# Signals combined per pane:
#   * last hook event + timestamp           (state file)
#   * transcript JSONL mtime                (heartbeat)
#   * CPU% of the claude process            (thinking vs working)
#   * background bash / subagent presence
#   * last JSONL entry for interrupt marker (routes interrupt back to
#                                            idle instead of error)

set -o errexit
set -o nounset
set -o pipefail

# tmux's #() subshell has a minimal PATH — on macOS `flock` lives in
# homebrew's util-linux and isn't reachable by default. Without it,
# our task-lock checks turn into silent false positives (every lock
# reads as "held" → background detected for every claude). Prepend
# likely locations so `flock` resolves everywhere.
PATH="/opt/homebrew/opt/util-linux/bin:/opt/homebrew/bin:/usr/local/opt/util-linux/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
export PATH

readonly STATUS_DIR="/tmp/kvaps-tmux-status.$(id -u)"
[[ -d "${STATUS_DIR}" ]] || exit 0

# Mutex: only one resolver run at a time. If tmux's probe fires again
# while we're still working, skip — the next tick will pick it up.
# Without this, concurrent runs race on @claude_status and can leave
# stale values (e.g. blue when a previous run detected a transient
# bg child).
readonly LOCK_FILE="${STATUS_DIR}/.resolver.lock"
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  exit 0
fi

readonly FRESH_HEARTBEAT_S=10    # heartbeat within this -> working
readonly STALE_HEARTBEAT_S=300   # heartbeat older than this -> stuck (5 min)

readonly PREV_ACTIVE_FILE="${STATUS_DIR}/.prev-active-windows"

now_s="$(date +%s)"

pane_exists() {
  tmux display-message -p -t "$1" '#{pane_id}' >/dev/null 2>&1
}

window_of_pane() {
  tmux display-message -p -t "$1" '#{window_id}' 2>/dev/null || true
}

find_claude_pid() {
  local sid="$1" f pid
  [[ -z "${sid}" ]] && return
  for f in "${HOME}"/.claude/sessions/*.json; do
    [[ -f "${f}" ]] || continue
    if [[ "$(jq -r '.sessionId // empty' "${f}" 2>/dev/null)" == "${sid}" ]]; then
      pid="$(jq -r '.pid // empty' "${f}" 2>/dev/null)"
      if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
        printf '%s' "${pid}"
      fi
      return
    fi
  done
}

cpu_pct_int() {
  local pid="$1" raw
  [[ -z "${pid}" ]] && { printf '0'; return; }
  raw="$(ps -p "${pid}" -o %cpu= 2>/dev/null | tr -d ' ' || true)"
  [[ -z "${raw}" ]] && { printf '0'; return; }
  printf '%s' "${raw%.*}"
}

# macOS BSD ps prints etime as [[DD-]HH:]MM:SS. Convert to seconds.
etime_to_s() {
  local raw="$1"
  awk -v e="${raw}" 'BEGIN {
    n = split(e, p, /[-:]/)
    mults[1] = 1; mults[2] = 60; mults[3] = 3600; mults[4] = 86400
    total = 0
    for (i = 0; i < n; i++) total += p[n-i] * mults[i+1]
    print total
  }'
}

has_background() {
  local claude_pid="$1"
  [[ -z "${claude_pid}" ]] && return 1
  local cpid cmd etime age exe_base
  while read -r cpid; do
    [[ -z "${cpid}" ]] && continue
    cmd="$(ps -p "${cpid}" -o command= 2>/dev/null)"

    # The user's mental model of "background" is a user-initiated
    # task running in the shell: Bash tool with run_in_background=true
    # ends up as /bin/bash -c "<cmd>" (or similar) under claude.
    # Internal helpers claude spawns for its own workflow (LSPs like
    # gopls, language servers, hook runners, caffeinate, etc.) don't
    # belong here — the user doesn't see them "running". Only count
    # direct shell children.
    exe_base="$(printf '%s\n' "${cmd}" | awk '{print $1}')"
    exe_base="${exe_base##*/}"
    case "${exe_base}" in
      bash|sh|zsh|dash|fish|ksh) : ;;
      *) continue ;;
    esac

    # Skip our own hook wrappers and other plugins' hooks explicitly.
    case "${cmd}" in
      *.claude/hooks/*) continue ;;
      *.claude/local-plugins/*) continue ;;
      *.claude/plugins/marketplaces/*) continue ;;
    esac

    # Short-lived shells are still likely a synchronous Bash tool call
    # finishing, or a concurrent hook's bash wrapper. Real user bg
    # services (`npm run dev &`, servers, etc.) live much longer.
    etime="$(ps -p "${cpid}" -o etime= 2>/dev/null | tr -d ' ')"
    age="$(etime_to_s "${etime}")"
    if [[ -n "${age}" ]] && [[ "${age}" -lt 3 ]]; then
      continue
    fi
    return 0
  done < <(pgrep -P "${claude_pid}" 2>/dev/null)

  # Task dirs accumulate historically (user's system has 39+); most are
  # long-dead. Only probe ones whose .highwatermark has been touched
  # within the last hour — an active agent writes to it continuously,
  # dormant ones won't.
  local lockdir lockfile hwfile hw_age
  local now_s
  now_s="$(date +%s)"
  for lockdir in "${HOME}"/.claude/tasks/*/; do
    lockfile="${lockdir}.lock"
    hwfile="${lockdir}.highwatermark"
    [[ -f "${lockfile}" ]] || continue
    if [[ -f "${hwfile}" ]]; then
      hw_age=$(( now_s - $(mtime_of "${hwfile}") ))
      [[ "${hw_age}" -gt 3600 ]] && continue
    fi
    if ! flock -n -s "${lockfile}" -c true 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# Scan the last few JSONL entries for a user-interrupt marker. Claude
# Code emits variations — "[Request interrupted by user]",
# "[Request interrupted by user for tool use]" — so match the prefix
# without the closing bracket. The flag clears naturally once claude
# writes a user-prompt or tool-result entry without the marker past
# the scan window.
has_recent_interrupt_marker() {
  local transcript="$1"
  [[ -f "${transcript}" ]] || return 1
  tail -n 5 "${transcript}" 2>/dev/null | grep -q '\[Request interrupted by user'
}

mtime_of() {
  stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null || echo 0
}

resolve_status() {
  local event="$1" event_s="$2" transcript="$3" message="$4"
  local claude_pid="$5" bg_flag="$6" interrupted="$7"

  # Interrupt = user took control back = treat like Stop. Check this
  # BEFORE the StopFailure short-circuit below, because cancelling a
  # tool can also fire StopFailure and we don't want that to latch
  # the dot to red (error) when the user just hit escape.
  if [[ "${interrupted}" -eq 1 ]]; then
    event="Stop"
  fi

  if [[ "${event}" == "StopFailure" ]]; then
    printf 'error'; return
  fi
  if [[ "${event}" == "SessionStart" ]]; then
    printf 'starting'; return
  fi
  if [[ "${event}" == "PreCompact" ]]; then
    printf 'background'; return
  fi

  if [[ "${event}" == "Notification" ]]; then
    local msg_lc
    msg_lc="$(printf '%s' "${message}" | tr '[:upper:]' '[:lower:]')"
    case "${msg_lc}" in
      *"waiting for your input"*) event="Stop" ;;
      *) printf 'waiting'; return ;;
    esac
  fi

  if [[ "${event}" == "Stop" ]]; then
    if [[ "${bg_flag}" -eq 1 ]]; then
      printf 'background'
    else
      printf 'idle'
    fi
    return
  fi

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
    elif [[ "${bg_flag}" -eq 1 ]]; then
      # Not streaming, but a user-initiated bg shell task is alive.
      printf 'background'
    elif [[ "${heartbeat_age}" -gt "${STALE_HEARTBEAT_S}" ]]; then
      # Pure time-based stuck: nothing from claude for 5+ minutes.
      # CPU% used to be part of this check but %cpu from ps oscillates
      # near 1% and caused the dot to flicker between red/yellow —
      # drop that signal entirely, time is the more reliable one.
      printf 'stuck'
    else
      # Middle band (FRESH..STALE) = still thinking.
      printf 'thinking'
    fi
    return
  fi

  printf 'idle'
}

color_for_status() {
  case "$1" in
    starting|idle)     printf '#00ff00' ;;
    working|thinking)  printf 'yellow' ;;
    background)        printf 'blue' ;;
    waiting)           printf 'magenta' ;;
    stuck|error)       printf 'red' ;;
    *)                 printf 'white' ;;
  esac
}

# Staging area: per-window dot string accumulator. Use files named
# after window_id so we don't need associative arrays.
stage_dir="$(mktemp -d "${STATUS_DIR}/.stage.XXXXXX")"
trap 'rm -rf "${stage_dir}"' EXIT

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

  # If claude died, drop the state file and skip.
  if [[ -z "${claude_pid}" ]] && [[ -n "${session_id}" ]]; then
    rm -f -- "${status_file}"
    continue
  fi

  interrupted=0
  has_recent_interrupt_marker "${transcript}" && interrupted=1

  bg_flag=0
  has_background "${claude_pid}" && bg_flag=1

  status="$(resolve_status \
    "${event}" "${event_s}" "${transcript}" "${message}" \
    "${claude_pid}" "${bg_flag}" "${interrupted}")"
  color="$(color_for_status "${status}")"

  window_id="$(window_of_pane "${pane_id}")"
  [[ -z "${window_id}" ]] && continue

  # Strip leading @ from window_id so the filename isn't awkward.
  safe_wid="${window_id//@/w}"
  printf '#[fg=%s]●' "${color}" >> "${stage_dir}/${safe_wid}"
done

# Apply per-window renders and record active windows for this pass.
# Only call set-window-option when the value actually changed —
# every set forces tmux to mark the window dirty and redraw the
# status bar, which can disturb terminal-level mouse selection.
active_windows=""
for stage_file in "${stage_dir}"/*; do
  [[ -f "${stage_file}" ]] || continue
  safe_wid="$(basename -- "${stage_file}")"
  window_id="${safe_wid//w/@}"
  render="$(cat -- "${stage_file}")"
  cur="$(tmux show-window-options -t "${window_id}" -v @claude_status 2>/dev/null || true)"
  if [[ "${cur}" != "${render}" ]]; then
    tmux set-window-option -t "${window_id}" @claude_status "${render}" >/dev/null 2>&1 || true
  fi
  active_windows="${active_windows}${window_id} "
done

# Clear @claude_status on windows that had a render last pass but
# have no active claude panes now.
prev_active=""
[[ -f "${PREV_ACTIVE_FILE}" ]] && prev_active="$(cat -- "${PREV_ACTIVE_FILE}")"
for w in ${prev_active}; do
  case " ${active_windows} " in
    *" ${w} "*) : ;;
    *)
      cur="$(tmux show-window-options -t "${w}" -v @claude_status 2>/dev/null || true)"
      if [[ -n "${cur}" ]]; then
        tmux set-window-option -t "${w}" -u @claude_status >/dev/null 2>&1 || true
      fi
      ;;
  esac
done

printf '%s' "${active_windows}" > "${PREV_ACTIVE_FILE}"
