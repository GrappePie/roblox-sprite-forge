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

local ProceduralRaster = {}

local function offset(width: number, x: number, y: number): number
	return (y * width + x) * 4
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
