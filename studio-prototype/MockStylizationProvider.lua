--!strict

local MockStylizationProvider = {}
MockStylizationProvider.__index = MockStylizationProvider

type Rect = {
	x: number,
	y: number,
	width: number,
	height: number,
	colorIndex: number,
	alpha: number?,
}

export type Provider = typeof(setmetatable({} :: {
	kind: "Mock",
	delaySeconds: number,
	requests: number,
}, MockStylizationProvider))

local function rect(x: number, y: number, width: number, height: number, colorIndex: number): Rect
	return { x = x, y = y, width = width, height = height, colorIndex = colorIndex }
end

local function layer(
	name: string,
	zIndex: number,
	pivot: Vector2,
	anchor: Vector2,
	rects: { Rect }
)
	return {
		name = name,
		zIndex = zIndex,
		pivot = pivot,
		anchor = anchor,
		rects = rects,
	}
end

local function transforms(values: { [string]: any }): { [string]: any }
	return values
end

function MockStylizationProvider.BuildPackage(fingerprint: string)
	local layers = {
		layer("BackHair", 10, Vector2.new(32, 31), Vector2.new(32, 31), {
			rect(17, 10, 30, 2, 1), rect(13, 12, 38, 5, 1), rect(10, 17, 44, 18, 1),
			rect(8, 25, 48, 18, 1), rect(10, 43, 44, 8, 1),
			rect(18, 12, 28, 3, 2), rect(14, 15, 36, 9, 2), rect(12, 24, 40, 19, 2),
			rect(14, 43, 36, 5, 3),
		}),
		layer("LeftLeg", 20, Vector2.new(25, 70), Vector2.new(25, 70), {
			rect(21, 67, 9, 21, 1), rect(23, 67, 7, 15, 5), rect(21, 82, 10, 7, 10),
			rect(19, 88, 13, 4, 1),
		}),
		layer("RightLeg", 21, Vector2.new(39, 70), Vector2.new(39, 70), {
			rect(34, 67, 9, 21, 1), rect(34, 67, 7, 15, 5), rect(33, 82, 10, 7, 10),
			rect(33, 88, 13, 4, 1),
		}),
		layer("LeftArm", 25, Vector2.new(21, 50), Vector2.new(21, 50), {
			rect(12, 48, 9, 4, 1), rect(11, 51, 10, 5, 7), rect(10, 56, 10, 5, 8),
			rect(9, 61, 10, 5, 9), rect(10, 66, 9, 5, 6), rect(11, 71, 7, 4, 5),
		}),
		layer("RightArm", 26, Vector2.new(43, 50), Vector2.new(43, 50), {
			rect(43, 48, 9, 4, 1), rect(43, 51, 10, 5, 7), rect(44, 56, 10, 5, 8),
			rect(45, 61, 10, 5, 9), rect(45, 66, 9, 5, 6), rect(46, 71, 7, 4, 5),
		}),
		layer("Face", 30, Vector2.new(32, 31), Vector2.new(32, 31), {
			rect(16, 20, 32, 20, 4), rect(19, 16, 26, 28, 4), rect(13, 25, 38, 10, 4),
			rect(19, 27, 7, 7, 11), rect(38, 27, 7, 7, 11),
			rect(21, 28, 3, 4, 12), rect(40, 28, 3, 4, 12),
			rect(27, 38, 10, 1, 13), rect(25, 35, 3, 2, 14), rect(37, 35, 3, 2, 14),
		}),
		layer("Torso", 35, Vector2.new(32, 50), Vector2.new(32, 50), {
			rect(20, 47, 24, 19, 1), rect(22, 48, 20, 16, 10),
			rect(29, 50, 6, 3, 6), rect(31, 48, 2, 8, 6), rect(27, 52, 10, 2, 6),
			rect(23, 64, 18, 4, 4),
		}),
		layer("Skirt", 40, Vector2.new(32, 66), Vector2.new(32, 66), {
			rect(17, 65, 30, 3, 1), rect(15, 68, 34, 5, 3), rect(13, 73, 38, 5, 1),
			rect(16, 68, 7, 8, 8), rect(27, 68, 7, 8, 9), rect(39, 68, 7, 8, 8),
			rect(18, 76, 28, 3, 3),
		}),
		layer("FrontHair", 50, Vector2.new(32, 18), Vector2.new(32, 18), {
			rect(16, 12, 32, 8, 2), rect(13, 18, 38, 6, 2),
			rect(14, 22, 10, 14, 2), rect(24, 20, 7, 12, 3), rect(31, 20, 8, 16, 2),
			rect(39, 21, 11, 13, 3), rect(18, 14, 16, 3, 15),
		}),
		layer("Accessories", 60, Vector2.new(32, 16), Vector2.new(32, 16), {
			rect(12, 7, 3, 9, 1), rect(15, 5, 6, 10, 1), rect(17, 7, 3, 6, 9),
			rect(49, 7, 3, 9, 1), rect(43, 5, 6, 10, 1), rect(44, 7, 3, 6, 9),
			rect(9, 24, 5, 12, 1), rect(10, 25, 3, 10, 9),
			rect(50, 24, 5, 12, 1), rect(51, 25, 3, 10, 9),
		}),
	}
	local idleTransforms = transforms({
		LeftArm = { rotation = -2 },
		RightArm = { rotation = 2 },
		FrontHair = { position = Vector2.new(0, -1) },
		Accessories = { position = Vector2.new(0, -1) },
	})
	local idleTransformsB = transforms({
		LeftArm = { rotation = 3 },
		RightArm = { rotation = -3 },
		FrontHair = { position = Vector2.new(0, 0) },
		Accessories = { position = Vector2.new(0, 0) },
	})
	return {
		schemaVersion = 1,
		id = "mock-chibi-v1-" .. fingerprint,
		fingerprint = fingerprint,
		canvasSize = Vector2.new(64, 96),
		palette = {
			Color3.fromRGB(25, 26, 36),
			Color3.fromRGB(115, 207, 86),
			Color3.fromRGB(119, 65, 171),
			Color3.fromRGB(246, 200, 175),
			Color3.fromRGB(239, 185, 164),
			Color3.fromRGB(255, 215, 63),
			Color3.fromRGB(56, 188, 225),
			Color3.fromRGB(94, 211, 86),
			Color3.fromRGB(194, 75, 217),
			Color3.fromRGB(20, 21, 28),
			Color3.fromRGB(77, 58, 116),
			Color3.fromRGB(244, 239, 255),
			Color3.fromRGB(157, 73, 91),
			Color3.fromRGB(235, 133, 145),
			Color3.fromRGB(176, 239, 133),
		},
		layers = layers,
		anchors = {
			Root = Vector2.new(32, 92),
			Head = Vector2.new(32, 31),
			LeftHand = Vector2.new(14, 73),
			RightHand = Vector2.new(50, 73),
			LeftFoot = Vector2.new(25, 91),
			RightFoot = Vector2.new(39, 91),
		},
		rig = {
			{ name = "Root", layer = "Torso", parent = nil, pivot = Vector2.new(32, 66) },
			{ name = "Head", layer = "Face", parent = "Root", pivot = Vector2.new(32, 43) },
			{ name = "LeftShoulder", layer = "LeftArm", parent = "Root", pivot = Vector2.new(21, 50) },
			{ name = "RightShoulder", layer = "RightArm", parent = "Root", pivot = Vector2.new(43, 50) },
			{ name = "LeftHip", layer = "LeftLeg", parent = "Root", pivot = Vector2.new(25, 70) },
			{ name = "RightHip", layer = "RightLeg", parent = "Root", pivot = Vector2.new(39, 70) },
		},
		clips = {
			Idle = {
				name = "Idle", duration = 1.2, looped = true,
				keyframes = {
					{ time = 0, rootOffset = Vector2.new(0, 0), transforms = idleTransforms },
					{ time = 0.6, rootOffset = Vector2.new(0, -1), transforms = idleTransformsB },
					{ time = 1.2, rootOffset = Vector2.new(0, 0), transforms = idleTransforms },
				},
			},
			Walk = {
				name = "Walk", duration = 0.6, looped = true,
				keyframes = {
					{ time = 0, rootOffset = Vector2.new(0, 0), transforms = {
						LeftArm = { rotation = 12 }, RightArm = { rotation = -12 },
						LeftLeg = { rotation = -8 }, RightLeg = { rotation = 8 },
					} },
					{ time = 0.3, rootOffset = Vector2.new(0, -1), transforms = {
						LeftArm = { rotation = -12 }, RightArm = { rotation = 12 },
						LeftLeg = { rotation = 8 }, RightLeg = { rotation = -8 },
					} },
					{ time = 0.6, rootOffset = Vector2.new(0, 0), transforms = {
						LeftArm = { rotation = 12 }, RightArm = { rotation = -12 },
						LeftLeg = { rotation = -8 }, RightLeg = { rotation = 8 },
					} },
				},
			},
			Jump = {
				name = "Jump", duration = 0.8, looped = false,
				keyframes = {
					{ time = 0, rootOffset = Vector2.new(0, 0), transforms = {
						LeftArm = { rotation = 5 }, RightArm = { rotation = -5 },
					} },
					{ time = 0.4, rootOffset = Vector2.new(0, -5), transforms = {
						LeftArm = { rotation = -18 }, RightArm = { rotation = 18 },
						LeftLeg = { rotation = 5 }, RightLeg = { rotation = -5 },
					} },
					{ time = 0.8, rootOffset = Vector2.new(0, 0), transforms = {
						LeftArm = { rotation = 5 }, RightArm = { rotation = -5 },
					} },
				},
			},
		},
	}
end

function MockStylizationProvider.new(delaySeconds: number?): Provider
	return setmetatable({
		kind = "Mock",
		delaySeconds = math.max(0, delaySeconds or 0.8),
		requests = 0,
	}, MockStylizationProvider)
end

function MockStylizationProvider.Request(self: Provider, request: any)
	self.requests += 1
	if self.delaySeconds > 0 then
		task.wait(self.delaySeconds)
	end
	return MockStylizationProvider.BuildPackage(request.fingerprint)
end

return MockStylizationProvider
