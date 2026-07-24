--!strict

local Face = require(script.Parent:WaitForChild("ProceduralChibiFace"))
local Accessory = require(script.Parent:WaitForChild("ProceduralChibiAccessory"))
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
	accessorySourceCoverage: number,
	accessoryTargetCoverage: number,
	maximumAccessoryArea: number,
	targetCollisionCount: number,
	targetRejectedCount: number,
	simplifiedAccessoryColors: number,
	preservedAccessoryHoles: number,
	lostAccessoryHoles: number,
	shapePreservingCount: number,
	templateAssistedCount: number,
	primitiveFallbackCount: number,
	averageAccessoryAspectError: number,
	simplifiedSourceColors: number,
	simplifiedFinalColors: number,
	rawCoreComponents: number,
	completedClusters: number,
	recoveredSupportPixels: number,
	recoveredSkinLikePixels: number,
	recoveredHairLikePixels: number,
	rejectedLeakPixels: number,
	linearAccessoryCount: number,
	stackedLinearAccessoryCount: number,
	safeCanvasAdjustments: number,
	offCanvasPixelsPrevented: number,
	averageVisibleRatio: number,
	minimumVisibleRatio: number,
	preClipHoles: number,
	finalHoles: number,
	holesLostDuringClipping: number,
	averageFinalAspectError: number,
	maximumFinalAspectError: number,
	averageHairAttachmentRatio: number,
	recoveredByTranslation: number,
	recoveredByScaling: number,
	recoveredByTemplate: number,
	recoveredByFallback: number,
	rejectedAfterFinalValidation: number,
	hairMassCount: number,
	highlightMassCount: number,
	shadowMassCount: number,
	secondaryMassCount: number,
	strandLineCount: number,
	rawIsolatedHighlightPixels: number,
	rawIsolatedSecondaryPixels: number,
	remainingIsolatedHighlightPixels: number,
	remainingIsolatedSecondaryPixels: number,
	pairMetrics: { [number]: {
		heightRatio: number,
		scaleRatio: number,
		verticalOffset: number,
		projectedPixelsLeft: number,
		projectedPixelsRight: number,
		leftZone: string,
		rightZone: string,
		leftKind: string,
		rightKind: string,
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
	hairMassDescriptors: buffer,
	accessoryCandidates: buffer,
	accessoryRawCandidates: buffer,
	accessoryMergedGroups: buffer,
	accessoryAnchors: buffer,
	accessorySelectedPerZone: buffer,
	accessoryPairLayout: buffer,
	accessoryCompositeBeforeClipping: buffer,
	accessoryCompositeAfterClipping: buffer,
	accessoryRelativeScale: buffer,
	accessoryTargetLayout: buffer,
	accessorySimplified: buffer,
	accessoryCoverageBudget: buffer,
	accessoryShapeOccupancy: buffer,
	accessoryContours: buffer,
	accessoryHoles: buffer,
	accessoryColorRoles: buffer,
	accessoryRenderModes: buffer,
	accessoryShapePreserving: buffer,
	accessoryTemplateAssisted: buffer,
	accessoryPrimitiveFallback: buffer,
	accessoryFinalLayout: buffer,
	accessoryCoreSeeds: buffer,
	accessorySupportMask: buffer,
	accessoryCompletedClusters: buffer,
	accessoryRecoveredSkinLike: buffer,
	accessoryRecoveredHairLike: buffer,
	accessoryClusterBounds: buffer,
	accessoryGeometryKinds: buffer,
	accessoryLinearDescriptors: buffer,
	accessorySafeCanvas: buffer,
	accessoryBoundsBeforeFit: buffer,
	accessoryBoundsAfterFit: buffer,
	accessoryHairAttachment: buffer,
	accessoryProtectedFaceOverlap: buffer,
	accessoryBeforeFinalValidation: buffer,
	accessoryAfterFinalValidation: buffer,
	accessoryPostClipHoles: buffer,
	accessoryPostClipTopology: buffer,
	templateAssistedLandmarks: buffer,
	templateAssistedResult: buffer,
	withoutAccessories: buffer,
	composite: buffer,
	masks: { [string]: buffer },
	colors: Face.PaintedColors,
	lockedColors: { Color3 },
	metrics: HeadMetrics,
}

local ProceduralChibiHead = {}

type NormalizedBounds = { minU: number, minV: number, maxU: number, maxV: number }

local function cloneBuffer(source: buffer): buffer
	local result = buffer.create(buffer.len(source))
	buffer.copy(result, 0, source, 0, buffer.len(source))
	return result
end

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

local function boundsPixelArea(bounds: Bounds): number
	return math.max(0, bounds.maxX - bounds.minX + 1) * math.max(0, bounds.maxY - bounds.minY + 1)
end

local function boundsOverlap(left: Bounds, right: Bounds): number
	local minX = math.max(left.minX, right.minX)
	local minY = math.max(left.minY, right.minY)
	local maxX = math.min(left.maxX, right.maxX)
	local maxY = math.min(left.maxY, right.maxY)
	if minX > maxX or minY > maxY then return 0 end
	return (maxX - minX + 1) * (maxY - minY + 1)
end

local function projectAccessoriesStructured(
	analysis: Analysis,
	targetSize: Vector2,
	headBounds: Bounds,
	masks: { [string]: buffer },
	backTarget: buffer,
	sideBackTarget: buffer,
	sideFrontTarget: buffer,
	frontTarget: buffer
): { [string]: any }
	local sourceArea = boundsPixelArea(analysis.sourceBounds)
	local headArea = boundsPixelArea(headBounds)
	local safeCanvas = Accessory.CreateSafeCanvas(targetSize, headBounds)
	local totalBudget = headArea * 0.20
	local frontBudget = headArea * 0.13
	local usedArea, usedFrontArea = 0, 0
	local layouts = {}
	for index, accessory in analysis.accessories do
		local descriptor = Accessory.Describe(accessory, analysis.sourceBounds)
		local sourceRelativeArea = accessory.area / math.max(1, sourceArea)
		local minimumArea, maximumArea = 0.01, 0.07
		if accessory.kind == "Clip" then minimumArea, maximumArea = 0.006, 0.04 end
		if accessory.kind == "Ear" or accessory.kind == "Headphone" then minimumArea, maximumArea = 0.035, 0.11 end
		local targetRelativeArea = math.clamp(sourceRelativeArea * 1.2, minimumArea, maximumArea)
		local sourceWidth = accessory.bounds.maxX - accessory.bounds.minX + 1
		local sourceHeight = accessory.bounds.maxY - accessory.bounds.minY + 1
		local aspect = math.clamp(sourceWidth / math.max(1, sourceHeight), 0.3, 3)
		local targetPixels = targetRelativeArea * headArea
		local targetHeight = math.max(3, math.floor(math.sqrt(targetPixels / aspect) + 0.5))
		local targetWidth = math.max(3, math.floor(targetHeight * aspect + 0.5))
		if descriptor.holeCount > 0 then
			local enlargement = math.max(1, 24 / math.max(1, math.min(targetWidth, targetHeight)))
			targetWidth = math.floor(targetWidth * enlargement + 0.5)
			targetHeight = math.floor(targetHeight * enlargement + 0.5)
		end
		local anchor = anchorBounds(headBounds, NORMALIZED_ANCHORS[accessory.anchor])
		local sourceU = (accessory.centroid.X - analysis.sourceBounds.minX)
			/ math.max(1, analysis.sourceBounds.maxX - analysis.sourceBounds.minX)
		local sourceV = (accessory.centroid.Y - analysis.sourceBounds.minY)
			/ math.max(1, analysis.sourceBounds.maxY - analysis.sourceBounds.minY)
		local centerX = anchor.minX + math.clamp(sourceU, 0, 1) * (anchor.maxX - anchor.minX)
		local centerY = anchor.minY + math.clamp(sourceV, 0, 1) * (anchor.maxY - anchor.minY)
		table.insert(layouts, {
			index = index,
			accessory = accessory,
			descriptor = descriptor,
			sourceRelativeArea = sourceRelativeArea,
			targetRelativeArea = targetRelativeArea,
			scale = math.sqrt(targetRelativeArea / math.max(0.0001, sourceRelativeArea)),
			bounds = {
				minX = math.floor(centerX - targetWidth / 2 + 0.5),
				maxX = math.floor(centerX - targetWidth / 2 + 0.5) + targetWidth - 1,
				minY = math.floor(centerY - targetHeight / 2 + 0.5),
				maxY = math.floor(centerY - targetHeight / 2 + 0.5) + targetHeight - 1,
			},
		})
	end
	-- Paired pieces share a baseline and stylistic scale, while retaining up
	-- to eight percent of their measured source-size difference.
	local pairGroups: { [number]: { any } } = {}
	for _, layout in layouts do
		local pairId = layout.accessory.pairId
		if pairId then
			pairGroups[pairId] = pairGroups[pairId] or {}
			table.insert(pairGroups[pairId], layout)
		end
	end
	for _, pair in pairGroups do
		if #pair ~= 2 then continue end
		local averageArea = (pair[1].sourceRelativeArea + pair[2].sourceRelativeArea) / 2
		local baseline = math.floor((pair[1].bounds.maxY + pair[2].bounds.maxY) / 2 + 0.5)
		local averageHeight = (
			(pair[1].bounds.maxY - pair[1].bounds.minY + 1)
			+ (pair[2].bounds.maxY - pair[2].bounds.minY + 1)
		) / 2
		local center = (headBounds.minX + headBounds.maxX) / 2
		local headHeight = headBounds.maxY - headBounds.minY + 1
		local topPair = string.find(pair[1].accessory.zone, "top", 1, true)
		local sidePair = string.find(pair[1].accessory.zone, "side", 1, true)
		if topPair then
			baseline = headBounds.minY + math.floor(headHeight * 0.24)
		elseif sidePair then
			baseline = headBounds.minY + math.floor(headHeight * 0.68)
		end
		local distance = (math.abs((pair[1].bounds.minX + pair[1].bounds.maxX) / 2 - center)
			+ math.abs((pair[2].bounds.minX + pair[2].bounds.maxX) / 2 - center)) / 2
		local headWidth = headBounds.maxX - headBounds.minX + 1
		distance = math.clamp(
			distance,
			headWidth * 0.27,
			headWidth * (if sidePair then 0.39 elseif topPair then 0.34 else 0.4)
		)
		for pairIndex, layout in pair do
			local ratio = math.clamp(math.sqrt(layout.sourceRelativeArea / math.max(0.0001, averageArea)), 0.925, 1.075)
			local originalAspect = math.clamp(layout.descriptor.sourceAspect, 0.35, 2.8)
			local pairBaseHeight = math.max(
				if string.find(layout.accessory.zone, "top", 1, true) then 12
					elseif string.find(layout.accessory.zone, "side", 1, true) then 16
					else 8,
				averageHeight
			)
			local height = math.max(3, math.floor(pairBaseHeight * ratio + 0.5))
			local width = math.max(3, math.floor(height * originalAspect + 0.5))
			if layout.descriptor.holeCount > 0 then
				local enlargement = math.max(1, 24 / math.max(1, math.min(width, height)))
				width = math.floor(width * enlargement + 0.5)
				height = math.floor(height * enlargement + 0.5)
			end
			local side = if string.find(layout.accessory.anchor, "Left", 1, true) then -1 else 1
			local centerX = center + distance * side
			layout.bounds = {
				minX = math.floor(centerX - width / 2 + 0.5),
				maxX = math.floor(centerX - width / 2 + 0.5) + width - 1,
				minY = baseline - height + 1,
				maxY = baseline,
			}
			-- Pair metrics report the retained source asymmetry around the
			-- shared stylistic scale, not each component's absolute resize.
			layout.scale = ratio
		end
		local leftHeight = pair[1].bounds.maxY - pair[1].bounds.minY + 1
		local rightHeight = pair[2].bounds.maxY - pair[2].bounds.minY + 1
		if math.max(leftHeight, rightHeight) / math.max(1, math.min(leftHeight, rightHeight)) > 1.18 then
			local smaller = if leftHeight < rightHeight then pair[1] else pair[2]
			local largerHeight = math.max(leftHeight, rightHeight)
			smaller.bounds.minY = baseline - math.ceil(largerHeight / 1.18) + 1
		end
	end
	table.sort(layouts, function(left, right)
		local leftPair = if left.accessory.pairId then 1 else 0
		local rightPair = if right.accessory.pairId then 1 else 0
		if leftPair ~= rightPair then return leftPair > rightPair end
		local function salience(layout: any): number
			local descriptor = layout.descriptor
			local modePenalty = if descriptor.renderMode == "PrimitiveFallback" then 0.18 else 0
			return layout.sourceRelativeArea * 3
				+ descriptor.contourComplexity * 0.34
				+ math.min(0.3, descriptor.holeCount * 0.12)
				+ math.min(0.22, #descriptor.colorRegions * 0.04)
				+ (if layout.accessory.pairId then 0.28 else 0)
				+ layout.accessory.confidence * 0.35
				- modePenalty
		end
		return salience(left) > salience(right)
	end)
	local acceptedBounds = {}
	local projected, fillTotal, repaired, clipped = 0, 0, 0, 0
	local collisions, rejected, holes, lostHoles = 0, 0, 0, 0
	local modeCounts = { ShapePreserving = 0, TemplateAssisted = 0, PrimitiveFallback = 0 }
	local sourceColors, finalColors, aspectErrorTotal = 0, 0, 0
	local maximumArea = 0
	local sourceUsedArea = 0
	local pairMetrics: { [number]: any } = {}
	local diagnostics = {
		shapeOccupancy = buffer.create(math.floor(targetSize.X) * math.floor(targetSize.Y) * 4),
		contours = buffer.create(math.floor(targetSize.X) * math.floor(targetSize.Y) * 4),
		holes = buffer.create(math.floor(targetSize.X) * math.floor(targetSize.Y) * 4),
		colorRoles = buffer.create(math.floor(targetSize.X) * math.floor(targetSize.Y) * 4),
		renderModes = buffer.create(math.floor(targetSize.X) * math.floor(targetSize.Y) * 4),
		shapePreserving = buffer.create(math.floor(targetSize.X) * math.floor(targetSize.Y) * 4),
		templateAssisted = buffer.create(math.floor(targetSize.X) * math.floor(targetSize.Y) * 4),
		primitiveFallback = buffer.create(math.floor(targetSize.X) * math.floor(targetSize.Y) * 4),
		finalLayout = buffer.create(math.floor(targetSize.X) * math.floor(targetSize.Y) * 4),
		geometryKinds = buffer.create(math.floor(targetSize.X) * math.floor(targetSize.Y) * 4),
		linearDescriptors = buffer.create(math.floor(targetSize.X) * math.floor(targetSize.Y) * 4),
		safeCanvas = buffer.create(math.floor(targetSize.X) * math.floor(targetSize.Y) * 4),
		boundsBeforeFit = buffer.create(math.floor(targetSize.X) * math.floor(targetSize.Y) * 4),
		boundsAfterFit = buffer.create(math.floor(targetSize.X) * math.floor(targetSize.Y) * 4),
		hairAttachment = buffer.create(math.floor(targetSize.X) * math.floor(targetSize.Y) * 4),
		protectedFaceOverlap = buffer.create(math.floor(targetSize.X) * math.floor(targetSize.Y) * 4),
		beforeFinalValidation = buffer.create(math.floor(targetSize.X) * math.floor(targetSize.Y) * 4),
		afterFinalValidation = buffer.create(math.floor(targetSize.X) * math.floor(targetSize.Y) * 4),
		postClipHoles = buffer.create(math.floor(targetSize.X) * math.floor(targetSize.Y) * 4),
		postClipTopology = buffer.create(math.floor(targetSize.X) * math.floor(targetSize.Y) * 4),
		templateLandmarks = buffer.create(math.floor(targetSize.X) * math.floor(targetSize.Y) * 4),
		templateResult = buffer.create(math.floor(targetSize.X) * math.floor(targetSize.Y) * 4),
	}
	local function drawBounds(target: buffer, bounds: Bounds, color: Color3)
		Raster.DrawLine(target, targetSize, Vector2.new(bounds.minX, bounds.minY), Vector2.new(bounds.maxX, bounds.minY), color)
		Raster.DrawLine(target, targetSize, Vector2.new(bounds.maxX, bounds.minY), Vector2.new(bounds.maxX, bounds.maxY), color)
		Raster.DrawLine(target, targetSize, Vector2.new(bounds.maxX, bounds.maxY), Vector2.new(bounds.minX, bounds.maxY), color)
		Raster.DrawLine(target, targetSize, Vector2.new(bounds.minX, bounds.maxY), Vector2.new(bounds.minX, bounds.minY), color)
	end
	local function constrainBounds(bounds: Bounds, descriptor: any): Bounds
		local headWidth = headBounds.maxX - headBounds.minX + 1
		local headHeight = headBounds.maxY - headBounds.minY + 1
		local width, height = bounds.maxX - bounds.minX + 1, bounds.maxY - bounds.minY + 1
		local maxWidth, maxHeight = headWidth * 0.28, headHeight * 0.24
		if descriptor.geometryKind == "PointedTop" then
			maxWidth, maxHeight = headWidth * 0.30, headHeight * 0.30
		elseif descriptor.geometryKind == "SideShell" then
			maxWidth, maxHeight = headWidth * 0.22, headHeight * 0.38
		elseif descriptor.geometryKind == "Linear" or descriptor.geometryKind == "StackedLinear" then
			local horizontal = width >= height
			local lineCount = if descriptor.linear then descriptor.linear.lineCount else 1
			if horizontal then
				maxWidth, maxHeight = headWidth * 0.32, math.max(3, lineCount * 3)
			else
				maxWidth, maxHeight = math.max(3, lineCount * 3), headHeight * 0.28
			end
		end
		local scale = math.min(1, maxWidth / math.max(1, width), maxHeight / math.max(1, height))
		if scale >= 1 then return bounds end
		local newWidth, newHeight = math.max(3, math.floor(width * scale + 0.5)), math.max(3, math.floor(height * scale + 0.5))
		local centerX, centerY = (bounds.minX + bounds.maxX) * 0.5, (bounds.minY + bounds.maxY) * 0.5
		local minX, minY = math.floor(centerX - newWidth * 0.5 + 0.5), math.floor(centerY - newHeight * 0.5 + 0.5)
		return { minX = minX, minY = minY, maxX = minX + newWidth - 1, maxY = minY + newHeight - 1 }
	end
	drawBounds(diagnostics.safeCanvas, safeCanvas.bounds, Color3.fromRGB(86, 225, 152))
	local fullHairMask = Raster.UnionMasks(masks.backHair, masks.frontHair, targetSize)
	local safeAdjustments, preventedPixels = 0, 0
	local visibleTotal, minimumVisible = 0, 1
	local preClipHoles, finalHoles, holesLostDuringClipping = 0, 0, 0
	local finalAspectTotal, maximumFinalAspectError, attachmentTotal = 0, 0, 0
	local linearCount, stackedLinearCount = 0, 0
	local recoveredByTranslation, recoveredByScaling, recoveredByTemplate, recoveredByFallback = 0, 0, 0, 0
	local rejectedAfterFinalValidation = 0
	for _, layout in layouts do
		local accessory = layout.accessory
		local descriptor = layout.descriptor
		local bounds = constrainBounds(layout.bounds, descriptor)
		drawBounds(diagnostics.boundsBeforeFit, bounds, Color3.fromRGB(255, 91, 109))
		local fit = Accessory.FitBoundsInsideSafeCanvas(bounds, safeCanvas)
		bounds = fit.fittedBounds
		drawBounds(diagnostics.boundsAfterFit, bounds, Color3.fromRGB(83, 177, 255))
		if fit.translatedPixels > 0 then safeAdjustments += 1; recoveredByTranslation += 1 end
		if fit.scaleReduction > 0 then safeAdjustments += 1; recoveredByScaling += 1 end
		preventedPixels += fit.offCanvasPixelsPrevented
		if fit.scaleReduction > 0.35 then rejectedAfterFinalValidation += 1; continue end
		if descriptor.geometryKind == "Linear" then linearCount += 1
		elseif descriptor.geometryKind == "StackedLinear" then stackedLinearCount += 1 end
		local area = boundsPixelArea(bounds)
		local isFront = accessory.depth == "Front"
		if not accessory.pairId
			and (usedArea + area > totalBudget or isFront and usedFrontArea + area > frontBudget) then
			rejected += 1
			continue
		end
		local collided = false
		for _, occupied in acceptedBounds do
			if boundsOverlap(bounds, occupied) / math.max(1, math.min(area, boundsPixelArea(occupied))) > 0.4 then
				collided = true
				break
			end
		end
		if collided and not accessory.pairId then
			collisions += 1
			local shift = if (bounds.minX + bounds.maxX) / 2 < (headBounds.minX + headBounds.maxX) / 2 then -4 else 4
			bounds = { minX = bounds.minX + shift, maxX = bounds.maxX + shift, minY = bounds.minY, maxY = bounds.maxY }
			for _, occupied in acceptedBounds do
				if boundsOverlap(bounds, occupied) / math.max(1, math.min(area, boundsPixelArea(occupied))) > 0.4 then
					rejected += 1
					collided = true
					break
				else collided = false end
			end
			if collided then continue end
		end
		local rendered = Accessory.Render(descriptor, targetSize, bounds)
		Raster.CompositeBufferSourceOver(diagnostics.beforeFinalValidation, rendered.pixels, targetSize)
		local renderedMask = alphaMask(rendered.pixels, targetSize)
		local protectedOverlapMask = Raster.IntersectMasks(renderedMask, masks.protectedFacialFeaturesMask, targetSize)
		local protectedOverlap = Raster.CountMaskPixels(protectedOverlapMask, targetSize)
		if protectedOverlap > 0 then
			local outward = if (bounds.minX + bounds.maxX) * 0.5 < (headBounds.minX + headBounds.maxX) * 0.5 then -protectedOverlap else protectedOverlap
			local shifted = {
				minX = bounds.minX + math.clamp(outward, -4, 4), maxX = bounds.maxX + math.clamp(outward, -4, 4),
				minY = bounds.minY - 2, maxY = bounds.maxY - 2,
			}
			local retryFit = Accessory.FitBoundsInsideSafeCanvas(shifted, safeCanvas)
			bounds = retryFit.fittedBounds
			rendered = Accessory.Render(descriptor, targetSize, bounds)
			renderedMask = alphaMask(rendered.pixels, targetSize)
			protectedOverlapMask = Raster.IntersectMasks(renderedMask, masks.protectedFacialFeaturesMask, targetSize)
			protectedOverlap = Raster.CountMaskPixels(protectedOverlapMask, targetSize)
			recoveredByTranslation += 1
		end
		Raster.CompositeBufferSourceOver(diagnostics.protectedFaceOverlap, protectedOverlapMask, targetSize)
		if protectedOverlap > 0 then rejectedAfterFinalValidation += 1; continue end
		local attachmentMask = Raster.IntersectMasks(renderedMask, fullHairMask, targetSize)
		local attachment = Raster.CountMaskPixels(attachmentMask, targetSize) / math.max(1, rendered.occupiedPixels)
		local minimumAttachment = if descriptor.geometryKind == "Linear" or descriptor.geometryKind == "StackedLinear"
			then 0.035
			else 0.075
		local attachmentAttempts = 0
		while attachment < minimumAttachment and attachmentAttempts < 12 do
			attachmentAttempts += 1
			local centerX, centerY = (bounds.minX + bounds.maxX) * 0.5, (bounds.minY + bounds.maxY) * 0.5
			local targetX = math.clamp(centerX, headBounds.minX + 2, headBounds.maxX - 2)
			local targetY = math.clamp(centerY, headBounds.minY + 2, headBounds.maxY - 2)
			if descriptor.geometryKind == "PointedTop" then targetY = headBounds.minY + (headBounds.maxY - headBounds.minY) * 0.18 end
			local dx = math.clamp(targetX - centerX, -3, 3)
			local dy = math.clamp(targetY - centerY, -3, 3)
			if math.abs(dx) < 0.5 and math.abs(dy) < 0.5 then break end
			bounds = Accessory.FitBoundsInsideSafeCanvas({
				minX = bounds.minX + dx, maxX = bounds.maxX + dx,
				minY = bounds.minY + dy, maxY = bounds.maxY + dy,
			}, safeCanvas).fittedBounds
			rendered = Accessory.Render(descriptor, targetSize, bounds)
			renderedMask = alphaMask(rendered.pixels, targetSize)
			attachmentMask = Raster.IntersectMasks(renderedMask, fullHairMask, targetSize)
			attachment = Raster.CountMaskPixels(attachmentMask, targetSize) / math.max(1, rendered.occupiedPixels)
		end
		if attachmentAttempts > 0 then recoveredByTranslation += 1 end
		protectedOverlapMask = Raster.IntersectMasks(renderedMask, masks.protectedFacialFeaturesMask, targetSize)
		protectedOverlap = Raster.CountMaskPixels(protectedOverlapMask, targetSize)
		if protectedOverlap > 0 or attachment < minimumAttachment then
			rejectedAfterFinalValidation += 1
			continue
		end
		Raster.CompositeBufferSourceOver(diagnostics.hairAttachment, attachmentMask, targetSize)
		Raster.CompositeBufferSourceOver(diagnostics.afterFinalValidation, rendered.pixels, targetSize)
		Raster.CompositeBufferSourceOver(diagnostics.postClipHoles, rendered.holes, targetSize)
		Raster.CompositeBufferSourceOver(diagnostics.postClipTopology, rendered.pixels, targetSize)
		Raster.CompositeBufferSourceOver(diagnostics.templateLandmarks, rendered.templateLandmarks, targetSize)
		Raster.CompositeBufferSourceOver(diagnostics.templateResult, rendered.templateResult, targetSize)
		local kindColor = if descriptor.geometryKind == "PointedTop" then Color3.fromRGB(255, 196, 64)
			elseif descriptor.geometryKind == "SideShell" then Color3.fromRGB(78, 188, 255)
			elseif descriptor.geometryKind == "Linear" then Color3.fromRGB(255, 91, 167)
			elseif descriptor.geometryKind == "StackedLinear" then Color3.fromRGB(190, 91, 255)
			elseif descriptor.geometryKind == "Compact" then Color3.fromRGB(88, 226, 137)
			else Color3.fromRGB(245, 245, 245)
		local kindLayer = buffer.create(buffer.len(rendered.pixels))
		fillMask(kindLayer, targetSize, renderedMask, kindColor)
		Raster.CompositeBufferSourceOver(diagnostics.geometryKinds, kindLayer, targetSize)
		if descriptor.linear then Raster.CompositeBufferSourceOver(diagnostics.linearDescriptors, kindLayer, targetSize) end
		local visibleRatio = Raster.CountMaskPixels(renderedMask, targetSize) / math.max(1, rendered.occupiedPixels)
		visibleTotal += visibleRatio; minimumVisible = math.min(minimumVisible, visibleRatio)
		preClipHoles += descriptor.holeCount
		finalHoles += rendered.preservedHoles
		-- No late clipping is performed; losses reported by Render belong to
		-- layout/downsampling, never to final layer clipping.
		finalAspectTotal += rendered.aspectError
		maximumFinalAspectError = math.max(maximumFinalAspectError, rendered.aspectError)
		attachmentTotal += attachment
		if descriptor.renderMode == "TemplateAssisted" then recoveredByTemplate += 1
		elseif descriptor.renderMode == "PrimitiveFallback" then recoveredByFallback += 1 end
		modeCounts[descriptor.renderMode] += 1
		holes += rendered.preservedHoles
		lostHoles += rendered.lostHoles
		sourceColors += descriptor.sourceColorCount
		finalColors += rendered.finalColorCount
		aspectErrorTotal += rendered.aspectError
		for key, diagnostic in diagnostics do
			local sourceDiagnostic = if key == "shapeOccupancy" then rendered.occupancy
				elseif key == "contours" then rendered.contours
				elseif key == "holes" then rendered.holes
				elseif key == "colorRoles" then rendered.colorRoles
				elseif key == "renderModes" then rendered.renderMode
				elseif key == "finalLayout" then rendered.pixels
				elseif key == "shapePreserving" and descriptor.renderMode == "ShapePreserving" then rendered.pixels
				elseif key == "templateAssisted" and descriptor.renderMode == "TemplateAssisted" then rendered.pixels
				elseif key == "primitiveFallback" and descriptor.renderMode == "PrimitiveFallback" then rendered.pixels
				else nil
			if sourceDiagnostic then Raster.CompositeBufferSourceOver(diagnostic, sourceDiagnostic, targetSize) end
		end
		if accessory.depth == "Side" then
			Raster.CompositeBufferSourceOver(sideBackTarget, rendered.pixels, targetSize)
			Raster.CompositeBufferSourceOver(sideFrontTarget, rendered.frontDetails, targetSize)
		elseif accessory.depth == "Back" then
			Raster.CompositeBufferSourceOver(backTarget, rendered.pixels, targetSize)
		else
			Raster.CompositeBufferSourceOver(frontTarget, rendered.pixels, targetSize)
		end
		local projection = {
			occupiedPixels = rendered.occupiedPixels,
			fillRatio = rendered.occupiedPixels / math.max(1, area),
			repairedPixels = 0,
			clippedPixels = 0,
		}
		if rendered.occupiedPixels > 0 then projected += 1 end
		fillTotal += projection.fillRatio
		usedArea += rendered.occupiedPixels
		sourceUsedArea += accessory.area
		if isFront then usedFrontArea += projection.occupiedPixels end
		maximumArea = math.max(maximumArea, rendered.occupiedPixels)
		table.insert(acceptedBounds, bounds)
		if accessory.pairId then
			local metric = pairMetrics[accessory.pairId] or {
				leftHeight = 0, rightHeight = 0, leftScale = 0, rightScale = 0,
				leftBottom = 0, rightBottom = 0, projectedPixelsLeft = 0, projectedPixelsRight = 0,
				leftZone = "", rightZone = "", leftKind = "", rightKind = "",
			}
			if string.find(accessory.anchor, "Left", 1, true) then
				metric.leftHeight = bounds.maxY - bounds.minY + 1
				metric.leftScale = layout.scale
				metric.leftBottom = bounds.maxY
				metric.projectedPixelsLeft = projection.occupiedPixels
				metric.leftZone = accessory.zone
				metric.leftKind = accessory.kind
			else
				metric.rightHeight = bounds.maxY - bounds.minY + 1
				metric.rightScale = layout.scale
				metric.rightBottom = bounds.maxY
				metric.projectedPixelsRight = projection.occupiedPixels
				metric.rightZone = accessory.zone
				metric.rightKind = accessory.kind
			end
			pairMetrics[accessory.pairId] = metric
		end
	end
	for _, metric in pairMetrics do
		metric.heightRatio = math.max(metric.leftHeight, metric.rightHeight) / math.max(1, math.min(metric.leftHeight, metric.rightHeight))
		metric.scaleRatio = math.max(metric.leftScale, metric.rightScale) / math.max(0.001, math.min(metric.leftScale, metric.rightScale))
		metric.verticalOffset = math.abs(metric.leftBottom - metric.rightBottom)
	end
	return {
		projected = projected,
		averageFillRatio = fillTotal / math.max(1, projected),
		repaired = repaired,
		clipped = clipped,
		pairMetrics = pairMetrics,
		sourceCoverage = sourceUsedArea / math.max(1, sourceArea),
		targetCoverage = usedArea / math.max(1, headArea),
		maximumArea = maximumArea,
		collisions = collisions,
		rejected = rejected,
		simplifiedColors = finalColors,
		holes = holes,
		lostHoles = lostHoles,
		shapePreservingCount = modeCounts.ShapePreserving,
		templateAssistedCount = modeCounts.TemplateAssisted,
		primitiveFallbackCount = modeCounts.PrimitiveFallback,
		averageAspectError = aspectErrorTotal / math.max(1, projected),
		sourceColors = sourceColors,
		finalColors = finalColors,
		diagnostics = diagnostics,
		safeCanvasAdjustments = safeAdjustments,
		offCanvasPixelsPrevented = preventedPixels,
		averageVisibleRatio = visibleTotal / math.max(1, projected),
		minimumVisibleRatio = if projected > 0 then minimumVisible else 0,
		preClipHoles = preClipHoles,
		finalHoles = finalHoles,
		holesLostDuringClipping = holesLostDuringClipping,
		averageFinalAspectError = finalAspectTotal / math.max(1, projected),
		maximumFinalAspectError = maximumFinalAspectError,
		averageHairAttachmentRatio = attachmentTotal / math.max(1, projected),
		linearAccessoryCount = linearCount,
		stackedLinearAccessoryCount = stackedLinearCount,
		recoveredByTranslation = recoveredByTranslation,
		recoveredByScaling = recoveredByScaling,
		recoveredByTemplate = recoveredByTemplate,
		recoveredByFallback = recoveredByFallback,
		rejectedAfterFinalValidation = rejectedAfterFinalValidation,
	}
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

local function cleanSmallComponents(pixels: buffer, size: Vector2)
	local width = math.floor(size.X)
	local mask = alphaMask(pixels, size)
	for _, component in Raster.ConnectedComponents(mask, size, nil, 1, 8) do
		if component.area > 2 then continue end
		for _, pixel in component.pixels do
			local pixelOffset = offset(width, pixel.x, pixel.y)
			buffer.writeu32(pixels, pixelOffset, 0)
		end
	end
end

local function paintHairMasses(
	size: Vector2,
	headBounds: Bounds,
	masks: { [string]: buffer },
	hair: Face.HairColors,
	backHair: buffer,
	frontHair: buffer
): (buffer, number, number, number, number)
	local masses = buffer.create(buffer.len(backHair))
	local headWidth = headBounds.maxX - headBounds.minX + 1
	local headHeight = headBounds.maxY - headBounds.minY + 1
	local secondaryCount, highlightCount, shadowCount = 0, 0, 0
	local descriptors = hair.massDescriptors or {}
	for _, descriptor in descriptors do
		if descriptor.label == "Primary" or descriptor.confidence < 0.28 then continue end
		if descriptor.label == "Secondary" and (not hair.secondaryReliable or secondaryCount >= 2) then continue end
		if descriptor.label == "Secondary" and descriptor.side == "Left"
			and (hair.leftTipSecondaryCoverage or 0) < 0.015 then continue end
		if descriptor.label == "Secondary" and descriptor.side == "Right"
			and (hair.rightTipSecondaryCoverage or 0) < 0.015 then continue end
		if descriptor.label == "Highlight" and highlightCount >= 2 then continue end
		if descriptor.label == "Shadow" and shadowCount >= 3 then continue end
		local shape = buffer.create(buffer.len(backHair))
		local bounds = descriptor.bounds
		local center = Vector2.new(
			headBounds.minX + (bounds.minU + bounds.maxU) * 0.5 * headWidth,
			headBounds.minY + (bounds.minV + bounds.maxV) * 0.5 * headHeight
		)
		local radius = Vector2.new(
			math.max(2, (bounds.maxU - bounds.minU) * headWidth * 0.58),
			math.max(2, (bounds.maxV - bounds.minV) * headHeight * 0.58)
		)
		local direction = Vector2.new(math.cos(descriptor.orientation), math.sin(descriptor.orientation))
		local length = math.max(radius.X, radius.Y)
		local thickness = math.max(1.5, math.min(radius.X, radius.Y) * 0.72)
		if descriptor.zone == "Crown" then
			Raster.FillRoundedPolygon(shape, size, {
				center - direction * length,
				center - direction * length * 0.25 + Vector2.new(0, -thickness),
				center + direction * length,
				center + direction * length * 0.25 + Vector2.new(0, thickness),
			}, math.max(1, thickness * 0.35))
		else
			Raster.FillCapsule(shape, size, center - direction * length, center + direction * length, thickness)
		end
		local targetMask = if descriptor.zone == "Fringe" then masks.frontHair else masks.backHair
		shape = Raster.IntersectMasks(shape, targetMask, size)
		local layer = buffer.create(buffer.len(backHair))
		local color = if descriptor.label == "Secondary" then hair.secondary
			elseif descriptor.label == "Highlight" then hair.highlight
			else hair.shadow
		fillMask(layer, size, shape, color)
		Raster.CompositeBufferSourceOver(masses, layer, size)
		if descriptor.zone == "Fringe" then
			Raster.CompositeBufferSourceOver(frontHair, layer, size)
		else
			Raster.CompositeBufferSourceOver(backHair, layer, size)
		end
		if descriptor.label == "Secondary" then secondaryCount += 1
		elseif descriptor.label == "Highlight" then highlightCount += 1
		else shadowCount += 1 end
	end
	if highlightCount == 0 then
		local highlightShape = buffer.create(buffer.len(backHair))
		Raster.FillEllipse(
			highlightShape, size,
			Vector2.new(headBounds.minX + headWidth * 0.48, headBounds.minY + headHeight * 0.23),
			Vector2.new(headWidth * 0.2, headHeight * 0.08)
		)
		highlightShape = Raster.IntersectMasks(highlightShape, masks.backHair, size)
		local highlightLayer = buffer.create(buffer.len(backHair))
		fillMask(highlightLayer, size, highlightShape, hair.highlight)
		Raster.CompositeBufferSourceOver(backHair, highlightLayer, size)
		Raster.CompositeBufferSourceOver(masses, highlightLayer, size)
		highlightCount = 1
	end

	local fallbackShadowMasks = {
		Raster.IntersectMasks(
		masks.backHair,
		rectangleMask(size, {
			minX = headBounds.minX,
			maxX = headBounds.maxX,
			minY = headBounds.minY + math.floor(headHeight * 0.78),
			maxY = headBounds.maxY,
		}),
		size
		),
		Raster.IntersectMasks(
		masks.frontHair,
		rectangleMask(size, {
			minX = headBounds.minX + math.floor(headWidth * 0.17),
			maxX = headBounds.maxX - math.floor(headWidth * 0.17),
			minY = headBounds.minY + math.floor(headHeight * 0.55),
			maxY = headBounds.minY + math.floor(headHeight * 0.68),
		}),
		size
		),
	}
	for index, shadowMask in fallbackShadowMasks do
		if shadowCount >= 2 then break end
		local shadowLayer = buffer.create(buffer.len(backHair))
		fillMask(shadowLayer, size, shadowMask, hair.shadow)
		Raster.CompositeBufferSourceOver(masses, shadowLayer, size)
		if index == 1 then
			Raster.CompositeBufferSourceOver(backHair, shadowLayer, size)
		else
			Raster.CompositeBufferSourceOver(frontHair, shadowLayer, size)
		end
		shadowCount += 1
	end
	return masses, 1 + secondaryCount + highlightCount + shadowCount,
		highlightCount, shadowCount, secondaryCount
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

	-- Label observations remain diagnostic input only. Final hair is rebuilt
	-- from a small set of canonical color masses.
	local fullHairMask = Raster.UnionMasks(masks.backHair, masks.frontHair, size)
	local hairLabelMapRaw = mapSourceBufferToHead(
		hair.rawLabelMap, sourceSize, sourceBounds, size, headBounds, fullHairMask
	)
	local hairLabelMap = mapSourceBufferToHead(
		hair.labelMap, sourceSize, sourceBounds, size, headBounds, fullHairMask
	)
	local hairColorMasses, hairMassCount, highlightMassCount, shadowMassCount, secondaryMassCount =
		paintHairMasses(size, headBounds, masks, hair, backHair, frontHair)
	local hairCore = mapSourceBufferToHead(
		hair.hairCoreMask, sourceSize, sourceBounds, size, headBounds, fullHairMask
	)

	local backAccessories = buffer.create(buffer.len(backHair))
	local sideBackAccessories = buffer.create(buffer.len(backHair))
	local sideFrontAccessories = buffer.create(buffer.len(backHair))
	local frontAccessories = buffer.create(buffer.len(backHair))
	local accessoryProjection =
		projectAccessoriesStructured(
			analysis,
			size,
			headBounds,
			masks,
			backAccessories,
			sideBackAccessories,
			sideFrontAccessories,
			frontAccessories
		)
	local accessoryCompositeBeforeClipping = buffer.create(buffer.len(backHair))
	for _, layer in { backAccessories, sideBackAccessories, sideFrontAccessories, frontAccessories } do
		Raster.CompositeBufferSourceOver(accessoryCompositeBeforeClipping, layer, size)
	end
	-- Placement validation above protects the face and safe canvas before
	-- rasterization; late hair clipping would destroy holes and silhouettes.
	for _, layer in { backAccessories, sideBackAccessories, sideFrontAccessories, frontAccessories } do
		cleanSmallComponents(layer, size)
	end
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
	local coreSeedsDiagnostic = mapSourceBufferToHead(
		analysis.rawCandidateMask, sourceSize, sourceBounds, size, headBounds, nil
	)
	local supportDiagnostic = mapSourceBufferToHead(
		analysis.supportMask, sourceSize, sourceBounds, size, headBounds, nil
	)
	local completedDiagnostic = mapSourceBufferToHead(
		analysis.completedClusterMask, sourceSize, sourceBounds, size, headBounds, nil
	)
	local recoveredSkinDiagnostic = mapSourceBufferToHead(
		analysis.recoveredSkinLikeMask, sourceSize, sourceBounds, size, headBounds, nil
	)
	local recoveredHairDiagnostic = mapSourceBufferToHead(
		analysis.recoveredHairLikeMask, sourceSize, sourceBounds, size, headBounds, nil
	)
	local clusterBoundsDiagnostic = mapSourceBufferToHead(
		analysis.clusterBoundsMask, sourceSize, sourceBounds, size, headBounds, nil
	)
	local anchorDiagnostic = diagnosticMasks(size, masks)
	local accessoryCompositeAfterClipping = buffer.create(buffer.len(backHair))
	Raster.CompositeBufferSourceOver(accessoryCompositeAfterClipping, accessories, size)
	local hairMassDescriptors = buffer.create(buffer.len(hairColorMasses))
	for _, descriptor in hair.massDescriptors or {} do
		local color = if descriptor.label == "Primary" then hair.primary
			elseif descriptor.label == "Secondary" then hair.secondary
			elseif descriptor.label == "Highlight" then hair.highlight
			else hair.shadow
		local bounds = descriptor.bounds
		local left = headBounds.minX + bounds.minU * (headBounds.maxX - headBounds.minX + 1)
		local right = headBounds.minX + bounds.maxU * (headBounds.maxX - headBounds.minX + 1)
		local top = headBounds.minY + bounds.minV * (headBounds.maxY - headBounds.minY + 1)
		local bottom = headBounds.minY + bounds.maxV * (headBounds.maxY - headBounds.minY + 1)
		Raster.DrawLine(hairMassDescriptors, size, Vector2.new(left, top), Vector2.new(right, top), color)
		Raster.DrawLine(hairMassDescriptors, size, Vector2.new(right, top), Vector2.new(right, bottom), color)
		Raster.DrawLine(hairMassDescriptors, size, Vector2.new(right, bottom), Vector2.new(left, bottom), color)
		Raster.DrawLine(hairMassDescriptors, size, Vector2.new(left, bottom), Vector2.new(left, top), color)
	end
	local coverageBudget = buffer.create(buffer.len(backHair))
	fillMask(
		coverageBudget,
		size,
		Raster.UnionMasks(masks.frontAccessoryAllowed, masks.sideAccessoryAllowed, size),
		Color3.fromRGB(38, 49, 64)
	)
	Raster.CompositeBufferSourceOver(coverageBudget, accessoryCompositeAfterClipping, size)
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
		hairColorMasses = hairColorMasses,
		hairMassDescriptors = hairMassDescriptors,
		accessoryCandidates = mergedDiagnostic,
		accessoryRawCandidates = rawDiagnostic,
		accessoryMergedGroups = mergedDiagnostic,
		accessoryAnchors = anchorDiagnostic,
		accessorySelectedPerZone = accessoryCompositeBeforeClipping,
		accessoryPairLayout = sideAccessories,
		accessoryCompositeBeforeClipping = accessoryCompositeBeforeClipping,
		accessoryCompositeAfterClipping = accessoryCompositeAfterClipping,
		accessoryRelativeScale = frontAccessories,
		accessoryTargetLayout = accessories,
		accessorySimplified = accessoryCompositeBeforeClipping,
		accessoryCoverageBudget = coverageBudget,
		accessoryShapeOccupancy = accessoryProjection.diagnostics.shapeOccupancy,
		accessoryContours = accessoryProjection.diagnostics.contours,
		accessoryHoles = accessoryProjection.diagnostics.holes,
		accessoryColorRoles = accessoryProjection.diagnostics.colorRoles,
		accessoryRenderModes = accessoryProjection.diagnostics.renderModes,
		accessoryShapePreserving = accessoryProjection.diagnostics.shapePreserving,
		accessoryTemplateAssisted = accessoryProjection.diagnostics.templateAssisted,
		accessoryPrimitiveFallback = accessoryProjection.diagnostics.primitiveFallback,
		accessoryFinalLayout = accessoryProjection.diagnostics.finalLayout,
		accessoryCoreSeeds = coreSeedsDiagnostic,
		accessorySupportMask = supportDiagnostic,
		accessoryCompletedClusters = completedDiagnostic,
		accessoryRecoveredSkinLike = recoveredSkinDiagnostic,
		accessoryRecoveredHairLike = recoveredHairDiagnostic,
		accessoryClusterBounds = clusterBoundsDiagnostic,
		accessoryGeometryKinds = accessoryProjection.diagnostics.geometryKinds,
		accessoryLinearDescriptors = accessoryProjection.diagnostics.linearDescriptors,
		accessorySafeCanvas = accessoryProjection.diagnostics.safeCanvas,
		accessoryBoundsBeforeFit = accessoryProjection.diagnostics.boundsBeforeFit,
		accessoryBoundsAfterFit = accessoryProjection.diagnostics.boundsAfterFit,
		accessoryHairAttachment = accessoryProjection.diagnostics.hairAttachment,
		accessoryProtectedFaceOverlap = accessoryProjection.diagnostics.protectedFaceOverlap,
		accessoryBeforeFinalValidation = accessoryProjection.diagnostics.beforeFinalValidation,
		accessoryAfterFinalValidation = accessoryProjection.diagnostics.afterFinalValidation,
		accessoryPostClipHoles = accessoryProjection.diagnostics.postClipHoles,
		accessoryPostClipTopology = accessoryProjection.diagnostics.postClipTopology,
		templateAssistedLandmarks = accessoryProjection.diagnostics.templateLandmarks,
		templateAssistedResult = accessoryProjection.diagnostics.templateResult,
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
			projectedComponents = accessoryProjection.projected,
			averageFillRatio = accessoryProjection.averageFillRatio,
			repairedPixels = accessoryProjection.repaired,
			clippedPixels = accessoryProjection.clipped,
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
			accessorySourceCoverage = accessoryProjection.sourceCoverage,
			accessoryTargetCoverage = accessoryProjection.targetCoverage,
			maximumAccessoryArea = accessoryProjection.maximumArea,
			targetCollisionCount = accessoryProjection.collisions,
			targetRejectedCount = accessoryProjection.rejected,
			simplifiedAccessoryColors = accessoryProjection.simplifiedColors,
			preservedAccessoryHoles = accessoryProjection.holes,
			lostAccessoryHoles = accessoryProjection.lostHoles,
			shapePreservingCount = accessoryProjection.shapePreservingCount,
			templateAssistedCount = accessoryProjection.templateAssistedCount,
			primitiveFallbackCount = accessoryProjection.primitiveFallbackCount,
			averageAccessoryAspectError = accessoryProjection.averageAspectError,
			simplifiedSourceColors = accessoryProjection.sourceColors,
			simplifiedFinalColors = accessoryProjection.finalColors,
			rawCoreComponents = analysis.metrics.rawCoreComponents,
			completedClusters = analysis.metrics.completedClusters,
			recoveredSupportPixels = analysis.metrics.recoveredSupportPixels,
			recoveredSkinLikePixels = analysis.metrics.recoveredSkinLikePixels,
			recoveredHairLikePixels = analysis.metrics.recoveredHairLikePixels,
			rejectedLeakPixels = analysis.metrics.rejectedLeakPixels,
			linearAccessoryCount = accessoryProjection.linearAccessoryCount,
			stackedLinearAccessoryCount = accessoryProjection.stackedLinearAccessoryCount,
			safeCanvasAdjustments = accessoryProjection.safeCanvasAdjustments,
			offCanvasPixelsPrevented = accessoryProjection.offCanvasPixelsPrevented,
			averageVisibleRatio = accessoryProjection.averageVisibleRatio,
			minimumVisibleRatio = accessoryProjection.minimumVisibleRatio,
			preClipHoles = accessoryProjection.preClipHoles,
			finalHoles = accessoryProjection.finalHoles,
			holesLostDuringClipping = accessoryProjection.holesLostDuringClipping,
			averageFinalAspectError = accessoryProjection.averageFinalAspectError,
			maximumFinalAspectError = accessoryProjection.maximumFinalAspectError,
			averageHairAttachmentRatio = accessoryProjection.averageHairAttachmentRatio,
			recoveredByTranslation = accessoryProjection.recoveredByTranslation,
			recoveredByScaling = accessoryProjection.recoveredByScaling,
			recoveredByTemplate = accessoryProjection.recoveredByTemplate,
			recoveredByFallback = accessoryProjection.recoveredByFallback,
			rejectedAfterFinalValidation = accessoryProjection.rejectedAfterFinalValidation,
			hairMassCount = hairMassCount,
			highlightMassCount = highlightMassCount,
			shadowMassCount = shadowMassCount,
			secondaryMassCount = secondaryMassCount,
			strandLineCount = 6,
			rawIsolatedHighlightPixels = hair.rawIsolatedHighlightPixels,
			rawIsolatedSecondaryPixels = hair.rawIsolatedSecondaryPixels,
			remainingIsolatedHighlightPixels = hair.remainingIsolatedHighlightPixels,
			remainingIsolatedSecondaryPixels = hair.remainingIsolatedSecondaryPixels,
			pairMetrics = accessoryProjection.pairMetrics,
			fallbackPixels = 0,
		},
	}
end

return table.freeze(ProceduralChibiHead)
