local PlotService = {}
PlotService.__index = PlotService

function PlotService.new(plotNames)
	local self = setmetatable({}, PlotService)
	self.plotNames = plotNames
	self.ownerByPlot = {}
	self.plotByUserId = {}
	return self
end

function PlotService:assign(player)
	if self.plotByUserId[player.UserId] then
		return self.plotByUserId[player.UserId]
	end

	for _, plotName in ipairs(self.plotNames) do
		if self.ownerByPlot[plotName] == nil then
			self.ownerByPlot[plotName] = player.UserId
			self.plotByUserId[player.UserId] = plotName
			return plotName
		end
	end

	return nil
end

function PlotService:release(player)
	local plotName = self.plotByUserId[player.UserId]
	if plotName then
		self.ownerByPlot[plotName] = nil
		self.plotByUserId[player.UserId] = nil
	end
end

function PlotService:isOwner(player, plotName)
	return self.ownerByPlot[plotName] == player.UserId
end

return PlotService

