import { parseToolPayload } from "./studio-mcp.js";

export class StudioRuntimeSync {
  constructor({ client, avatars, pollMs = 2_500 }) {
    this.client = client;
    this.avatars = avatars;
    this.pollMs = pollMs;
    this.timer = null;
    this.running = false;
    this.inPlay = false;
    this.playersSignature = "";
    this.states = new Map();
    this.lastError = null;
    this.lastTickAt = null;
  }

  start() {
    if (this.timer) return;
    this.timer = setInterval(() => {
      void this.tick().catch((error) => this.handleTickError(error));
    }, this.pollMs);
    this.timer.unref();
    void this.tick().catch((error) => this.handleTickError(error));
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  status() {
    return {
      enabled: true,
      running: this.inPlay,
      trackedPlayers: this.states.size,
      lastTickAt: this.lastTickAt,
      lastError: this.lastError,
    };
  }

  async tick() {
    if (this.running) return;
    this.running = true;
    try {
      const playtest = parseToolPayload(await this.client.callTool("solo_playtest", { action: "status" }));
      if (!playtest?.running) {
        this.resetSession();
        return;
      }
      this.inPlay = true;
      const players = await this.readPlayers();
      const signature = players.map((player) => player.userId).sort((a, b) => a - b).join(",");
      const rosterChanged = signature !== this.playersSignature;
      this.playersSignature = signature;

      for (const player of players) {
        let state = this.states.get(player.userId);
        if (!state) {
          state = { jobId: null, status: null, payload: null, delivered: false };
          this.states.set(player.userId, state);
        }
        if (rosterChanged && state.status === "ready") state.delivered = false;
        if (state.status === "ready" && state.delivered) continue;

        const payload = state.status === "ready" && state.payload
          ? state.payload
          : await this.avatars.resolve(player.userId, { jobId: state.jobId });
        state.jobId = payload.jobId ?? state.jobId;
        state.status = payload.status;
        state.payload = payload.status === "ready" ? payload : null;
        if (payload.status !== state.lastDeliveredStatus || payload.status === "ready") {
          await this.deliver(payload);
          state.lastDeliveredStatus = payload.status;
          state.delivered = payload.status === "ready";
        }
      }

      for (const userId of this.states.keys()) {
        if (!players.some((player) => player.userId === userId)) this.states.delete(userId);
      }
      this.lastError = null;
      this.lastTickAt = new Date().toISOString();
    } finally {
      this.running = false;
    }
  }

  async readPlayers() {
    const response = parseToolPayload(await this.client.callTool("eval_server_runtime", {
      code: `
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local result = {}
for _, player in Players:GetPlayers() do
    table.insert(result, { userId = player.UserId, name = player.Name })
end
return HttpService:JSONEncode(result)`,
    }));
    return parseNestedJson(response?.result ?? response) ?? [];
  }

  async deliver(payload) {
    if (payload.status === "ready" && payload.atlas) {
      await this.deliverReadyAtlas(payload);
      return;
    }
    const json = JSON.stringify(payload);
    const sourceLiteral = JSON.stringify(json);
    await this.client.callTool("eval_server_runtime", {
      code: `
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local runtime = ReplicatedStorage:FindFirstChild("SpriteForgeRuntime")
local event = runtime and runtime:FindFirstChild("AtlasUpdate")
assert(event and event:IsA("RemoteEvent"), "SpriteForge AtlasUpdate is missing")
local payload = HttpService:JSONDecode(${sourceLiteral})
event:FireAllClients(payload)
return HttpService:JSONEncode({ status = payload.status, userId = payload.userId, bytes = ${Buffer.byteLength(json)} })`,
    });
  }

  async deliverReadyAtlas(payload) {
    const chunks = payload.atlas.chunks;
    const envelope = {
      ...payload,
      atlas: { ...payload.atlas, chunks: [] },
    };
    const envelopeLiteral = JSON.stringify(JSON.stringify(envelope));
    const userId = Number(payload.userId);
    const folderName = JSON.stringify(String(userId));
    const jobId = JSON.stringify(String(payload.jobId));
    const fingerprint = JSON.stringify(String(payload.appearanceFingerprint ?? ""));

    await this.client.callTool("eval_server_runtime", {
      code: `
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local runtime = ReplicatedStorage:FindFirstChild("SpriteForgeRuntime")
assert(runtime, "SpriteForgeRuntime is missing")
local root = runtime:FindFirstChild("DynamicAtlases")
if not root then
    root = Instance.new("Folder")
    root.Name = "DynamicAtlases"
    root.Parent = runtime
end
local previous = root:FindFirstChild(${folderName})
if previous then previous:Destroy() end
local folder = Instance.new("Folder")
folder.Name = ${folderName}
folder:SetAttribute("Status", "loading")
folder:SetAttribute("JobId", ${jobId})
folder:SetAttribute("AppearanceFingerprint", ${fingerprint})
folder:SetAttribute("ChunkCount", ${chunks.length})
folder.Parent = root
local envelope = Instance.new("StringValue")
envelope.Name = "Envelope"
envelope.Value = ${envelopeLiteral}
envelope.Parent = folder
return HttpService:JSONEncode({ status = "loading", userId = ${userId}, chunks = ${chunks.length} })`,
    });

    // El bridge tiene un límite práctico de tamaño de código. Cuatro bloques
    // compactos caben, pero cuatro filas rle16x8 complejas pueden superar el
    // límite y perderse silenciosamente. Conservamos como máximo cuatro y
    // cortamos antes de 180k caracteres para que todos lleguen completos.
    const batches = createChunkBatches(chunks);
    for (const batchEntries of batches) {
      const batchLiteral = JSON.stringify(JSON.stringify(batchEntries));
      await this.client.callTool("eval_server_runtime", {
        code: `
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local runtime = ReplicatedStorage:FindFirstChild("SpriteForgeRuntime")
local root = runtime and runtime:FindFirstChild("DynamicAtlases")
local folder = root and root:FindFirstChild(${folderName})
assert(folder and folder:GetAttribute("JobId") == ${jobId}, "SpriteForge atlas transfer expired")
local entries = HttpService:JSONDecode(${batchLiteral})
local bytes = 0
for _, entry in ipairs(entries) do
    local value = Instance.new("StringValue")
    value.Name = entry.name
    value.Value = entry.value
    value.Parent = folder
    bytes += #value.Value
end
return bytes`,
      });
    }

    await this.client.callTool("eval_server_runtime", {
      code: `
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local runtime = ReplicatedStorage:FindFirstChild("SpriteForgeRuntime")
local root = runtime and runtime:FindFirstChild("DynamicAtlases")
local folder = root and root:FindFirstChild(${folderName})
local event = runtime and runtime:FindFirstChild("AtlasUpdate")
assert(folder and event and event:IsA("RemoteEvent"), "SpriteForge atlas transfer is incomplete")
local received = 0
for _, child in ipairs(folder:GetChildren()) do
    if child:IsA("StringValue") and string.match(child.Name, "^Chunk%d+$") then received += 1 end
end
assert(received == ${chunks.length}, string.format("SpriteForge atlas expected %d chunks, received %d", ${chunks.length}, received))
folder:SetAttribute("Status", "ready")
event:FireAllClients({ status = "replicated-ready", userId = ${userId}, jobId = ${jobId} })
return HttpService:JSONEncode({ status = "ready", userId = ${userId}, chunks = ${chunks.length} })`,
    });
  }

  resetSession() {
    this.inPlay = false;
    this.playersSignature = "";
    this.states.clear();
  }

  async handleTickError(error) {
    const message = error instanceof Error ? error.message : String(error);
    if (/target .* disconnected|running playtest|runtime bridge/i.test(message)) {
      try {
        const playtest = parseToolPayload(await this.client.callTool("solo_playtest", { action: "status" }));
        if (!playtest?.running) {
          this.resetSession();
          this.lastError = null;
          this.lastTickAt = new Date().toISOString();
          return;
        }
      } catch {
        // Preserve the original error if Studio itself is unreachable.
      }
    }
    this.recordError(error);
  }

  recordError(error) {
    this.lastError = error instanceof Error ? error.message : String(error);
    this.lastTickAt = new Date().toISOString();
    console.warn("[studio-runtime-sync]", this.lastError);
  }
}

export function createChunkBatches(chunks, {
  maximumChunks = 4,
  maximumCharacters = 180_000,
} = {}) {
  const batches = [];
  let current = [];
  let currentCharacters = 2;
  chunks.forEach((value, index) => {
    const entry = {
      name: `Chunk${String(index + 1).padStart(3, "0")}`,
      value,
    };
    const entryCharacters = JSON.stringify(entry).length + (current.length ? 1 : 0);
    if (
      current.length
      && (current.length >= maximumChunks || currentCharacters + entryCharacters > maximumCharacters)
    ) {
      batches.push(current);
      current = [];
      currentCharacters = 2;
    }
    current.push(entry);
    currentCharacters += entryCharacters;
  });
  if (current.length) batches.push(current);
  return batches;
}

function parseNestedJson(value) {
  let current = value;
  for (let index = 0; index < 3 && typeof current === "string"; index += 1) {
    try {
      current = JSON.parse(current);
    } catch {
      break;
    }
  }
  return current;
}
