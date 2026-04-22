# tmux-status

Reflect live Claude Code session state as a small colored dot in the tmux
window status line. Works per-window, targets the pane where claude is
actually running (not the focused one), and stays fresh via tmux's
`status-interval` — so the dot auto-corrects when background tasks
finish, when the model gets stuck, etc., without depending on new hook
events firing.

## States

| Color | Status | Meaning |
| --- | --- | --- |
| 🟢 green | `starting` | `SessionStart` |
| 🟡 yellow | `working` | Model actively streaming output (transcript mtime fresh, < 3s since last event/write) |
| 🟠 goldenrod `#b8860b` | `thinking` | Model processing internally, not streaming (CPU > 1%, transcript quiet) |
| 🔵 blue | `background` | Turn done and a bash `run_in_background` task or subagent is running; also during `PreCompact` |
| 🟢 green | `idle` | Turn done, nothing running |
| 🟣 magenta | `waiting` | Notification needing user attention (permission prompt, plan approval, elicitation) |
| 🔴 red | `stuck` | Heartbeat > 30s AND CPU < 1% (model hung or crashed) |
| 🔴 red | `error` | `StopFailure`, or transcript tail contains `[Request interrupted by user]` |

The dot disappears on `SessionEnd` or when the claude process vanishes.

## Architecture

- **Hook** (`scripts/tmux-status.sh`) fires on every Claude Code hook
  event and writes a compact JSON file under
  `/tmp/kvaps-tmux-status.<uid>/<pane_id>.json` with the raw event
  name, `session_id`, `transcript_path`, and timestamp. The hook does
  NOT decide on a status itself — it's a dumb recorder, safe and fast.
- **Resolver** (`scripts/tmux-status-resolve.sh`) is invoked from
  tmux's `status-left` via `#(...)` every `status-interval` seconds.
  It iterates every state file and combines four signals into a live
  status:
  1. last hook event (from the state file)
  2. heartbeat = max(event timestamp, transcript JSONL mtime) — proves
     the model is streaming output even when no hook is firing
  3. CPU% of claude's PID — distinguishes "thinking" (internal
     reasoning, CPU hot) from "working" (streaming) and from "stuck"
     (silent + cold)
  4. transcript tail for `[Request interrupted by user]` — flags error
  5. child-process tree of claude's PID + `~/.claude/tasks/*/.lock`
     flocks — detects background bash and subagent activity
- The resolver then writes `@claude_status` on each tracked pane's
  window. `tmux.conf` renders the colored dot from that option.

## Installation

```text
/plugin marketplace add kvaps/claude-plugins
/plugin install tmux-status@kvaps-claude-plugins
```

### tmux.conf setup (one-time)

Add to `~/.tmux.conf` **after** your theme plugin (e.g. after the
`run '~/.tmux/plugins/tpm/tpm'` line):

```tmux
# Claude Code session status indicator
set -g @claude_status_fmt "#{?@claude_status,#[fg=#{?#{==:#{E:@claude_status},error},red,#{?#{==:#{E:@claude_status},stuck},red,#{?#{==:#{E:@claude_status},waiting},magenta,#{?#{==:#{E:@claude_status},working},yellow,#{?#{==:#{E:@claude_status},thinking},#b8860b,#{?#{==:#{E:@claude_status},background},blue,#00ff00}}}}}}]● #[default],}"
run-shell "$HOME/.claude/plugins/marketplaces/kvaps-claude-plugins/hooks/tmux-status/scripts/tmux-install-status-fmt.sh"
```

Then reload: `tmux source-file ~/.tmux.conf`.

The installer script:
1. Injects `#{E:@claude_status_fmt}` into both `window-status-format`
   and `window-status-current-format` right before `#I:`, duplicating
   any `#[...]` style directives from the theme prefix so the dot's
   `#[default]` reset doesn't bleed the theme's fg/bg onto the window
   name. Non-style characters (powerline arrows, etc.) are left in
   place, not duplicated.
2. Installs the resolver as a `#(...)` probe on `status-left` so it
   runs every `status-interval` seconds as an invisible side effect.
3. Lowers `status-interval` to 2s if it was higher, so the probe feels
   live.

Safe to re-run; idempotent on every `tmux source-file`.

### Color customization

All colors live in the `@claude_status_fmt` value — swap any of
`red` / `magenta` / `yellow` / `#b8860b` / `blue` / `#00ff00` for
your preferred named tmux colors or hex values. `#00ff00` is used
instead of named `green` because some terminals override the named
color to a dimmer shade. `#b8860b` (dark goldenrod) gives a visible
distinction between `working` (bright yellow) and `thinking` (muted
yellow) without jumping to a completely different hue.

### Thresholds

Inside `scripts/tmux-status-resolve.sh`:

- `FRESH_HEARTBEAT_S=3` — heartbeat within this window = working
- `STALE_HEARTBEAT_S=30` — heartbeat older AND low CPU = stuck
- `CPU_ACTIVE_THRESHOLD=1` — CPU% above = thinking
- `CPU_IDLE_THRESHOLD=1` — CPU% below = idle/stuck

Edit these if the defaults feel off for your machine.

## Non-tmux environments

The hook exits silently when `$TMUX` or `$TMUX_PANE` is not set, so
the plugin is safe to keep enabled when claude runs outside tmux.

## State file location

`/tmp/kvaps-tmux-status.<uid>/` — per-user, volatile across reboots
(fine, since the hook rewrites on every event). Chosen to avoid
colliding with other tmux-status-style tools the user may have
installed.
