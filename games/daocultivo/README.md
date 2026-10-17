# daocultivo

Built on Forge. The engine is a library you write against, not a generator that
writes for you — there is no gameplay in this folder yet, by design.

## Rodar

```bash
rojo build default.project.json --output daocultivo.rbxlx
```

Abra o `.rbxlx` no Studio, ou use `rojo serve` com o plugin do Rojo para sync ao vivo.

## Onde escrever

- `src/server/systems/` — um módulo por sistema, cada um com `start()`
- `src/client/ui/` — interface
- `src/shared/Config.lua` — todo número ajustável

## Checar antes de rodar

```bash
python forge/forge.py doctor daocultivo
```
