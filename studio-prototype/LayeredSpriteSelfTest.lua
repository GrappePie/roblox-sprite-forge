--!strict

local AppearanceFingerprint = require(script.Parent:WaitForChild("AppearanceFingerprint"))
local LayeredSpriteRenderer = require(script.Parent:WaitForChild("LayeredSpriteRenderer"))
local LayeredSpriteRuntime = require(script.Parent:WaitForChild("LayeredSpriteRuntime"))
local MockStylizationProvider = require(script.Parent:WaitForChild("MockStylizationProvider"))
local SpritePackage = require(script.Parent:WaitForChild("SpritePackage"))
local SpritePackageCache = require(script.Parent:WaitForChild("SpritePackageCache"))

local LayeredSpriteSelfTest = {}

local function assertEqual(actual: any, expected: any, message: string)
	if actual ~= expected then
		error(string.format("%s (expected %s, got %s)", message, tostring(expected), tostring(actual)))
	end
end

local function findEvent(events: { string }, expected: string): number
	local index = table.find(events, expected)
	if not index then error("Missing event " .. expected) end
	return index
end

function LayeredSpriteSelfTest.Run()
	local snapshotA = {
		shirt = 100,
		body = { width = 1, height = 0.9 },
		accessories = {
			{ assetId = 8, kind = "Hat" },
			{ assetId = 2, kind = "Hair" },
		},
	}
	local snapshotAReordered = {
		accessories = {
			{ kind = "Hat", assetId = 8 },
			{ kind = "Hair", assetId = 2 },
		},
		body = { height = 0.9, width = 1 },
		shirt = 100,
	}
	local snapshotB = table.clone(snapshotA)
	snapshotB.shirt = 101
	local fingerprintA = AppearanceFingerprint.FromSnapshot(snapshotA)
	local fingerprintA2 = AppearanceFingerprint.FromSnapshot(snapshotAReordered)
	local fingerprintB = AppearanceFingerprint.FromSnapshot(snapshotB)
	assertEqual(fingerprintA, fingerprintA2, "Fingerprint must ignore table key order")
	assert(fingerprintA ~= fingerprintB, "Appearance changes must invalidate the fingerprint")

	local package = MockStylizationProvider.BuildPackage(fingerprintA)
	local validation = SpritePackage.Validate(package, fingerprintA)
	assert(validation.valid, table.concat(validation.errors, "; "))
	assertEqual(validation.layerOrder[1], "BackHair", "Layer order must follow zIndex")
	assertEqual(validation.layerOrder[#validation.layerOrder], "Accessories", "Accessories must render last")
	local invalidPackage = table.clone(package)
	invalidPackage.schemaVersion = 99
	local invalid = SpritePackage.Validate(invalidPackage, fingerprintA)
	assert(not invalid.valid, "Invalid schema must be rejected")

	local cache = SpritePackageCache.new()
	assertEqual(cache:Get(fingerprintA), nil, "First cache lookup must miss")
	cache:Put(fingerprintA, package)
	assertEqual(cache:Get(fingerprintA), package, "Second cache lookup must hit")
	local cacheMetrics = cache:Metrics()
	assertEqual(cacheMetrics.hits, 1, "Cache must count hits")
	assertEqual(cacheMetrics.misses, 1, "Cache must count misses")

	local rendererParent = Instance.new("Frame")
	local renderer = LayeredSpriteRenderer.new(rendererParent, package, {
		ViewportSize = Vector2.new(256, 384),
		AutoPlay = false,
		Visible = false,
	})
	local rendererMetrics = renderer:Metrics()
	assertEqual(rendererMetrics.layers, 10, "Renderer must build ten canonical layers")
	assertEqual(rendererMetrics.imagesCreated, 10, "Renderer must create one image per layer")
	assertEqual(rendererMetrics.integerScale, 4, "Renderer must use integer scaling")
	renderer:SetAnimation("Idle")
	renderer:Step(0)
	local rotationA = renderer:GetLayerRotation("LeftArm")
	renderer:Step(0.6)
	local rotationB = renderer:GetLayerRotation("LeftArm")
	assert(rotationA ~= rotationB, "Idle rig must animate a layer transform")
	renderer:SetAnimation("Walk")
	renderer:Step(0.3)
	assertEqual(renderer:Metrics().clip, "Walk", "Renderer must support Walk")
	renderer:SetAnimation("Jump")
	renderer:Step(0.4)
	assertEqual(renderer:Metrics().clip, "Jump", "Renderer must support Jump")
	for _ = 1, 10 do renderer:Step(0.05) end
	assertEqual(renderer:Metrics().imagesCreated, 10, "Animation must not regenerate EditableImages")
	renderer:Destroy()
	assert(renderer:Metrics().destroyed, "Renderer cleanup must mark itself destroyed")
	assertEqual(rendererParent:FindFirstChild("LayeredSprite"), nil, "Renderer cleanup must destroy its GUI")
	rendererParent:Destroy()

	local events = {}
	local provider = {
		kind = "Mock",
		requests = 0,
	}
	function provider:Request(request: any)
		self.requests += 1
		if request.fingerprint == fingerprintA then task.wait(0.06) else task.wait(0.01) end
		return MockStylizationProvider.BuildPackage(request.fingerprint)
	end
	local runtimeCache = SpritePackageCache.new()
	local runtime = LayeredSpriteRuntime.new({
		provider = provider,
		cache = runtimeCache,
		showFallback = function()
			table.insert(events, "fallback-show")
		end,
		hideFallback = function()
			table.insert(events, "fallback-hide")
		end,
		createRenderer = function(createdPackage: any)
			local fake: any = { package = createdPackage, visible = false, destroyed = false, clip = "" }
			function fake:SetVisible(visible: boolean)
				self.visible = visible
				if visible then table.insert(events, "renderer-visible") end
			end
			function fake:SetAnimation(name: string) self.clip = name end
			function fake:Destroy() self.destroyed = true end
			return fake
		end,
	})
	runtime:Start(snapshotA, fingerprintA)
	runtime:Start(snapshotB, fingerprintB)
	task.wait(0.11)
	assertEqual(runtime:GetState(), "Ready", "Newest provider response must become ready")
	assertEqual(runtime:GetFingerprint(), fingerprintB, "Stale response must not replace current fingerprint")
	assertEqual(runtime:Metrics().staleResponses, 1, "Stale provider response must be counted")
	assert(findEvent(events, "fallback-show") < findEvent(events, "renderer-visible"), "Fallback must appear first")
	assert(findEvent(events, "renderer-visible") < findEvent(events, "fallback-hide"), "Replacement must be visible before fallback hides")
	assertEqual(runtime.renderer.clip, "Idle", "Runtime must start Idle")
	local providerRequests = provider.requests
	runtime:Respawn(snapshotB, fingerprintB)
	assertEqual(runtime:GetState(), "Ready", "Respawn must reuse a cached valid package")
	assertEqual(provider.requests, providerRequests, "Cache hit must not call provider")
	assertEqual(runtime:Metrics().cacheHits, 1, "Respawn must record cache hit")
	assertEqual(runtime:Metrics().respawns, 1, "Respawn must be tracked")
	runtime:Destroy()
	assertEqual(runtime:GetState(), "Idle", "Destroy must return runtime to Idle")
	assert(runtime:Metrics().cleanups >= 2, "Replacement and destroy must clean renderers")

	local failedRuntime = LayeredSpriteRuntime.new({
		provider = {
			kind = "Mock",
			Request = function(_: any, request: any)
				local bad = MockStylizationProvider.BuildPackage(request.fingerprint)
				bad.layers = {}
				return bad
			end,
		},
		cache = SpritePackageCache.new(),
		showFallback = function() end,
		hideFallback = function() end,
		createRenderer = function() error("Invalid package reached renderer") end,
	})
	failedRuntime:Start(snapshotA, fingerprintA)
	task.wait()
	assertEqual(failedRuntime:GetState(), "Failed", "Invalid provider package must fail validation")
	assert(failedRuntime:Metrics().fallbackVisible, "Fallback must remain visible after provider failure")
	failedRuntime:Destroy()

	return {
		fingerprint = fingerprintA,
		layerCount = #package.layers,
		cacheHits = runtime:Metrics().cacheHits,
		staleResponses = runtime:Metrics().staleResponses,
		transitions = runtime:Metrics().transitions,
		imagesCreated = rendererMetrics.imagesCreated,
	}
end

return LayeredSpriteSelfTest
