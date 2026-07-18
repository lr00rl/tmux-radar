// tmux-radar opencode plugin template. install-hooks.sh replaces
// __TMUX_RADAR_NOTIFY__ with the absolute path to needinput-notify.sh.
//
// One blocking bridge process is owned by one OpenCode TUI. Events are written
// to its stdin and acknowledged in order; there is no per-event spawn loop.
import { spawn } from "node:child_process";

const NOTIFY = "__TMUX_RADAR_NOTIFY__";
const MAX_PENDING = 64;
const EVENT_TIMEOUT_MS = 3000;
const KILL_GRACE_MS = 250;

const brief = (value, max = 180) =>
  String(value ?? "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, max);

export default async ({ directory, client }) => {
  if (!process.env.TMUX_PANE) return {};

  const generationStarted = Date.now();
  const generation = `${generationStarted}:${process.pid}`;
  let sequence = 0;
  let pending = 0;
  let queue = Promise.resolve(true);
  let child;
  let bridgePgid = 0;
  let currentAck;
  let stdoutBuffer = "";
  let failed = false;
  let closed = false;
  let logged = false;
  let closeResolve;
  const closePromise = new Promise((resolve) => {
    closeResolve = resolve;
  });

  const logFailure = (message) => {
    if (logged) return;
    logged = true;
    try {
      Promise.resolve(
        client?.app?.log?.({
          body: {
            service: "tmux-radar",
            level: "error",
            message,
            extra: { generation, pane: process.env.TMUX_PANE },
          },
        })
      ).catch(() => {});
    } catch {}
  };

  const signalGroup = (signal) => {
    if (!bridgePgid) return;
    try {
      process.kill(-bridgePgid, signal);
      return;
    } catch {}
    if (closed) return;
    try {
      child.kill(signal);
    } catch {}
  };

  const failBridge = (reason) => {
    if (failed) return;
    failed = true;
    logFailure(`OpenCode lifecycle bridge stopped: ${reason}`);
    currentAck?.finish(false);
    signalGroup("SIGTERM");
    const killer = setTimeout(() => signalGroup("SIGKILL"), KILL_GRACE_MS);
    killer.unref?.();
  };

  try {
    child = spawn(NOTIFY, ["opencode-stream"], {
      stdio: ["pipe", "pipe", "ignore"],
      detached: true,
    });
    bridgePgid = child.pid;
  } catch (error) {
    logFailure(`OpenCode lifecycle bridge failed to start: ${brief(error)}`);
    return {};
  }

  child.once("error", (error) => failBridge(`spawn error: ${brief(error)}`));
  child.once("close", () => {
    closed = true;
    currentAck?.finish(false);
    closeResolve();
    if (!failed && pending > 0) {
      failed = true;
      logFailure("OpenCode lifecycle bridge exited before pending events were acknowledged");
    }
  });
  child.stdin.on("error", (error) => failBridge(`stdin error: ${brief(error)}`));
  child.stdout.on("error", (error) => failBridge(`stdout error: ${brief(error)}`));
  child.stdout.on("data", (chunk) => {
    stdoutBuffer += chunk.toString("utf8");
    if (stdoutBuffer.length > 8192) {
      failBridge("invalid acknowledgement stream");
      return;
    }
    let newline;
    while ((newline = stdoutBuffer.indexOf("\n")) >= 0) {
      const line = stdoutBuffer.slice(0, newline);
      stdoutBuffer = stdoutBuffer.slice(newline + 1);
      const [kind, ackGeneration, ackSequence] = line.split("\t");
      if (
        kind === "ok" &&
        currentAck &&
        ackGeneration === generation &&
        Number(ackSequence) === currentAck.sequence
      ) {
        currentAck.finish(true);
      }
    }
  });

  // exit handlers cannot await a grace period. The bridge is a dedicated
  // detached process group, so kill it synchronously instead of risking an
  // orphan when the OpenCode host exits without dispose().
  const onProcessExit = () => signalGroup("SIGKILL");
  process.once("exit", onProcessExit);

  const payload = (event, eventSequence, extra = {}) =>
    JSON.stringify({
      event,
      session_id: "",
      pane: process.env.TMUX_PANE,
      pid: process.pid,
      cwd: directory || process.cwd(),
      message: "",
      generation,
      generation_started: generationStarted,
      sequence: eventSequence,
      ...extra,
    }) + "\n";

  const deliver = (body, eventSequence) =>
    new Promise((resolve) => {
      if (failed || closed) {
        resolve(false);
        return;
      }
      let settled = false;
      const timer = setTimeout(
        () => failBridge(`event ${eventSequence} acknowledgement timed out`),
        EVENT_TIMEOUT_MS
      );
      const finish = (result) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (currentAck?.sequence === eventSequence) currentAck = undefined;
        resolve(result);
      };
      currentAck = { sequence: eventSequence, finish };
      try {
        child.stdin.write(body);
      } catch (error) {
        failBridge(`write error: ${brief(error)}`);
      }
    });

  const send = (event, extra = {}) => {
    if (failed || closed) return Promise.resolve(false);
    if (pending >= MAX_PENDING) {
      failBridge(`pending event limit (${MAX_PENDING}) exceeded`);
      return Promise.resolve(false);
    }
    const eventSequence = ++sequence;
    const body = payload(event, eventSequence, extra);
    pending += 1;
    const task = queue.then(() => deliver(body, eventSequence));
    queue = task.then(
      (result) => {
        pending -= 1;
        return result;
      },
      () => {
        pending -= 1;
        return false;
      }
    );
    return queue;
  };

  const sid = (event) => {
    const properties = event?.properties ?? {};
    return (
      properties.sessionID ??
      properties.session_id ??
      properties.info?.sessionID ??
      properties.info?.session_id ??
      (String(event?.type ?? "").startsWith("session.")
        ? properties.info?.id
        : "") ??
      ""
    );
  };

  const permissionMessage = (properties) => {
    const permission = brief(properties?.permission);
    const patterns = Array.isArray(properties?.patterns)
      ? properties.patterns.slice(0, 2).map((item) => brief(item, 100)).filter(Boolean)
      : [];
    return brief([permission, patterns.join(", ")].filter(Boolean).join(": "));
  };

  const questionMessage = (properties) => {
    const questions = Array.isArray(properties?.questions)
      ? properties.questions
      : [];
    return brief(
      questions
        .slice(0, 2)
        .map((question) =>
          brief(
            question?.question ??
              question?.prompt ??
              question?.header ??
              "question",
            120
          )
        )
        .filter(Boolean)
        .join(" | ")
    );
  };

  return {
    event: async ({ event }) => {
      try {
        const session_id = sid(event);
        const properties = event?.properties ?? {};
        switch (event?.type) {
          case "permission.asked":
          case "permission.updated":
            return send("permission", {
              session_id,
              message:
                permissionMessage(properties) ||
                brief(properties.title ?? properties.description),
            });
          case "permission.replied":
          case "question.replied":
          case "question.rejected":
            return send("user", { session_id });
          case "question.asked":
            return send("input", {
              session_id,
              message: questionMessage(properties),
            });
          case "session.created":
            return send("start", { session_id });
          case "session.status":
            if (properties.status?.type === "idle") {
              return send("idle", { session_id });
            }
            return;
          case "session.idle":
            return send("idle", { session_id });
          case "session.deleted":
            return send("end", { session_id });
          case "session.error":
            return send("error", {
              session_id,
              message: brief(properties.error?.message ?? properties.message),
            });
          case "message.updated":
            if (properties.info?.role === "user") {
              return send("user", { session_id });
            }
            return;
        }
      } catch (error) {
        logFailure(`OpenCode event mapping failed: ${brief(error)}`);
      }
    },
    "chat.message": async (input) =>
      send("user", { session_id: input?.sessionID ?? "" }),
    dispose: async () => {
      await queue;
      process.removeListener("exit", onProcessExit);
      if (!failed && !closed) child.stdin.end();
      await Promise.race([
        closePromise,
        new Promise((resolve) => setTimeout(resolve, KILL_GRACE_MS)),
      ]);
      if (!closed) {
        signalGroup("SIGTERM");
        await new Promise((resolve) => setTimeout(resolve, KILL_GRACE_MS));
      }
      if (!closed) signalGroup("SIGKILL");
    },
  };
};
