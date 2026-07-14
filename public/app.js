import { getAvatarDetailRecommendation } from "./avatar-detail.js";

const DIRECTIONS = [
  { key: "down", label: "Frente", dx: 0, dy: 1 },
  { key: "down_left", label: "Frente · izquierda", dx: -1, dy: 1 },
  { key: "left", label: "Izquierda", dx: -1, dy: 0 },
  { key: "up_left", label: "Espalda · izquierda", dx: -1, dy: -1 },
  { key: "up", label: "Espalda", dx: 0, dy: -1 },
  { key: "up_right", label: "Espalda · derecha", dx: 1, dy: -1 },
  { key: "right", label: "Derecha", dx: 1, dy: 0 },
  { key: "down_right", label: "Frente · derecha", dx: 1, dy: 1 },
];
const CLIPS = [
  "idle", "walk", "run", "jump", "fall", "climb", "idle_alt",
  "swim_idle", "swim", "swim_up", "swim_down",
];
const DEFAULT_IDLE_FRAMES = 16;
let frameNames = [];

const elements = {
  healthChip: document.querySelector("#healthChip"),
  healthPanel: document.querySelector("#healthPanel"),
  refreshHealth: document.querySelector("#refreshHealth"),
  avatarForm: document.querySelector("#avatarForm"),
  lookupButton: document.querySelector("#lookupButton"),
  source: document.querySelector("#source"),
  avatarCard: document.querySelector("#avatarCard"),
  generationForm: document.querySelector("#generationForm"),
  generateButton: document.querySelector("#generateButton"),
  cancelButton: document.querySelector("#cancelButton"),
  randomSeed: document.querySelector("#randomSeed"),
  seed: document.querySelector("#seed"),
  cellSize: document.querySelector("#cellSize"),
  renderResolution: document.querySelector("#renderResolution"),
  style: document.querySelector("#style"),
  steps: document.querySelector("#steps"),
  framesPerAnimation: document.querySelector("#framesPerAnimation"),
  paletteColors: document.querySelector("#paletteColors"),
  generationSummary: document.querySelector("#generationSummary"),
  detailRecommendation: document.querySelector("#detailRecommendation"),
  frameTotalLabel: document.querySelector("#frameTotalLabel"),
  notes: document.querySelector("#notes"),
  emptyOutput: document.querySelector("#emptyOutput"),
  progressView: document.querySelector("#progressView"),
  resultView: document.querySelector("#resultView"),
  errorView: document.querySelector("#errorView"),
  progressMessage: document.querySelector("#progressMessage"),
  progressPercent: document.querySelector("#progressPercent"),
  progressBar: document.querySelector("#progressBar"),
  frameCounter: document.querySelector("#frameCounter"),
  frameGrid: document.querySelector("#frameGrid"),
  sheetPreview: document.querySelector("#sheetPreview"),
  sheetSummary: document.querySelector("#sheetSummary"),
  downloadZip: document.querySelector("#downloadZip"),
  downloadSheet: document.querySelector("#downloadSheet"),
  downloadJson: document.querySelector("#downloadJson"),
  resultMeta: document.querySelector("#resultMeta"),
  liveStage: document.querySelector("#liveStage"),
  liveSprite: document.querySelector("#liveSprite"),
  pixelLadder: document.querySelector("#pixelLadder"),
  pixelPool: document.querySelector("#pixelPool"),
  directionLabel: document.querySelector("#directionLabel"),
  clipLabel: document.querySelector("#clipLabel"),
  frameLabel: document.querySelector("#frameLabel"),
  playToggle: document.querySelector("#playToggle"),
  resetPlayer: document.querySelector("#resetPlayer"),
  runToggle: document.querySelector("#runToggle"),
  climbToggle: document.querySelector("#climbToggle"),
  swimToggle: document.querySelector("#swimToggle"),
  captureReuseLabel: document.querySelector("#captureReuseLabel"),
  recaptureInputs: [...document.querySelectorAll("[data-recapture-clip]")],
  previewSpeed: document.querySelector("#previewSpeed"),
  speedValue: document.querySelector("#speedValue"),
  directionButtons: [...document.querySelectorAll("[data-direction]")],
};

const state = {
  health: null,
  avatar: null,
  avatarSource: null,
  job: null,
  pollTimer: null,
  defaultsApplied: false,
  lookupBusy: false,
  preview: {
    active: false,
    animationEnabled: true,
    animationTime: 0,
    lastTime: 0,
    direction: "down",
    clip: "idle",
    frameIndex: 1,
    framesPerAnimation: 8,
    frameCounts: buildClipFrameCounts(8, DEFAULT_IDLE_FRAMES),
    x: 0,
    y: 0,
    keys: new Set(),
    heldDirection: null,
    runLocked: false,
    shiftHeld: false,
    airborne: false,
    verticalVelocity: 0,
    airOffset: 0,
    climbing: false,
    swimming: false,
    idleWait: 0,
    idleAltActive: false,
    nextIdleAltAt: 6,
    availableClips: new Set(),
    avatarUserId: null,
    jobId: "",
    revision: "",
    framesBaseUrl: "",
    cacheKey: "",
  },
};

rebuildFrameGrid(8, DEFAULT_IDLE_FRAMES);
bindEvents();
requestAnimationFrame(updatePreview);
await loadHealth();
await restoreLatestCompletedJob();
window.setInterval(refreshCompletedRevision, 2_000);
window.addEventListener("focus", () => { void refreshCompletedRevision(); });
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) void refreshCompletedRevision();
});

function rebuildFrameGrid(
  framesPerAnimation = selectedFrameCount(),
  idleFramesPerAnimation = selectedIdleFrameCount(),
) {
  frameNames = buildFrameNames(framesPerAnimation, idleFramesPerAnimation);
  elements.frameGrid.replaceChildren();
  for (const [index, name] of frameNames.entries()) {
    const cell = document.createElement("div");
    cell.className = "frame-cell";
    cell.dataset.frame = name;
    cell.title = name;
    cell.textContent = String(index + 1).padStart(2, "0");
    elements.frameGrid.append(cell);
  }
  updateFrameConfigurationCopy(framesPerAnimation, idleFramesPerAnimation);
}

function buildFrameNames(framesPerAnimation, idleFramesPerAnimation = framesPerAnimation) {
  const frameCounts = buildClipFrameCounts(framesPerAnimation, idleFramesPerAnimation);
  return DIRECTIONS.flatMap((direction) => CLIPS.flatMap((clip) =>
    Array.from({ length: frameCounts[clip] }, (_, index) => `${direction.key}_${clip}_${index + 1}`),
  ));
}

function bindEvents() {
  elements.avatarForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    await lookupAvatar();
  });
  elements.generationForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    await startGeneration();
  });
  elements.cancelButton.addEventListener("click", cancelGeneration);
  elements.refreshHealth.addEventListener("click", loadHealth);
  elements.randomSeed.addEventListener("click", () => {
    elements.seed.value = String(Math.floor(Math.random() * 2_147_483_647));
  });
  elements.framesPerAnimation.addEventListener("change", () => rebuildFrameGrid());
  elements.source.addEventListener("input", () => {
    if (!state.avatar || elements.source.value.trim() === state.avatarSource) return;
    state.avatar = null;
    state.avatarSource = null;
    renderAvatar(null);
    updateGenerateState();
  });
  elements.playToggle.addEventListener("click", () => {
    state.preview.animationEnabled = !state.preview.animationEnabled;
    elements.playToggle.textContent = state.preview.animationEnabled ? "Pausar" : "Reproducir";
  });
  elements.resetPlayer.addEventListener("click", resetPlayerPosition);
  elements.runToggle.addEventListener("click", () => {
    state.preview.runLocked = !state.preview.runLocked;
    updateRunToggle();
  });
  elements.climbToggle.addEventListener("click", togglePreviewClimb);
  elements.swimToggle.addEventListener("click", togglePreviewSwim);
  elements.previewSpeed.addEventListener("input", () => {
    elements.speedValue.value = elements.previewSpeed.value;
    elements.speedValue.textContent = elements.previewSpeed.value;
  });
  elements.liveStage.addEventListener("pointerdown", () => elements.liveStage.focus());
  elements.liveStage.addEventListener("keydown", handleStageKeyDown);
  elements.liveStage.addEventListener("keyup", handleStageKeyUp);
  elements.liveStage.addEventListener("blur", () => {
    state.preview.keys.clear();
    state.preview.shiftHeld = false;
  });
  window.addEventListener("resize", constrainPlayer);

  for (const button of elements.directionButtons) {
    button.addEventListener("pointerdown", (event) => {
      event.preventDefault();
      state.preview.heldDirection = button.dataset.direction;
      setPreviewDirection(button.dataset.direction);
      elements.liveStage.focus();
      button.setPointerCapture?.(event.pointerId);
    });
    const release = () => { state.preview.heldDirection = null; };
    button.addEventListener("pointerup", release);
    button.addEventListener("pointercancel", release);
    button.addEventListener("lostpointercapture", release);
    button.addEventListener("click", () => {
      release();
      setPreviewDirection(button.dataset.direction);
    });
  }
  window.addEventListener("pointerup", () => { state.preview.heldDirection = null; });
}

async function restoreLatestCompletedJob() {
  try {
    const payload = await requestJson("/api/jobs");
    const latest = payload.jobs?.find((job) =>
      job.status === "completed" &&
      job.result?.clips?.includes("idle") &&
      job.result?.clips?.includes("walk") &&
      job.result?.clips?.includes("run") &&
      job.result?.clips?.includes("jump") &&
      job.result?.clips?.includes("fall") &&
      Number.isInteger(job.result?.framesPerAnimation),
    );
    if (!latest) return;
    state.avatar = latest.avatar;
    state.avatarSource = latest.input.source;
    elements.source.value = latest.input.source;
    setSelectValue(elements.framesPerAnimation, latest.result.framesPerAnimation);
    rebuildFrameGrid(
      latest.result.framesPerAnimation,
      latest.result.idleFramesPerAnimation ?? selectedIdleFrameCount(),
    );
    renderAvatar(latest.avatar);
    renderJob(latest);
  } catch {
    // La restauración es opcional; la creación de un set nuevo sigue disponible.
  }
}

async function loadHealth() {
  elements.refreshHealth.disabled = true;
  try {
    const health = await requestJson("/api/health");
    state.health = health;
    if (!state.defaultsApplied) {
      applyDefaults(health.defaults);
      state.defaultsApplied = true;
    }
    const comfy = health.comfy;
    elements.healthChip.className = `status-chip ${comfy.ok ? "ok" : "error"}`;
    elements.healthChip.lastElementChild.textContent = comfy.ok
      ? compactDeviceName(comfy.device?.name) || "GPU lista"
      : comfy.reachable ? "ComfyUI incompleto" : "ComfyUI desconectado";
    if (!comfy.ok) {
      const details = [
        comfy.error,
        comfy.missingNodes?.length ? `Nodos faltantes: ${comfy.missingNodes.join(", ")}` : "",
        comfy.missingModels?.length ? `Modelos faltantes: ${comfy.missingModels.join(", ")}` : "",
      ].filter(Boolean);
      elements.healthPanel.innerHTML = `${escapeHtml(details.join(" · "))}<br><strong>Abre ComfyUI y ejecuta <code>npm run doctor</code>.</strong>`;
      elements.healthPanel.classList.remove("hidden");
    } else {
      elements.healthPanel.classList.add("hidden");
    }
  } catch (error) {
    state.health = null;
    elements.healthChip.className = "status-chip error";
    elements.healthChip.lastElementChild.textContent = "Servidor no disponible";
    showError(error.message);
  } finally {
    elements.refreshHealth.disabled = false;
    updateGenerateState();
  }
}

async function lookupAvatar() {
  const source = elements.source.value.trim();
  if (!source || state.job || state.lookupBusy) return;
  state.lookupBusy = true;
  setButtonBusy(elements.lookupButton, true, "Buscando…");
  clearError();
  updateGenerateState();
  try {
    const avatar = await requestJson("/api/avatar", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ source }),
    });
    state.avatar = avatar;
    state.avatarSource = source;
    renderAvatar(avatar);
  } catch (error) {
    state.avatar = null;
    state.avatarSource = null;
    renderAvatar(null);
    showError(error.message);
  } finally {
    state.lookupBusy = false;
    setButtonBusy(elements.lookupButton, false, "Buscar");
    updateGenerateState();
  }
}

async function startGeneration() {
  const source = elements.source.value.trim();
  const avatarIsCurrent = state.avatar && state.avatarSource === source;
  if (!avatarIsCurrent || !state.health?.comfy?.ok || state.job) return;
  const reuseCaptureJobId = Number(state.preview.avatarUserId) === Number(state.avatar.user.id)
    ? state.preview.jobId
    : null;
  const recaptureClips = elements.recaptureInputs
    .filter((input) => input.checked)
    .map((input) => input.value);
  clearError();
  resetOutput();
  const body = {
    source: state.avatarSource,
    cellSize: Number(elements.cellSize.value),
    renderResolution: Number(elements.renderResolution.value),
    style: elements.style.value,
    steps: Number(elements.steps.value),
    framesPerAnimation: selectedFrameCount(),
    idleFramesPerAnimation: selectedIdleFrameCount(),
    paletteColors: Number(elements.paletteColors.value),
    seed: elements.seed.value.trim(),
    notes: elements.notes.value,
    reuseCaptureJobId,
    recaptureClips,
  };
  try {
    const job = await requestJson("/api/jobs", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    state.job = job;
    elements.cancelButton.classList.remove("hidden");
    updateGenerateState();
    renderJob(job);
    pollJob();
  } catch (error) {
    showIdleOutput();
    showError(error.message);
    updateGenerateState();
  }
}

async function cancelGeneration() {
  if (!state.job) return;
  elements.cancelButton.disabled = true;
  try {
    const job = await requestJson(`/api/jobs/${state.job.id}/cancel`, { method: "POST" });
    state.job = job;
    renderJob(job);
  } catch (error) {
    showError(error.message);
  } finally {
    elements.cancelButton.disabled = false;
  }
}

function pollJob() {
  clearTimeout(state.pollTimer);
  if (!state.job) return;
  state.pollTimer = setTimeout(async () => {
    try {
      const job = await requestJson(`/api/jobs/${state.job.id}`);
      state.job = job;
      renderJob(job);
      if (!isTerminal(job.status)) pollJob();
    } catch (error) {
      showError(error.message);
      if ([400, 404].includes(error.status)) {
        state.job = null;
        elements.cancelButton.classList.add("hidden");
        showIdleOutput();
        updateGenerateState();
        return;
      }
      pollJob();
    }
  }, 1100);
}

function renderJob(job) {
  const progress = job.progress ?? {};
  const jobFramesPerAnimation = job.input?.framesPerAnimation ?? selectedFrameCount();
  const jobIdleFrames = job.input?.idleFramesPerAnimation ?? job.result?.frameCounts?.idle ?? jobFramesPerAnimation;
  const total = progress.total ?? calculateFrameTotal(jobFramesPerAnimation, jobIdleFrames);
  if (elements.frameGrid.children.length !== total) rebuildFrameGrid(jobFramesPerAnimation, jobIdleFrames);
  const percent = Math.max(0, Math.min(100, Number(progress.percent ?? 0)));
  elements.progressMessage.textContent = progress.message ?? job.status;
  elements.progressPercent.textContent = `${percent}%`;
  elements.progressBar.style.width = `${percent}%`;
  elements.frameCounter.textContent = `${progress.done ?? 0} / ${total} frames`;

  for (const [index, name] of frameNames.entries()) {
    const cell = elements.frameGrid.children[index];
    cell.classList.toggle("done", index < (progress.done ?? 0));
    cell.classList.toggle("active", progress.currentFrame === name);
  }

  if (job.status === "completed") {
    clearTimeout(state.pollTimer);
    elements.emptyOutput.classList.add("hidden");
    elements.progressView.classList.add("hidden");
    elements.resultView.classList.remove("hidden");
    elements.cancelButton.classList.add("hidden");
    const cacheKey = encodeURIComponent(job.updatedAt);
    elements.sheetPreview.src = `${job.result.sheetUrl}?v=${cacheKey}`;
    elements.downloadZip.href = `${job.result.zipUrl}?v=${cacheKey}`;
    elements.downloadSheet.href = `${job.result.sheetUrl}?v=${cacheKey}`;
    elements.downloadJson.href = `${job.result.atlasUrl}?v=${cacheKey}`;
    const frameCounts = job.result.frameCounts ?? buildClipFrameCounts(
      job.result.framesPerAnimation,
      job.result.idleFramesPerAnimation ?? job.result.framesPerAnimation,
    );
    elements.sheetSummary.textContent = `idle ${frameCounts.idle} · otros ${frameCounts.walk} · ${job.result.frameCount} frames · ${job.result.sheetWidth} × ${job.result.sheetHeight}px`;
    elements.resultMeta.innerHTML = `
      <dt>Usuario</dt><dd>@${escapeHtml(job.avatar.user.username)}</dd>
      <dt>Frame</dt><dd>${job.result.frameSize} × ${job.result.frameSize}px</dd>
      <dt>Direcciones</dt><dd>${job.result.directions?.length ?? 8}</dd>
      <dt>Clips</dt><dd>${job.result.clips.join(" + ")}</dd>
      <dt>Frames/clip</dt><dd>idle ${frameCounts.idle} · otros ${frameCounts.walk}</dd>
      <dt>Sheet</dt><dd>${job.result.sheetWidth} × ${job.result.sheetHeight}px</dd>
      <dt>Semilla</dt><dd>${job.input.seed}</dd>
      <dt>Chroma</dt><dd>${escapeHtml(job.result.chroma)}</dd>
    `;
    applyJobSettings(job.input);
    initializeLivePreview(job, cacheKey);
    state.job = null;
    updateGenerateState();
  } else if (job.status === "failed") {
    clearTimeout(state.pollTimer);
    elements.cancelButton.classList.add("hidden");
    showIdleOutput();
    showError(`${job.error?.message ?? "La generación falló."}${formatDetails(job.error?.details)}`);
    state.job = null;
    updateGenerateState();
  } else if (job.status === "canceled") {
    clearTimeout(state.pollTimer);
    elements.cancelButton.classList.add("hidden");
    showIdleOutput();
    showError("La generación fue cancelada. Los frames ya guardados permanecen en data/generated hasta la limpieza automática.");
    state.job = null;
    updateGenerateState();
  }
}

function initializeLivePreview(job, cacheKey) {
  state.preview.active = true;
  state.preview.jobId = job.id;
  state.preview.revision = job.updatedAt;
  state.preview.framesBaseUrl = job.result.framesBaseUrl;
  state.preview.cacheKey = cacheKey;
  state.preview.direction = "down";
  state.preview.clip = "idle";
  state.preview.frameIndex = 1;
  state.preview.framesPerAnimation = job.result.framesPerAnimation;
  state.preview.frameCounts = job.result.frameCounts ?? buildClipFrameCounts(
    job.result.framesPerAnimation,
    job.result.idleFramesPerAnimation ?? job.result.framesPerAnimation,
  );
  state.preview.availableClips = new Set(job.result.clips ?? []);
  state.preview.avatarUserId = job.avatar?.user?.id ?? null;
  state.preview.animationTime = 0;
  state.preview.animationEnabled = true;
  state.preview.keys.clear();
  state.preview.heldDirection = null;
  state.preview.runLocked = false;
  state.preview.shiftHeld = false;
  state.preview.airborne = false;
  state.preview.verticalVelocity = 0;
  state.preview.airOffset = 0;
  state.preview.climbing = false;
  state.preview.swimming = false;
  state.preview.idleWait = 0;
  state.preview.idleAltActive = false;
  state.preview.nextIdleAltAt = nextIdleAlternateDelay();
  updateRunToggle();
  updateClimbToggle();
  updateSwimToggle();
  elements.playToggle.textContent = "Pausar";
  const displaySize = Math.max(112, Math.min(192, job.result.frameSize * 2.5));
  elements.liveSprite.style.width = `${displaySize}px`;
  elements.liveSprite.style.height = `${displaySize}px`;
  resetPlayerPosition();
  setSpriteFrame(true);
  syncRecaptureControls(job);
  elements.liveStage.focus({ preventScroll: true });
}

async function refreshCompletedRevision() {
  if (state.job || !state.preview.jobId) return;
  try {
    const job = await requestJson(
      `/api/jobs/${state.preview.jobId}?revision=${Date.now()}`,
      { cache: "no-store" },
    );
    if (job.status !== "completed" || job.updatedAt === state.preview.revision) return;
    renderJob(job);
  } catch {
    // Una revisión es oportunista: una caída momentánea del servidor no debe
    // interrumpir el preview que ya está visible.
  }
}

function handleStageKeyDown(event) {
  if (String(event.key).toLowerCase() === "e") {
    event.preventDefault();
    if (!event.repeat) togglePreviewClimb();
    return;
  }
  if (event.code === "Space" || event.key === " ") {
    event.preventDefault();
    if (state.preview.swimming) {
      state.preview.keys.add("ascend");
      return;
    }
    if (!event.repeat) {
      if (state.preview.climbing) leavePreviewClimb();
      startPreviewJump();
    }
    return;
  }
  if (event.key === "Control" && state.preview.swimming) {
    event.preventDefault();
    state.preview.keys.add("descend");
    return;
  }
  if (event.key === "Shift") {
    event.preventDefault();
    state.preview.shiftHeld = true;
    updateRunToggle();
    return;
  }
  const key = normalizeMovementKey(event.key);
  if (!key) return;
  event.preventDefault();
  state.preview.keys.add(key);
}

function handleStageKeyUp(event) {
  if (event.code === "Space" || event.key === " ") {
    state.preview.keys.delete("ascend");
    return;
  }
  if (event.key === "Control") {
    state.preview.keys.delete("descend");
    return;
  }
  if (event.key === "Shift") {
    event.preventDefault();
    state.preview.shiftHeld = false;
    updateRunToggle();
    return;
  }
  const key = normalizeMovementKey(event.key);
  if (!key) return;
  event.preventDefault();
  state.preview.keys.delete(key);
}

function normalizeMovementKey(key) {
  const normalized = String(key).toLowerCase();
  return ({ w: "up", arrowup: "up", s: "down", arrowdown: "down", a: "left", arrowleft: "left", d: "right", arrowright: "right" })[normalized] ?? null;
}

function updatePreview(timestamp) {
  const preview = state.preview;
  const delta = Math.min(0.05, Math.max(0, (timestamp - (preview.lastTime || timestamp)) / 1000));
  preview.lastTime = timestamp;
  if (preview.active && !elements.resultView.classList.contains("hidden")) {
    const vector = getMovementVector();
    const climbing = preview.climbing && preview.availableClips.has("climb");
    const swimming = preview.swimming && hasCompleteSwimPreview();
    const climbingMoving = climbing && vector.dy !== 0;
    const swimPitch = preview.keys.has("ascend") ? "up" : preview.keys.has("descend") ? "down" : "level";
    const swimmingMoving = swimming && (vector.dx !== 0 || vector.dy !== 0 || swimPitch !== "level");
    const moving = climbing ? climbingMoving : swimming ? swimmingMoving : vector.dx !== 0 || vector.dy !== 0;
    const running = !swimming && moving && (preview.runLocked || preview.shiftHeld);
    let nextClip = swimming
      ? (swimmingMoving ? (swimPitch === "up" ? "swim_up" : swimPitch === "down" ? "swim_down" : "swim") : "swim_idle")
      : climbing
      ? "climb"
      : preview.airborne
      ? (preview.verticalVelocity < 0 ? "jump" : "fall")
      : moving
        ? (running ? "run" : "walk")
        : "idle";
    if (!swimming && nextClip === "idle" && preview.availableClips.has("idle_alt")) {
      preview.idleWait += delta;
      if (!preview.idleAltActive && preview.idleWait >= preview.nextIdleAltAt) {
        preview.idleAltActive = true;
      }
      if (preview.idleAltActive) nextClip = "idle_alt";
    } else if (nextClip !== "idle_alt") {
      preview.idleWait = 0;
      preview.idleAltActive = false;
      preview.nextIdleAltAt = nextIdleAlternateDelay();
    }
    if (preview.clip !== nextClip) {
      preview.clip = nextClip;
      preview.animationTime = 0;
      preview.frameIndex = 1;
    }
    if (swimming) {
      if (vector.dx !== 0 || vector.dy !== 0) {
        const length = Math.hypot(vector.dx, vector.dy) || 1;
        preview.x += (vector.dx / length) * 96 * delta;
        preview.y += (vector.dy / length) * 96 * delta;
        setPreviewDirection(directionFromVector(vector.dx, vector.dy), false);
      }
      constrainPlayer();
    } else if (climbing) {
      const ladder = getPreviewLadderBounds();
      preview.x = ladder.x;
      preview.y = Math.max(ladder.top, Math.min(ladder.bottom, preview.y + vector.dy * 86 * delta));
      setPreviewDirection("up", false);
    } else if (moving) {
      const length = Math.hypot(vector.dx, vector.dy) || 1;
      const nx = vector.dx / length;
      const ny = vector.dy / length;
      const speed = running ? 184 : 112;
      preview.x += nx * speed * delta;
      preview.y += ny * speed * delta;
      setPreviewDirection(directionFromVector(vector.dx, vector.dy), false);
      constrainPlayer();
    }
    if (preview.airborne) {
      preview.verticalVelocity += 820 * delta;
      preview.airOffset += preview.verticalVelocity * delta;
      if (preview.airOffset >= 0) {
        preview.airOffset = 0;
        preview.verticalVelocity = 0;
        preview.airborne = false;
      }
    }
    if (preview.animationEnabled && !(climbing && !climbingMoving)) {
      preview.animationTime += delta;
      const baseFps = Number(elements.previewSpeed.value);
      const currentFrameCount = preview.frameCounts?.[preview.clip] ?? preview.framesPerAnimation;
      const fps = preview.clip === "idle" || preview.clip === "idle_alt" || preview.clip === "swim_idle"
        ? (baseFps / 8) * (currentFrameCount / 4)
        : preview.clip === "run"
          ? baseFps * 1.4
          : preview.clip === "jump" || preview.clip === "fall" || preview.clip === "climb"
            ? baseFps * 1.1
            : baseFps;
      const rawFrame = Math.floor(preview.animationTime * fps);
      preview.frameIndex = preview.clip === "jump"
        ? Math.min(currentFrameCount, rawFrame + 1)
        : rawFrame % currentFrameCount + 1;
      if (preview.clip === "idle_alt" && rawFrame >= currentFrameCount) {
        preview.idleAltActive = false;
        preview.idleWait = 0;
        preview.nextIdleAltAt = nextIdleAlternateDelay();
      }
    } else if (climbing) {
      preview.frameIndex = 1;
      preview.animationTime = 0;
    }
    elements.liveSprite.style.left = `${preview.x}px`;
    elements.liveSprite.style.top = `${preview.y + preview.airOffset}px`;
    setSpriteFrame();
  }
  requestAnimationFrame(updatePreview);
}

function startPreviewJump() {
  const preview = state.preview;
  if (!preview.active || preview.airborne || preview.swimming) return;
  preview.airborne = true;
  preview.verticalVelocity = -330;
  preview.airOffset = 0;
  preview.clip = "jump";
  preview.animationTime = 0;
  preview.frameIndex = 1;
}

function togglePreviewClimb() {
  const preview = state.preview;
  if (!preview.active || !preview.availableClips.has("climb")) return;
  if (preview.climbing) {
    leavePreviewClimb();
    return;
  }
  const ladder = getPreviewLadderBounds();
  preview.climbing = true;
  preview.swimming = false;
  preview.airborne = false;
  preview.airOffset = 0;
  preview.verticalVelocity = 0;
  preview.x = ladder.x;
  preview.y = ladder.bottom;
  preview.clip = "climb";
  preview.frameIndex = 1;
  preview.animationTime = 0;
  preview.runLocked = false;
  setPreviewDirection("up");
  updateRunToggle();
  updateClimbToggle();
  updateSwimToggle();
  elements.liveStage.focus({ preventScroll: true });
}

function togglePreviewSwim() {
  const preview = state.preview;
  if (!preview.active || !hasCompleteSwimPreview()) return;
  preview.swimming = !preview.swimming;
  preview.climbing = false;
  preview.airborne = false;
  preview.airOffset = 0;
  preview.verticalVelocity = 0;
  preview.runLocked = false;
  preview.keys.delete("ascend");
  preview.keys.delete("descend");
  if (preview.swimming) {
    const pool = getPreviewPoolBounds();
    preview.x = (pool.left + pool.right) / 2;
    preview.y = (pool.top + pool.bottom) / 2;
    preview.clip = "swim_idle";
  } else {
    const stage = elements.liveStage.getBoundingClientRect();
    preview.x = stage.width / 2;
    preview.y = stage.height * 0.57;
    preview.clip = "idle";
  }
  preview.frameIndex = 1;
  preview.animationTime = 0;
  updateRunToggle();
  updateClimbToggle();
  updateSwimToggle();
  constrainPlayer();
  setSpriteFrame(true);
  elements.liveStage.focus({ preventScroll: true });
}

function getPreviewPoolBounds() {
  const stage = elements.liveStage.getBoundingClientRect();
  const pool = elements.pixelPool.getBoundingClientRect();
  const spriteSize = elements.liveSprite.getBoundingClientRect().width || 140;
  return {
    left: pool.left - stage.left + spriteSize * 0.32,
    right: pool.right - stage.left - spriteSize * 0.32,
    top: pool.top - stage.top + spriteSize * 0.3,
    bottom: pool.bottom - stage.top - spriteSize * 0.3,
  };
}

function leavePreviewClimb() {
  const preview = state.preview;
  if (!preview.climbing) return;
  const ladder = getPreviewLadderBounds();
  preview.climbing = false;
  preview.y = ladder.bottom;
  preview.clip = "idle";
  preview.frameIndex = 1;
  preview.animationTime = 0;
  updateClimbToggle();
}

function getPreviewLadderBounds() {
  const stage = elements.liveStage.getBoundingClientRect();
  const ladder = elements.pixelLadder.getBoundingClientRect();
  const spriteSize = elements.liveSprite.getBoundingClientRect().height || 140;
  return {
    x: ladder.left - stage.left + ladder.width / 2,
    top: ladder.top - stage.top + spriteSize * 0.23,
    bottom: ladder.bottom - stage.top - spriteSize * 0.23,
  };
}

function getMovementVector() {
  const keys = state.preview.keys;
  let dx = (keys.has("right") ? 1 : 0) - (keys.has("left") ? 1 : 0);
  let dy = (keys.has("down") ? 1 : 0) - (keys.has("up") ? 1 : 0);
  if (!dx && !dy && state.preview.heldDirection) {
    const direction = DIRECTIONS.find((item) => item.key === state.preview.heldDirection);
    dx = direction?.dx ?? 0;
    dy = direction?.dy ?? 0;
  }
  return { dx, dy };
}

function directionFromVector(dx, dy) {
  if (dx < 0 && dy < 0) return "up_left";
  if (dx > 0 && dy < 0) return "up_right";
  if (dx < 0 && dy > 0) return "down_left";
  if (dx > 0 && dy > 0) return "down_right";
  if (dy < 0) return "up";
  if (dy > 0) return "down";
  if (dx < 0) return "left";
  if (dx > 0) return "right";
  return state.preview.direction;
}

function setPreviewDirection(directionKey) {
  if (!DIRECTIONS.some((direction) => direction.key === directionKey)) return;
  state.preview.direction = directionKey;
  const direction = DIRECTIONS.find((item) => item.key === directionKey);
  elements.directionLabel.textContent = direction.label;
  for (const button of elements.directionButtons) {
    button.classList.toggle("active", button.dataset.direction === directionKey);
  }
  setSpriteFrame();
}

function setSpriteFrame(force = false) {
  if (!state.preview.framesBaseUrl) return;
  const frame = `${state.preview.direction}_${state.preview.clip}_${state.preview.frameIndex}.png`;
  if (!force && elements.liveSprite.dataset.frame === frame) return;
  elements.liveSprite.dataset.frame = frame;
  elements.liveSprite.src = `${state.preview.framesBaseUrl}${frame}?v=${state.preview.cacheKey}`;
  elements.frameLabel.textContent = frame;
  elements.clipLabel.textContent = `${state.preview.clip.toUpperCase()} · DIRECCIÓN ACTUAL`;
}

function updateRunToggle() {
  const active = state.preview.runLocked || state.preview.shiftHeld;
  elements.runToggle.classList.toggle("active", active);
  elements.runToggle.setAttribute("aria-pressed", String(state.preview.runLocked));
  elements.runToggle.textContent = active ? "Corriendo" : "Correr";
}

function updateClimbToggle() {
  const available = state.preview.availableClips.has("climb");
  elements.climbToggle.disabled = !available;
  elements.climbToggle.classList.toggle("active", state.preview.climbing);
  elements.climbToggle.setAttribute("aria-pressed", String(state.preview.climbing));
  elements.climbToggle.textContent = available
    ? (state.preview.climbing ? "Escalando" : "Escalar")
    : "Climb pendiente";
}

function hasCompleteSwimPreview() {
  return ["swim_idle", "swim", "swim_up", "swim_down"]
    .every((clip) => state.preview.availableClips.has(clip));
}

function updateSwimToggle() {
  const available = hasCompleteSwimPreview();
  elements.swimToggle.disabled = !available;
  elements.swimToggle.classList.toggle("active", state.preview.swimming);
  elements.swimToggle.setAttribute("aria-pressed", String(state.preview.swimming));
  elements.swimToggle.textContent = available
    ? (state.preview.swimming ? "Nadando" : "Nadar")
    : "Nado pendiente";
}

function resetPlayerPosition() {
  const rect = elements.liveStage.getBoundingClientRect();
  state.preview.x = rect.width / 2;
  state.preview.y = rect.height * 0.57;
  state.preview.direction = "down";
  state.preview.clip = "idle";
  state.preview.frameIndex = 1;
  state.preview.animationTime = 0;
  state.preview.runLocked = false;
  state.preview.shiftHeld = false;
  state.preview.airborne = false;
  state.preview.verticalVelocity = 0;
  state.preview.airOffset = 0;
  state.preview.climbing = false;
  state.preview.swimming = false;
  state.preview.idleWait = 0;
  state.preview.idleAltActive = false;
  state.preview.nextIdleAltAt = nextIdleAlternateDelay();
  updateRunToggle();
  updateClimbToggle();
  updateSwimToggle();
  setPreviewDirection("down");
  constrainPlayer();
}

function constrainPlayer() {
  if (!state.preview.active) return;
  if (state.preview.climbing) {
    const ladder = getPreviewLadderBounds();
    state.preview.x = ladder.x;
    state.preview.y = Math.max(ladder.top, Math.min(ladder.bottom, state.preview.y));
    return;
  }
  if (state.preview.swimming) {
    const pool = getPreviewPoolBounds();
    state.preview.x = Math.max(pool.left, Math.min(pool.right, state.preview.x));
    state.preview.y = Math.max(pool.top, Math.min(pool.bottom, state.preview.y));
    return;
  }
  const rect = elements.liveStage.getBoundingClientRect();
  const spriteSize = elements.liveSprite.getBoundingClientRect().width || 140;
  const margin = spriteSize * 0.34;
  state.preview.x = Math.max(margin, Math.min(rect.width - margin, state.preview.x || rect.width / 2));
  state.preview.y = Math.max(spriteSize * .42, Math.min(rect.height - spriteSize * .28, state.preview.y || rect.height * .57));
}

function syncRecaptureControls(job) {
  const available = new Set(job?.result?.clips ?? []);
  for (const input of elements.recaptureInputs) {
    input.checked = !available.has(input.value);
  }
  elements.captureReuseLabel.textContent = job?.id
    ? `Base ${job.id.slice(0, 8)} · se reutiliza lo guardado; marca solo los clips que quieras volver a capturar.`
    : "No hay un set base compatible; Studio capturará automáticamente lo que falte.";
}

function renderAvatar(avatar) {
  if (!avatar) {
    applyAvatarDetailRecommendation(null);
    elements.avatarCard.className = "avatar-card empty";
    elements.avatarCard.innerHTML = `<div class="avatar-placeholder">?</div><div><strong>Sin personaje</strong><p>Busca un perfil para usarlo como referencia.</p></div>`;
    return;
  }
  if (Number(state.preview.avatarUserId) !== Number(avatar.user.id)) syncRecaptureControls(null);
  const tags = avatar.avatar.assets.slice(0, 5).map((asset) => `<span>${escapeHtml(asset.name)}</span>`).join("");
  elements.avatarCard.className = "avatar-card";
  elements.avatarCard.innerHTML = `
    <img src="${escapeAttribute(avatar.thumbnailUrl)}" alt="Avatar de ${escapeAttribute(avatar.user.username)}" />
    <div><strong>${escapeHtml(avatar.user.displayName)} · @${escapeHtml(avatar.user.username)}</strong><p>ID ${avatar.user.id} · ${avatar.avatar.assetCount} objetos · <a href="${escapeAttribute(avatar.user.profileUrl)}" target="_blank" rel="noreferrer">perfil</a></p><div class="avatar-tags">${tags}</div><span class="feature-audit">Referencia visual prioritaria · metadatos verificados</span></div>
  `;
  applyAvatarDetailRecommendation(avatar);
}

function applyAvatarDetailRecommendation(avatar) {
  const recommendation = getAvatarDetailRecommendation(avatar);
  if (!recommendation.needsHighDetail) {
    elements.detailRecommendation.classList.add("hidden");
    elements.detailRecommendation.textContent = "";
    return;
  }
  setSelectValue(elements.cellSize, recommendation.recommendedCellSize);
  setSelectValue(elements.renderResolution, recommendation.recommendedRenderResolution);
  const accessoryCopy = recommendation.reasons.includes("tall-accessory")
    ? " y accesorios verticales"
    : "";
  elements.detailRecommendation.textContent = `Detalle adaptativo activado · proporción ${recommendation.height.toFixed(2)} alto / ${recommendation.width.toFixed(2)} ancho${accessoryCopy}. Se seleccionó 128 × 128 y resolución 1024 para conservar píxeles del cuerpo.`;
  elements.detailRecommendation.classList.remove("hidden");
}

function resetOutput() {
  state.preview.active = false;
  state.preview.climbing = false;
  state.preview.jobId = "";
  state.preview.revision = "";
  state.preview.keys.clear();
  updateClimbToggle();
  elements.emptyOutput.classList.add("hidden");
  elements.progressView.classList.remove("hidden");
  elements.resultView.classList.add("hidden");
  elements.errorView.classList.add("hidden");
  elements.progressBar.style.width = "0%";
  elements.progressPercent.textContent = "0%";
  elements.frameCounter.textContent = `0 / ${calculateFrameTotal()} frames`;
  for (const cell of elements.frameGrid.children) cell.className = "frame-cell";
}

function showIdleOutput() {
  state.preview.active = false;
  state.preview.climbing = false;
  state.preview.jobId = "";
  state.preview.revision = "";
  updateClimbToggle();
  elements.emptyOutput.classList.remove("hidden");
  elements.progressView.classList.add("hidden");
  elements.resultView.classList.add("hidden");
}

function updateGenerateState() {
  const busy = Boolean(state.job);
  const sourceMatchesAvatar = state.avatar && state.avatarSource === elements.source.value.trim();
  elements.source.disabled = busy;
  elements.lookupButton.disabled = busy || state.lookupBusy;
  elements.generateButton.disabled = busy || !sourceMatchesAvatar || !state.health?.comfy?.ok;
  const label = elements.generateButton.querySelector("span");
  if (label) label.textContent = busy ? "Generando…" : "Generar set";
}

function applyDefaults(defaults) {
  if (!defaults) return;
  setSelectValue(elements.cellSize, defaults.cellSize);
  setSelectValue(elements.renderResolution, defaults.renderResolution);
  setSelectValue(elements.paletteColors, defaults.paletteColors);
  setSelectValue(elements.style, defaults.style);
  setSelectValue(elements.steps, defaults.steps);
  setSelectValue(elements.framesPerAnimation, defaults.framesPerAnimation);
  rebuildFrameGrid(defaults.framesPerAnimation, defaults.idleFramesPerAnimation);
}

function applyJobSettings(input) {
  if (!input) return;
  setSelectValue(elements.cellSize, input.cellSize);
  setSelectValue(elements.renderResolution, input.renderResolution);
  setSelectValue(elements.paletteColors, input.paletteColors);
  setSelectValue(elements.style, input.style);
  setSelectValue(elements.steps, input.steps);
  setSelectValue(elements.framesPerAnimation, input.framesPerAnimation);
  elements.seed.value = input.seed ?? "";
  elements.notes.value = input.notes ?? "";
  rebuildFrameGrid(input.framesPerAnimation, input.idleFramesPerAnimation ?? selectedIdleFrameCount());
}

function selectedFrameCount() {
  const count = Number(elements.framesPerAnimation?.value);
  return [2, 4, 6, 8].includes(count) ? count : 8;
}

function selectedIdleFrameCount() {
  const count = Number(state.health?.defaults?.idleFramesPerAnimation);
  return [8, 12, 16].includes(count) ? count : DEFAULT_IDLE_FRAMES;
}

function buildClipFrameCounts(framesPerAnimation, idleFramesPerAnimation = framesPerAnimation) {
  return Object.fromEntries(CLIPS.map((clip) => [
    clip,
    clip === "idle" || clip === "idle_alt" || clip === "swim_idle"
      ? idleFramesPerAnimation
      : framesPerAnimation,
  ]));
}

function calculateFrameTotal(
  framesPerAnimation = selectedFrameCount(),
  idleFramesPerAnimation = selectedIdleFrameCount(),
) {
  const frameCounts = buildClipFrameCounts(framesPerAnimation, idleFramesPerAnimation);
  return DIRECTIONS.length * Object.values(frameCounts).reduce((total, count) => total + count, 0);
}

function nextIdleAlternateDelay() {
  return 6 + Math.random() * 8;
}

function updateFrameConfigurationCopy(
  framesPerAnimation = selectedFrameCount(),
  idleFramesPerAnimation = selectedIdleFrameCount(),
) {
  const total = calculateFrameTotal(framesPerAnimation, idleFramesPerAnimation);
  elements.generationSummary.textContent = `idle ${idleFramesPerAnimation} · otros ${framesPerAnimation} · 8 direcciones · ${total} frames`;
  elements.frameTotalLabel.textContent = `${total} frames`;
  if (!state.job) elements.frameCounter.textContent = `0 / ${total} frames`;
}

function setSelectValue(select, value) {
  if ([...select.options].some((option) => option.value === String(value))) select.value = String(value);
}

function compactDeviceName(value) {
  const match = String(value ?? "").match(/NVIDIA GeForce [^:]+/i);
  return match?.[0]?.replace("NVIDIA GeForce ", "") ?? "";
}

function showError(message) {
  elements.errorView.textContent = message;
  elements.errorView.classList.remove("hidden");
}

function clearError() {
  elements.errorView.classList.add("hidden");
  elements.errorView.textContent = "";
}

async function requestJson(url, init = {}) {
  const response = await fetch(url, init);
  const body = await response.json().catch(() => null);
  if (!response.ok) {
    const error = new Error(body?.error?.message ?? `HTTP ${response.status}`);
    error.status = response.status;
    error.code = body?.error?.code;
    error.details = body?.error?.details;
    throw error;
  }
  return body;
}

function setButtonBusy(button, busy, label) {
  button.disabled = busy;
  button.textContent = label;
}

function isTerminal(status) {
  return ["completed", "failed", "canceled"].includes(status);
}

function formatDetails(details) {
  if (!details) return "";
  if (details.missingModels?.length) return `\nModelos faltantes: ${details.missingModels.join(", ")}`;
  if (details.missingNodes?.length) return `\nNodos faltantes: ${details.missingNodes.join(", ")}`;
  if (details.comfyui?.missingModels?.length) return `\nModelos faltantes: ${details.comfyui.missingModels.join(", ")}`;
  return "";
}

function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[character]);
}

function escapeAttribute(value) {
  return escapeHtml(value);
}
