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
	candidatesByZone: { [string]: number },
	retainedByZone: { [string]: number },
	rejectedByOverlap: number,
	rejectedByQuota: number,
	rejectedAsDuplicate: number,
	mergedPairs: number,
	rawLabelComponents: number,
	regularizedLabelComponents: number,
	removedLabelPixels: number,
	isolatedHighlightPixels: number,
	isolatedSecondaryPixels: number,
	fringeEyeOverlapRatio: number,
	pairMetrics: { [number]: {
		heightRatio: number,
		scaleRatio: number,
		verticalOffset: number,
		projectedPixelsLeft: number,
		projectedPixelsRight: number,
	} },
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
	sideBackAccessories: buffer,
	sideFrontAccessories: buffer,
	frontAccessories: buffer,
	hairMasks: buffer,
	hairClusters: buffer,
	hairCore: buffer,
	hairLabelMap: buffer,
	hairLabelMapRaw: buffer,
	hairLabelMapRegularized: buffer,
	hairColorMasses: buffer,
	accessoryCandidates: buffer,
	accessoryRawCandidates: buffer,
	accessoryMergedGroups: buffer,
	accessoryAnchors: buffer,
	accessorySelectedPerZone: buffer,
	accessoryPairLayout: buffer,
	accessoryCompositeBeforeClipping: buffer,
	accessoryCompositeAfterClipping: buffer,
	withoutAccessories: buffer,
	composite: buffer,
	masks: { [string]: buffer },
	colors: Face.PaintedColors,
	lockedColors: { Color3 },
	metrics: HeadMetrics,
}

local ProceduralChibiHead = {}

type NormalizedBounds = { minU: number, minV: number, maxU: number, maxV: number }

local NORMALIZED_ANCHORS: { [string]: NormalizedBounds } = {
	topLeft = { minU = -0.14, minV = -0.08, maxU = 0.34, maxV = 0.34 },
	topRight = { minU = 0.66, minV = -0.08, maxU = 1.14, maxV = 0.34 },
	sideLeft = { minU = -0.18, minV = 0.2, maxU = 0.25, maxV = 0.92 },
	sideRight = { minU = 0.75, minV = 0.2, maxU = 1.18, maxV = 0.92 },
	frontLeft = { minU = 0.08, minV = 0.08, maxU = 0.53, maxV = 0.62 },
	frontRight = { minU = 0.47, minV = 0.08, maxU = 0.92, maxV = 0.62 },
	centerTop = { minU = 0.32, minV = -0.1, maxU = 0.68, maxV = 0.3 },
}

local function offset(width: number, x: number, y: number): number
	return (y * width + x) * 4
end

local function anchorBounds(headBounds: Bounds, bounds: NormalizedBounds): Bounds
	local headWidth = headBounds.maxX - headBounds.minX + 1
	local headHeight = headBounds.maxY - headBounds.minY + 1
	return {
		minX = math.floor(headBounds.minX + bounds.minU * headWidth + 0.5),
		minY = math.floor(headBounds.minY + bounds.minV * headHeight + 0.5),
		maxX = math.floor(headBounds.minX + bounds.maxU * headWidth + 0.5),
		maxY = math.floor(headBounds.minY + bounds.maxV * headHeight + 0.5),
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
	local headWidth = headBounds.maxX - headBounds.minX + 1
	local headHeight = headBounds.maxY - headBounds.minY + 1
	local eyeY = headBounds.minY + math.floor(headHeight * 0.61)
	masks.protectedEyeMask = buffer.create(buffer.len(backLayer))
	Raster.FillEllipse(masks.protectedEyeMask, size,
		Vector2.new(headBounds.minX + headWidth * 0.36, eyeY),
		Vector2.new(headWidth * 0.13, headHeight * 0.095))
	Raster.FillEllipse(masks.protectedEyeMask, size,
		Vector2.new(headBounds.minX + headWidth * 0.64, eyeY),
		Vector2.new(headWidth * 0.13, headHeight * 0.095))
	masks.protectedMouthMask = rectangleMask(size, {
		minX = headBounds.minX + math.floor(headWidth * 0.43),
		maxX = headBounds.minX + math.floor(headWidth * 0.57),
		minY = headBounds.minY + math.floor(headHeight * 0.74),
		maxY = headBounds.minY + math.floor(headHeight * 0.84),
	})
	masks.protectedFacialFeaturesMask = Raster.UnionMasks(
		masks.protectedEyeMask,
		masks.protectedMouthMask,
		size
	)
	local tipStart = headBounds.minY + math.floor((headBounds.maxY - headBounds.minY + 1) * 0.72)
	local tipArea = rectangleMask(size, {
		minX = headBounds.minX,
		minY = tipStart,
		maxX = headBounds.maxX,
		maxY = headBounds.maxY,
	})
	masks.tips = Raster.IntersectMasks(masks.backHair, tipArea, size)
	for _, normalizedBounds in NORMALIZED_ANCHORS do
		masks.accessoryAnchors = Raster.UnionMasks(
			masks.accessoryAnchors,
			rectangleMask(size, anchorBounds(headBounds, normalizedBounds)),
			size
		)
	end
	local expandedHair = Raster.CardinalDilate(
		Raster.UnionMasks(masks.backHair, masks.frontHair, size),
		size,
		4
	)
	masks.frontAccessoryAllowed = Raster.SubtractMask(
		Raster.IntersectMasks(masks.accessoryAnchors, expandedHair, size),
		masks.protectedFacialFeaturesMask,
		size
	)
	masks.sideAccessoryAllowed = Raster.SubtractMask(
		Raster.UnionMasks(masks.accessoryAnchors, expandedHair, size),
		masks.protectedFacialFeaturesMask,
		size
	)
	masks.backAccessoryAllowed = Raster.UnionMasks(masks.accessoryAnchors, expandedHair, size)
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
	headBounds: Bounds,
	backTarget: buffer,
	sideBackTarget: buffer,
	sideFrontTarget: buffer,
	frontTarget: buffer
): (number, number, number, number, { [number]: any })
	local projected = 0
	local fillTotal = 0
	local repaired = 0
	local clipped = 0
	local pairTargets: { [number]: { [number]: Bounds } } = {}
	local pairMetrics: { [number]: any } = {}
	for index, accessory in analysis.accessories do
		if not accessory.pairId then continue end
		local pairId = accessory.pairId :: number
		pairTargets[pairId] = pairTargets[pairId] or {}
		local normalized = NORMALIZED_ANCHORS[accessory.anchor]
		local anchor = anchorBounds(headBounds, normalized)
		local sourceWidth = accessory.component.bounds.maxX - accessory.component.bounds.minX + 1
		local sourceHeight = accessory.component.bounds.maxY - accessory.component.bounds.minY + 1
		local height = math.max(3, math.floor((anchor.maxY - anchor.minY + 1) * 0.55))
		local width = math.max(3, math.floor(height * sourceWidth / math.max(1, sourceHeight)))
		local centerX = math.floor((anchor.minX + anchor.maxX) / 2)
		local baseline = anchor.maxY
		pairTargets[pairId][index] = {
			minX = centerX - math.floor(width / 2),
			maxX = centerX - math.floor(width / 2) + width - 1,
			minY = baseline - height + 1,
			maxY = baseline,
		}
	end
	for pairId, targets in pairTargets do
		local indices = {}
		for index in targets do table.insert(indices, index) end
		if #indices == 2 then
			local left = targets[indices[1]]
			local right = targets[indices[2]]
			local sharedHeight = math.floor(((left.maxY - left.minY + 1) + (right.maxY - right.minY + 1)) / 2 + 0.5)
			local baseline = math.floor((left.maxY + right.maxY) / 2 + 0.5)
			for _, target in { left, right } do
				target.minY = baseline - sharedHeight + 1
				target.maxY = baseline
			end
			local headCenter = (headBounds.minX + headBounds.maxX) / 2
			local distance = (math.abs((left.minX + left.maxX) / 2 - headCenter)
				+ math.abs((right.minX + right.maxX) / 2 - headCenter)) / 2
			local leftCenter = headCenter - distance
			local rightCenter = headCenter + distance
			local leftWidth = left.maxX - left.minX + 1
			local rightWidth = right.maxX - right.minX + 1
			left.minX = math.floor(leftCenter - leftWidth / 2 + 0.5)
			left.maxX = left.minX + leftWidth - 1
			right.minX = math.floor(rightCenter - rightWidth / 2 + 0.5)
			right.maxX = right.minX + rightWidth - 1
			pairMetrics[pairId] = {
				heightRatio = math.max(
					left.maxY - left.minY + 1,
					right.maxY - right.minY + 1
				) / math.max(1, math.min(
					left.maxY - left.minY + 1,
					right.maxY - right.minY + 1
				)),
				scaleRatio = 1,
				verticalOffset = math.abs(left.maxY - right.maxY),
				projectedPixelsLeft = 0,
				projectedPixelsRight = 0,
			}
		end
	end
	for _, accessory in analysis.accessories do
		local accessoryIndex = table.find(analysis.accessories, accessory) :: number
		local anchor = if accessory.pairId and pairTargets[accessory.pairId :: number]
			then pairTargets[accessory.pairId :: number][accessoryIndex]
			else nil
		local canonicalAnchor = anchorBounds(headBounds, NORMALIZED_ANCHORS[accessory.anchor])
		local occupancy = if accessory.kind == "Ear"
			then 0.62
			elseif accessory.kind == "Headphone" then 0.56
			elseif accessory.kind == "Bow" then 0.52
			elseif accessory.kind == "Clip" then 0.34
			else 0.42
		local anchorWidth = canonicalAnchor.maxX - canonicalAnchor.minX + 1
		local anchorHeight = canonicalAnchor.maxY - canonicalAnchor.minY + 1
		local fittedWidth = math.max(3, math.floor(anchorWidth * occupancy))
		local fittedHeight = math.max(3, math.floor(anchorHeight * occupancy))
		local sourceU = (accessory.centroid.X - analysis.protectedFace.minX)
			/ math.max(1, analysis.protectedFace.maxX - analysis.protectedFace.minX)
		local sourceV = (accessory.centroid.Y - analysis.protectedFace.minY)
			/ math.max(1, analysis.protectedFace.maxY - analysis.protectedFace.minY)
		local centerX = math.floor(canonicalAnchor.minX
			+ math.clamp(sourceU, 0.15, 0.85) * anchorWidth)
		local centerY = math.floor(canonicalAnchor.minY
			+ math.clamp(sourceV, 0.15, 0.85) * anchorHeight)
		local fittedMinX = centerX - math.floor(fittedWidth / 2)
		local fittedMinY = centerY - math.floor(fittedHeight / 2)
		if accessory.anchor == "topLeft" or accessory.anchor == "sideLeft" then
			fittedMinX = canonicalAnchor.maxX - fittedWidth + 1
		elseif accessory.anchor == "topRight" or accessory.anchor == "sideRight" then
			fittedMinX = canonicalAnchor.minX
		end
		if accessory.anchor == "topLeft"
			or accessory.anchor == "topRight"
			or accessory.anchor == "centerTop" then
			fittedMinY = canonicalAnchor.maxY - fittedHeight + 1
		end
		anchor = anchor or {
			minX = fittedMinX,
			maxX = fittedMinX + fittedWidth - 1,
			minY = fittedMinY,
			maxY = fittedMinY + fittedHeight - 1,
		}
		local target = if accessory.depth == "Back"
			then backTarget
			elseif accessory.depth == "Side"
				and (accessory.kind == "Ear" or accessory.anchor == "topLeft" or accessory.anchor == "topRight")
				then sideBackTarget
			elseif accessory.depth == "Side" then sideFrontTarget
			else frontTarget
		local temporary = buffer.create(buffer.len(target))
		local metrics = Raster.ProjectComponentResampled(accessory.component, temporary, targetSize, anchor, {
			CloseRadius = 1,
		})
		Raster.CompositeBufferSourceOver(target, temporary, targetSize)
		if metrics.occupiedPixels > 0 then projected += 1 end
		if accessory.pairId and pairMetrics[accessory.pairId :: number] then
			local pairMetric = pairMetrics[accessory.pairId :: number]
			if string.find(accessory.anchor, "Left", 1, true) then
				pairMetric.projectedPixelsLeft = metrics.occupiedPixels
			else
				pairMetric.projectedPixelsRight = metrics.occupiedPixels
			end
		end
		fillTotal += metrics.fillRatio
		repaired += metrics.repairedPixels
		clipped += metrics.clippedPixels
	end
	return projected, fillTotal / math.max(1, projected), repaired, clipped, pairMetrics
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
	local hairLabelMapRaw = mapSourceBufferToHead(
		hair.rawLabelMap, sourceSize, sourceBounds, size, headBounds, fullHairMask
	)
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
	local sideBackAccessories = buffer.create(buffer.len(backHair))
	local sideFrontAccessories = buffer.create(buffer.len(backHair))
	local frontAccessories = buffer.create(buffer.len(backHair))
	local projectedComponents, averageFillRatio, repairedPixels, clippedPixels, pairMetrics =
		projectAccessories(
			analysis,
			size,
			headBounds,
			backAccessories,
			sideBackAccessories,
			sideFrontAccessories,
			frontAccessories
		)
	local accessoryCompositeBeforeClipping = buffer.create(buffer.len(backHair))
	for _, layer in { backAccessories, sideBackAccessories, sideFrontAccessories, frontAccessories } do
		Raster.CompositeBufferSourceOver(accessoryCompositeBeforeClipping, layer, size)
	end
	backAccessories = Raster.ClipToMask(backAccessories, size, masks.backAccessoryAllowed)
	sideBackAccessories = Raster.ClipToMask(sideBackAccessories, size, masks.sideAccessoryAllowed)
	sideFrontAccessories = Raster.ClipToMask(sideFrontAccessories, size, masks.sideAccessoryAllowed)
	frontAccessories = Raster.ClipToMask(frontAccessories, size, masks.frontAccessoryAllowed)
	local sideAccessories = buffer.create(buffer.len(backHair))
	Raster.CompositeBufferSourceOver(sideAccessories, sideBackAccessories, size)
	Raster.CompositeBufferSourceOver(sideAccessories, sideFrontAccessories, size)
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
		sideBackAccessories,
		face,
		features,
		frontHair,
		sideFrontAccessories,
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
	local accessoryCompositeAfterClipping = buffer.create(buffer.len(backHair))
	Raster.CompositeBufferSourceOver(accessoryCompositeAfterClipping, accessories, size)
	local eyePixels = Raster.CountMaskPixels(masks.protectedEyeMask, size)
	local fringeEyeOverlap = Raster.CountMaskPixels(
		Raster.IntersectMasks(masks.protectedEyeMask, masks.frontHair, size),
		size
	) / math.max(1, eyePixels)

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
		sideBackAccessories = sideBackAccessories,
		sideFrontAccessories = sideFrontAccessories,
		frontAccessories = frontAccessories,
		hairMasks = diagnosticMasks(size, masks),
		hairClusters = clusterDiagnostic,
		hairCore = hairCore,
		hairLabelMap = hairLabelMap,
		hairLabelMapRaw = hairLabelMapRaw,
		hairLabelMapRegularized = hairLabelMap,
		hairColorMasses = clusterDiagnostic,
		accessoryCandidates = mergedDiagnostic,
		accessoryRawCandidates = rawDiagnostic,
		accessoryMergedGroups = mergedDiagnostic,
		accessoryAnchors = anchorDiagnostic,
		accessorySelectedPerZone = mergedDiagnostic,
		accessoryPairLayout = anchorDiagnostic,
		accessoryCompositeBeforeClipping = accessoryCompositeBeforeClipping,
		accessoryCompositeAfterClipping = accessoryCompositeAfterClipping,
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
			candidatesByZone = analysis.metrics.candidatesByZone,
			retainedByZone = analysis.metrics.retainedByZone,
			rejectedByOverlap = analysis.metrics.rejectedByOverlap,
			rejectedByQuota = analysis.metrics.rejectedByQuota,
			rejectedAsDuplicate = analysis.metrics.rejectedAsDuplicate,
			mergedPairs = analysis.metrics.mergedPairs,
			rawLabelComponents = hair.rawLabelComponents,
			regularizedLabelComponents = hair.regularizedLabelComponents,
			removedLabelPixels = hair.removedLabelPixels,
			isolatedHighlightPixels = hair.isolatedHighlightPixels,
			isolatedSecondaryPixels = hair.isolatedSecondaryPixels,
			fringeEyeOverlapRatio = fringeEyeOverlap,
			pairMetrics = pairMetrics,
			fallbackPixels = 0,
		},
	}
end

return table.freeze(ProceduralChibiHead)
