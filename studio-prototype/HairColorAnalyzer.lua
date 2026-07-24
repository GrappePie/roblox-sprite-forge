--!strict

local Raster = require(script.Parent:WaitForChild("ProceduralRaster"))

export type HairColors = {
	primary: Color3,
	secondary: Color3,
	highlight: Color3,
	shadow: Color3,
	primaryCoverage: number,
	secondaryCoverage: number,
	secondaryReliable: boolean,
	leftTipSecondaryCoverage: number,
	rightTipSecondaryCoverage: number,
	hairCoreMask: buffer,
	rawLabelMap: buffer,
	labelMap: buffer,
	hairCoreCoverage: number,
	hairCoreAspect: number,
	rawLabelComponents: number,
	regularizedLabelComponents: number,
	removedLabelPixels: number,
	isolatedHighlightPixels: number,
	isolatedSecondaryPixels: number,
	rawIsolatedHighlightPixels: number,
	rawIsolatedSecondaryPixels: number,
	remainingIsolatedHighlightPixels: number,
	remainingIsolatedSecondaryPixels: number,
	massDescriptors: { HairMassDescriptor },
}

export type HairMassDescriptor = {
	label: "Primary" | "Secondary" | "Highlight" | "Shadow",
	coverage: number,
	centroid: Vector2,
	bounds: { minU: number, minV: number, maxU: number, maxV: number },
	side: "Left" | "Center" | "Right",
	zone: "Crown" | "Fringe" | "Side" | "Tips" | "Bottom",
	confidence: number,
	orientation: number,
}

type Bucket = {
	r: number,
	g: number,
	b: number,
	count: number,
	crown: number,
	left: number,
	right: number,
	tips: number,
	leftTips: number,
	rightTips: number,
	minX: number,
	maxX: number,
	minY: number,
	maxY: number,
	luminances: { number },
}

local HairColorAnalyzer = {}

local function offset(width: number, x: number, y: number): number
	return (y * width + x) * 4
end

local function perceptualDistance(left: Color3, right: Color3): number
	local leftHue, leftSaturation, leftValue = left:ToHSV()
	local rightHue, rightSaturation, rightValue = right:ToHSV()
	local hueDistance = math.min(math.abs(leftHue - rightHue), 1 - math.abs(leftHue - rightHue))
	local valueDistance = math.abs(leftValue - rightValue)
	local saturationDistance = math.abs(leftSaturation - rightSaturation)
	return hueDistance * 220 + valueDistance * 90 + saturationDistance * 65
end

local function rgbDistance(red: number, green: number, blue: number, color: Color3): number
	local deltaRed = red - color.R * 255
	local deltaGreen = green - color.G * 255
	local deltaBlue = blue - color.B * 255
	return math.sqrt(deltaRed * deltaRed * 0.3 + deltaGreen * deltaGreen * 0.59 + deltaBlue * deltaBlue * 0.11)
end

local function bucketColor(bucket: Bucket): Color3
	return Color3.fromRGB(
		math.clamp(math.round(bucket.r / bucket.count), 0, 255),
		math.clamp(math.round(bucket.g / bucket.count), 0, 255),
		math.clamp(math.round(bucket.b / bucket.count), 0, 255)
	)
end

local function percentileColor(primary: Color3, luminances: { number }, percentile: number): Color3
	if #luminances == 0 then
		return primary
	end
	table.sort(luminances)
	local luminance = luminances[math.clamp(math.ceil(#luminances * percentile), 1, #luminances)]
	local _, saturation, _ = primary:ToHSV()
	local hue = select(1, primary:ToHSV())
	return Color3.fromHSV(hue, math.clamp(saturation, 0, 1), math.clamp(luminance, 0.05, 1))
end

local function cloneBuffer(source: buffer): buffer
	local result = buffer.create(buffer.len(source))
	buffer.copy(result, 0, source, 0, buffer.len(source))
	return result
end

local function labelIndexAt(labels: buffer, width: number, x: number, y: number, colors: { Color3 }): number
	local pixelOffset = offset(width, x, y)
	if buffer.readu8(labels, pixelOffset + 3) == 0 then return 0 end
	local red = buffer.readu8(labels, pixelOffset)
	local green = buffer.readu8(labels, pixelOffset + 1)
	local blue = buffer.readu8(labels, pixelOffset + 2)
	local best, bestDistance = 1, math.huge
	for index, color in colors do
		local distance = rgbDistance(red, green, blue, color)
		if distance < bestDistance then best, bestDistance = index, distance end
	end
	return best
end

function HairColorAnalyzer.RegularizeHairLabelMap(
	rawLabels: buffer,
	size: Vector2,
	hairCoreMask: buffer,
	colors: { Color3 }
): (buffer, { [string]: number })
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	local clipped = buffer.create(buffer.len(rawLabels))
	local rawPixels = 0
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local pixelOffset = offset(width, x, y)
			if buffer.readu8(rawLabels, pixelOffset + 3) > 0
				and buffer.readu8(hairCoreMask, pixelOffset + 3) > 0 then
				buffer.copy(clipped, pixelOffset, rawLabels, pixelOffset, 4)
				rawPixels += 1
			end
		end
	end
	local regularized = cloneBuffer(clipped)
	-- A categorical majority pass removes single-pixel confetti without ever
	-- inventing intermediate RGB values.
	for _ = 1, 2 do
		local nextLabels = cloneBuffer(regularized)
		for y = 1, height - 2 do
			for x = 1, width - 2 do
				local pixelOffset = offset(width, x, y)
				if buffer.readu8(hairCoreMask, pixelOffset + 3) == 0 then continue end
				local counts = { 0, 0, 0, 0 }
				for neighborY = y - 1, y + 1 do
					for neighborX = x - 1, x + 1 do
						local label = labelIndexAt(regularized, width, neighborX, neighborY, colors)
						if label > 0 then counts[label] += 1 end
					end
				end
				local current = labelIndexAt(regularized, width, x, y, colors)
				local best = if current > 0 then current else 1
				for index = 1, 4 do
					if counts[index] > counts[best] then best = index end
				end
				if counts[best] >= 5 or current == 0 and counts[best] >= 4 then
					local color = colors[best]
					buffer.writeu8(nextLabels, pixelOffset, math.round(color.R * 255))
					buffer.writeu8(nextLabels, pixelOffset + 1, math.round(color.G * 255))
					buffer.writeu8(nextLabels, pixelOffset + 2, math.round(color.B * 255))
					buffer.writeu8(nextLabels, pixelOffset + 3, 255)
				end
			end
		end
		regularized = nextLabels
	end
	local rawComponents = 0
	local regularizedComponents = 0
	local isolatedHighlightPixels = 0
	local isolatedSecondaryPixels = 0
	local rawIsolatedHighlightPixels = 0
	local rawIsolatedSecondaryPixels = 0
	for label = 1, 4 do
		local rawMask = buffer.create(buffer.len(rawLabels))
		local cleanMask = buffer.create(buffer.len(rawLabels))
		for y = 0, height - 1 do
			for x = 0, width - 1 do
				local pixelOffset = offset(width, x, y)
				if labelIndexAt(clipped, width, x, y, colors) == label then
					buffer.writeu8(rawMask, pixelOffset + 3, 255)
				end
				if labelIndexAt(regularized, width, x, y, colors) == label then
					buffer.writeu8(cleanMask, pixelOffset + 3, 255)
				end
			end
		end
		local rawLabelParts = Raster.ConnectedComponents(rawMask, size, nil, 1, 8)
		rawComponents += #rawLabelParts
		for _, component in rawLabelParts do
			if component.area <= 2 then
				if label == 2 then rawIsolatedSecondaryPixels += component.area end
				if label == 3 then rawIsolatedHighlightPixels += component.area end
			end
		end
		local components = Raster.ConnectedComponents(cleanMask, size, nil, 1, 8)
		for _, component in components do
			if component.area <= 2 then
				for _, pixel in component.pixels do
					buffer.writeu8(regularized, offset(width, pixel.x, pixel.y) + 3, 0)
				end
			else
				regularizedComponents += 1
			end
		end
	end
	local finalPixels = 0
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			if buffer.readu8(regularized, offset(width, x, y) + 3) > 0 then finalPixels += 1 end
		end
	end
	return regularized, {
		rawLabelComponents = rawComponents,
		regularizedLabelComponents = regularizedComponents,
		removedLabelPixels = math.max(0, rawPixels - finalPixels),
		isolatedHighlightPixels = isolatedHighlightPixels,
		isolatedSecondaryPixels = isolatedSecondaryPixels,
		rawIsolatedHighlightPixels = rawIsolatedHighlightPixels,
		rawIsolatedSecondaryPixels = rawIsolatedSecondaryPixels,
		remainingIsolatedHighlightPixels = isolatedHighlightPixels,
		remainingIsolatedSecondaryPixels = isolatedSecondaryPixels,
	}
end

local function buildMassDescriptors(
	labels: buffer,
	size: Vector2,
	bounds: { minX: number, minY: number, maxX: number, maxY: number },
	colors: { Color3 }
): { HairMassDescriptor }
	local width = math.floor(size.X)
	local boundsWidth = math.max(1, bounds.maxX - bounds.minX + 1)
	local boundsHeight = math.max(1, bounds.maxY - bounds.minY + 1)
	local descriptors: { HairMassDescriptor } = {}
	local names: { "Primary" | "Secondary" | "Highlight" | "Shadow" } =
		{ "Primary", "Secondary", "Highlight", "Shadow" }
	local limits = { 1, 2, 2, 3 }
	for labelIndex = 1, 4 do
		local mask = buffer.create(buffer.len(labels))
		for y = bounds.minY, bounds.maxY do
			for x = bounds.minX, bounds.maxX do
				if labelIndexAt(labels, width, x, y, colors) == labelIndex then
					buffer.writeu8(mask, offset(width, x, y) + 3, 255)
				end
			end
		end
		local components = Raster.ConnectedComponents(mask, size, nil, 3, 8)
		table.sort(components, function(left, right) return left.area > right.area end)
		for componentIndex = 1, math.min(limits[labelIndex], #components) do
			local component = components[componentIndex]
			local u = (component.centroid.X - bounds.minX) / boundsWidth
			local v = (component.centroid.Y - bounds.minY) / boundsHeight
			local zone: "Crown" | "Side" | "Fringe" | "Tips" | "Bottom" = if v < 0.34 then "Crown"
				elseif v > 0.78 then "Bottom"
				elseif v > 0.64 then "Tips"
				elseif u < 0.25 or u > 0.75 then "Side"
				else "Fringe"
			local xx, yy, xy = 0, 0, 0
			for _, pixel in component.pixels do
				local dx, dy = pixel.x - component.centroid.X, pixel.y - component.centroid.Y
				xx += dx * dx; yy += dy * dy; xy += dx * dy
			end
			table.insert(descriptors, {
				label = names[labelIndex],
				coverage = component.area / math.max(1, boundsWidth * boundsHeight),
				centroid = Vector2.new(u, v),
				bounds = {
					minU = (component.bounds.minX - bounds.minX) / boundsWidth,
					minV = (component.bounds.minY - bounds.minY) / boundsHeight,
					maxU = (component.bounds.maxX - bounds.minX) / boundsWidth,
					maxV = (component.bounds.maxY - bounds.minY) / boundsHeight,
				},
				side = if u < 0.4 then "Left" elseif u > 0.6 then "Right" else "Center",
				zone = zone,
				confidence = math.clamp(component.area / math.max(3, boundsWidth * boundsHeight * 0.02), 0, 1),
				orientation = 0.5 * math.atan2(2 * xy, xx - yy),
			})
		end
	end
	return descriptors
end

function HairColorAnalyzer.Analyze(
	pixels: buffer,
	size: Vector2,
	bounds: { minX: number, minY: number, maxX: number, maxY: number },
	skinColor: Color3,
	alphaThreshold: number?,
	secondaryMinimumCoverage: number?
): HairColors
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	local threshold = math.clamp(math.floor(alphaThreshold or 48), 1, 255)
	local minimumSecondary = math.clamp(secondaryMinimumCoverage or 0.04, 0.01, 0.3)
	local boundsWidth = math.max(1, bounds.maxX - bounds.minX + 1)
	local boundsHeight = math.max(1, bounds.maxY - bounds.minY + 1)
	local histogram: { [number]: Bucket } = {}
	local acceptedSamples = 0

	for y = math.max(0, bounds.minY), math.min(height - 1, bounds.maxY), 2 do
		for x = math.max(0, bounds.minX), math.min(width - 1, bounds.maxX), 2 do
			local normalizedX = (x - bounds.minX) / boundsWidth
			local normalizedY = (y - bounds.minY) / boundsHeight
			local protectedFace = normalizedX > 0.28 and normalizedX < 0.72
				and normalizedY > 0.36 and normalizedY < 0.79
			local likelyAccessoryZone = (normalizedY < 0.22
					and (normalizedX < 0.3 or normalizedX > 0.7))
				or ((normalizedX < 0.15 or normalizedX > 0.85)
					and normalizedY > 0.25)
			if protectedFace or likelyAccessoryZone then
				continue
			end
			local pixelOffset = offset(width, x, y)
			local alpha = buffer.readu8(pixels, pixelOffset + 3)
			if alpha < threshold then
				continue
			end
			local red = buffer.readu8(pixels, pixelOffset)
			local green = buffer.readu8(pixels, pixelOffset + 1)
			local blue = buffer.readu8(pixels, pixelOffset + 2)
			if rgbDistance(red, green, blue, skinColor) < 58 then
				continue
			end
			local value = math.max(red, green, blue) / 255
			local chroma = math.max(red, green, blue) - math.min(red, green, blue)
			if value < 0.055 or (chroma < 10 and value > 0.82) then
				continue
			end
			-- Thumbnail lighting creates many nearly-identical shades. A 32-step
			-- spatial bucket keeps gradients together without merging genuinely
			-- different tip colors such as green and purple.
			local key = math.floor(red / 32) * 64 + math.floor(green / 32) * 8 + math.floor(blue / 32)
			local bucket = histogram[key]
			if not bucket then
				bucket = {
					r = 0, g = 0, b = 0, count = 0,
					crown = 0, left = 0, right = 0, tips = 0, leftTips = 0, rightTips = 0,
					minX = x, maxX = x, minY = y, maxY = y, luminances = {},
				}
				histogram[key] = bucket
			end
			local weight = alpha / 255
			bucket.r += red * weight
			bucket.g += green * weight
			bucket.b += blue * weight
			bucket.count += weight
			bucket.minX = math.min(bucket.minX, x)
			bucket.maxX = math.max(bucket.maxX, x)
			bucket.minY = math.min(bucket.minY, y)
			bucket.maxY = math.max(bucket.maxY, y)
			if normalizedY <= 0.38 then bucket.crown += weight end
			if normalizedX <= 0.42 then bucket.left += weight end
			if normalizedX >= 0.58 then bucket.right += weight end
			if normalizedY >= 0.68 then
				bucket.tips += weight
				if normalizedX < 0.5 then bucket.leftTips += weight else bucket.rightTips += weight end
			end
			table.insert(bucket.luminances, value)
			acceptedSamples += weight
		end
	end

	local buckets: { Bucket } = {}
	for _, bucket in histogram do
		if bucket.count >= 2 then
			table.insert(buckets, bucket)
		end
	end
	-- Join adjacent lighting buckets into perceptual clusters. This is what
	-- lets a purple tip gradient reach its real regional coverage instead of
	-- being split across several individually-small RGB cells.
	local mergedBuckets: { Bucket } = {}
	for _, bucket in buckets do
		local destination: Bucket? = nil
		for _, merged in mergedBuckets do
			if perceptualDistance(bucketColor(bucket), bucketColor(merged)) < 20 then
				destination = merged
				break
			end
		end
		if destination then
			local merged = destination :: Bucket
			merged.r += bucket.r
			merged.g += bucket.g
			merged.b += bucket.b
			merged.count += bucket.count
			merged.crown += bucket.crown
			merged.left += bucket.left
			merged.right += bucket.right
			merged.tips += bucket.tips
			merged.leftTips += bucket.leftTips
			merged.rightTips += bucket.rightTips
			merged.minX = math.min(merged.minX, bucket.minX)
			merged.maxX = math.max(merged.maxX, bucket.maxX)
			merged.minY = math.min(merged.minY, bucket.minY)
			merged.maxY = math.max(merged.maxY, bucket.maxY)
			for _, luminance in bucket.luminances do table.insert(merged.luminances, luminance) end
		else
			table.insert(mergedBuckets, bucket)
		end
	end
	buckets = mergedBuckets
	local fallback = Color3.fromRGB(86, 116, 89)
	if #buckets == 0 then
		local emptyMask = buffer.create(width * height * 4)
		return {
			primary = fallback,
			secondary = fallback:Lerp(Color3.fromRGB(110, 74, 140), 0.25),
			highlight = fallback:Lerp(Color3.new(1, 1, 1), 0.28),
			shadow = fallback:Lerp(Color3.fromRGB(24, 22, 38), 0.34),
			primaryCoverage = 0,
			secondaryCoverage = 0,
			secondaryReliable = false,
			leftTipSecondaryCoverage = 0,
			rightTipSecondaryCoverage = 0,
			hairCoreMask = emptyMask,
			rawLabelMap = buffer.create(width * height * 4),
			labelMap = buffer.create(width * height * 4),
			hairCoreCoverage = 0,
			hairCoreAspect = 0.78,
			rawLabelComponents = 0,
			regularizedLabelComponents = 0,
			removedLabelPixels = 0,
			isolatedHighlightPixels = 0,
			isolatedSecondaryPixels = 0,
			rawIsolatedHighlightPixels = 0,
			rawIsolatedSecondaryPixels = 0,
			remainingIsolatedHighlightPixels = 0,
			remainingIsolatedSecondaryPixels = 0,
			massDescriptors = {},
		}
	end

	table.sort(buckets, function(left, right)
		local function score(bucket: Bucket): number
			local spatialSpan = ((bucket.maxX - bucket.minX) / boundsWidth + (bucket.maxY - bucket.minY) / boundsHeight) * 0.5
			local sidePresence = math.min(bucket.left, bucket.right) / math.max(1, bucket.count)
			local crownPresence = bucket.crown / math.max(1, bucket.count)
			local color = bucketColor(bucket)
			local skinDistance = perceptualDistance(color, skinColor)
			return bucket.count
				* (1 + math.min(0.55, spatialSpan))
				* (1 + math.min(0.35, sidePresence))
				* (1 + math.min(0.3, crownPresence))
				* math.clamp(skinDistance / 34, 0.55, 1.35)
		end
		return score(left) > score(right)
	end)

	local primaryBucket = buckets[1]
	local primary = bucketColor(primaryBucket)
	local _, _, primaryValue = primary:ToHSV()
	local secondaryBucket: Bucket? = nil
	local secondaryScore = -math.huge
	for index = 2, #buckets do
		local candidate = buckets[index]
		local candidateColor = bucketColor(candidate)
		local _, candidateSaturation, candidateValue = candidateColor:ToHSV()
		local coverage = candidate.count / math.max(1, acceptedSamples)
		local colorSeparation = perceptualDistance(primary, candidateColor)
		local tipRatio = candidate.tips / math.max(1, candidate.count)
		local sideCoherence = math.max(candidate.leftTips, candidate.rightTips) / math.max(1, candidate.count)
		local spatialSpan = (candidate.maxY - candidate.minY + 1) / boundsHeight
		local score = colorSeparation * math.sqrt(candidate.count) * (1 + tipRatio * 1.6 + sideCoherence + spatialSpan * 0.3)
		if coverage >= minimumSecondary * 0.55
			and colorSeparation >= 24
			and tipRatio >= 0.16
			and candidateValue >= 0.18
			and (candidateSaturation >= 0.16 or primaryValue < 0.18)
			and score > secondaryScore then
			secondaryScore = score
			secondaryBucket = candidate
		end
	end
	local secondaryCoverage = if secondaryBucket then secondaryBucket.count / math.max(1, acceptedSamples) else 0
	local secondaryReliable = secondaryBucket ~= nil
		and secondaryCoverage >= minimumSecondary
		and perceptualDistance(primary, bucketColor(secondaryBucket :: Bucket)) >= 28
	local secondary = if secondaryReliable
		then bucketColor(secondaryBucket :: Bucket)
		else primary:Lerp(Color3.fromRGB(110, 74, 140), 0.2)
	local highlight = percentileColor(primary, primaryBucket.luminances, 0.86)
	local shadow = percentileColor(primary, primaryBucket.luminances, 0.18)
	if perceptualDistance(primary, highlight) < 8 then
		highlight = primary:Lerp(Color3.new(1, 1, 1), 0.28)
	end
	if perceptualDistance(primary, shadow) < 8 then
		shadow = primary:Lerp(Color3.fromRGB(24, 22, 38), 0.36)
	end
	-- Keep a spatial observation instead of reducing hair to four swatches.
	-- The mask intentionally accepts the secondary hair color even when a
	-- similarly coloured ornament exists; connected spatial coverage decides
	-- which pixels form the reusable hair core.
	local hairCoreMask = buffer.create(width * height * 4)
	local labelMap = buffer.create(width * height * 4)
	local corePixels = 0
	local coreMinX = bounds.maxX
	local coreMaxX = bounds.minX
	local coreMinY = bounds.maxY
	local coreMaxY = bounds.minY
	for y = math.max(0, bounds.minY), math.min(height - 1, bounds.maxY) do
		for x = math.max(0, bounds.minX), math.min(width - 1, bounds.maxX) do
			local pixelOffset = offset(width, x, y)
			if buffer.readu8(pixels, pixelOffset + 3) < threshold then continue end
			local red = buffer.readu8(pixels, pixelOffset)
			local green = buffer.readu8(pixels, pixelOffset + 1)
			local blue = buffer.readu8(pixels, pixelOffset + 2)
			if rgbDistance(red, green, blue, skinColor) < 42 then continue end
			local distances = {
				rgbDistance(red, green, blue, primary),
				rgbDistance(red, green, blue, secondary),
				rgbDistance(red, green, blue, highlight),
				rgbDistance(red, green, blue, shadow),
			}
			local best = 1
			for index = 2, 4 do
				if distances[index] < distances[best] then best = index end
			end
			if distances[best] <= 58 then
				buffer.writeu8(hairCoreMask, pixelOffset + 3, 255)
				local labelColor = ({ primary, secondary, highlight, shadow })[best]
				buffer.writeu8(labelMap, pixelOffset, math.round(labelColor.R * 255))
				buffer.writeu8(labelMap, pixelOffset + 1, math.round(labelColor.G * 255))
				buffer.writeu8(labelMap, pixelOffset + 2, math.round(labelColor.B * 255))
				buffer.writeu8(labelMap, pixelOffset + 3, 255)
				corePixels += 1
				coreMinX = math.min(coreMinX, x)
				coreMaxX = math.max(coreMaxX, x)
				coreMinY = math.min(coreMinY, y)
				coreMaxY = math.max(coreMaxY, y)
			end
		end
	end
	-- Eight-connectivity preserves diagonal strands. Retain the largest broad
	-- hair mass as the core so small same-colour clips remain accessory input.
	local coreComponents = {}
	local visited: { [number]: boolean } = {}
	local deltas = {
		Vector2.new(-1, -1), Vector2.new(0, -1), Vector2.new(1, -1),
		Vector2.new(-1, 0), Vector2.new(1, 0),
		Vector2.new(-1, 1), Vector2.new(0, 1), Vector2.new(1, 1),
	}
	for y = math.max(0, bounds.minY), math.min(height - 1, bounds.maxY) do
		for x = math.max(0, bounds.minX), math.min(width - 1, bounds.maxX) do
			local key = y * width + x
			if visited[key] or buffer.readu8(hairCoreMask, offset(width, x, y) + 3) == 0 then continue end
			local queue = { key }
			local queueIndex = 1
			local members = {}
			visited[key] = true
			while queueIndex <= #queue do
				local current = queue[queueIndex]
				queueIndex += 1
				table.insert(members, current)
				local currentX = current % width
				local currentY = math.floor(current / width)
				for _, delta in deltas do
					local neighborX = currentX + delta.X
					local neighborY = currentY + delta.Y
					local neighborKey = neighborY * width + neighborX
					if neighborX >= 0 and neighborY >= 0 and neighborX < width and neighborY < height
						and not visited[neighborKey]
						and buffer.readu8(hairCoreMask, offset(width, neighborX, neighborY) + 3) > 0 then
						visited[neighborKey] = true
						table.insert(queue, neighborKey)
					end
				end
			end
			table.insert(coreComponents, members)
		end
	end
	table.sort(coreComponents, function(left, right) return #left > #right end)
	local retained = buffer.create(width * height * 4)
	corePixels = 0
	coreMinX = bounds.maxX
	coreMaxX = bounds.minX
	coreMinY = bounds.maxY
	coreMaxY = bounds.minY
	for componentIndex = 1, math.min(3, #coreComponents) do
		local members = coreComponents[componentIndex]
		if componentIndex > 1 and #members < #coreComponents[1] * 0.08 then break end
		for _, key in members do
			local x = key % width
			local y = math.floor(key / width)
			buffer.writeu8(retained, offset(width, x, y) + 3, 255)
			corePixels += 1
			coreMinX = math.min(coreMinX, x)
			coreMaxX = math.max(coreMaxX, x)
			coreMinY = math.min(coreMinY, y)
			coreMaxY = math.max(coreMaxY, y)
		end
	end
	hairCoreMask = retained
	local rawLabelMap = labelMap
	local labelMetrics
	labelMap, labelMetrics = HairColorAnalyzer.RegularizeHairLabelMap(
		rawLabelMap,
		size,
		hairCoreMask,
		{ primary, secondary, highlight, shadow }
	)
	local massDescriptors = buildMassDescriptors(
		labelMap,
		size,
		bounds,
		{ primary, secondary, highlight, shadow }
	)
	local coreAspect = if corePixels > 0
		then (coreMaxX - coreMinX + 1) / math.max(1, coreMaxY - coreMinY + 1)
		else 0.78
	return {
		primary = primary,
		secondary = secondary,
		highlight = highlight,
		shadow = shadow,
		primaryCoverage = primaryBucket.count / math.max(1, acceptedSamples),
		secondaryCoverage = secondaryCoverage,
		secondaryReliable = secondaryReliable,
		leftTipSecondaryCoverage = if secondaryBucket then secondaryBucket.leftTips / math.max(1, secondaryBucket.tips) else 0,
		rightTipSecondaryCoverage = if secondaryBucket then secondaryBucket.rightTips / math.max(1, secondaryBucket.tips) else 0,
		hairCoreMask = hairCoreMask,
		rawLabelMap = rawLabelMap,
		labelMap = labelMap,
		hairCoreCoverage = corePixels / math.max(1, boundsWidth * boundsHeight),
		hairCoreAspect = coreAspect,
		rawLabelComponents = labelMetrics.rawLabelComponents,
		regularizedLabelComponents = labelMetrics.regularizedLabelComponents,
		removedLabelPixels = labelMetrics.removedLabelPixels,
		isolatedHighlightPixels = labelMetrics.isolatedHighlightPixels,
		isolatedSecondaryPixels = labelMetrics.isolatedSecondaryPixels,
		rawIsolatedHighlightPixels = labelMetrics.rawIsolatedHighlightPixels,
		rawIsolatedSecondaryPixels = labelMetrics.rawIsolatedSecondaryPixels,
		remainingIsolatedHighlightPixels = labelMetrics.remainingIsolatedHighlightPixels,
		remainingIsolatedSecondaryPixels = labelMetrics.remainingIsolatedSecondaryPixels,
		massDescriptors = massDescriptors,
	}
end

return table.freeze(HairColorAnalyzer)
