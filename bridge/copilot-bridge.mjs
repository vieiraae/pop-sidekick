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
//                 mcpServers?, skillDirectories?, enableConfigDiscovery? }
//   { cmd: "cancel", id }
//   { cmd: "shutdown" }
//
// Events (bridge -> Swift):
//   { type: "ready" }
//   { type: "models", id, models: [{ id, name }] }
//   { type: "delta",  id, choice, text }
//   { type: "result", id, choice, text }
//   { type: "done",   id }
//   { type: "error",  id?, message }
//   { type: "log",    message }

import readline from "node:readline";
import { CopilotClient, RuntimeConnection, approveAll } from "@github/copilot-sdk";

const copilotPath = process.env.POPSIDEKICK_COPILOT_PATH || "/opt/homebrew/bin/copilot";

function emit(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
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
      models: models.map((m) => ({ id: m.id, name: m.name })),
    });
  } catch (err) {
    emit({ type: "error", id: req.id, message: errMsg(err) });
  }
}

function buildSessionConfig(req) {
  const config = {
    onPermissionRequest: approveAll,
  };
  if (req.model && req.model !== "auto") config.model = req.model;
  if (req.systemMessage && req.systemMessage.trim().length > 0) {
    config.systemMessage = { mode: "append", content: req.systemMessage };
  }
  if (req.mcpServers && Object.keys(req.mcpServers).length > 0) {
    config.mcpServers = req.mcpServers;
  }
  if (Array.isArray(req.skillDirectories) && req.skillDirectories.length > 0) {
    config.skillDirectories = req.skillDirectories;
  }
  if (req.enableConfigDiscovery) config.enableConfigDiscovery = true;
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
    const final = await session.sendAndWait({ prompt: req.prompt });
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
    case "cancel": handleCancel(req); break;
    case "shutdown": shutdown(); break;
    default: emit({ type: "error", id: req.id, message: "Unknown cmd: " + req.cmd });
  }
});
rl.on("close", () => shutdown());
process.on("SIGTERM", () => shutdown());
process.on("SIGINT", () => shutdown());

emit({ type: "ready" });
