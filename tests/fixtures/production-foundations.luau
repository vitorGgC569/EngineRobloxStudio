-- Explicit fake services. These assertions are STATICALLY_VALIDATED.
local JSON = (function()
-- MODULE:JSON
end)()
local function signal()
	local listeners = {}
	return {
		Connect = function(_, fn) table.insert(listeners, fn); return {Disconnect=function() end} end,
		Fire = function(_, ...) for _, fn in listeners do fn(...) end end,
	}
end
local function clone(value)
	if type(value) ~= "table" then return value end
	local out = {}
	for key, item in value do out[key] = clone(item) end
	return out
end
local function saveFactory(game, task, require, script, warn)
-- MODULE:Save
end
local function moneyFactory(game, task, require, script, Enum, warn)
-- MODULE:Monetization
end
local function gamekitFactory(game, task, warn)
-- MODULE:GameKitSave
end
local function environment(record, opts)
	opts = opts or {}
	local state = {record=clone(record), updates=0, threads={}, time=0}
	local player = {UserId=123,Name="FaultTest",Parent=true}
	state.player = player
	local fakeTask = {
		spawn=function(fn, ...)
			local co = coroutine.create(fn)
			table.insert(state.threads, co)
			local ok, err = coroutine.resume(co, ...); assert(ok, err)
			return co
		end,
		wait=function() coroutine.yield() end,
	}
	local store = {
		GetAsync=function() if opts.unavailable then error("offline") end return nil end,
		UpdateAsync=function(_, _, fn)
			state.updates += 1
			if opts.unavailable then error("offline") end
			if state.before then state.before() end
			if state.repeatCallback then fn(clone(state.record)) end -- discarded attempt
			local value = fn(clone(state.record))
			if value ~= nil then state.record = clone(value) end
			if state.after then state.after() end
			return clone(value)
		end,
		SetAsync=function() error("blind writes are forbidden") end,
	}
	local players = {PlayerAdded=signal(),PlayerRemoving=signal(),GetPlayers=function() return {player} end,
		GetPlayerByUserId=function(_, id) return if id == player.UserId then player else nil end}
	local guid = 0
	local services = {Players=players, DataStoreService={GetDataStore=function() return store end},
		RunService={IsStudio=function() return opts.studio ~= false end,IsServer=function() return true end},
		HttpService={JSONEncode=function(_, v) return JSON(v) end,
			GenerateGUID=function() guid+=1;return "token-"..guid end},
		MarketplaceService={PromptGamePassPurchaseFinished=signal()},
	}
	local game = {JobId="",GetService=function(_, name) return services[name] end,
		BindToClose=function(_, fn) state.close=fn end}
	if opts.gamekit then
		state.save = gamekitFactory(game, fakeTask, function() end).store("fixture", {gold=0}, {
			autoWire=false, legacyFlat=opts.legacyFlat, keyPrefix=opts.keyPrefix,
		})
		fakeTask.spawn(function() state.profile=state.save:load(player) end)
		return state
	end
	local script = {Parent={Core={Signal="signal"},Save="save"}}
	local Save
	local function require(name)
		if name == "save" then return Save end
		return {new=signal}
	end
	Save = saveFactory(game, fakeTask, require, script, function() end)
	Save.configure({template={gold=0},retries=opts.retries or 1,version=opts.version or 1,
		migrations=opts.migrations or {},allowStudioMemory=opts.allowMemory ~= false})
	Save.start()
	state.save, state.task, state.services = Save, fakeTask, services
	state.money = moneyFactory(game, fakeTask, require, script,
		{ProductPurchaseDecision={NotProcessedYet="defer",PurchaseGranted="granted"}},function() end)
	return state
end

-- The GameKit adapter must obey the same ownership and callback boundaries.
do
	local s = environment({data={gold=500},lock={jobId="foreign",at=os.time()}},{gamekit=true})
	assert(s.save:get(s.player)==nil and not s.save:save(s.player))
	assert(s.record.data.gold==500 and s.record.lock.jobId=="foreign")
	local owned = environment({data={gold=50}},{gamekit=true})
	owned.save:get(owned.player).data.gold=60
	assert(owned.save:save(owned.player) and owned.record.data.gold==60)
	owned.record.lock.jobId="new-owner"
	assert(not owned.save:save(owned.player) and owned.save:get(owned.player)==nil)
	local released = environment({data={gold=20}},{gamekit=true})
	assert(released.save:release(released.player) and released.record.lock==nil)
	local corrupt = environment("corrupt",{gamekit=true})
	assert(corrupt.save:get(corrupt.player)==nil and corrupt.record=="corrupt")
	local legacy = environment({gold=321, inventory={"sword"}},{gamekit=true,legacyFlat=true,keyPrefix="player_"})
	assert(legacy.save:get(legacy.player).data.gold==321 and legacy.record.data.inventory[1]=="sword")
	assert(legacy.record.lock~=nil and legacy.record.gold==nil)
	assert(legacy.save:releaseAll()==1 and legacy.record.lock==nil)
	assert(legacy.save:load(legacy.player)==nil, "a closing store must refuse new profiles")
end

-- A foreign owner must never turn into a writable template.
do
	local s = environment({gold=500,__lock="foreign",__lockTime=os.time()})
	assert(s.save.get(s.player) == nil)
	assert(s.save.status(s.player).error == "SESSION_LOCKED")
	assert(not s.save.write(s.player, true))
	assert(s.record.gold == 500 and s.record.__lock == "foreign")
end
-- Successful writes renew ownership; release actually clears it.
do
	local s = environment({gold=500})
	s.save.get(s.player).gold += 5
	assert(s.save.write(s.player))
	assert(s.record.gold == 505 and s.record.__lock ~= nil)
	assert(s.save.write(s.player, true))
	assert(s.record.__lock == nil and s.record.__lockTime == nil)
	assert(not s.save.write(s.player))
end
-- A former owner cannot overwrite a newer session, including a same-token ABA.
for _, steal in {"owner", "fence"} do
	local s = environment({gold=50})
	s.save.get(s.player).gold = 0
	if steal == "owner" then s.record.__lock = "new-owner" else s.record.__fence += 1 end
	assert(not s.save.write(s.player))
	assert(s.record.gold == 50 and not s.save.status(s.player).persistent)
end
-- Migration failure, future schema and corrupt records are preserved byte-for-byte.
for _, case in {
	{record={gold=50,__version=9}},
	{record={gold=50,__checksum="invalid"}},
	{record="corrupt"},
	{record={gold=50},options={version=2,migrations={[2]=function(p) p.gold=0;error("bad migration") end}}},
} do
	local s = environment(case.record, case.options)
	assert(s.save.get(s.player) == nil)
	assert(JSON(s.record) == JSON(case.record))
end
-- Live service failure does not enable a writable memory fallback.
do
	local s = environment({gold=50}, {unavailable=true,studio=false})
	assert(s.save.get(s.player) == nil and not s.save.describe().memoryOnly)
	local memory = environment(nil, {unavailable=true})
	assert(memory.save.get(memory.player) ~= nil and memory.save.describe().memoryOnly)
	assert(not memory.save.commitReceipt(memory.player,"paid",function(p) p.gold+=5 end))
end
-- One atomic paid state+receipt despite callback replay and repeated delivery.
do
	local s = environment({gold=50})
	s.repeatCallback = true
	s.money.defineProduct("coins",{productId=7,apply=function(p) p.gold += 10 end})
	local receipt = {PlayerId=123,ProductId=7,PurchaseId="purchase-1"}
	assert(s.money.processReceipt(receipt) == "granted")
	assert(s.record.gold == 60 and s.record.__receipts["purchase-1"])
	assert(s.money.processReceipt(receipt) == "granted")
	assert(s.record.gold == 60 and s.save.get(s.player).gold == 60)
	assert(s.money.describe().granted == 1 and s.money.describe().duplicatesRefused == 1)
	assert(not s.save.commitReceipt(s.player,"yielding",function() coroutine.yield() end))
	assert(not s.record.__receipts.yielding)
	assert(not s.save.commitReceipt(s.player,"throwing",function(p) p.gold=0;error("no") end))
	assert(s.record.gold == 60 and s.save.get(s.player).gold == 60)
end
-- Lost acknowledgement retries the same operation instead of applying twice.
do
	local s = environment({gold=50},{retries=2})
	local once = true
	s.after = function() if once then once=false;error("response lost after commit") end end
	local result
	local co = s.task.spawn(function() result=s.save.commitReceipt(s.player,"lost-ack",function(p) p.gold+=10 end) end)
	assert(coroutine.resume(co))
	assert(result == true and s.record.gold == 60 and s.save.get(s.player).gold == 60)
end
-- Flush waits for the actual outstanding write rather than a fixed sleep.
do
	local s = environment({gold=50})
	s.before = function() coroutine.yield() end
	local result
	local co = s.task.spawn(function() result=s.save.flush(2) end)
	assert(result == nil, "flush returned before the store completed")
	for _, thread in s.threads do
		if thread ~= co and coroutine.status(thread) == "suspended" then
			assert(coroutine.resume(thread))
		end
	end
	assert(coroutine.resume(co))
	assert(result.complete and s.record.__lock == nil)
end

local netCallback
local remote = {OnServerEvent={Connect=function(_, fn) netCallback=fn;return {} end}}
local folder = {FindFirstChild=function() return remote end,WaitForChild=function() return remote end}
local services = {RunService={IsServer=function() return true end},Players={},
	ReplicatedStorage={FindFirstChild=function() return folder end}}
local game = {GetService=function(_, name) return services[name] end}
local script = {Parent={Core={Signal="signal",Sched="sched"}}}
local require = function(name)
	if name == "signal" then return {new=signal} end
	return {bucket=function() return function() return true end end}
end
local warn = function() end
local Net = (function()
-- MODULE:Net
end)()
local delivered, checked = 0, 0
Net.define({Buy={dir="c2s",shape={item="string"},check=function(p) checked+=1;return p.item=="ok" end}})
Net.on("Buy",function() delivered+=1 end)
for _, payload in {{item=123},{item="ok",price=0},{item="no"},{item="ok"}} do
	netCallback({Name="Fake"},payload)
end
assert(delivered==1 and checked==2, "shape must precede the custom validator")
Net.define({Throws={dir="c2s",check=function() error("validator bug") end}})
Net.on("Throws",function() error("handler must not run") end)
assert(pcall(netCallback,{Name="Fake"},{}),"validator errors must refuse the packet")

local Vector3, mt = {}, {}
mt.__index=function(v,k)
	if k=="Magnitude" then return math.sqrt(v.X*v.X+v.Y*v.Y+v.Z*v.Z) end
	if k=="Unit" then local m=math.sqrt(v.X*v.X+v.Y*v.Y+v.Z*v.Z);return Vector3.new(v.X/m,v.Y/m,v.Z/m) end
end
mt.__sub=function(a,b) return Vector3.new(a.X-b.X,a.Y-b.Y,a.Z-b.Z) end
mt.__add=function(a,b) return Vector3.new(a.X+b.X,a.Y+b.Y,a.Z+b.Z) end
mt.__mul=function(a,b) return Vector3.new(a.X*b,a.Y*b,a.Z*b) end
Vector3.new=function(x,y,z) return setmetatable({X=x,Y=y,Z=z},mt) end
local typeof=function(v) return if type(v)=="table" and getmetatable(v)==mt then "Vector3" else type(v) end
local now, heartbeat = 0, nil
local os = {clock=function() return now end}
local pending = {}
local task = {spawn=function(fn, ...)
	local co=coroutine.create(fn);table.insert(pending,co);local ok,err=coroutine.resume(co,...);assert(ok,err)
end}
services.RunService.Heartbeat={Connect=function(_,fn) heartbeat=fn;return {Disconnect=function() end} end}
local Enum={PathWaypointAction={Jump="Jump"},HumanoidStateType={Jumping="Jumping"}}
local Nav = (function()
-- MODULE:Nav
end)()
local computes = 0
Nav.computePath=function(_, goal) computes+=1;coroutine.yield();return {{Position=goal}},"Success" end
local pos = Vector3.new(0,0,0)
local lastMove
local humanoid={MoveTo=function(_,p) lastMove=p end}
local model={Parent=true,GetPivot=function() return {Position=pos} end,FindFirstChildOfClass=function() return humanoid end}
local arrivals=0
local agent=Nav.follow(model,{target=Vector3.new(80,0,0),standoff=10,onArrive=function() arrivals+=1 end})
for i=1,3 do now=i/60;heartbeat() end
assert(computes==1 and agent:describe().computing, "overlapping ComputeAsync")
assert(coroutine.resume(pending[1]))
now=1;heartbeat()
assert(computes==1, "trimmed standoff must not look like a moving target")
pos=Vector3.new(70,0,0);heartbeat();heartbeat()
assert(arrivals==1 and agent:describe().arrived)
assert(lastMove.X==70,"arrived agent must not walk to the target center")
pos=Vector3.new(0,0,0);now=2;heartbeat()
agent:stop()
for _, co in pending do if coroutine.status(co)=="suspended" then assert(coroutine.resume(co)) end end
assert(Nav.agentCount()==0 and Nav.describe().activeComputes==0)
print("FOUNDATIONS_PASS")
