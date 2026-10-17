# Crystal Garden — auditoria Vigia

## Estado da evidência

NOT_VALIDATED: suite ainda não executada; `src/shared/Economy.lua`, `src/server/Garden.lua` e `src/server/init.server.lua` não estavam presentes na primeira leitura. Nenhum resultado de Studio, runtime ou E2E foi medido por Vigia. O coordenador mantém a posse do Studio e fará a integração e execução de `test.run`.

STATICALLY_VALIDATED: `TEAM.md` define preços, crescimento, sorteios, propriedade e recompensas como responsabilidade do servidor. `Config.lua` contém seis espécies, quatro mutações, mochila inicial de oito itens e quatro níveis para mochila/solo. Estes são dados de configuração, não medições do jogo.

## Suite entregue

`src/server/tests/Economy.lua` retorna `function()` sem parâmetros. Cenários determinísticos com tabelas novas, asserts e comparação profunda de rejeições. Cobertura: perfil inicial e isolamento, fundos insuficientes/exatos, espécies bloqueadas/desbloqueio repetido, IDs desconhecidos, timestamps não finitos, fronteira de crescimento, colheita repetida inclusive após venda, capacidade e retry, upgrades até máximo, limite de redução do solo e venda sem duplicar moedas. A resolução de dependências usa `ReplicatedStorage.Shared` em Studio e caminhos relativos no CLI Luau; os cenários não usam serviços, Instances, remotes, relógio real ou estado do jogo.

O significado exato de `sold` não é definido por TEAM.md; a suite exige avanço na venda válida e estabilidade em venda vazia, sem inventar unidade para esse contador.

## Achados

NOT_VALIDATED: nenhum defeito de implementação pode ser afirmado antes da chegada dos arquivos. Pontos de auditoria pendentes: validação e limitação dos remotes; origem do preço, mutação e horário; propriedade/proximidade em canteiros e mercado; atomicidade da colheita/venda; concorrência no carregamento/salvamento e sanitização de perfis persistidos. Atualizar esta seção com arquivo, linha, condição concreta e impacto assim que o servidor chegar.

## Execução pelo coordenador

Após mapear a pasta `src/server/tests` no projeto, chamar `test.run` com `source` que resolve o ModuleScript Economy da pasta de testes e executa sua função. Exemplo, ajustando o caminho ao projeto real:

```lua
local suite = require(game:GetService("ServerScriptService").Server.tests.Economy)
local ok, result = pcall(suite)
if ok then
    for _, case in ipairs(result.results) do
        check(case.name, case.passed, case.detail)
    end
else
    check("Economy suite", false, tostring(result))
end
```

Guardar resposta completa, contexto e identidade/hash das fontes executadas. Um `test.run` no contexto edit valida as regras puras no motor, mas não prova remotes, persistência, mundo ou fluxo E2E em execução. Nenhum comando de controle de Studio foi emitido por Vigia.
