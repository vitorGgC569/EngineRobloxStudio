-- Compiled with roblox-ts v2.3.0
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AlyaNum = require(ReplicatedStorage.Packages.alyanum)

local ZERO = AlyaNum.new(0)

local Formula = {}
Formula.__index = Formula

function Formula.new(): Formula
	return setmetatable({
		operations = {}
	}, Formula)
end

function Formula.add(self: Formula, number: AlyaNum.Number)
	table.insert(self.operations, {type = "add", amount = AlyaNum.new(number)})
	return self
end

function Formula.sub(self: Formula, number: AlyaNum.Number)
	table.insert(self.operations, {type = "sub", amount = AlyaNum.new(number)})
	return self
end

function Formula.mul(self: Formula, number: AlyaNum.Number)
	table.insert(self.operations, {type = "mul", amount = AlyaNum.new(number)})
	return self
end

function Formula.div(self: Formula, number: AlyaNum.Number)
	table.insert(self.operations, {type = "div", amount = AlyaNum.new(number)})
	return self
end

function Formula.pow(self: Formula, number: AlyaNum.Number)
	table.insert(self.operations, {type = "pow", amount = AlyaNum.new(number)})
	return self
end

function Formula.log(self: Formula, number: AlyaNum.Number)
	table.insert(self.operations, {type = "log", base = AlyaNum.new(number)})
	return self
end

function Formula.apply(self: Formula, number: AlyaNum.AlyaNum): AlyaNum.AlyaNum
	number = AlyaNum.new(number)
	for _, operation in pairs(self.operations) do
		local type = operation.type
		if type == "add" then
			number = number:add(operation.amount)
		elseif type == "sub" then
			number = number:sub(operation.amount)
		elseif type == "mul" then
			number = number:mul(operation.amount)
		elseif type == "div" then
			number = number:div(operation.amount)
		elseif type == "pow" then
			number = number:pow(operation.amount)
		elseif type == "log" then
			number = number:log(operation.base) or ZERO
		end
	end
	return number
end

function Formula.toString(self: Formula, nameOfX: string)
	for _, operation in self.operations do
		local _exp = operation.type
		repeat
			if _exp == "add" then
				nameOfX ..= " + " .. tostring(operation.amount)
				break
			end
			if _exp == "sub" then
				nameOfX ..= " - " .. tostring(operation.amount)
				break
			end
			if _exp == "mul" then
				nameOfX ..= " * " .. tostring(operation.amount)
				break
			end
			if _exp == "div" then
				nameOfX ..= " / " .. tostring(operation.amount)
				break
			end
			if _exp == "pow" then
				nameOfX ..= " ^ " .. tostring(operation.amount)
				break
			end
			if _exp == "log" then
				nameOfX = "log" .. tostring(operation.base) .. "(" .. nameOfX .. ")"
				break
			end
		until true
	end
	return nameOfX
end

export type Formula = typeof(setmetatable({} :: {operations: {{type: string, amount: AlyaNum.AlyaNum?, base: number?}}}, Formula))

return Formula
