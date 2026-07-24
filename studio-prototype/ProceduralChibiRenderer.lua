--!strict

local AssetService = game:GetService("AssetService")
local Players = game:GetService("Players")

local Body = require(script.Parent:WaitForChild("ProceduralChibiBody"))
local Face = require(script.Parent:WaitForChild("ProceduralChibiFace"))
local HairAnalyzer = require(script.Parent:WaitForChild("HairColorAnalyzer"))
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
	| "BeforeFace"
	| "BeforeFinalize"
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
}

export type Metrics = {
	stage: DebugStage,
	requestedColors: number,
	paletteColors: number,
	finalColors: number,
	regions: { [string]: RegionMetrics },
	totalFallbackPixels: number,
	accentComponents: number,
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
	BeforeFace = true,
	BeforeFinalize = true,
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
	regions: { [string]: RegionMetrics }
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
		local bodyProjected, bodyAccents, proceduralBody, bodyMasks, bodyLockedColors, regionMetrics =
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
		local headTarget: Bounds = {
			minX = 5,
			minY = 3,
			maxX = outputWidth - 6,
			maxY = headBottom,
		}
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
		else
			Raster.CompositeBufferSourceOver(outputPixels, proceduralBody, outputSize)
			Raster.CopyRegionArea(avatarPixels, avatarSourceSize, headSource, outputPixels, outputSize, headTarget)
		end

		if stage == "SourceBody"
			or stage == "SourceRegions"
			or stage == "BodySingleCopy"
			or stage == "BodySegments"
			or stage == "BodyMasks"
			or stage == "BodyProjected"
			or stage == "BodyAccents"
			or stage == "BeforeFace" then
			outputImage = allocateImage(outputSize, outputPixels)
			return outputImage, summarizeMetrics(stage, requestedColors, outputPixels, outputSize, regionMetrics)
		end

		local hairColors = HairAnalyzer.Analyze(
			headPixels,
			headSourceSize,
			headAnalysisBounds,
			avatarSignals.skinColor,
			options.AlphaThreshold
		)
		local faceLayer, faceColors = Face.Paint(
			outputSize,
			headTarget,
			avatarSignals.skinColor,
			options.EyeColor,
			hairColors
		)
		Raster.CompositeBufferSourceOver(outputPixels, faceLayer, outputSize)
		if stage == "BeforeFinalize" then
			outputImage = allocateImage(outputSize, outputPixels)
			return outputImage, summarizeMetrics(stage, requestedColors, outputPixels, outputSize, regionMetrics)
		end

		local lockedColors: { Color3 } = {
			faceColors.skin,
			faceColors.skinShadow,
			faceColors.hairPrimary,
			faceColors.hairSecondary,
			faceColors.hairHighlight,
			faceColors.hairShadow,
			faceColors.eye,
			faceColors.eyeShadow,
			faceColors.eyeOutline,
			faceColors.highlight,
			faceColors.blush,
		}
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
		local finalMetrics = summarizeMetrics(stage, requestedColors, finalizedPixels, outputSize, regionMetrics)
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
