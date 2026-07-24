--!strict

local AssetService = game:GetService("AssetService")
local Players = game:GetService("Players")

local Body = require(script.Parent:WaitForChild("ProceduralChibiBody"))
local Head = require(script.Parent:WaitForChild("ProceduralChibiHead"))
local HeadAnalyzer = require(script.Parent:WaitForChild("ProceduralChibiHeadAnalyzer"))
local ImageFinalizer = require(script.Parent:WaitForChild("ProceduralImageFinalizer"))
local OutfitAnalyzer = require(script.Parent:WaitForChild("ProceduralChibiOutfitAnalyzer"))
local Raster = require(script.Parent:WaitForChild("ProceduralRaster"))

type Bounds = Raster.Bounds
type RegionMetrics = Body.RegionMetrics

export type DebugStage =
	"SourceBody"
	| "SourceRegions"
	| "BodySingleCopy"
	| "BodySegments"
	| "BodyMasks"
	| "BodyProjected"
	| "BodyAccents"
	| "HeadSource"
	| "HairClusters"
	| "HairCore"
	| "HairLabelMap"
	| "HairLabelMapRaw"
	| "HairLabelMapRegularized"
	| "HairColorMasses"
	| "HairCategoricalGrid"
	| "HairMassDescriptors"
	| "HairMassesFinal"
	| "HairMasks"
	| "ProtectedFacialFeatures"
	| "FrontAccessoryAllowed"
	| "SideAccessoryAllowed"
	| "AccessoryCandidates"
	| "AccessoryRawCandidates"
	| "AccessoryMergedGroups"
	| "AccessoryAnchors"
	| "AccessorySelectedPerZone"
	| "AccessoryPairLayout"
	| "AccessoryCompositeBeforeClipping"
	| "AccessoryCompositeAfterClipping"
	| "AccessorySalience"
	| "AccessoryRelativeScale"
	| "AccessoryTargetLayout"
	| "AccessorySimplified"
	| "AccessoryCoverageBudget"
	| "AccessoryShapeOccupancy"
	| "AccessoryContours"
	| "AccessoryHoles"
	| "AccessoryColorRoles"
	| "AccessoryRenderModes"
	| "AccessoryShapePreserving"
	| "AccessoryTemplateAssisted"
	| "AccessoryPrimitiveFallback"
	| "AccessoryFinalLayout"
	| "AccessoryCoreSeeds"
	| "AccessorySupportMask"
	| "AccessoryCompletedClusters"
	| "AccessoryRecoveredSkinLike"
	| "AccessoryRecoveredHairLike"
	| "AccessoryClusterBounds"
	| "AccessoryGeometryKinds"
	| "AccessoryLinearDescriptors"
	| "AccessorySafeCanvas"
	| "AccessoryBoundsBeforeFit"
	| "AccessoryBoundsAfterFit"
	| "AccessoryHairAttachment"
	| "AccessoryProtectedFaceOverlap"
	| "AccessoryBeforeFinalValidation"
	| "AccessoryAfterFinalValidation"
	| "AccessoryPostClipHoles"
	| "AccessoryPostClipTopology"
	| "TemplateAssistedLandmarks"
	| "TemplateAssistedResult"
	| "AccessoryBackLayer"
	| "AccessorySideLayer"
	| "AccessoryFrontLayer"
	| "FringeMask"
	| "SkirtSourceMask"
	| "ShoulderRepair"
	| "SleeveBandDescriptors"
	| "SleevesStructured"
	| "LowerGarmentPalette"
	| "LowerGarmentSubregions"
	| "BodyStructured"
	| "TorsoDescriptor"
	| "TorsoStructured"
	| "TorsoSourceAccents"
	| "TorsoRetainedAccents"
	| "SleeveLocalCoordinates"
	| "SleeveBandsStructured"
	| "LowerGarmentSourceSubregions"
	| "LowerGarmentPanelDescriptors"
	| "LowerGarmentStructured"
	| "GarmentSourceSubregions"
	| "GarmentPanelDescriptors"
	| "GarmentPanelsStructured"
	| "BootDescriptors"
	| "BootsStructured"
	| "BootSubparts"
	| "AccentBudget"
	| "RegionColorBudget"
	| "HeadWithoutAccessories"
	| "HeadComposite"
	| "LegacyCopiedHead"
	| "BeforeFace"
	| "BeforeFinalize"
	| "FinalBeforeQuantize"
	| "FinalBeforePalette"
	| "Final"

export type Options = {
	OutputSize: Vector2,
	SkinColor: Color3?,
	EyeColor: Color3,
	HeadRatio: number,
	HeadHeightRatio: number?,
	PaletteSize: number?,
	AlphaThreshold: number?,
	OutlineColor: Color3?,
	OutlineEnabled: boolean?,
	DebugStage: DebugStage?,
	HeadWidthRatio: number?,
	HairSecondaryMinimumCoverage: number?,
	AccessoryMinimumConfidence: number?,
	MaxAccessoryComponents: number?,
	HeadFallbackEnabled: boolean?,
}

export type Metrics = {
	stage: DebugStage,
	requestedColors: number,
	paletteColors: number,
	finalColors: number,
	regions: { [string]: RegionMetrics },
	totalFallbackPixels: number,
	accentComponents: number,
	head: Head.HeadMetrics,
	body: Body.BodyMetrics,
}

type AvatarSignals = {
	skinColor: Color3,
	bodyColors: OutfitAnalyzer.BodyColors,
}

local ProceduralChibiRenderer = {}

local VALID_STAGES: { [string]: boolean } = {
	SourceBody = true,
	SourceRegions = true,
	BodySingleCopy = true,
	BodySegments = true,
	BodyMasks = true,
	BodyProjected = true,
	BodyAccents = true,
	HeadSource = true,
	HairClusters = true,
	HairCore = true,
	HairLabelMap = true,
	HairLabelMapRaw = true,
	HairLabelMapRegularized = true,
	HairColorMasses = true,
	HairCategoricalGrid = true,
	HairMassDescriptors = true,
	HairMassesFinal = true,
	HairMasks = true,
	ProtectedFacialFeatures = true,
	FrontAccessoryAllowed = true,
	SideAccessoryAllowed = true,
	AccessoryCandidates = true,
	AccessoryRawCandidates = true,
	AccessoryMergedGroups = true,
	AccessoryAnchors = true,
	AccessorySelectedPerZone = true,
	AccessoryPairLayout = true,
	AccessoryCompositeBeforeClipping = true,
	AccessoryCompositeAfterClipping = true,
	AccessorySalience = true,
	AccessoryRelativeScale = true,
	AccessoryTargetLayout = true,
	AccessorySimplified = true,
	AccessoryCoverageBudget = true,
	AccessoryShapeOccupancy = true,
	AccessoryContours = true,
	AccessoryHoles = true,
	AccessoryColorRoles = true,
	AccessoryRenderModes = true,
	AccessoryShapePreserving = true,
	AccessoryTemplateAssisted = true,
	AccessoryPrimitiveFallback = true,
	AccessoryFinalLayout = true,
	AccessoryCoreSeeds = true,
	AccessorySupportMask = true,
	AccessoryCompletedClusters = true,
	AccessoryRecoveredSkinLike = true,
	AccessoryRecoveredHairLike = true,
	AccessoryClusterBounds = true,
	AccessoryGeometryKinds = true,
	AccessoryLinearDescriptors = true,
	AccessorySafeCanvas = true,
	AccessoryBoundsBeforeFit = true,
	AccessoryBoundsAfterFit = true,
	AccessoryHairAttachment = true,
	AccessoryProtectedFaceOverlap = true,
	AccessoryBeforeFinalValidation = true,
	AccessoryAfterFinalValidation = true,
	AccessoryPostClipHoles = true,
	AccessoryPostClipTopology = true,
	TemplateAssistedLandmarks = true,
	TemplateAssistedResult = true,
	AccessoryBackLayer = true,
	AccessorySideLayer = true,
	AccessoryFrontLayer = true,
	FringeMask = true,
	SkirtSourceMask = true,
	ShoulderRepair = true,
	SleeveBandDescriptors = true,
	SleevesStructured = true,
	LowerGarmentPalette = true,
	LowerGarmentSubregions = true,
	BodyStructured = true,
	TorsoDescriptor = true,
	TorsoStructured = true,
	TorsoSourceAccents = true,
	TorsoRetainedAccents = true,
	SleeveLocalCoordinates = true,
	SleeveBandsStructured = true,
	LowerGarmentSourceSubregions = true,
	LowerGarmentPanelDescriptors = true,
	LowerGarmentStructured = true,
	GarmentSourceSubregions = true,
	GarmentPanelDescriptors = true,
	GarmentPanelsStructured = true,
	BootDescriptors = true,
	BootsStructured = true,
	BootSubparts = true,
	AccentBudget = true,
	RegionColorBudget = true,
	HeadWithoutAccessories = true,
	HeadComposite = true,
	LegacyCopiedHead = true,
	BeforeFace = true,
	BeforeFinalize = true,
	FinalBeforeQuantize = true,
	FinalBeforePalette = true,
	Final = true,
}

local function offset(width: number, x: number, y: number): number
	return (y * width + x) * 4
end

local function validateOptions(options: Options): (Vector2, number, DebugStage)
	local width = math.floor(options.OutputSize.X)
	local height = math.floor(options.OutputSize.Y)
	if width < 32 or width > 256 or height < 48 or height > 384 then
		error("Procedural chibi OutputSize must be between 32x48 and 256x384")
	end
	if options.OutputSize.X ~= width or options.OutputSize.Y ~= height then
		error("Procedural chibi OutputSize must contain whole pixel dimensions")
	end
	if options.HeadRatio < 0.25 or options.HeadRatio > 0.7 then
		error("Procedural chibi HeadRatio must be between 0.25 and 0.7")
	end
	local stage = options.DebugStage or "Final"
	if not VALID_STAGES[stage] then
		error("Unknown procedural chibi debug stage: " .. tostring(stage))
	end
	return Vector2.new(width, height), math.clamp(math.floor(options.PaletteSize or 48), 8, 96), stage
end

local function findBounds(
	pixels: buffer,
	width: number,
	height: number,
	minY: number?,
	maxY: number?
): Bounds?
	local firstY = math.clamp(minY or 0, 0, height - 1)
	local lastY = math.clamp(maxY or (height - 1), firstY, height - 1)
	local result: Bounds = { minX = width, minY = lastY + 1, maxX = -1, maxY = -1 }
	for y = firstY, lastY do
		for x = 0, width - 1 do
			if buffer.readu8(pixels, offset(width, x, y) + 3) > 8 then
				result.minX = math.min(result.minX, x)
				result.minY = math.min(result.minY, y)
				result.maxX = math.max(result.maxX, x)
				result.maxY = math.max(result.maxY, y)
			end
		end
	end
	return if result.maxX >= result.minX then result else nil
end

local function loadThumbnail(
	userId: number,
	thumbnailType: Enum.ThumbnailType
): (EditableImage, buffer, Vector2)
	local thumbnailUri, isReady = Players:GetUserThumbnailAsync(
		userId,
		thumbnailType,
		Enum.ThumbnailSize.Size420x420
	)
	if not isReady then
		error("Roblox thumbnail is not ready for " .. tostring(thumbnailType))
	end
	local image = AssetService:CreateEditableImageAsync(Content.fromUri(thumbnailUri))
	if not image then
		error("AssetService could not load " .. tostring(thumbnailType))
	end
	return image, image:ReadPixelsBuffer(Vector2.zero, image.Size), image.Size
end

local function readAvatarSignals(userId: number, fallback: Color3?): AvatarSignals
	local fallbackSkin = fallback or Color3.fromRGB(241, 195, 170)
	local ok, description = pcall(function()
		return Players:GetHumanoidDescriptionFromUserIdAsync(userId)
	end)
	if ok and description then
		local avatar = description :: HumanoidDescription
		return {
			skinColor = avatar.HeadColor,
			bodyColors = {
				head = avatar.HeadColor,
				torso = avatar.TorsoColor,
				leftArm = avatar.LeftArmColor,
				rightArm = avatar.RightArmColor,
				leftLeg = avatar.LeftLegColor,
				rightLeg = avatar.RightLegColor,
			},
		}
	end
	return {
		skinColor = fallbackSkin,
		bodyColors = {
			head = fallbackSkin,
			torso = fallbackSkin,
			leftArm = fallbackSkin,
			rightArm = fallbackSkin,
			leftLeg = fallbackSkin,
			rightLeg = fallbackSkin,
		},
	}
end

local function allocateImage(size: Vector2, pixels: buffer): EditableImage
	local image = AssetService:CreateEditableImage({ Size = size })
	if not image then
		error("AssetService could not allocate the procedural chibi image")
	end
	image:WritePixelsBuffer(Vector2.zero, size, pixels)
	return image
end

local function appendColors(target: { Color3 }, colors: { Color3 })
	for _, color in colors do
		table.insert(target, color)
	end
end

local function summarizeMetrics(
	stage: DebugStage,
	requestedColors: number,
	pixels: buffer,
	size: Vector2,
	regions: { [string]: RegionMetrics },
	headMetrics: Head.HeadMetrics?,
	bodyMetrics: Body.BodyMetrics?
): Metrics
	local colors = ImageFinalizer.CountOpaqueColors(pixels, size)
	local fallback = 0
	local accents = 0
	for _, region in regions do
		fallback += region.fallbackPixels
		accents += region.accentComponents
	end
	return {
		stage = stage,
		requestedColors = requestedColors,
		paletteColors = colors,
		finalColors = colors,
		regions = regions,
		totalFallbackPixels = fallback,
		accentComponents = accents,
		head = headMetrics or {
			proceduralUsed = false,
			fallbackUsed = false,
			primaryCoverage = 0,
			secondaryCoverage = 0,
			hairCoreCoverage = 0,
			fringeGapCount = 0,
			strayPixelCount = 0,
			accessoryCandidates = 0,
			accessoriesAccepted = 0,
			accessoriesRejectedFace = 0,
			rawComponents = 0,
			mergedComponents = 0,
			acceptedComponents = 0,
			projectedComponents = 0,
			averageFillRatio = 0,
			repairedPixels = 0,
			clippedPixels = 0,
			byZone = {},
			fallbackPixels = 0,
		},
		body = bodyMetrics or {
			lowerGarmentSkinRatio = 0,
			lowerGarmentCentralCoverage = 0,
			shoulderPixelsRepaired = 0,
			shoulderPixelsOverwritten = 0,
		},
	}
end

local function paintMaskDiagnostic(
	target: buffer,
	size: Vector2,
	masks: { [string]: buffer }
)
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	local colors = {
		leftArm = Color3.fromRGB(63, 164, 255),
		rightArm = Color3.fromRGB(255, 107, 201),
		leftHand = Color3.fromRGB(255, 204, 170),
		rightHand = Color3.fromRGB(255, 204, 170),
		torso = Color3.fromRGB(54, 230, 138),
		abdomen = Color3.fromRGB(255, 222, 120),
		skirt = Color3.fromRGB(168, 96, 255),
		leftLeg = Color3.fromRGB(104, 209, 255),
		rightLeg = Color3.fromRGB(255, 147, 198),
		leftBoot = Color3.fromRGB(54, 62, 82),
		rightBoot = Color3.fromRGB(76, 64, 92),
	}
	for name, mask in masks do
		local color = colors[name] or Color3.new(1, 1, 1)
		local red = math.round(color.R * 255)
		local green = math.round(color.G * 255)
		local blue = math.round(color.B * 255)
		for y = 0, height - 1 do
			for x = 0, width - 1 do
				local pixelOffset = offset(width, x, y)
				if buffer.readu8(mask, pixelOffset + 3) > 0 then
					Raster.SourceOverPixel(target, width, height, x, y, {
						r = red,
						g = green,
						b = blue,
						a = 255,
					})
				end
			end
		end
	end
end

local function paintSourceRegions(
	target: buffer,
	size: Vector2,
	sourcePixels: buffer,
	sourceSize: Vector2,
	bodySource: Bounds,
	analysis: OutfitAnalyzer.OutfitAnalysis
)
	local width = math.floor(size.X)
	local targetBounds: Bounds = { minX = 12, minY = 3, maxX = width - 13, maxY = math.floor(size.Y) - 4 }
	Raster.CopyRegionArea(sourcePixels, sourceSize, bodySource, target, size, targetBounds)
	local sourceRegionWidth = math.max(1, bodySource.maxX - bodySource.minX)
	local sourceRegionHeight = math.max(1, bodySource.maxY - bodySource.minY)
	local targetRegionWidth = targetBounds.maxX - targetBounds.minX
	local targetRegionHeight = targetBounds.maxY - targetBounds.minY
	local function mapPoint(x: number, y: number): Vector2
		return Vector2.new(
			targetBounds.minX + (x - bodySource.minX) / sourceRegionWidth * targetRegionWidth,
			targetBounds.minY + (y - bodySource.minY) / sourceRegionHeight * targetRegionHeight
		)
	end
	local diagnostics = {
		{ analysis.torso, Color3.fromRGB(54, 230, 138) },
		{ analysis.leftSleeve, Color3.fromRGB(63, 164, 255) },
		{ analysis.rightSleeve, Color3.fromRGB(255, 107, 201) },
		{ analysis.midriff, Color3.fromRGB(255, 222, 120) },
		{ analysis.lowerGarment, Color3.fromRGB(168, 96, 255) },
		{ analysis.leftLeg, Color3.fromRGB(104, 209, 255) },
		{ analysis.rightLeg, Color3.fromRGB(255, 147, 198) },
	}
	for _, entry in diagnostics do
		local region = (entry[1] :: OutfitAnalyzer.SourceRegion).bounds
		local color = entry[2] :: Color3
		local topLeft = mapPoint(region.minX, region.minY)
		local bottomRight = mapPoint(region.maxX, region.maxY)
		Raster.DrawLine(target, size, topLeft, Vector2.new(bottomRight.X, topLeft.Y), color)
		Raster.DrawLine(target, size, Vector2.new(bottomRight.X, topLeft.Y), bottomRight, color)
		Raster.DrawLine(target, size, bottomRight, Vector2.new(topLeft.X, bottomRight.Y), color)
		Raster.DrawLine(target, size, Vector2.new(topLeft.X, bottomRight.Y), topLeft, color)
	end
	local centerTop = mapPoint(analysis.centerX, bodySource.minY)
	local centerBottom = mapPoint(analysis.centerX, bodySource.maxY)
	Raster.DrawLine(target, size, centerTop, centerBottom, Color3.fromRGB(255, 244, 92))
end

function ProceduralChibiRenderer.Create(
	userId: number,
	options: Options
): (EditableImage, Metrics)
	local outputSize, requestedColors, stage = validateOptions(options)
	local outputWidth = math.floor(outputSize.X)
	local outputHeight = math.floor(outputSize.Y)
	local headImage: EditableImage? = nil
	local avatarImage: EditableImage? = nil
	local outputImage: EditableImage? = nil

	local ok, imageOrError, metrics = xpcall(function()
		local loadedHead, headPixels, headSourceSize = loadThumbnail(userId, Enum.ThumbnailType.HeadShot)
		headImage = loadedHead
		local loadedAvatar, avatarPixels, avatarSourceSize =
			loadThumbnail(userId, Enum.ThumbnailType.AvatarThumbnail)
		avatarImage = loadedAvatar

		local avatarWidth = math.floor(avatarSourceSize.X)
		local avatarHeight = math.floor(avatarSourceSize.Y)
		local fullBounds = findBounds(avatarPixels, avatarWidth, avatarHeight)
		local headAnalysisBounds = findBounds(headPixels, math.floor(headSourceSize.X), math.floor(headSourceSize.Y))
		if not fullBounds or not headAnalysisBounds then
			error("Procedural chibi source has no visible pixels")
		end
		local headCutoff = math.clamp(
			fullBounds.minY + math.floor((fullBounds.maxY - fullBounds.minY + 1) * options.HeadRatio),
			fullBounds.minY,
			fullBounds.maxY - 1
		)
		local headSource = findBounds(avatarPixels, avatarWidth, avatarHeight, fullBounds.minY, headCutoff)
		local bodySource = findBounds(avatarPixels, avatarWidth, avatarHeight, headCutoff + 1, fullBounds.maxY)
		if not headSource or not bodySource then
			error("Procedural chibi could not isolate head and body")
		end

		local avatarSignals = readAvatarSignals(userId, options.SkinColor)
		local analysis = OutfitAnalyzer.Analyze(avatarPixels, avatarSourceSize, bodySource, avatarSignals.bodyColors)
		local inkColor = options.OutlineColor or Color3.fromRGB(28, 34, 46)
		local bodyProjected, bodyAccents, proceduralBody, bodyMasks, bodyLockedColors, regionMetrics, bodyMetrics, bodyDebug =
			Body.Paint(
				outputSize,
				avatarPixels,
				avatarSourceSize,
				analysis,
				avatarSignals.bodyColors,
				inkColor
			)
		local headBottom =
			math.floor(outputHeight * math.clamp(options.HeadHeightRatio or 0.41, 0.34, 0.48))
		local headAnalysis = HeadAnalyzer.Analyze(
			headPixels,
			headSourceSize,
			headAnalysisBounds,
			avatarSignals.skinColor,
			{
				AlphaThreshold = options.AlphaThreshold,
				SecondaryMinimumCoverage = options.HairSecondaryMinimumCoverage,
				AccessoryMinimumConfidence = options.AccessoryMinimumConfidence,
				MaxAccessoryComponents = options.MaxAccessoryComponents,
			}
		)
		local automaticWidthRatio = math.clamp(
			0.74 + (headAnalysis.hair.hairCoreAspect - 0.65) * 0.16,
			0.74,
			0.82
		)
		local headWidthRatio = if options.HeadWidthRatio
			then math.clamp(options.HeadWidthRatio, 0.68, 0.94)
			else automaticWidthRatio
		local headWidth = math.floor(outputWidth * headWidthRatio)
		local headCenter = math.floor(outputWidth / 2)
		local headTarget: Bounds = {
			minX = headCenter - math.floor(headWidth / 2),
			minY = 3,
			maxX = headCenter + math.floor(headWidth / 2),
			maxY = headBottom,
		}
		local headResult = Head.Paint(
			outputSize,
			headTarget,
			headPixels,
			headSourceSize,
			headAnalysisBounds,
			headAnalysis,
			avatarSignals.skinColor,
			options.EyeColor,
			inkColor
		)
		local outputPixels = buffer.create(outputWidth * outputHeight * 4)

		if stage == "SourceBody" then
			Raster.CopyRegionArea(
				avatarPixels,
				avatarSourceSize,
				bodySource,
				outputPixels,
				outputSize,
				{ minX = 12, minY = 3, maxX = outputWidth - 13, maxY = outputHeight - 4 }
			)
		elseif stage == "SourceRegions" then
			paintSourceRegions(outputPixels, outputSize, avatarPixels, avatarSourceSize, bodySource, analysis)
		elseif stage == "BodySingleCopy" then
			Raster.CopyRegionArea(
				avatarPixels,
				avatarSourceSize,
				bodySource,
				outputPixels,
				outputSize,
				{ minX = 18, minY = headBottom - 4, maxX = outputWidth - 19, maxY = outputHeight - 4 }
			)
		elseif stage == "BodySegments" then
			local bands = Raster.MakeBodyBands(bodySource)
			Raster.CopyRegionArea(avatarPixels, avatarSourceSize, bands.torso, outputPixels, outputSize, { minX = 18, minY = 104, maxX = outputWidth - 19, maxY = 150 })
			Raster.CopyRegionArea(avatarPixels, avatarSourceSize, bands.hips, outputPixels, outputSize, { minX = 24, minY = 151, maxX = outputWidth - 25, maxY = 190 })
			Raster.CopyRegionArea(avatarPixels, avatarSourceSize, bands.legs, outputPixels, outputSize, { minX = 34, minY = 191, maxX = outputWidth - 35, maxY = outputHeight - 4 })
		elseif stage == "BodyMasks" then
			paintMaskDiagnostic(outputPixels, outputSize, bodyMasks)
		elseif stage == "BodyProjected" then
			Raster.CompositeBufferSourceOver(outputPixels, bodyProjected, outputSize)
		elseif stage == "BodyAccents" then
			Raster.CompositeBufferSourceOver(outputPixels, bodyAccents, outputSize)
		elseif stage == "SkirtSourceMask" then
			Raster.CompositeBufferSourceOver(outputPixels, bodyDebug.SkirtSourceMask, outputSize)
		elseif stage == "ShoulderRepair" then
			Raster.CompositeBufferSourceOver(outputPixels, bodyDebug.ShoulderRepair, outputSize)
		elseif stage == "SleeveBandDescriptors"
			or stage == "SleevesStructured"
			or stage == "LowerGarmentPalette"
			or stage == "LowerGarmentSubregions"
			or stage == "BodyStructured"
			or stage == "TorsoDescriptor"
			or stage == "TorsoStructured"
			or stage == "TorsoSourceAccents"
			or stage == "TorsoRetainedAccents"
			or stage == "SleeveLocalCoordinates"
			or stage == "SleeveBandsStructured"
			or stage == "LowerGarmentSourceSubregions"
			or stage == "LowerGarmentPanelDescriptors"
			or stage == "LowerGarmentStructured"
			or stage == "GarmentSourceSubregions"
			or stage == "GarmentPanelDescriptors"
			or stage == "GarmentPanelsStructured"
			or stage == "BootDescriptors"
			or stage == "BootsStructured"
			or stage == "BootSubparts"
			or stage == "AccentBudget"
			or stage == "RegionColorBudget" then
			Raster.CompositeBufferSourceOver(outputPixels, bodyDebug[stage], outputSize)
		else
			Raster.CompositeBufferSourceOver(outputPixels, proceduralBody, outputSize)
			if stage == "HeadSource" then
				outputPixels = buffer.create(outputWidth * outputHeight * 4)
				Raster.CopyRegionArea(headPixels, headSourceSize, headAnalysisBounds, outputPixels, outputSize, headTarget)
			elseif stage == "HairClusters" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.hairClusters, outputSize)
			elseif stage == "HairCore" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.hairCore, outputSize)
			elseif stage == "HairLabelMap" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.hairLabelMap, outputSize)
			elseif stage == "HairLabelMapRaw" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.hairLabelMapRaw, outputSize)
			elseif stage == "HairLabelMapRegularized" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.hairLabelMapRegularized, outputSize)
			elseif stage == "HairColorMasses" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.hairColorMasses, outputSize)
			elseif stage == "HairCategoricalGrid" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.hairLabelMapRegularized, outputSize)
			elseif stage == "HairMassDescriptors" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.hairMassDescriptors, outputSize)
			elseif stage == "HairMassesFinal" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.hairColorMasses, outputSize)
			elseif stage == "HairMasks" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.hairMasks, outputSize)
			elseif stage == "ProtectedFacialFeatures" then
				paintMaskDiagnostic(outputPixels, outputSize, {
					protected = headResult.masks.protectedFacialFeaturesMask,
				})
			elseif stage == "FrontAccessoryAllowed" then
				paintMaskDiagnostic(outputPixels, outputSize, {
					allowed = headResult.masks.frontAccessoryAllowed,
				})
			elseif stage == "SideAccessoryAllowed" then
				paintMaskDiagnostic(outputPixels, outputSize, {
					allowed = headResult.masks.sideAccessoryAllowed,
				})
			elseif stage == "AccessoryCandidates" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessoryCandidates, outputSize)
			elseif stage == "AccessoryRawCandidates" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessoryRawCandidates, outputSize)
			elseif stage == "AccessoryMergedGroups" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessoryMergedGroups, outputSize)
			elseif stage == "AccessoryAnchors" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessoryAnchors, outputSize)
			elseif stage == "AccessorySelectedPerZone" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessorySelectedPerZone, outputSize)
			elseif stage == "AccessoryPairLayout" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessoryPairLayout, outputSize)
			elseif stage == "AccessoryCompositeBeforeClipping" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessoryCompositeBeforeClipping, outputSize)
			elseif stage == "AccessoryCompositeAfterClipping" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessoryCompositeAfterClipping, outputSize)
			elseif stage == "AccessorySalience" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessorySelectedPerZone, outputSize)
			elseif stage == "AccessoryRelativeScale" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessoryRelativeScale, outputSize)
			elseif stage == "AccessoryTargetLayout" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessoryTargetLayout, outputSize)
			elseif stage == "AccessorySimplified" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessorySimplified, outputSize)
			elseif stage == "AccessoryCoverageBudget" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessoryCoverageBudget, outputSize)
			elseif stage == "AccessoryShapeOccupancy" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessoryShapeOccupancy, outputSize)
			elseif stage == "AccessoryContours" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessoryContours, outputSize)
			elseif stage == "AccessoryHoles" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessoryHoles, outputSize)
			elseif stage == "AccessoryColorRoles" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessoryColorRoles, outputSize)
			elseif stage == "AccessoryRenderModes" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessoryRenderModes, outputSize)
			elseif stage == "AccessoryShapePreserving" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessoryShapePreserving, outputSize)
			elseif stage == "AccessoryTemplateAssisted" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessoryTemplateAssisted, outputSize)
			elseif stage == "AccessoryPrimitiveFallback" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessoryPrimitiveFallback, outputSize)
			elseif stage == "AccessoryFinalLayout" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessoryFinalLayout, outputSize)
			elseif stage == "AccessoryCoreSeeds" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessoryCoreSeeds, outputSize)
			elseif stage == "AccessorySupportMask" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessorySupportMask, outputSize)
			elseif stage == "AccessoryCompletedClusters" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessoryCompletedClusters, outputSize)
			elseif stage == "AccessoryRecoveredSkinLike" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessoryRecoveredSkinLike, outputSize)
			elseif stage == "AccessoryRecoveredHairLike" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessoryRecoveredHairLike, outputSize)
			elseif stage == "AccessoryClusterBounds" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessoryClusterBounds, outputSize)
			elseif stage == "AccessoryGeometryKinds" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessoryGeometryKinds, outputSize)
			elseif stage == "AccessoryLinearDescriptors" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessoryLinearDescriptors, outputSize)
			elseif stage == "AccessorySafeCanvas" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessorySafeCanvas, outputSize)
			elseif stage == "AccessoryBoundsBeforeFit" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessoryBoundsBeforeFit, outputSize)
			elseif stage == "AccessoryBoundsAfterFit" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessoryBoundsAfterFit, outputSize)
			elseif stage == "AccessoryHairAttachment" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessoryHairAttachment, outputSize)
			elseif stage == "AccessoryProtectedFaceOverlap" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessoryProtectedFaceOverlap, outputSize)
			elseif stage == "AccessoryBeforeFinalValidation" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessoryBeforeFinalValidation, outputSize)
			elseif stage == "AccessoryAfterFinalValidation" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessoryAfterFinalValidation, outputSize)
			elseif stage == "AccessoryPostClipHoles" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessoryPostClipHoles, outputSize)
			elseif stage == "AccessoryPostClipTopology" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.accessoryPostClipTopology, outputSize)
			elseif stage == "TemplateAssistedLandmarks" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.templateAssistedLandmarks, outputSize)
			elseif stage == "TemplateAssistedResult" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.templateAssistedResult, outputSize)
			elseif stage == "AccessoryBackLayer" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.backAccessories, outputSize)
			elseif stage == "AccessorySideLayer" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.sideAccessories, outputSize)
			elseif stage == "AccessoryFrontLayer" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.frontAccessories, outputSize)
			elseif stage == "FringeMask" then
				paintMaskDiagnostic(outputPixels, outputSize, { fringe = headResult.masks.frontHair })
			elseif stage == "HeadWithoutAccessories" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.withoutAccessories, outputSize)
			elseif stage == "BeforeFace" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.backHair, outputSize)
			elseif stage == "LegacyCopiedHead" then
				Raster.CopyRegionArea(avatarPixels, avatarSourceSize, headSource, outputPixels, outputSize, headTarget)
			elseif stage == "HeadComposite"
				or stage == "BeforeFinalize"
				or stage == "FinalBeforeQuantize"
				or stage == "FinalBeforePalette" then
				Raster.CompositeBufferSourceOver(outputPixels, headResult.composite, outputSize)
			else
				local fallbackEnabled = options.HeadFallbackEnabled ~= false
				local lowConfidence = headAnalysis.hair.primaryCoverage < 0.002
				if fallbackEnabled and lowConfidence then
					Raster.CopyRegionArea(avatarPixels, avatarSourceSize, headSource, outputPixels, outputSize, headTarget)
					headResult.metrics.proceduralUsed = false
					headResult.metrics.fallbackUsed = true
					headResult.metrics.fallbackPixels =
						(headTarget.maxX - headTarget.minX + 1) * (headTarget.maxY - headTarget.minY + 1)
				else
					Raster.CompositeBufferSourceOver(outputPixels, headResult.composite, outputSize)
				end
			end
		end

		if stage ~= "Final" then
			outputImage = allocateImage(outputSize, outputPixels)
			return outputImage, summarizeMetrics(
				stage,
				requestedColors,
				outputPixels,
				outputSize,
				regionMetrics,
				headResult.metrics,
				bodyMetrics
			)
		end

		local lockedColors: { Color3 } = {}
		appendColors(lockedColors, headResult.lockedColors)
		appendColors(lockedColors, bodyLockedColors)
		local finalizedPixels, finalizerMetrics = ImageFinalizer.FinalizeWithMetrics(
			outputPixels,
			outputSize,
			{
				PaletteSize = requestedColors,
				LockedColors = lockedColors,
				OutlineColor = inkColor,
				OutlineEnabled = options.OutlineEnabled,
				AlphaThreshold = options.AlphaThreshold or 48,
			}
		)
		outputImage = allocateImage(outputSize, finalizedPixels)
		local finalMetrics = summarizeMetrics(
			stage,
			requestedColors,
			finalizedPixels,
			outputSize,
			regionMetrics,
			headResult.metrics,
			bodyMetrics
		)
		finalMetrics.requestedColors = finalizerMetrics.requestedColors
		finalMetrics.paletteColors = finalizerMetrics.paletteColors
		finalMetrics.finalColors = finalizerMetrics.finalColors
		return outputImage, finalMetrics
	end, debug.traceback)

	if headImage then
		headImage:Destroy()
	end
	if avatarImage then
		avatarImage:Destroy()
	end
	if not ok then
		if outputImage then
			outputImage:Destroy()
		end
		error(imageOrError)
	end
	return imageOrError :: EditableImage, metrics :: Metrics
end

return table.freeze(ProceduralChibiRenderer)
