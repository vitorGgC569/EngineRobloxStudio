return function (context, player: Player, ws: number)
	player.Character:FindFirstChildOfClass("Humanoid").WalkSpeed = ws
end