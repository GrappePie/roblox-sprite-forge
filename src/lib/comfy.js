import { randomUUID } from "node:crypto";
import { AppError } from "./errors.js";
import { fetchBuffer, fetchJson, sleep } from "./http.js";
import { REQUIRED_COMFY_NODES } from "./workflow.js";

export class ComfyClient {
  constructor({ baseUrl, pollMs = 800, frameTimeoutMs = 15 * 60_000 }) {
    this.baseUrl = baseUrl.replace(/\/$/, "");
    this.pollMs = pollMs;
    this.frameTimeoutMs = frameTimeoutMs;
    this.objectInfoCache = null;
    this.objectInfoCacheAt = 0;
  }

  async diagnose(models) {
    try {
      const [{ body: stats }, objectInfo] = await Promise.all([
        fetchJson(
          `${this.baseUrl}/system_stats`,
          { headers: { accept: "application/json" } },
          { service: "ComfyUI", timeoutMs: 8_000, retries: 0 },
        ),
        this.getObjectInfo({ refresh: true }),
      ]);
      const missingNodes = REQUIRED_COMFY_NODES.filter((name) => !objectInfo?.[name]);
      const installed = {
        unet: readComboValues(objectInfo, "UNETLoader", "unet_name"),
        textEncoder: readComboValues(objectInfo, "CLIPLoader", "clip_name"),
        vae: readComboValues(objectInfo, "VAELoader", "vae_name"),
        animationCheckpoint: readComboValues(objectInfo, "CheckpointLoaderSimple", "ckpt_name"),
        animationControlNet: readComboValues(objectInfo, "ControlNetLoader", "control_net_name"),
      };
      const missingModels = [];
      if (installed.unet.length && !installed.unet.includes(models.unet)) missingModels.push(models.unet);
      if (installed.textEncoder.length && !installed.textEncoder.includes(models.textEncoder)) {
        missingModels.push(models.textEncoder);
      }
      if (installed.vae.length && !installed.vae.includes(models.vae)) missingModels.push(models.vae);
      if (!installed.animationCheckpoint.includes(models.animationCheckpoint)) {
        missingModels.push(models.animationCheckpoint);
      }
      if (!installed.animationControlNet.includes(models.animationControlNet)) {
        missingModels.push(models.animationControlNet);
      }
      return {
        ok: missingNodes.length === 0 && missingModels.length === 0,
        reachable: true,
        url: this.baseUrl,
        device: summarizeDevice(stats),
        missingNodes,
        missingModels,
        configuredModels: models,
      };
    } catch (error) {
      return {
        ok: false,
        reachable: false,
        url: this.baseUrl,
        device: null,
        missingNodes: [],
        missingModels: [],
        configuredModels: models,
        error: error instanceof Error ? error.message : "No se pudo conectar con ComfyUI.",
      };
    }
  }

  async assertReady(models) {
    const diagnosis = await this.diagnose(models);
    if (!diagnosis.ok) {
      throw new AppError(
        diagnosis.reachable
          ? "ComfyUI está activo, pero faltan nodos o modelos requeridos."
          : "ComfyUI no está disponible.",
        {
          status: 503,
          code: "comfyui_not_ready",
          details: diagnosis,
        },
      );
    }
    return diagnosis;
  }

  async getObjectInfo({ refresh = false } = {}) {
    if (!refresh && this.objectInfoCache && Date.now() - this.objectInfoCacheAt < 30_000) {
      return this.objectInfoCache;
    }
    const { body } = await fetchJson(
      `${this.baseUrl}/object_info`,
      { headers: { accept: "application/json" } },
      { service: "ComfyUI", timeoutMs: 20_000, retries: 0 },
    );
    this.objectInfoCache = body;
    this.objectInfoCacheAt = Date.now();
    return body;
  }

  /** @param {Buffer} buffer */
  async uploadImage(buffer, filename, signal) {
    const form = new FormData();
    form.append("image", new Blob([buffer], { type: "image/png" }), filename);
    form.append("type", "input");
    form.append("overwrite", "true");
    const { body } = await fetchJson(
      `${this.baseUrl}/upload/image`,
      { method: "POST", body: form, signal },
      { service: "ComfyUI", timeoutMs: 60_000, retries: 0 },
    );
    if (!body?.name) {
      throw new AppError("ComfyUI no confirmó la carga de la referencia.", {
        status: 502,
        code: "comfy_upload_failed",
        details: body,
      });
    }
    return {
      name: body.name,
      subfolder: body.subfolder ?? "",
      type: body.type ?? "input",
      loadImageName: body.subfolder ? `${body.subfolder}/${body.name}` : body.name,
    };
  }

  /**
   * @param {{workflow: Record<string, unknown>, outputNodeId?: string, signal?: AbortSignal, onQueued?: (promptId: string) => void}} options
   */
  async runWorkflow(options) {
    const { body } = await fetchJson(
      `${this.baseUrl}/prompt`,
      {
        method: "POST",
        headers: { "content-type": "application/json", accept: "application/json" },
        body: JSON.stringify({ prompt: options.workflow, client_id: randomUUID() }),
        signal: options.signal,
      },
      { service: "ComfyUI", timeoutMs: 60_000, retries: 0 },
    );
    const promptId = body?.prompt_id;
    if (!promptId) {
      throw new AppError("ComfyUI rechazó el workflow.", {
        status: 502,
        code: "comfy_prompt_rejected",
        details: body,
      });
    }
    options.onQueued?.(promptId);

    const startedAt = Date.now();
    while (Date.now() - startedAt < this.frameTimeoutMs) {
      if (options.signal?.aborted) {
        throw new AppError("Generación cancelada.", { status: 499, code: "job_canceled" });
      }
      const { body: history } = await fetchJson(
        `${this.baseUrl}/history/${encodeURIComponent(promptId)}`,
        { signal: options.signal, headers: { accept: "application/json" } },
        { service: "ComfyUI", timeoutMs: 20_000, retries: 0 },
      );
      const record = history?.[promptId];
      if (record) {
        const executionError = findExecutionError(record);
        if (executionError) {
          throw new AppError(`ComfyUI falló al ejecutar el frame: ${executionError}`, {
            status: 502,
            code: "comfy_execution_error",
            details: record.status,
          });
        }
        const image = chooseOutputImage(record.outputs, options.outputNodeId);
        if (image) {
          const params = new URLSearchParams({
            filename: image.filename,
            subfolder: image.subfolder ?? "",
            type: image.type ?? "output",
          });
          const result = await fetchBuffer(
            `${this.baseUrl}/view?${params}`,
            { signal: options.signal },
            {
              service: "ComfyUI",
              timeoutMs: 60_000,
              maxBytes: 64 * 1024 * 1024,
              retries: 0,
            },
          );
          return { buffer: result.buffer, promptId, image };
        }
        if (record.status?.completed === true) {
          throw new AppError("ComfyUI terminó sin devolver una imagen.", {
            status: 502,
            code: "comfy_no_output_image",
            details: record.outputs,
          });
        }
      }
      await sleep(this.pollMs, options.signal);
    }
    throw new AppError("ComfyUI excedió el tiempo máximo para este frame.", {
      status: 504,
      code: "comfy_generation_timeout",
    });
  }

  async interrupt() {
    try {
      await fetchJson(
        `${this.baseUrl}/interrupt`,
        {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: "{}",
        },
        { service: "ComfyUI", timeoutMs: 8_000, retries: 0 },
      );
    } catch {
      // El trabajo local sigue marcado como cancelado aunque ComfyUI no responda.
    }
  }
}

function readComboValues(objectInfo, nodeName, inputName) {
  const value = objectInfo?.[nodeName]?.input?.required?.[inputName]?.[0];
  return Array.isArray(value) ? value.map(String) : [];
}

function summarizeDevice(stats) {
  const device = stats?.devices?.[0] ?? stats?.system?.devices?.[0] ?? null;
  if (!device) return null;
  return {
    name: device.name ?? device.device_name ?? device.type ?? "GPU",
    type: device.type ?? null,
    vramTotal: device.vram_total ?? device.vramTotal ?? null,
    vramFree: device.vram_free ?? device.vramFree ?? null,
  };
}

function chooseOutputImage(outputs, preferredNodeId) {
  if (!outputs || typeof outputs !== "object") return null;
  if (preferredNodeId && outputs[preferredNodeId]?.images?.length) {
    return outputs[preferredNodeId].images[0];
  }
  for (const output of Object.values(outputs)) {
    if (Array.isArray(output?.images) && output.images.length) return output.images[0];
  }
  return null;
}

function findExecutionError(record) {
  const messages = record?.status?.messages;
  if (!Array.isArray(messages)) return null;
  for (const message of messages) {
    if (!Array.isArray(message) || message[0] !== "execution_error") continue;
    const details = message[1] ?? {};
    return details.exception_message ?? details.exception_type ?? "error desconocido";
  }
  return null;
}
