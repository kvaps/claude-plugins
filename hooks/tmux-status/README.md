# tmux-status

Reflect live Claude Code session state as a small colored dot in the tmux
window status line. Works per-window, targets the pane where claude is
actually running (not the focused one), and cleans up on session end.

## States

| Color | Status | Triggered by |
| --- | --- | --- |
| 🟢 green | `starting` | `SessionStart` |
| 🟡 yellow | `working` | `UserPromptSubmit` / `PreToolUse` / `PostToolUse` |
| 🔵 blue | `waiting` | `Notification` (permission prompt, plan approval) |
| 🟢 green | `idle` | `Stop`, or `Notification` with "waiting for your input" |
| 🔴 red | `error` | `StopFailure` |

The dot disappears on `SessionEnd`.

## Installation

```text
/plugin marketplace add kvaps/claude-plugins
/plugin install tmux-status@kvaps-claude-plugins
```

### tmux.conf setup (one-time)

The plugin writes a per-window user option `@claude_status`. To render it
as a colored dot, add to your `~/.tmux.conf` **after** your theme plugin
(e.g. after the `run '~/.tmux/plugins/tpm/tpm'` line):

```tmux
# Claude Code session status indicator
set -g @claude_status_fmt "#{?@claude_status, #[fg=#{?#{==:#{E:@claude_status},error},red,#{?#{==:#{E:@claude_status},waiting},blue,#{?#{==:#{E:@claude_status},working},yellow,#00ff00}}}]●#[default] ,}"
run-shell "$HOME/.claude/plugins/marketplaces/kvaps-claude-plugins/hooks/tmux-status/scripts/tmux-install-status-fmt.sh"
```

Then reload: `tmux source-file ~/.tmux.conf`.

The second line prepends `#{E:@claude_status_fmt}` to
`window-status-format` and `window-status-current-format` idempotently, so
it plays nicely alongside themes like `tmux-power`.

### Color customization

- Replace `#00ff00` if your terminal overrides the named `green`
- Swap any of `red` / `blue` / `yellow` / `#00ff00` for your preferred hex values

## How it works

Hooks `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
`Notification`, `Stop`, `StopFailure`, and `SessionEnd` invoke
`scripts/tmux-status.sh`. The script reads the hook payload from stdin,
maps the event to one of five statuses, and writes `@claude_status` on
the window that contains `$TMUX_PANE` (inherited from the shell claude
was launched in — so it targets claude's window even if you are focused
somewhere else).

`SessionEnd` unsets `@claude_status`, which makes the conditional format
expand to empty again.

## Non-tmux environments

`scripts/tmux-status.sh` exits silently when `$TMUX` is not set, so the
plugin is safe to keep enabled when claude runs outside tmux.
