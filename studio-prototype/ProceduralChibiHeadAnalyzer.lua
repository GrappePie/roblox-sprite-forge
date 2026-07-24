--!strict

local HairColorAnalyzer = require(script.Parent:WaitForChild("HairColorAnalyzer"))
local Raster = require(script.Parent:WaitForChild("ProceduralRaster"))

type Bounds = Raster.Bounds
type ConnectedComponent = Raster.ConnectedComponent

export type AccessoryDepth = "Back" | "Side" | "Front"
export type AccessoryKind = "Ear" | "Headphone" | "Clip" | "Bow" | "Ornament"
export type AccessoryAnchor =
	"topLeft" | "topRight" | "sideLeft" | "sideRight" | "frontLeft" | "frontRight" | "centerTop"

export type AccessoryCandidate = {
	bounds: Bounds,
	area: number,
	centroid: Vector2,
	zone: AccessoryAnchor,
	anchor: AccessoryAnchor,
	depth: AccessoryDepth,
	kind: AccessoryKind,
	pairId: number?,
	confidence: number,
	colors: { Color3 },
	component: ConnectedComponent,
}

export type Options = {
	AlphaThreshold: number?,
	SecondaryMinimumCoverage: number?,
	AccessoryMinimumConfidence: number?,
	MaxAccessoryComponents: number?,
}

export type Analysis = {
	hair: HairColorAnalyzer.HairColors,
	accessories: { AccessoryCandidate },
	sourceBounds: Bounds,
	candidateMask: buffer,
	rawCandidateMask: buffer,
	mergedCandidateMask: buffer,
	protectedFace: Bounds,
	metrics: {
		candidates: number,
		accepted: number,
		rejectedFace: number,
		rawComponents: number,
		mergedComponents: number,
		acceptedComponents: number,
		byZone: { [string]: number },
		candidatesByZone: { [string]: number },
		retainedByZone: { [string]: number },
		rejectedByOverlap: number,
		rejectedByQuota: number,
		rejectedByFace: number,
		rejectedAsDuplicate: number,
		mergedPairs: number,
	},
}

local ProceduralChibiHeadAnalyzer = {}

local ZONE_LIMITS: { [string]: number } = {
	topLeft = 2,
	topRight = 2,
	sideLeft = 2,
	sideRight = 2,
	centerTop = 2,
	frontLeft = 4,
	frontRight = 4,
}

local function offset(width: number, x: number, y: number): number
	return (y * width + x) * 4
end

local function colorDistance(red: number, green: number, blue: number, color: Color3): number
	local deltaRed = red - color.R * 255
	local deltaGreen = green - color.G * 255
	local deltaBlue = blue - color.B * 255
	return math.sqrt(deltaRed * deltaRed * 0.3 + deltaGreen * deltaGreen * 0.59 + deltaBlue * deltaBlue * 0.11)
end

local function intersects(left: Bounds, right: Bounds): boolean
	return left.minX <= right.maxX and left.maxX >= right.minX
		and left.minY <= right.maxY and left.maxY >= right.minY
end

local function zoneFor(point: Vector2, bounds: Bounds): AccessoryAnchor
	local normalizedX = (point.X - bounds.minX) / math.max(1, bounds.maxX - bounds.minX)
	local normalizedY = (point.Y - bounds.minY) / math.max(1, bounds.maxY - bounds.minY)
	if normalizedY < 0.22 then
		if normalizedX < 0.38 then return "topLeft" end
		if normalizedX > 0.62 then return "topRight" end
		return "centerTop"
	end
	if normalizedX < 0.22 then return "sideLeft" end
	if normalizedX > 0.78 then return "sideRight" end
	if normalizedX < 0.5 then return "frontLeft" end
	return "frontRight"
end

local function representativeColors(component: ConnectedComponent): { Color3 }
	local histogram: { [number]: { r: number, g: number, b: number, count: number } } = {}
	for _, pixel in component.pixels do
		local key = math.floor(pixel.r / 32) * 64 + math.floor(pixel.g / 32) * 8 + math.floor(pixel.b / 32)
		local bucket = histogram[key]
		if bucket then
			bucket.r += pixel.r
			bucket.g += pixel.g
			bucket.b += pixel.b
			bucket.count += 1
		else
			histogram[key] = { r = pixel.r, g = pixel.g, b = pixel.b, count = 1 }
		end
	end
	local buckets = {}
	for _, bucket in histogram do table.insert(buckets, bucket) end
	table.sort(buckets, function(left, right) return left.count > right.count end)
	local colors = {}
	for index = 1, math.min(3, #buckets) do
		local bucket = buckets[index]
		table.insert(colors, Color3.fromRGB(
			math.round(bucket.r / bucket.count),
			math.round(bucket.g / bucket.count),
			math.round(bucket.b / bucket.count)
		))
	end
	return colors
end

local function componentGap(left: ConnectedComponent, right: ConnectedComponent): number
	local gapX = math.max(0, math.max(left.bounds.minX - right.bounds.maxX - 1, right.bounds.minX - left.bounds.maxX - 1))
	local gapY = math.max(0, math.max(left.bounds.minY - right.bounds.maxY - 1, right.bounds.minY - left.bounds.maxY - 1))
	return math.max(gapX, gapY)
end

local function boundsArea(bounds: Bounds): number
	return (bounds.maxX - bounds.minX + 1) * (bounds.maxY - bounds.minY + 1)
end

local function combinedBounds(left: Bounds, right: Bounds): Bounds
	return {
		minX = math.min(left.minX, right.minX),
		minY = math.min(left.minY, right.minY),
		maxX = math.max(left.maxX, right.maxX),
		maxY = math.max(left.maxY, right.maxY),
	}
end

local function boundsIntersectionRatio(left: Bounds, right: Bounds): number
	local minX = math.max(left.minX, right.minX)
	local minY = math.max(left.minY, right.minY)
	local maxX = math.min(left.maxX, right.maxX)
	local maxY = math.min(left.maxY, right.maxY)
	if minX > maxX or minY > maxY then return 0 end
	local intersection = (maxX - minX + 1) * (maxY - minY + 1)
	return intersection / math.max(1, math.min(boundsArea(left), boundsArea(right)))
end

local function averageColor(component: ConnectedComponent): Color3
	local red, green, blue = 0, 0, 0
	for _, pixel in component.pixels do
		red += pixel.r
		green += pixel.g
		blue += pixel.b
	end
	local count = math.max(1, #component.pixels)
	return Color3.fromRGB(math.round(red / count), math.round(green / count), math.round(blue / count))
end

function ProceduralChibiHeadAnalyzer.CanMergeComponents(
	left: ConnectedComponent,
	right: ConnectedComponent,
	context: { bounds: Bounds, protectedFace: Bounds? }
): boolean
	if zoneFor(left.centroid, context.bounds) ~= zoneFor(right.centroid, context.bounds) then return false end
	local gap = componentGap(left, right)
	if gap > 2 then return false end
	local areaRatio = math.max(left.area, right.area) / math.max(1, math.min(left.area, right.area))
	if areaRatio > 3.2 then return false end
	local leftColor = averageColor(left)
	local rightColor = averageColor(right)
	local luminanceLeft = leftColor.R * 0.3 + leftColor.G * 0.59 + leftColor.B * 0.11
	local luminanceRight = rightColor.R * 0.3 + rightColor.G * 0.59 + rightColor.B * 0.11
	if math.abs(luminanceLeft - luminanceRight) > 0.24 then return false end
	if colorDistance(
		math.round(leftColor.R * 255),
		math.round(leftColor.G * 255),
		math.round(leftColor.B * 255),
		rightColor
	) > 62 then return false end
	local combined = combinedBounds(left.bounds, right.bounds)
	local growth = boundsArea(combined) / math.max(1, boundsArea(left.bounds) + boundsArea(right.bounds))
	if growth > 2.15 then return false end
	if context.protectedFace and intersects(combined, context.protectedFace)
		and not intersects(left.bounds, context.protectedFace)
		and not intersects(right.bounds, context.protectedFace) then
		return false
	end
	return true
end

local function mergeComponents(
	components: { ConnectedComponent },
	bounds: Bounds,
	protectedFace: Bounds?
): ({ ConnectedComponent }, number)
	local groups: { { ConnectedComponent } } = {}
	local mergeCount = 0
	for _, component in components do
		local destination: { ConnectedComponent }? = nil
		for _, group in groups do
			for _, member in group do
				if ProceduralChibiHeadAnalyzer.CanMergeComponents(member, component, {
					bounds = bounds,
					protectedFace = protectedFace,
				}) then
					destination = group
					break
				end
			end
			if destination then break end
		end
		if destination then
			table.insert(destination, component)
			mergeCount += 1
		else
			table.insert(groups, { component })
		end
	end
	local merged = {}
	for _, group in groups do
		local pixels = {}
		local mergedBounds: Bounds = {
			minX = group[1].bounds.minX, minY = group[1].bounds.minY,
			maxX = group[1].bounds.maxX, maxY = group[1].bounds.maxY,
		}
		local sumX = 0
		local sumY = 0
		for _, component in group do
			for _, pixel in component.pixels do
				table.insert(pixels, pixel)
				sumX += pixel.x
				sumY += pixel.y
			end
			mergedBounds.minX = math.min(mergedBounds.minX, component.bounds.minX)
			mergedBounds.minY = math.min(mergedBounds.minY, component.bounds.minY)
			mergedBounds.maxX = math.max(mergedBounds.maxX, component.bounds.maxX)
			mergedBounds.maxY = math.max(mergedBounds.maxY, component.bounds.maxY)
		end
		table.insert(merged, {
			bounds = mergedBounds,
			area = #pixels,
			centroid = Vector2.new(sumX / math.max(1, #pixels), sumY / math.max(1, #pixels)),
			pixels = pixels,
		})
	end
	table.sort(merged, function(left, right) return left.area > right.area end)
	return merged, mergeCount
end

local function componentMask(components: { ConnectedComponent }, size: Vector2): buffer
	local width = math.floor(size.X)
	local mask = buffer.create(width * math.floor(size.Y) * 4)
	for _, component in components do
		for _, pixel in component.pixels do
			buffer.writeu8(mask, offset(width, pixel.x, pixel.y) + 3, 255)
		end
	end
	return mask
end

local function classify(zone: AccessoryAnchor, component: ConnectedComponent): (AccessoryKind, AccessoryDepth)
	local componentWidth = component.bounds.maxX - component.bounds.minX + 1
	local componentHeight = component.bounds.maxY - component.bounds.minY + 1
	local aspect = componentWidth / math.max(1, componentHeight)
	if zone == "sideLeft" or zone == "sideRight" then
		if aspect < 0.72 then return "Headphone", "Side" end
		return "Ornament", "Side"
	end
	if zone == "topLeft" or zone == "topRight" then
		if aspect > 0.7 and aspect < 1.45 then return "Ear", "Back" end
		return "Bow", "Back"
	end
	if zone == "centerTop" then return "Bow", "Back" end
	return "Clip", "Front"
end

local function pairAccessories(accessories: { AccessoryCandidate }, bounds: Bounds)
	local pairId = 0
	local used: { [number]: boolean } = {}
	for leftIndex, left in accessories do
		if used[leftIndex] or not string.find(left.zone, "Left", 1, true) then continue end
		local expectedZone = string.gsub(left.zone, "Left", "Right")
		local structuralZone = string.find(left.zone, "top", 1, true)
			or string.find(left.zone, "side", 1, true)
		local bestIndex: number? = nil
		local bestScore = math.huge
		for rightIndex, right in accessories do
			if used[rightIndex] or right.zone ~= expectedZone
				or right.kind ~= left.kind and not structuralZone then continue end
			local areaRatio = math.max(left.area, right.area) / math.max(1, math.min(left.area, right.area))
			local mirroredX = bounds.minX + bounds.maxX - left.centroid.X
			local score = math.abs(right.centroid.X - mirroredX)
				+ math.abs(right.centroid.Y - left.centroid.Y) * 1.5
				+ (areaRatio - 1) * 10
			local maximumAreaRatio = if structuralZone then 4 else 2.2
			if areaRatio <= maximumAreaRatio and score < bestScore then
				bestScore = score
				bestIndex = rightIndex
			end
		end
		if bestIndex then
			pairId += 1
			left.pairId = pairId
			accessories[bestIndex :: number].pairId = pairId
			used[leftIndex] = true
			used[bestIndex :: number] = true
		end
	end
end

function ProceduralChibiHeadAnalyzer.Analyze(
	pixels: buffer,
	size: Vector2,
	bounds: Bounds,
	skinColor: Color3,
	options: Options?
): Analysis
	local settings = options or {}
	local threshold = math.clamp(math.floor(settings.AlphaThreshold or 48), 1, 255)
	local minimumConfidence = math.clamp(settings.AccessoryMinimumConfidence or 0.35, 0, 1)
	local maximumComponents = math.clamp(math.floor(settings.MaxAccessoryComponents or 10), 1, 24)
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	local boundsWidth = math.max(1, bounds.maxX - bounds.minX + 1)
	local boundsHeight = math.max(1, bounds.maxY - bounds.minY + 1)
	local hair = HairColorAnalyzer.Analyze(
		pixels, size, bounds, skinColor, threshold, settings.SecondaryMinimumCoverage
	)
	local protectedFace: Bounds = {
		minX = bounds.minX + math.floor(boundsWidth * 0.27),
		maxX = bounds.minX + math.floor(boundsWidth * 0.73),
		minY = bounds.minY + math.floor(boundsHeight * 0.38),
		maxY = bounds.minY + math.floor(boundsHeight * 0.82),
	}
	local rawCandidateMask = buffer.create(width * height * 4)
	for y = math.max(0, bounds.minY), math.min(height - 1, bounds.maxY) do
		for x = math.max(0, bounds.minX), math.min(width - 1, bounds.maxX) do
			local pixelOffset = offset(width, x, y)
			if buffer.readu8(pixels, pixelOffset + 3) < threshold then continue end
			local red = buffer.readu8(pixels, pixelOffset)
			local green = buffer.readu8(pixels, pixelOffset + 1)
			local blue = buffer.readu8(pixels, pixelOffset + 2)
			local normalizedX = (x - bounds.minX) / boundsWidth
			local normalizedY = (y - bounds.minY) / boundsHeight
			local inFace = x >= protectedFace.minX and x <= protectedFace.maxX
				and y >= protectedFace.minY and y <= protectedFace.maxY
			local outerZone = normalizedY < 0.3 or normalizedX < 0.22 or normalizedX > 0.78
			local distanceSkin = colorDistance(red, green, blue, skinColor)
			local distanceHair = math.min(
				colorDistance(red, green, blue, hair.primary),
				colorDistance(red, green, blue, hair.secondary),
				colorDistance(red, green, blue, hair.highlight),
				colorDistance(red, green, blue, hair.shadow)
			)
			local chroma = math.max(red, green, blue) - math.min(red, green, blue)
			local belongsToHairCore = buffer.readu8(hair.hairCoreMask, pixelOffset + 3) > 0
			local candidate = distanceSkin >= 48 and not inFace
				and ((distanceHair >= 42 and chroma >= 18) or (outerZone and not belongsToHairCore))
			if candidate then buffer.writeu8(rawCandidateMask, pixelOffset + 3, 255) end
		end
	end
	-- Component identity comes from the unclosed observation. Global closing
	-- can bridge neighboring clips before color-aware CanMergeComponents gets
	-- a chance to distinguish them.
	local rawComponents = Raster.ConnectedComponents(rawCandidateMask, size, pixels, 1, 8)
	local sourceArea = boundsWidth * boundsHeight
	local mergedComponents, mergedPairs = mergeComponents(rawComponents, bounds, protectedFace)
	local mergedCandidateMask = componentMask(mergedComponents, size)
	local accepted: { AccessoryCandidate } = {}
	local rejectedFace = 0
	local candidatesByZone: { [string]: number } = {}
	for _, component in mergedComponents do
		if component.area < math.max(3, sourceArea * 0.00012) or component.area > sourceArea * 0.2 then continue end
		local componentWidth = component.bounds.maxX - component.bounds.minX + 1
		local componentHeight = component.bounds.maxY - component.bounds.minY + 1
		local compactness = component.area / math.max(1, componentWidth * componentHeight)
		local normalizedY = (component.centroid.Y - bounds.minY) / boundsHeight
		local fullyCentral = component.centroid.X > protectedFace.minX
			and component.centroid.X < protectedFace.maxX
			and component.centroid.Y > protectedFace.minY
			and component.centroid.Y < protectedFace.maxY
		if fullyCentral or normalizedY > 0.76 or intersects(component.bounds, protectedFace) and normalizedY > 0.45 then
			rejectedFace += 1
			continue
		end
		local zone = zoneFor(component.centroid, bounds)
		candidatesByZone[zone] = (candidatesByZone[zone] or 0) + 1
		local kind, depth = classify(zone, component)
		local borderTouch = if component.bounds.minX <= bounds.minX + 1
				or component.bounds.maxX >= bounds.maxX - 1
				or component.bounds.minY <= bounds.minY + 1 then 0.08 else 0
		local sizeScore = math.clamp(component.area / math.max(8, sourceArea * 0.004), 0, 1)
		local symmetryPotential = if zone ~= "centerTop" then 0.08 else 0
		local confidence = math.clamp(
			0.18 + compactness * 0.3 + sizeScore * 0.3 + symmetryPotential + borderTouch,
			0,
			1
		)
		if confidence >= minimumConfidence then
			table.insert(accepted, {
				bounds = component.bounds,
				area = component.area,
				centroid = component.centroid,
				zone = zone,
				anchor = zone,
				depth = depth,
				kind = kind,
				pairId = nil,
				confidence = confidence,
				colors = representativeColors(component),
				component = component,
			})
		end
	end
	table.sort(accepted, function(left, right)
		return left.confidence > right.confidence
	end)
	local selected: { AccessoryCandidate } = {}
	local retainedByZone: { [string]: number } = {}
	local rejectedByOverlap = 0
	local rejectedByQuota = 0
	local rejectedAsDuplicate = 0
	for _, accessory in accepted do
		local zoneCount = retainedByZone[accessory.zone] or 0
		if zoneCount >= (ZONE_LIMITS[accessory.zone] or 1) then
			rejectedByQuota += 1
			continue
		end
		local overlaps = false
		local duplicate = false
		for _, retained in selected do
			if retained.zone ~= accessory.zone then continue end
			local overlap = boundsIntersectionRatio(retained.bounds, accessory.bounds)
			if overlap >= 0.78 then
				duplicate = true
				break
			elseif overlap >= 0.42 then
				overlaps = true
				break
			end
		end
		if duplicate then
			rejectedAsDuplicate += 1
		elseif overlaps then
			rejectedByOverlap += 1
		else
			table.insert(selected, accessory)
			retainedByZone[accessory.zone] = zoneCount + 1
		end
		if #selected >= maximumComponents then break end
	end
	pairAccessories(selected, bounds)
	return {
		hair = hair,
		accessories = selected,
		sourceBounds = bounds,
		candidateMask = mergedCandidateMask,
		rawCandidateMask = rawCandidateMask,
		mergedCandidateMask = mergedCandidateMask,
		protectedFace = protectedFace,
		metrics = {
			candidates = #rawComponents,
			accepted = #selected,
			rejectedFace = rejectedFace,
			rawComponents = #rawComponents,
			mergedComponents = #mergedComponents,
			acceptedComponents = #selected,
			byZone = retainedByZone,
			candidatesByZone = candidatesByZone,
			retainedByZone = retainedByZone,
			rejectedByOverlap = rejectedByOverlap,
			rejectedByQuota = rejectedByQuota,
			rejectedByFace = rejectedFace,
			rejectedAsDuplicate = rejectedAsDuplicate,
			mergedPairs = mergedPairs,
		},
	}
end

return table.freeze(ProceduralChibiHeadAnalyzer)
