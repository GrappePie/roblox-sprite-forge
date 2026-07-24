--!strict

local Raster = require(script.Parent:WaitForChild("ProceduralRaster"))

type Bounds = Raster.Bounds

export type HairColors = {
	primary: Color3,
	secondary: Color3,
	highlight: Color3,
	shadow: Color3,
}

export type PaintedColors = {
	skin: Color3,
	skinShadow: Color3,
	hairPrimary: Color3,
	hairSecondary: Color3,
	hairHighlight: Color3,
	hairShadow: Color3,
	eye: Color3,
	eyeShadow: Color3,
	eyeOutline: Color3,
	highlight: Color3,
	blush: Color3,
}

local ProceduralChibiFace = {}

local function offset(width: number, x: number, y: number): number
	return (y * width + x) * 4
end

local function colorBytes(color: Color3): (number, number, number)
	return math.round(color.R * 255), math.round(color.G * 255), math.round(color.B * 255)
end

local function writeColor(
	pixels: buffer,
	size: Vector2,
	x: number,
	y: number,
	color: Color3
)
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	if x < 0 or y < 0 or x >= width or y >= height then
		return
	end
	local red, green, blue = colorBytes(color)
	local pixelOffset = offset(width, x, y)
	buffer.writeu8(pixels, pixelOffset, red)
	buffer.writeu8(pixels, pixelOffset + 1, green)
	buffer.writeu8(pixels, pixelOffset + 2, blue)
	buffer.writeu8(pixels, pixelOffset + 3, 255)
end

local function fillEllipse(
	pixels: buffer,
	size: Vector2,
	centerX: number,
	centerY: number,
	radiusX: number,
	radiusY: number,
	color: Color3
)
	for y = centerY - radiusY, centerY + radiusY do
		for x = centerX - radiusX, centerX + radiusX do
			local normalizedX = (x - centerX) / math.max(radiusX, 1)
			local normalizedY = (y - centerY) / math.max(radiusY, 1)
			if normalizedX * normalizedX + normalizedY * normalizedY <= 1 then
				writeColor(pixels, size, x, y, color)
			end
		end
	end
end

local function faceGeometry(headBounds: Bounds): {
	centerX: number,
	centerY: number,
	radiusX: number,
	radiusY: number,
	headWidth: number,
	headHeight: number,
}
	local headWidth = headBounds.maxX - headBounds.minX + 1
	local headHeight = headBounds.maxY - headBounds.minY + 1
	return {
		centerX = math.floor((headBounds.minX + headBounds.maxX) / 2),
		centerY = headBounds.minY + math.floor(headHeight * 0.67),
		radiusX = math.max(8, math.floor(headWidth * 0.26)),
		radiusY = math.max(7, math.floor(headHeight * 0.22)),
		headWidth = headWidth,
		headHeight = headHeight,
	}
end

function ProceduralChibiFace.BackHairLayer(
	size: Vector2,
	headBounds: Bounds,
	hairColors: HairColors
): buffer
	-- The copied AvatarThumbnail head remains the authoritative back-hair and
	-- accessory layer during this stage. This transparent layer is intentional.
	local _ = headBounds
	local _hair = hairColors
	return buffer.create(math.floor(size.X) * math.floor(size.Y) * 4)
end

function ProceduralChibiFace.FaceLayer(
	size: Vector2,
	headBounds: Bounds,
	skinColor: Color3
): buffer
	local layer = buffer.create(math.floor(size.X) * math.floor(size.Y) * 4)
	local geometry = faceGeometry(headBounds)
	-- This writes into a transparent buffer and creates its own alpha.
	fillEllipse(
		layer,
		size,
		geometry.centerX,
		geometry.centerY,
		geometry.radiusX,
		geometry.radiusY,
		skinColor
	)
	return layer
end

function ProceduralChibiFace.FacialFeaturesLayer(
	size: Vector2,
	headBounds: Bounds,
	skinColor: Color3,
	eyeColor: Color3
): (buffer, PaintedColors)
	local layer = buffer.create(math.floor(size.X) * math.floor(size.Y) * 4)
	local geometry = faceGeometry(headBounds)
	local skinShadow = skinColor:Lerp(Color3.fromRGB(125, 74, 86), 0.18)
	local eyeShadow = eyeColor:Lerp(Color3.fromRGB(20, 15, 31), 0.48)
	local eyeOutline = Color3.fromRGB(35, 29, 48)
	local highlight = Color3.fromRGB(255, 250, 255)
	local blush = Color3.fromRGB(238, 142, 157)
	local eyeOffset = math.max(6, math.floor(geometry.headWidth * 0.12))
	local eyeRadiusX = math.max(3, math.floor(geometry.headWidth * 0.055))
	local eyeRadiusY = math.max(4, math.floor(geometry.headHeight * 0.095))
	local eyeY = geometry.centerY - math.floor(geometry.radiusY * 0.16)
	for _, eyeX in { geometry.centerX - eyeOffset, geometry.centerX + eyeOffset } do
		fillEllipse(layer, size, eyeX, eyeY, eyeRadiusX + 1, eyeRadiusY + 1, eyeOutline)
		fillEllipse(layer, size, eyeX, eyeY, eyeRadiusX, eyeRadiusY, eyeColor)
		fillEllipse(
			layer,
			size,
			eyeX,
			eyeY + math.floor(eyeRadiusY * 0.45),
			math.max(1, eyeRadiusX - 1),
			math.max(1, math.floor(eyeRadiusY * 0.35)),
			eyeShadow
		)
		writeColor(
			layer,
			size,
			eyeX - math.max(1, math.floor(eyeRadiusX * 0.35)),
			eyeY - math.max(1, math.floor(eyeRadiusY * 0.35)),
			highlight
		)
		for lashX = eyeX - eyeRadiusX - 1, eyeX + eyeRadiusX + 1 do
			writeColor(layer, size, lashX, eyeY - eyeRadiusY, eyeOutline)
		end
	end
	local blushY = geometry.centerY + math.floor(geometry.radiusY * 0.35)
	for _, blushX in {
		geometry.centerX - eyeOffset - eyeRadiusX - 2,
		geometry.centerX + eyeOffset + eyeRadiusX + 2,
	} do
		fillEllipse(layer, size, blushX, blushY, 2, 1, blush)
	end
	local mouthY = geometry.centerY + math.floor(geometry.radiusY * 0.48)
	for x = geometry.centerX - 2, geometry.centerX + 2 do
		writeColor(
			layer,
			size,
			x,
			if x == geometry.centerX - 2 or x == geometry.centerX + 2
				then mouthY - 1
				else mouthY,
			skinShadow
		)
	end
	return layer, {
		skin = skinColor,
		skinShadow = skinShadow,
		hairPrimary = Color3.new(),
		hairSecondary = Color3.new(),
		hairHighlight = Color3.new(),
		hairShadow = Color3.new(),
		eye = eyeColor,
		eyeShadow = eyeShadow,
		eyeOutline = eyeOutline,
		highlight = highlight,
		blush = blush,
	}
end

function ProceduralChibiFace.FrontHairLayer(
	size: Vector2,
	headBounds: Bounds,
	hairColors: HairColors
): buffer
	local layer = buffer.create(math.floor(size.X) * math.floor(size.Y) * 4)
	local geometry = faceGeometry(headBounds)
	local fringeHalfWidth = math.max(10, math.floor(geometry.headWidth * 0.2))
	local fringeStartY = headBounds.minY + math.floor(geometry.headHeight * 0.43)
	for x = geometry.centerX - fringeHalfWidth, geometry.centerX + fringeHalfWidth do
		local normalized = math.abs(x - geometry.centerX) / fringeHalfWidth
		local strand = math.floor((1 - normalized) * geometry.radiusY * 0.72)
		if math.floor((x - geometry.centerX + fringeHalfWidth) / 5) % 2 == 0 then
			strand += 2
		end
		for y = fringeStartY, fringeStartY + strand do
			writeColor(
				layer,
				size,
				x,
				y,
				if y == fringeStartY + strand then hairColors.shadow else hairColors.primary
			)
		end
	end
	return layer
end

function ProceduralChibiFace.AccessoryLayer(
	size: Vector2,
	headBounds: Bounds
): buffer
	-- Accessories stay in the copied head until connected-component extraction
	-- is introduced. No heuristic pixel restoration is performed here.
	local _ = headBounds
	return buffer.create(math.floor(size.X) * math.floor(size.Y) * 4)
end

function ProceduralChibiFace.Paint(
	size: Vector2,
	headBounds: Bounds,
	skinColor: Color3,
	eyeColor: Color3,
	hairColors: HairColors
): (buffer, PaintedColors)
	local result = buffer.create(math.floor(size.X) * math.floor(size.Y) * 4)
	local backHair = ProceduralChibiFace.BackHairLayer(size, headBounds, hairColors)
	local face = ProceduralChibiFace.FaceLayer(size, headBounds, skinColor)
	local features, colors =
		ProceduralChibiFace.FacialFeaturesLayer(size, headBounds, skinColor, eyeColor)
	local frontHair = ProceduralChibiFace.FrontHairLayer(size, headBounds, hairColors)
	local accessory = ProceduralChibiFace.AccessoryLayer(size, headBounds)
	for _, layer in { backHair, face, features, frontHair, accessory } do
		Raster.CompositeBufferSourceOver(result, layer, size)
	end
	colors.hairPrimary = hairColors.primary
	colors.hairSecondary = hairColors.secondary
	colors.hairHighlight = hairColors.highlight
	colors.hairShadow = hairColors.shadow
	return result, colors
end

return table.freeze(ProceduralChibiFace)
