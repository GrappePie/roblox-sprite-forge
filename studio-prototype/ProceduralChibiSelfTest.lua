--!strict

local Body = require(script.Parent:WaitForChild("ProceduralChibiBody"))
local Face = require(script.Parent:WaitForChild("ProceduralChibiFace"))
local Finalizer = require(script.Parent:WaitForChild("ProceduralImageFinalizer"))
local Raster = require(script.Parent:WaitForChild("ProceduralRaster"))

local ProceduralChibiSelfTest = {}

local function offset(width: number, x: number, y: number): number
	return (y * width + x) * 4
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
	assert(
		Finalizer.CountOpaqueColors(paletteOutput, paletteSize) <= 48,
		"Final color count exceeded requested limit"
	)

	local source = { minX = 12, minY = 20, maxX = 91, maxY = 219 }
	local bands = Raster.MakeBodyBands(source)
	assert(bands.torso.maxY + 1 == bands.hips.minY, "Torso and hips overlap")
	assert(bands.hips.maxY + 1 == bands.legs.minY, "Hips and legs overlap")
	for _, band in { bands.torso, bands.hips, bands.legs } do
		assert(band.minX == source.minX and band.maxX == source.maxX, "Band center drifted")
	end

	local bodySize = Vector2.new(128, 256)
	local masks = Body.CreateMasks(bodySize)
	assert(countOpaque(masks.leftArm, bodySize) > 0, "Left arm mask is empty")
	assert(countOpaque(masks.rightArm, bodySize) > 0, "Right arm mask is empty")
	assert(countOpaque(masks.leftLeg, bodySize) > 0, "Left leg mask is empty")
	assert(countOpaque(masks.rightLeg, bodySize) > 0, "Right leg mask is empty")
	assert(buffer.readu8(masks.leftArm, offset(128, 64, 130) + 3) == 0, "Arms touch at center")
	assert(buffer.readu8(masks.rightArm, offset(128, 64, 130) + 3) == 0, "Arms touch at center")
	assert(buffer.readu8(masks.leftLeg, offset(128, 64, 200) + 3) == 0, "Legs touch at center")
	assert(buffer.readu8(masks.rightLeg, offset(128, 64, 200) + 3) == 0, "Legs touch at center")

	local faceLayer = Face.FaceLayer(
		bodySize,
		{ minX = 5, minY = 3, maxX = 122, maxY = 104 },
		Color3.fromRGB(235, 190, 170)
	)
	assert(countOpaque(faceLayer, bodySize) > 0, "FaceLayer did not create alpha")

	local destination = buffer.create(4)
	buffer.writeu8(destination, 0, 0)
	buffer.writeu8(destination, 1, 0)
	buffer.writeu8(destination, 2, 255)
	buffer.writeu8(destination, 3, 255)
	Raster.SourceOverPixel(destination, 1, 1, 0, 0, { r = 255, g = 0, b = 0, a = 128 })
	assert(buffer.readu8(destination, 0) > 120, "Source-over did not blend source")
	assert(buffer.readu8(destination, 2) > 120, "Source-over erased destination")

	return {
		requestedColors = paletteMetrics.requestedColors,
		paletteColors = paletteMetrics.paletteColors,
		finalColors = paletteMetrics.finalColors,
		leftArmPixels = countOpaque(masks.leftArm, bodySize),
		rightArmPixels = countOpaque(masks.rightArm, bodySize),
		leftLegPixels = countOpaque(masks.leftLeg, bodySize),
		rightLegPixels = countOpaque(masks.rightLeg, bodySize),
		facePixels = countOpaque(faceLayer, bodySize),
	}
end

return table.freeze(ProceduralChibiSelfTest)
