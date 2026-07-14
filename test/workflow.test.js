import test from "node:test";
import assert from "node:assert/strict";
import {
  buildFlux2KleinWorkflow,
  buildPoseControlledSpriteWorkflow,
  FLUX_REQUIRED_COMFY_NODES,
  POSE_REQUIRED_COMFY_NODES,
} from "../src/lib/workflow.js";

test("construye un workflow API completo", () => {
  const workflow = buildFlux2KleinWorkflow({
    imageName: "avatar.png",
    poseImageName: "pose.png",
    prompt: "pixel sprite",
    seed: 42,
    filenamePrefix: "test",
    steps: 4,
    renderResolution: 512,
    models: {
      unet: "flux-2-klein-4b-fp8.safetensors",
      textEncoder: "qwen_3_4b.safetensors",
      vae: "flux2-vae.safetensors",
      weightDtype: "default",
    },
  });
  assert.equal(workflow["1"].inputs.image, "avatar.png");
  assert.equal(workflow["7"].inputs.text, "pixel sprite");
  assert.equal(workflow["15"].inputs.noise_seed, 42);
  assert.equal(workflow["13"].inputs.steps, 4);
  assert.equal(workflow["2"].inputs.megapixels, 0.25);
  assert.equal(workflow["19"].class_type, "SaveImage");
  assert.equal(workflow["20"].inputs.image, "pose.png");
  assert.deepEqual(workflow["16"].inputs.positive, ["23", 0]);
  assert.deepEqual(workflow["16"].inputs.negative, ["24", 0]);
  const classes = new Set(Object.values(workflow).map((node) => node.class_type));
  for (const required of FLUX_REQUIRED_COMFY_NODES) assert.ok(classes.has(required), required);
});

test("construye el workflow SD img2img condicionado por OpenPose", () => {
  const workflow = buildPoseControlledSpriteWorkflow({
    imageName: "canonical.png",
    poseImageName: "walk-pose.png",
    prompt: "PixelartFSS walking",
    negativePrompt: "static pose",
    seed: 77,
    filenamePrefix: "pose-test",
    renderResolution: 512,
    models: {
      animationCheckpoint: "PixelartSpritesheet_V.1.ckpt",
      animationControlNet: "control_v11p_sd15_openpose.pth",
    },
    animation: { steps: 24, cfg: 6.5, denoise: 0.7, controlStrength: 1.2 },
  });
  assert.equal(workflow["1"].inputs.ckpt_name, "PixelartSpritesheet_V.1.ckpt");
  assert.equal(workflow["2"].inputs.image, "canonical.png");
  assert.equal(workflow["7"].inputs.image, "walk-pose.png");
  assert.equal(workflow["9"].inputs.control_net_name, "control_v11p_sd15_openpose.pth");
  assert.equal(workflow["10"].inputs.strength, 1.2);
  assert.equal(workflow["11"].inputs.denoise, 0.7);
  assert.equal(workflow["13"].class_type, "SaveImage");
  const classes = new Set(Object.values(workflow).map((node) => node.class_type));
  for (const required of POSE_REQUIRED_COMFY_NODES) assert.ok(classes.has(required), required);
});
