import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { StudioMcpClient, parseToolPayload } from "../src/lib/studio-mcp.js";

const root = path.resolve(import.meta.dirname, "..");
const sourceDir = path.join(root, "studio-prototype");
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
      name: "ProceduralChibiSelfTest",
    },
    {
      className: "ModuleScript",
      parent: "game.ReplicatedStorage.PixelAvatar",
      name: "ProceduralChibiRenderer",
    },
    {
      className: "LocalScript",
      parent: "game.StarterPlayer.StarterPlayerScripts",
      name: "PixelAvatarController",
    },
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
    "game.ReplicatedStorage.PixelAvatar.ProceduralChibiSelfTest",
    "ProceduralChibiSelfTest.lua",
  ],
  [
    "game.ReplicatedStorage.PixelAvatar.ProceduralChibiRenderer",
    "ProceduralChibiRenderer.lua",
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
    packageChildren: tree?.tree?.children?.map((child) => child.name) ?? [],
    controller: "game.StarterPlayer.StarterPlayerScripts.PixelAvatarController",
  }),
);
