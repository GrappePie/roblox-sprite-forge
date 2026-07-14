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

const pool = parseToolPayload(await client.callTool("execute_luau", {
  code: `
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")
local Terrain = Workspace.Terrain
local existing = Workspace:FindFirstChild("SpriteForgePixelPool")
if existing then
    local oldCenter = existing:GetAttribute("WaterCenter")
    local oldSize = existing:GetAttribute("WaterSize")
    if typeof(oldCenter) == "Vector3" and typeof(oldSize) == "Vector3" then
        Terrain:FillBlock(CFrame.new(oldCenter), oldSize, Enum.Material.Air)
    end
    existing:Destroy()
end

local spawn = Workspace:FindFirstChildWhichIsA("SpawnLocation", true)
local groundY = spawn and (spawn.Position.Y + spawn.Size.Y / 2) or 0
local waterSize = Vector3.new(28, 8, 26)
local origin = spawn
    and Vector3.new(spawn.Position.X - 20, groundY + waterSize.Y / 2, spawn.Position.Z + 20)
    or Vector3.new(-20, groundY + waterSize.Y / 2, 20)
local model = Instance.new("Model")
model.Name = "SpriteForgePixelPool"
model:SetAttribute("SpriteForgeSwimTest", true)
model:SetAttribute("OpenWater", true)
model:SetAttribute("WaterCenter", origin)
model:SetAttribute("WaterSize", waterSize)
model.Parent = Workspace

local function makePart(name, size, position, color)
    local part = Instance.new("Part")
    part.Name = name
    part.Size = size
    part.CFrame = CFrame.new(position)
    part.Anchored = true
    part.CanCollide = true
    part.CanTouch = true
    part.CanQuery = true
    part.CastShadow = false
    part.Material = Enum.Material.SmoothPlastic
    part.Color = color
    part.TopSurface = Enum.SurfaceType.Smooth
    part.BottomSurface = Enum.SurfaceType.Smooth
    part.Parent = model
    return part
end

local dark = Color3.fromRGB(28, 49, 59)
local tile = Color3.fromRGB(118, 173, 188)
local accent = Color3.fromRGB(126, 229, 255)
makePart(
    "PoolBed",
    Vector3.new(waterSize.X + 2, 0.8, waterSize.Z + 2),
    origin + Vector3.new(0, -waterSize.Y / 2 - 0.4, 0),
    dark
)
local entryX = origin.X + waterSize.X / 2 - 0.9
local entryZ = origin.Z - waterSize.Z / 2 + 1.6
for step = 0, 7 do
    makePart(
        string.format("EntryStep%02d", step + 1),
        Vector3.new(2.2, 0.6, 3.2),
        Vector3.new(
            entryX + step * 1.35,
            origin.Y + waterSize.Y / 2 - 0.3 - step * 0.95,
            entryZ
        ),
        if step % 2 == 0 then accent else tile
    )
end
Terrain:FillBlock(CFrame.new(origin), waterSize, Enum.Material.Water)

local signAnchor = makePart(
    "SignAnchor",
    Vector3.new(0.2, 0.2, 0.2),
    origin + Vector3.new(0, waterSize.Y / 2 + 2, -waterSize.Z / 2 + 1),
    accent
)
signAnchor.Transparency = 1
signAnchor.CanCollide = false
local sign = Instance.new("BillboardGui")
sign.Name = "SwimTestSign"
sign.Adornee = signAnchor
sign.Size = UDim2.fromOffset(270, 58)
sign.AlwaysOnTop = true
sign.Parent = signAnchor
local label = Instance.new("TextLabel")
label.Size = UDim2.fromScale(1, 1)
label.BackgroundColor3 = Color3.fromRGB(6, 20, 28)
label.BackgroundTransparency = 0.08
label.BorderSizePixel = 3
label.BorderColor3 = tile
label.TextColor3 = accent
label.Font = Enum.Font.Code
label.TextScaled = true
label.Text = "OPEN WATER  •  WASD / SPACE / CTRL"
label.Parent = sign

return HttpService:JSONEncode({
    name = model.Name,
    center = { x = origin.X, y = origin.Y, z = origin.Z },
    size = { x = waterSize.X, y = waterSize.Y, z = waterSize.Z },
    openWater = true,
    walls = 0,
    material = "Water",
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
  pool,
  runtimeChildren: tree?.tree?.children?.map((child) => child.name) ?? [],
}));
