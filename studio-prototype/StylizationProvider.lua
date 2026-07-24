--!strict

local StylizationProvider = {}

export type Request = {
	fingerprint: string,
	appearance: { [string]: any },
	generation: number,
}

export type Provider = {
	kind: "Mock" | "Http" | "Offline" | "ManualLibrary",
	Request: (self: Provider, request: Request) -> any,
}

StylizationProvider.FutureKinds = {
	Http = "Provider ejecutado en backend; nunca expone secretos al LocalScript.",
	Offline = "Herramienta de autoría que exporta SpritePackage antes de publicar.",
	ManualLibrary = "Biblioteca artística curada para un catálogo limitado.",
}

function StylizationProvider.IsProvider(value: any): boolean
	return type(value) == "table"
		and type(value.kind) == "string"
		and type(value.Request) == "function"
end

return StylizationProvider
