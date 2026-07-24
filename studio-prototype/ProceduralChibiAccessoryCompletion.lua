--!strict

local Raster = require(script.Parent:WaitForChild("ProceduralRaster"))

type Bounds = Raster.Bounds
type ConnectedComponent = Raster.ConnectedComponent

export type AccessoryCluster = {
	components: { ConnectedComponent },
	completedComponent: ConnectedComponent,
	bounds: Bounds,
	centroid: Vector2,
	zone: string,
	sourceArea: number,
	colorGroups: { Color3 },
	confidence: number,
	corePixels: number,
	supportPixels: number,
}

export type Result = {
	clusters: { AccessoryCluster },
	coreMask: buffer,
	supportMask: buffer,
	completedMask: buffer,
	recoveredSkinLikeMask: buffer,
	recoveredHairLikeMask: buffer,
	clusterBoundsMask: buffer,
	rawCoreComponents: number,
	completedClusters: number,
	recoveredSupportPixels: number,
	recoveredSkinLikePixels: number,
	recoveredHairLikePixels: number,
	rejectedLeakPixels: number,
}

local Completion = {}

local function offset(width: number, x: number, y: number): number
	return (y * width + x) * 4
end

local function distance(red: number, green: number, blue: number, color: Color3): number
	local dr, dg, db = red - color.R * 255, green - color.G * 255, blue - color.B * 255
	return math.sqrt(dr * dr * 0.3 + dg * dg * 0.59 + db * db * 0.11)
end

local function zoneFor(point: Vector2, bounds: Bounds): string
	local u = (point.X - bounds.minX) / math.max(1, bounds.maxX - bounds.minX)
	local v = (point.Y - bounds.minY) / math.max(1, bounds.maxY - bounds.minY)
	if v < 0.22 then return if u < 0.38 then "topLeft" elseif u > 0.62 then "topRight" else "centerTop" end
	if u < 0.22 then return "sideLeft" end
	if u > 0.78 then return "sideRight" end
	return if u < 0.5 then "frontLeft" else "frontRight"
end

local function representativeColors(component: ConnectedComponent): { Color3 }
	local buckets: { [number]: { r: number, g: number, b: number, count: number } } = {}
	for _, pixel in component.pixels do
		local key = math.floor(pixel.r / 32) * 64 + math.floor(pixel.g / 32) * 8 + math.floor(pixel.b / 32)
		local bucket = buckets[key] or { r = 0, g = 0, b = 0, count = 0 }
		bucket.r += pixel.r; bucket.g += pixel.g; bucket.b += pixel.b; bucket.count += 1
		buckets[key] = bucket
	end
	local ordered = {}
	for _, bucket in buckets do table.insert(ordered, bucket) end
	table.sort(ordered, function(a, b) return a.count > b.count end)
	local colors = {}
	for index = 1, math.min(5, #ordered) do
		local bucket = ordered[index]
		table.insert(colors, Color3.fromRGB(
			math.round(bucket.r / bucket.count),
			math.round(bucket.g / bucket.count),
			math.round(bucket.b / bucket.count)
		))
	end
	return colors
end

local function boundsDiagnostic(size: Vector2, boundsList: { Bounds }): buffer
	local result = buffer.create(math.floor(size.X) * math.floor(size.Y) * 4)
	for _, bounds in boundsList do
		for x = bounds.minX, bounds.maxX do
			for _, y in { bounds.minY, bounds.maxY } do
				if x >= 0 and y >= 0 and x < size.X and y < size.Y then
					buffer.writeu32(result, offset(math.floor(size.X), x, y), 0xFF46D9FF)
				end
			end
		end
		for y = bounds.minY, bounds.maxY do
			for _, x in { bounds.minX, bounds.maxX } do
				if x >= 0 and y >= 0 and x < size.X and y < size.Y then
					buffer.writeu32(result, offset(math.floor(size.X), x, y), 0xFF46D9FF)
				end
			end
		end
	end
	return result
end

function Completion.Complete(
	pixels: buffer,
	size: Vector2,
	sourceBounds: Bounds,
	protectedFace: Bounds,
	coreMask: buffer,
	hairCoreMask: buffer,
	skinColor: Color3,
	hairColors: { Color3 },
	alphaThreshold: number
): Result
	local width, height = math.floor(size.X), math.floor(size.Y)
	local supportMask = buffer.create(buffer.len(coreMask))
	local recoveredSkin = buffer.create(buffer.len(coreMask))
	local recoveredHair = buffer.create(buffer.len(coreMask))
	local completedMask = buffer.create(buffer.len(coreMask))
	local skinMask = buffer.create(buffer.len(coreMask))
	for y = sourceBounds.minY, sourceBounds.maxY do
		for x = sourceBounds.minX, sourceBounds.maxX do
			local pixelOffset = offset(width, x, y)
			local alpha = buffer.readu8(pixels, pixelOffset + 3)
			if alpha < math.max(12, math.floor(alphaThreshold * 0.5)) then continue end
			local inProtected = x >= protectedFace.minX and x <= protectedFace.maxX
				and y >= protectedFace.minY and y <= protectedFace.maxY
			if not inProtected then buffer.writeu8(supportMask, pixelOffset + 3, 255) end
			local red, green, blue = buffer.readu8(pixels, pixelOffset),
				buffer.readu8(pixels, pixelOffset + 1), buffer.readu8(pixels, pixelOffset + 2)
			if distance(red, green, blue, skinColor) < 48 then
				buffer.writeu8(skinMask, pixelOffset + 3, 255)
			end
		end
	end
	-- Reject the connected skin mass nearest the face center, not every skin-like color.
	local faceCenter = Vector2.new(
		(protectedFace.minX + protectedFace.maxX) * 0.5,
		(protectedFace.minY + protectedFace.maxY) * 0.5
	)
	local mainSkin: ConnectedComponent? = nil
	for _, component in Raster.ConnectedComponents(skinMask, size, pixels, 2, 8) do
		if not mainSkin or (component.centroid - faceCenter).Magnitude < ((mainSkin :: ConnectedComponent).centroid - faceCenter).Magnitude then
			mainSkin = component
		end
	end
	if mainSkin then
		for _, pixel in (mainSkin :: ConnectedComponent).pixels do
			buffer.writeu8(supportMask, offset(width, pixel.x, pixel.y) + 3, 0)
		end
	end

	local rawCores = Raster.ConnectedComponents(coreMask, size, pixels, 2, 8)
	local clusters = {}
	local claimed: { [number]: boolean } = {}
	local recoveredSupportPixels, recoveredSkinPixels, recoveredHairPixels, rejectedLeakPixels = 0, 0, 0, 0
	local boundsList = {}
	for _, core in rawCores do
		local zone = zoneFor(core.centroid, sourceBounds)
		local padding = if string.find(zone, "top", 1, true) or string.find(zone, "side", 1, true) then 6 else 3
		local roi: Bounds = {
			minX = math.max(sourceBounds.minX, core.bounds.minX - padding),
			minY = math.max(sourceBounds.minY, core.bounds.minY - padding),
			maxX = math.min(sourceBounds.maxX, core.bounds.maxX + padding),
			maxY = math.min(sourceBounds.maxY, core.bounds.maxY + padding),
		}
		local members, queue, memberSet = {}, {}, {}
		for _, pixel in core.pixels do
			local key = pixel.y * width + pixel.x
			if not claimed[key] then
				memberSet[key] = true; table.insert(queue, key)
			end
		end
		local maximumArea = math.max(core.area + 12, math.floor(core.area * (if padding == 6 then 4.5 else 3)))
		local index = 1
		while index <= #queue and #members < maximumArea do
			local key = queue[index]; index += 1
			local x, y = key % width, math.floor(key / width)
			local pixelOffset = offset(width, x, y)
			table.insert(members, {
				x = x, y = y,
				r = buffer.readu8(pixels, pixelOffset),
				g = buffer.readu8(pixels, pixelOffset + 1),
				b = buffer.readu8(pixels, pixelOffset + 2),
				a = buffer.readu8(pixels, pixelOffset + 3),
			})
			for dy = -1, 1 do
				for dx = -1, 1 do
					if dx == 0 and dy == 0 then continue end
					local nx, ny = x + dx, y + dy
					local nextKey = ny * width + nx
					if nx < roi.minX or nx > roi.maxX or ny < roi.minY or ny > roi.maxY
						or memberSet[nextKey] or claimed[nextKey] then continue end
					local nextOffset = offset(width, nx, ny)
					if buffer.readu8(supportMask, nextOffset + 3) == 0 then continue end
					local crossesCenter = string.find(zone, "Left", 1, true) and nx > protectedFace.maxX
						or string.find(zone, "Right", 1, true) and nx < protectedFace.minX
					if crossesCenter then rejectedLeakPixels += 1; continue end
					local hairLike = buffer.readu8(hairCoreMask, nextOffset + 3) > 0
					if hairLike and #members > core.area * 1.8 then rejectedLeakPixels += 1; continue end
					memberSet[nextKey] = true
					table.insert(queue, nextKey)
				end
			end
		end
		if #members == 0 then continue end
		local minX, minY, maxX, maxY = width, height, -1, -1
		local sumX, sumY = 0, 0
		for _, pixel in members do
			local key = pixel.y * width + pixel.x
			claimed[key] = true
			buffer.writeu8(completedMask, offset(width, pixel.x, pixel.y) + 3, 255)
			minX, minY, maxX, maxY = math.min(minX, pixel.x), math.min(minY, pixel.y),
				math.max(maxX, pixel.x), math.max(maxY, pixel.y)
			sumX += pixel.x; sumY += pixel.y
			if buffer.readu8(coreMask, offset(width, pixel.x, pixel.y) + 3) == 0 then
				recoveredSupportPixels += 1
				if distance(pixel.r, pixel.g, pixel.b, skinColor) < 48 then
					recoveredSkinPixels += 1
					buffer.writeu8(recoveredSkin, offset(width, pixel.x, pixel.y) + 3, 255)
				end
				local nearestHair = math.huge
				for _, color in hairColors do nearestHair = math.min(nearestHair, distance(pixel.r, pixel.g, pixel.b, color)) end
				if nearestHair < 42 then
					recoveredHairPixels += 1
					buffer.writeu8(recoveredHair, offset(width, pixel.x, pixel.y) + 3, 255)
				end
			end
		end
		local completed: ConnectedComponent = {
			bounds = { minX = minX, minY = minY, maxX = maxX, maxY = maxY },
			area = #members,
			centroid = Vector2.new(sumX / #members, sumY / #members),
			pixels = members,
		}
		table.insert(boundsList, completed.bounds)
		table.insert(clusters, {
			components = { core },
			completedComponent = completed,
			bounds = completed.bounds,
			centroid = completed.centroid,
			zone = zone,
			sourceArea = completed.area,
			colorGroups = representativeColors(completed),
			confidence = math.clamp(0.42 + core.area / math.max(1, completed.area) * 0.25 + math.min(0.3, completed.area / 120), 0, 1),
			corePixels = core.area,
			supportPixels = math.max(0, completed.area - core.area),
		})
	end
	return {
		clusters = clusters,
		coreMask = coreMask,
		supportMask = supportMask,
		completedMask = completedMask,
		recoveredSkinLikeMask = recoveredSkin,
		recoveredHairLikeMask = recoveredHair,
		clusterBoundsMask = boundsDiagnostic(size, boundsList),
		rawCoreComponents = #rawCores,
		completedClusters = #clusters,
		recoveredSupportPixels = recoveredSupportPixels,
		recoveredSkinLikePixels = recoveredSkinPixels,
		recoveredHairLikePixels = recoveredHairPixels,
		rejectedLeakPixels = rejectedLeakPixels,
	}
end

return table.freeze(Completion)
