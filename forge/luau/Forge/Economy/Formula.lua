--!strict
--[[
	Formula — an immutable, renderable chain of arithmetic operations.

		local f = Formula.start()
			:mul(2)
			:add(5)
			:pow(2)

		f:apply(3)     --> 121
		f:render()     --> "(x * 2 + 5) ^ 2"

	Every chain call returns a NEW formula; the receiver is never mutated, so a
	partly-built chain is safe to share and extend from. Hand `adapt(...)` any
	module exposing new/add/sub/mul/div/powInt/compare to run the same chain on
	BigNumber values instead of doubles.
]]

local Formula = {}

export type OpKind = "add" | "sub" | "mul" | "div" | "pow" | "clamp"

export type Op = {
	kind: OpKind,
	value: number?,
	min: number?,
	max: number?,
}

export type Ops = {
	add: (any, any) -> any,
	sub: (any, any) -> any,
	mul: (any, any) -> any,
	div: (any, any) -> any,
	pow: (any, any) -> any,
	clamp: (any, any, any) -> any,
}

local NUMBER_OPS: Ops = {
	add = function(a: any, b: any): any
		return a + b
	end,
	sub = function(a: any, b: any): any
		return a - b
	end,
	mul = function(a: any, b: any): any
		return a * b
	end,
	div = function(a: any, b: any): any
		return a / b
	end,
	pow = function(a: any, exponent: any): any
		return a ^ exponent
	end,
	clamp = function(a: any, minValue: any, maxValue: any): any
		return math.clamp(a, minValue, maxValue)
	end,
}

local PRECEDENCE: { [OpKind]: number } = {
	add = 1,
	sub = 1,
	mul = 2,
	div = 2,
	pow = 3,
	clamp = 4,
}

local SYMBOL: { [OpKind]: string } = {
	add = " + ",
	sub = " - ",
	mul = " * ",
	div = " / ",
	pow = " ^ ",
}

-- ============================== construction ================================

local FormulaClass = {}
FormulaClass.__index = FormulaClass

export type Formula = typeof(setmetatable({} :: { ops: { Op }, impl: Ops }, FormulaClass))

-- table.clone of the ops array still shares each operation table. A later
-- write to f.ops[i].value would change every formula derived from f.
local function deepCopy(value: any, seen: { [any]: any }): any
	if type(value) ~= "table" then
		return value
	end
	if seen[value] then
		return seen[value]
	end
	local copy = {}
	seen[value] = copy
	for key, item in value :: { [any]: any } do
		copy[key] = deepCopy(item, seen)
	end
	return copy
end

local function extended(self: Formula, op: Op): Formula
	local copied = deepCopy(self.ops, {})
	table.insert(copied, op)
	return setmetatable({ ops = copied, impl = self.impl }, FormulaClass)
end

function Formula.start(base: Formula?, ops: Ops?): Formula
	local chain: { Op } = {}
	local impl = ops or NUMBER_OPS
	if base ~= nil then
		chain = deepCopy(base.ops, {})
		impl = ops or base.impl
	end
	return setmetatable({ ops = chain, impl = impl }, FormulaClass)
end

function Formula.adapt(mod: any): Ops
	local function lift(operand: any): any
		if type(operand) == "number" then
			return mod.new(operand)
		end
		return operand
	end
	return {
		add = function(a: any, b: any): any
			return mod.add(a, lift(b))
		end,
		sub = function(a: any, b: any): any
			return mod.sub(a, lift(b))
		end,
		mul = function(a: any, b: any): any
			return mod.mul(a, lift(b))
		end,
		div = function(a: any, b: any): any
			return mod.div(a, lift(b))
		end,
		pow = function(a: any, exponent: any): any
			return mod.powInt(a, exponent)
		end,
		clamp = function(a: any, minValue: any, maxValue: any): any
			if mod.compare(a, lift(minValue)) < 0 then
				return lift(minValue)
			end
			if mod.compare(a, lift(maxValue)) > 0 then
				return lift(maxValue)
			end
			return a
		end,
	}
end

-- ================================ chaining ===================================

function FormulaClass.add(self: Formula, value: number): Formula
	return extended(self, { kind = "add", value = value })
end

function FormulaClass.sub(self: Formula, value: number): Formula
	return extended(self, { kind = "sub", value = value })
end

function FormulaClass.mul(self: Formula, value: number): Formula
	return extended(self, { kind = "mul", value = value })
end

function FormulaClass.div(self: Formula, value: number): Formula
	return extended(self, { kind = "div", value = value })
end

function FormulaClass.pow(self: Formula, value: number): Formula
	return extended(self, { kind = "pow", value = value })
end

function FormulaClass.clamp(self: Formula, minValue: number, maxValue: number): Formula
	return extended(self, { kind = "clamp", min = minValue, max = maxValue })
end

-- =============================== evaluation ==================================

function FormulaClass.apply(self: Formula, x: any): any
	local acc = x
	for _, op in self.ops do
		if op.kind == "add" then
			acc = self.impl.add(acc, op.value)
		elseif op.kind == "sub" then
			acc = self.impl.sub(acc, op.value)
		elseif op.kind == "mul" then
			acc = self.impl.mul(acc, op.value)
		elseif op.kind == "div" then
			acc = self.impl.div(acc, op.value)
		elseif op.kind == "pow" then
			acc = self.impl.pow(acc, op.value)
		elseif op.kind == "clamp" then
			acc = self.impl.clamp(acc, op.min, op.max)
		end
	end
	return acc
end

-- ================================ rendering ==================================

local function renderValue(value: number): string
	if value == math.floor(value) and math.abs(value) < 1e15 then
		return string.format("%d", value)
	end
	return tostring(value)
end

function FormulaClass.render(self: Formula): string
	local text = "x"
	local bound = 4
	for _, op in self.ops do
		local precedence = PRECEDENCE[op.kind]
		if op.kind == "clamp" then
			text = string.format(
				"clamp(%s, %s, %s)",
				text,
				renderValue(op.min :: number),
				renderValue(op.max :: number)
			)
			bound = 4
		else
			if precedence > bound then
				text = "(" .. text .. ")"
			end
			text = text .. SYMBOL[op.kind] .. renderValue(op.value :: number)
			bound = precedence
		end
	end
	return text
end

return Formula
