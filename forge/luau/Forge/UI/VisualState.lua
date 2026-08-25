--!strict
--[[
	VisualState — behaviour decorators for components (pract's pattern).

	State, external signals and lifecycle become wrappers around a
	component instance instead of scattered booleans: the wrapper holds
	the value, re-renders on change and cleans up subscriptions on
	destroy. Same shape as pract.withState/withSignal/withLifecycle,
	without adopting a framework.
]]

local VisualState = {}

export type Component = { render: ((any) -> { [string]: any })?, destroyed: boolean }

-- withState: managed value + rerender callback; returns getter/setter.
function VisualState.withState(component: Component, key: string, initial: any): (() -> any, (any) -> ())
	local storage = { value = initial }
	local function get(): any
		return storage.value
	end
	local function set(value: any): ()
		if component.destroyed then
			return
		end
		if storage.value == value then
			return
		end
		storage.value = value
		if component.render then
			component:render()
		end
	end
	-- expose under a namespaced field so destroy-time sweep finds it
	local anyComponent = component :: any
	anyComponent._states = anyComponent._states or {}
	anyComponent._states[key] = storage
	return get, set
end

-- withSignal: subscribe now; auto-disconnect when the component dies.
function VisualState.withSignal(
	component: Component,
	connect: ((() -> ()) -> (() -> ()))?,
	handler: () -> ()
): ()
	local disconnect = connect and connect(handler) or function() end
	local cast = component :: any
	local baseDestroy = cast.destroy
	cast.destroy = function(self: Component)
		disconnect()
		baseDestroy(self)
	end
end

-- withLifecycle: run once on first render, cleanup on destroy.
function VisualState.withLifecycle(
	component: Component,
	onMount: (() -> ())?,
	onCleanup: (() -> ())?
): ()
	local cast = component :: any
	cast._lifecycleMounted = false
	local baseRender = cast.render
	cast.render = function(self: Component): { [string]: any }
		if not cast._lifecycleMounted then
			cast._lifecycleMounted = true
			if onMount then
				onMount()
			end
		end
		if baseRender then
			return baseRender(self)
		end
		return {}
	end
	local baseDestroy = cast.destroy
	cast.destroy = function(self: Component)
		if onCleanup and not self.destroyed then
			onCleanup()
		end
		baseDestroy(self)
	end
end

return VisualState
