--!strict

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local runtime = ReplicatedStorage:WaitForChild("SpriteForgeRuntime")
local atlasUpdate = runtime:WaitForChild("AtlasUpdate") :: RemoteEvent
local apiBase = runtime:GetAttribute("LocalApiUrl")
local tokens: { [Player]: {} } = {}
local readyPayloads: { [number]: any } = {}
local transport = runtime:GetAttribute("DynamicAtlasTransport")

if not RunService:IsStudio() then
    warn("[SpriteForgeDynamicAvatar] Local generation is Studio-only; using normal 3D avatars")
    return
end

if transport == "mcp" then
    print("[SpriteForgeDynamicAvatar] waiting for local MCP atlas transport")
    return
end

local function publish(payload: any)
    if payload.status == "ready" then
        readyPayloads[payload.userId] = payload
    end
    atlasUpdate:FireAllClients(payload)
end

local function requestStatus(userId: number, jobId: string?): (any?, string?)
    if typeof(apiBase) ~= "string" or apiBase == "" then
        return nil, "LocalApiUrl is not configured"
    end
    local url = `{apiBase}/{userId}`
    if jobId then
        url ..= `?jobId={HttpService:UrlEncode(jobId)}`
    end
    local success, response = pcall(function()
        return HttpService:RequestAsync({
            Url = url,
            Method = "GET",
            Headers = { Accept = "application/json" },
        })
    end)
    if not success then return nil, tostring(response) end
    if not response.Success then
        return nil, `HTTP {response.StatusCode}: {response.StatusMessage}`
    end
    local decodedSuccess, decoded = pcall(HttpService.JSONDecode, HttpService, response.Body)
    if not decodedSuccess or typeof(decoded) ~= "table" then
        return nil, "Sprite Forge returned invalid JSON"
    end
    return decoded, nil
end

local function syncPlayer(player: Player)
    local token = {}
    tokens[player] = token
    local jobId = nil
    local consecutiveFailures = 0

    for _ = 1, 720 do
        if tokens[player] ~= token or not player.Parent then return end
        local payload, requestError = requestStatus(player.UserId, jobId)
        if payload then
            consecutiveFailures = 0
            publish(payload)
            jobId = payload.jobId
            if payload.status == "ready" or payload.status == "failed" then return end
        else
            consecutiveFailures += 1
            warn(`[SpriteForgeDynamicAvatar] user={player.UserId} request failed: {requestError}`)
            if consecutiveFailures >= 3 then
                publish({ status = "unavailable", userId = player.UserId, error = requestError })
                return
            end
        end
        task.wait(5)
    end
end

local function playerAdded(player: Player)
    for _, payload in readyPayloads do
        atlasUpdate:FireClient(player, payload)
    end
    task.spawn(syncPlayer, player)
end

if not HttpService.HttpEnabled then
    warn("[SpriteForgeDynamicAvatar] HTTP requests are disabled; enable them in Experience Settings")
end

for _, player in Players:GetPlayers() do playerAdded(player) end
Players.PlayerAdded:Connect(playerAdded)
Players.PlayerRemoving:Connect(function(player)
    tokens[player] = nil
    readyPayloads[player.UserId] = nil
end)

print(`[SpriteForgeDynamicAvatar] server ready api={apiBase}`)
