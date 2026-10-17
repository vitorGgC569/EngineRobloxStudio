# Lacunas e backlog de implementação

**86 entregas em 14 áreas.** Proposta de implementação; nenhuma entrega abaixo é marcada como concluída.

A lista reúne defeitos confirmados, integrações parciais, provas ainda ausentes e capacidades propostas. **PROVA_AUSENTE não significa que o módulo não existe ou está quebrado.** As referências existentes indicam o ponto de partida, não uma certificação integral do arquivo.

Toda solução futura permanece `NOT_VALIDATED`. O nível indicado em cada item se refere somente à observação atual. CORE é o núcleo da primeira cadeia completa; PROFILE é obrigatório quando selecionado pelo contrato; SCALE é expansão. P0/P1/P2 ordenam o trabalho e não reclassificam a severidade dos bugs da auditoria. S/M/L/XL são complexidade relativa sem promessa de prazo.

[Visão e plano](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/platform/plans/professional-engine/VISION-AND-PLAN.md) · [Backlog estruturado](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/platform/plans/professional-engine/backlog.v1.json) · [Auditoria](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md)

## Ambiente e compatibilidade

Base a reaproveitar: [forge/cli/preflight.py](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/cli/preflight.py), [rqe/hub/lifecycle.py](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/rqe/hub/lifecycle.py), [.github/workflows/ci.yml](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/.github/workflows/ci.yml), [pyproject.toml](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/pyproject.toml).

### ENV-01 — Catálogo e manifesto consistentes

**M0 · P0 · CORE · esforço S**

Estado: `DEFEITO_CONFIRMADO`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** 16 testes falharam, concentrados em divergência do hash de comandos.

**Implementar:** Revisar capacidades alteradas, atualizar stamps e impedir drift no fluxo normal.

**Aceitação:** Preflight e verificações de catálogo verdes; comando novo sem proprietário ou hash atualizado é rejeitado.

**Dependências:** Nenhuma dependência de implementação listada..

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### ENV-02 — CI provisionado do zero

**M0 · P0 · CORE · esforço M**

Estado: `DEFEITO_CONFIRMADO`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Workflow não instala explicitamente dependências de desenvolvimento e Rojo antes de exigi-los.

**Implementar:** Instalar dependências e ferramentas verificadas; executar a suíte completa em runner limpo.

**Aceitação:** Checkout limpo instala, compila, testa e constrói os consumidores sem dependências pessoais.

**Dependências:** ENV-01.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### ENV-03 — Distribuição e instalação reproduzíveis

**M0 · P0 · CORE · esforço M**

Estado: `PROVA_AUSENTE_NESTA_AUDITORIA`; evidência: `NOT_VALIDATED`.

**Lacuna:** Instalação fora do workspace e pacote distribuído não foram validados.

**Implementar:** Definir suporte por sistema operacional, empacotar recursos necessários e testar CLI instalada.

**Aceitação:** Ambiente novo localiza schemas, bibliotecas, templates e ferramentas e executa exemplo documentado.

**Dependências:** ENV-02.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### ENV-04 — Compatibilidade com APIs atuais do Studio

**M0 · P0 · CORE · esforço M**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Documentos negam APIs que agora existem; descoberta em edit confirmou serviços e membro CreateVirtualInput.

**Implementar:** Probar permissão e funcionamento de testes, dispositivos e input; registrar versão e backend efetivo.

**Aceitação:** Matriz disponível/indisponível por versão/contexto; existência de membro não vira prova de execução.

**Dependências:** Nenhuma dependência de implementação listada..

Evidência/base: [planning-api-discovery.json](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/.tmp/audit-2026-09-05/planning-api-discovery.json), [teamtest.py](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/rqe/hub/teamtest.py), [testing-modes](https://create.roblox.com/docs/studio/testing-modes).

### ENV-05 — Lifecycle e logs por contexto

**M0 · P0 · CORE · esforço M**

Estado: `DEFEITO_OBSERVADO_EM_RUNTIME`; evidência: `RUNTIME_VALIDATED`.

**Lacuna:** Restart falhou por ambiente PowerShell; plugin tentou HTTP no cliente repetidamente.

**Implementar:** Sanitizar subprocessos, manter assinatura, separar transportes e expor readiness/erros estruturados.

**Aceitação:** Abrir e fechar repetidamente sem intervenção; falha tem causa e contexto; cliente não entra em retry HTTP inválido.

**Dependências:** ENV-04.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### ENV-06 — Limites externos e permissões como dados verificáveis

**M0 · P0 · CORE · esforço M**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Catálogo contém afirmações datadas sobre beta, quotas, importação e acesso a assets que podem divergir do ambiente atual.

**Implementar:** Matriz de backend/contexto/dono/permissão/versão; revalidar limites e oferecer pacote importável quando o provider não consegue executar.

**Aceitação:** Método presente sem permissão permanece indisponível; mudança de conta, versão ou moderação invalida o estado antigo.

**Dependências:** ENV-04.

Evidência/base: [production-capabilities.v1.json](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/quality/production-capabilities.v1.json), [mcp](https://create.roblox.com/docs/studio/mcp).

## Documentação e rastreabilidade

Base a reaproveitar: [docs/platform/OVERVIEW.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/platform/OVERVIEW.md), [docs/platform/ENGINE-CHARTER.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/platform/ENGINE-CHARTER.md), [docs/engine-map.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/engine-map.md).

### DOC-01 — Documentação viva e uma entrada canônica

**M0 · P0 · CORE · esforço M**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Documentos antigos contradizem comandos, protocolos, limitações e nível de conclusão atual.

**Implementar:** Datar e arquivar estados históricos; gerar inventário da API e testar exemplos; apontar a fonte normativa.

**Aceitação:** Nenhuma referência atual anuncia método ausente ou classifica plano como implementação; documentação de instalação reproduzida.

**Dependências:** ENV-04.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### DOC-02 — Cobertura de revisão semântica

**M4 · P1 · CORE · esforço L**

Estado: `PROVA_AUSENTE_NESTA_AUDITORIA`; evidência: `NOT_VALIDATED`.

**Lacuna:** A varredura completa não foi uma revisão manual de todas as linhas.

**Implementar:** Criar mapa por arquivo/hash com revisão, risco e testes; completar leitura dos caminhos críticos e ampliar por dependência.

**Aceitação:** Relatório distingue compilação, leitura, revisão e execução; áreas restantes aparecem explicitamente sem selo integral.

**Dependências:** DOC-01.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

## Persistência e compras

Base a reaproveitar: [forge/luau/Forge/Save](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Save), [forge/luau/Forge/Monetization](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Monetization), [roblox/lib/GameKit](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/roblox/lib/GameKit).

### DAT-01 — Posse de perfil em toda gravação

**M1 · P0 · CORE · esforço L**

Estado: `DEFEITO_CONFIRMADO`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Perfil temporário sem lock sobrescreveu dado legítimo na reprodução local.

**Implementar:** Estados explícitos de carregamento e escrita com fencing e UpdateAsync; perfil sem posse não grava.

**Aceitação:** Disputa e retomada entre duas sessões preservam saldo; escritor antigo, timeout e fallback não apagam dados.

**Dependências:** ENV-01.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### DAT-02 — Liberação real de sessão

**M1 · P0 · CORE · esforço S**

Estado: `DEFEITO_CONFIRMADO`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** release and nil or jobId mantém o lock na saída.

**Implementar:** Liberação explícita e atômica condicionada ao dono atual, com identificador único inclusive em Studio.

**Aceitação:** Saída limpa permite reentrada; sessão antiga não libera lock de outra sessão.

**Dependências:** DAT-01.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### DAT-03 — Migração, corrupção e versões futuras

**M1 · P0 · CORE · esforço M**

Estado: `DEFEITO_CONFIRMADO`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Migração falha e ainda avança versão; versão futura pode ser reduzida.

**Implementar:** Migrar em cópia, validar, confirmar atomicamente; preservar versões desconhecidas e dados em quarentena.

**Aceitação:** Erro intermediário mantém original; downgrade indevido recusado; recuperação preserva cópia auditável.

**Dependências:** DAT-01.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### DAT-04 — Autosave e encerramento com prazo

**M1 · P0 · CORE · esforço M**

Estado: `DEFEITO_CONFIRMADO`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** BindToClose espera intervalo fixo sem acompanhar conclusão das escritas.

**Implementar:** Fila de gravações com orçamento, backoff, coalescência, prazo e resultado de flush.

**Aceitação:** Escrita lenta e throttling não produzem sucesso falso; encerramento relata o que confirmou e o que não confirmou.

**Dependências:** DAT-01, DAT-02.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### DAT-05 — Recibo e recompensa na mesma transação

**M1 · P0 · CORE · esforço L**

Estado: `DEFEITO_CONFIRMADO`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Callback repetido concedeu duas recompensas e o módulo registrou uma.

**Implementar:** Concessão como transformação pura do perfil junto ao ledger; efeitos externos idempotentes após commit durável.

**Aceitação:** Repetição, dois servidores e falha antes/depois do commit terminam com uma entrega durável.

**Dependências:** DAT-01, DAT-03.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### DAT-06 — Prova com serviços reais isolados

**M4 · P1 · CORE · esforço L**

Estado: `PROVA_AUSENTE_NESTA_AUDITORIA`; evidência: `NOT_VALIDATED`.

**Lacuna:** Cinco cenários ficaram sem DataStore no place local; simulação não prova persistência publicada.

**Implementar:** Ambiente de testes com namespaces e identidades isoladas, quotas, backup e limpeza identificada por run.

**Aceitação:** Salvar, desconectar, reentrar, migrar e repetir recibos com evidência do serviço real, sem dados de produção.

**Dependências:** DAT-03, DAT-04, DAT-05, REL-03.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### DAT-07 — Configuração de produtos e direitos de compra

**M3 · P1 · PROFILE · esforço L**

Estado: `PROVA_AUSENTE_NESTA_AUDITORIA`; evidência: `NOT_VALIDATED`.

**Lacuna:** O catálogo registra lacunas em provisioning, compra de teste, replay e reconciliação; módulos sozinhos não configuram o produto externo.

**Implementar:** Vincular produto/passe ao universo/dono e ambiente; preparar configuração e testar compra pelos mecanismos suportados.

**Aceitação:** Oferta inexistente, produto de outro destino ou direito indisponível impede a integração; configuração correta reconcilia entrega durável.

**Dependências:** DAT-05, REL-03.

Evidência/base: [production-capabilities.v1.json](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/quality/production-capabilities.v1.json).

## Rede e autoridade

Base a reaproveitar: [forge/luau/Forge/Net](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Net), [forge/luau/Forge/Netcode](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Netcode).

### NET-01 — Formato e autorização compostos

**M1 · P0 · CORE · esforço M**

Estado: `DEFEITO_CONFIRMADO`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Custom check desativou shape e pacote malformado chegou ao handler.

**Implementar:** Compor formato e verificador de domínio, limitar dados e rejeitar exceções de validação.

**Aceitação:** Tipo errado, campos extras, NaN, tamanho excessivo e check que lança erro não chegam ao handler.

**Dependências:** ENV-01.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### NET-02 — Autoridade servidor em cada verbo

**M1 · P0 · CORE · esforço L**

Estado: `PROVA_AUSENTE_NESTA_AUDITORIA`; evidência: `NOT_VALIDATED`.

**Lacuna:** Não houve auditoria completa das superfícies de todos os jogos e sistemas.

**Implementar:** Catálogo de remotes com regras de posse, distância, cooldown, transição e valores decididos pelo servidor.

**Aceitação:** Payloads forjados em cada verbo protegido são recusados; nenhum caminho confia em preço ou posse enviados pelo cliente.

**Dependências:** NET-01, DAT-01.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### NET-03 — Multicliente, perda, jitter e reentrada

**M4 · P1 · CORE · esforço L**

Estado: `PROVA_AUSENTE_NESTA_AUDITORIA`; evidência: `NOT_VALIDATED`.

**Lacuna:** Testes locais de módulos não comprovaram toda a replicação entre clientes independentes.

**Implementar:** Integrar simulação de rede suportada e cenários join/leave/reconnect, isolamento e estado inicial.

**Aceitação:** Dois ou mais clientes mantêm invariantes sob condições declaradas; estado de um jogador não vaza para outro.

**Dependências:** CTL-06, NET-01.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### NET-04 — Predição, reconciliação e acerto justo

**M4 · P1 · PROFILE · esforço L**

Estado: `PROVA_AUSENTE_NESTA_AUDITORIA`; evidência: `NOT_VALIDATED`.

**Lacuna:** Netcode existe; sensação e correção sob latência real não foram comprovadas.

**Implementar:** Validar prediction/ack/reconcile, histórico de hit e limites de rewind por perfil de ação.

**Aceitação:** Ação recusada reconcilia; acerto inválido não é aceito; medir resposta visual e divergência com latência e perda.

**Dependências:** NET-03.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### NET-05 — Contratos de replicação versionados

**M3 · P1 · CORE · esforço M**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Ter eventos definidos não garante handlers, compatibilidade e orçamento ao compor sistemas.

**Implementar:** Validar schemas, assinaturas, handlers, estado inicial, payload e versões entre cliente/servidor.

**Aceitação:** Cliente sem estado inicial ou remoto sem handler falha claramente; pacote incompatível não causa estado silenciosamente incorreto.

**Dependências:** NET-01, FAC-08.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

## Controle do Studio e do jogador

Base a reaproveitar: [rqe/hub](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/rqe/hub), [rqe/mcp/client.py](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/rqe/mcp/client.py), [rqe/mcp/world_tools.py](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/rqe/mcp/world_tools.py), [apps/studio-plugin/src](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/apps/studio-plugin/src), [rqe/capture.py](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/rqe/capture.py).

### CTL-01 — Federação MCP funcional

**M2 · P1 · CORE · esforço M**

Estado: `DEFEITO_CONFIRMADO`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** StudioMcpClient foi chamado com assinatura inválida antes de enviar input.

**Implementar:** Reparar spawn e ciclo stdio, negociar tools/list, tipar respostas e selecionar studio_id explícito.

**Aceitação:** Read, edit, teclado, mouse e erros exercitados pela mesma superfície do agente, sem pressupor ferramentas pelo nome.

**Dependências:** ENV-04.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### CTL-02 — Identidade exata de build, processo e cliente

**M2 · P1 · CORE · esforço L**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Título e nome de place não bastam para distinguir todas as sessões.

**Implementar:** Vincular hash dos bytes, productId, processo/janela, sessão e jogador em cada operação.

**Aceitação:** Dois places com mesmo nome e reinício durante operação nunca cruzam evidências ou mutações.

**Dependências:** ENV-05.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### CTL-03 — Câmera e captura do mesmo cliente

**M2 · P1 · CORE · esforço M**

Estado: `DEFEITO_OBSERVADO_EM_RUNTIME`; evidência: `RUNTIME_VALIDATED`.

**Lacuna:** Captura confiável usou pose do servidor e dimensão do cliente.

**Implementar:** Obter pose completa, viewport e estado renderizado do cliente correto, antes e depois da captura.

**Aceitação:** Mover câmera cliente invalida continuidade incorreta; oclusão, troca de janela e sessão são detectadas.

**Dependências:** CTL-02.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### CTL-04 — Observações paginadas e referência estável

**M2 · P1 · CORE · esforço M**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Consultas truncadas e refs de outro DataModel podem parecer ausência de objetos.

**Implementar:** Protocolo de paginação, limites explícitos, validade de refs e amostras ligadas ao contexto.

**Aceitação:** Mundo acima do limite de retorno é enumerado ou marcado incompleto; ref expirada nunca resolve outro objeto.

**Dependências:** CTL-02.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### CTL-05 — Modo jogador sem informação interna

**M2 · P1 · CORE · esforço L**

Estado: `PROVA_AUSENTE_NESTA_AUDITORIA`; evidência: `NOT_VALIDATED`.

**Lacuna:** A jornada medida precisou localizar caminhos internos e não foi black-box.

**Implementar:** Separar interface de jogador e observação diagnóstica; registrar ações/frames sem paths ou pivôs como instruções.

**Aceitação:** Agente reconhece objetivo e compra usando visão e input; instrumentação interna só entra no diagnóstico posterior.

**Dependências:** CTL-01, CTL-03.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### CTL-06 — Testes e dispositivos por APIs nativas

**M2 · P1 · CORE · esforço L**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Automação multicliente atual usa coordenadas e menu; serviços recentes já aparecem no Studio instalado.

**Implementar:** Adapters versionados para StudioTestService, dispositivos e input; fallback somente quando necessário e identificado.

**Aceitação:** Play, Run, multicliente, alteração de dispositivo, desconexão e stop funcionam com timeout/cancelamento e resultado correlacionado.

**Dependências:** ENV-04, CTL-02.

Evidência/base: [planning-api-discovery.json](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/.tmp/audit-2026-09-05/planning-api-discovery.json), [teamtest.py](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/rqe/hub/teamtest.py), [StudioTestService](https://create.roblox.com/docs/reference/engine/classes/StudioTestService).

### CTL-07 — Objetivos e aproximações espaciais

**M2 · P1 · CORE · esforço M**

Estado: `DEFEITO_OBSERVADO_EM_RUNTIME`; evidência: `RUNTIME_VALIDATED`.

**Lacuna:** ProximityPrompt provocou E_BAD_PARAMS; coleta limita descoberta a 40 e avaliação a 12 objetivos.

**Implementar:** Resolver suportes e pontos de aproximação; objetivos do contrato e múltiplos spawns; cobertura explícita.

**Aceitação:** Prompt em Attachment/Part/Model e mais de 12 objetivos avaliados sem amostra apresentada como total.

**Dependências:** CTL-04.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### CTL-08 — Mutações reversíveis e rastreáveis

**M3 · P1 · CORE · esforço L**

Estado: `PROVA_AUSENTE_NESTA_AUDITORIA`; evidência: `NOT_VALIDATED`.

**Lacuna:** Não foi demonstrado um ciclo uniforme de diff/aplicar/desfazer para todas as ferramentas de autoria.

**Implementar:** ChangeSet com precondições, proprietário, efeitos, snapshot e compensação por operação suportada.

**Aceitação:** Falha no meio de edição não deixa cena atribuída como completa; alteração humana conflitante é preservada e reportada.

**Dependências:** CTL-02, FAC-04.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### CTL-09 — Stack trace ligado à fonte e ao build

**M2 · P1 · CORE · esforço M**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Catálogo registra ausência de source map entre traceback do DataModel e arquivo do repositório.

**Implementar:** Mapear scripts, linhas e hashes do bundle para fonte, e anexar frame/ação/contexto ao erro.

**Aceitação:** Erro Luau em runtime aponta para o arquivo/linha da revisão construída, mesmo com módulo renomeado ou código gerado.

**Dependências:** CTL-02, FAC-04.

Evidência/base: [production-capabilities.v1.json](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/quality/production-capabilities.v1.json).

## Execução da fábrica por agentes

Base a reaproveitar: [rqe/orchestrator](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/rqe/orchestrator), [rqe/mcp/factory_execution.py](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/rqe/mcp/factory_execution.py), [rqe/producer](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/rqe/producer), [forge/cli/quality.py](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/cli/quality.py).

### FAC-01 — Uma definição de produto completa

**M2 · P1 · CORE · esforço L**

Estado: `DEFEITO_CONFIRMADO`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Forge quality gera descriptor sem productIntent e pode sobrescrever política editada.

**Implementar:** Integrar GameProjectDefinition e product truth; preservar política; separar campos derivados de decisões autorais.

**Aceitação:** Regeneração não apaga requisitos editados; contrato, referências, spec e runtime identificam o mesmo produto.

**Dependências:** DOC-01.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### FAC-02 — Handlers executáveis para o DAG inteiro

**M2 · P1 · CORE · esforço XL**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Executor durável existe; a superfície MCP registra apenas specification e design de leitura.

**Implementar:** Conectar handlers de autoria, assets, build, Studio, medição, play, captura, reparo e release candidate.

**Aceitação:** Plano de consumidor executa até candidato ou bloqueio preciso; nenhum estágio obrigatório depende de texto não executável.

**Dependências:** FAC-01, CTL-02, REL-01.

Evidência/base: [factory_execution.py](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/rqe/mcp/factory_execution.py), [executor.py](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/rqe/orchestrator/executor.py).

### FAC-03 — Retomada validada por artefatos e versões

**M2 · P1 · CORE · esforço L**

Estado: `DEFEITO_CONFIRMADO`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Checkpoint do producer licencia pular estágios pelo brief/status sem verificar hashes dos arquivos produzidos.

**Implementar:** Checkpoint por run e identidade completa: engine, ferramentas, entradas e saídas; invalidar descendentes afetados.

**Aceitação:** Apagar ou alterar um output, mudar fonte/engine ou interromper escrita impede reaproveitamento incorreto.

**Dependências:** FAC-01.

Evidência/base: [checkpoint.py](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/rqe/producer/checkpoint.py), [pipeline.py](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/rqe/producer/pipeline.py).

### FAC-04 — Ownership e integração de código

**M2 · P1 · CORE · esforço L**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Worktrees, leases e ownership existem; cadeia de autoria concorrente até integração real não foi provada.

**Implementar:** Conectar escritor e integrador aos limites por arquivo, commits/diffs e dependências de SDK.

**Aceitação:** Duas alterações conflitantes não são sobrescritas; lease expirada impede escritor antigo; modo sequencial funciona sozinho.

**Dependências:** ENV-02.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### FAC-05 — Reparo com regressão por impacto

**M4 · P1 · CORE · esforço L**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Há planejamento de impacto, sem demonstração completa de reparo orientado por falha até novo gate.

**Implementar:** Ligar finding a origem, dependências, mudança mínima e regressão afetada, seguida de regressão total.

**Aceitação:** Falha semeada gera patch revisável; reexecução prova correção e nova regressão completa evita aprovar dano colateral.

**Dependências:** FAC-02, QAT-01.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### FAC-06 — Orçamentos, cancelamento e retomada por agente

**M2 · P1 · CORE · esforço L**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Ledger e scheduler existem, mas a fábrica completa não foi operada com limites fim a fim.

**Implementar:** Budget de tempo/custo/tentativas, filas de Studio/provider, cancelamento cooperativo e estado UNCERTAIN.

**Aceitação:** Interromper agente durante ferramenta não dispara duplicação cega; retomar não repete publicação já confirmada.

**Dependências:** FAC-03, FAC-04.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### FAC-07 — Papéis, revisão independente e permissões

**M2 · P1 · CORE · esforço M**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Charter separa implementador e aprovação; falta provar aplicação em todos os adapters.

**Implementar:** Papéis para design, autoria, revisão e release; credenciais por escopo e política persistente de autorização.

**Aceitação:** Implementador não altera threshold congelado nem a evidência do revisor; ação autorizada não exige confirmação repetida.

**Dependências:** FAC-04, REL-01.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### FAC-08 — Extensão além de templates e vocabulários fixos

**M3 · P1 · CORE · esforço L**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Há SDK extensível e DSLs estreitas; composição desconhecida não pode virar um teto silencioso.

**Implementar:** Contrato de extensão para Luau e providers com schemas, testes, budgets, lifecycle e registro de capacidades.

**Aceitação:** Mecânica inédita é adicionada sem editar orquestrador por nome de jogo; ferramenta sem suporte reporta limite preciso.

**Dependências:** FAC-01.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

## Mundo, navegação e física

Base a reaproveitar: [forge/luau/Forge/Nav](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Nav), [forge/luau/Forge/World](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/World), [forge/luau/Forge/Scene](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Scene), [forge/luau/Forge/Streaming](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Streaming), [roblox/lib/WorldKit](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/roblox/lib/WorldKit).

### WRL-01 — Navegação sem reentrada de cálculo

**M2 · P1 · CORE · esforço L**

Estado: `DEFEITO_OBSERVADO_EM_RUNTIME`; evidência: `RUNTIME_VALIDATED`.

**Lacuna:** Proving Ground não chegou ao alvo em 25s; simulação abriu três cálculos concorrentes por agente.

**Implementar:** Fila de pathfinding, in-flight guard, geração/cancelamento, chegada/standoff e diagnóstico de rig.

**Aceitação:** Cenário original passa repetidamente, stop invalida cálculo pendente e orçamento limita demanda por população.

**Dependências:** ENV-02.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### WRL-02 — Layout com intenção de gameplay

**M3 · P1 · CORE · esforço L**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Blockout existe; topologia e aparência não demonstram legibilidade ou circulação final.

**Implementar:** Regiões, rotas, marcos, sightlines, densidade e objetivos testados antes e depois do dressing.

**Aceitação:** Spawn encontra objetivo; rotas, portas, escadas e pontos de retorno continuam utilizáveis na versão com arte.

**Dependências:** FAC-01, CTL-07, WRL-01.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### WRL-03 — Kits, terreno e materiais coerentes

**M3 · P1 · CORE · esforço L**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Primitivas e kits existem; os consumidores capturados ainda apresentam acabamento de teste.

**Implementar:** Kits modulares com conexões, pivôs, escala, variações e material/UV; aplicar com seeds e budgets.

**Aceitação:** Um conjunto modular produz regiões coerentes e variação controlada, sem duplicação invisível ou colisão inadequada.

**Dependências:** WRL-02, AST-03.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### WRL-04 — Streaming preserva gameplay

**M4 · P1 · PROFILE · esforço L**

Estado: `PROVA_AUSENTE_NESTA_AUDITORIA`; evidência: `NOT_VALIDATED`.

**Lacuna:** Streaming existe; descarregar e remontar conteúdo com estado persistido não foi validado nesta auditoria.

**Implementar:** Separar existência visual, estado autoritativo e replicação; lifecycle de chunks e assets com referências válidas.

**Aceitação:** Entrar/sair e cruzar fronteiras não reinicia loot ou inimigos indevidamente nem quebra quests e colisões.

**Dependências:** WRL-03, GAM-01, QAT-05.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### WRL-05 — Física e propriedade de rede

**M4 · P1 · CORE · esforço L**

Estado: `PROVA_AUSENTE_NESTA_AUDITORIA`; evidência: `NOT_VALIDATED`.

**Lacuna:** Geometria estática e bot não comprovam todas as colisões, escalas e interações multijogador.

**Implementar:** Testes de degrau, inclinação, porta, moving platform, velocidades e network ownership por perfil.

**Aceitação:** Trajetos físicos suportados funcionam com avatares/perfis declarados; queda, travamento e empurrões têm diagnóstico.

**Dependências:** CTL-06, WRL-01.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### WRL-06 — Roundtrip Studio e fonte

**M3 · P1 · CORE · esforço L**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Scene/Editor existem; edição autoral e regeneração precisam preservar a intenção e a origem.

**Implementar:** Mapear seleção/cena a fonte, serialização canônica, diffs, overrides e regeneração incremental.

**Aceitação:** Editar no Studio, salvar, rebuild e reabrir preserva alteração; conflito com geração não é sobrescrito silenciosamente.

**Dependências:** CTL-08, WRL-03.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### WRL-07 — Montagem por restrições e layouts em lote

**M3 · P1 · PROFILE · esforço L**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Catálogo registra falta de alinhamento por face de modelo rotacionado e composição de múltiplas peças.

**Implementar:** Sockets, faces nomeadas, snap, distribuição e restrições espaciais com preview e operações em lote.

**Aceitação:** Kit rotacionado se conecta corretamente; conflito de restrições não desloca partes silenciosamente; undo restaura o lote.

**Dependências:** CTL-08, WRL-03.

Evidência/base: [production-capabilities.v1.json](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/quality/production-capabilities.v1.json).

## Assets e ferramentas de criação

Base a reaproveitar: [rqe/assets](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/rqe/assets), [rqe/geometry](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/rqe/geometry), [rqe/sourcing](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/rqe/sourcing), [forge/luau/Forge/Assets](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Assets), [forge/luau/Forge/Catalog](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Catalog).

### AST-01 — Busca e adoção de assets rastreáveis

**M3 · P1 · CORE · esforço L**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Catálogos e busca existem; toda seleção não foi provada até integração.

**Implementar:** Pesquisa tipada, previews, provenance, licença, creator, versão e decisão REUSE/ADAPT/GENERATE por papel artístico.

**Aceitação:** Asset escolhido é acessível ao dono do jogo, script-free quando exigido e vinculado ao brief e à manifestação final.

**Dependências:** FAC-01.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### AST-02 — Workers reais de criação

**M3 · P1 · CORE · esforço XL**

Estado: `PROVA_AUSENTE_NESTA_AUDITORIA`; evidência: `NOT_VALIDATED`.

**Lacuna:** Outbox e fake provider não demonstram geração original real completa.

**Implementar:** Integrar providers de mesh/imagem/áudio/animação com jobs retomáveis, ferramenta/modelo versão, custo e outputs verificáveis.

**Aceitação:** Cada classe necessária ao contrato produz bytes, preview e recibo reais; indisponível bloqueia sem ID fictício.

**Dependências:** FAC-02, FAC-06.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### AST-03 — Pacote de asset pronto para produção

**M3 · P1 · CORE · esforço L**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Há validadores/geometry runtime, mas qualidade de um asset precisa incluir uso final.

**Implementar:** Topologia, escala, pivô, UV, materiais, colisão, custo, previews e revisão da silhueta por brief.

**Aceitação:** Asset falha por defeito de importação/uso mesmo se o render é bonito; versão aprovada tem hashes e limites medidos.

**Dependências:** AST-01.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### AST-04 — Publicação e moderação de assets

**M3 · P1 · CORE · esforço L**

Estado: `PROVA_AUSENTE_NESTA_AUDITORIA`; evidência: `NOT_VALIDATED`.

**Lacuna:** Upload e adapters existem; cadeia real para todas as classes não foi demonstrada nesta auditoria.

**Implementar:** Estado durável de upload/moderação/permissão, polling, retry idempotente, versionamento e integração por ID confirmado.

**Aceitação:** Reiniciar worker não duplica upload; asset negado ou sem permissão mantém build bloqueado; ID aprovado carrega no jogo.

**Dependências:** AST-02, AST-03, REL-03.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### AST-05 — Cache e builds incrementais de conteúdo

**M3 · P1 · CORE · esforço M**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Existem pacotes por hash, mas reutilização e invalidação entre todos os caminhos precisam de contrato único.

**Implementar:** Content hash por fonte/config/ferramenta; template/clones; invalidação transitiva e cache com limites.

**Aceitação:** Mesmo input reutiliza bytes sem refazer upload; mudança relevante invalida dependentes, sem reaproveitar asset errado.

**Dependências:** AST-03, FAC-03.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### AST-06 — Quarentena de conteúdo importado

**M1 · P0 · CORE · esforço L**

Estado: `PROVA_AUSENTE_NESTA_AUDITORIA`; evidência: `NOT_VALIDATED`.

**Lacuna:** Dois arquivos de salvage não compilaram; importação não equivale a auditoria de código, licença ou dependências.

**Implementar:** Separar kits de referência e pacotes aprovados, inspecionar scripts/links e recursos transitivos antes da adoção.

**Aceitação:** Kit não aprovado não entra no build por busca automática; importação excessiva ou código não permitido é recusado.

**Dependências:** ENV-02.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### AST-07 — Asset aprovado integrado automaticamente à fonte

**M3 · P1 · CORE · esforço L**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Um ID que resolve não comprova que mesh, material, áudio ou animação foi ligado ao jogo.

**Implementar:** Bindings declarativos e patch da fonte/catálogo por papel, rebuild incremental e verificação runtime no uso correto.

**Aceitação:** Trocar asset por versão aprovada atualiza o consumidor e sua evidência; resolução de ID sem uso não passa.

**Dependências:** AST-04, FAC-03.

Evidência/base: [production-capabilities.v1.json](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/quality/production-capabilities.v1.json), [integration.py](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/rqe/assets/integration.py).

## Personagens e apresentação

Base a reaproveitar: [forge/luau/Forge/Rig](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Rig), [forge/luau/Forge/Anim](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Anim), [forge/luau/Forge/IK](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/IK), [forge/luau/Forge/Camera](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Camera), [forge/luau/Forge/Feel](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Feel), [forge/luau/Forge/Audio](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Audio), [rqe/assets/animation_authoring.py](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/rqe/assets/animation_authoring.py).

### CHR-01 — Rigs próprios e importação de animação

**M3 · P1 · PROFILE · esforço XL**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Rig/IK/Anim existem; a linguagem de geometria não expõe armature/skinning/retargeting completos.

**Implementar:** Adapter de autoria/importação de rig, skin, joints, retarget, root motion quando aplicável e clipes.

**Aceitação:** Um rig próprio e um avatar suportado executam o mesmo contrato de ações sem juntas perdidas ou deformação inadequada.

**Dependências:** AST-03, FAC-08.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### CHR-02 — Animação e ação sincronizadas

**M3 · P1 · CORE · esforço L**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Clipes e procedural existem; fidelidade temporal completa não foi comprovada.

**Implementar:** Blend, prioridade, transições, markers, cancelamento e sincronização com hitbox, som e feedback.

**Aceitação:** Interromper ataque, morrer, trocar arma e renascer não deixa clip, joint, hitbox ou conexão residual.

**Dependências:** GAM-01.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### CHR-03 — Câmera, som, VFX e sensação de controle

**M3 · P1 · CORE · esforço L**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Módulos existem, mas composição audiovisual profissional não foi demonstrada nos consumidores.

**Implementar:** Perfis de câmera/mix, áudio espacial, VFX legível, resposta visual, recoil/shake e redução de movimento.

**Aceitação:** Ação tem feedback compreensível sem poluição; pausa, respawn e mudança de câmera limpam efeitos e respeitam preferências.

**Dependências:** CHR-02, UIX-04.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### CHR-04 — Avatares, proporções e cosméticos

**M4 · P1 · PROFILE · esforço L**

Estado: `PROVA_AUSENTE_NESTA_AUDITORIA`; evidência: `NOT_VALIDATED`.

**Lacuna:** Não foram testadas combinações de rig, escala e acessórios nos sistemas e mapas.

**Implementar:** Perfis de corpo/colisão/equipamento e validação de compatibilidade com ações e câmera.

**Aceitação:** Avatares declarados atravessam mapa, equipam itens e animam sem clipping impeditivo ou hitbox injusta.

**Dependências:** CHR-01, WRL-05.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

## Sistemas de gameplay e design

Base a reaproveitar: [forge/luau/Forge/Core](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Core), [forge/luau/Forge/Combat](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Combat), [forge/luau/Forge/Progression](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Progression), [forge/luau/Forge/Economy](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Economy), [forge/luau/Forge/Inventory](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Inventory), [forge/luau/Forge/Quest](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Quest), [rqe/economy](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/rqe/economy).

### GAM-01 — Lifecycle de sistemas compartilhado

**M3 · P1 · CORE · esforço L**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Muitos módulos coexistem; montagem e teardown precisam obedecer à mesma semântica.

**Implementar:** Dependências explícitas, boot/ready/start/stop/dispose, escopo de conexões e estado de carregamento.

**Aceitação:** Iniciar, parar, reentrar e renascer repetidamente não duplica handlers, sistemas, UI ou recursos.

**Dependências:** FAC-08, DAT-01.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### GAM-02 — Mecânicas compostas por contratos

**M3 · P1 · CORE · esforço XL**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Combate, movimento, itens, quests e progressão existem, sem prova de toda a composição escolhida.

**Implementar:** Interfaces de recursos, ações, inventário, interação e progressão com adapters para implementações existentes.

**Aceitação:** Os dois consumidores integram sistemas sem cópias divergentes nem regras de gênero no núcleo.

**Dependências:** GAM-01, NET-05.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### GAM-03 — Dados de conteúdo validados

**M3 · P1 · CORE · esforço M**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Tabelas e designers existem; relações entre conteúdo e sistemas podem ficar sem verificação.

**Implementar:** Schemas e referências cruzadas para itens, inimigos, drops, receitas, objetivos e estados.

**Aceitação:** ID órfão, ciclo impossível, reward inválido e conteúdo sem uso são encontrados antes do build.

**Dependências:** GAM-02.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### GAM-04 — Economia e progressão verificáveis

**M3 · P1 · PROFILE · esforço L**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Simulações existentes não são prova da curva real de experiência e persistência.

**Implementar:** Simular regras compartilhadas, medir fontes/sinks, preços, pacing e invariantes; calibrar com sessões reais.

**Aceitação:** Modelo e execução Luau concordam; inflação, progressão bloqueada e custo sem reward são detectados.

**Dependências:** GAM-03, DAT-05.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### GAM-05 — Primeira sessão e recuperação

**M3 · P1 · CORE · esforço L**

Estado: `PROVA_AUSENTE_NESTA_AUDITORIA`; evidência: `NOT_VALIDATED`.

**Lacuna:** Comprar uma vez não demonstra onboarding, tutorial, morte, retorno e reentrada.

**Implementar:** Jornada inicial com objetivos legíveis, feedback, estado vazio, derrota, recuperação e persistência do progresso.

**Aceitação:** Jogador novo completa o ciclo principal e volta após sair sem assistência interna nem perda de progresso.

**Dependências:** GAM-02, UIX-01.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### GAM-06 — Pacotes por necessidade de jogo

**M6 · P2 · PROFILE · esforço XL**

Estado: `CAPACIDADE_PROPOSTA`; evidência: `NOT_VALIDATED`.

**Lacuna:** Uma engine geral precisa expandir sem carregar todas as mecânicas em todos os jogos.

**Implementar:** Perfis opcionais para partida/party/social/trading, construção, survival, veículos e outros domínios pedidos.

**Aceitação:** Cada pacote declara dependências, orçamento e cenários; jogo que não o usa não paga seu custo de execução.

**Dependências:** GAM-02, FAC-08.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

## Interface, dispositivos e acessibilidade

Base a reaproveitar: [forge/luau/Forge/UI](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/UI), [forge/luau/Forge/Input](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Input), [forge/luau/Forge/Platform](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Platform), [forge/luau/Forge/Access](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Access).

### UIX-01 — Design system aplicado aos consumidores

**M3 · P1 · CORE · esforço L**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** UI existe; capturas mostram texto pequeno, identificadores técnicos e acabamento inconsistente.

**Implementar:** Tokens, hierarquia visual, estados, ícones, nomes de apresentação, loading e mensagens acionáveis.

**Aceitação:** Fluxos de loja/inventário/configuração são legíveis e consistentes sem expor nomes internos de implementação.

**Dependências:** FAC-01.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### UIX-02 — Toque, teclado e gamepad reais

**M4 · P1 · CORE · esforço L**

Estado: `PROVA_AUSENTE_NESTA_AUDITORIA`; evidência: `NOT_VALIDATED`.

**Lacuna:** Não foi comprovada a jornada completa nos dispositivos de destino.

**Implementar:** Matriz de resolução/orientação, safe area, foco, captura de input, gestos e troca de modalidade.

**Aceitação:** Cada fluxo crítico é concluído nas modalidades declaradas; UI não oculta controles nem perde foco em modal.

**Dependências:** CTL-06, UIX-01.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### UIX-03 — Localização e conteúdo expansível

**M3 · P1 · CORE · esforço M**

Estado: `PROVA_AUSENTE_NESTA_AUDITORIA`; evidência: `NOT_VALIDATED`.

**Lacuna:** Cobertura de idiomas e textos longos não foi demonstrada.

**Implementar:** Chaves de tradução, formatação de número/tempo, fallback, fontes e testes de expansão de strings.

**Aceitação:** Português e idioma adicional suportado funcionam sem overflow, chaves internas ou truncamento de ação crítica.

**Dependências:** UIX-01.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### UIX-04 — Acessibilidade integrada ao gameplay

**M3 · P1 · CORE · esforço M**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Access existe, mas aplicação de captions, contraste e reducedMotion ao jogo inteiro não foi demonstrada.

**Implementar:** Conectar preferências a UI, áudio, câmera e VFX; sinais redundantes e alvos ajustáveis.

**Aceitação:** Preferência muda o resultado observado; objetivos continuam legíveis sem depender só de cor ou som.

**Dependências:** UIX-01.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

## Qualidade e provas de integração

Base a reaproveitar: [rqe/observe.py](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/rqe/observe.py), [rqe/scenario.py](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/rqe/scenario.py), [rqe/scene/critic.py](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/rqe/scene/critic.py), [rqe/release.py](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/rqe/release.py), [quality/probe-registry.v1.json](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/quality/probe-registry.v1.json), [tests](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/tests), [forge/luau/Forge/Testing](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Testing).

### QAT-01 — Produtores reais para requisitos obrigatórios

**M2 · P1 · CORE · esforço L**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Gate contém requisitos sem produtor utilizável ou integrado.

**Implementar:** Matriz requirement→producer→context→evidence; implementar produtores reutilizáveis e verificar cobertura.

**Aceitação:** Requisito obrigatório sem produtor bloqueia no planejamento; produtor registra cobertura e validação adequadas no run.

**Dependências:** FAC-01, CTL-07.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### QAT-02 — Testes negativos e de invariantes

**M4 · P1 · CORE · esforço L**

Estado: `PROVA_AUSENTE_NESTA_AUDITORIA`; evidência: `NOT_VALIDATED`.

**Lacuna:** Muitos testes passam enquanto bugs fundamentais sobreviveram; cobertura de falhas relevantes é incompleta.

**Implementar:** Testar código Luau original com serviços controláveis, propriedades/invariantes e defeitos semeados.

**Aceitação:** Suíte falha quando cada bug crítico é reintroduzido; fixture nunca vira medição real.

**Dependências:** DAT-05, NET-02, GAM-02.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### QAT-03 — Jornadas e replay diagnóstico

**M4 · P1 · CORE · esforço XL**

Estado: `PROVA_AUSENTE_NESTA_AUDITORIA`; evidência: `NOT_VALIDATED`.

**Lacuna:** Não há prova black-box completa nos dois consumidores auditados.

**Implementar:** Registro de input/frames/tempo e estado de teste, reprodução por contrato e diagnóstico após falha.

**Aceitação:** Onboarding→ação→recompensa→saída→retorno passa; replay explica falha sem prometer determinismo de toda física.

**Dependências:** CTL-05, GAM-05.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### QAT-04 — Qualidade visual com referências independentes

**M4 · P1 · CORE · esforço L**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Crítico é estreito e captura teve metadados incorretos; nota visual não garante acabamento.

**Implementar:** Corpus por câmera/gênero, brief visual congelado, métricas calibradas e revisão independente de imagens/movimento.

**Aceitação:** Exemplos ruins são rejeitados sem penalizar estilos válidos; revisão cobre composição, leitura, exposição e identidade.

**Dependências:** CTL-03, WRL-03, CHR-03, UIX-01.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### QAT-05 — Medições de desempenho com significado correto

**M2 · P1 · CORE · esforço M**

Estado: `DEFEITO_OBSERVADO_EM_RUNTIME`; evidência: `RUNTIME_VALIDATED`.

**Lacuna:** Heartbeat do servidor foi usado como FPS; amostras curtas e memória Studio não provam cliente.

**Implementar:** Separar frame cliente, tick servidor, memória e tráfego; janelas, warmup e percentis por dispositivo/cena.

**Aceitação:** Amostra aponta contexto e duração; servidor a 60 Hz não aprova cliente com frame lento.

**Dependências:** CTL-02, CTL-06.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### QAT-06 — Carga, duração e vazamentos

**M4 · P1 · CORE · esforço L**

Estado: `PROVA_AUSENTE_NESTA_AUDITORIA`; evidência: `NOT_VALIDATED`.

**Lacuna:** Execuções breves não comprovam estabilidade durante sessões longas e população alvo.

**Implementar:** Soak tests, stress controlado, perfil de instâncias/conexões/assets e performance em hardware alvo.

**Aceitação:** Budgets congelados são atendidos nos cenários definidos; crescimento persistente ou degradação causa falha reproduzível.

**Dependências:** QAT-05, NET-03, GAM-01.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### QAT-07 — Instrumentos calibrados e estados honestos

**M4 · P1 · CORE · esforço M**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Erro do observador e falta de serviço podem parecer falha de gameplay.

**Implementar:** Controles positivos/negativos de sondas, saúde do instrumento e estados INFRA_FAILED/INCONCLUSIVE/SKIP.

**Aceitação:** Sonda cega ou serviço ausente não gera PASS nem acusa o jogo sem evidência suficiente.

**Dependências:** QAT-01, CTL-04.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### QAT-08 — Aceitação da engine em jogos diferentes

**M4 · P1 · CORE · esforço XL**

Estado: `PROVA_AUSENTE_NESTA_AUDITORIA`; evidência: `NOT_VALIDATED`.

**Lacuna:** Os consumidores foram executados, mas nenhum completou toda a cadeia validada nesta auditoria.

**Implementar:** Dois consumidores completos e um terceiro brief de generalidade sem adaptação por nome no núcleo.

**Aceitação:** Dois candidatos íntegros; mudança deliberada de produto é rejeitada; terceiro brief produz plano e extensão honesta.

**Dependências:** FAC-02, QAT-03, QAT-04, QAT-06, DAT-06.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

## Release e distribuição

Base a reaproveitar: [rqe/release.py](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/rqe/release.py), [rqe/orchestrator/metrics.py](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/rqe/orchestrator/metrics.py), [forge/forge.py](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/forge.py), [forge/cli/publish.py](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/cli/publish.py), [forge/cli/playtest.py](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/cli/playtest.py), [forge/cli/rollback.py](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/cli/rollback.py).

### REL-01 — Uma autoridade de release vinculada aos bytes

**M1 · P0 · CORE · esforço L**

Estado: `DEFEITO_CONFIRMADO`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** forge publish usa recibo mutável de tamanho/data, aceitando conteúdo diferente.

**Implementar:** Reusar verificador de run final; congelar bytes e verificar build/produto/evidência antes do upload.

**Aceitação:** Troca de conteúdo, evidência de outro produto e manifesto adulterado impedem publicação normal e rollback indevido.

**Dependências:** ENV-01.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### REL-02 — Resultado pelo runId e artefatos íntegros

**M2 · P1 · CORE · esforço M**

Estado: `DEFEITO_CONFIRMADO`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** forge quality escolhe diretório por nome; reports/latest e bundles legados não são autoridade.

**Implementar:** Retornar runId explicitamente, verificar manifesto e links; manter compatibilidade apenas diagnóstica.

**Aceitação:** Execuções simultâneas nunca apresentam relatório de outra tentativa como resultado atual.

**Dependências:** REL-01, FAC-01.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### REL-03 — Ambientes e credenciais separados

**M1 · P0 · CORE · esforço M**

Estado: `PROVA_AUSENTE_NESTA_AUDITORIA`; evidência: `NOT_VALIDATED`.

**Lacuna:** Não foi comprovada a configuração integral de dev/test/staging/prod nesta auditoria.

**Implementar:** Policy de autorização persistente, segredos por escopo, namespaces de dados e destinos explícitos.

**Aceitação:** Teste não escreve em produção; credencial ausente gera pacote pronto e bloqueio preciso sem exposição de segredo.

**Dependências:** ENV-03.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### REL-04 — Publicação gradual e rollback compatível

**M5 · P2 · CORE · esforço L**

Estado: `PROVA_AUSENTE_NESTA_AUDITORIA`; evidência: `NOT_VALIDATED`.

**Lacuna:** Uploader e rollback existem, mas a operação real completa não foi testada aqui.

**Implementar:** Release candidate verificável, rollout compatível com recursos da plataforma, rollback de bytes e política de migração.

**Aceitação:** Publicar em ambiente autorizado, observar, detectar regressão e restaurar versão compatível com dados.

**Dependências:** REL-01, DAT-06, QAT-08.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### REL-05 — Separação de instrumentação e produto entregue

**M4 · P1 · CORE · esforço M**

Estado: `PROVA_AUSENTE_NESTA_AUDITORIA`; evidência: `NOT_VALIDATED`.

**Lacuna:** Bridge cliente e diagnóstico não tiveram auditoria completa no pacote distribuído.

**Implementar:** Manifesto de build distingue debug, testes e runtime; restringir/remove hooks de mutação e dados sensíveis.

**Aceitação:** Build de release não aceita comandos de teste privilegiados nem expõe credenciais ou fixtures como estado real.

**Dependências:** FAC-02, NET-02, REL-01.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### REL-06 — Comissionamento da operação

**M5 · P2 · CORE · esforço L**

Estado: `PROVA_AUSENTE_NESTA_AUDITORIA`; evidência: `NOT_VALIDATED`.

**Lacuna:** Aprovar qualidade não demonstra permissões externas, entrega e resposta operacional.

**Implementar:** Ensaio documentado de deploy, health, contingência e handoff com responsáveis e destinos claros.

**Aceitação:** Uma versão autorizada vai ao ambiente alvo e deixa evidência de saúde, rollback e pendências externas explícitas.

**Dependências:** REL-04, OPS-01, OPS-03.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

## Operação e escala da fábrica

Base a reaproveitar: [forge/luau/Forge/Telemetry](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Telemetry), [forge/luau/Forge/LiveOps](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/LiveOps), [forge/luau/Forge/Cluster](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/forge/luau/Forge/Cluster), [rqe/ledger.py](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/rqe/ledger.py), [rqe/orchestrator](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/rqe/orchestrator), [apps/dashboard](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/apps/dashboard).

### OPS-01 — Telemetria de experiência e operação

**M5 · P2 · CORE · esforço L**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Telemetry e analytics existem; funil, economia, erro e performance não foram comprovados como uma visão única.

**Implementar:** Eventos versionados e minimizados por sessão/build, taxas de amostragem e ingestão/consulta verificadas.

**Aceitação:** Dados reais de teste explicam abandono, erro e pacing; ausência de eventos aparece como ausência, não como zero.

**Dependências:** GAM-05, QAT-05.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### OPS-02 — Console do diretor de produto

**M2 · P1 · CORE · esforço L**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Dashboard e métricas existem; falta demonstrar a jornada completa de decisão e acompanhamento.

**Implementar:** Mostrar projeto, mudanças, preview, custo, dependências, evidências, impedimento e próxima ação.

**Aceitação:** Usuário inspeciona por que um build falhou e o que foi alterado sem ler logs extensos; links verificam o run correto.

**Dependências:** REL-02, FAC-06.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### OPS-03 — Configuração, alertas e contenção

**M5 · P2 · CORE · esforço L**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** LiveOps existe; operação segura de mudanças e incidentes não foi validada ponta a ponta.

**Implementar:** Config versionada, feature flags, desativação rápida de função, thresholds operacionais e runbooks.

**Aceitação:** Config inválida é recusada; incidente de teste gera diagnóstico e contenção sem corromper progresso.

**Dependências:** REL-03, OPS-01.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### OPS-04 — Experimentos e aprendizado de produto

**M6 · P2 · SCALE · esforço L**

Estado: `PROVA_AUSENTE_NESTA_AUDITORIA`; evidência: `NOT_VALIDATED`.

**Lacuna:** Simulação e percepção do agente não demonstram diversão ou retenção humana.

**Implementar:** Testes com jogadores, funnels e experimentos por coorte com guardrails de qualidade e interpretação de amostra.

**Aceitação:** Decisões apontam dados e incerteza; ausência de significância ou amostra não vira melhora afirmada.

**Dependências:** OPS-01, OPS-03.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### OPS-05 — Suporte e administração auditáveis

**M5 · P2 · CORE · esforço L**

Estado: `PROVA_AUSENTE_NESTA_AUDITORIA`; evidência: `NOT_VALIDATED`.

**Lacuna:** Fluxos de restauração e manutenção de dados não foram operados nesta auditoria.

**Implementar:** Ferramentas de inspeção, restauração, exportação/remoção conforme política, revisão de permissão e trilha de ações.

**Aceitação:** Operação em usuário de teste exige escopo correto, preserva histórico e permite verificar resultado e reversibilidade.

**Dependências:** DAT-06, REL-03, OPS-01.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### OPS-06 — Workers e projetos em escala

**M6 · P2 · SCALE · esforço XL**

Estado: `INTEGRACAO_PARCIAL`; evidência: `STATICALLY_VALIDATED`.

**Lacuna:** Orquestrador e leases existem; frota distribuída e concorrência autorizada não foram comprovadas.

**Implementar:** Workers por capacidade, filas por recurso, isolamento por produto e paralelismo sob política explícita.

**Aceitação:** Dois projetos concorrentes, worker morto e quota de provider não cruzam artefatos nem duplicam efeitos.

**Dependências:** QAT-08, FAC-06, REL-06.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).

### OPS-07 — Evolução do SDK e ecossistema

**M6 · P2 · SCALE · esforço L**

Estado: `CAPACIDADE_PROPOSTA`; evidência: `NOT_VALIDATED`.

**Lacuna:** Mais módulos sem compatibilidade verificável aumenta custo para cada consumidor.

**Implementar:** Pacotes versionados, matriz de compatibilidade, migrations, contratos de extensão e catálogo de exemplos executáveis.

**Aceitação:** Atualizar SDK mostra impacto e guia de migração; extensão pode ser removida sem dependência oculta no núcleo.

**Dependências:** FAC-08, ENV-03, QAT-08.

Evidência/base: [2026-09-05-auditoria-engine.md](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/docs/audits/2026-09-05-auditoria-engine.md).
