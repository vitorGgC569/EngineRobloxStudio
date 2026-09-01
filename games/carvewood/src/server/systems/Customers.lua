--!strict
--[[
	Customers — the people who walk in, look, and decide.

	The counter used to pay list price and ask no questions. This replaces that
	with somebody who has a budget, a taste and a limit, walks to a shop,
	looks at what is actually on the shelves, and buys, haggles or leaves.

	Walking away is the feedback loop. A shop that sells nothing is telling its
	owner the price is wrong, and nothing in the old counter could say that.

	Wiring, not invention
	---------------------

	  * `AI/Navigator` follows waypoints and reports the direction to move.
	  * `AI/BehaviorTree` is the branch structure -- approach, browse, transact,
	    leave -- with `meander` as the fallback when nothing appeals.
	  * `AI/CrowdSeparation` keeps six of them from standing inside each other.
	  * `Yard.decide` is the rule, and it is pure, so what a customer will pay
	    was tuned in a simulation with no NPC in it.

	Bodies are parts, not Humanoids
	-------------------------------

	Six yards times several customers is thirty characters. Humanoids at that
	count cost more than the whole rest of this game, and none of it buys
	anything: a customer walks in a straight line to a shelf and stands there.
	So they are anchored models moved by CFrame, with a bob so they read as
	walking rather than sliding.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Trees = require(ReplicatedStorage.Shared.Trees)
local Yard = require(script.Parent.Yard)
local Shop = require(script.Parent.Shop)

local Navigator = Forge.AI.Navigator
local BehaviorTree = Forge.AI.BehaviorTree
local CrowdSeparation = Forge.AI.CrowdSeparation
local Rng = Forge.Core.Rng

local Customers = {}

local SUCCESS, RUNNING, FAILURE = 1, 0, -1

Customers.SPEED = 13
Customers.MAX_PER_SHOP = 4
Customers.MAX_TOTAL = 18

--: Seconds between arrivals at a shop with no signage and one piece on
--: display. Signage and a full shelf both cut it.
Customers.BASE_INTERVAL = 26

local stream = Rng.stream("carvewood.customers")
local separation = CrowdSeparation.new({ radiusFactor = 0.4, strength = 1.2, hz = 8 })

local active: { any } = {}
local folder: Folder? = nil

--: Set by the server so a decision can reach the player who owns the shop.
Customers.onOffer = nil :: ((Player, any) -> ())?
Customers.onSale = nil :: ((Player, any) -> ())?

-- ================================== bodies ==================================
local SHIRTS = {
	Color3.fromRGB(196, 88, 74), Color3.fromRGB(74, 122, 176),
	Color3.fromRGB(96, 158, 96), Color3.fromRGB(202, 158, 70),
	Color3.fromRGB(146, 104, 178), Color3.fromRGB(206, 132, 92),
}

local function body(at: Vector3, shirt: Color3, parent: Instance): Model
	local model = Instance.new("Model")
	model.Name = "Customer"

	local torso = Instance.new("Part")
	torso.Name = "Torso"
	torso.Size = Vector3.new(2, 2.4, 1)
	torso.CFrame = CFrame.new(at + Vector3.new(0, 3, 0))
	torso.Anchored = true
	torso.CanCollide = false
	torso.Color = shirt
	torso.Material = Enum.Material.SmoothPlastic
	torso.TopSurface = Enum.SurfaceType.Smooth
	torso.BottomSurface = Enum.SurfaceType.Smooth
	torso.Parent = model
	model.PrimaryPart = torso

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Shape = Enum.PartType.Ball
	head.Size = Vector3.new(1.35, 1.35, 1.35)
	head.Anchored = true
	head.CanCollide = false
	head.Color = Color3.fromRGB(226, 194, 160)
	head.Material = Enum.Material.SmoothPlastic
	head.Parent = model

	local legs = Instance.new("Part")
	legs.Name = "Legs"
	legs.Size = Vector3.new(1.8, 2.6, 0.9)
	legs.Anchored = true
	legs.CanCollide = false
	legs.Color = Color3.fromRGB(72, 76, 96)
	legs.Material = Enum.Material.SmoothPlastic
	legs.Parent = model

	--: A name tag, because a customer with a name is a person and a customer
	--: without one is a prop. It is also where the offer shows up.
	local gui = Instance.new("BillboardGui")
	gui.Name = "Say"
	gui.Size = UDim2.fromOffset(210, 46)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 2.6, 0)
	gui.AlwaysOnTop = false
	gui.MaxDistance = 90
	gui.Adornee = head
	gui.Parent = head
	local text = Instance.new("TextLabel")
	text.Name = "Text"
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Text = ""
	text.TextScaled = true
	text.TextStrokeTransparency = 0.4
	text.TextColor3 = Color3.fromRGB(248, 242, 230)
	text.FontFace = Font.new("rbxasset://fonts/families/SourceSansPro.json",
		Enum.FontWeight.Bold)
	text.Parent = gui

	model.Parent = parent
	return model
end

local function place(model: Model, at: Vector3, facing: Vector3, bob: number)
	local torso = model.PrimaryPart
	if not torso then
		return
	end
	local look = if facing.Magnitude > 0.01
		then CFrame.lookAt(at + Vector3.new(0, 3, 0), at + facing + Vector3.new(0, 3, 0))
		else CFrame.new(at + Vector3.new(0, 3, 0))
	torso.CFrame = look * CFrame.new(0, bob, 0)
	local head = model:FindFirstChild("Head")
	local legs = model:FindFirstChild("Legs")
	if head and head:IsA("BasePart") then
		head.CFrame = torso.CFrame * CFrame.new(0, 1.9, 0)
	end
	if legs and legs:IsA("BasePart") then
		legs.CFrame = torso.CFrame * CFrame.new(0, -2.5, 0)
	end
end

local function say(record: any, text: string)
	local head = record.model and record.model:FindFirstChild("Head")
	local gui = head and head:FindFirstChild("Say")
	local label = gui and gui:FindFirstChild("Text")
	if label and label:IsA("TextLabel") then
		label.Text = text
	end
end

-- ================================ the person ================================
--[[
	Who just walked in.

	`taste` is biased toward what the shop is actually displaying rather than
	drawn flat. A flat draw sends a player whose shelves hold nothing but Pine a
	steady stream of people who came for a Legendary and leave -- technically
	correct and, for the first hour of the game, indistinguishable from the shop
	being broken.
]]
local function invent(state: Yard.State): Yard.Customer
	local tiers, count = 0, 0
	for _, stand in state.shop.stands do
		local species = Trees.get(stand.species)
		if species then
			tiers += species.tier
			count += 1
		end
	end
	local centre = if count > 0 then tiers / count else 1
	local taste = math.clamp(
		math.round(centre + stream:number(-1.1, 1.4)), 1, 7)

	--: Budget scales with what they came for, so a Celestial browser can
	--: actually afford a Celestial.
	local species = Trees.species[math.min(taste, #Trees.species)]
	local ceiling = math.max(60, (species and species.value or 60) * 4)
	return {
		budget = math.floor(ceiling * stream:number(0.5, 1.6)),
		taste = taste,
		generosity = stream:number(0.82, 1.32),
		patience = stream:number(9, 18),
	}
end

-- =============================== the behaviour ==============================
--[[
	Approach, browse, transact, leave -- and meander when nothing appeals.

	The tree is the shape of the visit and the leaves are one step each, so a
	customer who cannot find anything worth looking at falls through to the
	wander instead of standing in the doorway.
]]
local function buildTree()
	local walk = BehaviorTree.action(function(ctx)
		local record = ctx.blackboard.record
		if record.navigator:finished() then
			return SUCCESS
		end
		local pos = record.position
		local dir = record.navigator:update(
			{ x = pos.X, y = pos.Y, z = pos.Z }, ctx.dt)
		record.heading = Vector3.new(dir.x, 0, dir.z)
		return RUNNING
	end)

	local browse = BehaviorTree.action(function(ctx)
		local record = ctx.blackboard.record
		record.browsedFor = (record.browsedFor or 0) + ctx.dt
		if record.browsedFor < 1.6 then
			say(record, "...")
			return RUNNING
		end
		--: Look at everything on the shelves and want the best deal, not the
		--: first thing seen. A customer who takes the nearest stand makes the
		--: left-hand shelf the only one worth stocking.
		local state = record.state
		local best, bestIndex, bestGap = nil, nil, -math.huge
		for index, stand in state.shop.stands do
			local willing = Yard.valuation(record.customer, stand, state.shop)
			local gap = willing - stand.price
			if stand.price <= record.customer.budget and gap > bestGap then
				best, bestIndex, bestGap = stand, index, gap
			end
		end
		if not best then
			return FAILURE
		end
		record.standIndex = bestIndex
		record.stand = best
		return SUCCESS
	end)

	local transact = BehaviorTree.action(function(ctx)
		local record = ctx.blackboard.record
		local state = record.state
		local stand = state.shop.stands[record.standIndex]
		if not stand then
			--: Somebody else bought it, or the owner took it down.
			return FAILURE
		end
		if not record.verdict then
			local verdict, amount = Yard.decide(record.customer, stand, state.shop)
			record.verdict, record.offer = verdict, amount
			if verdict == "buy" then
				say(record, "I'll take it!")
			elseif verdict == "haggle" then
				say(record, string.format("%d?", amount))
				if Customers.onOffer then
					Customers.onOffer(record.player, {
						id = record.id, stand = record.standIndex,
						asking = stand.price, offer = amount,
						species = stand.species, quality = stand.quality,
						seconds = record.customer.patience,
					})
				end
			else
				say(record, "Too rich for me.")
			end
		end

		if record.verdict == "buy" then
			Customers.settle(record, stand.price)
			return SUCCESS
		end
		if record.verdict ~= "haggle" then
			return FAILURE
		end

		--: Waiting on the owner. Patience is a real clock: an unanswered offer
		--: is a lost sale, which is what makes auto-accept worth having.
		record.waited = (record.waited or 0) + ctx.dt
		if record.answered == "accept" then
			Customers.settle(record, record.offer)
			return SUCCESS
		end
		if record.answered == "decline" or record.waited >= record.customer.patience then
			say(record, "Another time.")
			return FAILURE
		end
		return RUNNING
	end)

	local visit = BehaviorTree.sequence({ walk, browse, transact })

	--: Nothing to buy. Drift for a moment so the yard has people in it rather
	--: than a queue of statues, then the sweep retires them.
	local wander = BehaviorTree.action(function(ctx)
		local record = ctx.blackboard.record
		record.wandering = (record.wandering or 0) + ctx.dt
		if record.wandering > 3.5 then
			record.done = true
			return SUCCESS
		end
		record.heading = Vector3.new(
			math.sin(record.seed + record.wandering), 0,
			math.cos(record.seed * 1.7 + record.wandering))
		return RUNNING
	end)

	return BehaviorTree.fallback({ visit, wander })
end

local tree = buildTree()

-- ================================== sales ===================================
function Customers.settle(record: any, paid: number)
	local ok, detail = Yard.completeSale(record.state, record.standIndex, paid)
	if ok then
		say(record, string.format("+%d", paid))
		if Customers.onSale then
			Customers.onSale(record.player, detail)
		end
	end
	record.done = true
	record.leaving = true
end

--: The owner answered a haggle. Returns whether the customer was still there,
--: because "too late" is a real outcome and the client should be told.
function Customers.answer(player: Player, id: number, accept: boolean): boolean
	for _, record in active do
		if record.id == id and record.player == player then
			record.answered = if accept then "accept" else "decline"
			return true
		end
	end
	return false
end

-- ================================= lifecycle ================================
local nextId = 0

function Customers.spawn(player: Player, state: Yard.State): any
	local shop = Shop.of(player)
	if not shop then
		return nil
	end
	if #active >= Customers.MAX_TOTAL then
		return nil
	end
	local here = 0
	for _, record in active do
		if record.player == player then
			here += 1
		end
	end
	if here >= Customers.MAX_PER_SHOP then
		return nil
	end

	if not folder then
		local made = Instance.new("Folder")
		made.Name = "Customers"
		made.Parent = Workspace
		folder = made
	end

	--: In from the treeline behind the shop's door, so they arrive walking
	--: rather than appearing on the doorstep.
	local door = shop.door
	local away = door + Vector3.new(stream:number(-30, 30), 0, stream:number(26, 46))
	nextId += 1

	local record: any = {
		id = nextId,
		player = player,
		state = state,
		customer = invent(state),
		position = away,
		heading = Vector3.zero,
		seed = stream:number(0, 6.28),
		model = body(away, SHIRTS[stream:int(1, #SHIRTS)], folder :: Folder),
		navigator = Navigator.new({
			waypoints = {
				{ x = door.X, y = door.Y, z = door.Z + 12 },
				{ x = door.X, y = door.Y, z = door.Z },
			},
			arriveDistance = 3.5,
			expectedSpeed = Customers.SPEED,
			clock = os.clock,
		}),
		blackboard = {},
		bob = stream:number(0, 6.28),
		age = 0,
	}
	record.blackboard.record = record
	table.insert(active, record)
	return record
end

--[[
	One tick for everybody.

	Separation is computed once for the whole crowd rather than per customer,
	which is the only reason thirty of them is affordable: the module answers
	with a correction per id and the movement below just adds it.
]]
function Customers.tick(dt: number)
	if #active == 0 then
		return
	end

	local corrections = {}
	if separation:tick(dt) then
		local entities = {}
		for _, record in active do
			table.insert(entities, {
				id = tostring(record.id), size = 2.4,
				x = record.position.X, z = record.position.Z,
			})
		end
		corrections = separation:compute(entities)
	end

	for index = #active, 1, -1 do
		local record = active[index]
		record.age += dt

		if not record.done then
			BehaviorTree.run(tree, record.blackboard, dt)
		end

		--: Leaving is the same walk, outward. A customer that vanishes on the
		--: shop floor reads as a bug even when the sale was correct.
		if record.done and not record.exit then
			record.exit = record.position + Vector3.new(
				stream:number(-24, 24), 0, 54)
			say(record, "")
		end
		if record.exit then
			local to = record.exit - record.position
			record.heading = if to.Magnitude > 1 then to.Unit else Vector3.zero
		end

		local nudge = corrections[tostring(record.id)]
		local move = record.heading
		if nudge then
			move = move + Vector3.new(nudge.x, 0, nudge.z)
		end
		if move.Magnitude > 0.01 then
			record.position = record.position + move.Unit * Customers.SPEED * dt
		end

		record.bob += dt * 9
		local bob = if move.Magnitude > 0.05 then math.abs(math.sin(record.bob)) * 0.22 else 0
		place(record.model, record.position, record.heading, bob)

		--: Retired when they are off the lot, or after a minute regardless --
		--: an NPC that outlives its errand is a leak with a face on it.
		local far = record.exit and (record.position - record.exit).Magnitude < 6
		if far or record.age > 75 then
			record.model:Destroy()
			table.remove(active, index)
		end
	end
end

--[[
	Whether anybody turns up.

	Footfall is the signage upgrade times how much there is to look at: an empty
	shop draws nobody, which is the game telling a player to stock it rather
	than a message saying so.
]]
function Customers.interval(state: Yard.State): number
	local stocked = 0
	for _ in state.shop.stands do
		stocked += 1
	end
	if stocked == 0 then
		return math.huge
	end
	local pull = Yard.footfall(state.shop) * (1 + math.min(stocked, 12) * 0.16)
	return Customers.BASE_INTERVAL / pull
end

function Customers.clearFor(player: Player)
	for index = #active, 1, -1 do
		if active[index].player == player then
			active[index].model:Destroy()
			table.remove(active, index)
		end
	end
end

function Customers.describe(): { [string]: any }
	local shopping = 0
	for _, record in active do
		if not record.done then
			shopping += 1
		end
	end
	return { active = #active, shopping = shopping }
end

return Customers
