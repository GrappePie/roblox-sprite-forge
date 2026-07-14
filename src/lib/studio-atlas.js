import fs from "node:fs/promises";
import path from "node:path";
import sharp from "sharp";
import { AppError } from "./errors.js";

const MAX_PALETTE_COLORS = 256;
const LEGACY_CLIPS = Object.freeze(["idle", "walk", "run", "jump", "fall", "climb"]);

export async function createStudioAtlasPayload(sourceDirectory, appearanceFingerprint = null) {
  const manifest = JSON.parse(await fs.readFile(path.join(sourceDirectory, "manifest.json"), "utf8"));
  const sheetPath = path.join(sourceDirectory, manifest.sheet.image ?? "sheet.png");
  const { data, info } = await sharp(sheetPath)
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });

  const frameWidth = Number(manifest.sheet.frameWidth);
  const frameHeight = Number(manifest.sheet.frameHeight);
  const columns = Number(manifest.sheet.columns);
  const rows = Number(manifest.sheet.rows);
  const clips = Array.isArray(manifest.settings?.clips) && manifest.settings.clips.length
    ? manifest.settings.clips.map(String)
    : LEGACY_CLIPS;
  const clipRows = Object.fromEntries(clips.map((clip, index) => [clip, index]));
  const framesPerAnimation = Number(manifest.settings.framesPerAnimation);
  const clipFrameCounts = Object.fromEntries(clips.map((clip) => [
    clip,
    Number(manifest.settings?.frameCounts?.[clip] ?? framesPerAnimation),
  ]));
  if (info.width !== frameWidth * columns || info.height !== frameHeight * rows) {
    throw new AppError(`El atlas ${path.basename(sourceDirectory)} no coincide con su manifest.`, {
      status: 500,
      code: "studio_atlas_dimensions_mismatch",
    });
  }

  const palette = [];
  const paletteLookup = new Map();
  const pixelIndexes = new Uint8Array(info.width * info.height);
  for (let pixel = 0, offset = 0; offset < data.length; pixel += 1, offset += 4) {
    const key = data.readUInt32BE(offset);
    let paletteIndex = paletteLookup.get(key);
    if (paletteIndex === undefined) {
      paletteIndex = palette.length;
      if (paletteIndex >= MAX_PALETTE_COLORS) {
        throw new AppError("El atlas dinámico supera el límite de 256 colores.", {
          status: 500,
          code: "studio_atlas_palette_too_large",
        });
      }
      paletteLookup.set(key, paletteIndex);
      palette.push([data[offset], data[offset + 1], data[offset + 2], data[offset + 3]]);
    }
    pixelIndexes[pixel] = paletteIndex;
  }

  const encoding = palette.length <= 16 ? "rle12" : "rle16x8";
  const chunks = [];
  let packedBytes = 0;
  for (let row = 0; row < rows; row += 1) {
    const start = row * frameHeight * info.width;
    const end = start + frameHeight * info.width;
    const runs = [];
    let cursor = start;
    while (cursor < end) {
      const paletteIndex = pixelIndexes[cursor];
      const maxRun = encoding === "rle12" ? 4095 : 65_535;
      let runLength = 1;
      while (
        cursor + runLength < end
        && pixelIndexes[cursor + runLength] === paletteIndex
        && runLength < maxRun
      ) {
        runLength += 1;
      }
      runs.push({ runLength, paletteIndex });
      cursor += runLength;
    }

    const bytesPerRun = encoding === "rle12" ? 2 : 3;
    const packed = Buffer.allocUnsafe(runs.length * bytesPerRun);
    runs.forEach(({ runLength, paletteIndex }, index) => {
      const offset = index * bytesPerRun;
      if (encoding === "rle12") {
        packed.writeUInt16LE((runLength << 4) | paletteIndex, offset);
      } else {
        packed.writeUInt16LE(runLength, offset);
        packed.writeUInt8(paletteIndex, offset + 2);
      }
    });
    packedBytes += packed.length;
    chunks.push(packed.toString("base64"));
  }

  return {
    metadata: {
      Version: 2,
      UserId: Number(manifest.source.userId),
      Username: String(manifest.source.username),
      JobId: path.basename(sourceDirectory),
      AppearanceFingerprint: appearanceFingerprint,
      Width: info.width,
      Height: info.height,
      FrameWidth: frameWidth,
      FrameHeight: frameHeight,
      Columns: columns,
      Rows: rows,
      FramesPerAnimation: framesPerAnimation,
      ClipFrameCounts: clipFrameCounts,
      IdleFps: clipFrameCounts.idle / 4,
      IdleAltFps: (clipFrameCounts.idle_alt ?? clipFrameCounts.idle) / 4,
      WalkFps: 10,
      RunFps: 14,
      JumpFps: 11,
      FallFps: 11,
      ClimbFps: 10,
      SwimIdleFps: (clipFrameCounts.swim_idle ?? clipFrameCounts.idle) / 4,
      SwimFps: 10,
      SwimEnterSpeedThreshold: 1.25,
      SwimExitSpeedThreshold: 0.7,
      SwimPitchEnterRatio: 0.38,
      SwimPitchExitRatio: 0.22,
      RunSpeedThreshold: 18,
      DirectionRows: {
        down: 0,
        down_left: 1,
        left: 2,
        up_left: 3,
        up: 4,
        up_right: 5,
        right: 6,
        down_right: 7,
      },
      ClipRows: clipRows,
      ClipCount: clips.length,
      Palette: palette,
      Encoding: encoding,
      ChunkHeight: frameHeight,
    },
    chunks,
    stats: { colors: palette.length, chunks: chunks.length, packedBytes },
  };
}
