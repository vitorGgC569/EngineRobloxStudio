# DREADHOLLOW — O Sanatório

Terror de sobrevivência single/multiplayer no Roblox, construído sobre a
engine (`WorldKit.Threat`, `GameKit.Pursuit`/`Motion` via `Behaviours.Life`,
`Core` e `Behaviours.Play`) e sem alterar nenhuma linha dela.

## Premissa

Dreadhollow foi um sanatório murado, fechado depois que os internos
começaram a desaparecer nas noites sem lua; a lenda diz que quem juntar
páginas suficientes do prontuário do diretor entende o selo do portão norte
e escapa antes que o Hollow entenda você — noite fixa, nevoeiro, 8 páginas
espalhadas, **6 vencem** e o primeiro a fugir quebra o selo para todos.

## O Hollow

O Hollow é a entidade que caça **por visão**: patrulha o sanatório em ondas
por timer (1ª aos 25s, nova a cada 30s, teto 6; cada onda: visão 70+4 studs
teto 90, perseguição 11+0,8 studs/s teto 17 = 11+6 — retune é decisão do
@systems), entra em perseguição quando te vê e **desiste após 5s sem visão**,
voltando a patrulhar — `chasedRadius` 60 só telegrafia (`Chased`/flicker da
lanterna, sem dreno); o medo drena +5/s só a <16 studs (`fearRadius`, fora da
capela); ele nunca entra na capela.
(Tuning lido em `src/shared/GameConfig.lua` (`chasedRadius` canônico, servidor
lê com fallback 60) + `src/server/init.server.lua`
(`makeHollow`/`Life.guard`, `HOLLOW_SPAWNS`, trickle por timer com teto
`waveCap`; `Life.spawner` aposentado — ver R13/R14).)

## A capela

A capela é o **único quarto seguro**: lá dentro o Hollow não percebe nem
persegue, o medo não drena e a **lanterna recarrega 6/s** — fora dela a
lanterna drena 1,4/s e, zerada, o escuro fere 5/s; baterias (+40 cada, 5 no
mapa, reaparecem em 30s) são para a exploração, a capela é para respirar.

O chão é construído no role `ground` do token set (Slate) e o servidor
mantém o Slate na construção do `Ground` (`part` + `tokens:swatch` em
`src/server/init.server.lua`) — sem override; `Grass` lavava para lavanda
sob o `Fog`. A zona da capela (`Zone.new`, centro (0,6,-70), tamanho
34×14×28) é ~2 studs maior que o quarto (30×24) por lado — tolerância para a
porta sul não piscar `Sheltered`; lido na fonte, nunca medido.

## Páginas — especificação de texto para @systems (NÃO implementado)

Os textos abaixo são **especificação de lore** para o @systems implementar
em rodada futura via `Shared`/servidor. Nada aqui afirma UI ou coleta
funcionando — ver tabela de validação.

1. **Admissão** — "Dia 1. Trouxeram mais seis. O portão norte só abre para quem entende o que fizemos aqui."
2. **Ronda** — "Dia 9. Ele anda pelo salão de noite. Não pisca. Não respira. Fingi que era sombra."
3. **Ala leste** — "Dia 17. Os da ala leste pararam de gritar. É pior quando param."
4. **Ala oeste** — "Dia 23. Queimamos os prontuários da ala oeste. As cinzas soletram meu nome."
5. **Enfermaria** — "Dia 31. A luz da lanterna é a única coisa que ele respeita. Enquanto dura."
6. **Capela** — "Dia 40. O padre jura que a capela é surda para ele. Dormi uma noite inteira. Acordei chorando de alívio."
7. **Pátio** — "Dia 48. Enterrei uma página no pátio para quem vier depois. Se você lê isto, corra pelo norte."
8. **Diretor** — "Dia 55. Seis páginas bastam para quebrar o selo. Eu não tive coragem. Tenha você."

Distribuição especificada: 2 no salão, 2 por ala (leste/oeste), 1 na
capela, 1 no pátio. Morte = renasce na entrada com lanterna cheia;
**páginas sobrevivem**.

| Sistema | Regra (especificada, NÃO medida) |
|---|---|
| Lanterna | drena 1,4/s fora, recupera 6/s na capela; zerada, o escuro fere 5/s |
| Medo | Hollow a <16 studs drena +5/s (só fora da capela) |
| Baterias | 5 no mapa, +40 cada, reaparecem em 30s |
| Páginas | 8 espalhadas, 6 vencem |
| Portão | norte, exige 6 páginas; o primeiro a fugir quebra o selo para todos |
| Morte | renasce na entrada com lanterna cheia; páginas sobrevivem |

## Selo, Notices e atributos — lore para @systems (fonte lida, runtime NÃO medido)

- **Selo quebra no 1º escape (lore, fonte: `src/server/init.server.lua`
  (`sealBroken`, ramo `EscapePad`/`winPad` + `Events.onPlayer`):**
  6 páginas no `EscapePad` do portão norte marcam `Won`; o primeiro escape
  destrói o selo, abre a barreira (`sealBroken`, server-authoritative) e os
  demais passam livres. Páginas são pickups de mundo — nunca há dois 6/8
  simultâneos — por isso o selo global não soft-locka.
- **Notices (toast do HUD; servidor escreve `Notice`/`NoticeAt`/`NoticeKind`,
  HUD só projeta):** os quatro kinds canônicos são emitidos na fonte —
  `page` (coleta, `handle.collected`), `escape` (selo/escape),
  `locked` (portão exige páginas), `danger` (`waveStarted` do spawner).
  O HUD colore `danger`/`page`/`escape`/`locked` e trata kind ausente como
  neutro (fonte: `src/client/init.client.lua`, `toastColorForKind`, TTL local 4s).
- **Atributos (server-authoritative, tuning em `src/shared/GameConfig.lua`):**
  `PagesToWin` = `pagesToWin` = 6, `LanternMax` = `lanternMax` = 100; por
  jogador: `Pages`, `Lantern`, `Sheltered`, `Chased`, `Won` (+ `Notice*`).
  O HUD espelha como `PAGES_TO_WIN`/`LANTERN_MAX` e nunca decide gameplay.
- Tudo acima: especificação lida na fonte (`STATICALLY_VALIDATED`), nunca
  rodada num Studio (`NOT_VALIDATED` em runtime).

## Controles

WASD + mouse (padrão Roblox desktop). "Shift — correr" existe só no texto de
ajuda do HUD (`src/client/init.client.lua`, `helpBody`) — sem override de
`WalkSpeed` no `src/`; sprint é default da engine, `NOT_VALIDATED`.
Sem mobile/console dedicado (contrato: desktop).

## Crítica cap-r4/r5 + intenção R-E (NÃO medida)

Frames `cap-r4`/`cap-r5` (runs sem player, diagnóstico — não prova):
pêndulo wash→void — `cap-r4` noite lavada (`Fog` sem `FogColor`), `cap-r5`
noite fechada demais; torre/belfry (`BelfryPillar`/`Bell`/`Spire`/
`BellLight`), pátio (`Rubble`/`Fence`), páginas 3×4 `paper` sem luz própria
já aplicados em `src/server/init.server.lua` — lidos na fonte, nunca
medidos.

Intenção R-E do @systems (implementação dele; aqui só docs): pacote de
exposição em runtime — `Lighting.Brightness`, `Lighting.Ambient`/
`OutdoorAmbient`, `Lighting.FogColor`/`FogStart`/`FogEnd`,
`DreadAtmosphere` (`Density`/`Haze`), `DreadBloom` (`Threshold`),
`DreadGrade`, mais `LanternGlow`/`BellLight`/`Flame`/`GateLight`.
Visual segue `NOT_VALIDATED` até print novo.

Lacuna: HUD só existe com player (Play Solo) — `src/client/init.client.lua`
lê `LocalPlayer`/`PlayerGui`; run sem player não tem HUD por construção.
Teste definitivo pendente: Play Solo com lanterna (`LanternGlow`
`Range`/`Brightness` via `Curve.remap` + flicker sob `Chased`). Próximos
viewpoints eye-level do crítico: spawn→torre, pátio→página, capela→altar,
portão.

## Crítica R6 + fixes R-F (aplicados, NÃO medidos)

Causa-mãe R6: write `Lighting.Technology` (`src/server/init.server.lua`)
abortava o script — mundo nunca construído. Fixes R-F do @systems (fonte
lida, runtime NÃO medido): deletar linha `Technology`; `LanternGlow` p/
torso (`init.server.lua`, bloco `lantern`, `Range`/`Brightness` via
`Curve.remap` + flicker sob `Chased`); vinheta radial
(`src/client/init.client.lua`, `Vignette`+`UIGradient`); `DreadBloom`
congelado (`init.server.lua`, `DreadBloom`/`Threshold`). R6 provou só
HUD+spawn+logs, NÃO o mundo. Prova pendente (2 viewpoints): spawn→torre
pós-fix; close `Page1` a 10 studs.

## R7 + pacote moonlight R-G (intenção)

Pacote moonlight R-G = intenção lida em `src/server/init.server.lua` (não medida): `Lighting.Brightness`/`Ambient`/`OutdoorAmbient`, `FogColor`/`FogStart`/`FogEnd`, `DreadAtmosphere` (`Density`/`Haze`), `DreadBloom` (`Threshold`), `DreadGrade` + `LanternGlow`/`BellLight`/`Flame`/`GateLight`. Visual segue `NOT_VALIDATED`.

R7 provado (frame `artifacts/loop-captures/cap-r7-spawn-fixed.png` + log): mundo (`Dreadhollow`/`Ground`/`Entrance`), spawn, dreno `GameConfig.lanternDrain` 1,4/s, HUD (`DreadHud`/`Objective`/`LanternFill`).

Falta observar: entidade (`makeHollow`/`Life.guard`), página coletável (`Play.pickup`), portão (`EscapePad`/`sealBroken`), capela (`Zone.new`/`Sheltered`), torre visível. Pendentes: `page-close`, capela→altar.

## R8 — 1º passo E2E + intenção R-H + externas

- E2E parcial: `Pages` 0→1 por navegação até `Page1` + toast kind `page` — `Play.pickup`/`handle.collected` → `Actions.notify` kind `page` (`src/server/init.server.lua`) → `Toast`/`toastColorForKind`/`Objective` (`PÁGINAS %d/%d`, `src/client/init.client.lua`); frame `artifacts/loop-captures/cap-r8-page-collected.png`.
- Halo ancora (em R8): `BellLight` (`Range` 160/`Brightness` 3.5/`Shadows=false`) — não projeta; resto (`breadcrumbs`/`mosslight`) era intenção R-H, sem símbolo no `src/` em R8 (ver R9).
- Ajuda (em R8): fonte lia fecha só por clique; dismiss por movimento era intenção R-H, não fonte (ver R9).
- Externas (não corrigir engine): warn `Trove` é da engine; plugin instalado defasado (`player.teleport` ausente → `studio install`+restart, decisão da orquestração).
- Viewpoints pendentes: spawn sem modal (`Help` fechado), `page-close`, entidade (`makeHollow`/`Life.guard`).

## R9 — movimento/dismiss/mosslight/página; torre/entidade/capela/portão seguem NÃO medidos

- `RUNTIME_VALIDATED` (R9): movimento WASD, dismiss do `Help` por movimento (`init.client.lua`, `InputBegan` + `ENTENDI` + fallback 12s se `Pages>0`, tudo local), baterias em `mosslight` (frias, torre segue único âmbar — `TokenData` r5 + `cellRole` no `init.server.lua`), coleta (`Play.pickup`→toast kind `page`).
- `NOT_VALIDATED`: torre, entidade (`makeHollow`/`Life.guard`), capela (`Zone`/`Sheltered`), portão (`EscapePad`/`sealBroken`) — nunca observados.
- Conflito lighting pendente do frame da torre, sem decisão: servidor (`OutdoorAmbient` 75,85,115 / `FogEnd` 700 / `BellLight` Range 200) acima dos tetos `moods.deadnight` (`outdoorAmbientCap` 55,62,82 / `fogEnd` 400 / `bellRangeMax` 80).
- R-I fino = intenção, não fonte; nada de R-I no `src/`.

## R10 — veredito: terceira via; entidade = próximo teste

- Veredito R10 fecha o conflito lighting do frame da torre por decisão, não por medida: terceira via — envelope mantém a noite legível + sino emissivo em vez de estourar `Range`.
- Terceira via = intenção R-J do @systems, NÃO implementada: nada de R-J no `src/`; visual segue `NOT_VALIDATED`.
- Próximos viewpoints, por ordem: torre pós-fix (spawn→torre) + entidade (`makeHollow`/`Life.guard`, nunca observada).

## R11 — lanterna provada; Hall quente sem fonte; entidade = próximo teste

- `RUNTIME_VALIDATED` (R11): lanterna — frame `artifacts/loop-captures/cap-r11-courtyard.png` mostra poça de luz no chão + HUD `LANTERNA FRACA`; fonte `src/server/init.server.lua` (`LanternGlow` no `HumanoidRootPart`, `Range`/`Brightness` via `Curve.remap`).
- `NOT_VALIDATED`: Hall quente sem fonte — interior âmbar no frame sem `PointLight` próprio no `src/` (só `BellLight`/`Flame`/`GateLight`/`Lamp_*`/`LanternGlow`); leak vs feature em aberto, decisão @systems R-K como intenção, NÃO implementada.
- `NOT_VALIDATED`: entidade (`makeHollow`/`Life.guard`) nunca observada. Próximo teste: esperar em (0,3,-35) → medir `Chased` + flicker da `LanternGlow` + vinheta/`Chased` no HUD (protocolo R12).

## R12 — veredito: PARCIAL (halo sem silhueta, âmbar-triplo); intenção R-L; protocolo entidade

- Veredito R12 PARCIAL: halo ancora (`BellLight` `Range` 80/`Brightness` 2.0/`Shadows=false`) sem silhueta da torre + âmbar-triplo (`BellLight`/`HallLamp`/`Lamp_*` mesma cor 255,190,120 sem hierarquia) — fonte lida, visual `NOT_VALIDATED` até print novo.
- Intenção R-L do @systems (NÃO implementada, nada de R-L no `src/`): pulso do `Bell` + `HallLamp` off-axis (fora do vão/eixo, equalizar por intenção não por leak).
- Protocolo entidade (pendente, `NOT_VALIDATED`): Play Solo, esperar em (0,3,-35), medir `Chased` + flicker da `LanternGlow` + vinheta/`Chased` no HUD.

## R13 — falha runtime wave-clear; trickle R-M virou fonte; encontro segue falta

- Falha `RUNTIME_VALIDATED` só p/ travar: spawner por wave-clear parou em 1 Hollow parado (sem onda nova).
- Fonte atual `src/server/init.server.lua`: trickle por timer (`Timer.after(firstWaveDelay)` + `Timer.every(waveBetween)`, teto `waveCap`, `aliveHollows`) — R-M implementada, `Life.spawner` aposentado no jogo.
- Encontro seguia `NOT_VALIDATED` em R13 — ver R14.

## R14 — telegrafia wave→chase→critical em pixels; Hollow/capela/portão seguem falta

- `RUNTIME_VALIDATED` só p/ telegrafia (frame `artifacts/loop-captures/cap-r14-chased.png`, Play Solo): toast kind `danger` "Onda 4 — ele volta a caçar. Apague-se." + `Chased` "ELE ESTÁ ATRÁS DE VOCÊ — CORRA" + "LANTERNA FRACA — VOLTE À LUZ" no mesmo quadro. Prova que o trickle dispara e o HUD projeta os três níveis; não prova Hollow visível nem perseguição.
- `NOT_VALIDATED`: Hollow visível (quadro escuro, sem silhueta — falta); capela (`Zone`/`Sheltered`), portão (`EscapePad`/`sealBroken`), `Won` — nunca observados.
- Intenção R-N do @systems (NÃO implementada, nada de R-N no `src/`): hierarquia de telegrafia — `danger` (onda) vs `Chased` (perseguição) vs crítico de lanterna hoje colidem no mesmo vermelho; diferenciar por cor/peso/posição, sem mudar regra.
- Protocolo encontro frontal (pendente, `NOT_VALIDATED`): Play Solo, frente para ponto aberto de `HOLLOW_SPAWNS` (ex. (0,4,-40)), lanterna cheia, aguardar onda e capturar o Hollow em quadro com `Chased` visível.

## R15 — veredito: INCONCLUSIVO (modelo); telegrafia provada; intenção R-O

- Veredito R15 INCONCLUSIVO p/ modelo: fonte `makeHollow`/`Life.guard` (`bodyRole ink`/`mantle slate`/`face neutralLight`/`accent accentDanger`, `showName`/`showHealth=false`) lida, sem silhueta observada em quadro (R14 escuro) — não carimbar Hollow.
- `RUNTIME_VALIDATED` só p/ telegrafia R14 (`cap-r14-chased.png`: toast `danger` onda + `Chased` + crítica de lanterna); perseguição/Hollow visível seguem `NOT_VALIDATED`.
- Intenção R-O do @systems (NÃO implementada, nada de R-O no `src/`): olhos-par + tints.
- E2E restante `NOT_VALIDATED`: capela (`Zone`/`Sheltered`), selo/portão (`EscapePad`/`sealBroken`), `Won`; viewpoint gate-escape pendente.

## Rodar no Studio

```powershell
rojo build games/dreadhollow/default.project.json --output games/dreadhollow/dreadhollow.rbxlx
```

Abra o `.rbxlx` no Studio e pressione Play. Para medir (com Studio aberto):

```powershell
python rqe.py studio serve
python rqe.py studio restart .tmp\dreadhollow.rbxlx .
python rqe.py studio call run.start --params '{"settleSeconds":6}' --timeout 60
python rqe.py studio measure .
```

## Validação honesta

| Afirmação | Nível |
|---|---|
| Estrutura do projeto, contrato, Luau compila, Rojo build | `STATICALLY_VALIDATED` |
| Spec visual (`contracts/visual-quality.json` rev.2: 1 viewpoint desktop da torre, 10 swatches cobrindo os 10 roles do token set, `maximumOffPaletteFraction` 0 mantido porque a cobertura é total — completar a paleta em vez de afrouxar a fração) | `STATICALLY_VALIDATED` (fonte; schema-conforme, sem captura) |
| Quality (`quality/quality-focus.json` + `quality/probe-registry.v1.json`: foco desktop-only, produtores runtime/visuais `DISABLED`, sem wiring no `rqe.project.json`) | `STATICALLY_VALIDATED` (fonte; schema-conforme, sem evidência) |
| Lore deste README (textos acima são especificação, não coleta medida) | `NOT_VALIDATED` |
| Mundo + spawn + dreno 1,4/s (`GameConfig.lanternDrain`) + HUD (`DreadHud`/`Objective`/`LanternFill`) — frame `cap-r7-spawn-fixed.png` + log | `RUNTIME_VALIDATED` (sessão Play Solo; sem E2E) |
| R8 1º passo E2E: `Pages` 0→1 por navegação + toast kind `page` (`Play.pickup`/`handle.collected` → `Toast`/`toastColorForKind`/`Objective`; frame `cap-r8-page-collected.png`) | `RUNTIME_VALIDATED` só p/ coleta; fuga/portão/entidade seguem `NOT_VALIDATED` |
| Halo `BellLight` ancora (`Shadows=false`); conflito do frame da torre fechado por veredito R10 — terceira via (envelope + sino emissivo) como intenção R-J, NÃO implementada | fonte `STATICALLY_VALIDATED`; visual/intenção `NOT_VALIDATED` |
| Baterias `mosslight` + coleta `Play.pickup`→toast `page` + movimento + dismiss por movimento | `RUNTIME_VALIDATED` (R9); `breadcrumbs`/R-I fino = intenção `NOT_VALIDATED` |
| Ajuda: `ENTENDI` + dismiss por movimento + fallback 12s se `Pages>0` (só local) | `RUNTIME_VALIDATED` (R9) |
| Externas: warn `Trove` da engine; plugin defasado (`player.teleport` ausente → `studio install`+restart) | observação externa, sem fix na engine |
| Entidade (`makeHollow`/`Life.guard`), capela (`Zone.new`/`Sheltered`), portão (`EscapePad`/`sealBroken`), torre visível | `NOT_VALIDATED` — capela/portão/`Won`/torre nunca observados; entidade: só telegrafia R14, sem silhueta; protocolo: encontro frontal p/ ponto aberto de `HOLLOW_SPAWNS` com `Chased` em quadro |
| R13 wave-clear (1 Hollow parado, falha travada) + R-M trickle por timer (`Timer.after`/`Timer.every`, teto `waveCap`) | falha R13 `RUNTIME_VALIDATED` (travou); trickle fonte `STATICALLY_VALIDATED` + disparo `RUNTIME_VALIDATED` só p/ toast "Onda 4" em R14; perseguição/Hollow visível seguem `NOT_VALIDATED` |
| R14 telegrafia wave→chase→critical (`cap-r14-chased.png`: toast `danger` Onda 4 + `Chased` + `LANTERNA FRACA`); intenção R-N (hierarquia por cor/peso/posição) | telegrafia `RUNTIME_VALIDATED` só em pixels; R-N intenção `NOT_VALIDATED` (nada de R-N no `src/`); Hollow/capela/portão seguem `NOT_VALIDATED` |
| R15 modelo INCONCLUSIVO (`makeHollow`/`Life.guard` lidos, sem silhueta em quadro — não carimbar Hollow); intenção R-O (olhos-par + tints); E2E restante capela/selo/`Won` + viewpoint gate-escape | telegrafia `RUNTIME_VALIDATED` (R14); modelo/E2E/R-O `NOT_VALIDATED` (nada de R-O no `src/`) |
| Lanterna R11 (poça de luz + `LANTERNA FRACA`, `cap-r11-courtyard.png`; `LanternGlow`/`Curve.remap`) | `RUNTIME_VALIDATED` (luz provada; flicker sob `Chased` segue `NOT_VALIDATED`) |
| Hall quente sem fonte (âmbar sem `PointLight` próprio; só `BellLight`/`Flame`/`GateLight`/`Lamp_*`/`LanternGlow`) | `NOT_VALIDATED` — leak vs feature, decisão @systems R-K como intenção, NÃO implementada |
| R12 PARCIAL (halo sem silhueta, âmbar-triplo `BellLight`/`HallLamp`/`Lamp_*`); intenção R-L (pulso `Bell` + `HallLamp` off-axis) | `NOT_VALIDATED` — veredito sobre fonte, intenção NÃO implementada, sem print novo |
| Visual (cap-r4/r5 sem player = diagnóstico; cap-r7-spawn-fixed = só mundo/spawn/HUD, não look; pacote moonlight R-G = intenção, sem print novo) | `NOT_VALIDATED` |
| R6 + fixes R-F (causa-mãe `Technology`; fixes: sem `Technology`, `LanternGlow` torso, vinheta radial `Vignette`/`UIGradient`, `DreadBloom` congelado) — R6 provou só HUD+spawn+logs, NÃO o mundo; pós-fix sem medida | `NOT_VALIDATED` — pendentes: spawn→torre pós-fix, close `Page1` a 10 studs |
| HUD em run sem player (cego por construção; só existe com player), flicker sob `Chased` + vinheta pendentes, próximos viewpoints eye-level (capela→altar, portão) | `NOT_VALIDATED` — pendente |
| Performance, E2E com ator | `NOT_VALIDATED` |
| Probes do contrato (`gate_requires_six_pages`, `flashlight_chapel_loop`, `hollow_hunts_by_sight` → `button_interaction` genérico; sem probe dedicado de perseguição/portão/lanterna no catálogo `rqe/probes.py`; `probe-registry` `runtime.interactions` reflete o mesmo mapeamento) | `NOT_VALIDATED` — placeholder sem evidência; @qa-gate decide probes dedicados |

Nada neste README autoriza release. Release exige run/manifest hash mais
evidência `RUNTIME_VALIDATED` (gameplay/runtime) via Studio Bridge.
Seed canônico: `GameConfig.seed` = 20260912 (dono do número);
`rqe.project.json` `release.seed` espelha.

## Inacabado, declarado

- Sem áudio publicado (sem asset ids; nada toca nada ainda).
- Sem DataStore (morte = renascimento local; sem persistência entre sessões).
- Sem mobile/console dedicado (contrato: desktop).
- Só `cap-r7-spawn-fixed.png` (mundo/spawn/dreno/HUD) + `cap-r8-page-collected.png` (coleta 0→1 + toast `page`) + `cap-r11-courtyard.png` (lanterna provada, Hall quente sem fonte) + `cap-r14-chased.png` (só telegrafia wave→chase→critical, sem Hollow visível); sem release candidate; R-J (terceira via), R-K (Hall), R-L (pulso Bell + HallLamp off-axis) NÃO implementados; R-M (trickle) implementada; R-N (hierarquia de telegrafia) e R-O (olhos-par + tints) NÃO implementadas; R15 INCONCLUSIVO p/ modelo (não carimbar Hollow); próximo E2E: capela→altar, portão/gate-escape, `Won`/selo.
- HUD invisível em Run sem player por construção (requer Play Solo); luz da lanterna provada R11, flicker sob `Chased` + vinheta pendentes.
- Sem wiring de quality no `rqe.project.json` (sem chaves `qualityFocus`/`probeRegistry`); sem medidas Studio (runtime/visual/E2E) — produtores marcados `DISABLED` no registry.
- Sem guarda late-join dedicada: quem entra após o selo quebrado ainda precisa tocar o `EscapePad` (ramo `sealBroken` + `Events.onPlayer`, `init.server.lua`) — lido na fonte, nunca medido. Pré-escape, late-joiner com 0 páginas recebe só um aviso (`adviseLateJoiner`, kind `page`): "Siga quem tem páginas" — sem mint de páginas, sem respawn de hall.
- "Hiper-realista" no teto do Roblox: Future + sombras + Atmosphere/Bloom/
  ColorCorrection e materiais PBR — não é path tracing, e este README não
  afirma que seja.
