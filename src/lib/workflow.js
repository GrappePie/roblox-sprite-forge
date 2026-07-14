export const FLUX_REQUIRED_COMFY_NODES = Object.freeze([
  "LoadImage",
  "ImageScaleToTotalPixels",
  "GetImageSize",
  "UNETLoader",
  "CLIPLoader",
  "VAELoader",
  "CLIPTextEncode",
  "ConditioningZeroOut",
  "VAEEncode",
  "ReferenceLatent",
  "KSamplerSelect",
  "Flux2Scheduler",
  "EmptyFlux2LatentImage",
  "RandomNoise",
  "CFGGuider",
  "SamplerCustomAdvanced",
  "VAEDecode",
  "SaveImage",
]);

export const POSE_REQUIRED_COMFY_NODES = Object.freeze([
  "CheckpointLoaderSimple",
  "LoadImage",
  "ImageScaleToTotalPixels",
  "CLIPTextEncode",
  "VAEEncode",
  "ControlNetLoader",
  "ControlNetApplyAdvanced",
  "KSampler",
  "VAEDecode",
  "SaveImage",
]);

export const REQUIRED_COMFY_NODES = Object.freeze([
  ...new Set([...FLUX_REQUIRED_COMFY_NODES, ...POSE_REQUIRED_COMFY_NODES]),
]);

/**
 * Construye un workflow en formato API para FLUX.2 Klein 4B Distilled Image Edit.
 * @param {{imageName: string, poseImageName?: string, prompt: string, seed: number, filenamePrefix: string, steps: number, renderResolution: number, models: {unet: string, textEncoder: string, vae: string, weightDtype?: string}}} options
 */
export function buildFlux2KleinWorkflow(options) {
  const resolution = clampInteger(options.renderResolution, 512, 1024, 768);
  const megapixels = Number(((resolution * resolution) / (1024 * 1024)).toFixed(6));
  const workflow = {
    "1": { class_type: "LoadImage", inputs: { image: options.imageName } },
    "2": {
      class_type: "ImageScaleToTotalPixels",
      inputs: {
        image: ["1", 0],
        upscale_method: "nearest-exact",
        megapixels,
        resolution_steps: 16,
      },
    },
    "3": { class_type: "GetImageSize", inputs: { image: ["2", 0] } },
    "4": {
      class_type: "UNETLoader",
      inputs: {
        unet_name: options.models.unet,
        weight_dtype: options.models.weightDtype ?? "default",
      },
    },
    "5": {
      class_type: "CLIPLoader",
      inputs: { clip_name: options.models.textEncoder, type: "flux2" },
    },
    "6": { class_type: "VAELoader", inputs: { vae_name: options.models.vae } },
    "7": {
      class_type: "CLIPTextEncode",
      inputs: { text: options.prompt, clip: ["5", 0] },
    },
    "8": { class_type: "ConditioningZeroOut", inputs: { conditioning: ["7", 0] } },
    "9": {
      class_type: "VAEEncode",
      inputs: { pixels: ["2", 0], vae: ["6", 0] },
    },
    "10": {
      class_type: "ReferenceLatent",
      inputs: { conditioning: ["7", 0], latent: ["9", 0] },
    },
    "11": {
      class_type: "ReferenceLatent",
      inputs: { conditioning: ["8", 0], latent: ["9", 0] },
    },
    "12": { class_type: "KSamplerSelect", inputs: { sampler_name: "euler" } },
    "13": {
      class_type: "Flux2Scheduler",
      inputs: {
        steps: clampInteger(options.steps, 1, 50, 4),
        width: ["3", 0],
        height: ["3", 1],
      },
    },
    "14": {
      class_type: "EmptyFlux2LatentImage",
      inputs: { width: ["3", 0], height: ["3", 1], batch_size: 1 },
    },
    "15": {
      class_type: "RandomNoise",
      inputs: { noise_seed: normalizeSeed(options.seed) },
    },
    "16": {
      class_type: "CFGGuider",
      inputs: {
        model: ["4", 0],
        positive: [options.poseImageName ? "23" : "10", 0],
        negative: [options.poseImageName ? "24" : "11", 0],
        cfg: 1,
      },
    },
    "17": {
      class_type: "SamplerCustomAdvanced",
      inputs: {
        noise: ["15", 0],
        guider: ["16", 0],
        sampler: ["12", 0],
        sigmas: ["13", 0],
        latent_image: ["14", 0],
      },
    },
    "18": {
      class_type: "VAEDecode",
      inputs: { samples: ["17", 0], vae: ["6", 0] },
    },
    "19": {
      class_type: "SaveImage",
      inputs: { filename_prefix: options.filenamePrefix, images: ["18", 0] },
    },
  };
  if (options.poseImageName) {
    workflow["20"] = { class_type: "LoadImage", inputs: { image: options.poseImageName } };
    workflow["21"] = {
      class_type: "ImageScaleToTotalPixels",
      inputs: {
        image: ["20", 0],
        upscale_method: "nearest-exact",
        megapixels,
        resolution_steps: 16,
      },
    };
    workflow["22"] = {
      class_type: "VAEEncode",
      inputs: { pixels: ["21", 0], vae: ["6", 0] },
    };
    workflow["23"] = {
      class_type: "ReferenceLatent",
      inputs: { conditioning: ["10", 0], latent: ["22", 0] },
    };
    workflow["24"] = {
      class_type: "ReferenceLatent",
      inputs: { conditioning: ["11", 0], latent: ["22", 0] },
    };
  }
  return workflow;
}

/**
 * Anima un sprite maestro con SD 1.5 img2img y una pose OpenPose explicita.
 * Cada frame vuelve al mismo maestro para evitar que el diseno derive al
 * encadenar salidas generadas.
 * @param {{imageName: string, poseImageName: string, prompt: string, negativePrompt: string, seed: number, filenamePrefix: string, renderResolution: number, models: {animationCheckpoint: string, animationControlNet: string}, animation?: {steps?: number, cfg?: number, denoise?: number, controlStrength?: number}}} options
 */
export function buildPoseControlledSpriteWorkflow(options) {
  const resolution = clampInteger(options.renderResolution, 512, 1024, 512);
  const megapixels = Number(((resolution * resolution) / (1024 * 1024)).toFixed(6));
  const animation = options.animation ?? {};
  return {
    "1": {
      class_type: "CheckpointLoaderSimple",
      inputs: { ckpt_name: options.models.animationCheckpoint },
    },
    "2": { class_type: "LoadImage", inputs: { image: options.imageName } },
    "3": {
      class_type: "ImageScaleToTotalPixels",
      inputs: {
        image: ["2", 0],
        upscale_method: "nearest-exact",
        megapixels,
        resolution_steps: 16,
      },
    },
    "4": { class_type: "VAEEncode", inputs: { pixels: ["3", 0], vae: ["1", 2] } },
    "5": {
      class_type: "CLIPTextEncode",
      inputs: { text: options.prompt, clip: ["1", 1] },
    },
    "6": {
      class_type: "CLIPTextEncode",
      inputs: { text: options.negativePrompt, clip: ["1", 1] },
    },
    "7": { class_type: "LoadImage", inputs: { image: options.poseImageName } },
    "8": {
      class_type: "ImageScaleToTotalPixels",
      inputs: {
        image: ["7", 0],
        upscale_method: "nearest-exact",
        megapixels,
        resolution_steps: 16,
      },
    },
    "9": {
      class_type: "ControlNetLoader",
      inputs: { control_net_name: options.models.animationControlNet },
    },
    "10": {
      class_type: "ControlNetApplyAdvanced",
      inputs: {
        positive: ["5", 0],
        negative: ["6", 0],
        control_net: ["9", 0],
        image: ["8", 0],
        strength: clampNumber(animation.controlStrength, 0, 3, 1.15),
        start_percent: 0,
        end_percent: 1,
      },
    },
    "11": {
      class_type: "KSampler",
      inputs: {
        model: ["1", 0],
        seed: normalizeSeed(options.seed),
        steps: clampInteger(animation.steps, 4, 60, 20),
        cfg: clampNumber(animation.cfg, 1, 20, 7),
        sampler_name: "dpmpp_2m",
        scheduler: "karras",
        positive: ["10", 0],
        negative: ["10", 1],
        latent_image: ["4", 0],
        denoise: clampNumber(animation.denoise, 0.1, 1, 0.72),
      },
    },
    "12": { class_type: "VAEDecode", inputs: { samples: ["11", 0], vae: ["1", 2] } },
    "13": {
      class_type: "SaveImage",
      inputs: { filename_prefix: options.filenamePrefix, images: ["12", 0] },
    },
  };
}

function normalizeSeed(value) {
  const numeric = Number(value);
  return Number.isSafeInteger(numeric) && numeric >= 0 ? numeric : 0;
}

function clampInteger(value, minimum, maximum, fallback) {
  const numeric = Number(value);
  if (!Number.isInteger(numeric)) return fallback;
  return Math.max(minimum, Math.min(maximum, numeric));
}

function clampNumber(value, minimum, maximum, fallback) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) return fallback;
  return Math.max(minimum, Math.min(maximum, numeric));
}
