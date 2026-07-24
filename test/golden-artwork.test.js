import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import sharp from "sharp";
import {
  DERIVED_MAX_COLORS,
  GOLDEN_SCHEMA_VERSION,
  GOLDEN_STYLE_VERSION,
  MASTER_SIZE,
  decodeGoldenPackage,
  importGoldenArtwork,
  inspectGoldenArtwork,
} from "../src/lib/golden-artwork.js";

const FINGERPRINT = "0123456789abcdef01234567";

test("imports exact RGBA master and creates a <=48-color derived artwork", async (t) => {
  const fixture = await createFixture(t);
  const result = await importGoldenArtwork({
    requestPath: fixture.requestPath,
    imagePath: fixture.imagePath,
    resultsRoot: fixture.resultsRoot,
  });
  assert.equal(result.validationReport.valid, true);
  assert.deepEqual(result.packageManifest.appearance.assetIds, [111, 222]);
  assert.deepEqual(result.validationReport.dimensions, MASTER_SIZE);
  assert.ok(result.validationReport.transparentPercent > 0);
  assert.ok(result.validationReport.margins.left >= 2);
  assert.ok(result.packageManifest.variants.derived.colors <= DERIVED_MAX_COLORS);

  const binary = await fs.readFile(path.join(result.outputDirectory, "package.bin"));
  const decoded = decodeGoldenPackage(binary);
  const sourceRgba = await sharp(fixture.imagePath).ensureAlpha().raw().toBuffer();
  assert.deepEqual(decoded.variants.master.rgba, sourceRgba);
  assert.equal(decoded.variants.master.width, 256);
  assert.equal(decoded.variants.master.height, 512);
  assert.equal(decoded.variants.derived.width, 128);
  assert.equal(decoded.variants.derived.height, 256);
});

test("rejects an invalid PNG signature", async (t) => {
  const fixture = await createFixture(t);
  await fs.writeFile(fixture.imagePath, Buffer.from("not-a-png"));
  await assert.rejects(() => inspectFixture(fixture), /valid PNG signature/);
});

test("rejects incorrect master dimensions", async (t) => {
  const fixture = await createFixture(t, { width: 128, height: 256 });
  await assert.rejects(() => inspectFixture(fixture), /dimensions must be 256x512/);
});

test("rejects a completely opaque background", async (t) => {
  const fixture = await createFixture(t, { opaqueBackground: true });
  await assert.rejects(() => inspectFixture(fixture), /opaque background/);
});

test("rejects artwork cropped against a canvas edge", async (t) => {
  const fixture = await createFixture(t, { touchesEdge: true });
  await assert.rejects(() => inspectFixture(fixture), /cropped|margin/);
});

test("rejects a request-directory fingerprint mismatch", async (t) => {
  const fixture = await createFixture(t);
  const request = JSON.parse(await fs.readFile(fixture.requestPath, "utf8"));
  request.appearanceFingerprint = "ffffffffffffffffffffffff";
  await fs.writeFile(fixture.requestPath, JSON.stringify(request));
  await assert.rejects(() => inspectFixture(fixture), /Fingerprint mismatch/);
});

async function inspectFixture(fixture) {
  const request = JSON.parse(await fs.readFile(fixture.requestPath, "utf8"));
  return inspectGoldenArtwork({
    request,
    requestPath: fixture.requestPath,
    imagePath: fixture.imagePath,
  });
}

async function createFixture(t, options = {}) {
  const temporaryRoot = await fs.mkdtemp(path.join(os.tmpdir(), "golden-artwork-"));
  t.after(() => fs.rm(temporaryRoot, { recursive: true, force: true }));
  const requestDirectory = path.join(temporaryRoot, FINGERPRINT);
  const resultsRoot = path.join(temporaryRoot, "results");
  await fs.mkdir(requestDirectory, { recursive: true });
  const width = options.width ?? 256;
  const height = options.height ?? 512;
  const background = options.opaqueBackground
    ? { r: 25, g: 30, b: 40, alpha: 1 }
    : { r: 0, g: 0, b: 0, alpha: 0 };
  const left = options.touchesEdge ? 0 : Math.max(8, Math.floor(width * 0.2));
  const top = Math.max(8, Math.floor(height * 0.1));
  const characterWidth = Math.max(20, Math.floor(width * 0.6));
  const characterHeight = Math.max(40, Math.floor(height * 0.8));
  const imagePath = path.join(requestDirectory, "canonical.png");
  await sharp({
    create: { width, height, channels: 4, background },
  }).composite([
    {
      input: {
        create: {
          width: Math.min(characterWidth, width - left),
          height: Math.min(characterHeight, height - top),
          channels: 4,
          background: { r: 80, g: 210, b: 120, alpha: 1 },
        },
      },
      left,
      top,
    },
    {
      input: {
        create: {
          width: Math.max(4, Math.floor(characterWidth / 3)),
          height: Math.max(4, Math.floor(characterHeight / 4)),
          channels: 4,
          background: { r: 160, g: 70, b: 210, alpha: 1 },
        },
      },
      left: Math.min(width - 4, left + Math.floor(characterWidth / 3)),
      top: Math.min(height - 4, top + Math.floor(characterHeight / 2)),
    },
  ]).png().toFile(imagePath);
  const requestPath = path.join(requestDirectory, "request.json");
  await fs.writeFile(requestPath, JSON.stringify({
    schemaVersion: GOLDEN_SCHEMA_VERSION,
    styleVersion: GOLDEN_STYLE_VERSION,
    userId: 123,
    assetIds: [222, 111, 222],
    assets: [
      { id: 222, type: "ShirtAccessory" },
      { id: 111, type: "HairAccessory" },
      { id: 333, type: "WalkAnimation" },
    ],
    appearanceFingerprint: FINGERPRINT,
    requiredArtwork: { master: MASTER_SIZE },
  }));
  return { requestPath, imagePath, resultsRoot };
}
