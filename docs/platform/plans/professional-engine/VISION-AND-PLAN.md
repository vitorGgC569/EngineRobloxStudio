# Engine profissional de Roblox operada por agentes

**Proposta de produto e implementação — referência: auditoria de 5 de setembro de 2026.**

Status das soluções propostas: **`NOT_VALIDATED`**. Este documento organiza a implementação; não altera contratos de release, não autoriza publicação e não declara as capacidades futuras concluídas. O charter e os contratos vigentes continuam normativos.

**Produto final:** uma plataforma pela qual agentes transformam uma intenção de jogo em uma experiência Roblox autoral, jogável, acessível, estável e operável, com código e assets editáveis, testes reais e uma cadeia verificável de decisões e versões. O humano dirige produto e qualidade; a engine executa e explica o trabalho dentro das autorizações recebidas.

O diferencial deve ser a capacidade de **criar → observar → jogar → diagnosticar → corrigir → provar → entregar**, mantendo a identidade do jogo e a integridade dos dados. A quantidade de comandos e módulos mede o tamanho da superfície, não o resultado.

## 1. Documentos e ponto de partida

- [Auditoria e reproduções](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md): o que foi inspecionado e executado, com os limites da cobertura.
- [Backlog completo — 86 entregas](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/platform/plans/professional-engine/BACKLOG.md): lacuna, implementação, dependências, escopo e aceitação por item.
- [Backlog estruturado](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/platform/plans/professional-engine/backlog.v1.json): a mesma proposta em dados para planejamento e acompanhamento. Não é um ProductionPlan executável.
- [Correspondência com o catálogo atual](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/platform/plans/professional-engine/CAPABILITY-COVERAGE.md): todas as 43 capacidades declaradas, inclusive limitações e declarações que precisam ser atualizadas.
- [Charter](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/platform/ENGINE-CHARTER.md): fronteiras de produto, generalidade e autoridade de release.

Na auditoria, dois consumidores compilaram e executaram. Um personagem real concluiu uma compra com moeda de jogo no MVP. O Proving Ground teve 32 cenários aprovados, cinco impedidos por DataStore local indisponível e uma falha de navegação. A suíte pytest teve 1.670 aprovações e 16 falhas concentradas em drift do catálogo. Há defeitos reproduzidos em persistência, recibos, validação de rede, navegação e vinculação da publicação. Os resultados e seus níveis estão no relatório citado.

A cobertura global foi automatizada; não houve revisão semântica manual de todas as 1.099.153 linhas inventariadas. O backlog não se apresenta como uma lista de todos os defeitos possíveis do repositório. Ele reúne tudo identificado nesta revisão e os requisitos necessários à visão de produto, distinguindo observação e proposta.

**Descoberta adicional nesta etapa — `STATICALLY_VALIDATED`:** o Studio instalado expôs `StudioTestService`, `StudioDeviceSimulatorService` e o membro `UserInputService.CreateVirtualInput` em edit mode. A descoberta não executou um teste multicliente nem comprovou permissões para todas as operações. [Resultado local](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/.tmp/audit-2026-09-05/planning-api-discovery.json).

A documentação atual descreve APIs para testes, emulação de dispositivos e input. O MCP oficial também oferece teclado, mouse e seleção explícita de Studio. O plano deve testar esses caminhos antes de ampliar automações por coordenadas. [Testes do Studio](https://create.roblox.com/docs/studio/testing-modes), [StudioTestService](https://create.roblox.com/docs/reference/engine/classes/StudioTestService), [MCP oficial](https://create.roblox.com/docs/studio/mcp).

## 2. O que significa “profissional”

A avaliação precisa abranger sete dimensões independentes. Um resultado excelente em uma não compensa uma falha impeditiva em outra.

| Dimensão | Resultado que o jogador ou diretor deve perceber | Evidência necessária |
|---|---|---|
| Identidade e direção | O jogo tem proposta, estilo, linguagem e objetivos próprios. | Brief e referências independentes; alinhamento do build e revisão de arte. |
| Jogabilidade | O jogador entende o objetivo, controla bem, recebe feedback e pode progredir. | Jornadas reais, testes com jogadores e telemetria; sucesso técnico não certifica diversão. |
| Conteúdo e acabamento | Cenários, personagens, animação, áudio e UI parecem partes do mesmo jogo. | Revisão em movimento e capturas corretas por contexto; assets finais carregando. |
| Correção e segurança | Recompensa, compra, posse, combate e save obedecem às regras. | Invariantes, testes negativos, disputa entre sessões e serviços reais de teste. |
| Desempenho | A experiência permanece responsiva nos aparelhos e populações declarados. | Frame time cliente, servidor, memória, rede e sessões longas. |
| Acessibilidade e alcance | Controles e informação funcionam nos dispositivos e idiomas do produto. | Testes por modalidade, resolução, orientação, preferências e conteúdo localizado. |
| Operação | É possível lançar, observar, corrigir, restaurar dados e voltar de uma versão ruim. | Ensaio de release/rollback e suporte em ambiente autorizado; configuração e eventos auditáveis. |

Os limites numéricos pertencem ao contrato do produto. Uma experiência pode mirar 60 FPS em desktop e outra usar um perfil móvel diferente; ambos precisam declarar o aparelho, cenário e orçamento antes da avaliação. Não adotar um “95 de qualidade” universal como substituto dessas condições.

## 3. Jornada do diretor e dos agentes

1. **Definir o produto.** O diretor descreve público, plataforma, fantasia, loop, referências, escala, identidade artística, monetização pretendida e restrições. A engine destaca decisões ainda necessárias e propõe alternativas com seus custos.
2. **Congelar a intenção para uma tentativa.** Criar a definição versionada do jogo, limites de qualidade, referências, verbos e objetivos. Mudanças futuras geram nova versão e invalidam somente o trabalho afetado.
3. **Verificar viabilidade.** Confrontar o pedido com módulos, ferramentas, permissões, dispositivos de teste, serviços e budgets disponíveis. Um recurso desconhecido gera tarefa de extensão ou experimento delimitado.
4. **Construir uma primeira experiência completa.** Planejar e implementar um vertical slice: um trecho pequeno com começo, ação, consequência, apresentação, interface e recuperação. O layout começa simples para validar circulação; o slice precisa chegar a conteúdo e acabamento finais.
5. **Revisar direção e sensação de jogo.** Mostrar previews reais, diferenças, decisões e impedimentos. O diretor pode comentar uma região, ação, asset ou tela e pedir uma revisão localizada.
6. **Produzir e integrar o restante.** Compor sistemas e conteúdo por dependência, reaproveitando o que atende ao contrato e criando o que define a identidade do jogo.
7. **Jogar como jogador.** Explorar objetivos, controles e interfaces sem instruções internas. Após uma falha, usar instrumentação para explicar causa e reproduzir o problema.
8. **Corrigir e revalidar.** Gerar alteração pequena, executar regressão afetada e depois o gate completo. Preservar o histórico de tentativa, falha, patch e prova.
9. **Preparar e publicar a versão autorizada.** Vincular aprovação aos bytes, às permissões e ao destino. Se depender de uma decisão ou serviço externo, deixar pacote completo, motivo e próximo passo, com retomada possível.
10. **Operar e melhorar.** Observar erros, estabilidade, funil e economia; corrigir incidentes; planejar mudanças a partir de evidência real de uso.

O sistema deve funcionar com um único agente sequencial. Papéis especializados são contratos de responsabilidade, e podem ser exercidos em sequência. Paralelismo é uma capacidade opcional, sujeita à autorização, ownership e disponibilidade dos recursos. Este planejamento foi produzido sem subagentes.

O diretor pode pré-autorizar categorias de ações, custos e destinos. A engine mantém essas decisões e só solicita intervenção quando uma decisão necessária sai desse escopo. Gate independente e autorização de publicação são verificações distintas.

## 4. Arquitetura do produto final

| Camada | Responsabilidade | Base existente a aproveitar | Integração necessária |
|---|---|---|---|
| Definição de produto | Brief, referências, verbos, sistemas, assets, budgets e critérios. | ProductIntent, GameProjectDefinition, ProductionBlueprint, tokens e contratos. | Um formato de entrada completo e preservação das decisões autorais. |
| Planejamento e execução | DAG, dependências, ownership, filas, custos, retomada e reparo. | Orchestrator, SQLite journal, producer, impact e ledger. | Handlers reais para todas as etapas e um fluxo operacional comum. |
| Ferramentas de agentes | APIs tipadas, descoberta, edição, busca, providers e retorno estruturado. | MCP RQE, StudioMcpClient, CLIs Forge/RQE. | Federações compatíveis, seletores explícitos e ciclo de vida consistente. |
| Studio e serviços de teste | Build, contexto edit/server/client, sessões e input. | Plugin, hub, client bridge, lifecycle e teamtest. | Adotar APIs nativas verificadas, controlar sessões e correlacionar artefatos. |
| SDK de jogo | Mecânicas, mundo, personagens, UI, rede, save e apresentação. | Forge, GameKit, WorldKit e módulos já existentes. | Escolher implementações canônicas de fundamentos e adapters de compatibilidade. |
| Fábrica de conteúdo | Busca, criação, modelagem, revisão, publicação e integração de assets. | Sourcing, assets, geometry, catálogos e authoring de mídia. | Workers reais, permissões e integração automática à fonte e ao build. |
| Qualidade e evidência | Medição, cenários, revisão visual, desempenho e gate. | Observe, scenario, critic, probe registry e release. | Produtores completos; observações válidas por domínio e contexto. |
| Operação | Deploy, rollback, configuração, telemetria e suporte. | Publish/rollback, LiveOps, Telemetry, Cluster e dashboard. | Cadeia operacional comprovada e ferramentas do diretor. |

**Separação canônica proposta:** o núcleo da fábrica não contém nomes, coordenadas ou regras de um jogo. A definição de produto fornece a semântica. O SDK fornece primitivas e interfaces reutilizáveis. O jogo consome tudo isso e pode possuir código autoral próprio.

Escolher uma implementação canônica para posse de perfil, transações, recibos, eventos e lifecycle. Migrar consumidores gradualmente, com testes e adapters; uma reescrita simultânea das bibliotecas aumenta risco sem resolver a falta de prova.

O SDK deve permitir extensões e Luau autoral validado. Uma DSL de regras acelera o caso que ela cobre; quando o jogo exige um verbo novo, a engine deve conseguir adicionar esse verbo com schema, implementação, validação e testes. A fronteira da API precisa ser extensível e auditável.

## 5. Contratos que precisam fechar a cadeia

Os nomes abaixo representam conceitos; reutilizar e ampliar schemas existentes antes de criar equivalentes novos.

| Contrato | Conteúdo mínimo | Garantia |
|---|---|---|
| Definição de jogo | productId, versão, fontes, público, dispositivos, referências, sistemas, assets e critérios. | O produto avaliado corresponde ao produto pedido. |
| Capacidade executável | versão, backend, contexto, permissões, efeito, custo, schema e evidência de disponibilidade. | Um nome em tools/list não é confundido com uma implementação utilizável. |
| Tarefa de produção | entrada/saída por hash, escopo, proprietário, dependências, prazo, orçamento e aceitação. | O agente recebe trabalho concreto e termina com resultado verificável. |
| ChangeSet | base da fonte, alterações, precondições, recursos tocados e compensação. | Revisão, conflito e recuperação são possíveis. |
| Build | fontes e ferramentas versionadas, dependências, artefatos, productId e hash dos bytes. | Mede-se e publica-se o mesmo conteúdo. |
| Sessão de teste | build, processo, Studio, contexto, jogador, dispositivo, seed e parâmetros. | Observações não atravessam builds, clientes ou janelas. |
| Resultado de cenário | ações, frames, observações, asserções, cobertura, ambiente e motivo de término. | Uma jornada concluída pode ser inspecionada e uma falha pode ser diagnosticada. |
| Asset package | brief, origem, direitos, ferramentas, fontes, previews, validações e dependências. | A aprovação se refere ao asset que entra no jogo. |
| Publicação de asset | destino/dono, conteúdo, job, idempotência, moderação, ID confirmado e integração. | ID retornado não é confundido com aprovação ou uso correto. |
| Run final de qualidade | entradas congeladas, evidências registradas, hashes, julgamentos e resultado. | A autoridade de release usa artefatos imutáveis verificados. |
| Release receipt | run aprovado, bytes enviados, destino, versão retornada e verificações após entrega. | Aprovação, autorização e efeito externo são correlacionados. |

A retomada usa identidade de inputs, outputs, ferramentas e engine. Um checkpoint com `OK` não licencia ignorar que um arquivo foi apagado ou que o SDK mudou. Recursos com efeito externo precisam permitir consultar o resultado de uma tentativa incerta antes de repeti-la.

Os níveis de validação permanecem explícitos. Além deles, registrar o domínio e o contexto da prova: um cenário E2E não substitui uma medição de performance ou uma revisão de arte. A captura precisa da câmera correta; um JSON de câmera do servidor não certifica uma imagem do cliente.

## 6. Inventário de lacunas por área

O backlog detalhado contém todas as 86 entregas. Este mapa orienta a leitura e a implementação.

| Área e IDs | Lacunas e resultados necessários |
|---|---|
| **Ambiente — ENV-01…06** | Corrigir stamps e CI; instalar a distribuição em máquina limpa; negociar APIs/permissões; estabilizar restart e logs por contexto; tratar limites externos como dados atualizados. |
| **Documentação — DOC-01…02** | Uma entrada canônica, documentação gerada/testada, estados históricos datados e cobertura explícita da revisão semântica. |
| **Dados — DAT-01…07** | Posse em cada escrita; liberação correta; migração atômica; autosave/flush; recibo e recompensa duráveis; DataStore real isolado; configuração e prova de produtos/passes conforme o jogo. |
| **Rede — NET-01…05** | Compor shape e custom check; autoridade por verbo; replicação multicliente; perda/jitter/reentrada; prediction/reconcile quando necessário; schemas/handlers/orçamentos versionados. |
| **Controle — CTL-01…09** | Federação funcional; build/processo/cliente exatos; câmera verdadeira; paginação/refs; input de jogador; testes/dispositivos nativos; aproximação de prompts; mutações reversíveis; stack trace até a fonte. |
| **Fábrica — FAC-01…08** | Definição completa; handlers de todo o DAG; checkpoints por conteúdo; ownership/integrador; reparo e regressão; budgets/cancelamento; revisão independente; extensões além de templates. |
| **Mundo — WRL-01…07** | Navegação sem reentrada; layout e rotas; kits/terreno/material; streaming com estado; física/network ownership; roundtrip Studio/fonte; montagem por sockets/faces e restrições em lote. |
| **Assets — AST-01…07** | Pesquisa e proveniência; workers reais; pacote validado; upload/moderação; cache incremental; quarentena de terceiros; patch automático da fonte e prova de uso. |
| **Personagens — CHR-01…04** | Rigs e retargeting quando requeridos; sincronização de animação/ação; áudio/câmera/VFX; compatibilidade de avatares, escalas e cosméticos. |
| **Gameplay — GAM-01…06** | Lifecycle comum; contratos entre mecânicas; dados referenciados corretamente; economia/pacing; onboarding e recuperação; pacotes especializados selecionados por produto. |
| **UX — UIX-01…04** | Design system aplicado; toque/teclado/gamepad; localização e textos longos; acessibilidade ligada aos sistemas reais. |
| **Qualidade — QAT-01…08** | Produtores de evidência; testes negativos; jornadas e replay diagnóstico; referências visuais; medição correta; carga/soak; saúde dos instrumentos; dois consumidores completos e terceiro brief. |
| **Release — REL-01…06** | Autoridade imutável; seleção por runId; ambientes/credenciais; publicação/rollback compatíveis; remoção/restrição de instrumentação; ensaio operacional. |
| **Operação — OPS-01…07** | Telemetria por versão; console do diretor; config/alertas/contenção; experimentos com jogadores; administração de dados; escala autorizada de workers; evolução do SDK. |

As 75 entregas CORE formam o alvo da primeira cadeia profissional completa. Oito PROFILE tornam-se obrigatórias quando um jogo as exige. Três SCALE expandem a operação depois dessa cadeia. O tamanho dessa lista representa um programa de engenharia; não uma única alteração de código nem um prazo implícito.

## 7. Limites que o plano precisa tratar corretamente

| Tipo | Exemplo | Tratamento |
|---|---|---|
| Defeito da implementação atual | Save sem posse, recibo duplicado, shape ignorado, hash fraco. | Corrigir com reprodução negativa e regressão nos consumidores. |
| Integração incompleta | DAG sem handlers, geração de asset sem binding à fonte, evidência sem produtor no release. | Conectar os componentes existentes com contratos e um cenário completo. |
| Ausência de prova | Netcode, streaming, acessibilidade, rollback ou performance em aparelho não executados nesta auditoria. | Executar o cenário apropriado; manter classificação pendente até observar. |
| Limitação de uma superfície | DSL de regras ou modelagem sem o operador necessário. | Estender por contrato ou selecionar backend capaz; preservar o resultado e a proveniência. |
| Restrição externa | Permissões, moderação, conta/dono, serviço não disponível ou quota. | Detectar, preparar pacote, informar bloqueio e retomar pelo resultado externo. |
| Mudança de plataforma | APIs de teste e input mais novas que a documentação local. | Probar versão, permissão e comportamento; atualizar adapter e testes de compatibilidade. |
| Limite de julgamento | Diversão, originalidade e sucesso comercial. | Referências, revisão independente, playtests humanos e dados de uso com incerteza explícita. |

Não fixar no código números retirados de documentação histórica sem checagem. O inventário de capacidades conserva declarações antigas sobre betas, quotas e importação; o item ENV-06 deve reconciliá-las com a versão, o contexto, o proprietário e as APIs vigentes.

A emulação de dispositivos ajuda a testar layout, input e condições simuladas; a aceitação de desempenho no aparelho exige medição no alvo declarado. Uma sessão de Run sem jogador serve para alguns testes de servidor e mundo, mas não substitui Play nem multicliente. [Modos e emulação do Studio](https://create.roblox.com/docs/studio/testing-modes).

A engine pode automatizar ações suportadas quando estiverem autorizadas. Ela precisa tratar serviços externos indisponíveis como impedimentos reais, com pacote completo e retomada, sem prometer que toda publicação ou moderação tem prazo controlável.

## 8. Plano de implementação por dependência

Os marcos são condições de saída. Dentro deles, seguir as dependências do JSON; as tabelas abaixo não representam estimativas de semanas.

| Marco | Entrega | Principais frentes | Condição de saída |
|---|---|---|---|
| **M0 — Baseline reproduzível** | Máquina e ferramentas deixam de ser uma variável implícita. | ENV e documentação corrente. | CI limpo e comandos de instalação reproduzidos; catálogo consistente; matriz real das APIs de Studio, permissões e versões. |
| **M1 — Fundamentos seguros** | Dados, rede, conteúdo importado e publicação têm regras aplicadas no ponto do efeito. | DAT-01…05, NET-01…02, AST-06, REL-01/03. | Reproduções críticas deixam de falhar; testes negativos impedem regressão; nenhum caminho de release usa recibo de tamanho/data. |
| **M2 — Agente executa e observa corretamente** | A fábrica passa de planos e ferramentas separadas para execução durável com contexto exato. | CTL, FAC inicial, WRL-01, QAT-01/05, REL-02, OPS-02. | Um plano percorre handlers reais; input e captura medidos no cliente; interrupção e retomada verificam artefatos; erro aponta fonte. |
| **M3 — Vertical slice com acabamento** | Sistemas e assets compõem um trecho completo do jogo. | Autoria de mundo/conteúdo, gameplay, UI, apresentação e bindings. | Loop completo com conteúdo final, UI utilizável, animação/som/VFX e progresso; edição do diretor sobrevive ao rebuild. |
| **M4 — Prova de qualidade e generalidade** | Os consumidores passam pela mesma cadeia sob dispositivos, rede e duração declarados. | QAT, DAT-06, NET-03, UIX-02, física, pacotes PROFILE pertinentes. | Dois candidatos integrais, falhas semeadas rejeitadas, aparelho alvo medido e terceiro brief sem hardcode de gênero. |
| **M5 — Release e operação profissional** | Entrega, observação e recuperação funcionam no ambiente autorizado. | REL-04/06 e OPS-01/03/05. | Publicação e rollback ensaiados, dados compatíveis, dashboards úteis, configuração e suporte auditáveis. |
| **M6 — Escala e expansão** | Aumentar capacidade e variedade com compatibilidade controlada. | Workers, pacotes especializados, experimentação e ecossistema de SDK. | Concorrência autorizada, quotas e falhas de worker preservam isolamento; extensões têm contratos e regressão. |

As frentes de conteúdo podem começar a explorar estilo e referências enquanto M0/M1 são implementados, mas não devem receber aprovação final antes de os instrumentos necessários funcionarem. Serviços e permissões de teste precisam ser preparados cedo para que M4 não descubra o impedimento só no final.

**Sequência inicial de alterações revisáveis:**

1. **Baseline e compatibilidade:** ENV-01/02/04/05/06 e DOC-01. Corrigir o catálogo após revisão; instalar dependências no CI; provar APIs nativas; preservar resultados anteriores da auditoria.
2. **Sessões de dados:** DAT-01/02, com a reprodução de perda de perfil convertida em regressão do módulo original.
3. **Migração, flush e recibos:** DAT-03/04/05, mantendo identidade e posse da etapa anterior.
4. **Rede e autoridade de release:** NET-01 e REL-01, incluindo os casos reproduzidos de bypass de shape e troca de bytes.
5. **Controle e contexto:** CTL-01/02/03/06/07 e WRL-01. Entrada real, câmera cliente, lifecycle nativo e navegação passam juntos nos consumidores.
6. **Execução da fábrica:** FAC-01/02/03/04/06/07, REL-02 e QAT-01; materializar o contrato completo do produto e os handlers.
7. **Primeiro slice final:** escolher a jornada do MVP, integrando arte, UI, conteúdo e persistência. Depois repetir a cadeia no Proving Ground sem inserir nomes dos jogos no núcleo.

NET-02, AST-06, REL-03 e demais dependências acompanham essas alterações conforme o grafo. As sete entradas acima são agrupamentos de trabalho, não sete commits gigantes.

Não estimar datas a partir da quantidade de linhas ou de comandos. Usar S/M/L/XL do backlog para refinamento e medir duração/custo das primeiras entregas, principalmente as dependentes de Studio, serviços e assets. Definir calendário depois da confirmação de equipe, dispositivos e providers; a ordem técnica já está especificada.

## 9. Critérios de aceitação da engine

As metas abaixo são propostas para o produto; não são resultados já obtidos.

**A engine profissional inicial estará pronta quando:**

1. Um checkout limpo instala as dependências, valida o catálogo e constrói os consumidores pelas instruções documentadas.
2. Um agente sequencial consegue carregar uma definição, executar o plano e entregar candidato ou bloqueio preciso sem reconstruir o pipeline manualmente.
3. Todas as exigências obrigatórias do contrato possuem produtor real, cobertura explícita e evidência no contexto correto.
4. Os defeitos críticos reproduzidos têm regressões negativas executando o código original; disputa, repetição e falha não causam perda de progresso ou duplicação de entrega.
5. A jornada central do MVP e a do Proving Ground passam como experiência de jogador, além dos testes instrumentados dos sistemas.
6. Dois consumidores estruturalmente diferentes completam a cadeia com o mesmo núcleo; um terceiro brief não usado para adaptar a implementação confirma a generalidade do planejamento.
7. Captura, UI, input, save, desempenho e rede são medidos nos contextos e aparelhos declarados. Não há E2E promovido de fixture nem captura certificada com câmera de outro contexto.
8. Cada asset obrigatório foi adotado ou produzido, validado, autorizado para uso, integrado e observado no papel correto. Placeholder obrigatório não é aprovado como conteúdo final.
9. Alteração, apagamento ou troca de artefato invalida retomada/aprovação pertinente. Falha após um efeito externo é consultada antes de retry.
10. A fonte construída, a sessão medida, a aprovação e os bytes enviados pertencem ao mesmo produto e tentativa verificável.
11. A publicação autorizada possui resultado observado, compatibilidade de dados, caminho de rollback e operação ensaiada.
12. O diretor consegue entender resultado, alteração, custo, risco e impedimento por um console e artefatos revisáveis.

Repetir os caminhos de lifecycle, retomada e release candidate em campanhas controladas, registrando todas as falhas e intervenções. A quantidade de repetições deve aparecer no relatório; poucas execuções sem erro não autorizam alegar uma taxa baixa de falha em produção.

**Casos negativos obrigatórios de demonstração:** troca do arquivo mantendo tamanho/data; câmera do cliente diferente da certificada; outro produto usando os mesmos nomes de instância; callback de recibo repetido; perfil ocupado; migração que lança erro; pacote de rede inválido com custom check; pathfinding pendente em vários frames; script sem handler; asset moderado/revogado; perda de worker após upload; output apagado antes do resume; GUI fora do viewport; serviço de medição indisponível.

## 10. O que entregar ao diretor em cada tentativa

Um resultado deve trazer o build ou pacote completo, resumo das mudanças, preview real, decisões de design, lista de requisitos e seus estados, falhas reproduzíveis, diferenças relevantes, custo e duração observados, e o próximo passo preciso.

O estado terminal precisa ser significativo:

- **Candidato pronto:** requisitos e revisões exigidos foram concluídos; pacote íntegro está pronto para a ação autorizada seguinte.
- **Falha de produto:** o instrumento funcionou e observou comportamento incorreto, com reprodução.
- **Falha de infraestrutura:** ferramenta, contexto, processo ou serviço não permitiu executar corretamente.
- **Inconclusivo:** observação insuficiente para decidir.
- **Bloqueio externo:** artefatos preparados; falta a ação, permissão ou resultado externo identificado.
- **Cancelado ou orçamento encerrado:** trabalho preservado e retomável; nenhuma aprovação inferida por tempo gasto.

Telemetria e feedback humano completam a avaliação após o jogo chegar a jogadores. A engine deve melhorar a capacidade de criar e operar bons jogos; diversão e sucesso comercial continuam exigindo evidência de pessoas jogando.

## 11. Decisões de produto assumidas nesta proposta

- Priorizar a distribuição local de Studio em Windows já usada pelo projeto; componentes portáveis e workers especializados mantêm fronteiras claras. Suporte a outros hosts depende de adapters e testes próprios.
- Usar desktop e mobile como alvos da engine inicial, com gamepad conforme o contrato do consumidor. Recursos específicos de VR, MMO, corrida, trading ou outros gêneros entram como perfis de extensão quando pedidos.
- Começar com dois consumidores existentes para integração, corrigindo seu conteúdo junto da cadeia; usar terceiro brief para verificar generalidade sem moldar o núcleo ao caso.
- Reaproveitar ferramentas nativas do Roblox e backends de autoria já disponíveis, verificando capacidades em execução antes de prometer automação.
- Manter código, assets fonte e decisões editáveis pelo usuário e por agentes, com roundtrip, diff e proveniência.
- Preservar autorizações recebidas e manter revisão independente do implementador para a qualidade exigida; intervenção humana deve corresponder a uma decisão real.
- Usar o backlog como proposta de escopo. Durante implementação, mudança de status exige evidência específica, e uma nova lacuna entra identificada em vez de ser resolvida por atalho particular de um jogo.

Essas premissas permitem começar a implementação sem confundir a meta de produto com uma promessa de suportar todo gênero e toda plataforma de imediato. A extensão é parte do produto desde o início; a comprovação cresce por perfis e consumidores.
