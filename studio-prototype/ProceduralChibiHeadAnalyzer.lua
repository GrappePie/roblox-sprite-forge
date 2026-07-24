--!strict

local HairColorAnalyzer = require(script.Parent:WaitForChild("HairColorAnalyzer"))
local Raster = require(script.Parent:WaitForChild("ProceduralRaster"))

type Bounds = Raster.Bounds
type ConnectedComponent = Raster.ConnectedComponent

export type AccessoryCandidate = {
	bounds: Bounds,
	area: number,
	centroid: Vector2,
	zone: string,
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
	protectedFace: Bounds,
	metrics: {
		candidates: number,
		accepted: number,
		rejectedFace: number,
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

local function zoneFor(point: Vector2, bounds: Bounds): string
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
		pixels,
		size,
		bounds,
		skinColor,
		threshold,
		settings.SecondaryMinimumCoverage
	)
	local protectedFace: Bounds = {
		minX = bounds.minX + math.floor(boundsWidth * 0.27),
		maxX = bounds.minX + math.floor(boundsWidth * 0.73),
		minY = bounds.minY + math.floor(boundsHeight * 0.38),
		maxY = bounds.minY + math.floor(boundsHeight * 0.82),
	}
	local candidateMask = buffer.create(width * height * 4)
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
			local outerAccessoryZone = (normalizedY < 0.22
					and (normalizedX < 0.3 or normalizedX > 0.7))
				or ((normalizedX < 0.15 or normalizedX > 0.85)
					and normalizedY > 0.25)
			local distanceSkin = colorDistance(red, green, blue, skinColor)
			local distancePrimary = colorDistance(red, green, blue, hair.primary)
			local distanceSecondary = colorDistance(red, green, blue, hair.secondary)
			local distanceHighlight = colorDistance(red, green, blue, hair.highlight)
			local distanceShadow = colorDistance(red, green, blue, hair.shadow)
			local distanceHair = math.min(
				distancePrimary,
				distanceSecondary,
				distanceHighlight,
				distanceShadow
			)
			local chroma = math.max(red, green, blue) - math.min(red, green, blue)
			local highContrastOrnament = chroma >= 55
				and distanceHair >= 34
			local candidate = distanceSkin >= 52
				and distanceHair >= 48
				and (not inFace or highContrastOrnament)
			if outerAccessoryZone and distanceSkin >= 38
				and (chroma >= 24 or math.max(red, green, blue) < 82) then
				candidate = true
			end
			if candidate then
				buffer.writeu8(candidateMask, pixelOffset + 3, 255)
			end
		end
	end
	-- Close one-pixel gaps, then remove isolated noise through a cardinal opening.
	local cleaned = Raster.CardinalDilate(candidateMask, size, 1)
	cleaned = Raster.CardinalErode(cleaned, size, 1)
	local components = Raster.ConnectedComponents(cleaned, size, pixels, 1)
	local accepted: { AccessoryCandidate } = {}
	local rejectedFace = 0
	local sourceArea = boundsWidth * boundsHeight
	for _, component in components do
		if component.area < math.max(3, sourceArea * 0.00012)
			or component.area > sourceArea * 0.2 then
			continue
		end
		local componentWidth = component.bounds.maxX - component.bounds.minX + 1
		local componentHeight = component.bounds.maxY - component.bounds.minY + 1
		local compactness = component.area / math.max(1, componentWidth * componentHeight)
		local normalizedY = (component.centroid.Y - bounds.minY) / boundsHeight
		local faceIntersection = intersects(component.bounds, protectedFace)
		local fullyCentral = component.centroid.X > protectedFace.minX
			and component.centroid.X < protectedFace.maxX
			and component.centroid.Y > protectedFace.minY
			and component.centroid.Y < protectedFace.maxY
		local normalizedX = (component.centroid.X - bounds.minX) / boundsWidth
		if fullyCentral and normalizedY > 0.48 then
			rejectedFace += 1
			continue
		end
		-- HeadShot thumbnails frequently include shoulder/collar fragments at
		-- the very bottom. They are not head accessories and otherwise become
		-- oversized dark "bows" beside the procedural neck.
		if normalizedY > 0.72 then
			rejectedFace += 1
			continue
		end
		local edgeBonus = if component.centroid.X < protectedFace.minX
				or component.centroid.X > protectedFace.maxX
				or component.centroid.Y < protectedFace.minY
			then 0.28
			else 0
		local sizeScore = math.clamp(component.area / math.max(8, sourceArea * 0.004), 0, 1)
		local confidence = math.clamp(0.2 + compactness * 0.28 + sizeScore * 0.34 + edgeBonus
			- (if faceIntersection then 0.15 else 0), 0, 1)
		if confidence >= minimumConfidence then
			table.insert(accepted, {
				bounds = component.bounds,
				area = component.area,
				centroid = component.centroid,
				zone = zoneFor(component.centroid, bounds),
				confidence = confidence,
				colors = representativeColors(component),
				component = component,
			})
			if #accepted >= maximumComponents then break end
		end
	end
	return {
		hair = hair,
		accessories = accepted,
		candidateMask = cleaned,
		protectedFace = protectedFace,
		metrics = {
			candidates = #components,
			accepted = #accepted,
			rejectedFace = rejectedFace,
		},
	}
end

return table.freeze(ProceduralChibiHeadAnalyzer)
