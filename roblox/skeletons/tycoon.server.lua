--!strict
--- TYCOON — a plot you fill with machines that turn time into money.
---
--- The genre's whole design is one number: how fast the next purchase gets
--- further away. Get the curve wrong and the game is over in four minutes or
--- unreachable at hour two. Everything else is decoration.
---
--- What it sets up:
---   * a plot per player, claimed on join
---   * droppers that make money on a beat, a conveyor, a collector
---   * buttons that buy the next tier, priced on a geometric ladder
---   * income that scales with what you own
---
--- Read `TIERS` first. That table is the game.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Core = require(ReplicatedStorage.Core)
local Behaviours = require(ReplicatedStorage.Behaviours)

local Actions, Events, Timer, Curve = Core.Actions, Core.Events, Core.Timer, Core.Curve
local Play = Behaviours.Play

-- ------------------------------------------------------------------ the design

--- **The whole game.** Price grows 1.6x a tier; income grows 2.1x. Income
--- outrunning price is what makes a tycoon feel like progress rather than a
--- treadmill — but only just, or it collapses by tier five.
local TIERS = {
	{ name = "Handcart", price = 0, income = 1, colour = Color3.fromRGB(150, 130, 100) },
	{ name = "Barrow", price = 250, income = 3, colour = Color3.fromRGB(160, 140, 90) },
	{ name = "Mill", price = 900, income = 8, colour = Color3.fromRGB(140, 150, 110) },
	{ name = "Kiln", price = 3200, income = 22, colour = Color3.fromRGB(180, 120, 80) },
	{ name = "Forge", price = 11000, income = 60, colour = Color3.fromRGB(190, 100, 70) },
	{ name = "Foundry", price = 38000, income = 165, colour = Color3.fromRGB(200, 150, 80) },
}

local DROP_EVERY = 1.5
local PLOT_SIZE = Vector3.new(80, 1, 80)

-- ------------------------------------------------------------------- the plots

local PLOTS = Instance.new("Folder")
PLOTS.Name = "Plots"
PLOTS.Parent = workspace

local claimed: { [Player]: Instance } = {}
local nextPlot = 0

local function buildPlot(player: Player): Instance
	nextPlot += 1
	local origin = Vector3.new(nextPlot * 120, 0, 0)

	local plot = Instance.new("Folder")
	plot.Name = ("Plot_%s"):format(player.Name)
	plot.Parent = PLOTS

	local floor = Instance.new("Part")
	floor.Name = "Floor"
	floor.Size = PLOT_SIZE
	floor.Position = origin
	floor.Anchored = true
	floor.Color = Color3.fromRGB(90, 95, 100)
	floor.Parent = plot

	local collector = Instance.new("Part")
	collector.Name = "Collector"
	collector.Size = Vector3.new(10, 6, 10)
	collector.Position = origin + Vector3.new(0, 3, -30)
	collector.Anchored = true
	collector.Color = Color3.fromRGB(80, 150, 120)
	collector.Material = Enum.Material.Metal
	collector.Parent = plot

	--- Collecting is a deliberate act, not automatic. A tycoon where money
	--- appears in your balance has no reason for the player to walk anywhere.
	Events.onTouch(collector, function(_, toucher)
		if toucher ~= player then
			return
		end
		local waiting = Actions.get(player, "Uncollected", 0) :: number
		if waiting <= 0 then
			return
		end
		Actions.set(player, "Uncollected", 0)
		Actions.add(player, "Cash", waiting)
		Actions.notify(player, ("Collected %d"):format(waiting))
	end, { debounce = 0.5 })

	Actions.set(player, "Tier", 1)
	Actions.set(player, "Cash", 0)
	Actions.set(player, "Uncollected", 0)
	Actions.set(player, "PlotOrigin", origin.X)
	return plot
end

-- ---------------------------------------------------------------- the machines

local function buildTier(player: Player, plot: Instance, index: number)
	local tier = TIERS[index]
	if tier == nil then
		return
	end
	local origin = Vector3.new(Actions.get(player, "PlotOrigin", 0) :: number, 0, 0)

	local machine = Instance.new("Part")
	machine.Name = ("Machine%d"):format(index)
	machine.Size = Vector3.new(8, 10, 8)
	machine.Position = origin + Vector3.new(-30 + index * 12, 5, 20)
	machine.Anchored = true
	machine.Color = tier.colour
	machine.Material = Enum.Material.Slate
	machine.Parent = plot

	Actions.set(machine, "Income", tier.income)
	Actions.notify(player, ("%s built"):format(tier.name))
end

local function buyButton(player: Player, plot: Instance, index: number)
	local tier = TIERS[index]
	if tier == nil then
		return
	end
	local origin = Vector3.new(Actions.get(player, "PlotOrigin", 0) :: number, 0, 0)

	local button = Instance.new("Part")
	button.Name = ("Buy%d"):format(index)
	button.Size = Vector3.new(6, 4, 6)
	button.Position = origin + Vector3.new(-30 + index * 12, 2, 5)
	button.Anchored = true
	button.Color = Color3.fromRGB(210, 180, 100)
	button.Material = Enum.Material.Neon
	button.Parent = plot

	Events.onPrompt(button, function(buyer)
		if buyer ~= player then
			return
		end
		if not Actions.spend(player, "Cash", tier.price) then
			Actions.notify(player, ("%s costs %d"):format(tier.name, tier.price))
			return
		end
		Actions.set(player, "Tier", index)
		buildTier(player, plot, index)
		button:Destroy()
		buyButton(player, plot, index + 1)
	end, { label = tier.name, action = ("Buy (%d)"):format(tier.price) })
end

-- ------------------------------------------------------------------- the income

--- Money accrues whether you are standing there or not, and waits to be
--- collected. That waiting pile is what pulls a player back to the plot.
Timer.every(DROP_EVERY, function()
	for player, _ in pairs(claimed) do
		local tier = Actions.get(player, "Tier", 1) :: number
		local income = 0
		for index = 1, tier do
			income += TIERS[index].income
		end
		Actions.add(player, "Uncollected", income)
	end
end, "tycoon.income")

-- --------------------------------------------------------------------- joining

Events.onPlayer(function(player)
	local plot = buildPlot(player)
	claimed[player] = plot
	buildTier(player, plot, 1)
	buyButton(player, plot, 2)

	local origin = Vector3.new(Actions.get(player, "PlotOrigin", 0) :: number, 0, 0)
	task.defer(function()
		Actions.teleport(player, origin + Vector3.new(0, 6, 0))
	end)
end)

Events.onPlayerLeft(function(player)
	local plot = claimed[player]
	if plot ~= nil then
		plot:Destroy()
		claimed[player] = nil
	end
end)

print("[tycoon] plots ready,", #TIERS, "tiers")
