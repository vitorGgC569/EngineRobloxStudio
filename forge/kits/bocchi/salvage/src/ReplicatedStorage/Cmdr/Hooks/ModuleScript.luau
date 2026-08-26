return function (registry)
	registry:RegisterHook("BeforeRun", function(context)
		local permLevel = context.Executor:GetAttribute("PermissionLevel")
		local errorMsg = "You don't have permission to run this command"
		if (context.Group == "DefaultDebug" and permLevel < 4) then
			return errorMsg
		end
		if (context.Group == "DefaultAdmin" and permLevel < 3) then
			return errorMsg
		end
	end)
end