--!strict
--[[
	Iso2D — run 2D games on a GuiObject surface.

	A compact isometric engine layer: coordinate mapping between the
	game's world pixels and the screen under ScaleType.Fit (Calc), AABB
	collision with side reporting and penetration resolution (Physics2D),
	and painter-order depth with focus fade (DepthSorter).

	Pure tables in, pure tables out; the presentation layer binds results
	to Instances.
]]

--[[
	`script.X`, not `script.Parent.X`.

	Every one of these said `script.Parent`, and every one of them was wrong in
	the same way: with Rojo an `init.lua` *becomes* its folder, so `script` is
	the `Iso2D` module itself and `script.Parent` is the library folder above
	it. The ten requires below therefore asked for ten siblings of `Iso2D` that
	have never existed, and the package failed on its first line -- so nothing
	that required `Iso2D` ever got a table back.

	The sibling modules have it right (`ScrollingMap` requires
	`script.Parent.Calc` and is correct, because it really is a sibling). Only
	the index was wrong, and the index is the only file anybody requires.
]]
return {
	Calc = require(script.Calc),
	Physics2D = require(script.Physics2D),
	DepthSorter = require(script.DepthSorter),
	ScrollingMap = require(script.ScrollingMap),
	TweenWalker = require(script.TweenWalker),
	DirectionalAnimPicker = require(script.DirectionalAnimPicker),
	FrameAnimator = require(script.FrameAnimator),
	SpatialAudio2D = require(script.SpatialAudio2D),
	UnifiedInput = require(script.UnifiedInput),
	GameSession = require(script.GameSession),
}
