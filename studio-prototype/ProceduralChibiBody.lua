--!strict

local OutfitAnalyzer = require(script.Parent:WaitForChild("ProceduralChibiOutfitAnalyzer"))
local Raster = require(script.Parent:WaitForChild("ProceduralRaster"))

type OutfitAnalysis = OutfitAnalyzer.OutfitAnalysis
type SourceRegion = OutfitAnalyzer.SourceRegion

export type RegionMetrics = {
	projectedPixels: number,
	fallbackPixels: number,
	rejectedSkinPixels: number,
	accentComponents: number,
}

export type BodyMetrics = {
	lowerGarmentSkinRatio: number,
	lowerGarmentCentralCoverage: number,
	shoulderPixelsRepaired: number,
	shoulderPixelsOverwritten: number,
}

local ProceduralChibiBody = {}

local PART_ORDER = {
	"leftArm",
	"rightArm",
	"leftHand",
	"rightHand",
	"torso",
	"abdomen",
	"skirt",
	"leftLeg",
	"rightLeg",
	"leftBoot",
	"rightBoot",
}

local function offset(width: number, x: number, y: number): number
	return (y * width + x) * 4
end

local function scaled(size: Vector2, x: number, y: number): Vector2
	return Vector2.new(
		math.floor(x * size.X / 128 + 0.5),
		math.floor(y * size.Y / 256 + 0.5)
	)
end

local function polygon(mask: buffer, size: Vector2, coordinates: { number })
	local points = {}
	for index = 1, #coordinates, 2 do
		table.insert(points, scaled(size, coordinates[index], coordinates[index + 1]))
	end
	Raster.FillPolygon(mask, size, points)
end

function ProceduralChibiBody.CreateMasks(size: Vector2): { [string]: buffer }
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	local masks: { [string]: buffer } = {}
	for _, name in PART_ORDER do
		masks[name] = buffer.create(width * height * 4)
	end

	-- A compact torso and connected shoulders. The arms angle out instead of
	-- hanging as long rectangles.
	polygon(masks.torso, size, { 46, 104, 82, 104, 78, 145, 50, 145 })
	polygon(masks.leftArm, size, { 43, 107, 51, 113, 42, 173, 28, 169, 33, 125 })
	polygon(masks.rightArm, size, { 77, 113, 85, 107, 95, 125, 100, 169, 86, 173 })
	Raster.FillCapsule(masks.leftArm, size, scaled(size, 39, 124), scaled(size, 34, 158), math.max(3, size.X / 16))
	Raster.FillCapsule(masks.rightArm, size, scaled(size, 89, 124), scaled(size, 94, 158), math.max(3, size.X / 16))
	polygon(masks.leftHand, size, { 29, 169, 42, 171, 43, 181, 37, 185, 30, 180 })
	polygon(masks.rightHand, size, { 86, 171, 99, 169, 98, 180, 91, 185, 85, 181 })

	polygon(masks.abdomen, size, { 51, 143, 77, 143, 80, 164, 48, 164 })
	polygon(masks.skirt, size, {
		47, 160, 81, 160, 87, 174, 92, 188, 71, 191, 64, 187,
		57, 191, 36, 188, 41, 174,
	})
	masks.waistband = buffer.create(width * height * 4)
	masks.upperPanels = buffer.create(width * height * 4)
	masks.lowerRuffle = buffer.create(width * height * 4)
	polygon(masks.waistband, size, { 47, 160, 81, 160, 83, 166, 45, 166 })
	polygon(masks.upperPanels, size, { 45, 166, 83, 166, 87, 179, 41, 179 })
	polygon(masks.lowerRuffle, size, {
		41, 178, 87, 178, 92, 188, 71, 191, 64, 187, 57, 191, 36, 188,
	})

	polygon(masks.leftLeg, size, { 47, 185, 61, 185, 60, 233, 49, 233, 46, 211 })
	polygon(masks.rightLeg, size, { 67, 185, 81, 185, 82, 211, 79, 233, 68, 233 })
	polygon(masks.leftBoot, size, {
		46, 221, 62, 221, 62, 247, 58, 253, 42, 253, 40, 248, 47, 241,
	})
	polygon(masks.rightBoot, size, {
		66, 221, 82, 221, 81, 241, 88, 248, 86, 253, 70, 253, 66, 247,
	})
	return masks
end

local function colorBytes(color: Color3): (number, number, number)
	return math.round(color.R * 255), math.round(color.G * 255), math.round(color.B * 255)
end

local function shoulderColor(region: SourceRegion): Color3
	local _, primarySaturation, primaryValue = region.fallbackPrimary:ToHSV()
	local _, secondarySaturation, secondaryValue = region.fallbackSecondary:ToHSV()
	local primaryScore = primaryValue * 0.62 + primarySaturation * 0.38
	local secondaryScore = secondaryValue * 0.62 + secondarySaturation * 0.38
	return if secondaryScore > primaryScore then region.fallbackSecondary else region.fallbackPrimary
end

local function fillMaskColor(target: buffer, size: Vector2, mask: buffer, color: Color3)
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	local red, green, blue = colorBytes(color)
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local pixelOffset = offset(width, x, y)
			local alpha = buffer.readu8(mask, pixelOffset + 3)
			if alpha > 0 then
				Raster.SourceOverPixel(target, width, height, x, y, {
					r = red,
					g = green,
					b = blue,
					a = alpha,
				})
			end
		end
	end
end

local function fillMaskColorRange(
	target: buffer,
	size: Vector2,
	mask: buffer,
	color: Color3,
	minY: number,
	maxY: number
)
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	local red, green, blue = colorBytes(color)
	local firstY = math.clamp(math.floor(minY * size.Y / 256 + 0.5), 0, height - 1)
	local lastY = math.clamp(math.floor(maxY * size.Y / 256 + 0.5), firstY, height - 1)
	for y = firstY, lastY do
		for x = 0, width - 1 do
			local pixelOffset = offset(width, x, y)
			if buffer.readu8(mask, pixelOffset + 3) > 0 then
				Raster.SourceOverPixel(target, width, height, x, y, {
					r = red, g = green, b = blue, a = 255,
				})
			end
		end
	end
end

local function renderSleeveBands(
	target: buffer,
	size: Vector2,
	mask: buffer,
	bands: { OutfitAnalyzer.SleeveBand }?
)
	if not bands or #bands == 0 then return end
	local bounds = Raster.MaskBounds(mask, size)
	if not bounds then return end
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	local span = math.max(1, bounds.maxY - bounds.minY + 1)
	for _, band in bands do
		local minY = bounds.minY + math.floor(band.startRatio * span)
		local maxY = bounds.minY + math.floor(math.max(band.startRatio, band.endRatio) * span)
		local red, green, blue = colorBytes(band.color)
		for y = math.clamp(minY, 0, height - 1), math.clamp(maxY, 0, height - 1) do
			for x = math.max(0, bounds.minX), math.min(width - 1, bounds.maxX) do
				local pixelOffset = offset(width, x, y)
				if buffer.readu8(mask, pixelOffset + 3) > 0 then
					Raster.SourceOverPixel(target, width, height, x, y, {
						r = red, g = green, b = blue, a = 255,
					})
				end
			end
		end
	end
end

local function maskedSource(sourcePixels: buffer, sourceSize: Vector2, sourceMask: buffer): buffer
	local result = buffer.create(buffer.len(sourcePixels))
	local width = math.floor(sourceSize.X)
	for y = 0, math.floor(sourceSize.Y) - 1 do
		for x = 0, width - 1 do
			local pixelOffset = offset(width, x, y)
			if buffer.readu8(sourceMask, pixelOffset + 3) > 0 then
				buffer.copy(result, pixelOffset, sourcePixels, pixelOffset, 4)
			end
		end
	end
	return result
end

local function repairShoulders(
	target: buffer,
	size: Vector2,
	leftMask: buffer,
	rightMask: buffer
): (buffer, number, number)
	local diagnostic = buffer.create(buffer.len(target))
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	local firstY = math.clamp(math.floor(107 * size.Y / 256 + 0.5), 0, height - 1)
	local lastY = math.clamp(math.floor(132 * size.Y / 256 + 0.5), firstY, height - 1)
	local searchLastY = math.clamp(math.floor(154 * size.Y / 256 + 0.5), lastY, height - 1)
	local repaired = 0
	local overwritten = 0
	for _, mask in { leftMask, rightMask } do
		for y = firstY, lastY do
			for x = 0, width - 1 do
				local pixelOffset = offset(width, x, y)
				if buffer.readu8(mask, pixelOffset + 3) == 0 then continue end
				-- Never replace valid projected texture. Only fill true holes
				-- using the closest textured pixel in the same sleeve column.
				if buffer.readu8(target, pixelOffset + 3) > 0 then continue end
				for sampleY = y + 1, searchLastY do
					local sampleOffset = offset(width, x, sampleY)
					if buffer.readu8(mask, sampleOffset + 3) > 0
						and buffer.readu8(target, sampleOffset + 3) > 0 then
						buffer.copy(target, pixelOffset, target, sampleOffset, 4)
						buffer.copy(diagnostic, pixelOffset, target, pixelOffset, 4)
						repaired += 1
						break
					end
				end
			end
		end
	end
	return diagnostic, repaired, overwritten
end

local function sampleVibrantMaskColor(
	pixels: buffer,
	size: Vector2,
	mask: buffer,
	minY: number,
	maxY: number,
	fallback: Color3
): Color3
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	local firstY = math.clamp(math.floor(minY * size.Y / 256 + 0.5), 0, height - 1)
	local lastY = math.clamp(math.floor(maxY * size.Y / 256 + 0.5), firstY, height - 1)
	local histogram: { [number]: { r: number, g: number, b: number, count: number } } = {}
	for y = firstY, lastY do
		for x = 0, width - 1 do
			local pixelOffset = offset(width, x, y)
			if buffer.readu8(mask, pixelOffset + 3) == 0
				or buffer.readu8(pixels, pixelOffset + 3) == 0 then
				continue
			end
			local red = buffer.readu8(pixels, pixelOffset)
			local green = buffer.readu8(pixels, pixelOffset + 1)
			local blue = buffer.readu8(pixels, pixelOffset + 2)
			local value = math.max(red, green, blue)
			local chroma = value - math.min(red, green, blue)
			if value < 82 and chroma < 42 then continue end
			local key = math.floor(red / 32) * 64 + math.floor(green / 32) * 8 + math.floor(blue / 32)
			local bucket = histogram[key]
			if bucket then
				bucket.r += red
				bucket.g += green
				bucket.b += blue
				bucket.count += 1
			else
				histogram[key] = { r = red, g = green, b = blue, count = 1 }
			end
		end
	end
	local best: { r: number, g: number, b: number, count: number }? = nil
	for _, bucket in histogram do
		if not best or bucket.count > best.count then best = bucket end
	end
	if not best then return fallback end
	return Color3.fromRGB(
		math.round(best.r / best.count),
		math.round(best.g / best.count),
		math.round(best.b / best.count)
	)
end

local function cloneBuffer(source: buffer): buffer
	local clone = buffer.create(buffer.len(source))
	buffer.copy(clone, 0, source, 0, buffer.len(source))
	return clone
end

local function projectRegion(
	sourcePixels: buffer,
	sourceSize: Vector2,
	target: buffer,
	targetSize: Vector2,
	mask: buffer,
	region: SourceRegion,
	rejectSkin: boolean
): RegionMetrics
	local projection = Raster.ProjectRegionToMask(
		sourcePixels,
		sourceSize,
		region.bounds,
		target,
		targetSize,
		mask,
		{
			MinAlpha = region.minAlpha,
			FallbackPrimary = region.fallbackPrimary,
			FallbackSecondary = region.fallbackSecondary,
			RejectColor = if rejectSkin
				then function(red: number, green: number, blue: number): boolean
					return OutfitAnalyzer.IsSkinLike(red, green, blue, region.skinSignals)
				end
				else nil,
		}
	)
	return {
		projectedPixels = projection.projectedPixels,
		fallbackPixels = projection.fallbackPixels,
		rejectedSkinPixels = projection.rejectedColorSamples,
		accentComponents = 0,
	}
end

local function projectAccents(
	sourcePixels: buffer,
	sourceSize: Vector2,
	target: buffer,
	targetSize: Vector2,
	targetMask: buffer,
	region: SourceRegion
): number
	local components = OutfitAnalyzer.FindAccentComponents(sourcePixels, sourceSize, region)
	local width = math.floor(targetSize.X)
	local height = math.floor(targetSize.Y)
	local maskBounds = Raster.MaskBounds(targetMask, targetSize)
	if not maskBounds then
		return 0
	end
	local sourceWidth = math.max(1, region.bounds.maxX - region.bounds.minX)
	local sourceHeight = math.max(1, region.bounds.maxY - region.bounds.minY)
	local targetWidth = math.max(1, maskBounds.maxX - maskBounds.minX)
	local targetHeight = math.max(1, maskBounds.maxY - maskBounds.minY)
	local acceptedComponents = 0
	for _, component in components do
		local sumY = 0
		local sumValue = 0
		local sumChroma = 0
		for _, pixel in component.pixels do
			sumY += pixel.y
			sumValue += math.max(pixel.r, pixel.g, pixel.b)
			sumChroma += math.max(pixel.r, pixel.g, pixel.b) - math.min(pixel.r, pixel.g, pixel.b)
		end
		local sampleCount = math.max(1, #component.pixels)
		local localCenterY = (sumY / sampleCount - region.bounds.minY)
			/ math.max(1, region.bounds.maxY - region.bounds.minY)
		local darkShoulderContamination = (region.name == "leftSleeve" or region.name == "rightSleeve")
			and localCenterY < 0.28
			and sumValue / sampleCount < 76
			and sumChroma / sampleCount < 34
		if darkShoulderContamination then
			continue
		end
		acceptedComponents += 1
		for _, pixel in component.pixels do
			local localX = (pixel.x - region.bounds.minX) / sourceWidth
			local localY = (pixel.y - region.bounds.minY) / sourceHeight
			local targetX = math.round(maskBounds.minX + localX * targetWidth)
			local targetY = math.round(maskBounds.minY + localY * targetHeight)
			if targetX >= 0 and targetY >= 0 and targetX < width and targetY < height then
				local targetOffset = offset(width, targetX, targetY)
				if buffer.readu8(targetMask, targetOffset + 3) > 0 then
					Raster.SourceOverPixel(target, width, height, targetX, targetY, {
						r = pixel.r,
						g = pixel.g,
						b = pixel.b,
						a = 255,
					})
				end
			end
		end
	end
	return acceptedComponents
end

local function unionMasks(masks: { [string]: buffer }, size: Vector2): buffer
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	local union = buffer.create(width * height * 4)
	for _, name in PART_ORDER do
		local mask = masks[name]
		for pixelOffset = 3, width * height * 4 - 1, 4 do
			if buffer.readu8(mask, pixelOffset) > 0 then
				buffer.writeu8(union, pixelOffset, 255)
			end
		end
	end
	return union
end

local function drawLineClipped(
	target: buffer,
	size: Vector2,
	bodyMask: buffer,
	startPoint: Vector2,
	endPoint: Vector2,
	color: Color3
)
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	local lineLayer = buffer.create(width * height * 4)
	Raster.DrawLine(lineLayer, size, scaled(size, startPoint.X, startPoint.Y), scaled(size, endPoint.X, endPoint.Y), color)
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local pixelOffset = offset(width, x, y)
			if buffer.readu8(bodyMask, pixelOffset + 3) > 0
				and buffer.readu8(lineLayer, pixelOffset + 3) > 0 then
				Raster.SourceOverPixel(target, width, height, x, y, {
					r = buffer.readu8(lineLayer, pixelOffset),
					g = buffer.readu8(lineLayer, pixelOffset + 1),
					b = buffer.readu8(lineLayer, pixelOffset + 2),
					a = 255,
				})
			end
		end
	end
end

function ProceduralChibiBody.Paint(
	size: Vector2,
	sourcePixels: buffer,
	sourceSize: Vector2,
	analysis: OutfitAnalysis,
	bodyColors: OutfitAnalyzer.BodyColors,
	inkColor: Color3
): (
	buffer,
	buffer,
	buffer,
	{ [string]: buffer },
	{ Color3 },
	{ [string]: RegionMetrics },
	BodyMetrics,
	{ [string]: buffer }
)
	local masks = ProceduralChibiBody.CreateMasks(size)
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	local projected = buffer.create(width * height * 4)
	local metrics: { [string]: RegionMetrics } = {}

	metrics.torso = projectRegion(
		sourcePixels,
		sourceSize,
		projected,
		size,
		masks.torso,
		analysis.torso,
		analysis.torso.excludeSkin
	)
	metrics.leftSleeve = projectRegion(
		sourcePixels,
		sourceSize,
		projected,
		size,
		masks.leftArm,
		analysis.leftSleeve,
		analysis.leftSleeve.excludeSkin
	)
	metrics.rightSleeve = projectRegion(
		sourcePixels,
		sourceSize,
		projected,
		size,
		masks.rightArm,
		analysis.rightSleeve,
		analysis.rightSleeve.excludeSkin
	)
	renderSleeveBands(projected, size, masks.leftArm, analysis.leftSleeve.bands)
	renderSleeveBands(projected, size, masks.rightArm, analysis.rightSleeve.bands)
	local shoulderRepair, shoulderPixelsRepaired, shoulderPixelsOverwritten =
		repairShoulders(projected, size, masks.leftArm, masks.rightArm)
	if analysis.midriffUsesSkin then
		fillMaskColor(projected, size, masks.abdomen, bodyColors.torso)
		metrics.midriff = {
			projectedPixels = Raster.CountMaskPixels(masks.abdomen, size),
			fallbackPixels = 0,
			rejectedSkinPixels = 0,
			accentComponents = 0,
		}
	else
		metrics.midriff = projectRegion(sourcePixels, sourceSize, projected, size, masks.abdomen, analysis.torso, true)
	end
	local garmentPixels = maskedSource(sourcePixels, sourceSize, analysis.lowerGarmentMask)
	metrics.lowerGarment = projectRegion(
		garmentPixels,
		sourceSize,
		projected,
		size,
		masks.waistband,
		analysis.lowerGarment,
		analysis.lowerGarment.excludeSkin
	)
	projectRegion(garmentPixels, sourceSize, projected, size, masks.upperPanels, analysis.lowerGarment, true)
	projectRegion(garmentPixels, sourceSize, projected, size, masks.lowerRuffle, analysis.lowerGarment, true)
	if analysis.leftLegUsesSkin then
		fillMaskColor(projected, size, masks.leftLeg, bodyColors.leftLeg)
		metrics.leftLeg = {
			projectedPixels = Raster.CountMaskPixels(masks.leftLeg, size),
			fallbackPixels = 0,
			rejectedSkinPixels = 0,
			accentComponents = 0,
		}
	else
		metrics.leftLeg = projectRegion(sourcePixels, sourceSize, projected, size, masks.leftLeg, analysis.leftLeg, false)
	end
	if analysis.rightLegUsesSkin then
		fillMaskColor(projected, size, masks.rightLeg, bodyColors.rightLeg)
		metrics.rightLeg = {
			projectedPixels = Raster.CountMaskPixels(masks.rightLeg, size),
			fallbackPixels = 0,
			rejectedSkinPixels = 0,
			accentComponents = 0,
		}
	else
		metrics.rightLeg = projectRegion(sourcePixels, sourceSize, projected, size, masks.rightLeg, analysis.rightLeg, false)
	end
	metrics.leftBoot = projectRegion(
		sourcePixels,
		sourceSize,
		projected,
		size,
		masks.leftBoot,
		analysis.leftBoot,
		analysis.leftBoot.excludeSkin
	)
	metrics.rightBoot = projectRegion(
		sourcePixels,
		sourceSize,
		projected,
		size,
		masks.rightBoot,
		analysis.rightBoot,
		analysis.rightBoot.excludeSkin
	)
	fillMaskColor(projected, size, masks.leftHand, bodyColors.leftArm)
	fillMaskColor(projected, size, masks.rightHand, bodyColors.rightArm)

	local accented = cloneBuffer(projected)
	metrics.torso.accentComponents =
		projectAccents(sourcePixels, sourceSize, accented, size, masks.torso, analysis.torso)
	metrics.leftSleeve.accentComponents =
		projectAccents(sourcePixels, sourceSize, accented, size, masks.leftArm, analysis.leftSleeve)
	metrics.rightSleeve.accentComponents =
		projectAccents(sourcePixels, sourceSize, accented, size, masks.rightArm, analysis.rightSleeve)
	metrics.lowerGarment.accentComponents =
		projectAccents(sourcePixels, sourceSize, accented, size, masks.skirt, analysis.lowerGarment)

	local finished = cloneBuffer(accented)
	local bodyMask = unionMasks(masks, size)
	local shadowColor = inkColor:Lerp(Color3.new(), 0.25)
	for _, line in {
		{ Vector2.new(49, 145), Vector2.new(79, 145), inkColor },
		{ Vector2.new(47, 162), Vector2.new(81, 162), inkColor },
		{ Vector2.new(39, 174), Vector2.new(43, 174), inkColor },
		{ Vector2.new(85, 174), Vector2.new(89, 174), inkColor },
		{ Vector2.new(64, 184), Vector2.new(64, 253), inkColor },
		{ Vector2.new(46, 222), Vector2.new(62, 222), inkColor },
		{ Vector2.new(66, 222), Vector2.new(82, 222), inkColor },
		{ Vector2.new(49, 253), Vector2.new(61, 253), shadowColor },
		{ Vector2.new(69, 253), Vector2.new(83, 253), shadowColor },
		{ Vector2.new(42, 188), Vector2.new(86, 188), shadowColor },
	} do
		drawLineClipped(finished, size, bodyMask, line[1] :: Vector2, line[2] :: Vector2, line[3] :: Color3)
	end
	for _, maskName in { "leftArm", "rightArm", "skirt", "leftBoot", "rightBoot" } do
		Raster.StrokeMaskInside(finished, size, masks[maskName], inkColor)
	end

	local lockedColors = {
		analysis.torso.fallbackPrimary,
		analysis.torso.fallbackSecondary,
		analysis.leftSleeve.fallbackPrimary,
		analysis.rightSleeve.fallbackPrimary,
		analysis.lowerGarment.fallbackPrimary,
		analysis.lowerGarment.fallbackSecondary,
		analysis.leftBoot.fallbackPrimary,
		analysis.rightBoot.fallbackPrimary,
		bodyColors.torso,
		bodyColors.leftLeg,
		bodyColors.rightLeg,
		inkColor,
		shadowColor,
	}
	local skirtSourceDiagnostic = buffer.create(buffer.len(projected))
	projectRegion(
		garmentPixels,
		sourceSize,
		skirtSourceDiagnostic,
		size,
		masks.skirt,
		analysis.lowerGarment,
		false
	)
	return projected, accented, finished, masks, lockedColors, metrics, {
		lowerGarmentSkinRatio = analysis.lowerGarmentSkinRatio,
		lowerGarmentCentralCoverage = analysis.lowerGarmentCentralCoverage,
		shoulderPixelsRepaired = shoulderPixelsRepaired,
		shoulderPixelsOverwritten = shoulderPixelsOverwritten,
	}, {
		SkirtSourceMask = skirtSourceDiagnostic,
		ShoulderRepair = shoulderRepair,
		SleeveBandDescriptors = projected,
		SleevesStructured = projected,
		LowerGarmentPalette = skirtSourceDiagnostic,
		LowerGarmentSubregions = projected,
		BodyStructured = finished,
	}
end

return table.freeze(ProceduralChibiBody)
