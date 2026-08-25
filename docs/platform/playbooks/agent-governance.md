# Governança de agentes

Destilado de BloxAI (personas) + rbsmithy (clean-room) + backup-guard.

## Escopos
- **Read-only** (auditoria): exploit-check, datastore-review, perf-profile —
  ferramentas de leitura do bridge; nenhuma mutação.
- **Write/runtime** (correção): remotes-networking, code write via
  `bridge.exec`; exige flag e audit trail.
- **QA** (jogo): ator dirigível em cenários declarados; sem paths internos
  em modo blackbox.

## Guardrails machine-enforced
1. Hook PreToolUse `backup-guard.js`: mutação em massa sem backup fresco é
   bloqueada (exit 2), TTL 30 min, fail-closed.
2. Mutações do bridge declaram efeito + idempotência (`at-most-once`
   para publish/delete).
3. Token de bridge só por ambiente (`RQE_BRIDGE_TOKEN`), nunca argumento.

## Honestidade
4. Agente não afirma playtest bem-sucedido sem evidência do adapter;
   headless é rotulado como headless.
5. Níveis de validação: nunca apresentar estático como runtime.
6. Clean-room: padrões são livres; código de terceiros entra só com
   licença verificada (MIT/Apache) ou como vendor isolado.
