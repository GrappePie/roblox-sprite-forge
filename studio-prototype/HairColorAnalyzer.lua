--!strict

export type HairColors = {
	primary: Color3,
	secondary: Color3,
	highlight: Color3,
	shadow: Color3,
}

type Bucket = {
	r: number,
	g: number,
	b: number,
	count: number,
}

local HairColorAnalyzer = {}

local function offset(width: number, x: number, y: number): number
	return (y * width + x) * 4
end

local function distance(
	redA: number,
	greenA: number,
	blueA: number,
	redB: number,
	greenB: number,
	blueB: number
): number
	return math.abs(redA - redB) + math.abs(greenA - greenB) + math.abs(blueA - blueB)
end

function HairColorAnalyzer.Analyze(
	pixels: buffer,
	size: Vector2,
	bounds: { minX: number, minY: number, maxX: number, maxY: number },
	skinColor: Color3,
	alphaThreshold: number?
): HairColors
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	local threshold = math.clamp(math.floor(alphaThreshold or 48), 1, 255)
	local skinRed = math.round(skinColor.R * 255)
	local skinGreen = math.round(skinColor.G * 255)
	local skinBlue = math.round(skinColor.B * 255)
	local histogram: { [number]: Bucket } = {}
	local analysisBottom =
		math.min(bounds.maxY, bounds.minY + math.floor((bounds.maxY - bounds.minY + 1) * 0.72))
	for y = math.max(0, bounds.minY), math.min(height - 1, analysisBottom), 2 do
		for x = math.max(0, bounds.minX), math.min(width - 1, bounds.maxX), 2 do
			local pixelOffset = offset(width, x, y)
			local alpha = buffer.readu8(pixels, pixelOffset + 3)
			if alpha < threshold then
				continue
			end
			local red = buffer.readu8(pixels, pixelOffset)
			local green = buffer.readu8(pixels, pixelOffset + 1)
			local blue = buffer.readu8(pixels, pixelOffset + 2)
			if distance(red, green, blue, skinRed, skinGreen, skinBlue) < 78 then
				continue
			end
			local key =
				math.floor(red / 12) * 484 + math.floor(green / 12) * 22 + math.floor(blue / 12)
			local weight = alpha / 255
			local bucket = histogram[key]
			if bucket then
				bucket.r += red * weight
				bucket.g += green * weight
				bucket.b += blue * weight
				bucket.count += weight
			else
				histogram[key] = {
					r = red * weight,
					g = green * weight,
					b = blue * weight,
					count = weight,
				}
			end
		end
	end
	local buckets: { Bucket } = {}
	for _, bucket in histogram do
		table.insert(buckets, bucket)
	end
	table.sort(buckets, function(a, b)
		return a.count > b.count
	end)
	local fallback = Color3.fromRGB(86, 116, 89)
	if #buckets == 0 then
		return {
			primary = fallback,
			secondary = fallback:Lerp(Color3.fromRGB(110, 74, 140), 0.25),
			highlight = fallback:Lerp(Color3.new(1, 1, 1), 0.28),
			shadow = fallback:Lerp(Color3.fromRGB(24, 22, 38), 0.34),
		}
	end
	local function bucketColor(bucket: Bucket): Color3
		return Color3.fromRGB(
			math.clamp(math.round(bucket.r / bucket.count), 0, 255),
			math.clamp(math.round(bucket.g / bucket.count), 0, 255),
			math.clamp(math.round(bucket.b / bucket.count), 0, 255)
		)
	end
	local primary = bucketColor(buckets[1])
	local primaryRed = math.round(primary.R * 255)
	local primaryGreen = math.round(primary.G * 255)
	local primaryBlue = math.round(primary.B * 255)
	local secondary = primary
	local bestScore = -1
	for index = 2, math.min(#buckets, 16) do
		local candidate = bucketColor(buckets[index])
		local score = distance(
			primaryRed,
			primaryGreen,
			primaryBlue,
			math.round(candidate.R * 255),
			math.round(candidate.G * 255),
			math.round(candidate.B * 255)
		) * math.log(buckets[index].count + 1)
		if score > bestScore then
			bestScore = score
			secondary = candidate
		end
	end
	return {
		primary = primary,
		secondary = secondary,
		highlight = primary:Lerp(Color3.new(1, 1, 1), 0.3),
		shadow = primary:Lerp(Color3.fromRGB(24, 22, 38), 0.36),
	}
end

return table.freeze(HairColorAnalyzer)
