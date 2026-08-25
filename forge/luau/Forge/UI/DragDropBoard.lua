--!strict
--[[
	DragDropBoard — shared drag-and-drop state for grid boards.

	The puzzle-board interaction: pick a piece, drag it, show a ghost at
	the snapped cell colored by validity computed with the SAME planner
	rules as the server. This module tracks gesture state only; validity
	delegates to an injected fits() callback.
]]

local DragDropBoard = {}

export type Vec2 = { x: number, y: number }

export type GestureState = "idle" | "dragging" | "settling"

type Self = {
	state: GestureState,
	draggedPieceId: string?,
	pointer: Vec2?,
	snappedCell: { row: number, col: number }?,
	valid: boolean,
	fitsCallback: ((pieceId: string?, row: number, col: number) -> boolean)?,
}

DragDropBoard.__index = DragDropBoard

function DragDropBoard.new(fitsCallback: ((string?, number, number) -> boolean)?): Self
	return setmetatable({
		state = "idle" :: GestureState,
		draggedPieceId = nil,
		pointer = nil,
		snappedCell = nil,
		valid = false,
		fitsCallback = fitsCallback,
	}, DragDropBoard)
end

function DragDropBoard.pickUp(self: Self, pieceId: string): boolean
	if self.state ~= "idle" then
		return false
	end
	self.state = "dragging"
	self.draggedPieceId = pieceId
	return true
end

-- Pointer moved; snappedCell is already grid-snapped by the caller.
function DragDropBoard.moveTo(self: Self, pointer: Vec2, snappedRow: number, snappedCol: number): ()
	if self.state ~= "dragging" then
		return
	end
	self.pointer = pointer
	self.snappedCell = { row = snappedRow, col = snappedCol }
	self.valid = if self.fitsCallback then self.fitsCallback(self.draggedPieceId, snappedRow, snappedCol) else true
end

-- Drop resolves the placement attempt; returns whether it may place.
function DragDropBoard.drop(self: Self): (boolean, string?)
	if self.state ~= "dragging" then
		return false, "not_dragging"
	end
	local ok = self.valid and self.snappedCell ~= nil
	self.state = "idle"
	local pieceId = self.draggedPieceId
	self.draggedPieceId = nil
	self.snappedCell = nil
	self.pointer = nil
	if ok then
		return true, nil
	end
	return false, "invalid_drop"
end

return DragDropBoard
