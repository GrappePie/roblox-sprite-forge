--!strict

local AppearanceFingerprint = require(script.Parent:WaitForChild("AppearanceFingerprint"))
local SpritePackage = require(script.Parent:WaitForChild("SpritePackage"))

local LayeredSpriteRuntime = {}
LayeredSpriteRuntime.__index = LayeredSpriteRuntime

export type State =
	"Idle"
	| "Fingerprinting"
	| "Fallback"
	| "Loading"
	| "Validating"
	| "Ready"
	| "MissingGoldenArtwork"
	| "Failed"
	| "Stale"

export type Options = {
	provider: any,
	cache: any,
	createRenderer: (package: any) -> any,
	showFallback: (fingerprint: string) -> (),
	hideFallback: () -> (),
	onStateChanged: ((state: State, detail: string?) -> ())?,
}

export type Runtime = typeof(setmetatable({} :: {
	provider: any,
	cache: any,
	createRenderer: (package: any) -> any,
	showFallback: (fingerprint: string) -> (),
	hideFallback: () -> (),
	onStateChanged: ((state: State, detail: string?) -> ())?,
	state: State,
	stateHistory: { State },
	generation: number,
	fingerprint: string?,
	renderer: any?,
	fallbackVisible: boolean,
	destroyed: boolean,
	cacheHits: number,
	cacheMisses: number,
	staleResponses: number,
	fallbackShows: number,
	transitions: number,
	respawns: number,
	cleanups: number,
	failures: number,
}, LayeredSpriteRuntime))

local function safeCall(callback: (...any) -> (), ...: any)
	local ok, problem = pcall(callback, ...)
	if not ok then
		warn("[LayeredSpriteRuntime] callback failed: " .. tostring(problem))
	end
end

function LayeredSpriteRuntime.new(options: Options): Runtime
	assert(options.provider ~= nil, "LayeredSpriteRuntime requires provider")
	assert(options.cache ~= nil, "LayeredSpriteRuntime requires cache")
	return setmetatable({
		provider = options.provider,
		cache = options.cache,
		createRenderer = options.createRenderer,
		showFallback = options.showFallback,
		hideFallback = options.hideFallback,
		onStateChanged = options.onStateChanged,
		state = "Idle",
		stateHistory = { "Idle" },
		generation = 0,
		fingerprint = nil,
		renderer = nil,
		fallbackVisible = false,
		destroyed = false,
		cacheHits = 0,
		cacheMisses = 0,
		staleResponses = 0,
		fallbackShows = 0,
		transitions = 0,
		respawns = 0,
		cleanups = 0,
		failures = 0,
	}, LayeredSpriteRuntime)
end

function LayeredSpriteRuntime.SetState(self: Runtime, state: State, detail: string?)
	self.state = state
	table.insert(self.stateHistory, state)
	if self.onStateChanged then
		safeCall(self.onStateChanged, state, detail)
	end
end

function LayeredSpriteRuntime.ShowFallback(self: Runtime, fingerprint: string)
	if self.fallbackVisible then return end
	self.fallbackVisible = true
	self.fallbackShows += 1
	safeCall(self.showFallback, fingerprint)
	self:SetState("Fallback")
end

function LayeredSpriteRuntime.HideFallback(self: Runtime)
	if not self.fallbackVisible then return end
	safeCall(self.hideFallback)
	self.fallbackVisible = false
end

function LayeredSpriteRuntime.CleanupRenderer(self: Runtime)
	if not self.renderer then return end
	local renderer = self.renderer
	self.renderer = nil
	if type(renderer.Destroy) == "function" then
		safeCall(function() renderer:Destroy() end)
	end
	self.cleanups += 1
end

function LayeredSpriteRuntime.ActivatePackage(
	self: Runtime,
	package: any,
	fingerprint: string,
	fromCache: boolean,
	generation: number
): boolean
	self:SetState("Validating")
	local validation = SpritePackage.Validate(package, fingerprint)
	if not validation.valid then
		self.failures += 1
		self:SetState("Failed", table.concat(validation.errors, "; "))
		return false
	end
	if generation ~= self.generation or fingerprint ~= self.fingerprint then
		self.staleResponses += 1
		return false
	end
	local ok, rendererOrError = pcall(self.createRenderer, package)
	if not ok then
		self.failures += 1
		self:SetState("Failed", tostring(rendererOrError))
		return false
	end
	if generation ~= self.generation or fingerprint ~= self.fingerprint then
		local staleRenderer = rendererOrError
		if type(staleRenderer.Destroy) == "function" then
			staleRenderer:Destroy()
		end
		self.staleResponses += 1
		return false
	end
	if not fromCache then
		self.cache:Put(fingerprint, package)
	end
	self:CleanupRenderer()
	self.renderer = rendererOrError
	if type(self.renderer.SetAnimation) == "function" and package.clips.Idle then
		self.renderer:SetAnimation("Idle")
	end
	if type(self.renderer.SetVisible) == "function" then
		self.renderer:SetVisible(true)
	end
	-- The replacement is already visible before the fallback is hidden.
	self:HideFallback()
	self.transitions += 1
	self:SetState("Ready", if fromCache then "cache-hit" else "provider")
	return true
end

function LayeredSpriteRuntime.Start(self: Runtime, appearance: { [string]: any }, fingerprintOverride: string?): string
	assert(not self.destroyed, "LayeredSpriteRuntime is destroyed")
	self.generation += 1
	local generation = self.generation
	self:SetState("Fingerprinting")
	local fingerprint = fingerprintOverride or AppearanceFingerprint.FromSnapshot(appearance)
	self.fingerprint = fingerprint
	local cached = self.cache:Get(fingerprint)
	if cached ~= nil then
		self.cacheHits += 1
		self:ActivatePackage(cached, fingerprint, true, generation)
		return fingerprint
	end
	self.cacheMisses += 1
	self:ShowFallback(fingerprint)
	self:SetState("Loading")
	task.spawn(function()
		local ok, packageOrError, providerDetail = pcall(function()
			return self.provider:Request({
				fingerprint = fingerprint,
				appearance = appearance,
				generation = generation,
			})
		end)
		if generation ~= self.generation or fingerprint ~= self.fingerprint or self.destroyed then
			self.staleResponses += 1
			return
		end
		if not ok then
			self.failures += 1
			self:SetState("Failed", tostring(packageOrError))
			return
		end
		if packageOrError == nil then
			self:SetState("MissingGoldenArtwork", tostring(providerDetail or fingerprint))
			return
		end
		self:ActivatePackage(packageOrError, fingerprint, false, generation)
	end)
	return fingerprint
end

function LayeredSpriteRuntime.Respawn(self: Runtime, appearance: { [string]: any }, fingerprintOverride: string?): string
	self.respawns += 1
	self:Cancel()
	return self:Start(appearance, fingerprintOverride)
end

function LayeredSpriteRuntime.Cancel(self: Runtime)
	if self.destroyed then return end
	self.generation += 1
	self:SetState("Stale")
	self:CleanupRenderer()
	self:HideFallback()
	self.fingerprint = nil
end

function LayeredSpriteRuntime.GetState(self: Runtime): State
	return self.state
end

function LayeredSpriteRuntime.GetFingerprint(self: Runtime): string?
	return self.fingerprint
end

function LayeredSpriteRuntime.Metrics(self: Runtime)
	return {
		state = self.state,
		cacheHits = self.cacheHits,
		cacheMisses = self.cacheMisses,
		staleResponses = self.staleResponses,
		fallbackShows = self.fallbackShows,
		transitions = self.transitions,
		respawns = self.respawns,
		cleanups = self.cleanups,
		failures = self.failures,
		generation = self.generation,
		fallbackVisible = self.fallbackVisible,
	}
end

function LayeredSpriteRuntime.Destroy(self: Runtime)
	if self.destroyed then return end
	self:Cancel()
	self.destroyed = true
	self:SetState("Idle")
end

return LayeredSpriteRuntime
