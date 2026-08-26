return {
    Type = "DepthOfFieldEffect",
    Configuration = {
        FarIntensity = 0.75, 
        FocusDistance = 0.05, 
        InFocusRadius = 10, 
        NearIntensity = 0.75
    },
    
    TweenInfo = TweenInfo.new(1, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)
}