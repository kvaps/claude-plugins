# tmux-status

Reflect live Claude Code session state as a small colored dot in the tmux
window status line. Works per-window, targets the pane where claude is
actually running (not the focused one), and cleans up on session end.

## States

| Color | Status | Triggered by |
| --- | --- | --- |
| 🟢 green | `starting` | `SessionStart` |
| 🟡 yellow | `working` | `UserPromptSubmit` / `PreToolUse` / `PostToolUse` |
| 🔵 blue | `background` | `Stop` / `Notification` "waiting for your input" when a background bash task or subagent is still running; also during `PreCompact` |
| 🟢 green | `idle` | `Stop` / `Notification` "waiting for your input" when nothing is running |
| 🟣 magenta | `waiting` | `Notification` that needs the user's active attention (permission prompt, plan approval, elicitation) |
| 🔴 red | `error` | `StopFailure` |

The dot disappears on `SessionEnd`.

## Installation

```text
/plugin marketplace add kvaps/claude-plugins
/plugin install tmux-status@kvaps-claude-plugins
```

### tmux.conf setup (one-time)

The plugin writes a per-window user option `@claude_status`. To render it
as a colored dot inside the theme's active-tab decoration, add to
`~/.tmux.conf` **after** your theme plugin (e.g. after the
`run '~/.tmux/plugins/tpm/tpm'` line):

```tmux
# Claude Code session status indicator
set -g @claude_status_fmt "#{?@claude_status, #[fg=#{?#{==:#{E:@claude_status},error},red,#{?#{==:#{E:@claude_status},waiting},magenta,#{?#{==:#{E:@claude_status},working},yellow,#{?#{==:#{E:@claude_status},background},blue,#00ff00}}}}]● #[default],}"
run-shell "$HOME/.claude/plugins/marketplaces/kvaps-claude-plugins/hooks/tmux-status/scripts/tmux-install-status-fmt.sh"
```

Then reload: `tmux source-file ~/.tmux.conf`.

The installer script splits `window-status-format` and
`window-status-current-format` at `#I:`, injects `#{E:@claude_status_fmt}`
at that point, and appends a duplicate of every `#[...]` style directive
that appeared in the theme's prefix — so the theme's fg/bg/attrs are
re-applied immediately after the dot's `#[default]` reset. Decorative
non-style characters (e.g. powerline arrows) are left in place and never
duplicated. Safe to re-run on every tmux config reload.

### Color customization

Colors live in the `@claude_status_fmt` value. Swap any of
`red` / `magenta` / `yellow` / `blue` / `#00ff00` for your preferred
named tmux colors or hex values. `#00ff00` is used instead of named
`green` because some terminals override the named color to a dimmer
shade.

## How it works

Hooks `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
`Notification`, `Stop`, `StopFailure`, `PreCompact`, and `SessionEnd`
invoke `scripts/tmux-status.sh`. The script reads the hook payload from
stdin, maps the event to a status value, and writes `@claude_status` on
the window that contains `$TMUX_PANE` (inherited from the shell claude
was launched in — so it targets claude's window even if the user is
focused somewhere else).

### Background detection

On `Stop` and on `Notification` "waiting for your input", the script
checks two signals to decide between `idle` and `background`:

1. **Claude's child processes** — resolves claude's PID via
   `~/.claude/sessions/<pid>.json` (matching the hook's `session_id`),
   then lists direct children. Known system children (`caffeinate`,
   `~/.claude/hooks/*`, the hook's own zsh wrapper) are filtered out;
   anything else left is a live background task (e.g. `Bash` with
   `run_in_background: true`).
2. **Task locks** — each active subagent holds an exclusive flock on
   `~/.claude/tasks/<uuid>/.lock`. A failed `flock -n -s` means the
   task is running.

If either signal fires → `background`; otherwise → `idle`.

### SessionEnd cleanup

`SessionEnd` unsets `@claude_status`, which makes the conditional
format expand to empty again.

## Non-tmux environments

`scripts/tmux-status.sh` exits silently when `$TMUX` is not set, so the
plugin is safe to keep enabled when claude runs outside tmux.
