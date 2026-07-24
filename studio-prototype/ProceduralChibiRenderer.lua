--!strict

local AssetService = game:GetService("AssetService")
local Players = game:GetService("Players")

local Body = require(script.Parent:WaitForChild("ProceduralChibiBody"))
local Face = require(script.Parent:WaitForChild("ProceduralChibiFace"))
local HairAnalyzer = require(script.Parent:WaitForChild("HairColorAnalyzer"))
local ImageFinalizer = require(script.Parent:WaitForChild("ProceduralImageFinalizer"))
local Raster = require(script.Parent:WaitForChild("ProceduralRaster"))

type Bounds = Raster.Bounds

export type DebugStage =
	"SourceBody"
	| "BodySingleCopy"
	| "BodySegments"
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
}

type AvatarSignals = {
	skinColor: Color3,
}

local ProceduralChibiRenderer = {}

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
	if stage ~= "SourceBody"
		and stage ~= "BodySingleCopy"
		and stage ~= "BodySegments"
		and stage ~= "BeforeFace"
		and stage ~= "BeforeFinalize"
		and stage ~= "Final" then
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
	local result: Bounds = {
		minX = width,
		minY = lastY + 1,
		maxX = -1,
		maxY = -1,
	}
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
	if result.maxX < result.minX then
		return nil
	end
	return result
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
	local ok, description = pcall(function()
		return Players:GetHumanoidDescriptionFromUserIdAsync(userId)
	end)
	if ok and description then
		return { skinColor = (description :: HumanoidDescription).HeadColor }
	end
	return { skinColor = fallback or Color3.fromRGB(241, 195, 170) }
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
		local loadedHead, headPixels, headSourceSize =
			loadThumbnail(userId, Enum.ThumbnailType.HeadShot)
		headImage = loadedHead
		local loadedAvatar, avatarPixels, avatarSourceSize =
			loadThumbnail(userId, Enum.ThumbnailType.AvatarThumbnail)
		avatarImage = loadedAvatar

		local avatarWidth = math.floor(avatarSourceSize.X)
		local avatarHeight = math.floor(avatarSourceSize.Y)
		local fullBounds = findBounds(avatarPixels, avatarWidth, avatarHeight)
		local headAnalysisBounds = findBounds(
			headPixels,
			math.floor(headSourceSize.X),
			math.floor(headSourceSize.Y)
		)
		if not fullBounds or not headAnalysisBounds then
			error("Procedural chibi source has no visible pixels")
		end
		local headCutoff = math.clamp(
			fullBounds.minY
				+ math.floor((fullBounds.maxY - fullBounds.minY + 1) * options.HeadRatio),
			fullBounds.minY,
			fullBounds.maxY - 1
		)
		local headSource =
			findBounds(avatarPixels, avatarWidth, avatarHeight, fullBounds.minY, headCutoff)
		local bodySource =
			findBounds(avatarPixels, avatarWidth, avatarHeight, headCutoff + 1, fullBounds.maxY)
		if not headSource or not bodySource then
			error("Procedural chibi could not isolate head and body")
		end
		local bands = Raster.MakeBodyBands(bodySource)
		local avatarSignals = readAvatarSignals(userId, options.SkinColor)
		local headBottom =
			math.floor(outputHeight * math.clamp(options.HeadHeightRatio or 0.41, 0.34, 0.48))
		local neckOverlap = math.max(3, math.floor(outputHeight * 0.025))
		local headTarget: Bounds = {
			minX = 5,
			minY = 3,
			maxX = outputWidth - 6,
			maxY = headBottom,
		}
		local wholeBodyTarget: Bounds = {
			minX = math.floor(outputWidth * 0.14),
			minY = headBottom - neckOverlap,
			maxX = outputWidth - math.floor(outputWidth * 0.14) - 1,
			maxY = outputHeight - 5,
		}
		local torsoTarget: Bounds = {
			minX = math.floor(outputWidth * 0.14),
			minY = headBottom - neckOverlap,
			maxX = outputWidth - math.floor(outputWidth * 0.14) - 1,
			maxY = math.floor(outputHeight * 0.64),
		}
		local hipsTarget: Bounds = {
			minX = math.floor(outputWidth * 0.18),
			minY = math.floor(outputHeight * 0.64) + 1,
			maxX = outputWidth - math.floor(outputWidth * 0.18) - 1,
			maxY = math.floor(outputHeight * 0.75),
		}
		local legsTarget: Bounds = {
			minX = math.floor(outputWidth * 0.24),
			minY = math.floor(outputHeight * 0.75) + 1,
			maxX = outputWidth - math.floor(outputWidth * 0.24) - 1,
			maxY = outputHeight - 5,
		}

		local outputPixels = buffer.create(outputWidth * outputHeight * 4)
		if stage == "SourceBody" then
			Raster.CopyRegionArea(
				avatarPixels,
				avatarSourceSize,
				bodySource,
				outputPixels,
				outputSize,
				{ minX = 16, minY = 4, maxX = outputWidth - 17, maxY = outputHeight - 5 }
			)
		elseif stage == "BodySingleCopy" then
			Raster.CopyRegionArea(
				avatarPixels,
				avatarSourceSize,
				bodySource,
				outputPixels,
				outputSize,
				wholeBodyTarget
			)
		elseif stage == "BodySegments" then
			Raster.CopyRegionArea(
				avatarPixels,
				avatarSourceSize,
				bands.legs,
				outputPixels,
				outputSize,
				legsTarget
			)
			Raster.CopyRegionArea(
				avatarPixels,
				avatarSourceSize,
				bands.hips,
				outputPixels,
				outputSize,
				hipsTarget
			)
			Raster.CopyRegionArea(
				avatarPixels,
				avatarSourceSize,
				bands.torso,
				outputPixels,
				outputSize,
				torsoTarget
			)
		else
			local bodyPalette =
				Body.AnalyzePalette(avatarPixels, avatarSourceSize, bands, avatarSignals.skinColor)
			local proceduralBody = Body.Paint(outputSize, bodyPalette)
			Raster.CompositeBufferSourceOver(outputPixels, proceduralBody, outputSize)
		end

		if stage ~= "SourceBody" then
			Raster.CopyRegionArea(
				avatarPixels,
				avatarSourceSize,
				headSource,
				outputPixels,
				outputSize,
				headTarget
			)
		end
		if stage == "SourceBody" or stage == "BodySingleCopy" or stage == "BodySegments" or stage == "BeforeFace" then
			outputImage = allocateImage(outputSize, outputPixels)
			local colors = ImageFinalizer.CountOpaqueColors(outputPixels, outputSize)
			return outputImage, {
				stage = stage,
				requestedColors = requestedColors,
				paletteColors = colors,
				finalColors = colors,
			}
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
			local colors = ImageFinalizer.CountOpaqueColors(outputPixels, outputSize)
			return outputImage, {
				stage = stage,
				requestedColors = requestedColors,
				paletteColors = colors,
				finalColors = colors,
			}
		end

		local bodyPalette =
			Body.AnalyzePalette(avatarPixels, avatarSourceSize, bands, avatarSignals.skinColor)
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
		appendColors(lockedColors, Body.LockedColors(bodyPalette))
		local finalizedPixels, finalizerMetrics = ImageFinalizer.FinalizeWithMetrics(
			outputPixels,
			outputSize,
			{
				PaletteSize = requestedColors,
				LockedColors = lockedColors,
				OutlineColor = options.OutlineColor or Color3.fromRGB(28, 34, 46),
				OutlineEnabled = options.OutlineEnabled,
				AlphaThreshold = options.AlphaThreshold or 48,
			}
		)
		outputImage = allocateImage(outputSize, finalizedPixels)
		return outputImage, {
			stage = stage,
			requestedColors = finalizerMetrics.requestedColors,
			paletteColors = finalizerMetrics.paletteColors,
			finalColors = finalizerMetrics.finalColors,
		}
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
