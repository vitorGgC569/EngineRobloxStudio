--!strict
local Config = {
    title = "JARDIM DE CRISTAIS",
    seed = 641029,
    plotCount = 6,
    bedCount = 9,
    capacityBase = 8,
    capacityStep = 6,
    maxSoilReduction = 0.4,
    interactionDistance = 14,
    weatherSeconds = 150,
    upgrades = {backpack = {70, 220, 650, 1800}, soil = {100, 300, 900, 2500}},
    species = {
        {id = "quartz", name = "Quartzo", cost = 5, growSeconds = 8, value = 14, color = {166, 237, 232}, unlockCost = 0},
        {id = "amethyst", name = "Ametista", cost = 18, growSeconds = 14, value = 46, color = {181, 144, 244}, unlockCost = 100},
        {id = "citrine", name = "Citrino", cost = 55, growSeconds = 20, value = 142, color = {251, 204, 105}, unlockCost = 450},
        {id = "rose", name = "Quartzo Rosa", cost = 140, growSeconds = 27, value = 360, color = {246, 158, 193}, unlockCost = 1400},
        {id = "celestial", name = "Celestita", cost = 380, growSeconds = 34, value = 980, color = {128, 187, 252}, unlockCost = 4200},
        {id = "sunstone", name = "Pedra do Sol", cost = 950, growSeconds = 40, value = 2480, color = {250, 151, 94}, unlockCost = 11000},
    },
    mutations = {
        {id = "normal", name = "Natural", multiplier = 1, color = {166, 237, 232}},
        {id = "dewy", name = "Orvalhado", multiplier = 1.5, color = {113, 226, 237}},
        {id = "aurora", name = "Aurora", multiplier = 2.5, color = {240, 158, 231}},
        {id = "golden", name = "Dourado", multiplier = 4, color = {255, 215, 113}},
    },
    weathers = {
        {id = "clear", name = "Céu limpo", multiplier = 1},
        {id = "dew", name = "Chuva de orvalho", multiplier = 1.5},
        {id = "aurora", name = "Aurora cristalina", multiplier = 2},
    },
}
return Config
