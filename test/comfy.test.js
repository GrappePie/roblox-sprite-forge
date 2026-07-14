import test from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import sharp from "sharp";
import { ComfyClient } from "../src/lib/comfy.js";
import { REQUIRED_COMFY_NODES } from "../src/lib/workflow.js";

const models = {
  unet: "flux-2-klein-4b-fp8.safetensors",
  textEncoder: "qwen_3_4b.safetensors",
  vae: "flux2-vae.safetensors",
  weightDtype: "default",
  animationCheckpoint: "PixelartSpritesheet_V.1.ckpt",
  animationControlNet: "control_v11p_sd15_openpose.pth",
};

test("diagnostica ComfyUI, sube una referencia y descarga el resultado", async (context) => {
  const png = await sharp({
    create: { width: 8, height: 8, channels: 4, background: { r: 1, g: 2, b: 3, alpha: 1 } },
  }).png().toBuffer();
  let interrupted = false;
  const objectInfo = Object.fromEntries(REQUIRED_COMFY_NODES.map((name) => [name, { input: { required: {} } }]));
  objectInfo.UNETLoader.input.required.unet_name = [[models.unet]];
  objectInfo.CLIPLoader.input.required.clip_name = [[models.textEncoder]];
  objectInfo.VAELoader.input.required.vae_name = [[models.vae]];
  objectInfo.CheckpointLoaderSimple.input.required.ckpt_name = [[models.animationCheckpoint]];
  objectInfo.ControlNetLoader.input.required.control_net_name = [[models.animationControlNet]];

  const server = http.createServer(async (request, response) => {
    if (request.url === "/system_stats") return json(response, { devices: [{ name: "Test GPU", vram_total: 12_000_000_000 }] });
    if (request.url === "/object_info") return json(response, objectInfo);
    if (request.url === "/upload/image" && request.method === "POST") {
      for await (const _chunk of request) {}
      return json(response, { name: "reference.png", subfolder: "", type: "input" });
    }
    if (request.url === "/prompt" && request.method === "POST") {
      for await (const _chunk of request) {}
      return json(response, { prompt_id: "prompt-1" });
    }
    if (request.url === "/history/prompt-1") {
      return json(response, {
        "prompt-1": {
          status: { completed: true, messages: [] },
          outputs: { "19": { images: [{ filename: "out.png", subfolder: "", type: "output" }] } },
        },
      });
    }
    if (request.url?.startsWith("/view?")) {
      response.writeHead(200, { "content-type": "image/png", "content-length": String(png.length) });
      return response.end(png);
    }
    if (request.url === "/interrupt" && request.method === "POST") {
      interrupted = true;
      return json(response, {});
    }
    response.writeHead(404).end();
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  context.after(() => new Promise((resolve) => server.close(resolve)));
  const address = server.address();
  const client = new ComfyClient({
    baseUrl: `http://127.0.0.1:${address.port}`,
    pollMs: 10,
    frameTimeoutMs: 2_000,
  });

  const diagnosis = await client.diagnose(models);
  assert.equal(diagnosis.ok, true);
  assert.equal(diagnosis.device.name, "Test GPU");

  const upload = await client.uploadImage(png, "reference.png");
  assert.equal(upload.loadImageName, "reference.png");

  const result = await client.runWorkflow({ workflow: { "1": { class_type: "Test", inputs: {} } }, outputNodeId: "19" });
  assert.deepEqual(result.buffer, png);
  await client.interrupt();
  assert.equal(interrupted, true);
});

function json(response, body, status = 200) {
  const payload = Buffer.from(JSON.stringify(body));
  response.writeHead(status, {
    "content-type": "application/json",
    "content-length": String(payload.length),
  });
  response.end(payload);
}
