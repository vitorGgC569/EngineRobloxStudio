--!strict
--[[
	NpcData — who stands where, and what the salt has to say.

	This file is *content*: the roster, positions as dock offsets, and
	dialogue as data. NpcService is *life* (models, prompts, sessions) and
	DialogueUI is *pixels*. Nothing here touches the engine beyond colour
	literals, which is what lets the harness walk every branch of it.

	`voice(id, ctx)` builds a tree per conversation rather than per boot, so
	a line can read `ctx.coins` and greet a pauper differently from a
	captain with no templating language. Offsets are measured from each
	zone's dock; WorldService resolves them onto dry land, so a writer may
	move an NPC with one number and never think about the heightfield.
]]

local NpcData = {}

-- ================================= palettes =================================
--: Five clothings, worn by eight people. Hue carries the introduction: the
--: harbor's coats are cold, the merchants' warm, the fishers' green. Skin
--: tones differ so a row of NPCs does not read as one print run.
local PALETTES = {
	--: shirt, pants, skin, hat
	harbor = { Color3.fromRGB(58, 96, 118), Color3.fromRGB(52, 54, 62), Color3.fromRGB(198, 152, 112), Color3.fromRGB(38, 46, 54) },
	market = { Color3.fromRGB(154, 78, 62), Color3.fromRGB(74, 60, 48), Color3.fromRGB(224, 178, 134), Color3.fromRGB(62, 44, 38) },
	clerk = { Color3.fromRGB(74, 108, 84), Color3.fromRGB(58, 58, 66), Color3.fromRGB(186, 140, 104), Color3.fromRGB(70, 88, 72) },
	sailor = { Color3.fromRGB(96, 92, 130), Color3.fromRGB(64, 62, 70), Color3.fromRGB(204, 158, 116), Color3.fromRGB(48, 48, 76) },
	fisher = { Color3.fromRGB(96, 122, 92), Color3.fromRGB(70, 62, 52), Color3.fromRGB(210, 166, 122), Color3.fromRGB(52, 66, 56) },
}

--: index 1..4 -> the four garment colours, by name for the builders.
local function paletteIndex(p: { Color3 }): any
	return { shirt = p[1], pants = p[2], skin = p[3], hat = p[4] }
end

-- ================================== roster ==================================
--[[
	Four who live at the harbor and one who watches each outer water. Keys
	are distinct on purpose and stay clear of Q (cancel a cast) and WASD
	(the helm) -- a prompt that squats on a control is an ambush. `facing`
	names a rule, not a direction: "sea" watches the water the zone is
	about, "hub" turns toward the spawn.
]]
NpcData.roster = {
	{
		id = "harbormaster", name = "Harbormaster Brine", title = "Saltwind Harbor",
		zone = "shallows", kind = "hub", offset = Vector2.new(-7, 1), facing = "sea",
		key = "E", label = "Talk", palette = paletteIndex(PALETTES.harbor),
	},
	{
		id = "merchant", name = "Maribel", title = "Keeper of the Market",
		zone = "shallows", kind = "hub", offset = Vector2.new(6, -30), facing = "hub",
		key = "F", label = "Talk shop", palette = paletteIndex(PALETTES.market),
	},
	{
		id = "questclerk", name = "Clerk Ondine", title = "The Quests Board",
		zone = "shallows", kind = "hub", offset = Vector2.new(-4, -41), facing = "hub",
		key = "T", label = "Talk", palette = paletteIndex(PALETTES.clerk),
	},
	{
		id = "sailor", name = "Old Marn", title = "Has Been Everywhere",
		zone = "shallows", kind = "hub", offset = Vector2.new(22, -24), facing = "sea",
		key = "G", label = "Talk", palette = paletteIndex(PALETTES.sailor),
	},
	{
		id = "fisher_kelp", name = "Willa", title = "Kelp Ranger",
		zone = "kelp", kind = "fisher", offset = Vector2.new(8, 6), facing = "sea",
		key = "R", label = "Talk", palette = paletteIndex(PALETTES.fisher),
	},
	{
		id = "fisher_coral", name = "Tavi", title = "Reef Watcher",
		zone = "coral", kind = "fisher", offset = Vector2.new(-8, 6), facing = "sea",
		key = "Z", label = "Talk", palette = paletteIndex(PALETTES.fisher),
	},
	{
		id = "fisher_storm", name = "Gustav", title = "Shelf Weatherman",
		zone = "storm", kind = "fisher", offset = Vector2.new(8, -6), facing = "sea",
		key = "X", label = "Talk", palette = paletteIndex(PALETTES.fisher),
	},
	{
		id = "fisher_abyss", name = "Neri", title = "Trench Keeper",
		zone = "abyss", kind = "fisher", offset = Vector2.new(-8, -6), facing = "sea",
		key = "C", label = "Talk", palette = paletteIndex(PALETTES.fisher),
	},
}

--: The consequences a choice may name. Registered once by NpcService; the
--: harness asserts no tree invents one.
NpcData.actions = { openShop = true, openQuests = true, openMap = true, openRanks = true, openBestiary = true }

-- ================================ helpers ===================================
local function levelOf(ctx: any): number
	return math.floor(tonumber(ctx.level) or 1)
end

local function coinsOf(ctx: any): number
	return math.floor(tonumber(ctx.coins) or 0)
end

local function streakOf(ctx: any): number
	return math.floor(tonumber(ctx.streak) or 0)
end

local function claimableOf(ctx: any): number
	return math.floor(tonumber(ctx.claimable) or 0)
end

--: "Has this player met this NPC before?" rides on the generic flag bag in
--: the save (profile.tutorial.seen, keyed "npc.<id>"), because the profile
--: schema is shared and chatter is not worth widening it for.
local function metBefore(ctx: any, id: string): boolean
	return ctx.met ~= nil and ctx.met["npc." .. id] == true
end

-- ============================ harbor: the four ==============================
local function harbormasterTree(ctx: any): any
	local level = levelOf(ctx)
	local greeting
	if metBefore(ctx, "harbormaster") and level >= 10 then
		greeting = string.format(
			"Level %d and still smellin' of squid. The sea either likes you or is waitin' its moment -- keep the crate handy for either.",
			level)
	elseif metBefore(ctx, "harbormaster") then
		greeting = "Back again. Harbor's the same -- the water never is. That's the whole job, some days."
	else
		greeting = "New keel in my harbor, and I don't say that twice a week. Rules are simple: pier's for castin', stalls are for sellin', and the water's for listenin' to."
	end
	return {
		start = "greet",
		nodes = {
			greet = {
				text = greeting,
				choices = {
					{ text = "What's past the shallows?", goto = "work", once = true },
					{ text = "Any trouble in the water?", goto = "trouble", condition = function(c: any): boolean
						return levelOf(c) >= 5
					end },
					{ text = "Who's catching the big ones?", action = "openRanks" },
					{ text = "Not today, chief.", action = "close" },
				},
			},
			work = {
				text = "Kelp Hollow west-northwest, then the coral steps, then the shelf -- and the trench, which you don't sail to. You arrive.",
				choices = {
					{ text = "And the trench?", goto = "trench", once = true },
					{ text = "I'll chart it myself.", action = "close" },
				},
			},
			trench = {
				text = "The buoy ring stops short of it, and so do I. Everything that keeps me standing on this dock is down in that dark. Fish it quiet, land it fast.",
				choices = {
					{ text = "Fair enough.", action = "close" },
				},
			},
			trouble = {
				text = if streakOf(ctx) >= 3
					then string.format("%d days runnin' and no trouble worth the name. That's not luck, that's a schedule. Keep it.", streakOf(ctx))
					else "Trouble? The tide keeps its own hours and the storms don't RSVP. You fish through it, or you watch.",
				choices = {
					{ text = "Noted.", action = "close" },
				},
			},
		},
	}
end

local function merchantTree(ctx: any): any
	local purse = coinsOf(ctx)
	local greeting
	if purse < 500 then
		greeting = "You walk like a man countin' his coins. Good habit. Here's the honest ledger: bait pays for itself before any rod does."
	elseif purse >= 12000 then
		greeting = "A heavy purse and salt in your hair -- my favorite weather. Come closer, the good stuff is under the counter."
	else
		greeting = "Coins earned on the water always spend best on the water. So what'll it be?"
	end
	return {
		start = "greet",
		nodes = {
			greet = {
				text = greeting,
				choices = {
					{ text = "Show me the wares.", action = "openShop" },
					{ text = "What's wrong with my rod?", goto = "rod", condition = function(c: any): boolean
						return coinsOf(c) >= 800
					end },
					{ text = "They say the market has maps.", goto = "maps", once = true },
					{ text = "Just looking.", action = "close" },
				},
			},
			rod = {
				text = "Nothing a lure can't fix -- until the deep fish start spitting your hook back. Then it's the tidecaller, and yes, I take crates.",
				choices = {
					{ text = "Show me that one.", action = "openShop" },
					{ text = "I'll manage.", action = "close" },
				},
			},
			maps = {
				text = "Maps? Not mine to sell, love. That's the TIDE MAP door -- free to open, coin to travel. Click it like it owes you money.",
				choices = {
					{ text = "Opening it now.", action = "openMap" },
					{ text = "Later.", action = "close" },
				},
			},
		},
	}
end

local function questclerkTree(ctx: any): any
	local active = math.floor(tonumber(ctx.quests) or 0)
	local claimable = claimableOf(ctx)
	local greeting
	if claimable > 0 then
		greeting = string.format(
			"You've %d ripe for the claimin' and the ledger knows it. Don't let coin-cold errands sit -- interest doesn't run here, but the day turns.",
			claimable)
	elseif active > 0 then
		greeting = "Three errands in the ledger and the day's honest yet. The board doesn't judge; it just counts. I'm the same, mostly."
	else
		greeting = "Board's empty, which means you've finished it or the day's about to flip. Either way -- good work, and don't tell the other desks."
	end
	return {
		start = "greet",
		nodes = {
			greet = {
				text = greeting,
				choices = {
					{ text = "Read me the board.", action = "openQuests" },
					{ text = "How do the errands work?", goto = "how", once = true },
					{ text = "The streak ledger still true?", goto = "streak", condition = function(c: any): boolean
						return streakOf(c) >= 2
					end },
					{ text = "Later, clerk.", action = "close" },
				},
			},
			how = {
				text = "Fish, sell, land the odd monster -- the board rolls three kinds fresh at every sunrise. Progress runs itself. The claimin' is the only part that doesn't.",
				choices = {
					{ text = "Got it.", action = "close" },
					{ text = "Open them anyway.", action = "openQuests" },
				},
			},
			streak = {
				text = string.format(
					"%d days, no gap. Keep the login lit and the rewards glimmer brighter each dawn; break it and we both start over, politely.",
					streakOf(ctx)),
				choices = {
					{ text = "Not on my watch.", action = "close" },
				},
			},
		},
	}
end

local function sailorTree(ctx: any): any
	local greeting
	if levelOf(ctx) >= 20 then
		greeting = "Stormbreak eyes. I know 'em -- I wore 'em a while. Sit if you want the truth, stand if you want the stories."
	else
		greeting = "Been fishin' this water since before the buoys learned to blink. Sit down. The fish aren't goin' anywhere -- they never do."
	end
	return {
		start = "greet",
		nodes = {
			greet = {
				text = greeting,
				choices = {
					{ text = "Tell me about the trench.", goto = "trench", once = true },
					{ text = "What's in the dark?", goto = "dark", condition = function(c: any): boolean
						return levelOf(c) >= 25
					end },
					{ text = "Look at my bestiary.", action = "openBestiary" },
					{ text = "Fair winds, old timer.", action = "close" },
				},
			},
			trench = {
				text = "Past the shelf the light stops volunteerin'. Something down there has been patient for longer than the buoys have blinked. That's all I know, and all I want to.",
				choices = {
					{ text = "You're a comfort.", action = "close" },
				},
			},
			dark = {
				text = "Fish with too many eyes. Fish with none. Ones that light up polite and ones that don't bother. You'll meet 'em all with a hook, the same as the minnow.",
				choices = {
					{ text = "Cheery. Thanks.", action = "close" },
				},
			},
		},
	}
end

-- ============================== fishers, one per water ======================
local FISHER_LINES = {
	fisher_kelp = {
		greet = "Kelp's thick today. The fish love it -- so do the eels, so mind your ankles.",
		biting = "Bright fins in the green. Bring shrimp if you want the shy ones to stop whisperin' about you.",
		rumor = "A courier swore he saw a light under the canopy where no lamp hangs. I told him what I'll tell you: probably a fish. Probably.",
		lives = "Everything here learned to hide in the sway. Slow casts, patient hands, and the Hollow pays.",
		rumorLevel = 12,
		close = "Tight lines.",
	},
	fisher_coral = {
		greet = "The steps drop fast past my post. Shallow casts for pretty, deep casts for legends.",
		biting = "Anything wearin' color, mostly. The expensive ones wear the most of it.",
		rumor = "Somebody keeps snappin' hooks on the third terrace. Hooks don't snap. I've been over this with the water and it's not talkin'.",
		lives = "Bright as a market and twice as noisy. The camouflage here isn't leaflets, it's blush.",
		rumorLevel = 16,
		close = "Mind the drop.",
	},
	fisher_storm = {
		greet = "Weather lands here first. Fish the rain, respect the lightning, and you'll do fine anywhere.",
		biting = "The big ones come up when the sky argues. Storm water is honest water -- it tells you it's tryin' to drown you.",
		rumor = "A wave stood up sideways yesterday, held a long breath, and sat back down. I've elected not to write it in the log.",
		lives = "Everything out here has shoulders. Hold on to your rod and your opinions.",
		rumorLevel = 24,
		close = "Keep your deck down.",
	},
	fisher_abyss = {
		greet = "Quiet, isn't it. Down there it's quieter. That's the warning and the invitation both.",
		biting = "Things without names, until someone brave and bored gives them one. That someone is usually haulin' on my old rod.",
		rumor = "The trench took my best lantern once. It gave back the light, later, politely. I still don't know what to do with that.",
		lives = "Past the rim the dark does the decoratin'. You'll know your line by the feel -- no eyes will be doin' the tellin'.",
		rumorLevel = 30,
		close = "Don't fish alone.",
	},
}

local function fisherTree(id: string, ctx: any): any
	local lines = FISHER_LINES[id]
	if not lines then
		return nil
	end
	local level = levelOf(ctx)
	return {
		start = "greet",
		nodes = {
			greet = {
				text = lines.greet,
				choices = {
					{ text = "What's biting?", goto = "biting" },
					{ text = "What lives down here?", goto = "lives", once = true },
					{ text = "Any rumors from the water?", goto = "rumor", once = true, condition = function(_c: any): boolean
						return level >= lines.rumorLevel
					end },
					{ text = lines.close, action = "close" },
				},
			},
			biting = {
				text = lines.biting,
				choices = {
					{ text = "Anything else worth knowing?", goto = "lives" },
					{ text = lines.close, action = "close" },
				},
			},
			lives = {
				text = lines.lives,
				choices = {
					{ text = lines.close, action = "close" },
				},
			},
			rumor = {
				text = lines.rumor,
				choices = {
					{ text = "I'll keep an eye out.", action = "close" },
					{ text = "What else lives here?", goto = "lives" },
				},
			},
		},
	}
end

-- ================================== voice ===================================
local HUB_BUILDERS: { [string]: (any) -> any } = {
	harbormaster = harbormasterTree,
	merchant = merchantTree,
	questclerk = questclerkTree,
	sailor = sailorTree,
}

--: Build one NPC's tree for one conversation. Nil for an unknown id, which
--: the service treats as "nobody home" rather than an error.
function NpcData.voice(id: string, ctx: any): any?
	local hubBuilder = HUB_BUILDERS[id]
	if hubBuilder then
		return hubBuilder(ctx)
	end
	if FISHER_LINES[id] then
		return fisherTree(id, ctx)
	end
	return nil
end

return NpcData
