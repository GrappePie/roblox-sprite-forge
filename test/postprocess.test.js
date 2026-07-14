import test from "node:test";
import assert from "node:assert/strict";
import sharp from "sharp";
import {
  alignSpriteCell,
  alignSpriteTorsoToReference,
  assembleSpriteSheet,
  chooseChromaColor,
  createAtlasData,
  createPixelPreview,
  createStudioCellTransform,
  measureSpriteFootAnchor,
  measureSpriteTorsoAnchor,
  preserveSmallFaceDetails,
  repairHeadTorsoConnection,
  repairTorsoHipPixels,
  removeIsolatedAlphaPixels,
  removeChromaBackground,
  renderSpriteCell,
  renderStudioSpriteCell,
} from "../src/lib/postprocess.js";
import { getFramePlan } from "../src/lib/prompt.js";

async function createSyntheticFrame() {
  return sharp({
    create: {
      width: 96,
      height: 96,
      channels: 4,
      background: { r: 255, g: 0, b: 255, alpha: 1 },
    },
  })
    .composite([
      {
        input: {
          create: {
            width: 28,
            height: 50,
            channels: 4,
            background: { r: 20, g: 80, b: 220, alpha: 1 },
          },
        },
        left: 34,
        top: 30,
      },
    ])
    .png()
    .toBuffer();
}

test("elimina chroma, recorta y crea una celda transparente", async () => {
  const raw = await createSyntheticFrame();
  const transparent = await removeChromaBackground(raw, { hex: "#FF00FF", rgb: [255, 0, 255] });
  const trimmedInfo = await sharp(transparent).metadata();
  assert.ok(trimmedInfo.width <= 30);
  assert.ok(trimmedInfo.height <= 52);

  const cell = await renderSpriteCell(transparent, { cellSize: 64, paletteColors: 32 });
  const cellInfo = await sharp(cell).metadata();
  assert.equal(cellInfo.width, 64);
  assert.equal(cellInfo.height, 64);
  assert.equal(cellInfo.hasAlpha, true);
});

test("elimina el derrame magenta del antialias antes de cuantizar", async () => {
  const width = 12;
  const height = 12;
  const pixels = Buffer.alloc(width * height * 4);
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const offset = (y * width + x) * 4;
      const inside = x >= 3 && x <= 8 && y >= 3 && y <= 8;
      const interior = x >= 4 && x <= 7 && y >= 4 && y <= 7;
      const color = interior ? [8, 8, 10] : inside ? [128, 0, 128] : [255, 0, 255];
      pixels[offset] = color[0];
      pixels[offset + 1] = color[1];
      pixels[offset + 2] = color[2];
      pixels[offset + 3] = 255;
    }
  }
  const raw = await sharp(pixels, { raw: { width, height, channels: 4 } }).png().toBuffer();
  const transparent = await removeChromaBackground(
    raw,
    { hex: "#FF00FF", rgb: [255, 0, 255] },
    { trim: false },
  );
  const { data } = await sharp(transparent).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  for (let offset = 0; offset < data.length; offset += 4) {
    if (data[offset + 3] <= 18) continue;
    const magentaExcess = Math.min(data[offset], data[offset + 2]) - data[offset + 1];
    assert.ok(magentaExcess <= 18, `quedó spill magenta en ${offset / 4}: ${magentaExcess}`);
  }
});

test("conserva los acentos diminutos del rostro sin colorear el resto del cuerpo", async () => {
  const width = 32;
  const height = 32;
  const source = Buffer.alloc(width * height * 4);
  const quantized = Buffer.alloc(width * height * 4);
  for (let y = 3; y <= 29; y += 1) {
    for (let x = 8; x <= 23; x += 1) {
      const offset = (y * width + x) * 4;
      source.set([180, 180, 182, 255], offset);
      quantized.set([180, 180, 182, 255], offset);
    }
  }
  for (const [x, y] of [[14, 10], [17, 10], [15, 25]]) {
    source.set([55, 165, 220, 255], (y * width + x) * 4);
  }
  const corrected = await preserveSmallFaceDetails(
    await sharp(source, { raw: { width, height, channels: 4 } }).png().toBuffer(),
    await sharp(quantized, { raw: { width, height, channels: 4 } }).png().toBuffer(),
  );
  const data = await sharp(corrected).ensureAlpha().raw().toBuffer();
  assert.deepEqual([...data.subarray((10 * width + 14) * 4, (10 * width + 14) * 4 + 3)], [55, 165, 220]);
  assert.deepEqual([...data.subarray((25 * width + 15) * 4, (25 * width + 15) * 4 + 3)], [180, 180, 182]);
});

test("cierra una separación mínima entre una cabeza grande y el torso", async () => {
  const width = 32;
  const height = 32;
  const pixels = Buffer.alloc(width * height * 4);
  for (let y = 2; y <= 10; y += 1) {
    for (let x = 10; x <= 20; x += 1) pixels.set([80, 82, 86, 255], (y * width + x) * 4);
  }
  for (let y = 12; y <= 29; y += 1) {
    for (let x = 12; x <= 22; x += 1) pixels.set([120, 122, 126, 255], (y * width + x) * 4);
  }
  const repaired = await repairHeadTorsoConnection(
    await sharp(pixels, { raw: { width, height, channels: 4 } }).png().toBuffer(),
  );
  const data = await sharp(repaired).ensureAlpha().raw().toBuffer();
  const bridgePixels = Array.from({ length: width }, (_, x) => data[(11 * width + x) * 4 + 3]);
  assert.ok(bridgePixels.some((alpha) => alpha >= 220));
});

test("refuerza el cuello visible aunque el cabello ya conecte cabeza y torso", async () => {
  const width = 32;
  const height = 32;
  const pixels = Buffer.alloc(width * height * 4);
  for (let y = 2; y <= 10; y += 1) {
    for (let x = 8; x <= 22; x += 1) pixels.set([170, 172, 176, 255], (y * width + x) * 4);
  }
  for (let y = 14; y <= 29; y += 1) {
    for (let x = 11; x <= 21; x += 1) pixels.set([130, 132, 136, 255], (y * width + x) * 4);
  }
  // El mechón izquierdo deja toda la silueta conectada, pero el cuello central
  // conserva tres filas transparentes, igual que en la captura diagonal real.
  for (let y = 9; y <= 18; y += 1) {
    for (let x = 8; x <= 10; x += 1) pixels.set([24, 24, 28, 255], (y * width + x) * 4);
  }
  const repaired = await repairHeadTorsoConnection(
    await sharp(pixels, { raw: { width, height, channels: 4 } }).png().toBuffer(),
  );
  const data = await sharp(repaired).ensureAlpha().raw().toBuffer();
  assert.ok(data[(12 * width + 16) * 4 + 3] >= 220);
  assert.equal(data[(12 * width + 25) * 4 + 3], 0);
});

test("rellena píxeles incompletos de la cadera sin cerrar el espacio entre las piernas", async () => {
  const width = 32;
  const height = 32;
  const pixels = Buffer.alloc(width * height * 4);
  for (let y = 2; y <= 20; y += 1) {
    for (let x = 8; x <= 23; x += 1) pixels.set([150, 152, 156, 255], (y * width + x) * 4);
  }
  for (let y = 21; y <= 29; y += 1) {
    for (let x = 10; x <= 13; x += 1) pixels.set([120, 122, 126, 255], (y * width + x) * 4);
    for (let x = 18; x <= 21; x += 1) pixels.set([120, 122, 126, 255], (y * width + x) * 4);
  }
  for (const [x, y] of [[15, 17], [16, 17], [15, 18], [16, 18]]) {
    pixels.fill(0, (y * width + x) * 4, (y * width + x) * 4 + 4);
  }
  const repaired = await repairTorsoHipPixels(
    await sharp(pixels, { raw: { width, height, channels: 4 } }).png().toBuffer(),
  );
  const data = await sharp(repaired).ensureAlpha().raw().toBuffer();
  assert.ok(data[(18 * width + 15) * 4 + 3] >= 220);
  assert.equal(data[(24 * width + 15) * 4 + 3], 0);
});

test("elimina un píxel aislado sin borrar detalles conectados en diagonal", async () => {
  const source = await sharp({
    create: { width: 8, height: 8, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } },
  }).composite([
    { input: { create: { width: 1, height: 1, channels: 4, background: "#ffffff" } }, left: 1, top: 1 },
    { input: { create: { width: 1, height: 1, channels: 4, background: "#ffffff" } }, left: 4, top: 4 },
    { input: { create: { width: 1, height: 1, channels: 4, background: "#ffffff" } }, left: 5, top: 5 },
  ]).png().toBuffer();
  const cleaned = await removeIsolatedAlphaPixels(source);
  const { data } = await sharp(cleaned).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  assert.equal(data[(1 * 8 + 1) * 4 + 3], 0);
  assert.equal(data[(4 * 8 + 4) * 4 + 3], 255);
  assert.equal(data[(5 * 8 + 5) * 4 + 3], 255);
});

test("ensambla la hoja, preview y atlas", async () => {
  const transparent = await removeChromaBackground(await createSyntheticFrame(), {
    hex: "#FF00FF",
    rgb: [255, 0, 255],
  });
  const cell = await renderSpriteCell(transparent, { cellSize: 48, paletteColors: 32 });
  const plan = getFramePlan();
  const frames = plan.map((frame) => ({ ...frame, buffer: cell }));
  const sheet = await assembleSpriteSheet(frames, { cellSize: 48, paletteColors: 32 });
  const info = await sharp(sheet).metadata();
  assert.equal(info.width, 192);
  assert.equal(info.height, 4224);
  const preview = await createPixelPreview(sheet, 4);
  const previewInfo = await sharp(preview).metadata();
  assert.equal(previewInfo.width, 768);
  assert.equal(previewInfo.height, 16896);
  const atlas = createAtlasData({ username: "YukiManju", cellSize: 48, frames });
  assert.equal(Object.keys(atlas.frames).length, 352);
  assert.equal(atlas.meta.size.h, 4224);
  assert.equal(atlas.meta.directions.length, 8);
  assert.equal(atlas.frames["down_idle_1.png"].duration, 1000);
  assert.equal(atlas.frames["down_idle_alt_1.png"].duration, 1000);
  assert.deepEqual(atlas.animations.down_idle, [
    "down_idle_1.png",
    "down_idle_2.png",
    "down_idle_3.png",
    "down_idle_4.png",
  ]);
  assert.deepEqual(atlas.animations.down_walk, [
    "down_walk_1.png",
    "down_walk_2.png",
    "down_walk_3.png",
    "down_walk_4.png",
  ]);
  assert.deepEqual(atlas.animations.down_run, [
    "down_run_1.png",
    "down_run_2.png",
    "down_run_3.png",
    "down_run_4.png",
  ]);
  assert.deepEqual(atlas.animations.down_jump, [
    "down_jump_1.png",
    "down_jump_2.png",
    "down_jump_3.png",
    "down_jump_4.png",
  ]);
  assert.deepEqual(atlas.animations.down_fall, [
    "down_fall_1.png",
    "down_fall_2.png",
    "down_fall_3.png",
    "down_fall_4.png",
  ]);
  assert.deepEqual(atlas.animations.down_climb, [
    "down_climb_1.png",
    "down_climb_2.png",
    "down_climb_3.png",
    "down_climb_4.png",
  ]);
  assert.deepEqual(atlas.animations.down_idle_alt, [
    "down_idle_alt_1.png",
    "down_idle_alt_2.png",
    "down_idle_alt_3.png",
    "down_idle_alt_4.png",
  ]);
  assert.deepEqual(atlas.animations.down_swim, [
    "down_swim_1.png",
    "down_swim_2.png",
    "down_swim_3.png",
    "down_swim_4.png",
  ]);
});

test("el atlas conserva cuatro segundos de idle al duplicarlo a 16 frames", () => {
  const plan = getFramePlan({ framesPerAnimation: 8, idleFramesPerAnimation: 16 });
  const frames = plan.map((frame) => ({ ...frame, buffer: Buffer.alloc(0) }));
  const atlas = createAtlasData({ username: "YukiManju", cellSize: 128, frames });
  assert.equal(Object.keys(atlas.frames).length, 896);
  assert.equal(atlas.animations.down_idle.length, 16);
  assert.equal(atlas.animations.down_walk.length, 8);
  assert.equal(atlas.frames["down_idle_1.png"].duration, 250);
  assert.equal(atlas.frames["down_idle_alt_1.png"].duration, 250);
  assert.equal(atlas.meta.size.w, 2048);
  assert.deepEqual(atlas.meta.frameCounts, {
    idle: 16,
    walk: 8,
    run: 8,
    jump: 8,
    fall: 8,
    climb: 8,
    idle_alt: 16,
    swim_idle: 16,
    swim: 8,
    swim_up: 8,
    swim_down: 8,
  });
});

test("elige un chroma distinto cuando el avatar es magenta", async () => {
  const avatar = await sharp({
    create: { width: 32, height: 32, channels: 4, background: { r: 255, g: 0, b: 255, alpha: 1 } },
  }).png().toBuffer();
  const chroma = await chooseChromaColor(avatar);
  assert.notEqual(chroma.hex, "#FF00FF");
});

test("ancla accesorios asimetricos por los pies y no por la caja completa", async () => {
  const asymmetric = await sharp({
    create: { width: 80, height: 80, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } },
  }).composite([
    { input: { create: { width: 36, height: 12, channels: 4, background: "#ffffff" } }, left: 20, top: 10 },
    { input: { create: { width: 14, height: 50, channels: 4, background: "#333333" } }, left: 20, top: 18 },
    { input: { create: { width: 12, height: 8, channels: 4, background: "#ffcc99" } }, left: 21, top: 66 },
  ]).png().toBuffer();
  const cell = await renderSpriteCell(asymmetric, { cellSize: 64, paletteColors: 32 });
  const anchor = await measureSpriteFootAnchor(cell);
  assert.equal(anchor.x, 33);
  assert.equal(anchor.y, 61);
});

test("normaliza dos celdas desplazadas al mismo pivote de pies", async () => {
  const createCell = (left) => sharp({
    create: { width: 64, height: 64, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } },
  }).composite([
    { input: { create: { width: 12, height: 38, channels: 4, background: "#ff3366" } }, left, top: 23 },
  ]).png().toBuffer();
  const [leftCell, rightCell] = await Promise.all([
    alignSpriteCell(await createCell(18), { cellSize: 64, paletteColors: 32 }),
    alignSpriteCell(await createCell(34), { cellSize: 64, paletteColors: 32 }),
  ]);
  const [leftAnchor, rightAnchor] = await Promise.all([
    measureSpriteFootAnchor(leftCell),
    measureSpriteFootAnchor(rightCell),
  ]);
  assert.equal(leftAnchor.x, rightAnchor.x);
  assert.equal(leftAnchor.y, rightAnchor.y);
});

test("estabiliza el torso horizontal contra idle sin borrar la zancada", async () => {
  const createPose = (torsoLeft, forwardLegLeft, backLegLeft) => sharp({
    create: { width: 64, height: 64, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } },
  }).composite([
    { input: { create: { width: 18, height: 26, channels: 4, background: "#663399" } }, left: torsoLeft, top: 15 },
    { input: { create: { width: 6, height: 21, channels: 4, background: "#ffcc99" } }, left: forwardLegLeft, top: 40 },
    { input: { create: { width: 6, height: 21, channels: 4, background: "#cc9966" } }, left: backLegLeft, top: 40 },
  ]).png().toBuffer();

  const idle = await createPose(23, 25, 33);
  const stride = await createPose(30, 20, 40);
  const stabilized = await alignSpriteTorsoToReference(stride, idle, {
    cellSize: 64,
    paletteColors: 32,
  });
  const [idleTorso, stabilizedTorso, strideFeet, stabilizedFeet] = await Promise.all([
    measureSpriteTorsoAnchor(idle),
    measureSpriteTorsoAnchor(stabilized),
    measureSpriteFootAnchor(stride),
    measureSpriteFootAnchor(stabilized),
  ]);

  assert.equal(stabilizedTorso.x, idleTorso.x);
  assert.equal(stabilizedFeet.y, strideFeet.y);
  assert.equal(stabilizedFeet.bounds.right - stabilizedFeet.bounds.left, strideFeet.bounds.right - strideFeet.bounds.left);
});

test("Studio aplica un único encuadre y conserva la elevación interna de la pose", async () => {
  const createRegisteredPose = (legTop, legHeight, withArms = false) => sharp({
    create: { width: 160, height: 140, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } },
  }).composite([
    { input: { create: { width: 24, height: 34, channels: 4, background: "#663399" } }, left: 68, top: 45 },
    { input: { create: { width: 7, height: legHeight, channels: 4, background: "#ffcc99" } }, left: 70, top: legTop },
    { input: { create: { width: 7, height: legHeight, channels: 4, background: "#cc9966" } }, left: 83, top: legTop },
    ...(withArms ? [
      { input: { create: { width: 34, height: 6, channels: 4, background: "#224466" } }, left: 34, top: 51 },
      { input: { create: { width: 34, height: 6, channels: 4, background: "#224466" } }, left: 92, top: 51 },
    ] : []),
  ]).png().toBuffer();
  const idle = await createRegisteredPose(78, 31);
  const airborne = await createRegisteredPose(72, 17, true);
  const options = { cellSize: 64, paletteColors: 32 };
  const transform = await createStudioCellTransform(idle, options);
  const [idleCell, airborneCell] = await Promise.all([
    renderStudioSpriteCell(idle, transform, options),
    renderStudioSpriteCell(airborne, transform, options),
  ]);
  const [idleTorso, airborneTorso, idleFeet, airborneFeet] = await Promise.all([
    measureColorBounds(idleCell, [102, 51, 153]),
    measureColorBounds(airborneCell, [102, 51, 153]),
    measureSpriteFootAnchor(idleCell),
    measureSpriteFootAnchor(airborneCell),
  ]);
  assert.deepEqual(airborneTorso, idleTorso);
  assert.ok(airborneFeet.y < idleFeet.y);
});

async function measureColorBounds(input, color) {
  const { data, info } = await sharp(input).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  const bounds = { left: info.width, right: -1, top: info.height, bottom: -1 };
  for (let y = 0; y < info.height; y += 1) {
    for (let x = 0; x < info.width; x += 1) {
      const offset = (y * info.width + x) * 4;
      if (
        data[offset] !== color[0]
        || data[offset + 1] !== color[1]
        || data[offset + 2] !== color[2]
        || data[offset + 3] < 8
      ) continue;
      bounds.left = Math.min(bounds.left, x);
      bounds.right = Math.max(bounds.right, x);
      bounds.top = Math.min(bounds.top, y);
      bounds.bottom = Math.max(bounds.bottom, y);
    }
  }
  return bounds.right >= bounds.left ? bounds : null;
}
