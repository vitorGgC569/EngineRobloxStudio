--!strict
--[[
	Stance — what the shooter is doing, and what that costs in accuracy.

	`Weapon` already models bloom: a cone that grows per shot and recovers while
	the trigger is released. What it did not model is the other half of every
	shooter's accuracy, which is *posture*. Aiming down sights narrows the cone;
	walking, sprinting and being airborne widen it.

	This is the layer that makes movement a decision. Without it a player who
	sprints backwards while firing is exactly as accurate as one who plants and
	aims, and the entire risk/reward of a firefight disappears.

		local stance = Stance.read(character, { ads = aiming })
		local cone = Weapon.currentSpread(character) * Stance.multiplier(def, stance)

	Multipliers compound
	--------------------

	A player sprinting *and* airborne is worse off than either alone. That is
	deliberate and it is what stops bunny-hopping from being free accuracy --
	the single most common way a shooter's movement model eats its aiming model.

	The presets
	-----------

	Four weapon classes, tuned in a shipped shooter. Offered as a starting point
	for `Weapon.define`, and more usefully as a worked example of the
	relationships, which travel further than the values:

	  * a **pistol** blooms fastest per shot and recovers fastest, so it rewards
	    tapping and punishes spraying;
	  * a **shotgun** barely blooms *relative to its own cone* -- around a
	    tenth of its resting spread per shot, against two thirds for a pistol.
	    Its cone is already its pellet spread, and bloom on top of that is a
	    penalty no player can read;
	  * **fast weapons bloom harder**, so holding the trigger costs accuracy and
	    a burst becomes a real choice rather than a worse version of holding it.
]]

local Stance = {}

export type State = {
	ads: boolean?,
	moving: boolean?,
	sprinting: boolean?,
	airborne: boolean?,
}

--: Applied on top of whatever cone `Weapon` has already computed. Below one
--: narrows, above one widens.
local DEFAULT_MULTIPLIERS = {
	ads = 0.35,
	moving = 1.4,
	sprinting = 2.2,
	airborne = 2.2,
}

--[[
	Ready-made `Weapon.define` fragments for four classes.

	Merge one into a definition rather than copying numbers around:

		Weapon.define("carbine", Stance.preset("rifle", { damage = 24 }))
]]
Stance.presets = {
	rifle = {
		rpm = 620,
		spread = { min = 0.9, max = 6.0, perShot = 0.30, recover = 7.0 },
		stance = { ads = 0.35, moving = 1.5, sprinting = 2.4, airborne = 2.2 },
	},
	smg = {
		rpm = 850,
		spread = { min = 1.4, max = 7.5, perShot = 0.26, recover = 8.5 },
		stance = { ads = 0.45, moving = 1.35, sprinting = 2.1, airborne = 2.2 },
	},
	pistol = {
		rpm = 380,
		spread = { min = 0.7, max = 5.0, perShot = 0.45, recover = 9.0 },
		stance = { ads = 0.30, moving = 1.4, sprinting = 2.2, airborne = 2.2 },
	},
	shotgun = {
		rpm = 75,
		pellets = 8,
		spread = { min = 4.5, max = 8.0, perShot = 0.5, recover = 6.0 },
		stance = { ads = 0.70, moving = 1.15, sprinting = 1.5, airborne = 1.8 },
	},
}

--[[
	A weapon definition built from a preset, with overrides merged over it.

	Shallow per-table, so `{ spread = { min = 2 } }` replaces only `min` and
	keeps the preset's other three. A deep merge here would be surprising and a
	replace would make the presets useless for tuning one value.
]]
function Stance.preset(class: string, overrides: { [string]: any }?): { [string]: any }
	local base = Stance.presets[class]
	if not base then
		error(`Stance.preset: unknown class "{class}"`, 2)
	end

	local out: { [string]: any } = {}
	for key, value in base do
		if type(value) == "table" then
			local copy = {}
			for k, v in value do
				copy[k] = v
			end
			out[key] = copy
		else
			out[key] = value
		end
	end

	for key, value in overrides or {} do
		if type(value) == "table" and type(out[key]) == "table" then
			for k, v in value do
				out[key][k] = v
			end
		else
			out[key] = value
		end
	end
	return out
end

--[[
	The accuracy multiplier for a posture.

	`def` may carry a `stance` table to override any of the four; anything it
	omits falls back to the defaults above, so a weapon defined without
	thinking about stance still behaves sensibly.
]]
function Stance.multiplier(def: any, state: State?): number
	local posture = state or {}
	local tuning = (def and def.stance) or {}
	local function factor(key: string): number
		local value = tuning[key]
		if value ~= nil then
			return value
		end
		return (DEFAULT_MULTIPLIERS :: any)[key]
	end

	local multiplier = 1
	if posture.ads then
		multiplier *= factor("ads")
	end
	if posture.moving then
		multiplier *= factor("moving")
	end
	if posture.sprinting then
		multiplier *= factor("sprinting")
	end
	if posture.airborne then
		multiplier *= factor("airborne")
	end
	return multiplier
end

--[[
	Read a posture off a character, so callers do not each invent their own.

	`moving` and `sprinting` are derived from actual velocity rather than from
	input, because a player held against a wall is pressing forward and not
	moving, and should be shooting like someone standing still.

	`extra` supplies what a character cannot know -- chiefly `ads`, which is a
	game's own aiming state.

	`sprintAbove` defaults to just over a default walk speed. A game with its
	own movement model should pass its own threshold.
]]
function Stance.read(character: Model?, extra: State?): State
	local out: State = {}
	for key, value in extra or {} do
		(out :: any)[key] = value
	end
	if not character then
		return out
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = humanoid and humanoid.RootPart
	if not (humanoid and root) then
		return out
	end

	local velocity = root.AssemblyLinearVelocity
	local horizontal = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	if out.moving == nil then
		out.moving = horizontal > 0.5
	end
	if out.sprinting == nil then
		local threshold = (extra and (extra :: any).sprintAbove) or 18
		out.sprinting = horizontal > threshold
	end
	if out.airborne == nil then
		local state = humanoid:GetState()
		out.airborne = state == Enum.HumanoidStateType.Freefall
			or state == Enum.HumanoidStateType.Jumping
	end
	return out
end

function Stance.describe(): { [string]: any }
	local classes = {}
	for name in Stance.presets do
		table.insert(classes, name)
	end
	table.sort(classes)
	return { presets = classes, defaults = DEFAULT_MULTIPLIERS }
end

return Stance
