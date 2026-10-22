// tmux-radar pi bridge. install-hooks.sh copies this file to
// ~/.pi/agent/extensions/tmux-radar.ts and replaces __TMUX_RADAR_NOTIFY__
// with the absolute path of scripts/needinput-notify.sh.
//
// pi loads extensions in-process (jiti, no build step). One child process per
// event pipes one normalized JSON object to the notifier's public
// `agent-event` API, one child at a time so the notifier receives the events
// in the order pi fired them. (A notifier that waits 2s on a busy state lock
// spools its event for a replay a moment later, as it does for every
// adapter.) Events come at run boundaries and dialogs only. The
// bridge never throws into pi: every failure is swallowed. Plain JS on
// purpose: stays dependency-free and `node --check`-able despite the .ts
// extension.
//
// What radar hears, and from which pi event:
//   agent_start      user_resumed: a run began, from a prompt, a queued
//                    follow-up or another extension
//   ui_prompt_start  approval (select, confirm) or input_required (input,
//                    editor, custom), during a run only: a dialog opened
//                    between runs is one the person just asked for. pi asks
//                    for nothing itself; extensions such as
//                    pi-permission-system ask through ctx.ui. pi 0.84.4+.
//   ui_prompt_end    approval_resolved
//   agent_settled    turn_complete; turn_failed when the run ended on an
//                    error, interrupt when Escape stopped it, nothing when
//                    no run started. agent_end is not the end of a run: an
//                    automatic retry, compaction or a queued message can
//                    follow it. pi 0.80.4+.
//   session_start    session_start, and session_shutdown session_end
//
// At the end of a run the bridge also shows when the run started and ended,
// how long it took, and the session id and file, the lines radar's stop hook
// gives Claude Code and Codex:
//   UTC 2026-10-16T11:39:03Z → 11:39:50Z  turn took 47s
//   session 01a15e1a-591f-709a-93e2-ad8f735963c6
//   ~/.pi/agent/sessions/--Users-me-code-app--/2026-10-16T11-30-00-000Z_01a15e1a-….jsonl
// A session start shows the two session lines. `@radar-turn-stamp off` and
// `@radar-session-info off` leave them out, as they do there. pi shows them
// as a status line, which is not sent to the model or saved in the session.
//
// Only the TUI reports. pi loads extensions in print, json and rpc mode too,
// where a program reads the output and nobody sits at the prompt; started
// from another agent's tool call such a run inherits that agent's TMUX_PANE.
// ctx.mode says which it is (ctx.hasUI would not do: rpc reports true).
import { execFile, spawn } from "node:child_process";
import { homedir } from "node:os";

const NOTIFY = "__TMUX_RADAR_NOTIFY__";
const DETAIL_MAX = 100;

// a pi that does not say its mode predates the field and is served as before
function attended(ctx) {
  return !(ctx && typeof ctx.mode === "string" && ctx.mode !== "tui");
}

// One line of plain text for a label: radar rejects control characters.
function oneLine(text) {
  const s = String(text || "")
    .replace(/\x1b\[[0-9;?]*[ -/]*[@-~]/g, "")
    .replace(/[\s\x00-\x1f\x7f]+/g, " ")
    .trim();
  const chars = Array.from(s);
  return chars.length > DETAIL_MAX ? chars.slice(0, DETAIL_MAX - 1).join("") + "…" : s;
}

// The error a failed run stopped on: its last assistant message says why.
function lastError(messages) {
  if (!Array.isArray(messages)) return "";
  for (let i = messages.length - 1; i >= 0; i -= 1) {
    const m = messages[i];
    if (m && m.role === "assistant") return m.stopReason === "error" ? oneLine(m.errorMessage) : "";
  }
  return "";
}

function sessionOf(ctx) {
  const sm = ctx && ctx.sessionManager;
  let id = "";
  let file = "";
  try { id = String(sm.getSessionId() || ""); } catch { /* no session manager */ }
  try { file = String(sm.getSessionFile() || ""); } catch { /* in-memory session */ }
  return { id, file, key: id || String(process.pid) };
}

// Every child starts after the one before it has exited, so a late
// approval_resolved can never land on top of the turn_complete that followed
// it. A child still running after CHILD_MS is killed and the queue moves on.
let queue = Promise.resolve();
const CHILD_MS = 10000;

function run(event, payload) {
  return new Promise((resolve) => {
    let timer = null;
    const done = () => {
      clearTimeout(timer);
      resolve();
    };
    try {
      const child = spawn(NOTIFY, ["agent-event", "pi", event], {
        stdio: ["pipe", "ignore", "ignore"],
      });
      // SIGKILL: the notifier traps TERM, and bash runs a trap only after the
      // command it is waiting on returns, which may be the one that hangs
      timer = setTimeout(() => {
        try { child.kill("SIGKILL"); } catch { /* already gone */ }
        done();
      }, CHILD_MS);
      timer.unref();
      child.on("error", done);
      child.on("close", done);
      child.stdin.on("error", () => {});
      child.stdin.end(JSON.stringify(payload));
    } catch {
      done(); // never disturb the agent
    }
  });
}

function send(event, ctx, key, label) {
  const pane = process.env.TMUX_PANE || "";
  if (!pane) return; // pi outside tmux: radar has no destination to mark
  // radar rejects a payload whose strings hold control characters
  let cwd = String((ctx && ctx.cwd) || "");
  if (/[\x00-\x1f\x7f]/.test(cwd)) cwd = "";
  const payload = { session_id: key, cwd, pane, pid: process.pid, process: "pi" };
  if (label) payload.label = label;
  queue = queue.then(() => run(event, payload));
}

// What is still queued when pi quits, given a moment to reach radar.
function drain(ms) {
  return Promise.race([queue, new Promise((resolve) => setTimeout(resolve, ms).unref())]);
}

function tmuxOption(name) {
  return new Promise((resolve) => {
    try {
      execFile("tmux", ["show-options", "-gqv", name], { timeout: 2000 }, (err, out) =>
        resolve(err ? "" : String(out).trim()));
    } catch {
      resolve("");
    }
  });
}

// on unless set otherwise; no tmux server means the default
async function enabled(name) {
  return ((await tmuxOption(name)) || "on") === "on";
}

function utc(sec) {
  return new Date(sec * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");
}

// Same text as the notifier's _turn_text: whole seconds, the end's date left
// out when it is the start's.
function turnText(startMs, endMs) {
  const end = Math.floor(endMs / 1000);
  const to = utc(end);
  const start = Math.floor(startMs / 1000);
  if (!startMs || start > end) return `UTC ${to}  turn end`;
  const from = utc(start);
  const shown = from.slice(0, 10) === to.slice(0, 10) ? to.slice(11) : to;
  const d = end - start;
  const pad = (n) => String(n).padStart(2, "0");
  let took;
  if (d < 60) took = `${d}s`;
  else if (d < 3600) took = `${Math.floor(d / 60)}m ${pad(d % 60)}s`;
  else took = `${Math.floor(d / 3600)}h ${pad(Math.floor((d % 3600) / 60))}m`;
  return `UTC ${from} → ${shown}  turn took ${took}`;
}

// The id, then the file with the home dir as ~ on a line of its own, so it
// copies in one piece.
function sessionText(session) {
  if (!session.id) return "";
  let file = session.file;
  const home = homedir();
  if (file && home && file.startsWith(home + "/")) file = "~" + file.slice(home.length);
  return file ? `session ${session.id}\n${file}` : `session ${session.id}`;
}

async function showInfo(ctx, session, turn) {
  if (!ctx || !ctx.ui || typeof ctx.ui.notify !== "function") return;
  const [stamp, info] = await Promise.all([
    turn ? enabled("@radar-turn-stamp") : false,
    enabled("@radar-session-info"),
  ]);
  const lines = [];
  if (stamp) lines.push(turnText(turn[0], turn[1]));
  if (info) {
    const text = sessionText(session);
    if (text) lines.push(text);
  }
  if (!lines.length) return;
  try {
    ctx.ui.notify(lines.join("\n"), "info");
  } catch {
    // the session went away while the options were read
  }
}

export default function tmuxRadar(pi) {
  let session = null; // the session this runtime serves; null when unattended
  let runStart = 0;   // when the current run began; 0 between runs
  let outcome = "";   // how the run is settling, from agent_before_settle
  let failure = "";   // why the run's last assistant message stopped on an error
  let prompts = 0;    // dialogs reported to radar and still open

  const report = (event, ctx, label) => {
    if (session) send(event, ctx, session.key, label);
  };

  pi.on("session_start", (event, ctx) => {
    if (!attended(ctx)) return;
    session = sessionOf(ctx);
    report("session_start", ctx);
    if (!event || event.reason !== "reload") showInfo(ctx, session, null).catch(() => {});
  });

  pi.on("agent_start", (_event, ctx) => {
    if (!session || runStart) return;
    runStart = Date.now();
    outcome = "";
    failure = "";
    prompts = 0;
    report("user_resumed", ctx);
  });

  pi.on("ui_prompt_start", (event, ctx) => {
    if (!session || !runStart) return;
    prompts += 1;
    const kind = event && event.kind;
    const what = kind === "select" || kind === "confirm" ? "approval" : "input_required";
    report(what, ctx, oneLine(event && event.title));
  });

  pi.on("ui_prompt_end", (_event, ctx) => {
    if (!session || prompts === 0) return;
    prompts -= 1;
    if (prompts === 0) report("approval_resolved", ctx);
  });

  pi.on("agent_end", (event) => {
    failure = lastError(event && event.messages);
  });

  pi.on("agent_before_settle", (event) => {
    outcome = (event && event.outcome) || "";
  });

  pi.on("agent_settled", (event, ctx) => {
    if (!session) return;
    const started = runStart;
    const how = (event && event.aborted) || outcome === "aborted" ? "interrupt"
      : outcome === "error" || (!outcome && failure) ? "turn_failed"
      : "turn_complete";
    const why = failure;
    runStart = 0;
    outcome = "";
    failure = "";
    prompts = 0;
    // Nothing ran: the run failed before agent_start, right after the person
    // submitted it at this pane, so there is no turn to report or time.
    if (!started) return;
    report(how, ctx, how === "turn_failed" ? why : "");
    showInfo(ctx, session, [started, Date.now()]).catch(() => {});
  });

  pi.on("session_shutdown", (_event, ctx) => {
    if (!session) return undefined;
    report("session_end", ctx);
    session = null;
    return drain(1500);
  });
}
