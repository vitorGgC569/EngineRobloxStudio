--!strict
-- First-time onboarding overlay. Shows once (server persists seenTutorial) on a new
-- player's first join, walking through the premise, roles, and controls. Control hints
-- adapt to touch vs keyboard/mouse. Dismissing fires MarkTutorialSeen.
--
-- Must register with MenuState so CameraController releases mouse lock — otherwise the
-- cursor stays locked at screen centre and NEXT/PLAY can never be clicked (desktop).

local UserInputService = game:GetService("UserInputService")

local Theme = require(script.Parent.Theme)
local MenuState = require(script.Parent.MenuState)

local Tutorial = {}

function Tutorial.start(remotes: any)
	local touch = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
	local fireHint = touch and "the FIRE button" or "left-click"
	local sprintHint = touch and "the SPRINT button" or "hold Shift"
	local knifeHint = touch and "the KNIFE button" or "press F"

	local slides = {
		{
			title = "WELCOME TO INFECTED",
			body = "30 players. One is secretly Patient Zero. Survive the round — or spread the infection.",
		},
		{
			title = "IF YOU'RE A SURVIVOR",
			body = ("You have a real gun. Shoot zombies (%s) and %s to escape them. But watch your back — anyone could be the hidden Patient Zero."):format(
				fireHint,
				sprintHint
			),
		},
		{
			title = "IF YOU'RE PATIENT ZERO",
			body = ("You look like a survivor — blend in. Throw your one-hit knife with %s to convert people without being caught."):format(
				knifeHint
			),
		},
		{
			title = "GET TURNED?",
			body = "You respawn as a zombie and hunt the survivors with the horde. Last survivor standing wins it for the humans.",
		},
		{
			title = "EARN & UNLOCK",
			body = "Coins, XP and levels unlock skins from crates. Claim daily rewards and quests for keys. Now — good luck out there.",
		},
	}

	local gui = Theme.screenGui("Tutorial", 100)
	-- Modal so other GUI (and the locked combat camera path) cannot steal focus while open.
	gui.DisplayOrder = 100

	local dimmer = Theme.frame(gui, {
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundColor3 = Color3.fromRGB(0, 0, 0),
		BackgroundTransparency = 0.35,
		Visible = false,
		Active = true, -- sink clicks so the world behind is not interactable
	})
	-- Releases mouse lock while the overlay is open (same path shop/settings use).
	MenuState.track(dimmer)

	local panel = Theme.frame(dimmer, {
		Size = UDim2.new(0, 460, 0, 300),
		Position = UDim2.new(0.5, -230, 0.5, -150),
		BackgroundColor3 = Theme.Colors.Panel,
		Active = true,
	})
	Theme.corner(panel, 16)
	local stroke = Instance.new("UIStroke")
	stroke.Color = Theme.Colors.Infected
	stroke.Thickness = 2
	stroke.Parent = panel

	local title = Theme.label(panel, {
		Size = UDim2.new(1, -32, 0, 40),
		Position = UDim2.new(0, 16, 0, 20),
		Text = "",
		TextSize = 26,
		TextColor3 = Theme.Colors.Infected,
	})
	local body = Theme.label(panel, {
		Size = UDim2.new(1, -40, 0, 120),
		Position = UDim2.new(0, 20, 0, 70),
		Text = "",
		TextSize = 18,
		TextColor3 = Theme.Colors.Text,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
	})
	local dots = Theme.label(panel, {
		Size = UDim2.new(0, 200, 0, 20),
		Position = UDim2.new(0, 20, 1, -52),
		Text = "",
		TextSize = 16,
		TextColor3 = Theme.Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	local skipBtn = Theme.button(panel, {
		Size = UDim2.new(0, 100, 0, 44),
		Position = UDim2.new(0, 16, 1, -58),
		Text = "SKIP",
		TextSize = 16,
		BackgroundColor3 = Theme.Colors.PanelLight,
		TextColor3 = Theme.Colors.TextDim,
	})
	local nextBtn = Theme.button(panel, {
		Size = UDim2.new(0, 140, 0, 44),
		Position = UDim2.new(1, -156, 1, -58),
		Text = "NEXT",
		TextSize = 18,
		BackgroundColor3 = Theme.Colors.Infected,
		TextColor3 = Theme.Colors.Bg,
	})
	-- Prefer Activated (mouse + touch + gamepad) over MouseButton1Click alone.
	nextBtn.AutoButtonColor = true
	skipBtn.AutoButtonColor = true

	local index = 1
	local function renderSlide()
		local slide = slides[index]
		title.Text = slide.title
		body.Text = slide.body
		dots.Text = ("%d / %d"):format(index, #slides)
		nextBtn.Text = index == #slides and "PLAY" or "NEXT"
	end

	local finished = false
	local function finish()
		if finished then
			return
		end
		finished = true
		remotes.fire("MarkTutorialSeen")
		dimmer.Visible = false
	end

	local function advance()
		if not dimmer.Visible or finished then
			return
		end
		if index >= #slides then
			finish()
		else
			index += 1
			renderSlide()
		end
	end

	nextBtn.Activated:Connect(advance)
	skipBtn.Activated:Connect(finish)

	-- Keyboard: Enter/Space advance, Escape skips the whole tutorial.
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed or not dimmer.Visible or finished then
			return
		end
		if input.KeyCode == Enum.KeyCode.Return or input.KeyCode == Enum.KeyCode.Space then
			advance()
		elseif input.KeyCode == Enum.KeyCode.Escape then
			finish()
		end
	end)

	local shown = false
	remotes.on("ProfileSync", function(profile)
		if shown or finished then
			return
		end
		-- Treat missing/false the same: only skip when the server has recorded true.
		if profile.seenTutorial ~= true then
			shown = true
			index = 1
			renderSlide()
			dimmer.Visible = true
		end
	end)

	return {}
end

return Tutorial
