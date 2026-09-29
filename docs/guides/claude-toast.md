# Claude Code toast plugin

tmux-radar tells you about other panes through the tmux status line, pane
titles and the Agents board. When the pane you are looking at is a Claude Code
session, the plugin in `claude-plugin/` says the same thing inside that
session: a toast such as

```text
tmux-radar: ⚠ billing-api · Claude needs approval: Bash
```

appears on Claude Code's notification line when an agent in another pane gets
a mark, and leaves on its own (ten seconds for an action, six otherwise).

The plugin is a display. It writes no state and decides nothing about what an
event means. The command hooks and the scanner keep doing that; the plugin
reads the result.

## Requirements

Function hooks are an early-access Claude Code feature. The interface can
change between releases, which is why tracking does not depend on this plugin.
Turn the feature on where Claude Code runs, for example in
`~/.claude/settings.json`:

```json
{ "env": { "CLAUDE_CODE_ENABLE_FUNCTION_HOOKS": "1" } }
```

The plugin was written and tested against Claude Code 2.1.283.

## Install

From the tmux-radar checkout, for one session:

```sh
claude --plugin-dir ~/.tmux/plugins/tmux-radar/claude-plugin
```

For every session, name the folder in `CLAUDE_CODE_PLUGIN_DIRS` in the `env`
block of `~/.claude/settings.json`, or install it from the repository's
marketplace entry:

```sh
claude plugin marketplace add lr00rl/tmux-radar
claude plugin install tmux-radar@tmux-radar
```

An installed plugin is copied without the repository's `scripts/` folder, so
it uses the scripts of your tmux-radar install (`$TMUX_PLUGIN_MANAGER_PATH` or
`~/.tmux/plugins/tmux-radar`). Set the `radarDir` option when the checkout
lives somewhere else.

## When a toast appears

All of these hold:

- the session is interactive and runs inside tmux;
- its own pane is on screen (active pane of the active window of an attached
  session), because a toast in a pane nobody looks at is read by nobody;
- the mark belongs to another pane and another session;
- the mark is new since the session started and at most two minutes old;
- its level is one of the `levels` option (`action,done,notice` by default).

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `levels` | `action,done,notice` | Levels that raise a toast. `action` alone keeps only "needs you". |
| `radarDir` | empty | Path of the tmux-radar checkout to take the scripts from. |

## Cost

Every two seconds the plugin asks for the modification time of the mark file
and does nothing else while it is unchanged. When a mark is written or
cleared it runs `scripts/needinput-toast.sh feed <pane> <session>` once. No
process runs in an idle workspace.

## How it fits together

```text
agent hook -> needinput-notify.sh -> need-input (marks)
                                        |
             needinput-toast.sh render -+-> @radar-chips (tmux status line)
             needinput-toast.sh feed ---+-> claude-plugin (toast in the session)
```

`feed` prints one row per mark that is off screen or paneless, with the level
from `scripts/radar-level.sh` and the window name, so the plugin carries no
second definition of either.

## Develop

```sh
cd claude-plugin
# writes the API types the tsconfig includes; the folder is gitignored
claude   # then run: /plugin-types .claude/types
tsc -p tsconfig.json
claude plugin validate .
CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 claude plugin test .
```
