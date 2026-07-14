import fs from "node:fs/promises";
import path from "node:path";
import { randomUUID } from "node:crypto";
import sharp from "sharp";
import { AppError, asAppError } from "./errors.js";
import {
  downloadRobloxThumbnail,
  getAvatarAppearanceFingerprint,
  getRobloxAvatarBundle,
} from "./roblox.js";
import { buildFlux2KleinWorkflow, buildPoseControlledSpriteWorkflow } from "./workflow.js";
import {
  buildFramePrompt,
  buildPoseAnimationNegativePrompt,
  buildPoseAnimationPrompt,
  CLIPS,
  DIRECTIONS,
  getClipFrameCounts,
  getFramePlan,
} from "./prompt.js";
import { createPoseGuide } from "./pose.js";
import {
  animateCanonicalCell,
  hasStableMotionTopology,
  hasVerticalBodyContinuity,
} from "./motion.js";
import {
  createMirroredDirectionMaster,
  getDirectionMasterStrategy,
  harmonizeDirectionMasterPalette,
  harmonizeSpritePalette,
  normalizeDirectionalMasters,
} from "./direction-consistency.js";
import {
  assembleSpriteSheet,
  chooseChromaColor,
  createStudioCellTransform,
  createStudioSwimCellTransform,
  createAtlasData,
  createPixelPreview,
  prepareAvatarReference,
  removeIsolatedAlphaPixels,
  removeChromaBackground,
  renderSpriteCell,
  renderStudioSpriteCell,
} from "./postprocess.js";
import { createZip } from "./archive.js";

const STUDIO_CLIP_KEYS = Object.freeze(["idle", "walk", "run", "jump", "fall", "climb", "swim"]);
const STUDIO_CAPTURED_ANIMATION_CLIP_KEYS = Object.freeze(CLIPS.map((clip) => clip.key));

function captureSelectionForClip(clip) {
  if (clip === "idle" || clip === "idle_alt") return "idle";
  if (clip.startsWith("swim")) return "swim";
  return clip;
}

function internalClipsForSelection(selection) {
  return STUDIO_CAPTURED_ANIMATION_CLIP_KEYS.filter(
    (clip) => captureSelectionForClip(clip) === selection,
  );
}

export class JobManager {
  constructor({
    outputDirectory,
    retentionHours,
    maxQueuedJobs,
    comfy,
    models,
    animation,
    studioCapture = null,
    keepRawFrames = false,
    interruptOnCancel = true,
  }) {
    this.outputDirectory = outputDirectory;
    this.retentionHours = retentionHours;
    this.maxQueuedJobs = maxQueuedJobs;
    this.comfy = comfy;
    this.models = models;
    this.animation = animation;
    this.studioCapture = studioCapture;
    this.keepRawFrames = keepRawFrames;
    this.interruptOnCancel = interruptOnCancel;
    this.jobs = new Map();
    this.pending = [];
    this.active = null;
    this.persistChains = new Map();
  }

  async initialize() {
    await fs.mkdir(this.outputDirectory, { recursive: true });
    await this.loadPersistedJobs();
    await this.cleanupExpired();
    const timer = setInterval(() => this.cleanupExpired().catch(console.error), 60 * 60_000);
    timer.unref();
  }

  create(input) {
    const queuedCount = this.pending.length + (this.active ? 1 : 0);
    if (queuedCount >= this.maxQueuedJobs) {
      throw new AppError("La cola local está llena. Espera a que termine un trabajo.", {
        status: 429,
        code: "job_queue_full",
        details: { maxQueuedJobs: this.maxQueuedJobs },
      });
    }
    const now = new Date().toISOString();
    const frameTotal = getFramePlan(input).length;
    const job = {
      id: randomUUID(),
      status: "queued",
      createdAt: now,
      updatedAt: now,
      input,
      progress: {
        stage: "queued",
        message: "Esperando turno de GPU…",
        done: 0,
        total: frameTotal,
        percent: 0,
        currentFrame: null,
      },
      avatar: null,
      result: null,
      error: null,
      cancelRequested: false,
      abortController: null,
    };
    this.jobs.set(job.id, job);
    this.pending.push(job.id);
    this.persist(job).catch(console.error);
    queueMicrotask(() => this.pump().catch(console.error));
    return this.publicJob(job);
  }

  get(id) {
    const job = this.jobs.get(id);
    if (!job) return null;
    return this.publicJob(job);
  }

  list() {
    return [...this.jobs.values()]
      .sort((a, b) => b.createdAt.localeCompare(a.createdAt))
      .slice(0, 20)
      .map((job) => this.publicJob(job));
  }

  findByAppearance(userId, fingerprint) {
    const matches = [...this.jobs.values()].filter((job) => {
      const avatarUserId = Number(job.avatar?.user?.id ?? job.input?.source);
      if (avatarUserId !== Number(userId)) return false;
      if (job.status === "completed" && !isCompatibleDynamicAtlasJob(job)) return false;
      const jobFingerprint = job.avatar
        ? (job.avatar.appearanceFingerprint ?? getAvatarAppearanceFingerprint(job.avatar))
        : job.input?.appearanceFingerprint;
      return jobFingerprint === fingerprint;
    });
    matches.sort((left, right) => {
      const leftReady = left.status === "completed" ? 1 : 0;
      const rightReady = right.status === "completed" ? 1 : 0;
      const leftFrames = Number(left.input?.framesPerAnimation ?? 0);
      const rightFrames = Number(right.input?.framesPerAnimation ?? 0);
      return rightReady - leftReady
        || rightFrames - leftFrames
        || right.createdAt.localeCompare(left.createdAt);
    });
    return matches[0] ? this.publicJob(matches[0]) : null;
  }

  findCaptureSourceByAppearance(userId, fingerprint) {
    const matches = [...this.jobs.values()].filter((job) => {
      if (job.status !== "completed" || !job.result) return false;
      const avatarUserId = Number(job.avatar?.user?.id ?? job.input?.source);
      if (avatarUserId !== Number(userId)) return false;
      const jobFingerprint = job.avatar
        ? (job.avatar.appearanceFingerprint ?? getAvatarAppearanceFingerprint(job.avatar))
        : job.input?.appearanceFingerprint;
      return jobFingerprint === fingerprint
        && job.result.clips?.includes("idle")
        && job.result.directions?.length === DIRECTIONS.length;
    });
    matches.sort((left, right) => {
      const leftClipCount = left.result?.clips?.length ?? 0;
      const rightClipCount = right.result?.clips?.length ?? 0;
      return rightClipCount - leftClipCount || right.updatedAt.localeCompare(left.updatedAt);
    });
    return matches[0] ? this.publicJob(matches[0]) : null;
  }

  async loadReusableStudioCapture(job, bundle) {
    const sourceId = job.input.reuseCaptureJobId;
    if (!sourceId) return null;
    const sourceJob = this.jobs.get(sourceId);
    if (!sourceJob || !["completed", "failed", "canceled"].includes(sourceJob.status)) {
      throw new AppError("El set elegido para reutilizar capturas ya no está disponible.", {
        status: 409,
        code: "capture_source_unavailable",
      });
    }
    const currentFingerprint = bundle.appearanceFingerprint ?? getAvatarAppearanceFingerprint(bundle);
    const sourceFingerprint = sourceJob.avatar?.appearanceFingerprint
      ?? (sourceJob.avatar ? getAvatarAppearanceFingerprint(sourceJob.avatar) : null);
    if (!currentFingerprint || currentFingerprint !== sourceFingerprint) {
      throw new AppError("El avatar cambió desde esas capturas; es necesario volver a capturarlo.", {
        status: 409,
        code: "capture_source_avatar_changed",
      });
    }

    const sourceRoot = path.join(this.outputDirectory, sourceId);
    const manifest = await fs.readFile(path.join(sourceRoot, "manifest.json"), "utf8")
      .then(JSON.parse)
      .catch((error) => {
        if (error?.code === "ENOENT") return null;
        throw error;
      });
    if (manifest && manifest.studioCapture?.mode !== "studio-3d-turntable") return null;
    const referenceRoot = path.join(
      sourceRoot,
      manifest?.studioCapture?.referencesDirectory ?? "studio-references",
    );
    const targetResolution = job.input.renderResolution;
    const readReference = async (name) => {
      const buffer = await fs.readFile(path.join(referenceRoot, name));
      const metadata = await sharp(buffer).metadata();
      if (metadata.width === targetResolution && metadata.height === targetResolution) return buffer;
      return sharp(buffer)
        .resize(targetResolution, targetResolution, { fit: "fill", kernel: sharp.kernel.lanczos3 })
        .png({ compressionLevel: 9 })
        .toBuffer();
    };
    const images = new Map();
    for (const direction of DIRECTIONS) {
      try {
        images.set(direction.key, await readReference(`${direction.key}.png`));
      } catch (error) {
        if (error?.code !== "ENOENT") throw error;
      }
    }
    const motionImages = Object.fromEntries(
      STUDIO_CAPTURED_ANIMATION_CLIP_KEYS.map((clip) => [clip, new Map()]),
    );
    const sourceFrameCounts = getClipFrameCounts(sourceJob.input);
    const targetFrameCounts = getClipFrameCounts(job.input);
    for (const clip of STUDIO_CAPTURED_ANIMATION_CLIP_KEYS) {
      if (sourceFrameCounts[clip] === targetFrameCounts[clip]) {
        for (const direction of DIRECTIONS) {
          for (let frameIndex = 1; frameIndex <= targetFrameCounts[clip]; frameIndex += 1) {
            const key = `${direction.key}_${clip}_${frameIndex}`;
            try {
              motionImages[clip].set(key, await readReference(`${key}.png`));
            } catch (error) {
              if (error?.code !== "ENOENT") throw error;
            }
          }
        }
      }
    }
    return {
      images,
      ...Object.fromEntries(STUDIO_CAPTURED_ANIMATION_CLIP_KEYS.map((clip) => [
        studioImagesProperty(clip),
        motionImages[clip],
      ])),
      animationCatalog: manifest?.studioCapture?.animationCatalog ?? {},
      chroma: {
        hex: manifest?.settings?.chroma ?? await readCapturedChromaHex(images.values().next().value),
      },
      source: {
        ...(manifest?.studioCapture ?? { mode: "studio-3d-turntable" }),
        reusedFromJobId: sourceId,
      },
    };
  }

  async cancel(id) {
    const job = this.jobs.get(id);
    if (!job) return null;
    if (["completed", "failed", "canceled"].includes(job.status)) return this.publicJob(job);
    const wasQueued = job.status === "queued";
    const wasActive = this.active === id;
    job.cancelRequested = true;
    job.abortController?.abort(new Error("job canceled"));
    this.pending = this.pending.filter((queuedId) => queuedId !== id);
    this.update(job, wasQueued
      ? {
          status: "canceled",
          progress: { ...job.progress, stage: "canceled", message: "Trabajo cancelado." },
        }
      : {
          status: "canceling",
          progress: { ...job.progress, stage: "canceling", message: "Cancelando el workflow activo…" },
        });
    await this.persist(job);
    if (wasActive && this.interruptOnCancel) await this.comfy.interrupt();
    return this.publicJob(job);
  }

  async pump() {
    if (this.active) return;
    const nextId = this.pending.shift();
    if (!nextId) return;
    const job = this.jobs.get(nextId);
    if (!job || job.status === "canceled") {
      queueMicrotask(() => this.pump().catch(console.error));
      return;
    }
    this.active = job.id;
    try {
      await this.run(job);
    } finally {
      this.active = null;
      queueMicrotask(() => this.pump().catch(console.error));
    }
  }

  async run(job) {
    const frameCounts = getClipFrameCounts(job.input);
    const plan = getFramePlan(job.input);
    const jobDirectory = path.join(this.outputDirectory, job.id);
    const framesDirectory = path.join(jobDirectory, "frames");
    const guidesDirectory = path.join(jobDirectory, "guides");
    const rawDirectory = path.join(jobDirectory, "raw");
    const studioReferencesDirectory = path.join(jobDirectory, "studio-references");
    job.abortController = new AbortController();
    const signal = job.abortController.signal;

    try {
      await fs.mkdir(framesDirectory, { recursive: true });
      await fs.mkdir(guidesDirectory, { recursive: true });
      if (this.keepRawFrames) await fs.mkdir(rawDirectory, { recursive: true });
      this.throwIfCanceled(job);
      this.update(job, {
        status: "checking",
        progress: {
          ...job.progress,
          stage: "comfy-check",
          message: "Comprobando ComfyUI y los modelos locales…",
          percent: 1,
        },
      });
      await this.comfy.assertReady(this.models);

      this.update(job, {
        status: "resolving",
        progress: {
          ...job.progress,
          stage: "roblox",
          message: "Leyendo el perfil y el avatar público de Roblox…",
          percent: 2,
        },
      });
      const bundle = await getRobloxAvatarBundle(job.input.source);
      job.avatar = bundle;
      await this.persist(job);
      this.throwIfCanceled(job);

      const thumbnail = await downloadRobloxThumbnail(bundle.thumbnailUrl);
      const prepared = await prepareAvatarReference(thumbnail.buffer, job.input.renderResolution);
      const reusableStudioCapture = await this.loadReusableStudioCapture(job, bundle);
      const chroma = reusableStudioCapture?.chroma ?? await chooseChromaColor(prepared.transparent);
      await Promise.all([
        fs.writeFile(path.join(jobDirectory, "reference.png"), prepared.reference),
        fs.writeFile(path.join(jobDirectory, "reference-transparent.png"), prepared.transparent),
      ]);
      const originalUpload = await this.comfy.uploadImage(
        prepared.reference,
        `rsf_${job.id}_roblox_reference.png`,
        signal,
      );

      let studioTurntable = reusableStudioCapture;
      const studioReferenceNames = new Map();
      const studioMotionCells = new Map();
      if (this.studioCapture) {
        const explicitlyRequested = new Set(job.input.recaptureClips ?? []);
        const captureClips = STUDIO_CLIP_KEYS.filter((selection) => {
          if (explicitlyRequested.has(selection)) return true;
          const internalClips = internalClipsForSelection(selection);
          if (selection === "idle") {
            const expectedMotionFrames = DIRECTIONS.length * frameCounts.idle;
            const hasDirections = reusableStudioCapture?.images?.size === DIRECTIONS.length;
            const hasPrimary = reusableStudioCapture?.idleImages?.size === expectedMotionFrames;
            const expectsAlternate = Boolean(
              reusableStudioCapture?.animationCatalog?.resolvedAnimations?.IdleAltAnimation,
            );
            const hasAlternate = reusableStudioCapture?.idleAltImages?.size === expectedMotionFrames;
            return !hasDirections || !hasPrimary || (expectsAlternate && !hasAlternate);
          }
          return internalClips.some((clip) => (
            reusableStudioCapture?.[studioImagesProperty(clip)]?.size
              !== DIRECTIONS.length * frameCounts[clip]
          ));
        });
        this.update(job, {
          status: captureClips.length ? "capturing" : "resolving",
          progress: {
            ...job.progress,
            stage: "studio-capture",
            message: captureClips.length
              ? reusableStudioCapture
                ? `Reutilizando capturas guardadas y recapturando: ${captureClips.join(", ")}…`
                : `Capturando desde Roblox Studio: ${captureClips.join(", ")}…`
              : "Reutilizando todas las capturas guardadas de Roblox Studio…",
            percent: 3,
          },
        });
        try {
          if (captureClips.length) {
            const freshCapture = await this.studioCapture.captureTurntable({
              userId: bundle.user.id,
              renderResolution: job.input.renderResolution,
              chroma,
              framesPerAnimation: job.input.framesPerAnimation,
              frameCounts,
              clips: captureClips,
              signal,
            });
            studioTurntable = mergeStudioCaptures({
              reusable: reusableStudioCapture,
              fresh: freshCapture,
              recapturedClips: captureClips,
              frameCounts,
            });
          }
          if (!studioTurntable || studioTurntable.images.size !== DIRECTIONS.length) {
            throw new AppError("Faltan las vistas idle necesarias para registrar las animaciones.", {
              status: 502,
              code: "studio_idle_references_missing",
            });
          }
          await fs.mkdir(studioReferencesDirectory, { recursive: true });
          for (const [direction, buffer] of studioTurntable.images) {
            await fs.writeFile(path.join(studioReferencesDirectory, `${direction}.png`), buffer);
            const upload = await this.comfy.uploadImage(
              buffer,
              `rsf_${job.id}_studio_${direction}.png`,
              signal,
            );
            studioReferenceNames.set(direction, upload.loadImageName);
          }
          for (const clip of STUDIO_CAPTURED_ANIMATION_CLIP_KEYS) {
            for (const [frameKey, buffer] of studioTurntable[studioImagesProperty(clip)] ?? []) {
              await fs.writeFile(path.join(studioReferencesDirectory, `${frameKey}.png`), buffer);
            }
          }
        } catch (error) {
          if (signal.aborted || job.cancelRequested) throw error;
          studioTurntable = reusableStudioCapture;
          studioReferenceNames.clear();
          console.warn("[studio-capture-fallback]", job.id, error instanceof Error ? error.message : error);
          this.update(job, {
            status: "resolving",
            progress: {
              ...job.progress,
              stage: "studio-fallback",
              message: "Studio no estaba disponible; continuando con la referencia pública de Roblox…",
              percent: 3,
            },
          });
        }
      }

      const completedFrames = [];
      const directionMasters = new Map();
      const masterStrategies = {};
      let turntableReferenceName = originalUpload.loadImageName;
      let generatedMasterCount = 0;
      let done = 0;
      const studioMotionCollections = {
        idle: studioTurntable?.idleImages,
        idle_alt: studioTurntable?.idleAltImages,
        walk: studioTurntable?.walkImages,
        run: studioTurntable?.runImages,
        jump: studioTurntable?.jumpImages,
        fall: studioTurntable?.fallImages,
        climb: studioTurntable?.climbImages,
        swim_idle: studioTurntable?.swim_idleImages,
        swim: studioTurntable?.swimImages,
        swim_up: studioTurntable?.swim_upImages,
        swim_down: studioTurntable?.swim_downImages,
      };
      for (const direction of [...new Set(plan.map((frame) => frame.direction.key))]) {
        const directionFrames = plan.filter((frame) => frame.direction.key === direction);
        const directionSeed = deriveDirectionSeed(job.input.seed, directionFrames[0].direction.row);
        const masterStrategy = studioTurntable
          ? { kind: "studio-direct", sourceKey: null }
          : getDirectionMasterStrategy(direction, this.animation.engine);
        masterStrategies[direction] = masterStrategy;
        let directionMasterName = null;
        let directionMasterCell = null;
        let studioCellTransform = null;
        let studioSwimCellTransform = null;

        for (const frame of directionFrames) {
          const poseGuide = await createPoseGuide(frame, job.input);
          await fs.writeFile(path.join(guidesDirectory, `${frame.key}.png`), poseGuide);
          const isDirectionMaster = frame.clip.key === "idle" && frame.frameIndex === 1;
          const studioMotionReference = studioMotionCollections[frame.clip.key]?.get(frame.key) ?? null;
          let cell;
          if (isDirectionMaster && masterStrategy.kind === "studio-direct") {
            this.update(job, {
              status: "generating",
              progress: {
                ...job.progress,
                stage: "identity",
                message: `Pixelando la captura auténtica: ${frame.direction.label}…`,
                currentFrame: frame.key,
              },
            });
            const studioReference = studioMotionReference ?? studioTurntable.images.get(direction);
            if (!studioReference) {
              throw new AppError(`Studio no devolvió la vista ${direction}.`, {
                status: 502,
                code: "studio_direction_missing",
              });
            }
            const transparentStudioReference = await removeChromaBackground(
              studioReference,
              chroma,
              { trim: false },
            );
            studioCellTransform = await createStudioCellTransform(transparentStudioReference, job.input);
            studioSwimCellTransform = await createStudioSwimCellTransform(
              transparentStudioReference,
              job.input,
            );
            cell = await renderStudioSpriteCell(
              transparentStudioReference,
              studioCellTransform,
              job.input,
            );
            directionMasterCell = cell;
            directionMasters.set(direction, cell);
            await fs.writeFile(path.join(framesDirectory, `${frame.key}.png`), cell);
          } else if (isDirectionMaster && masterStrategy.kind === "mirrored") {
            this.update(job, {
              status: "generating",
              progress: {
                ...job.progress,
                stage: "identity",
                message: `Construyendo ${frame.direction.label} como espejo exacto de ${masterStrategy.sourceKey}…`,
                currentFrame: frame.key,
              },
            });
            cell = await createMirroredDirectionMaster(
              directionMasters.get(masterStrategy.sourceKey),
              job.input,
            );
            directionMasterCell = cell;
            directionMasters.set(direction, cell);
            await fs.writeFile(path.join(framesDirectory, `${frame.key}.png`), cell);
          } else if (studioMotionReference && this.animation.engine === "deterministic") {
            this.update(job, {
              status: "generating",
              progress: {
                ...job.progress,
                stage: "motion",
                message: `Pixelando pose real de Roblox: ${frame.direction.label} · ${frame.clip.label} ${frame.frameIndex}/${frame.frameCount}…`,
                currentFrame: frame.key,
              },
            });
            try {
              const transparentMotionReference = await removeChromaBackground(
                studioMotionReference,
                chroma,
                { trim: false },
              );
              cell = await renderStudioSpriteCell(
                transparentMotionReference,
                frame.clip.key.startsWith("swim") ? studioSwimCellTransform : studioCellTransform,
                job.input,
              );
              if (!frame.clip.key.startsWith("swim") && !(await hasVerticalBodyContinuity(cell))) {
                throw new AppError(`La pose real ${frame.key} perdió la continuidad entre torso y pies.`, {
                  status: 502,
                  code: `studio_${frame.clip.key}_body_disconnected`,
                });
              }
              studioMotionCells.set(frame.key, cell);
            } catch (error) {
              if (!["idle", "idle_alt", "swim_idle", "swim", "swim_up", "swim_down"].includes(frame.clip.key)) throw error;
              console.warn(
                "[studio-idle-frame-fallback]",
                job.id,
                frame.key,
                error instanceof Error ? error.message : error,
              );
              cell = await removeIsolatedAlphaPixels(await animateCanonicalCell(directionMasterCell, frame));
            }
            await fs.writeFile(path.join(framesDirectory, `${frame.key}.png`), cell);
          } else if (!isDirectionMaster && this.animation.engine === "deterministic") {
            this.update(job, {
              status: "generating",
              progress: {
                ...job.progress,
                stage: "motion",
                message: `Aplicando pose estable: ${frame.direction.label} · ${frame.clip.label} ${frame.frameIndex}/${frame.frameCount}…`,
                currentFrame: frame.key,
              },
            });
            cell = await removeIsolatedAlphaPixels(await animateCanonicalCell(directionMasterCell, frame));
            if (!(await hasStableMotionTopology(directionMasterCell, cell, {
              accessoryAware: Boolean(studioTurntable),
            }))) {
              console.warn("[motion-topology-fallback]", job.id, frame.key);
              cell = Buffer.from(directionMasterCell);
            }
            await fs.writeFile(path.join(framesDirectory, `${frame.key}.png`), cell);
          } else {
            let referenceName = isDirectionMaster ? turntableReferenceName : directionMasterName;
            let referenceKind = isDirectionMaster
              ? (generatedMasterCount === 0 ? "roblox" : "turntable")
              : "direction-master";
            let secondaryImageName = null;
            if (isDirectionMaster && studioTurntable) {
              const studioReferenceName = studioReferenceNames.get(direction);
              referenceName = studioReferenceName;
              referenceKind = "studio-avatar";
              secondaryImageName = null;
            } else {
              const poseUpload = await this.comfy.uploadImage(
                poseGuide,
                `rsf_${job.id}_${frame.key}_pose.png`,
                signal,
              );
              secondaryImageName = poseUpload.loadImageName;
            }
            const raw = await this.generateFrame({
              job,
              bundle,
              frame,
              engine: isDirectionMaster ? "canonical" : "pose",
              referenceName,
              referenceKind,
              poseImageName: secondaryImageName,
              seed: isDirectionMaster && this.animation.engine === "deterministic"
                ? job.input.seed
                : deriveFrameSeed(directionSeed, frame.clip.key, frame.frameIndex),
              chroma,
              signal,
              done,
              total: plan.length,
            });
            cell = await this.processAndSaveFrame({
              job,
              frame,
              raw,
              chroma,
              framesDirectory,
              rawDirectory,
            });
            if (isDirectionMaster) {
              const upload = await this.comfy.uploadImage(
                raw,
                `rsf_${job.id}_${direction}_canonical.png`,
                signal,
              );
              directionMasterName = upload.loadImageName;
              if (this.animation.engine === "deterministic") {
                turntableReferenceName = upload.loadImageName;
                generatedMasterCount += 1;
              }
              directionMasterCell = cell;
              directionMasters.set(direction, cell);
            }
          }
          completedFrames.push({ ...frame, buffer: cell });
          done += 1;
          this.updateProgress(job, done, plan.length, frame.key);
        }
      }

      let directionConsistency = null;
      if (this.animation.engine === "deterministic") {
        let harmonizedMasters = null;
        if (studioTurntable) {
          const paletteInputs = new Map();
          for (const [direction, buffer] of directionMasters) {
            paletteInputs.set(`master:${direction}`, buffer);
          }
          for (const [frameKey, buffer] of studioMotionCells) {
            paletteInputs.set(`motion:${frameKey}`, buffer);
          }
          const harmonized = await harmonizeSpritePalette(paletteInputs, job.input);
          harmonizedMasters = new Map([...directionMasters.keys()].map((direction) => [
            direction,
            harmonized.get(`master:${direction}`),
          ]));
          for (const frameKey of studioMotionCells.keys()) {
            studioMotionCells.set(frameKey, harmonized.get(`motion:${frameKey}`));
          }
          const plannedClipByKey = new Map(plan.map((frame) => [frame.key, frame.clip.key]));
          const capturedMotionFrames = Object.fromEntries(
            STUDIO_CAPTURED_ANIMATION_CLIP_KEYS.map((clip) => [
              clip,
              [...studioMotionCells.keys()].filter((key) => plannedClipByKey.get(key) === clip).length,
            ]),
          );
          directionConsistency = {
            version: 8,
            mode: studioMotionCells.size
              ? "studio-direct-pixel-turntable-and-motion"
              : "studio-direct-pixel-turntable",
              generation: {
                generatedDirections: [...directionMasters.keys()],
                mirroredDirections: {},
                referenceMode: "authentic-roblox-3d-direct-pixelization",
                continuityMode: studioMotionCells.size
                  ? "equipped-roblox-locomotion-and-airborne-poses-plus-shared-palette"
                  : "exact-turntable-geometry-plus-shared-palette",
                registrationMode: studioMotionCells.size
                  ? "fixed-studio-camera-and-shared-direction-transform"
                  : "fixed-studio-camera",
                capturedWalkFrames: capturedMotionFrames.walk,
                capturedIdleFrames: capturedMotionFrames.idle,
                capturedIdleAltFrames: capturedMotionFrames.idle_alt,
                capturedRunFrames: capturedMotionFrames.run,
                capturedJumpFrames: capturedMotionFrames.jump,
                capturedFallFrames: capturedMotionFrames.fall,
                capturedClimbFrames: capturedMotionFrames.climb,
                capturedSwimIdleFrames: capturedMotionFrames.swim_idle,
                capturedSwimFrames: capturedMotionFrames.swim,
                capturedSwimUpFrames: capturedMotionFrames.swim_up,
                capturedSwimDownFrames: capturedMotionFrames.swim_down,
                seedMode: "not-applicable",
              },
            palette: { mode: "shared-master-palette", colors: job.input.paletteColors },
          };
        } else {
          const normalized = await normalizeDirectionalMasters(directionMasters, job.input);
          harmonizedMasters = await harmonizeDirectionMasterPalette(normalized.masters, job.input);
          directionConsistency = normalized.selection
            ? {
                ...normalized.selection,
                generation: {
                  generatedDirections: Object.entries(masterStrategies)
                    .filter(([, strategy]) => strategy.kind === "generated")
                    .map(([key]) => key),
                  mirroredDirections: Object.fromEntries(Object.entries(masterStrategies)
                    .filter(([, strategy]) => strategy.kind === "mirrored")
                    .map(([key, strategy]) => [key, strategy.sourceKey])),
                  referenceMode: "sequential-45-degree-turntable",
                  seedMode: "shared-canonical-seed",
                },
                palette: { mode: "shared-master-palette", colors: job.input.paletteColors },
              }
            : null;
        }
        if (directionConsistency && harmonizedMasters) {
          completedFrames.length = 0;
          for (const frame of plan) {
            const master = harmonizedMasters.get(frame.direction.key);
            const isDirectionMaster = frame.clip.key === "idle" && frame.frameIndex === 1;
            const capturedMotion = !isDirectionMaster ? studioMotionCells.get(frame.key) : null;
            let cell = isDirectionMaster
              ? master
              : capturedMotion
                ? capturedMotion
                : await removeIsolatedAlphaPixels(await animateCanonicalCell(master, frame));
            if (!isDirectionMaster && !capturedMotion && !(await hasStableMotionTopology(master, cell, {
              accessoryAware: Boolean(studioTurntable),
            }))) {
              console.warn("[motion-topology-fallback]", job.id, frame.key);
              cell = Buffer.from(master);
            }
            await fs.writeFile(path.join(framesDirectory, `${frame.key}.png`), cell);
            completedFrames.push({ ...frame, buffer: cell });
          }
        }
      }

      this.throwIfCanceled(job);
      this.update(job, {
        status: "processing",
        progress: {
          ...job.progress,
          stage: "packing",
          message: "Empacando la hoja, el atlas y el ZIP…",
          percent: 96,
          currentFrame: null,
        },
      });
      completedFrames.sort((a, b) => a.row - b.row || a.column - b.column);
      const sheet = await assembleSpriteSheet(completedFrames, job.input);
      const preview = await createPixelPreview(sheet, 4);
      const atlas = createAtlasData({
        username: bundle.user.username,
        cellSize: job.input.cellSize,
        frames: completedFrames,
      });
      const manifest = createManifest(job, plan, chroma, this.animation);
      manifest.directionConsistency = directionConsistency;
      manifest.studioCapture = studioTurntable
        ? {
            ...studioTurntable.source,
            referencesDirectory: "studio-references",
            animationCatalog: studioTurntable.animationCatalog,
          }
        : { mode: "web-thumbnail-fallback" };
      await Promise.all([
        fs.writeFile(path.join(jobDirectory, "sheet.png"), sheet),
        fs.writeFile(path.join(jobDirectory, "preview.png"), preview),
        fs.writeFile(path.join(jobDirectory, "sheet.json"), JSON.stringify(atlas, null, 2)),
        fs.writeFile(path.join(jobDirectory, "manifest.json"), JSON.stringify(manifest, null, 2)),
      ]);
      await createZip({
        jobDirectory,
        zipPath: path.join(jobDirectory, "roblox-sprites.zip"),
      });

      this.update(job, {
        status: "completed",
        progress: {
          stage: "completed",
          message: "Hoja de sprites terminada.",
          done: plan.length,
          total: plan.length,
          percent: 100,
          currentFrame: null,
        },
        result: {
          sheetUrl: `/outputs/${job.id}/sheet.png`,
          previewUrl: `/outputs/${job.id}/preview.png`,
          atlasUrl: `/outputs/${job.id}/sheet.json`,
          manifestUrl: `/outputs/${job.id}/manifest.json`,
          zipUrl: `/outputs/${job.id}/roblox-sprites.zip`,
          framesBaseUrl: `/outputs/${job.id}/frames/`,
          frameSize: job.input.cellSize,
          sheetWidth: job.input.cellSize * Math.max(...Object.values(frameCounts)),
          sheetHeight: job.input.cellSize * (Math.max(...plan.map((frame) => frame.row)) + 1),
          frameCount: plan.length,
          directions: [...new Set(plan.map((frame) => frame.direction.key))],
          clips: [...new Set(plan.map((frame) => frame.clip.key))],
          framesPerAnimation: job.input.framesPerAnimation,
          idleFramesPerAnimation: job.input.idleFramesPerAnimation,
          frameCounts,
          chroma: chroma.hex,
        },
      });
    } catch (error) {
      const canceled = job.cancelRequested || signal.aborted || error?.code === "job_canceled";
      if (canceled) {
        this.update(job, {
          status: "canceled",
          progress: { ...job.progress, stage: "canceled", message: "Trabajo cancelado." },
          error: null,
        });
      } else {
        const appError = asAppError(error);
        this.update(job, {
          status: "failed",
          progress: { ...job.progress, stage: "failed", message: "La generación falló." },
          error: {
            code: appError.code,
            message: appError.message,
            details: appError.details,
          },
        });
        console.error("[job-failed]", job.id, appError);
      }
    } finally {
      job.abortController = null;
      await this.persist(job);
    }
  }

  async generateFrame({
    job,
    bundle,
    frame,
    engine,
    referenceName,
    referenceKind,
    poseImageName,
    seed,
    chroma,
    signal,
    done,
    total,
  }) {
    this.throwIfCanceled(job);
    this.update(job, {
      status: "generating",
      progress: {
        stage: "comfy",
        message: `Generando ${frame.direction.label} · ${frame.clip.label} ${frame.frameIndex}/${frame.frameCount}…`,
        done,
        total,
        percent: Math.min(94, 3 + Math.round((done / total) * 91)),
        currentFrame: frame.key,
      },
    });
    const commonPromptInput = {
      bundle,
      direction: frame.direction,
      clip: frame.clip,
      frameIndex: frame.frameIndex,
      frameCount: frame.frameCount,
      notes: job.input.notes,
      chromaHex: chroma.hex,
      cellSize: job.input.cellSize,
      style: job.input.style,
      referenceKind,
    };
    const workflow = engine === "pose"
      ? buildPoseControlledSpriteWorkflow({
          imageName: referenceName,
          poseImageName,
          prompt: buildPoseAnimationPrompt(commonPromptInput),
          negativePrompt: buildPoseAnimationNegativePrompt(),
          seed,
          filenamePrefix: `RobloxSpriteForge_${job.id}_${frame.key}_pose`,
          renderResolution: job.input.renderResolution,
          models: this.models,
          animation: this.animation,
        })
      : buildFlux2KleinWorkflow({
          imageName: referenceName,
          poseImageName,
          prompt: buildFramePrompt(commonPromptInput),
          seed,
          filenamePrefix: `RobloxSpriteForge_${job.id}_${frame.key}_canonical`,
          steps: job.input.steps,
          renderResolution: job.input.renderResolution,
          models: this.models,
        });
    const generated = await this.comfy.runWorkflow({
      workflow,
      outputNodeId: engine === "pose" ? "13" : "19",
      signal,
    });
    this.throwIfCanceled(job);
    return generated.buffer;
  }

  async processAndSaveFrame({ job, frame, raw, chroma, framesDirectory, rawDirectory }) {
    const transparent = await removeChromaBackground(raw, chroma);
    const cell = await renderSpriteCell(transparent, job.input);
    const writes = [fs.writeFile(path.join(framesDirectory, `${frame.key}.png`), cell)];
    if (this.keepRawFrames) writes.push(fs.writeFile(path.join(rawDirectory, `${frame.key}.png`), raw));
    await Promise.all(writes);
    return cell;
  }

  updateProgress(job, done, total, currentFrame) {
    this.update(job, {
      status: "generating",
      progress: {
        stage: "comfy",
        message: `Frame ${done}/${total} terminado.`,
        done,
        total,
        percent: Math.min(94, 3 + Math.round((done / total) * 91)),
        currentFrame,
      },
    });
  }

  throwIfCanceled(job) {
    if (job.cancelRequested || job.abortController?.signal.aborted) {
      throw new AppError("Generación cancelada.", { status: 499, code: "job_canceled" });
    }
  }

  update(job, patch) {
    Object.assign(job, patch, { updatedAt: new Date().toISOString() });
    this.persist(job).catch(console.error);
  }

  publicJob(job) {
    return {
      id: job.id,
      status: job.status,
      createdAt: job.createdAt,
      updatedAt: job.updatedAt,
      input: job.input,
      progress: job.progress,
      avatar: job.avatar,
      result: job.result,
      error: job.error,
    };
  }

  persist(job) {
    const previous = this.persistChains.get(job.id) ?? Promise.resolve();
    const next = previous
      .catch(() => {})
      .then(async () => {
        const directory = path.join(this.outputDirectory, job.id);
        await fs.mkdir(directory, { recursive: true });
        const temporary = path.join(directory, "job.json.tmp");
        await fs.writeFile(temporary, JSON.stringify(this.publicJob(job), null, 2));
        await replaceFileWithRetry(temporary, path.join(directory, "job.json"));
      });
    this.persistChains.set(job.id, next);
    void next.then(
      () => {
        if (this.persistChains.get(job.id) === next) this.persistChains.delete(job.id);
      },
      () => {
        if (this.persistChains.get(job.id) === next) this.persistChains.delete(job.id);
      },
    );
    return next;
  }

  async loadPersistedJobs() {
    const entries = await fs.readdir(this.outputDirectory, { withFileTypes: true }).catch(() => []);
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      try {
        const raw = await fs.readFile(path.join(this.outputDirectory, entry.name, "job.json"), "utf8");
        const job = JSON.parse(raw);
        if (!job?.id || job.id !== entry.name) continue;
        const wasInterrupted = !["completed", "failed", "canceled"].includes(job.status);
        if (wasInterrupted) {
          job.status = "failed";
          job.updatedAt = new Date().toISOString();
          job.progress = {
            ...(job.progress ?? {}),
            stage: "failed",
            message: "El servidor se reinició durante la generación.",
          };
          job.error = {
            code: "server_restarted",
            message: "El servidor se reinició durante la generación.",
          };
        }
        job.cancelRequested = false;
        job.abortController = null;
        this.jobs.set(job.id, job);
        if (wasInterrupted) await this.persist(job);
      } catch {
        // Ignora carpetas que no correspondan a un trabajo válido.
      }
    }
  }

  async cleanupExpired() {
    const cutoff = Date.now() - this.retentionHours * 60 * 60_000;
    for (const [id, job] of this.jobs.entries()) {
      if (this.active === id || job.status === "queued") continue;
      const timestamp = Date.parse(job.updatedAt ?? job.createdAt);
      if (!Number.isFinite(timestamp) || timestamp >= cutoff) continue;
      await fs.rm(path.join(this.outputDirectory, id), { recursive: true, force: true });
      this.jobs.delete(id);
    }
  }
}

async function replaceFileWithRetry(temporary, destination) {
  let lastError = null;
  for (let attempt = 0; attempt < 6; attempt += 1) {
    try {
      await fs.rename(temporary, destination);
      return;
    } catch (error) {
      if (!new Set(["EPERM", "EACCES", "EBUSY"]).has(error?.code)) throw error;
      lastError = error;
      await new Promise((resolve) => setTimeout(resolve, 40 * (2 ** attempt)));
    }
  }
  throw lastError;
}

function mergeStudioCaptures({ reusable, fresh, recapturedClips, frameCounts }) {
  const images = new Map(reusable?.images ?? []);
  for (const [key, buffer] of fresh?.images ?? []) images.set(key, buffer);
  const mergedMotion = {};
  for (const clip of STUDIO_CAPTURED_ANIMATION_CLIP_KEYS) {
    const property = studioImagesProperty(clip);
    const selection = captureSelectionForClip(clip);
    const frames = new Map(recapturedClips.includes(selection) ? [] : reusable?.[property] ?? []);
    for (const [key, buffer] of fresh?.[property] ?? []) frames.set(key, buffer);
    mergedMotion[clip] = frames;
  }
  const reusedClips = STUDIO_CLIP_KEYS.filter((selection) => {
    if (recapturedClips.includes(selection)) return false;
    return selection === "idle"
      ? reusable?.images?.size === DIRECTIONS.length
        && reusable?.idleImages?.size === DIRECTIONS.length * frameCounts.idle
      : internalClipsForSelection(selection).every((clip) => (
          reusable?.[studioImagesProperty(clip)]?.size === DIRECTIONS.length * frameCounts[clip]
        ));
  });
  const source = {
    mode: "studio-3d-turntable",
    place: fresh?.source?.place ?? reusable?.source?.place ?? null,
    capturedDirections: DIRECTIONS.map((direction) => direction.key),
    capturedDirectionFrames: images.size,
    recapturedClips: [...recapturedClips],
    reusedClips,
    reusedFromJobId: reusable?.source?.reusedFromJobId ?? null,
  };
  for (const clip of STUDIO_CAPTURED_ANIMATION_CLIP_KEYS) {
    const sourceTitle = clip.split("_").map((part) => `${part[0].toUpperCase()}${part.slice(1)}`).join("");
    source[`captured${sourceTitle}Frames`] = mergedMotion[clip].size;
    const camelClip = clip.replace(/_([a-z])/g, (_, letter) => letter.toUpperCase());
    const motionSourceKey = `${camelClip}MotionSource`;
    source[motionSourceKey] = mergedMotion[clip].size
      ? "equipped-roblox-animation"
      : "deterministic-fallback";
  }
  return {
    images,
    ...Object.fromEntries(STUDIO_CAPTURED_ANIMATION_CLIP_KEYS.map((clip) => [
      studioImagesProperty(clip),
      mergedMotion[clip],
    ])),
    animationCatalog: fresh?.animationCatalog ?? reusable?.animationCatalog ?? {},
    source,
  };
}

function studioImagesProperty(clip) {
  return clip === "idle_alt" ? "idleAltImages" : `${clip}Images`;
}

async function readCapturedChromaHex(reference) {
  if (!reference) return "#FF00FF";
  const { data } = await sharp(reference)
    .ensureAlpha()
    .extract({ left: 0, top: 0, width: 1, height: 1 })
    .raw()
    .toBuffer({ resolveWithObject: true });
  return `#${[data[0], data[1], data[2]]
    .map((channel) => channel.toString(16).padStart(2, "0"))
    .join("")}`.toUpperCase();
}

function deriveDirectionSeed(baseSeed, row) {
  const maximum = BigInt(Number.MAX_SAFE_INTEGER - 100_000);
  const value = BigInt(baseSeed) + BigInt(row) * 104_729n;
  return Number(value % maximum);
}

function deriveFrameSeed(directionSeed, clipKey, frameIndex) {
  const maximum = BigInt(Number.MAX_SAFE_INTEGER - 100_000);
  const clipOffsets = {
    walk: 1_000_003n,
    run: 2_000_033n,
    jump: 3_000_091n,
    fall: 4_000_127n,
    climb: 5_000_167n,
    swim_idle: 6_000_203n,
    swim: 7_000_237n,
    swim_up: 8_000_269n,
    swim_down: 9_000_299n,
  };
  const clipOffset = clipOffsets[clipKey] ?? 0n;
  const phaseOffset = BigInt(frameIndex - 1) * 65_537n;
  return Number((BigInt(directionSeed) + clipOffset + phaseOffset) % maximum);
}

function isCompatibleDynamicAtlasJob(job) {
  const directions = job.result?.directions;
  const clips = job.result?.clips;
  const frames = Number(job.result?.framesPerAnimation ?? job.input?.framesPerAnimation);
  const requiredDirections = [
    "down",
    "down_left",
    "left",
    "up_left",
    "up",
    "up_right",
    "right",
    "down_right",
  ];
  return Array.isArray(directions)
    && requiredDirections.every((direction) => directions.includes(direction))
    && Array.isArray(clips)
    && clips.includes("idle")
    && clips.includes("walk")
    && clips.includes("run")
    && clips.includes("jump")
    && clips.includes("fall")
    && clips.includes("climb")
    && clips.includes("swim_idle")
    && clips.includes("swim")
    && clips.includes("swim_up")
    && clips.includes("swim_down")
    && [2, 4, 6, 8].includes(frames);
}

function createManifest(job, plan, chroma, animation) {
  const frameCounts = getClipFrameCounts(job.input);
  const columns = Math.max(...Object.values(frameCounts));
  const animations = {};
  for (const frame of plan) {
    const key = `${frame.direction.key}_${frame.clip.key}`;
    animations[key] ??= [];
    animations[key].push(frame.key);
  }
  return {
    generator: "Roblox Sprite Forge Local 1.0.0",
    generatedAt: new Date().toISOString(),
    source: {
      userId: job.avatar.user.id,
      username: job.avatar.user.username,
      displayName: job.avatar.user.displayName,
      profileUrl: job.avatar.user.profileUrl,
      thumbnailUrl: job.avatar.thumbnailUrl,
    },
    sheet: {
      image: "sheet.png",
      frameWidth: job.input.cellSize,
      frameHeight: job.input.cellSize,
      columns,
      rows: Math.max(...plan.map((frame) => frame.row)) + 1,
      order: "row-major",
    },
    animations,
    settings: {
      animationEngine: animation.engine,
      style: job.input.style,
      renderResolution: job.input.renderResolution,
      steps: job.input.steps,
      framesPerAnimation: job.input.framesPerAnimation,
      idleFramesPerAnimation: job.input.idleFramesPerAnimation,
      frameCounts,
      paletteColors: job.input.paletteColors,
      seed: job.input.seed,
      chroma: chroma.hex,
      clips: [...new Set(plan.map((frame) => frame.clip.key))],
    },
  };
}
