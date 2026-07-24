import { createHash } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import sharp from "sharp";

export const GOLDEN_SCHEMA_VERSION = 1;
export const GOLDEN_STYLE_VERSION = "golden-chibi-v1";
export const MASTER_SIZE = Object.freeze({ width: 256, height: 512 });
export const DERIVED_SIZE = Object.freeze({ width: 128, height: 256 });
export const DERIVED_MAX_COLORS = 48;
export const MAX_IMAGE_BYTES = 16 * 1024 * 1024;

const PNG_SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
const PACKAGE_MAGIC = Buffer.from("GARTPKG1", "ascii");

export async function inspectGoldenArtwork({
  request,
  requestPath,
  imagePath,
  expectedFingerprint,
}) {
  const warnings = [];
  const imageBytes = await fs.readFile(imagePath);
  if (imageBytes.length > MAX_IMAGE_BYTES) {
    throw new Error(`PNG exceeds ${MAX_IMAGE_BYTES} bytes`);
  }
  if (imageBytes.length < PNG_SIGNATURE.length ||
      !imageBytes.subarray(0, PNG_SIGNATURE.length).equals(PNG_SIGNATURE)) {
    throw new Error("Image is not a valid PNG signature");
  }
  if (request.schemaVersion !== GOLDEN_SCHEMA_VERSION) {
    throw new Error(`Unsupported request schemaVersion ${request.schemaVersion}`);
  }
  if (request.styleVersion !== GOLDEN_STYLE_VERSION) {
    throw new Error(`Unsupported styleVersion ${request.styleVersion}`);
  }

  const directoryFingerprint = path.basename(path.dirname(path.resolve(requestPath)));
  const requestedFingerprint = String(request.appearanceFingerprint ?? "");
  const assertedFingerprint = expectedFingerprint ?? directoryFingerprint;
  if (!requestedFingerprint ||
      requestedFingerprint !== assertedFingerprint ||
      directoryFingerprint !== requestedFingerprint) {
    throw new Error(
      `Fingerprint mismatch: request=${requestedFingerprint || "<missing>"} ` +
      `directory=${directoryFingerprint} expected=${assertedFingerprint}`,
    );
  }

  const metadata = await sharp(imageBytes, { failOn: "error" }).metadata();
  if (metadata.format !== "png") throw new Error("Image decoder did not identify a PNG");
  const required = request.requiredArtwork?.master ?? MASTER_SIZE;
  if (metadata.width !== required.width || metadata.height !== required.height) {
    throw new Error(
      `Master dimensions must be ${required.width}x${required.height}; ` +
      `received ${metadata.width}x${metadata.height}`,
    );
  }
  if (metadata.width > MASTER_SIZE.width || metadata.height > MASTER_SIZE.height) {
    throw new Error("Master exceeds the supported 256x512 canvas");
  }
  if (!metadata.hasAlpha || metadata.channels !== 4) {
    throw new Error("Golden artwork must contain an alpha channel");
  }

  const { data: rgba, info } = await sharp(imageBytes)
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  const metrics = analyzeRgba(rgba, info.width, info.height);
  if (metrics.transparentPixels === 0 || metrics.transparentPercent < 0.02) {
    throw new Error("Golden artwork has a completely or effectively opaque background");
  }
  if (!metrics.boundingBox) throw new Error("Golden artwork contains no visible character pixels");
  for (const [side, margin] of Object.entries(metrics.margins)) {
    if (margin < 2) throw new Error(`Character is cropped or lacks transparent ${side} margin`);
  }
  if (metrics.colorCount > 128) {
    warnings.push(
      `Master uses ${metrics.colorCount} RGB colors; retained losslessly as direct RGBA.`,
    );
  }
  if (metrics.partialAlphaPercent > 0.2) {
    warnings.push("More than 20% of the canvas uses partial alpha; inspect chroma-key edges.");
  }

  return {
    imageBytes,
    rgba,
    width: info.width,
    height: info.height,
    metrics,
    warnings,
    contentHash: createHash("sha256").update(imageBytes).digest("hex"),
    rgbaHash: createHash("sha256").update(rgba).digest("hex"),
  };
}

export async function importGoldenArtwork({
  requestPath,
  imagePath,
  resultsRoot,
  expectedFingerprint,
}) {
  const request = JSON.parse(await fs.readFile(requestPath, "utf8"));
  const inspected = await inspectGoldenArtwork({
    request,
    requestPath,
    imagePath,
    expectedFingerprint,
  });
  const fingerprint = request.appearanceFingerprint;
  const outputDirectory = path.join(resultsRoot, fingerprint);

  const { data: resizedRgba } = await sharp(inspected.imageBytes)
    .resize(DERIVED_SIZE.width, DERIVED_SIZE.height, {
      fit: "fill",
      kernel: "lanczos3",
    })
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  const quantizedRgbPng = await sharp(resizedRgba, {
    raw: { ...DERIVED_SIZE, channels: 4 },
  })
    .flatten({ background: { r: 0, g: 0, b: 0 } })
    .png({ palette: true, colours: DERIVED_MAX_COLORS, dither: 0 })
    .toBuffer();
  const quantizedRgb = await sharp(quantizedRgbPng)
    .removeAlpha()
    .raw()
    .toBuffer();
  const derivedRgba = Buffer.alloc(DERIVED_SIZE.width * DERIVED_SIZE.height * 4);
  for (let pixel = 0; pixel < DERIVED_SIZE.width * DERIVED_SIZE.height; pixel += 1) {
    const rgbaOffset = pixel * 4;
    const rgbOffset = pixel * 3;
    derivedRgba[rgbaOffset] = quantizedRgb[rgbOffset];
    derivedRgba[rgbaOffset + 1] = quantizedRgb[rgbOffset + 1];
    derivedRgba[rgbaOffset + 2] = quantizedRgb[rgbOffset + 2];
    derivedRgba[rgbaOffset + 3] = resizedRgba[rgbaOffset + 3];
  }
  const derivedPng = await sharp(derivedRgba, {
    raw: { ...DERIVED_SIZE, channels: 4 },
  }).png({ palette: false }).toBuffer();
  const derivedMetrics = analyzeRgba(
    derivedRgba,
    DERIVED_SIZE.width,
    DERIVED_SIZE.height,
  );
  if (derivedMetrics.colorCount > DERIVED_MAX_COLORS) {
    throw new Error(
      `Derived artwork uses ${derivedMetrics.colorCount} colors; limit is ${DERIVED_MAX_COLORS}`,
    );
  }

  const packageBinary = encodeGoldenPackage([
    {
      name: "master",
      width: inspected.width,
      height: inspected.height,
      rgba: inspected.rgba,
    },
    {
      name: "derived",
      width: DERIVED_SIZE.width,
      height: DERIVED_SIZE.height,
      rgba: derivedRgba,
    },
  ]);
  const packageHash = createHash("sha256").update(packageBinary).digest("hex");
  const packageManifest = {
    schemaVersion: GOLDEN_SCHEMA_VERSION,
    styleVersion: request.styleVersion,
    id: `golden-${fingerprint}`,
    fingerprint,
    userId: request.userId,
    layerName: "CharacterFlat",
    storage: "rgba8",
    anchor: [0.5, 1],
    pivot: [0.5, 1],
    packageHash,
    variants: {
      master: {
        width: inspected.width,
        height: inspected.height,
        colors: inspected.metrics.colorCount,
        rgbaHash: inspected.rgbaHash,
      },
      derived: {
        width: DERIVED_SIZE.width,
        height: DERIVED_SIZE.height,
        colors: derivedMetrics.colorCount,
        rgbaHash: createHash("sha256").update(derivedRgba).digest("hex"),
      },
    },
  };
  const validationReport = {
    valid: true,
    schemaVersion: GOLDEN_SCHEMA_VERSION,
    styleVersion: request.styleVersion,
    fingerprint,
    userId: request.userId,
    dimensions: { width: inspected.width, height: inspected.height },
    colorCount: inspected.metrics.colorCount,
    boundingBox: inspected.metrics.boundingBox,
    transparentPercent: inspected.metrics.transparentPercent,
    partialAlphaPercent: inspected.metrics.partialAlphaPercent,
    margins: inspected.metrics.margins,
    contentHash: inspected.contentHash,
    rgbaHash: inspected.rgbaHash,
    derived: {
      dimensions: { ...DERIVED_SIZE },
      colorCount: derivedMetrics.colorCount,
      boundingBox: derivedMetrics.boundingBox,
      transparentPercent: derivedMetrics.transparentPercent,
      margins: derivedMetrics.margins,
    },
    warnings: inspected.warnings,
  };

  await fs.mkdir(outputDirectory, { recursive: true });
  await Promise.all([
    fs.copyFile(imagePath, path.join(outputDirectory, "canonical.png")),
    fs.writeFile(path.join(outputDirectory, "canonical-128x256.png"), derivedPng),
    fs.writeFile(path.join(outputDirectory, "package.bin"), packageBinary),
    fs.writeFile(
      path.join(outputDirectory, "package.json"),
      `${JSON.stringify(packageManifest, null, 2)}\n`,
    ),
    fs.writeFile(
      path.join(outputDirectory, "validation-report.json"),
      `${JSON.stringify(validationReport, null, 2)}\n`,
    ),
  ]);
  return { outputDirectory, packageManifest, validationReport };
}

export function analyzeRgba(rgba, width, height, alphaThreshold = 8) {
  if (!Buffer.isBuffer(rgba) || rgba.length !== width * height * 4) {
    throw new Error("RGBA buffer length does not match its dimensions");
  }
  let transparentPixels = 0;
  let partialAlphaPixels = 0;
  let minX = width;
  let minY = height;
  let maxX = -1;
  let maxY = -1;
  const colors = new Set();
  const alphaValues = new Set();
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const offset = (y * width + x) * 4;
      const alpha = rgba[offset + 3];
      alphaValues.add(alpha);
      if (alpha === 0) transparentPixels += 1;
      else if (alpha < 255) partialAlphaPixels += 1;
      if (alpha <= alphaThreshold) continue;
      minX = Math.min(minX, x);
      minY = Math.min(minY, y);
      maxX = Math.max(maxX, x);
      maxY = Math.max(maxY, y);
      colors.add(`${rgba[offset]},${rgba[offset + 1]},${rgba[offset + 2]}`);
    }
  }
  const pixelCount = width * height;
  const boundingBox = maxX < minX
    ? null
    : { minX, minY, maxX, maxY, width: maxX - minX + 1, height: maxY - minY + 1 };
  return {
    pixelCount,
    transparentPixels,
    transparentPercent: transparentPixels / pixelCount,
    partialAlphaPixels,
    partialAlphaPercent: partialAlphaPixels / pixelCount,
    colorCount: colors.size,
    alphaValueCount: alphaValues.size,
    boundingBox,
    margins: boundingBox
      ? {
          left: boundingBox.minX,
          top: boundingBox.minY,
          right: width - 1 - boundingBox.maxX,
          bottom: height - 1 - boundingBox.maxY,
        }
      : { left: width, top: height, right: width, bottom: height },
  };
}

export function encodeGoldenPackage(variants) {
  const chunks = [PACKAGE_MAGIC, writeUInt16(GOLDEN_SCHEMA_VERSION), writeUInt16(variants.length)];
  for (const variant of variants) {
    const name = Buffer.from(variant.name, "utf8");
    const rgba = Buffer.from(variant.rgba);
    if (name.length > 255) throw new Error("Variant name is too long");
    if (rgba.length !== variant.width * variant.height * 4) {
      throw new Error(`Variant ${variant.name} has an invalid RGBA length`);
    }
    const header = Buffer.alloc(1 + name.length + 2 + 2 + 4);
    header.writeUInt8(name.length, 0);
    name.copy(header, 1);
    let offset = 1 + name.length;
    header.writeUInt16LE(variant.width, offset);
    offset += 2;
    header.writeUInt16LE(variant.height, offset);
    offset += 2;
    header.writeUInt32LE(rgba.length, offset);
    chunks.push(header, rgba);
  }
  return Buffer.concat(chunks);
}

export function decodeGoldenPackage(bytes) {
  const buffer = Buffer.from(bytes);
  if (buffer.length < 12 || !buffer.subarray(0, 8).equals(PACKAGE_MAGIC)) {
    throw new Error("Invalid golden artwork package magic");
  }
  const schemaVersion = buffer.readUInt16LE(8);
  if (schemaVersion !== GOLDEN_SCHEMA_VERSION) {
    throw new Error(`Unsupported golden package version ${schemaVersion}`);
  }
  const count = buffer.readUInt16LE(10);
  const variants = {};
  let offset = 12;
  for (let index = 0; index < count; index += 1) {
    const nameLength = buffer.readUInt8(offset);
    offset += 1;
    const name = buffer.subarray(offset, offset + nameLength).toString("utf8");
    offset += nameLength;
    const width = buffer.readUInt16LE(offset);
    offset += 2;
    const height = buffer.readUInt16LE(offset);
    offset += 2;
    const byteLength = buffer.readUInt32LE(offset);
    offset += 4;
    const rgba = buffer.subarray(offset, offset + byteLength);
    offset += byteLength;
    if (rgba.length !== width * height * 4) {
      throw new Error(`Corrupt RGBA payload for ${name}`);
    }
    variants[name] = { name, width, height, rgba: Buffer.from(rgba) };
  }
  if (offset !== buffer.length) throw new Error("Golden package contains trailing bytes");
  return { schemaVersion, variants };
}

function writeUInt16(value) {
  const buffer = Buffer.alloc(2);
  buffer.writeUInt16LE(value);
  return buffer;
}
