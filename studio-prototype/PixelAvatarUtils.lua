--!strict

local Players = game:GetService("Players")

local Utils = {}

export type PosePair = {
	source: Motor6D | AnimationConstraint | Bone,
	target: Motor6D | AnimationConstraint | Bone,
}

local function relativePath(instance: Instance, root: Instance): { string }
	local names = {}
	local cursor: Instance? = instance
	while cursor and cursor ~= root do
		table.insert(names, 1, cursor.Name)
		cursor = cursor.Parent
	end
	return names
end

local function findByRelativePath(root: Instance, names: { string }): Instance?
	local cursor: Instance = root
	for _, name in names do
		local child = cursor:FindFirstChild(name)
		if not child then
			return nil
		end
		cursor = child
	end
	return cursor
end

function Utils.buildPosePairs(character: Model, clone: Model): { PosePair }
	local pairs = {}
	for _, source in character:GetDescendants() do
		if source:IsA("Motor6D") or source:IsA("AnimationConstraint") or source:IsA("Bone") then
			local target = findByRelativePath(clone, relativePath(source, character))
			if target and target.ClassName == source.ClassName then
				table.insert(pairs, {
					source = source,
					target = target :: Motor6D | AnimationConstraint | Bone,
				})
			end
		end
	end
	return pairs
end

function Utils.syncPose(pairs: { PosePair })
	for _, pair in pairs do
		if pair.source:IsA("Motor6D") and pair.target:IsA("Motor6D") then
			pair.target.Transform = pair.source.Transform
		elseif pair.source:IsA("AnimationConstraint") and pair.target:IsA("AnimationConstraint") then
			pair.target.Transform = pair.source.Transform
		elseif pair.source:IsA("Bone") and pair.target:IsA("Bone") then
			pair.target.Transform = pair.source.Transform
		end
	end
end

function Utils.syncAnimationTracks(
	sourceHumanoid: Humanoid,
	targetAnimator: Animator,
	trackMap: { [AnimationTrack]: AnimationTrack }
): number
	local sourceAnimator = sourceHumanoid:FindFirstChildOfClass("Animator")
	if not sourceAnimator or not targetAnimator then
		return 0
	end

	local active: { [AnimationTrack]: boolean } = {}
	local activeCount = 0
	for _, sourceTrack in sourceAnimator:GetPlayingAnimationTracks() do
		local animation = sourceTrack.Animation
		if not animation or animation.AnimationId == "" then
			continue
		end
		active[sourceTrack] = true
		activeCount += 1
		local targetTrack = trackMap[sourceTrack]
		if not targetTrack then
			local targetAnimation = Instance.new("Animation")
			targetAnimation.Name = "PixelAvatar_" .. sourceTrack.Name
			targetAnimation.AnimationId = animation.AnimationId
			local loaded, loadProblem = pcall(function()
				return targetAnimator:LoadAnimation(targetAnimation)
			end)
			targetAnimation:Destroy()
			if not loaded or not loadProblem then
				warn("[PixelAvatar] animation load failed: " .. tostring(loadProblem))
				continue
			end
			targetTrack = loadProblem :: AnimationTrack
			targetTrack.Priority = sourceTrack.Priority
			targetTrack.Looped = sourceTrack.Looped
			targetTrack:Play(0, math.max(sourceTrack.WeightCurrent, 0.001), 0)
			trackMap[sourceTrack] = targetTrack
		end

		targetTrack.Priority = sourceTrack.Priority
		targetTrack.Looped = sourceTrack.Looped
		if not targetTrack.IsPlaying then
			targetTrack:Play(0, math.max(sourceTrack.WeightCurrent, 0.001), 0)
		end
		targetTrack.TimePosition = sourceTrack.TimePosition
		targetTrack:AdjustWeight(sourceTrack.WeightCurrent, 0)
		targetTrack:AdjustSpeed(0)
	end

	for sourceTrack, targetTrack in trackMap do
		if not active[sourceTrack] then
			targetTrack:Stop(0)
			targetTrack:Destroy()
			trackMap[sourceTrack] = nil
		end
	end
	return activeCount
end

function Utils.makeAnimationOnly(model: Model): Animator
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		error("Visual model has no Humanoid to convert")
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
	end
	local controller = Instance.new("AnimationController")
	controller.Name = "PixelAvatarAnimationController"
	controller.Parent = model
	animator.Parent = controller
	humanoid:Destroy()
	return animator
end

function Utils.setCharacterHidden(character: Model, hidden: boolean)
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.LocalTransparencyModifier = if hidden then 1 else 0
			descendant.CastShadow = not hidden
		end
	end
end

local function quantizeChannel(channel: number, levels: number): number
	local steps = math.max(2, levels) - 1
	return math.floor((channel * steps) + 0.5) / steps
end

function Utils.quantizeColor(color: Color3, levels: number): Color3
	return Color3.new(
		quantizeChannel(color.R, levels),
		quantizeChannel(color.G, levels),
		quantizeChannel(color.B, levels)
	)
end

function Utils.prepareVisualClone(clone: Model, paletteLevels: number, material: Enum.Material): number
	local partCount = 0
	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("LuaSourceContainer")
			or descendant:IsA("Sound")
			or descendant:IsA("ParticleEmitter")
			or descendant:IsA("Trail")
			or descendant:IsA("Beam")
			or descendant:IsA("BillboardGui")
			or descendant:IsA("SurfaceGui")
			or descendant:IsA("Highlight") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			partCount += 1
			descendant.LocalTransparencyModifier = 0
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.CastShadow = false
			descendant.Massless = true
			descendant.Reflectance = 0
			descendant.Material = material
			descendant.Color = Utils.quantizeColor(descendant.Color, paletteLevels)
		end
	end

	local humanoid = clone:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid.BreakJointsOnDeath = false
	end
	return partCount
end

function Utils.cloneCharacter(character: Model, paletteLevels: number, material: Enum.Material): (Model, BasePart, number)
	local wasArchivable = character.Archivable
	character.Archivable = true
	local clone = character:Clone()
	character.Archivable = wasArchivable
	clone.Name = "PixelAvatarVisual"

	local partCount = Utils.prepareVisualClone(clone, paletteLevels, material)
	local root = clone:FindFirstChild("HumanoidRootPart", true)
	if not root or not root:IsA("BasePart") then
		clone:Destroy()
		error("Visual clone has no HumanoidRootPart")
	end

	clone.PrimaryPart = root
	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = descendant == root
		end
	end
	return clone, root, partCount
end

function Utils.createPlayerVisual(
	player: Player,
	character: Model,
	paletteLevels: number,
	material: Enum.Material
): (Model, BasePart, number, string)
	local sourceHumanoid = character:FindFirstChildOfClass("Humanoid")
	local visual: Model? = nil
	local appearanceSource = "character clone"
	local ok, problem = pcall(function()
		local description = Players:GetHumanoidDescriptionFromUserIdAsync(player.UserId)
		local rigType = if sourceHumanoid then sourceHumanoid.RigType else Enum.HumanoidRigType.R15
		visual = Players:CreateHumanoidModelFromDescriptionAsync(description, rigType)
	end)
	if not ok or not visual then
		warn(string.format(
			"[PixelAvatar] public appearance unavailable for %s; using character clone: %s",
			player.Name,
			tostring(problem)
		))
		local fallback, fallbackRoot, fallbackParts =
			Utils.cloneCharacter(character, paletteLevels, material)
		return fallback, fallbackRoot, fallbackParts, appearanceSource
	end

	appearanceSource = "Roblox HumanoidDescription"
	local model = visual :: Model
	model.Name = "PixelAvatarVisual"
	local partCount = Utils.prepareVisualClone(model, paletteLevels, material)
	local root = model:FindFirstChild("HumanoidRootPart", true)
	if not root or not root:IsA("BasePart") then
		model:Destroy()
		error("Roblox appearance model has no HumanoidRootPart")
	end
	model.PrimaryPart = root
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = descendant == root
		end
	end
	return model, root, partCount, appearanceSource
end

function Utils.flatUnit(vector: Vector3, fallback: Vector3): Vector3
	local flat = Vector3.new(vector.X, 0, vector.Z)
	if flat.Magnitude < 0.001 then
		return fallback
	end
	return flat.Unit
end

function Utils.destroyConnections(connections: { RBXScriptConnection })
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

return Utils
