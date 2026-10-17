--!strict
-- Dreadhollow tuning. The tension knobs live here and nowhere else:
-- lantern drain against the walk to the next battery is the entire feel.

return {
	-- Lantern: the light, the health bar, the clock. When it runs out the
	-- dark is real, and that is the whole horror of the resource.
	-- R1: longer base clock, denser batteries, wider fear field, slower ramp.
	lanternMax = 100,
	lanternDrain = 1.4, -- per second, unsheltered
	lanternRecover = 6, -- per second, inside the chapel
	batteryGives = 40,
	batteryCount = 5,
	batteryRespawn = 30,

	-- Objective: six pages, then the gate.
	pagesToWin = 6,
	pageCount = 8, -- two spare, so no single page can soft-lock the run

	-- Fear: the Hollow drains the lantern by proximity. Sheltered players
	-- in the chapel are untouched: the chapel is the one safe room.
	fearRadius = 16,
	fearDrain = 5, -- per second, unsheltered and close
	-- fear (16) drena de verdade via fearDrain; chased (60) só telegrafia/flicker.
	chasedRadius = 60, -- canônico p/ @systems; servidor lê com fallback 60
	darkDamage = 5, -- per second at zero lantern, unsheltered

	-- The Hollow: slow, relentless, louder every wave.
	firstWaveDelay = 25,
	waveFirst = 1,
	waveGrowth = 1.25,
	waveGap = 3,
	waveBetween = 30,
	waveCap = 6,
	sight = 70,
	chaseSpeed = 11,
	giveUp = 5,
	lanternOffSightFactor = 0.35, -- sight x0.35 quando a lanterna apaga

	-- Sanity: o apagado corroi a mente; abaixo do limiar o passo pesa.
	sanityDrain = 4, -- por s, com a lanterna apagada
	sanitySlowAt = 30, -- abaixo disso o WalkSpeed e reduzido

	-- Stamina: sprint cobra, parado paga de volta, zerou trava por exaustao.
	staminaMax = 100, -- teto da barra de folego
	staminaDrain = 18, -- por s, em sprint
	staminaRegen = 12, -- por s, parado/recuperando
	exhaustSeconds = 3, -- trava de sprint ao zerar

	-- Hide: armario esconde, mas cobra espera e tempo curto.
	hideCooldown = 20, -- espera entre esconderijos
	hideMax = 12, -- teto de segundos escondido

	-- Loop: lobby curto, noite longa, minimo para iniciar.
	lobbySeconds = 30, -- espera no lobby
	nightSeconds = 300, -- duracao da noite
	minReady = 2, -- prontos minimos para comecar

	arenaSize = 220,
	seed = 20260912,
}
