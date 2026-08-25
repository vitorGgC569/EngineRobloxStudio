--!strict
--[[
	Movement — player feel and shooting validation.

	Movement quality is configuration, not mystery: split accel/brake
	integration (AccelMove), a shared spread cone so aim matches server
	truth (Ballistics), and authoritative hitscan checks
	(HitscanValidator). Pure math over plain vectors throughout.
]]

--[[
	Siblings, and the reference that was wrong.

	These were written `require(script.Parent.X)`. Inside a family's own
	`init.lua`, `script` *is* the family — so `script.Parent` is `Forge`, and
	every one of these was looking for a module one level too high. Requiring
	this family at all would have thrown; nothing did, because every caller so
	far reached past it to the child directly.

	Corrected to `script.X`, and given the same lazy resolver as the rest so a
	module added tomorrow is reachable without editing this list.
]]

local _Movement = {
	AccelMove = require(script.AccelMove),
	Ballistics = require(script.Ballistics),
	HitscanValidator = require(script.HitscanValidator),
}

return setmetatable(_Movement, {
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
