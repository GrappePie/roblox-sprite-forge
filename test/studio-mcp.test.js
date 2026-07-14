import test from "node:test";
import assert from "node:assert/strict";
import sharp from "sharp";
import {
  CAPTURE_DIRECTIONS,
  StudioCaptureService,
  cropStudioContactSheet,
  cropStudioViewport,
  extractToolImage,
  parseMcpResponse,
  parseToolPayload,
} from "../src/lib/studio-mcp.js";

test("etiqueta los ángulos horizontales desde la perspectiva del personaje", () => {
  assert.deepEqual(Object.fromEntries(CAPTURE_DIRECTIONS), {
    down: 0,
    down_left: 315,
    left: 270,
    up_left: 225,
    up: 180,
    up_right: 135,
    right: 90,
    down_right: 45,
  });
});

test("interpreta la envoltura SSE del bridge MCP", () => {
  const envelope = parseMcpResponse(
    'event: message\ndata: {"jsonrpc":"2.0","id":7,"result":{"content":[]}}\n\n',
    "text/event-stream",
  );
  assert.equal(envelope.id, 7);
  assert.deepEqual(envelope.result.content, []);
});

test("extrae imágenes base64 y resultados JSON anidados de herramientas", () => {
  const result = {
    content: [
      { type: "text", text: '{"success":true,"result":"{\\"rigType\\":\\"R15\\"}"}' },
      { type: "image", mimeType: "image/png", data: Buffer.from("pixels").toString("base64") },
    ],
  };
  const image = extractToolImage(result);
  assert.equal(image.mimeType, "image/png");
  assert.equal(image.buffer.toString(), "pixels");
  assert.deepEqual(parseToolPayload(result), { success: true, result: '{"rigType":"R15"}' });
});

test("recorta el centro del viewport panorámico y entrega una referencia cuadrada", async () => {
  const source = await sharp({
    create: { width: 300, height: 100, channels: 3, background: "#ff00ff" },
  }).png().toBuffer();
  const output = await cropStudioViewport(source, 64);
  const metadata = await sharp(output).metadata();
  assert.equal(metadata.width, 64);
  assert.equal(metadata.height, 64);
  assert.equal(metadata.format, "png");
});

test("separa una cuadrícula de Studio en frames cuadrados", async () => {
  const source = await sharp({
    create: { width: 300, height: 100, channels: 3, background: "#ff00ff" },
  }).png().toBuffer();
  const frames = await cropStudioContactSheet(source, 32, 4, 2);
  assert.equal(frames.length, 4);
  for (const frame of frames) {
    const metadata = await sharp(frame).metadata();
    assert.equal(metadata.width, 32);
    assert.equal(metadata.height, 32);
    assert.equal(metadata.format, "png");
  }
});

test("captura los dos idles equipados, locomoción, salto, caída y escalada", async () => {
  const screenshot = await sharp({
    create: { width: 24, height: 16, channels: 3, background: "#ff00ff" },
  }).png().toBuffer();
  const calls = [];
  const asText = (value) => ({ content: [{ type: "text", text: JSON.stringify(value) }] });
  const client = {
    diagnose: async () => ({ ok: true, place: { name: "Pixel avatar", id: 1, running: true } }),
    async callTool(name, args) {
      calls.push({ name, args });
      if (name === "solo_playtest") return asText({ running: true });
      if (name === "capture_screenshot") {
        return { content: [{ type: "image", mimeType: "image/png", data: screenshot.toString("base64") }] };
      }
      if (name === "eval_server_runtime" && args.code.includes("GetHumanoidDescriptionFromUserIdAsync")) {
        return asText({ result: JSON.stringify({
          animations: { IdleAnimation: "44", WalkAnimation: "55", RunAnimation: "66", JumpAnimation: "77", FallAnimation: "88", ClimbAnimation: "99" },
          resolvedAnimations: {
            IdleAnimation: "rbxassetid://111",
            IdleAltAnimation: "rbxassetid://222",
            WalkAnimation: "rbxassetid://123",
            RunAnimation: "rbxassetid://456",
            JumpAnimation: "rbxassetid://789",
            FallAnimation: "rbxassetid://987",
            ClimbAnimation: "rbxassetid://654",
          },
        }) });
      }
      if (name === "eval_server_runtime" && args.code.includes("SpriteForgeResolvedIdleAlt")) {
        return asText({ result: JSON.stringify({ ready: true, length: 1.2 }) });
      }
      if (name === "eval_server_runtime" && args.code.includes("SpriteForgeResolvedIdle")) {
        return asText({ result: JSON.stringify({ ready: true, length: 1.0 }) });
      }
      if (name === "eval_server_runtime" && args.code.includes("SpriteForgeResolvedWalk")) {
        return asText({ result: JSON.stringify({ ready: true, length: 0.65 }) });
      }
      if (name === "eval_server_runtime" && args.code.includes("SpriteForgeResolvedRun")) {
        return asText({ result: JSON.stringify({ ready: true, length: 0.5 }) });
      }
      if (name === "eval_server_runtime" && args.code.includes("SpriteForgeResolvedJump")) {
        return asText({ result: JSON.stringify({ ready: true, length: 0.45 }) });
      }
      if (name === "eval_server_runtime" && args.code.includes("SpriteForgeResolvedFall")) {
        return asText({ result: JSON.stringify({ ready: true, length: 0.7 }) });
      }
      if (name === "eval_server_runtime" && args.code.includes("SpriteForgeResolvedClimb")) {
        return asText({ result: JSON.stringify({ ready: true, length: 0.8 }) });
      }
      return asText({ result: true });
    },
  };
  const service = new StudioCaptureService({ client, format: "png" });
  const capture = await service.captureTurntable({
    userId: 42,
    renderResolution: 16,
    chroma: { hex: "#FF00FF" },
    framesPerAnimation: 2,
    frameCounts: { idle: 4, idle_alt: 4 },
  });

  assert.equal(capture.images.size, 8);
  assert.equal(capture.idleImages.size, 32);
  assert.equal(capture.idleAltImages.size, 32);
  assert.equal(capture.walkImages.size, 16);
  assert.equal(capture.runImages.size, 16);
  assert.equal(capture.jumpImages.size, 16);
  assert.equal(capture.fallImages.size, 16);
  assert.equal(capture.climbImages.size, 16);
  assert.ok(capture.walkImages.has("down_left_walk_2"));
  assert.ok(capture.idleImages.has("down_idle_2"));
  assert.ok(capture.idleAltImages.has("up_right_idle_alt_2"));
  assert.ok(capture.runImages.has("up_right_run_2"));
  assert.ok(capture.jumpImages.has("left_jump_2"));
  assert.ok(capture.fallImages.has("down_right_fall_2"));
  assert.ok(capture.climbImages.has("up_climb_2"));
  assert.equal(capture.source.capturedIdleFrames, 32);
  assert.equal(capture.source.capturedIdleAltFrames, 32);
  assert.equal(capture.source.capturedWalkFrames, 16);
  assert.equal(capture.source.capturedRunFrames, 16);
  assert.equal(capture.source.capturedJumpFrames, 16);
  assert.equal(capture.source.capturedFallFrames, 16);
  assert.equal(capture.source.capturedClimbFrames, 16);
  assert.equal(capture.source.walkMotionSource, "equipped-roblox-animation");
  assert.equal(capture.source.runMotionSource, "equipped-roblox-animation");
  assert.equal(capture.source.jumpMotionSource, "equipped-roblox-animation");
  assert.equal(capture.source.fallMotionSource, "equipped-roblox-animation");
  assert.equal(capture.source.climbMotionSource, "equipped-roblox-animation");
  assert.equal(calls.filter((call) => call.name === "capture_screenshot").length, 152);
  assert.equal(calls.filter((call) =>
    call.name === "eval_client_runtime" && call.args.code.includes("track.TimePosition")
  ).length, 144);
  assert.equal(capture.source.captureMethods.idle, "sequential");
  assert.equal(capture.source.captureMethods.idle_alt, "sequential");
  assert.equal(capture.source.captureMethods.walk, "sequential");
  assert.equal(capture.source.screenshotCalls, 152);
  assert.deepEqual(capture.source.batchFallbacks, []);
  const cameraSetup = calls.find((call) =>
    call.name === "eval_client_runtime" && call.args.code.includes("SpriteForgeCaptureCamera")
  );
  assert.match(cameraSetup.args.code, /SpriteForgeCaptureTarget = initialBounds\.Position/);
  assert.match(cameraSetup.args.code, /SpriteForgeCaptureDistance = math\.max\(initialSize/);
});

test("recaptura únicamente los clips solicitados", async () => {
  const screenshot = await sharp({
    create: { width: 24, height: 16, channels: 3, background: "#ff00ff" },
  }).png().toBuffer();
  const calls = [];
  const asText = (value) => ({ content: [{ type: "text", text: JSON.stringify(value) }] });
  const client = {
    diagnose: async () => ({ ok: true, place: { name: "Pixel avatar", id: 1, running: true } }),
    async callTool(name, args) {
      calls.push({ name, args });
      if (name === "capture_screenshot") {
        return { content: [{ type: "image", mimeType: "image/png", data: screenshot.toString("base64") }] };
      }
      if (name === "eval_server_runtime" && args.code.includes("GetHumanoidDescriptionFromUserIdAsync")) {
        return asText({ result: JSON.stringify({ animations: {}, resolvedAnimations: { ClimbAnimation: "rbxassetid://654" } }) });
      }
      if (name === "eval_server_runtime" && args.code.includes("SpriteForgeResolvedClimb")) {
        return asText({ result: JSON.stringify({ ready: true, length: 0.8 }) });
      }
      return asText({ result: true });
    },
  };
  const service = new StudioCaptureService({ client, format: "png" });
  const capture = await service.captureTurntable({
    userId: 42,
    renderResolution: 16,
    chroma: { hex: "#FF00FF" },
    framesPerAnimation: 2,
    clips: ["climb"],
  });

  assert.equal(capture.images.size, 0);
  assert.equal(capture.walkImages.size, 0);
  assert.equal(capture.climbImages.size, 16);
  assert.deepEqual(capture.source.recapturedClips, ["climb"]);
  assert.equal(calls.filter((call) => call.name === "capture_screenshot").length, 16);
});

test("captura flotación y nado nivel/arriba/abajo con una sola selección", async () => {
  const screenshot = await sharp({
    create: { width: 24, height: 16, channels: 3, background: "#ff00ff" },
  }).png().toBuffer();
  const calls = [];
  const asText = (value) => ({ content: [{ type: "text", text: JSON.stringify(value) }] });
  const client = {
    diagnose: async () => ({ ok: true, place: { name: "Pixel avatar", id: 1, running: true } }),
    async callTool(name, args) {
      calls.push({ name, args });
      if (name === "solo_playtest") return asText({ running: true });
      if (name === "capture_screenshot") {
        return { content: [{ type: "image", mimeType: "image/png", data: screenshot.toString("base64") }] };
      }
      if (name === "eval_server_runtime" && args.code.includes("GetHumanoidDescriptionFromUserIdAsync")) {
        return asText({ result: JSON.stringify({
          animations: {},
          resolvedAnimations: {
            SwimAnimation: "rbxassetid://700",
            SwimIdleAnimation: "rbxassetid://701",
          },
        }) });
      }
      if (name === "eval_server_runtime" && args.code.includes("SpriteForgeResolvedSwim")) {
        return asText({ result: JSON.stringify({ ready: true, length: 1 }) });
      }
      return asText({ result: true });
    },
  };
  const service = new StudioCaptureService({ client, format: "png", batchIdle: true });
  const capture = await service.captureTurntable({
    userId: 42,
    renderResolution: 16,
    chroma: { hex: "#FF00FF" },
    framesPerAnimation: 2,
    frameCounts: { swim_idle: 2, swim: 2, swim_up: 2, swim_down: 2 },
    clips: ["swim"],
  });

  assert.equal(capture.images.size, 0);
  assert.equal(capture.swim_idleImages.size, 16);
  assert.equal(capture.swimImages.size, 16);
  assert.equal(capture.swim_upImages.size, 16);
  assert.equal(capture.swim_downImages.size, 16);
  assert.ok(capture.swim_upImages.has("down_left_swim_up_2"));
  assert.equal(capture.source.capturedSwimIdleFrames, 16);
  assert.equal(capture.source.capturedSwimFrames, 16);
  assert.equal(capture.source.capturedSwimUpFrames, 16);
  assert.equal(capture.source.capturedSwimDownFrames, 16);
  assert.equal(capture.source.screenshotCalls, 32);
  assert.equal(capture.source.captureMethods.swim_idle, "world-grid-batch");
  assert.equal(capture.source.captureMethods.swim_up, "world-grid-batch");
  const swimUpBatch = calls.find((call) =>
    call.name === "eval_client_runtime"
      && call.args.code.includes("SpriteForgeCaptureSwimUpTrack")
      && call.args.code.includes("rig:Clone")
  );
  const swimDownBatch = calls.find((call) =>
    call.name === "eval_client_runtime"
      && call.args.code.includes("SpriteForgeCaptureSwimDownTrack")
      && call.args.code.includes("rig:Clone")
  );
  assert.match(swimUpBatch.args.code, /math\.rad\(-60\)/);
  assert.match(swimDownBatch.args.code, /math\.rad\(-120\)/);
  const swimLevelBatch = calls.find((call) =>
    call.name === "eval_client_runtime"
      && call.args.code.includes("SpriteForgeCaptureSwimTrack")
      && call.args.code.includes("rig:Clone")
  );
  assert.match(swimLevelBatch.args.code, /math\.rad\(-90\)/);
});

test("vuelve al capturador secuencial si Studio rechaza el lote", async () => {
  const screenshot = await sharp({
    create: { width: 24, height: 16, channels: 3, background: "#ff00ff" },
  }).png().toBuffer();
  const calls = [];
  const asText = (value) => ({ content: [{ type: "text", text: JSON.stringify(value) }] });
  const client = {
    diagnose: async () => ({ ok: true, place: { name: "Pixel avatar", id: 1, running: true } }),
    async callTool(name, args) {
      calls.push({ name, args });
      if (name === "solo_playtest") return asText({ running: true });
      if (name === "capture_screenshot") {
        return { content: [{ type: "image", mimeType: "image/png", data: screenshot.toString("base64") }] };
      }
      if (name === "eval_server_runtime" && args.code.includes("GetHumanoidDescriptionFromUserIdAsync")) {
        return asText({ result: JSON.stringify({
          animations: {},
          resolvedAnimations: { IdleAnimation: "rbxassetid://111" },
        }) });
      }
      if (name === "eval_server_runtime" && args.code.includes("SpriteForgeResolvedIdle")) {
        return asText({ result: JSON.stringify({ ready: true, length: 1 }) });
      }
      if (name === "eval_client_runtime" && args.code.includes("SpriteForgeBatchCapture") && args.code.includes("rig:Clone")) {
        throw new Error("batch unavailable");
      }
      return asText({ result: true });
    },
  };
  const service = new StudioCaptureService({ client, format: "png", batchIdle: true });
  const capture = await service.captureTurntable({
    userId: 42,
    renderResolution: 16,
    chroma: { hex: "#FF00FF" },
    framesPerAnimation: 2,
    clips: ["idle"],
  });

  assert.equal(capture.idleImages.size, 16);
  assert.equal(capture.idleAltImages.size, 0);
  assert.equal(capture.source.captureMethods.idle, "sequential-fallback");
  assert.equal(capture.source.screenshotCalls, 24);
  assert.equal(capture.source.batchFallbacks.length, 1);
  assert.equal(capture.source.batchFallbacks[0].clip, "idle");
});
