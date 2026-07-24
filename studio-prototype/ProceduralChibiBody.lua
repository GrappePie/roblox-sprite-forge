--!strict

local Raster = require(script.Parent:WaitForChild("ProceduralRaster"))

type Bounds = Raster.Bounds

export type BodyPalette = {
	torsoPrimary: Color3,
	torsoSecondary: Color3,
	hipsPrimary: Color3,
	hipsSecondary: Color3,
	legsPrimary: Color3,
	legsSecondary: Color3,
	skin: Color3,
	boot: Color3,
}

local ProceduralChibiBody = {}

local PART_ORDER = {
	"leftArm",
	"rightArm",
	"leftHand",
	"rightHand",
	"leftLeg",
	"rightLeg",
	"leftBoot",
	"rightBoot",
	"torso",
	"abdomen",
	"skirt",
}

local function offset(width: number, x: number, y: number): number
	return (y * width + x) * 4
end

local function setMask(mask: buffer, width: number, height: number, x: number, y: number)
	if x < 0 or y < 0 or x >= width or y >= height then
		return
	end
	buffer.writeu8(mask, offset(width, x, y) + 3, 255)
end

local function fillRect(
	mask: buffer,
	width: number,
	height: number,
	minX: number,
	minY: number,
	maxX: number,
	maxY: number
)
	for y = minY, maxY do
		for x = minX, maxX do
			setMask(mask, width, height, x, y)
		end
	end
end

local function fillEllipse(
	mask: buffer,
	width: number,
	height: number,
	centerX: number,
	centerY: number,
	radiusX: number,
	radiusY: number
)
	for y = centerY - radiusY, centerY + radiusY do
		for x = centerX - radiusX, centerX + radiusX do
			local nx = (x - centerX) / math.max(radiusX, 1)
			local ny = (y - centerY) / math.max(radiusY, 1)
			if nx * nx + ny * ny <= 1 then
				setMask(mask, width, height, x, y)
			end
		end
	end
end

local function fillTrapezoid(
	mask: buffer,
	width: number,
	height: number,
	centerX: number,
	minY: number,
	maxY: number,
	topHalfWidth: number,
	bottomHalfWidth: number
)
	local span = math.max(1, maxY - minY)
	for y = minY, maxY do
		local progress = (y - minY) / span
		local halfWidth = math.floor(topHalfWidth + (bottomHalfWidth - topHalfWidth) * progress)
		for x = centerX - halfWidth, centerX + halfWidth do
			setMask(mask, width, height, x, y)
		end
	end
end

function ProceduralChibiBody.CreateMasks(size: Vector2): { [string]: buffer }
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	local scaleX = width / 128
	local scaleY = height / 256
	local function sx(value: number): number
		return math.floor(value * scaleX + 0.5)
	end
	local function sy(value: number): number
		return math.floor(value * scaleY + 0.5)
	end
	local masks: { [string]: buffer } = {}
	for _, name in PART_ORDER do
		masks[name] = buffer.create(width * height * 4)
	end

	fillTrapezoid(masks.torso, width, height, sx(64), sy(103), sy(143), sx(15), sx(12))
	fillRect(masks.leftArm, width, height, sx(34), sy(110), sx(45), sy(150))
	fillRect(masks.rightArm, width, height, sx(82), sy(110), sx(93), sy(150))
	fillEllipse(masks.leftHand, width, height, sx(39), sy(154), sx(6), sy(7))
	fillEllipse(masks.rightHand, width, height, sx(88), sy(154), sx(6), sy(7))
	fillTrapezoid(masks.abdomen, width, height, sx(64), sy(139), sy(160), sx(11), sx(14))
	fillTrapezoid(masks.skirt, width, height, sx(64), sy(155), sy(181), sx(18), sx(24))
	fillRect(masks.leftLeg, width, height, sx(48), sy(179), sx(59), sy(229))
	fillRect(masks.rightLeg, width, height, sx(68), sy(179), sx(79), sy(229))
	fillRect(masks.leftBoot, width, height, sx(44), sy(220), sx(61), sy(249))
	fillRect(masks.rightBoot, width, height, sx(66), sy(220), sx(83), sy(249))
	fillEllipse(masks.leftBoot, width, height, sx(52), sy(247), sx(10), sy(5))
	fillEllipse(masks.rightBoot, width, height, sx(75), sy(247), sx(10), sy(5))
	return masks
end

local function sampleRegionColors(
	pixels: buffer,
	size: Vector2,
	bounds: Bounds,
	fallback: Color3
): (Color3, Color3)
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	local histogram: { [number]: { r: number, g: number, b: number, count: number } } = {}
	for y = math.max(0, bounds.minY), math.min(height - 1, bounds.maxY), 2 do
		for x = math.max(0, bounds.minX), math.min(width - 1, bounds.maxX), 2 do
			local pixelOffset = offset(width, x, y)
			local alpha = buffer.readu8(pixels, pixelOffset + 3)
			if alpha < 48 then
				continue
			end
			local red = buffer.readu8(pixels, pixelOffset)
			local green = buffer.readu8(pixels, pixelOffset + 1)
			local blue = buffer.readu8(pixels, pixelOffset + 2)
			local key =
				math.floor(red / 16) * 256 + math.floor(green / 16) * 16 + math.floor(blue / 16)
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
	local buckets = {}
	for _, bucket in histogram do
		table.insert(buckets, bucket)
	end
	table.sort(buckets, function(a, b)
		return a.count > b.count
	end)
	if #buckets == 0 then
		return fallback, fallback:Lerp(Color3.fromRGB(30, 30, 42), 0.25)
	end
	local function bucketColor(bucket): Color3
		return Color3.fromRGB(
			math.round(bucket.r / bucket.count),
			math.round(bucket.g / bucket.count),
			math.round(bucket.b / bucket.count)
		)
	end
	local primary = bucketColor(buckets[1])
	local secondary = if #buckets > 1 then bucketColor(buckets[2]) else primary:Lerp(Color3.new(), 0.2)
	return primary, secondary
end

function ProceduralChibiBody.AnalyzePalette(
	sourcePixels: buffer,
	sourceSize: Vector2,
	bands: { torso: Bounds, hips: Bounds, legs: Bounds },
	skinColor: Color3
): BodyPalette
	local torsoPrimary, torsoSecondary =
		sampleRegionColors(sourcePixels, sourceSize, bands.torso, Color3.fromRGB(63, 84, 120))
	local hipsPrimary, hipsSecondary =
		sampleRegionColors(sourcePixels, sourceSize, bands.hips, torsoPrimary)
	local legsPrimary, legsSecondary =
		sampleRegionColors(sourcePixels, sourceSize, bands.legs, skinColor)
	local boot = legsPrimary:Lerp(Color3.fromRGB(18, 20, 30), 0.72)
	return {
		torsoPrimary = torsoPrimary,
		torsoSecondary = torsoSecondary,
		hipsPrimary = hipsPrimary,
		hipsSecondary = hipsSecondary,
		legsPrimary = legsPrimary,
		legsSecondary = legsSecondary,
		skin = skinColor,
		boot = boot,
	}
end

local function colorBytes(color: Color3): (number, number, number)
	return math.round(color.R * 255), math.round(color.G * 255), math.round(color.B * 255)
end

local function paintMask(
	target: buffer,
	size: Vector2,
	mask: buffer,
	primary: Color3,
	secondary: Color3,
	pattern: string
)
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	local primaryRed, primaryGreen, primaryBlue = colorBytes(primary)
	local secondaryRed, secondaryGreen, secondaryBlue = colorBytes(secondary)
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local pixelOffset = offset(width, x, y)
			if buffer.readu8(mask, pixelOffset + 3) == 0 then
				continue
			end
			local useSecondary = if pattern == "vertical"
				then math.floor(x / math.max(2, math.floor(width / 32))) % 2 == 0
				elseif pattern == "horizontal"
				then math.floor(y / math.max(2, math.floor(height / 64))) % 3 == 0
				else false
			Raster.SourceOverPixel(target, width, height, x, y, {
				r = if useSecondary then secondaryRed else primaryRed,
				g = if useSecondary then secondaryGreen else primaryGreen,
				b = if useSecondary then secondaryBlue else primaryBlue,
				a = 255,
			})
		end
	end
end

function ProceduralChibiBody.Paint(
	size: Vector2,
	palette: BodyPalette
): (buffer, { [string]: buffer })
	local masks = ProceduralChibiBody.CreateMasks(size)
	local result = buffer.create(math.floor(size.X) * math.floor(size.Y) * 4)
	paintMask(result, size, masks.leftArm, palette.torsoPrimary, palette.torsoSecondary, "horizontal")
	paintMask(result, size, masks.rightArm, palette.torsoPrimary, palette.torsoSecondary, "horizontal")
	paintMask(result, size, masks.leftHand, palette.skin, palette.skin, "solid")
	paintMask(result, size, masks.rightHand, palette.skin, palette.skin, "solid")
	paintMask(result, size, masks.leftLeg, palette.legsPrimary, palette.legsSecondary, "vertical")
	paintMask(result, size, masks.rightLeg, palette.legsPrimary, palette.legsSecondary, "vertical")
	paintMask(result, size, masks.leftBoot, palette.boot, palette.legsSecondary, "horizontal")
	paintMask(result, size, masks.rightBoot, palette.boot, palette.legsSecondary, "horizontal")
	paintMask(result, size, masks.torso, palette.torsoPrimary, palette.torsoSecondary, "vertical")
	paintMask(result, size, masks.abdomen, palette.skin, palette.torsoSecondary, "solid")
	paintMask(result, size, masks.skirt, palette.hipsPrimary, palette.hipsSecondary, "vertical")
	return result, masks
end

function ProceduralChibiBody.LockedColors(palette: BodyPalette): { Color3 }
	return {
		palette.torsoPrimary,
		palette.torsoSecondary,
		palette.hipsPrimary,
		palette.hipsSecondary,
		palette.legsPrimary,
		palette.legsSecondary,
		palette.skin,
		palette.boot,
	}
end

return table.freeze(ProceduralChibiBody)
