import fs from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";
import sharp from "sharp";
import {
  harmonizeDirectionMasterPalette,
  normalizeDirectionalMasters,
} from "../src/lib/direction-consistency.js";
import {
  animateCanonicalCell,
  hasStableMotionTopology,
  hasVerticalBodyContinuity,
} from "../src/lib/motion.js";
import {
  assembleSpriteSheet,
  createPixelPreview,
  measureSpriteTorsoAnchor,
} from "../src/lib/postprocess.js";
import { getFramePlan } from "../src/lib/prompt.js";

const jobId = process.argv[2];
if (!jobId) throw new Error("Uso: node scripts/qa-motion.js <job-id>");

const root = path.resolve("data", "generated", jobId);
const outputDir = path.join(root, "qa-layered-motion");
await fs.mkdir(outputDir, { recursive: true });

const job = JSON.parse(await fs.readFile(path.join(root, "job.json"), "utf8"));
const manifest = JSON.parse(await fs.readFile(path.join(root, "manifest.json"), "utf8"));
const accessoryAware = manifest.studioCapture?.mode === "studio-3d-turntable";
const fixedRegistration = manifest.directionConsistency?.generation?.registrationMode
  === "fixed-studio-camera-and-shared-direction-transform";
const options = job.input;
const plan = getFramePlan({ framesPerAnimation: options.framesPerAnimation });
const expectedClipFrames = 8 * options.framesPerAnimation;
const motionClips = ["walk", "run", "jump", "fall", "climb"];
const usesCaptured = Object.fromEntries(motionClips.map((clip) => [
  clip,
  Number(manifest.studioCapture?.[`captured${clip[0].toUpperCase()}${clip.slice(1)}Frames`]) >= expectedClipFrames,
]));
const masters = new Map();
const completed = [];
const report = {
  stable: true,
  topologyMode: accessoryAware ? "accessory-aware" : "strict",
  registrationMode: fixedRegistration ? "fixed-frame" : "legacy-torso-anchor",
  motionSource: {
    ...Object.fromEntries(motionClips.map((clip) => [
      clip,
      usesCaptured[clip] ? "equipped-roblox-animation" : "deterministic-layering",
    ])),
  },
  rigidCorePixelChanges: 0,
  frames: [],
  directions: {},
  runDirections: {},
  jumpDirections: {},
  fallDirections: {},
  climbDirections: {},
};

for (const direction of [...new Set(plan.map((frame) => frame.direction.key))]) {
  masters.set(direction, await fs.readFile(path.join(root, "frames", `${direction}_idle_1.png`)));
}
if (motionClips.some((clip) => usesCaptured[clip])) {
  report.directionConsistency = manifest.directionConsistency;
} else {
  const normalized = await normalizeDirectionalMasters(masters, options);
  const harmonized = await harmonizeDirectionMasterPalette(normalized.masters, options);
  masters.clear();
  for (const [direction, master] of harmonized) masters.set(direction, master);
  report.directionConsistency = normalized.selection;
}

for (const frame of plan) {
  const master = masters.get(frame.direction.key);
  const usesCapturedMotion = usesCaptured[frame.clip.key] ?? false;
  const buffer = usesCapturedMotion
    ? await fs.readFile(path.join(root, "frames", `${frame.key}.png`))
    : await animateCanonicalCell(master, frame);
  const stable = usesCapturedMotion
    ? await hasVerticalBodyContinuity(buffer)
    : await hasStableMotionTopology(master, buffer, { accessoryAware });
  report.stable &&= stable;
  report.frames.push({ key: frame.key, stable });
  if (frame.clip.key === "walk" || frame.clip.key === "run") {
    report.rigidCorePixelChanges += await countRigidCoreChanges(master, buffer, frame);
  }
  completed.push({ ...frame, buffer });
  await fs.writeFile(path.join(outputDir, `${frame.key}.png`), buffer);
}

const sheet = await assembleSpriteSheet(completed, options);
const preview = await createPixelPreview(sheet, 4);
await fs.writeFile(path.join(outputDir, "sheet.png"), sheet);
await fs.writeFile(path.join(outputDir, "preview.png"), preview);

// Compact clip sheets make visual regressions in each motion easy to inspect.
const walkFrames = completed.filter((frame) => frame.clip.key === "walk");
const walkSheet = await sharp({
  create: {
    width: options.framesPerAnimation * options.cellSize,
    height: 8 * options.cellSize,
    channels: 4,
    background: { r: 0, g: 0, b: 0, alpha: 0 },
  },
}).composite(walkFrames.map((frame) => ({
  input: frame.buffer,
  left: (frame.frameIndex - 1) * options.cellSize,
  top: frame.direction.row * options.cellSize,
}))).png().toBuffer();
await fs.writeFile(path.join(outputDir, "walk-sheet.png"), walkSheet);
await fs.writeFile(path.join(outputDir, "walk-preview.png"), await createPixelPreview(walkSheet, 4));

const runFrames = completed.filter((frame) => frame.clip.key === "run");
const runSheet = await createClipSheet(runFrames, options);
await fs.writeFile(path.join(outputDir, "run-sheet.png"), runSheet);
await fs.writeFile(path.join(outputDir, "run-preview.png"), await createPixelPreview(runSheet, 4));

const jumpFrames = completed.filter((frame) => frame.clip.key === "jump");
const jumpSheet = await createClipSheet(jumpFrames, options);
await fs.writeFile(path.join(outputDir, "jump-sheet.png"), jumpSheet);
await fs.writeFile(path.join(outputDir, "jump-preview.png"), await createPixelPreview(jumpSheet, 4));

const fallFrames = completed.filter((frame) => frame.clip.key === "fall");
const fallSheet = await createClipSheet(fallFrames, options);
await fs.writeFile(path.join(outputDir, "fall-sheet.png"), fallSheet);
await fs.writeFile(path.join(outputDir, "fall-preview.png"), await createPixelPreview(fallSheet, 4));

const climbFrames = completed.filter((frame) => frame.clip.key === "climb");
const climbSheet = await createClipSheet(climbFrames, options);
await fs.writeFile(path.join(outputDir, "climb-sheet.png"), climbSheet);
await fs.writeFile(path.join(outputDir, "climb-preview.png"), await createPixelPreview(climbSheet, 4));

const lowerDiagonalKeys = ["down_left", "down_right"];
const lowerDiagonalFrames = walkFrames.filter((frame) => lowerDiagonalKeys.includes(frame.direction.key));
const lowerDiagonalSheet = await sharp({
  create: {
    width: options.framesPerAnimation * options.cellSize,
    height: lowerDiagonalKeys.length * options.cellSize,
    channels: 4,
    background: { r: 0, g: 0, b: 0, alpha: 0 },
  },
}).composite(lowerDiagonalFrames.map((frame) => ({
  input: frame.buffer,
  left: (frame.frameIndex - 1) * options.cellSize,
  top: lowerDiagonalKeys.indexOf(frame.direction.key) * options.cellSize,
}))).png().toBuffer();
await fs.writeFile(path.join(outputDir, "lower-diagonals.png"), lowerDiagonalSheet);
await fs.writeFile(
  path.join(outputDir, "lower-diagonals-preview.png"),
  await sharp(lowerDiagonalSheet).resize({
    width: options.framesPerAnimation * options.cellSize * 2,
    height: lowerDiagonalKeys.length * options.cellSize * 2,
    kernel: "nearest",
  }).png().toBuffer(),
);

const diagonalKeys = ["down_left", "up_left", "up_right", "down_right"];
const diagonalFrames = walkFrames.filter((frame) => diagonalKeys.includes(frame.direction.key));
const diagonalSheet = await sharp({
  create: {
    width: options.framesPerAnimation * options.cellSize,
    height: diagonalKeys.length * options.cellSize,
    channels: 4,
    background: { r: 0, g: 0, b: 0, alpha: 0 },
  },
}).composite(diagonalFrames.map((frame) => ({
  input: frame.buffer,
  left: (frame.frameIndex - 1) * options.cellSize,
  top: diagonalKeys.indexOf(frame.direction.key) * options.cellSize,
}))).png().toBuffer();
await fs.writeFile(path.join(outputDir, "diagonals.png"), diagonalSheet);
await fs.writeFile(
  path.join(outputDir, "diagonals-preview.png"),
  await sharp(diagonalSheet).resize({
    width: options.framesPerAnimation * options.cellSize * 2,
    height: diagonalKeys.length * options.cellSize * 2,
    kernel: "nearest",
  }).png().toBuffer(),
);

for (const direction of [...new Set(walkFrames.map((frame) => frame.direction.key))]) {
  const cycle = walkFrames.filter((frame) => frame.direction.key === direction);
  const rawFrames = await Promise.all(cycle.map((frame) => sharp(frame.buffer).ensureAlpha().raw().toBuffer()));
  const differences = rawFrames.map((raw, index) => countChangedPixels(raw, rawFrames[(index + 1) % rawFrames.length]));
  report.directions[direction] = {
    uniqueFrames: new Set(rawFrames.map((raw) => crypto.createHash("sha256").update(raw).digest("hex"))).size,
    minimumConsecutivePixelChanges: Math.min(...differences),
    maximumConsecutivePixelChanges: Math.max(...differences),
  };
}
for (const [clip, frames, reportKey] of [
  ["run", runFrames, "runDirections"],
  ["jump", jumpFrames, "jumpDirections"],
  ["fall", fallFrames, "fallDirections"],
  ["climb", climbFrames, "climbDirections"],
]) {
  for (const direction of [...new Set(frames.map((frame) => frame.direction.key))]) {
    const cycle = frames.filter((frame) => frame.direction.key === direction);
    const rawFrames = await Promise.all(cycle.map((frame) => sharp(frame.buffer).ensureAlpha().raw().toBuffer()));
    const differences = rawFrames.map((raw, index) => countChangedPixels(raw, rawFrames[(index + 1) % rawFrames.length]));
    report[reportKey][direction] = {
      uniqueFrames: new Set(rawFrames.map((raw) => crypto.createHash("sha256").update(raw).digest("hex"))).size,
      minimumConsecutivePixelChanges: Math.min(...differences),
      maximumConsecutivePixelChanges: Math.max(...differences),
    };
  }
}
if (motionClips.some((clip) => usesCaptured[clip])) {
  report.torsoAlignment = {};
  const framesByClip = { walk: walkFrames, run: runFrames, jump: jumpFrames, fall: fallFrames, climb: climbFrames };
  for (const clip of motionClips) {
    if (usesCaptured[clip]) {
      report.torsoAlignment[clip] = await measureClipAlignment(
        framesByClip[clip],
        masters,
        report,
        { fixedRegistration },
      );
    }
  }
}
await fs.writeFile(path.join(outputDir, "report.json"), JSON.stringify(report, null, 2));

console.log(JSON.stringify({
  outputDir,
  frameCount: completed.length,
  stable: report.stable,
  rigidCorePixelChanges: report.rigidCorePixelChanges,
  torsoAlignment: report.torsoAlignment,
  directions: report.directions,
  runDirections: report.runDirections,
  jumpDirections: report.jumpDirections,
  fallDirections: report.fallDirections,
  climbDirections: report.climbDirections,
}, null, 2));

async function createClipSheet(frames, frameOptions) {
  return sharp({
    create: {
      width: frameOptions.framesPerAnimation * frameOptions.cellSize,
      height: 8 * frameOptions.cellSize,
      channels: 4,
      background: { r: 0, g: 0, b: 0, alpha: 0 },
    },
  }).composite(frames.map((frame) => ({
    input: frame.buffer,
    left: (frame.frameIndex - 1) * frameOptions.cellSize,
    top: frame.direction.row * frameOptions.cellSize,
  }))).png().toBuffer();
}

async function measureClipAlignment(
  frames,
  directionMasters,
  motionReport,
  { fixedRegistration = false } = {},
) {
  const alignment = {};
  for (const direction of [...new Set(frames.map((frame) => frame.direction.key))]) {
    const target = await measureSpriteTorsoAnchor(directionMasters.get(direction));
    const cycle = frames.filter((frame) => frame.direction.key === direction);
    const measurements = await Promise.all(cycle.map(async (frame) => ({
      anchor: await measureSpriteTorsoAnchor(frame.buffer),
      bounds: await measureOpaqueFrameBounds(frame.buffer),
    })));
    const anchors = measurements.map((measurement) => measurement.anchor);
    const values = anchors.map((anchor) => anchor?.x).filter(Number.isFinite);
    const edgeClearances = measurements
      .map((measurement) => measurement.bounds?.edgeClearance)
      .filter(Number.isFinite);
    const torsoAnchorRange = numericRange(values);
    const maximumIdleDeviation = values.length && target
      ? Math.max(...values.map((value) => Math.abs(value - target.x)))
      : null;
    const stable = fixedRegistration
      ? values.length === cycle.length
        && edgeClearances.length === cycle.length
        && Math.min(...edgeClearances) >= 1
      : torsoAnchorRange !== null
        && torsoAnchorRange <= 1
        && maximumIdleDeviation <= 1;
    motionReport.stable &&= stable;
    alignment[direction] = {
      stable,
      frameRegistration: fixedRegistration ? "shared-direction-transform" : "torso-anchor",
      idleTorsoX: target?.x ?? null,
      torsoAnchorRange,
      maximumIdleDeviation,
      minimumEdgeClearance: edgeClearances.length ? Math.min(...edgeClearances) : null,
      frameTorsoX: values,
    };
  }
  return alignment;
}

async function measureOpaqueFrameBounds(buffer) {
  const { data, info } = await sharp(buffer).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  const bounds = opaqueBounds(data, info.width, info.height);
  if (!bounds) return null;
  return {
    ...bounds,
    edgeClearance: Math.min(
      bounds.left,
      bounds.top,
      info.width - 1 - bounds.right,
      info.height - 1 - bounds.bottom,
    ),
  };
}

async function countRigidCoreChanges(master, animated, frame) {
  const [source, target] = await Promise.all([
    sharp(master).ensureAlpha().raw().toBuffer({ resolveWithObject: true }),
    sharp(animated).ensureAlpha().raw().toBuffer({ resolveWithObject: true }),
  ]);
  const bounds = opaqueBounds(source.data, source.info.width, source.info.height);
  if (!bounds) return 0;
  const spriteHeight = bounds.bottom - bounds.top + 1;
  const spriteWidth = bounds.right - bounds.left + 1;
  const cutY = Math.round(bounds.top + spriteHeight * 0.61);
  const centerX = lowerBodyCenter(source.data, source.info.width, bounds, cutY);
  const shoulderY = Math.round(bounds.top + spriteHeight * 0.43);
  const armBottom = Math.round(bounds.top + spriteHeight * 0.72);
  const armInnerRadius = Math.max(2, spriteHeight * 0.075);
  const armOuterRadius = Math.max(armInnerRadius + 2, Math.min(spriteWidth * 0.48, spriteHeight * 0.22));
  const isSide = frame.direction.key === "left" || frame.direction.key === "right";
  const phase = ((frame.frameIndex - 1) / frame.frameCount) * Math.PI * 2;
  const bob = -Math.round(Math.abs(Math.sin(phase)));
  let changed = 0;
  // Se excluyen cuatro filas de la cadera: son el solape intencional que oculta
  // la unión entre el torso rígido y las piernas móviles.
  for (let y = bounds.top; y <= cutY - 4; y += 1) {
    const targetY = y + bob;
    for (let x = 0; x < source.info.width; x += 1) {
      const distance = Math.abs(x - centerX);
      const armMotionZone = y >= shoulderY - 3 && y <= armBottom + 4
        && distance <= armOuterRadius + 6
        && (isSide || distance >= Math.max(0, armInnerRadius - 2));
      if (armMotionZone) continue;
      const sourceIndex = (y * source.info.width + x) * 4;
      const targetIndex = (targetY * target.info.width + x) * 4;
      const sourceAlpha = source.data[sourceIndex + 3];
      const targetAlpha = target.data[targetIndex + 3];
      if (sourceAlpha < 8 && targetAlpha < 8) continue;
      if (!source.data.subarray(sourceIndex, sourceIndex + 4).equals(target.data.subarray(targetIndex, targetIndex + 4))) changed += 1;
    }
  }
  return changed;
}

function lowerBodyCenter(data, width, bounds, cutY) {
  const spriteHeight = bounds.bottom - bounds.top + 1;
  const lowerBandTop = Math.max(cutY, bounds.bottom - Math.max(3, Math.round(spriteHeight * 0.28)));
  const samples = [];
  for (let y = lowerBandTop; y <= bounds.bottom; y += 1) {
    for (let x = bounds.left; x <= bounds.right; x += 1) {
      if (data[(y * width + x) * 4 + 3] >= 8) samples.push(x);
    }
  }
  if (!samples.length) return (bounds.left + bounds.right) / 2;
  samples.sort((left, right) => left - right);
  const middle = Math.floor(samples.length / 2);
  return samples.length % 2 ? samples[middle] : (samples[middle - 1] + samples[middle]) / 2;
}

function opaqueBounds(data, width, height) {
  const bounds = { left: width, right: -1, top: height, bottom: -1 };
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      if (data[(y * width + x) * 4 + 3] < 8) continue;
      bounds.left = Math.min(bounds.left, x);
      bounds.right = Math.max(bounds.right, x);
      bounds.top = Math.min(bounds.top, y);
      bounds.bottom = Math.max(bounds.bottom, y);
    }
  }
  return bounds.right >= bounds.left ? bounds : null;
}

function countChangedPixels(left, right) {
  let changed = 0;
  for (let index = 0; index < left.length; index += 4) {
    if (!left.subarray(index, index + 4).equals(right.subarray(index, index + 4))) changed += 1;
  }
  return changed;
}

function numericRange(values) {
  return values.length ? Math.max(...values) - Math.min(...values) : null;
}
