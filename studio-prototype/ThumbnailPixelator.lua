--!strict

local AssetService = game:GetService("AssetService")
local Players = game:GetService("Players")

export type Options = {
	Size: number,
	ChannelLevels: number,
	PaletteSize: number?,
	HeadPaletteSize: number?,
	BodyPaletteSize: number?,
	AccentPreservation: number?,
	AlphaThreshold: number,
	OutlineRadius: number,
	OutlineColor: Color3,
	CropPadding: number?,
	HeadRatio: number?,
	CleanIsolatedPixels: boolean?,
}

local ThumbnailPixelator = {}

local function sourceOffset(sourceWidth: number, x: number, y: number): number
	return (y * sourceWidth + x) * 4
end

local function targetOffset(targetSize: number, x: number, y: number): number
	return (y * targetSize + x) * 4
end

type ColorBucket = {
	r: number,
	g: number,
	b: number,
	count: number,
}

type PaletteColor = {
	r: number,
	g: number,
	b: number,
}

type PixelBounds = {
	minX: number,
	minY: number,
	maxX: number,
	maxY: number,
}

local function colorDistance(
	r1: number,
	g1: number,
	b1: number,
	r2: number,
	g2: number,
	b2: number
): number
	local red = r1 - r2
	local green = g1 - g2
	local blue = b1 - b2
	return red * red * 2 + green * green * 3 + blue * blue
end

local function buildAdaptivePalette(
	redValues: { number },
	greenValues: { number },
	blueValues: { number },
	occupied: { boolean },
	requestedSize: number
): { PaletteColor }
	local histogram: { [number]: ColorBucket } = {}
	for index, isOccupied in occupied do
		if not isOccupied then
			continue
		end
		local red = redValues[index]
		local green = greenValues[index]
		local blue = blueValues[index]
		-- Five-bit buckets remove one-off texture noise before palette fitting.
		local key = math.floor(red / 8) * 1024 + math.floor(green / 8) * 32 + math.floor(blue / 8)
		local bucket = histogram[key]
		if bucket then
			bucket.r += red
			bucket.g += green
			bucket.b += blue
			bucket.count += 1
		else
			histogram[key] = {
				r = red,
				g = green,
				b = blue,
				count = 1,
			}
		end
	end

	local buckets: { ColorBucket } = {}
	for _, summed in histogram do
		table.insert(buckets, {
			r = summed.r / summed.count,
			g = summed.g / summed.count,
			b = summed.b / summed.count,
			count = summed.count,
		})
	end
	table.sort(buckets, function(a, b)
		return a.count > b.count
	end)
	if #buckets == 0 then
		return {}
	end

	local paletteSize = math.clamp(math.floor(requestedSize), 4, math.min(32, #buckets))
	local palette: { PaletteColor } = {
		{
			r = buckets[1].r,
			g = buckets[1].g,
			b = buckets[1].b,
		},
	}

	-- Deterministic farthest-point seeds keep small but distinctive colors such
	-- as skin, eyes and trim instead of letting black/white consume the palette.
	while #palette < paletteSize do
		local bestBucket = buckets[1]
		local bestScore = -1
		for _, bucket in buckets do
			local nearest = math.huge
			for _, color in palette do
				nearest = math.min(
					nearest,
					colorDistance(bucket.r, bucket.g, bucket.b, color.r, color.g, color.b)
				)
			end
			local score = nearest * (1 + math.log(bucket.count))
			if score > bestScore then
				bestScore = score
				bestBucket = bucket
			end
		end
		table.insert(palette, {
			r = bestBucket.r,
			g = bestBucket.g,
			b = bestBucket.b,
		})
	end

	for _ = 1, 4 do
		local sums = table.create(paletteSize)
		for index = 1, paletteSize do
			sums[index] = { r = 0, g = 0, b = 0, count = 0 }
		end
		for _, bucket in buckets do
			local nearestIndex = 1
			local nearestDistance = math.huge
			for index, color in palette do
				local distance = colorDistance(bucket.r, bucket.g, bucket.b, color.r, color.g, color.b)
				if distance < nearestDistance then
					nearestDistance = distance
					nearestIndex = index
				end
			end
			local sum = sums[nearestIndex]
			sum.r += bucket.r * bucket.count
			sum.g += bucket.g * bucket.count
			sum.b += bucket.b * bucket.count
			sum.count += bucket.count
		end
		for index, sum in sums do
			if sum.count > 0 then
				palette[index] = {
					r = sum.r / sum.count,
					g = sum.g / sum.count,
					b = sum.b / sum.count,
				}
			end
		end
	end

	return palette
end

local function nearestPaletteColor(
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
			nearest = color
			nearestDistance = distance
		end
	end
	return nearest
end

local function findAlphaBounds(
	sourcePixels: buffer,
	sourceWidth: number,
	sourceHeight: number,
	alphaThreshold: number
): PixelBounds
	local minX = sourceWidth
	local minY = sourceHeight
	local maxX = -1
	local maxY = -1
	for y = 0, sourceHeight - 1 do
		for x = 0, sourceWidth - 1 do
			local alpha = buffer.readu8(sourcePixels, sourceOffset(sourceWidth, x, y) + 3)
			if alpha >= alphaThreshold then
				minX = math.min(minX, x)
				minY = math.min(minY, y)
				maxX = math.max(maxX, x)
				maxY = math.max(maxY, y)
			end
		end
	end
	if maxX < minX or maxY < minY then
		return {
			minX = 0,
			minY = 0,
			maxX = sourceWidth - 1,
			maxY = sourceHeight - 1,
		}
	end
	return {
		minX = minX,
		minY = minY,
		maxX = maxX,
		maxY = maxY,
	}
end

local function expandBounds(
	bounds: PixelBounds,
	sourceWidth: number,
	sourceHeight: number,
	paddingFraction: number
): PixelBounds
	local contentWidth = bounds.maxX - bounds.minX + 1
	local contentHeight = bounds.maxY - bounds.minY + 1
	local padding = math.floor(math.max(contentWidth, contentHeight) * paddingFraction + 0.5)
	return {
		minX = math.max(0, bounds.minX - padding),
		minY = math.max(0, bounds.minY - padding),
		maxX = math.min(sourceWidth - 1, bounds.maxX + padding),
		maxY = math.min(sourceHeight - 1, bounds.maxY + padding),
	}
end

local function cleanIsolatedOccupancy(
	occupied: { boolean },
	targetSize: number
): { boolean }
	local cleaned = table.clone(occupied)
	for y = 0, targetSize - 1 do
		for x = 0, targetSize - 1 do
			local index = y * targetSize + x + 1
			if not occupied[index] then
				continue
			end
			local neighborCount = 0
			for neighborY = math.max(0, y - 1), math.min(targetSize - 1, y + 1) do
				for neighborX = math.max(0, x - 1), math.min(targetSize - 1, x + 1) do
					if neighborX == x and neighborY == y then
						continue
					end
					if occupied[neighborY * targetSize + neighborX + 1] then
						neighborCount += 1
					end
				end
			end
			if neighborCount == 0 then
				cleaned[index] = false
			end
		end
	end
	return cleaned
end

function ThumbnailPixelator.ProcessBuffer(
	sourcePixels: buffer,
	sourceSize: Vector2,
	options: Options
): buffer
	local targetSize = math.clamp(math.floor(options.Size), 8, 256)
	local sourceWidth = math.floor(sourceSize.X)
	local sourceHeight = math.floor(sourceSize.Y)
	local result = buffer.create(targetSize * targetSize * 4)
	local occupied = table.create(targetSize * targetSize, false)
	local redValues = table.create(targetSize * targetSize, 0)
	local greenValues = table.create(targetSize * targetSize, 0)
	local blueValues = table.create(targetSize * targetSize, 0)
	local rawBounds = findAlphaBounds(sourcePixels, sourceWidth, sourceHeight, math.min(options.AlphaThreshold, 16))
	local bounds = expandBounds(
		rawBounds,
		sourceWidth,
		sourceHeight,
		math.clamp(options.CropPadding or 0.025, 0, 0.15)
	)
	local contentWidth = bounds.maxX - bounds.minX + 1
	local contentHeight = bounds.maxY - bounds.minY + 1
	local margin = math.max(2, math.floor(options.OutlineRadius) + 1)
	local availableSize = math.max(1, targetSize - margin * 2)
	local fitScale = math.min(availableSize / contentWidth, availableSize / contentHeight)
	local destinationWidth = math.max(1, math.floor(contentWidth * fitScale + 0.5))
	local destinationHeight = math.max(1, math.floor(contentHeight * fitScale + 0.5))
	local destinationX = math.floor((targetSize - destinationWidth) / 2)
	local destinationY = math.floor((targetSize - destinationHeight) / 2)
	local headCutoffY = destinationY
		+ math.floor(destinationHeight * math.clamp(options.HeadRatio or 0.43, 0.25, 0.6))

	for localY = 0, destinationHeight - 1 do
		local targetY = destinationY + localY
		local sourceY0 = bounds.minY + math.floor((localY * contentHeight) / destinationHeight)
		local sourceY1 = math.max(
			sourceY0,
			bounds.minY + math.ceil(((localY + 1) * contentHeight) / destinationHeight) - 1
		)
		for localX = 0, destinationWidth - 1 do
			local targetX = destinationX + localX
			local sourceX0 = bounds.minX + math.floor((localX * contentWidth) / destinationWidth)
			local sourceX1 = math.max(
				sourceX0,
				bounds.minX + math.ceil(((localX + 1) * contentWidth) / destinationWidth) - 1
			)
			local alphaSum = 0
			local premultipliedR = 0
			local premultipliedG = 0
			local premultipliedB = 0
			local sampleCount = 0
			local strongestChroma = 0
			local accentR = 0
			local accentG = 0
			local accentB = 0

			for sourceY = sourceY0, math.min(sourceY1, bounds.maxY) do
				for sourceX = sourceX0, math.min(sourceX1, bounds.maxX) do
					local offset = sourceOffset(sourceWidth, sourceX, sourceY)
					local alpha = buffer.readu8(sourcePixels, offset + 3)
					local red = buffer.readu8(sourcePixels, offset)
					local green = buffer.readu8(sourcePixels, offset + 1)
					local blue = buffer.readu8(sourcePixels, offset + 2)
					alphaSum += alpha
					premultipliedR += red * alpha
					premultipliedG += green * alpha
					premultipliedB += blue * alpha
					local chroma = math.max(red, green, blue) - math.min(red, green, blue)
					if alpha >= options.AlphaThreshold and chroma > strongestChroma then
						strongestChroma = chroma
						accentR = red
						accentG = green
						accentB = blue
					end
					sampleCount += 1
				end
			end

			local averageAlpha = if sampleCount > 0 then alphaSum / sampleCount else 0
			local targetIndex = targetY * targetSize + targetX + 1
			if averageAlpha >= options.AlphaThreshold and alphaSum > 0 then
				local red = premultipliedR / alphaSum
				local green = premultipliedG / alphaSum
				local blue = premultipliedB / alphaSum
				local averageChroma = math.max(red, green, blue) - math.min(red, green, blue)
				local accentWeight = math.clamp(options.AccentPreservation or 0, 0, 0.5)
				if strongestChroma >= 80 and strongestChroma - averageChroma >= 36 then
					red = red + (accentR - red) * accentWeight
					green = green + (accentG - green) * accentWeight
					blue = blue + (accentB - blue) * accentWeight
				end
				redValues[targetIndex] = red
				greenValues[targetIndex] = green
				blueValues[targetIndex] = blue
				occupied[targetIndex] = true
			end
		end
	end

	if options.CleanIsolatedPixels ~= false then
		occupied = cleanIsolatedOccupancy(occupied, targetSize)
	end

	local paletteSize = options.PaletteSize
		or math.clamp(options.ChannelLevels * options.ChannelLevels, 8, 32)
	local headOccupied = table.create(targetSize * targetSize, false)
	local bodyOccupied = table.create(targetSize * targetSize, false)
	for index, isOccupied in occupied do
		if not isOccupied then
			continue
		end
		local y = math.floor((index - 1) / targetSize)
		if y < headCutoffY then
			headOccupied[index] = true
		else
			bodyOccupied[index] = true
		end
	end
	local headPalette = buildAdaptivePalette(
		redValues,
		greenValues,
		blueValues,
		headOccupied,
		options.HeadPaletteSize or math.min(paletteSize, 18)
	)
	local bodyPalette = buildAdaptivePalette(
		redValues,
		greenValues,
		blueValues,
		bodyOccupied,
		options.BodyPaletteSize or paletteSize
	)
	if #headPalette == 0 then
		headPalette = bodyPalette
	elseif #bodyPalette == 0 then
		bodyPalette = headPalette
	end
	for y = 0, targetSize - 1 do
		for x = 0, targetSize - 1 do
			local index = y * targetSize + x + 1
			if not occupied[index] then
				continue
			end
			local regionalPalette = if y < headCutoffY then headPalette else bodyPalette
			local color = nearestPaletteColor(
				redValues[index],
				greenValues[index],
				blueValues[index],
				regionalPalette
			)
			local offset = targetOffset(targetSize, x, y)
			buffer.writeu8(result, offset, math.round(color.r))
			buffer.writeu8(result, offset + 1, math.round(color.g))
			buffer.writeu8(result, offset + 2, math.round(color.b))
			buffer.writeu8(result, offset + 3, 255)
		end
	end

	local radius = math.max(0, math.floor(options.OutlineRadius))
	if radius > 0 then
		local outlined = buffer.create(targetSize * targetSize * 4)
		buffer.copy(outlined, 0, result, 0, buffer.len(result))
		local outlineR = math.round(options.OutlineColor.R * 255)
		local outlineG = math.round(options.OutlineColor.G * 255)
		local outlineB = math.round(options.OutlineColor.B * 255)

		for y = 0, targetSize - 1 do
			for x = 0, targetSize - 1 do
				local index = y * targetSize + x + 1
				if occupied[index] then
					continue
				end
				local touchesSilhouette = false
				for neighborY = math.max(0, y - radius), math.min(targetSize - 1, y + radius) do
					for neighborX = math.max(0, x - radius), math.min(targetSize - 1, x + radius) do
						local manhattanDistance = math.abs(neighborX - x) + math.abs(neighborY - y)
						if manhattanDistance <= radius
							and occupied[neighborY * targetSize + neighborX + 1] then
							touchesSilhouette = true
							break
						end
					end
					if touchesSilhouette then
						break
					end
				end
				if touchesSilhouette then
					local offset = targetOffset(targetSize, x, y)
					buffer.writeu8(outlined, offset, outlineR)
					buffer.writeu8(outlined, offset + 1, outlineG)
					buffer.writeu8(outlined, offset + 2, outlineB)
					buffer.writeu8(outlined, offset + 3, 255)
				end
			end
		end
		result = outlined
	end

	return result
end

function ThumbnailPixelator.Create(userId: number, options: Options): EditableImage
	local thumbnailUri = Players:GetUserThumbnailAsync(
		userId,
		Enum.ThumbnailType.AvatarThumbnail,
		Enum.ThumbnailSize.Size420x420
	)
	local sourceImage = AssetService:CreateEditableImageAsync(Content.fromUri(thumbnailUri))
	local sourceSize = sourceImage.Size
	local sourcePixels = sourceImage:ReadPixelsBuffer(Vector2.zero, sourceSize)
	local targetSize = math.clamp(math.floor(options.Size), 8, 256)
	local processedPixels = ThumbnailPixelator.ProcessBuffer(sourcePixels, sourceSize, options)
	local output = AssetService:CreateEditableImage({
		Size = Vector2.new(targetSize, targetSize),
	})
	if not output then
		sourceImage:Destroy()
		error("AssetService could not allocate the output EditableImage")
	end
	output:WritePixelsBuffer(Vector2.zero, output.Size, processedPixels)
	sourceImage:Destroy()
	return output
end

return table.freeze(ThumbnailPixelator)
