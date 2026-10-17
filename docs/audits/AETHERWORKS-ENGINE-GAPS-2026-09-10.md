# O que criar Aetherworks revelou sobre a engine

Registro de 10/09/2026. O produto avaliado é a plataforma RQE/Forge/WorldKit; Aetherworks é seu caso de uso. Este documento reúne observações desta implementação e leituras específicas do código. Não equivale a uma auditoria linha por linha de todo o repositório.

## Conclusão

A engine já permite construir e operar um jogo real. Ainda exige muita autoria e integração em Luau/Python, decisões visuais do agente e intervenção para diagnosticar testes. O limite observado não é simplesmente falta de comandos: é transformar as primitivas existentes em sistemas compostos, com aparência consistente e verificação confiável.

Criar uma feature diretamente no jogo resolve o pedido local, mas só evolui o produto da engine quando a solução ganha contrato genérico, integração e regressão em outro jogo. Neste trabalho, houve mais implementação específica do Aetherworks do que extração de capacidades reutilizáveis; isso precisa ser corrigido como prática de desenvolvimento.

## Capacidades que de fato usamos

- RUNTIME_VALIDATED: geração original por Blender/RQE, publicação e carregamento de dezesseis templates de malha no Studio. Cinco geometrias de cristais distintas, clonadas para máquinas e exibições.
- RUNTIME_VALIDATED: jogador nativo controlado por `client.input`; compra da casa e seus cinco andares pelo menu, adoção, melhoria, ocupação e retirada de pets. Observados 2, 4 e 10 espaços e produção ×1,06 → ×1,185 → ×1,06 conforme a ocupação.
- RUNTIME_VALIDATED: 22 cenários internos aprovados, incluindo progressão, limites de slots e bônus. São testes de integração/funções com perfil local pré-carregado, não uma jornada orgânica completa.
- VISUALLY_VALIDATED: fotografias do mundo e interfaces com identificação da sessão, câmera, processo e hash do build. A casa ganhou janelas/varandas; coletor e farol foram separados após inspeção visual.

Evidência principal: [habitat-runtime.json](../../games/aetherworks/artifacts/habitat-runtime.json). A prova anterior de carregamento do kit está em [art-runtime.json](../../games/aetherworks/artifacts/art-runtime.json); cada relatório pertence ao seu build.

## Lacunas observadas e correções necessárias

| ID / prioridade | O que ocorreu | Limitação exposta | Próxima capacidade e critério de conclusão |
|---|---|---|---|
| E01 / P0 | O teste multiplayer expirou em 240s sem runtime verificável; limpeza automática informou que não havia identidade segura para encerrá-lo. | Inicialização e diagnóstico multiplayer ainda não foram confiáveis nesta revisão. Não prova defeito no combate nem impossibilidade de multiplayer. | Diagnóstico por etapa, versão do Studio, servidor e clientes, identidade do teste e recuperação restrita aos processos próprios. Passar cenários consecutivos de dois jogadores e repetir com quatro. |
| E02 / P0 | Houve input reportado como entregue sem a compra esperada; outra sequência pela tecla U e botões completou o fluxo. | Sucesso do transporte não comprova ativação nem resultado. A causa da primeira sequência não foi isolada. | Unificar localizar, confirmar visibilidade, observar Activated, clicar e aguardar pós-condição específica. Não repetir uma compra após timeout sem reconciliar o resultado. |
| E03 / P0 | O release genérico na raiz selecionou outro jogo anteriormente; `rqe/release.py` ainda contém fallback para `roblox/mvp/default.project.json`. | Escolha do alvo e integração entre build, sessão e release são fáceis de usar incorretamente num repositório com vários jogos. | Contexto obrigatório de projeto: jogo, Rojo, place, universe e hashes consistentes. Teste negativo deve recusar qualquer mistura entre Aetherworks e outro projeto. |
| E04 / P1 | Cada rebuild substitui o place e exige reinstalar o client bridge; editar o plugin exige instalação e reinício. | Muitas etapas manuais para preparar um teste real; falha de preparação pode parecer falha do jogo. | Comando de preparação por projeto que verifica build, plugin, client bridge, sessão e disponibilidade das APIs antes de começar. Registrar tempo por etapa e diagnosticar ausência de cliente imediatamente. |
| E05 / P1 | Publicação de malhas precisou receber suporte a normais e UVs; validação de índices e recibo foram adicionados. | A cadeia de autoria/publicação não preservava esses atributos por esse caminho tipado. | Correção genérica já implementada em `rqe/geometry/publication.py` e `Commands/Assets.lua`. Falta provar o ciclo completo com textura/PBR, materiais, colisão, orçamento e falha de carregamento, sem fallback visual silencioso. |
| E06 / P1 | Para sair de blocos simples foi necessário escrever `Art.lua`, programas de geometria, compor oficina, cofre, casa e pets. | Geometria procedural existente não entrega sozinha direção de arte ou um kit de objetos acabados. | Kits parametrizados com silhueta, peças conectáveis, detalhes, materiais, colisão, LOD e variantes. Demonstrar o mesmo kit em dois temas sem duplicar o construtor. |
| E07 / P1 | Placa ficou dentro da torre, um Highlight afetou o mundo inteiro, guarnição/boosts ficaram próximos e o farol encobria o coletor. | Testes de código não detectaram problemas de uso e composição que apareceram ao olhar/jogar. | Contratos espaciais para entrada, área de interação, circulação, visibilidade de placas, orçamento de oclusão e escopo de destaques. Validar marcos desde a câmera de jogo após construir todos os níveis. |
| E08 / P1 | UI exigiu layouts específicos, dimensões e ajustes manuais; previews e painéis foram compostos no jogo. | Há widgets e tokens, mas faltou aproveitar uma camada comum de telas completas e regras de legibilidade. | Biblioteca de HUD compacto, modal, inventário, compra, melhorias e slots com navegação, estados de erro/espera, rolagem, tamanho de texto e testes em resoluções de computador. |
| E09 / P1 | Casa comprável, andares por rebirth, inventário de pets, ocupação, bônus, saves e UI foram ligados em módulos novos do jogo. | `Forge.Companion` cuida de formação/movimento, não de inventário ou residência; `Forge.Loop` tem composição, mas a prateleira observada só inclui Hatch. | Compor capacidades genéricas de propriedade, capacidade desbloqueável, equipamento e modificadores. Primeiro extrair a casa/pets; depois validar a mesma composição com trabalhadores em oficinas. |
| E10 / P1 | Torre cooperativa e domínio exigiram lógica específica para membros, ataques, cura, rotas, alvos e recompensas. | Nav/Combat/rigs existentes não resolvem sozinhos grupo de expedição e objetivos competitivos. | Sessão de grupo e objetivo de captura reutilizáveis, com desconexão, morte, entrada tardia, recompensa por participante e isolamento. Verificar no runtime multiplayer antes de prometer suporte pronto. |
| E11 / P1 | As instruções diziam que Play Solo não era programável e cliques sintéticos eram impossíveis; o teste atual executou ambos por APIs novas. | Conhecimento medido envelheceu sem identificação suficiente de versão/backend. | Atualizar fatos por versão e comando, manter prova/reprodução e distinguir método antigo de limitação atual. Duas afirmações foram corrigidas nesta revisão em ENGINE-FACTS.md. |
| E12 / P1 | A suíte ampla teve 14 falhas/erros por hash de schema desatualizado; o stamp foi corrigido e 60 testes afetados passaram. | Mudança de comando exige manter vários contratos sincronizados e pode consumir tempo com falha previsível. | Verificação rápida dos stamps antes da suíte cara e relatório de impacto por contrato. Não substituir a validação completa exigida para release. |
| E13 / P2 | Capturas e testes por jogo foram montados em scripts próprios; tentativas sucessivas reutilizam alguns nomes de relatórios. | Há suporte a evidência imutável no release, mas o fluxo exploratório ainda é fácil de deixar sem histórico completo. | Roteiro genérico de validação com pastas por tentativa, hash da fonte, build, ação, captura e resultado; preservar falhas antes de nova tentativa. |
| E14 / P2 | Balanceamento, custos dos andares e bônus foram escolhidos e testados localmente, sem acompanhar jogadores ao longo de dias. | Não podemos afirmar retenção ou economia saudável com base em código e sessões pré-carregadas. | Simulação ligada às mesmas regras de produção, cenários AFK/ativos, gasto/ganho e snowball; comparar depois com funis reais, retorno, abandono e tempo até marcos. |
| E15 / P2 | Salvamento de pets foi verificado por estrutura serializável; testes locais usam memória. | Não comprovamos persistência distribuída, reconexão, concorrência ou recuperação nesta atualização. Forge.Save existe; ausência de evidência não significa ausência do sistema. | Matriz de testes publicados em ambiente de homologação: sair/entrar, outro servidor, sessão concorrente, save recusado, migração e repetição de compra. |
| E16 / P2 | Limitamos NPCs e cristais em código, mas não fizemos ensaio desta revisão com quatro bases completas, pets e torre simultâneos. | Orçamento configurado não é medida de FPS, memória, rede ou custo de scripts. | Cenários de carga representativos, métricas de cliente/servidor por sistema e regressão por build; identificar o limite medido antes de prometer escala. |

As prioridades são julgamento de engenharia, não pontuações medidas. E01/E02 foram observados em execução; E07 em execução/capturas; E03/E06/E08–E13 têm suporte no código e histórico desta tarefa; E14–E16 descrevem lacunas de validação explicitamente NOT_VALIDATED.

## O que ainda não demonstramos conseguir de forma confiável

1. Partir de uma descrição e entregar arte profissional consistente sem várias rodadas de composição e julgamento visual.
2. Montar sistemas completos apenas por configuração, reutilizando os mesmos contratos em gêneros diferentes.
3. Executar uma bateria multiplayer desta revisão sem intervenção e com recuperação garantida.
4. Concluir uma jornada por ações de jogador, incluindo persistência publicada, com evidência de ponta a ponta. Os testes atuais misturam UI real e observação/diagnóstico interno, devidamente identificados.
5. Comprovar diversão, retenção, equilíbrio competitivo e desempenho em carga a partir do resultado atual.
6. Produzir uma atualização pronta para lançamento por um fluxo único, inequivocamente preso ao jogo correto e a um manifesto imutável.

São limites do que foi demonstrado neste trabalho. Não são alegações de impossibilidade do Roblox ou inventário de todas as capacidades ausentes do repositório.

## O que já virou melhoria da engine, e o que ainda ficou no jogo

**Correção genérica implementada:** publicação tipada de malhas com normais/UVs e validação antes do envio; testes para atributos, índices e transporte incerto; sincronização do contrato de comandos. Isso é diferente de criar dezesseis assets específicos do Aetherworks.

**Infraestrutura utilizada e comprovada:** build pela engine, sessões nativas, input público, logs do servidor/cliente e capturas vinculadas. Essas capacidades já estavam no workspace; não atribuir toda a sua criação a este trabalho.

**Ainda específico do jogo:** `Art`, `Habitat`, `HabitatWorld`, `Discovery`, expansão de `Tower`/`Dominion` e telas. São candidatos a extração, não novas APIs reutilizáveis já entregues.

**Não confundir com lacuna da engine:** não implementar ranking global, passe, temporadas ou outro modo no Aetherworks não prova que o motor seja incapaz de implementá-los. Materiais e avaliação visual têm APIs existentes; falta integrá-los/prová-los neste ciclo, não inventar novamente essas ferramentas.

## Ordem recomendada para evoluir o produto

1. Confiabilidade do trabalho do agente: alvo explícito, preparo de teste, pós-condição de input, diagnóstico multiplayer e histórico das tentativas.
2. Extrair um sistema composto a partir de um caso real: propriedade + capacidade por progressão + inventário + slots + modificadores + UI + save. Usar a residência como primeiro caso e outro jogo como contraprova de reutilização.
3. Kit visual e contratos espaciais: construir com regras de acesso/visibilidade, comparar variantes e validar pela câmera do jogador.
4. Fechar o ciclo público: carga, persistência, analytics, economia e release verificáveis. Só então usar aprovação técnica como autorização de um candidato a lançamento.

A métrica do próximo ciclo deve ser capacidade nova, reutilizada e comprovada na engine; quantidade de features adicionadas ao Aetherworks sozinha não mede esse avanço.
