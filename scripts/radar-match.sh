#!/usr/bin/env bash
# shellcheck shell=bash
# Which watched agent a process is, defined once for the pane scan, the hook's
# own ancestry walk, registry liveness and the live scanner. Sourced, never
# executed.
#
# A process is matched on the ps `command=` text. pane_current_command is no
# help: Claude Code's foreground binary is a bare version number ("2.1.283").
#   1. Any path component of argv0 equal to a watched name, ".app" stripped
#      ("/opt/x/claude/bin/run", "cursor-agent").
#   2. When argv0 is a wrapper, the same test on the program it runs: the first
#      later argument that is not a flag. A wrapper is a script runtime (node,
#      bun, deno) or a launcher whose own name says nothing (Cursor's CLI
#      installs as `agent` and runs ".../cursor-agent/versions/<v>/index.js").
# Step 2 is limited to wrappers on purpose: `vim ~/src/claude/notes.md` has a
# "claude" component in an argument and is no agent.
#
# radar_norm maps a package directory to the watched name it stands for: pi's
# cli.js lives under ".../pi-coding-agent/...", Gemini's under "gemini-cli",
# and an SDK-run Claude session is "node .../@anthropic-ai/claude-code/cli.js".
#
# RADAR_MATCH_AWK holds the awk functions; prepend it to a program. Keep the
# text free of apostrophes.
#   radar_kind(cmd, name, want)  the watched name `cmd` stands for, or "".
#                                name != "": test that one name. Otherwise any
#                                key of the array `want`.
#   radar_proc(cmd, kind)        the name to record for liveness: argv0's
#                                basename, or `kind` behind a wrapper.
#   radar_elapsed(etime)         seconds, from ps `etime=` ([[dd-]hh:]mm:ss).
#   radar_firing(me, kind, want) who fired an event, read off the process tree
#                                in the arrays par[pid], cmd[pid], age[pid]
#                                (parent, command line, elapsed seconds):
#                                "<pid> <proc> <nested> <kind>", tab-separated,
#                                or "". kind == "": the nearest watched agent.
#   radar_teammate(cmd)          1 when `cmd` is a Claude Code teammate: the
#                                lead of an agent team starts each member as
#                                `claude --agent-id <id> --agent-name <name>
#                                --team-name <team>` (all three or none), and
#                                a member reports to that lead, not to you.
#
# radar_firing answers two questions with one walk up from the hook process
# `me`. The agent that fired the event is the nearest ancestor of `kind`. It is
# nested when another watched agent stands above it: a run an agent started
# from a tool call (claude -p, codex exec) inherits that agent's $TMUX_PANE,
# and its events would land on a pane whose own agent is mid-turn. A launcher
# and the binary it spawns (node codex.js and codex) are one agent, not two:
# a direct parent of the same kind that started within three seconds of its
# child is skipped. A host that ran the same CLI through an exec-ing shell is
# a direct parent of the same kind too, but it started long before.
# shellcheck disable=SC2034  # consumed by the scripts that source this file
RADAR_MATCH_AWK='
function radar_norm(c) {
  sub(/\.app$/, "", c)
  if (c == "pi-coding-agent") return "pi"
  if (c == "gemini-cli") return "gemini"
  if (c == "claude-code") return "claude"
  return c
}
function radar_wrapper(b) {
  return (b == "node" || b == "nodejs" || b == "bun" || b == "deno" || b == "agent")
}
function radar_argv0(cmd,    a0) {
  a0 = cmd; sub(/^[[:space:]]+/, "", a0); sub(/[[:space:]].*/, "", a0)
  return a0
}
function radar_program(cmd,    n, t, i) {
  n = split(cmd, t, /[[:space:]]+/)
  for (i = 2; i <= n && i <= 8; i++) if (t[i] != "" && t[i] !~ /^-/) return t[i]
  return ""
}
function radar_base(path,    low, n, parts) {
  low = tolower(path); gsub(/\\/, "/", low)
  n = split(low, parts, "/")
  return radar_norm(parts[n])
}
function radar_component(path, name, want,    low, n, parts, i, c) {
  low = tolower(path); gsub(/\\/, "/", low)
  n = split(low, parts, "/")
  for (i = 1; i <= n; i++) {
    c = radar_norm(parts[i])
    if (c == "") continue
    if (name != "" ? c == name : (c in want)) return c
  }
  return ""
}
function radar_kind(cmd, name, want,    a0, k) {
  a0 = radar_argv0(cmd)
  k = radar_component(a0, name, want)
  if (k != "") return k
  if (radar_wrapper(radar_base(a0))) return radar_component(radar_program(cmd), name, want)
  return ""
}
function radar_proc(cmd, kind,    b) {
  b = radar_base(radar_argv0(cmd))
  return radar_wrapper(b) ? kind : b
}
function radar_teammate(cmd) {
  return (index(cmd " ", " --agent-id ") > 0 || index(cmd, " --agent-id=") > 0) ? 1 : 0
}
function radar_elapsed(etime,    n, f, days) {
  days = 0
  if (etime ~ /-/) { days = etime; sub(/-.*/, "", days); sub(/^[^-]*-/, "", etime) }
  n = split(etime, f, ":")
  if (n == 3) return days * 86400 + f[1] * 3600 + f[2] * 60 + f[3]
  if (n == 2) return days * 86400 + f[1] * 60 + f[2]
  return days * 86400 + f[1]
}
function radar_firing(me, kind, want,    cur, hops, agent, is, top, up, gap, nested) {
  agent = ""; is = ""; cur = me
  for (hops = 0; hops < 60 && cur != "" && cur != "0" && cur != "1"; hops++) {
    if (cur in cmd) { is = radar_kind(cmd[cur], kind, want); if (is != "") { agent = cur; break } }
    cur = par[cur]
  }
  if (agent == "") return ""
  top = agent
  for (hops = 0; hops < 8; hops++) {
    up = par[top]
    if (up == "" || !(up in cmd) || radar_kind(cmd[up], is, want) == "") break
    gap = age[up] - age[top]; if (gap < 0) gap = -gap
    if (gap > 3) break
    top = up
  }
  nested = 0; cur = par[top]
  for (hops = 0; hops < 60 && cur != "" && cur != "0" && cur != "1"; hops++) {
    if ((cur in cmd) && radar_kind(cmd[cur], "", want) != "") { nested = 1; break }
    cur = par[cur]
  }
  return agent "\t" radar_proc(cmd[agent], is) "\t" nested "\t" is
}
'
