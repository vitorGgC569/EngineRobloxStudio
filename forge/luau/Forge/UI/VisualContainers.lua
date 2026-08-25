--!strict
--[[
	VisualContainers — M3-style containers as render plans.

	Card (elevated surface), Dropdown (closed/open + selection), Tab bar
	(active index), Menu (anchored rows), Dialog, Chip and FAB. Plans
	only; elevation/roles resolve through VisualTokens at bind time.
]]

local Containers = {}

-- ============================== card =====================================
export type CardProps = { title: string?, body: string?, elevated: boolean? }

function Containers.card(props: CardProps): { [string]: any }
	return {
		kind = "card",
		title = props.title,
		body = props.body,
		elevationLevel = if props.elevated then 2 else 1,
	}
end

-- ============================== dropdown =================================
export type DropdownState = {
	options: { string },
	selectedIndex: number?,
	open: boolean,
}

function Containers.dropdown(options: { string }): DropdownState
	assert(#options > 0, "dropdown needs options")
	return { options = table.clone(options), selectedIndex = nil, open = false }
end

function Containers.openDropdown(state: DropdownState): ()
	state.open = true
end

function Containers.closeDropdown(state: DropdownState): ()
	state.open = false
end

function Containers.selectDropdown(state: DropdownState, index: number): boolean?
	if not state.options[index] then
		return nil
	end
	state.selectedIndex = index
	state.open = false
	return state.options[index]
end

-- ============================== tab bar ==================================
export type TabBarState = { tabs: { string }, activeIndex: number }

function Containers.tabBar(tabs: { string }): TabBarState
	assert(#tabs > 0, "tab bar needs tabs")
	return { tabs = table.clone(tabs), activeIndex = 1 }
end

function Containers.selectTab(state: TabBarState, index: number): boolean
	if not state.tabs[index] then
		return false
	end
	state.activeIndex = index
	return true
end

-- ============================== menu / dialog / chip / fab ================
function Containers.menu(rows: { { text: string } }): { [string]: any }
	return { kind = "menu", rows = rows, selectedRow = nil }
end

function Containers.dialog(config: { title: string, body: string, confirmText: string, dismissText: string? }): { [string]: any }
	return {
		kind = "dialog",
		title = config.title,
		body = config.body,
		confirmText = config.confirmText,
		dismissText = config.dismissText or "Cancel",
	}
end

function Containers.chip(text: string, kind: ("assist" | "filter")?): { [string]: any }
	return { kind = "chip", chipType = kind or "assist", text = text, selected = false }
end

function Containers.fab(label: string?): { [string]: any }
	return { kind = "fab", label = label }
end

return Containers
