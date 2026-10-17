# Engine facts

Roblox behaviours that were measured on this project, each one after it broke
something. They are here because every one of them costs hours to rediscover,
and because several are invisible: the code is accepted, nothing errors, and
the result is silently wrong.

Do not treat any of these as folklore. Each was observed directly through the
bridge against a live Studio.

## Studio and the plugin

| Fact | Consequence |
|---|---|
| Studio loads plugins **only at startup** (`Hot reload attempted but not actually enabled` in its log) | Every plugin change costs a Studio restart. `rqe studio restart` automates it. |
| An unclean exit raises a modal **auto-recovery dialog** on next launch | It blocks unattended startup. Archive `%LOCALAPPDATA%\Roblox\RobloxStudio\AutoSaves\*_AutoRecovery_*` before launching — move, never delete. |
| Plugins may use `HttpService` regardless of the place's `HttpEnabled` | The bridge needs no game-settings change. |
| `HttpService` is **server-only** | A LocalScript cannot reach the hub. The client half is driven through `RemoteFunction:InvokeClient` from the plugin. |
| `loadstring` is unavailable in a **play session's** server DataModel | `bridge.exec` works in edit mode only. Anything needed during play must be a typed command. |
| A yielding command run inline **freezes the whole plugin** | One `ContentProvider:PreloadAsync` left the bridge unreachable until Studio restarted. Commands run on their own threads. |

## Running the game

| Fact | Consequence |
|---|---|
| `RunService:Run()` **is** scriptable from a plugin | An agent can bring a world to life and measure it with no keyboard input. |
| Run mode does **not** revert what game scripts built | Measured 372 → 742 Workspace descendants across two cycles. Every count after the first run is contaminated. Reopen the place between measurements. |
| Studio 0.738 supports a real player via `StudioTestService:ExecutePlayModeAsync` | Measured in Aetherworks: `games/aetherworks/artifacts/habitat-runtime.json` records a completed native player test. The older `studio play_solo` foreground-key route remains available; its limitations do not apply to the native test API. Multiplayer must be validated separately: the latest attempted test timed out before a verified runtime. |
| `Players:CreateLocalPlayer` → `lacking capability LocalUser` | A Player cannot be conjured. |
| `Instance.new("Player")` → `lacking capability WritePlayer` | Same. |
| A Studio killed mid-playtest leaves a session that still looks alive | Its poll handler stays blocked until it tries to write. The caller that killed it must retire the session explicitly. |

## Input and prompts

| Fact | Consequence |
|---|---|
| `ProximityPrompt:InputHoldBegin()` from the **server** is accepted and `Triggered` never fires | Prompt activation must come from the client. |
| `ProximityPromptExclusivity` defaults to `OnePerButton` | The nearest prompt sharing a key **silently suppresses** the others. A prompt can be visible, in range, enabled and impossible to trigger. Use `AlwaysShow` and a distinct `KeyboardKeyCode` for prompts that must coexist. |
| A prompt on a fast **unanchored** part never fires | A card riding a belt cannot be taken. Present it anchored. |
| The old `VirtualInputManager:SendMouseButtonEvent` route was refused, but Studio 0.738 provides `UserInputService:CreateVirtualInput()` | `client.input` delivered real UI purchases in the Aetherworks native test. A delivered pointer event alone is not proof of button activation: verify the intended state change. Direct RemoteEvents remain gray-box diagnostics, not evidence of successful human interaction. |

## Addressing and state

| Fact | Consequence |
|---|---|
| `GetFullName()` is **not unique** | Four sibling parts named `PlotBorder` share one path. Use `GetDebugId` refs for anything you must distinguish. |
| A weak-valued ref registry is collected | Instances live in the DataModel, not in Lua, so nothing holds the wrapper and the GC drops the mapping between two commands. Hold strong references, bounded, and check liveness on read. |
| Refs are **per DataModel** | Pin a measurement sequence to one session or it will compare two different worlds. |
| Client script errors are invisible to the server's `LogService` | A LocalScript that dies leaves no trace server-side. Read the client's own log. |

## UI

| Fact | Consequence |
|---|---|
| `UIListLayout` / `UIGridLayout` sort by **name** unless told otherwise | Set `LayoutOrder` on children and `SortOrder = LayoutOrder` on the layout, or the design order becomes alphabetical order. |
| A GuiObject reports `Visible = true` inside a hidden parent | Effective visibility must be computed by walking ancestors. |
| `BillboardGui.MaxDistance` defaults far | 8 plots × 40 slot labels at 400 studs buried the map in overlapping text. Set distance per role: a label appears when a player is close enough to act on what it names. |
| Luau declaration order is fatal and silent on the client | Using a `local function` before its definition kills the whole script. The HUD lost every button this way twice, with **zero** errors visible server-side. |

## Rendering

| Fact | Consequence |
|---|---|
| A moderated or deleted image assigns to `ImageLabel.Image` without complaint | It simply shows nothing. `IsLoaded`, read after a wait, is the only honest answer. |
| Screen-region capture reads **desktop pixels** | An overlapping window lands in the evidence: a capture aimed at Studio once returned a different game entirely. Verify the target is foreground and mark the shot untrustworthy when it is not. |
| Neon and PointLights are additive across a map | 49 point lights washed the scene yellow. Bright flat-colour worlds need almost none. |
| High brightness plus high ambient blows out saturated colour | Measured: `Brightness 2.6` with ambient ~160 turned the map white. Flat plastic needs far less fill than a dark PBR scene. |
