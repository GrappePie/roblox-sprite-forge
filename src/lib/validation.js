import { randomInt } from "node:crypto";
import { AppError } from "./errors.js";

const CAPTURE_CLIPS = Object.freeze(["idle", "walk", "run", "jump", "fall", "climb", "swim"]);

export function readGenerationPayload(body, config) {
  return {
    source: readSource(body?.source),
    renderResolution: readAllowedNumber(
      body?.renderResolution,
      config.allowed.renderResolutions,
      config.defaults.renderResolution,
    ),
    cellSize: readAllowedNumber(body?.cellSize, config.allowed.cellSizes, config.defaults.cellSize),
    paletteColors: readAllowedNumber(
      body?.paletteColors,
      config.allowed.paletteSizes,
      config.defaults.paletteColors,
    ),
    style: readAllowedString(body?.style, config.allowed.styles, config.defaults.style),
    steps: readAllowedNumber(body?.steps, config.allowed.steps, config.defaults.steps),
    framesPerAnimation: readAllowedNumber(
      body?.framesPerAnimation,
      config.allowed.animationFrames,
      config.defaults.framesPerAnimation,
    ),
    idleFramesPerAnimation: readAllowedNumber(
      body?.idleFramesPerAnimation,
      config.allowed.idleAnimationFrames,
      config.defaults.idleFramesPerAnimation,
    ),
    notes: readNotes(body?.notes, config.maxNotesLength),
    seed: readSeed(body?.seed),
    reuseCaptureJobId: readOptionalJobId(body?.reuseCaptureJobId),
    recaptureClips: readCaptureClips(body?.recaptureClips),
  };
}

export function readSource(value) {
  if (typeof value !== "string" || value.trim().length === 0 || value.length > 180) {
    throw new AppError("Indica un @username, ID o URL de perfil de Roblox.", {
      status: 400,
      code: "invalid_source",
    });
  }
  return value.trim();
}

export function readJobId(value) {
  if (
    typeof value !== "string" ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
  ) {
    throw new AppError("El identificador del trabajo no es válido.", {
      status: 400,
      code: "invalid_job_id",
    });
  }
  return value;
}

function readOptionalJobId(value) {
  if (value === undefined || value === null || value === "") return null;
  return readJobId(value);
}

function readCaptureClips(value) {
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value) || value.some((clip) => typeof clip !== "string" || !CAPTURE_CLIPS.includes(clip))) {
    throw new AppError("La selección de clips para recapturar no es válida.", {
      status: 400,
      code: "invalid_recapture_clips",
    });
  }
  return [...new Set(value)];
}

function readAllowedString(value, allowed, fallback) {
  return typeof value === "string" && allowed.includes(value) ? value : fallback;
}

function readAllowedNumber(value, allowed, fallback) {
  const number = Number(value);
  return allowed.includes(number) ? number : fallback;
}

function readNotes(value, maxLength) {
  if (value === undefined || value === null) return "";
  if (typeof value !== "string") {
    throw new AppError("Las indicaciones adicionales deben ser texto.", {
      status: 400,
      code: "invalid_notes",
    });
  }
  return value.slice(0, maxLength);
}

function readSeed(value) {
  if (value === undefined || value === null || value === "") {
    return randomInt(0, 2_147_483_647);
  }
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number < 0) {
    throw new AppError("La semilla debe ser un entero igual o mayor que cero, o estar vacía.", {
      status: 400,
      code: "invalid_seed",
    });
  }
  return number;
}
