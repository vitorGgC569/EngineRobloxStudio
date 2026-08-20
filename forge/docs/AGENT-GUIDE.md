# Construindo um jogo com Forge

Guia de trabalho para um agente. Não é referência de API — `python forge/forge.py engine`
lista a API. É a ordem em que as decisões devem ser tomadas e os padrões que
evitam as armadilhas conhecidas.

## Ordem

1. **Escreva o conteúdo antes dos sistemas.** `src/shared/Content.lua`, com
   `Data.define` antes de `Data.load`. Se você não consegue declarar o shape de
   uma arma, você ainda não decidiu o que uma arma é — e vai descobrir isso no
   meio do sistema de combate, que é o pior lugar.

2. **Declare o contrato de rede inteiro de uma vez.** Um `Net.define` no
   servidor e o mesmo no cliente. Não vá acrescentando eventos: a lista completa
   é o desenho do jogo visto de fora.

3. **Mundo, depois atores, depois combate, depois interface.** Cada um depende
   do anterior existir. `Players.CharacterAutoLoads = false` até o chão existir.

4. **`Debug.expose()` no fim do bootstrap.** Sem isso o jogo é opaco para
   qualquer medição que não seja geométrica.

5. **`forge doctor` antes de cada build.** Ele compila o Luau de verdade.

## Padrões

### Um sistema

```lua
local System = {}

function System.start()
    -- assinaturas, populações, loops
end

return System
```

Requerido explicitamente pelo bootstrap, em ordem de dependência. Iterar a pasta
`systems/` funciona até o dia em que um sistema precisa que outro já tenha
rodado — e aí a falha é intermitente, que é a pior categoria.

### Dano

Todo dano passa por `Combat.damage`. Regras entram como modificadores com ordem
explícita:

```lua
Combat.addModifier("armor", 100, function(ctx) ... end)
Combat.addModifier("block", 150, function(ctx) ... end)
Combat.addModifier("crit",  200, function(ctx) ... end)
```

A ordem é um número porque "armadura antes ou depois do crítico" muda o
balanceamento, e isso não pode ser um acidente da iteração de uma tabela.

### Timing de golpe

Nunca aplique dano no frame do input. Aplique no marcador do clipe:

```lua
animator:onMarker(function(clip, marker)
    if marker == "hit" then applyDamage() end
end)
```

No servidor, para inimigos, isso é literal. Para o jogador, o servidor atrasa o
dano pelo mesmo tempo do marcador (veja `Fight.onAttack` em `provingground`) —
o cliente não é fonte de verdade, mas o timing precisa bater com o que ele vê.

### IA

Uma máquina de estados por arquétipo, não por inimigo. Três tipos de husk
compartilham um cérebro e diferem por dados. Se você está escrevendo um cérebro
por criatura, a diferença entre elas provavelmente é um número.

Transições são checadas antes do update, então um estado nunca age num frame em
que sua própria condição de saída já vale.

Sempre defina `leash`. Um inimigo que persegue o jogador pelo mapa inteiro é o
bug de IA mais comum que existe em Roblox.

### Feedback

Um acerto que não é anunciado é um acerto que não aconteceu, do ponto de vista
do jogador. O mínimo por golpe:

```lua
Feel.number(position, tostring(amount), { crit = crit })
Feel.hit(position, { power = 1, direction = dir, crit = crit })
```

`Feel.hit` já agrupa partícula, shake, hitstop e flash porque essas quatro
coisas sempre andam juntas e sempre desandam separadas quando são chamadas em
quatro lugares diferentes.

### Limpeza

Qualquer sistema que conecta mais de dois sinais usa um `Trove`. O vazamento de
`:Connect` não quebra nada imediatamente; ele deixa o servidor mais lento a cada
hora, o que é indistinguível de "Roblox é assim mesmo".

## Armadilhas medidas

Estas custaram tempo real. `docs/platform/ENGINE-FACTS.md` tem a lista completa
da plataforma; estas são as que atingem quem usa Forge.

| Armadilha | Consequência |
|---|---|
| Não chamar `Rig.stripDefaultAnimate` | o script `Animate` da Roblox escreve os mesmos Motor6D e a animação treme |
| Não chamar `Feel.mount()` | shake, hitstop e punch ficam inertes, sem erro nenhum |
| Guardar o retorno de `Debug.tunable` num local | você saiu do sistema de tuning sem perceber |
| `Net.fire(player, name, ...)` com o nome no lugar errado | o nome do evento não é o primeiro argumento em `fire`, `fireNear`, `fireExcept` |
| Ocupação binária de voxel | degraus visíveis em toda encosta; `World.paint` usa rampa linear por isso |
| Um `Heartbeat:Connect` por ator | use `Sched.group` com slices; 200 atores custam uma conexão |
| Confiar em `heightfield:height` para posicionar | o voxel arredonda; use `World.surface` depois do terreno escrito |

## Como saber se está funcionando

Não confie em ter escrito. Meça:

```bash
python rqe.py studio serve
python rqe.py studio restart games/meujogo/meujogo.rbxlx .
python rqe.py studio call run.start
python forge/forge.py probe
```

O snapshot deve mostrar contadores subindo. Um contador que fica em zero durante
um playtest inteiro é um sistema que nunca rodou — a falha silenciosa mais comum
num jogo gerado, e a razão de `Debug.count` existir.

Use `Debug.check(condition, "descrição")` para expectativas. Ela não derruba o
jogo; registra a expectativa violada no snapshot. Num playtest, um `assert` duro
esconde todos os problemas depois do primeiro.
