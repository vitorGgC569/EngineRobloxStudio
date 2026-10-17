--!strict
--[[
	Curated — a filtered view of an asset catalogue.

	Why this exists
	---------------

	A topic is a claim about *kind*, and a catalogue's topics are assembled by
	whoever published the packs, not by anyone who ever looked at all of them
	side by side. `tree` gathers round leafy trees, flat PSX slabs, bare
	graveyard skeletons and one stylised pine into one list, and `pick(topic)`
	hands back whichever the seed lands on. The world that results has trees
	and also has errors, and no amount of tinting makes the graveyard skeleton
	look like a decision.

	The fix is not a better `pick`. It is a *decision* written down: this
	topic may use these models. That decision has to live with the game --
	it is taste -- while the machinery for expressing it belongs here, next
	to the catalogue it filters.

	How it decides
	--------------

	Rules are per topic, and a topic without rules passes through whole:

	  * `allow`  -- id allow-list. Present means "only these".
	  * `deny`   -- id deny-list, applied after allow (unless allow is set).
	  * `allowNames` / `denyNames` -- lowercase substrings against the model
	    name, because packs name families ("Bush Tall Dead") that the eye
	    rejects as a family and would take a paragraph of ids to spell out.
	  * `mix` -- do not prefer textured models. `ItchAssets.pick` sorts
	    textured first and `Place.put` asks for textured-only before falling
	    back, which quietly funnels a topic with one textured member onto
	    that member every time. For a curated list the texture flag is no
	    longer an argument -- the list already contains only models that
	    look right -- and greys are wanted, because `Tint` colours them.

	Flat models are always dropped, matching `ItchAssets.pick`.

	Usage:

		local Curated = Forge.Catalog.Curated
		local dress = Curated.new(Forge.Catalog.ItchAssets, {
			tree = { mix = true, allow = { 71973165859498, 111598666746773 } },
			bush = { denyNames = { "dead", "connector" } },
		})
		Place.put(dress, { topic = "tree", seed = 7, at = point, parent = folder })
]]

local Curated = {}

export type Rule = {
	allow: { number }?,
	deny: { number }?,
	allowNames: { string }?,
	denyNames: { string }?,
	mix: boolean?,
}

export type Rules = { [string]: Rule }

local function matchesAny(name: string, words: { string }): boolean
	for _, word in words do
		if string.find(name, word, 1, true) then
			return true
		end
	end
	return false
end

local function passes(rule: Rule, entry: any): boolean
	if entry.flat then
		return false
	end
	if rule.allow then
		local wanted = false
		for _, id in rule.allow do
			if id == entry.id then
				wanted = true
				break
			end
		end
		if not wanted then
			return false
		end
	elseif rule.deny then
		for _, id in rule.deny do
			if id == entry.id then
				return false
			end
		end
	end
	local name = string.lower(entry.name)
	if rule.denyNames and matchesAny(name, rule.denyNames) then
		return false
	end
	if rule.allowNames and not matchesAny(name, rule.allowNames) then
		return false
	end
	return true
end

--[[
	A catalogue view. `base` is anything with `byTopic(topic)`, which is
	`ItchAssets` and is a small enough surface for a game with its own asset
	table to satisfy.
]]
function Curated.new(base: any, rules: Rules)
	local self = {}
	local cache: { [string]: { any } } = {}

	local function list(topic: string): { any }
		local cached = cache[topic]
		if cached then
			return cached
		end
		local rule = rules[topic] or {}
		local out = {}
		for _, entry in base.byTopic(topic) do
			if passes(rule, entry) then
				table.insert(out, entry)
			end
		end
		cache[topic] = out
		return out
	end

	--: The same contract as `ItchAssets.pick`, over the filtered list. A
	--: topic whose rules emptied it returns nil, which `Place.put` already
	--: treats as "use the fallback", exactly like a fetch that failed.
	function self.pick(topic: string, seed: number, texturedOnly: boolean?): number?
		local entries = list(topic)
		if #entries == 0 then
			return nil
		end
		local pool = entries
		local rule = rules[topic]
		if texturedOnly and not (rule and rule.mix) then
			pool = {}
			for _, entry in entries do
				if entry.textured then
					table.insert(pool, entry)
				end
			end
			if #pool == 0 then
				return nil
			end
		end
		return pool[(math.floor(math.abs(seed)) % #pool) + 1].id
	end

	function self.byTopic(topic: string): { any }
		return list(topic)
	end

	--: topic -> how many models survived, for `forge` diagnostics and for
	--: tests that want to fail loudly when a rule list has a typo'd id.
	function self.describe(): { [string]: any }
		local report = {}
		for topic in rules do
			local entries = list(topic)
			local names = {}
			for _, entry in entries do
				table.insert(names, entry.name)
			end
			report[topic] = { count = #entries, names = names }
		end
		return report
	end

	return self
end

return Curated
