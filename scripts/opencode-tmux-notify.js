// tmux-radar opencode plugin — TEMPLATE. install-hooks.sh copies this to
// ~/.config/opencode/plugins/tmux-radar.js, replacing __TMUX_RADAR_NOTIFY__
// with the absolute path to needinput-notify.sh. Runs under Bun inside the
// opencode TUI process (no npm deps; node:child_process is available).
//
// Reports lifecycle events (start / permission / idle / user / error / end)
// to `needinput-notify.sh opencode-hook` as one JSON line on stdin, feeding
// the tmux-radar agent registry + need-input marks. Fire-and-forget: never
// blocks and never throws into the TUI. Without TMUX_PANE (opencode attach /
// server-side runs) the plugin is a complete no-op.
import { spawn, spawnSync } from "node:child_process";

const NOTIFY = "__TMUX_RADAR_NOTIFY__";

export default async ({ directory }) => {
  if (!process.env.TMUX_PANE) return {};

  const payload = (event, extra = {}) =>
    JSON.stringify({
      event,
      session_id: "",
      pane: process.env.TMUX_PANE,
      pid: process.pid,
      cwd: directory || process.cwd(),
      message: "",
      ...extra,
    }) + "\n";

  const send = (event, extra) => {
    try {
      const child = spawn(NOTIFY, ["opencode-hook"], {
        stdio: ["pipe", "ignore", "ignore"],
        detached: false,
      });
      child.on("error", () => {}); // notify missing/unexecutable: stay silent
      child.stdin.on("error", () => {});
      child.stdin.end(payload(event, extra));
      child.unref?.(); // don't hold the event loop; never await exit
    } catch {
      // never crash the TUI over a status ping
    }
  };

  // event shapes vary across opencode versions — extract sid defensively
  const sid = (event) =>
    event?.properties?.sessionID ??
    event?.properties?.session_id ??
    event?.properties?.info?.id ??
    "";

  // async spawn may not flush on process death: best-effort sync end
  process.on("exit", () => {
    try {
      spawnSync(NOTIFY, ["opencode-hook"], {
        input: payload("end"),
        timeout: 1500,
        stdio: ["pipe", "ignore", "ignore"],
      });
    } catch {}
  });

  send("start");

  return {
    event: async ({ event }) => {
      try {
        const session_id = sid(event);
        switch (event?.type) {
          case "permission.updated":
            send("permission", {
              session_id,
              message: String(
                event?.properties?.title ?? event?.properties?.description ?? ""
              ),
            });
            break;
          case "session.status": // current shape: status object on properties
            if (event?.properties?.status?.type === "idle")
              send("idle", { session_id });
            break;
          case "session.idle": // legacy event name
            send("idle", { session_id });
            break;
          case "session.error":
            send("error", {
              session_id,
              message: String(
                event?.properties?.error?.message ??
                  event?.properties?.message ??
                  ""
              ),
            });
            break;
        }
      } catch {
        // unknown event shapes must never throw into opencode
      }
    },
    "chat.message": async () => send("user"),
    // honored by opencode versions that support a dispose hook; ignored otherwise
    dispose: async () => send("end"),
  };
};
