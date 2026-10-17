# Aetherworks — Fábricas acima das nuvens

Tycoon para computador, criado com Forge e WorldKit. Quatro bases industriais disputam uma ilha central. O dinheiro financia expansão, evolução das máquinas, guarnições e expedições; relíquias e renascimentos mantêm objetivos depois da fábrica completa.

## Jogar e controles

Abra `aetherworks.rbxlx` no Roblox Studio e pressione Play. A versão normal começa com 100 coroas. Construa o extrator, extraia no veio e recolha o coletor; a construção 9 automatiza a coleta.

| Tecla | Ação |
|---|---|
| WASD / espaço / E | Mover / pular / interagir |
| B / M | Construções / melhorias infinitas das máquinas |
| G | Guarnição e formação |
| J | Contratos (também pelo pequeno objetivo no canto) |
| T / H | Viajar ao arsenal / voltar à ilha |
| L / R / O / P | Legado / presentes / opções / pesquisas permanentes |
| C / U | Coleção, projetos e semanais / casa e pets |
| Enter | Iniciar; construir no menu B; confirmar renascimento no menu L |
| F ou mouse esquerdo segurado / Q / X | Disparar / esquivar / sair da torre |

Os painéis começam fechados. A barra inferior abre os menus; B, M, G, J, L, R e O também fecham o respectivo menu. As opções numéricas mostradas no arsenal, legado e presentes são atalhos adicionais. Compras também funcionam pelos botões.

## Indústria e cristais

32 construções incluem três expansões de terreno e cinco pisos com escadas e elevadores. Os renascimentos 1 a 5 liberam construções exclusivas: distrito do vazio, observatório orbital e coração da singularidade. Cada máquina produtiva possui níveis próprios sem teto configurado, com compra de +1 ou +10 níveis. Terrenos e pisos não entram nessa lista. Evoluir uma máquina aumenta sua contribuição à produção, além do multiplicador da raridade:

| Nível da máquina | Cristal | Valor da raridade |
|---|---|---|
| 1 | Aether azul | 1× |
| 5 | Esmeralda verde | 1,6× |
| 15 | Âmbar amarelo | 2,7× |
| 35 | Prisma violeta | 4,4× |
| 75+ | Obsidiana preta com aura violeta | 7× |

A produção continua aumentando depois do nível 75. As máquinas e seus cristais nas esteiras refletem a raridade; o veio manual acompanha a melhor raridade desbloqueada. Os preços crescem por uma curva polinomial. Limites numéricos de segurança não representam níveis finais de conteúdo.

## Disputa pelo centro

O terreno central está configurado em 196 × 196 studs. Os centros das quatro bases estão a 296 studs do centro, conectados por pontes de 18 studs de largura. O círculo de captura tem raio de 28 studs. Arsenal e entrada da torre ficam fora do círculo de combate.

A guarnição abre após três construções. Comprar o primeiro nível recruta soldados; novos níveis aumentam vida e dano e liberam mais unidades, até seis por base. Treinamento continua depois disso. Vanguarda, defensores e atiradores marcham e enfrentam tropas rivais. Soldados derrotados recebem reforços automaticamente. As formações Equilibrado, Assalto e Guarda trocam velocidade, dano e resistência, com 20 segundos entre ordens.

Uma única facção no círculo por 18 segundos captura o centro. O dono recebe **1,5× na produção automática**. Rivais dentro do círculo suspendem o bônus; perder todos os soldados no círculo remove a posse. A disputa é entre tropas: jogadores podem visitar o porto sem sofrer ataques delas. A presença de outros jogadores reais é necessária para competição entre bases; não há adversários humanos simulados na versão normal.

Ordens adicionais: Conquistar persegue rivais, Defender limita a perseguição ao entorno do círculo e Reagrupar retorna à base, recuperando vida depois de seis segundos sem dano. As ordens têm recarga de cinco segundos. A árvore de comando permanente melhora vida e dano sem aumentar o orçamento de seis NPCs por ilha.

## Torre, legado e presença

A torre tem ondas sem limite configurado, inimigos progressivamente mais fortes e chefe a cada cinco ondas. Vendaval acelera inimigos; Legião Blindada aumenta resistência; Tempestade Astral exige sair das áreas roxas. Recompensas são creditadas a cada onda. Armas e armaduras avançadas continuam evoluindo por maestrias; pesquisa industrial também continua consumindo relíquias após os primeiros níveis.

Renascimentos exigem 20, 22, 24, 27, 29 e finalmente 32 construções, com reserva crescente de coroas. Reiniciam fábrica, níveis de máquinas e coroas; preservam equipamento, maestrias, tropas, pesquisas, calendário e legado. Núcleos liberam coleta magnética, drone e sobrecarga. A torre heroica abre após o primeiro renascimento.

P abre duas árvores permanentes. Legado exige os benefícios anteriores e fortalece indústria, combate, comando e reserva offline (até 24 horas). Pesquisa da torre gasta relíquias em dano, vida, esquiva e coleta de relíquias. A esquiva conserva recarga mínima de 0,8 segundo.

Bastiões reduzem dano recebido pela frente; tecelões curam aliados e devem ser priorizados. Elites aparecem a partir da onda 8. Condutores telegrafam disparos em linha; chefes alternam cruzes e anéis com áreas seguras e aceleram abaixo de 40% de vida. Vida e dano continuam crescendo após as antigas limitações, com até dez inimigos simultâneos por arena. Recordes a cada dez ondas concedem relíquias adicionais uma vez por marco.

Presentes por 5, 10, 20, 30 e 60 minutos ativos são resgatados uma vez por dia UTC. O calendário de sete entregas é acumulativo. Uma sequência separada de dias consecutivos concede até +35%; faltar um dia reinicia somente esse bônus. Visitas acumuladas concedem marcos em 3, 7, 14 e 30 dias. O tempo de recompensa pausa após três minutos sem atividade observada pelo servidor; a renda passiva da fábrica continua. A aurora coletiva dobra a produção por 40 segundos.

## Build e persistência

### Casa Aurora e pets

O lote residencial fica no anexo oposto à guarnição. Todas as ilhas recebem o mesmo projeto. U abre o menu; **Ir até a casa** leva à entrada, onde também existe um prompt de interação. A compra inicial custa 2.500 coroas e inclui Raposa de brisa (+6% produção) e Toupeira de aether (+12% no valor da mineração manual), ambas já hospedadas.

| Andar | Renascimentos exigidos | Custo em coroas | Espaços totais |
|---|---:|---:|---:|
| 1 | 0 | 2.500 | 2 |
| 2 | 1 | 80.000 | 4 |
| 3 | 2 | 600.000 | 6 |
| 4 | 3 | 3.000.000 | 8 |
| 5 | 5 | 18.000.000 | 10 |

Cada andar precisa ser comprado em sequência; ter renascimentos suficientes apenas libera a compra. Elevadores conectam somente andares construídos. A coleção tem dez pets, com adoção garantida em coroas e até cinco níveis individuais. Os pets ficam visíveis nas camas de sua casa. Selecione um espaço e um pet no menu para hospedá-lo; mover o mesmo pet remove sua ocupação anterior, e retirar um pet pausa seu bônus.

Os bônus de pets são somados dentro da categoria (produção ou mineração), depois multiplicam o ganho correspondente. A produção offline também considera os pets hospedados. O bônus manual afeta cristais extraídos do veio, sem multiplicar novamente o saque do coletor. Casa, andares, coleção, níveis e ocupação permanecem após renascer. Compras exigem proximidade da casa do próprio jogador, fundos e requisitos validados pelo servidor.

### Refinamento visual e objetivos adicionais

O kit original em `art/` fornece dezesseis malhas publicadas de cristais, máquinas, peças estruturais e equipamentos. O arsenal tem oficina e vitrines; guarnição e sobrecarga ocupam um anexo separado; o coletor tem cofre, funil e bandeja. Os menus de máquinas mostram os modelos atuais e após melhorias. A coleção registra cristais, três projetos de chefes, especializações, desafios semanais e decoração permanente.

Guarnições agora oferecem cinco funções, incluindo médico e artilheiro, escolha de composição, três rotas, prioridades de alvo e relés de cura. Rodadas locais de dez minutos concedem honra para decoração. A torre inclui escolhas entre ondas, seleção de alvo e uma implementação de expedição em dupla. A validação multiplayer desta revisão ainda está pendente; não tratar presença do código como prova de cooperação executada. Ranking global e pareamento por força continuam fora deste pacote.

```powershell
rojo build games/aetherworks/default.project.json --output games/aetherworks/aetherworks.rbxlx
```

`src/shared/TycoonConfig.lua` concentra economia e progressão. `World.lua` constrói a geometria; `Dominion.lua` controla tropas e captura; `Tower.lua` controla expedições. O servidor valida compras, propriedade, requisitos e recompensas. O cliente apresenta menus, cristais e animação.

Integrações: Forge.Save, Net, Economy.Balance, Tycoon.PlotAllocator, DropperChain, ThroughputLedger, UI, Feel, Audio, Telemetry, Testing, Rig, Anim, Combat, Nav e WorldKit.Build.

Um place local sem acesso a DataStore usa memória durante a sessão. Persistência entre sessões e servidores requer uma experiência publicada e acesso ao serviço. Este pacote de melhorias ainda precisa ser enviado ao lugar publicado. A suíte interna fica em `ReplicatedStorage.ForgeTests.Report`; recibos e capturas ficam em `artifacts/`. Perfis completos usados no Studio são fixtures de integração explicitamente identificadas, não progressão conquistada nem a experiência inicial normal. Build local e testes não autorizam lançamento.
