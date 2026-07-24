import fs from "node:fs/promises";
import path from "node:path";
import {
  downloadRobloxThumbnail,
  getRobloxAvatarBundle,
} from "../../src/lib/roblox.js";
import {
  GOLDEN_SCHEMA_VERSION,
  GOLDEN_STYLE_VERSION,
  MASTER_SIZE,
  DERIVED_SIZE,
  DERIVED_MAX_COLORS,
} from "../../src/lib/golden-artwork.js";

const root = path.resolve(import.meta.dirname, "../..");
const args = parseArgs(process.argv.slice(2));
if (!args["user-id"]) {
  throw new Error("Usage: npm run stylizer:export-request -- --user-id <USER_ID>");
}

const bundle = await getRobloxAvatarBundle(String(args["user-id"]));
const fingerprint = bundle.appearanceFingerprint;
const outputDirectory = path.join(root, "stylization-requests", fingerprint);
await fs.mkdir(outputDirectory, { recursive: true });

const [avatarThumbnail, headshot] = await Promise.all([
  downloadRobloxThumbnail(bundle.thumbnailUrl),
  fetchThumbnail(bundle.user.id, "AvatarHeadShot", "420x420"),
]);
const request = {
  schemaVersion: GOLDEN_SCHEMA_VERSION,
  styleVersion: GOLDEN_STYLE_VERSION,
  userId: bundle.user.id,
  username: bundle.user.username,
  appearanceFingerprint: fingerprint,
  avatarType: bundle.avatar.avatarType,
  assetIds: bundle.avatar.assets.map((asset) => asset.id),
  assets: bundle.avatar.assets,
  bodyColors: bundle.avatar.bodyColors,
  scales: bundle.avatar.scales,
  requiredArtwork: {
    master: { ...MASTER_SIZE, format: "png", alpha: true, maxColors: 128 },
    derived: {
      ...DERIVED_SIZE,
      format: "png",
      alpha: true,
      maxColors: DERIVED_MAX_COLORS,
    },
  },
  expectedResults: ["canonical.png"],
};
const humanoidDescription = {
  source: "Roblox public avatar endpoint",
  userId: bundle.user.id,
  avatarType: bundle.avatar.avatarType,
  assets: bundle.avatar.assets,
  bodyColors: bundle.avatar.bodyColors,
  scales: bundle.avatar.scales,
  note:
    "Roblox does not expose a serialized HumanoidDescription through this Node flow; " +
    "these public fields are the reproducible authoring snapshot.",
};

await Promise.all([
  fs.writeFile(
    path.join(outputDirectory, "request.json"),
    `${JSON.stringify(request, null, 2)}\n`,
  ),
  fs.writeFile(
    path.join(outputDirectory, "humanoid-description.json"),
    `${JSON.stringify(humanoidDescription, null, 2)}\n`,
  ),
  fs.writeFile(path.join(outputDirectory, "avatar-thumbnail.png"), avatarThumbnail.buffer),
  fs.writeFile(path.join(outputDirectory, "headshot.png"), headshot),
  fs.writeFile(path.join(outputDirectory, "ARTWORK_REQUIREMENTS.md"), requirements(fingerprint)),
]);

await copyOptional(args["style-reference"], path.join(outputDirectory, "style-reference.png"));
await copyOptional(args["avatar-reference"], path.join(outputDirectory, "avatar-reference.png"));

console.log(JSON.stringify({
  created: outputDirectory,
  fingerprint,
  userId: bundle.user.id,
  manualInputs: [
    ...(args["style-reference"] ? [] : ["style-reference.png"]),
    ...(args["avatar-reference"] ? [] : ["avatar-reference.png"]),
  ],
}, null, 2));

async function fetchThumbnail(userId, type, size) {
  const endpoint = new URL(`https://thumbnails.roblox.com/v1/users/${type === "AvatarHeadShot" ? "avatar-headshot" : "avatar"}`);
  endpoint.search = new URLSearchParams({
    userIds: String(userId),
    size,
    format: "Png",
    isCircular: "false",
  }).toString();
  for (let attempt = 0; attempt < 7; attempt += 1) {
    const response = await fetch(endpoint, { headers: { accept: "application/json" } });
    if (!response.ok) throw new Error(`Roblox thumbnail request failed: HTTP ${response.status}`);
    const payload = await response.json();
    const item = payload?.data?.[0];
    if (item?.state === "Completed" && item.imageUrl) {
      return (await downloadRobloxThumbnail(item.imageUrl)).buffer;
    }
    await new Promise((resolve) => setTimeout(resolve, 500 + attempt * 250));
  }
  throw new Error(`Roblox did not finish the ${type} thumbnail`);
}

async function copyOptional(source, destination) {
  if (!source) return;
  await fs.copyFile(path.resolve(source), destination);
}

function requirements(fingerprint) {
  return `# Golden Artwork requirements

Request fingerprint: \`${fingerprint}\`

- Produce \`canonical.png\` at exactly 256x512 RGBA.
- Transparent background, full body, front view, neutral pose.
- Preserve hair, colors, ears, headphones, hair ornaments, large right accessory,
  torso star, multicolor sleeves, exposed midriff, skirt and boots.
- Keep transparent margins around hair, accessories, hands and feet.
- Do not add props, scenery, text, shadows or new accessories.
- Do not crop any character part.
- Use the style reference only for art direction; the avatar images define identity.

If automation could not provide \`style-reference.png\` or \`avatar-reference.png\`,
place those files manually in this directory. No Roblox API is invented for those
author-controlled references.
`;
}

function parseArgs(values) {
  const parsed = {};
  for (let index = 0; index < values.length; index += 1) {
    const item = values[index];
    if (!item.startsWith("--")) continue;
    parsed[item.slice(2)] = values[index + 1];
    index += 1;
  }
  return parsed;
}
