--!strict

local AssetService = game:GetService("AssetService")
local RunService = game:GetService("RunService")

local SpritePackage = require(script.Parent:WaitForChild("SpritePackage"))

local LayeredSpriteRenderer = {}
LayeredSpriteRenderer.__index = LayeredSpriteRenderer

type Package = SpritePackage.Package
type Transform = SpritePackage.Transform
type Clip = SpritePackage.Clip

export type Options = {
	ViewportSize: Vector2?,
	AutoPlay: boolean?,
	Visible: boolean?,
}

export type Renderer = typeof(setmetatable({} :: {
	package: Package,
	root: Frame,
	labels: { [string]: ImageLabel },
	images: { EditableImage },
	baseAnchors: { [string]: Vector2 },
	basePivots: { [string]: Vector2 },
	scale: number,
	viewportSize: Vector2,
	clipName: string,
	clipTime: number,
	connection: RBXScriptConnection?,
	destroyed: boolean,
	imagesCreated: number,
	steps: number,
}, LayeredSpriteRenderer))

local function writeRect(
	pixels: buffer,
	canvasSize: Vector2,
	rect: SpritePackage.Rect,
	color: Color3
)
	local width = math.floor(canvasSize.X)
	local height = math.floor(canvasSize.Y)
	local minX = math.clamp(math.floor(rect.x), 0, width - 1)
	local minY = math.clamp(math.floor(rect.y), 0, height - 1)
	local maxX = math.clamp(math.ceil(rect.x + rect.width) - 1, 0, width - 1)
	local maxY = math.clamp(math.ceil(rect.y + rect.height) - 1, 0, height - 1)
	local alpha = math.clamp(math.round((rect.alpha or 1) * 255), 0, 255)
	for y = minY, maxY do
		for x = minX, maxX do
			local offset = (y * width + x) * 4
			buffer.writeu8(pixels, offset, math.round(color.R * 255))
			buffer.writeu8(pixels, offset + 1, math.round(color.G * 255))
			buffer.writeu8(pixels, offset + 2, math.round(color.B * 255))
			buffer.writeu8(pixels, offset + 3, alpha)
		end
	end
end

local function rasterizeLayer(package: Package, layer: SpritePackage.Layer): EditableImage
	local size = package.canvasSize
	local image = AssetService:CreateEditableImage({ Size = size })
	if package.flatArtwork and layer.name == "CharacterFlat" then
		image:WritePixelsBuffer(Vector2.zero, size, package.flatArtwork.rgba)
		return image
	end
	local pixels = buffer.create(math.floor(size.X) * math.floor(size.Y) * 4)
	for _, rect in layer.rects do
		writeRect(pixels, size, rect, package.palette[rect.colorIndex])
	end
	image:WritePixelsBuffer(Vector2.zero, size, pixels)
	return image
end

local function lerpNumber(left: number?, right: number?, alpha: number, fallback: number): number
	return (left or fallback) + ((right or fallback) - (left or fallback)) * alpha
end

local function lerpVector(left: Vector2?, right: Vector2?, alpha: number, fallback: Vector2): Vector2
	return (left or fallback):Lerp(right or fallback, alpha)
end

function LayeredSpriteRenderer.CalculateIntegerScale(canvasSize: Vector2, viewportSize: Vector2): number
	return math.max(1, math.floor(math.min(
		viewportSize.X / math.max(1, canvasSize.X),
		viewportSize.Y / math.max(1, canvasSize.Y)
	)))
end

function LayeredSpriteRenderer.SampleClip(clip: Clip, requestedTime: number): (Vector2, { [string]: Transform })
	local time = if clip.looped
		then requestedTime % clip.duration
		else math.clamp(requestedTime, 0, clip.duration)
	local left = clip.keyframes[1]
	local right = clip.keyframes[#clip.keyframes]
	for index = 1, #clip.keyframes - 1 do
		local candidate = clip.keyframes[index]
		local nextCandidate = clip.keyframes[index + 1]
		if time >= candidate.time and time <= nextCandidate.time then
			left = candidate
			right = nextCandidate
			break
		end
	end
	local span = math.max(0.0001, right.time - left.time)
	local alpha = math.clamp((time - left.time) / span, 0, 1)
	local names: { [string]: boolean } = {}
	for name in left.transforms do names[name] = true end
	for name in right.transforms do names[name] = true end
	local sampled: { [string]: Transform } = {}
	for name in names do
		local leftTransform = left.transforms[name] or {}
		local rightTransform = right.transforms[name] or {}
		sampled[name] = {
			position = lerpVector(leftTransform.position, rightTransform.position, alpha, Vector2.zero),
			rotation = lerpNumber(leftTransform.rotation, rightTransform.rotation, alpha, 0),
			scale = lerpVector(leftTransform.scale, rightTransform.scale, alpha, Vector2.one),
		}
	end
	return lerpVector(left.rootOffset, right.rootOffset, alpha, Vector2.zero), sampled
end

function LayeredSpriteRenderer.new(parent: Instance, package: Package, options: Options?): Renderer
	local validation = SpritePackage.Validate(package, package.fingerprint)
	if not validation.valid then
		error("Invalid SpritePackage: " .. table.concat(validation.errors, "; "))
	end
	local resolved = options or {}
	local viewportSize = resolved.ViewportSize or Vector2.new(512, 512)
	local scale = LayeredSpriteRenderer.CalculateIntegerScale(package.canvasSize, viewportSize)
	local displaySize = package.canvasSize * scale
	local root = Instance.new("Frame")
	root.Name = "LayeredSprite"
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.fromScale(0.5, 0.5)
	root.Size = UDim2.fromOffset(displaySize.X, displaySize.Y)
	root.BackgroundTransparency = 1
	root.ClipsDescendants = false
	root.Visible = resolved.Visible ~= false
	root.Parent = parent

	local renderer: Renderer = setmetatable({
		package = package,
		root = root,
		labels = {},
		images = {},
		baseAnchors = {},
		basePivots = {},
		scale = scale,
		viewportSize = viewportSize,
		clipName = if package.flatArtwork then "Static" else "Idle",
		clipTime = 0,
		connection = nil,
		destroyed = false,
		imagesCreated = 0,
		steps = 0,
	}, LayeredSpriteRenderer)

	for _, layer in SpritePackage.OrderLayers(package) do
		local image = rasterizeLayer(package, layer)
		table.insert(renderer.images, image)
		renderer.imagesCreated += 1
		local label = Instance.new("ImageLabel")
		label.Name = layer.name
		label.BackgroundTransparency = 1
		label.BorderSizePixel = 0
		label.ResampleMode = Enum.ResamplerMode.Pixelated
		label.ScaleType = Enum.ScaleType.Stretch
		label.AnchorPoint = if package.flatArtwork
			then layer.pivot
			else Vector2.new(
				layer.pivot.X / package.canvasSize.X,
				layer.pivot.Y / package.canvasSize.Y
			)
		label.Position = if package.flatArtwork
			then UDim2.fromScale(layer.anchor.X, layer.anchor.Y)
			else UDim2.fromOffset(layer.anchor.X * scale, layer.anchor.Y * scale)
		label.Size = UDim2.fromOffset(displaySize.X, displaySize.Y)
		-- Package zIndex is relative to the sprite. GUI ZIndex 0 would render
		-- behind the preview panel itself, so reserve 0 for the host background.
		label.ZIndex = layer.zIndex + 1
		label.ImageContent = Content.fromObject(image)
		label.Parent = root
		renderer.labels[layer.name] = label
		renderer.baseAnchors[layer.name] = layer.anchor
		renderer.basePivots[layer.name] = layer.pivot
	end
	if not package.flatArtwork then
		renderer:SetAnimation("Idle")
		renderer:Step(0)
	end
	if not package.flatArtwork and resolved.AutoPlay ~= false then
		renderer.connection = RunService.RenderStepped:Connect(function(deltaTime)
			renderer:Step(deltaTime)
		end)
	end
	return renderer
end

function LayeredSpriteRenderer.SetVisible(self: Renderer, visible: boolean)
	if not self.destroyed then
		self.root.Visible = visible
	end
end

function LayeredSpriteRenderer.SetAnimation(self: Renderer, clipName: string)
	if not self.package.clips[clipName] then
		error("Unknown SpritePackage clip " .. clipName)
	end
	self.clipName = clipName
	self.clipTime = 0
end

function LayeredSpriteRenderer.Step(self: Renderer, deltaTime: number)
	if self.destroyed then return end
	self.steps += 1
	if self.package.flatArtwork then return end
	self.clipTime += math.max(0, deltaTime)
	local clip = self.package.clips[self.clipName]
	local rootOffset, transforms = LayeredSpriteRenderer.SampleClip(clip, self.clipTime)
	self.root.Position = UDim2.new(0.5, rootOffset.X * self.scale, 0.5, rootOffset.Y * self.scale)
	local displaySize = self.package.canvasSize * self.scale
	for name, label in self.labels do
		local transform = transforms[name]
		local position = if transform and transform.position then transform.position else Vector2.zero
		local rotation = if transform and transform.rotation then transform.rotation else 0
		local scale = if transform and transform.scale then transform.scale else Vector2.one
		local anchor = self.baseAnchors[name]
		label.Position = UDim2.fromOffset(
			(anchor.X + position.X) * self.scale,
			(anchor.Y + position.Y) * self.scale
		)
		label.Rotation = rotation
		label.Size = UDim2.fromOffset(displaySize.X * scale.X, displaySize.Y * scale.Y)
	end
end

function LayeredSpriteRenderer.GetLayerOrder(self: Renderer): { string }
	local names = {}
	for _, layer in SpritePackage.OrderLayers(self.package) do
		table.insert(names, layer.name)
	end
	return names
end

function LayeredSpriteRenderer.GetLayerRotation(self: Renderer, name: string): number
	local label = self.labels[name]
	return if label then label.Rotation else 0
end

function LayeredSpriteRenderer.Metrics(self: Renderer)
	return {
		layers = #self.package.layers,
		imagesCreated = self.imagesCreated,
		steps = self.steps,
		integerScale = self.scale,
		clip = self.clipName,
		destroyed = self.destroyed,
	}
end

function LayeredSpriteRenderer.Destroy(self: Renderer)
	if self.destroyed then return end
	self.destroyed = true
	if self.connection then
		self.connection:Disconnect()
		self.connection = nil
	end
	self.root:Destroy()
	for _, image in self.images do
		image:Destroy()
	end
	table.clear(self.images)
	table.clear(self.labels)
end

return LayeredSpriteRenderer
