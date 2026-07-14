import fs from "node:fs/promises";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { createZip } from "../src/lib/archive.js";
import { harmonizeSpritePalette } from "../src/lib/direction-consistency.js";
import { animateCanonicalCell, hasVerticalBodyContinuity } from "../src/lib/motion.js";
import {
  assembleSpriteSheet,
  createStudioCellTransform,
  createAtlasData,
  createPixelPreview,
  removeChromaBackground,
  renderStudioSpriteCell,
} from "../src/lib/postprocess.js";
import { getFramePlan } from "../src/lib/prompt.js";

const sourceJobId = process.argv[2];
const requestedCellSize = Number(process.argv[3] ?? 128);
if (!sourceJobId) throw new Error("Uso: node scripts/rebuild-studio-references.js <job-id> [cell-size]");
if (![48, 64, 96, 128].includes(requestedCellSize)) throw new Error("El tamaño debe ser 48, 64, 96 o 128.");

const generatedRoot = path.resolve("data", "generated");
const sourceRoot = path.join(generatedRoot, sourceJobId);
const [sourceJob, sourceManifest] = await Promise.all([
  readJson(path.join(sourceRoot, "job.json")),
  readJson(path.join(sourceRoot, "manifest.json")),
]);
const referenceRoot = path.join(sourceRoot, sourceManifest.studioCapture?.referencesDirectory ?? "studio-references");
const referenceFiles = await fs.readdir(referenceRoot);
if (referenceFiles.length < 8) throw new Error("El trabajo no conserva las ocho vistas base de Studio necesarias.");

const jobId = randomUUID();
const root = path.join(generatedRoot, jobId);
const framesRoot = path.join(root, "frames");
const options = {
  ...sourceJob.input,
  cellSize: requestedCellSize,
  renderResolution: Math.max(1024, Number(sourceJob.input.renderResolution ?? 512)),
};
const plan = getFramePlan({ framesPerAnimation: options.framesPerAnimation });
const directions = [...new Set(plan.map((frame) => frame.direction.key))];
const chroma = chromaFromHex(sourceManifest.settings.chroma);
const masters = new Map();
const motionFrames = new Map();
const studioTransforms = new Map();

await fs.mkdir(framesRoot, { recursive: true });
await fs.cp(referenceRoot, path.join(root, "studio-references"), { recursive: true });
for (const name of ["reference.png", "reference-transparent.png"]) {
  await copyIfPresent(path.join(sourceRoot, name), path.join(root, name));
}

for (const direction of directions) {
  const transparent = await removeChromaBackground(
    await fs.readFile(path.join(referenceRoot, `${direction}.png`)),
    chroma,
    { trim: false },
  );
  const transform = await createStudioCellTransform(transparent, options);
  studioTransforms.set(direction, transform);
  masters.set(direction, await renderStudioSpriteCell(transparent, transform, options));
}
for (const frame of plan.filter((candidate) => candidate.clip.key !== "idle")) {
  const referencePath = path.join(referenceRoot, `${frame.key}.png`);
  if (!(await fileExists(referencePath))) continue;
  const transparent = await removeChromaBackground(
    await fs.readFile(referencePath),
    chroma,
    { trim: false },
  );
  const cell = await renderStudioSpriteCell(
    transparent,
    studioTransforms.get(frame.direction.key),
    options,
  );
  if (!(await hasVerticalBodyContinuity(cell))) {
    throw new Error(`La referencia ${frame.key} perdió continuidad al reprocesarla.`);
  }
  motionFrames.set(frame.key, cell);
}

const paletteInputs = new Map();
for (const [direction, buffer] of masters) paletteInputs.set(`master:${direction}`, buffer);
for (const [key, buffer] of motionFrames) paletteInputs.set(`motion:${key}`, buffer);
const harmonized = await harmonizeSpritePalette(paletteInputs, options);
for (const direction of directions) masters.set(direction, harmonized.get(`master:${direction}`));
for (const key of motionFrames.keys()) motionFrames.set(key, harmonized.get(`motion:${key}`));

const completed = [];
for (const frame of plan) {
  const master = masters.get(frame.direction.key);
  const capturedMotion = motionFrames.get(frame.key);
  const buffer = capturedMotion
    ? capturedMotion
    : frame.frameIndex === 1 && frame.clip.key === "idle"
      ? master
      : await animateCanonicalCell(master, frame);
  await fs.writeFile(path.join(framesRoot, `${frame.key}.png`), buffer);
  completed.push({ ...frame, buffer });
}
completed.sort((left, right) => left.row - right.row || left.column - right.column);

const sheet = await assembleSpriteSheet(completed, options);
const preview = await createPixelPreview(sheet, 4);
const atlas = createAtlasData({
  username: sourceJob.avatar.user.username,
  cellSize: options.cellSize,
  frames: completed,
});
const now = new Date().toISOString();
const animations = {};
for (const frame of plan) {
  const key = `${frame.direction.key}_${frame.clip.key}`;
  animations[key] ??= [];
  animations[key].push(frame.key);
}
const manifest = {
  ...sourceManifest,
  generatedAt: now,
  sheet: {
    ...sourceManifest.sheet,
    frameWidth: options.cellSize,
    frameHeight: options.cellSize,
    columns: options.framesPerAnimation,
    rows: Math.max(...plan.map((frame) => frame.row)) + 1,
  },
  animations,
  settings: {
    ...sourceManifest.settings,
    cellSize: options.cellSize,
    renderResolution: options.renderResolution,
  },
  derivedFrom: {
    jobId: sourceJobId,
    mode: "saved-studio-references-high-detail",
  },
  motionAlignment: {
    mode: "fixed-studio-camera-and-shared-direction-transform",
    version: 3,
    directions,
    appliedAt: now,
  },
  studioCapture: {
    ...sourceManifest.studioCapture,
    capturedWalkFrames: [...motionFrames.keys()].filter((key) => key.includes("_walk_")).length,
    capturedRunFrames: [...motionFrames.keys()].filter((key) => key.includes("_run_")).length,
    capturedJumpFrames: [...motionFrames.keys()].filter((key) => key.includes("_jump_")).length,
    capturedFallFrames: [...motionFrames.keys()].filter((key) => key.includes("_fall_")).length,
    capturedClimbFrames: [...motionFrames.keys()].filter((key) => key.includes("_climb_")).length,
    runMotionSource: [...motionFrames.keys()].some((key) => key.includes("_run_"))
      ? "equipped-roblox-animation"
      : "deterministic-fallback",
    jumpMotionSource: [...motionFrames.keys()].some((key) => key.includes("_jump_"))
      ? "equipped-roblox-animation"
      : "deterministic-fallback",
    fallMotionSource: [...motionFrames.keys()].some((key) => key.includes("_fall_"))
      ? "equipped-roblox-animation"
      : "deterministic-fallback",
    climbMotionSource: [...motionFrames.keys()].some((key) => key.includes("_climb_"))
      ? "equipped-roblox-animation"
      : "deterministic-fallback",
  },
};
const result = {
  sheetUrl: `/outputs/${jobId}/sheet.png`,
  previewUrl: `/outputs/${jobId}/preview.png`,
  atlasUrl: `/outputs/${jobId}/sheet.json`,
  manifestUrl: `/outputs/${jobId}/manifest.json`,
  zipUrl: `/outputs/${jobId}/roblox-sprites.zip`,
  framesBaseUrl: `/outputs/${jobId}/frames/`,
  frameSize: options.cellSize,
  sheetWidth: options.cellSize * options.framesPerAnimation,
  sheetHeight: options.cellSize * (Math.max(...plan.map((frame) => frame.row)) + 1),
  frameCount: plan.length,
  directions,
  clips: [...new Set(plan.map((frame) => frame.clip.key))],
  framesPerAnimation: options.framesPerAnimation,
  chroma: chroma.hex,
};
const job = {
  ...sourceJob,
  id: jobId,
  status: "completed",
  createdAt: now,
  updatedAt: now,
  input: options,
  progress: {
    stage: "completed",
    message: `Hoja reprocesada a ${options.cellSize} × ${options.cellSize} desde referencias 3D guardadas.`,
    done: plan.length,
    total: plan.length,
    percent: 100,
    currentFrame: null,
  },
  result,
  error: null,
  cancelRequested: false,
};

await Promise.all([
  fs.writeFile(path.join(root, "sheet.png"), sheet),
  fs.writeFile(path.join(root, "preview.png"), preview),
  fs.writeFile(path.join(root, "sheet.json"), JSON.stringify(atlas, null, 2)),
  fs.writeFile(path.join(root, "manifest.json"), JSON.stringify(manifest, null, 2)),
  fs.writeFile(path.join(root, "job.json"), JSON.stringify(job, null, 2)),
]);
await createZip({ jobDirectory: root, zipPath: path.join(root, "roblox-sprites.zip") });

console.log(JSON.stringify({ jobId, sourceJobId, frameSize: options.cellSize, frameCount: plan.length }, null, 2));

function chromaFromHex(hex) {
  const match = String(hex).match(/^#([0-9a-f]{6})$/i);
  if (!match) throw new Error(`Chroma inválido: ${hex}`);
  const value = Number.parseInt(match[1], 16);
  return {
    hex: `#${match[1].toUpperCase()}`,
    rgb: [(value >> 16) & 255, (value >> 8) & 255, value & 255],
  };
}

async function copyIfPresent(source, destination) {
  try {
    await fs.copyFile(source, destination);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
}

async function fileExists(file) {
  try {
    await fs.access(file);
    return true;
  } catch {
    return false;
  }
}

async function readJson(file) {
  return JSON.parse(await fs.readFile(file, "utf8"));
}
