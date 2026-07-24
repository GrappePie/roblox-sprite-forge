--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local localPlayer = Players.LocalPlayer
local packageFolder = ReplicatedStorage:WaitForChild("PixelAvatar")
local Config = require(packageFolder:WaitForChild("PixelAvatarConfig"))
local Utils = require(packageFolder:WaitForChild("PixelAvatarUtils"))
local ThumbnailPixelator = require(packageFolder:WaitForChild("ThumbnailPixelator"))
local ProceduralFallbackRenderer = require(packageFolder:WaitForChild("ProceduralFallbackRenderer"))
local ProceduralChibiSelfTest = require(packageFolder:WaitForChild("ProceduralChibiSelfTest"))
local AppearanceFingerprint = require(packageFolder:WaitForChild("AppearanceFingerprint"))
local LayeredSpriteRenderer = require(packageFolder:WaitForChild("LayeredSpriteRenderer"))
local LayeredSpriteRuntime = require(packageFolder:WaitForChild("LayeredSpriteRuntime"))
local LayeredSpriteSelfTest = require(packageFolder:WaitForChild("LayeredSpriteSelfTest"))
local MockStylizationProvider = require(packageFolder:WaitForChild("MockStylizationProvider"))
local SpritePackageCache = require(packageFolder:WaitForChild("SpritePackageCache"))

type Mode = "Original" | "Thumbnail" | "ProceduralChibi" | "Layered" | "Experimental" | "Retro3D"
type Session = {
	player: Player,
	character: Model,
	sourceRoot: BasePart,
	sourceHumanoid: Humanoid,
	retroClone: Model,
	retroRoot: BasePart,
	retroAnimator: Animator,
	retroPairs: { Utils.PosePair },
	retroTracks: { [AnimationTrack]: AnimationTrack },
	viewportClone: Model,
	viewportRoot: BasePart,
	viewportAnimator: Animator,
	viewportPairs: { Utils.PosePair },
	viewportTracks: { [AnimationTrack]: AnimationTrack },
	proxyFolder: Folder,
	proxyPlane: Part,
	surfaceGui: SurfaceGui,
	viewport: ViewportFrame,
	viewportCamera: Camera,
	highlight: Highlight,
	partCount: number,
	appearanceSource: string,
	originalHidden: boolean,
	retroVisible: boolean,
	experimentalVisible: boolean,
	centerYOffset: number,
	viewportRootPosition: Vector3,
	connections: { RBXScriptConnection },
}

local sessions: { [Player]: Session } = {}
local playerConnections: { [Player]: { RBXScriptConnection } } = {}
local globalConnections: { RBXScriptConnection } = {}
local mode: Mode = Config.DefaultMode
local outlineEnabled = Config.OutlineEnabled
local resolution: Vector2 = Config.PixelResolution
local updateRate: number = Config.UpdateRate
local updateAccumulator = 0
local sampleElapsed = 0
local sampleFrames = 0
local measuredFps = 0
local updateSamples = 0
local totalUpdateTime = 0
local averageUpdateMs = 0

local statusTechnique: TextLabel
local statusMetrics: TextLabel
local statusWarning: TextLabel
local modeButtons: { [Mode]: TextButton } = {} :: any
local resolutionButtons: { [number]: TextButton } = {}
local rateButtons: { [number]: TextButton } = {}
local outlineButton: TextButton
local stageButton: TextButton
local stageEvent: BindableEvent
local thumbnailFrame: Frame
local thumbnailLabel: ImageLabel
local layeredHost: Frame
local thumbnailImage: EditableImage? = nil
local thumbnailError: string? = nil
local thumbnailLoading = false
local thumbnailGeneration = 0
local thumbnailRenderedMode: Mode? = nil
local selfTestError: string? = nil
local THUMBNAIL_PREVIEW_MAX = 512
local previewTitle: TextLabel
local proceduralDebugStage = Config.ProceduralChibiDebugStage
local layeredState = "Idle"
local layeredCache = SpritePackageCache.new()
local layeredProvider = MockStylizationProvider.new(Config.LayeredMockDelaySeconds)
local layeredRuntime: any? = nil
local layeredActiveCharacter: Model? = nil

local MODE_LABELS: { [Mode]: string } = {
	Original = "Original",
	Thumbnail = "Thumbnail pixel real",
	ProceduralChibi = "Chibi procedural",
	Layered = "Sprite por capas",
	Experimental = "Pixelado experimental",
	Retro3D = "Estilizado retro 3D",
}

local function rounded(gui: GuiObject, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = gui
end

local function makeLabel(parent: Instance, text: string, height: number): TextLabel
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 0, height)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Code
	label.Text = text
	label.TextColor3 = Color3.fromRGB(211, 222, 235)
	label.TextSize = 13
	label.TextWrapped = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = parent
	return label
end

local function makeButton(parent: Instance, text: string, width: number): TextButton
	local button = Instance.new("TextButton")
	button.Size = UDim2.fromOffset(width, 30)
	button.BackgroundColor3 = Color3.fromRGB(31, 39, 54)
	button.BorderSizePixel = 0
	button.Font = Enum.Font.Code
	button.Text = text
	button.TextColor3 = Color3.fromRGB(218, 228, 240)
	button.TextSize = 12
	button.AutoButtonColor = true
	button.Parent = parent
	rounded(button, 5)
	return button
end

local function makeRow(parent: Instance, height: number): Frame
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, height)
	row.BackgroundTransparency = 1
	row.Parent = parent
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, 5)
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Parent = row
	return row
end

local function createPanel()
	local playerGui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui
	local previous = playerGui:FindFirstChild("PixelAvatarDebug")
	if previous then
		previous:Destroy()
	end

	local screen = Instance.new("ScreenGui")
	screen.Name = "PixelAvatarDebug"
	screen.ResetOnSpawn = false
	screen.DisplayOrder = 100
	screen.Parent = playerGui
	stageEvent = Instance.new("BindableEvent")
	stageEvent.Name = "SetProceduralDebugStage"
	stageEvent.Parent = screen

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0, 1)
	panel.Position = UDim2.new(0, 18, 1, -18)
	panel.Size = UDim2.fromOffset(610, 405)
	panel.BackgroundColor3 = Color3.fromRGB(13, 17, 24)
	panel.BackgroundTransparency = 0.06
	panel.BorderSizePixel = 0
	panel.Parent = screen
	rounded(panel, 9)

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(91, 223, 239)
	stroke.Transparency = 0.38
	stroke.Thickness = 1
	stroke.Parent = panel

	local content = Instance.new("Frame")
	content.BackgroundTransparency = 1
	content.Position = UDim2.fromOffset(14, 10)
	content.Size = UDim2.new(1, -28, 1, -20)
	content.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 5)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = content

	local title = makeLabel(content, "PIXEL AVATAR / ROBLOX-ONLY COMPARISON", 22)
	title.LayoutOrder = 1
	title.TextColor3 = Color3.fromRGB(229, 250, 255)
	title.TextSize = 15

	local modeRow = makeRow(content, 32)
	modeRow.LayoutOrder = 2
	for _, candidate: Mode in { "Original", "Thumbnail", "ProceduralChibi", "Layered" } do
		local widths: { [Mode]: number } = {
			Original = 76,
			Thumbnail = 132,
			ProceduralChibi = 138,
			Layered = 142,
			Experimental = 170,
			Retro3D = 145,
		}
		local button = makeButton(modeRow, MODE_LABELS[candidate], widths[candidate])
		modeButtons[candidate] = button
	end

	local modeRowSecondary = makeRow(content, 32)
	modeRowSecondary.LayoutOrder = 3
	for _, candidate: Mode in { "Experimental", "Retro3D" } do
		local width = if candidate == "Experimental" then 170 else 145
		local button = makeButton(modeRowSecondary, MODE_LABELS[candidate], width)
		modeButtons[candidate] = button
	end

	local optionRow = makeRow(content, 32)
	optionRow.LayoutOrder = 4
	outlineButton = makeButton(optionRow, "Contorno: ON", 124)
	for index, candidate in Config.Resolutions do
		local button = makeButton(optionRow, string.format("%dx%d", candidate.X, candidate.Y), 82)
		resolutionButtons[index] = button
	end

	local rateRow = makeRow(content, 32)
	rateRow.LayoutOrder = 5
	local ratePrefix = makeLabel(rateRow, "FPS visual:", 26)
	ratePrefix.Size = UDim2.fromOffset(82, 26)
	for index, candidate in Config.UpdateRates do
		local button = makeButton(rateRow, tostring(candidate), 55)
		rateButtons[index] = button
	end

	local stageRow = makeRow(content, 32)
	stageRow.LayoutOrder = 6
	local stagePrefix = makeLabel(stageRow, "Etapa chibi:", 26)
	stagePrefix.Size = UDim2.fromOffset(100, 26)
	stageButton = makeButton(stageRow, proceduralDebugStage, 190)

	statusTechnique = makeLabel(content, "Técnica: preparando...", 28)
	statusTechnique.LayoutOrder = 7
	statusTechnique.TextColor3 = Color3.fromRGB(139, 235, 198)
	statusMetrics = makeLabel(content, "FPS: -- | partes: -- | actualización: --", 28)
	statusMetrics.LayoutOrder = 8
	statusWarning = makeLabel(content, "", 50)
	statusWarning.LayoutOrder = 9
	statusWarning.TextColor3 = Color3.fromRGB(255, 196, 112)

	local note = makeLabel(
		content,
		"La réplica es solo visual: no controla físicas, colisiones, salud ni lógica.",
		34
	)
	note.LayoutOrder = 10
	note.TextColor3 = Color3.fromRGB(145, 158, 177)

	thumbnailFrame = Instance.new("Frame")
	thumbnailFrame.Name = "ThumbnailPixelPreview"
	thumbnailFrame.AnchorPoint = Vector2.new(1, 0.5)
	thumbnailFrame.Position = UDim2.new(1, -24, 0.5, 0)
	thumbnailFrame.Size = UDim2.fromOffset(300, 570)
	thumbnailFrame.BackgroundColor3 = Color3.fromRGB(13, 17, 24)
	thumbnailFrame.BackgroundTransparency = 0.06
	thumbnailFrame.BorderSizePixel = 0
	thumbnailFrame.Visible = false
	thumbnailFrame.Parent = screen
	rounded(thumbnailFrame, 9)

	local previewStroke = Instance.new("UIStroke")
	previewStroke.Color = Color3.fromRGB(91, 223, 239)
	previewStroke.Transparency = 0.38
	previewStroke.Thickness = 1
	previewStroke.Parent = thumbnailFrame

	previewTitle = makeLabel(
		thumbnailFrame,
		"GENERADOR PROCEDURAL CHIBI / LUAU",
		30
	)
	previewTitle.Position = UDim2.fromOffset(14, 8)
	previewTitle.Size = UDim2.new(1, -28, 0, 30)
	previewTitle.TextColor3 = Color3.fromRGB(229, 250, 255)
	previewTitle.TextSize = 14

	thumbnailLabel = Instance.new("ImageLabel")
	thumbnailLabel.Name = "PixelImage"
	thumbnailLabel.AnchorPoint = Vector2.new(0.5, 0)
	local initialScale = math.max(1, math.floor(THUMBNAIL_PREVIEW_MAX / resolution.X))
	local initialDisplaySize = resolution.X * initialScale
	thumbnailLabel.Position = UDim2.new(
		0.5,
		0,
		0,
		45 + math.floor((THUMBNAIL_PREVIEW_MAX - initialDisplaySize) / 2)
	)
	thumbnailLabel.Size = UDim2.fromOffset(initialDisplaySize, initialDisplaySize)
	thumbnailLabel.BackgroundColor3 = Color3.fromRGB(43, 52, 66)
	thumbnailLabel.BorderSizePixel = 0
	thumbnailLabel.ScaleType = Enum.ScaleType.Fit
	thumbnailLabel.ResampleMode = Enum.ResamplerMode.Pixelated
	thumbnailLabel.Parent = thumbnailFrame
	rounded(thumbnailLabel, 5)

	layeredHost = Instance.new("Frame")
	layeredHost.Name = "LayeredSpriteHost"
	layeredHost.AnchorPoint = Vector2.new(0.5, 0)
	layeredHost.Position = UDim2.new(0.5, 0, 0, 45)
	layeredHost.Size = UDim2.fromOffset(256, THUMBNAIL_PREVIEW_MAX)
	layeredHost.BackgroundTransparency = 1
	layeredHost.ClipsDescendants = true
	layeredHost.Visible = false
	layeredHost.Parent = thumbnailFrame
end

local function setSessionVisibility(session: Session)
	local camera = workspace.CurrentCamera
	local withinDistance = camera ~= nil
		and (camera.CFrame.Position - session.sourceRoot.Position).Magnitude <= Config.RenderDistance
	local showExperimental = withinDistance and mode == "Experimental"
	local showRetro = withinDistance and mode == "Retro3D"
	local hideOriginal = showExperimental or showRetro

	if session.originalHidden ~= hideOriginal then
		session.originalHidden = hideOriginal
		Utils.setCharacterHidden(session.character, hideOriginal)
	end
	if session.retroVisible ~= showRetro then
		session.retroVisible = showRetro
		session.retroClone.Parent = if showRetro then workspace else nil
	end
	if session.experimentalVisible ~= showExperimental then
		session.experimentalVisible = showExperimental
		session.proxyFolder.Parent = if showExperimental then workspace else nil
		session.surfaceGui.Enabled = showExperimental
	end
	session.highlight.Enabled = showRetro and outlineEnabled
end

local function refreshButtonStyles()
	for candidate, button in modeButtons do
		local selected = candidate == mode
		button.BackgroundColor3 = if selected then Color3.fromRGB(25, 117, 132) else Color3.fromRGB(31, 39, 54)
	end
	outlineButton.Text = if outlineEnabled then "Contorno: ON" else "Contorno: OFF"
	outlineButton.BackgroundColor3 = if outlineEnabled
		then Color3.fromRGB(80, 70, 34)
		else Color3.fromRGB(48, 52, 61)
	for index, button in resolutionButtons do
		button.BackgroundColor3 = if Config.Resolutions[index] == resolution
			then Color3.fromRGB(25, 117, 132)
			else Color3.fromRGB(31, 39, 54)
	end
	for index, button in rateButtons do
		button.BackgroundColor3 = if Config.UpdateRates[index] == updateRate
			then Color3.fromRGB(25, 117, 132)
			else Color3.fromRGB(31, 39, 54)
	end
	stageButton.Text = proceduralDebugStage
	stageButton.BackgroundColor3 = if mode == "ProceduralChibi"
		then Color3.fromRGB(80, 70, 34)
		else Color3.fromRGB(48, 52, 61)
end

local function refreshStatus()
	local totalParts = 0
	for _, session in sessions do
		totalParts += session.partCount
	end

	if mode == "Original" then
		statusTechnique.Text = "Técnica: avatar original de Roblox"
		statusWarning.Text = "Comparación base; no hay réplica activa."
	elseif mode == "Thumbnail" then
		statusTechnique.Text = string.format(
			"Técnica: thumbnail inteligente %dx%d, paletas regionales",
			resolution.X,
			resolution.Y
		)
		if thumbnailLoading then
			statusWarning.Text = "Generando píxeles reales desde el avatar público..."
		elseif thumbnailError then
			statusWarning.Text = thumbnailError
		else
			statusWarning.Text =
				"Imagen estática real: alfa duro, paleta reducida, contorno y escalado nearest-neighbor."
		end
	elseif mode == "ProceduralChibi" then
		statusTechnique.Text = string.format(
			"Técnica: fallback procedural experimental %dx%d",
			Config.ProceduralChibiSize.X,
			Config.ProceduralChibiSize.Y
		)
		if thumbnailLoading then
			statusWarning.Text = "Analizando silueta y dibujando rostro/cuerpo chibi..."
		elseif thumbnailError then
			statusWarning.Text = thumbnailError
		else
			statusWarning.Text =
				"Fallback inmediato dentro de Roblox; no pretende reinterpretación ilustrada arbitraria."
		end
	elseif mode == "Layered" then
		local metrics = if layeredRuntime then layeredRuntime:Metrics() else nil
		statusTechnique.Text = "Técnica: SpritePackage por capas + rig 2D determinista"
		statusWarning.Text = string.format(
			"Estado: %s | provider mock=%d | caché=%d/%d | stale=%d | transición=%d",
			layeredState,
			layeredProvider.requests,
			if metrics then metrics.cacheHits else 0,
			if metrics then metrics.cacheMisses else 0,
			if metrics then metrics.staleResponses else 0,
			if metrics then metrics.transitions else 0
		)
	elseif mode == "Experimental" then
		statusTechnique.Text = "Técnica: ViewportFrame de baja resolución (experimental)"
		statusWarning.Text =
			"NO ES PIXEL ART REAL: Roblox no permite capturar los píxeles renderizados por ViewportFrame."
	else
		statusTechnique.Text = "Técnica: réplica visual retro 3D sincronizada"
		statusWarning.Text =
			"Simulación retro 3D: paleta/material simplificados y contorno; conserva texturas y accesorios."
	end
	if selfTestError then
		statusWarning.Text = "ProceduralChibiSelfTest FALLÓ: " .. selfTestError
	end

	statusMetrics.Text = string.format(
		"FPS aprox: %d | partes réplica: %d | actualización media: %.2f ms | tasa: %d Hz",
		measuredFps,
		totalParts,
		averageUpdateMs,
		updateRate
	)
end

local function regenerateThumbnail()
	thumbnailGeneration += 1
	local generation = thumbnailGeneration
	local displayMode = mode
	thumbnailLoading = true
	thumbnailError = nil
	if thumbnailImage then
		thumbnailImage:Destroy()
		thumbnailImage = nil
	end
	thumbnailRenderedMode = nil
	thumbnailLabel.ImageContent = Content.none
	refreshStatus()

	task.spawn(function()
		local thumbnailOptions = {
				Size = resolution.X,
				ChannelLevels = Config.ThumbnailChannelLevels,
				PaletteSize = Config.ThumbnailPaletteSize,
				HeadPaletteSize = Config.ThumbnailHeadPaletteSize,
				BodyPaletteSize = Config.ThumbnailBodyPaletteSize,
				AccentPreservation = Config.ThumbnailAccentPreservation,
				AlphaThreshold = Config.ThumbnailAlphaThreshold,
				OutlineRadius = if outlineEnabled then Config.ThumbnailOutlineRadius else 0,
				OutlineColor = Config.OutlineColor,
				CropPadding = Config.ThumbnailCropPadding,
				HeadRatio = Config.ThumbnailHeadRatio,
				CleanIsolatedPixels = Config.ThumbnailCleanIsolatedPixels,
			}
		local requestedMode: Mode = if displayMode == "Layered" then "ProceduralChibi" else displayMode
		local ok, result, renderMetrics = pcall(function()
			if requestedMode == "ProceduralChibi" then
				local skinColor = Color3.fromRGB(234, 190, 171)
				local character = localPlayer.Character
				local head = if character then character:FindFirstChild("Head") else nil
				if head and head:IsA("BasePart") then
					skinColor = head.Color
				end
				return ProceduralFallbackRenderer.Create(localPlayer.UserId, {
					OutputSize = Config.ProceduralChibiSize,
					SkinColor = skinColor,
					EyeColor = Config.ProceduralChibiEyeColor,
					HeadRatio = Config.ThumbnailHeadRatio,
					HeadHeightRatio = Config.ProceduralChibiHeadHeightRatio,
					HeadWidthRatio = if Config.ProceduralChibiHeadWidthAuto
						then nil
						else Config.ProceduralChibiHeadWidthRatio,
					HairSecondaryMinimumCoverage =
						Config.ProceduralChibiHairSecondaryMinimumCoverage,
					AccessoryMinimumConfidence =
						Config.ProceduralChibiAccessoryMinimumConfidence,
					MaxAccessoryComponents = Config.ProceduralChibiMaxAccessoryComponents,
					HeadFallbackEnabled = Config.ProceduralChibiHeadFallbackEnabled,
					PaletteSize = Config.ProceduralChibiPaletteSize,
					AlphaThreshold = Config.ProceduralChibiAlphaThreshold,
					OutlineColor = Config.OutlineColor,
					OutlineEnabled = outlineEnabled,
					DebugStage = proceduralDebugStage,
				})
			end
			return ThumbnailPixelator.Create(localPlayer.UserId, thumbnailOptions)
		end)
		if generation ~= thumbnailGeneration then
			if ok then
				(result :: EditableImage):Destroy()
			end
			return
		end
		thumbnailLoading = false
		if ok then
			thumbnailImage = result :: EditableImage
			thumbnailRenderedMode = displayMode
			thumbnailLabel.ImageContent = Content.fromObject(thumbnailImage)
			local renderedSize = if requestedMode == "ProceduralChibi"
				then Config.ProceduralChibiSize
				else resolution
			print(string.format(
				"[PixelAvatar] image ready mode=%s userId=%d size=%dx%d requestedColors=%d finalColors=%d stage=%s fallback=%d accents=%d outline=%d",
				requestedMode,
				localPlayer.UserId,
				renderedSize.X,
				renderedSize.Y,
				if requestedMode == "ProceduralChibi"
					then Config.ProceduralChibiPaletteSize
					else Config.ThumbnailPaletteSize,
				if requestedMode == "ProceduralChibi" and renderMetrics
					then renderMetrics.finalColors
					else Config.ThumbnailPaletteSize,
				if requestedMode == "ProceduralChibi" and renderMetrics
					then renderMetrics.stage
					else "Final",
				if requestedMode == "ProceduralChibi" and renderMetrics
					then renderMetrics.totalFallbackPixels
					else 0,
				if requestedMode == "ProceduralChibi" and renderMetrics
					then renderMetrics.accentComponents
					else 0,
				if outlineEnabled then Config.ThumbnailOutlineRadius else 0
			))
			if requestedMode == "ProceduralChibi" and renderMetrics then
				print(string.format(
					"[PixelAvatar] head procedural=%s primaryCoverage=%.3f secondaryCoverage=%.3f candidates=%d accepted=%d rejectedFace=%d fallbackPixels=%d headFallback=%s",
					tostring(renderMetrics.head.proceduralUsed),
					renderMetrics.head.primaryCoverage,
					renderMetrics.head.secondaryCoverage,
					renderMetrics.head.accessoryCandidates,
					renderMetrics.head.accessoriesAccepted,
					renderMetrics.head.accessoriesRejectedFace,
					renderMetrics.head.fallbackPixels,
					tostring(renderMetrics.head.fallbackUsed)
				))
				print(string.format(
					"[PixelAvatar] accessory raw=%d merged=%d accepted=%d projected=%d fill=%.3f repaired=%d clipped=%d hairCore=%.3f fringeGaps=%d strays=%d",
					renderMetrics.head.rawComponents,
					renderMetrics.head.mergedComponents,
					renderMetrics.head.acceptedComponents,
					renderMetrics.head.projectedComponents,
					renderMetrics.head.averageFillRatio,
					renderMetrics.head.repairedPixels,
					renderMetrics.head.clippedPixels,
					renderMetrics.head.hairCoreCoverage,
					renderMetrics.head.fringeGapCount,
					renderMetrics.head.strayPixelCount
				))
				print(string.format(
					"[PixelAvatar] zones frontLeft=%d frontRight=%d topLeft=%d topRight=%d sideLeft=%d sideRight=%d mergedPairs=%d rejectedOverlap=%d rejectedQuota=%d rejectedDuplicate=%d",
					renderMetrics.head.retainedByZone.frontLeft or 0,
					renderMetrics.head.retainedByZone.frontRight or 0,
					renderMetrics.head.retainedByZone.topLeft or 0,
					renderMetrics.head.retainedByZone.topRight or 0,
					renderMetrics.head.retainedByZone.sideLeft or 0,
					renderMetrics.head.retainedByZone.sideRight or 0,
					renderMetrics.head.mergedPairs,
					renderMetrics.head.rejectedByOverlap,
					renderMetrics.head.rejectedByQuota,
					renderMetrics.head.rejectedAsDuplicate
				))
				print(string.format(
					"[PixelAvatar] hair labels raw=%d regularized=%d removedPixels=%d isolatedHighlight=%d isolatedSecondary=%d fringeEyeOverlap=%.3f",
					renderMetrics.head.rawLabelComponents,
					renderMetrics.head.regularizedLabelComponents,
					renderMetrics.head.removedLabelPixels,
					renderMetrics.head.isolatedHighlightPixels,
					renderMetrics.head.isolatedSecondaryPixels,
					renderMetrics.head.fringeEyeOverlapRatio
				))
				print(string.format(
					"[PixelAvatar] accessory sourceCoverage=%.3f targetCoverage=%.3f maximumArea=%d collisions=%d rejectedTarget=%d simplifiedColors=%d preservedHoles=%d",
					renderMetrics.head.accessorySourceCoverage,
					renderMetrics.head.accessoryTargetCoverage,
					renderMetrics.head.maximumAccessoryArea,
					renderMetrics.head.targetCollisionCount,
					renderMetrics.head.targetRejectedCount,
					renderMetrics.head.simplifiedAccessoryColors,
					renderMetrics.head.preservedAccessoryHoles
				))
				print(string.format(
					"[PixelAvatar] accessory modes shape=%d template=%d primitive=%d lostHoles=%d aspectError=%.3f colors=%d->%d",
					renderMetrics.head.shapePreservingCount,
					renderMetrics.head.templateAssistedCount,
					renderMetrics.head.primitiveFallbackCount,
					renderMetrics.head.lostAccessoryHoles,
					renderMetrics.head.averageAccessoryAspectError,
					renderMetrics.head.simplifiedSourceColors,
					renderMetrics.head.simplifiedFinalColors
				))
				print(string.format(
					"[PixelAvatar] accessory completion core=%d clusters=%d support=%d skinLike=%d hairLike=%d rejectedLeak=%d linear=%d stacked=%d",
					renderMetrics.head.rawCoreComponents,
					renderMetrics.head.completedClusters,
					renderMetrics.head.recoveredSupportPixels,
					renderMetrics.head.recoveredSkinLikePixels,
					renderMetrics.head.recoveredHairLikePixels,
					renderMetrics.head.rejectedLeakPixels,
					renderMetrics.head.linearAccessoryCount,
					renderMetrics.head.stackedLinearAccessoryCount
				))
				print(string.format(
					"[PixelAvatar] accessory final safeAdjustments=%d offCanvasPrevented=%d visible=%.3f/%.3f holes=%d->%d lostClip=%d finalAspect=%.3f/%.3f attachment=%.3f recovered=%d/%d/%d/%d rejected=%d",
					renderMetrics.head.safeCanvasAdjustments,
					renderMetrics.head.offCanvasPixelsPrevented,
					renderMetrics.head.minimumVisibleRatio,
					renderMetrics.head.averageVisibleRatio,
					renderMetrics.head.preClipHoles,
					renderMetrics.head.finalHoles,
					renderMetrics.head.holesLostDuringClipping,
					renderMetrics.head.averageFinalAspectError,
					renderMetrics.head.maximumFinalAspectError,
					renderMetrics.head.averageHairAttachmentRatio,
					renderMetrics.head.recoveredByTranslation,
					renderMetrics.head.recoveredByScaling,
					renderMetrics.head.recoveredByTemplate,
					renderMetrics.head.recoveredByFallback,
					renderMetrics.head.rejectedAfterFinalValidation
				))
				print(string.format(
					"[PixelAvatar] hair masses=%d highlight=%d shadow=%d secondary=%d strands=%d rawIsolatedHighlight=%d rawIsolatedSecondary=%d remainingHighlight=%d remainingSecondary=%d",
					renderMetrics.head.hairMassCount,
					renderMetrics.head.highlightMassCount,
					renderMetrics.head.shadowMassCount,
					renderMetrics.head.secondaryMassCount,
					renderMetrics.head.strandLineCount,
					renderMetrics.head.rawIsolatedHighlightPixels,
					renderMetrics.head.rawIsolatedSecondaryPixels,
					renderMetrics.head.remainingIsolatedHighlightPixels,
					renderMetrics.head.remainingIsolatedSecondaryPixels
				))
				for pairId, pairMetric in renderMetrics.head.pairMetrics do
					print(string.format(
						"[PixelAvatar] pair=%d zones=%s/%s kinds=%s/%s heightRatio=%.3f scaleRatio=%.3f verticalOffset=%d pixelsLeft=%d pixelsRight=%d",
						pairId,
						pairMetric.leftZone,
						pairMetric.rightZone,
						pairMetric.leftKind,
						pairMetric.rightKind,
						pairMetric.heightRatio,
						pairMetric.scaleRatio,
						pairMetric.verticalOffset,
						pairMetric.projectedPixelsLeft,
						pairMetric.projectedPixelsRight
					))
				end
				print(string.format(
					"[PixelAvatar] body skirtSkin=%.3f skirtCentral=%.3f shoulderRepaired=%d shoulderOverwritten=%d",
					renderMetrics.body.lowerGarmentSkinRatio,
					renderMetrics.body.lowerGarmentCentralCoverage,
					renderMetrics.body.shoulderPixelsRepaired,
					renderMetrics.body.shoulderPixelsOverwritten
				))
				print(string.format(
					"[PixelAvatar] structure sleeves=%d/%d similarity=%.3f torso=%d/%d removed=%d skirtPanels=%d skirtFallback=%d skirtSkinRejected=%d bootsFallback=%.3f/%.3f bootPairRecovery=%s",
					renderMetrics.body.leftSleeveBandCount,
					renderMetrics.body.rightSleeveBandCount,
					renderMetrics.body.sleeveSequenceSimilarity,
					renderMetrics.body.torsoRetainedComponents,
					renderMetrics.body.torsoSourceComponents,
					renderMetrics.body.torsoRemovedNoisePixels,
					renderMetrics.body.lowerGarmentPanelCount,
					renderMetrics.body.lowerGarmentFallbackPixels,
					renderMetrics.body.lowerGarmentSkinPixelsRejected,
					renderMetrics.body.leftBootFallbackRatio,
					renderMetrics.body.rightBootFallbackRatio,
					tostring(renderMetrics.body.bootPairRecoveryUsed)
				))
				for regionName, regionMetrics in renderMetrics.regions do
					local fallbackRatio = regionMetrics.fallbackPixels
						/ math.max(1, regionMetrics.projectedPixels)
					print(string.format(
						"[PixelAvatar] region=%s projected=%d fallback=%d rejectedSkin=%d accents=%d",
						regionName,
						regionMetrics.projectedPixels,
						regionMetrics.fallbackPixels,
						regionMetrics.rejectedSkinPixels,
						regionMetrics.accentComponents
					))
					if fallbackRatio > 0.3 then
						warn(string.format(
							"[PixelAvatar] high regional fallback region=%s ratio=%.2f",
							regionName,
							fallbackRatio
						))
					end
				end
			end
		else
			local detail = tostring(result)
			if string.find(detail, "not accessible", 1, true) then
				thumbnailError =
					"Activa manualmente Game Settings > Security > Allow Mesh / Image APIs para ver este modo."
			else
				thumbnailError = "No se pudo generar el thumbnail: " .. detail
			end
			warn("[PixelAvatar] thumbnail unavailable: " .. detail)
		end
		refreshStatus()
	end)
end

local function updateResolution()
	for _, session in sessions do
		session.surfaceGui.CanvasSize = resolution
	end
	local imageSize = if mode == "ProceduralChibi" or mode == "Layered"
		then Config.ProceduralChibiSize
		else resolution
	local displayScale = math.max(
		1,
		math.floor(math.min(
			THUMBNAIL_PREVIEW_MAX / imageSize.X,
			THUMBNAIL_PREVIEW_MAX / imageSize.Y
		))
	)
	local displayWidth = imageSize.X * displayScale
	local displayHeight = imageSize.Y * displayScale
	thumbnailLabel.Size = UDim2.fromOffset(displayWidth, displayHeight)
	thumbnailLabel.Position = UDim2.new(
		0.5,
		0,
		0,
		45 + math.floor((THUMBNAIL_PREVIEW_MAX - displayHeight) / 2)
	)
end

local function ensureLayeredRuntime()
	if layeredRuntime then return end
	layeredRuntime = LayeredSpriteRuntime.new({
		provider = layeredProvider,
		cache = layeredCache,
		showFallback = function(fingerprint: string)
			thumbnailLabel.Visible = true
			layeredHost.Visible = true
			print("[LayeredSprite] fallback fingerprint=" .. fingerprint)
		end,
		hideFallback = function()
			thumbnailLabel.Visible = false
			print("[LayeredSprite] fallback replaced without blank frame")
		end,
		createRenderer = function(package: any)
			local renderer = LayeredSpriteRenderer.new(layeredHost, package, {
				ViewportSize = Vector2.new(256, THUMBNAIL_PREVIEW_MAX),
				Visible = false,
				AutoPlay = true,
			})
			local metrics = renderer:Metrics()
			print(string.format(
				"[LayeredSprite] renderer layers=%d images=%d integerScale=%d clip=%s",
				metrics.layers,
				metrics.imagesCreated,
				metrics.integerScale,
				metrics.clip
			))
			return renderer
		end,
		onStateChanged = function(state: string, detail: string?)
			layeredState = state
			print(string.format("[LayeredSprite] state=%s detail=%s", state, detail or ""))
			refreshStatus()
		end,
	})
end

local function startLayeredRuntime(isRespawn: boolean?)
	local character = localPlayer.Character
	if not character then return end
	if mode == "Layered" then
		thumbnailFrame.Visible = true
		layeredHost.Visible = true
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	local ok, descriptionOrError = pcall(function()
		return humanoid:GetAppliedDescription()
	end)
	if not ok then
		layeredState = "Failed"
		warn("[LayeredSprite] fingerprint failed: " .. tostring(descriptionOrError))
		return
	end
	local snapshot = AppearanceFingerprint.Capture(descriptionOrError :: HumanoidDescription)
	local fingerprint = AppearanceFingerprint.FromSnapshot(snapshot)
	ensureLayeredRuntime()
	if not isRespawn
		and layeredActiveCharacter == character
		and layeredRuntime:GetFingerprint() == fingerprint
		and table.find({ "Fallback", "Loading", "Validating", "Ready" }, layeredRuntime:GetState()) then
		return
	end
	layeredActiveCharacter = character
	if isRespawn then
		layeredRuntime:Respawn(snapshot, fingerprint)
	else
		layeredRuntime:Start(snapshot, fingerprint)
	end
	thumbnailLabel.Visible = layeredRuntime:GetState() ~= "Ready"
	print(string.format(
		"[LayeredSprite] request fingerprint=%s respawn=%s",
		fingerprint,
		tostring(isRespawn == true)
	))
end

local function stopLayeredRuntime()
	if layeredRuntime and layeredRuntime:GetFingerprint() then
		layeredRuntime:Cancel()
	end
	layeredActiveCharacter = nil
	layeredHost.Visible = false
end

local function applyMode()
	for _, session in sessions do
		setSessionVisibility(session)
	end
	local isImageMode = mode == "Thumbnail" or mode == "ProceduralChibi" or mode == "Layered"
	thumbnailFrame.Visible = isImageMode
	previewTitle.Text = if mode == "ProceduralChibi"
		then "PROCEDURAL FALLBACK / LUAU"
		elseif mode == "Layered" then "SPRITE PACKAGE / CAPAS + RIG"
		else "AVATAR THUMBNAIL → PÍXELES REALES"
	updateResolution()
	if mode == "Layered" then
		layeredHost.Visible = true
		thumbnailLabel.Visible = layeredState ~= "Ready"
		if thumbnailRenderedMode ~= "Layered" and not thumbnailLoading then
			regenerateThumbnail()
		end
		startLayeredRuntime(false)
	else
		stopLayeredRuntime()
		thumbnailLabel.Visible = true
		if isImageMode and thumbnailRenderedMode ~= mode and not thumbnailLoading then
			regenerateThumbnail()
		end
	end
	refreshButtonStyles()
	refreshStatus()
end

local function destroySession(player: Player)
	local session = sessions[player]
	if not session then
		return
	end
	sessions[player] = nil
	Utils.destroyConnections(session.connections)
	Utils.setCharacterHidden(session.character, false)
	session.retroClone:Destroy()
	session.viewportClone:Destroy()
	session.surfaceGui:Destroy()
	session.proxyFolder:Destroy()
end

local function guardOriginalPart(session: Session, part: BasePart)
	table.insert(session.connections, part:GetPropertyChangedSignal("LocalTransparencyModifier"):Connect(function()
		if session.originalHidden and part.LocalTransparencyModifier ~= 1 then
			part.LocalTransparencyModifier = 1
		end
	end))
end

local function guardReplicaPart(session: Session, part: BasePart)
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	local function guardProperty(propertyName: "CanCollide" | "CanQuery" | "CanTouch")
		table.insert(session.connections, part:GetPropertyChangedSignal(propertyName):Connect(function()
			if propertyName == "CanCollide" and part.CanCollide then
				part.CanCollide = false
			elseif propertyName == "CanQuery" and part.CanQuery then
				part.CanQuery = false
			elseif propertyName == "CanTouch" and part.CanTouch then
				part.CanTouch = false
			end
		end))
	end
	for _, propertyName in { "CanCollide", "CanQuery", "CanTouch" } do
		guardProperty(propertyName :: "CanCollide" | "CanQuery" | "CanTouch")
	end
end

local function createSession(player: Player, character: Model)
	destroySession(player)
	local ok, problem = pcall(function()
		local sourceRoot = character:WaitForChild("HumanoidRootPart", 15)
		local humanoid = character:WaitForChild("Humanoid", 15)
		if not sourceRoot or not sourceRoot:IsA("BasePart") or not humanoid or not humanoid:IsA("Humanoid") then
			error("Character is missing HumanoidRootPart or Humanoid")
		end
		if not player:HasAppearanceLoaded() then
			player.CharacterAppearanceLoaded:Wait()
		end
		task.wait(0.2)

		local retroClone, retroRoot, retroPartCount, appearanceSource =
			Utils.createPlayerVisual(player, character, Config.PaletteLevels, Config.RetroMaterial)
		retroClone.Name = "PixelAvatarRetro_" .. player.Name
		retroClone:PivotTo(character:GetPivot())
		retroClone.Parent = nil

		local viewportClone = retroClone:Clone()
		viewportClone.Name = "PixelAvatarViewport_" .. player.Name
		local viewportRoot = viewportClone:FindFirstChild("HumanoidRootPart", true)
		if not viewportRoot or not viewportRoot:IsA("BasePart") then
			viewportClone:Destroy()
			retroClone:Destroy()
			error("Viewport appearance clone has no HumanoidRootPart")
		end
		viewportClone.PrimaryPart = viewportRoot
		local retroAnimator = Utils.makeAnimationOnly(retroClone)
		local viewportAnimator = Utils.makeAnimationOnly(viewportClone)

		local highlight = Instance.new("Highlight")
		highlight.Name = "PixelAvatarOutline"
		highlight.Adornee = retroClone
		highlight.FillTransparency = Config.OutlineFillTransparency
		highlight.OutlineTransparency = 0
		highlight.OutlineColor = Config.OutlineColor
		highlight.DepthMode = Config.OutlineDepthMode
		highlight.Enabled = outlineEnabled
		highlight.Parent = retroClone

		viewportClone:PivotTo(CFrame.new())
		local viewportRootPosition = viewportRoot.Position

		local proxyFolder = Instance.new("Folder")
		proxyFolder.Name = "PixelAvatarProxy_" .. player.Name
		local boundsCFrame, boundsSize = character:GetBoundingBox()
		local plane = Instance.new("Part")
		plane.Name = "DisplayPlane"
		plane.Anchored = true
		plane.CanCollide = false
		plane.CanQuery = false
		plane.CanTouch = false
		plane.CastShadow = false
		plane.Transparency = 1
		local height = math.max(boundsSize.Y + 0.25, 4.5)
		plane.Size = Vector3.new(height, height, 0.05)
		plane.Parent = proxyFolder

		local playerGui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui
		local surface = Instance.new("SurfaceGui")
		surface.Name = "PixelAvatarSurface_" .. player.Name
		surface.Adornee = plane
		surface.Face = Enum.NormalId.Front
		surface.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
		surface.CanvasSize = resolution
		surface.AlwaysOnTop = false
		surface.LightInfluence = 0
		surface.MaxDistance = Config.RenderDistance
		surface.ClipsDescendants = true
		surface.ResetOnSpawn = false
		surface.Parent = playerGui

		local viewport = Instance.new("ViewportFrame")
		viewport.Name = "LowResolutionViewport"
		viewport.Size = UDim2.fromScale(1, 1)
		viewport.BackgroundTransparency = 1
		viewport.BorderSizePixel = 0
		viewport.Ambient = Config.FlatAmbient
		viewport.LightColor = Config.FlatLightColor
		viewport.LightDirection = Config.FlatLightDirection
		viewport.Parent = surface

		local worldModel = Instance.new("WorldModel")
		worldModel.Name = "AvatarWorld"
		worldModel.Parent = viewport
		viewportClone.Parent = worldModel

		local viewportCamera = Instance.new("Camera")
		viewportCamera.Name = "PixelAvatarCamera"
		viewportCamera.FieldOfView = 22
		viewportCamera.Parent = viewport
		viewport.CurrentCamera = viewportCamera

		local cloneBoundsCFrame, cloneBoundsSize = viewportClone:GetBoundingBox()
		local target = cloneBoundsCFrame.Position
		local distance = math.max(cloneBoundsSize.X, cloneBoundsSize.Y, cloneBoundsSize.Z) * 3.4
		viewportCamera.CFrame = CFrame.lookAt(target + Vector3.new(0, 0, distance), target)

		local session: Session = {
			player = player,
			character = character,
			sourceRoot = sourceRoot,
			sourceHumanoid = humanoid,
			retroClone = retroClone,
			retroRoot = retroRoot,
			retroAnimator = retroAnimator,
			retroPairs = Utils.buildPosePairs(character, retroClone),
			retroTracks = {},
			viewportClone = viewportClone,
			viewportRoot = viewportRoot,
			viewportAnimator = viewportAnimator,
			viewportPairs = Utils.buildPosePairs(character, viewportClone),
			viewportTracks = {},
			proxyFolder = proxyFolder,
			proxyPlane = plane,
			surfaceGui = surface,
			viewport = viewport,
			viewportCamera = viewportCamera,
			highlight = highlight,
			partCount = retroPartCount,
			appearanceSource = appearanceSource,
			originalHidden = false,
			retroVisible = false,
			experimentalVisible = false,
			centerYOffset = boundsCFrame.Position.Y - sourceRoot.Position.Y,
			viewportRootPosition = viewportRootPosition,
			connections = {},
		}
		sessions[player] = session

		for _, descendant in character:GetDescendants() do
			if descendant:IsA("BasePart") then
				guardOriginalPart(session, descendant)
			end
		end
		for _, visual in { retroClone, viewportClone } do
			for _, descendant in visual:GetDescendants() do
				if descendant:IsA("BasePart") then
					guardReplicaPart(session, descendant)
				end
			end
		end
		table.insert(session.connections, character.DescendantAdded:Connect(function(descendant)
			if descendant:IsA("BasePart") then
				guardOriginalPart(session, descendant)
				if session.originalHidden then
					descendant.LocalTransparencyModifier = 1
					descendant.CastShadow = false
				end
			end
		end))
		setSessionVisibility(session)
		print(string.format(
			"[PixelAvatar] ready player=%s appearance=%s parts=%d retroPairs=%d viewportPairs=%d",
			player.Name,
			appearanceSource,
			retroPartCount,
			#session.retroPairs,
			#session.viewportPairs
		))
	end)
	if not ok then
		Utils.setCharacterHidden(character, false)
		warn("[PixelAvatar] setup failed for " .. player.Name .. ": " .. tostring(problem))
	end
end

local function watchPlayer(player: Player)
	if playerConnections[player] then
		return
	end
	local connections = {}
	playerConnections[player] = connections
	table.insert(connections, player.CharacterAdded:Connect(function(character)
		task.defer(createSession, player, character)
		if player == localPlayer then
			task.delay(0.4, function()
				if mode == "Layered" and localPlayer.Character == character then
					startLayeredRuntime(true)
				end
			end)
		end
	end))
	table.insert(connections, player.CharacterRemoving:Connect(function()
		destroySession(player)
		if player == localPlayer then
			stopLayeredRuntime()
		end
	end))
	table.insert(connections, player.CharacterAppearanceLoaded:Connect(function(character)
		if character == player.Character and sessions[player] == nil then
			task.defer(createSession, player, character)
		end
		if player == localPlayer then
			task.delay(0.2, function()
				if mode == "Layered" and localPlayer.Character == character then
					startLayeredRuntime(true)
				end
			end)
		end
	end))
	if player.Character then
		task.defer(createSession, player, player.Character)
	end
end

local function unwatchPlayer(player: Player)
	destroySession(player)
	local connections = playerConnections[player]
	if connections then
		Utils.destroyConnections(connections)
		playerConnections[player] = nil
	end
end

local function updateSessions()
	local started = os.clock()
	local camera = workspace.CurrentCamera
	for _, session in sessions do
		if not session.character.Parent or not session.sourceRoot.Parent then
			continue
		end
		setSessionVisibility(session)
		if mode == "Retro3D" and session.retroClone.Parent then
			local trackCount = Utils.syncAnimationTracks(
				session.sourceHumanoid,
				session.retroAnimator,
				session.retroTracks
			)
			if trackCount == 0 then
				Utils.syncPose(session.retroPairs)
			end
			session.retroRoot.CFrame = session.sourceRoot.CFrame
		elseif mode == "Experimental" and session.proxyFolder.Parent and camera then
			local trackCount = Utils.syncAnimationTracks(
				session.sourceHumanoid,
				session.viewportAnimator,
				session.viewportTracks
			)
			if trackCount == 0 then
				Utils.syncPose(session.viewportPairs)
			end
			local center = session.sourceRoot.Position + Vector3.new(0, session.centerYOffset, 0)
			local flatCameraPosition = Vector3.new(camera.CFrame.Position.X, center.Y, camera.CFrame.Position.Z)
			if (flatCameraPosition - center).Magnitude < 0.01 then
				flatCameraPosition = center + Vector3.zAxis
			end
			session.proxyPlane.CFrame = CFrame.lookAt(center, flatCameraPosition)
			local cameraForward = Utils.flatUnit(session.sourceRoot.Position - camera.CFrame.Position, -Vector3.zAxis)
			local characterForward = Utils.flatUnit(session.sourceRoot.CFrame.LookVector, -Vector3.zAxis)
			local cameraBasis = CFrame.lookAt(Vector3.zero, cameraForward)
			local characterBasis = CFrame.lookAt(Vector3.zero, characterForward)
			local _, relativeYaw = cameraBasis:ToObjectSpace(characterBasis):ToOrientation()
			session.viewportRoot.CFrame =
				CFrame.new(session.viewportRootPosition) * CFrame.Angles(0, relativeYaw, 0)
		end
	end
	totalUpdateTime += os.clock() - started
	updateSamples += 1
end

createPanel()
if RunService:IsStudio() and Config.ProceduralChibiRunSelfTest then
	local selfTestOk, selfTestResult = pcall(ProceduralChibiSelfTest.Run)
	if selfTestOk then
		print(string.format(
			"[ProceduralChibiSelfTest] PASS colors=%d fallback=%d accents=%d",
			selfTestResult.finalColors,
			selfTestResult.fallbackPixels,
			selfTestResult.accentComponents
		))
	else
		selfTestError = tostring(selfTestResult)
		statusWarning.Text = "ProceduralChibiSelfTest FALLÓ: " .. selfTestError
		warn("[ProceduralChibiSelfTest] FAIL: " .. tostring(selfTestResult))
	end
	local layeredTestOk, layeredTestResult = pcall(LayeredSpriteSelfTest.Run)
	if layeredTestOk then
		print(string.format(
			"[LayeredSpriteSelfTest] PASS fingerprint=%s layers=%d cacheHits=%d stale=%d transitions=%d images=%d",
			layeredTestResult.fingerprint,
			layeredTestResult.layerCount,
			layeredTestResult.cacheHits,
			layeredTestResult.staleResponses,
			layeredTestResult.transitions,
			layeredTestResult.imagesCreated
		))
	else
		selfTestError = tostring(layeredTestResult)
		statusWarning.Text = "LayeredSpriteSelfTest FALLÓ: " .. selfTestError
		warn("[LayeredSpriteSelfTest] FAIL: " .. tostring(layeredTestResult))
	end
end
for candidate, button in modeButtons do
	table.insert(globalConnections, button.Activated:Connect(function()
		mode = candidate
		applyMode()
	end))
end
table.insert(globalConnections, outlineButton.Activated:Connect(function()
	outlineEnabled = not outlineEnabled
	if mode == "Thumbnail" or mode == "ProceduralChibi" or mode == "Layered" then
		regenerateThumbnail()
	end
	applyMode()
end))
table.insert(globalConnections, stageButton.Activated:Connect(function()
	local currentIndex = table.find(Config.ProceduralChibiDebugStages, proceduralDebugStage) or 0
	local nextIndex = currentIndex % #Config.ProceduralChibiDebugStages + 1
	proceduralDebugStage = Config.ProceduralChibiDebugStages[nextIndex]
	if mode == "ProceduralChibi" then
		regenerateThumbnail()
	end
	refreshButtonStyles()
	refreshStatus()
end))
stageEvent.Event:Connect(function(requestedStage: string)
	if not table.find(Config.ProceduralChibiDebugStages, requestedStage) then
		warn("[PixelAvatar] unknown requested debug stage: " .. tostring(requestedStage))
		return
	end
	proceduralDebugStage = requestedStage
	if mode == "ProceduralChibi" then
		regenerateThumbnail()
	end
	refreshButtonStyles()
	refreshStatus()
end)
for index, button in resolutionButtons do
	table.insert(globalConnections, button.Activated:Connect(function()
		resolution = Config.Resolutions[index]
		updateResolution()
		if mode == "Thumbnail" or mode == "ProceduralChibi" or mode == "Layered" then
			regenerateThumbnail()
		end
		refreshButtonStyles()
		refreshStatus()
	end))
end
for index, button in rateButtons do
	table.insert(globalConnections, button.Activated:Connect(function()
		updateRate = Config.UpdateRates[index]
		updateAccumulator = 0
		refreshButtonStyles()
		refreshStatus()
	end))
end

for _, player in Players:GetPlayers() do
	watchPlayer(player)
end
table.insert(globalConnections, Players.PlayerAdded:Connect(watchPlayer))
table.insert(globalConnections, Players.PlayerRemoving:Connect(unwatchPlayer))

table.insert(globalConnections, RunService.RenderStepped:Connect(function(deltaTime)
	updateAccumulator += deltaTime
	sampleElapsed += deltaTime
	sampleFrames += 1
	if updateAccumulator >= 1 / updateRate then
		updateAccumulator %= 1 / updateRate
		updateSessions()
	end
	if sampleElapsed >= 0.5 then
		measuredFps = math.floor((sampleFrames / sampleElapsed) + 0.5)
		averageUpdateMs = if updateSamples > 0 then (totalUpdateTime / updateSamples) * 1000 else 0
		sampleElapsed = 0
		sampleFrames = 0
		updateSamples = 0
		totalUpdateTime = 0
		refreshStatus()
	end
end))

applyMode()
print("[PixelAvatar] Roblox-only comparison controller ready")
