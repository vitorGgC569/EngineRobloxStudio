# Checklist pré-release

O gate automatizado (`rqe release`) já exige: 11 categorias com cobertura
1.0, fontes permitidas, níveis mínimos de validação (E2E para
scenario/persistence/multiplayer), score visual ≥ 95, capturas confiáveis e
evidência hash-bound da mesma run/build.

Este documento lista o que o gate **não** cobre e precisa de humano:

1. Moderação de conteúdo gerado (imagens/áudio) — Roblox modera no upload;
   receipts de asset não provam aprovação.
2. Gamepasses/dev products configurados no dashboard do criador (IDs batem
   com `EntitlementTags`/`Commerce`).
3. Descrição/ícone/thumbnail finais publicados.
4. Teste manual em 3 dispositivos (phone/tablet/desktop) do fluxo crítico.
5. Rollback plan revisado (último run verde identificado).
6. Playbooks `anti-exploit-review` e `datastore-review` assinados.
