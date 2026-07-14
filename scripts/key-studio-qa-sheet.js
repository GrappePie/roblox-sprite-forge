import path from "node:path";
import sharp from "sharp";
import { removeChromaBackground } from "../src/lib/postprocess.js";

const inputPath = path.resolve(process.argv[2] ?? "data/diagnostics/studio-batch-idle-1021056267.png");
const cellSize = Math.max(16, Math.trunc(Number(process.argv[3])) || 128);
const metadata = await sharp(inputPath).metadata();
if (!metadata.width || !metadata.height || metadata.width % cellSize || metadata.height % cellSize) {
  throw new Error("La hoja QA no coincide con el tamaño de celda indicado.");
}
const columns = metadata.width / cellSize;
const rows = metadata.height / cellSize;
const composites = [];
for (let row = 0; row < rows; row += 1) {
  for (let column = 0; column < columns; column += 1) {
    const raw = await sharp(inputPath)
      .extract({
        left: column * cellSize,
        top: row * cellSize,
        width: cellSize,
        height: cellSize,
      })
      .png()
      .toBuffer();
    composites.push({
      input: await removeChromaBackground(raw, { hex: "#FF00FF", rgb: [255, 0, 255] }, { trim: false }),
      left: column * cellSize,
      top: row * cellSize,
    });
  }
}
const outputPath = inputPath.replace(/\.png$/i, "-keyed.png");
await sharp({
  create: {
    width: metadata.width,
    height: metadata.height,
    channels: 4,
    background: { r: 28, g: 34, b: 43, alpha: 1 },
  },
})
  .composite(composites)
  .png({ compressionLevel: 9 })
  .toFile(outputPath);
console.log(outputPath);
