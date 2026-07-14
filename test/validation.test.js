import test from "node:test";
import assert from "node:assert/strict";
import { readGenerationPayload, readJobId } from "../src/lib/validation.js";

const config = {
  allowed: {
    renderResolutions: [512, 768],
    cellSizes: [48, 64],
    paletteSizes: [32, 64],
    styles: ["handheld", "minimal"],
    steps: [4, 6],
    animationFrames: [2, 4, 6, 8],
    idleAnimationFrames: [8, 12, 16],
  },
  defaults: {
    renderResolution: 768,
    cellSize: 64,
    paletteColors: 64,
    style: "handheld",
    steps: 4,
    framesPerAnimation: 4,
    idleFramesPerAnimation: 16,
  },
  maxNotesLength: 20,
};

test("normaliza el payload de generación", () => {
  const payload = readGenerationPayload(
    {
      source: "@YukiManju",
      renderResolution: 512,
      cellSize: 48,
      paletteColors: 32,
      style: "minimal",
      steps: 6,
      framesPerAnimation: 6,
      idleFramesPerAnimation: 12,
      seed: "123",
      notes: "texto",
    },
    config,
  );
  assert.deepEqual(payload, {
    source: "@YukiManju",
    renderResolution: 512,
    cellSize: 48,
    paletteColors: 32,
    style: "minimal",
    steps: 6,
    framesPerAnimation: 6,
    idleFramesPerAnimation: 12,
    seed: 123,
    notes: "texto",
    reuseCaptureJobId: null,
    recaptureClips: [],
  });
});

test("acepta una base de captura y una selección de clips sin duplicados", () => {
  const payload = readGenerationPayload({
    source: "YukiManju",
    reuseCaptureJobId: "123e4567-e89b-42d3-a456-426614174000",
    recaptureClips: ["climb", "swim", "walk", "climb"],
  }, config);
  assert.equal(payload.reuseCaptureJobId, "123e4567-e89b-42d3-a456-426614174000");
  assert.deepEqual(payload.recaptureClips, ["climb", "swim", "walk"]);
  assert.throws(() => readGenerationPayload({
    source: "YukiManju",
    recaptureClips: ["dance"],
  }, config), /capturar/i);
});

test("crea una semilla cuando queda vacía", () => {
  const payload = readGenerationPayload({ source: "YukiManju" }, config);
  assert.ok(Number.isSafeInteger(payload.seed));
  assert.ok(payload.seed >= 0);
});

test("valida UUID de trabajo", () => {
  assert.equal(readJobId("123e4567-e89b-42d3-a456-426614174000"), "123e4567-e89b-42d3-a456-426614174000");
  assert.throws(() => readJobId("abc"), /identificador/i);
});
