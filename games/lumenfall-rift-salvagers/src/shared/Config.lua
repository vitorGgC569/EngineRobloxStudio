--!strict
return {
    name = "Lumenfall: Rift Salvagers",
    seed = 20260922,
    saveStore = "LumenfallProfiles_v1",
    selfTest = game:GetService("RunService"):IsStudio(),
    containers = { "LumenWorld", "Actors", "Effects", "Loot" },
    player = { health = 180, walkSpeed = 17, sprintSpeed = 25, dashIFrames = 0.42, dashCooldown = 1.15, utilityCooldown = 5.0 },
    economy = { extractionSeconds = 24, failureKeepRatio = 0.20, upgradeBase = 18 },
    palette = {
        void = Color3.fromRGB(17,12,31), stone = Color3.fromRGB(46,44,62),
        stoneLight = Color3.fromRGB(73,69,91), metal = Color3.fromRGB(48,53,66),
        lumen = Color3.fromRGB(255,191,77), lumenCool = Color3.fromRGB(105,235,255),
        storm = Color3.fromRGB(124,74,224), danger = Color3.fromRGB(255,76,108),
        safe = Color3.fromRGB(96,239,177),
    },
}
