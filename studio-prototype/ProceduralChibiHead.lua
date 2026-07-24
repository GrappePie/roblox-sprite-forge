--!strict

local Face = require(script.Parent:WaitForChild("ProceduralChibiFace"))
local HeadAnalyzer = require(script.Parent:WaitForChild("ProceduralChibiHeadAnalyzer"))
local Raster = require(script.Parent:WaitForChild("ProceduralRaster"))

type Bounds = Raster.Bounds
type Analysis = HeadAnalyzer.Analysis

export type HeadMetrics = {
	proceduralUsed: boolean,
	fallbackUsed: boolean,
	primaryCoverage: number,
	secondaryCoverage: number,
	accessoryCandidates: number,
	accessoriesAccepted: number,
	accessoriesRejectedFace: number,
	fallbackPixels: number,
}

export type PaintResult = {
	backHair: buffer,
	face: buffer,
	features: buffer,
	frontHair: buffer,
	accessories: buffer,
	hairMasks: buffer,
	hairClusters: buffer,
	accessoryCandidates: buffer,
	withoutAccessories: buffer,
	composite: buffer,
	masks: { [string]: buffer },
	colors: Face.PaintedColors,
	lockedColors: { Color3 },
	metrics: HeadMetrics,
}

local ProceduralChibiHead = {}

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

local function alphaMask(layer: buffer, size: Vector2): buffer
	local mask = buffer.create(buffer.len(layer))
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local pixelOffset = offset(width, x, y)
			if buffer.readu8(layer, pixelOffset + 3) > 0 then
				buffer.writeu8(mask, pixelOffset + 3, 255)
			end
		end
	end
	return mask
end

local function intersectMasks(left: buffer, right: buffer, size: Vector2): buffer
	local result = buffer.create(buffer.len(left))
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local pixelOffset = offset(width, x, y)
			if buffer.readu8(left, pixelOffset + 3) > 0
				and buffer.readu8(right, pixelOffset + 3) > 0 then
				buffer.writeu8(result, pixelOffset + 3, 255)
			end
		end
	end
	return result
end

local function fillMask(target: buffer, size: Vector2, mask: buffer, color: Color3)
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	local red = math.round(color.R * 255)
	local green = math.round(color.G * 255)
	local blue = math.round(color.B * 255)
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local pixelOffset = offset(width, x, y)
			if buffer.readu8(mask, pixelOffset + 3) > 0 then
				Raster.SourceOverPixel(target, width, height, x, y, { r = red, g = green, b = blue, a = 255 })
			end
		end
	end
end

function ProceduralChibiHead.CreateMasks(
	size: Vector2,
	headBounds: Bounds,
	hair: Face.HairColors
): { [string]: buffer }
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	local backLayer = Face.BackHairLayer(size, headBounds, hair)
	local faceLayer = Face.FaceLayer(size, headBounds, Color3.new(1, 1, 1))
	local frontLayer = Face.FrontHairLayer(size, headBounds, hair)
	local masks: { [string]: buffer } = {
		backHair = alphaMask(backLayer, size),
		face = alphaMask(faceLayer, size),
		frontHair = alphaMask(frontLayer, size),
		sides = buffer.create(width * height * 4),
		bangs = alphaMask(frontLayer, size),
		tips = buffer.create(width * height * 4),
		accessoryAnchors = buffer.create(width * height * 4),
	}
	polygon(masks.sides, size, {
		18, 42, 35, 34, 38, 94, 31, 108, 18, 99,
	})
	polygon(masks.sides, size, {
		110, 42, 93, 34, 90, 94, 97, 108, 110, 99,
	})
	polygon(masks.tips, size, {
		18, 84, 40, 82, 37, 108, 29, 101, 23, 110, 17, 99,
	})
	polygon(masks.tips, size, {
		110, 84, 88, 82, 91, 108, 99, 101, 105, 110, 111, 99,
	})
	masks.tips = intersectMasks(masks.tips, masks.backHair, size)
	for _, point in {
		scaled(size, 22, 18), scaled(size, 106, 18),
		scaled(size, 17, 58), scaled(size, 111, 58),
		scaled(size, 43, 37), scaled(size, 85, 37),
	} do
		local x = math.floor(point.X)
		local y = math.floor(point.Y)
		if x >= 0 and y >= 0 and x < width and y < height then
			buffer.writeu8(masks.accessoryAnchors, offset(width, x, y) + 3, 255)
		end
	end
	return masks
end

local function projectAccessories(
	analysis: Analysis,
	sourceBounds: Bounds,
	target: buffer,
	targetSize: Vector2,
	headBounds: Bounds
): number
	local sourceWidth = math.max(1, sourceBounds.maxX - sourceBounds.minX + 1)
	local sourceHeight = math.max(1, sourceBounds.maxY - sourceBounds.minY + 1)
	local targetWidth = headBounds.maxX - headBounds.minX + 1
	local targetHeight = headBounds.maxY - headBounds.minY + 1
	local drawn = 0
	for _, accessory in analysis.accessories do
		local normalizedMinX = (accessory.bounds.minX - sourceBounds.minX) / sourceWidth
		local normalizedMaxX = (accessory.bounds.maxX - sourceBounds.minX + 1) / sourceWidth
		local normalizedMinY = (accessory.bounds.minY - sourceBounds.minY) / sourceHeight
		local normalizedMaxY = (accessory.bounds.maxY - sourceBounds.minY + 1) / sourceHeight
		local projectedBounds: Bounds = {
			minX = math.floor(headBounds.minX + normalizedMinX * targetWidth),
			maxX = math.ceil(headBounds.minX + normalizedMaxX * targetWidth),
			minY = math.floor(headBounds.minY + normalizedMinY * targetHeight),
			maxY = math.ceil(headBounds.minY + normalizedMaxY * targetHeight),
		}
		local projectedWidth = projectedBounds.maxX - projectedBounds.minX + 1
		local projectedHeight = projectedBounds.maxY - projectedBounds.minY + 1
		local maximumWidth = math.max(5, math.floor(targetWidth * 0.24))
		local maximumHeight = math.max(6, math.floor(targetHeight * 0.3))
		if projectedWidth > maximumWidth or projectedHeight > maximumHeight then
			local centerX = math.floor((projectedBounds.minX + projectedBounds.maxX) / 2)
			local centerY = math.floor((projectedBounds.minY + projectedBounds.maxY) / 2)
			local scale = math.min(maximumWidth / projectedWidth, maximumHeight / projectedHeight)
			projectedWidth = math.max(2, math.floor(projectedWidth * scale))
			projectedHeight = math.max(2, math.floor(projectedHeight * scale))
			projectedBounds.minX = centerX - math.floor(projectedWidth / 2)
			projectedBounds.maxX = projectedBounds.minX + projectedWidth - 1
			projectedBounds.minY = centerY - math.floor(projectedHeight / 2)
			projectedBounds.maxY = projectedBounds.minY + projectedHeight - 1
		end
		drawn += Raster.ProjectComponent(accessory.component, target, targetSize, projectedBounds)
	end
	return drawn
end

local function diagnosticMasks(size: Vector2, masks: { [string]: buffer }): buffer
	local result = buffer.create(math.floor(size.X) * math.floor(size.Y) * 4)
	for _, entry in {
		{ masks.backHair, Color3.fromRGB(64, 191, 113) },
		{ masks.face, Color3.fromRGB(255, 202, 178) },
		{ masks.sides, Color3.fromRGB(103, 99, 225) },
		{ masks.bangs, Color3.fromRGB(255, 211, 72) },
		{ masks.tips, Color3.fromRGB(207, 84, 229) },
		{ masks.accessoryAnchors, Color3.fromRGB(255, 255, 255) },
	} do
		fillMask(result, size, entry[1] :: buffer, entry[2] :: Color3)
	end
	return result
end

function ProceduralChibiHead.Paint(
	size: Vector2,
	headBounds: Bounds,
	sourcePixels: buffer,
	sourceSize: Vector2,
	sourceBounds: Bounds,
	analysis: Analysis,
	skinColor: Color3,
	eyeColor: Color3,
	inkColor: Color3
): PaintResult
	local hair = analysis.hair
	local masks = ProceduralChibiHead.CreateMasks(size, headBounds, hair)
	local backHair = Face.BackHairLayer(size, headBounds, hair)
	local secondaryTips = buffer.create(buffer.len(backHair))
	if hair.secondaryReliable then
		fillMask(secondaryTips, size, masks.tips, hair.secondary)
		Raster.CompositeBufferSourceOver(backHair, secondaryTips, size)
	end
	local face = Face.FaceLayer(size, headBounds, skinColor)
	local features, colors = Face.FacialFeaturesLayer(size, headBounds, skinColor, eyeColor)
	local frontHair = Face.FrontHairLayer(size, headBounds, hair)
	-- Source observations decide which lower side receives more secondary color.
	if hair.secondaryReliable then
		local tipLayer = buffer.create(buffer.len(backHair))
		local width = math.floor(size.X)
		local centerX = math.floor((headBounds.minX + headBounds.maxX) / 2)
		for y = 0, math.floor(size.Y) - 1 do
			for x = 0, width - 1 do
				local pixelOffset = offset(width, x, y)
				if buffer.readu8(masks.tips, pixelOffset + 3) > 0 then
					local sideCoverage = if x < centerX
						then hair.leftTipSecondaryCoverage
						else hair.rightTipSecondaryCoverage
					if sideCoverage >= 0.24 or (x + y) % 3 ~= 0 then
						local red = math.round(hair.secondary.R * 255)
						local green = math.round(hair.secondary.G * 255)
						local blue = math.round(hair.secondary.B * 255)
						Raster.SourceOverPixel(tipLayer, width, math.floor(size.Y), x, y, {
							r = red, g = green, b = blue, a = 255,
						})
					end
				end
			end
		end
		Raster.CompositeBufferSourceOver(frontHair, tipLayer, size)
	end
	local accessories = buffer.create(buffer.len(backHair))
	local accessoryPixels = projectAccessories(analysis, sourceBounds, accessories, size, headBounds)
	local withoutAccessories = buffer.create(buffer.len(backHair))
	for _, layer in { backHair, face, features, frontHair } do
		Raster.CompositeBufferSourceOver(withoutAccessories, layer, size)
	end
	local composite = buffer.create(buffer.len(backHair))
	buffer.copy(composite, 0, withoutAccessories, 0, buffer.len(withoutAccessories))
	Raster.CompositeBufferSourceOver(composite, accessories, size)
	Raster.StrokeMaskInside(composite, size, masks.backHair, inkColor)
	Raster.StrokeMaskInside(composite, size, masks.face, skinColor:Lerp(inkColor, 0.32))

	local clusterDiagnostic = buffer.create(buffer.len(backHair))
	fillMask(clusterDiagnostic, size, masks.backHair, hair.primary)
	if hair.secondaryReliable then fillMask(clusterDiagnostic, size, masks.tips, hair.secondary) end
	fillMask(clusterDiagnostic, size, masks.bangs, hair.highlight)
	local candidateDiagnostic = buffer.create(buffer.len(backHair))
	projectAccessories(analysis, sourceBounds, candidateDiagnostic, size, headBounds)

	colors.hairPrimary = hair.primary
	colors.hairSecondary = hair.secondary
	colors.hairHighlight = hair.highlight
	colors.hairShadow = hair.shadow
	return {
		backHair = backHair,
		face = face,
		features = features,
		frontHair = frontHair,
		accessories = accessories,
		hairMasks = diagnosticMasks(size, masks),
		hairClusters = clusterDiagnostic,
		accessoryCandidates = candidateDiagnostic,
		withoutAccessories = withoutAccessories,
		composite = composite,
		masks = masks,
		colors = colors,
		lockedColors = {
			hair.primary, hair.secondary, hair.highlight, hair.shadow,
			colors.skin, colors.skinShadow, colors.eye, colors.eyeShadow,
			colors.eyeOutline, colors.highlight, colors.blush, colors.mouth, inkColor,
		},
		metrics = {
			proceduralUsed = true,
			fallbackUsed = false,
			primaryCoverage = hair.primaryCoverage,
			secondaryCoverage = hair.secondaryCoverage,
			accessoryCandidates = analysis.metrics.candidates,
			accessoriesAccepted = analysis.metrics.accepted,
			accessoriesRejectedFace = analysis.metrics.rejectedFace,
			fallbackPixels = 0,
		},
	}
end

return table.freeze(ProceduralChibiHead)
