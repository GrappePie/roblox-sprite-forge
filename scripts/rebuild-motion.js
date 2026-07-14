import fs from "node:fs/promises";
import path from "node:path";
import { createZip } from "../src/lib/archive.js";
import {
  harmonizeDirectionMasterPalette,
  normalizeDirectionalMasters,
} from "../src/lib/direction-consistency.js";
import { animateCanonicalCell, hasStableMotionTopology } from "../src/lib/motion.js";
import {
  alignSpriteCell,
  assembleSpriteSheet,
  createAtlasData,
  createPixelPreview,
  measureSpriteFootAnchor,
} from "../src/lib/postprocess.js";
import { getFramePlan } from "../src/lib/prompt.js";

const jobId = process.argv[2];
if (!jobId) throw new Error("Uso: node scripts/rebuild-motion.js <job-id>");

const jobDirectory = path.resolve("data", "generated", jobId);
const framesDirectory = path.join(jobDirectory, "frames");
const jobPath = path.join(jobDirectory, "job.json");
const job = JSON.parse(await fs.readFile(jobPath, "utf8"));
const plan = getFramePlan({ framesPerAnimation: job.input.framesPerAnimation });
const directions = [...new Set(plan.map((frame) => frame.direction.key))];
const masters = new Map();
const anchors = {};

for (const direction of directions) {
  const original = await fs.readFile(path.join(framesDirectory, `${direction}_idle_1.png`));
  const aligned = await alignSpriteCell(original, job.input);
  const [before, after] = await Promise.all([
    measureSpriteFootAnchor(original),
    measureSpriteFootAnchor(aligned),
  ]);
  masters.set(direction, aligned);
  anchors[direction] = { before: compactAnchor(before), after: compactAnchor(after) };
}

const normalized = await normalizeDirectionalMasters(masters, job.input);
const harmonized = await harmonizeDirectionMasterPalette(normalized.masters, job.input);
masters.clear();
for (const [direction, master] of harmonized) masters.set(direction, master);

const completedFrames = [];
for (const frame of plan) {
  const master = masters.get(frame.direction.key);
  const isMaster = frame.clip.key === "idle" && frame.frameIndex === 1;
  let buffer = isMaster ? master : await animateCanonicalCell(master, frame);
  if (!isMaster && !(await hasStableMotionTopology(master, buffer))) buffer = Buffer.from(master);
  await fs.writeFile(path.join(framesDirectory, `${frame.key}.png`), buffer);
  completedFrames.push({ ...frame, buffer });
}

completedFrames.sort((left, right) => left.row - right.row || left.column - right.column);
const sheet = await assembleSpriteSheet(completedFrames, job.input);
const preview = await createPixelPreview(sheet, 4);
const atlas = createAtlasData({
  username: job.avatar?.user?.username ?? "unknown",
  cellSize: job.input.cellSize,
  frames: completedFrames,
});
const manifestPath = path.join(jobDirectory, "manifest.json");
const manifest = JSON.parse(await fs.readFile(manifestPath, "utf8"));
const rebuiltAt = new Date().toISOString();
manifest.generatedAt = rebuiltAt;
manifest.alignment = {
  pivot: "median lower-body x + shared ground baseline",
  target: { x: Math.floor(job.input.cellSize / 2) + 1, y: job.input.cellSize - Math.max(2, Math.round(job.input.cellSize * 0.035)) - 1 },
};
manifest.directionConsistency = {
  ...normalized.selection,
  palette: { mode: "shared-master-palette", colors: job.input.paletteColors },
};

await Promise.all([
  fs.writeFile(path.join(jobDirectory, "sheet.png"), sheet),
  fs.writeFile(path.join(jobDirectory, "preview.png"), preview),
  fs.writeFile(path.join(jobDirectory, "sheet.json"), JSON.stringify(atlas, null, 2)),
  fs.writeFile(manifestPath, JSON.stringify(manifest, null, 2)),
]);
await createZip({ jobDirectory, zipPath: path.join(jobDirectory, "roblox-sprites.zip") });

job.updatedAt = rebuiltAt;
job.progress = {
  stage: "completed",
  message: "Hoja terminada con pivote de pies normalizado.",
  done: plan.length,
  total: plan.length,
  percent: 100,
  currentFrame: null,
};
await fs.writeFile(jobPath, JSON.stringify(job, null, 2));

console.log(JSON.stringify({
  jobId,
  frameCount: plan.length,
  anchors,
  directionConsistency: manifest.directionConsistency,
}, null, 2));

function compactAnchor(anchor) {
  return anchor ? { x: anchor.x, y: anchor.y } : null;
}
