-- Server-only diagnostic relay for the Game Agent Bridge.
-- Keyboard, mouse and screenshots remain Studio/MCP responsibilities. This
-- relay exposes observation and white-box diagnostics without opening a
-- client-callable RemoteEvent that could mutate game state.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local bridgeFolder = ReplicatedStorage:FindFirstChild("QualityAgent")
if not bridgeFolder then
	bridgeFolder = Instance.new("Folder")
	bridgeFolder.Name = "QualityAgent"
	bridgeFolder.Parent = ReplicatedStorage
end

local request = bridgeFolder:FindFirstChild("QualityAgentRequest")
if not request then
	request = Instance.new("BindableFunction")
	request.Name = "QualityAgentRequest"
	request.Parent = bridgeFolder
end

local function getPlayer(playerUserId)
	if playerUserId then
		return Players:GetPlayerByUserId(playerUserId)
	end
	return Players:GetPlayers()[1]
end

local function observePlayer(player, mode)
	if not player then
		return { status = "FAIL", reason = "player_not_found" }
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local state = {
		mode = mode or "graybox",
		player = {
			position = root and { root.Position.X, root.Position.Y, root.Position.Z } or nil,
			health = humanoid and humanoid.Health or 0,
			velocity = root and { root.AssemblyLinearVelocity.X, root.AssemblyLinearVelocity.Y, root.AssemblyLinearVelocity.Z } or nil,
			grounded = humanoid and humanoid.FloorMaterial ~= Enum.Material.Air or false,
		},
		visibleUi = {},
		nearby = {},
		consoleErrors = {},
	}

	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if playerGui then
		for _, item in ipairs(playerGui:GetDescendants()) do
			if item:IsA("TextLabel") or item:IsA("TextButton") then
				table.insert(state.visibleUi, { name = item.Name, text = item.Text, visible = item.Visible })
			end
		end
	end

	if root then
		for _, item in ipairs(workspace:GetDescendants()) do
			if item:IsA("ProximityPrompt") and item.Parent:IsA("BasePart") then
				local distance = (item.Parent.Position - root.Position).Magnitude
				if distance <= item.MaxActivationDistance + 4 then
					table.insert(state.nearby, { type = "ProximityPrompt", name = item.Name, distance = distance, actionText = item.ActionText })
				end
			end
		end
	end

	if mode == "blackbox" then
		state.player = nil
	elseif mode == "whitebox" then
		state.diagnostics = { playerUserId = player.UserId, character = character and character:GetFullName() or nil }
	end
	return state
end

request.OnInvoke = function(payload)
	if type(payload) ~= "table" then
		return { status = "FAIL", reason = "payload_must_be_table" }
	end
	local command = payload.command or "observe"
	local player = getPlayer(payload.playerUserId)
	if command == "observe" then
		return observePlayer(player, payload.mode or "graybox")
	elseif command == "get_player" then
		local state = observePlayer(player, "graybox")
		return state.player
	elseif command == "get_ui" then
		return { visibleUi = observePlayer(player, payload.mode or "graybox").visibleUi }
	elseif command == "get_nearby" then
		return observePlayer(player, payload.mode or "graybox").nearby
	elseif command == "raycast" then
		local origin = Vector3.new(table.unpack(payload.origin or { 0, 0, 0 }))
		local direction = Vector3.new(table.unpack(payload.direction or { 0, -10, 0 }))
		local result = workspace:Raycast(origin, direction)
		return { hit = result ~= nil, instance = result and result.Instance:GetFullName() or nil, position = result and { result.Position.X, result.Position.Y, result.Position.Z } or nil }
	end
	return { status = "FAIL", reason = "unsupported_command", command = command }
end

