--!strict

export type Options = {
	PaletteSize: number,
	LockedColors: { Color3 },
	OutlineColor: Color3,
	OutlineEnabled: boolean?,
	AlphaThreshold: number?,
}

export type Metrics = {
	requestedColors: number,
	paletteColors: number,
	finalColors: number,
}

type PaletteColor = {
	r: number,
	g: number,
	b: number,
}

type ColorBucket = {
	r: number,
	g: number,
	b: number,
	count: number,
}

local ProceduralImageFinalizer = {}

local function pixelOffset(width: number, x: number, y: number): number
	return (y * width + x) * 4
end

local function colorBytes(color: Color3): (number, number, number)
	return math.round(color.R * 255), math.round(color.G * 255), math.round(color.B * 255)
end

local function colorKey(red: number, green: number, blue: number): number
	return red * 65536 + green * 256 + blue
end

local function colorDistance(
	redA: number,
	greenA: number,
	blueA: number,
	redB: number,
	greenB: number,
	blueB: number
): number
	local red = redA - redB
	local green = greenA - greenB
	local blue = blueA - blueB
	return red * red * 2 + green * green * 3 + blue * blue
end

local function appendUnique(
	palette: { PaletteColor },
	seen: { [number]: boolean },
	red: number,
	green: number,
	blue: number,
	limit: number
)
	if #palette >= limit then
		return
	end
	red = math.clamp(math.round(red), 0, 255)
	green = math.clamp(math.round(green), 0, 255)
	blue = math.clamp(math.round(blue), 0, 255)
	local key = colorKey(red, green, blue)
	if seen[key] then
		return
	end
	seen[key] = true
	table.insert(palette, { r = red, g = green, b = blue })
end

local function buildPalette(
	pixels: buffer,
	size: Vector2,
	requestedSize: number,
	lockedColors: { Color3 },
	alphaThreshold: number
): { PaletteColor }
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	local paletteSize = math.clamp(math.floor(requestedSize), 4, 96)
	local palette: { PaletteColor } = {}
	local seen: { [number]: boolean } = {}

	for _, color in lockedColors do
		local red, green, blue = colorBytes(color)
		appendUnique(palette, seen, red, green, blue, paletteSize)
	end

	local histogram: { [number]: ColorBucket } = {}
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local offset = pixelOffset(width, x, y)
			local alpha = buffer.readu8(pixels, offset + 3)
			if alpha < alphaThreshold then
				continue
			end
			local red = buffer.readu8(pixels, offset)
			local green = buffer.readu8(pixels, offset + 1)
			local blue = buffer.readu8(pixels, offset + 2)
			if seen[colorKey(red, green, blue)] then
				continue
			end
			local bucketKey =
				math.floor(red / 8) * 1024 + math.floor(green / 8) * 32 + math.floor(blue / 8)
			local bucket = histogram[bucketKey]
			local weight = alpha / 255
			if bucket then
				bucket.r += red * weight
				bucket.g += green * weight
				bucket.b += blue * weight
				bucket.count += weight
			else
				histogram[bucketKey] = {
					r = red * weight,
					g = green * weight,
					b = blue * weight,
					count = weight,
				}
			end
		end
	end

	local buckets: { ColorBucket } = {}
	for _, bucket in histogram do
		table.insert(buckets, {
			r = bucket.r / bucket.count,
			g = bucket.g / bucket.count,
			b = bucket.b / bucket.count,
			count = bucket.count,
		})
	end
	table.sort(buckets, function(a, b)
		return a.count > b.count
	end)

	while #palette < paletteSize and #buckets > 0 do
		local best: ColorBucket? = nil
		local bestScore = -1
		for _, bucket in buckets do
			local roundedKey = colorKey(
				math.clamp(math.round(bucket.r), 0, 255),
				math.clamp(math.round(bucket.g), 0, 255),
				math.clamp(math.round(bucket.b), 0, 255)
			)
			if seen[roundedKey] then
				continue
			end
			local nearestDistance = math.huge
			for _, color in palette do
				nearestDistance = math.min(
					nearestDistance,
					colorDistance(bucket.r, bucket.g, bucket.b, color.r, color.g, color.b)
				)
			end
			if #palette == 0 then
				nearestDistance = 1
			end
			local score = nearestDistance * (1 + math.log(bucket.count))
			if score > bestScore then
				bestScore = score
				best = bucket
			end
		end
		if not best then
			break
		end
		appendUnique(palette, seen, best.r, best.g, best.b, paletteSize)
	end

	if #palette == 0 then
		appendUnique(palette, seen, 255, 255, 255, paletteSize)
	end
	return palette
end

local function nearestColor(
	red: number,
	green: number,
	blue: number,
	palette: { PaletteColor }
): PaletteColor
	local nearest = palette[1]
	local nearestDistance = math.huge
	for _, color in palette do
		local distance = colorDistance(red, green, blue, color.r, color.g, color.b)
		if distance < nearestDistance then
			nearestDistance = distance
			nearest = color
		end
	end
	return nearest
end

function ProceduralImageFinalizer.Quantize(
	pixels: buffer,
	size: Vector2,
	paletteSize: number,
	lockedColors: { Color3 },
	alphaThreshold: number?
): buffer
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	local threshold = math.clamp(math.floor(alphaThreshold or 48), 1, 255)
	local palette = buildPalette(pixels, size, paletteSize, lockedColors, threshold)
	local result = buffer.create(width * height * 4)
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local offset = pixelOffset(width, x, y)
			local alpha = buffer.readu8(pixels, offset + 3)
			if alpha < threshold then
				continue
			end
			local color = nearestColor(
				buffer.readu8(pixels, offset),
				buffer.readu8(pixels, offset + 1),
				buffer.readu8(pixels, offset + 2),
				palette
			)
			buffer.writeu8(result, offset, color.r)
			buffer.writeu8(result, offset + 1, color.g)
			buffer.writeu8(result, offset + 2, color.b)
			buffer.writeu8(result, offset + 3, 255)
		end
	end
	return result
end

function ProceduralImageFinalizer.ApplyExteriorOutline(
	pixels: buffer,
	size: Vector2,
	outlineColor: Color3
): buffer
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	local result = buffer.create(buffer.len(pixels))
	buffer.copy(result, 0, pixels, 0, buffer.len(pixels))
	local outlineRed, outlineGreen, outlineBlue = colorBytes(outlineColor)
	local directions: { Vector2 } = {
		Vector2.new(-1, 0),
		Vector2.new(1, 0),
		Vector2.new(0, -1),
		Vector2.new(0, 1),
	}
	local exterior = table.create(width * height, false)
	local queueX: { number } = {}
	local queueY: { number } = {}
	local readIndex = 1
	local function enqueueIfBackground(x: number, y: number)
		local index = y * width + x + 1
		if exterior[index] or buffer.readu8(pixels, pixelOffset(width, x, y) + 3) > 0 then
			return
		end
		exterior[index] = true
		table.insert(queueX, x)
		table.insert(queueY, y)
	end
	for x = 0, width - 1 do
		enqueueIfBackground(x, 0)
		enqueueIfBackground(x, height - 1)
	end
	for y = 0, height - 1 do
		enqueueIfBackground(0, y)
		enqueueIfBackground(width - 1, y)
	end
	while readIndex <= #queueX do
		local x = queueX[readIndex]
		local y = queueY[readIndex]
		readIndex += 1
		for _, direction in directions do
			local neighborX = x + direction.X
			local neighborY = y + direction.Y
			if neighborX >= 0 and neighborY >= 0 and neighborX < width and neighborY < height then
				enqueueIfBackground(neighborX, neighborY)
			end
		end
	end

	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local offset = pixelOffset(width, x, y)
			if buffer.readu8(pixels, offset + 3) > 0 or not exterior[y * width + x + 1] then
				continue
			end
			local touchesSilhouette = false
			for _, direction in directions do
				local neighborX = x + direction.X
				local neighborY = y + direction.Y
				if neighborX >= 0
					and neighborY >= 0
					and neighborX < width
					and neighborY < height
					and buffer.readu8(
						pixels,
						pixelOffset(width, neighborX, neighborY) + 3
					) > 0 then
					touchesSilhouette = true
					break
				end
			end
			if touchesSilhouette then
				buffer.writeu8(result, offset, outlineRed)
				buffer.writeu8(result, offset + 1, outlineGreen)
				buffer.writeu8(result, offset + 2, outlineBlue)
				buffer.writeu8(result, offset + 3, 255)
			end
		end
	end
	return result
end

function ProceduralImageFinalizer.Finalize(
	pixels: buffer,
	size: Vector2,
	options: Options
): buffer
	local result = ProceduralImageFinalizer.FinalizeWithMetrics(pixels, size, options)
	return result
end

function ProceduralImageFinalizer.FinalizeWithMetrics(
	pixels: buffer,
	size: Vector2,
	options: Options
): (buffer, Metrics)
	local lockedColors = table.clone(options.LockedColors)
	table.insert(lockedColors, options.OutlineColor)
	local requestedColors = math.clamp(math.floor(options.PaletteSize), 4, 96)
	local result = ProceduralImageFinalizer.Quantize(
		pixels,
		size,
		requestedColors,
		lockedColors,
		options.AlphaThreshold
	)
	local paletteColors = ProceduralImageFinalizer.CountOpaqueColors(result, size)
	if options.OutlineEnabled ~= false then
		result = ProceduralImageFinalizer.ApplyExteriorOutline(
			result,
			size,
			options.OutlineColor
		)
	end
	return result, {
		requestedColors = requestedColors,
		paletteColors = paletteColors,
		finalColors = ProceduralImageFinalizer.CountOpaqueColors(result, size),
	}
end

function ProceduralImageFinalizer.CountOpaqueColors(
	pixels: buffer,
	size: Vector2
): number
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	local colors: { [number]: boolean } = {}
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local offset = pixelOffset(width, x, y)
			if buffer.readu8(pixels, offset + 3) > 0 then
				colors[colorKey(
					buffer.readu8(pixels, offset),
					buffer.readu8(pixels, offset + 1),
					buffer.readu8(pixels, offset + 2)
				)] = true
			end
		end
	end
	local count = 0
	for _ in colors do
		count += 1
	end
	return count
end

return table.freeze(ProceduralImageFinalizer)
