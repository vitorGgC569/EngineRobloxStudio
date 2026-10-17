--!strict
-- Dreadhollow token set: dead-of-night sanatorium.
--
-- Near-achromatic stone and wood so the only colours that can command the
-- frame are lantern amber, mosslight cold, and the Hollow's danger accent. Read by
-- `WorldKit.Tokens.define` (validated, frozen) and by nothing else.

return {
	schemaVersion = 1,
	tokenSetId = "dreadhollow-night",
	revision = 5,
	description = "Art direction for Dreadhollow: moon-cold stone, dead wood, lantern amber. Large surfaces stay nearly achromatic; warm light and danger red are the only accents. r3: slate Granite->Slate, roofs read flat at scale. r4: R7 envelope recusado em nível (nota, nunca slider) — Outdoor/FogEnd/BellRange tetos em moods.deadnight.lighting. r5: R8 mosslight p/ baterias (frias, nunca âmbar) — torre segue único âmbar; servidor ainda lê lanternGlow p/ Battery (ver SINAIS).",
	palette = {
		roles = {
			ground = {
				srgb = { 26, 28, 34 },
				material = "Slate",
				tier = "dominant",
				usage = "Courtyard earth and floors, rough under Future lighting. The base note of the whole world.",
				minSurfaceCoverage = 0.2,
				maxSurfaceCoverage = 0.6,
			},
			stone = {
				srgb = { 52, 54, 63 },
				material = "Concrete",
				tier = "dominant",
				usage = "Sanatorium walls. Cold masonry that swallows light.",
				minSurfaceCoverage = 0.15,
				maxSurfaceCoverage = 0.5,
			},
			wood = {
				srgb = { 50, 42, 34 },
				material = "WoodPlanks",
				tier = "supporting",
				usage = "Doors, chapel pews, gate. Dead timber.",
			},
			slate = {
				srgb = { 30, 32, 40 },
				material = "Slate",
				tier = "supporting",
				usage = "Trim, roof slabs, the Hollow's mantle.",
			},
			bone = {
				srgb = { 168, 160, 140 },
				material = "Limestone",
				tier = "supporting",
				usage = "Chapel altar and candles. The only pale surface; marks safety.",
				maxSurfaceCoverage = 0.05,
			},
			paper = {
				srgb = { 205, 195, 170 },
				material = "SmoothPlastic",
				tier = "accent",
				usage = "Collectible pages. Must read at lantern range.",
				maxSurfaceCoverage = 0.02,
			},
			lanternGlow = {
				srgb = { 255, 190, 120 },
				material = "Neon",
				tier = "accent",
				usage = "Tower halo and chapel candles; tower is the only amber beacon — batteries are mosslight, cold, never amber.",
				maxSurfaceCoverage = 0.03,
			},
			mosslight = {
				srgb = { 170, 200, 160 },
				material = "Neon",
				tier = "accent",
				usage = "Batteries; cold, never amber. The tower halo stays the only amber.",
				maxSurfaceCoverage = 0.02,
			},
			ink = {
				srgb = { 12, 12, 16 },
				material = "SmoothPlastic",
				tier = "supporting",
				usage = "The Hollow's body. Darker than the night around it.",
			},
			neutralLight = {
				srgb = { 190, 195, 205 },
				material = "SmoothPlastic",
				tier = "supporting",
				usage = "The Hollow's face plate. Catches the lantern beam.",
			},
			accentDanger = {
				srgb = { 150, 18, 22 },
				material = "Neon",
				tier = "accent",
				usage = "The Hollow's eyes and the locked gate seal. The only red allowed on frame.",
				maxSurfaceCoverage = 0.02,
			},
		},
	},
	scale = {
		character = {
			height = 5.0,
			width = 2.0,
			walkSpeed = 16,
			jumpHeight = 7.2,
			maxStepUp = 2.0,
			comfortableSlopeDegrees = 45,
		},
		grammar = {
			doorWidth = 8,
			doorHeight = 11,
			corridorWidth = 12,
			ceilingHeight = 15,
			stairRise = 1.4,
			stairRun = 2.6,
			railHeight = 3.5,
			roomMinDimension = 20,
			buildingMinFootprint = 24,
			buildingMinHeight = 18,
			landmarkMinHeight = 34,
			plotMinDimension = 150,
			avenueWidth = 58,
		},
		legibility = {
			labelReadDistance = 26,
			signageReadDistance = 120,
			landmarkReadDistance = 900,
			silhouetteReadDistance = 320,
		},
	},
	spacing = {
		steps = {
			tight = 4,
			cozy = 8,
			roomy = 16,
		},
	},
	typography = {
		steps = {
			body = 14,
			title = 28,
		},
		weights = {
			regular = "Regular",
			bold = "Bold",
		},
	},
	motion = {
		durations = {
			instant = 0.1,
			beat = 0.4,
		},
		easings = {
			standard = { style = "Quad", direction = "Out" },
		},
	},
	moods = {
		-- R7 (crítico) validado contra o cânone — RECUSADO em nível, aceito
		-- só em matiz. Nota, nunca slider cego (dono do runtime: @systems):
		-- 1. Outdoor 75,85,115: matiz frio é canônico (moon-cold stone), mas
		-- o nível lava o void (lição R4) e levanta o ink (12,12,16), que deve
		-- seguir "darker than the night". Teto: outdoorAmbientCap 55,62,82.
		-- 2. FogEnd 700: silhouette 320 já lê no envelope 60/400; 900 é teto
		-- de teste do contrato (bell-tower maximumDistance), não alvo
		-- runtime — 700 expõe a arena inteira (220) e mata o esconderijo do
		-- pátio. Envelope canônico: fogStart 60, fogEnd 400.
		-- 3. BellRange 160: vira holofote âmbar sobre a página do pátio
		-- (12,2,-20, ~12 studs do sino) e compete com a lanterna (único
		-- quente = vida; capela = único quarto seguro). Teto: 80 (atual).
		deadnight = {
			lighting = {
				clockTime = 0,
				outdoorAmbientCap = { 55, 62, 82 },
				fogStart = 60,
				fogEnd = 400,
				bellRangeMax = 80,
			},
			atmosphere = { color = { 10, 12, 20 } },
		},
	},
	cameras = {
		chase = { fov = 70 },
	},
	audio = {
		buses = {
			master = {},
		},
		spatial = {},
	},
}
