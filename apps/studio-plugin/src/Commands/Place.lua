--!strict
-- Native place persistence through AssetService.
--
-- This command is deliberately fail-closed: saving overwrites place state and
-- publishing changes what players can receive. Both require explicit consent,
-- and publishing requires a second, distinct opt-in.

local AssetService = game:GetService("AssetService")
local RunService = game:GetService("RunService")

local Errors = require(script.Parent.Parent.Errors)

local PlaceCommands = {}

local function positiveInteger(value: any, name: string): number?
	if value == nil then
		return nil
	end
	local numeric = tonumber(value)
	if not numeric or numeric % 1 ~= 0 or numeric <= 0 then
		Errors.raise(Errors.BAD_PARAMS, name .. " must be a positive integer")
	end
	return numeric
end

function PlaceCommands.save(params: { [string]: any }): any
	if RunService:IsRunning() then
		Errors.raise(
			Errors.UNSUPPORTED_CONTEXT,
			"studio.save_place is edit-mode only"
		)
	end

	if params.confirmOverwrite ~= true then
		Errors.raise(
			Errors.BAD_PARAMS,
			"confirmOverwrite=true is required because saving overwrites place state"
		)
	end

	local saveWithoutPublish = params.saveWithoutPublish ~= false
	if not saveWithoutPublish and params.confirmPublish ~= true then
		Errors.raise(
			Errors.BAD_PARAMS,
			"confirmPublish=true is required when saveWithoutPublish=false"
		)
	end

	local placeId = positiveInteger(params.placeId, "placeId")
	if placeId == nil and game.PlaceId <= 0 then
		Errors.raise(
			Errors.BAD_PARAMS,
			"the current DataModel has no published PlaceId; provide an explicit placeId"
		)
	end

	local request: { [string]: any } = {
		SaveWithoutPublish = saveWithoutPublish,
	}
	if placeId ~= nil then
		request.PlaceId = placeId
	end

	local ok, err = pcall(function()
		AssetService:SavePlaceAsync(request)
	end)
	if not ok then
		Errors.raise(
			Errors.EXEC,
			"AssetService:SavePlaceAsync failed: " .. tostring(err)
		)
	end

	return {
		saved = true,
		published = not saveWithoutPublish,
		saveWithoutPublish = saveWithoutPublish,
		placeId = placeId or game.PlaceId,
		source = "AssetService.SavePlaceAsync",
	}
end

local function requireEditMode(commandName: string)
	if RunService:IsRunning() then
		Errors.raise(
			Errors.UNSUPPORTED_CONTEXT,
			commandName .. " is edit-mode only"
		)
	end
end

function PlaceCommands.list(params: { [string]: any }): any
	requireEditMode("studio.list_places")

	local maxPages = tonumber(params.maxPages) or 5
	local maxPlaces = tonumber(params.maxPlaces) or 200
	if maxPages % 1 ~= 0 or maxPages < 1 or maxPages > 20 then
		Errors.raise(Errors.BAD_PARAMS, "maxPages must be an integer between 1 and 20")
	end
	if maxPlaces % 1 ~= 0 or maxPlaces < 1 or maxPlaces > 1000 then
		Errors.raise(Errors.BAD_PARAMS, "maxPlaces must be an integer between 1 and 1000")
	end

	local ok, pagesOrError = pcall(function()
		return AssetService:GetGamePlacesAsync()
	end)
	if not ok then
		Errors.raise(
			Errors.EXEC,
			"AssetService:GetGamePlacesAsync failed: " .. tostring(pagesOrError)
		)
	end

	local pages = pagesOrError
	local places = {}
	local pageCount = 0
	local truncated = false

	while pageCount < maxPages and #places < maxPlaces do
		pageCount += 1
		local page = pages:GetCurrentPage()
		for _, item in ipairs(page) do
			if #places >= maxPlaces then
				truncated = true
				break
			end
			table.insert(places, {
				placeId = tonumber(item.PlaceId or item.Id or item.id) or 0,
				name = tostring(item.Name or item.name or ""),
				description = tostring(item.Description or item.description or ""),
			})
		end

		if pages.IsFinished then
			break
		end
		if pageCount >= maxPages or #places >= maxPlaces then
			truncated = true
			break
		end

		local advanced, advanceError = pcall(function()
			pages:AdvanceToNextPageAsync()
		end)
		if not advanced then
			Errors.raise(
				Errors.EXEC,
				"could not advance experience places page: " .. tostring(advanceError)
			)
		end
	end

	return {
		places = places,
		count = #places,
		pages = pageCount,
		truncated = truncated,
		source = "AssetService.GetGamePlacesAsync",
	}
end

function PlaceCommands.create(params: { [string]: any }): any
	requireEditMode("studio.create_place")

	if params.confirmCreate ~= true then
		Errors.raise(
			Errors.BAD_PARAMS,
			"confirmCreate=true is required because creating a place mutates the Roblox experience"
		)
	end

	local name = params.name
	if type(name) ~= "string" or name == "" or string.match(name, "^%s*$") then
		Errors.raise(Errors.BAD_PARAMS, "name must be a non-empty string")
	end
	if #name > 100 then
		Errors.raise(Errors.BAD_PARAMS, "name must be at most 100 characters")
	end

	local templatePlaceId = positiveInteger(params.templatePlaceId, "templatePlaceId")
	if templatePlaceId == nil then
		Errors.raise(Errors.BAD_PARAMS, "templatePlaceId is required")
	end

	local description = params.description or ""
	if type(description) ~= "string" then
		Errors.raise(Errors.BAD_PARAMS, "description must be a string")
	end
	if #description > 1000 then
		Errors.raise(Errors.BAD_PARAMS, "description must be at most 1000 characters")
	end

	local ok, placeIdOrError = pcall(function()
		return AssetService:CreatePlaceAsync(name, templatePlaceId, description)
	end)
	if not ok then
		Errors.raise(
			Errors.EXEC,
			"AssetService:CreatePlaceAsync failed: " .. tostring(placeIdOrError)
		)
	end

	return {
		created = true,
		placeId = placeIdOrError,
		name = name,
		templatePlaceId = templatePlaceId,
		source = "AssetService.CreatePlaceAsync",
	}
end

return PlaceCommands
