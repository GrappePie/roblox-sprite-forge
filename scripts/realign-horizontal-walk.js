import fs from "node:fs/promises";
import path from "node:path";
import sharp from "sharp";
import { createZip } from "../src/lib/archive.js";
import {
  alignSpriteTorsoToReference,
  assembleSpriteSheet,
  createAtlasData,
  createPixelPreview,
  measureSpriteTorsoAnchor,
} from "../src/lib/postprocess.js";
import { getFramePlan } from "../src/lib/prompt.js";

const jobId = process.argv[2];
if (!jobId) throw new Error("Uso: node scripts/realign-horizontal-walk.js <job-id>");

const root = path.resolve("data", "generated", jobId);
const framesDirectory = path.join(root, "frames");
const qaDirectory = path.join(root, "qa-walk-alignment");
const [job, manifest] = await Promise.all([
  readJson(path.join(root, "job.json")),
  readJson(path.join(root, "manifest.json")),
]);
const options = job.input;
const plan = getFramePlan({ framesPerAnimation: options.framesPerAnimation });
const directions = [
  "down",
  "down_left",
  "left",
  "up_left",
  "up",
  "up_right",
  "right",
  "down_right",
];
const before = new Map();
const after = new Map();
const report = {
  mode: "direction-idle-torso-x",
  directions: {},
};

await fs.mkdir(qaDirectory, { recursive: true });
for (const direction of directions) {
  const idle = await fs.readFile(path.join(framesDirectory, `${direction}_idle_1.png`));
  const target = await measureSpriteTorsoAnchor(idle);
  const samples = [];
  for (let index = 1; index <= options.framesPerAnimation; index += 1) {
    const key = `${direction}_walk_${index}`;
    const file = path.join(framesDirectory, `${key}.png`);
    const original = await fs.readFile(file);
    const originalAnchor = await measureSpriteTorsoAnchor(original);
    const stabilized = await alignSpriteTorsoToReference(original, idle, options);
    const stabilizedAnchor = await measureSpriteTorsoAnchor(stabilized);
    before.set(key, original);
    after.set(key, stabilized);
    samples.push({
      frame: index,
      beforeX: originalAnchor?.x ?? null,
      afterX: stabilizedAnchor?.x ?? null,
      targetX: target?.x ?? null,
    });
    await fs.writeFile(file, stabilized);
  }
  report.directions[direction] = {
    targetX: target?.x ?? null,
    beforeRange: range(samples.map((sample) => sample.beforeX)),
    afterRange: range(samples.map((sample) => sample.afterX)),
    samples,
  };
}

const completed = [];
for (const frame of plan) {
  completed.push({
    ...frame,
    buffer: await fs.readFile(path.join(framesDirectory, `${frame.key}.png`)),
  });
}
completed.sort((left, right) => left.row - right.row || left.column - right.column);
const sheet = await assembleSpriteSheet(completed, options);
const preview = await createPixelPreview(sheet, 4);
const atlas = createAtlasData({
  username: manifest.source?.username ?? job.avatar?.username ?? "Roblox",
  cellSize: options.cellSize,
  frames: completed,
});
const rebuiltAt = new Date().toISOString();
manifest.generatedAt = rebuiltAt;
manifest.motionAlignment = {
  mode: report.mode,
  version: 2,
  directions,
  appliedAt: rebuiltAt,
};
job.updatedAt = rebuiltAt;
job.progress = {
  ...job.progress,
  message: "Hoja terminada con torso estabilizado en ocho direcciones.",
};

await Promise.all([
  fs.writeFile(path.join(root, "sheet.png"), sheet),
  fs.writeFile(path.join(root, "preview.png"), preview),
  fs.writeFile(path.join(root, "sheet.json"), JSON.stringify(atlas, null, 2)),
  fs.writeFile(path.join(root, "manifest.json"), JSON.stringify(manifest, null, 2)),
  fs.writeFile(path.join(root, "job.json"), JSON.stringify(job, null, 2)),
  fs.writeFile(path.join(qaDirectory, "report.json"), JSON.stringify(report, null, 2)),
  writeContactSheet(path.join(qaDirectory, "before.png"), before, options),
  writeContactSheet(path.join(qaDirectory, "after.png"), after, options),
]);
await fs.writeFile(
  path.join(qaDirectory, "after-preview.png"),
  await createPixelPreview(await fs.readFile(path.join(qaDirectory, "after.png")), 4),
);
await createZip({
  jobDirectory: root,
  zipPath: path.join(root, "roblox-sprites.zip"),
});

console.log(JSON.stringify(report, null, 2));

async function writeContactSheet(outputPath, frames, { cellSize, framesPerAnimation, paletteColors }) {
  const composites = [];
  for (const [row, direction] of directions.entries()) {
    for (let index = 1; index <= framesPerAnimation; index += 1) {
      composites.push({
        input: frames.get(`${direction}_walk_${index}`),
        left: (index - 1) * cellSize,
        top: row * cellSize,
      });
    }
  }
  const image = await sharp({
    create: {
      width: framesPerAnimation * cellSize,
      height: directions.length * cellSize,
      channels: 4,
      background: { r: 0, g: 0, b: 0, alpha: 0 },
    },
  }).composite(composites).png({ palette: true, colours: paletteColors, dither: 0 }).toBuffer();
  await fs.writeFile(outputPath, image);
}

function range(values) {
  const valid = values.filter(Number.isFinite);
  return valid.length ? Math.max(...valid) - Math.min(...valid) : null;
}

async function readJson(file) {
  return JSON.parse(await fs.readFile(file, "utf8"));
}
