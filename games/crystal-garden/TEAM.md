# Jardim de Cristais

Validation: NOT_VALIDATED until Studio evidence is recorded.

Small social farming simulator: plant crystals, wait 8-40 seconds, harvest into a backpack, sell at the market, unlock species and improve backpack/soil. No Robux purchase, combat, pets, or imported assets. Six owned plots, nine beds each. Server owns all prices, growth, rewards, ownership and random rolls. Bright mint/lavender botanical conservatory with a giant crystal landmark and readable paths. Portuguese player-facing text.

## Ownership

Coordinator owns shared/Config.lua, shared/Economy.lua, server/Garden.lua, server/init.server.lua, project files, docs and integration.
Brisa owns ONLY src/server/World.lua (world geometry + growth visuals).
Prisma owns ONLY src/client/init.client.lua (responsive HUD, shop, collection, interaction feedback).
Vigia owns ONLY src/server/tests/Economy.lua and review notes in REVIEW.md; review coordinator code when it arrives. No platform edits.

## Shared contract (fixed)

ReplicatedStorage.Shared.Config / Economy; ReplicatedStorage.WorldKit / GameKit.
ReplicatedStorage.GardenNet.Action RemoteEvent receives (verb, id): select/speciesId, unlock/speciesId, upgrade/backpack or soil, sell (only near market), harvestAll (only near own plot). State RemoteEvent sends snapshot; Toast sends (message, kind).
Client calls Action:FireServer("sync") once listeners connected.
Snapshot fields: coins, selected, unlocked (id->boolean), upgrades={backpack=0,soil=0}, capacity, bagCount, bagValue, harvested, sold, collection (speciesId->count), weather={id,name,multiplier,endsAt}, plotId, beds={{slot,speciesId?,readyAt?,plantedAt?,mutation?,value?}}, nextCosts={backpack,soil}, saveMode, goal={text,progress,target}.
Config.species array: id,name,cost,growSeconds,value,color={r,g,b},unlockCost. Config.mutations array: id,name,multiplier,color. Config.upgrades.backpack / soil arrays of prices; Config.capacityBase / capacityStep / maxSoilReduction.
Time is workspace:GetServerTimeNow(). State pushes every second.

## World interface

World.build(Config) -> {plots={{id,origin=Vector3,spawn=CFrame,beds={BasePart,...},sign=TextLabel}},market=BasePart,spawn=SpawnLocation,root=Folder}. Layout six plots near paths, numbered, 9 beds per plot spaced >=8 studs. All beds carry slot prompts; Garden owns wiring. Put plot ids/slots on attributes for diagnostics only.
World.setOwner(plot,playerOrNil) updates sign.
World.setBed(plot,slot,plantOrNil,Config) creates/updates crystal growth visuals. plant={speciesId,plantedAt,readyAt,mutation,value}; stage from server time. Must avoid recreate every tick; cap parts and labels.
World.setWeather(weather) presentation only, optional.
World.build uses WorldKit.Build and Palette.BrickFarm or custom named palette. Bound labels' MaxDistance; no user text except Roblox DisplayName; prefer plot number sign to avoid moderation ambiguity. Spawn facing first plot at 0,+Z, market close by. Flat navigable ground; no physical obstacles covering walkways. Limit world <2500 instances.

## Economy interface for tests

Economy.new(Config) -> profile {coins=30,selected="quartz",unlocked={quartz=true},upgrades={backpack=0,soil=0},bag={},collection={},harvested=0,sold=0}.
Economy.capacity(profile,Config), upgradeCost(profile,id,Config), plant(profile,speciesId,now,mutation,Config)->plant?,reason?, harvest(profile,plant,now,Config)->boolean,reason?, sell(profile,Config)->number, unlock(profile,id,Config)->boolean,reason?, upgrade(profile,id,Config)->boolean,reason?. Pure tables/math, no Roblox dependencies. mutation chosen by server, never passed by client. harvest must mark plant.harvested; prevents duplicate pickup. Insufficient funds cannot mutate profile; validation rejects unknown ids/NaN timestamps. Config uses numeric color arrays so tests can run headless.
