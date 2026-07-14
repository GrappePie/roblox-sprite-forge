import test from "node:test";
import assert from "node:assert/strict";
import sharp from "sharp";
import {
  getDirectionMasterStrategy,
  harmonizeDirectionMasterPalette,
  harmonizeSpritePalette,
  normalizeDiagonalMasters,
  normalizeDirectionalMasters,
  preserveWarmColorFamilies,
} from "../src/lib/direction-consistency.js";
import { animateCanonicalCell } from "../src/lib/motion.js";
import { alignSpriteCell, measureSpriteFootAnchor } from "../src/lib/postprocess.js";

test("las diagonales inferiores comparten la identidad más cercana al maestro frontal", async () => {
  const down = await createMaster("#aa3355", "#222222");
  const downLeft = await createMaster("#3366dd", "#eeeeee");
  const downRight = await createMaster("#aa3355", "#222222");
  const { masters, selection } = await normalizeDiagonalMasters(new Map([
    ["down", down],
    ["down_left", downLeft],
    ["down_right", downRight],
  ]), { cellSize: 48, paletteColors: 64 });

  assert.equal(selection.sourceKey, "down_right");
  assert.equal(selection.canonicalSide, "right");
  const [leftRaw, rightRaw] = await Promise.all([
    sharp(masters.get("down_left")).ensureAlpha().raw().toBuffer(),
    sharp(masters.get("down_right")).ensureAlpha().raw().toBuffer(),
  ]);
  assert.deepEqual(opaqueColorCounts(leftRaw), opaqueColorCounts(rightRaw));
});

test("canonicaliza la fase a la derecha aunque gane el maestro izquierdo", async () => {
  const down = await createMaster("#aa3355", "#222222");
  const downLeft = await createMaster("#aa3355", "#222222");
  const downRight = await createMaster("#3366dd", "#eeeeee");
  const { masters, selection } = await normalizeDiagonalMasters(new Map([
    ["down", down],
    ["down_left", downLeft],
    ["down_right", downRight],
  ]), { cellSize: 48, paletteColors: 64 });

  assert.equal(selection.pairs.down.sourceKey, "down_left");
  assert.equal(selection.pairs.down.canonicalKey, "down_right");
  const [leftRaw, rightRaw] = await Promise.all([
    sharp(masters.get("down_left")).ensureAlpha().raw().toBuffer(),
    sharp(masters.get("down_right")).ensureAlpha().raw().toBuffer(),
  ]);
  assert.deepEqual(opaqueColorCounts(leftRaw), opaqueColorCounts(rightRaw));
});

test("normaliza también las diagonales superiores desde un canónico derecho", async () => {
  const up = await createMaster("#5522aa", "#111111");
  const upLeft = await createMaster("#22aa77", "#dddddd");
  const upRight = await createMaster("#5522aa", "#111111");
  const { masters, selection } = await normalizeDiagonalMasters(new Map([
    ["up", up],
    ["up_left", upLeft],
    ["up_right", upRight],
  ]), { cellSize: 48, paletteColors: 64 });

  assert.equal(selection.pairs.up.sourceKey, "up_right");
  assert.equal(selection.pairs.up.canonicalKey, "up_right");
  const [leftRaw, rightRaw] = await Promise.all([
    sharp(masters.get("up_left")).ensureAlpha().raw().toBuffer(),
    sharp(masters.get("up_right")).ensureAlpha().raw().toBuffer(),
  ]);
  assert.deepEqual(opaqueColorCounts(leftRaw), opaqueColorCounts(rightRaw));
});

test("las vistas laterales forman una pareja reflejada con el mismo pivote", async () => {
  const down = await createMaster("#aa3355", "#222222");
  const up = await createMaster("#993355", "#252525");
  const left = await createMaster("#3366dd", "#eeeeee");
  const right = await createMaster("#aa3355", "#222222");
  const { masters, selection } = await normalizeDirectionalMasters(new Map([
    ["down", down],
    ["left", left],
    ["up", up],
    ["right", right],
  ]), { cellSize: 48, paletteColors: 64 });

  assert.equal(selection.version, 3);
  assert.equal(selection.pairs.side.sourceKey, "right");
  const [leftRaw, rightRaw, leftAnchor, rightAnchor] = await Promise.all([
    sharp(masters.get("left")).ensureAlpha().raw().toBuffer(),
    sharp(masters.get("right")).ensureAlpha().raw().toBuffer(),
    measureSpriteFootAnchor(masters.get("left")),
    measureSpriteFootAnchor(masters.get("right")),
  ]);
  assert.deepEqual(opaqueColorCounts(leftRaw), opaqueColorCounts(rightRaw));
  assert.deepEqual(
    { x: Math.round(leftAnchor.x), y: Math.round(leftAnchor.y) },
    { x: Math.round(rightAnchor.x), y: Math.round(rightAnchor.y) },
  );
});

test("el plan de maestros genera cinco ángulos y deriva tres vistas opuestas", () => {
  const directions = [
    "down", "down_left", "left", "up_left", "up", "up_right", "right", "down_right",
  ];
  const strategies = Object.fromEntries(directions.map((key) => [
    key,
    getDirectionMasterStrategy(key, "deterministic"),
  ]));

  assert.deepEqual(
    Object.entries(strategies).filter(([, strategy]) => strategy.kind === "generated").map(([key]) => key),
    ["down", "down_left", "left", "up_left", "up"],
  );
  assert.deepEqual(
    Object.fromEntries(Object.entries(strategies)
      .filter(([, strategy]) => strategy.kind === "mirrored")
      .map(([key, strategy]) => [key, strategy.sourceKey])),
    { up_right: "up_left", right: "left", down_right: "down_left" },
  );
  assert.equal(getDirectionMasterStrategy("right", "controlnet").kind, "generated");
});

test("todos los maestros comparten una sola paleta limitada", async () => {
  const masters = new Map([
    ["down", await createMaster("#aa3355", "#222222")],
    ["down_left", await createMaster("#a93458", "#242121")],
    ["left", await createMaster("#ad3152", "#202326")],
    ["up", await createMaster("#a83259", "#232120")],
  ]);
  const harmonized = await harmonizeDirectionMasterPalette(masters, {
    cellSize: 48,
    paletteColors: 8,
  });
  const colors = new Set();
  for (const master of harmonized.values()) {
    const raw = await sharp(master).ensureAlpha().raw().toBuffer();
    for (let index = 0; index < raw.length; index += 4) {
      if (raw[index + 3] < 8) continue;
      colors.add(`${raw[index]},${raw[index + 1]},${raw[index + 2]},${raw[index + 3]}`);
    }
  }
  assert.ok(colors.size <= 8, `la paleta compartida contiene ${colors.size} colores`);
});

test("las poses capturadas comparten la paleta sin perder sus claves de frame", async () => {
  const frames = new Map([
    ["master:down", await createMaster("#aa3355", "#222222")],
    ["walk:down_walk_1", await createMaster("#a93458", "#242121")],
    ["walk:down_walk_2", await createMaster("#ad3152", "#202326")],
  ]);
  const harmonized = await harmonizeSpritePalette(frames, {
    cellSize: 48,
    paletteColors: 8,
  });
  assert.deepEqual([...harmonized.keys()], [...frames.keys()]);
  const colors = new Set();
  for (const frame of harmonized.values()) {
    const raw = await sharp(frame).ensureAlpha().raw().toBuffer();
    for (let index = 0; index < raw.length; index += 4) {
      if (raw[index + 3] < 8) continue;
      colors.add(`${raw[index]},${raw[index + 1]},${raw[index + 2]},${raw[index + 3]}`);
    }
  }
  assert.ok(colors.size <= 8, `la paleta compartida contiene ${colors.size} colores`);
});

test("la paleta compartida no convierte piel cálida en manchas grises", async () => {
  const original = await sharp(Buffer.from([
    219, 191, 160, 255,
    220, 220, 222, 255,
  ]), { raw: { width: 2, height: 1, channels: 4 } }).png().toBuffer();
  const quantized = await sharp(Buffer.from([
    196, 196, 196, 255,
    220, 220, 222, 255,
  ]), { raw: { width: 2, height: 1, channels: 4 } }).png().toBuffer();
  const corrected = await preserveWarmColorFamilies(original, quantized, [
    [197, 163, 130],
    [196, 196, 196],
    [220, 220, 222],
  ]);
  const raw = await sharp(corrected).ensureAlpha().raw().toBuffer();
  assert.ok(raw[0] - raw[1] >= 12);
  assert.ok(raw[1] - raw[2] >= 8);
  assert.deepEqual([...raw.subarray(4, 7)], [220, 220, 222]);
});

test("las dos selecciones de maestro conservan fase 1 a 1 en las cuatro diagonales", async () => {
  const options = { cellSize: 48, paletteColors: 64 };
  const masters = new Map([
    ["down", await createMaster("#aa3355", "#222222")],
    // Abajo gana la izquierda.
    ["down_left", await createMaster("#aa3355", "#222222")],
    ["down_right", await createMaster("#3366dd", "#eeeeee")],
    ["up", await createMaster("#5522aa", "#111111")],
    // Arriba gana la derecha.
    ["up_left", await createMaster("#22aa77", "#dddddd")],
    ["up_right", await createMaster("#5522aa", "#111111")],
  ]);
  const normalized = await normalizeDiagonalMasters(masters, options);

  assert.equal(normalized.selection.pairs.down.sourceKey, "down_left");
  assert.equal(normalized.selection.pairs.up.sourceKey, "up_right");
  for (const [leftKey, rightKey] of [["down_left", "down_right"], ["up_left", "up_right"]]) {
    for (let frameIndex = 1; frameIndex <= 8; frameIndex += 1) {
      const frame = { frameIndex, frameCount: 8, clip: { key: "walk" } };
      const [leftAnimated, rightAnimated] = await Promise.all([
        animateCanonicalCell(normalized.masters.get(leftKey), { ...frame, direction: { key: leftKey } }),
        animateCanonicalCell(normalized.masters.get(rightKey), { ...frame, direction: { key: rightKey } }),
      ]);
      const mirroredLeft = await sharp(leftAnimated).flop().png().toBuffer();
      const [alignedLeft, alignedRight] = await Promise.all([
        alignSpriteCell(mirroredLeft, options),
        alignSpriteCell(rightAnimated, options),
      ]);
      const [leftRaw, rightRaw] = await Promise.all([
        sharp(alignedLeft).ensureAlpha().raw().toBuffer(),
        sharp(alignedRight).ensureAlpha().raw().toBuffer(),
      ]);
      assert.ok(
        countAlphaMaskDifferences(leftRaw, rightRaw) <= 12,
        JSON.stringify({ leftKey, rightKey, frameIndex }),
      );
    }
  }
});

async function createMaster(outfit, pants) {
  return sharp({
    create: { width: 48, height: 48, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } },
  }).composite([
    { input: { create: { width: 14, height: 13, channels: 4, background: "#f2d0b0" } }, left: 17, top: 5 },
    { input: { create: { width: 16, height: 14, channels: 4, background: outfit } }, left: 16, top: 18 },
    { input: { create: { width: 7, height: 12, channels: 4, background: pants } }, left: 17, top: 31 },
    { input: { create: { width: 7, height: 12, channels: 4, background: pants } }, left: 25, top: 31 },
  ]).png().toBuffer();
}

function opaqueColorCounts(data) {
  const counts = {};
  for (let index = 0; index < data.length; index += 4) {
    if (data[index + 3] < 8) continue;
    const key = `${data[index]},${data[index + 1]},${data[index + 2]},${data[index + 3]}`;
    counts[key] = (counts[key] ?? 0) + 1;
  }
  return counts;
}

function countAlphaMaskDifferences(left, right) {
  let differences = 0;
  for (let index = 3; index < left.length; index += 4) {
    if ((left[index] >= 8) !== (right[index] >= 8)) differences += 1;
  }
  return differences;
}
