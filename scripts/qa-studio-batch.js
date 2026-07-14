import fs from "node:fs/promises";
import path from "node:path";
import sharp from "sharp";
import { config, projectRoot } from "../src/config.js";
import { CAPTURE_DIRECTIONS, StudioCaptureService, StudioMcpClient } from "../src/lib/studio-mcp.js";

const userId = Math.max(1, Math.trunc(Number(process.argv[2])) || 1_021_056_267);
const frameCount = 16;
const cellSize = 128;
const client = new StudioMcpClient({
  baseUrl: config.studio.url,
  tokenPath: config.studio.tokenPath,
});
const captureService = new StudioCaptureService({
  client,
  format: "png",
  quality: config.studio.quality,
  batchIdle: true,
});

const startedAt = performance.now();
const capture = await captureService.captureTurntable({
  userId,
  renderResolution: cellSize,
  chroma: { hex: "#FF00FF" },
  framesPerAnimation: 8,
  frameCounts: { idle: frameCount, idle_alt: frameCount },
  clips: ["idle"],
});
const elapsedSeconds = (performance.now() - startedAt) / 1_000;

const rows = [
  ["idle", capture.idleImages],
  ["idle_alt", capture.idleAltImages],
].flatMap(([clip, images]) => images.size
  ? CAPTURE_DIRECTIONS.map(([direction]) => ({ clip, direction, images }))
  : []);
const outputDirectory = path.join(projectRoot, "data", "diagnostics");
await fs.mkdir(outputDirectory, { recursive: true });
const outputPath = path.join(outputDirectory, `studio-batch-idle-${userId}.png`);
const composites = [];
for (let rowIndex = 0; rowIndex < rows.length; rowIndex += 1) {
  const row = rows[rowIndex];
  for (let frameIndex = 1; frameIndex <= frameCount; frameIndex += 1) {
    const input = row.images.get(`${row.direction}_${row.clip}_${frameIndex}`);
    if (!input) continue;
    composites.push({
      input,
      left: (frameIndex - 1) * cellSize,
      top: rowIndex * cellSize,
    });
  }
}
await sharp({
  create: {
    width: frameCount * cellSize,
    height: Math.max(1, rows.length) * cellSize,
    channels: 3,
    background: "#FF00FF",
  },
})
  .composite(composites)
  .png({ compressionLevel: 9 })
  .toFile(outputPath);

console.log(JSON.stringify({
  userId,
  elapsedSeconds: Number(elapsedSeconds.toFixed(2)),
  screenshotCalls: capture.source.screenshotCalls,
  captureMethods: capture.source.captureMethods,
  batchFallbacks: capture.source.batchFallbacks,
  capturedIdleFrames: capture.source.capturedIdleFrames,
  capturedIdleAltFrames: capture.source.capturedIdleAltFrames,
  outputPath,
}, null, 2));
