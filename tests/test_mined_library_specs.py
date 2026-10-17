"""Behavioural specs for the modules mined from the licensed projects.

Executed as real Luau through the pinned runtime, not asserted against source.
Every one of these caught something the compiler did not: `TransactionJournal`
reached for `HttpService` while its own header claimed to be pure, and running
it said so in one line.

The cases chosen are the ones where being wrong is silent — a hold committed
twice, an achievement awarded twice, a cap that raises instead of limits, a
replication rule that defaults open. Those do not throw; they just quietly cost
somebody something.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestBoot(unittest.TestCase):
    def test_awaiting_something_already_signalled_returns_at_once(self) -> None:
        """The whole reason this is a latch and not a BindableEvent."""
        out = _run([FORGE / "Core"], """
            local Boot = Require("Boot")
            Boot.signal("world")
            assert(Boot.await("world", 1), "a signalled latch must return true")
            print('{"instant":true}')
        """)
        assert "instant" in out

    def test_signalling_twice_is_a_no_op(self) -> None:
        out = _run([FORGE / "Core"], """
            local Boot = Require("Boot")
            assert(Boot.signal("a") == true, "first signal is new")
            assert(Boot.signal("a") == false, "second signal must not re-fire")
            print('{"ok":true}')
        """)
        assert "ok" in out

    def test_a_missing_producer_is_reported_rather_than_raced(self) -> None:
        out = _run([FORGE / "Core"], """
            local Boot = Require("Boot")
            Boot.declare("props", { producedBy = "Scatter", requires = { "terrain" } })
            local problems = Boot.validate()
            assert(#problems == 1, "expected one problem, got " .. #problems)
            print(problems[1])
        """)
        assert "terrain" in out

    def test_a_cycle_is_found(self) -> None:
        out = _run([FORGE / "Core"], """
            local Boot = Require("Boot")
            Boot.declare("a", { producedBy = "A", requires = { "b" } })
            Boot.declare("b", { producedBy = "B", requires = { "a" } })
            local problems = Boot.validate()
            local cycles = 0
            for _, problem in problems do
                if string.find(problem, "cycle") then cycles += 1 end
            end
            assert(cycles > 0, "a cycle must be reported")
            print('{"cycle":true}')
        """)
        assert "cycle" in out


class TestClock(unittest.TestCase):
    def test_days_are_utc_and_stable(self) -> None:
        out = _run([FORGE / "Core"], """
            local Clock = Require("Clock")
            assert(Clock.dayNumber(86400 * 3) == 3, "day three")
            assert(Clock.dayStart(86400 * 3 + 500) == 86400 * 3, "day start")
            print('{"ok":true}')
        """)
        assert "ok" in out

    def test_the_daily_seed_is_the_same_all_day_and_different_tomorrow(self) -> None:
        """The property that lets every server derive the same shop."""
        out = _run([FORGE / "Core"], """
            local Clock = Require("Clock")
            local morning = Clock.dailySeed("shop", 86400 * 10 + 60)
            local evening = Clock.dailySeed("shop", 86400 * 10 + 80000)
            local tomorrow = Clock.dailySeed("shop", 86400 * 11 + 60)
            assert(morning == evening, "same day must give the same seed")
            assert(morning ~= tomorrow, "a new day must give a new seed")
            print('{"stable":true}')
        """)
        assert "stable" in out

    def test_different_salts_do_not_rotate_in_lockstep(self) -> None:
        out = _run([FORGE / "Core"], """
            local Clock = Require("Clock")
            local a = Clock.dailySeed("shop", 86400 * 10)
            local b = Clock.dailySeed("shops", 86400 * 10)
            assert(a ~= b, "a one-letter difference must not collide")
            print('{"distinct":true}')
        """)
        assert "distinct" in out

    def test_a_nil_expiry_is_permanent_not_expired(self) -> None:
        """Treating nil as expired silently deletes everything with no deadline."""
        out = _run([FORGE / "Core"], """
            local Clock = Require("Clock")
            assert(Clock.hasExpired(nil) == false, "nil must not be expired")
            assert(Clock.remaining(nil) == math.huge, "nil has no end")
            print('{"permanent":true}')
        """)
        assert "permanent" in out


class TestTransactionJournal(unittest.TestCase):
    def test_a_pending_hold_survives_and_a_committed_one_does_not_replay(self) -> None:
        out = _run([FORGE / "Save"], """
            local Journal = Require("TransactionJournal")
            local hold = Journal.open("trade", "7", { "sword" })
            assert(#Journal.pendingFor("7") == 1, "a pending hold is owed back")
            assert(Journal.commit(hold) == true, "first commit lands")
            assert(#Journal.pendingFor("7") == 0, "a committed hold is not owed")
            assert(Journal.commit(hold) == false, "a second commit must not re-settle")
            print('{"exactlyOnce":true}')
        """)
        assert "exactlyOnce" in out

    def test_ids_are_unique_so_reconciliation_can_dedup(self) -> None:
        out = _run([FORGE / "Save"], """
            local Journal = Require("TransactionJournal")
            local seen = {}
            for _ = 1, 200 do
                local hold = Journal.open("trade", "7", {})
                assert(seen[hold.holdId] == nil, "duplicate hold id: " .. hold.holdId)
                seen[hold.holdId] = true
            end
            print('{"unique":true}')
        """)
        assert "unique" in out

    def test_it_runs_with_no_roblox_services_at_all(self) -> None:
        """The header claims pure. This is what makes the claim testable."""
        out = _run([FORGE / "Save"], """
            local Journal = Require("TransactionJournal")
            Journal.open("x", "1", {})
            print('{"pure":true}')
        """)
        assert "pure" in out


class TestServerProfile(unittest.TestCase):
    def test_a_migration_grant_is_stamped_so_reload_does_not_grant_again(self) -> None:
        """The schema version has to survive the save or the next load is blind.

        Reconcile used to build a new table without `version`, and the migration
        loop advanced a local that was thrown away. A grant inside that step
        could not be told apart from one that had never run, and a later step
        had nothing to key off.
        """
        out = _run([FORGE / "Save"], """
            local ServerProfile = Require("ServerProfile")
            local stored = {
                version = 1,
                entityKey = "keep",
                settings = { coins = 5 },
                managerUserIds = { 9 },
            }
            local grants = 0
            local function open()
                return ServerProfile.new({
                    store = {
                        get = function()
                            return true, stored
                        end,
                        update = function(_, _, transform)
                            stored = transform(stored)
                            return true, stored
                        end,
                    },
                    entityKey = "keep",
                    reconcile = ServerProfile.reconciler({ settings = { coins = 0 } }),
                })
            end

            local profile = open()
            profile:addMigration(1, function(data)
                grants += 1
                data.settings.coins += 100
                return data
            end)
            assert(profile:load(), "load")
            local data = profile:get()
            assert(data.version == 2, "version after the step, got " .. tostring(data.version))
            assert(data.settings.coins == 105, "one grant")
            assert(data.managerUserIds[1] == 9, "saved managers survived reconcile")
            assert(profile:mutate(function(d)
                return {
                    entityKey = d.entityKey,
                    ownerUserId = d.ownerUserId,
                    managerUserIds = d.managerUserIds,
                    bannedUserIds = d.bannedUserIds,
                    settings = d.settings,
                }
            end), "save")
            assert(stored.version == 2, "save dropped the schema version")

            local again = open()
            again:addMigration(1, function(d)
                grants += 1
                d.settings.coins += 100
                return d
            end)
            local later = 0
            again:addMigration(2, function(d)
                later += 1
                d.settings.coins += 1
                return d
            end)
            assert(again:load(), "reload")
            assert(grants == 1, "replay granted again, grants=" .. tostring(grants))
            assert(later == 1, "the stamped version must unlock the next step")
            assert(again:get().version == 3, "version after the second step")
            assert(again:get().settings.coins == 106, "coins=" .. tostring(again:get().settings.coins))
            assert(again:get().managerUserIds[1] == 9, "managers survived reload")
            print('{"schema":true}')
        """)
        assert "schema" in out

    def test_a_missing_schema_version_is_zero_and_a_later_step_does_not_replay(self) -> None:
        """An unstamped save is older than schema 1, not a second copy of it."""
        out = _run([FORGE / "Save"], """
            local ServerProfile = Require("ServerProfile")
            local stored = {
                entityKey = "keep",
                settings = { coins = 105 },
                managerUserIds = { 4 },
            }
            local function open()
                return ServerProfile.new({
                    store = {
                        get = function()
                            return true, stored
                        end,
                        update = function(_, _, transform)
                            stored = transform(stored)
                            return true, stored
                        end,
                    },
                    entityKey = "keep",
                    reconcile = ServerProfile.reconciler({ settings = { coins = 0 } }),
                })
            end

            local fromOne = 0
            local legacy = open()
            legacy:addMigration(1, function(data)
                fromOne += 1
                data.settings.coins += 100
                return data
            end)
            assert(legacy:load(), "legacy load")
            assert(fromOne == 0, "missing version must not qualify for step 1")
            assert(legacy:get().version == 0, "missing version stamps as 0")
            assert(legacy:get().settings.coins == 105, "coins stayed")
            assert(legacy:get().managerUserIds[1] == 4, "managers stayed")

            stored = { entityKey = "keep", settings = { coins = 1 } }
            local fromZero = 0
            local fresh = open()
            fresh:addMigration(0, function(data)
                fromZero += 1
                data.settings.coins += 10
                return data
            end)
            assert(fresh:load(), "unstamped load")
            assert(fresh:mutate(function(d) return d end), "save unstamped")
            assert(fromZero == 1, "step 0 runs once for a missing stamp")
            assert(fresh:get().version == 1, "step 0 advances to 1")
            assert(stored.version == 1, "advanced version was saved")
            assert(fresh:get().settings.coins == 11, "step 0 grant")

            local replay = open()
            replay:addMigration(0, function(data)
                fromZero += 1
                data.settings.coins += 10
                return data
            end)
            assert(replay:load(), "replay")
            assert(fromZero == 1, "step 0 replayed, grants=" .. tostring(fromZero))
            assert(replay:get().version == 1, "version stayed 1")
            assert(replay:get().settings.coins == 11, "grant was not repeated")
            print('{"unstamped":true}')
        """)
        assert "unstamped" in out

    def test_saved_settings_tables_keep_missing_default_keys(self) -> None:
        """A saved settings table must not replace the default table.

        `audio = { volume = 0.2 }` against `{ volume = 1, muted = false }`
        has to load with the saved volume and the default mute. A saved
        scalar still wins. Id lists are not merged.
        """
        out = _run([FORGE / "Save"], """
            local ServerProfile = Require("ServerProfile")
            local managers = { 9 }
            local banned = { 4 }
            local reconcile = ServerProfile.reconciler({
                settings = {
                    coins = 0,
                    audio = {
                        volume = 1,
                        muted = false,
                        eq = { bass = 1, treble = 2 },
                    },
                },
            })
            local data = reconcile({
                version = 1,
                settings = {
                    coins = 5,
                    audio = { volume = 0.2, eq = { bass = 4 } },
                },
                managerUserIds = managers,
                bannedUserIds = banned,
            })
            assert(data.settings.audio.volume == 0.2, "saved volume lost")
            assert(data.settings.audio.muted == false, "nested default muted was dropped")
            assert(data.settings.audio.eq.bass == 4, "saved nested scalar lost")
            assert(data.settings.audio.eq.treble == 2, "deeper default was dropped")
            assert(data.settings.coins == 5, "saved scalar was replaced by the default")
            assert(data.managerUserIds == managers, "manager ids were merged or copied")
            assert(data.bannedUserIds == banned, "banned ids were merged or copied")
            print('{"settings":true}')
        """)
        assert "settings" in out

    def test_mutate_keeps_a_settings_key_only_the_store_has(self) -> None:
        """The transform has to edit the stored record, not the stale session.

        Memory has coins = 1. The record the store passes in also has gems = 7.
        Adding 1 to coins must write coins = 2 and gems = 7, and the transform
        runs once. A rejected update leaves the session profile unchanged.
        """
        out = _run([FORGE / "Save"], """
            local ServerProfile = Require("ServerProfile")
            local stored = {
                version = 1,
                entityKey = "keep",
                settings = { coins = 1 },
                managerUserIds = { 3 },
            }
            local runs = 0
            local reject = false
            local profile = ServerProfile.new({
                store = {
                    get = function()
                        return true, stored
                    end,
                    update = function(_, _, transform)
                        local current = {
                            version = 1,
                            entityKey = "keep",
                            settings = { coins = 1, gems = 7 },
                            managerUserIds = stored.managerUserIds,
                        }
                        local written = transform(current)
                        if reject then
                            return false, nil
                        end
                        stored = written
                        return true, written
                    end,
                },
                entityKey = "keep",
                reconcile = ServerProfile.reconciler({ settings = { coins = 0 } }),
            })
            assert(profile:load(), "load")
            assert(profile:get().settings.coins == 1, "memory coins")
            assert(profile:get().settings.gems == nil, "memory must not already have gems")
            assert(profile:mutate(function(data)
                runs += 1
                data.settings.coins += 1
                return data
            end), "mutate")
            assert(runs == 1, "transform ran " .. tostring(runs) .. " times")
            assert(stored.settings.coins == 2, "coins=" .. tostring(stored.settings.coins))
            assert(stored.settings.gems == 7, "gems were dropped")
            assert(profile:get().settings.coins == 2, "session did not adopt the write")
            assert(profile:get().settings.gems == 7, "session dropped gems")

            reject = true
            assert(profile:mutate(function(data)
                runs += 1
                data.settings.coins += 1
                return data
            end) == false, "failed update reported success")
            assert(runs == 2, "failed update did not attempt the transform")
            assert(profile:get().settings.coins == 2, "failed update changed the session")
            assert(profile:get().settings.gems == 7, "failed update dropped gems")
            print('{"mutate":true}')
        """)
        assert "mutate" in out


class TestMigrator(unittest.TestCase):
    def test_an_in_place_step_keeps_fields_and_a_new_table_still_replaces(self) -> None:
        """A nil return is the step editing the copy, not a request to empty it.

        The old branch turned that nil into `{}` and then stamped the target
        version, so the wipe was the saved profile. A returned table is still
        the new profile. A non-table return keeps the copy too.
        """
        out = _run([FORGE / "Save"], """
            local Migrator = Require("Migrator")

            local inplace = Migrator.new({
                version = 2,
                migrations = {
                    [1] = function(data)
                        data.renamed = data.old
                    end,
                },
                defaults = { renamed = "fallback", level = 1 },
            })
            local kept = inplace:migrate({ version = 1, old = "kept", extra = 7 })
            assert(kept.data.renamed == "kept", "mutated field lost: " .. tostring(kept.data.renamed))
            assert(kept.data.old == "kept", "source field dropped")
            assert(kept.data.extra == 7, "untouched field dropped")
            assert(kept.data.level == 1, "defaults still fill gaps")
            assert(kept.data.version == 2, "target version was not stamped")
            assert(kept.fromVersion == 1 and kept.toVersion == 2, "version range")

            local replacing = Migrator.new({
                version = 2,
                migrations = {
                    [1] = function(data)
                        return { renamed = data.old, carried = data.extra }
                    end,
                },
            })
            local replaced = replacing:migrate({ version = 1, old = "kept", extra = 7, dropped = true })
            assert(replaced.data.renamed == "kept", "returned table was ignored")
            assert(replaced.data.carried == 7, "returned table lost its own field")
            assert(replaced.data.dropped == nil, "old fields leaked onto the new table")
            assert(replaced.data.old == nil, "old table was kept beside the return")
            assert(replaced.data.version == 2, "returned table was not stamped")

            local refused = Migrator.new({
                version = 2,
                migrations = {
                    [1] = function(data)
                        data.renamed = data.old
                        return false
                    end,
                },
                defaults = { renamed = "fallback" },
            })
            local held = refused:migrate({ version = 1, old = "kept", extra = 7 })
            assert(held.data.renamed == "kept", "non-table return wiped the edit")
            assert(held.data.extra == 7, "non-table return dropped untouched fields")
            assert(held.data.version == 2, "surviving copy was not stamped")
            print('{"migrated":true}')
        """)
        assert "migrated" in out


class TestVersionRollback(unittest.TestCase):
    def test_a_later_edit_does_not_rewrite_nested_history(self) -> None:
        """The snapshot has to keep the bag that existed at record time.

        A shallow copy shares nested tables with the live profile. Changing
        the sword after the save rewrites the history, and a restore then
        returns that edited bag as if it were the recorded one.
        """
        out = _run([FORGE / "Save"], """
            local History = Require("VersionRollback")
            local now = 10
            local ring = History.new({
                maxHistory = 4,
                clock = function()
                    return now
                end,
            })
            local live = { coins = 3, bag = { sword = true, gems = 2 } }
            local snap = ring:record(live)
            live.coins = 99
            live.bag.sword = false
            live.bag.gems = 0

            local recorded = ring:list()[1].payload
            assert(recorded.coins == 3, "top-level value leaked into history")
            assert(recorded.bag.sword == true, "nested history was rewritten")
            assert(recorded.bag.gems == 2, "nested field was dropped")

            snap.payload.coins = 0
            snap.payload.bag.sword = false
            assert(ring:list()[1].payload.coins == 3, "record returned the stored coins")
            assert(ring:list()[1].payload.bag.sword == true, "record returned the stored bag")

            local restored = ring:restore(snap.version)
            assert(restored.bag.sword == true, "restore returned the edited bag")
            assert(restored.coins == 3, "restore returned the edited coins")
            restored.bag.sword = false
            restored.coins = 0
            assert(ring:list()[1].payload.bag.sword == true, "restore aliased the old snapshot")
            assert(ring:list()[1].payload.coins == 3, "restore aliased the old coins")
            assert(restored.bag.sword == false, "the forward copy did not take the edit")

            local listed = ring:list()[1].payload
            listed.bag.sword = false
            listed.coins = 0
            assert(ring:list()[1].payload.bag.sword == true, "list handed out the live snapshot")
            assert(ring:list()[1].payload.coins == 3, "list handed out the live coins")
            print('{"history":true}')
        """)
        assert "history" in out


class TestVersionRollbackStore(unittest.TestCase):
    def test_each_player_keeps_their_own_oldest_and_a_later_edit_does_not_rewrite_the_payload(self) -> None:
        """The index used to be one global store of zeros.

        GetSortedAsync orders by value, so a page of zeros is not oldest-first,
        and two players writing in the same second shared a key. Trimming that
        page could delete the other player's snapshot.
        """
        out = _run([FORGE / "Save"], """
            local Store = Require("VersionRollbackStore")

            local function memoryIndex()
                local rows = {}
                return {
                    rows = rows,
                    SetAsync = function(_, key, value)
                        rows[key] = value
                    end,
                    RemoveAsync = function(_, key)
                        rows[key] = nil
                    end,
                    GetSortedAsync = function(_, ascending, count)
                        local page = {}
                        for key, value in rows do
                            table.insert(page, { key = key, value = value })
                        end
                        table.sort(page, function(a, b)
                            if a.value == b.value then
                                return tostring(a.key) < tostring(b.key)
                            end
                            if ascending then
                                return a.value < b.value
                            end
                            return a.value > b.value
                        end)
                        local limited = {}
                        for i = 1, math.min(count, #page) do
                            limited[i] = page[i]
                        end
                        return { GetCurrentPage = function() return limited end }
                    end,
                }
            end

            local function memoryPayload()
                local rows = {}
                return {
                    rows = rows,
                    SetAsync = function(_, key, value)
                        rows[key] = value
                    end,
                    RemoveAsync = function(_, key)
                        rows[key] = nil
                    end,
                }
            end

            local payload = memoryPayload()
            local alice = Store.new("alice", 2, { payload = payload, index = memoryIndex() })
            local bob = Store.new("bob", 2, { payload = payload, index = memoryIndex() })
            assert(alice.indexName ~= bob.indexName, "two players share one index")
            assert(string.find(alice.indexName, "alice", 1, true), "alice's index is not hers")

            local first = { n = 1, bag = { sword = true } }
            assert(alice:record(first) ~= nil, "first record failed")
            first.bag.sword = false
            local kept = false
            for _, stored in payload.rows do
                if type(stored) == "table" and stored.n == 1 and stored.bag and stored.bag.sword == true then
                    kept = true
                end
            end
            assert(kept, "the stored bag was rewritten after record")

            assert(alice:record({ n = 2, bag = { sword = true } }) ~= nil, "second")
            assert(alice:record({ n = 3, bag = { sword = true } }) ~= nil, "third")
            local left = {}
            for _, stored in payload.rows do
                if type(stored) == "table" and stored.n then
                    table.insert(left, stored.n)
                end
            end
            table.sort(left)
            assert(#left == 2, "trim did not keep two snapshots, got " .. #left)
            assert(left[1] == 2 and left[2] == 3, "the oldest snapshot was not the one removed")

            assert(bob:record({ n = 9, bag = { sword = true } }) ~= nil, "bob")
            local bobKept = false
            for _, stored in payload.rows do
                if type(stored) == "table" and stored.n == 9 then
                    bobKept = true
                end
            end
            assert(bobKept, "alice's trim deleted bob")

            local crowded = Store.new("crowded", 2, { payload = payload, index = memoryIndex() })
            for n = 1, 12 do
                assert(crowded:record({ n = n, bag = { sword = true } }) ~= nil, "crowded record")
            end
            local prefix = "crowded:"
            local survived = {}
            for key, stored in payload.rows do
                if type(stored) == "table" and type(key) == "string" and string.sub(key, 1, #prefix) == prefix and stored.n then
                    table.insert(survived, stored.n)
                end
            end
            table.sort(survived)
            assert(#survived == 2, "a same-second burst did not keep two, got " .. #survived)
            assert(survived[1] == 11 and survived[2] == 12, "the trim kept an older snapshot than the newest two")

            local rolled = Store.new("rolled", 2, { payload = payload, index = memoryIndex() })
            rolled.seq = 999998
            for n = 1, 3 do
                assert(rolled:record({ n = n, bag = { sword = true } }) ~= nil, "rolled record")
            end
            local after = {}
            local rolledPrefix = "rolled:"
            for key, stored in payload.rows do
                if type(stored) == "table" and type(key) == "string" and string.sub(key, 1, #rolledPrefix) == rolledPrefix and stored.n then
                    table.insert(after, stored.n)
                end
            end
            table.sort(after)
            assert(#after == 2, "the sequence rollover did not keep two, got " .. #after)
            assert(after[1] == 2 and after[2] == 3, "the trim treated 1000000 as older than 999999")
            print('{"isolated":true}')
        """)
        assert "isolated" in out


class TestReceiptLedger(unittest.TestCase):
    def test_a_later_edit_does_not_rewrite_the_granted_payload(self) -> None:
        """The grant used to keep the caller's table.

        Changing the sword after the receipt was recorded rewrote the entry,
        and the next state still pointed at that same bag.
        """
        out = _run([FORGE / "Save"], """
            local Ledger = Require("ReceiptLedger")
            local ledger = Ledger.new()
            local payload = { items = { sword = true, gems = 2 } }
            local state, isNew = ledger:grant(nil, "r1", payload)
            assert(isNew, "first grant")
            payload.items.sword = false
            payload.items.gems = 0
            assert(state.r1.items.sword == true, "the granted bag was rewritten")
            assert(state.r1.items.gems == 2, "the granted gems were rewritten")

            local nextState, alsoNew = ledger:grant(state, "r2", { items = { gem = 1 } })
            assert(alsoNew, "second grant")
            state.r1.items.sword = false
            assert(nextState.r1.items.sword == true, "the new state aliased the old payload")
            assert(nextState.r2.items.gem == 1, "the second payload was dropped")
            print('{"receipt":true}')
        """)
        assert "receipt" in out


class TestLiveConfig(unittest.TestCase):
    def test_a_later_edit_does_not_rewrite_the_cached_price(self) -> None:
        """Defaults and store records used to stay shared with the caller.

        Changing a nested price after construction, or after the store handed
        the record over, changed the value every later read returned.
        """
        out = _run([FORGE / "Save"], """
            local LiveConfig = Require("LiveConfig")
            local bag = { prices = { sword = 99 } }
            local store = {}
            function store:get(_key)
                return true, bag
            end
            local defaults = { prices = { sword = 10 } }
            local live = LiveConfig.new({
                store = store,
                defaults = defaults,
                refreshSeconds = 60,
                clock = function() return 1000 end,
            })
            defaults.prices.sword = 1
            local before = live:get("prices")
            assert(before.sword == 10, "the default was rewritten")
            before.sword = 0
            assert(live:get("prices").sword == 10, "a read rewrote the default")
            live:refresh()
            bag.prices.sword = 1
            local tuned = live:get("prices")
            assert(tuned.sword == 99, "the store bag rewrote the cache")
            tuned.sword = 0
            assert(live:get("prices").sword == 99, "a read rewrote the override")
            print('{"live":true}')
        """)
        assert "live" in out


class TestGuildModel(unittest.TestCase):
    def test_donate_and_upgrade_do_not_share_the_member_map(self) -> None:
        """Invite copied the member map. Donate and upgrade did not.

        Writing a member on the returned state rewrote the guild the caller
        still held.
        """
        out = _run([FORGE / "Social"], """
            local Guild = Require("GuildModel")
            local guild = Guild.new()
            local state = Guild.create("North")
            state.members[1] = 3
            local donated, err = guild:donate(state, 1, 100)
            assert(donated, err or "donate failed")
            donated.members[2] = 1
            assert(state.members[2] == nil, "donate shared the member table")
            assert(state.funds == 0, "donate wrote the original funds")
            state.funds = 100000
            local upgraded, upgradeErr = guild:applyUpgrade(state)
            assert(upgraded, upgradeErr or "upgrade failed")
            upgraded.members[9] = 1
            assert(state.members[9] == nil, "upgrade shared the member table")
            print('{"guild":true}')
        """)
        assert "guild" in out


class TestTradeSession(unittest.TestCase):
    def test_a_later_edit_does_not_rewrite_the_locked_stack(self) -> None:
        """The offer kept the caller's stack tables.

        Raising the count after both sides locked changed what the confirmed
        trade transferred, and result() handed back that same live table.
        """
        out = _run([FORGE / "Social"], """
            local Trade = Require("TradeSession")
            local session = Trade.new({
                a = "a",
                b = "b",
                cooldownSeconds = 0,
                clock = function() return 0 end,
            })
            local stack = { id = "sword", count = 1 }
            local ok, err = session:offer("a", { items = { stack }, currency = 5 })
            assert(ok, err or "offer a")
            stack.count = 40
            local okb, errb = session:offer("b", { items = { { id = "gem", count = 2 } }, currency = 0 })
            assert(okb, errb or "offer b")
            assert(session:lock("a"))
            assert(session:lock("b"))
            assert(session:confirm("a"))
            assert(session:confirm("b"))
            local result = session:result()
            assert(result.give.items[1].count == 1, "the locked stack was rewritten")
            result.give.items[1].count = 9
            local again = session:result()
            assert(again.give.items[1].count == 1, "result handed back the live offer")
            print('{"trade":true}')
        """)
        assert "trade" in out


class TestEnchanting(unittest.TestCase):
    def test_a_later_edit_does_not_rewrite_the_definition_or_the_slot(self) -> None:
        """define kept the caller's modifier list, and roll cloned it shallowly.

        Zeroing a weight after define made the next roll say the enchant had
        no modifiers. Editing the old slot's flat rewrote the rolled copy.
        """
        out = _run([FORGE / "Progression"], """
            local Enchanting = Require("Enchanting")
            local ench = Enchanting.new()
            local def = {
                id = "sharp",
                materialItemId = "stone",
                goldCost = 10,
                maxUpgrades = 3,
                modifiers = { { stat = "dmg", flatMin = 1, flatMax = 2, weight = 1 } },
            }
            ench:define(def)
            def.modifiers[1].weight = 0
            def.modifiers[1].flatMax = 100
            local slot = { itemId = "sword", upgrades = 0, modifiers = { { stat = "dmg", flat = 1 } } }
            local function rng()
                return 0.5
            end
            local rolled, rollErr = ench:roll("sharp", slot, rng)
            assert(rolled, rollErr or "roll failed")
            slot.modifiers[1].flat = 99
            assert(rolled.modifiers[1].flat == 1, "the rolled slot aliased the old modifier")
            assert(rolled.upgrades == 1, "upgrade count")
            print('{"enchant":true}')
        """)
        assert "enchant" in out


class TestModifierPipeline(unittest.TestCase):
    def test_stages_run_in_order_and_a_cap_limits_rather_than_raises(self) -> None:
        out = _run([FORGE / "Progression"], """
            local Pipeline = Require("ModifierPipeline")
            Pipeline.define("payout", { "bonus", { "event", "multiply" }, { "cap", "cap" } })
            Pipeline.provide("payout", "bonus", function() return { amount = 50, label = "pass" } end)
            Pipeline.provide("payout", "event", function() return { amount = 2, label = "weekend" } end)
            Pipeline.provide("payout", "cap", function() return { amount = 250, label = "daily" } end)
            local total = Pipeline.resolve("payout", 100)
            assert(total == 250, "expected 250, got " .. tostring(total))

            -- A cap must never raise a value that is already under it.
            local small = Pipeline.resolve("payout", 1)
            assert(small == 102, "a cap must not raise: " .. tostring(small))
            print('{"ordered":true}')
        """)
        assert "ordered" in out

    def test_every_contribution_is_labelled(self) -> None:
        """The audit trail is the reason this exists rather than StatsDeriver."""
        out = _run([FORGE / "Progression"], """
            local Pipeline = Require("ModifierPipeline")
            Pipeline.define("dmg", { "gear" })
            Pipeline.provide("dmg", "gear", function() return { amount = 7, label = "sword" } end)
            local _, steps = Pipeline.resolve("dmg", 10)
            assert(#steps == 1 and steps[1].label == "sword", "the step must name its source")
            assert(steps[1].before == 10 and steps[1].after == 17, "before and after")
            print('{"audited":true}')
        """)
        assert "audited" in out

    def test_a_broken_provider_costs_its_own_bonus_and_nothing_else(self) -> None:
        out = _run([FORGE / "Progression"], """
            local Pipeline = Require("ModifierPipeline")
            Pipeline.define("dmg", { "gear" })
            Pipeline.provide("dmg", "gear", function() error("guild service is down") end)
            Pipeline.provide("dmg", "gear", function() return { amount = 5, label = "sword" } end)
            local total = Pipeline.resolve("dmg", 10)
            assert(total == 15, "a failed provider must not take the payout down")
            print('{"isolated":true}')
        """)
        assert "isolated" in out


class TestAchievements(unittest.TestCase):
    def test_tiers_are_awarded_once_and_never_again(self) -> None:
        out = _run([FORGE / "Progression"], """
            local Achievements = Require("Achievements")
            Achievements.define("slayer", { stat = "kills", tiers = { 10, 100, 1000 } })
            local profile = { kills = 150 }

            local first = Achievements.evaluate(profile)
            assert(#first == 2, "150 kills clears two tiers, got " .. #first)
            local second = Achievements.evaluate(profile)
            assert(#second == 0, "a second pass must award nothing")
            print('{"onceEver":true}')
        """)
        assert "onceEver" in out

    def test_an_achievement_added_later_fires_retroactively(self) -> None:
        """The veterans must not be the only players who never get it."""
        out = _run([FORGE / "Progression"], """
            local Achievements = Require("Achievements")
            local profile = { kills = 5000 }
            Achievements.define("veteran", { stat = "kills", target = 1000 })
            local awarded = Achievements.evaluate(profile)
            assert(#awarded == 1, "an existing counter must qualify at once")
            print('{"retroactive":true}')
        """)
        assert "retroactive" in out

    def test_a_higher_tier_is_not_skipped_past_a_missing_one(self) -> None:
        out = _run([FORGE / "Progression"], """
            local Achievements = Require("Achievements")
            Achievements.define("rich", { stat = "coins", tiers = { 100, 1000 } })
            local profile = { coins = 500 }
            local awarded = Achievements.evaluate(profile)
            assert(#awarded == 1 and awarded[1].tier == 1, "only tier one is earned")
            print('{"noSkip":true}')
        """)
        assert "noSkip" in out


class TestGlobalEffects(unittest.TestCase):
    def test_two_doublers_give_four_times(self) -> None:
        out = _run([FORGE / "LiveOps", FORGE / "Core"], """
            local Effects = Require("GlobalEffects")
            Effects.define("weekend", { coin = 2 })
            Effects.define("boss", { coin = 2 })
            Effects.apply("weekend", 60)
            Effects.apply("boss", 60)
            assert(Effects.aggregate("coin") == 4, "doublers multiply")
            print('{"stacked":true}')
        """)
        assert "stacked" in out

    def test_an_unaffected_axis_is_neutral_rather_than_absent(self) -> None:
        """So a caller can multiply unconditionally without checking."""
        out = _run([FORGE / "LiveOps", FORGE / "Core"], """
            local Effects = Require("GlobalEffects")
            assert(Effects.aggregate("xp") == 1, "an untouched multiplicative axis is 1")
            Effects.addsUp("luck")
            assert(Effects.aggregate("luck") == 0, "an untouched additive axis is 0")
            print('{"neutral":true}')
        """)
        assert "neutral" in out

    def test_reapplying_extends_rather_than_stacking_a_second_copy(self) -> None:
        out = _run([FORGE / "LiveOps", FORGE / "Core"], """
            local Effects = Require("GlobalEffects")
            Effects.define("weekend", { coin = 2 })
            Effects.apply("weekend", 60)
            Effects.apply("weekend", 60)
            assert(Effects.aggregate("coin") == 2, "two presses must not double the event")
            print('{"extended":true}')
        """)
        assert "extended" in out


class TestAreas(unittest.TestCase):
    def test_a_locked_area_says_why(self) -> None:
        out = _run([FORGE / "World", FORGE / "Core"], """
            local Areas = Require("Areas")
            Areas.define("hub", { safe = true })
            Areas.define("deep", { requires = { level = 12 } })
            Areas.satisfies = function() return false end
            local allowed, reason = Areas.mayEnter({}, "deep")
            assert(allowed == false, "must be refused")
            assert(string.find(reason, "level"), "the reason must name the requirement")
            print(reason)
        """)
        assert "level" in out

    def test_a_game_with_no_safe_area_says_so(self) -> None:
        """A configuration mistake whose symptom is a player falling for ever."""
        out = _run([FORGE / "World", FORGE / "Core"], """
            local Areas = Require("Areas")
            Areas.define("deep", {})
            assert(Areas.describe().hasNowhereSafe == true, "must be flagged")
            print('{"flagged":true}')
        """)
        assert "flagged" in out


class TestAutoTarget(unittest.TestCase):
    def test_facing_beats_distance(self) -> None:
        """The single weighting that makes combat feel like it obeys you."""
        out = _run([FORGE / "Combat"], """
            local AutoTarget = Require("AutoTarget")
            local from = CFrame.new(Vector3.new(0, 0, 0))
            local ahead = { instance = "ahead", position = from.LookVector * 20 }
            local beside = { instance = "beside", position = Vector3.new(6, 0, 0) }
            local picked = AutoTarget.pick(from, { beside, ahead }, { range = 40, arc = 150 })
            assert(picked == "ahead", "picked " .. tostring(picked))
            print('{"facing":true}')
        """)
        assert "facing" in out

    def test_anything_outside_the_arc_is_not_a_target(self) -> None:
        out = _run([FORGE / "Combat"], """
            local AutoTarget = Require("AutoTarget")
            local from = CFrame.new(Vector3.new(0, 0, 0))
            local behind = { instance = "behind", position = from.LookVector * -10 }
            local picked = AutoTarget.pick(from, { behind }, { range = 40, arc = 90 })
            assert(picked == nil, "a target behind you is not a target")
            print('{"arc":true}')
        """)
        assert "arc" in out


class TestStore(unittest.TestCase):
    def test_a_reducer_owns_its_slice_and_subscribers_hear_changes(self) -> None:
        out = _run([FORGE / "State", FORGE / "Core"], """
            local Store = Require("Store")
            Store.reducer("score", function(state, action)
                if action.type == "scored" then return (state or 0) + action.points end
                return state or 0
            end)
            Store.dispatch({ type = "scored", points = 10 })
            Store.dispatch({ type = "scored", points = 5 })
            assert(Store.get("score") == 15, "got " .. tostring(Store.get("score")))
            print('{"reduced":true}')
        """)
        assert "reduced" in out

    def test_a_thunk_can_dispatch_several_actions(self) -> None:
        out = _run([FORGE / "State", FORGE / "Core"], """
            local Store = Require("Store")
            Store.reducer("n", function(state, action)
                if action.type == "inc" then return (state or 0) + 1 end
                return state or 0
            end)
            Store.dispatch(function(dispatch)
                dispatch({ type = "inc" })
                dispatch({ type = "inc" })
            end)
            assert(Store.get("n") == 2, "got " .. tostring(Store.get("n")))
            print('{"thunk":true}')
        """)
        assert "thunk" in out


class TestReplication(unittest.TestCase):
    def test_an_action_with_no_rule_is_withheld(self) -> None:
        """The default that decides whether forgetting a rule leaks everything."""
        out = _run([FORGE / "State", FORGE / "Core"], """
            local Replication = Require("Replication")
            assert(Replication.openByDefault == false, "must default closed")
            assert(Replication.mayReceive({ type = "secret" }, {}) == false, "withheld")
            print('{"closed":true}')
        """)
        assert "closed" in out

    def test_a_rule_that_errors_withholds_rather_than_opens(self) -> None:
        out = _run([FORGE / "State", FORGE / "Core"], """
            local Replication = Require("Replication")
            Replication.rule("inventory", function() error("broken") end)
            assert(Replication.mayReceive({ type = "inventory" }, {}) == false,
                "a broken filter must not become an open door")
            print('{"failsClosed":true}')
        """)
        assert "failsClosed" in out


class TestMissionInstance(unittest.TestCase):
    def test_objectives_advance_in_order_and_the_run_closes_when_done(self) -> None:
        out = _run([FORGE / "Match", FORGE / "Core"], """
            local Mission = Require("MissionInstance")
            Mission.define("crypt", { objectives = { "door", "boss" } })
            local run = Mission.open("crypt")
            assert(Mission.advance(run, "boss") == false, "cannot skip an objective")
            assert(Mission.advance(run, "door") == true, "the current objective advances")
            assert(Mission.advance(run, "boss") == true, "then the next one")
            assert(run.state == "closed", "clearing the last objective closes the run")
            print('{"ordered":true}')
        """)
        assert "ordered" in out


if __name__ == "__main__":
    unittest.main()


class TestSparseSet(unittest.TestCase):
    def test_swap_remove_keeps_both_halves_agreeing(self) -> None:
        """The one way a sparse set corrupts, and it corrupts silently."""
        out = _run([FORGE / "Core"], """
            local SparseSet = Require("SparseSet")
            local set = SparseSet.new()
            for id = 1, 200 do SparseSet.add(set, id) end
            for id = 1, 200, 2 do SparseSet.remove(set, id) end

            local report = SparseSet.describe(set)
            assert(report.count == 100, "count: " .. report.count)
            assert(report.consistent, "sparse and dense disagree")
            for id = 2, 200, 2 do
                assert(SparseSet.has(set, id), "lost " .. id)
            end
            print('{"consistent":true}')
        """)
        assert "consistent" in out

    def test_adding_twice_does_not_duplicate(self) -> None:
        out = _run([FORGE / "Core"], """
            local SparseSet = Require("SparseSet")
            local set = SparseSet.new()
            assert(SparseSet.add(set, 7) == true, "first add is new")
            assert(SparseSet.add(set, 7) == false, "second add is not")
            assert(SparseSet.size(set) == 1, "size must stay 1")
            print('{"unique":true}')
        """)
        assert "unique" in out

    def test_intersect_walks_the_smaller_set(self) -> None:
        out = _run([FORGE / "Core"], """
            local SparseSet = Require("SparseSet")
            local many, few = SparseSet.new(), SparseSet.new()
            for id = 1, 1000 do SparseSet.add(many, id) end
            SparseSet.add(few, 5) SparseSet.add(few, 500) SparseSet.add(few, 9999)
            local both = SparseSet.intersect(many, few)
            assert(#both == 2, "expected 2, got " .. #both)
            print('{"joined":true}')
        """)
        assert "joined" in out


class TestEconomyAudit(unittest.TestCase):
    def test_a_wall_in_the_curve_is_named(self) -> None:
        out = _run([FORGE / "Economy"], """
            local Audit = Require("Audit")
            Audit.faucet("kill", { amount = 12, perMinute = 4 })
            Audit.sink("sword", { price = 500, tier = 1 })
            Audit.sink("armour", { price = 6000, tier = 2 })
            local report = Audit.report()
            local walls = 0
            for _, note in report.notes do
                if string.find(note, "longer than the step before") then walls += 1 end
            end
            assert(walls == 1, "the eleven-fold jump must be named")
            print('{"wall":true}')
        """)
        assert "wall" in out

    def test_an_economy_with_nothing_to_spend_on_is_named(self) -> None:
        out = _run([FORGE / "Economy"], """
            local Audit = Require("Audit")
            Audit.faucet("kill", { amount = 10, perMinute = 6 })
            local report = Audit.report()
            local found = false
            for _, note in report.notes do
                if string.find(note, "nothing to spend it on") then found = true end
            end
            assert(found, "an economy with no sinks must say so")
            print('{"noSink":true}')
        """)
        assert "noSink" in out

    def test_a_price_in_a_currency_nobody_earns_is_unreachable(self) -> None:
        out = _run([FORGE / "Economy"], """
            local Audit = Require("Audit")
            Audit.sink("relic", { price = 100, currency = "gem", tier = 1 })
            local report = Audit.report("gem")
            assert(report.incomePerMinute == 0, "no faucet")
            local found = false
            for _, note in report.notes do
                if string.find(note, "unreachable") then found = true end
            end
            assert(found, "must say the currency is unreachable")
            print('{"unreachable":true}')
        """)
        assert "unreachable" in out
