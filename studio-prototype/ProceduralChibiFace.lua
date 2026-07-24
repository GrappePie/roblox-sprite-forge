--!strict

local Raster = require(script.Parent:WaitForChild("ProceduralRaster"))

type Bounds = Raster.Bounds

export type HairColors = {
	primary: Color3,
	secondary: Color3,
	highlight: Color3,
	shadow: Color3,
	primaryCoverage: number?,
	secondaryCoverage: number?,
	secondaryReliable: boolean?,
	leftTipSecondaryCoverage: number?,
	rightTipSecondaryCoverage: number?,
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
	mouth: Color3,
}

local ProceduralChibiFace = {}

local function offset(width: number, x: number, y: number): number
	return (y * width + x) * 4
end

local function colorBytes(color: Color3): (number, number, number)
	return math.round(color.R * 255), math.round(color.G * 255), math.round(color.B * 255)
end

local function writeColor(pixels: buffer, size: Vector2, x: number, y: number, color: Color3)
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	if x < 0 or y < 0 or x >= width or y >= height then return end
	local red, green, blue = colorBytes(color)
	Raster.SourceOverPixel(pixels, width, height, x, y, { r = red, g = green, b = blue, a = 255 })
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

local function geometry(headBounds: Bounds): {
	centerX: number, width: number, height: number,
	faceTop: number, faceBottom: number, faceLeft: number, faceRight: number,
}
	local width = headBounds.maxX - headBounds.minX + 1
	local height = headBounds.maxY - headBounds.minY + 1
	local centerX = math.floor((headBounds.minX + headBounds.maxX) / 2)
	return {
		centerX = centerX,
		width = width,
		height = height,
		faceTop = headBounds.minY + math.floor(height * 0.38),
		faceBottom = headBounds.minY + math.floor(height * 0.91),
		faceLeft = centerX - math.floor(width * 0.25),
		faceRight = centerX + math.floor(width * 0.25),
	}
end

local function polygon(layer: buffer, size: Vector2, points: { Vector2 }, color: Color3)
	local mask = buffer.create(math.floor(size.X) * math.floor(size.Y) * 4)
	Raster.FillPolygon(mask, size, points)
	local red, green, blue = colorBytes(color)
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local pixelOffset = offset(width, x, y)
			if buffer.readu8(mask, pixelOffset + 3) > 0 then
				Raster.SourceOverPixel(layer, width, height, x, y, { r = red, g = green, b = blue, a = 255 })
			end
		end
	end
end

function ProceduralChibiFace.BackHairLayer(size: Vector2, headBounds: Bounds, hairColors: HairColors): buffer
	local layer = buffer.create(math.floor(size.X) * math.floor(size.Y) * 4)
	local g = geometry(headBounds)
	local top = headBounds.minY + math.floor(g.height * 0.1)
	local bottom = headBounds.minY + math.floor(g.height * 0.98)
	polygon(layer, size, {
		Vector2.new(g.centerX - math.floor(g.width * 0.31), top + math.floor(g.height * 0.18)),
		Vector2.new(g.centerX - math.floor(g.width * 0.25), top + math.floor(g.height * 0.08)),
		Vector2.new(g.centerX - math.floor(g.width * 0.14), top),
		Vector2.new(g.centerX, top - 2),
		Vector2.new(g.centerX + math.floor(g.width * 0.14), top),
		Vector2.new(g.centerX + math.floor(g.width * 0.25), top + math.floor(g.height * 0.08)),
		Vector2.new(g.centerX + math.floor(g.width * 0.31), top + math.floor(g.height * 0.18)),
		Vector2.new(g.centerX + math.floor(g.width * 0.34), bottom - math.floor(g.height * 0.18)),
		Vector2.new(g.centerX + math.floor(g.width * 0.25), bottom),
		Vector2.new(g.centerX, bottom - math.floor(g.height * 0.04)),
		Vector2.new(g.centerX - math.floor(g.width * 0.25), bottom),
		Vector2.new(g.centerX - math.floor(g.width * 0.34), bottom - math.floor(g.height * 0.18)),
	}, hairColors.primary)
	local shadowY = headBounds.minY + math.floor(g.height * 0.73)
	Raster.DrawLine(
		layer,
		size,
		Vector2.new(g.centerX - math.floor(g.width * 0.3), shadowY),
		Vector2.new(g.centerX - math.floor(g.width * 0.23), bottom - 2),
		hairColors.shadow
	)
	Raster.DrawLine(
		layer,
		size,
		Vector2.new(g.centerX + math.floor(g.width * 0.3), shadowY),
		Vector2.new(g.centerX + math.floor(g.width * 0.23), bottom - 2),
		hairColors.shadow
	)
	return layer
end

function ProceduralChibiFace.FaceLayer(size: Vector2, headBounds: Bounds, skinColor: Color3): buffer
	local layer = buffer.create(math.floor(size.X) * math.floor(size.Y) * 4)
	local g = geometry(headBounds)
	-- Flat cheeks and a small chin read more like a drawn chibi face than a
	-- fully visible ellipse; front hair will cover the forehead.
	polygon(layer, size, {
		Vector2.new(g.faceLeft + 4, g.faceTop),
		Vector2.new(g.faceRight - 4, g.faceTop),
		Vector2.new(g.faceRight + 2, g.faceTop + math.floor(g.height * 0.14)),
		Vector2.new(g.faceRight, g.faceBottom - math.floor(g.height * 0.12)),
		Vector2.new(g.centerX + math.floor(g.width * 0.12), g.faceBottom),
		Vector2.new(g.centerX, g.faceBottom + 2),
		Vector2.new(g.centerX - math.floor(g.width * 0.12), g.faceBottom),
		Vector2.new(g.faceLeft, g.faceBottom - math.floor(g.height * 0.12)),
		Vector2.new(g.faceLeft - 2, g.faceTop + math.floor(g.height * 0.14)),
	}, skinColor)
	return layer
end

function ProceduralChibiFace.FacialFeaturesLayer(
	size: Vector2,
	headBounds: Bounds,
	skinColor: Color3,
	eyeColor: Color3
): (buffer, PaintedColors)
	local layer = buffer.create(math.floor(size.X) * math.floor(size.Y) * 4)
	local g = geometry(headBounds)
	local skinShadow = skinColor:Lerp(Color3.fromRGB(125, 74, 86), 0.18)
	local eyeShadow = eyeColor:Lerp(Color3.fromRGB(20, 15, 31), 0.48)
	local eyeOutline = Color3.fromRGB(35, 29, 48)
	local highlight = Color3.fromRGB(255, 250, 255)
	local blush = Color3.fromRGB(238, 142, 157)
	local mouth = Color3.fromRGB(137, 68, 91)
	local eyeOffset = math.max(9, math.floor(g.width * 0.125))
	local eyeRadiusX = math.max(4, math.floor(g.width * 0.058))
	local eyeRadiusY = math.max(5, math.floor(g.height * 0.092))
	local eyeY = g.faceTop + math.floor(g.height * 0.25)
	for _, direction in { -1, 1 } do
		local eyeX = g.centerX + eyeOffset * direction
		fillEllipse(layer, size, eyeX, eyeY, eyeRadiusX + 1, eyeRadiusY, eyeOutline)
		fillEllipse(layer, size, eyeX, eyeY + 1, eyeRadiusX, eyeRadiusY - 1, eyeColor)
		fillEllipse(layer, size, eyeX, eyeY + math.floor(eyeRadiusY * 0.5), eyeRadiusX - 1, 2, eyeShadow)
		fillEllipse(layer, size, eyeX, eyeY + eyeRadiusY - 1, eyeRadiusX - 2, 1, eyeColor:Lerp(highlight, 0.48))
		fillEllipse(layer, size, eyeX, eyeY + 1, math.max(1, eyeRadiusX - 2), math.max(2, eyeRadiusY - 2), eyeShadow)
		writeColor(layer, size, eyeX - 2, eyeY - 2, highlight)
		writeColor(layer, size, eyeX - 1, eyeY - 2, highlight)
		writeColor(layer, size, eyeX + 2, eyeY + 1, highlight)
		-- Thick upper lid, thinner lower lid and outward lashes.
		Raster.DrawLine(layer, size, Vector2.new(eyeX - eyeRadiusX - 1, eyeY - eyeRadiusY), Vector2.new(eyeX + eyeRadiusX, eyeY - eyeRadiusY + 1), eyeOutline)
		Raster.DrawLine(layer, size, Vector2.new(eyeX - eyeRadiusX, eyeY + eyeRadiusY), Vector2.new(eyeX + eyeRadiusX - 1, eyeY + eyeRadiusY), eyeOutline)
		local lashStart = Vector2.new(eyeX + eyeRadiusX * direction, eyeY - eyeRadiusY + 1)
		Raster.DrawLine(layer, size, lashStart, lashStart + Vector2.new(3 * direction, -2), eyeOutline)
	end
	local blushY = eyeY + eyeRadiusY + math.max(3, math.floor(g.height * 0.07))
	for _, blushX in { g.centerX - eyeOffset - eyeRadiusX - 2, g.centerX + eyeOffset + eyeRadiusX + 2 } do
		fillEllipse(layer, size, blushX, blushY, 3, 1, blush)
	end
	local mouthY = g.faceBottom - math.floor(g.height * 0.12)
	Raster.DrawLine(layer, size, Vector2.new(g.centerX - 3, mouthY - 1), Vector2.new(g.centerX, mouthY + 1), mouth)
	Raster.DrawLine(layer, size, Vector2.new(g.centerX, mouthY + 1), Vector2.new(g.centerX + 3, mouthY - 1), mouth)
	writeColor(layer, size, g.centerX, mouthY - 5, skinShadow)
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
		mouth = mouth,
	}
end

function ProceduralChibiFace.FrontHairLayer(size: Vector2, headBounds: Bounds, hairColors: HairColors): buffer
	local layer = buffer.create(math.floor(size.X) * math.floor(size.Y) * 4)
	local g = geometry(headBounds)
	local fringeTop = headBounds.minY + math.floor(g.height * 0.3)
	local fringeBottom = headBounds.minY + math.floor(g.height * 0.67)
	local fringeLeft = g.centerX - math.floor(g.width * 0.25)
	local fringeRight = g.centerX + math.floor(g.width * 0.25)
	local strandWidth = math.max(4, math.floor((fringeRight - fringeLeft) / 6))
	for strand = 0, 5 do
		local left = fringeLeft + strand * strandWidth
		local right = if strand == 5 then fringeRight else left + strandWidth + 1
		local centerDistance = math.abs(strand - 2.5)
		local tip = fringeBottom + math.floor((2.5 - centerDistance) * 3)
		polygon(layer, size, {
			Vector2.new(left, fringeTop + math.abs(strand - 3)),
			Vector2.new(right, fringeTop),
			Vector2.new(math.floor((left + right) / 2), tip),
		}, if strand == 0 or strand == 5 then hairColors.shadow else hairColors.primary)
	end
	local highlightY = headBounds.minY + math.floor(g.height * 0.24)
	Raster.DrawLine(
		layer,
		size,
		Vector2.new(g.centerX - math.floor(g.width * 0.16), highlightY + 3),
		Vector2.new(g.centerX + math.floor(g.width * 0.11), highlightY),
		hairColors.highlight
	)
	return layer
end

function ProceduralChibiFace.AccessoryLayer(size: Vector2, headBounds: Bounds): buffer
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
	local features, colors = ProceduralChibiFace.FacialFeaturesLayer(size, headBounds, skinColor, eyeColor)
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
