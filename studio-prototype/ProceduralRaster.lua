--!strict

export type Bounds = {
	minX: number,
	minY: number,
	maxX: number,
	maxY: number,
}

export type Sample = {
	r: number,
	g: number,
	b: number,
	a: number,
}

export type ProjectionMetrics = {
	projectedPixels: number,
	rejectedSamples: number,
	rejectedColorSamples: number,
	nearbySearchSuccesses: number,
	fallbackPixels: number,
}

export type ProjectOptions = {
	MinAlpha: number?,
	NearbyRadius: number?,
	FallbackPrimary: Color3?,
	FallbackSecondary: Color3?,
	RejectColor: ((number, number, number) -> boolean)?,
}

local ProceduralRaster = {}

local function offset(width: number, x: number, y: number): number
	return (y * width + x) * 4
end

local function setMaskAlpha(
	mask: buffer,
	width: number,
	height: number,
	x: number,
	y: number,
	alpha: number?
)
	if x < 0 or y < 0 or x >= width or y >= height then
		return
	end
	buffer.writeu8(mask, offset(width, x, y) + 3, math.clamp(alpha or 255, 0, 255))
end

function ProceduralRaster.CountMaskPixels(mask: buffer, size: Vector2): number
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	local count = 0
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			if buffer.readu8(mask, offset(width, x, y) + 3) > 0 then
				count += 1
			end
		end
	end
	return count
end

function ProceduralRaster.MaskBounds(mask: buffer, size: Vector2): Bounds?
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	local bounds: Bounds = { minX = width, minY = height, maxX = -1, maxY = -1 }
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			if buffer.readu8(mask, offset(width, x, y) + 3) > 0 then
				bounds.minX = math.min(bounds.minX, x)
				bounds.minY = math.min(bounds.minY, y)
				bounds.maxX = math.max(bounds.maxX, x)
				bounds.maxY = math.max(bounds.maxY, y)
			end
		end
	end
	return if bounds.maxX >= bounds.minX then bounds else nil
end

function ProceduralRaster.FillPolygon(mask: buffer, size: Vector2, points: { Vector2 })
	if #points < 3 then
		return
	end
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	local minX, minY, maxX, maxY = width - 1, height - 1, 0, 0
	for _, point in points do
		minX = math.min(minX, math.floor(point.X))
		minY = math.min(minY, math.floor(point.Y))
		maxX = math.max(maxX, math.ceil(point.X))
		maxY = math.max(maxY, math.ceil(point.Y))
	end
	for y = math.max(0, minY), math.min(height - 1, maxY) do
		for x = math.max(0, minX), math.min(width - 1, maxX) do
			local inside = false
			local previous = #points
			for current = 1, #points do
				local a = points[current]
				local b = points[previous]
				if ((a.Y > y) ~= (b.Y > y))
					and x < (b.X - a.X) * (y - a.Y) / (b.Y - a.Y) + a.X then
					inside = not inside
				end
				previous = current
			end
			if inside then
				setMaskAlpha(mask, width, height, x, y)
			end
		end
	end
end

function ProceduralRaster.FillCapsule(
	mask: buffer,
	size: Vector2,
	startPoint: Vector2,
	endPoint: Vector2,
	radius: number
)
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	local minX = math.floor(math.min(startPoint.X, endPoint.X) - radius)
	local minY = math.floor(math.min(startPoint.Y, endPoint.Y) - radius)
	local maxX = math.ceil(math.max(startPoint.X, endPoint.X) + radius)
	local maxY = math.ceil(math.max(startPoint.Y, endPoint.Y) + radius)
	local segment = endPoint - startPoint
	local lengthSquared = segment:Dot(segment)
	for y = math.max(0, minY), math.min(height - 1, maxY) do
		for x = math.max(0, minX), math.min(width - 1, maxX) do
			local point = Vector2.new(x, y)
			local progress = if lengthSquared > 0
				then math.clamp((point - startPoint):Dot(segment) / lengthSquared, 0, 1)
				else 0
			local closest = startPoint + segment * progress
			if (point - closest).Magnitude <= radius then
				setMaskAlpha(mask, width, height, x, y)
			end
		end
	end
end

function ProceduralRaster.DrawLine(
	target: buffer,
	size: Vector2,
	startPoint: Vector2,
	endPoint: Vector2,
	color: Color3,
	thickness: number?
)
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	local steps = math.max(math.abs(endPoint.X - startPoint.X), math.abs(endPoint.Y - startPoint.Y), 1)
	local radius = math.max(0, math.floor((thickness or 1) / 2))
	local red = math.round(color.R * 255)
	local green = math.round(color.G * 255)
	local blue = math.round(color.B * 255)
	for step = 0, steps do
		local progress = step / steps
		local centerX = math.round(startPoint.X + (endPoint.X - startPoint.X) * progress)
		local centerY = math.round(startPoint.Y + (endPoint.Y - startPoint.Y) * progress)
		for y = centerY - radius, centerY + radius do
			for x = centerX - radius, centerX + radius do
				ProceduralRaster.SourceOverPixel(target, width, height, x, y, {
					r = red,
					g = green,
					b = blue,
					a = 255,
				})
			end
		end
	end
end

function ProceduralRaster.StrokeMaskInside(
	target: buffer,
	size: Vector2,
	mask: buffer,
	color: Color3
)
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	local red = math.round(color.R * 255)
	local green = math.round(color.G * 255)
	local blue = math.round(color.B * 255)
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local pixelOffset = offset(width, x, y)
			if buffer.readu8(mask, pixelOffset + 3) == 0 then
				continue
			end
			local edge = false
			for _, direction in {
				Vector2.new(-1, 0),
				Vector2.new(1, 0),
				Vector2.new(0, -1),
				Vector2.new(0, 1),
			} do
				local neighborX = x + direction.X
				local neighborY = y + direction.Y
				if neighborX < 0 or neighborY < 0 or neighborX >= width or neighborY >= height
					or buffer.readu8(mask, offset(width, neighborX, neighborY) + 3) == 0 then
					edge = true
					break
				end
			end
			if edge then
				ProceduralRaster.SourceOverPixel(target, width, height, x, y, {
					r = red,
					g = green,
					b = blue,
					a = 255,
				})
			end
		end
	end
end

function ProceduralRaster.MakeBodyBands(bodySource: Bounds): {
	torso: Bounds,
	hips: Bounds,
	legs: Bounds,
}
	local height = bodySource.maxY - bodySource.minY + 1
	local torsoEnd = bodySource.minY + math.floor(height * 0.45) - 1
	local hipsEnd = bodySource.minY + math.floor(height * 0.66) - 1
	torsoEnd = math.clamp(torsoEnd, bodySource.minY, bodySource.maxY - 2)
	hipsEnd = math.clamp(hipsEnd, torsoEnd + 1, bodySource.maxY - 1)
	return {
		torso = {
			minX = bodySource.minX,
			maxX = bodySource.maxX,
			minY = bodySource.minY,
			maxY = torsoEnd,
		},
		hips = {
			minX = bodySource.minX,
			maxX = bodySource.maxX,
			minY = torsoEnd + 1,
			maxY = hipsEnd,
		},
		legs = {
			minX = bodySource.minX,
			maxX = bodySource.maxX,
			minY = hipsEnd + 1,
			maxY = bodySource.maxY,
		},
	}
end

function ProceduralRaster.SampleAreaPremultiplied(
	source: buffer,
	sourceWidth: number,
	sourceHeight: number,
	sourceX0: number,
	sourceY0: number,
	sourceX1: number,
	sourceY1: number
): Sample
	local alphaCoverage = 0
	local totalCoverage = 0
	local premultipliedRed = 0
	local premultipliedGreen = 0
	local premultipliedBlue = 0
	for sourceY = math.floor(sourceY0), math.ceil(sourceY1) - 1 do
		if sourceY < 0 or sourceY >= sourceHeight then
			continue
		end
		local coverageY =
			math.max(0, math.min(sourceY + 1, sourceY1) - math.max(sourceY, sourceY0))
		for sourceX = math.floor(sourceX0), math.ceil(sourceX1) - 1 do
			if sourceX < 0 or sourceX >= sourceWidth then
				continue
			end
			local coverageX =
				math.max(0, math.min(sourceX + 1, sourceX1) - math.max(sourceX, sourceX0))
			local coverage = coverageX * coverageY
			local sourceOffset = offset(sourceWidth, sourceX, sourceY)
			local alpha = buffer.readu8(source, sourceOffset + 3) / 255
			local weightedAlpha = alpha * coverage
			totalCoverage += coverage
			alphaCoverage += weightedAlpha
			premultipliedRed += buffer.readu8(source, sourceOffset) * weightedAlpha
			premultipliedGreen += buffer.readu8(source, sourceOffset + 1) * weightedAlpha
			premultipliedBlue += buffer.readu8(source, sourceOffset + 2) * weightedAlpha
		end
	end
	if alphaCoverage <= 0 or totalCoverage <= 0 then
		return { r = 0, g = 0, b = 0, a = 0 }
	end
	return {
		r = math.clamp(math.round(premultipliedRed / alphaCoverage), 0, 255),
		g = math.clamp(math.round(premultipliedGreen / alphaCoverage), 0, 255),
		b = math.clamp(math.round(premultipliedBlue / alphaCoverage), 0, 255),
		a = math.clamp(math.round((alphaCoverage / totalCoverage) * 255), 0, 255),
	}
end

function ProceduralRaster.SourceOverPixel(
	target: buffer,
	targetWidth: number,
	targetHeight: number,
	x: number,
	y: number,
	sample: Sample
)
	if x < 0 or y < 0 or x >= targetWidth or y >= targetHeight or sample.a <= 0 then
		return
	end
	local targetOffset = offset(targetWidth, x, y)
	local sourceAlpha = sample.a / 255
	local destinationAlpha = buffer.readu8(target, targetOffset + 3) / 255
	local outputAlpha = sourceAlpha + destinationAlpha * (1 - sourceAlpha)
	if outputAlpha <= 0 then
		return
	end
	local destinationRed = buffer.readu8(target, targetOffset)
	local destinationGreen = buffer.readu8(target, targetOffset + 1)
	local destinationBlue = buffer.readu8(target, targetOffset + 2)
	local destinationWeight = destinationAlpha * (1 - sourceAlpha)
	buffer.writeu8(
		target,
		targetOffset,
		math.clamp(
			math.round((sample.r * sourceAlpha + destinationRed * destinationWeight) / outputAlpha),
			0,
			255
		)
	)
	buffer.writeu8(
		target,
		targetOffset + 1,
		math.clamp(
			math.round((sample.g * sourceAlpha + destinationGreen * destinationWeight) / outputAlpha),
			0,
			255
		)
	)
	buffer.writeu8(
		target,
		targetOffset + 2,
		math.clamp(
			math.round((sample.b * sourceAlpha + destinationBlue * destinationWeight) / outputAlpha),
			0,
			255
		)
	)
	buffer.writeu8(target, targetOffset + 3, math.clamp(math.round(outputAlpha * 255), 0, 255))
end

function ProceduralRaster.CopyRegionArea(
	source: buffer,
	sourceSize: Vector2,
	sourceBounds: Bounds,
	target: buffer,
	targetSize: Vector2,
	targetBounds: Bounds
)
	local sourceWidth = math.floor(sourceSize.X)
	local sourceHeight = math.floor(sourceSize.Y)
	local targetWidth = math.floor(targetSize.X)
	local targetHeight = math.floor(targetSize.Y)
	local sourceRegionWidth = sourceBounds.maxX - sourceBounds.minX + 1
	local sourceRegionHeight = sourceBounds.maxY - sourceBounds.minY + 1
	local targetRegionWidth = targetBounds.maxX - targetBounds.minX + 1
	local targetRegionHeight = targetBounds.maxY - targetBounds.minY + 1
	for targetY = targetBounds.minY, targetBounds.maxY do
		for targetX = targetBounds.minX, targetBounds.maxX do
			local localX = targetX - targetBounds.minX
			local localY = targetY - targetBounds.minY
			local sourceX0 =
				sourceBounds.minX + (localX * sourceRegionWidth) / targetRegionWidth
			local sourceX1 =
				sourceBounds.minX + ((localX + 1) * sourceRegionWidth) / targetRegionWidth
			local sourceY0 =
				sourceBounds.minY + (localY * sourceRegionHeight) / targetRegionHeight
			local sourceY1 =
				sourceBounds.minY + ((localY + 1) * sourceRegionHeight) / targetRegionHeight
			local sample = ProceduralRaster.SampleAreaPremultiplied(
				source,
				sourceWidth,
				sourceHeight,
				sourceX0,
				sourceY0,
				sourceX1,
				sourceY1
			)
			ProceduralRaster.SourceOverPixel(
				target,
				targetWidth,
				targetHeight,
				targetX,
				targetY,
				sample
			)
		end
	end
end

function ProceduralRaster.ProjectRegionToMask(
	sourcePixels: buffer,
	sourceSize: Vector2,
	sourceBounds: Bounds,
	targetPixels: buffer,
	targetSize: Vector2,
	targetMask: buffer,
	options: ProjectOptions?
): ProjectionMetrics
	local sourceWidth = math.floor(sourceSize.X)
	local sourceHeight = math.floor(sourceSize.Y)
	local targetWidth = math.floor(targetSize.X)
	local targetHeight = math.floor(targetSize.Y)
	local maskBounds = ProceduralRaster.MaskBounds(targetMask, targetSize)
	local metrics: ProjectionMetrics = {
		projectedPixels = 0,
		rejectedSamples = 0,
		rejectedColorSamples = 0,
		nearbySearchSuccesses = 0,
		fallbackPixels = 0,
	}
	if not maskBounds then
		return metrics
	end
	local settings = options or {}
	local minAlpha = settings.MinAlpha or 32
	local nearbyRadius = settings.NearbyRadius or 4
	local fallbackPrimary = settings.FallbackPrimary or Color3.fromRGB(96, 96, 112)
	local fallbackSecondary = settings.FallbackSecondary or fallbackPrimary
	local sourceRegionWidth = sourceBounds.maxX - sourceBounds.minX + 1
	local sourceRegionHeight = sourceBounds.maxY - sourceBounds.minY + 1
	local targetRegionWidth = math.max(1, maskBounds.maxX - maskBounds.minX + 1)
	local targetRegionHeight = math.max(1, maskBounds.maxY - maskBounds.minY + 1)

	local function accepted(sample: Sample): boolean
		return sample.a >= minAlpha
			and not (settings.RejectColor and settings.RejectColor(sample.r, sample.g, sample.b))
	end

	local function nearby(centerX: number, centerY: number): Sample?
		for radius = 1, nearbyRadius do
			for deltaY = -radius, radius do
				for deltaX = -radius, radius do
					if math.abs(deltaX) ~= radius and math.abs(deltaY) ~= radius then
						continue
					end
					local sourceX = math.clamp(math.round(centerX + deltaX), sourceBounds.minX, sourceBounds.maxX)
					local sourceY = math.clamp(math.round(centerY + deltaY), sourceBounds.minY, sourceBounds.maxY)
					local sample = ProceduralRaster.SampleAreaPremultiplied(
						sourcePixels,
						sourceWidth,
						sourceHeight,
						sourceX,
						sourceY,
						sourceX + 1,
						sourceY + 1
					)
					if accepted(sample) then
						return sample
					end
				end
			end
		end
		return nil
	end

	for targetY = maskBounds.minY, maskBounds.maxY do
		for targetX = maskBounds.minX, maskBounds.maxX do
			local targetOffset = offset(targetWidth, targetX, targetY)
			local maskAlpha = buffer.readu8(targetMask, targetOffset + 3)
			if maskAlpha == 0 then
				continue
			end
			local localX = (targetX - maskBounds.minX) / targetRegionWidth
			local localY = (targetY - maskBounds.minY) / targetRegionHeight
			local sourceX0 = sourceBounds.minX + localX * sourceRegionWidth
			local sourceY0 = sourceBounds.minY + localY * sourceRegionHeight
			local sourceX1 = sourceBounds.minX
				+ ((targetX - maskBounds.minX + 1) / targetRegionWidth) * sourceRegionWidth
			local sourceY1 = sourceBounds.minY
				+ ((targetY - maskBounds.minY + 1) / targetRegionHeight) * sourceRegionHeight
			local sample = ProceduralRaster.SampleAreaPremultiplied(
				sourcePixels,
				sourceWidth,
				sourceHeight,
				sourceX0,
				sourceY0,
				sourceX1,
				sourceY1
			)
			local rejectedByColor = sample.a >= minAlpha
				and settings.RejectColor ~= nil
				and settings.RejectColor(sample.r, sample.g, sample.b)
			if sample.a < minAlpha or rejectedByColor then
				metrics.rejectedSamples += 1
				if rejectedByColor then
					metrics.rejectedColorSamples += 1
				end
				local replacement = nearby((sourceX0 + sourceX1) * 0.5, (sourceY0 + sourceY1) * 0.5)
				if replacement then
					sample = replacement
					metrics.nearbySearchSuccesses += 1
				else
					local fallback = if (targetX + targetY) % 2 == 0
						then fallbackPrimary
						else fallbackSecondary
					sample = {
						r = math.round(fallback.R * 255),
						g = math.round(fallback.G * 255),
						b = math.round(fallback.B * 255),
						a = 255,
					}
					metrics.fallbackPixels += 1
				end
			end
			sample.a = maskAlpha
			ProceduralRaster.SourceOverPixel(
				targetPixels,
				targetWidth,
				targetHeight,
				targetX,
				targetY,
				sample
			)
			metrics.projectedPixels += 1
		end
	end
	return metrics
end

function ProceduralRaster.CompositeBufferSourceOver(
	target: buffer,
	source: buffer,
	size: Vector2
)
	local width = math.floor(size.X)
	local height = math.floor(size.Y)
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local sourceOffset = offset(width, x, y)
			ProceduralRaster.SourceOverPixel(target, width, height, x, y, {
				r = buffer.readu8(source, sourceOffset),
				g = buffer.readu8(source, sourceOffset + 1),
				b = buffer.readu8(source, sourceOffset + 2),
				a = buffer.readu8(source, sourceOffset + 3),
			})
		end
	end
end

return table.freeze(ProceduralRaster)
