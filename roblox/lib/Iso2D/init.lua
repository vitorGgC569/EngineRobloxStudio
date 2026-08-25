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

return {
	Calc = require(script.Parent.Calc),
	Physics2D = require(script.Parent.Physics2D),
	DepthSorter = require(script.Parent.DepthSorter),
	ScrollingMap = require(script.Parent.ScrollingMap),
	TweenWalker = require(script.Parent.TweenWalker),
	DirectionalAnimPicker = require(script.Parent.DirectionalAnimPicker),
	FrameAnimator = require(script.Parent.FrameAnimator),
	SpatialAudio2D = require(script.Parent.SpatialAudio2D),
	UnifiedInput = require(script.Parent.UnifiedInput),
	GameSession = require(script.Parent.GameSession),
}
