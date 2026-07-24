--!strict

local Raster = require(script.Parent:WaitForChild("ProceduralRaster"))

type Bounds = Raster.Bounds
type Pixel = Raster.ComponentPixel

export type AccessoryRenderMode = "ShapePreserving" | "TemplateAssisted" | "PrimitiveFallback"

export type ColorRegion = {
	mask: buffer,
	color: Color3,
	coverage: number,
	centroid: Vector2,
}

export type AccessoryColorRoles = {
	dominant: Color3,
	outline: Color3,
	shadow: Color3,
	highlight: Color3?,
	accents: { Color3 },
}

export type AccessoryShapeDescriptor = {
	renderMode: AccessoryRenderMode,
	sourceBounds: Bounds,
	sourceAspect: number,
	sourceArea: number,
	relativeArea: number,
	occupancySize: Vector2,
	occupancy: buffer,
	contour: buffer,
	holes: { buffer },
	holeCount: number,
	orientation: number,
	compactness: number,
	bilateralSymmetry: number,
	contourComplexity: number,
	colorRoles: AccessoryColorRoles,
	colorRegions: { ColorRegion },
	confidence: number,
	sourceColorCount: number,
}

export type RenderResult = {
	pixels: buffer,
	frontDetails: buffer,
	occupancy: buffer,
	contours: buffer,
	holes: buffer,
	colorRoles: buffer,
	renderMode: buffer,
	occupiedPixels: number,
	finalColorCount: number,
	preservedHoles: number,
	lostHoles: number,
	aspectError: number,
}

type Candidate = {
	bounds: Bounds,
	area: number,
	centroid: Vector2,
	zone: string,
	kind: string,
	pairId: number?,
	confidence: number,
	colors: { Color3 },
	component: {
		bounds: Bounds,
		area: number,
		centroid: Vector2,
		pixels: { Pixel },
	},
}

type ColorBucket = {
	r: number,
	g: number,
	b: number,
	count: number,
	edge: number,
	interior: number,
	minX: number,
	maxX: number,
	minY: number,
	maxY: number,
}

local ProceduralChibiAccessory = {}

local function offset(width: number, x: number, y: number): number
	return (y * width + x) * 4
end

local function maskAt(mask: buffer, width: number, height: number, x: number, y: number): boolean
	return x >= 0 and y >= 0 and x < width and y < height
		and buffer.readu8(mask, offset(width, x, y) + 3) > 0
end

local function setMask(mask: buffer, width: number, x: number, y: number)
	buffer.writeu8(mask, offset(width, x, y) + 3, 255)
end

local function colorDistance(left: Color3, right: Color3): number
	local red = left.R - right.R
	local green = left.G - right.G
	local blue = left.B - right.B
	return math.sqrt(red * red * 0.3 + green * green * 0.59 + blue * blue * 0.11)
end

local function colorFromBucket(bucket: ColorBucket): Color3
	return Color3.fromRGB(
		math.round(bucket.r / bucket.count),
		math.round(bucket.g / bucket.count),
		math.round(bucket.b / bucket.count)
	)
end

local function chooseGridSize(candidate: Candidate): number
	if candidate.kind == "Clip" and candidate.area < 32 then return 12 end
	if candidate.area < 64 then return 16 end
	if candidate.area < 220 then return 24 end
	return 32
end

local function normalizedOccupancy(candidate: Candidate, gridSize: number): (buffer, { [number]: { Pixel } })
	local occupancy = buffer.create(gridSize * gridSize * 4)
	local samples: { [number]: { Pixel } } = {}
	local sourceWidth = math.max(1, candidate.bounds.maxX - candidate.bounds.minX + 1)
	local sourceHeight = math.max(1, candidate.bounds.maxY - candidate.bounds.minY + 1)
	local scale = math.min((gridSize - 2) / sourceWidth, (gridSize - 2) / sourceHeight)
	local fittedWidth = math.max(1, sourceWidth * scale)
	local fittedHeight = math.max(1, sourceHeight * scale)
	local insetX = (gridSize - fittedWidth) / 2
	local insetY = (gridSize - fittedHeight) / 2
	for _, pixel in candidate.component.pixels do
		if pixel.a < 32 then continue end
		local minX = math.clamp(math.floor(insetX + (pixel.x - candidate.bounds.minX) * scale), 0, gridSize - 1)
		local maxX = math.clamp(math.ceil(insetX + (pixel.x - candidate.bounds.minX + 1) * scale) - 1, 0, gridSize - 1)
		local minY = math.clamp(math.floor(insetY + (pixel.y - candidate.bounds.minY) * scale), 0, gridSize - 1)
		local maxY = math.clamp(math.ceil(insetY + (pixel.y - candidate.bounds.minY + 1) * scale) - 1, 0, gridSize - 1)
		for y = minY, maxY do
			for x = minX, maxX do
				setMask(occupancy, gridSize, x, y)
				local key = y * gridSize + x
				samples[key] = samples[key] or {}
				table.insert(samples[key], pixel)
			end
		end
	end
	-- Only remove genuinely isolated one-cell observations.
	for _, component in Raster.ConnectedComponents(occupancy, Vector2.new(gridSize, gridSize), nil, 1, 8) do
		if component.area > 1 then continue end
		for _, pixel in component.pixels do
			buffer.writeu8(occupancy, offset(gridSize, pixel.x, pixel.y) + 3, 0)
			samples[pixel.y * gridSize + pixel.x] = nil
		end
	end
	return occupancy, samples
end

local function contourMask(occupancy: buffer, gridSize: number): buffer
	local contour = buffer.create(buffer.len(occupancy))
	for y = 0, gridSize - 1 do
		for x = 0, gridSize - 1 do
			if not maskAt(occupancy, gridSize, gridSize, x, y) then continue end
			for _, delta in {
				Vector2.new(-1, 0), Vector2.new(1, 0),
				Vector2.new(0, -1), Vector2.new(0, 1),
			} do
				if not maskAt(occupancy, gridSize, gridSize, x + delta.X, y + delta.Y) then
					setMask(contour, gridSize, x, y)
					break
				end
			end
		end
	end
	return contour
end

local function holeMasks(occupancy: buffer, gridSize: number): { buffer }
	local exterior: { [number]: boolean } = {}
	local queue = {}
	for y = 0, gridSize - 1 do
		for x = 0, gridSize - 1 do
			if x ~= 0 and y ~= 0 and x ~= gridSize - 1 and y ~= gridSize - 1 then continue end
			local key = y * gridSize + x
			if not maskAt(occupancy, gridSize, gridSize, x, y) and not exterior[key] then
				exterior[key] = true
				table.insert(queue, key)
			end
		end
	end
	local index = 1
	while index <= #queue do
		local key = queue[index]
		index += 1
		local x, y = key % gridSize, math.floor(key / gridSize)
		for _, delta in {
			Vector2.new(-1, 0), Vector2.new(1, 0),
			Vector2.new(0, -1), Vector2.new(0, 1),
		} do
			local nextX, nextY = x + delta.X, y + delta.Y
			local nextKey = nextY * gridSize + nextX
			if nextX >= 0 and nextY >= 0 and nextX < gridSize and nextY < gridSize
				and not exterior[nextKey]
				and not maskAt(occupancy, gridSize, gridSize, nextX, nextY) then
				exterior[nextKey] = true
				table.insert(queue, nextKey)
			end
		end
	end
	local visited: { [number]: boolean } = {}
	local holes = {}
	for y = 1, gridSize - 2 do
		for x = 1, gridSize - 2 do
			local key = y * gridSize + x
			if exterior[key] or visited[key] or maskAt(occupancy, gridSize, gridSize, x, y) then continue end
			local hole = buffer.create(buffer.len(occupancy))
			local members = { key }
			visited[key] = true
			local memberIndex = 1
			while memberIndex <= #members do
				local current = members[memberIndex]
				memberIndex += 1
				local currentX, currentY = current % gridSize, math.floor(current / gridSize)
				setMask(hole, gridSize, currentX, currentY)
				for _, delta in {
					Vector2.new(-1, 0), Vector2.new(1, 0),
					Vector2.new(0, -1), Vector2.new(0, 1),
				} do
					local nextX, nextY = currentX + delta.X, currentY + delta.Y
					local nextKey = nextY * gridSize + nextX
					if nextX > 0 and nextY > 0 and nextX < gridSize - 1 and nextY < gridSize - 1
						and not visited[nextKey] and not exterior[nextKey]
						and not maskAt(occupancy, gridSize, gridSize, nextX, nextY) then
						visited[nextKey] = true
						table.insert(members, nextKey)
					end
				end
			end
			if #members >= math.max(1, math.floor(gridSize * gridSize * 0.0025)) then
				table.insert(holes, hole)
			end
		end
	end
	return holes
end

local function colorAnalysis(
	samples: { [number]: { Pixel } },
	contour: buffer,
	gridSize: number,
	occupancyPixels: number
): (AccessoryColorRoles, { ColorRegion }, number)
	local histogram: { [number]: ColorBucket } = {}
	for key, pixels in samples do
		local x, y = key % gridSize, math.floor(key / gridSize)
		for _, pixel in pixels do
			local bucketKey = math.floor(pixel.r / 32) * 64 + math.floor(pixel.g / 32) * 8 + math.floor(pixel.b / 32)
			local bucket = histogram[bucketKey] or {
				r = 0, g = 0, b = 0, count = 0, edge = 0, interior = 0,
				minX = x, maxX = x, minY = y, maxY = y,
			}
			bucket.r += pixel.r
			bucket.g += pixel.g
			bucket.b += pixel.b
			bucket.count += 1
			if buffer.readu8(contour, offset(gridSize, x, y) + 3) > 0 then bucket.edge += 1 else bucket.interior += 1 end
			bucket.minX, bucket.maxX = math.min(bucket.minX, x), math.max(bucket.maxX, x)
			bucket.minY, bucket.maxY = math.min(bucket.minY, y), math.max(bucket.maxY, y)
			histogram[bucketKey] = bucket
		end
	end
	local buckets = {}
	for _, bucket in histogram do table.insert(buckets, bucket) end
	table.sort(buckets, function(left, right) return left.count > right.count end)
	if #buckets == 0 then
		local neutral = Color3.fromRGB(120, 120, 128)
		return { dominant = neutral, outline = neutral:Lerp(Color3.new(), 0.5), shadow = neutral:Lerp(Color3.new(), 0.25), highlight = nil, accents = {} }, {}, 0
	end
	local dominant = colorFromBucket(buckets[1])
	local outlineBucket = buckets[1]
	local outlineScore = -math.huge
	local highlight: Color3? = nil
	local highlightScore = -math.huge
	local accents = {}
	local regions = {}
	for index, bucket in buckets do
		local color = colorFromBucket(bucket)
		local luminance = color.R * 0.3 + color.G * 0.59 + color.B * 0.11
		local edgeRatio = bucket.edge / math.max(1, bucket.count)
		local edgeScore = edgeRatio * 1.4 + (1 - luminance) * 0.7 + math.log(bucket.count + 1) * 0.08
		if edgeScore > outlineScore then outlineScore, outlineBucket = edgeScore, bucket end
		local interiorRatio = bucket.interior / math.max(1, bucket.count)
		local lightScore = luminance * interiorRatio * math.sqrt(bucket.count)
		if interiorRatio > 0.45 and lightScore > highlightScore then highlightScore, highlight = lightScore, color end
		if index > 1 and #accents < 3 and bucket.count / math.max(1, occupancyPixels) >= 0.025
			and colorDistance(color, dominant) >= 0.1 then
			table.insert(accents, color)
		end
		if index <= 5 then
			local regionMask = buffer.create(gridSize * gridSize * 4)
			local sumX, sumY, count = 0, 0, 0
			for key, cellPixels in samples do
				local bestDistance = math.huge
				local average = Color3.fromRGB(cellPixels[1].r, cellPixels[1].g, cellPixels[1].b)
				for _, candidateBucket in buckets do
					local distance = colorDistance(average, colorFromBucket(candidateBucket))
					if distance < bestDistance then bestDistance = distance end
				end
				if colorDistance(average, color) <= bestDistance + 0.001 then
					local x, y = key % gridSize, math.floor(key / gridSize)
					setMask(regionMask, gridSize, x, y)
					sumX, sumY, count = sumX + x, sumY + y, count + 1
				end
			end
			if count > 0 then
				table.insert(regions, {
					mask = regionMask,
					color = color,
					coverage = count / math.max(1, occupancyPixels),
					centroid = Vector2.new(sumX / count, sumY / count),
				})
			end
		end
	end
	local outline = colorFromBucket(outlineBucket)
	local shadow = dominant:Lerp(outline, 0.48)
	return {
		dominant = dominant,
		outline = outline,
		shadow = shadow,
		highlight = if highlight and colorDistance(highlight, dominant) >= 0.07 then highlight else nil,
		accents = accents,
	}, regions, #buckets
end

function ProceduralChibiAccessory.Describe(candidate: Candidate, sourceBounds: Bounds): AccessoryShapeDescriptor
	local gridSize = chooseGridSize(candidate)
	local occupancy, samples = normalizedOccupancy(candidate, gridSize)
	local contour = contourMask(occupancy, gridSize)
	local holes = holeMasks(occupancy, gridSize)
	local occupied = Raster.CountMaskPixels(occupancy, Vector2.new(gridSize, gridSize))
	local contourPixels = Raster.CountMaskPixels(contour, Vector2.new(gridSize, gridSize))
	local sourceWidth = math.max(1, candidate.bounds.maxX - candidate.bounds.minX + 1)
	local sourceHeight = math.max(1, candidate.bounds.maxY - candidate.bounds.minY + 1)
	local sumX, sumY = 0, 0
	for y = 0, gridSize - 1 do
		for x = 0, gridSize - 1 do
			if maskAt(occupancy, gridSize, gridSize, x, y) then sumX, sumY = sumX + x, sumY + y end
		end
	end
	local centerX, centerY = sumX / math.max(1, occupied), sumY / math.max(1, occupied)
	local xx, yy, xy = 0, 0, 0
	local mirroredMatches = 0
	for y = 0, gridSize - 1 do
		for x = 0, gridSize - 1 do
			if not maskAt(occupancy, gridSize, gridSize, x, y) then continue end
			local dx, dy = x - centerX, y - centerY
			xx, yy, xy = xx + dx * dx, yy + dy * dy, xy + dx * dy
			if maskAt(occupancy, gridSize, gridSize, gridSize - 1 - x, y) then mirroredMatches += 1 end
		end
	end
	local roles, regions, sourceColorCount = colorAnalysis(samples, contour, gridSize, occupied)
	local compactness = occupied / math.max(1, gridSize * gridSize)
	local confidence = math.clamp(candidate.confidence * 0.55 + math.min(1, occupied / 24) * 0.25
		+ math.min(1, contourPixels / 18) * 0.1 + math.min(1, #regions / 3) * 0.1, 0, 1)
	local stable = candidate.area >= 4
		and occupied >= 8
		and compactness >= 0.035
		and confidence >= 0.38
	local pairedStructural = candidate.pairId ~= nil
		and (string.find(candidate.zone, "top", 1, true) or string.find(candidate.zone, "side", 1, true))
	local renderMode: AccessoryRenderMode = if not stable then "PrimitiveFallback"
		elseif pairedStructural then "TemplateAssisted"
		else "ShapePreserving"
	return {
		renderMode = renderMode,
		sourceBounds = candidate.bounds,
		sourceAspect = sourceWidth / sourceHeight,
		sourceArea = candidate.area,
		relativeArea = candidate.area / math.max(1,
			(sourceBounds.maxX - sourceBounds.minX + 1) * (sourceBounds.maxY - sourceBounds.minY + 1)),
		occupancySize = Vector2.new(gridSize, gridSize),
		occupancy = occupancy,
		contour = contour,
		holes = holes,
		holeCount = #holes,
		orientation = 0.5 * math.atan2(2 * xy, xx - yy),
		compactness = compactness,
		bilateralSymmetry = mirroredMatches / math.max(1, occupied),
		contourComplexity = contourPixels / math.max(1, occupied),
		colorRoles = roles,
		colorRegions = regions,
		confidence = confidence,
		sourceColorCount = sourceColorCount,
	}
end

local function paintCell(
	target: buffer,
	size: Vector2,
	bounds: Bounds,
	gridSize: number,
	x: number,
	y: number,
	color: Color3
)
	local width, height = math.floor(size.X), math.floor(size.Y)
	local minX = math.floor(bounds.minX + x / gridSize * (bounds.maxX - bounds.minX + 1))
	local maxX = math.ceil(bounds.minX + (x + 1) / gridSize * (bounds.maxX - bounds.minX + 1)) - 1
	local minY = math.floor(bounds.minY + y / gridSize * (bounds.maxY - bounds.minY + 1))
	local maxY = math.ceil(bounds.minY + (y + 1) / gridSize * (bounds.maxY - bounds.minY + 1)) - 1
	local red, green, blue = math.round(color.R * 255), math.round(color.G * 255), math.round(color.B * 255)
	for targetY = math.max(0, minY), math.min(height - 1, maxY) do
		for targetX = math.max(0, minX), math.min(width - 1, maxX) do
			Raster.SourceOverPixel(target, width, height, targetX, targetY, { r = red, g = green, b = blue, a = 255 })
		end
	end
end

local function renderPrimitive(descriptor: AccessoryShapeDescriptor, target: buffer, size: Vector2, bounds: Bounds)
	local mask = buffer.create(buffer.len(target))
	local center = Vector2.new((bounds.minX + bounds.maxX) / 2, (bounds.minY + bounds.maxY) / 2)
	if descriptor.sourceAspect >= 0.72 and descriptor.sourceAspect <= 1.45 then
		Raster.FillPolygon(mask, size, {
			Vector2.new(bounds.minX, bounds.maxY), Vector2.new(center.X, bounds.minY), Vector2.new(bounds.maxX, bounds.maxY),
		})
	else
		Raster.FillEllipse(mask, size, center, Vector2.new(
			(bounds.maxX - bounds.minX + 1) * 0.5, (bounds.maxY - bounds.minY + 1) * 0.5
		))
	end
	local width, height = math.floor(size.X), math.floor(size.Y)
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			if buffer.readu8(mask, offset(width, x, y) + 3) > 0 then
				local color = descriptor.colorRoles.dominant
				local red, green, blue = math.round(color.R * 255), math.round(color.G * 255), math.round(color.B * 255)
				Raster.SourceOverPixel(target, width, height, x, y, { r = red, g = green, b = blue, a = 255 })
			end
		end
	end
end

function ProceduralChibiAccessory.Render(
	descriptor: AccessoryShapeDescriptor,
	size: Vector2,
	bounds: Bounds
): RenderResult
	local pixels = buffer.create(math.floor(size.X) * math.floor(size.Y) * 4)
	local frontDetails = buffer.create(buffer.len(pixels))
	local occupancyDiagnostic = buffer.create(buffer.len(pixels))
	local contourDiagnostic = buffer.create(buffer.len(pixels))
	local holesDiagnostic = buffer.create(buffer.len(pixels))
	local rolesDiagnostic = buffer.create(buffer.len(pixels))
	local modeDiagnostic = buffer.create(buffer.len(pixels))
	local gridSize = math.floor(descriptor.occupancySize.X)
	if descriptor.renderMode == "PrimitiveFallback" then
		renderPrimitive(descriptor, pixels, size, bounds)
	else
		for y = 0, gridSize - 1 do
			for x = 0, gridSize - 1 do
				if not maskAt(descriptor.occupancy, gridSize, gridSize, x, y) then continue end
				local color = descriptor.colorRoles.dominant
				for _, region in descriptor.colorRegions do
					if buffer.readu8(region.mask, offset(gridSize, x, y) + 3) > 0 then
						color = region.color
						break
					end
				end
				if buffer.readu8(descriptor.contour, offset(gridSize, x, y) + 3) > 0 then
					color = descriptor.colorRoles.outline
					paintCell(frontDetails, size, bounds, gridSize, x, y, color)
				elseif colorDistance(color, descriptor.colorRoles.dominant) >= 0.07 then
					paintCell(frontDetails, size, bounds, gridSize, x, y, color)
				end
				paintCell(pixels, size, bounds, gridSize, x, y, color)
				paintCell(occupancyDiagnostic, size, bounds, gridSize, x, y, Color3.fromRGB(235, 235, 235))
				if buffer.readu8(descriptor.contour, offset(gridSize, x, y) + 3) > 0 then
					paintCell(contourDiagnostic, size, bounds, gridSize, x, y, Color3.fromRGB(255, 196, 52))
				end
				paintCell(rolesDiagnostic, size, bounds, gridSize, x, y, color)
			end
		end
	end
	for _, hole in descriptor.holes do
		for y = 0, gridSize - 1 do
			for x = 0, gridSize - 1 do
				if buffer.readu8(hole, offset(gridSize, x, y) + 3) > 0 then
					paintCell(holesDiagnostic, size, bounds, gridSize, x, y, Color3.fromRGB(236, 72, 216))
				end
			end
		end
	end
	local modeColor = if descriptor.renderMode == "ShapePreserving" then Color3.fromRGB(72, 221, 130)
		elseif descriptor.renderMode == "TemplateAssisted" then Color3.fromRGB(83, 165, 255)
		else Color3.fromRGB(255, 96, 82)
	for y = 0, gridSize - 1 do
		for x = 0, gridSize - 1 do
			if maskAt(descriptor.occupancy, gridSize, gridSize, x, y) then
				paintCell(modeDiagnostic, size, bounds, gridSize, x, y, modeColor)
			end
		end
	end
	local renderedAspect = (bounds.maxX - bounds.minX + 1) / math.max(1, bounds.maxY - bounds.minY + 1)
	local renderedOccupancy = buffer.create(gridSize * gridSize * 4)
	local width, height = math.floor(size.X), math.floor(size.Y)
	local targetWidth = math.max(1, bounds.maxX - bounds.minX + 1)
	local targetHeight = math.max(1, bounds.maxY - bounds.minY + 1)
	local renderedColors: { [number]: boolean } = {}
	for y = 0, gridSize - 1 do
		for x = 0, gridSize - 1 do
			local sampleX = math.clamp(
				math.floor(bounds.minX + (x + 0.5) / gridSize * targetWidth),
				0,
				width - 1
			)
			local sampleY = math.clamp(
				math.floor(bounds.minY + (y + 0.5) / gridSize * targetHeight),
				0,
				height - 1
			)
			local pixelOffset = offset(width, sampleX, sampleY)
			if buffer.readu8(pixels, pixelOffset + 3) > 0 then
				setMask(renderedOccupancy, gridSize, x, y)
			end
		end
	end
	for y = math.max(0, bounds.minY), math.min(height - 1, bounds.maxY) do
		for x = math.max(0, bounds.minX), math.min(width - 1, bounds.maxX) do
			local pixelOffset = offset(width, x, y)
			if buffer.readu8(pixels, pixelOffset + 3) == 0 then continue end
			local key = math.floor(buffer.readu8(pixels, pixelOffset) / 8) * 1024
				+ math.floor(buffer.readu8(pixels, pixelOffset + 1) / 8) * 32
				+ math.floor(buffer.readu8(pixels, pixelOffset + 2) / 8)
			renderedColors[key] = true
		end
	end
	local renderedHoleCount = #holeMasks(renderedOccupancy, gridSize)
	local finalColorCount = 0
	for _ in renderedColors do finalColorCount += 1 end
	return {
		pixels = pixels,
		frontDetails = frontDetails,
		occupancy = occupancyDiagnostic,
		contours = contourDiagnostic,
		holes = holesDiagnostic,
		colorRoles = rolesDiagnostic,
		renderMode = modeDiagnostic,
		occupiedPixels = Raster.CountMaskPixels(pixels, size),
		finalColorCount = finalColorCount,
		preservedHoles = math.min(descriptor.holeCount, renderedHoleCount),
		lostHoles = math.max(0, descriptor.holeCount - renderedHoleCount),
		aspectError = math.abs(renderedAspect - descriptor.sourceAspect) / math.max(0.001, descriptor.sourceAspect),
	}
end

return table.freeze(ProceduralChibiAccessory)
