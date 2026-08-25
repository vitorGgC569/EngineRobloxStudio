# Catálogo de Reuso — UI, Animação e Design Systems

Segunda frente da biblioteca de reuse: a camada visual. Dez repositórios
clonados em `Desktop\projetos\` cobrem os três pilares de um futuro
**VisualKit** — motion, componentes e design system — e alimentam tanto os
jogos quanto a própria engine (specs declarativas compiláveis e probes de UI).

---

## 1. Inventário por repositório

### otter (Roblox) — ★★★★★ motion puro
68 arquivos. Núcleo: `modules/otter/src/`.
| Extrair | Arquivos | Notas |
|---|---|---|
| Solver analítico de spring (dampingRatio+frequency OU stiffness/mass/damping estilo Figma) | `src/spring.lua` | Solução fechada de Fraktality; limites de repouso configuráveis (`restingVelocityLimit/PositionLimit`) |
| Motors single/grupo | `createSingleMotor.lua`, `createGroupMotor.lua` | Loop de animação com `onStep` signal |
| Easing + instant + step signal | `ease.lua`, `instant.lua`, `AnimationStepSignal.lua` | |

**Uso:** núcleo matemático do VisualKit.Motion — puro, headless-testável,
compatível com `Forge/Core/Sched`. Melhor base de spring disponível no
ecossistema (mesma família usada pelo roact-hooks ecosystem).

### react-luau (Roblox) — ★★★★☆ referência arquitetural
345 arquivos (~4 MB). Tradução completa do React 17: reconciler, hooks,
scheduler, renderer Roblox, roact-compat.
| Extrair | Notas |
|---|---|
| SEMÂNTICA de reconciliação declarativa (element → diff → mutate instances) | `modules/react-reconciler`, `react-roblox` |
| Contrato de hooks (useState/useEffect/useMemo/useRef) | referência para API do VisualKit |
| **Não adotar como dependência** — peso e complexidade desnecessários | |

**Uso para a engine:** especificação de comportamento para um compilador
`UiSpec → Instâncias` mais simples (estilo Pract), usando react-luau como
oráculo de semântica. Os probes da RQE podem verificar o resultado montado.

### RBX-UI (abovefolks) — ★★★★★ componentes + tema + motion
14 arquivos, Vide-based.
| Extrair | Arquivos |
|---|---|
| Tema semântico: Background/Surface/SurfaceRaised/Muted/Border/Text(+Muted)/Accent(+Hover/Pressed)/Danger(+Hover/Pressed) | `Components/UI/Theme.luau` |
| Fontes tipadas por peso (Regular..Bold como `Font.new`) + Radii (Panel 12 / Control 8) | idem |
| Motion vocabulary: Duration {Fast .16 / Normal .2 / Slow .24}, Damping {Smooth 1 / Snappy .85 / Soft .9}, `hoverPressScale`, `booleanScale` | `Components/UI/Motion.luau` |
| Componentes: Button, IconButton, Card, Panel, Modal, ProgressBar, Slider, Toggle | `Components/UI/*.luau` |

**Uso:** inventário mínimo de componentes + vocabulário de estados
(hover/pressed/disabled) — exatamente o contrato que `Forge/UI/InteractionRules`
e `PanelStateMachine` precisam consumir.

### synthetic (nightcycle) — ★★★★★ design system completo (M3)
320 arquivos, --!strict. Port do Material Design 3.
| Extrair | Arquivos |
|---|---|
| **Ciência de cor M3 em Luau**: CorePalette/TonalPalette (HCT), Scheme completo (primary/onPrimary/*Container, surface, outline, scrim, inverse*...), Blend, ViewingConditions — port do material-color-utilities | `src/Theme/{Scheme,Palette,Blend,ColorUtil,MathUtil,ViewingConditions}.luau` |
| Style class: `GetColor(role, elevation)`, `GetElevatedColor`, `GetFont(type)`, `GetTextSize`, `GetLineHeight`; Scale factor; SchemeType light/dark | `src/Style/init.luau` + Typography |
| Matriz de componentes M3: Filled/Outlined/Text/IconButton ×variants, FAB/ExtendedFAB, Chips Assist/Filter, Checkbox, Dialog, Menu+Row, ProgressIndicator, RadioButton, Search, Snackbar, Switch, TextField | `src/Component/**` |
| Transitions | `src/Transition/` |

**Uso:** a joia da coroa. Geração de paleta acessível a partir de uma cor de
marca conecta direto com `rqe/art/direction.py` e os design tokens L0 — um
token set vira um Scheme M3 inteiro derivado, não digitado à mão. O modelo de
elevação resolve superfícies empilhadas. Snackbar≈Toast fecha o gap do catálogo.

### Pretty (mastedore) — ★★★★☆ gerenciamento por atributos
6 arquivos, --!strict, MIT.
| Extrair | Arquivos |
|---|---|
| Singleton de UI com **stack de handles ativos** (ordem modal real) | `Pretty/init.luau` (`Stack`, `IsInStack`) |
| PButton dirigido por atributos (hover/press sem wiring manual) | `Pretty/Button.luau` |
| PSelectionGroup, Tooly (helpers), limpeza via Janitor | demais |

**Uso:** padrão de stacking/foco para o gerenciador de modais do VisualKit
(complementa `PanelStateMachine`, que ainda não conhece ordem entre painéis).

### RBUI (SS1Dev) — ★★★☆☆ temas prontos + ícones
14 arquivos.
| Extrair | Arquivos |
|---|---|
| Presets de tema completos multi-tema (PlatinumGray default + outros) | `Theme.lua` |
| Registry de ícones centralizado | `Icons.lua` |
| Dropdown e Tab (ausentes nos demais pequenos) | `Components/{Dropdown,Tab}.lua` |

**Uso:** formato de preset de tema (troca de identidade inteira em runtime) e
registry de ícones — par ideal para tokens FLAVOR do brickblast.

### roblox-ui-component-library (cruzeht915) — ★★★☆☆ contrato mínimo
5 arquivos.
| Extrair | Arquivos |
|---|---|
| Contrato BaseComponent: props/render/destroy | `Core/BaseComponent.lua` |
| Toast e Modal como referências mínimas | `UIComponents/*.lua` |
| Bootstrap UIRoot client | `StarterGui/UIRoot/UIRoot.client.lua` |

**Uso:** o contrato props/render/destroy é o esqueleto canônico de componente
do VisualKit (3 métodos, zero dependência).

### pract (AmberGraceRblx) — ★★★★☆ declarativo intermediário
45 arquivos, --!strict, MIT.
| Extrair | Arquivos |
|---|---|
| Elementos declarativos congelados (createElement/Fragment/Portal/Index) | `Pract/{index,combine,portal,create}.lua` |
| Hooks próprios: useState/useEffect/useMemo/useSignalUpdates/useConsumer | `Pract/use*.lua` |
| Decorators de estado: withState/withSignal/withLifecycle/withDeferredState | `Pract/with*.lua` |
| Reconciler plugável + createHook | `createReconciler.lua` |

**Uso:** o meio-termo perfeito — declarativo sem o peso do react-luau. O
padrão `withState` (comportamento como decorator sobre componente) é o modelo
para estados de UI do VisualKit sem adotar framework inteiro.

### roblox-ui-library (axzaxzz) — ★★★☆☆ timing vocabulary
20 arquivos.
| Extrair | Arquivos |
|---|---|
| Presets de TweenInfo por gesto: Hover .2 Quart/Out, Click .1, Slide .3, Pop .4 Back/Out | `Components.lua` (`AnimationInfo`) |
| Paleta funcional com Success/Warning/Error além de Accent | idem |
| KeybindManager, gradientes, evolução SnowV3→V5 (lições de iteração) | `KeybindManager.lua`, `Snow*.lua` |

**Uso:** o dicionário de durações/easings por intenção de gesto alimenta o
Motion do VisualKit (mesma ideia dos Duration/Damping do RBX-UI, mais rico).

### Modular-Roblox-GUI-framework (D-M-dev) — ★★★★☆ manager + binding
18 arquivos.
| Extrair | Arquivos |
|---|---|
| **DataBinding reativo**: `data:Set(key,v)` dispara sinais por chave, bindings de texto com template `"{score}"` e bindings de propriedade | `src/Core/DataBinding.luau` |
| UIManager (lifecycle de telas) + Layouts Grid/Horizontal/Vertical | `src/UIManager.luau`, `src/Layouts/*` |
| Hierarquia BaseComponent (Button/Image/Input/Panel/ScrollFrame/Text) + Theme + Tween wrapper + uSignal próprio | `src/Core/*`, `src/Components/*` |

**Uso:** DataBinding com templates nomeados é o mecanismo que faltava entre
"os atributos publicados pelo servidor" (padrão RQE) e o texto do HUD — HUD
binda `{Cash}` e nunca recalcula economia. Layouts abstraem UIListLayout/UIGridLayout.

---

## 2. Síntese — o VisualKit derivado do material

```
VisualKit
├── Tokens      ← WorldKit/Tokens (L0) + synthetic Scheme M3 (roles, elevação,
│                 tipografia) + RBX-UI estados + RBUI presets
├── Motion      ← otter springs/motors + presets de gesto (RBX-UI Motion +
│                 axzaxzz AnimationInfo) — tudo headless-testável
├── Components  ← contrato BaseComponent (cruzeht915) + inventário RBX-UI +
│                 matriz M3 do synthetic (Button×8, Chip, Snackbar, Dialog...)
│                 + Dropdown/Tab (RBUI)
├── State       ← withState/withSignal (pract) + DataBinding com templates
│                 (Modular) + PanelStateMachine/InteractionRules (já na Forge)
├── Stack       ← Pretty.Stack (ordem modal) + foco
└── Spec        ← UiSpec declarativo compilado a instâncias (semântica
                  react-luau/pract como oráculo; probes da RQE verificam)
```

## 3. Gaps fechados no catálogo de reuse anterior
- `NotificationKit`/Toast → **Snackbar (synthetic) + Toast (cruzeht915)**
- `ThemeTokenSystem` lado Luau → **Scheme M3 + Style (synthetic)** deriva paleta
  de marca com acessibilidade (HCT/contraste) em vez de hex à mão
- Stacking de modais → **Pretty.Stack**
- Data binding HUD↔servidor → **DataBinding templates (Modular)**
- Motion unificado → **otter + presets de gesto**

## 4. Ordem sugerida de implementação (VisualKit Onda 1)
1. `VisualKit/Motion` — portar spring/motor do otter (puro) + tabela de presets
2. `VisualKit/Tokens` — Scheme M3 (synthetic Theme) ligado aos tokens L0
3. `VisualKit/Component` — BaseComponent + Button/Modal/Snackbar/Slider/Tab
4. `VisualKit/Stack` — gerenciador de pilha de telas (Pretty)
5. `VisualKit/Binding` — DataBinding com templates para HUD server-driven
6. `VisualKit/spec.luau` + probe `ui_spec_conformance` na RQE (spec → monta → mede)

Licenças: otter/react-luau (Roblox OSS, Apache/MIT family), synthetic
(LICENSE no repo), Pretty MIT, pract MIT. Demais: verificar antes de vendor.
