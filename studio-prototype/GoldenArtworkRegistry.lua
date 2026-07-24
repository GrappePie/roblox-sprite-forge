--!strict

-- The offline installer replaces this empty registry with validated imported
-- resources from stylization-results/. Keeping the default empty makes the
-- MissingGoldenArtwork fallback path explicit and testable.
return table.freeze({
	schemaVersion = 1,
	entries = table.freeze({}),
})
