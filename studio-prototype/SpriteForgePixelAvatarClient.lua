--!strict

local AssetService = game:GetService("AssetService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")
local runtime = ReplicatedStorage:WaitForChild("SpriteForgeRuntime")
local atlasUpdate = runtime:WaitForChild("AtlasUpdate") :: RemoteEvent

local DEFAULT_MIN_CAMERA_PITCH_DEGREES = -20
local DEFAULT_MAX_CAMERA_PITCH_DEGREES = 50
local MIN_CAMERA_PITCH_ATTRIBUTE = "SpriteForgeMinCameraPitchDegrees"
local MAX_CAMERA_PITCH_ATTRIBUTE = "SpriteForgeMaxCameraPitchDegrees"
local lastCameraHorizontalDirection = Vector3.new(0, 0, 1)
local swimAscendHeld = false
local swimDescendHeld = false
local SWIM_DESCEND_SPEED = 8
local SWIM_DIRECTION_INPUT_EPSILON = 0.05

local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local base64Lookup = table.create(256, -1)
for index = 1, #BASE64_ALPHABET do
    base64Lookup[string.byte(BASE64_ALPHABET, index)] = index - 1
end

local directionVectors = {
    { name = "down", vector = Vector2.new(0, -1) },
    { name = "down_left", vector = Vector2.new(-0.70710678, -0.70710678) },
    { name = "left", vector = Vector2.new(-1, 0) },
    { name = "up_left", vector = Vector2.new(-0.70710678, 0.70710678) },
    { name = "up", vector = Vector2.new(0, 1) },
    { name = "up_right", vector = Vector2.new(0.70710678, 0.70710678) },
    { name = "right", vector = Vector2.new(1, 0) },
    { name = "down_right", vector = Vector2.new(0.70710678, -0.70710678) },
}

type Atlas = {
    metadata: any,
    pixels: buffer,
    renderMode: string,
    editableImage: EditableImage?,
    content: any,
}

type Controller = {
    player: Player,
    character: Model,
    humanoid: Humanoid,
    root: BasePart,
    atlas: Atlas,
    surface: SurfaceGui,
    plane: Part,
    image: ImageLabel?,
    canvas: Frame?,
    pixelPool: { Frame },
    lastRenderedRow: number,
    lastRenderedFrame: number,
    lastDirection: string,
    lastClip: string,
    elapsed: number,
    idleWait: number,
    idleAltElapsed: number,
    idleAltActive: boolean,
    nextIdleAltAt: number,
    swimPitchBand: string,
    swimMoving: boolean,
    planeCenterOffset: number,
    descendantConnection: RBXScriptConnection?,
    hiddenParts: { [BasePart]: number },
    disabledEffects: { [Instance]: boolean },
}

local atlases: { [number]: Atlas } = {}
local controllers: { [Player]: Controller } = {}

local function updateSwimVerticalKey(input: InputObject, held: boolean)
    if input.KeyCode == Enum.KeyCode.Space then
        swimAscendHeld = held
    elseif input.KeyCode == Enum.KeyCode.LeftControl
        or input.KeyCode == Enum.KeyCode.RightControl
    then
        swimDescendHeld = held
    end
end

UserInputService.InputBegan:Connect(function(input)
    if UserInputService:GetFocusedTextBox() then
        return
    end
    updateSwimVerticalKey(input, true)
end)
UserInputService.InputEnded:Connect(function(input)
    updateSwimVerticalKey(input, false)
end)
UserInputService.WindowFocusReleased:Connect(function()
    swimAscendHeld = false
    swimDescendHeld = false
end)

local function decodeBase64(encoded: string): (buffer, number)
    encoded = string.gsub(encoded, "%s", "")
    local padding = 0
    if string.sub(encoded, -2) == "==" then
        padding = 2
    elseif string.sub(encoded, -1) == "=" then
        padding = 1
    end
    local outputLength = math.floor(#encoded * 3 / 4) - padding
    local output = buffer.create(outputLength)
    local outputOffset = 0

    for inputOffset = 1, #encoded, 4 do
        local a = base64Lookup[string.byte(encoded, inputOffset)]
        local b = base64Lookup[string.byte(encoded, inputOffset + 1)]
        local cByte = string.byte(encoded, inputOffset + 2)
        local dByte = string.byte(encoded, inputOffset + 3)
        local c = cByte == 61 and 0 or base64Lookup[cByte]
        local d = dByte == 61 and 0 or base64Lookup[dByte]
        local value = bit32.lshift(a, 18) + bit32.lshift(b, 12) + bit32.lshift(c, 6) + d

        if outputOffset < outputLength then
            buffer.writeu8(output, outputOffset, bit32.band(bit32.rshift(value, 16), 255))
            outputOffset += 1
        end
        if outputOffset < outputLength then
            buffer.writeu8(output, outputOffset, bit32.band(bit32.rshift(value, 8), 255))
            outputOffset += 1
        end
        if outputOffset < outputLength then
            buffer.writeu8(output, outputOffset, bit32.band(value, 255))
            outputOffset += 1
        end
    end
    return output, outputLength
end

local function decodeAtlas(metadata: any, chunks: { string }): buffer
    assert(metadata.Width > 0 and metadata.Height > 0, "Atlas dimensions are invalid")
    assert(
        metadata.Width <= 4096 and metadata.Height <= 16_384
            and metadata.Width * metadata.Height <= 33_554_432,
        "Atlas exceeds the safe client decode budget"
    )
    assert(#chunks == metadata.Rows, "Atlas chunk count does not match its rows")
    local expectedPixels = metadata.Width * metadata.Height
    local pixels = buffer.create(expectedPixels * 4)
    local pixelOffset = 0
    local encoding = metadata.Encoding or "rle12"

    for chunkIndex, encoded in chunks do
        local packed, packedLength = decodeBase64(encoded)
        local bytesPerRun = encoding == "rle16x8" and 3 or 2
        assert(packedLength % bytesPerRun == 0, `Atlas chunk {chunkIndex} is truncated`)

        for packedOffset = 0, packedLength - 1, bytesPerRun do
            local runLength: number
            local paletteIndex: number
            if encoding == "rle16x8" then
                runLength = buffer.readu16(packed, packedOffset)
                paletteIndex = buffer.readu8(packed, packedOffset + 2) + 1
            else
                local word = buffer.readu16(packed, packedOffset)
                paletteIndex = bit32.band(word, 15) + 1
                runLength = bit32.rshift(word, 4)
            end
            local color = metadata.Palette[paletteIndex]
            assert(color ~= nil and runLength > 0, `Atlas chunk {chunkIndex} has invalid RLE data`)

            for _ = 1, runLength do
                local byteOffset = pixelOffset * 4
                buffer.writeu8(pixels, byteOffset, color[1])
                buffer.writeu8(pixels, byteOffset + 1, color[2])
                buffer.writeu8(pixels, byteOffset + 2, color[3])
                buffer.writeu8(pixels, byteOffset + 3, color[4])
                pixelOffset += 1
            end
        end
        -- Un atlas de seis clips a 128 px contiene más de seis millones de
        -- píxeles. Ceder cada dos filas evita monopolizar el hilo del cliente
        -- durante la decodificación sin cambiar un solo píxel del resultado.
        if chunkIndex % 2 == 0 then task.wait() end
    end

    assert(pixelOffset == expectedPixels, `Decoded {pixelOffset} atlas pixels; expected {expectedPixels}`)
    return pixels
end

local function createAtlas(payload: any): Atlas
    local metadata = payload.metadata
    local pixels = decodeAtlas(metadata, payload.chunks)
    local editableImage = nil
    local content = nil
    local renderMode = "ui-runs"

    if runtime:GetAttribute("UseEditableImage") == true then
        local success, result = pcall(function()
            local image = AssetService:CreateEditableImage({
                Size = Vector2.new(metadata.Width, metadata.Height),
            })
            assert(image ~= nil, "Roblox did not allocate the Sprite Forge EditableImage")
            image:WritePixelsBuffer(Vector2.zero, image.Size, pixels)
            return image
        end)
        if success then
            editableImage = result
            content = Content.fromObject(result)
            renderMode = "editable-image"
        else
            warn(`[SpriteForgePixelAvatar] EditableImage unavailable; using UI pixel runs: {result}`)
        end
    end

    return {
        metadata = metadata,
        pixels = pixels,
        renderMode = renderMode,
        editableImage = editableImage,
        content = content,
    }
end

local function getAtlasColor(atlas: Atlas, x: number, y: number): (number, number, number, number)
    local metadata = atlas.metadata
    local byteOffset = (y * metadata.Width + x) * 4
    return buffer.readu8(atlas.pixels, byteOffset),
        buffer.readu8(atlas.pixels, byteOffset + 1),
        buffer.readu8(atlas.pixels, byteOffset + 2),
        buffer.readu8(atlas.pixels, byteOffset + 3)
end

local function getClipFrameCount(metadata: any, clip: string): number
    local configured = metadata.ClipFrameCounts and metadata.ClipFrameCounts[clip]
    local count = tonumber(configured) or tonumber(metadata.FramesPerAnimation) or 1
    return math.max(1, math.floor(count))
end

local function renderUiFrame(controller: Controller, row: number, frameIndex: number)
    local canvas = controller.canvas
    if not canvas or (controller.lastRenderedRow == row and controller.lastRenderedFrame == frameIndex) then
        return
    end
    controller.lastRenderedRow = row
    controller.lastRenderedFrame = frameIndex

    local metadata = controller.atlas.metadata
    local sourceX = frameIndex * metadata.FrameWidth
    local sourceY = row * metadata.FrameHeight
    local used = 0
    for y = 0, metadata.FrameHeight - 1 do
        local x = 0
        while x < metadata.FrameWidth do
            local red, green, blue, alpha = getAtlasColor(controller.atlas, sourceX + x, sourceY + y)
            local runLength = 1
            while x + runLength < metadata.FrameWidth do
                local nextRed, nextGreen, nextBlue, nextAlpha = getAtlasColor(
                    controller.atlas,
                    sourceX + x + runLength,
                    sourceY + y
                )
                if nextRed ~= red or nextGreen ~= green or nextBlue ~= blue or nextAlpha ~= alpha then
                    break
                end
                runLength += 1
            end

            if alpha > 0 then
                used += 1
                local pixelRun = controller.pixelPool[used]
                if not pixelRun then
                    pixelRun = Instance.new("Frame")
                    pixelRun.Name = "PixelRun"
                    pixelRun.BorderSizePixel = 0
                    pixelRun.Parent = canvas
                    controller.pixelPool[used] = pixelRun
                end
                pixelRun.BackgroundColor3 = Color3.fromRGB(red, green, blue)
                pixelRun.BackgroundTransparency = 1 - alpha / 255
                pixelRun.Position = UDim2.fromScale(x / metadata.FrameWidth, y / metadata.FrameHeight)
                pixelRun.Size = UDim2.fromScale(runLength / metadata.FrameWidth, 1 / metadata.FrameHeight)
                pixelRun.Visible = true
            end
            x += runLength
        end
    end

    for index = used + 1, #controller.pixelPool do
        controller.pixelPool[index].Visible = false
    end
    controller.surface:SetAttribute("PixelRuns", used)
end

local function hideLocally(controller: Controller, descendant: Instance)
    if descendant:IsA("BasePart") then
        if controller.hiddenParts[descendant] == nil then
            controller.hiddenParts[descendant] = descendant.LocalTransparencyModifier
        end
        descendant.LocalTransparencyModifier = 1
    elseif descendant:IsA("ParticleEmitter") or descendant:IsA("Trail") or descendant:IsA("Beam") then
        if controller.disabledEffects[descendant] == nil then
            controller.disabledEffects[descendant] = descendant.Enabled
        end
        descendant.Enabled = false
    end
end

local function detachPlayer(player: Player)
    local controller = controllers[player]
    if not controller then
        return
    end
    controllers[player] = nil
    if controller.descendantConnection then
        controller.descendantConnection:Disconnect()
    end
    controller.surface:Destroy()
    controller.plane:Destroy()
    for part, transparency in controller.hiddenParts do
        if part.Parent then
            part.LocalTransparencyModifier = transparency
        end
    end
    for effect, enabled in controller.disabledEffects do
        if effect.Parent then
            (effect :: any).Enabled = enabled
        end
    end
end

local function getHumanoidFootPlaneY(character: Model, humanoid: Humanoid, root: BasePart): number
    local rootToGround = root.Size.Y * 0.5 + humanoid.HipHeight
    if humanoid.RigType == Enum.HumanoidRigType.R6 then
        local leg = character:FindFirstChild("Left Leg") or character:FindFirstChild("Right Leg")
        if leg and leg:IsA("BasePart") then
            rootToGround += leg.Size.Y
        end
    end
    return root.Position.Y - rootToGround
end

local function fitSpritePlaneToCharacter(
    surface: SurfaceGui,
    plane: Part,
    character: Model,
    humanoid: Humanoid,
    root: BasePart,
    metadata: any
): number
    local _, boundsSize = character:GetBoundingBox()
    -- El encuadre de Studio reserva 10 % a cada lado, 14 % arriba y 7 %
    -- abajo. Convertir esos márgenes a studs hace que la silueta pixel ocupe el
    -- mismo volumen que el avatar invisible sin depender del zoom de cámara.
    local frameHeight = math.max(1, tonumber(metadata.FrameHeight) or 64)
    local paddingX = math.max(3, math.round(frameHeight * 0.10))
    local paddingTop = math.max(3, math.round(frameHeight * 0.14))
    local paddingBottom = math.max(3, math.round(frameHeight * 0.07))
    local contentWidthRatio = (frameHeight - paddingX * 2) / frameHeight
    local contentHeightRatio = (frameHeight - paddingTop - paddingBottom) / frameHeight
    local footRatioFromTop = (frameHeight - paddingBottom - 1) / frameHeight
    local horizontalExtent = math.max(boundsSize.X, boundsSize.Z)
    local worldCellSize = math.max(
        horizontalExtent / contentWidthRatio,
        boundsSize.Y / contentHeightRatio,
        1
    )
    -- El límite total del modelo puede incluir colas, bandas, pinchos o handles
    -- que atraviesan el suelo. El plano físico del Humanoid es el pivote estable
    -- que comparten los pies y no cambia por esos accesorios visuales.
    local footPlaneY = getHumanoidFootPlaneY(character, humanoid, root)
    local footPlaneOffset = footPlaneY - root.Position.Y
    local footLocalY = worldCellSize * (0.5 - footRatioFromTop)
    local planeCenterOffset = footPlaneOffset - footLocalY

    plane.Size = Vector3.new(worldCellSize, worldCellSize, 0.05)
    surface.CanvasSize = Vector2.new(metadata.FrameWidth, metadata.FrameHeight)
    surface:SetAttribute("WorldCellSize", worldCellSize)
    surface:SetAttribute("AvatarBoundsHeight", boundsSize.Y)
    surface:SetAttribute("AvatarBoundsWidth", horizontalExtent)
    surface:SetAttribute("AtlasFootRatio", footRatioFromTop)
    surface:SetAttribute("FootLocalY", footLocalY)
    surface:SetAttribute("FootPlaneOffset", footPlaneOffset)
    surface:SetAttribute("PlaneCenterOffset", planeCenterOffset)
    surface:SetAttribute("FootAnchorMode", "humanoid-rig-upright-plane")
    return planeCenterOffset
end

local function updateSpritePlane(controller: Controller)
    local camera = Workspace.CurrentCamera
    if not camera then
        return
    end

    local swimming = controller.humanoid:GetState() == Enum.HumanoidStateType.Swimming
    local center = if swimming
        then controller.root.Position
        else controller.root.Position + Vector3.new(0, controller.planeCenterOffset, 0)
    local anchorMode = if swimming then "humanoid-root-swim" else "humanoid-feet-ground"
    if controller.surface:GetAttribute("ActiveAnchorMode") ~= anchorMode then
        controller.surface:SetAttribute("ActiveAnchorMode", anchorMode)
    end
    local cameraOffset = camera.CFrame.Position - center
    local flatCameraOffset = Vector3.new(cameraOffset.X, 0, cameraOffset.Z)
    if flatCameraOffset.Magnitude < 0.05 then
        controller.plane.Position = center
        return
    end
    -- El plano solo gira alrededor de Y. Cambiar el pitch de la cámara no
    -- modifica su posición, escala u orientación vertical; desde arriba se ve
    -- de canto, como una lámina 2D colocada en el mundo.
    controller.plane.CFrame = CFrame.lookAt(
        center,
        center + flatCameraOffset.Unit,
        Vector3.yAxis
    )
end

local function getCameraPitchLimitsDegrees(): (number, number)
    local minimum = tonumber(localPlayer:GetAttribute(MIN_CAMERA_PITCH_ATTRIBUTE))
        or DEFAULT_MIN_CAMERA_PITCH_DEGREES
    local maximum = tonumber(localPlayer:GetAttribute(MAX_CAMERA_PITCH_ATTRIBUTE))
        or DEFAULT_MAX_CAMERA_PITCH_DEGREES
    minimum = math.clamp(minimum, -85, 85)
    maximum = math.clamp(maximum, -85, 85)
    if minimum > maximum then
        minimum, maximum = maximum, minimum
    end
    return minimum, maximum
end

local function clampGameplayCameraPitch()
    local localController = controllers[localPlayer]
    if not localController then
        return
    end
    local camera = Workspace.CurrentCamera
    if not camera or camera.CameraType ~= Enum.CameraType.Custom then
        return
    end

    local focus = camera.Focus.Position
    local cameraOffset = camera.CFrame.Position - focus
    local distance = cameraOffset.Magnitude
    if distance < 1 then
        return
    end

    local flatOffset = Vector3.new(cameraOffset.X, 0, cameraOffset.Z)
    if flatOffset.Magnitude >= 0.01 then
        lastCameraHorizontalDirection = flatOffset.Unit
    end
    local minimumDegrees, maximumDegrees = getCameraPitchLimitsDegrees()
    if localController.surface:GetAttribute("CameraPitchMinDegrees") ~= minimumDegrees then
        localController.surface:SetAttribute("CameraPitchMinDegrees", minimumDegrees)
    end
    if localController.surface:GetAttribute("CameraPitchMaxDegrees") ~= maximumDegrees then
        localController.surface:SetAttribute("CameraPitchMaxDegrees", maximumDegrees)
    end
    local pitch = math.asin(math.clamp(cameraOffset.Y / distance, -1, 1))
    local clampedPitch = math.clamp(
        pitch,
        math.rad(minimumDegrees),
        math.rad(maximumDegrees)
    )
    if math.abs(clampedPitch - pitch) < 0.0001 then
        return
    end

    local clampedOffset = lastCameraHorizontalDirection * (math.cos(clampedPitch) * distance)
        + Vector3.yAxis * (math.sin(clampedPitch) * distance)
    camera.CFrame = CFrame.lookAt(focus + clampedOffset, focus, Vector3.yAxis)
end

local function attachCharacter(player: Player, character: Model)
    detachPlayer(player)
    local atlas = atlases[player.UserId]
    if not atlas then
        return
    end

    local humanoid = character:WaitForChild("Humanoid", 10)
    local root = character:WaitForChild("HumanoidRootPart", 10)
    if not humanoid or not humanoid:IsA("Humanoid") or not root or not root:IsA("BasePart") then
        warn(`[SpriteForgePixelAvatar] Character incomplete for {player.Name}`)
        return
    end

    local metadata = atlas.metadata
    local plane = Instance.new("Part")
    plane.Name = `SpriteForgePixelPlane_{player.UserId}`
    plane.Anchored = true
    plane.CanCollide = false
    plane.CanQuery = false
    plane.CanTouch = false
    plane.CastShadow = false
    plane.Transparency = 1
    plane.Archivable = false

    local surface = Instance.new("SurfaceGui")
    surface.Name = `SpriteForgePixelAvatar_{player.UserId}`
    surface.Adornee = plane
    surface.Face = Enum.NormalId.Front
    surface.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
    surface.AlwaysOnTop = false
    surface.LightInfluence = 0
    surface.MaxDistance = 200
    local planeCenterOffset = fitSpritePlaneToCharacter(
        surface,
        plane,
        character,
        humanoid,
        root,
        metadata
    )
    surface:SetAttribute("Direction", "down")
    surface:SetAttribute("Clip", "idle")
    surface:SetAttribute("Frame", 0)
    surface:SetAttribute("RenderMode", atlas.renderMode)
    surface:SetAttribute("AppearanceFingerprint", metadata.AppearanceFingerprint)
    surface:SetAttribute("JobId", metadata.JobId)
    local minimumPitch, maximumPitch = getCameraPitchLimitsDegrees()
    surface:SetAttribute("CameraPitchMinDegrees", minimumPitch)
    surface:SetAttribute("CameraPitchMaxDegrees", maximumPitch)
    plane.Parent = Workspace
    surface.Parent = playerGui

    local image: ImageLabel? = nil
    local canvas: Frame? = nil
    if atlas.content then
        image = Instance.new("ImageLabel")
        image.Name = "Sprite"
        image.BackgroundTransparency = 1
        image.BorderSizePixel = 0
        image.Size = UDim2.fromScale(1, 1)
        image.ImageContent = atlas.content
        image.ImageRectSize = Vector2.new(metadata.FrameWidth, metadata.FrameHeight)
        image.ImageRectOffset = Vector2.zero
        image.ResampleMode = Enum.ResamplerMode.Pixelated
        image.Parent = surface
    else
        canvas = Instance.new("Frame")
        canvas.Name = "PixelCanvas"
        canvas.BackgroundTransparency = 1
        canvas.BorderSizePixel = 0
        canvas.ClipsDescendants = true
        canvas.Size = UDim2.fromScale(1, 1)
        canvas.Parent = surface
    end

    local controller: Controller = {
        player = player,
        character = character,
        humanoid = humanoid,
        root = root,
        atlas = atlas,
        surface = surface,
        plane = plane,
        image = image,
        canvas = canvas,
        pixelPool = {},
        lastRenderedRow = -1,
        lastRenderedFrame = -1,
        lastDirection = "down",
        lastClip = "idle",
        elapsed = 0,
        idleWait = 0,
        idleAltElapsed = 0,
        idleAltActive = false,
        nextIdleAltAt = 6 + math.random() * 8,
        swimPitchBand = "level",
        swimMoving = false,
        planeCenterOffset = planeCenterOffset,
        descendantConnection = nil,
        hiddenParts = {},
        disabledEffects = {},
    }
    controllers[player] = controller
    updateSpritePlane(controller)
    for _, descendant in character:GetDescendants() do
        hideLocally(controller, descendant)
    end
    controller.descendantConnection = character.DescendantAdded:Connect(function(descendant)
        hideLocally(controller, descendant)
    end)
    renderUiFrame(controller, 0, 0)
    print(`[SpriteForgePixelAvatar] ready user={player.UserId} fingerprint={metadata.AppearanceFingerprint} job={metadata.JobId} mode={atlas.renderMode}`)
end

local function watchPlayer(player: Player)
    player.CharacterAdded:Connect(function(character)
        task.defer(attachCharacter, player, character)
    end)
    player.CharacterRemoving:Connect(function()
        detachPlayer(player)
    end)
    if player.Character then
        task.defer(attachCharacter, player, player.Character)
    end
end

local function getViewDirectionFromForward(
    position: Vector3,
    worldForward: Vector3,
    fallback: string
): string
    local camera = Workspace.CurrentCamera
    if not camera then
        return fallback
    end
    local cameraOffset = camera.CFrame.Position - position
    local flatCameraOffset = Vector3.new(cameraOffset.X, 0, cameraOffset.Z)
    local rootForward = Vector3.new(worldForward.X, 0, worldForward.Z)
    local rootRight = Vector3.new(-rootForward.Z, 0, rootForward.X)
    if flatCameraOffset.Magnitude < 0.05
        or rootRight.Magnitude < 0.001
        or rootForward.Magnitude < 0.001
    then
        return fallback
    end

    -- Los nombres del atlas describen el perfil visible del avatar: una cámara
    -- delante de su LookVector ve "down" (frente), detrás ve "up" (espalda).
    -- Así el rig invisible conserva la orientación física y la cámara solo
    -- selecciona uno de los ocho ángulos capturados, incluso durante idle.
    local cameraDirection = flatCameraOffset.Unit
    local viewDirection = Vector2.new(
        cameraDirection:Dot(rootRight.Unit),
        -cameraDirection:Dot(rootForward.Unit)
    ).Unit
    local bestDirection = fallback
    local bestDot = -math.huge
    for _, candidate in directionVectors do
        local dot = viewDirection:Dot(candidate.vector)
        if dot > bestDot then
            bestDot = dot
            bestDirection = candidate.name
        end
    end
    return bestDirection
end

local function getViewDirection(root: BasePart, fallback: string): string
    return getViewDirectionFromForward(root.Position, root.CFrame.LookVector, fallback)
end

local function getSwimViewDirection(controller: Controller, fallback: string): string
    local moveDirection = controller.humanoid.MoveDirection
    local horizontalIntent = Vector3.new(moveDirection.X, 0, moveDirection.Z)
    if horizontalIntent.Magnitude < SWIM_DIRECTION_INPUT_EPSILON then
        return fallback
    end
    -- El rig R15 puede girar su HumanoidRootPart casi 180 grados durante el
    -- nado y la velocidad se desvía al rozar el fondo o el borde de la piscina.
    -- MoveDirection conserva la dirección que el jugador está ordenando, así
    -- que evita inversiones y saltos entre horizontal y diagonal.
    return getViewDirectionFromForward(controller.root.Position, horizontalIntent, fallback)
end

local function updateSwimPitchBand(controller: Controller, metadata: any): string
    local velocity = controller.root.AssemblyLinearVelocity
    local horizontalSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
    local speed = velocity.Magnitude
    if controller.player == localPlayer then
        if swimDescendHeld then
            controller.swimMoving = true
            controller.swimPitchBand = "down"
            return controller.swimPitchBand
        elseif swimAscendHeld then
            controller.swimMoving = true
            controller.swimPitchBand = "up"
            return controller.swimPitchBand
        end
    end
    local enterSpeed = tonumber(metadata.SwimEnterSpeedThreshold) or 1.25
    local exitSpeed = tonumber(metadata.SwimExitSpeedThreshold) or 0.7
    if controller.swimMoving then
        if speed <= exitSpeed then controller.swimMoving = false end
    elseif speed >= enterSpeed then
        controller.swimMoving = true
    end
    if not controller.swimMoving then
        controller.swimPitchBand = "level"
        return controller.swimPitchBand
    end

    local ratio = math.abs(velocity.Y) / math.max(horizontalSpeed, 0.1)
    local enterRatio = tonumber(metadata.SwimPitchEnterRatio) or 0.38
    local exitRatio = tonumber(metadata.SwimPitchExitRatio) or 0.22
    if controller.swimPitchBand == "level" then
        if ratio >= enterRatio then
            controller.swimPitchBand = if velocity.Y >= 0 then "up" else "down"
        end
    elseif ratio <= exitRatio then
        controller.swimPitchBand = "level"
    elseif ratio >= enterRatio then
        if velocity.Y > 0 then
            controller.swimPitchBand = "up"
        elseif velocity.Y < 0 then
            controller.swimPitchBand = "down"
        end
    end
    return controller.swimPitchBand
end

local function applyLocalSwimVerticalInput(controller: Controller)
    if controller.player ~= localPlayer or not swimDescendHeld then
        return
    end
    local velocity = controller.root.AssemblyLinearVelocity
    if velocity.Y > -SWIM_DESCEND_SPEED then
        controller.root.AssemblyLinearVelocity = Vector3.new(
            velocity.X,
            -SWIM_DESCEND_SPEED,
            velocity.Z
        )
    end
end

local function discardAtlas(userId: number)
    local old = atlases[userId]
    atlases[userId] = nil
    if old and old.editableImage then
        old.editableImage:Destroy()
    end
    local player = Players:GetPlayerByUserId(userId)
    if player then detachPlayer(player) end
end

local function applyAtlasStatus(payload: any)
    if typeof(payload) ~= "table" or typeof(payload.userId) ~= "number" then
        warn("[SpriteForgePixelAvatar] Ignored invalid atlas status")
        return
    end
    local userId = payload.userId
    if payload.status ~= "ready" then
        discardAtlas(userId)
        if payload.status == "failed" or payload.status == "unavailable" then
            warn(`[SpriteForgePixelAvatar] user={userId} status={payload.status}; keeping 3D avatar`)
        end
        return
    end

    local success, atlasOrError = pcall(createAtlas, payload.atlas)
    if not success then
        discardAtlas(userId)
        warn(`[SpriteForgePixelAvatar] Could not decode atlas for user={userId}: {atlasOrError}`)
        return
    end
    discardAtlas(userId)
    atlases[userId] = atlasOrError
    local player = Players:GetPlayerByUserId(userId)
    if player and player.Character then
        task.defer(attachCharacter, player, player.Character)
    end
end

local loadingReplicated: { [Instance]: boolean } = {}
local loadedReplicatedJobs: { [number]: string } = {}

local function loadReplicatedFolder(folder: Instance)
    if not folder:IsA("Folder") or loadingReplicated[folder] then return end
    loadingReplicated[folder] = true
    task.spawn(function()
        -- La entrega local puede tardar más en un atlas grande o con Studio
        -- ocupado. Esperar hasta 90 s evita declarar fallo mientras los
        -- micro-lotes todavía están llegando.
        for _ = 1, 360 do
            if not folder.Parent then break end
            if folder:GetAttribute("Status") == "ready" then
                local envelopeValue = folder:FindFirstChild("Envelope")
                local chunkCount = folder:GetAttribute("ChunkCount")
                local jobId = folder:GetAttribute("JobId")
                if envelopeValue and envelopeValue:IsA("StringValue")
                    and typeof(chunkCount) == "number" and typeof(jobId) == "string"
                then
                    local chunks = table.create(chunkCount)
                    local complete = true
                    for index = 1, chunkCount do
                        local chunk = folder:FindFirstChild(`Chunk{string.format("%03d", index)}`)
                        if not chunk or not chunk:IsA("StringValue") then
                            complete = false
                            break
                        end
                        chunks[index] = chunk.Value
                    end
                    if complete then
                        local decoded, payload = pcall(HttpService.JSONDecode, HttpService, envelopeValue.Value)
                        if decoded and typeof(payload) == "table" and typeof(payload.atlas) == "table" then
                            if loadedReplicatedJobs[payload.userId] ~= jobId then
                                payload.atlas.chunks = chunks
                                applyAtlasStatus(payload)
                                loadedReplicatedJobs[payload.userId] = jobId
                            end
                            loadingReplicated[folder] = nil
                            return
                        end
                    end
                end
            end
            task.wait(0.25)
        end
        loadingReplicated[folder] = nil
        warn(`[SpriteForgePixelAvatar] Replicated atlas did not finish loading from {folder:GetFullName()}`)
    end)
end

local function watchReplicatedFolder(folder: Instance)
    if not folder:IsA("Folder") then return end
    folder:GetAttributeChangedSignal("Status"):Connect(function()
        loadReplicatedFolder(folder)
    end)
    loadReplicatedFolder(folder)
end

local function watchReplicatedRoot(root: Instance)
    if not root:IsA("Folder") then return end
    for _, folder in root:GetChildren() do watchReplicatedFolder(folder) end
    root.ChildAdded:Connect(watchReplicatedFolder)
end

local replicatedRoot = runtime:FindFirstChild("DynamicAtlases")
if replicatedRoot then watchReplicatedRoot(replicatedRoot) end
runtime.ChildAdded:Connect(function(child)
    if child.Name == "DynamicAtlases" then watchReplicatedRoot(child) end
end)

atlasUpdate.OnClientEvent:Connect(function(payload: any)
    if typeof(payload) == "table" and payload.status == "replicated-ready" then
        local root = runtime:FindFirstChild("DynamicAtlases")
        local folder = root and root:FindFirstChild(tostring(payload.userId))
        if folder then loadReplicatedFolder(folder) end
        return
    end
    applyAtlasStatus(payload)
end)

RunService:BindToRenderStep("SpriteForgePixelAvatarRender", Enum.RenderPriority.Camera.Value + 10, function(deltaTime)
    clampGameplayCameraPitch()
    for _, controller in controllers do
        if not controller.character.Parent or controller.humanoid.Health <= 0 then
            continue
        end
        for part in controller.hiddenParts do
            if part.Parent then part.LocalTransparencyModifier = 1 end
        end
        updateSpritePlane(controller)

        local metadata = controller.atlas.metadata
        local moving = controller.humanoid.MoveDirection.Magnitude >= 0.05
        local horizontalVelocity = Vector3.new(
            controller.root.AssemblyLinearVelocity.X,
            0,
            controller.root.AssemblyLinearVelocity.Z
        ).Magnitude
        local runThreshold = tonumber(metadata.RunSpeedThreshold) or 18
        local runRequested = metadata.ClipRows.run ~= nil and (
            controller.player:GetAttribute("SpriteForgeRunning") == true
            or controller.humanoid:GetAttribute("SpriteForgeRunning") == true
            or horizontalVelocity >= runThreshold
            or controller.humanoid.WalkSpeed >= runThreshold
        )
        local humanoidState = controller.humanoid:GetState()
        local verticalVelocity = controller.root.AssemblyLinearVelocity.Y
        local swimming = metadata.ClipRows.swim ~= nil
            and metadata.ClipRows.swim_idle ~= nil
            and metadata.ClipRows.swim_up ~= nil
            and metadata.ClipRows.swim_down ~= nil
            and humanoidState == Enum.HumanoidStateType.Swimming
        if swimming then
            applyLocalSwimVerticalInput(controller)
        end
        local swimPitchBand = if swimming then updateSwimPitchBand(controller, metadata) else "level"
        if not swimming then
            controller.swimPitchBand = "level"
            controller.swimMoving = false
        end
        local climbing = not swimming and metadata.ClipRows.climb ~= nil
            and humanoidState == Enum.HumanoidStateType.Climbing
        -- Permanecer sujeto a la escalera selecciona la pose de climb, pero el
        -- ciclo solo debe avanzar cuando el personaje realmente gana o pierde
        -- altura. Esto también evita caminar en el sitio al llegar a un extremo.
        local climbSpeedThreshold = tonumber(metadata.ClimbSpeedThreshold) or 0.5
        local climbingMoving = climbing and math.abs(verticalVelocity) >= climbSpeedThreshold
        local airborne = not swimming and not climbing and (controller.humanoid.FloorMaterial == Enum.Material.Air
            or humanoidState == Enum.HumanoidStateType.Jumping
            or humanoidState == Enum.HumanoidStateType.Freefall)
        local jumping = metadata.ClipRows.jump ~= nil and airborne and (
            humanoidState == Enum.HumanoidStateType.Jumping or verticalVelocity > 0.75
        )
        local falling = metadata.ClipRows.fall ~= nil and airborne and not jumping
        local clip = if swimming
            then if not controller.swimMoving
                then "swim_idle"
                elseif swimPitchBand == "up"
                then "swim_up"
                elseif swimPitchBand == "down"
                then "swim_down"
                else "swim"
            elseif climbing
            then "climb"
            elseif jumping
            then "jump"
            elseif falling
            then "fall"
            elseif not moving
            then "idle"
            elseif runRequested
            then "run"
            else "walk"
        if clip == "idle" and metadata.ClipRows.idle_alt ~= nil then
            if controller.idleAltActive then
                controller.idleAltElapsed += deltaTime
                local alternateFps = tonumber(metadata.IdleAltFps) or tonumber(metadata.IdleFps) or 6.25
                local alternateDuration = getClipFrameCount(metadata, "idle_alt") / math.max(1, alternateFps)
                if controller.idleAltElapsed >= alternateDuration then
                    controller.idleAltActive = false
                    controller.idleAltElapsed = 0
                    controller.idleWait = 0
                    controller.nextIdleAltAt = 6 + math.random() * 8
                end
            else
                controller.idleWait += deltaTime
                if controller.idleWait >= controller.nextIdleAltAt then
                    controller.idleAltActive = true
                    controller.idleAltElapsed = 0
                end
            end
            if controller.idleAltActive then clip = "idle_alt" end
        elseif clip ~= "idle_alt" then
            controller.idleWait = 0
            controller.idleAltElapsed = 0
            controller.idleAltActive = false
            controller.nextIdleAltAt = 6 + math.random() * 8
        end
        local direction = if swimming
            then getSwimViewDirection(controller, controller.lastDirection)
            else getViewDirection(controller.root, controller.lastDirection)
        local debugDirection = controller.player:GetAttribute("SpriteForgeDebugDirection")
        local debugClip = controller.player:GetAttribute("SpriteForgeDebugClip")
        if typeof(debugDirection) == "string" and metadata.DirectionRows[debugDirection] ~= nil then
            direction = debugDirection
        end
        if typeof(debugClip) == "string" and metadata.ClipRows[debugClip] ~= nil then
            clip = debugClip
        end

        if clip ~= controller.lastClip then
            controller.elapsed = 0
        elseif not (clip == "climb" and climbing and not climbingMoving) then
            controller.elapsed += deltaTime
        end
        controller.lastClip = clip
        controller.lastDirection = direction

        local fps = if clip == "run"
            then metadata.RunFps
            elseif clip == "walk"
            then metadata.WalkFps
            elseif clip == "jump"
            then metadata.JumpFps or 11
            elseif clip == "fall"
            then metadata.FallFps or 11
            elseif clip == "climb"
            then metadata.ClimbFps or 10
            elseif clip == "swim_idle"
            then metadata.SwimIdleFps or metadata.IdleFps
            elseif clip == "swim" or clip == "swim_up" or clip == "swim_down"
            then metadata.SwimFps or 10
            elseif clip == "idle_alt"
            then metadata.IdleAltFps or metadata.IdleFps
            else metadata.IdleFps
        local frameCount = getClipFrameCount(metadata, clip)
        local frame = if clip == "jump"
            then math.min(frameCount - 1, math.floor(controller.elapsed * fps))
            else math.floor(controller.elapsed * fps) % frameCount
        local row = metadata.DirectionRows[direction] * (metadata.ClipCount or 2) + metadata.ClipRows[clip]
        if controller.image then
            controller.image.ImageRectOffset = Vector2.new(
                frame * metadata.FrameWidth,
                row * metadata.FrameHeight
            )
        else
            renderUiFrame(controller, row, frame)
        end
        controller.surface:SetAttribute("Direction", direction)
        controller.surface:SetAttribute("Clip", clip)
        controller.surface:SetAttribute("Frame", frame)
        controller.surface:SetAttribute("Airborne", airborne)
        controller.surface:SetAttribute("Climbing", climbing)
        controller.surface:SetAttribute("ClimbMoving", climbingMoving)
        controller.surface:SetAttribute("Swimming", swimming)
        controller.surface:SetAttribute("SwimMoving", controller.swimMoving)
        controller.surface:SetAttribute("SwimPitchBand", swimPitchBand)
        controller.surface:SetAttribute("VerticalVelocity", verticalVelocity)
    end
end)

for _, player in Players:GetPlayers() do watchPlayer(player) end
Players.PlayerAdded:Connect(watchPlayer)
Players.PlayerRemoving:Connect(function(player)
    detachPlayer(player)
    discardAtlas(player.UserId)
end)

print("[SpriteForgePixelAvatar] dynamic atlas client ready with idle/idle_alt/walk/run/jump/fall/climb/swim; 3D remains visible until a matching fingerprint arrives")
