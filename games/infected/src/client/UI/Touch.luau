--!strict
-- Mobile touch controls: FIRE / THROW / SPRINT / RELOAD buttons, shown only on
-- touch devices without a mouse. Role-aware (throw only shows for Patient Zero).

local UserInputService = game:GetService("UserInputService")

local Theme = require(script.Parent.Theme)

local Touch = {}

function Touch.start(
	remotes: any,
	actions: {
		fire: () -> (),
		throwKnife: () -> (),
		melee: () -> (),
		reload: () -> (),
		setSprint: (on: boolean) -> (),
	}
)
	-- Any touch-capable device gets the buttons (tablets with mice and Studio's
	-- Device Emulator report both touch AND mouse; requiring mouse-absence hid
	-- the controls there).
	if not UserInputService.TouchEnabled then
		return {}
	end

	local gui = Theme.screenGui("TouchControls", 3)
	local role = "NONE"

	local function makeButton(text: string, position: UDim2, size: number?): TextButton
		local button = Theme.button(gui, {
			Size = UDim2.new(0, size or 72, 0, size or 72),
			Position = position,
			Text = text,
			TextSize = 13,
			BackgroundTransparency = 0.35,
		})
		Theme.corner(button, (size or 72) // 2)
		return button
	end

	local fire = makeButton("FIRE", UDim2.new(1, -100, 1, -190), 84)
	local throwBtn = makeButton("THROW", UDim2.new(1, -196, 1, -150))
	local reload = makeButton("RELOAD", UDim2.new(1, -100, 1, -290))
	local sprint = makeButton("SPRINT", UDim2.new(0, 24, 1, -160))

	-- Held-trigger parity with mouse and keyboard: tapping used to be the only way to fire,
	-- which made automatic weapons unusable on a phone.
	fire.MouseButton1Down:Connect(function()
		if role == "ZOMBIE" then
			actions.melee()
		else
			actions.setFiring(true)
		end
	end)
	fire.MouseButton1Up:Connect(function()
		actions.setFiring(false)
	end)
	-- A drag that leaves the button still counts as letting go of the trigger.
	fire.MouseLeave:Connect(function()
		actions.setFiring(false)
	end)
	throwBtn.Activated:Connect(function()
		if role == "PATIENT_ZERO" then
			actions.throwKnife()
		else
			actions.melee()
		end
	end)
	reload.Activated:Connect(actions.reload)

	local sprinting = false
	sprint.Activated:Connect(function()
		sprinting = not sprinting
		actions.setSprint(sprinting)
		sprint.BackgroundColor3 = sprinting and Theme.Colors.Survivor or Theme.Colors.PanelLight
	end)

	remotes.on("RoleAssigned", function(payload)
		role = payload.role
		throwBtn.Visible = role == "PATIENT_ZERO" or role == "ZOMBIE"
		fire.Text = if role == "ZOMBIE" then "CLAW" else "FIRE"
		reload.Visible = role == "SURVIVOR" or role == "PATIENT_ZERO"
	end)

	return {}
end

return Touch
