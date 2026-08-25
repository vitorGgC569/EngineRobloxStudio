# Plano de rollback

## Dados de jogador
1. Histórico de saves com versões (`VersionRollback`): últimas N versões
   endereçáveis; restore escreve para FRENTE, nunca reescreve histórico.
2. Rollback é uma nova versão com payload antigo — auditoria preservada.

## Build/place
3. Cada release imutável vive em `artifacts/<runId>/` com hash — voltar =
   publicar o rbxlx de um run anterior verificado.
4. LiveConfig: reverter tuning = restaurar defaults compilados (o store
   pode ser esvaziado sem republish).

## Procedimento humano
5. Congelar mudanças → identificar último run verde (`gate.release_allowed`)
   → publicar esse place → comunicar jogadores afetados → abrir issue com
   causa raiz.

## Automação
- Gate já bloqueia release sem evidência hash-bound; rollback usa os mesmos
  artefatos imutáveis.
