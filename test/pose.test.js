import test from "node:test";
import assert from "node:assert/strict";
import sharp from "sharp";
import { calculatePoseGeometry, createPoseGuide } from "../src/lib/pose.js";
import { CLIPS, DIRECTIONS } from "../src/lib/prompt.js";

test("crea mapas de pose cuadrados y fases de caminar distintas", async () => {
  const first = { direction: DIRECTIONS[0], clip: CLIPS[1], frameIndex: 1, frameCount: 4 };
  const third = { ...first, frameIndex: 3 };
  const guide = await createPoseGuide(first, { renderResolution: 512 });
  const metadata = await sharp(guide).metadata();
  assert.equal(metadata.width, 512);
  assert.equal(metadata.height, 512);
  assert.notDeepEqual(calculatePoseGeometry(first), calculatePoseGeometry(third));
  assert.ok(calculatePoseGeometry(first).leftFoot.x > calculatePoseGeometry(third).leftFoot.x);
});

test("la carrera tiene una zancada y elevación mayores que caminar", () => {
  const walk = calculatePoseGeometry({ direction: DIRECTIONS[6], clip: CLIPS[1], frameIndex: 1, frameCount: 8 });
  const run = calculatePoseGeometry({ direction: DIRECTIONS[6], clip: CLIPS[2], frameIndex: 1, frameCount: 8 });
  assert.ok(Math.abs(run.leftFoot.x - run.rightFoot.x) > Math.abs(walk.leftFoot.x - walk.rightFoot.x));
  const walkFlight = calculatePoseGeometry({ direction: DIRECTIONS[6], clip: CLIPS[1], frameIndex: 3, frameCount: 8 });
  const runFlight = calculatePoseGeometry({ direction: DIRECTIONS[6], clip: CLIPS[2], frameIndex: 3, frameCount: 8 });
  assert.ok(runFlight.leftFoot.y < walkFlight.leftFoot.y);
});

test("salto asciende hacia el ápice y caída prepara el aterrizaje", () => {
  const jumpStart = calculatePoseGeometry({ direction: DIRECTIONS[0], clip: CLIPS[3], frameIndex: 1, frameCount: 8 });
  const jumpApex = calculatePoseGeometry({ direction: DIRECTIONS[0], clip: CLIPS[3], frameIndex: 8, frameCount: 8 });
  const fallStart = calculatePoseGeometry({ direction: DIRECTIONS[0], clip: CLIPS[4], frameIndex: 1, frameCount: 8 });
  const fallEnd = calculatePoseGeometry({ direction: DIRECTIONS[0], clip: CLIPS[4], frameIndex: 8, frameCount: 8 });
  assert.ok(jumpApex.leftHand.y < jumpStart.leftHand.y);
  assert.ok(fallEnd.leftFoot.y > fallStart.leftFoot.y);
  assert.ok(fallEnd.leftFoot.y < fallEnd.ground.y);
});

test("escalar alterna manos y pies opuestos", () => {
  const first = calculatePoseGeometry({ direction: DIRECTIONS[4], clip: CLIPS[5], frameIndex: 3, frameCount: 8 });
  const opposite = calculatePoseGeometry({ direction: DIRECTIONS[4], clip: CLIPS[5], frameIndex: 7, frameCount: 8 });
  assert.ok(first.rightHand.y < first.leftHand.y);
  assert.ok(first.leftFoot.y < first.rightFoot.y);
  assert.ok(opposite.leftHand.y < opposite.rightHand.y);
  assert.ok(opposite.rightFoot.y < opposite.leftFoot.y);
});
