import path from "node:path";
import { AppError } from "./errors.js";
import { getRobloxAvatarBundle } from "./roblox.js";
import { createStudioAtlasPayload } from "./studio-atlas.js";

export class StudioAvatarService {
  constructor({ jobs, outputDirectory, createInput, resolveAvatar = getRobloxAvatarBundle }) {
    this.jobs = jobs;
    this.outputDirectory = outputDirectory;
    this.createInput = createInput;
    this.resolveAvatar = resolveAvatar;
    this.atlasCache = new Map();
  }

  async resolve(userId, { jobId = null } = {}) {
    const safeUserId = readUserId(userId);
    let bundle = null;
    let job = null;

    if (jobId) {
      job = this.jobs.get(jobId);
      if (!job || !jobBelongsToUser(job, safeUserId)) {
        throw new AppError("El trabajo dinámico no corresponde a ese jugador.", {
          status: 404,
          code: "studio_avatar_job_not_found",
        });
      }
    } else {
      bundle = await this.resolveAvatar(String(safeUserId));
      const fingerprint = bundle.appearanceFingerprint;
      job = this.jobs.findByAppearance(safeUserId, fingerprint);
      if (!job) {
        const captureSource = this.jobs.findCaptureSourceByAppearance?.(safeUserId, fingerprint) ?? null;
        job = this.jobs.create(this.createInput(safeUserId, fingerprint, captureSource));
      }
    }

    return this.format(job, bundle);
  }

  async format(job, resolvedBundle = null) {
    const avatar = job.avatar ?? resolvedBundle;
    const fingerprint = resolvedBundle?.appearanceFingerprint
      ?? avatar?.appearanceFingerprint
      ?? job.input?.appearanceFingerprint
      ?? null;
    const base = {
      userId: Number(avatar?.user?.id ?? job.input?.source),
      appearanceFingerprint: fingerprint,
      jobId: job.id,
      jobStatus: job.status,
      progress: job.progress,
      avatar: avatar
        ? {
            username: avatar.user.username,
            displayName: avatar.user.displayName,
            assetCount: avatar.avatar.assetCount,
          }
        : null,
    };

    if (job.status === "completed" && job.result) {
      let atlas = this.atlasCache.get(job.id);
      if (!atlas) {
        atlas = await createStudioAtlasPayload(
          path.join(this.outputDirectory, job.id),
          fingerprint,
        );
        this.atlasCache.set(job.id, atlas);
      }
      return { ...base, status: "ready", atlas };
    }
    if (["failed", "canceled"].includes(job.status)) {
      return { ...base, status: "failed", error: job.error ?? { message: "La generación no terminó." } };
    }
    return { ...base, status: "pending" };
  }
}

function readUserId(value) {
  const userId = Number(value);
  if (!Number.isSafeInteger(userId) || userId <= 0) {
    throw new AppError("El ID dinámico de Roblox no es válido.", {
      status: 400,
      code: "invalid_studio_avatar_user_id",
    });
  }
  return userId;
}

function jobBelongsToUser(job, userId) {
  return Number(job.avatar?.user?.id ?? job.input?.source) === userId;
}
