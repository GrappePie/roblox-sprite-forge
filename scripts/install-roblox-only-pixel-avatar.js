import fs from "node:fs/promises";
import { createHash } from "node:crypto";
import os from "node:os";
import path from "node:path";
import { StudioMcpClient, parseToolPayload } from "../src/lib/studio-mcp.js";
import { decodeGoldenPackage } from "../src/lib/golden-artwork.js";

const root = path.resolve(import.meta.dirname, "..");
const sourceDir = path.join(root, "studio-prototype");
const skipGolden = process.argv.includes("--skip-golden");
const goldenResources = skipGolden ? emptyGoldenResources() : await loadGoldenResources();
const client = new StudioMcpClient({
  baseUrl: "http://127.0.0.1:58741",
  tokenPath: path.join(os.homedir(), ".robloxstudio-mcp", "auth-token"),
  timeoutMs: 90_000,
});

async function deleteIfPresent(instancePath) {
  try {
    await client.callTool("get_instance_properties", { instancePath, excludeSource: true });
  } catch {
    return;
  }
  await client.callTool("delete_object", { instancePath });
}

const playtest = parseToolPayload(await client.callTool("solo_playtest", { action: "status" }));
if (playtest?.running) {
  await client.callTool("solo_playtest", { action: "stop", timeout: 20 });
}

await deleteIfPresent("game.ReplicatedStorage.PixelAvatar");
await deleteIfPresent("game.StarterPlayer.StarterPlayerScripts.PixelAvatarController");
await deleteIfPresent("game.StarterPlayer.StarterPlayerScripts.LivePixelAvatarPOC");

await client.callTool("mass_create_objects", {
  objects: [
    { className: "Folder", parent: "game.ReplicatedStorage", name: "PixelAvatar" },
    {
      className: "ModuleScript",
      parent: "game.ReplicatedStorage.PixelAvatar",
      name: "PixelAvatarConfig",
    },
    {
      className: "ModuleScript",
      parent: "game.ReplicatedStorage.PixelAvatar",
      name: "PixelAvatarUtils",
    },
    {
      className: "ModuleScript",
      parent: "game.ReplicatedStorage.PixelAvatar",
      name: "ThumbnailPixelator",
    },
    {
      className: "ModuleScript",
      parent: "game.ReplicatedStorage.PixelAvatar",
      name: "ProceduralImageFinalizer",
    },
    {
      className: "ModuleScript",
      parent: "game.ReplicatedStorage.PixelAvatar",
      name: "ProceduralRaster",
    },
    {
      className: "ModuleScript",
      parent: "game.ReplicatedStorage.PixelAvatar",
      name: "ProceduralChibiOutfitAnalyzer",
    },
    {
      className: "ModuleScript",
      parent: "game.ReplicatedStorage.PixelAvatar",
      name: "ProceduralChibiBody",
    },
    {
      className: "ModuleScript",
      parent: "game.ReplicatedStorage.PixelAvatar",
      name: "HairColorAnalyzer",
    },
    {
      className: "ModuleScript",
      parent: "game.ReplicatedStorage.PixelAvatar",
      name: "ProceduralChibiFace",
    },
    {
      className: "ModuleScript",
      parent: "game.ReplicatedStorage.PixelAvatar",
      name: "ProceduralChibiHeadAnalyzer",
    },
    {
      className: "ModuleScript",
      parent: "game.ReplicatedStorage.PixelAvatar",
      name: "ProceduralChibiAccessory",
    },
    {
      className: "ModuleScript",
      parent: "game.ReplicatedStorage.PixelAvatar",
      name: "ProceduralChibiAccessoryCompletion",
    },
    {
      className: "ModuleScript",
      parent: "game.ReplicatedStorage.PixelAvatar",
      name: "ProceduralChibiHead",
    },
    {
      className: "ModuleScript",
      parent: "game.ReplicatedStorage.PixelAvatar",
      name: "ProceduralChibiSelfTest",
    },
    {
      className: "ModuleScript",
      parent: "game.ReplicatedStorage.PixelAvatar",
      name: "ProceduralChibiRenderer",
    },
    {
      className: "ModuleScript",
      parent: "game.ReplicatedStorage.PixelAvatar",
      name: "ProceduralFallbackRenderer",
    },
    {
      className: "ModuleScript",
      parent: "game.ReplicatedStorage.PixelAvatar",
      name: "AppearanceFingerprint",
    },
    {
      className: "ModuleScript",
      parent: "game.ReplicatedStorage.PixelAvatar",
      name: "SpritePackage",
    },
    {
      className: "ModuleScript",
      parent: "game.ReplicatedStorage.PixelAvatar",
      name: "SpritePackageCache",
    },
    {
      className: "ModuleScript",
      parent: "game.ReplicatedStorage.PixelAvatar",
      name: "StylizationProvider",
    },
    {
      className: "ModuleScript",
      parent: "game.ReplicatedStorage.PixelAvatar",
      name: "MockStylizationProvider",
    },
    {
      className: "ModuleScript",
      parent: "game.ReplicatedStorage.PixelAvatar",
      name: "GoldenArtworkProvider",
    },
    {
      className: "ModuleScript",
      parent: "game.ReplicatedStorage.PixelAvatar",
      name: "GoldenArtworkRegistry",
    },
    {
      className: "Folder",
      parent: "game.ReplicatedStorage.PixelAvatar",
      name: "GoldenArtworkData",
    },
    {
      className: "ModuleScript",
      parent: "game.ReplicatedStorage.PixelAvatar",
      name: "LayeredSpriteRenderer",
    },
    {
      className: "ModuleScript",
      parent: "game.ReplicatedStorage.PixelAvatar",
      name: "LayeredSpriteRuntime",
    },
    {
      className: "ModuleScript",
      parent: "game.ReplicatedStorage.PixelAvatar",
      name: "LayeredSpriteSelfTest",
    },
    {
      className: "LocalScript",
      parent: "game.StarterPlayer.StarterPlayerScripts",
      name: "PixelAvatarController",
    },
    ...goldenResources.chunks.map((chunk) => ({
      className: "ModuleScript",
      parent: "game.ReplicatedStorage.PixelAvatar.GoldenArtworkData",
      name: chunk.name,
    })),
  ],
});

for (const [instancePath, filename] of [
  ["game.ReplicatedStorage.PixelAvatar.PixelAvatarConfig", "PixelAvatarConfig.lua"],
  ["game.ReplicatedStorage.PixelAvatar.PixelAvatarUtils", "PixelAvatarUtils.lua"],
  ["game.ReplicatedStorage.PixelAvatar.ThumbnailPixelator", "ThumbnailPixelator.lua"],
  [
    "game.ReplicatedStorage.PixelAvatar.ProceduralImageFinalizer",
    "ProceduralImageFinalizer.lua",
  ],
  ["game.ReplicatedStorage.PixelAvatar.ProceduralRaster", "ProceduralRaster.lua"],
  [
    "game.ReplicatedStorage.PixelAvatar.ProceduralChibiOutfitAnalyzer",
    "ProceduralChibiOutfitAnalyzer.lua",
  ],
  [
    "game.ReplicatedStorage.PixelAvatar.ProceduralChibiBody",
    "ProceduralChibiBody.lua",
  ],
  ["game.ReplicatedStorage.PixelAvatar.HairColorAnalyzer", "HairColorAnalyzer.lua"],
  [
    "game.ReplicatedStorage.PixelAvatar.ProceduralChibiFace",
    "ProceduralChibiFace.lua",
  ],
  [
    "game.ReplicatedStorage.PixelAvatar.ProceduralChibiHeadAnalyzer",
    "ProceduralChibiHeadAnalyzer.lua",
  ],
  [
    "game.ReplicatedStorage.PixelAvatar.ProceduralChibiAccessory",
    "ProceduralChibiAccessory.lua",
  ],
  [
    "game.ReplicatedStorage.PixelAvatar.ProceduralChibiAccessoryCompletion",
    "ProceduralChibiAccessoryCompletion.lua",
  ],
  [
    "game.ReplicatedStorage.PixelAvatar.ProceduralChibiHead",
    "ProceduralChibiHead.lua",
  ],
  [
    "game.ReplicatedStorage.PixelAvatar.ProceduralChibiSelfTest",
    "ProceduralChibiSelfTest.lua",
  ],
  [
    "game.ReplicatedStorage.PixelAvatar.ProceduralChibiRenderer",
    "ProceduralChibiRenderer.lua",
  ],
  [
    "game.ReplicatedStorage.PixelAvatar.ProceduralFallbackRenderer",
    "ProceduralFallbackRenderer.lua",
  ],
  [
    "game.ReplicatedStorage.PixelAvatar.AppearanceFingerprint",
    "AppearanceFingerprint.lua",
  ],
  ["game.ReplicatedStorage.PixelAvatar.SpritePackage", "SpritePackage.lua"],
  ["game.ReplicatedStorage.PixelAvatar.SpritePackageCache", "SpritePackageCache.lua"],
  ["game.ReplicatedStorage.PixelAvatar.StylizationProvider", "StylizationProvider.lua"],
  [
    "game.ReplicatedStorage.PixelAvatar.MockStylizationProvider",
    "MockStylizationProvider.lua",
  ],
  [
    "game.ReplicatedStorage.PixelAvatar.GoldenArtworkProvider",
    "GoldenArtworkProvider.lua",
  ],
  [
    "game.ReplicatedStorage.PixelAvatar.LayeredSpriteRenderer",
    "LayeredSpriteRenderer.lua",
  ],
  [
    "game.ReplicatedStorage.PixelAvatar.LayeredSpriteRuntime",
    "LayeredSpriteRuntime.lua",
  ],
  [
    "game.ReplicatedStorage.PixelAvatar.LayeredSpriteSelfTest",
    "LayeredSpriteSelfTest.lua",
  ],
  [
    "game.StarterPlayer.StarterPlayerScripts.PixelAvatarController",
    "PixelAvatarController.client.lua",
  ],
]) {
  await client.callTool("set_script_source", {
    instancePath,
    source: await fs.readFile(path.join(sourceDir, filename), "utf8"),
  });
}

await client.callTool("set_script_source", {
  instancePath: "game.ReplicatedStorage.PixelAvatar.GoldenArtworkRegistry",
  source: goldenResources.registrySource,
});
for (const chunk of goldenResources.chunks) {
  await client.callTool("set_script_source", {
    instancePath: `game.ReplicatedStorage.PixelAvatar.GoldenArtworkData.${chunk.name}`,
    source: `return "${chunk.base64}"`,
  });
}

for (const oldPath of [
  "game.StarterPlayer.StarterPlayerScripts.SpriteForgePixelAvatarClient",
  "game.ServerScriptService.SpriteForgeDynamicAvatarServer",
]) {
  try {
    await client.callTool("set_property", {
      instancePath: oldPath,
      propertyName: "Enabled",
      propertyValue: false,
    });
  } catch {
    // The Roblox-only package does not require the legacy atlas system.
  }
}

const tree = parseToolPayload(
  await client.callTool("get_file_tree", { path: "game.ReplicatedStorage.PixelAvatar" }),
);
console.log(
  JSON.stringify({
    installed: true,
    goldenArtwork: {
      skipped: skipGolden,
      entries: goldenResources.entryCount,
      chunks: goldenResources.chunks.length,
    },
    packageChildren: tree?.tree?.children?.map((child) => child.name) ?? [],
    controller: "game.StarterPlayer.StarterPlayerScripts.PixelAvatarController",
  }),
);

function emptyGoldenResources() {
  return {
    chunks: [],
    entryCount: 0,
    registrySource:
      '--!strict\nreturn table.freeze({ schemaVersion = 1, entries = table.freeze({}) })\n',
  };
}

async function loadGoldenResources() {
  const resultsRoot = path.join(root, "stylization-results");
  let directories;
  try {
    directories = await fs.readdir(resultsRoot, { withFileTypes: true });
  } catch (error) {
    if (error?.code === "ENOENT") return emptyGoldenResources();
    throw error;
  }
  const chunks = [];
  const entrySources = [];
  for (const directory of directories.filter((entry) => entry.isDirectory())) {
    const resultDirectory = path.join(resultsRoot, directory.name);
    const [manifestText, packageBytes] = await Promise.all([
      fs.readFile(path.join(resultDirectory, "package.json"), "utf8"),
      fs.readFile(path.join(resultDirectory, "package.bin")),
    ]);
    const manifest = JSON.parse(manifestText);
    if (manifest.fingerprint !== directory.name) {
      throw new Error(`Golden result directory mismatch for ${directory.name}`);
    }
    const actualPackageHash = createHash("sha256").update(packageBytes).digest("hex");
    if (actualPackageHash !== manifest.packageHash) {
      throw new Error(`Golden package hash mismatch for ${directory.name}`);
    }
    const decoded = decodeGoldenPackage(packageBytes);
    const variantSources = [];
    for (const variantName of ["master", "derived"]) {
      const variant = decoded.variants[variantName];
      const variantManifest = manifest.variants[variantName];
      if (!variant || !variantManifest) {
        throw new Error(`Golden result ${directory.name} lacks ${variantName}`);
      }
      const chunkNames = [];
      for (let offset = 0, index = 0; offset < variant.rgba.length; index += 1) {
        const next = Math.min(variant.rgba.length, offset + 48_000);
        const rawChunk = variant.rgba.subarray(offset, next);
        const name = `Golden_${directory.name}_${variantName}_${String(index + 1).padStart(3, "0")}`;
        chunks.push({ name, base64: rawChunk.toString("base64") });
        chunkNames.push(name);
        offset = next;
      }
      variantSources.push(
        `${variantName} = { width = ${variant.width}, height = ${variant.height}, ` +
        `rgbaHash = ${luaString(variantManifest.rgbaHash)}, ` +
        `chunkNames = { ${chunkNames.map(luaString).join(", ")} } }`,
      );
    }
    entrySources.push(
      `[${luaString(directory.name)}] = { fingerprint = ${luaString(directory.name)}, ` +
      `userId = ${Number(manifest.userId)}, styleVersion = ${luaString(manifest.styleVersion)}, ` +
      `variants = { ${variantSources.join(", ")} } }`,
    );
  }
  return {
    chunks,
    entryCount: entrySources.length,
    registrySource:
      "--!strict\nreturn table.freeze({ schemaVersion = 1, entries = table.freeze({\n" +
      entrySources.join(",\n") +
      "\n}) })\n",
  };
}

function luaString(value) {
  return JSON.stringify(String(value));
}
