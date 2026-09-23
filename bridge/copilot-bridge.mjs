#!/usr/bin/env node
// Pop Sidekick <-> GitHub Copilot SDK bridge.
//
// Speaks newline-delimited JSON (NDJSON) over stdio with the Swift app.
// Every line on stdin is one request object; every line on stdout is one
// event object. All AI work goes through the official @github/copilot-sdk.
//
// Requests (Swift -> bridge):
//   { cmd: "listModels", id }
//   { cmd: "run", id, prompt, model?, systemMessage?, choices?,
//                 mcpServers?, disabledMcpServers?, skillDirectories?, enableConfigDiscovery?,
//                 reasoningEffort?, autoTier?,
//                 workingDirectory?,
//                 autoApproveTools?, timeoutMs?, attachments?, provider? }
//   { cmd: "ping", id, model?, provider?, prompt?, timeoutMs? }
//   { cmd: "cancel", id }
//   { cmd: "shutdown" }
//
// Events (bridge -> Swift):
//   { type: "ready" }
//   { type: "models", id, models: [{ id, name, efforts?, defaultEffort? }] }
//   { type: "pong",   id }
//   { type: "delta",  id, choice, text }
//   { type: "result", id, choice, text }
//   { type: "done",   id }
//   { type: "error",  id?, message }
//   { type: "log",    message }

import readline from "node:readline";
import { CopilotClient, RuntimeConnection, approveAll } from "@github/copilot-sdk";

let copilotPath = process.env.POPSIDEKICK_COPILOT_PATH || "/opt/homebrew/bin/copilot";

// If the reader (the app) goes away, writes to stdout raise EPIPE. Without a
// handler Node throws an unhandled 'error' event and the whole bridge crashes.
// Handle it gracefully instead.
let stdoutBroken = false;
process.stdout.on("error", (err) => {
  if (err && (err.code === "EPIPE" || err.code === "ERR_STREAM_DESTROYED")) {
    stdoutBroken = true;
    process.exit(0);
  }
});

function emit(obj) {
  if (stdoutBroken) return;
  try {
    process.stdout.write(JSON.stringify(obj) + "\n");
  } catch {
    // Swallow write failures; the stdout 'error' handler deals with EPIPE.
  }
}
function log(message) {
  emit({ type: "log", message: String(message) });
}

let client = null;
// Map of request id -> array of active sessions, so cancel() can abort them.
const active = new Map();

async function getClient() {
  if (client) return client;
  client = new CopilotClient({
    connection: RuntimeConnection.forStdio({ path: copilotPath }),
    logLevel: "error",
    clientInfo: {
      applicationName: "Pop Sidekick",
      ...(process.env.POPSIDEKICK_VERSION ? { applicationVersion: process.env.POPSIDEKICK_VERSION } : {}),
    },
  });
  await client.start();
  return client;
}

async function handleListModels(req) {
  try {
    const c = await getClient();
    const models = await c.listModels();
    emit({
      type: "models",
      id: req.id,
      models: models.map((m) => ({
        id: m.id,
        name: m.name,
        efforts: m.capabilities?.supports?.reasoningEffort ? (m.supportedReasoningEfforts ?? []) : [],
        defaultEffort: m.defaultReasoningEffort,
      })),
    });
  } catch (err) {
    emit({ type: "error", id: req.id, message: errMsg(err) });
  }
}

// Permission handler that rejects every tool/path/url request, used when the
// user disables automatic tool approval (the bridge runs headless and cannot
// prompt interactively).
const denyAll = () => ({
  kind: "reject",
  feedback: "Tool use is disabled in Pop Sidekick settings.",
});

function buildSessionConfig(req) {
  const autoApprove = req.autoApproveTools !== false;
  const config = {
    onPermissionRequest: autoApprove ? approveAll : denyAll,
  };
  if (req.model && req.model !== "auto") config.model = req.model;
  if (req.reasoningEffort && config.model) config.reasoningEffort = req.reasoningEffort;
  // Auto routing tier only applies to the "auto" model.
  if (req.autoTier && !config.model && !req.provider) {
    config.model = "auto";
    config.autoTier = req.autoTier;
  }
  if (req.systemMessage && req.systemMessage.trim().length > 0) {
    config.systemMessage = { mode: "append", content: req.systemMessage };
  }
  if (req.mcpServers && Object.keys(req.mcpServers).length > 0) {
    config.mcpServers = req.mcpServers;
  }
  if (Array.isArray(req.disabledMcpServers) && req.disabledMcpServers.length > 0) {
    config.disabledMcpServers = req.disabledMcpServers;
  }
  if (Array.isArray(req.skillDirectories) && req.skillDirectories.length > 0) {
    config.skillDirectories = req.skillDirectories;
  }
  if (req.enableConfigDiscovery) config.enableConfigDiscovery = true;
  if (typeof req.workingDirectory === "string" && req.workingDirectory.trim().length > 0) {
    config.workingDirectory = req.workingDirectory;
  }
  // BYOK: pass the user-supplied provider config straight through to the SDK.
  if (req.provider && req.provider.baseUrl) config.provider = req.provider;
  return config;
}

async function runOneChoice(req, choiceIndex, sessionsBag) {
  const c = await getClient();
  const session = await c.createSession(buildSessionConfig(req));
  sessionsBag.push(session);

  let full = "";
  const unsub = session.on("assistant.message_delta", (event) => {
    const piece = event?.data?.deltaContent ?? "";
    if (piece) {
      full += piece;
      emit({ type: "delta", id: req.id, choice: choiceIndex, text: piece });
    }
  });

  try {
    const timeoutMs = Number(req.timeoutMs) || 0;
    const sendOptions = { prompt: req.prompt };
    if (Array.isArray(req.attachments) && req.attachments.length > 0) {
      sendOptions.attachments = req.attachments;
    }
    const sendPromise = session.sendAndWait(sendOptions);
    let final;
    if (timeoutMs > 0) {
      let timer;
      const timeout = new Promise((_, reject) => {
        timer = setTimeout(
          () => reject(new Error(`Timed out after ${Math.round(timeoutMs / 1000)}s`)),
          timeoutMs,
        );
      });
      try {
        final = await Promise.race([sendPromise, timeout]);
      } finally {
        clearTimeout(timer);
      }
    } else {
      final = await sendPromise;
    }
    const finalText = final?.data?.content ?? full;
    emit({ type: "result", id: req.id, choice: choiceIndex, text: finalText });
  } finally {
    try { unsub(); } catch {}
    try { await session.disconnect(); } catch {}
  }
}

async function handleRun(req) {
  const choices = Math.max(1, Math.min(10, req.choices || 1));
  const sessionsBag = [];
  active.set(req.id, sessionsBag);
  try {
    const tasks = [];
    for (let i = 0; i < choices; i++) {
      tasks.push(runOneChoice(req, i, sessionsBag));
    }
    const results = await Promise.allSettled(tasks);
    const failed = results.filter((r) => r.status === "rejected");
    if (failed.length === results.length && failed.length > 0) {
      emit({ type: "error", id: req.id, message: errMsg(failed[0].reason) });
    }
    emit({ type: "done", id: req.id });
  } catch (err) {
    emit({ type: "error", id: req.id, message: errMsg(err) });
  } finally {
    active.delete(req.id);
  }
}

async function handlePing(req) {
  const timeoutMs = Number(req.timeoutMs) || 120000;
  let session;
  let timer;
  // The whole operation (client start + session create + first completion) is
  // raced against the timeout. Local providers (Ollama / Foundry Local) can be
  // slow on the first request because the model is loaded on demand.
  const work = (async () => {
    const c = await getClient();
    session = await c.createSession(buildSessionConfig(req));
    await session.sendAndWait({ prompt: req.prompt || "Reply with: OK" });
  })();
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(
      () => reject(new Error(
        `No response within ${Math.round(timeoutMs / 1000)}s. The endpoint may be unreachable, or a local model may still be loading — try again.`,
      )),
      timeoutMs,
    );
  });
  try {
    await Promise.race([work, timeout]);
    emit({ type: "pong", id: req.id });
  } catch (err) {
    emit({ type: "error", id: req.id, message: errMsg(err) });
  } finally {
    clearTimeout(timer);
    if (session) { try { await session.disconnect(); } catch {} }
    // After a timeout the work keeps going; release its session when it lands.
    work.then(
      () => { if (session) session.disconnect().catch(() => {}); },
      () => { if (session) session.disconnect().catch(() => {}); },
    );
  }
}

async function handleCancel(req) {
  const sessions = active.get(req.id);
  if (!sessions) return;
  for (const session of sessions) {
    try { await session.abort(); } catch {}
    try { await session.disconnect(); } catch {}
  }
  active.delete(req.id);
}

function errMsg(err) {
  if (!err) return "Unknown error";
  if (err instanceof Error) return err.message;
  return String(err);
}

async function shutdown() {
  try {
    for (const sessions of active.values()) {
      for (const s of sessions) {
        try { await s.abort(); } catch {}
        try { await s.disconnect(); } catch {}
      }
    }
    if (client) await client.stop();
  } catch {}
  process.exit(0);
}

const rl = readline.createInterface({ input: process.stdin });
rl.on("line", (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;
  let req;
  try {
    req = JSON.parse(trimmed);
  } catch (err) {
    emit({ type: "error", message: "Invalid JSON: " + errMsg(err) });
    return;
  }
  switch (req.cmd) {
    case "listModels": handleListModels(req); break;
    case "run": handleRun(req); break;
    case "ping": handlePing(req); break;
    case "cancel": handleCancel(req); break;
    case "shutdown": shutdown(); break;
    default: emit({ type: "error", id: req.id, message: "Unknown cmd: " + req.cmd });
  }
});
rl.on("close", () => shutdown());
process.on("SIGTERM", () => shutdown());
process.on("SIGINT", () => shutdown());

emit({ type: "ready" });
