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
				scaleRatio = math.max(leftWidth, rightWidth) / math.max(1, math.min(leftWidth, rightWidth)),
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
		local sourceU = (accessory.centroid.X - analysis.sourceBounds.minX)
			/ math.max(1, analysis.sourceBounds.maxX - analysis.sourceBounds.minX)
		local sourceV = (accessory.centroid.Y - analysis.sourceBounds.minY)
			/ math.max(1, analysis.sourceBounds.maxY - analysis.sourceBounds.minY)
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

local function simplifiedComponent(accessory: HeadAnalyzer.AccessoryCandidate): (Raster.ConnectedComponent, number, number)
	local maximumColors = if accessory.kind == "Clip" then 3
		elseif accessory.area < 80 then 4 else 6
	local colors = {}
	for index = 1, math.min(maximumColors, #accessory.colors) do
		table.insert(colors, accessory.colors[index])
	end
	if #colors == 0 then table.insert(colors, Color3.fromRGB(128, 128, 128)) end
	local pixels = {}
	for _, pixel in accessory.component.pixels do
		local bestColor = colors[1]
		local bestDistance = math.huge
		for _, color in colors do
			local red = pixel.r - color.R * 255
			local green = pixel.g - color.G * 255
			local blue = pixel.b - color.B * 255
			local distance = red * red + green * green + blue * blue
			if distance < bestDistance then bestDistance, bestColor = distance, color end
		end
		table.insert(pixels, {
			x = pixel.x, y = pixel.y,
			r = math.round(bestColor.R * 255),
			g = math.round(bestColor.G * 255),
			b = math.round(bestColor.B * 255),
			a = pixel.a,
		})
	end
	local occupied: { [number]: boolean } = {}
	local componentWidth = accessory.bounds.maxX - accessory.bounds.minX + 1
	for _, pixel in accessory.component.pixels do
		occupied[(pixel.y - accessory.bounds.minY) * componentWidth + pixel.x - accessory.bounds.minX] = true
	end
	local exterior: { [number]: boolean } = {}
	local queue = {}
	for localY = 0, accessory.bounds.maxY - accessory.bounds.minY do
		for localX = 0, componentWidth - 1 do
			if localX ~= 0 and localX ~= componentWidth - 1
				and localY ~= 0 and localY ~= accessory.bounds.maxY - accessory.bounds.minY then continue end
			local key = localY * componentWidth + localX
			if not occupied[key] and not exterior[key] then exterior[key] = true table.insert(queue, key) end
		end
	end
	local queueIndex = 1
	while queueIndex <= #queue do
		local key = queue[queueIndex]
		queueIndex += 1
		local localX = key % componentWidth
		local localY = math.floor(key / componentWidth)
		for _, delta in { Vector2.new(-1, 0), Vector2.new(1, 0), Vector2.new(0, -1), Vector2.new(0, 1) } do
			local nextX = localX + delta.X
			local nextY = localY + delta.Y
			local nextKey = nextY * componentWidth + nextX
			if nextX >= 0 and nextY >= 0 and nextX < componentWidth
				and nextY <= accessory.bounds.maxY - accessory.bounds.minY
				and not occupied[nextKey] and not exterior[nextKey] then
				exterior[nextKey] = true
				table.insert(queue, nextKey)
			end
		end
	end
	local holes = 0
	local visitedHoles: { [number]: boolean } = {}
	for localY = 0, accessory.bounds.maxY - accessory.bounds.minY do
		for localX = 0, componentWidth - 1 do
			local key = localY * componentWidth + localX
			if not occupied[key] and not exterior[key] and not visitedHoles[key] then
				holes += 1
				local holeQueue = { key }
				visitedHoles[key] = true
				local holeIndex = 1
				while holeIndex <= #holeQueue do
					local current = holeQueue[holeIndex]
					holeIndex += 1
					local currentX = current % componentWidth
					local currentY = math.floor(current / componentWidth)
					for _, delta in { Vector2.new(-1, 0), Vector2.new(1, 0), Vector2.new(0, -1), Vector2.new(0, 1) } do
						local nextX = currentX + delta.X
						local nextY = currentY + delta.Y
						local nextKey = nextY * componentWidth + nextX
						if nextX >= 0 and nextY >= 0 and nextX < componentWidth
							and nextY <= accessory.bounds.maxY - accessory.bounds.minY
							and not occupied[nextKey] and not exterior[nextKey] and not visitedHoles[nextKey] then
							visitedHoles[nextKey] = true
							table.insert(holeQueue, nextKey)
						end
					end
				end
			end
		end
	end
	return {
		bounds = accessory.component.bounds,
		area = #pixels,
		centroid = accessory.component.centroid,
		pixels = pixels,
	}, #colors, holes
end

local function projectAccessoriesStructured(
	analysis: Analysis,
	targetSize: Vector2,
	headBounds: Bounds,
	backTarget: buffer,
	sideBackTarget: buffer,
	sideFrontTarget: buffer,
	frontTarget: buffer
): { [string]: any }
	local sourceArea = boundsPixelArea(analysis.sourceBounds)
	local headArea = boundsPixelArea(headBounds)
	local totalBudget = headArea * 0.28
	local frontBudget = headArea * 0.18
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
	}
	for _, layout in layouts do
		local accessory = layout.accessory
		local descriptor = layout.descriptor
		local bounds = layout.bounds
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
		Raster.FillEllipse(shape, size, center, radius)
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
