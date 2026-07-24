--!strict

local AppearanceFingerprint = require(script.Parent:WaitForChild("AppearanceFingerprint"))
local LayeredSpriteRenderer = require(script.Parent:WaitForChild("LayeredSpriteRenderer"))
local LayeredSpriteRuntime = require(script.Parent:WaitForChild("LayeredSpriteRuntime"))
local MockStylizationProvider = require(script.Parent:WaitForChild("MockStylizationProvider"))
local GoldenArtworkProvider = require(script.Parent:WaitForChild("GoldenArtworkProvider"))
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
	local authoredEntry = { assetIds = { 100, 200, 300 } }
	local compatible, compatibleRatio = GoldenArtworkProvider.IsAppearanceCompatible(authoredEntry, {
		Shirt = 100,
		Pants = 200,
		accessories = { { assetId = 300 } },
	})
	assert(compatible and compatibleRatio == 1, "Matching appearance must reuse Golden Artwork")
	local incompatible, incompatibleRatio = GoldenArtworkProvider.IsAppearanceCompatible(authoredEntry, {
		Shirt = 999,
		Pants = 998,
		accessories = { { assetId = 997 } },
	})
	assert(
		not incompatible and incompatibleRatio == 0,
		"Changed appearance must not reuse Golden Artwork by userId"
	)
	local removedAsset = GoldenArtworkProvider.IsAppearanceCompatible(authoredEntry, {
		Shirt = 100,
		Pants = 200,
	})
	assert(not removedAsset, "Removed accessories must invalidate Golden Artwork")

	local package = MockStylizationProvider.BuildPackage(fingerprintA)
	local validation = SpritePackage.Validate(package, fingerprintA)
	assert(validation.valid, table.concat(validation.errors, "; "))
	assertEqual(validation.layerOrder[1], "BackHair", "Layer order must follow zIndex")
	assertEqual(validation.layerOrder[#validation.layerOrder], "Accessories", "Accessories must render last")
	local invalidPackage = table.clone(package)
	invalidPackage.schemaVersion = 99
	local invalid = SpritePackage.Validate(invalidPackage, fingerprintA)
	assert(not invalid.valid, "Invalid schema must be rejected")

	local flatPixels = buffer.create(16 * 32 * 4)
	for y = 4, 27 do
		for x = 3, 12 do
			local offset = (y * 16 + x) * 4
			buffer.writeu8(flatPixels, offset, 72 + x * 4)
			buffer.writeu8(flatPixels, offset + 1, 210 - y * 2)
			buffer.writeu8(flatPixels, offset + 2, 164)
			buffer.writeu8(flatPixels, offset + 3, 255)
		end
	end
	local flatPackage = {
		schemaVersion = 1,
		id = "golden-flat-test",
		fingerprint = fingerprintA,
		canvasSize = Vector2.new(16, 32),
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
			width = 16,
			height = 32,
			rgba = flatPixels,
			anchor = Vector2.new(0.5, 1),
			pivot = Vector2.new(0.5, 1),
			variant = "master",
			contentHash = "synthetic",
		},
	}
	local flatValidation = SpritePackage.Validate(flatPackage, fingerprintA)
	assert(flatValidation.valid, "Flat SpritePackage must validate: " .. table.concat(flatValidation.errors, "; "))
	assertEqual(flatValidation.layerOrder[1], "CharacterFlat", "Flat package must keep CharacterFlat")

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

	local flatParent = Instance.new("Frame")
	local flatRenderer = LayeredSpriteRenderer.new(flatParent, flatPackage, {
		ViewportSize = Vector2.new(64, 128),
		AutoPlay = true,
		Visible = false,
	})
	assertEqual(flatRenderer:Metrics().layers, 1, "Flat renderer must create one layer")
	assertEqual(flatRenderer:Metrics().imagesCreated, 1, "Flat renderer must create one EditableImage")
	assertEqual(flatRenderer:Metrics().integerScale, 4, "Flat renderer must use integer scaling")
	assertEqual(flatRenderer:Metrics().clip, "Static", "Flat artwork must not start a rig clip")
	for _ = 1, 10 do flatRenderer:Step(0.05) end
	assertEqual(flatRenderer:Metrics().imagesCreated, 1, "Flat Step must not recreate EditableImage")
	flatRenderer:Destroy()
	assertEqual(flatParent:FindFirstChild("LayeredSprite"), nil, "Flat cleanup must destroy its GUI")
	flatParent:Destroy()

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

	local missingHideCalls = 0
	local missingRuntime = LayeredSpriteRuntime.new({
		provider = {
			kind = "GoldenArtwork",
			Request = function(_: any, request: any)
				return nil, "MissingGoldenArtwork:" .. request.fingerprint
			end,
		},
		cache = SpritePackageCache.new(),
		showFallback = function() end,
		hideFallback = function() missingHideCalls += 1 end,
		createRenderer = function() error("Missing artwork must not create renderer") end,
	})
	missingRuntime:Start(snapshotA, fingerprintA)
	task.wait()
	assertEqual(
		missingRuntime:GetState(),
		"MissingGoldenArtwork",
		"Missing golden artwork must be a distinct state"
	)
	assert(missingRuntime:Metrics().fallbackVisible, "Missing golden artwork must keep fallback visible")
	assertEqual(missingHideCalls, 0, "Missing artwork must not hide fallback")
	missingRuntime:Destroy()

	local flatRequests = 0
	local flatCache = SpritePackageCache.new()
	local flatRuntime = LayeredSpriteRuntime.new({
		provider = {
			kind = "GoldenArtwork",
			Request = function(_: any)
				flatRequests += 1
				return flatPackage
			end,
		},
		cache = flatCache,
		showFallback = function() end,
		hideFallback = function() end,
		createRenderer = function(createdPackage: any)
			local fake: any = { package = createdPackage, visible = false, destroyed = false }
			function fake:SetVisible(visible: boolean) self.visible = visible end
			function fake:Destroy() self.destroyed = true end
			return fake
		end,
	})
	flatRuntime:Start(snapshotA, fingerprintA)
	task.wait()
	assertEqual(flatRuntime:GetState(), "Ready", "Flat artwork must replace fallback")
	assert(flatRuntime.renderer.visible, "Flat artwork must be visible before fallback hides")
	flatRuntime:Respawn(snapshotA, fingerprintA)
	assertEqual(flatRequests, 1, "Flat artwork respawn must reuse cache")
	assertEqual(flatRuntime:Metrics().cacheHits, 1, "Flat cache hit must be counted")
	flatRuntime:Destroy()
	assert(flatRuntime:Metrics().cleanups >= 2, "Flat EditableImage owners must be cleaned")

	return {
		fingerprint = fingerprintA,
		layerCount = #package.layers,
		cacheHits = runtime:Metrics().cacheHits,
		staleResponses = runtime:Metrics().staleResponses,
		transitions = runtime:Metrics().transitions,
		imagesCreated = rendererMetrics.imagesCreated,
		flatImagesCreated = 1,
	}
end

return LayeredSpriteSelfTest
