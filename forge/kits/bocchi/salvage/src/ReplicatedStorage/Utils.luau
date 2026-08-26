local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Balance = require(ReplicatedStorage.Balance)
local Currency = require(ReplicatedStorage.Currency)
local AlyaNum = require(ReplicatedStorage.Packages.alyanum)

--- @class Utils
--- Utility object for ease of creating new content.
local Utils = {}

Utils.Playtime = 0
Utils.SessionTime = 0

Utils.Currencies = {} :: Balance.Balance
Utils.Buttons = {} :: {[string]: number}

Utils.DoubleBocchiPass = {
	Enabled = false,
	Id = 132326138689490,
}

return Utils
