# Auditoria da Roblox Quality Engine / Forge — 5 de setembro de 2026

**Nota atual: 5/10.** Avaliação técnica do estado encontrado no workspace, considerando a capacidade de produzir, testar e entregar jogos de qualidade com consistência. É um julgamento fundamentado, não uma pontuação oficial do release gate nem uma previsão comercial.

O projeto já permite construir e executar jogos. O maior limitador é a distância entre a quantidade de recursos disponíveis e a confiabilidade da integração entre autoria, execução, observação e publicação. Há defeitos reproduzíveis em fundamentos que qualquer jogo com progressão precisa: salvar dados, processar recompensas, validar pacotes e vincular uma aprovação ao conteúdo publicado.

| Dimensão | Nota | Base da avaliação |
|---|---:|---|
| Recursos de construção e controle | 8/10 | Biblioteca ampla; dois consumidores compilados e executados; personagem real movimentado; compra com moeda do jogo concluída. |
| Confiabilidade e integração | 4/10 | Defeitos reproduzíveis de persistência, recibos, validação de rede, navegação e captura; suíte local ainda vermelha. |
| Qualidade do produto demonstrada | 3/10 | Experimentos pontuais funcionam, mas faltam provas completas de experiência, dispositivos, persistência real e release dos consumidores. |

As notas por dimensão são qualitativas. Não constituem uma média de testes aprovados. Uma suíte com muitas verificações estáticas pode passar enquanto uma função essencial permanece incorreta.

## Escopo e honestidade da cobertura

O trabalho foi realizado **sem subagentes**. Houve inventário, leitura de documentação e caminhos críticos, compilação, testes locais, execução em Studio e reproduções com falhas simuladas.

O inventário inicial reuniu **4.075 arquivos textuais e 1.099.153 linhas**, incluindo código, documentação, dados gerados e kits importados. Não inclui o conteúdo de dependências externas, binários, arquivos ignorados ou todo o histórico Git.

**Não concluí uma revisão semântica manual de cada uma dessas linhas.** A cobertura de todo o inventário é automatizada; a leitura detalhada se concentrou nos fundamentos e integrações descritos abaixo. Compilar todos os arquivos não equivale a revisar todos os comportamentos. Esta é uma auditoria ampla com aprofundamento orientado por risco e execução, não uma certificação integral linha por linha.

| Área | Arquivos do inventário | Linhas |
|---|---:|---:|
| RQE / Python | 221 | 80.768 |
| Forge, incluindo kits e catálogos | 2.332 | 714.759 |
| Jogos consumidores | 1.115 | 205.854 |
| Roblox / MVP / bibliotecas | 143 | 37.415 |
| Testes | 108 | 25.347 |
| Aplicações / plugin | 32 | 8.610 |
| Documentação em docs | 30 | 4.246 |

As demais linhas estão em schemas, contratos, ferramentas, instruções e arquivos da raiz. A classificação `project` da varredura significa que o arquivo está fora do diretório de salvage; não comprova autoria original ou licença de cada trecho.

Rastreabilidade: [inventário inicial](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/.tmp/audit-2026-09-05/inventory.json), [resultado por arquivo com SHA-256 e tipo de checagem](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/.tmp/audit-2026-09-05/static-sweep.json), [resumo da varredura](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/.tmp/audit-2026-09-05/static-summary.json).

O workspace já continha muitas alterações e arquivos novos antes da auditoria. A avaliação se refere a esse estado de trabalho, não exclusivamente ao último commit. As alterações de implementação preexistentes foram preservadas. Não corrigi silenciosamente o catálogo ou os módulos durante a medição da situação inicial.

A conferência final encontrou alteração de hash em três arquivos MeshKit do consumidor kb-escape desde a varredura: `reef_landmark.lua`, `hub_landmark.lua` e `cave_landmark.lua`. Eles foram recompilados com sucesso; não atribuí a mudança a um autor ou processo sem evidência. Os demais arquivos inventariados conservaram os hashes medidos. [Conferência de cobertura](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/.tmp/audit-2026-09-05/coverage-final-check.json), [rechecagem dos três arquivos](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/.tmp/audit-2026-09-05/changed-files-recheck.json).

## O que foi realmente executado

| Experimento | Resultado | Nível e limite da evidência |
|---|---|---|
| Compilação Luau do inventário | 1.211 arquivos classificados como projeto compilaram. Dos kits importados, 1.564 compilaram e 2 falharam. | `STATICALLY_VALIDATED`; não é execução de todos os módulos nem checagem completa de tipos. |
| Sintaxe Python e JSON | 363 arquivos Python passaram no parser; 805 JSON válidos. | `STATICALLY_VALIDATED`; não prova importação, semântica nem todos os schemas. |
| unittest | 1.367 testes, 7 failures, 9 errors, 1 skip. | `STATICALLY_VALIDATED`; suíte local, inclui testes com simulações. |
| pytest completo | **1.670 passed, 16 failed, 1 skipped**, mais 104 subtests passed; 692,33 segundos. | `STATICALLY_VALIDATED`; inclui funções que o unittest não coleta. As duas contagens não devem ser somadas. |
| Rojo / MVP | Build de MinersRidgeTycoon concluído. | `STATICALLY_VALIDATED`. |
| Forge / Proving Ground | Build concluído; doctor sem achados. | `STATICALLY_VALIDATED`; doctor não antecipou a falha de navegação observada ao executar. |
| MVP em Run | 1.833 instâncias no Workspace; 106 ProximityPrompts; nenhum jogador nesse modo. | `RUNTIME_VALIDATED`; geometria gerada em Studio. |
| MVP em Play Solo | Personagem real andou aproximadamente 202 studs até a loja; compra mudou moeda de 1.000 para 900 e coleção de 1 para 2 cartas. | `RUNTIME_VALIDATED`; diagnóstico gray-box com caminhos internos. Não é prova black-box. |
| Proving Ground em Play Solo | 38 cenários: **32 passaram e 6 falharam**, em 39,015 segundos. | `RUNTIME_VALIDATED`; cenários instrumentados dentro do jogo, com bots; não equivalem a 38 jornadas humanas. |
| Capturas dos dois consumidores | Imagens reais do Studio inspecionadas. | `VISUALLY_VALIDATED` apenas quanto ao conteúdo visível dessas imagens; pose certificada da câmera não foi validada. |
| Release oficial | `BLOCKED`, `releaseAllowed=false`; manifesto e 13 artefatos verificados por hash. | Resultado do gate verificado; não autoriza publicação. |
| Bridge demo blackbox | Comando executado com adapter headless. | Evidência de fixture/simulação; **não** `E2E_VALIDATED` em Studio. |

Logs: [pytest](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/.tmp/audit-2026-09-05/pytest.log), [unittest](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/.tmp/audit-2026-09-05/unittest.log), [cenários Proving Ground](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/.tmp/audit-2026-09-05/provingground-suite.json), [compra real com moeda de jogo](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/.tmp/audit-2026-09-05/store-interact-correct.json), [trajeto real](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/.tmp/audit-2026-09-05/walk-store-anchor.json).

No Proving Ground, cinco falhas dependem de DataStore indisponível em um place local não publicado. A sexta foi uma falha funcional de navegação. Não houve publicação, compra de Robux ou experimento com dados de jogadores em produção.

O comando inicial `forge gametest provingground` informou que o jogo não iniciou. A recuperação pelo lifecycle permitiu iniciar Play Solo e ler o relatório do próprio jogo. Isso documenta uma falha da primeira tentativa de inicialização, não uma incapacidade permanente de executar o consumidor.

## Achados prioritários e como resolver

### 1. P1 — Um perfil temporário pode sobrescrever um save legítimo

**`STATICALLY_VALIDATED`, reproduzido com Luau e serviços falsos explícitos.** Não foi provocado em um DataStore real.

Em [Save: carregamento](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Save/init.lua:236), um lock de outro servidor cancela o `UpdateAsync`, mas o carregamento continua com um perfil temporário normal. Esse perfil entra na tabela de perfis e pode ser salvo. Em [Save: escrita](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Save/init.lua:412), `SetAsync` substitui o registro sem conferir novamente quem possui a sessão.

A reprodução partiu de 500 gold e lock pertencente a outro servidor. O módulo entregou um perfil com 0; após uma alteração local para 1, `Save.write` substituiu o registro persistido por 1. O mecanismo de proteção da sessão foi, portanto, contornado pelo próprio fluxo de fallback.

**Correção:** representar explicitamente `LOADING`, `READY`, `BUSY`, `UNAVAILABLE` e `RELEASED`; um perfil sem posse válida nunca pode escrever. Usar `UpdateAsync` com identificação única de sessão e geração de posse, verificar essa posse em cada gravação e invalidar escritores antigos. Falha de carregamento deve preservar o dado original e produzir um estado indisponível ou uma sessão temporária estritamente sem persistência.

**Aceitação:** duas sessões disputando o mesmo perfil; expiração de posse; servidor antigo voltando depois de outro assumir; timeout de leitura; falha após commit; todos devem preservar o registro e rejeitar o escritor sem posse.

### 2. P1 — Liberar a sessão não remove o lock; migrações podem avançar após falhar

**`STATICALLY_VALIDATED`.** A retenção do lock foi reproduzida no mesmo teste local do item anterior. Os problemas de migração e encerramento foram identificados na leitura do código.

[Linha 373 de Save](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Save/init.lua:373) usa `release and nil or jobId`. Quando `release` é verdadeiro, o resultado continua sendo `jobId`: a expressão não implementa uma seleção cujo resultado verdadeiro pode ser `nil`.

[Migração](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Save/init.lua:115) apenas avisa quando uma etapa falha e depois marca a versão final. Também substitui o número de uma versão mais nova pela versão configurada. [BindToClose](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Save/init.lua:519) espera um intervalo fixo após disparar gravações, sem comprovar que terminaram.

**Correção:** atribuição explícita do lock; migração em cópia, com commit somente após todas as etapas; recusa de downgrade não planejado; coordenador de encerramento que acompanhe gravações até um prazo, registrando as que não terminaram. Reutilizar uma implementação robusta entre Forge, GameKit e consumidores, mantendo adapters de compatibilidade.

**Aceitação:** reentrada imediata após saída limpa; migração que lança erro na etapa intermediária; perfil de versão futura; gravação lenta durante fechamento.

### 3. P1 — A recompensa de um recibo pode ser concedida duas vezes

**`STATICALLY_VALIDATED`, reproduzido com o módulo original e um `UpdateAsync` simulado.** Nenhuma compra real foi feita.

[Monetization](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Monetization/init.lua:205) chama `product.grant(player)` dentro do callback de `UpdateAsync`. O callback pode ser reexecutado quando há disputa; descartar o resultado da tentativa não desfaz uma alteração já realizada no inventário ou no saldo.

Na reprodução, duas chamadas do callback geraram **duas concessões**, enquanto o módulo reportou uma e retornou `PurchaseGranted`. A documentação oficial confirma a possibilidade de repetição do callback e de processamento de um recibo em servidores simultâneos. [GlobalDataStore](https://create.roblox.com/docs/reference/engine/classes/GlobalDataStore#UpdateAsync), [ProcessReceipt](https://create.roblox.com/docs/reference/engine/classes/MarketplaceService#ProcessReceipt).

**Correção:** registrar o identificador do recibo e sua alteração durável de inventário/saldo na mesma transação de perfil, por uma transformação sem efeitos externos. Aplicar à sessão o resultado confirmado. Para efeitos fora do perfil, usar entrega durável e idempotente. Apenas mover `grant` para depois do `UpdateAsync` cria outra janela de perda; é necessário definir a atomicidade da entrega.

**Aceitação:** callback repetido, dois servidores, repetição do recibo, jogador desconectando e falha entre gravação e confirmação. A entrega final deve ocorrer exatamente uma vez no domínio persistido.

Reprodução dos itens 1–3: [resultado](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/.tmp/audit-2026-09-05/data-bug-reproducer.json), [script reproduzível](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/.tmp/audit-2026-09-05/reproduce_data_bugs.py).

### 4. P1 — Um validador personalizado desativa a validação de formato de rede

**`STATICALLY_VALIDATED`, reproduzido em Luau com serviços falsos.**

[Net.define](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Net/init.lua:146) só cria a checagem de `shape` quando não existe `check`. A documentação do tipo diz que o validador personalizado roda depois do formato. No caminho real de [recebimento](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Net/init.lua:319), somente `def.check` é usado.

A reprodução definiu `item="string"` e um `check` de permissão. Um pacote com `item=123` e campo extra chegou ao handler. Isto demonstra o defeito da composição dos validadores; não demonstra que todos os jogos consumidores sejam exploráveis.

**Correção:** compor verificadores independentes: limite de frequência, formato, limites do conteúdo e autorização. Capturar exceções de validadores e rejeitar o pacote. Preço, posse, alvo e distância devem continuar sendo decididos pelo servidor.

**Aceitação:** testar `shape` sozinho, `check` sozinho e ambos; tipo errado, campo desconhecido, NaN, payload excessivo, validador que lança erro e usuário sem autorização.

### 5. P1 — O caminho de publicação não usa a autoridade imutável exigida pelo projeto

**`STATICALLY_VALIDATED`, com reprodução local sem rede.**

[cmd_publish](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/forge.py:917) consulta um recibo mutável de `forge playtest`. [stamp](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/cli/playtest.py:96) identifica o build apenas por tamanho e data de modificação truncada em segundos. Não verifica um `run.json` finalizado com evidências vinculadas por hash, como exigem AGENTS e o charter.

No teste, dois arquivos de 12 bytes com conteúdos e SHA-256 diferentes, mas mesmo tamanho/data, receberam a mesma aprovação: `read_receipt` retornou `true, "passed"`. O teste não chamou o uploader. A função de escrita do recibo também aceita um `Report` vazio; o caminho normal de playtest possui uma defesa contra ausência de medições, mas essa garantia não é verificada no ponto final de publicação.

**Correção:** tornar a verificação do manifesto imutável a condição obrigatória do upload de release, incluindo `productId`, contrato, build, evidências e SHA-256 dos bytes que serão enviados. Abrir/congelar os bytes dentro da operação protegida para evitar mudança entre verificação e envio. Um override diagnóstico não deve fabricar aprovação de qualidade. Rollback precisa recuperar bytes comprovados e sua cadeia de proveniência.

**Aceitação:** recibo alterado, tamanho/data iguais com conteúdo diferente, evidência de outro jogo, captura de outro build, troca do arquivo após checagem, artefato removido e rollback sem manifesto devem ser recusados.

Evidência: [colisão do recibo](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/.tmp/audit-2026-09-05/receipt-reproducer.json).

### 6. P1 — A captura certifica continuidade de uma câmera que não é a do jogador

**`RUNTIME_VALIDATED` para a divergência de dados; `VISUALLY_VALIDATED` para a imagem inspecionada.**

[Camera.lua](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/apps/studio-plugin/src/Commands/Camera.lua:15) usa `Workspace.CurrentCamera` do contexto em que roda. [capture._camera_response](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/rqe/capture.py:359) corrige a dimensão 1×1 solicitando `client.viewport`, mas conserva posição, orientação e tipo de câmera do servidor.

A captura do MVP foi marcada `trustworthy=true` com câmera `Fixed` em `[0,20,20]`. A câmera real do cliente era `Custom`, aproximadamente `[-11,97;12,89;47,60]`. A imagem é real, mas os metadados não provam que ela representa a pose certificada.

**Correção:** obter e aplicar a pose completa no cliente correto; vincular jogador, sessão, processo e viewport; comparar o mesmo contexto antes e depois. Se não houver câmera cliente verificável, emitir `INCONCLUSIVE` em vez de completar seus dados com outra câmera.

**Aceitação:** movimentar a câmera cliente enquanto a do servidor permanece parada; alternar cliente; fechar viewport; capturar janela diferente. A certificação deve detectar cada divergência.

Evidências: [metadados da captura](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/.tmp/audit-2026-09-05/player-spawn-capture.json), [câmera real do cliente](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/.tmp/audit-2026-09-05/camera-client-actual.json).

### 7. P1 — Navegação pode sobrepor cálculos e não concluir um trajeto simples

**`RUNTIME_VALIDATED` para a falha no Proving Ground; `STATICALLY_VALIDATED` para a corrida reproduzida.** A reprodução não isola todos os fatores físicos responsáveis pela falha no mapa.

O cenário `an agent follows a path and arrives` falhou após 25 segundos: `Success`, 21 waypoints, **200 repaths**, 1 stuck. Encontrar um caminho não produziu chegada.

Em [Nav:_repath](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Nav/init.lua:135), os campos que limitam a frequência são atualizados depois de `ComputeAsync`, que pode suspender a coroutine. [Nav.start](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Nav/init.lua:316) chama `_step` a partir de Heartbeat sem impedir a reentrada. A simulação de três frames com cálculo pendente abriu três cálculos simultâneos para o mesmo agente.

**Correção:** marcar cálculo em andamento antes da suspensão; usar geração para descartar resultados antigos; separar seguir waypoints de recalcular; limitar a fila global de pathfinding; cancelar resultados após stop; modelar chegada e standoff como estados explícitos. Investigar o rig, colisões e posse de rede no cenário que falhou antes de declarar resolvida toda a navegação.

**Aceitação:** um agente, alvo móvel, passagem estreita, obstáculo dinâmico e grupo de agentes; chegada física comprovada, um cálculo pendente por agente e nenhum resultado aplicado depois de cancelado.

Reproduções dos itens 4 e 7: [resultados](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/.tmp/audit-2026-09-05/nav-net-reproducer.jsonl), [script](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/.tmp/audit-2026-09-05/reproduce_nav_net.py).

### 8. P1 — A superfície de controle ainda não permite a jornada black-box demonstrada pelo projeto

**`STATICALLY_VALIDATED` para a falha do wrapper; `RUNTIME_VALIDATED` para as respostas de indisponibilidade do bridge.**

O comando `client.gui_click` foi recusado como indisponível. O fallback [federated_call](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/rqe/mcp/world_tools.py:380) instancia `StudioMcpClient()` sem o argumento `peer`; depois tenta `spawn()` sem o comando exigido. Uma chamada real ao registry MCP retornou `TypeError` antes de acionar teclado ou mouse.

Foi possível andar e interagir usando o adapter semântico de ator. Como o diagnóstico precisou localizar instâncias internas, esse trajeto não é uma prova de que um agente encontra e usa a loja apenas pela visão e pelos controles de jogador.

**Correção:** reparar a federação de acordo com a API real, anunciar somente capacidades utilizáveis e executar uma jornada com observações e ações permitidas a um jogador. Usar os mecanismos suportados pelo ambiente; uma indisponibilidade de input deve continuar explícita. Hooks internos continuam úteis para diagnóstico, sem serem contabilizados como black-box.

**Aceitação:** começar no spawn, reconhecer a oferta, caminhar, abrir a interface, comprar, verificar feedback e repetir após reentrada, sem nomes internos de instâncias, pivôs ou saldo lido diretamente.

Evidências: [erro da federação](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/.tmp/audit-2026-09-05/federated-input-failure.json), [resposta GUI](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/.tmp/audit-2026-09-05/ui-click-base.json).

### 9. P2 — O observador de objetivos envia prompts a um resolvedor espacial incompatível

**`RUNTIME_VALIDATED`.** A medição produziu 12 erros `world.path` porque o destino era um `ProximityPrompt`. [Resolve.spatial](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/apps/studio-plugin/src/Resolve.lua:141) não resolve esse tipo para seu suporte espacial. O mesmo aconteceu ao navegar diretamente ao prompt. Navegar ao balcão funcionou.

Além disso, [observe._measure_navigation](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/rqe/observe.py:772) descobre no máximo 40 prompts e percorre apenas os primeiros 12 objetivos. Um jogo maior pode ter objetivos obrigatórios fora dessa amostra.

**Correção:** criar um resolvedor reutilizável de posição e pontos de aproximação para BasePart, Model, Attachment e ProximityPrompt. Derivar os objetivos obrigatórios do contrato; paginar a descoberta; testar os spawns pertinentes; reportar cobertura incompleta quando houver amostragem.

**Aceitação:** prompt em Part, Model e Attachment, objetivo inacessível, mais de 12 objetivos e múltiplos spawns, sempre distinguindo erro de transporte, erro de resolução e caminho inexistente.

### 10. P2 — A medição chamada FPS não comprova a experiência de renderização do cliente

**`STATICALLY_VALIDATED` para o significado do código; `RUNTIME_VALIDATED` para as amostras coletadas.**

[Runtime.lua](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/apps/studio-plugin/src/Commands/Runtime.lua:48) calcula frequência a partir de Heartbeat. No servidor, isso mede a cadência dessa sessão. Não é prova de FPS gráfico no celular do jogador. Na auditoria, amostras de poucos segundos ficaram próximas de 60 Hz, com piores intervalos entre aproximadamente 19 e 22 ms.

Os 2–2,7 GB observados são memória da sessão/ambiente Studio medido, não consumo isolado comprovado do jogo em um aparelho alvo. A coleta curta de `studio measure` ainda pode falhar por limites exatos de 60/16,67, sem uma interpretação estável de percentis.

**Correção:** métricas separadas para servidor, renderização cliente, memória e rede; warmup; amostragem representativa durante combate, transições e carregamento; percentis e limites explícitos por dispositivo. Instrumentar os módulos Bench/Telemetry existentes e integrar os resultados ao run.

**Aceitação:** sessão longa, cliente real em aparelhos alvo, p95/p99 de frame time, crescimento de memória, custo por população e orçamento de tráfego. Usar regressões comparáveis, sem converter ausência de amostra em zero.

### 11. P2 — O catálogo e o ambiente de desenvolvimento ainda não estão consistentes

**`STATICALLY_VALIDATED`, com falhas locais executadas.** As 16 falhas do pytest se concentram na divergência do SHA-256 do manifesto de comandos registrado em `quality/production-capabilities.v1.json`. O esperado era `1326b552…`; o medido foi `348af2e1…`.

O bloqueio por divergência funciona corretamente. O problema é o estado inconsistente ter chegado ao fluxo normal de trabalho. Após revisar o novo manifesto, o comando existente `python rqe.py stamp --write` pode atualizar os hashes; depois é necessário reexecutar os testes afetados e a suíte completa.

**`STATICALLY_VALIDATED` por leitura do workflow; execução em runner limpo `NOT_VALIDATED`.** O [CI](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/.github/workflows/ci.yml:81) executa preflight e pytest sem uma etapa anterior que instale o projeto e suas dependências de desenvolvimento, e não instala Rojo. O preflight exige componentes que o workflow não provisiona explicitamente.

**Correção:** instalar `.[dev]`, Rojo e ferramentas Luau de forma reproduzível antes das verificações. O bootstrap deve verificar integridade dos downloads. Validar o caminho de uma máquina limpa para evitar depender do ambiente pessoal do autor.

### 12. P2 — Há duas integrações de qualidade com regras diferentes

**`STATICALLY_VALIDATED`.** O registry possui 18 produtores: 11 `AVAILABLE`, 4 `PARTIAL`, 1 `FIXTURE_ONLY` e 2 `DISABLED`. Cinco produtores disponíveis e integrados declaram nível acima de estático. Há bastante diferença entre registrar uma ferramenta e produzir evidência obrigatória em um release.

[forge quality](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/cli/quality.py:862) gera um descriptor sem `productIntent`, embora o release exija alinhamento de produto. O gerador sobrescreve contrato e descriptor ao ser chamado, apesar da orientação para editar os requisitos. Na leitura do resultado, [audit](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/cli/quality.py:987) escolhe diretórios pelo nome e busca arquivos sem verificar o manifesto e sem correlação explícita com o run acabado de executar.

Isso não demonstra que o gate RQE liberou algo indevido: o release executado foi corretamente bloqueado. Demonstra que a integração de autoria, diagnóstico e autoridade de release precisa ser concluída.

**Correção:** uma definição de projeto versionada e completa; geração idempotente dos campos derivados; política editável preservada; seleção de resultado pelo `runId` retornado pela execução; verificação do manifesto; produtores reais para cada requisito obrigatório. Integrar as medições já existentes antes de aumentar o catálogo de comandos.

### 13. P2 — Inicialização e contexto do plugin geram ruído e falhas recuperáveis

**`RUNTIME_VALIDATED` para os sintomas; `STATICALLY_VALIDATED` para a explicação do ambiente.** A verificação da assinatura do executável Studio falhou ao iniciar `powershell.exe` herdando o caminho de módulos do PowerShell 7. O executável Roblox tinha assinatura válida. Limitar `PSModulePath` ao diretório do Windows PowerShell no processo de inicialização permitiu o restart.

Nos dois consumidores, o plugin também executou um ciclo de HTTP no cliente e imprimiu repetidamente que HTTP só pode ser executado pelo servidor. Isso polui observação e dificulta distinguir erro de infraestrutura e erro do jogo.

**Correção:** sanitizar o ambiente do subprocesso de verificação sem desativar a validação de assinatura; inicializar o transporte HTTP apenas em contexto suportado; usar a ponte cliente instalada para observações cliente; deduplicar avisos e propagar erros estruturados de inicialização.

## O que impede jogos com acabamento melhor

**Diagnóstico apoiado nas duas capturas e na arquitetura inspecionada; não é uma classificação de todos os jogos do repositório.**

1. **Uma biblioteca não fornece direção de arte por si só.** No MVP, o spawn tem áreas muito claras, geometria simples e informação visual disputando atenção. No Proving Ground, a iluminação alaranjada domina chão, personagem e elementos da arena, com trechos escuros no entorno. São consumidores funcionais, mas as capturas ainda comunicam ambientes de teste. O catálogo de meshes, materiais e efeitos precisa ser usado dentro de uma linguagem visual coerente, com hierarquia, silhuetas e iluminação voltadas à jogabilidade.
2. **Qualidade visual automática tem alcance limitado.** O crítico de cenas mede defeitos como exposição, áreas planas e densidade; o próprio código diz que pontuação alta não significa atratividade. Sua calibração registrada é estreita. É necessário um corpus de referências independente por gênero/câmera, exemplos negativos e positivos e revisão da experiência em movimento. Aumentar densidade pode melhorar uma métrica e piorar leitura e desempenho.
3. **O ciclo completo de jogo não foi comprovado.** A compra do MVP funciona; isso não prova onboarding, progressão prolongada, retenção, recuperação após desconexão ou economia sustentável. O teste de um sistema precisa alimentar uma jornada: compreender, agir, receber feedback, progredir, falhar, recuperar e voltar.
4. **Mobile e controles são parte da autoria.** Textos pequenos, hotbar exibindo identificador técnico e instruções pensadas para teclado aparecem nos consumidores inspecionados. Forge já tem UI e Access; falta demonstrar composição consistente em resoluções, áreas seguras, toque e gamepad reais. Uma árvore GUI correta não basta.
5. **Os subsistemas precisam compartilhar contratos de ciclo de vida.** Forge, GameKit, WorldKit e componentes dos jogos têm responsabilidades sobrepostas. Isso não justifica reescrever tudo. Escolher uma implementação canônica para persistência, recibos, eventos e instrumentação reduz comportamentos incompatíveis sem remover as bibliotecas de autoria.
6. **Assets originais ainda exigem fechar o caminho até o jogo.** A documentação de criação reconhece que provider falso e outbox não provam geração real. Modelagem, upload, moderação, integração e verificação precisam concluir a mesma cadeia de proveniência. A linguagem de geometria atual é útil para objetos procedurais; seu vocabulário não expõe uma cadeia completa de armature, skinning, retargeting e exportação animada. Isso limita esse caminho específico para personagens autorais, sem significar que Roblox ou os módulos de animação sejam incapazes de usá-los.

Fontes locais: [crítico de cenas](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/rqe/scene/critic.py:1), [operações de geometria](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/rqe/geometry/program.py:37), [fronteira de criação de assets](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/platform/ASSET-CREATION.md).

Capturas reais inspecionadas: [MVP](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/.tmp/audit-2026-09-05/player-spawn.png), [Proving Ground](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/.tmp/audit-2026-09-05/provingground-live.png). Não certificam fidelidade a uma referência artística aprovada nem comportamento em dispositivos não testados.

## Features e evolução recomendadas

Estas propostas estão **`NOT_VALIDATED` como soluções implementadas**. A ordem prioriza remover obstáculos existentes, com critérios de conclusão observáveis.

| Ordem | Entrega | O que destrava | Critério de conclusão |
|---|---|---|---|
| 1 | Persistência e recibos com transações seguras | Progressão, inventário, economia e monetização confiáveis | Testes de disputa, repetição, falha e reentrada; execução em ambiente de DataStore próprio para testes. |
| 2 | Aprovação vinculada aos bytes publicados | Releases e rollback verificáveis | Uploader exige manifesto final íntegro do mesmo produto e conteúdo; testes negativos de troca de artefatos passam. |
| 3 | Controle e observação cliente integrados | Agente consegue testar a experiência de jogador | Jornada black-box completa, câmera cliente correta, sessão/processo identificados, falhas de input explícitas. |
| 4 | Navegação com fila e estados de movimento | NPCs, combate, seguidores e mapas menos planos | Cenário que falhou passa repetidamente; um cálculo por agente, chegada física e cancelamento corretos. |
| 5 | Produtores reutilizáveis de evidência | Contratos passam a corresponder a capacidades executáveis | Cada requisito obrigatório aponta para produtor real integrado, com cobertura e nível corretos. |
| 6 | Matriz de dispositivos e orçamento em gameplay | Experiência consistente em desktop, mobile e gamepad | UI e input testados por dispositivo; p95/p99, memória e rede medidos com carga representativa. |
| 7 | Pipeline de assets e acabamento com referências | Identidade visual, personagens e cenários próprios | Asset vai de brief a publicação e uso validado; materiais, colisão, escala, animação e direitos rastreados. |
| 8 | Dois consumidores completos como regressão de integração | Engine reutilizável além de um único jogo | MVP de progressão e Proving Ground percorrem build → play → persistência → captura → gate com definição própria. |

Expandir rigging, retargeting, importação de clipes, LOD e ferramentas de composição pode elevar o teto de autoria, mas a próxima melhoria de maior impacto é tornar a cadeia existente confiável. Combat, Anim, Feel, Audio, UI, Access, Bench e sistemas de IA já existem; a prioridade é provar que compõem uma experiência estável.

Para elevar minha avaliação a aproximadamente **7/10**, eu esperaria os defeitos P1 corrigidos e reproduções negativas passando, suíte e preflight verdes em ambiente limpo e uma jornada completa confiável nos dois consumidores. Para **8–9/10**, seriam necessárias evidências de acabamento, desempenho e operação em dispositivos e sessões reais, incluindo persistência e release. Essas são condições propostas de avaliação, não uma garantia de nota futura.

## Autoridade de release e limites restantes

Foi verificado o run `release-20260905T144550Z-5d749e31`, com manifesto SHA-256 `e87ead67b1f2e283879d5aee370f46d4742ee20cce4e6783c6611f64f4e7f91c`, build `fd6a8919bc3edbd9124d1c93229d480ede0d46d05196e4de176106639f317d58` e 13 artefatos íntegros. Seu resultado permanece **BLOCKED**. Parte dos bloqueios daquele run veio da infraestrutura ainda indisponível; outros são requisitos sem produtor utilizável. As medições posteriores não foram incorporadas retroativamente a esse run.

[Gate imutável](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/artifacts/release-20260905T144550Z-5d749e31/gate.json), [manifesto](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/artifacts/release-20260905T144550Z-5d749e31/run.json), [verificação executada](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/.tmp/audit-2026-09-05/verified-runs.json).

O bundle `run-00014` de `studio measure` não possui o schema 2 exigido pelo verificador de runs finalizados. Seus dados de bridge são úteis para diagnóstico, mas não são autoridade de release. O mesmo vale para `reports/latest*` e para os arquivos de reprodução desta auditoria.

Permanecem **`NOT_VALIDATED`**: revisão semântica de todas as linhas inventariadas; comportamento de todos os jogos e combinações de módulos; jornada black-box completa em Studio; persistência e recibos em serviço real de testes; multijogador entre clientes independentes com falhas de rede; desempenho gráfico em aparelhos alvo; upload/moderação de assets nesta auditoria; publicação e rollback reais; validade universal dos critérios visuais.

O plugin corrente foi instalado para os experimentos, os places foram compilados e o Studio foi reiniciado. Ao concluir as medições, Play Solo foi encerrado e o Studio ficou em edição no Proving Ground. Os testes e comandos geraram logs, builds e ponteiros diagnósticos; nenhum arquivo de implementação foi corrigido como parte desta auditoria.
