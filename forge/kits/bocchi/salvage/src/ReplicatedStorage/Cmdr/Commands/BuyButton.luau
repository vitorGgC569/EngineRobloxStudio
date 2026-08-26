return {
	Name = "buybutton";
	Aliases = {"bb"};
	Description = "Buy a button.";
	Group = "Admin";
	Args = {
		{
			Type = "string";
			Name = "id";
			Description = "Id of button";
		},
		{
			Type = "number";
			Name = "amount";
			Description = "Amount of times to set";
		}
	};
}