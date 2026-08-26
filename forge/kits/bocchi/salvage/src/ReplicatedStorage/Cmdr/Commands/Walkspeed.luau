return {
	Name = "walkspeed";
	Aliases = {"ws"};
	Description = "Set walkspeed of a player.";
	Group = "Admin";
	Args = {
		{
			Type = "player";
			Name = "player";
			Description = "Player";
		},
		{
			Type = "number";
			Name = "ws";
			Description = "Walkspeed to set";
		}
	};
}