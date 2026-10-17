--!strict
--[[
	Core — primitives with no Roblox opinions in them.

	Everything here is testable without a DataModel, which is why it is
	separate. If a module in this folder reaches for a service, it is in the
	wrong folder.

	Every file beside this one is reachable as `Core.<Name>`, resolved on
	demand by the metatable at the bottom. It used to be a list maintained by
	hand, and four modules were missing from it: `Boot` sat on disk, compiled,
	specced and unreachable, and the first game written against it died on
	`attempt to index nil with 'declareMany'`. A hand-written index is a folder
	somebody has to remember to copy, so it is gone.
]]

local Core = {}


--[[
	Siblings, resolved on the first thing that asks for one.

	One convention for the whole engine, because half the families had this and
	half did not, and in the half that did not a module beside this file was
	reachable only by requiring the instance directly. Two conventions in one
	engine is not a style difference; it is `attempt to index nil` in the first
	game that trusts the wrong one.

	Lazy rather than eager, matching `Forge` itself. Touching one family must
	not drag in every module it contains -- several build tables and open
	connections at load, and paying for all of that to read one constant is how
	a require graph becomes a frame budget.
]]
return setmetatable(Core, {
	__index = function(self, key: string): any
		local child = script:FindFirstChild(key)
		if not child or not child:IsA("ModuleScript") then
			return nil
		end
		local module = require(child) :: any
		rawset(self, key, module)
		return module
	end,
})
