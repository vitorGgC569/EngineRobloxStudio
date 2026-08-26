return {
	Name = "ecoset";
	Aliases = {"eset"};
	Description = "Sets the amount of the specified currency.";
	Group = "Admin";
	Args = {
		{
			Type = "string";
			Name = "currency";
			Description = "Currency to change";
		},
		{
			Type = "number";
			Name = "mantissa";
			Description = "Mantissa of the number (number = mantissa * 10^exponent)";
		},
		{
			Type = "number";
			Name = "exponent";
			Description = "Exponent of the number (number = mantissa * 10^exponent)";
		},
	};
}