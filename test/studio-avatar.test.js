import test from "node:test";
import assert from "node:assert/strict";
import { StudioAvatarService } from "../src/lib/studio-avatar.js";

test("reutiliza el trabajo de la misma apariencia y crea uno al cambiar", async () => {
  const jobsByFingerprint = new Map();
  let creations = 0;
  const jobs = {
    findByAppearance(_userId, fingerprint) {
      return jobsByFingerprint.get(fingerprint) ?? null;
    },
    findCaptureSourceByAppearance() {
      return null;
    },
    create(input) {
      creations += 1;
      const job = {
        id: `00000000-0000-4000-8000-${String(creations).padStart(12, "0")}`,
        status: "queued",
        input,
        progress: { stage: "queued" },
        avatar: null,
        result: null,
      };
      jobsByFingerprint.set(input.appearanceFingerprint, job);
      return job;
    },
    get() {
      return null;
    },
  };
  let fingerprint = "appearance-a";
  const service = new StudioAvatarService({
    jobs,
    outputDirectory: "unused",
    createInput: (userId, appearanceFingerprint) => ({
      source: String(userId),
      appearanceFingerprint,
    }),
    resolveAvatar: async () => ({
      appearanceFingerprint: fingerprint,
      user: { id: 42, username: "Player", displayName: "Player" },
      avatar: { assetCount: 2 },
    }),
  });

  const first = await service.resolve(42);
  const same = await service.resolve(42);
  fingerprint = "appearance-b";
  const changed = await service.resolve(42);

  assert.equal(first.jobId, same.jobId);
  assert.notEqual(first.jobId, changed.jobId);
  assert.equal(creations, 2);
  assert.equal(changed.appearanceFingerprint, "appearance-b");
});

test("usa el set incompleto como base y solicita solo los clips faltantes", async () => {
  const base = {
    id: "123e4567-e89b-42d3-a456-426614174000",
    status: "completed",
    input: { source: "42" },
    result: { clips: ["idle", "walk", "run", "jump", "fall"] },
  };
  let createdInput = null;
  const jobs = {
    findByAppearance: () => null,
    findCaptureSourceByAppearance: () => base,
    create(input) {
      createdInput = input;
      return { id: "223e4567-e89b-42d3-a456-426614174000", status: "queued", input, progress: {} };
    },
    get: () => null,
  };
  const service = new StudioAvatarService({
    jobs,
    outputDirectory: "unused",
    createInput: (userId, appearanceFingerprint, captureSource) => ({
      source: String(userId),
      appearanceFingerprint,
      reuseCaptureJobId: captureSource.id,
      recaptureClips: ["climb"],
    }),
    resolveAvatar: async () => ({
      appearanceFingerprint: "appearance-a",
      user: { id: 42, username: "Player", displayName: "Player" },
      avatar: { assetCount: 2 },
    }),
  });

  await service.resolve(42);
  assert.equal(createdInput.reuseCaptureJobId, base.id);
  assert.deepEqual(createdInput.recaptureClips, ["climb"]);
});
