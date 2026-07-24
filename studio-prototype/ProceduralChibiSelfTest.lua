--!strict

local Body = require(script.Parent:WaitForChild("ProceduralChibiBody"))
local Face = require(script.Parent:WaitForChild("ProceduralChibiFace"))
local Finalizer = require(script.Parent:WaitForChild("ProceduralImageFinalizer"))
local Head = require(script.Parent:WaitForChild("ProceduralChibiHead"))
local HeadAnalyzer = require(script.Parent:WaitForChild("ProceduralChibiHeadAnalyzer"))
local OutfitAnalyzer = require(script.Parent:WaitForChild("ProceduralChibiOutfitAnalyzer"))
local Raster = require(script.Parent:WaitForChild("ProceduralRaster"))

local ProceduralChibiSelfTest = {}

local function offset(width: number, x: number, y: number): number
	return (y * width + x) * 4
end

local function writePixel(pixels: buffer, width: number, x: number, y: number, color: Color3)
	local pixelOffset = offset(width, x, y)
	buffer.writeu8(pixels, pixelOffset, math.round(color.R * 255))
	buffer.writeu8(pixels, pixelOffset + 1, math.round(color.G * 255))
	buffer.writeu8(pixels, pixelOffset + 2, math.round(color.B * 255))
	buffer.writeu8(pixels, pixelOffset + 3, 255)
end

local function fillRect(
	pixels: buffer,
	width: number,
	minX: number,
	minY: number,
	maxX: number,
	maxY: number,
	color: Color3
)
	for y = minY, maxY do
		for x = minX, maxX do
			writePixel(pixels, width, x, y, color)
		end
	end
end

local function countOpaque(pixels: buffer, size: Vector2): number
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	local count = 0
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			if buffer.readu8(pixels, offset(width, x, y) + 3) > 0 then
				count += 1
			end
		end
	end
	return count
end

local function countNearColor(
	pixels: buffer,
	size: Vector2,
	mask: buffer,
	color: Color3,
	tolerance: number
): number
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	local targetRed = color.R * 255
	local targetGreen = color.G * 255
	local targetBlue = color.B * 255
	local count = 0
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local pixelOffset = offset(width, x, y)
			if buffer.readu8(mask, pixelOffset + 3) == 0
				or buffer.readu8(pixels, pixelOffset + 3) == 0 then
				continue
			end
			local delta = math.abs(buffer.readu8(pixels, pixelOffset) - targetRed)
				+ math.abs(buffer.readu8(pixels, pixelOffset + 1) - targetGreen)
				+ math.abs(buffer.readu8(pixels, pixelOffset + 2) - targetBlue)
			if delta <= tolerance then
				count += 1
			end
		end
	end
	return count
end

local function rowCenter(mask: buffer, width: number, y: number): number
	local sum = 0
	local count = 0
	for x = 0, width - 1 do
		if buffer.readu8(mask, offset(width, x, y) + 3) > 0 then
			sum += x
			count += 1
		end
	end
	assert(count > 0, "Expected occupied mask row")
	return sum / count
end

local function unionContains(masks: { [string]: buffer }, pixelOffset: number): boolean
	for _, mask in masks do
		if buffer.readu8(mask, pixelOffset + 3) > 0 then
			return true
		end
	end
	return false
end

local function syntheticOutfit(): (buffer, Vector2, Raster.Bounds, OutfitAnalyzer.BodyColors)
	local size = Vector2.new(96, 192)
	local width = 96
	local pixels = buffer.create(width * 192 * 4)
	local skin = Color3.fromRGB(236, 184, 158)
	local black = Color3.fromRGB(18, 19, 27)
	local yellow = Color3.fromRGB(255, 218, 48)
	local sleeveColors = {
		Color3.fromRGB(44, 182, 255),
		Color3.fromRGB(86, 226, 93),
		Color3.fromRGB(255, 216, 52),
		Color3.fromRGB(255, 91, 161),
		Color3.fromRGB(139, 72, 241),
	}

	fillRect(pixels, width, 35, 8, 60, 68, black)
	for index, color in sleeveColors do
		local minY = 8 + (index - 1) * 15
		fillRect(pixels, width, 8, minY, 31, math.min(81, minY + 14), color)
		fillRect(pixels, width, 64, minY, 87, math.min(81, minY + 14), color)
	end
	fillRect(pixels, width, 44, 27, 51, 43, yellow)
	fillRect(pixels, width, 40, 33, 55, 37, yellow)
	fillRect(pixels, width, 38, 69, 57, 82, skin)
	fillRect(pixels, width, 25, 83, 39, 116, Color3.fromRGB(90, 226, 67))
	fillRect(pixels, width, 40, 83, 55, 116, Color3.fromRGB(121, 56, 224))
	fillRect(pixels, width, 56, 83, 70, 116, black)
	fillRect(pixels, width, 34, 117, 45, 154, skin)
	fillRect(pixels, width, 50, 117, 61, 154, skin)
	fillRect(pixels, width, 32, 155, 46, 183, black)
	fillRect(pixels, width, 49, 155, 63, 183, black)

	return pixels, size, { minX = 8, minY = 8, maxX = 87, maxY = 183 }, {
		head = skin,
		torso = skin,
		leftArm = skin,
		rightArm = skin,
		leftLeg = skin,
		rightLeg = skin,
	}
end

local function syntheticHead(
	primary: Color3,
	secondary: Color3
): (buffer, Vector2, Raster.Bounds, Color3)
	local size = Vector2.new(96, 96)
	local width = 96
	local pixels = buffer.create(width * 96 * 4)
	local skin = Color3.fromRGB(236, 184, 158)
	local shadow = primary:Lerp(Color3.fromRGB(20, 18, 30), 0.38)
	local bounds: Raster.Bounds = { minX = 8, minY = 4, maxX = 87, maxY = 91 }
	-- Hair surrounds a protected central face. The secondary is deliberately
	-- concentrated in the lower sides/tips.
	fillRect(pixels, width, 18, 12, 77, 38, primary)
	fillRect(pixels, width, 12, 25, 29, 82, primary)
	fillRect(pixels, width, 66, 25, 83, 82, primary)
	fillRect(pixels, width, 20, 14, 75, 19, shadow)
	fillRect(pixels, width, 13, 68, 31, 87, secondary)
	fillRect(pixels, width, 64, 68, 82, 87, secondary)
	fillRect(pixels, width, 30, 34, 65, 79, skin)
	-- Original thumbnail eyes are residual dark components and must never be
	-- restored as accessories over the procedural face.
	fillRect(pixels, width, 37, 51, 43, 60, Color3.fromRGB(18, 18, 26))
	fillRect(pixels, width, 52, 51, 58, 60, Color3.fromRGB(18, 18, 26))
	-- Two ears, two side headphones and two compact hair ornaments.
	fillRect(pixels, width, 13, 4, 26, 17, Color3.fromRGB(245, 126, 42))
	fillRect(pixels, width, 69, 4, 82, 17, Color3.fromRGB(245, 126, 42))
	fillRect(pixels, width, 7, 38, 15, 61, Color3.fromRGB(42, 221, 230))
	fillRect(pixels, width, 80, 38, 88, 61, Color3.fromRGB(42, 221, 230))
	fillRect(pixels, width, 24, 28, 29, 34, Color3.fromRGB(255, 197, 55))
	fillRect(pixels, width, 67, 30, 75, 38, Color3.fromRGB(237, 82, 177))
	return pixels, size, bounds, skin
end

function ProceduralChibiSelfTest.Run(): { [string]: any }
	local paletteSize = Vector2.new(16, 4)
	local paletteInput = buffer.create(16 * 4 * 4)
	for index = 0, 63 do
		local pixelOffset = index * 4
		buffer.writeu8(paletteInput, pixelOffset, (index % 8) * 32 + 8)
		buffer.writeu8(paletteInput, pixelOffset + 1, math.floor(index / 8) * 32 + 8)
		buffer.writeu8(paletteInput, pixelOffset + 2, (index * 53) % 256)
		buffer.writeu8(paletteInput, pixelOffset + 3, 255)
	end
	local paletteOutput, paletteMetrics = Finalizer.FinalizeWithMetrics(
		paletteInput,
		paletteSize,
		{
			PaletteSize = 48,
			LockedColors = {},
			OutlineColor = Color3.fromRGB(1, 2, 3),
			OutlineEnabled = false,
			AlphaThreshold = 48,
		}
	)
	assert(paletteMetrics.requestedColors == 48, "48 requested colors were not preserved")
	assert(paletteMetrics.paletteColors > 32, "48-color request was internally capped at 32")
	assert(Finalizer.CountOpaqueColors(paletteOutput, paletteSize) <= 48, "Final color count exceeded requested limit")

	local source = { minX = 12, minY = 20, maxX = 91, maxY = 219 }
	local bands = Raster.MakeBodyBands(source)
	assert(bands.torso.maxY + 1 == bands.hips.minY, "Torso and hips overlap")
	assert(bands.hips.maxY + 1 == bands.legs.minY, "Hips and legs overlap")
	for _, band in { bands.torso, bands.hips, bands.legs } do
		assert(band.minX == source.minX and band.maxX == source.maxX, "Band center drifted")
	end

	local sourcePixels, sourceSize, bodySource, bodyColors = syntheticOutfit()
	local analysis = OutfitAnalyzer.Analyze(sourcePixels, sourceSize, bodySource, bodyColors)
	assert(analysis.midriffUsesSkin, "Synthetic exposed midriff was not classified as skin")
	assert(analysis.leftLegUsesSkin and analysis.rightLegUsesSkin, "Synthetic skin legs were not classified as skin")
	local bodySize = Vector2.new(128, 256)
	local projected, accented, painted, masks, lockedColors, regionMetrics = Body.Paint(
		bodySize,
		sourcePixels,
		sourceSize,
		analysis,
		bodyColors,
		Color3.fromRGB(24, 28, 40)
	)
	assert(countOpaque(masks.leftArm, bodySize) > 0, "Left arm mask is empty")
	assert(countOpaque(masks.rightArm, bodySize) > 0, "Right arm mask is empty")
	assert(countOpaque(masks.leftLeg, bodySize) > 0, "Left leg mask is empty")
	assert(countOpaque(masks.rightLeg, bodySize) > 0, "Right leg mask is empty")
	assert(buffer.readu8(masks.leftLeg, offset(128, 64, 205) + 3) == 0, "Legs touch at center")
	assert(rowCenter(masks.leftArm, 128, 112) > rowCenter(masks.leftArm, 128, 168), "Left arm is not angled outward")
	assert(rowCenter(masks.rightArm, 128, 112) < rowCenter(masks.rightArm, 128, 168), "Right arm is not angled outward")

	assert(countNearColor(accented, bodySize, masks.torso, Color3.fromRGB(255, 218, 48), 90) > 2, "Yellow torso symbol was lost")
	assert(countNearColor(projected, bodySize, masks.abdomen, bodyColors.torso, 45) > 40, "Skin midriff was lost")
	assert(countNearColor(projected, bodySize, masks.leftLeg, bodyColors.leftLeg, 45) > 60, "Left skin leg was lost")
	assert(countNearColor(projected, bodySize, masks.rightLeg, bodyColors.rightLeg, 45) > 60, "Right skin leg was lost")
	assert(countNearColor(accented, bodySize, masks.skirt, Color3.fromRGB(90, 226, 67), 120) > 2, "Green skirt panel was lost")
	assert(countNearColor(accented, bodySize, masks.skirt, Color3.fromRGB(121, 56, 224), 120) > 2, "Purple skirt panel was lost")
	assert(countNearColor(projected, bodySize, masks.leftBoot, Color3.fromRGB(18, 19, 27), 55) > 40, "Dark left boot was lost")
	assert(regionMetrics.torso.accentComponents > 0, "Torso accent component was not recovered")

	for y = 0, 255 do
		for x = 0, 127 do
			local pixelOffset = offset(128, x, y)
			if buffer.readu8(painted, pixelOffset + 3) > 0 then
				assert(unionContains(masks, pixelOffset), "Body emitted opaque pixels outside canonical masks")
			end
		end
	end
	local totalProjected = 0
	local totalFallback = 0
	for _, metric in regionMetrics do
		totalProjected += metric.projectedPixels
		totalFallback += metric.fallbackPixels
	end
	assert(totalFallback / math.max(1, totalProjected) < 0.45, "Synthetic regional fallback ratio is unreasonable")

	local finalized, finalMetrics = Finalizer.FinalizeWithMetrics(
		painted,
		bodySize,
		{
			PaletteSize = 48,
			LockedColors = lockedColors,
			OutlineColor = Color3.fromRGB(24, 28, 40),
			OutlineEnabled = true,
			AlphaThreshold = 48,
		}
	)
	assert(Finalizer.CountOpaqueColors(finalized, bodySize) <= 48, "Synthetic final body exceeded palette limit")

	local faceLayer = Face.FaceLayer(
		bodySize,
		{ minX = 5, minY = 3, maxX = 122, maxY = 104 },
		Color3.fromRGB(235, 190, 170)
	)
	assert(countOpaque(faceLayer, bodySize) > 0, "FaceLayer did not create alpha")

	for _, palette in {
		{ Color3.fromRGB(104, 202, 76), Color3.fromRGB(139, 70, 219) },
		{ Color3.fromRGB(72, 168, 219), Color3.fromRGB(238, 105, 151) },
	} do
		local headPixels, headSize, headBounds, headSkin =
			syntheticHead(palette[1] :: Color3, palette[2] :: Color3)
		local headAnalysis = HeadAnalyzer.Analyze(headPixels, headSize, headBounds, headSkin, {
			AlphaThreshold = 48,
			SecondaryMinimumCoverage = 0.04,
			AccessoryMinimumConfidence = 0.35,
			MaxAccessoryComponents = 10,
		})
		assert(headAnalysis.hair.primaryCoverage > 0.12, "Spatial primary hair coverage is too low")
		assert(headAnalysis.hair.secondaryReliable, "Secondary tip color was not detected")
		assert(headAnalysis.hair.secondaryCoverage >= 0.04, "Secondary coverage did not reach its limit")
		assert(
			headAnalysis.metrics.accepted >= 2,
			string.format(
				"Synthetic head accessories were not retained accepted=%d candidates=%d rejectedFace=%d",
				headAnalysis.metrics.accepted,
				headAnalysis.metrics.candidates,
				headAnalysis.metrics.rejectedFace
			)
		)
		assert(
			buffer.readu8(headAnalysis.candidateMask, offset(96, 40, 55) + 3) == 0,
			"Original dark eyes survived as accessory candidates"
		)
		local paintedHead = Head.Paint(
			bodySize,
			{ minX = 12, minY = 3, maxX = 116, maxY = 108 },
			headPixels,
			headSize,
			headBounds,
			headAnalysis,
			headSkin,
			Color3.fromRGB(116, 88, 168),
			Color3.fromRGB(24, 28, 40)
		)
		assert(countOpaque(paintedHead.backHair, bodySize) > 500, "BackHairLayer is empty")
		assert(countOpaque(paintedHead.face, bodySize) > 500, "Procedural face mask is empty")
		assert(countOpaque(paintedHead.frontHair, bodySize) > 100, "Procedural fringe is empty")
		assert(countOpaque(paintedHead.accessories, bodySize) > 0, "Accessory projection is empty")
		assert(countOpaque(paintedHead.composite, bodySize) > countOpaque(paintedHead.face, bodySize), "Head layers did not compose")
		assert(not paintedHead.metrics.fallbackUsed, "Synthetic head unexpectedly used legacy fallback")
	end

	local destination = buffer.create(4)
	buffer.writeu8(destination, 2, 255)
	buffer.writeu8(destination, 3, 255)
	Raster.SourceOverPixel(destination, 1, 1, 0, 0, { r = 255, g = 0, b = 0, a = 128 })
	assert(buffer.readu8(destination, 0) > 120, "Source-over did not blend source")
	assert(buffer.readu8(destination, 2) > 120, "Source-over erased destination")

	return {
		requestedColors = paletteMetrics.requestedColors,
		paletteColors = paletteMetrics.paletteColors,
		finalColors = finalMetrics.finalColors,
		leftArmPixels = countOpaque(masks.leftArm, bodySize),
		rightArmPixels = countOpaque(masks.rightArm, bodySize),
		leftLegPixels = countOpaque(masks.leftLeg, bodySize),
		rightLegPixels = countOpaque(masks.rightLeg, bodySize),
		facePixels = countOpaque(faceLayer, bodySize),
		fallbackPixels = totalFallback,
		accentComponents = regionMetrics.torso.accentComponents,
	}
end

return table.freeze(ProceduralChibiSelfTest)
