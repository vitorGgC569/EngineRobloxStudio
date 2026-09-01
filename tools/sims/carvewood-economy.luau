
local Trees = Require("Trees")
local Yard = Require("Yard")
local Carving = Require("Carving")
local t = 0
Yard.clock = function() return t end
Carving.clock = function() return t end
local function say(...) print(table.concat({...}, " ")) end
local seed = 12345
local function rng()
	seed = (seed * 1103515245 + 12345) % 2147483648
	return seed / 2147483648
end

local s = Yard.blank(); s.cash = 1000000
local seen = {}
for _ = 1, 600 do
	local ok, d = Yard.rollSeed(s, rng)
	if ok then seen[d.rarity] = (seen[d.rarity] or 0) + 1 end
end
local parts = {}
for _, r in { "Common","Uncommon","Rare","Epic","Legendary","Mythic","Celestial" } do
	table.insert(parts, r .. " " .. (seen[r] or 0))
end
say("600 packs ->", table.concat(parts, " | "))

local rows = {}
for _, id in { "pine", "oak", "amberheart", "starheart" } do
	table.insert(rows, id .. " " .. Yard.hitsToFell(id, 1) .. "->" .. Yard.hitsToFell(id, 8))
end
say("hits axe1->axe8:", table.concat(rows, "  "))

local widths = {}
for _, id in { "pine", "oak", "starheart" } do
	table.insert(widths, id .. " " .. string.format("%.2f", Carving.zoneWidth(id, 1))
		.. "->" .. string.format("%.2f", Carving.zoneWidth(id, 5)))
end
say("carve zone chisel1->5:", table.concat(widths, "  "))

local function carveWith(acc)
	local sess = Carving.begin("oak", 1, rng, t)
	for _ = 1, Carving.STROKES do
		local target = sess.centre + sess.halfWidth * (1 - acc)
		t = t + target * Carving.SWEEP / 2
		Carving.strike(sess, t)
	end
	return Carving.grade(sess)
end
say("grade 100%:", carveWith(1.0), "| 80%:", carveWith(0.8),
	"| 50%:", carveWith(0.5), "| 0%:", carveWith(0.0))

local function play(minutes, axe, crew, quality)
	local st = Yard.blank(); st.axe, st.crew = axe, crew
	st.seeds = { pine = 9999 }; t = 0
	local swings = 0
	for second = 1, minutes * 60 do
		t = second
		for i = 1, st.slots do
			local p = st.plots[i]
			if p and not p.species then Yard.plant(st, i, "pine") end
		end
		for i = 1, st.slots do
			local p = st.plots[i]
			if p and p.species and Yard.ready(p) then
				Yard.strike(st, i, t); swings += 1; break
			end
		end
		Yard.carveInto(st, nil, quality)
		Yard.crewTick(st, 1)
	end
	Yard.sell(st)
	return st.cash, st.chopped, swings
end
local cash, chopped, swings = play(40, 1, 0, "fine")
say(string.format("40min axe1 crew0 Fine   -> cash %d  logs %d  swings %d", cash, chopped, swings))
say(string.format("40min axe4 crew2 Master -> cash %d", (play(40, 4, 2, "master"))))

local st = Yard.blank()
st.logs.oak = 3
Yard.carveInto(st, "oak", "fine")
local fair = Yard.fairPrice("oak", "fine")
local before = st.cash
Yard.sell(st)
say(string.format("one Fine Oak: fair %d, counter pays %d", fair, st.cash - before))

local stand = { species = "oak", quality = "fine", price = fair }
for _, c in {
	{ l = "taste match, generous", budget = 9999, taste = 2, generosity = 1.3, patience = 20 },
	{ l = "taste match, tight   ", budget = 9999, taste = 2, generosity = 0.85, patience = 20 },
	{ l = "wanted a Legendary   ", budget = 9999, taste = 5, generosity = 1.0, patience = 20 },
	{ l = "broke                ", budget = 10, taste = 2, generosity = 1.2, patience = 20 },
} do
	local v, amount = Yard.decide(c, stand, st.shop)
	say(string.format("  %s @fair -> %s %d", c.l, v, amount))
end
local rich = { budget = 9999, taste = 2, generosity = 1.3, patience = 20 }
local line = {}
for _, m in { 0.8, 1.0, 1.3, 1.6, 2.0 } do
	local v = Yard.decide(rich, { species = "oak", quality = "fine",
		price = math.floor(fair * m) }, st.shop)
	table.insert(line, string.format("%.1fx=%s", m, v))
end
say("  generous customer:", table.concat(line, " "))

local shop = { upgrades = {}, stands = {}, takings = 0 }
say("shop at start:", Yard.standCount(shop), "stands,", Yard.floors(shop), "floor")
shop.upgrades.counter = 4; shop.upgrades.floors = 4
say("shop fully built:", Yard.standCount(shop), "stands,", Yard.floors(shop), "floors")
