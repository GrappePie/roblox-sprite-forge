import fs from "node:fs/promises";
import sharp from "sharp";
import { AppError } from "./errors.js";

export const CAPTURE_DIRECTIONS = Object.freeze([
  ["down", 0],
  ["down_left", 315],
  ["left", 270],
  ["up_left", 225],
  ["up", 180],
  ["up_right", 135],
  ["right", 90],
  ["down_right", 45],
]);

export class StudioMcpClient {
  constructor({ baseUrl, tokenPath, timeoutMs = 90_000 }) {
    this.baseUrl = String(baseUrl).replace(/\/$/, "");
    this.tokenPath = tokenPath;
    this.timeoutMs = timeoutMs;
    this.nextId = 1;
    this.token = null;
  }

  async diagnose() {
    try {
      const response = await fetch(`${this.baseUrl}/status`, {
        signal: AbortSignal.timeout(5_000),
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const status = await response.json();
      const editInstance = status.instances?.find((instance) => instance.role === "edit")
        ?? status.instances?.[0]
        ?? null;
      return {
        ok: Boolean(status.pluginConnected && editInstance),
        reachable: true,
        pluginConnected: Boolean(status.pluginConnected),
        serverVersion: status.serverVersion ?? null,
        place: editInstance
          ? {
              name: editInstance.placeName ?? editInstance.dataModelName ?? null,
              id: editInstance.placeId ?? null,
              running: Boolean(editInstance.isRunning),
            }
          : null,
      };
    } catch (error) {
      return {
        ok: false,
        reachable: false,
        pluginConnected: false,
        error: error instanceof Error ? error.message : "No se pudo consultar Roblox Studio.",
      };
    }
  }

  async callTool(name, args = {}, signal) {
    const token = await this.readToken();
    const timeoutSignal = AbortSignal.timeout(this.timeoutMs);
    const requestSignal = signal ? AbortSignal.any([timeoutSignal, signal]) : timeoutSignal;
    let response;
    try {
      response = await fetch(`${this.baseUrl}/mcp`, {
        method: "POST",
        headers: {
          Accept: "application/json, text/event-stream",
          "Content-Type": "application/json",
          "X-MCP-Auth": token,
        },
        body: JSON.stringify({
          jsonrpc: "2.0",
          id: this.nextId++,
          method: "tools/call",
          params: { name, arguments: args },
        }),
        signal: requestSignal,
      });
    } catch (error) {
      throw new AppError("No se pudo comunicar con el plugin MCP de Roblox Studio.", {
        status: 502,
        code: "studio_mcp_unreachable",
        cause: error,
      });
    }
    const text = await response.text();
    if (!response.ok) {
      throw new AppError(`Roblox Studio MCP respondió con HTTP ${response.status}.`, {
        status: 502,
        code: "studio_mcp_http_error",
      });
    }
    const envelope = parseMcpResponse(text, response.headers.get("content-type"));
    if (envelope.error) {
      throw new AppError(envelope.error.message ?? `La herramienta ${name} falló.`, {
        status: 502,
        code: "studio_mcp_rpc_error",
        details: envelope.error,
      });
    }
    const result = envelope.result ?? {};
    if (result.isError) {
      throw new AppError(extractToolText(result) || `La herramienta ${name} falló.`, {
        status: 502,
        code: "studio_mcp_tool_error",
      });
    }
    return result;
  }

  async readToken() {
    if (this.token) return this.token;
    try {
      this.token = (await fs.readFile(this.tokenPath, "utf8")).trim();
    } catch (error) {
      throw new AppError("No se encontró el token local del plugin MCP de Roblox Studio.", {
        status: 503,
        code: "studio_mcp_token_missing",
        cause: error,
      });
    }
    if (!this.token) {
      throw new AppError("El token local de Roblox Studio MCP está vacío.", {
        status: 503,
        code: "studio_mcp_token_empty",
      });
    }
    return this.token;
  }
}

export class StudioCaptureService {
  constructor({ client, format = "jpeg", quality = 96, batchIdle = true }) {
    this.client = client;
    this.format = format;
    this.quality = quality;
    this.batchIdle = batchIdle;
    this.active = false;
  }

  diagnose() {
    return this.client.diagnose();
  }

  async captureTurntable({
    userId,
    renderResolution,
    chroma,
    framesPerAnimation = 8,
    frameCounts = {},
    clips = ["idle", "walk", "run", "jump", "fall", "climb"],
    signal,
  }) {
    if (this.active) {
      throw new AppError("Roblox Studio ya está capturando otro avatar.", {
        status: 409,
        code: "studio_capture_busy",
      });
    }
    this.active = true;
    let ownsPlaytest = false;
    try {
      const diagnosis = await this.client.diagnose();
      if (!diagnosis.ok) {
        throw new AppError("Roblox Studio no está conectado al bridge MCP.", {
          status: 503,
          code: "studio_not_connected",
          details: diagnosis,
        });
      }
      const status = parseToolPayload(await this.client.callTool(
        "solo_playtest",
        { action: "status" },
        signal,
      ));
      if (!status?.running) {
        await this.client.callTool("solo_playtest", { action: "start", mode: "play", timeout: 60 }, signal);
        ownsPlaytest = true;
      }
      const rgb = parseHexColor(chroma.hex);
      const setupResult = parseToolPayload(await this.client.callTool(
        "eval_server_runtime",
        { code: buildServerSetupCode(userId, rgb) },
        signal,
      ));
      const animationCatalog = parseNestedJson(setupResult?.result ?? setupResult) ?? {};
      await this.client.callTool(
        "eval_client_runtime",
        { code: buildClientCameraCode() },
        signal,
      );

      let screenshotCalls = 0;
      const takeScreenshot = async () => {
        const screenshot = await this.client.callTool(
          "capture_screenshot",
          this.format === "png"
            ? { format: "png" }
            : { format: "jpeg", quality: this.quality },
          signal,
        );
        screenshotCalls += 1;
        return extractToolImage(screenshot);
      };

      const selectedClips = new Set(clips);
      const images = new Map();
      if (selectedClips.has("idle")) {
        for (const [direction, angle] of CAPTURE_DIRECTIONS) {
          await this.client.callTool(
            "eval_client_runtime",
            { code: buildSetAngleCode(angle) },
            signal,
          );
          const image = await takeScreenshot();
          images.set(direction, await cropStudioViewport(image.buffer, renderResolution));
        }
      }

      const motionImages = {
        idle: new Map(),
        idle_alt: new Map(),
        walk: new Map(),
        run: new Map(),
        jump: new Map(),
        fall: new Map(),
        climb: new Map(),
      };
      const captureMethods = {};
      const batchFallbacks = [];
      const motionDefinitions = [
        { key: "idle", catalogKey: "IdleAnimation", selectionKey: "idle" },
        { key: "idle_alt", catalogKey: "IdleAltAnimation", selectionKey: "idle" },
        { key: "walk", catalogKey: "WalkAnimation" },
        { key: "run", catalogKey: "RunAnimation" },
        { key: "jump", catalogKey: "JumpAnimation" },
        { key: "fall", catalogKey: "FallAnimation" },
        { key: "climb", catalogKey: "ClimbAnimation" },
      ];
      for (const motion of motionDefinitions) {
        if (!selectedClips.has(motion.selectionKey ?? motion.key)) continue;
        if (!animationCatalog.resolvedAnimations?.[motion.catalogKey]) continue;
        try {
          const setupResult = parseToolPayload(await this.client.callTool(
            "eval_server_runtime",
            { code: buildServerMotionSetupCode(motion.key) },
            signal,
          ));
          const setup = parseNestedJson(setupResult?.result ?? setupResult) ?? {};
          if (setup.ready) {
            const requestedFrameCount = frameCounts[motion.key] ?? framesPerAnimation;
            const frameCount = Math.max(2, Math.min(16, Math.trunc(Number(requestedFrameCount)) || 8));
            const canBatch = this.batchIdle && ["idle", "idle_alt"].includes(motion.key);
            let capturedAsBatch = false;
            if (canBatch) {
              try {
                const gridSize = Math.ceil(Math.sqrt(frameCount));
                for (const [direction, angle] of CAPTURE_DIRECTIONS) {
                  let image;
                  try {
                    await this.client.callTool(
                      "eval_client_runtime",
                      { code: buildMotionBatchCode(angle, frameCount, motion.key, gridSize, rgb) },
                      signal,
                    );
                    image = await takeScreenshot();
                  } finally {
                    await this.client.callTool(
                      "eval_client_runtime",
                      { code: buildMotionBatchCleanupCode() },
                      signal,
                    ).catch(() => {});
                  }
                  const frames = await cropStudioContactSheet(
                    image.buffer,
                    renderResolution,
                    frameCount,
                    gridSize,
                  );
                  frames.forEach((frame, index) => {
                    motionImages[motion.key].set(
                      `${direction}_${motion.key}_${index + 1}`,
                      frame,
                    );
                  });
                }
                captureMethods[motion.key] = "world-grid-batch";
                capturedAsBatch = true;
              } catch (error) {
                motionImages[motion.key].clear();
                batchFallbacks.push({
                  clip: motion.key,
                  reason: error instanceof Error ? error.message : String(error),
                });
                console.warn(
                  `[studio-${motion.key}-batch-fallback]`,
                  error instanceof Error ? error.message : error,
                );
              }
            }
            if (!capturedAsBatch) {
              captureMethods[motion.key] = canBatch ? "sequential-fallback" : "sequential";
              for (const [direction, angle] of CAPTURE_DIRECTIONS) {
                for (let frameIndex = 1; frameIndex <= frameCount; frameIndex += 1) {
                  const phase = (frameIndex - 1) / frameCount;
                  await this.client.callTool(
                    "eval_client_runtime",
                    { code: buildSetAngleAndMotionPhaseCode(angle, phase, motion.key) },
                    signal,
                  );
                  const image = await takeScreenshot();
                  motionImages[motion.key].set(
                    `${direction}_${motion.key}_${frameIndex}`,
                    await cropStudioViewport(image.buffer, renderResolution),
                  );
                }
              }
            }
          }
        } catch (error) {
          motionImages[motion.key].clear();
          console.warn(`[studio-${motion.key}-capture-fallback]`, error instanceof Error ? error.message : error);
        }
      }
      const idleImages = motionImages.idle;
      const idleAltImages = motionImages.idle_alt;
      const walkImages = motionImages.walk;
      const runImages = motionImages.run;
      const jumpImages = motionImages.jump;
      const fallImages = motionImages.fall;
      const climbImages = motionImages.climb;
      return {
        images,
        idleImages,
        idleAltImages,
        walkImages,
        runImages,
        jumpImages,
        fallImages,
        climbImages,
        animationCatalog,
        source: {
          mode: "studio-3d-turntable",
          place: diagnosis.place,
          capturedDirections: CAPTURE_DIRECTIONS.map(([key]) => key),
          capturedDirectionFrames: images.size,
          capturedIdleFrames: idleImages.size,
          capturedIdleAltFrames: idleAltImages.size,
          capturedWalkFrames: walkImages.size,
          capturedRunFrames: runImages.size,
          capturedJumpFrames: jumpImages.size,
          capturedFallFrames: fallImages.size,
          capturedClimbFrames: climbImages.size,
          idleMotionSource: idleImages.size ? "equipped-roblox-animation" : "deterministic-fallback",
          idleAltMotionSource: idleAltImages.size ? "equipped-roblox-animation" : "deterministic-fallback",
          walkMotionSource: walkImages.size ? "equipped-roblox-animation" : "deterministic-fallback",
          runMotionSource: runImages.size ? "equipped-roblox-animation" : "deterministic-fallback",
          jumpMotionSource: jumpImages.size ? "equipped-roblox-animation" : "deterministic-fallback",
          fallMotionSource: fallImages.size ? "equipped-roblox-animation" : "deterministic-fallback",
          climbMotionSource: climbImages.size ? "equipped-roblox-animation" : "deterministic-fallback",
          recapturedClips: [...selectedClips],
          captureMethods,
          screenshotCalls,
          batchFallbacks,
        },
      };
    } finally {
      if (ownsPlaytest) {
        await this.client.callTool("solo_playtest", { action: "stop", timeout: 20 }).catch((error) => {
          console.warn("[studio-stop-warning]", error instanceof Error ? error.message : error);
        });
      } else {
        await Promise.all([
          this.client.callTool("eval_client_runtime", { code: buildClientCleanupCode() }).catch(() => {}),
          this.client.callTool("eval_server_runtime", { code: buildServerCleanupCode() }).catch(() => {}),
        ]);
      }
      this.active = false;
    }
  }
}

export function parseMcpResponse(text, contentType = "") {
  if (contentType?.includes("application/json")) return JSON.parse(text);
  const events = String(text).split(/\r?\n\r?\n/);
  for (const event of events) {
    const data = event
      .split(/\r?\n/)
      .filter((line) => line.startsWith("data:"))
      .map((line) => line.slice(5).trim())
      .join("\n");
    if (data) return JSON.parse(data);
  }
  throw new AppError("Roblox Studio MCP devolvió una respuesta SSE inválida.", {
    status: 502,
    code: "studio_mcp_invalid_response",
  });
}

export function extractToolImage(result) {
  const block = result?.content?.find((item) => item?.type === "image" && item?.data);
  if (!block) {
    throw new AppError(extractToolText(result) || "Roblox Studio no devolvió una captura.", {
      status: 502,
      code: "studio_capture_missing_image",
    });
  }
  return {
    buffer: Buffer.from(block.data, "base64"),
    mimeType: block.mimeType ?? "application/octet-stream",
  };
}

export function parseToolPayload(result) {
  const text = extractToolText(result);
  return parseNestedJson(text) ?? text;
}

export async function cropStudioViewport(input, resolution) {
  const metadata = await sharp(input).metadata();
  if (!metadata.width || !metadata.height) {
    throw new AppError("La captura de Studio no tiene dimensiones válidas.", {
      code: "studio_capture_invalid_dimensions",
    });
  }
  const side = Math.min(metadata.width, metadata.height);
  const left = Math.max(0, Math.floor((metadata.width - side) / 2));
  const top = Math.max(0, Math.floor((metadata.height - side) / 2));
  return sharp(input)
    .extract({ left, top, width: side, height: side })
    .resize(resolution, resolution, { fit: "fill", kernel: sharp.kernel.lanczos3 })
    .png({ compressionLevel: 9 })
    .toBuffer();
}

export async function cropStudioContactSheet(input, resolution, frameCount, gridSize) {
  const safeFrameCount = Math.max(1, Math.min(16, Math.trunc(Number(frameCount)) || 1));
  const safeGridSize = Math.max(
    1,
    Math.min(4, Math.trunc(Number(gridSize)) || Math.ceil(Math.sqrt(safeFrameCount))),
  );
  if (safeFrameCount > safeGridSize * safeGridSize) {
    throw new AppError("La cuadrícula de Studio no tiene suficientes celdas.", {
      code: "studio_batch_grid_too_small",
    });
  }
  const metadata = await sharp(input).metadata();
  if (!metadata.width || !metadata.height) {
    throw new AppError("La captura por lotes de Studio no tiene dimensiones válidas.", {
      code: "studio_batch_invalid_dimensions",
    });
  }
  const side = Math.min(metadata.width, metadata.height);
  const sheetLeft = Math.max(0, Math.floor((metadata.width - side) / 2));
  const sheetTop = Math.max(0, Math.floor((metadata.height - side) / 2));
  return Promise.all(Array.from({ length: safeFrameCount }, async (_, index) => {
    const column = index % safeGridSize;
    const row = Math.floor(index / safeGridSize);
    const x0 = Math.round((column * side) / safeGridSize);
    const x1 = Math.round(((column + 1) * side) / safeGridSize);
    const y0 = Math.round((row * side) / safeGridSize);
    const y1 = Math.round(((row + 1) * side) / safeGridSize);
    return sharp(input)
      .extract({
        left: sheetLeft + x0,
        top: sheetTop + y0,
        width: Math.max(1, x1 - x0),
        height: Math.max(1, y1 - y0),
      })
      .resize(resolution, resolution, { fit: "fill", kernel: sharp.kernel.lanczos3 })
      .png({ compressionLevel: 9 })
      .toBuffer();
  }));
}

function extractToolText(result) {
  return result?.content
    ?.filter((item) => item?.type === "text" && typeof item.text === "string")
    .map((item) => item.text)
    .join("\n")
    .trim() ?? "";
}

function parseNestedJson(value) {
  let current = value;
  for (let index = 0; index < 3 && typeof current === "string"; index += 1) {
    try {
      current = JSON.parse(current);
    } catch {
      break;
    }
  }
  return current;
}

function parseHexColor(hex) {
  const match = /^#([0-9A-F]{6})$/i.exec(String(hex));
  if (!match) return { r: 255, g: 0, b: 255 };
  return {
    r: Number.parseInt(match[1].slice(0, 2), 16),
    g: Number.parseInt(match[1].slice(2, 4), 16),
    b: Number.parseInt(match[1].slice(4, 6), 16),
  };
}

function buildServerSetupCode(userId, rgb) {
  const safeUserId = Math.max(1, Math.trunc(Number(userId)));
  return `
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")
local Lighting = game:GetService("Lighting")
local InsertService = game:GetService("InsertService")

for _, trackName in ipairs({"SpriteForgeCaptureIdleTrack", "SpriteForgeCaptureIdleAltTrack", "SpriteForgeCaptureWalkTrack", "SpriteForgeCaptureRunTrack", "SpriteForgeCaptureJumpTrack", "SpriteForgeCaptureFallTrack", "SpriteForgeCaptureClimbTrack"}) do
    local track = _G[trackName]
    if track then pcall(function() track:Stop(0) end) end
    _G[trackName] = nil
end

for _, name in ipairs({"SpriteForgeCaptureRig", "SpriteForgeBackdrop"}) do
    local existing = Workspace:FindFirstChild(name)
    if existing then existing:Destroy() end
end

local description = Players:GetHumanoidDescriptionFromUserIdAsync(${safeUserId})
local rig = Players:CreateHumanoidModelFromUserIdAsync(${safeUserId})
rig.Name = "SpriteForgeCaptureRig"
rig.Parent = Workspace
local humanoid = rig:FindFirstChildOfClass("Humanoid")
if humanoid then
    humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
    humanoid.NameDisplayDistance = 0
    humanoid.HealthDisplayDistance = 0
end
for _, item in ipairs(rig:GetDescendants()) do
    if item:IsA("BasePart") then
        item.CanCollide = false
        item.CanTouch = false
        item.CanQuery = false
        item.CastShadow = false
    elseif item:IsA("ParticleEmitter") or item:IsA("Trail") or item:IsA("Beam") then
        item.Enabled = false
    end
end
local root = rig:FindFirstChild("HumanoidRootPart")
if root then root.Anchored = true end
rig:PivotTo(CFrame.new(0, 1000, 0) * CFrame.Angles(0, 0, 0))

local backdrop = Instance.new("Folder")
backdrop.Name = "SpriteForgeBackdrop"
backdrop.Parent = Workspace
backdrop:SetAttribute("PreviousAmbient", Lighting.Ambient)
backdrop:SetAttribute("PreviousOutdoorAmbient", Lighting.OutdoorAmbient)
backdrop:SetAttribute("PreviousBrightness", Lighting.Brightness)
backdrop:SetAttribute("PreviousExposure", Lighting.ExposureCompensation)
backdrop:SetAttribute("PreviousDiffuse", Lighting.EnvironmentDiffuseScale)
backdrop:SetAttribute("PreviousSpecular", Lighting.EnvironmentSpecularScale)
backdrop:SetAttribute("PreviousGlobalShadows", Lighting.GlobalShadows)
backdrop:SetAttribute("PreviousClockTime", Lighting.ClockTime)

Lighting.Ambient = Color3.fromRGB(170, 170, 170)
Lighting.OutdoorAmbient = Color3.fromRGB(170, 170, 170)
Lighting.Brightness = 2
Lighting.ExposureCompensation = 0
Lighting.EnvironmentDiffuseScale = 0
Lighting.EnvironmentSpecularScale = 0
Lighting.GlobalShadows = false
Lighting.ClockTime = 12
for _, effect in ipairs(Lighting:GetChildren()) do
    if effect:IsA("PostEffect") then
        effect:SetAttribute("SpriteForgeCaptureWasEnabled", effect.Enabled)
        effect.Enabled = false
    end
end

local function makeWall(name, size, position)
    local wall = Instance.new("Part")
    wall.Name = name
    wall.Size = size
    wall.CFrame = CFrame.new(position)
    wall.Anchored = true
    wall.CanCollide = false
    wall.CanTouch = false
    wall.CanQuery = false
    wall.CastShadow = false
    wall.Material = Enum.Material.SmoothPlastic
    wall.Reflectance = 0
    wall.Color = Color3.fromRGB(${rgb.r}, ${rgb.g}, ${rgb.b})
    wall.Parent = backdrop
end
makeWall("Front", Vector3.new(300, 300, 1), Vector3.new(0, 1000, -100))
makeWall("Back", Vector3.new(300, 300, 1), Vector3.new(0, 1000, 100))
makeWall("Left", Vector3.new(1, 300, 300), Vector3.new(-100, 1000, 0))
makeWall("Right", Vector3.new(1, 300, 300), Vector3.new(100, 1000, 0))
makeWall("Ceiling", Vector3.new(300, 1, 300), Vector3.new(0, 1100, 0))
makeWall("Floor", Vector3.new(300, 1, 300), Vector3.new(0, 900, 0))

local animations = {}
for _, property in ipairs({"IdleAnimation", "WalkAnimation", "RunAnimation", "JumpAnimation", "FallAnimation", "ClimbAnimation", "SwimAnimation", "MoodAnimation"}) do
    animations[property] = tostring(description[property] or 0)
end
local function resolveAnimationId(assetId, preferredName)
    local numericId = tonumber(assetId)
    if not numericId or numericId <= 0 then return nil end
    local ok, container = pcall(function()
        return InsertService:LoadAsset(numericId)
    end)
    if not ok or not container then return nil end
    local selected = nil
    for _, item in ipairs(container:GetDescendants()) do
        if item:IsA("Animation") and (not selected or item.Name == preferredName) then
            selected = item
            if item.Name == preferredName then break end
        end
    end
    local animationId = selected and selected.AnimationId or nil
    container:Destroy()
    return animationId
end
local function resolveIdleAnimationIds(assetId)
    local numericId = tonumber(assetId)
    if not numericId or numericId <= 0 then return nil, nil end
    local ok, container = pcall(function()
        return InsertService:LoadAsset(numericId)
    end)
    if not ok or not container then return nil, nil end
    local candidates = {}
    local primary = nil
    local alternate = nil
    for _, item in ipairs(container:GetDescendants()) do
        if item:IsA("Animation") then
            local itemName = string.lower(item.Name)
            local parentName = item.Parent and string.lower(item.Parent.Name) or ""
            if parentName == "idle" or itemName == "animation1" or itemName == "animation2" then
                table.insert(candidates, item.AnimationId)
                if itemName == "animation1" then primary = item.AnimationId end
                if itemName == "animation2" then alternate = item.AnimationId end
            end
        end
    end
    primary = primary or candidates[1]
    alternate = alternate or candidates[2]
    container:Destroy()
    return primary, alternate
end
local resolvedIdle, resolvedIdleAlt = resolveIdleAnimationIds(description.IdleAnimation)
local resolvedAnimations = {
    IdleAnimation = resolvedIdle,
    IdleAltAnimation = resolvedIdleAlt,
    WalkAnimation = resolveAnimationId(description.WalkAnimation, "WalkAnim"),
    RunAnimation = resolveAnimationId(description.RunAnimation, "RunAnim"),
    JumpAnimation = resolveAnimationId(description.JumpAnimation, "JumpAnim"),
    FallAnimation = resolveAnimationId(description.FallAnimation, "FallAnim"),
    ClimbAnimation = resolveAnimationId(description.ClimbAnimation, "ClimbAnim"),
}
if resolvedAnimations.IdleAnimation then
    rig:SetAttribute("SpriteForgeIdleAnimationId", resolvedAnimations.IdleAnimation)
end
if resolvedAnimations.IdleAltAnimation then
    rig:SetAttribute("SpriteForgeIdleAltAnimationId", resolvedAnimations.IdleAltAnimation)
end
if resolvedAnimations.WalkAnimation then
    rig:SetAttribute("SpriteForgeWalkAnimationId", resolvedAnimations.WalkAnimation)
end
if resolvedAnimations.RunAnimation then
    rig:SetAttribute("SpriteForgeRunAnimationId", resolvedAnimations.RunAnimation)
end
if resolvedAnimations.JumpAnimation then
    rig:SetAttribute("SpriteForgeJumpAnimationId", resolvedAnimations.JumpAnimation)
end
if resolvedAnimations.FallAnimation then
    rig:SetAttribute("SpriteForgeFallAnimationId", resolvedAnimations.FallAnimation)
end
if resolvedAnimations.ClimbAnimation then
    rig:SetAttribute("SpriteForgeClimbAnimationId", resolvedAnimations.ClimbAnimation)
end
local emotes = {}
pcall(function()
    emotes = description:GetEmotes()
end)
return HttpService:JSONEncode({
    userId = "${safeUserId}",
    rigType = humanoid and humanoid.RigType.Name or "Unknown",
    animations = animations,
    resolvedAnimations = resolvedAnimations,
    emotes = emotes,
})`;
}

function buildClientCameraCode() {
  return `
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
_G.SpriteForgeCaptureAngle = 0
_G.SpriteForgeCaptureFieldOfView = 30
RunService:UnbindFromRenderStep("SpriteForgeCaptureCamera")
local initialCamera = Workspace.CurrentCamera
local rig = Workspace:FindFirstChild("SpriteForgeCaptureRig")
assert(rig, "SpriteForge capture rig is missing")
local initialBounds, initialSize = rig:GetBoundingBox()
-- La cámara se calibra una sola vez con idle. Si se recalcula con cada pose,
-- Roblox vuelve a centrar y escalar el encuadre durante el salto y la caída,
-- haciendo que el sprite parezca desplazarse aunque la raíz esté fija.
_G.SpriteForgeCaptureTarget = initialBounds.Position
_G.SpriteForgeCaptureDistance = math.max(initialSize.X, initialSize.Y, initialSize.Z) * 4.4
if initialCamera and not _G.SpriteForgeCapturePreviousCamera then
    _G.SpriteForgeCapturePreviousCamera = {
        CameraType = initialCamera.CameraType,
        CameraSubject = initialCamera.CameraSubject,
        FieldOfView = initialCamera.FieldOfView,
        CFrame = initialCamera.CFrame,
    }
end
RunService:BindToRenderStep("SpriteForgeCaptureCamera", Enum.RenderPriority.Camera.Value + 100, function()
    local camera = Workspace.CurrentCamera
    local rig = Workspace:FindFirstChild("SpriteForgeCaptureRig")
    local backdrop = Workspace:FindFirstChild("SpriteForgeBackdrop")
    if not camera or not rig or not backdrop then return end
    local target = _G.SpriteForgeCaptureTarget
    local radians = math.rad(_G.SpriteForgeCaptureAngle or 0)
    local radial = Vector3.new(math.sin(radians), 0, -math.cos(radians))
    local distance = _G.SpriteForgeCaptureDistance
    camera.CameraType = Enum.CameraType.Scriptable
    camera.FieldOfView = _G.SpriteForgeCaptureFieldOfView or 30
    camera.CFrame = CFrame.lookAt(target + radial * distance, target)
end)
RunService.RenderStepped:Wait()
RunService.RenderStepped:Wait()
return true`;
}

function buildServerMotionSetupCode(clipKey) {
  const motion = getMotionDefinition(clipKey);
  return `
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")
local rig = Workspace:FindFirstChild("SpriteForgeCaptureRig")
local humanoid = rig and rig:FindFirstChildOfClass("Humanoid")
local animationId = rig and rig:GetAttribute("SpriteForge${motion.title}AnimationId")
if not rig or not humanoid or typeof(animationId) ~= "string" or animationId == "" then
    return HttpService:JSONEncode({ready = false, reason = "${motion.lower}_animation_missing"})
end
for _, trackName in ipairs({"SpriteForgeCaptureIdleTrack", "SpriteForgeCaptureIdleAltTrack", "SpriteForgeCaptureWalkTrack", "SpriteForgeCaptureRunTrack", "SpriteForgeCaptureJumpTrack", "SpriteForgeCaptureFallTrack", "SpriteForgeCaptureClimbTrack"}) do
    local oldTrack = _G[trackName]
    if oldTrack then pcall(function() oldTrack:Stop(0) end) end
    _G[trackName] = nil
end
local animator = humanoid:FindFirstChildOfClass("Animator")
if not animator then
    animator = Instance.new("Animator")
    animator.Parent = humanoid
end
local animation = Instance.new("Animation")
animation.Name = "SpriteForgeResolved${motion.title}"
animation.AnimationId = animationId
animation.Parent = rig
local ok, track = pcall(function()
    return animator:LoadAnimation(animation)
end)
if not ok or not track then
    animation:Destroy()
    return HttpService:JSONEncode({ready = false, reason = "${motion.lower}_animation_load_failed"})
end
track.Looped = ${motion.looped ? "true" : "false"}
track:Play(0, 1, 1)
local deadline = os.clock() + 8
while track.Length <= 0 and os.clock() < deadline do task.wait(0.1) end
if track.Length <= 0 then
    track:Stop(0)
    animation:Destroy()
    return HttpService:JSONEncode({ready = false, reason = "${motion.lower}_animation_empty"})
end
track.TimePosition = 0
track:AdjustSpeed(0)
_G.SpriteForgeCapture${motion.title}Track = track
task.wait(0.15)
return HttpService:JSONEncode({
    ready = true,
    animationId = animationId,
    length = track.Length,
})`;
}

function buildSetAngleAndMotionPhaseCode(angle, phase, clipKey) {
  const safePhase = Math.max(0, Math.min(0.999_999, Number(phase) || 0));
  const motion = getMotionDefinition(clipKey);
  return `
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
_G.SpriteForgeCaptureAngle = ${Number(angle)}
local rig = Workspace:FindFirstChild("SpriteForgeCaptureRig")
local humanoid = rig and rig:FindFirstChildOfClass("Humanoid")
local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
local expectedId = rig and rig:GetAttribute("SpriteForge${motion.title}AnimationId")
local track = _G.SpriteForgeCapture${motion.title}Track
if (not track or track.Length <= 0) and animator then
    for _, candidate in ipairs(animator:GetPlayingAnimationTracks()) do
        if candidate.Length > 0 and candidate.Animation and candidate.Animation.AnimationId == expectedId then
            track = candidate
            break
        end
    end
end
if not track or track.Length <= 0 then return false end
track:AdjustSpeed(0)
track.TimePosition = math.min(track.Length * ${safePhase}, math.max(0, track.Length - 1 / 240))
_G.SpriteForgeCapture${motion.title}Track = track
RunService.RenderStepped:Wait()
RunService.RenderStepped:Wait()
RunService.RenderStepped:Wait()
return true`;
}

function buildMotionBatchCode(angle, frameCount, clipKey, gridSize, rgb) {
  const safeFrameCount = Math.max(2, Math.min(16, Math.trunc(Number(frameCount)) || 8));
  const safeGridSize = Math.max(2, Math.min(4, Math.trunc(Number(gridSize)) || 4));
  const motion = getMotionDefinition(clipKey);
  return `
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local rig = Workspace:FindFirstChild("SpriteForgeCaptureRig")
local humanoid = rig and rig:FindFirstChildOfClass("Humanoid")
local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
local expectedId = rig and rig:GetAttribute("SpriteForge${motion.title}AnimationId")
local track = _G.SpriteForgeCapture${motion.title}Track
if (not track or track.Length <= 0) and animator then
    for _, candidate in ipairs(animator:GetPlayingAnimationTracks()) do
        if candidate.Length > 0 and candidate.Animation and candidate.Animation.AnimationId == expectedId then
            track = candidate
            break
        end
    end
end
assert(rig and track and track.Length > 0, "Sprite Forge batch animation is unavailable")
local previous = Workspace:FindFirstChild("SpriteForgeBatchCapture")
if previous then previous:Destroy() end
local folder = Instance.new("Folder")
folder.Name = "SpriteForgeBatchCapture"
folder.Parent = Workspace
local angle = ${Number(angle)}
local gridSize = ${safeGridSize}
local baseTarget = _G.SpriteForgeCaptureTarget
local distance = _G.SpriteForgeCaptureDistance
assert(typeof(baseTarget) == "Vector3" and typeof(distance) == "number", "Sprite Forge camera is not calibrated")
local radians = math.rad(angle)
local radial = Vector3.new(math.sin(radians), 0, -math.cos(radians))
local cameraFrame = CFrame.lookAt(baseTarget + radial * distance, baseTarget)
local screenRight = cameraFrame.RightVector
local screenUp = cameraFrame.UpVector
local cellSpan = 2 * distance * math.tan(math.rad(15))
local background = Instance.new("Part")
background.Name = "ChromaBackground"
background.Size = Vector3.new(cellSpan * gridSize * 2, cellSpan * gridSize * 2, 0.2)
background.CFrame = CFrame.lookAt(
    baseTarget - radial * distance * 0.75,
    baseTarget + radial * distance,
    screenUp
)
background.Anchored = true
background.CanCollide = false
background.CanTouch = false
background.CanQuery = false
background.CastShadow = false
background.Material = Enum.Material.SmoothPlastic
background.Reflectance = 0
background.Color = Color3.fromRGB(${rgb.r}, ${rgb.g}, ${rgb.b})
background.Parent = folder
rig.Archivable = true
track:AdjustSpeed(0)
for frameIndex = 1, ${safeFrameCount} do
    local phase = (frameIndex - 1) / ${safeFrameCount}
    track.TimePosition = math.min(track.Length * phase, math.max(0, track.Length - 1 / 240))
    RunService.RenderStepped:Wait()
    RunService.RenderStepped:Wait()
    local clone = rig:Clone()
    clone.Name = string.format("Frame%02d", frameIndex)
    for _, item in ipairs(clone:GetDescendants()) do
        if item:IsA("BaseScript") then
            item:Destroy()
        elseif item:IsA("BasePart") then
            item.CanCollide = false
            item.CanTouch = false
            item.CanQuery = false
            item.CastShadow = false
            item.LocalTransparencyModifier = 0
        end
    end
    clone.Parent = folder
    local column = (frameIndex - 1) % gridSize
    local row = math.floor((frameIndex - 1) / gridSize)
    local horizontal = (column - (gridSize - 1) / 2) * cellSpan
    local vertical = ((gridSize - 1) / 2 - row) * cellSpan
    local offset = screenRight * horizontal + screenUp * vertical
    clone:PivotTo(CFrame.new(offset) * clone:GetPivot())
end
for _, item in ipairs(rig:GetDescendants()) do
    if item:IsA("BasePart") then item.LocalTransparencyModifier = 1 end
end
_G.SpriteForgeCapture${motion.title}Track = track
_G.SpriteForgeCaptureAngle = angle
_G.SpriteForgeCaptureFieldOfView = math.deg(2 * math.atan(gridSize * math.tan(math.rad(15))))
_G.SpriteForgeBatchActive = true
RunService.RenderStepped:Wait()
RunService.RenderStepped:Wait()
RunService.RenderStepped:Wait()
return {ready = true, frames = ${safeFrameCount}, gridSize = gridSize}`;
}

function buildMotionBatchCleanupCode() {
  return `
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local folder = Workspace:FindFirstChild("SpriteForgeBatchCapture")
if folder then folder:Destroy() end
local rig = Workspace:FindFirstChild("SpriteForgeCaptureRig")
if rig then
    for _, item in ipairs(rig:GetDescendants()) do
        if item:IsA("BasePart") then item.LocalTransparencyModifier = 0 end
    end
end
_G.SpriteForgeCaptureFieldOfView = 30
_G.SpriteForgeBatchActive = nil
RunService.RenderStepped:Wait()
RunService.RenderStepped:Wait()
return true`;
}

function buildClientCleanupCode() {
  return `
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
RunService:UnbindFromRenderStep("SpriteForgeCaptureCamera")
local batch = Workspace:FindFirstChild("SpriteForgeBatchCapture")
if batch then batch:Destroy() end
local rig = Workspace:FindFirstChild("SpriteForgeCaptureRig")
if rig then
    for _, item in ipairs(rig:GetDescendants()) do
        if item:IsA("BasePart") then item.LocalTransparencyModifier = 0 end
    end
end
local camera = Workspace.CurrentCamera
local previous = _G.SpriteForgeCapturePreviousCamera
if camera and previous then
    camera.CameraType = previous.CameraType
    camera.CameraSubject = previous.CameraSubject
    camera.FieldOfView = previous.FieldOfView
    camera.CFrame = previous.CFrame
elseif camera then
    camera.CameraType = Enum.CameraType.Custom
end
_G.SpriteForgeCapturePreviousCamera = nil
_G.SpriteForgeCaptureAngle = nil
_G.SpriteForgeCaptureTarget = nil
_G.SpriteForgeCaptureDistance = nil
_G.SpriteForgeCaptureFieldOfView = nil
_G.SpriteForgeBatchActive = nil
_G.SpriteForgeCaptureIdleTrack = nil
_G.SpriteForgeCaptureIdleAltTrack = nil
_G.SpriteForgeCaptureWalkTrack = nil
_G.SpriteForgeCaptureRunTrack = nil
_G.SpriteForgeCaptureJumpTrack = nil
_G.SpriteForgeCaptureFallTrack = nil
_G.SpriteForgeCaptureClimbTrack = nil
return true`;
}

function buildServerCleanupCode() {
  return `
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
for _, trackName in ipairs({"SpriteForgeCaptureIdleTrack", "SpriteForgeCaptureIdleAltTrack", "SpriteForgeCaptureWalkTrack", "SpriteForgeCaptureRunTrack", "SpriteForgeCaptureJumpTrack", "SpriteForgeCaptureFallTrack", "SpriteForgeCaptureClimbTrack"}) do
    local track = _G[trackName]
    if track then pcall(function() track:Stop(0) end) end
    _G[trackName] = nil
end
local backdrop = Workspace:FindFirstChild("SpriteForgeBackdrop")
if backdrop then
    Lighting.Ambient = backdrop:GetAttribute("PreviousAmbient") or Lighting.Ambient
    Lighting.OutdoorAmbient = backdrop:GetAttribute("PreviousOutdoorAmbient") or Lighting.OutdoorAmbient
    Lighting.Brightness = backdrop:GetAttribute("PreviousBrightness") or Lighting.Brightness
    Lighting.ExposureCompensation = backdrop:GetAttribute("PreviousExposure") or Lighting.ExposureCompensation
    Lighting.EnvironmentDiffuseScale = backdrop:GetAttribute("PreviousDiffuse") or Lighting.EnvironmentDiffuseScale
    Lighting.EnvironmentSpecularScale = backdrop:GetAttribute("PreviousSpecular") or Lighting.EnvironmentSpecularScale
    local previousShadows = backdrop:GetAttribute("PreviousGlobalShadows")
    if typeof(previousShadows) == "boolean" then Lighting.GlobalShadows = previousShadows end
    Lighting.ClockTime = backdrop:GetAttribute("PreviousClockTime") or Lighting.ClockTime
end
for _, effect in ipairs(Lighting:GetChildren()) do
    if effect:IsA("PostEffect") then
        local wasEnabled = effect:GetAttribute("SpriteForgeCaptureWasEnabled")
        if typeof(wasEnabled) == "boolean" then
            effect.Enabled = wasEnabled
            effect:SetAttribute("SpriteForgeCaptureWasEnabled", nil)
        end
    end
end
for _, name in ipairs({"SpriteForgeCaptureRig", "SpriteForgeBackdrop"}) do
    local existing = Workspace:FindFirstChild(name)
    if existing then existing:Destroy() end
end
return true`;
}

function getMotionDefinition(clipKey) {
  const definitions = {
    idle: { title: "Idle", lower: "idle", looped: true },
    idle_alt: { title: "IdleAlt", lower: "idle_alt", looped: true },
    walk: { title: "Walk", lower: "walk", looped: true },
    run: { title: "Run", lower: "run", looped: true },
    jump: { title: "Jump", lower: "jump", looped: false },
    fall: { title: "Fall", lower: "fall", looped: true },
    climb: { title: "Climb", lower: "climb", looped: true },
  };
  return definitions[clipKey] ?? definitions.walk;
}

function buildSetAngleCode(angle) {
  return `
local RunService = game:GetService("RunService")
_G.SpriteForgeCaptureAngle = ${Number(angle)}
RunService.RenderStepped:Wait()
RunService.RenderStepped:Wait()
return _G.SpriteForgeCaptureAngle`;
}
