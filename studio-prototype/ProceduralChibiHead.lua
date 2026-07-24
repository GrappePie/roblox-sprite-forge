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
	hairCoreCoverage: number,
	fringeGapCount: number,
	strayPixelCount: number,
	accessoryCandidates: number,
	accessoriesAccepted: number,
	accessoriesRejectedFace: number,
	rawComponents: number,
	mergedComponents: number,
	acceptedComponents: number,
	projectedComponents: number,
	averageFillRatio: number,
	repairedPixels: number,
	clippedPixels: number,
	byZone: { [string]: number },
	fallbackPixels: number,
}

export type PaintResult = {
	backHair: buffer,
	face: buffer,
	features: buffer,
	frontHair: buffer,
	accessories: buffer,
	backAccessories: buffer,
	sideAccessories: buffer,
	frontAccessories: buffer,
	hairMasks: buffer,
	hairClusters: buffer,
	hairCore: buffer,
	hairLabelMap: buffer,
	accessoryCandidates: buffer,
	accessoryRawCandidates: buffer,
	accessoryMergedGroups: buffer,
	accessoryAnchors: buffer,
	withoutAccessories: buffer,
	composite: buffer,
	masks: { [string]: buffer },
	colors: Face.PaintedColors,
	lockedColors: { Color3 },
	metrics: HeadMetrics,
}

local ProceduralChibiHead = {}

local CANONICAL_ANCHORS: { [string]: Bounds } = {
	topLeft = { minX = 2, minY = 0, maxX = 45, maxY = 38 },
	topRight = { minX = 83, minY = 0, maxX = 126, maxY = 38 },
	sideLeft = { minX = 1, minY = 28, maxX = 34, maxY = 105 },
	sideRight = { minX = 94, minY = 28, maxX = 127, maxY = 105 },
	frontLeft = { minX = 20, minY = 18, maxX = 63, maxY = 72 },
	frontRight = { minX = 65, minY = 18, maxX = 108, maxY = 72 },
	centerTop = { minX = 43, minY = 0, maxX = 85, maxY = 34 },
}

local function offset(width: number, x: number, y: number): number
	return (y * width + x) * 4
end

local function scaledBounds(size: Vector2, bounds: Bounds): Bounds
	return {
		minX = math.floor(bounds.minX * size.X / 128 + 0.5),
		minY = math.floor(bounds.minY * size.Y / 256 + 0.5),
		maxX = math.floor(bounds.maxX * size.X / 128 + 0.5),
		maxY = math.floor(bounds.maxY * size.Y / 256 + 0.5),
	}
end

local function alphaMask(layer: buffer, size: Vector2): buffer
	local mask = buffer.create(buffer.len(layer))
	local width = math.floor(size.X)
	for y = 0, math.floor(size.Y) - 1 do
		for x = 0, width - 1 do
			local pixelOffset = offset(width, x, y)
			if buffer.readu8(layer, pixelOffset + 3) > 0 then
				buffer.writeu8(mask, pixelOffset + 3, 255)
			end
		end
	end
	return mask
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

local function rectangleMask(size: Vector2, bounds: Bounds): buffer
	local mask = buffer.create(math.floor(size.X) * math.floor(size.Y) * 4)
	Raster.FillPolygon(mask, size, {
		Vector2.new(bounds.minX, bounds.minY),
		Vector2.new(bounds.maxX, bounds.minY),
		Vector2.new(bounds.maxX, bounds.maxY),
		Vector2.new(bounds.minX, bounds.maxY),
	})
	return mask
end

function ProceduralChibiHead.CreateMasks(
	size: Vector2,
	headBounds: Bounds,
	hair: Face.HairColors
): { [string]: buffer }
	local backLayer = Face.BackHairLayer(size, headBounds, hair)
	local faceLayer = Face.FaceLayer(size, headBounds, Color3.new(1, 1, 1))
	local frontLayer = Face.FrontHairLayer(size, headBounds, hair)
	local masks: { [string]: buffer } = {
		backHair = alphaMask(backLayer, size),
		face = alphaMask(faceLayer, size),
		frontHair = alphaMask(frontLayer, size),
		bangs = alphaMask(frontLayer, size),
		tips = buffer.create(buffer.len(backLayer)),
		accessoryAnchors = buffer.create(buffer.len(backLayer)),
	}
	local tipStart = headBounds.minY + math.floor((headBounds.maxY - headBounds.minY + 1) * 0.72)
	local tipArea = rectangleMask(size, {
		minX = headBounds.minX,
		minY = tipStart,
		maxX = headBounds.maxX,
		maxY = headBounds.maxY,
	})
	masks.tips = Raster.IntersectMasks(masks.backHair, tipArea, size)
	for _, canonicalBounds in CANONICAL_ANCHORS do
		masks.accessoryAnchors = Raster.UnionMasks(
			masks.accessoryAnchors,
			rectangleMask(size, scaledBounds(size, canonicalBounds)),
			size
		)
	end
	return masks
end

local function mapSourceBufferToHead(
	source: buffer,
	sourceSize: Vector2,
	sourceBounds: Bounds,
	targetSize: Vector2,
	headBounds: Bounds,
	targetMask: buffer?
): buffer
	local target = buffer.create(math.floor(targetSize.X) * math.floor(targetSize.Y) * 4)
	local sourceWidth = math.floor(sourceSize.X)
	local targetWidth = math.floor(targetSize.X)
	local targetHeight = math.floor(targetSize.Y)
	local headWidth = math.max(1, headBounds.maxX - headBounds.minX + 1)
	local headHeight = math.max(1, headBounds.maxY - headBounds.minY + 1)
	local sourceBoundsWidth = math.max(1, sourceBounds.maxX - sourceBounds.minX + 1)
	local sourceBoundsHeight = math.max(1, sourceBounds.maxY - sourceBounds.minY + 1)
	for y = math.max(0, headBounds.minY), math.min(targetHeight - 1, headBounds.maxY) do
		for x = math.max(0, headBounds.minX), math.min(targetWidth - 1, headBounds.maxX) do
			local targetOffset = offset(targetWidth, x, y)
			if targetMask and buffer.readu8(targetMask, targetOffset + 3) == 0 then continue end
			local sourceX = math.clamp(
				sourceBounds.minX + math.floor((x - headBounds.minX + 0.5) * sourceBoundsWidth / headWidth),
				sourceBounds.minX,
				sourceBounds.maxX
			)
			local sourceY = math.clamp(
				sourceBounds.minY + math.floor((y - headBounds.minY + 0.5) * sourceBoundsHeight / headHeight),
				sourceBounds.minY,
				sourceBounds.maxY
			)
			local sourceOffset = offset(sourceWidth, sourceX, sourceY)
			if buffer.readu8(source, sourceOffset + 3) > 0 then
				buffer.copy(target, targetOffset, source, sourceOffset, 4)
			end
		end
	end
	return target
end

local function projectAccessories(
	analysis: Analysis,
	targetSize: Vector2,
	backTarget: buffer,
	sideTarget: buffer,
	frontTarget: buffer
): (number, number, number, number)
	local projected = 0
	local fillTotal = 0
	local repaired = 0
	local clipped = 0
	for _, accessory in analysis.accessories do
		local anchor = scaledBounds(targetSize, CANONICAL_ANCHORS[accessory.anchor])
		local occupancy = if accessory.kind == "Ear"
			then 0.62
			elseif accessory.kind == "Headphone" then 0.56
			elseif accessory.kind == "Bow" then 0.52
			elseif accessory.kind == "Clip" then 0.34
			else 0.42
		local anchorWidth = anchor.maxX - anchor.minX + 1
		local anchorHeight = anchor.maxY - anchor.minY + 1
		local fittedWidth = math.max(3, math.floor(anchorWidth * occupancy))
		local fittedHeight = math.max(3, math.floor(anchorHeight * occupancy))
		local centerX = math.floor((anchor.minX + anchor.maxX) / 2)
		local centerY = math.floor((anchor.minY + anchor.maxY) / 2)
		local fittedMinX = centerX - math.floor(fittedWidth / 2)
		local fittedMinY = centerY - math.floor(fittedHeight / 2)
		if accessory.anchor == "topLeft" or accessory.anchor == "sideLeft" then
			fittedMinX = anchor.maxX - fittedWidth + 1
		elseif accessory.anchor == "topRight" or accessory.anchor == "sideRight" then
			fittedMinX = anchor.minX
		end
		if accessory.anchor == "topLeft"
			or accessory.anchor == "topRight"
			or accessory.anchor == "centerTop" then
			fittedMinY = anchor.maxY - fittedHeight + 1
		end
		anchor = {
			minX = fittedMinX,
			maxX = fittedMinX + fittedWidth - 1,
			minY = fittedMinY,
			maxY = fittedMinY + fittedHeight - 1,
		}
		local target = if accessory.depth == "Back"
			then backTarget
			elseif accessory.depth == "Side" then sideTarget
			else frontTarget
		local temporary = buffer.create(buffer.len(target))
		local metrics = Raster.ProjectComponentResampled(accessory.component, temporary, targetSize, anchor, {
			CloseRadius = 1,
		})
		local shiftX = if accessory.anchor == "topLeft" or accessory.anchor == "sideLeft" or accessory.anchor == "frontLeft"
			then 8
			elseif accessory.anchor == "topRight" or accessory.anchor == "sideRight" or accessory.anchor == "frontRight" then -8
			else 0
		local shiftY = if accessory.anchor == "topLeft"
				or accessory.anchor == "topRight"
				or accessory.anchor == "centerTop" then 5 else 0
		if shiftX ~= 0 or shiftY ~= 0 then
			local shifted = buffer.create(buffer.len(temporary))
			local width = math.floor(targetSize.X)
			local height = math.floor(targetSize.Y)
			for y = 0, height - 1 do
				for x = 0, width - 1 do
					local sourceX = x - shiftX
					local sourceY = y - shiftY
					if sourceX >= 0 and sourceY >= 0 and sourceX < width and sourceY < height then
						local sourceOffset = offset(width, sourceX, sourceY)
						if buffer.readu8(temporary, sourceOffset + 3) > 0 then
							buffer.copy(shifted, offset(width, x, y), temporary, sourceOffset, 4)
						end
					end
				end
			end
			temporary = shifted
		end
		Raster.CompositeBufferSourceOver(target, temporary, targetSize)
		if metrics.occupiedPixels > 0 then projected += 1 end
		fillTotal += metrics.fillRatio
		repaired += metrics.repairedPixels
		clipped += metrics.clippedPixels
	end
	return projected, fillTotal / math.max(1, projected), repaired, clipped
end

local function diagnosticMasks(size: Vector2, masks: { [string]: buffer }): buffer
	local result = buffer.create(math.floor(size.X) * math.floor(size.Y) * 4)
	for _, entry in {
		{ masks.backHair, Color3.fromRGB(64, 191, 113) },
		{ masks.face, Color3.fromRGB(255, 202, 178) },
		{ masks.bangs, Color3.fromRGB(255, 211, 72) },
		{ masks.tips, Color3.fromRGB(207, 84, 229) },
		{ masks.accessoryAnchors, Color3.fromRGB(255, 255, 255) },
	} do
		fillMask(result, size, entry[1] :: buffer, entry[2] :: Color3)
	end
	return result
end

local function countFringeGaps(mask: buffer, size: Vector2): number
	local bounds = Raster.MaskBounds(mask, size)
	if not bounds then return 1 end
	local width = math.floor(size.X)
	local gaps = 0
	for y = bounds.minY, math.min(bounds.maxY, bounds.minY + math.floor((bounds.maxY - bounds.minY) * 0.48)) do
		local gapLength = 0
		local occupiedSeen = false
		for x = bounds.minX, bounds.maxX do
			if buffer.readu8(mask, offset(width, x, y) + 3) > 0 then
				if occupiedSeen and gapLength > 2 then gaps += 1 end
				occupiedSeen = true
				gapLength = 0
			elseif occupiedSeen then
				gapLength += 1
			end
		end
	end
	return gaps
end

local function countStrays(pixels: buffer, size: Vector2): number
	local mask = alphaMask(pixels, size)
	local strays = 0
	for _, component in Raster.ConnectedComponents(mask, size, nil, 1, 8) do
		if component.area <= 2 then strays += component.area end
	end
	return strays
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
	local face = Face.FaceLayer(size, headBounds, skinColor)
	local features, colors = Face.FacialFeaturesLayer(size, headBounds, skinColor, eyeColor)
	local frontHair = Face.FrontHairLayer(size, headBounds, hair)

	-- Project the spatial label distribution into canonical alpha. Texture is
	-- observed from the thumbnail, while silhouette remains procedural.
	local fullHairMask = Raster.UnionMasks(masks.backHair, masks.frontHair, size)
	local hairLabelMap = mapSourceBufferToHead(
		hair.labelMap, sourceSize, sourceBounds, size, headBounds, fullHairMask
	)
	local labelBack = Raster.ClipToMask(hairLabelMap, size, masks.backHair)
	local labelFront = Raster.ClipToMask(hairLabelMap, size, masks.frontHair)
	Raster.CompositeBufferSourceOver(backHair, labelBack, size)
	Raster.CompositeBufferSourceOver(frontHair, labelFront, size)
	if hair.secondaryReliable and Raster.CountMaskPixels(labelBack, size) == 0 then
		-- A reliable secondary still receives a coherent tip mass when sparse
		-- source labels vanish during reduction; never use a checker pattern.
		local secondaryTips = buffer.create(buffer.len(backHair))
		fillMask(secondaryTips, size, masks.tips, hair.secondary)
		Raster.CompositeBufferSourceOver(backHair, secondaryTips, size)
	end
	local hairCore = mapSourceBufferToHead(
		hair.hairCoreMask, sourceSize, sourceBounds, size, headBounds, fullHairMask
	)

	local backAccessories = buffer.create(buffer.len(backHair))
	local sideAccessories = buffer.create(buffer.len(backHair))
	local frontAccessories = buffer.create(buffer.len(backHair))
	local projectedComponents, averageFillRatio, repairedPixels, clippedPixels =
		projectAccessories(analysis, size, backAccessories, sideAccessories, frontAccessories)
	local sideAllowed = Raster.SubtractMask(masks.accessoryAnchors, masks.face, size)
	sideAccessories = Raster.ClipToMask(sideAccessories, size, sideAllowed)
	frontAccessories = Raster.ClipToMask(frontAccessories, size, masks.frontHair)
	local accessories = buffer.create(buffer.len(backHair))
	for _, layer in { backAccessories, sideAccessories, frontAccessories } do
		Raster.CompositeBufferSourceOver(accessories, layer, size)
	end

	local withoutAccessories = buffer.create(buffer.len(backHair))
	for _, layer in { backHair, face, features, frontHair } do
		Raster.CompositeBufferSourceOver(withoutAccessories, layer, size)
	end
	local composite = buffer.create(buffer.len(backHair))
	for _, layer in {
		backAccessories,
		backHair,
		sideAccessories,
		face,
		features,
		frontHair,
		frontAccessories,
	} do
		Raster.CompositeBufferSourceOver(composite, layer, size)
	end
	Raster.StrokeMaskInside(composite, size, masks.backHair, inkColor)
	Raster.StrokeMaskInside(composite, size, masks.face, skinColor:Lerp(inkColor, 0.32))

	local clusterDiagnostic = buffer.create(buffer.len(backHair))
	fillMask(clusterDiagnostic, size, masks.backHair, hair.primary)
	Raster.CompositeBufferSourceOver(clusterDiagnostic, hairLabelMap, size)
	local rawDiagnostic = mapSourceBufferToHead(
		analysis.rawCandidateMask, sourceSize, sourceBounds, size, headBounds, nil
	)
	local mergedDiagnostic = mapSourceBufferToHead(
		analysis.mergedCandidateMask, sourceSize, sourceBounds, size, headBounds, nil
	)
	local anchorDiagnostic = diagnosticMasks(size, masks)

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
		backAccessories = backAccessories,
		sideAccessories = sideAccessories,
		frontAccessories = frontAccessories,
		hairMasks = diagnosticMasks(size, masks),
		hairClusters = clusterDiagnostic,
		hairCore = hairCore,
		hairLabelMap = hairLabelMap,
		accessoryCandidates = mergedDiagnostic,
		accessoryRawCandidates = rawDiagnostic,
		accessoryMergedGroups = mergedDiagnostic,
		accessoryAnchors = anchorDiagnostic,
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
			hairCoreCoverage = hair.hairCoreCoverage,
			fringeGapCount = countFringeGaps(masks.frontHair, size),
			strayPixelCount = countStrays(composite, size),
			accessoryCandidates = analysis.metrics.candidates,
			accessoriesAccepted = analysis.metrics.accepted,
			accessoriesRejectedFace = analysis.metrics.rejectedFace,
			rawComponents = analysis.metrics.rawComponents,
			mergedComponents = analysis.metrics.mergedComponents,
			acceptedComponents = analysis.metrics.acceptedComponents,
			projectedComponents = projectedComponents,
			averageFillRatio = averageFillRatio,
			repairedPixels = repairedPixels,
			clippedPixels = clippedPixels,
			byZone = analysis.metrics.byZone,
			fallbackPixels = 0,
		},
	}
end

return table.freeze(ProceduralChibiHead)
