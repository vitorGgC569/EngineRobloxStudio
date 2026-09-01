--!strict
--[[
	carvewood — server bootstrap.

	The loop, in one place: roll a seed, plant it, wait, swing an axe at it,
	carve the logs by hand, put the pieces on a shelf, and let somebody walk in
	and decide what they are worth.

	What the client is never trusted with
	-------------------------------------

	Prices, growth, yields, grades and balances are all decided server-side from
	state the server owns. A remote carries a plot number, a species id or a
	price inside a clamped band -- never a cost, never an amount, never an
	elapsed time, never a score. The two things a client could usefully lie
	about are how long a tree has been growing and how well it carved, and
	neither is ever asked: readiness is arithmetic against the server's clock,
	and a carving stroke is scored from when the message arrived.

	Persistence
	-----------

	One profile per player, loaded on join and written after every action that
	changes it. `Forge.Save` falls back to memory when DataStore is unavailable,
	which is normal in an unpublished place -- so a session that appears to save
	in Studio is not evidence that saving works.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
Forge.require("0.2.0")

local Wire = require(ReplicatedStorage.Shared.Wire)
local Trees = require(ReplicatedStorage.Shared.Trees)

local systems = ServerScriptService.Server.systems
local Yard = require(systems.Yard)
local Grove = require(systems.Grove)
local Shop = require(systems.Shop)
local Carving = require(systems.Carving)
local Customers = require(systems.Customers)

local Net = Forge.Net
local Save = Forge.Save
local Debug = Forge.Debug
local Rng = Forge.Core.Rng

--: Remotes before any handler. `Net.define` creates the instances; a handler
--: registered first attaches to nothing and the client's call hangs until it
--: times out, which looks exactly like a broken button.
Wire.install()

Save.configure({
	store = "CarveWoodYards",
	template = { yard = false },
	autosaveInterval = 90,
})
Save.start()

--: The ground, before anyone can stand on it. Deliberately not inside
--: `arrive`: a player joins faster than a profile loads.
Grove.foundation()

local states: { [Player]: Yard.State } = {}
local slots: { [Player]: number } = {}
local usedSlots: { [number]: boolean } = {}
local benches: { [Player]: any } = {}
local lastSwing: { [Player]: number } = {}
local autoAccept: { [Player]: number } = {}
local nextArrival: { [Player]: number } = {}

local seedStream = Rng.stream("carvewood.seeds")

--: The swing cooldown, server-side. The remote's rate limit is a ceiling on
--: traffic; this is the one that decides how fast an axe can actually be
--: swung, and it is the only one a macro cannot talk its way past.
local SWING_COOLDOWN = 0.36

-- ================================ publishing ================================
local function publish(player: Player)
	local state = states[player]
	if not state then
		return
	end
	local logs, carved = Yard.counts(state)
	player:SetAttribute("cash", state.cash)
	player:SetAttribute("logs", logs)
	player:SetAttribute("carved", carved)
	player:SetAttribute("essence", state.essence)
	player:SetAttribute("seeds", Yard.seedCount(state))
	player:SetAttribute("slots", state.slots)
	player:SetAttribute("axe", state.axe)
	player:SetAttribute("crew", state.crew)
	player:SetAttribute("chopped", state.chopped)
	player:SetAttribute("stands", Yard.standCount(state.shop))
end

local function persist(player: Player)
	local state = states[player]
	local profile = Save.get(player)
	if not state or type(profile) ~= "table" then
		return
	end
	state.lastSeen = os.time()
	profile.yard = state
	pcall(function()
		Save.write(player)
	end)
end

local function tell(player: Player, kind: string, text: string)
	Net.fire(player, "notice", { kind = kind, text = text })
end

--[[
	One place where an action lands.

	Every remote does the same four things -- run the rule, redraw the world,
	republish the numbers, say what happened -- and doing them here is what
	stops the next action anybody adds from forgetting the third.
]]
local function apply(player: Player, ok: boolean, detail: any,
                     success: string?): any
	if not ok then
		tell(player, "refused", tostring(detail))
		return { ok = false, reason = tostring(detail) }
	end
	local state = states[player]
	if state then
		Grove.refresh(player, state)
		--: A shop whose *shape* changed needs raising, not refreshing.
		--: `refresh` says which by returning false, rather than silently
		--: drawing shelves onto a floor that does not exist yet.
		if Shop.of(player) and Shop.refresh(player, state) == false then
			local yard = Grove.of(player)
			if yard then
				Shop.raise(player, Grove.shopAnchor(yard.anchor), state,
					yard.folder)
			end
		end
		publish(player)
		persist(player)
	end
	if success then
		tell(player, "good", success)
	end
	return { ok = true, detail = detail }
end

local function stateOf(player: Player): Yard.State?
	return states[player]
end

-- ================================= actions ==================================
Net.on("yard", function(player: Player)
	local state = states[player]
	return if state then Yard.snapshot(state) else nil
end)

Net.on("plant", function(player: Player, payload: any)
	local state = stateOf(player)
	if not state then
		return { ok = false, reason = "your yard is still loading" }
	end
	local species = tostring((payload or {}).species)
	local ok, detail = Yard.plant(state, tonumber((payload or {}).plot) or 0, species)
	local kind = Trees.get(species)
	return apply(player, ok, detail,
		if ok and kind then "Planted a " .. kind.name else nil)
end)

--[[
	A swing.

	Refusals are silent on purpose. A player holding the button down against a
	growing tree would otherwise raise a toast every third of a second, and
	"still growing" is already written on the prompt in front of them.
]]
Net.on("strike", function(player: Player, payload: any)
	local state = stateOf(player)
	if not state then
		return { ok = false, reason = "your yard is still loading" }
	end
	local now = os.clock()
	if now - (lastSwing[player] or 0) < SWING_COOLDOWN then
		return { ok = false, reason = "too fast" }
	end
	lastSwing[player] = now

	local plot = tonumber((payload or {}).plot) or 0
	local ok, detail = Yard.strike(state, plot)
	if not ok then
		return { ok = false, reason = tostring(detail) }
	end
	Net.fire(player, "struck", {
		plot = plot, hp = detail.hp, max = detail.max,
		felled = detail.felled, species = detail.species,
	})
	if detail.felled then
		return apply(player, true, detail,
			string.format("+%d logs", detail.logs))
	end
	--: Not felled: redraw so the bite shows, but do not persist. A DataStore
	--: write per axe swing is a DataStore ban.
	Grove.refresh(player, state)
	return { ok = true, detail = detail }
end)

-- ================================== bench ===================================
local function sendBench(player: Player, session: any, extra: { [string]: any }?)
	local payload = Carving.describe(session)
	for key, value in extra or {} do
		payload[key] = value
	end
	Net.fire(player, "carveState", payload)
end

--[[
	The carving bench.

	A session belongs to the player, not to a plot, so walking away mid-carve
	leaves it to time out rather than leaving a log in limbo.
]]
Net.on("carveBegin", function(player: Player, payload: any)
	local state = stateOf(player)
	if not state then
		return { ok = false, reason = "your yard is still loading" }
	end
	local open = benches[player]
	if open and not open.done then
		return { ok = false, reason = "finish the piece you are on" }
	end
	local wanted = tostring((payload or {}).species)
	local id = if Trees.get(wanted) then wanted else Yard.bestLog(state)
	if not id or (state.logs[id] or 0) <= 0 then
		return apply(player, false, "no logs to carve")
	end
	--: The chisel is the axe for now: one tool track, because a second one
	--: would be a shop tab nobody asked for. Split it the day it earns its own.
	local session = Carving.begin(id, state.axe, function()
		return seedStream:number(0, 1)
	end)
	benches[player] = session
	sendBench(player, session, { began = true })
	return { ok = true, detail = Carving.describe(session) }
end)

Net.on("carveStrike", function(player: Player)
	local state = stateOf(player)
	local session = benches[player]
	if not state or not session or session.done then
		return { ok = false, reason = "no piece on the bench" }
	end
	local score, perfect, done = Carving.strike(session)
	if not done then
		sendBench(player, session, { score = score, perfect = perfect })
		return { ok = true, detail = { score = score, perfect = perfect } }
	end

	local grade = Carving.grade(session)
	benches[player] = nil
	local ok, detail = Yard.carveInto(state, session.species, grade)
	sendBench(player, session, {
		score = score, perfect = perfect, finished = true, grade = grade,
	})
	if not ok then
		return apply(player, false, detail)
	end
	local species = Trees.get(session.species)
	return apply(player, true, detail, string.format("%s %s -- worth %d",
		Yard.QUALITY[grade].name,
		if species then species.name else session.species, detail.value))
end)

-- ================================== seeds ===================================
Net.on("rollSeed", function(player: Player)
	local state = stateOf(player)
	if not state then
		return { ok = false, reason = "your yard is still loading" }
	end
	local ok, detail = Yard.rollSeed(state, function()
		return seedStream:number(0, 1)
	end)
	return apply(player, ok, detail,
		if ok then string.format("%s seed -- %s", detail.name, detail.rarity)
		else nil)
end)

Net.on("convert", function(player: Player, payload: any)
	local state = stateOf(player)
	if not state then
		return { ok = false, reason = "your yard is still loading" }
	end
	local ok, detail = Yard.convert(state, tostring((payload or {}).species))
	local species = if ok then Trees.get(detail.species) else nil
	return apply(player, ok, detail,
		if ok and species then "Traded essence for a " .. species.name else nil)
end)

-- ============================== the shop floor ==============================
Net.on("stock", function(player: Player, payload: any)
	local state = stateOf(player)
	if not state then
		return { ok = false, reason = "your yard is still loading" }
	end
	local p = payload or {}
	local ok, detail = Yard.stock(state, tonumber(p.stand) or 0,
		tonumber(p.carving) or 0, tonumber(p.price) or 0)
	return apply(player, ok, detail,
		if ok then string.format("On display at %d", detail.price) else nil)
end)

Net.on("unstock", function(player: Player, payload: any)
	local state = stateOf(player)
	if not state then
		return { ok = false, reason = "your yard is still loading" }
	end
	local ok, detail = Yard.unstock(state, tonumber((payload or {}).stand) or 0)
	return apply(player, ok, detail, if ok then "Taken off display" else nil)
end)

Net.on("setPrice", function(player: Player, payload: any)
	local state = stateOf(player)
	if not state then
		return { ok = false, reason = "your yard is still loading" }
	end
	local p = payload or {}
	local ok, detail = Yard.setPrice(state, tonumber(p.stand) or 0,
		tonumber(p.price) or 0)
	return apply(player, ok, detail, nil)
end)

Net.on("buyUpgrade", function(player: Player, payload: any)
	local state = stateOf(player)
	if not state then
		return { ok = false, reason = "your yard is still loading" }
	end
	local node = tostring((payload or {}).node)
	local ok, detail = Yard.buyUpgrade(state, node)
	local said = ({
		counter = "Another shelf on every floor",
		floors = "A new floor",
		signage = "A bigger sign -- more customers will come",
		decor = "The place looks better",
	})[node]
	return apply(player, ok, detail, if ok then said else nil)
end)

--: A standing answer to haggles, so a player who is out chopping is not losing
--: sales they never saw. Zero is off.
Net.on("autoAccept", function(player: Player, payload: any)
	local percent = math.clamp(tonumber((payload or {}).percent) or 0, 0, 100)
	autoAccept[player] = percent
	return { ok = true, detail = { percent = percent } }
end)

Net.on("haggle", function(player: Player, payload: any)
	local p = payload or {}
	local reached = Customers.answer(player, tonumber(p.id) or 0, p.accept == true)
	if not reached then
		tell(player, "refused", "they had already left")
	end
	return { ok = reached }
end)

Net.on("sell", function(player: Player)
	local state = stateOf(player)
	if not state then
		return { ok = false, reason = "your yard is still loading" }
	end
	local ok, detail = Yard.sell(state)
	return apply(player, ok, detail,
		if ok then string.format("Sold %d at the counter for %d",
			detail.pieces, detail.earned) else nil)
end)

local purchases: { [string]: { rule: (Yard.State) -> (boolean, any), said: string } } = {
	buyPlot = { rule = Yard.buyPlot, said = "Cleared another plot" },
	buyAxe = { rule = Yard.buyAxe, said = "Sharpened your axe" },
	hire = { rule = Yard.hire, said = "Hired a carver" },
}
for name, entry in purchases do
	Net.on(name, function(player: Player)
		local state = stateOf(player)
		if not state then
			return { ok = false, reason = "your yard is still loading" }
		end
		local ok, detail = entry.rule(state)
		return apply(player, ok, detail, if ok then entry.said else nil)
	end)
end

-- ================================= customers ================================
Customers.onOffer = function(player: Player, offer: any)
	--: The standing answer, if there is one. Checked here rather than inside
	--: the customer, so turning it on takes effect on the offer already open.
	local threshold = autoAccept[player] or 0
	if threshold > 0 and offer.asking > 0
			and offer.offer >= offer.asking * threshold / 100 then
		Customers.answer(player, offer.id, true)
		return
	end
	Net.fire(player, "customerOffer", offer)
end

Customers.onSale = function(player: Player, detail: any)
	local state = states[player]
	if state then
		Shop.refresh(player, state)
		publish(player)
		persist(player)
	end
	Net.fire(player, "saleMade", detail)
	tell(player, "good", string.format("Sold a %s for %d",
		Yard.QUALITY[detail.quality].name, detail.paid))
end

-- =================================== ticks ==================================
--[[
	The crew, the prompts, and any bench somebody walked away from.

	Once a second rather than every frame: the work is whole pieces and a
	sixtieth of a piece is not a thing. Keeping it off the render path also
	matters when six yards are ticking at once.
]]
task.spawn(function()
	while true do
		task.wait(1)
		for player, state in states do
			local carved = Yard.crewTick(state, 1)
			Grove.refresh(player, state)
			if carved > 0 then
				Shop.refresh(player, state)
				publish(player)
			end
			local session = benches[player]
			if session and not session.done and Carving.timeout(session) then
				local grade = Carving.grade(session)
				benches[player] = nil
				local ok, detail = Yard.carveInto(state, session.species, grade)
				if ok then
					sendBench(player, session, { finished = true, grade = grade })
					apply(player, true, detail, nil)
				end
			end
		end
	end
end)

--: Arrivals. Each shop keeps its own timer, because footfall is a property of
--: that shop's signage and shelves and not of the server.
task.spawn(function()
	while true do
		task.wait(1)
		local now = os.clock()
		for player, state in states do
			local due = nextArrival[player]
			if not due then
				nextArrival[player] = now + Customers.interval(state)
			elseif now >= due then
				Customers.spawn(player, state)
				nextArrival[player] = now + Customers.interval(state)
			end
		end
	end
end)

--: The crowd moves every frame; everything it decides happens on its own
--: budget inside `tick`.
RunService.Heartbeat:Connect(function(dt)
	Customers.tick(math.min(dt, 0.2))
end)

-- ================================== players =================================
local function claimSlot(): number
	for index = 1, 6 do
		if not usedSlots[index] then
			usedSlots[index] = true
			return index
		end
	end
	return 1
end

local function arrive(player: Player)
	--: The profile may not have landed yet; the yard cannot be built from a
	--: guess, because a guess that turns out wrong is a player whose progress
	--: was silently reset.
	local profile = Save.await(player, 12)
	local state = Yard.reconcile(if type(profile) == "table" then profile.yard else nil)
	states[player] = state
	if type(profile) == "table" then
		profile.yard = state
	end

	local slot = claimSlot()
	slots[player] = slot
	local yard = Grove.claim(player, slot, state)
	if yard then
		Shop.raise(player, Grove.shopAnchor(yard.anchor), state, yard.folder)
	end
	Grove.refresh(player, state)
	publish(player)

	--[[
		What grew while they were away, said out loud.

		The original promises on its store page that the yard grows offline and
		then never mentions it again in play. Saying it on arrival is the
		difference between a mechanic a player has and one they know they have,
		and it costs a sentence.
	]]
	local waiting = 0
	for index = 1, state.slots do
		if Yard.ready(state.plots[index]) then
			waiting += 1
		end
	end
	if waiting > 0 then
		tell(player, "good", string.format(
			"%d tree%s finished growing while you were away",
			waiting, if waiting == 1 then "" else "s"))
	end
end

for _, player in Players:GetPlayers() do
	task.spawn(arrive, player)
end
Players.PlayerAdded:Connect(function(player)
	task.spawn(arrive, player)
end)
Players.PlayerRemoving:Connect(function(player)
	--: Written before anything is released. A purchase made in the last
	--: seconds of a session is the one a player remembers losing.
	persist(player)
	Customers.clearFor(player)
	Shop.clear(player)
	Grove.release(player)
	if slots[player] then
		usedSlots[slots[player]] = nil
	end
	states[player], slots[player] = nil, nil
	benches[player], lastSwing[player] = nil, nil
	autoAccept[player], nextArrival[player] = nil, nil
end)

Debug.probe("carvewood", function()
	local live, cash, chopped, displayed = 0, 0, 0, 0
	local seeds: { [string]: number } = {}
	for _, state in states do
		live += 1
		cash += state.cash
		chopped += state.chopped
		for _ in state.shop.stands do
			displayed += 1
		end
		for id, count in state.seeds do
			seeds[id] = (seeds[id] or 0) + count
		end
	end
	return {
		players = live, totalCash = cash, totalChopped = chopped,
		onDisplay = displayed, seeds = seeds, species = #Trees.species,
		grove = Grove.describe(), shops = Shop.describe(),
		customers = Customers.describe(), economy = Trees.describe(),
	}
end)

Debug.expose()

return nil
