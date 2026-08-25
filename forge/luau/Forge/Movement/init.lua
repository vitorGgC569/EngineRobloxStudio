--!strict
--[[
	Movement — player feel and shooting validation.

	Movement quality is configuration, not mystery: split accel/brake
	integration (AccelMove), a shared spread cone so aim matches server
	truth (Ballistics), and authoritative hitscan checks
	(HitscanValidator). Pure math over plain vectors throughout.
]]

return {
	AccelMove = require(script.Parent.AccelMove),
	Ballistics = require(script.Parent.Ballistics),
	HitscanValidator = require(script.Parent.HitscanValidator),
}
