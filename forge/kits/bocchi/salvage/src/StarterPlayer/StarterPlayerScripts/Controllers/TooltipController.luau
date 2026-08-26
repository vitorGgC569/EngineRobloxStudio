--!optimize 2

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local constants = require(ReplicatedStorage.constants)
local Lumin = require(ReplicatedStorage.Packages.framework)

local TooltipController = {}
TooltipController.__index = TooltipController

local MOUSE = constants.MOUSE
local TOOLTIP_WINDOW = constants.INTERFACE.TooltipWindow

TooltipController.tooltipsPerObject = {}

function TooltipController:HideTooltipWindow()
	local tweenInfo = TweenInfo.new(0.2)
	local tween = TweenService:Create(TOOLTIP_WINDOW, tweenInfo, {
		BackgroundTransparency = 1,
	})
	TweenService:Create(TOOLTIP_WINDOW.MessageLabel, tweenInfo, {
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	}):Play()
	TweenService:Create(TOOLTIP_WINDOW.UIStroke, tweenInfo, {
		Transparency = 1,
	}):Play()
	tween:Play()
	tween.Completed:Connect(function()
		TOOLTIP_WINDOW.Visible = false
		return TOOLTIP_WINDOW.Visible
	end)
end

function TooltipController:ShowTooltipWindow()
	local tweenInfo = TweenInfo.new(0.2)
	TOOLTIP_WINDOW.Visible = true
	TweenService:Create(TOOLTIP_WINDOW, tweenInfo, {
		BackgroundTransparency = 0.5,
	}):Play()
	TweenService:Create(TOOLTIP_WINDOW.UIStroke, tweenInfo, {
		Transparency = 0.5,
	}):Play()
	TweenService:Create(TOOLTIP_WINDOW.MessageLabel, tweenInfo, {
		TextTransparency = 0,
		TextStrokeTransparency = 0,
	}):Play()
end

function TooltipController:SetMessage(message: string)
	TOOLTIP_WINDOW.MessageLabel.Text = message
end

function TooltipController:SetTooltip(guiObject: GuiObject, message: string)
	if not (TooltipController.tooltipsPerObject[guiObject] ~= nil) then
		guiObject.MouseMoved:Connect(function()
			TooltipController:ShowTooltipWindow()
			TooltipController:SetMessage(TooltipController.tooltipsPerObject[guiObject] or "")
		end)
		guiObject.MouseEnter:Connect(function()
			TooltipController:ShowTooltipWindow()
		end)
		guiObject.MouseLeave:Connect(function()
			TooltipController:HideTooltipWindow()
		end)
	end
	TooltipController.tooltipsPerObject[guiObject] = message
end

function TooltipController:Start()
	RunService.Heartbeat:Connect(function()
		local canvasSize = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize
		if canvasSize ~= nil then
			TOOLTIP_WINDOW.AnchorPoint = Vector2.new(if canvasSize.X - MOUSE.X < 200 then 1 else 0, if canvasSize.Y - MOUSE.Y < 200 then 1 else 0)
			TOOLTIP_WINDOW.Position = UDim2.fromOffset(MOUSE.X + 5, MOUSE.Y + 36)
		end
	end)
end

export type TooltipController = typeof(TooltipController)

return TooltipController