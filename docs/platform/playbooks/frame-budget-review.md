# Orçamento de frame (destilado de frame-budget-review + microprofiler)

## Contrato
- Orçamento do contrato (`performance_budget`): 16.67 ms/frame @ 60 FPS.
- Nenhuma afirmação de performance sem medição `studio-bridge`.

## Checks
1. Frame time amostrado (Heartbeat) dentro do orçamento por 60s de jogo?
2. Crescimento de memória < limite em sessão de 10 min (sem leak)?
3. Contagem de instâncias no Workspace sob o teto do contrato?
4. Efeitos visuais respeitam tier (`QualityTierSelector`): tela pequena =
   reduced; média móvel de frame > 115% do budget = reduzir automaticamente?
5. MicroProfiler zones nomeadas por sistema (profiling por fase)?

## Automação na RQE
- Probe `runtime.performance-budget` via studio-bridge.
- `Forge.UI.QualityTierSelector` como mecanismo adaptativo documentado.
