--!strict
-- Friend invites: an INVITE button that opens Roblox's native game-invite prompt so a
-- solo player can pull friends into their server. Uses SocialService; pcall-guarded and
-- hidden if invites aren't available on the platform/session.

local SocialService = game:GetService("SocialService")
local Players = game:GetService("Players")

local Theme = require(script.Parent.Theme)

local Social = {}

function Social.start(_remotes: any)
	local gui = Theme.screenGui("Social", 10)
	local LocalPlayer = Players.LocalPlayer

	local button = Theme.button(gui, {
		Size = UDim2.new(0, 120, 0, 40),
		Position = UDim2.new(0, 390, 1, -104),
		Text = "+ INVITE",
		TextSize = 16,
		BackgroundColor3 = Theme.Colors.Survivor,
		TextColor3 = Theme.Colors.Bg,
		Visible = false,
	})

	-- Only show the button if the platform can send invites.
	task.spawn(function()
		local ok, canInvite = pcall(function()
			return SocialService:CanSendGameInviteAsync(LocalPlayer)
		end)
		button.Visible = ok and canInvite == true
	end)

	button.Activated:Connect(function()
		pcall(function()
			SocialService:PromptGameInvite(LocalPlayer)
		end)
	end)

	return {}
end

return Social
