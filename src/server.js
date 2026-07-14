import fs from "node:fs/promises";
import path from "node:path";
import express from "express";
import { config } from "./config.js";
import { AppError, asAppError } from "./lib/errors.js";
import { ComfyClient } from "./lib/comfy.js";
import { JobManager } from "./lib/jobs.js";
import { getRobloxAvatarBundle } from "./lib/roblox.js";
import { StudioAvatarService } from "./lib/studio-avatar.js";
import { StudioCaptureService, StudioMcpClient } from "./lib/studio-mcp.js";
import { StudioRuntimeSync } from "./lib/studio-runtime-sync.js";
import { readGenerationPayload, readJobId, readSource } from "./lib/validation.js";

await fs.mkdir(config.outputDirectory, { recursive: true });
const comfy = new ComfyClient({
  baseUrl: config.comfyUrl,
  pollMs: config.comfyPollMs,
  frameTimeoutMs: config.frameTimeoutMs,
});
const studioClient = config.studio.enabled
  ? new StudioMcpClient({
      baseUrl: config.studio.url,
      tokenPath: config.studio.tokenPath,
    })
  : null;
const studioCapture = studioClient
  ? new StudioCaptureService({
      client: studioClient,
      format: config.studio.format,
      quality: config.studio.quality,
    })
  : null;
const jobs = new JobManager({
  outputDirectory: config.outputDirectory,
  retentionHours: config.retentionHours,
  maxQueuedJobs: config.maxQueuedJobs,
  comfy,
  models: config.models,
  animation: config.animation,
  keepRawFrames: config.keepRawFrames,
  interruptOnCancel: config.interruptOnCancel,
  studioCapture,
});
await jobs.initialize();
const studioAvatars = new StudioAvatarService({
  jobs,
  outputDirectory: config.outputDirectory,
  createInput(userId, appearanceFingerprint, captureSource = null) {
    const availableClips = new Set(captureSource?.result?.clips ?? []);
    const captureSettings = captureSource?.input ?? {};
    return {
      ...readGenerationPayload({
        source: String(userId),
        renderResolution: captureSettings.renderResolution,
        cellSize: captureSettings.cellSize,
        paletteColors: captureSettings.paletteColors,
        style: captureSettings.style,
        steps: captureSettings.steps,
        framesPerAnimation: captureSettings.framesPerAnimation,
        idleFramesPerAnimation: captureSettings.idleFramesPerAnimation,
        seed: captureSettings.seed,
        notes: captureSettings.notes,
        reuseCaptureJobId: captureSource?.id,
        recaptureClips: ["idle", "walk", "run", "jump", "fall", "climb"]
          .filter((clip) => !availableClips.has(clip)),
      }, config),
      appearanceFingerprint,
    };
  },
});
const studioRuntimeSync = studioClient
  ? new StudioRuntimeSync({ client: studioClient, avatars: studioAvatars })
  : null;
studioRuntimeSync?.start();

const app = express();
app.disable("x-powered-by");
app.set("trust proxy", false);
app.use(express.json({ limit: "32kb" }));
app.use((_request, response, next) => {
  response.setHeader("X-Content-Type-Options", "nosniff");
  response.setHeader("Referrer-Policy", "no-referrer");
  response.setHeader("Permissions-Policy", "camera=(), microphone=(), geolocation=()");
  response.setHeader(
    "Content-Security-Policy",
    "default-src 'self'; img-src 'self' data: https://rbxcdn.com https://*.rbxcdn.com https://roblox.com https://*.roblox.com; style-src 'self'; script-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'",
  );
  next();
});

const createJobRateLimit = createRateLimit({ max: 10, windowMs: 60 * 60_000 });

app.get(
  "/api/health",
  asyncHandler(async (_request, response) => {
    const [diagnosis, studioDiagnosis] = await Promise.all([
      comfy.diagnose(config.models),
      studioCapture?.diagnose() ?? Promise.resolve({ ok: false, enabled: false }),
    ]);
    response.json({
      ok: true,
      app: { name: "Roblox Sprite Forge Local", version: config.version },
      comfy: diagnosis,
      defaults: config.defaults,
      allowed: config.allowed,
      modelNames: config.models,
      animation: config.animation,
      studio: { enabled: Boolean(studioCapture), ...studioDiagnosis },
      studioRuntimeSync: studioRuntimeSync?.status() ?? { enabled: false },
    });
  }),
);

app.post(
  "/api/avatar",
  asyncHandler(async (request, response) => {
    const source = readSource(request.body?.source);
    response.json(await getRobloxAvatarBundle(source));
  }),
);

app.get("/api/jobs", (_request, response) => response.json({ jobs: jobs.list() }));

app.get(
  "/api/studio/avatars/:userId",
  asyncHandler(async (request, response) => {
    const jobId = request.query.jobId ? readJobId(request.query.jobId) : null;
    response.setHeader("Cache-Control", "no-store");
    response.json(await studioAvatars.resolve(request.params.userId, { jobId }));
  }),
);

app.post(
  "/api/jobs",
  createJobRateLimit,
  asyncHandler(async (request, response) => {
    const payload = readGenerationPayload(request.body, config);
    response.status(202).json(jobs.create(payload));
  }),
);

app.get("/api/jobs/:jobId", (request, response, next) => {
  try {
    const job = jobs.get(readJobId(request.params.jobId));
    if (!job) throw new AppError("No se encontró ese trabajo local.", { status: 404, code: "job_not_found" });
    response.json(job);
  } catch (error) {
    next(error);
  }
});

for (const method of ["delete", "post"]) {
  app[method]("/api/jobs/:jobId/cancel", asyncHandler(async (request, response) => {
    const job = await jobs.cancel(readJobId(request.params.jobId));
    if (!job) throw new AppError("No se encontró ese trabajo local.", { status: 404, code: "job_not_found" });
    response.json(job);
  }));
}

app.use(
  "/outputs",
  express.static(config.outputDirectory, {
    index: false,
    fallthrough: true,
    etag: true,
    maxAge: "1h",
    setHeaders(response, filePath) {
      if (filePath.endsWith(".json")) {
        response.setHeader("Content-Type", "application/json; charset=utf-8");
      }
      response.setHeader("Cache-Control", "private, max-age=3600");
    },
  }),
);
app.use("/outputs", (_request, response) => {
  response.status(404).json({
    error: { code: "output_not_found", message: "Ese archivo de resultado no existe." },
  });
});
app.use(express.static(config.publicDirectory, {
  etag: true,
  maxAge: 0,
  setHeaders(response) {
    response.setHeader("Cache-Control", "no-cache, must-revalidate");
  },
}));

app.use("/api", (_request, response) => {
  response.status(404).json({ error: { code: "route_not_found", message: "Ruta de API no encontrada." } });
});
app.use((request, response, next) => {
  if (request.method !== "GET" || !request.accepts("html")) return next();
  response.sendFile(path.join(config.publicDirectory, "index.html"));
});
app.use((error, _request, response, _next) => {
  if (error?.type === "entity.parse.failed") {
    response.status(400).json({
      error: { code: "invalid_json", message: "El cuerpo JSON no es válido." },
    });
    return;
  }
  const appError = asAppError(error);
  const status = Number.isInteger(appError.status) ? appError.status : 500;
  if (status >= 500) {
    console.error("[server-error]", {
      code: appError.code,
      message: appError.message,
      details: appError.details,
      cause: appError.cause instanceof Error ? appError.cause.message : undefined,
    });
  }
  response.status(status).json({
    error: {
      code: appError.code,
      message: appError.message,
      ...(appError.details !== undefined ? { details: appError.details } : {}),
    },
  });
});

const server = app.listen(config.port, config.host, () => {
  console.log(`\nRoblox Sprite Forge Local: http://${config.host}:${config.port}`);
  console.log(`ComfyUI: ${config.comfyUrl}`);
  console.log(`Roblox Studio MCP: ${config.studio.enabled ? config.studio.url : "desactivado"}`);
  console.log(`Resultados: ${config.outputDirectory}\n`);
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    console.log(`\n${signal}: cerrando servidor…`);
    server.close(() => process.exit(0));
    studioRuntimeSync?.stop();
  });
}

function asyncHandler(handler) {
  return (request, response, next) => Promise.resolve(handler(request, response, next)).catch(next);
}

function createRateLimit({ max, windowMs }) {
  const buckets = new Map();
  const cleanup = setInterval(() => {
    const now = Date.now();
    for (const [key, bucket] of buckets.entries()) if (bucket.resetAt <= now) buckets.delete(key);
  }, Math.min(windowMs, 10 * 60_000));
  cleanup.unref();
  return (request, response, next) => {
    const key = request.ip || request.socket.remoteAddress || "local";
    const now = Date.now();
    const existing = buckets.get(key);
    const bucket = !existing || existing.resetAt <= now
      ? { count: 0, resetAt: now + windowMs }
      : existing;
    bucket.count += 1;
    buckets.set(key, bucket);
    response.setHeader("X-RateLimit-Limit", String(max));
    response.setHeader("X-RateLimit-Remaining", String(Math.max(0, max - bucket.count)));
    if (bucket.count > max) {
      next(new AppError("Demasiados trabajos creados en poco tiempo.", {
        status: 429,
        code: "generation_rate_limited",
        details: { resetAt: new Date(bucket.resetAt).toISOString() },
      }));
      return;
    }
    next();
  };
}
