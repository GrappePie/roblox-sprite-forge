--!strict

local SpritePackage = {}

export type Rect = {
	x: number,
	y: number,
	width: number,
	height: number,
	colorIndex: number,
	alpha: number?,
}

export type Layer = {
	name: string,
	zIndex: number,
	pivot: Vector2,
	anchor: Vector2,
	rects: { Rect },
}

export type FlatArtwork = {
	width: number,
	height: number,
	rgba: buffer,
	anchor: Vector2,
	pivot: Vector2,
	variant: string,
	contentHash: string?,
}

export type Transform = {
	position: Vector2?,
	rotation: number?,
	scale: Vector2?,
}

export type Keyframe = {
	time: number,
	rootOffset: Vector2?,
	transforms: { [string]: Transform },
}

export type Clip = {
	name: string,
	duration: number,
	looped: boolean,
	keyframes: { Keyframe },
}

export type Joint = {
	name: string,
	layer: string,
	parent: string?,
	pivot: Vector2,
}

export type Package = {
	schemaVersion: number,
	id: string,
	fingerprint: string,
	canvasSize: Vector2,
	palette: { Color3 },
	layers: { Layer },
	anchors: { [string]: Vector2 },
	rig: { Joint },
	clips: { [string]: Clip },
	flatArtwork: FlatArtwork?,
}

export type ValidationResult = {
	valid: boolean,
	errors: { string },
	layerOrder: { string },
}

local REQUIRED_LAYERS = {
	"BackHair",
	"Face",
	"FrontHair",
	"Torso",
	"LeftArm",
	"RightArm",
	"Skirt",
	"LeftLeg",
	"RightLeg",
	"Accessories",
}

local function addError(errors: { string }, condition: boolean, message: string)
	if not condition then
		table.insert(errors, message)
	end
end

function SpritePackage.OrderLayers(package: Package): { Layer }
	local ordered = table.clone(package.layers)
	table.sort(ordered, function(left, right)
		if left.zIndex == right.zIndex then
			return left.name < right.name
		end
		return left.zIndex < right.zIndex
	end)
	return ordered
end

function SpritePackage.Validate(value: any, expectedFingerprint: string?): ValidationResult
	local errors = {}
	if type(value) ~= "table" then
		return { valid = false, errors = { "package must be a table" }, layerOrder = {} }
	end
	addError(errors, value.schemaVersion == 1, "schemaVersion must be 1")
	addError(errors, type(value.id) == "string" and #value.id > 0, "id is required")
	addError(errors, type(value.fingerprint) == "string" and #value.fingerprint > 0, "fingerprint is required")
	if expectedFingerprint then
		addError(errors, value.fingerprint == expectedFingerprint, "fingerprint does not match request")
	end
	addError(errors, typeof(value.canvasSize) == "Vector2", "canvasSize must be Vector2")
	if typeof(value.canvasSize) == "Vector2" then
		addError(errors, value.canvasSize.X > 0 and value.canvasSize.Y > 0, "canvasSize must be positive")
		addError(errors, value.canvasSize.X <= 512 and value.canvasSize.Y <= 512, "canvasSize exceeds 512")
	end
	local isFlat = type(value.flatArtwork) == "table"
	addError(errors, type(value.palette) == "table", "palette is required")
	if not isFlat then
		addError(errors, type(value.palette) == "table" and #value.palette > 0, "palette is required")
	end
	addError(errors, type(value.palette) == "table" and #value.palette <= 96, "palette exceeds 96 colors")
	if type(value.palette) == "table" then
		for index, color in value.palette do
			addError(errors, typeof(color) == "Color3", "palette[" .. index .. "] must be Color3")
		end
	end

	local layerNames: { [string]: boolean } = {}
	local zIndices: { [number]: boolean } = {}
	if type(value.layers) ~= "table" then
		table.insert(errors, "layers are required")
	else
		for index, layer in value.layers do
			if type(layer) ~= "table" then
				table.insert(errors, "layer[" .. index .. "] must be a table")
				continue
			end
			addError(errors, type(layer.name) == "string" and #layer.name > 0, "layer name is required")
			if type(layer.name) == "string" then
				addError(errors, not layerNames[layer.name], "duplicate layer " .. layer.name)
				layerNames[layer.name] = true
			end
			addError(errors, type(layer.zIndex) == "number", "layer zIndex is required")
			if type(layer.zIndex) == "number" then
				addError(errors, not zIndices[layer.zIndex], "duplicate zIndex " .. layer.zIndex)
				zIndices[layer.zIndex] = true
			end
			addError(errors, typeof(layer.pivot) == "Vector2", "layer pivot must be Vector2")
			addError(errors, typeof(layer.anchor) == "Vector2", "layer anchor must be Vector2")
			addError(
				errors,
				type(layer.rects) == "table" and (isFlat or #layer.rects > 0),
				"layer rects are required"
			)
			if type(layer.rects) == "table" and typeof(value.canvasSize) == "Vector2" then
				for rectIndex, rect in layer.rects do
					if type(rect) ~= "table" then
						table.insert(errors, string.format("%s rect[%d] must be a table", tostring(layer.name), rectIndex))
						continue
					end
					local inside = type(rect.x) == "number" and type(rect.y) == "number"
						and type(rect.width) == "number" and type(rect.height) == "number"
						and rect.width > 0 and rect.height > 0
						and rect.x >= 0 and rect.y >= 0
						and rect.x + rect.width <= value.canvasSize.X
						and rect.y + rect.height <= value.canvasSize.Y
					addError(errors, inside, string.format("%s rect[%d] is outside canvas", tostring(layer.name), rectIndex))
					addError(
						errors,
						type(rect.colorIndex) == "number"
							and rect.colorIndex >= 1
							and rect.colorIndex <= #(value.palette or {}),
						string.format("%s rect[%d] has invalid colorIndex", tostring(layer.name), rectIndex)
					)
				end
			end
		end
	end
	if isFlat then
		addError(errors, layerNames.CharacterFlat == true, "flat package needs CharacterFlat")
		addError(errors, #(value.layers or {}) == 1, "flat package must contain one layer")
		local artwork = value.flatArtwork
		addError(errors, type(artwork.width) == "number" and artwork.width > 0, "flat width is required")
		addError(errors, type(artwork.height) == "number" and artwork.height > 0, "flat height is required")
		addError(errors, typeof(artwork.rgba) == "buffer", "flat rgba buffer is required")
		addError(errors, typeof(artwork.anchor) == "Vector2", "flat anchor must be Vector2")
		addError(errors, typeof(artwork.pivot) == "Vector2", "flat pivot must be Vector2")
		addError(errors, type(artwork.variant) == "string", "flat variant is required")
		if typeof(value.canvasSize) == "Vector2"
			and type(artwork.width) == "number"
			and type(artwork.height) == "number" then
			addError(
				errors,
				artwork.width == value.canvasSize.X and artwork.height == value.canvasSize.Y,
				"flat artwork dimensions must match canvasSize"
			)
		end
		if typeof(artwork.rgba) == "buffer"
			and type(artwork.width) == "number"
			and type(artwork.height) == "number" then
			addError(
				errors,
				buffer.len(artwork.rgba) == artwork.width * artwork.height * 4,
				"flat rgba length does not match dimensions"
			)
		end
	else
		for _, required in REQUIRED_LAYERS do
			addError(errors, layerNames[required] == true, "missing required layer " .. required)
		end
	end

	addError(errors, type(value.anchors) == "table", "anchors are required")
	if not isFlat and type(value.anchors) == "table" then
		for _, anchorName in { "Root", "Head", "LeftHand", "RightHand", "LeftFoot", "RightFoot" } do
			addError(errors, typeof(value.anchors[anchorName]) == "Vector2", "missing anchor " .. anchorName)
		end
	end
	addError(errors, type(value.rig) == "table" and (isFlat or #value.rig > 0), "rig is required")
	if type(value.rig) == "table" then
		local joints: { [string]: boolean } = {}
		for _, joint in value.rig do
			addError(errors, type(joint.name) == "string" and not joints[joint.name], "joint names must be unique")
			if type(joint.name) == "string" then joints[joint.name] = true end
			addError(errors, layerNames[joint.layer] == true, "joint layer does not exist: " .. tostring(joint.layer))
			addError(errors, typeof(joint.pivot) == "Vector2", "joint pivot must be Vector2")
		end
	end
	addError(errors, type(value.clips) == "table", "clips are required")
	for _, clipName in if isFlat then {} else { "Idle", "Walk", "Jump" } do
		local clip = if type(value.clips) == "table" then value.clips[clipName] else nil
		addError(errors, type(clip) == "table", "missing clip " .. clipName)
		if type(clip) == "table" then
			addError(errors, clip.name == clipName, "clip name mismatch " .. clipName)
			addError(errors, type(clip.duration) == "number" and clip.duration > 0, "clip duration must be positive")
			addError(errors, type(clip.keyframes) == "table" and #clip.keyframes >= 2, "clip needs two keyframes")
			if type(clip.keyframes) == "table" then
				local previous = -math.huge
				for _, keyframe in clip.keyframes do
					addError(errors, type(keyframe.time) == "number" and keyframe.time >= previous, "keyframes must be ordered")
					previous = keyframe.time
					if type(keyframe.transforms) == "table" then
						for layerName in keyframe.transforms do
							addError(errors, layerNames[layerName] == true, "clip references unknown layer " .. layerName)
						end
					end
				end
			end
		end
	end
	local layerOrder = {}
	if type(value.layers) == "table" then
		for _, layer in SpritePackage.OrderLayers(value :: Package) do
			table.insert(layerOrder, layer.name)
		end
	end
	return { valid = #errors == 0, errors = errors, layerOrder = layerOrder }
end

return SpritePackage
