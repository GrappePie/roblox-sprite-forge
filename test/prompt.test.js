import test from "node:test";
import assert from "node:assert/strict";
import {
  buildAccessoryGuardrails,
  buildFramePrompt,
  CLIPS,
  DIRECTIONS,
  getClipFrameCounts,
  getFramePlan,
} from "../src/lib/prompt.js";

const bundle = {
  user: { username: "YukiManju" },
  avatar: {
    avatarType: "R15",
    assets: [{ type: "Hat", name: "Black Cat Ears" }],
  },
};

test("el plan tiene siete clips configurables para ocho direcciones", () => {
  const plan = getFramePlan();
  assert.equal(plan.length, 224);
  assert.deepEqual([...new Set(plan.map((item) => item.row))], Array.from({ length: 56 }, (_, index) => index));
  assert.deepEqual([...new Set(plan.map((item) => item.column))], [0, 1, 2, 3]);
  assert.equal(plan[0].key, "down_idle_1");
  assert.equal(plan.at(-1).key, "down_right_idle_alt_4");
  assert.equal(getFramePlan({ framesPerAnimation: 6 }).length, 336);
  assert.deepEqual(DIRECTIONS.map((direction) => direction.key), [
    "down", "down_left", "left", "up_left", "up", "up_right", "right", "down_right",
  ]);
});

test("el idle puede usar 16 frames sin volver a capturar los demás clips", () => {
  const frameCounts = getClipFrameCounts({ framesPerAnimation: 8, idleFramesPerAnimation: 16 });
  const plan = getFramePlan({ framesPerAnimation: 8, idleFramesPerAnimation: 16 });
  assert.deepEqual(frameCounts, {
    idle: 16,
    walk: 8,
    run: 8,
    jump: 8,
    fall: 8,
    climb: 8,
    idle_alt: 16,
  });
  assert.equal(plan.length, 576);
  assert.equal(plan.filter((frame) => frame.clip.key === "idle").length, 128);
  assert.equal(plan.filter((frame) => frame.clip.key === "idle_alt").length, 128);
  assert.equal(plan.filter((frame) => frame.clip.key === "walk").length, 64);
  assert.equal(Math.max(...plan.map((frame) => frame.column)), 15);
});

test("el idle alternativo conserva la respiración estable como fallback", () => {
  const prompt = buildFramePrompt({
    bundle,
    direction: DIRECTIONS[0],
    clip: CLIPS[6],
    frameIndex: 2,
    frameCount: 4,
  });
  assert.match(prompt, /Idle phase: subtle inhale/i);
  assert.match(prompt, /Animation clip: idle_alt/i);
});

test("escalar alterna manos y pies sin convertirlo en caminata", () => {
  const prompt = buildFramePrompt({
    bundle,
    direction: DIRECTIONS[4],
    clip: CLIPS[5],
    frameIndex: 3,
    frameCount: 8,
  });
  assert.match(prompt, /vertical ladder cycle/i);
  assert.match(prompt, /alternating hands and feet/i);
  assert.match(prompt, /ladder/i);
});

test("salto es one-shot y conecta con caída sin volver al despegue", () => {
  const jump = buildFramePrompt({
    bundle,
    direction: DIRECTIONS[0],
    clip: CLIPS[3],
    frameIndex: 8,
    frameCount: 8,
  });
  const fall = buildFramePrompt({
    bundle,
    direction: DIRECTIONS[0],
    clip: CLIPS[4],
    frameIndex: 1,
    frameCount: 8,
  });
  assert.match(jump, /one-shot ascent/i);
  assert.match(jump, /transition into fall frame 1/i);
  assert.match(jump, /must not loop back/i);
  assert.match(fall, /airborne descent/i);
  assert.match(fall, /grounded clip on landing/i);
});

test("el prompt de carrera exige una zancada distinta de caminar", () => {
  const prompt = buildFramePrompt({
    bundle,
    direction: DIRECTIONS[6],
    clip: CLIPS[2],
    frameIndex: 3,
    frameCount: 8,
  });
  assert.match(prompt, /running rather than a faster walk/i);
  assert.match(prompt, /higher knee drive/i);
  assert.match(prompt, /brief flight phases/i);
});

test("el prompt exige un sprite aislado, chroma y conserva accesorios", () => {
  const prompt = buildFramePrompt({
    bundle,
    direction: DIRECTIONS[0],
    clip: CLIPS[0],
    frameIndex: 1,
    frameCount: 4,
    style: "handheld",
    chromaHex: "#FF00FF",
    cellSize: 64,
  });
  assert.match(prompt, /exactly ONE isolated/i);
  assert.match(prompt, /#FF00FF/);
  assert.match(prompt, /Black Cat Ears/);
  assert.match(prompt, /64 by 64/);
  assert.match(prompt, /Only draw a tail when/i);
  assert.match(buildAccessoryGuardrails(bundle), /reference image is primary evidence/i);
  assert.doesNotMatch(buildAccessoryGuardrails(bundle), /confirmed absent/i);
});

test("el prompt de continuidad avanza una sola fase y exige una caminata legible", () => {
  const prompt = buildFramePrompt({
    bundle,
    direction: DIRECTIONS[1],
    clip: CLIPS[1],
    frameIndex: 3,
    frameCount: 8,
    referenceKind: "continuity",
  });
  assert.match(prompt, /immediately preceding approved animation frame/i);
  assert.match(prompt, /exactly one small phase/i);
  assert.match(prompt, /locomotion, not a static fashion pose/i);
});

test("el prompt turntable gira el maestro anterior sin rediseñar al personaje", () => {
  const prompt = buildFramePrompt({
    bundle,
    direction: DIRECTIONS[2],
    clip: CLIPS[0],
    frameIndex: 1,
    frameCount: 8,
    referenceKind: "turntable",
  });
  assert.match(prompt, /preceding approved direction master/i);
  assert.match(prompt, /precisely 45 degrees/i);
  assert.match(prompt, /never a redesign/i);
  assert.match(prompt, /Do not add, remove, reinterpret or swap any feature/i);
});

test("el prompt de Studio separa la identidad pixel del perfil 3D auténtico", () => {
  const first = buildFramePrompt({
    bundle,
    direction: DIRECTIONS[0],
    clip: CLIPS[0],
    frameIndex: 1,
    frameCount: 8,
    referenceKind: "studio-avatar",
  });
  assert.match(first, /authentic in-engine render/i);
  assert.match(first, /deliberate pixel art/i);
  assert.doesNotMatch(first, /abstract colored skeleton/i);

  const rotated = buildFramePrompt({
    bundle,
    direction: DIRECTIONS[1],
    clip: CLIPS[0],
    frameIndex: 1,
    frameCount: 8,
    referenceKind: "studio-turntable",
  });
  assert.match(rotated, /first reference.*authentic in-engine/is);
  assert.match(rotated, /second reference.*preceding approved pixel-art/is);
  assert.match(rotated, /Never copy smooth 3D shading/i);
});
