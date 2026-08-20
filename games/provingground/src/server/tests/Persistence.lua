--!strict
--[[
	Save and economy scenarios, against the real services.

	These are the ones that were impossible to write before. `Save` calls
	`DataStoreService`, migrates versions and checksums its payloads, and none
	of that had ever executed — it was code that looked correct. Studio talks to
	the real DataStore service when API access is enabled for the place, so
	these are real round trips: written, read back, corrupted on purpose,
	rolled back.

	If API access is off, these scenarios say so and fail rather than passing
	quietly. A persistence suite that skips itself when it cannot reach storage
	is a suite that is green precisely when you most need it not to be.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Save = Forge.Save
local Monetization = Forge.Monetization
local LiveOps = Forge.LiveOps

local TEST_STORE = "ForgeSuite_Persistence"

return function(Testing)
	Testing.scenario("the DataStore is actually reachable", function(t)
		local ok, err = pcall(function()
			local store = DataStoreService:GetDataStore(TEST_STORE)
			store:SetAsync("reachability", { at = os.time() })
			return store:GetAsync("reachability")
		end)
		t:expect(ok, "no DataStore access: enable API services for this place ("
			.. tostring(err) .. ")")
	end, { timeout = 30 })

	Testing.scenario("a profile survives a write and a read", function(t)
		local store = DataStoreService:GetDataStore(TEST_STORE)
		local key = "profile_" .. tostring(math.random(1, 1e9))

		local written = { score = 4200, kills = 17, __version = 1 }
		local ok = pcall(function()
			store:SetAsync(key, written)
		end)
		t:expect(ok, "the write failed")

		local read
		local readOk = pcall(function()
			read = store:GetAsync(key)
		end)
		t:expect(readOk and typeof(read) == "table", "the read came back empty")
		if typeof(read) == "table" then
			t:expectEqual(read.score, 4200, "score did not survive the round trip")
			t:expectEqual(read.kills, 17, "kills did not survive the round trip")
		end

		pcall(function()
			store:RemoveAsync(key)
		end)
	end, { timeout = 40 })

	Testing.scenario("a corrupted payload is refused, not loaded", function(t)
		--[[
			The check that matters most and is hardest to trigger by playing.

			A save that fails its checksum has to be treated as absent, because
			loading half a profile is worse than loading none: the player keeps
			their level and loses their inventory, and no support ticket ever
			explains that.
		]]
		local store = DataStoreService:GetDataStore(TEST_STORE)
		local key = "corrupt_" .. tostring(math.random(1, 1e9))

		local ok = pcall(function()
			store:SetAsync(key, {
				score = 999999,
				__version = 1,
				__checksum = "definitely-not-the-right-checksum",
			})
		end)
		t:expect(ok, "could not stage the corrupt payload")

		local verified = Save.verify(store:GetAsync(key))
		t:expect(verified == false,
			"a payload with a wrong checksum was accepted")

		pcall(function()
			store:RemoveAsync(key)
		end)
	end, { timeout = 40 })

	Testing.scenario("an update is atomic under contention", function(t)
		--[[
			Two writers, one key.

			`SetAsync` loses one of these; `UpdateAsync` must not. This is the
			exact shape of the bug that costs players their purchases — two
			servers granting from the same balance, one overwriting the other.
		]]
		local store = DataStoreService:GetDataStore(TEST_STORE)
		local key = "atomic_" .. tostring(math.random(1, 1e9))

		pcall(function()
			store:SetAsync(key, { count = 0 })
		end)

		local done = 0
		for _ = 1, 4 do
			task.spawn(function()
				pcall(function()
					store:UpdateAsync(key, function(old)
						old = old or { count = 0 }
						old.count += 1
						return old
					end)
				end)
				done += 1
			end)
		end

		t:expect(t:waitUntil(function()
			return done >= 4
		end, 25), "the concurrent updates never finished")

		local final
		pcall(function()
			final = store:GetAsync(key)
		end)
		t:expect(typeof(final) == "table", "could not read the result back")
		if typeof(final) == "table" then
			t:expectEqual(final.count, 4, "an update was lost under contention")
		end

		pcall(function()
			store:RemoveAsync(key)
		end)
	end, { timeout = 60 })

	Testing.scenario("a receipt granted twice only pays once", function(t)
		--[[
			Roblox retries `ProcessReceipt` until it is told the grant is done,
			so the same purchase arrives more than once as a matter of routine.
			Granting per delivery instead of per receipt id is the difference
			between selling a sword and giving it away.
		]]
		local granted = 0
		Monetization.defineProduct("SuiteTestProduct", {
			productId = 9999001,
			grant = function()
				granted += 1
			end,
		})

		--[[
			A real player id, because the handler correctly refuses a fake one.

			The first version of this used `PlayerId = 1` and reported zero
			grants, which read like a broken transaction and was in fact the
			engine being right: `processReceipt` looks the player up and, if
			they are not here, declines to grant so Roblox retries when they
			come back. Testing against an absent player tests the absence.
		]]
		local subject = Players:GetPlayers()[1]
		if not subject then
			t:expect(false, "no player in the session to deliver a receipt to")
			return
		end

		local receiptId = "suite-" .. tostring(math.random(1, 1e9))
		local fakeReceipt = {
			PurchaseId = receiptId,
			ProductId = 9999001,
			PlayerId = subject.UserId,
			CurrencySpent = 0,
		}

		local first = Monetization.processReceipt(fakeReceipt)
		local second = Monetization.processReceipt(fakeReceipt)

		t:expect(first ~= nil, "processReceipt is not reachable")
		--[[
			Zero grants here is usually not a transaction bug.

			`processReceipt` refuses to grant when it has no receipt store, and
			it is right to: granting without a durable record means granting
			again on the next retry. In an unpublished place there is no store,
			so this scenario is really reporting the same missing DataStore as
			the four above it.
		]]
		t:expectEqual(granted, 1, granted == 0
			and "no grant happened -- most likely no receipt store, which needs "
				.. "a published place; the refusal itself is correct"
			or ("the same receipt granted " .. granted .. " times"))
		t:expect(second ~= nil, "a repeated receipt must still be acknowledged")
	end, { timeout = 40 })

	Testing.scenario("experiment buckets are stable for a player", function(t)
		LiveOps.experiment("suite_bucket_check", { "control", "variant" })

		-- A fake player id is enough: the whole point is that the assignment
		-- is a pure function of the id, so no real session is involved.
		local fake = { UserId = 8675309 }
		local first = LiveOps.bucket(fake :: any, "suite_bucket_check")
		local again = LiveOps.bucket(fake :: any, "suite_bucket_check")

		t:expect(first ~= nil, "the experiment returned no arm")
		t:expectEqual(again, first, "the same player landed in two different arms")

		local other = LiveOps.bucket({ UserId = 111222 } :: any, "suite_bucket_check")
		t:expect(other ~= nil, "a second player got no arm at all")
	end)

	Testing.scenario("config falls back to defaults rather than failing", function(t)
		LiveOps.define("suite.number", 7)
		t:expectEqual(LiveOps.get("suite.number"), 7, "the default did not come back")

		LiveOps.set("suite.number", 12)
		t:expectEqual(LiveOps.get("suite.number"), 12, "the override did not take")

		-- A push of the wrong type must not reach gameplay code.
		LiveOps.set("suite.number", "twelve")
		t:expectEqual(LiveOps.get("suite.number"), 7,
			"a string overwrote a number-typed config value")
	end)
end
