"""Exercise the Roblox-dependent paths the headless harness cannot reach.

`run_new_modules.py` covers the pure maths under a shim. Two functions are not
pure and therefore were not covered by it:

  * `Weapon.Validate.origin` raycasts the real world to decide whether a claimed
    muzzle is reachable -- the check that stops shooting through walls;
  * `Weapon.Stance.read` reads a Humanoid's state and velocity.

Both are exactly the kind of code that type-checks and then does not work, so
they get built into the open place as real ModuleScripts, against a real Model
with a real Humanoid, and run.
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from rqe.hub.client import StudioBridge  # noqa: E402


FORGE = ROOT / "forge" / "luau" / "Forge"

MODULES = {
    "Stance": FORGE / "Weapon" / "Stance.lua",
    "Validate": FORGE / "Weapon" / "Validate.lua",
}

TEST = r"""
local failures, checks = 0, {}
local function check(name, condition, detail)
	if not condition then
		failures += 1
		checks[name] = "FALHOU" .. (detail and (" -- " .. tostring(detail)) or "")
	else
		checks[name] = "ok"
	end
end

local holder = Instance.new("Folder")
holder.Name = "RQEStudioCheck"
holder.Parent = workspace

-- A character with the parts these functions actually look for.
local character = Instance.new("Model")
character.Name = "Probe"
local root = Instance.new("Part")
root.Name = "HumanoidRootPart"
root.Size = Vector3.new(2, 2, 1)
root.Position = Vector3.new(0, 50, 0)
root.Anchored = true
root.CanCollide = false
root.Parent = character
local head = Instance.new("Part")
head.Name = "Head"
head.Size = Vector3.new(1, 1, 1)
head.Position = Vector3.new(0, 51, 0)
head.Anchored = true
head.CanCollide = false
head.Parent = character
local humanoid = Instance.new("Humanoid")
humanoid.Parent = character
character.PrimaryPart = root
character.Parent = holder

-- ============================================================== Validate
local near = Validate.origin(character, Vector3.new(0, 51, -2))
check("origem proxima e alcancavel passa", near.ok, near.reason)

local far = Validate.origin(character, Vector3.new(0, 51, -200))
check("origem distante e recusada", not far.ok and far.reason == "far", far.reason)
check("origem distante e hostil", far.hostile)

-- The wall case: a muzzle INSIDE tolerance but behind geometry. This is the
-- whole reason the raycast exists, and the case a distance bound alone passes.
local wall = Instance.new("Part")
wall.Name = "Wall"
wall.Size = Vector3.new(20, 20, 1)
wall.Position = Vector3.new(0, 51, -4)
wall.Anchored = true
wall.Parent = holder
task.wait(0.1)

local behind = Validate.origin(character, Vector3.new(0, 51, -8))
check("muro: dentro da tolerancia mas bloqueado", not behind.ok, behind.reason)
check("muro: reportado como bloqueado", behind.reason == "blocked", behind.reason)
check("muro: hostil", behind.hostile)

-- ...and the same distance with the wall gone must pass, or the check is just
-- rejecting everything and would look identical in this test.
wall:Destroy()
task.wait(0.1)
local clear = Validate.origin(character, Vector3.new(0, 51, -8))
check("sem muro a mesma origem passa", clear.ok, clear.reason)

-- The character must not block itself.
local ownBody = Validate.origin(character, Vector3.new(0, 50.5, -0.6))
check("o proprio corpo nao bloqueia", ownBody.ok, ownBody.reason)

local noRig = Validate.origin(Instance.new("Model"), Vector3.new(0, 0, 0))
check("modelo sem humanoid e recusado sem acusar",
	not noRig.ok and not noRig.hostile and noRig.reason == "no-character", noRig.reason)

-- ================================================================= Stance
local still = Stance.read(character, nil)
check("parado nao conta como movendo", still.moving == false, tostring(still.moving))
check("parado nao conta como correndo", still.sprinting == false)

root.Anchored = false
root.AssemblyLinearVelocity = Vector3.new(0, 0, 24)
task.wait(0.15)
local moving = Stance.read(character, nil)
check("velocidade alta le como movendo", moving.moving == true, tostring(moving.moving))
check("velocidade alta le como correndo", moving.sprinting == true, tostring(moving.sprinting))

-- Vertical velocity alone is not horizontal movement.
root.AssemblyLinearVelocity = Vector3.new(0, 40, 0)
task.wait(0.15)
local rising = Stance.read(character, nil)
check("velocidade vertical nao conta como movimento",
	rising.moving == false, tostring(rising.moving))

local forced = Stance.read(character, { ads = true, moving = false })
check("o chamador pode sobrepor", forced.ads == true and forced.moving == false)
check("sem personagem devolve so o que foi passado",
	Stance.read(nil, { ads = true }).ads == true)

-- The multiplier must work on a real definition table.
local cone = Stance.multiplier(Stance.presets.rifle, moving)
check("postura real produz um multiplicador", cone > 1, cone)

holder:Destroy()
return { failures = failures, checks = checks }
"""


def main() -> int:
    parts = []
    for name, path in MODULES.items():
        source = path.read_text(encoding="utf-8")
        if "]==]" in source:
            raise SystemExit(f"{name}: long-bracket delimiter collides")
        parts.append(
            f'local {name}Src = [==[\n{source}\n]==]\n'
            f'local {name}Module = Instance.new("ModuleScript")\n'
            f'{name}Module.Name = "{name}"\n'
            f'{name}Module.Source = {name}Src\n'
            f'{name}Module.Parent = workspace\n'
            f'local {name} = require({name}Module)\n'
        )

    bridge = StudioBridge(allow_arbitrary=True)
    try:
        with bridge.lease_scope(
            agent_id="studio-check-new-systems",
            context="edit",
            ttl_seconds=150.0,
        ):
            result = bridge.call(
                "bridge.exec",
                {"source": "".join(parts) + TEST, "chunkName": "studio-check-new-systems"},
                timeout=120,
            )
    except Exception as exc:  # noqa: BLE001 - standalone diagnostic output
        print("ERRO", json.dumps({"type": type(exc).__name__, "message": str(exc)}, indent=1)[:600])
        return 1

    returned = result["returned"]
    for name, outcome in sorted(returned["checks"].items()):
        mark = " " if outcome == "ok" else "!"
        print(f" {mark} {name}: {outcome}")
    print(f"\n{len(returned['checks'])} verificacoes, {returned['failures']} falhas")
    return 0 if returned["failures"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
