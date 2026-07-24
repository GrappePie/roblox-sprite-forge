--!strict

local Raster = require(script.Parent:WaitForChild("ProceduralRaster"))

type Bounds = Raster.Bounds

export type BodyColors = {
	head: Color3,
	torso: Color3,
	leftArm: Color3,
	rightArm: Color3,
	leftLeg: Color3,
	rightLeg: Color3,
}

export type SourceRegionMetrics = {
	opaqueSamples: number,
	acceptedSamples: number,
	rejectedSkinSamples: number,
}

export type SourceRegion = {
	name: string,
	bounds: Bounds,
	excludeSkin: boolean,
	minAlpha: number,
	fallbackPrimary: Color3,
	fallbackSecondary: Color3,
	skinSignals: { Color3 },
	bands: { SleeveBand }?,
	palette: { Color3 },
}

export type SleeveBand = {
	startRatio: number,
	endRatio: number,
	color: Color3,
	samples: number,
}

export type RowProfile = {
	y: number,
	minX: number,
	maxX: number,
	centerX: number,
	width: number,
}

export type OutfitAnalysis = {
	torso: SourceRegion,
	leftSleeve: SourceRegion,
	rightSleeve: SourceRegion,
	midriff: SourceRegion,
	lowerGarment: SourceRegion,
	leftLeg: SourceRegion,
	rightLeg: SourceRegion,
	leftBoot: SourceRegion,
	rightBoot: SourceRegion,
	midriffUsesSkin: boolean,
	leftLegUsesSkin: boolean,
	rightLegUsesSkin: boolean,
	centerX: number,
	rows: { RowProfile },
	lowerGarmentMask: buffer,
	lowerGarmentSkinRatio: number,
	lowerGarmentCentralCoverage: number,
	metrics: { [string]: SourceRegionMetrics },
}

export type AccentPixel = {
	x: number,
	y: number,
	r: number,
	g: number,
	b: number,
}

export type AccentComponent = {
	pixels: { AccentPixel },
}

local ProceduralChibiOutfitAnalyzer = {}

local function offset(width: number, x: number, y: number): number
	return (y * width + x) * 4
end

local function colorDistance(red: number, green: number, blue: number, color: Color3): number
	local deltaRed = red - color.R * 255
	local deltaGreen = green - color.G * 255
	local deltaBlue = blue - color.B * 255
	return math.sqrt(deltaRed * deltaRed + deltaGreen * deltaGreen + deltaBlue * deltaBlue)
end

local function colorDistance3(left: Color3, right: Color3): number
	return colorDistance(left.R * 255, left.G * 255, left.B * 255, right)
end

local function paletteFromMask(pixels: buffer, size: Vector2, mask: buffer, maximumColors: number): { Color3 }
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	local buckets: { [number]: { red: number, green: number, blue: number, count: number, score: number } } = {}
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local pixelOffset = offset(width, x, y)
			if buffer.readu8(mask, pixelOffset + 3) == 0 or buffer.readu8(pixels, pixelOffset + 3) < 24 then continue end
			local red = buffer.readu8(pixels, pixelOffset)
			local green = buffer.readu8(pixels, pixelOffset + 1)
			local blue = buffer.readu8(pixels, pixelOffset + 2)
			local key = math.floor(red / 32) * 64 + math.floor(green / 32) * 8 + math.floor(blue / 32)
			local bucket = buckets[key] or { red = 0, green = 0, blue = 0, count = 0, score = 0 }
			bucket.red += red
			bucket.green += green
			bucket.blue += blue
			bucket.count += 1
			buckets[key] = bucket
		end
	end
	local ranked = {}
	for _, bucket in buckets do
		local red = bucket.red / bucket.count
		local green = bucket.green / bucket.count
		local blue = bucket.blue / bucket.count
		local chroma = math.max(red, green, blue) - math.min(red, green, blue)
		local darkness = 255 - (red + green + blue) / 3
		-- Saturated garment panels and dark line-art both deserve a place even
		-- when a broad neutral region has more raw samples.
		bucket.score = bucket.count * (1 + chroma / 170 + darkness / 460)
		table.insert(ranked, bucket)
	end
	table.sort(ranked, function(left, right) return left.score > right.score end)
	local palette = {}
	for _, bucket in ranked do
		local color = Color3.fromRGB(
			math.round(bucket.red / bucket.count),
			math.round(bucket.green / bucket.count),
			math.round(bucket.blue / bucket.count)
		)
		local distinct = true
		for _, existing in palette do
			if colorDistance3(existing, color) < 30 then
				distinct = false
				break
			end
		end
		if distinct then table.insert(palette, color) end
		if #palette >= maximumColors then break end
	end
	return palette
end

function ProceduralChibiOutfitAnalyzer.AnalyzeSleeveBands(
	pixels: buffer,
	size: Vector2,
	region: SourceRegion
): { SleeveBand }
	local width = math.floor(size.X)
	local descriptors: { SleeveBand } = {}
	local regionHeight = math.max(1, region.bounds.maxY - region.bounds.minY + 1)
	for y = region.bounds.minY, region.bounds.maxY do
		local buckets: { [number]: { red: number, green: number, blue: number, count: number } } = {}
		for x = region.bounds.minX, region.bounds.maxX do
			local pixelOffset = offset(width, x, y)
			if buffer.readu8(pixels, pixelOffset + 3) < region.minAlpha then continue end
			local red = buffer.readu8(pixels, pixelOffset)
			local green = buffer.readu8(pixels, pixelOffset + 1)
			local blue = buffer.readu8(pixels, pixelOffset + 2)
			if region.excludeSkin and ProceduralChibiOutfitAnalyzer.IsSkinLike(red, green, blue, region.skinSignals) then
				continue
			end
			local key = math.floor(red / 40) * 49 + math.floor(green / 40) * 7 + math.floor(blue / 40)
			local bucket = buckets[key] or { red = 0, green = 0, blue = 0, count = 0 }
			bucket.red += red
			bucket.green += green
			bucket.blue += blue
			bucket.count += 1
			buckets[key] = bucket
		end
		local dominant = nil
		for _, bucket in buckets do
			if not dominant or bucket.count > dominant.count then dominant = bucket end
		end
		if dominant then
			local color = Color3.fromRGB(
				math.round(dominant.red / dominant.count),
				math.round(dominant.green / dominant.count),
				math.round(dominant.blue / dominant.count)
			)
			local ratio = (y - region.bounds.minY) / regionHeight
			local previous = descriptors[#descriptors]
			if previous and colorDistance3(previous.color, color) <= 54 then
				local total = previous.samples + dominant.count
				previous.color = previous.color:Lerp(color, dominant.count / total)
				previous.endRatio = ratio
				previous.samples = total
			else
				table.insert(descriptors, {
					startRatio = ratio,
					endRatio = ratio,
					color = color,
					samples = dominant.count,
				})
			end
		end
	end
	-- Merge tiny observations into the closest neighbor, leaving 3-7 broad
	-- longitudinal bands instead of raster noise.
	while #descriptors > 7 do
		local smallest = 1
		for index = 2, #descriptors do
			if descriptors[index].samples < descriptors[smallest].samples then smallest = index end
		end
		local neighbor = if smallest == 1 then 2 elseif smallest == #descriptors then smallest - 1
			elseif colorDistance3(descriptors[smallest].color, descriptors[smallest - 1].color)
				<= colorDistance3(descriptors[smallest].color, descriptors[smallest + 1].color)
				then smallest - 1 else smallest + 1
		local keep = descriptors[neighbor]
		local remove = descriptors[smallest]
		keep.startRatio = math.min(keep.startRatio, remove.startRatio)
		keep.endRatio = math.max(keep.endRatio, remove.endRatio)
		keep.color = keep.color:Lerp(remove.color, remove.samples / math.max(1, keep.samples + remove.samples))
		keep.samples += remove.samples
		table.remove(descriptors, smallest)
		table.sort(descriptors, function(left, right) return left.startRatio < right.startRatio end)
	end
	return descriptors
end

function ProceduralChibiOutfitAnalyzer.IsSkinLike(
	red: number,
	green: number,
	blue: number,
	signals: { Color3 }
): boolean
	for _, signal in signals do
		-- Roblox thumbnail lighting and layered-clothing shading can move the
		-- same body color substantially away from HumanoidDescription.
		if colorDistance(red, green, blue, signal) <= 96 then
			return true
		end
		local signalRed = signal.R * 255
		local signalGreen = signal.G * 255
		local signalBlue = signal.B * 255
		local warmSignal = signalRed >= signalGreen
			and signalGreen >= signalBlue
			and signalRed - signalBlue >= 28
		local warmShadedSample = red >= 45
			and red >= green * 0.9
			and green >= blue * 0.9
			and red - blue >= 18
			and red - blue <= 145
			and green - blue <= 110
			and red - green <= 100
		if warmSignal and warmShadedSample then
			return true
		end
	end
	return false
end

local function rowProfiles(
	pixels: buffer,
	size: Vector2,
	bodySource: Bounds,
	minAlpha: number
): ({ RowProfile }, number)
	local width = math.floor(size.X)
	local rows: { RowProfile } = {}
	local centers: { number } = {}
	for y = bodySource.minY, bodySource.maxY do
		local minX = bodySource.maxX
		local maxX = bodySource.minX
		local weightedX = 0
		local alphaWeight = 0
		for x = bodySource.minX, bodySource.maxX do
			local alpha = buffer.readu8(pixels, offset(width, x, y) + 3)
			if alpha >= minAlpha then
				minX = math.min(minX, x)
				maxX = math.max(maxX, x)
				weightedX += x * alpha
				alphaWeight += alpha
			end
		end
		if alphaWeight > 0 then
			local center = weightedX / alphaWeight
			table.insert(centers, center)
			table.insert(rows, {
				y = y,
				minX = minX,
				maxX = maxX,
				centerX = center,
				width = maxX - minX + 1,
			})
		end
	end
	table.sort(centers)
	local median = if #centers > 0 then centers[math.ceil(#centers / 2)] else (bodySource.minX + bodySource.maxX) / 2
	for index, row in rows do
		local sum = 0
		local count = 0
		for neighbor = math.max(1, index - 2), math.min(#rows, index + 2) do
			if math.abs(rows[neighbor].centerX - median) <= math.max(4, rows[neighbor].width * 0.18) then
				sum += rows[neighbor].centerX
				count += 1
			end
		end
		row.centerX = if count > 0 then sum / count else median
	end
	return rows, median
end

local function regionBounds(
	bodySource: Bounds,
	centerX: number,
	minRatio: number,
	maxRatio: number,
	side: string?
): Bounds
	local bodyHeight = bodySource.maxY - bodySource.minY + 1
	local minY = bodySource.minY + math.floor(bodyHeight * minRatio)
	local maxY = bodySource.minY + math.floor(bodyHeight * maxRatio) - 1
	minY = math.clamp(minY, bodySource.minY, bodySource.maxY)
	maxY = math.clamp(maxY, minY, bodySource.maxY)
	local split = math.clamp(math.floor(centerX), bodySource.minX, bodySource.maxX - 1)
	local bodyWidth = bodySource.maxX - bodySource.minX + 1
	local torsoInset = math.max(1, math.floor(bodyWidth * 0.11))
	if side == "leftOuter" then
		return {
			minX = bodySource.minX,
			minY = minY,
			maxX = math.max(bodySource.minX, split - torsoInset),
			maxY = maxY,
		}
	elseif side == "rightOuter" then
		return {
			minX = math.min(bodySource.maxX, split + torsoInset),
			minY = minY,
			maxX = bodySource.maxX,
			maxY = maxY,
		}
	elseif side == "left" then
		return { minX = bodySource.minX, minY = minY, maxX = split, maxY = maxY }
	elseif side == "right" then
		return { minX = split + 1, minY = minY, maxX = bodySource.maxX, maxY = maxY }
	elseif side == "center" or side == "centerWide" then
		local halfWidth = math.floor(bodyWidth * (if side == "centerWide" then 0.34 else 0.23))
		return {
			minX = math.max(bodySource.minX, math.floor(centerX) - halfWidth),
			minY = minY,
			maxX = math.min(bodySource.maxX, math.floor(centerX) + halfWidth),
			maxY = maxY,
		}
	end
	return {
		minX = bodySource.minX,
		minY = minY,
		maxX = bodySource.maxX,
		maxY = maxY,
	}
end

local function analyzeRegion(
	pixels: buffer,
	size: Vector2,
	name: string,
	bounds: Bounds,
	excludeSkin: boolean,
	skinSignals: { Color3 },
	fallback: Color3
): (SourceRegion, SourceRegionMetrics, number, number)
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	local histogram: { [number]: { red: number, green: number, blue: number, count: number } } = {}
	local metrics: SourceRegionMetrics = {
		opaqueSamples = 0,
		acceptedSamples = 0,
		rejectedSkinSamples = 0,
	}
	local skinSamples = 0
	for y = math.max(0, bounds.minY), math.min(height - 1, bounds.maxY) do
		for x = math.max(0, bounds.minX), math.min(width - 1, bounds.maxX) do
			local pixelOffset = offset(width, x, y)
			if buffer.readu8(pixels, pixelOffset + 3) < 32 then
				continue
			end
			metrics.opaqueSamples += 1
			local red = buffer.readu8(pixels, pixelOffset)
			local green = buffer.readu8(pixels, pixelOffset + 1)
			local blue = buffer.readu8(pixels, pixelOffset + 2)
			local skinLike = ProceduralChibiOutfitAnalyzer.IsSkinLike(red, green, blue, skinSignals)
			if skinLike then
				skinSamples += 1
			end
			if excludeSkin and skinLike then
				metrics.rejectedSkinSamples += 1
				continue
			end
			metrics.acceptedSamples += 1
			local key = math.floor(red / 16) * 256 + math.floor(green / 16) * 16 + math.floor(blue / 16)
			local bucket = histogram[key]
			if bucket then
				bucket.red += red
				bucket.green += green
				bucket.blue += blue
				bucket.count += 1
			else
				histogram[key] = { red = red, green = green, blue = blue, count = 1 }
			end
		end
	end
	local buckets = {}
	for _, bucket in histogram do
		table.insert(buckets, bucket)
	end
	table.sort(buckets, function(a, b)
		return a.count > b.count
	end)
	local function bucketColor(index: number, default: Color3): Color3
		local bucket = buckets[index]
		if not bucket then
			return default
		end
		return Color3.fromRGB(
			math.round(bucket.red / bucket.count),
			math.round(bucket.green / bucket.count),
			math.round(bucket.blue / bucket.count)
		)
	end
	local primary = bucketColor(1, fallback)
	local secondary = bucketColor(2, primary:Lerp(Color3.new(), 0.18))
	local palette = {}
	for index = 1, math.min(6, #buckets) do
		table.insert(palette, bucketColor(index, primary))
	end
	if #palette == 0 then table.insert(palette, primary) end
	return {
		name = name,
		bounds = bounds,
		excludeSkin = excludeSkin,
		minAlpha = 32,
		fallbackPrimary = primary,
		fallbackSecondary = secondary,
		skinSignals = skinSignals,
		palette = palette,
	}, metrics, skinSamples, metrics.opaqueSamples
end

function ProceduralChibiOutfitAnalyzer.Analyze(
	pixels: buffer,
	size: Vector2,
	bodySource: Bounds,
	bodyColors: BodyColors
): OutfitAnalysis
	local rows, centerX = rowProfiles(pixels, size, bodySource, 24)
	local regions: { [string]: SourceRegion } = {}
	local metrics: { [string]: SourceRegionMetrics } = {}
	local skinRatios: { [string]: number } = {}
	local definitions = {
		{ "torso", 0.00, 0.35, "center", false, { bodyColors.torso }, bodyColors.torso },
		{ "leftSleeve", 0.00, 0.44, "leftOuter", true, { bodyColors.leftArm, bodyColors.head }, bodyColors.leftArm },
		{ "rightSleeve", 0.00, 0.44, "rightOuter", true, { bodyColors.rightArm, bodyColors.head }, bodyColors.rightArm },
		{ "midriff", 0.35, 0.43, "center", false, { bodyColors.torso, bodyColors.head }, bodyColors.torso },
		-- Warm rainbow/pink skirt panels can resemble shaded skin numerically;
		-- preserve the complete garment texture in this central region.
		{ "lowerGarment", 0.30, 0.62, "centerWide", false, { bodyColors.leftLeg, bodyColors.rightLeg }, bodyColors.torso },
		{ "leftLeg", 0.62, 0.83, "left", false, { bodyColors.leftLeg, bodyColors.head }, bodyColors.leftLeg },
		{ "rightLeg", 0.62, 0.83, "right", false, { bodyColors.rightLeg, bodyColors.head }, bodyColors.rightLeg },
		{ "leftBoot", 0.83, 1.00, "left", true, { bodyColors.leftLeg, bodyColors.head }, Color3.fromRGB(24, 25, 34) },
		{ "rightBoot", 0.83, 1.00, "right", true, { bodyColors.rightLeg, bodyColors.head }, Color3.fromRGB(24, 25, 34) },
	}
	for _, definition in definitions do
		local name = definition[1] :: string
		local region, regionMetrics, skinSamples, opaqueSamples = analyzeRegion(
			pixels,
			size,
			name,
			regionBounds(
				bodySource,
				centerX,
				definition[2] :: number,
				definition[3] :: number,
				definition[4] :: string?
			),
			definition[5] :: boolean,
			definition[6] :: { Color3 },
			definition[7] :: Color3
		)
		regions[name] = region
		metrics[name] = regionMetrics
		skinRatios[name] = skinSamples / math.max(1, opaqueSamples)
	end
	regions.leftSleeve.bands = ProceduralChibiOutfitAnalyzer.AnalyzeSleeveBands(pixels, size, regions.leftSleeve)
	regions.rightSleeve.bands = ProceduralChibiOutfitAnalyzer.AnalyzeSleeveBands(pixels, size, regions.rightSleeve)
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	local lowerGarmentMask = buffer.create(width * height * 4)
	local garment = regions.lowerGarment
	local garmentWidth = garment.bounds.maxX - garment.bounds.minX + 1
	local garmentOpaque = 0
	local garmentSkin = 0
	for y = garment.bounds.minY, garment.bounds.maxY do
		for x = garment.bounds.minX, garment.bounds.maxX do
			local pixelOffset = offset(width, x, y)
			if buffer.readu8(pixels, pixelOffset + 3) < garment.minAlpha then continue end
			garmentOpaque += 1
			local red = buffer.readu8(pixels, pixelOffset)
			local green = buffer.readu8(pixels, pixelOffset + 1)
			local blue = buffer.readu8(pixels, pixelOffset + 2)
			local chroma = math.max(red, green, blue) - math.min(red, green, blue)
			local skinLike = ProceduralChibiOutfitAnalyzer.IsSkinLike(
				red, green, blue, { bodyColors.leftArm, bodyColors.rightArm, bodyColors.leftLeg, bodyColors.rightLeg, bodyColors.head }
			)
			if skinLike then garmentSkin += 1 end
			local central = math.abs(x - centerX) <= garmentWidth * 0.32
			-- Warm pixels in the center may be legitimate skirt panels. Warm
			-- side islands are much more likely to be hands and stay excluded.
			if not skinLike or (central and chroma >= 38) then
				buffer.writeu8(lowerGarmentMask, pixelOffset + 3, 255)
			end
		end
	end
	local garmentComponents = Raster.ConnectedComponents(lowerGarmentMask, size, pixels, 1, 8)
	local centralGarmentMask = buffer.create(width * height * 4)
	local centralPixels = 0
	for _, component in garmentComponents do
		local nearCenter = math.abs(component.centroid.X - centerX) <= garmentWidth * 0.34
		local touchesWaist = component.bounds.minY <= garment.bounds.minY + math.floor(
			(garment.bounds.maxY - garment.bounds.minY + 1) * 0.4
		)
		if nearCenter and (touchesWaist or component.area >= garmentWidth * 0.16) then
			for _, pixel in component.pixels do
				buffer.writeu8(centralGarmentMask, offset(width, pixel.x, pixel.y) + 3, 255)
				centralPixels += 1
			end
		end
	end
	local garmentPalette = paletteFromMask(pixels, size, centralGarmentMask, 6)
	if #garmentPalette > 0 then
		regions.lowerGarment.palette = garmentPalette
		regions.lowerGarment.fallbackPrimary = garmentPalette[1]
		regions.lowerGarment.fallbackSecondary = garmentPalette[2] or garmentPalette[1]
	end
	return {
		torso = regions.torso,
		leftSleeve = regions.leftSleeve,
		rightSleeve = regions.rightSleeve,
		midriff = regions.midriff,
		lowerGarment = regions.lowerGarment,
		leftLeg = regions.leftLeg,
		rightLeg = regions.rightLeg,
		leftBoot = regions.leftBoot,
		rightBoot = regions.rightBoot,
		midriffUsesSkin = skinRatios.midriff >= 0.25,
		leftLegUsesSkin = skinRatios.leftLeg >= 0.28,
		rightLegUsesSkin = skinRatios.rightLeg >= 0.28,
		centerX = centerX,
		rows = rows,
		lowerGarmentMask = centralGarmentMask,
		lowerGarmentSkinRatio = garmentSkin / math.max(1, garmentOpaque),
		lowerGarmentCentralCoverage = centralPixels / math.max(1, garmentWidth * (garment.bounds.maxY - garment.bounds.minY + 1)),
		metrics = metrics,
	}
end

function ProceduralChibiOutfitAnalyzer.FindAccentComponents(
	pixels: buffer,
	size: Vector2,
	region: SourceRegion
): { AccentComponent }
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	local visited: { [number]: boolean } = {}
	local candidates: { [number]: boolean } = {}
	local primary = region.fallbackPrimary
	local regionArea = math.max(1, (region.bounds.maxX - region.bounds.minX + 1) * (region.bounds.maxY - region.bounds.minY + 1))
	for y = math.max(0, region.bounds.minY), math.min(height - 1, region.bounds.maxY) do
		for x = math.max(0, region.bounds.minX), math.min(width - 1, region.bounds.maxX) do
			local pixelOffset = offset(width, x, y)
			if buffer.readu8(pixels, pixelOffset + 3) < 96 then
				continue
			end
			local red = buffer.readu8(pixels, pixelOffset)
			local green = buffer.readu8(pixels, pixelOffset + 1)
			local blue = buffer.readu8(pixels, pixelOffset + 2)
			local chroma = math.max(red, green, blue) - math.min(red, green, blue)
			if colorDistance(red, green, blue, primary) >= 74 or chroma >= 92 then
				candidates[y * width + x] = true
			end
		end
	end
	local components: { AccentComponent } = {}
	for key in candidates do
		if visited[key] then
			continue
		end
		local queue = { key }
		local head = 1
		local component: { AccentPixel } = {}
		visited[key] = true
		while head <= #queue do
			local current = queue[head]
			head += 1
			local x = current % width
			local y = math.floor(current / width)
			local pixelOffset = offset(width, x, y)
			table.insert(component, {
				x = x,
				y = y,
				r = buffer.readu8(pixels, pixelOffset),
				g = buffer.readu8(pixels, pixelOffset + 1),
				b = buffer.readu8(pixels, pixelOffset + 2),
			})
			for _, delta in {
				Vector2.new(-1, 0),
				Vector2.new(1, 0),
				Vector2.new(0, -1),
				Vector2.new(0, 1),
			} do
				local neighborX = x + delta.X
				local neighborY = y + delta.Y
				local neighborKey = neighborY * width + neighborX
				if neighborX >= region.bounds.minX
					and neighborX <= region.bounds.maxX
					and neighborY >= region.bounds.minY
					and neighborY <= region.bounds.maxY
					and candidates[neighborKey]
					and not visited[neighborKey] then
					visited[neighborKey] = true
					table.insert(queue, neighborKey)
				end
			end
		end
		if #component >= 2 and #component <= regionArea * 0.42 then
			table.insert(components, { pixels = component })
		end
	end
	return components
end

return table.freeze(ProceduralChibiOutfitAnalyzer)
