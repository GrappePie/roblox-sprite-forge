--!strict

local AppearanceFingerprint = {}

export type Snapshot = { [string]: any }

local DESCRIPTION_PROPERTIES = {
	"BackAccessory",
	"BodyTypeScale",
	"ClimbAnimation",
	"DepthScale",
	"Face",
	"FaceAccessory",
	"FallAnimation",
	"FrontAccessory",
	"GraphicTShirt",
	"HairAccessory",
	"HatAccessory",
	"Head",
	"HeadColor",
	"HeadScale",
	"HeightScale",
	"IdleAnimation",
	"JumpAnimation",
	"LeftArm",
	"LeftArmColor",
	"LeftLeg",
	"LeftLegColor",
	"MoodAnimation",
	"NeckAccessory",
	"Pants",
	"ProportionScale",
	"RightArm",
	"RightArmColor",
	"RightLeg",
	"RightLegColor",
	"RunAnimation",
	"Shirt",
	"ShouldersAccessory",
	"SwimAnimation",
	"Torso",
	"TorsoColor",
	"WaistAccessory",
	"WalkAnimation",
	"WidthScale",
}

local function normalizedScalar(value: any): string
	local valueType = typeof(value)
	if valueType == "Color3" then
		local color = value :: Color3
		return string.format(
			"c:%d,%d,%d",
			math.round(color.R * 255),
			math.round(color.G * 255),
			math.round(color.B * 255)
		)
	elseif valueType == "Vector2" then
		local vector = value :: Vector2
		return string.format("v2:%.5f,%.5f", vector.X, vector.Y)
	elseif valueType == "Vector3" then
		local vector = value :: Vector3
		return string.format("v3:%.5f,%.5f,%.5f", vector.X, vector.Y, vector.Z)
	elseif valueType == "EnumItem" then
		return "e:" .. tostring(value)
	elseif valueType == "number" then
		return string.format("n:%.8g", value)
	elseif valueType == "boolean" then
		return if value then "b:1" else "b:0"
	elseif value == nil then
		return "nil"
	end
	return "s:" .. tostring(value)
end

local function canonical(value: any, seen: { [any]: boolean }): string
	if type(value) ~= "table" then
		return normalizedScalar(value)
	end
	if seen[value] then
		error("Appearance fingerprint snapshots cannot contain cycles")
	end
	seen[value] = true
	local entries = {}
	for key, child in value do
		table.insert(entries, {
			key = canonical(key, seen),
			value = canonical(child, seen),
		})
	end
	table.sort(entries, function(left, right)
		return left.key < right.key
	end)
	local parts = {}
	for _, entry in entries do
		table.insert(parts, entry.key .. "=" .. entry.value)
	end
	seen[value] = nil
	return "{" .. table.concat(parts, ";") .. "}"
end

local function hashText(text: string): string
	local hash = 5381
	for index = 1, #text do
		hash = (hash * 33 + string.byte(text, index)) % 4294967296
	end
	return string.format("avatar-v1-%08x", hash)
end

function AppearanceFingerprint.FromSnapshot(snapshot: Snapshot): string
	return hashText(canonical(snapshot, {}))
end

function AppearanceFingerprint.Capture(description: HumanoidDescription): Snapshot
	local snapshot: Snapshot = {}
	for _, propertyName in DESCRIPTION_PROPERTIES do
		local ok, value = pcall(function()
			return (description :: any)[propertyName]
		end)
		if ok then
			snapshot[propertyName] = value
		end
	end
	local accessories = {}
	local ok, result = pcall(function()
		return description:GetAccessories(true)
	end)
	if ok then
		for _, accessory in result do
			table.insert(accessories, {
				assetId = accessory.AssetId,
				accessoryType = tostring(accessory.AccessoryType),
				isLayered = accessory.IsLayered == true,
				order = accessory.Order or 0,
				puffiness = accessory.Puffiness or 0,
			})
		end
	end
	table.sort(accessories, function(left, right)
		if left.assetId ~= right.assetId then return left.assetId < right.assetId end
		if left.accessoryType ~= right.accessoryType then
			return left.accessoryType < right.accessoryType
		end
		return left.order < right.order
	end)
	snapshot.accessories = accessories
	return snapshot
end

return AppearanceFingerprint
