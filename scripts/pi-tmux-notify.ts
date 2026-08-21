// tmux-radar pi bridge. install-hooks.sh copies this file to
// ~/.pi/agent/extensions/tmux-radar.ts and replaces __TMUX_RADAR_NOTIFY__
// with the absolute path of scripts/needinput-notify.sh.
//
// pi loads extensions in-process (jiti, no build step). One child process per
// event pipes one normalized JSON object to the notifier's public
// `agent-event` API; event volume is turn-boundary only. The bridge never
// throws into pi: every failure is swallowed. Plain JS on purpose: stays
// dependency-free and `node --check`-able despite the .ts extension.
//
// Coverage: session_start / user_resumed (interactive input) / turn_complete
// (agent_end) / session_end (shutdown). pi exposes no approval-request event,
// so permission waits are covered by tmux-radar's live screen scanner, not by
// this bridge.
import { spawn } from "node:child_process";

const NOTIFY = "__TMUX_RADAR_NOTIFY__";

function send(event, ctx) {
  const pane = process.env.TMUX_PANE || "";
  if (!pane) return; // pi outside tmux: radar has no destination to mark
  try {
    const child = spawn(NOTIFY, ["agent-event", "pi", event], {
      stdio: ["pipe", "ignore", "ignore"],
    });
    child.on("error", () => {});
    child.stdin.end(
      JSON.stringify({
        session_id: String(process.pid),
        cwd: (ctx && ctx.cwd) || "",
        pane,
        pid: process.pid,
        process: "pi",
      }),
    );
  } catch {
    // never disturb the agent
  }
}

export default function tmuxRadar(pi) {
  pi.on("session_start", (_event, ctx) => send("session_start", ctx));
  pi.on("input", (event, ctx) => {
    if (event && event.source === "interactive") send("user_resumed", ctx);
  });
  pi.on("agent_end", (_event, ctx) => send("turn_complete", ctx));
  pi.on("session_shutdown", (_event, ctx) => send("session_end", ctx));
}
