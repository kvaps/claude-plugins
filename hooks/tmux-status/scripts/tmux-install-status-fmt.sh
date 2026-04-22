#!/usr/bin/env bash
#
# Install tmux-status' glue into the current tmux server config:
#
#   1. Inject #{E:@claude_status_fmt} into window-status-format and
#      window-status-current-format right before "#I:", duplicating any
#      #[...] style directives from the theme's prefix so the dot's
#      #[default] reset doesn't bleed the theme's fg/bg onto the
#      window name. Non-style chars (powerline arrows, etc.) are left
#      in place, not duplicated.
#
#   2. Install tmux-status-resolve.sh as a "#(...)" probe in
#      status-left. The probe is invisible but runs every
#      status-interval seconds (side effect only: updates
#      @claude_status on every claude-tracked pane). This makes the
#      dot auto-correct when background tasks complete, when the
#      model gets stuck, etc. — without needing a new hook event.
#
#   3. Lower status-interval to 2s if it's higher, so the probe
#      actually runs at a useful cadence.
#
# Idempotent — safe to re-run on every tmux config reload. Must run
# AFTER the user's theme plugin so it extends the theme's format
# instead of being overwritten by it.

set -o errexit
set -o nounset
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly RESOLVER="${SCRIPT_DIR}/tmux-status-resolve.sh"

marker='#{E:@claude_status_fmt}'
probe_marker='#{E:@claude_status_probe}'

#
# 1. Inject into window-status-format / window-status-current-format.
#
for opt in window-status-format window-status-current-format; do
  cur="$(tmux show-option -gv "${opt}")"
  case "${cur}" in
    *'@claude_status_fmt'*) continue ;;
  esac

  case "${cur}" in
    *'#I:'*)
      prefix="${cur%%#I:*}"
      suffix="#I:${cur#*#I:}"
      restore="$(printf '%s' "${prefix}" | grep -Eo '#\[[^]]*\]' | tr -d '\n' || true)"
      new="${prefix}${marker}${restore}${suffix}"
      ;;
    *)
      new="${marker}${cur}"
      ;;
  esac

  tmux set-option -g "${opt}" "${new}"
done

#
# 2. Install the resolver probe on status-left.
#
tmux set-option -g @claude_status_probe "#(${RESOLVER})"

cur_status_left="$(tmux show-option -gv status-left 2>/dev/null || true)"
case "${cur_status_left}" in
  *'@claude_status_probe'*) ;;  # already present
  *)
    tmux set-option -g status-left "${probe_marker}${cur_status_left}"
    ;;
esac

#
# 3. Ensure status-interval is fast enough for the probe to feel live.
#
cur_interval="$(tmux show-option -gv status-interval 2>/dev/null || echo 15)"
if [[ "${cur_interval}" -gt 2 ]] || [[ "${cur_interval}" -lt 1 ]]; then
  tmux set-option -g status-interval 2
fi
