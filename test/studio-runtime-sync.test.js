import assert from "node:assert/strict";
import test from "node:test";
import { StudioRuntimeSync } from "../src/lib/studio-runtime-sync.js";

test("entrega los bloques del atlas a Studio en micro-lotes de cuatro", async () => {
  const calls = [];
  const client = {
    async callTool(name, args) {
      calls.push({ name, args });
      return { content: [{ type: "text", text: JSON.stringify({ result: true }) }] };
    },
  };
  const sync = new StudioRuntimeSync({ client, avatars: {} });
  await sync.deliverReadyAtlas({
    status: "ready",
    userId: 42,
    jobId: "job-42",
    appearanceFingerprint: "fingerprint-42",
    atlas: { chunks: Array.from({ length: 9 }, (_, index) => `payload-${index + 1}`) },
  });

  assert.equal(calls.length, 5);
  assert.ok(calls.every((call) => call.name === "eval_server_runtime"));
  assert.match(calls[1].args.code, /Chunk001/);
  assert.match(calls[1].args.code, /Chunk004/);
  assert.doesNotMatch(calls[1].args.code, /Chunk005/);
  assert.match(calls[2].args.code, /Chunk005/);
  assert.match(calls[2].args.code, /Chunk008/);
  assert.match(calls[3].args.code, /Chunk009/);
  assert.match(calls[4].args.code, /replicated-ready/);
});
