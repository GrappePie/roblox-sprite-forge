import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { config } from "../src/config.js";
import { StudioMcpClient, parseToolPayload } from "../src/lib/studio-mcp.js";

const root = path.resolve(import.meta.dirname, "..");
const generated = path.join(root, "studio-prototype", "generated");
const clientSource = await fs.readFile(
  path.join(root, "studio-prototype", "SpriteForgePixelAvatarClient.lua"),
  "utf8",
);
const serverSource = await fs.readFile(
  path.join(root, "studio-prototype", "SpriteForgeDynamicAvatarServer.lua"),
  "utf8",
);
const build = JSON.parse(await fs.readFile(path.join(generated, "atlas-build.json"), "utf8"));
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

await deleteIfPresent("game.ReplicatedStorage.SpriteForgeRuntime");
await deleteIfPresent("game.StarterPlayer.StarterPlayerScripts.SpriteForgePixelAvatarClient");
await deleteIfPresent("game.ServerScriptService.SpriteForgeDynamicAvatarServer");

await client.callTool("mass_create_objects", {
  objects: [
    { className: "Folder", parent: "game.ReplicatedStorage", name: "SpriteForgeRuntime" },
    {
      className: "ModuleScript",
      parent: "game.ReplicatedStorage.SpriteForgeRuntime",
      name: "AtlasMetadata",
    },
    {
      className: "Folder",
      parent: "game.ReplicatedStorage.SpriteForgeRuntime",
      name: "AtlasChunks",
    },
    {
      className: "RemoteEvent",
      parent: "game.ReplicatedStorage.SpriteForgeRuntime",
      name: "AtlasUpdate",
    },
    ...Array.from({ length: build.chunks }, (_, index) => ({
      className: "ModuleScript",
      parent: "game.ReplicatedStorage.SpriteForgeRuntime.AtlasChunks",
      name: `Row${String(index).padStart(2, "0")}`,
    })),
    {
      className: "LocalScript",
      parent: "game.StarterPlayer.StarterPlayerScripts",
      name: "SpriteForgePixelAvatarClient",
    },
    {
      className: "Script",
      parent: "game.ServerScriptService",
      name: "SpriteForgeDynamicAvatarServer",
    },
  ],
});

await client.callTool("set_script_source", {
  instancePath: "game.ReplicatedStorage.SpriteForgeRuntime.AtlasMetadata",
  source: await fs.readFile(path.join(generated, "AtlasMetadata.lua"), "utf8"),
});
await client.callTool("set_script_source", {
  instancePath: "game.ServerScriptService.SpriteForgeDynamicAvatarServer",
  source: serverSource,
});

for (let index = 0; index < build.chunks; index += 1) {
  const name = `Row${String(index).padStart(2, "0")}`;
  await client.callTool("set_script_source", {
    instancePath: `game.ReplicatedStorage.SpriteForgeRuntime.AtlasChunks.${name}`,
    source: await fs.readFile(path.join(generated, `${name}.lua`), "utf8"),
  });
}

await client.callTool("set_script_source", {
  instancePath: "game.StarterPlayer.StarterPlayerScripts.SpriteForgePixelAvatarClient",
  source: clientSource,
});
await client.callTool("bulk_set_attributes", {
  instancePath: "game.ReplicatedStorage.SpriteForgeRuntime",
  attributes: {
    SourceUserId: build.userId,
    SourceUsername: build.username,
    AtlasWidth: build.width,
    AtlasHeight: build.height,
    PaletteColors: build.colors,
    UseEditableImage: false,
    DynamicAtlas: true,
    DynamicAtlasTransport: "mcp",
    LocalApiUrl: `http://127.0.0.1:${config.port}/api/studio/avatars`,
  },
});
await client.callTool("mass_set_property", {
  paths: [
    "game.StarterPlayer.StarterPlayerScripts.YukiSpriteClient",
    "game.StarterPlayer.StarterPlayerScripts.YukiSpriteStudioClient",
    "game.ServerScriptService.YukiSpriteServer",
    "game.ServerScriptService.YukiSpriteStudioServer",
  ],
  propertyName: "Enabled",
  propertyValue: false,
});

const ladder = parseToolPayload(await client.callTool("execute_luau", {
  code: `
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")
local existing = Workspace:FindFirstChild("SpriteForgePixelLadder")
if existing then existing:Destroy() end

local spawn = Workspace:FindFirstChildWhichIsA("SpawnLocation", true)
local groundY = spawn and (spawn.Position.Y + spawn.Size.Y / 2) or 0
local origin = spawn
    and Vector3.new(spawn.Position.X + 11, groundY, spawn.Position.Z)
    or Vector3.new(11, groundY, 0)
local model = Instance.new("Model")
model.Name = "SpriteForgePixelLadder"
model:SetAttribute("SpriteForgeClimbTest", true)
model.Parent = Workspace

local function makePart(name, size, offset, color, collidable)
    local part = Instance.new("Part")
    part.Name = name
    part.Size = size
    part.CFrame = CFrame.new(origin + offset)
    part.Anchored = true
    part.CanCollide = collidable == true
    part.CanTouch = collidable == true
    part.CanQuery = true
    part.CastShadow = false
    part.Material = Enum.Material.SmoothPlastic
    part.Color = color
    part.TopSurface = Enum.SurfaceType.Smooth
    part.BottomSurface = Enum.SurfaceType.Smooth
    part.Parent = model
    return part
end

local dark = Color3.fromRGB(34, 47, 54)
local metal = Color3.fromRGB(125, 158, 170)
local accent = Color3.fromRGB(217, 255, 97)
makePart("LeftRail", Vector3.new(0.7, 18.5, 0.7), Vector3.new(-2.1, 9.25, 0), metal, false)
makePart("RightRail", Vector3.new(0.7, 18.5, 0.7), Vector3.new(2.1, 9.25, 0), metal, false)
for index = 0, 9 do
    local color = if index % 3 == 0 then accent else dark
    makePart(
        string.format("Rung%02d", index + 1),
        Vector3.new(4.6, 0.48, 0.72),
        Vector3.new(0, 1.1 + index * 1.82, 0),
        color,
        false
    )
end
local surface = Instance.new("TrussPart")
surface.Name = "ClimbSurface"
surface.Size = Vector3.new(4.2, 18, 1)
surface.CFrame = CFrame.new(origin + Vector3.new(0, 9, 0.18))
surface.Anchored = true
surface.CanCollide = true
surface.CanTouch = true
surface.CanQuery = true
surface.Transparency = 1
surface.Parent = model
model.PrimaryPart = surface

makePart("TopPlatform", Vector3.new(7, 0.7, 4), Vector3.new(0, 18.7, 1.5), dark, true)
local signAnchor = makePart("SignAnchor", Vector3.new(0.3, 0.3, 0.3), Vector3.new(0, 20.2, 0), accent, false)
signAnchor.Transparency = 1
local sign = Instance.new("BillboardGui")
sign.Name = "ClimbTestSign"
sign.Adornee = signAnchor
sign.Size = UDim2.fromOffset(220, 54)
sign.AlwaysOnTop = true
sign.StudsOffsetWorldSpace = Vector3.new(0, 0.8, 0)
sign.Parent = signAnchor
local label = Instance.new("TextLabel")
label.Size = UDim2.fromScale(1, 1)
label.BackgroundColor3 = Color3.fromRGB(8, 13, 16)
label.BackgroundTransparency = 0.08
label.BorderSizePixel = 3
label.BorderColor3 = metal
label.TextColor3 = accent
label.Font = Enum.Font.Code
label.TextScaled = true
label.Text = "CLIMB TEST  •  W / S"
label.Parent = sign

return HttpService:JSONEncode({
    name = model.Name,
    position = { x = origin.X, y = origin.Y, z = origin.Z },
    rungs = 10,
    climbSurface = surface:GetFullName(),
})`,
}));

const tree = parseToolPayload(await client.callTool("get_file_tree", {
  path: "game.ReplicatedStorage.SpriteForgeRuntime",
}));

console.log(JSON.stringify({
  installed: true,
  userId: build.userId,
  atlas: `${build.width}x${build.height}`,
  paletteColors: build.colors,
  chunks: build.chunks,
  ladder,
  runtimeChildren: tree?.tree?.children?.map((child) => child.name) ?? [],
}));
