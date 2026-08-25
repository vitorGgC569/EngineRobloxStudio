# Revisão de persistência (destilado de rbsmithy + BloxAI)

## Sessão e travas
1. Todo perfil usa session lock (UpdateAsync) com takeover de stale lock?
2. BindToClose salva todos os jogadores ativos e mantém o servidor vivo
   pelo tempo do save?
3. Falha de save coloca a sessão em read-only com notificação única
   (`Forge.Save.Gatekeeper`)?

## Schema
4. Perfil tem campo de versão + migrations encadeadas (`Forge.Save.Migrator`)?
5. Defaults reconciliados deep-merge sem sobrescrever valor existente?
6. Perfil de versão futura NUNCA é re-stampado (rollback não faz downgrade)?

## Idempotência
7. Dev products usam receipts idempotentes (`Forge.Save.ReceiptLedger`)?
8. Contadores cross-server usam merge add-only (`DeltaCounter`/
   `TelemetrySync`) — retry nunca dupla-conta?

## Verificação automatizada na RQE
- Gate: categoria `persistence == 100` e fonte E2E para requisitos de
  persistência.
- Patterns MCP: `delta-merge-counters`, `save-load`.
