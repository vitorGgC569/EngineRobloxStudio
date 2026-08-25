--!strict
--[[
	Physics2D — AABB collision with explicit side resolution.

	Hitboxes are invisible frames separated from visuals. Modes escalate:
	touch-only objects report overlap, side-checkers report which edge was
	hit (by comparing centres and intersection shape), colliders resolve
	penetration by pushing the non-anchored body out along the shallowest
	axis. Deterministic order: X wins ties unless the Y penetration is
	strictly smaller.
]]

local Physics2D = {}

export type Rect = { x: number, y: number, w: number, h: number }

export type Mode = "NoPhysics" | "CanTouch" | "CanCheckSide" | "CanCollide"

local MODE_RANK: { [Mode]: number } = {
	NoPhysics = 0,
	CanTouch = 1,
	CanCheckSide = 2,
	CanCollide = 3,
}

function Physics2D.modeRank(mode: Mode): number
	return MODE_RANK[mode]
end

function Physics2D.overlap(a: Rect, b: Rect): boolean
	return a.x < b.x + b.w and a.x + a.w > b.x and a.y < b.y + b.h and a.y + a.h > b.y
end

export type Side = "left" | "right" | "top" | "bottom"

-- Which side of `selfRect` touched `other`? Diagonals pick two sides when
-- the intersection is nearly square; otherwise the dominant axis wins.
function Physics2D.touchedSide(selfRect: Rect, other: Rect): { Side }
	if not Physics2D.overlap(selfRect, other) then
		return {}
	end
	local overlapX = math.min(selfRect.x + selfRect.w, other.x + other.w) - math.max(selfRect.x, other.x)
	local overlapY = math.min(selfRect.y + selfRect.h, other.y + other.h) - math.max(selfRect.y, other.y)

	local selfCX, selfCY = selfRect.x + selfRect.w / 2, selfRect.y + selfRect.h / 2
	local otherCX, otherCY = other.x + other.w / 2, other.y + other.h / 2

	local ratio = if overlapX == 0 then math.huge else overlapY / overlapX
	local sides: { Side } = {}

	local function pushHorizontal()
		table.insert(sides, if otherCX < selfCX then "left" else "right")
	end
	local function pushVertical()
		table.insert(sides, if otherCY < selfCY then "top" else "bottom")
	end

	if ratio > 1.25 then
		pushHorizontal()
	elseif ratio < 0.8 then
		pushVertical()
	else
		pushHorizontal()
		pushVertical()
	end
	return sides
end

-- Resolves penetration by moving `movable` out of `solid` along the
-- shallowest axis (split when both bodies are movable).
function Physics2D.resolve(movable: Rect, solid: Rect, bothMovable: boolean?): Rect
	if not Physics2D.overlap(movable, solid) then
		return movable
	end
	local overlapLeft = movable.x + movable.w - solid.x
	local overlapRight = solid.x + solid.w - movable.x
	local overlapTop = movable.y + movable.h - solid.y
	local overlapBottom = solid.y + solid.h - movable.y

	local minX = math.min(overlapLeft, overlapRight)
	local minY = math.min(overlapTop, overlapBottom)
	local share = if bothMovable then 2 else 1

	if minX <= minY then
		movable.x += (if overlapLeft < overlapRight then -minX else minX) / share
	else
		movable.y += (if overlapTop < overlapBottom then -minY else minY) / share
	end
	return movable
end

return Physics2D
