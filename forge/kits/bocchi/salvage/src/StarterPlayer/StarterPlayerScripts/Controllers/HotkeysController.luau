--!optimize 2

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Lumin = require(ReplicatedStorage.Packages.framework)
local TooltipController = require(script.Parent.TooltipController)

local HotkeysController = {}
HotkeysController.__index = HotkeysController

HotkeysController.bindedKeys = {}
HotkeysController.connections = {}
HotkeysController.bindsDisabled = false
HotkeysController.index = 0


function HotkeysController:Execute(hotkey: Enum.KeyCode)
	for _, binded in HotkeysController.bindedKeys do
		if hotkey == binded.hotkey and binded.action() then
			return nil
		end
	end
end

function HotkeysController:Tooltip(button: GuiButton, keyCode: Enum.KeyCode, label: string)
	local l = button:GetAttribute("Tooltip")
	if l == nil then
		l = (if label == nil then (if button:IsA("TextButton") then button.Text else button.Name) else label)
		button:SetAttribute("Tooltip", l)
	end
	TooltipController:SetTooltip(button, `{l} ({keyCode.Name})`)
	return l
end

function HotkeysController:SetHotkey(button: GuiButton, keyCode: Enum.KeyCode, action: () -> (), label: string, priority: number)
	local l = HotkeysController:Tooltip(button, keyCode, label)
	HotkeysController:BindKey(keyCode, action, priority, l, button)
	if not (HotkeysController.connections[button] ~= nil) then
		local connection = button.Activated:Connect(action)
		HotkeysController.connections[button] = connection
		button.Destroying:Once(function()
			connection:Disconnect()
			HotkeysController.connections[button] = nil
		end)
	end
end

function HotkeysController:BindKey(keyCode: Enum.KeyCode, action: () -> (), priority: number, name: string, button: GuiButton)
	local object = {
		hotkey = keyCode,
		action = action,
		priority = priority or 0,
		name = name
	}
	HotkeysController.index += 1
	object.index = HotkeysController.index
	object.button = button
	local bindedKeys = HotkeysController.bindedKeys
	table.insert(bindedKeys, object)
	bindedKeys = table.sort(bindedKeys, function(a, b)
		return a.priority > b.priority
	end)
end

function HotkeysController:Init()
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed == true or HotkeysController.bindsDisabled == true then
			return nil
		end
		HotkeysController:Execute(input.KeyCode)
	end)
end


return HotkeysController