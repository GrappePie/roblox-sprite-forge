--!strict

local GoldenArtworkProvider = {}
GoldenArtworkProvider.__index = GoldenArtworkProvider

export type Provider = typeof(setmetatable({} :: {
	kind: "GoldenArtwork",
	registry: any,
	dataFolder: Instance,
	variant: "master" | "derived",
	requests: number,
	hits: number,
	misses: number,
}, GoldenArtworkProvider))

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local DECODE: { [string]: number } = {}
for index = 1, #ALPHABET do
	DECODE[string.sub(ALPHABET, index, index)] = index - 1
end

local function decodeBase64(encoded: string): buffer
	local padding = if string.sub(encoded, -2) == "==" then 2
		elseif string.sub(encoded, -1) == "=" then 1
		else 0
	local byteLength = math.floor(#encoded / 4) * 3 - padding
	local output = buffer.create(byteLength)
	local outputOffset = 0
	for index = 1, #encoded, 4 do
		local a = DECODE[string.sub(encoded, index, index)] or 0
		local b = DECODE[string.sub(encoded, index + 1, index + 1)] or 0
		local c = DECODE[string.sub(encoded, index + 2, index + 2)] or 0
		local d = DECODE[string.sub(encoded, index + 3, index + 3)] or 0
		local packed = bit32.lshift(a, 18)
			+ bit32.lshift(b, 12)
			+ bit32.lshift(c, 6)
			+ d
		if outputOffset < byteLength then
			buffer.writeu8(output, outputOffset, bit32.band(bit32.rshift(packed, 16), 255))
			outputOffset += 1
		end
		if outputOffset < byteLength then
			buffer.writeu8(output, outputOffset, bit32.band(bit32.rshift(packed, 8), 255))
			outputOffset += 1
		end
		if outputOffset < byteLength then
			buffer.writeu8(output, outputOffset, bit32.band(packed, 255))
			outputOffset += 1
		end
	end
	return output
end

local function loadRgba(dataFolder: Instance, variant: any): buffer
	local result = buffer.create(variant.width * variant.height * 4)
	local offset = 0
	for _, chunkName in variant.chunkNames do
		local module = dataFolder:FindFirstChild(chunkName)
		if not module or not module:IsA("ModuleScript") then
			error("Missing golden artwork data chunk " .. tostring(chunkName))
		end
		local decoded = decodeBase64(require(module))
		buffer.copy(result, offset, decoded)
		offset += buffer.len(decoded)
	end
	if offset ~= buffer.len(result) then
		error(string.format("Golden RGBA length mismatch: %d ~= %d", offset, buffer.len(result)))
	end
	return result
end

local IDENTITY_PROPERTIES = {
	"BackAccessory",
	"Face",
	"FaceAccessory",
	"FrontAccessory",
	"GraphicTShirt",
	"HairAccessory",
	"HatAccessory",
	"Head",
	"LeftArm",
	"LeftLeg",
	"NeckAccessory",
	"Pants",
	"RightArm",
	"RightLeg",
	"Shirt",
	"ShouldersAccessory",
	"Torso",
	"WaistAccessory",
}

local function addAssetId(ids: { [number]: boolean }, value: any)
	if type(value) == "number" then
		local rounded = math.floor(value)
		if rounded > 0 then ids[rounded] = true end
	elseif type(value) == "string" then
		for match in string.gmatch(value, "%d+") do
			local id = tonumber(match)
			if id and id > 0 then ids[id] = true end
		end
	end
end

local function collectAppearanceAssetIds(appearance: any): ({ [number]: boolean }, number)
	local ids: { [number]: boolean } = {}
	if type(appearance) ~= "table" then return ids, 0 end
	for _, propertyName in IDENTITY_PROPERTIES do
		addAssetId(ids, appearance[propertyName])
	end
	if type(appearance.accessories) == "table" then
		for _, accessory in appearance.accessories do
			if type(accessory) == "table" then
				addAssetId(ids, accessory.assetId)
			end
		end
	end
	local count = 0
	for _ in ids do count += 1 end
	return ids, count
end

function GoldenArtworkProvider.IsAppearanceCompatible(entry: any, appearance: any): (boolean, number)
	local expected: { [number]: boolean } = {}
	for _, assetId in entry.assetIds or {} do
		addAssetId(expected, assetId)
	end
	local expectedCount = 0
	for _ in expected do expectedCount += 1 end
	local current, currentCount = collectAppearanceAssetIds(appearance)
	if currentCount == 0 or expectedCount == 0 then return false, 0 end
	local matched = 0
	for assetId in current do
		if expected[assetId] then matched += 1 end
	end
	local ratio = matched / math.max(currentCount, expectedCount)
	return matched == currentCount and matched == expectedCount, ratio
end

local function findEntry(registry: any, request: any): (any?, string?)
	local exact = registry.entries[request.fingerprint]
	if exact then return exact, nil end
	local userId = request.appearance and request.appearance.userId
	local foundUserEntry = false
	if userId then
		for _, entry in registry.entries do
			if entry.userId == userId then
				foundUserEntry = true
				local compatible = GoldenArtworkProvider.IsAppearanceCompatible(
					entry,
					request.appearance
				)
				if compatible then return entry, nil end
			end
		end
	end
	return nil, if foundUserEntry
		then "MissingGoldenArtworkAppearanceMismatch:" .. request.fingerprint
		else "MissingGoldenArtwork:" .. request.fingerprint
end

function GoldenArtworkProvider.new(
	registry: any,
	dataFolder: Instance,
	variant: "master" | "derived"?
): Provider
	assert(type(registry) == "table" and registry.schemaVersion == 1, "Invalid GoldenArtworkRegistry")
	return setmetatable({
		kind = "GoldenArtwork",
		registry = registry,
		dataFolder = dataFolder,
		variant = variant or "master",
		requests = 0,
		hits = 0,
		misses = 0,
	}, GoldenArtworkProvider)
end

function GoldenArtworkProvider.Request(self: Provider, request: any)
	self.requests += 1
	local entry, missingReason = findEntry(self.registry, request)
	if not entry then
		self.misses += 1
		return nil, missingReason
	end
	local variant = entry.variants[self.variant]
	if not variant then
		self.misses += 1
		return nil, "MissingGoldenArtworkVariant:" .. self.variant
	end
	self.hits += 1
	local rgba = loadRgba(self.dataFolder, variant)
	return {
		schemaVersion = 1,
		id = string.format("golden-%s-%s", entry.fingerprint, self.variant),
		fingerprint = request.fingerprint,
		canvasSize = Vector2.new(variant.width, variant.height),
		palette = {},
		layers = {
			{
				name = "CharacterFlat",
				zIndex = 0,
				anchor = Vector2.new(0.5, 1),
				pivot = Vector2.new(0.5, 1),
				rects = {},
			},
		},
		anchors = {},
		rig = {},
		clips = {},
		flatArtwork = {
			width = variant.width,
			height = variant.height,
			rgba = rgba,
			anchor = Vector2.new(0.5, 1),
			pivot = Vector2.new(0.5, 1),
			variant = self.variant,
			contentHash = variant.rgbaHash,
		},
	}
end

return GoldenArtworkProvider
