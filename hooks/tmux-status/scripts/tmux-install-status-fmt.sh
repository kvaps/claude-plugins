#!/usr/bin/env bash
#
# Inject #{E:@claude_status_fmt} into window-status-format and
# window-status-current-format so a colored dot appears INSIDE the
# active-tab decoration (between the theme's opening style and the
# window name).
#
# Strategy: split the format at the first "#I:" and inject
#
#   <original-prefix> MARKER <extracted-styles> <rest>
#
# where MARKER = #{E:@claude_status_fmt} and <extracted-styles> is the
# concatenation of all #[...] blocks found in the prefix. The dot uses
# #[default] to reset, and the extracted styles re-apply the theme's
# fg/bg/attrs immediately after — without re-drawing any non-style
# characters (like powerline arrows) that sat between the blocks.
#
# Idempotent — if the marker is already in the format, skip.

set -o errexit
set -o nounset
set -o pipefail

marker='#{E:@claude_status_fmt}'

for opt in window-status-format window-status-current-format; do
  cur="$(tmux show-option -gv "${opt}")"
  case "${cur}" in
    *'@claude_status_fmt'*) continue ;;
  esac

  case "${cur}" in
    *'#I:'*)
      prefix="${cur%%#I:*}"
      suffix="#I:${cur#*#I:}"
      # Extract all #[...] blocks from the prefix, joined, with no
      # other chars (so arrows/spaces/etc. aren't duplicated).
      restore="$(printf '%s' "${prefix}" | grep -Eo '#\[[^]]*\]' | tr -d '\n' || true)"
      new="${prefix}${marker}${restore}${suffix}"
      ;;
    *)
      new="${marker}${cur}"
      ;;
  esac

  tmux set-option -g "${opt}" "${new}"
done
