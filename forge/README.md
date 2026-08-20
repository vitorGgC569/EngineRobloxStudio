# Forge — a metade de autoria

A Quality Engine prova que um jogo está correto. Forge é o que você usa para
fazer um que valha a pena provar.

## A regra

**Forge nunca escreve gameplay.** Não existe `Forge.makeTycoon()`, não existe
template de gênero, não existe gerador. Forge entrega primitivas que você usa
para escrever o jogo.

Isso não é preferência de estilo. É a correção do erro que produziu 32 jogos em
`games/` com 3.276 linhas cada e seis linhas de diferença entre eles: quando o
gerador escreve o jogo, o gerador vira o teto. `rqe/implement/emitter.py`
(função `_playable_source`, 800 linhas) *é* aquele teto. Forge existe para que
o teto seja o que você consegue imaginar, não o que coube num f-string de
Python.

Um corolário prático: se um módulo de Forge começar a decidir o que o jogo é,
ele deixou de ser engine.

## Rodar

```bash
python forge/forge.py new meujogo
python forge/forge.py doctor meujogo
python forge/forge.py build meujogo
```

O esqueleto criado não tem gameplay — só o wiring: contrato de rede,
persistência, containers e a seam de debug. Você escreve os sistemas em
`src/server/systems/`.

Para ver uma fatia vertical de verdade construída sobre as primitivas:

```bash
python forge/forge.py build provingground
```

`games/provingground` é uma arena procedural com três tipos de inimigo, combo
de três golpes, esquiva com i-frames, bloqueio direcional e HUD. Usa os doze
módulos e não tem uma linha de conteúdo vinda da engine.

## Os módulos

| Módulo | O que resolve |
|---|---|
| `Core` | Signal, Trove, Spring, Ease, Rng, Sched — sem opinião sobre Roblox |
| `Data` | tabelas de conteúdo com shape declarado; typo vira erro no load |
| `Net` | barramento tipado, validado e com rate limit; nada indeclarado trafega |
| `Save` | perfis com session lock, migração e retry |
| `Rig` | personagens montados por código, R6, com trilha de arma |
| `Anim` | animação procedural em camadas **com marcadores** |
| `Feel` | shake, hitstop, números de dano, impacto, knockback |
| `Combat` | pipeline de dano com modificadores, hitbox em arco, status, projéteis |
| `Actor` | máquinas de estado, percepção, steering, população — tudo num loop só |
| `World` | heightfield composto por camadas, pintura de voxel, scatter determinístico |
| `UI` | tokens e widgets, para a interface parecer desenhada |
| `Entity` | componentes e sistemas: nada é Player nem NPC, tudo é o que carrega |
| `Assets` | `Assets.spawn("Enemy.Orc", cf)` — producers, templates, placeholder visível |
| `Scene` | mundo como tabela de placements, serializável e editável |
| `Streaming` | camada de chunks própria: existência, não só replicação |
| `Editor` | overlay de autoria sobre Scene, com as mesmas operações que um agente usa |
| `Events` | barramento nomeado + auditoria de quem ouve o quê |
| `Inventory` | containers genéricos: mochila, baú, loja e cadáver são a mesma coisa |
| `Quest` | objetivos como filtros de evento |
| `Progression`, `Ability`, `Interaction`, `Dialogue` | níveis, cooldowns, prompts, conversa |
| `Input` | ações, não teclas: teclado, gamepad e toque da mesma declaração |
| `Audio` | cues agrupados, com pool, variação de pitch e ducking |
| `Visual` | direção de arte como dado: looks, grading, paletas, tiers por device |
| `Telemetry` | funis, marcos, erros agregados por assinatura, sinks à sua escolha |
| `Monetization` | passes e produtos com recibo idempotente |
| `Bench` | carga medida, e honesto sobre o que não consegue medir |
| `Debug` | como o jogo em execução se explica — a seam com a metade de validação |

`python forge/forge.py engine` lista a API pública inteira.

## As três decisões que importam

**Animação é dado, com marcadores.** Um clipe carrega o frame em que a espada
passa a machucar (`{ t = 0.26, name = "hit" }`) na mesma tabela em que carrega
a pose. Mexeu na pose, a janela de dano vem junto. É isso que torna timing de
combate ajustável sem tocar em lógica de combate — e é o que animação autoral
via Animation Editor não permite a um agente, porque exige um humano numa GUI
para cada mudança de timing.

Quando você tiver um animador de verdade, mantenha os nomes dos clipes e dos
marcadores e troque a fonte da pose. Todo sistema que ouvia `"hit"` continua
funcionando.

**Determinismo fica onde ele serve.** `Rng` tem streams nomeadas derivadas de
uma seed mestra: `Rng.stream("world")` e `Rng.stream("loot")` são independentes
e reproduzíveis. Regenerar o mesmo mundo com drops diferentes passa a ser
possível, e um bug de ontem reproduz hoje. Determinismo é a propriedade certa
para *provar* e a errada para *criar* — por isso ele está confinado a um módulo
de 180 linhas em vez de estruturar a engine inteira.

**O servidor nunca confia no cliente, por construção.** Um evento que não está
em `Net.define` não existe. Todo pacote c2s passa por shape check e rate limit
antes do seu handler ver. A defesa não é vigilância, é fazer o caminho inseguro
mais difícil de escrever que o seguro.

## A seam

`Debug.expose()` publica uma `StringValue` em `ReplicatedStorage.ForgeDebug.Snapshot`
com JSON do que o jogo sabe sobre si mesmo: estados dos atores, contadores,
tunables, expectativas violadas, performance.

E é `StringValue` e não `BindableFunction` por um motivo medido: **BindableFunction
não cruza a fronteira cliente/servidor.** O `OnInvoke` fica preso na VM que o
criou, então um handler no servidor é invisível para o `client.invoke_bindable`
do plugin — a primeira versão desta seam parecia ligada e retornava `null` para
sempre. Um StringValue replicado é lido por `dm.properties` em qualquer contexto,
com um comando que já existia.

```bash
python rqe.py studio serve            # em outro terminal
python forge/forge.py probe
```

É assim que a metade de validação passa a medir **sentido** e não só geometria.
Raycast prova que existe chão; só o jogo sabe dizer que quarenta atores estão
travados no mesmo estado há um minuto.

Na direção contrária, `forge doctor` empresta o compilador Luau que a Quality
Engine já mantém em `.tools/luau`. Rojo empacota arquivos, não os compila — uma
place pode buildar limpa a partir de código que nunca roda. O doctor pega isso
com arquivo e linha antes de chegar no Studio.

## Tunables ao vivo

```lua
local cooldown = Debug.tunable("fight.comboWindow", 1.1)
if now - last < cooldown() then return end
```

```bash
python forge/forge.py probe --command set --argument fight.comboWindow
```

Mudar um número numa sessão rodando e observar o efeito é o ciclo de iteração
mais curto que a plataforma permite. O getter é uma função de propósito: guarde
o valor num local e você saiu do sistema de tuning sem perceber.

## O editor

`Debug.expose()` deixa o jogo se explicar; `Editor` deixa você mexer nele.

```lua
Editor.attachStreamer(streamer)
Editor.open(scene)
Editor.serve()          -- servidor: único mutador, com autorização
```

```lua
EditorUi.mount()        -- cliente: F4 abre o overlay
```

Paleta de assets (populada sozinha do registro), viewport que é o próprio jogo,
inspector com transform e ações, console. Grid com snap, undo/redo real, e um
`Save` que serializa a scene inteira em JSON.

O ponto que decide se é engine ou brinquedo: **a UI não tem nenhuma operação que
a automação não alcance**. Cada botão envia o mesmo `EditorOp` que um agente
envia pela ponte:

```bash
python rqe.py studio call client.fire_remote --params '{
  "path": "ReplicatedStorage.ForgeNet.EditorOp",
  "args": [{"op": "place", "data": {"asset": "Prop.Rock", "position": [30, 34, 30]}}]
}'
```

Verificado medindo: 4 `place` levaram a scene de 453 para 457 placements, `nudge`
e `rotate` empilharam undo, dois `undo` e um `redo` deixaram a pilha simétrica.

## Streaming

O `StreamingEnabled` da Roblox streama *replicação*: o servidor continua segurando
cada instância. `Streaming` streama *existência*.

```lua
local streamer = Streaming.attach(scene, {
    chunkSize = 48, loadRadius = 180, unloadRadius = 250, budget = 14,
})
streamer:pin(dockPosition, 40)
streamer:start()
```

Raios de carga e descarga diferentes de propósito: com um só, quem anda numa
fronteira faz o chunk entrar e sair a cada tick. E materialização com orçamento,
senão entrar num chunk denso cria 400 instâncias num frame.

Medido no Lanternreach: **59 de 453 placements instanciados sem jogadores** (só os
pins), 424 partes no Workspace em vez de 2764.

## Produção

O que separa demo de jogo que pode ir ao ar, e onde cada peça está.

**Mobile não é opcional.** Metade do Roblox está no celular. `Input` declara
ações, e uma tabela `touch` é o port inteiro daquela ação:

```lua
Input.defineActions({
    strike = { keyboard = Enum.UserInputType.MouseButton1,
               gamepad  = Enum.KeyCode.ButtonR2,
               touch    = { label = "Strike", order = 1 } },
})
```

Um teste do repo falha se um arquivo de jogo tocar `UserInputService` direto, e
outro falha se uma ação existir sem `touch`.

**Save que não perde progresso.** Checksum estável em cada escrita, três backups
rotativos, `Save.rollback`, e quarentena do perfil corrompido em vez de
sobrescrita. Um perfil que não bate com o próprio checksum não chega ao jogo.

**Recibo que não concede duas vezes.** O `grant` acontece *dentro* do
`UpdateAsync`, chaveado pelo `PurchaseId`. Conceder fora da transação é como um
retry da Roblox vira item duplicado — e a Roblox repete até você retornar
`PurchaseGranted`.

**Telemetria desde o primeiro boot.** Funis por assunto, marcos únicos, erros
agregados por assinatura (uma linha quebrada num Heartbeat vira uma entrada com
contagem, não onze mil linhas iguais). O destino é seu: registre um sink.

## Números medidos

Todo número de performance que esta engine tinha vinha de uma sala vazia.
`forge bench` roda dentro de uma sessão viva:

```bash
python rqe.py studio call run.start --params '{"settleSeconds": 20}'
python forge/forge.py bench --entities 8000 --anchors 30
```

```
  case                                      median       p95       max
  entity.query.pair.8000                    0.564ms    0.817ms    0.867ms
  entity.query.single.8000                  1.108ms    1.668ms    2.088ms
  streaming.tick.30Anchors                  0.403ms    2.596ms    2.993ms
```

Mediana e p95, nunca média: a média esconde o frame de 40ms, e o frame de 40ms é
o que o jogador sentiu.

O benchmark já pagou por si: a query de entidade custava 1,40ms porque
`Entity.query` ordenava o array de ids a cada chamada. Sem o sort, 1,11ms — 20%,
não a ordem de grandeza que o formato do fix sugeria. A lição real é o
orçamento: a 20Hz isso ainda é 22ms por segundo, e um sistema que toca toda
entidade todo tick não escala por mais rápido que o loop fique.

O que ele **não** mede, e diz isso na saída: banda de replicação por cliente,
frame time do cliente, latência de input em rede real, throughput de DataStore.
Roblox recusa criar um `Player` por script, então isso precisa de gente de
verdade.

## O que Forge não faz

Não faz arte, som, nem animação autoral. Não decide o core loop, não desenha
progressão, não sabe se o seu jogo é divertido. Não substitui playtest.

Ela encurta a distância entre uma ideia e uma build que roda, e torna o
resultado mensurável. O julgamento continua sendo humano.
