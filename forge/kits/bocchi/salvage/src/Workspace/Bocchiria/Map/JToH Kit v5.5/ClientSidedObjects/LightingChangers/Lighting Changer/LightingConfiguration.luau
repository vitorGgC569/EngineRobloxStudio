return {
    Type = "Lighting",
    Configuration = {
        GlobalShadows=false,
        Ambient=Color3.fromRGB(51,51,51),
        OutdoorAmbient=Color3.fromRGB(51,51,51),
        FogEnd=70,
        FogStart=20,
        FogColor=Color3.fromRGB(0,0,0),
        ClockTime=0,
        Brightness=0,
    },
    
    TweenInfo = TweenInfo.new(1, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)
}