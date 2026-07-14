import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { AppError } from "./lib/errors.js";

const currentDirectory = path.dirname(fileURLToPath(import.meta.url));
export const projectRoot = path.resolve(currentDirectory, "..");
loadDotEnv(path.join(projectRoot, ".env"));

const renderResolutions = [512, 768, 1024];
const cellSizes = [48, 64, 96, 128, 144];
const paletteSizes = [32, 48, 64, 96, 128];
const styles = ["handheld", "minimal", "detailed"];
const steps = [4, 6, 8, 10, 12];
const animationFrames = [2, 4, 6, 8];
const idleAnimationFrames = [8, 12, 16];

export const config = Object.freeze({
  version: "1.0.0",
  host: envString("HOST", "127.0.0.1"),
  port: envInteger("PORT", 3000, 1, 65_535),
  comfyUrl: normalizeBaseUrl(envString("COMFYUI_URL", "http://127.0.0.1:8188")),
  studio: Object.freeze({
    enabled: envBoolean("ROBLOX_STUDIO_CAPTURE", true),
    url: normalizeHttpUrl(envString("ROBLOX_STUDIO_MCP_URL", "http://127.0.0.1:58741"), "ROBLOX_STUDIO_MCP_URL"),
    tokenPath: resolveUserPath(envString(
      "ROBLOX_STUDIO_MCP_TOKEN_PATH",
      path.join(os.homedir(), ".robloxstudio-mcp", "auth-token"),
    )),
    format: envAllowedString("ROBLOX_STUDIO_CAPTURE_FORMAT", "png", ["jpeg", "png"]),
    quality: envInteger("ROBLOX_STUDIO_CAPTURE_QUALITY", 96, 70, 100),
    batchIdle: envBoolean("ROBLOX_STUDIO_BATCH_IDLE", false),
  }),
  models: Object.freeze({
    unet: envString("COMFYUI_UNET", "flux-2-klein-4b-fp8.safetensors"),
    textEncoder: envString("COMFYUI_TEXT_ENCODER", "qwen_3_4b.safetensors"),
    vae: envString("COMFYUI_VAE", "flux2-vae.safetensors"),
    weightDtype: envAllowedString(
      "COMFYUI_WEIGHT_DTYPE",
      "default",
      ["default", "fp8_e4m3fn", "fp8_e4m3fn_fast", "fp8_e5m2"],
    ),
    animationCheckpoint: envString(
      "COMFYUI_ANIMATION_CHECKPOINT",
      "PixelartSpritesheet_V.1.ckpt",
    ),
    animationControlNet: envString(
      "COMFYUI_ANIMATION_CONTROLNET",
      "control_v11p_sd15_openpose.pth",
    ),
  }),
  animation: Object.freeze({
    engine: envAllowedString("ANIMATION_ENGINE", "deterministic", ["deterministic", "controlnet"]),
    steps: envInteger("ANIMATION_STEPS", 20, 4, 60),
    cfg: envNumber("ANIMATION_CFG", 7, 1, 20),
    denoise: envNumber("ANIMATION_DENOISE", 0.72, 0.1, 1),
    controlStrength: envNumber("ANIMATION_CONTROL_STRENGTH", 1.15, 0, 3),
  }),
  defaults: Object.freeze({
    renderResolution: envAllowedInteger(
      "DEFAULT_RENDER_RESOLUTION",
      512,
      renderResolutions,
    ),
    cellSize: envAllowedInteger("DEFAULT_CELL_SIZE", 64, cellSizes),
    paletteColors: envAllowedInteger("DEFAULT_PALETTE_COLORS", 64, paletteSizes),
    style: envAllowedString("DEFAULT_STYLE", "handheld", styles),
    steps: envAllowedInteger("DEFAULT_STEPS", 4, steps),
    framesPerAnimation: envAllowedInteger(
      "DEFAULT_FRAMES_PER_ANIMATION",
      8,
      animationFrames,
    ),
    idleFramesPerAnimation: envAllowedInteger(
      "DEFAULT_IDLE_FRAMES_PER_ANIMATION",
      16,
      idleAnimationFrames,
    ),
  }),
  allowed: Object.freeze({
    renderResolutions,
    cellSizes,
    paletteSizes,
    styles,
    steps,
    animationFrames,
    idleAnimationFrames,
  }),
  frameTimeoutMs: envInteger("FRAME_TIMEOUT_MS", 15 * 60_000, 30_000, 60 * 60_000),
  comfyPollMs: envInteger("COMFYUI_POLL_MS", 800, 250, 5_000),
  maxQueuedJobs: envInteger("MAX_QUEUED_JOBS", 8, 1, 50),
  retentionHours: envInteger("JOB_RETENTION_HOURS", 24, 1, 168),
  interruptOnCancel: envBoolean("COMFYUI_INTERRUPT_ON_CANCEL", true),
  keepRawFrames: envBoolean("KEEP_RAW_FRAMES", false),
  outputDirectory: resolveProjectPath(envString("OUTPUT_DIR", "data/generated")),
  publicDirectory: path.join(projectRoot, "public"),
  maxNotesLength: 800,
});

function loadDotEnv(filePath) {
  if (!fs.existsSync(filePath)) return;
  const text = fs.readFileSync(filePath, "utf8");
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const separator = line.indexOf("=");
    if (separator < 1) continue;
    const key = line.slice(0, separator).trim();
    let value = line.slice(separator + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    if (!(key in process.env)) process.env[key] = value;
  }
}

function envString(name, fallback) {
  const value = process.env[name]?.trim();
  return value || fallback;
}

function envInteger(name, fallback, min, max) {
  const value = Number(process.env[name]);
  if (!Number.isInteger(value)) return fallback;
  return Math.min(max, Math.max(min, value));
}

function envNumber(name, fallback, min, max) {
  const value = Number(process.env[name]);
  if (!Number.isFinite(value)) return fallback;
  return Math.min(max, Math.max(min, value));
}

function envAllowedInteger(name, fallback, allowed) {
  const value = Number(process.env[name]);
  return allowed.includes(value) ? value : fallback;
}

function envAllowedString(name, fallback, allowed) {
  const value = process.env[name]?.trim();
  return allowed.includes(value) ? value : fallback;
}

function envBoolean(name, fallback) {
  const value = process.env[name]?.trim().toLowerCase();
  if (["1", "true", "yes", "on"].includes(value)) return true;
  if (["0", "false", "no", "off"].includes(value)) return false;
  return fallback;
}

function resolveProjectPath(value) {
  return path.isAbsolute(value) ? path.normalize(value) : path.resolve(projectRoot, value);
}

function resolveUserPath(value) {
  if (value.startsWith("~/") || value.startsWith("~\\")) {
    return path.join(os.homedir(), value.slice(2));
  }
  return resolveProjectPath(value);
}

function normalizeBaseUrl(value) {
  return normalizeHttpUrl(value, "COMFYUI_URL");
}

function normalizeHttpUrl(value, variableName) {
  try {
    const url = new URL(value);
    if (!["http:", "https:"].includes(url.protocol)) throw new Error("protocol");
    return url.toString().replace(/\/$/, "");
  } catch (error) {
    throw new AppError(`${variableName} debe ser una URL http o https válida.`, {
      status: 500,
      code: "invalid_service_url",
      cause: error,
    });
  }
}
