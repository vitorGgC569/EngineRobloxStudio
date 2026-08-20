-- Read back what the gallery actually rendered.
--
-- Judging a component by looking at a screenshot is how three attempts at the
-- shelf and the chips went wrong: a change is applied, the capture looks about
-- the same, and there is no way to tell "the fix did nothing" from "the fix
-- worked and the difference is subtle". Both look identical at a glance.
--
-- These are the properties, straight off the instances. If a transparency did
-- not take, this says so in a number.

local CoreGui = game:GetService("CoreGui")

local gallery = CoreGui:FindFirstChild("RQEUiGallery")
if gallery == nil then
	return { ok = false, reason = "no gallery; run tools/ui_gallery.lua first" }
end

local shelf = gallery:FindFirstChild("Shelf", true)
if shelf == nil then
	return { ok = false, reason = "gallery has no Shelf" }
end

local chips = {}
for _, child in ipairs(shelf:GetChildren()) do
	if child:IsA("Frame") then
		local amount = child:FindFirstChild("Amount", true)
		table.insert(chips, {
			name = child.Name,
			transparency = child.BackgroundTransparency,
			width = child.AbsoluteSize.X,
			height = child.AbsoluteSize.Y,
			textSize = if amount and amount:IsA("TextLabel") then amount.TextSize else 0,
		})
	end
end

local buttons = {}
for _, node in ipairs(gallery:GetDescendants()) do
	if node:IsA("TextButton") then
		local label = node:FindFirstChildWhichIsA("TextLabel")
		table.insert(buttons, {
			name = node.Name,
			width = node.AbsoluteSize.X,
			labelWidth = if label then label.AbsoluteSize.X else 0,
			-- The defect this caught: a fill narrower than the words on it.
			fits = if label then node.AbsoluteSize.X >= label.AbsoluteSize.X else false,
		})
	end
end

return {
	ok = true,
	shelfTransparency = shelf.BackgroundTransparency,
	chips = chips,
	buttons = buttons,
}
