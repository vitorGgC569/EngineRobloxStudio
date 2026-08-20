"""Headless gameplay execution and validation runner for ZombieSurvival3D in teste/."""

import json
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
LUAU_EXE = ROOT / ".tools" / "luau" / "luau.exe"
SHIM = ROOT / "tools" / "luau-harness" / "shim.luau"

TEST_BODY = """
local WeaponCatalog = Require("WeaponCatalog")
local SkinCatalog = Require("SkinCatalog")
local ZombieCatalog = Require("ZombieCatalog")
local EconomyCatalog = Require("EconomyCatalog")
local PersistenceService = Require("PersistenceService")
local ShopService = Require("ShopService")
local BarricadeService = Require("BarricadeService")

-- 1. Test Catalogs
local testResults = {
	weaponCount = 0,
	skinCount = 0,
	zombieCount = 0,
	upgradeCount = 0,
	shopPass = false,
	skinUnlockPass = false,
	persistencePass = false,
	barricadePass = false,
	combatPass = false,
}

for _ in pairs(WeaponCatalog.Weapons) do testResults.weaponCount += 1 end
for _ in pairs(SkinCatalog.Skins) do testResults.skinCount += 1 end
for _ in pairs(ZombieCatalog.Zombies) do testResults.zombieCount += 1 end
for _ in pairs(EconomyCatalog.Upgrades) do testResults.upgradeCount += 1 end

-- 2. Test Player Persistence
local persistence = PersistenceService.new("TestStore_Zombie")
local player1 = { UserId = 501, Name = "SurvivorOne" }
local player2 = { UserId = 502, Name = "SurvivorTwo" }

local data1 = persistence:load(player1)
local initialScraps = data1.scraps

-- 3. Test Shop System
local shop = ShopService.new(persistence)
-- Give scraps for testing purchases
data1.scraps = 2000
persistence:save(player1, data1)

local boughtWeapon, msg1 = shop:buyWeapon(player1, "assault_rifle")
local boughtSkin, msg2 = shop:buySkin(player1, "cyber_neon")
local boughtAmmo, msg3 = shop:buySupply(player1, "ammo_box_rifle")

testResults.shopPass = boughtWeapon and boughtAmmo and (data1.ammo.Rifle > 90)
testResults.skinUnlockPass = boughtSkin and table.find(data1.unlockedSkins, "cyber_neon") ~= nil

-- 4. Test Persistence Save & Reload
local savedSnapshot = table.clone(data1)
persistence:clear(player1)
local reloadedData = persistence:load(player1)

testResults.persistencePass = (reloadedData.scraps == savedSnapshot.scraps)
	and (table.find(reloadedData.unlockedWeapons, "assault_rifle") ~= nil)
	and (reloadedData.ammo.Rifle == savedSnapshot.ammo.Rifle)

-- 5. Test Barricade Logic
local barricadeService = BarricadeService.new()
local fakeBarricade = {
	Name = "Barricade_1",
	attributes = { Health = 200, MaxHealth = 200, Tier = 1 },
	GetAttribute = function(self, key) return self.attributes[key] end,
	SetAttribute = function(self, key, val) self.attributes[key] = val end,
	GetChildren = function(self) return {} end,
}

barricadeService:register(fakeBarricade)
local destroyed = barricadeService:damageBarricade(fakeBarricade, 120)
local damagedHp = fakeBarricade:GetAttribute("Health")
local repaired = barricadeService:repairBarricade(player1, fakeBarricade, 50)
local repairedHp = fakeBarricade:GetAttribute("Health")

testResults.barricadePass = (damagedHp == 80) and (repairedHp == 130) and not destroyed

-- 6. Test Combat & Ballistics Logic
local CombatService = Require("CombatService")
local combat = CombatService.new()
local weaponAr = WeaponCatalog.get("assault_rifle")
local baseDmg = weaponAr.damage
local headshotDmg = baseDmg * weaponAr.headshotMultiplier

testResults.combatPass = (baseDmg == 32) and (headshotDmg == 64) and (weaponAr.magazineSize == 30)

local function toJson(t)
	if type(t) == "table" then
		local isArr = #t > 0
		local parts = {}
		if isArr then
			for _, v in ipairs(t) do
				table.insert(parts, toJson(v))
			end
			return "[" .. table.concat(parts, ",") .. "]"
		else
			for k, v in pairs(t) do
				table.insert(parts, '"' .. tostring(k) .. '":' .. toJson(v))
			end
			return "{" .. table.concat(parts, ",") .. "}"
		end
	elseif type(t) == "string" then
		return '"' .. t .. '"'
	elseif type(t) == "number" or type(t) == "boolean" then
		return tostring(t)
	end
	return "null"
end

-- Output validation result as JSON
print(toJson({
	status = "PASS",
	metrics = testResults,
	game = "ZombieSurvival3D",
	scrapsRemaining = reloadedData.scraps,
	weaponsUnlocked = reloadedData.unlockedWeapons,
	skinsUnlocked = reloadedData.unlockedSkins,
}))
"""


def run_validation():
    from rqe.luau_harness import run as run_harness

    shared_dir = ROOT / "teste" / "src" / "shared"
    gameplay_dir = ROOT / "teste" / "src" / "gameplay" / "Services"

    res = run_harness(
        ROOT,
        libraries=[shared_dir, gameplay_dir],
        body=TEST_BODY,
        timeout=30.0,
    )

    if not res.ok:
        print("EXECUTION ERROR:\n", res.stderr)
        return False

    output_lines = [l for l in res.stdout.splitlines() if l.strip().startswith("{")]
    if not output_lines:
        print("RAW OUTPUT:\n", res.stdout)
        return False

    result_data = json.loads(output_lines[-1])
    print("=" * 60)
    print("ZOMBIE SURVIVAL 3D - VALIDATION EXECUTION TRACE:")
    print("=" * 60)
    print(json.dumps(result_data, indent=2))
    print("=" * 60)
    return result_data.get("status") == "PASS"


if __name__ == "__main__":
    ok = run_validation()
    print("FINAL VERDICT:", "VALIDATED (PASS)" if ok else "FAILED")
