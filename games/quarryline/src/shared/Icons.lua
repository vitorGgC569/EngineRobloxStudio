--!strict
--[[
	Icons — generated from `forge/catalog/images.json`. Do not hand-edit.

	Real published assets, not paths. An image on disk cannot be referenced by
	a running game, so each of these was resampled to 128px and pushed through
	`AssetService:CreateAssetAsync`. The licensed collection held 592 images
	that were unusable for exactly that reason.

	Only 162 went up. The source ships the same 57 icons in six palettes, and
	`ImageColor3` recolours a white glyph for free -- so the neutral variant
	was taken and 430 recolourable duplicates were left alone rather than
	permanently occupying asset slots on the account.

	Moderation is asynchronous. A freshly published id is valid and may still
	be under review, in which case it draws as nothing -- which is why every
	use site should keep a colour or a shape behind it.
]]

local Icons = {}

--: The handful the quarryline HUD names directly.
Icons.hud = {
	belt = "rbxassetid://99078056000970",
	coin = "rbxassetid://137410645022776",
	depot = "rbxassetid://84271047286484",
	drill = "rbxassetid://120140673385748",
	rebirth = "rbxassetid://73573644827238",
	smelter = "rbxassetid://82456717745265",
}

--: Everything else that was lifted from the licensed projects (162 glyphs),
--: available to any game by its original file name.
Icons.ui = {
	TheTrialsIcon = "rbxassetid://74484805784226",
	armor_chest = "rbxassetid://127770454489583",
	arrow_right = "rbxassetid://110365890321097",
	auto_collect = "rbxassetid://107924309130751",
	["b1-blocky-competitive-desktop-1920x1080"] = "rbxassetid://105687797637980",
	["b1-blocky-competitive-mobile-1080x1920"] = "rbxassetid://76213233486174",
	["b2-polished-arcade-desktop-1920x1080"] = "rbxassetid://91579068152057",
	["b2-polished-arcade-mobile-1080x1920"] = "rbxassetid://121196675676034",
	["b3-clean-block-tech-desktop-1920x1080"] = "rbxassetid://115664533846683",
	["b3-clean-block-tech-mobile-1080x1920"] = "rbxassetid://89131450222126",
	["blocky-bedwars-icon-pack-preview"] = "rbxassetid://109365813828258",
	candy_flourish_corner = "rbxassetid://88166101537427",
	capacitor = "rbxassetid://105863061816479",
	chevrons_down = "rbxassetid://129642516235202",
	chevrons_up = "rbxassetid://94956362693606",
	citrine_gem_bag = "rbxassetid://101469464533999",
	citrine_gem_pile = "rbxassetid://92724187940072",
	citrine_gem_single = "rbxassetid://88127663987903",
	clover_huge = "rbxassetid://126540179613534",
	clover_lucky = "rbxassetid://77240813049158",
	coins = "rbxassetid://121743548144729",
	coins_up = "rbxassetid://114834820520994",
	["combo-burst-512"] = "rbxassetid://79601913823137",
	["comparison-b1-b2-b3"] = "rbxassetid://125399562185428",
	confetti_dot = "rbxassetid://129696388267828",
	confetti_rect = "rbxassetid://71946363202180",
	confetti_squiggle = "rbxassetid://138908690933219",
	confetti_star = "rbxassetid://136368682986454",
	contact_sheet = "rbxassetid://139355515616820",
	contagion = "rbxassetid://100824860707948",
	crate_reward_closed = "rbxassetid://71764743322258",
	crate_reward_open = "rbxassetid://79514549751090",
	critical_hit = "rbxassetid://113170763955854",
	["ctf-gamemode"] = "rbxassetid://109260077164889",
	disarm = "rbxassetid://131622059169655",
	disarm_contact_sheet = "rbxassetid://85929284960901",
	emerald_gem_bag = "rbxassetid://77926591842445",
	emerald_gem_pile = "rbxassetid://79239867630273",
	emerald_gem_single = "rbxassetid://86258224192029",
	eye = "rbxassetid://119031523292311",
	eye_hidden = "rbxassetid://94552381234068",
	favicon = "rbxassetid://74267154376063",
	fear = "rbxassetid://114404945794266",
	["ffa-gamemode"] = "rbxassetid://126259770229943",
	fire_storm = "rbxassetid://124847379872361",
	fist = "rbxassetid://113902991811926",
	fist_broken = "rbxassetid://102924757769549",
	fist_impact = "rbxassetid://117789321053472",
	flag = "rbxassetid://108374406178145",
	focus = "rbxassetid://70456188513483",
	focus_regen = "rbxassetid://139691162080538",
	friends = "rbxassetid://138649552371707",
	gamemodes = "rbxassetid://111339911999842",
	gem_bag = "rbxassetid://96734491431202",
	gem_pile = "rbxassetid://135723101662973",
	gem_single = "rbxassetid://137056837832584",
	gems_all_colors = "rbxassetid://98311757149347",
	gift_up = "rbxassetid://115348907285797",
	golden_luck_pass = "rbxassetid://133615643972305",
	hand_stop = "rbxassetid://109335196163257",
	haste = "rbxassetid://97992245048565",
	heart = "rbxassetid://123267338859809",
	history = "rbxassetid://105846220810388",
	["homeworld_grass_pets_2026-07-21_contact_sheet"] = "rbxassetid://134240557373553",
	hourglass = "rbxassetid://125705013279729",
	["hud-icon-upload-pack-preview"] = "rbxassetid://132055537511462",
	huge_luck_pass = "rbxassetid://126306012960798",
	ice_hold = "rbxassetid://104807533238778",
	ice_shard = "rbxassetid://113884447119845",
	ice_storm = "rbxassetid://132021647690656",
	icon = "rbxassetid://70617568041462",
	icon_best = "rbxassetid://110702383780559",
	icon_coin = "rbxassetid://120341487244137",
	icon_stage = "rbxassetid://74421716659674",
	icon_trophy = "rbxassetid://87008791165065",
	icon_xp = "rbxassetid://125081906752723",
	icons_all_colors = "rbxassetid://121507678415261",
	impact_burst = "rbxassetid://76686073478179",
	knockback = "rbxassetid://132668562201238",
	leaderboard = "rbxassetid://129312507514892",
	["logo-icon"] = "rbxassetid://123757295165986",
	lollipop_mark = "rbxassetid://95020786270535",
	magnet = "rbxassetid://103538446138204",
	medal_first = "rbxassetid://124641616377462",
	medal_second = "rbxassetid://134713207538786",
	medal_third = "rbxassetid://96250279025289",
	["new_icons_2026-06-08_batch2_contact_sheet"] = "rbxassetid://80499783692521",
	["new_icons_2026-06-09_batch3_contact_sheet"] = "rbxassetid://134270657407195",
	["new_icons_2026-06-15_batch5_contact_sheet"] = "rbxassetid://112649527824929",
	new_icons_blue_contact_sheet = "rbxassetid://124789223109046",
	nuke = "rbxassetid://88922635639433",
	overheat = "rbxassetid://123472916785913",
	["panel-shine-512x256"] = "rbxassetid://93385952375330",
	pet = "rbxassetid://140666901840366",
	pet_slot_pass = "rbxassetid://138546129025198",
	pet_transfer = "rbxassetid://120984871950467",
	pill_frame = "rbxassetid://137722256317430",
	pill_panel = "rbxassetid://131646901060904",
	pill_ui_all_colors = "rbxassetid://117286153027873",
	play = "rbxassetid://108982073308341",
	player_status_quest_combo_reference = "rbxassetid://137250317106646",
	["plugin-icon"] = "rbxassetid://92332636699712",
	plus = "rbxassetid://80156668502208",
	plus_down = "rbxassetid://133550527906418",
	portal = "rbxassetid://90885562135929",
	potency = "rbxassetid://83161895062590",
	power_bar_reference = "rbxassetid://77762325031617",
	power_slotting_menu_reference = "rbxassetid://102004056267112",
	power_slotting_reference = "rbxassetid://122738828331627",
	proc = "rbxassetid://91588095404022",
	quests = "rbxassetid://134275957737264",
	rage = "rbxassetid://103543136881570",
	rainbow_luck_pass = "rbxassetid://121397933152531",
	range = "rbxassetid://96586648789600",
	ranged_impact = "rbxassetid://114530759404479",
	["rank-medals-512x192"] = "rbxassetid://104795687394432",
	revive = "rbxassetid://124767102692664",
	ring_aoe = "rbxassetid://89600489823779",
	ring_aura = "rbxassetid://78834691811703",
	ring_bronze = "rbxassetid://96582024380761",
	ring_copper = "rbxassetid://122389214507780",
	ring_enhancement = "rbxassetid://86609401377088",
	ring_enhancement_filled = "rbxassetid://101516106936017",
	ring_enhancement_filled_transparent = "rbxassetid://125702184160565",
	ring_frames_all_colors = "rbxassetid://138020513244564",
	ring_gold = "rbxassetid://88252229722226",
	ring_onyx = "rbxassetid://129908978664345",
	ring_silver = "rbxassetid://113224482891413",
	ring_target_aoe = "rbxassetid://90155569226713",
	ring_target_in = "rbxassetid://136626646261128",
	ring_target_out = "rbxassetid://70414058745240",
	ruby_gem_bag = "rbxassetid://97464047757492",
	ruby_gem_pile = "rbxassetid://102399439557429",
	ruby_gem_single = "rbxassetid://97396487876493",
	sand_storm = "rbxassetid://139027954979050",
	sapphire_gem_bag = "rbxassetid://129382255134196",
	sapphire_gem_pile = "rbxassetid://109222463101789",
	sapphire_gem_single = "rbxassetid://80789808962452",
	scorch = "rbxassetid://115898836948895",
	second_wind = "rbxassetid://93176975732469",
	settings = "rbxassetid://101483616156210",
	shadow_soft_9slice = "rbxassetid://122421793747429",
	shield = "rbxassetid://76784780659817",
	shield_broken = "rbxassetid://128997229700019",
	shop = "rbxassetid://120709298165448",
	sparkle_particle = "rbxassetid://126875233731639",
	speed = "rbxassetid://70957503358584",
	speed_boost = "rbxassetid://78691950118219",
	["speed_icon_2026-06-24_contact_sheet"] = "rbxassetid://94625853092781",
	star_sparkle = "rbxassetid://97111252370524",
	starlight_gift_icon = "rbxassetid://127047086878788",
	["story-stars"] = "rbxassetid://82977700928968",
	target = "rbxassetid://85618915228488",
	target_down = "rbxassetid://71929913423043",
	taunt = "rbxassetid://109535418930864",
	["toy-block-pattern-512"] = "rbxassetid://102919621058090",
	user_desk = "rbxassetid://87758450995518",
	vip_pass = "rbxassetid://105495474338789",
	waycoin = "rbxassetid://117460895957365",
	wins = "rbxassetid://121180982747081",
	winter_hold = "rbxassetid://109232567173448",
	xp_up = "rbxassetid://81759012135296",
}

--: Nil rather than an empty string for an unknown name: an ImageLabel with
--: `Image = ""` is a silent grey box, and nil is something a caller can test.
function Icons.hudIcon(name: string): string?
	return Icons.hud[name]
end

--: Falls back to the HUD set, so a name promoted from the library to the
--: HUD keeps working at every call site that already used it.
function Icons.find(name: string): string?
	return Icons.ui[name] or Icons.hud[name]
end

return Icons
