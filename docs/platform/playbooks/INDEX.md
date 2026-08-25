# Playbooks — checklists operacionais da plataforma

Corpus destilado dos projetos rbsmithy-roblox-claude-skill e BloxAI
(ambos do próprio usuário), reduzido aos checks que a RQE pode aplicar ou
verificar. Cada playbook lista seu destino de automação.

## Índice

| Playbook | Arquivo | Destino de automação |
|---|---|---|
| Revisão anti-exploit | `anti-exploit-review.md` | Scanner estático (`rqe/scanner.py`) + probes de segurança |
| Revisão de persistência | `datastore-review.md` | Gate de release (requisitos persistence) + Forge/Save |
| Orçamento de frame | `frame-budget-review.md` | Probes runtime performance + QualityTierSelector |
| Plano de rollback | `rollback-plan.md` | `Forge/Save/VersionRollback.lua` + procedimento humano |
| Checklist pré-release | `pre-release-checklist.md` | `rqe release` gate (já automatizado; este doc lista o que o gate NÃO cobre) |
| Governança de agentes | `agent-governance.md` | Hooks (backup-guard) + regras de escopo read-only/write |

## Regras transversais

1. **Evidência rotulada**: nenhum checklist passa com afirmação sem fonte
   (`STATICALLY_VALIDATED` no mínimo; gameplay exige runtime).
2. **Fail-closed**: item não verificado é bloqueio, nunca "presumido ok".
3. **Sem segredo em argumento**: credenciais só por ambiente.
4. **Backup antes de mutação em massa**: enforced pelo hook
   `.claude/hooks/backup-guard.js` (TTL 30 min, fail-closed).
