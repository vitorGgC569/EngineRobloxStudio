local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ByteNet = require(ReplicatedStorage.Packages.bytenet)

local Packets = ByteNet.defineNamespace("mossupgradetree", function()
	local BaseAlyaNum = ByteNet.struct({
		sign = ByteNet.float64,
		multiplicand = ByteNet.float64,
		exponent = ByteNet.float64,
		tetrate = ByteNet.float64,
		pentate = ByteNet.float64,
		hexate = ByteNet.float64,
		heptate = ByteNet.float64,
	})
	return {
		changeCurrencies = ByteNet.definePacket({
			reliabilityType = "unreliable",
			value = ByteNet.map(ByteNet.string, BaseAlyaNum)
		}),
		changeIncome = ByteNet.definePacket({
			reliabilityType = "unreliable",
			value = ByteNet.map(ByteNet.string, BaseAlyaNum)
		}),
		buyButton = ByteNet.definePacket({
			reliabilityType = "reliable",
			value = ByteNet.struct({
				button = ByteNet.string
			})
		}),
		buttonBought = ByteNet.definePacket({
			reliabilityType = "reliable",
			value = ByteNet.struct({
				button = ByteNet.string,
				difficulty = ByteNet.string
			})
		}),
		cubeClicked = ByteNet.definePacket({
			reliabilityType = "unreliable",
			value = ByteNet.nothing
		}),
		changeTime = ByteNet.definePacket({
			reliabilityType = "unreliable",
			value = ByteNet.struct({
				sessionTime = ByteNet.int32,
				playTime = ByteNet.int32
			})
		}),
		error = ByteNet.definePacket({
			reliabilityType = "unreliable",
			value = ByteNet.string
		}),
		testPacket = ByteNet.definePacket({
			value = ByteNet.struct({
				message = ByteNet.string
			})
		})
	}
end)

return Packets