#!/usr/bin/env bash
#
# Prepend #{E:@claude_status_fmt} to window-status-format and
# window-status-current-format so a colored dot appears before the
# window name for claude sessions. Idempotent — safe to re-run on
# every tmux config reload. Must run AFTER the user's theme plugin
# (e.g. tmux-power) so it extends the theme's format instead of
# being overwritten by it.

set -o errexit
set -o nounset
set -o pipefail

marker='@claude_status_fmt'
prefix='#{E:@claude_status_fmt}'

for opt in window-status-format window-status-current-format; do
  cur="$(tmux show-option -gv "${opt}")"
  case "${cur}" in
    *"${marker}"*) continue ;;
  esac
  tmux set-option -g "${opt}" "${prefix}${cur}"
done
