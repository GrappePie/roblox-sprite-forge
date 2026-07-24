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
	},
}

local ProceduralChibiHeadAnalyzer = {}

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
	if normalizedY < 0.3 then
		if normalizedX < 0.38 then return "topLeft" end
		if normalizedX > 0.62 then return "topRight" end
		return "centerTop"
	end
	if normalizedX < 0.3 then return "sideLeft" end
	if normalizedX > 0.7 then return "sideRight" end
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

local function mergeComponents(components: { ConnectedComponent }, bounds: Bounds): { ConnectedComponent }
	local groups: { { ConnectedComponent } } = {}
	for _, component in components do
		local zone = zoneFor(component.centroid, bounds)
		local destination: { ConnectedComponent }? = nil
		for _, group in groups do
			if zoneFor(group[1].centroid, bounds) == zone then
				for _, member in group do
					if componentGap(member, component) <= 3 then
						destination = group
						break
					end
				end
			end
			if destination then break end
		end
		if destination then
			table.insert(destination, component)
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
	return merged
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
		local bestIndex: number? = nil
		local bestScore = math.huge
		for rightIndex, right in accessories do
			if used[rightIndex] or right.zone ~= expectedZone or right.kind ~= left.kind then continue end
			local areaRatio = math.max(left.area, right.area) / math.max(1, math.min(left.area, right.area))
			local mirroredX = bounds.minX + bounds.maxX - left.centroid.X
			local score = math.abs(right.centroid.X - mirroredX)
				+ math.abs(right.centroid.Y - left.centroid.Y) * 1.5
				+ (areaRatio - 1) * 10
			if areaRatio <= 2.2 and score < bestScore then
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
	local closed = Raster.CardinalErode(Raster.CardinalDilate(rawCandidateMask, size, 1), size, 1)
	local rawComponents = Raster.ConnectedComponents(closed, size, pixels, 1, 8)
	local mergedComponents = mergeComponents(rawComponents, bounds)
	local mergedCandidateMask = componentMask(mergedComponents, size)
	local accepted: { AccessoryCandidate } = {}
	local rejectedFace = 0
	local sourceArea = boundsWidth * boundsHeight
	local byZone: { [string]: number } = {}
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
			byZone[zone] = (byZone[zone] or 0) + 1
			if #accepted >= maximumComponents then break end
		end
	end
	table.sort(accepted, function(left, right)
		return left.confidence > right.confidence
	end)
	local selected: { AccessoryCandidate } = {}
	local selectedZones: { [string]: boolean } = {}
	for _, accessory in accepted do
		if not selectedZones[accessory.zone] then
			selectedZones[accessory.zone] = true
			table.insert(selected, accessory)
		end
		if #selected >= maximumComponents then break end
	end
	byZone = {}
	for _, accessory in selected do
		byZone[accessory.zone] = (byZone[accessory.zone] or 0) + 1
	end
	pairAccessories(selected, bounds)
	return {
		hair = hair,
		accessories = selected,
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
			byZone = byZone,
		},
	}
end

return table.freeze(ProceduralChibiHeadAnalyzer)
