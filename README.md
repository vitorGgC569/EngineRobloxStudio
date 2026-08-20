# Roblox Quality Engine

Uma engine que prova que um jogo Roblox está correto, em vez de apenas gerar código.

## Studio Bridge — medição real dentro do Roblox

O canal que faltava entre o agente e o Roblox. Um plugin de Studio conecta-se a
um hub local; o agente envia comandos tipados e recebe respostas estruturadas do
DataModel real, cada uma carimbada com o contexto (`edit` ou `run`) em que foi
produzida.

```powershell
python rqe.py studio install .                              # instala o plugin
python rqe.py studio serve                                  # hub em 127.0.0.1:8790
python rqe.py studio restart .tmp\MinersRidgeTycoon-qa-v7.rbxlx .
python rqe.py studio measure . --start-run                  # artifacts/run-NNNNN/
```

`studio restart` é desassistido: encerra o Studio, **arquiva** os arquivos de
recuperação automática (o modal "Recuperação automática" some sem perder dados),
limpa o `.lock` órfão, abre o place e espera uma sessão nova do plugin.

`run.start` dá vida ao jogo por comando (`RunService:Run()`), sem automação de
teclado. `world.ground_support` prova apoio por raycasts reais;
`world.overlaps` prova exclusividade entre regiões por bounding boxes medidas.

A arquitetura completa, a matriz de capacidades e o status honesto de validação
estão em [docs/platform/](docs/platform/README.md).

> **Cuidado ao ler os scores do audit legado.** As 38 evidências de
> `python rqe.py audit .` vêm em sua maioria de `roblox/mvp/game-state.json`, um
> fixture escrito à mão — `frameMs: 12.4` nunca foi amostrado. Somente evidências
> com `source="studio-bridge"` são medições.

## O MVP original

Este repositório também contém um MVP executável do conceito descrito no objetivo:

- Game Contract declarativo em `contracts/`;
- 25 probes determinísticos para geometria, navegação, UI, gameplay, segurança, persistência, multiplayer e performance;
- scanner estático de scripts Luau para assets suspeitos;
- runtime headless que reproduz o cenário de compra, clique duplicado, reconnect e isolamento entre jogadores;
- score por categoria e release gate (`critical == 0`, `major == 0`, gameplay >= 95, persistence == 100, multiplayer >= 90);
- evidências JSON e relatório Markdown;
- dashboard estático em `apps/dashboard/`;
- jogo MVP Luau/Rojo em `roblox/mvp/`.

## Rodar

O MVP não depende de Node, banco ou pacotes externos em runtime. Requer Python 3.11+.

```powershell
python rqe.py audit .
python rqe.py verify .
python rqe.py fix .
python -m unittest discover -s tests -v
python rqe.py bridge demo . --mode blackbox
python rqe.py bridge operations
```

`audit` sempre grava `reports/latest.json` e `reports/latest.md`. `verify` retorna código diferente de zero quando o release gate é bloqueado. `fix` gera `reports/fix-plan.md` com as ações sugeridas para cada falha.

## Game Agent Bridge

O bridge permite que um agente externo observe e jogue o MVP usando uma API estável:

```text
game.start → game.observe → game.walk → game.interact → game.assert
```

`python rqe.py bridge demo . --mode blackbox` executa uma partida humana headless. Cada ação grava evidência BEFORE/ACTION/AFTER, screenshot lógico, estado visível, resultado e motivo. O modo blackbox não entrega `Workspace` nem posição interna ao agente; graybox fornece estado de jogador/UI/prompts; whitebox acrescenta diagnósticos, remotes e caminho interno.

Para conectar um relay local do Studio/MCP:

```powershell
python rqe.py bridge serve . --studio-url http://127.0.0.1:8765 --token dev-token
```

O servidor JSON-RPC do bridge escuta apenas em `127.0.0.1` por padrão e possui `/health` e `/rpc`. O `StudioGameAdapter` traduz ações para `playtest_start`, `screen_capture`, `console_read`, `character_navigation`, `user_keyboard_input` e `user_mouse_input`; o relay Luau oferece as leituras `quality_probe_observe`, `quality_probe_player`, `quality_probe_ui`, `quality_probe_nearby` e `quality_probe_raycast`.

## Executar o jogo no Roblox Studio

O projeto usa Rojo:

```powershell
rojo serve roblox/mvp/default.project.json
```

No Studio, instale/conecte o plugin Rojo e sincronize o projeto. O servidor cria o mapa, o spawn, a loja Basic Pack, quatro plots e o RemoteEvent server-authoritative. O fluxo do MVP é:

1. entrar no jogo e receber um plot isolado;
2. caminhar até `BasicPackStore`;
3. ativar `PurchasePrompt`;
4. gastar 100 de currency e receber `basic_mining_pack`;
5. ativar novamente sem duplicar o item;
6. sair e reconectar com o estado persistido.

O runtime de probes em `roblox/runtime/` fornece a prova física de `ground_support` via raycasts e o cenário de compra para integração com um harness de Studio/MCP.

## Evidência e dashboard

Depois de executar `audit`, abra `apps/dashboard/index.html` por um servidor estático local para visualizar o último relatório. O artefato canônico é `reports/latest.json`; cada evidência contém status, severidade, probe, mensagem, detalhes e fonte.

O MVP headless é a validação executada automaticamente nesta máquina. A captura de tela, pathfinding real, MicroProfiler e Playtest do Studio são pontos de integração do adapter/runtime Luau; eles não são simulados como se fossem evidência real.

## Estrutura

```text
apps/dashboard/             dashboard local do último relatório
contracts/                  Game Contracts .robloxqa em JSON
rqe/                        engine, probes, runtime, scoring e CLI
roblox/mvp/                 jogo de exemplo sincronizável pelo Rojo
roblox/runtime/             probes Luau executáveis dentro do Roblox
schemas/                    schemas do contrato, resultados e evidências
tests/                      testes unitários e testes de regressão do gate
reports/                    artefatos gerados pelo audit
```

## Próximos adapters

O núcleo já está separado da execução do Studio. A próxima camada pode implementar `StudioAdapter` para substituir o fixture headless por `playtest_start`, `console_read`, `character_move`, `screen_capture` e `input` do Studio MCP, preservando o mesmo contrato de evidências e release gate.
