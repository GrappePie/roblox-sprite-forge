--!strict

local SpritePackageCache = {}
SpritePackageCache.__index = SpritePackageCache

export type Cache = typeof(setmetatable({} :: {
	entries: { [string]: any },
	hits: number,
	misses: number,
	writes: number,
}, SpritePackageCache))

function SpritePackageCache.new(): Cache
	return setmetatable({
		entries = {},
		hits = 0,
		misses = 0,
		writes = 0,
	}, SpritePackageCache)
end

function SpritePackageCache.Get(self: Cache, fingerprint: string): any?
	local value = self.entries[fingerprint]
	if value == nil then
		self.misses += 1
	else
		self.hits += 1
	end
	return value
end

function SpritePackageCache.Put(self: Cache, fingerprint: string, package: any)
	self.entries[fingerprint] = package
	self.writes += 1
end

function SpritePackageCache.Invalidate(self: Cache, fingerprint: string)
	self.entries[fingerprint] = nil
end

function SpritePackageCache.Clear(self: Cache)
	table.clear(self.entries)
end

function SpritePackageCache.Metrics(self: Cache)
	local count = 0
	for _ in self.entries do count += 1 end
	return {
		hits = self.hits,
		misses = self.misses,
		writes = self.writes,
		entries = count,
	}
end

return SpritePackageCache
