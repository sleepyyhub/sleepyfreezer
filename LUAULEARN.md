# LUAULEARN.md — Luau / Roblox Skills for Claude

A consolidated reference of every publicly available **Claude Agent Skill** for Luau and
Roblox development that I could find and download, plus the distilled knowledge from
each one.

Downloaded and merged on **2026-07-26**. 13 Luau/Roblox skills across 5 repositories.

---

## Table of Contents

1. [Skill Catalog](#1-skill-catalog)
2. [How to Install](#2-how-to-install)
3. [Luau Language & Type System](#3-luau-language--type-system)
4. [Project Structure & Architecture](#4-project-structure--architecture)
5. [Networking — RemoteEvents & RemoteFunctions](#5-networking--remoteevents--remotefunctions)
6. [Security & Anti-Exploit](#6-security--anti-exploit)
7. [Data Persistence — DataStores](#7-data-persistence--datastores)
8. [Performance Optimization](#8-performance-optimization)
9. [GUI Systems](#9-gui-systems)
10. [Animations](#10-animations)
11. [Monetization](#11-monetization)
12. [Tooling — Rojo, Wally, luau-lsp](#12-tooling--rojo-wally-luau-lsp)
13. [Sharp Edges Catalog](#13-sharp-edges-catalog)
14. [Anti-Patterns Cheat Sheet](#14-anti-patterns-cheat-sheet)
15. [Official Documentation Endpoints](#15-official-documentation-endpoints)
16. [Sources](#16-sources)

---

## 1. Skill Catalog

### `brockmartin/roblox-game-skill` — "roblox-game"

Single monolithic skill, ~1.7 MB. `SKILL.md` is a 123-line router with 18 routing paths
into 16 reference files and 6 genre templates (simulator, tycoon, obby, RPG, horror,
battle royale) plus 6 workflows.

| Property | Value |
|---|---|
| Skill name | `roblox-game` |
| `user-invocable` | `true` |
| Structure | router `SKILL.md` + `references/` (16) + `templates/` (7) + `workflows/` (6) |
| Standout content | `references/sharp-edges.md` (12 severity-rated gotchas), `references/luau-mastery.md` (1666 lines), `references/multiplayer-networking.md` (1808 lines) |
| MCP-aware | Yes — detects full (39 tools) / standard (6 tools) / offline mode |
| License | none declared |

**MCP detection logic it uses:**

1. **Full mode** — community MCP server. Probe for `execute_luau`, `get_file_tree`, `grep_scripts`, `create_build`.
2. **Standard mode** — official MCP server. Probe for `run_code`, `insert_model`, `get_console_output`, `start_stop_play`.
3. **Offline mode** — no MCP. Pure code generation, copy-paste-ready scripts with placement instructions.

**Routing table (verbatim):**

| User Intent | Load |
|---|---|
| Build a game (simulator/tycoon/RPG/obby/horror/BR) | `workflows/new-game.md` + `templates/genre-{type}.md` + `templates/game-scaffold.md` |
| Fix bug / debug | `workflows/debug-loop.md` + `references/mcp-orchestration.md` |
| Save/load data | `references/datastore-persistence.md` |
| Combat system | `references/combat-systems.md` + `references/security-hardening.md` |
| Shop / gamepass / monetization | `references/monetization-systems.md` + `references/gui-systems.md` |
| Optimize performance | `workflows/performance-audit.md` + `references/performance-optimization.md` |
| Security review | `workflows/security-audit.md` + `references/security-hardening.md` |
| Set up Rojo / external tools | `references/tooling-ecosystem.md` |
| Gotchas / sharp edges / common bugs | `references/sharp-edges.md` |
| General Luau question | `references/luau-mastery.md` |
| Game design question | `references/game-design-roblox.md` |
| Ready to publish | `workflows/publish-checklist.md` |
| Review monetization | `workflows/monetization-audit.md` |
| Review code quality | `workflows/code-review.md` |
| Animation / VFX | `references/animation-vfx.md` |
| Multiplayer / networking | `references/multiplayer-networking.md` |
| Testing | `references/testing-patterns.md` |
| Inventory / items | `references/inventory-systems.md` |
| GUI / UI | `references/gui-systems.md` |

---

### `MSayib/roblox-dev-skill` — "roblox-dev"

~488 KB, 5100+ lines of Luau/Roblox knowledge. Targets Claude Code, Antigravity IDE, and
any SKILL.md-compatible assistant. Notably has a **knowledge-freshness mechanism**.

| Property | Value |
|---|---|
| Skill name | `roblox-dev` |
| Structure | router `SKILL.md` (336 lines) + `references/` (11 files) + `metadata.json` |
| Engine target | Roblox Studio v727+ (mid-2026) |
| Negative triggers | Explicitly does *not* fire for Unity, Unreal, Godot, web/mobile, non-Luau |
| Freshness check | Reads `metadata.json`, compares `last_updated` to today; reminds after 7 days; `/roblox-update` runs a research → compare → report → discuss → apply → audit → stamp protocol. Never auto-updates without approval. |
| License | present (`LICENSE`) |

**Its routing table:**

| User Intent | Reference File |
|---|---|
| Luau syntax, types, naming conventions, style | `references/luau-fundamentals.md` |
| Project layout, architecture, patterns | `references/project-structure.md` |
| Save/load player data, DataStore, ProfileStore | `references/datastore-persistence.md` |
| Client-server communication, RemoteEvents, input | `references/networking.md` |
| Security, anti-exploit, server authority, bans | `references/security-hardening.md` |
| Performance, memory, optimization, Parallel Luau | `references/performance-optimization.md` |
| Using Roblox Studio MCP tools effectively | `references/mcp-integration.md` |
| UI, GUI, ScreenGui, menus, HUD, StyleQuery | `references/ui-systems.md` |
| Migrating legacy code, deprecated APIs | `references/legacy-migration.md` |
| Monetization, game passes, donations, transfers | `references/monetization.md` |
| File formats, import/export, asset management | `references/file-formats-and-assets.md` |

**Official Roblox MCP tools it expects** (from the `Roblox_Studio` server): `execute_luau`,
`search_game_tree`, `script_search`/`script_grep`, `script_read`, `multi_edit`,
`inspect_instance`, `insert_asset`/`search_asset`, `start_stop_play`, `get_console_output`,
`get_studio_state`, `screen_capture`/`store_image`, `generate_mesh`,
`generate_procedural_model`, `generate_material`, `upload_image`, `character_navigation`,
`user_mouse_input`/`user_keyboard_input`, `list_roblox_studios`/`set_active_studio`.

---

### `sentinelcore/roblox-skills` — 7 focused skills

~300 KB. Unlike the two monoliths above, this is **seven small, independently-triggering
skills**. Each is a single self-contained `SKILL.md` (~190–240 lines) ending in a
"Common Mistakes" table. Best signal-to-noise of the set.

| Skill | Triggers on |
|---|---|
| `roblox-datastores` | Player data persistence, saving/loading stats or inventory, ordered datastores for leaderboards, data migration, data-loss diagnosis, auto-save and shutdown-safe handling |
| `roblox-remote-events` | Client-server communication, firing events between LocalScripts and Scripts, passing data across the network boundary, syncing state, defending against remote abuse |
| `roblox-security` | Scripts handling player actions, currencies, stats, damage, or any Remote traffic; reviewing for exploitable patterns; anti-cheat; validation; rate limiting |
| `roblox-performance` | FPS drops, lag, large worlds, streaming, draw calls, object pooling, LOD, MicroProfiler, expensive loops |
| `roblox-gui` | HUDs, menus, world-space UI, player labels, ScreenGui/SurfaceGui/BillboardGui, UDim2 sizing, TweenService UI animation, responsive scaling, `ResetOnSpawn` |
| `roblox-animations` | Playing/stopping/blending animations on Humanoid or non-Humanoid rigs, AnimationTrack events, replacing default character animations, priority/blending bugs |
| `roblox-monetization` | Game Passes, Developer Products, UGC avatar items, Premium Payouts — both Studio scripting and Creator Hub dashboard setup |

---

### `dig1t/skills` — 3 Luau skills (+ `anti-ai`)

Trigger-keyword-rich descriptions, `--!strict`-first, references broken out per topic.
Ships both at repo root and under `.agents/skills/` (identical copies).

| Skill | Focus |
|---|---|
| `luau-best-practices` | 407-line SKILL.md. Naming, file organization, service/controller patterns, error handling with Result types, memory/maids, security, anti-patterns, project structure. References: `code-style.md`, `patterns.md`, `error-handling.md`, `memory.md`, `security.md` |
| `luau-type-expert` | 336-line SKILL.md. Type modes, annotations, aliases, unions/intersections, narrowing/refinements, casts, generics, table types, typed metatable OOP, common type errors, `luau-lsp` CLI, `.luaurc`, 28 lint rules |
| `rojo-pro` | 240-line SKILL.md. Rojo 7.6.1 stable / 7.7.0-rc.1 (websocket sync + syncback), `project.json` config, file conventions, multi-environment setups, Wally/Aftman integration. References: `patterns.md` (577 lines), `sharp_edges.md` (520 lines) |

---

### `greedychipmunk/agent-skills` — `roblox-game-developer`

One Roblox skill inside a larger multi-domain marketplace repo (argocd, pulumi, datadog,
terraform, docker, k8s, supabase, nextjs, …).

| Property | Value |
|---|---|
| Skill name | `roblox-game-developer` |
| SKILL.md | 283 lines |
| Resources | `performance_optimization.md` (833), `quick_reference.md` (640), `debugging_guide.md` (638), `asset_library.md` (485) |
| Templates | `technical_specification.md` (779), `testing_plan.md` (671), `marketing_plan.md` (819) |
| Genre templates | Simulator, Tycoon, Obby, RPG, Horror, Battle Royale |
| License | present (`LICENSE`) |

---

### Not obtained

- `CyanoTex/Roblox-Claude-Code-Skills` — clone failed (repo not reachable/renamed at time of download).
- `anthropics/skills` issue [#915](https://github.com/anthropics/skills/issues/915) is an
  open *feature request* for an official Roblox Studio / Luau skill — no first-party skill exists yet.

---

## 2. How to Install

Agent Skills are directories containing a `SKILL.md` with YAML frontmatter (`name`,
`description`, optionally `user-invocable`). Claude Code discovers them under
`~/.claude/skills/` (personal) or `.claude/skills/` (project).

```bash
# Personal — available in every project
mkdir -p ~/.claude/skills && cd ~/.claude/skills

# Monolithic all-in-one
git clone --depth 1 https://github.com/brockmartin/roblox-game-skill.git roblox-game
git clone --depth 1 https://github.com/MSayib/roblox-dev-skill.git roblox-dev

# Seven focused skills — copy each subdirectory
git clone --depth 1 https://github.com/sentinelcore/roblox-skills.git /tmp/rbx
cp -r /tmp/rbx/roblox-* ~/.claude/skills/

# Luau language + Rojo
git clone --depth 1 https://github.com/dig1t/skills.git /tmp/dig1t
cp -r /tmp/dig1t/luau-best-practices /tmp/dig1t/luau-type-expert /tmp/dig1t/rojo-pro ~/.claude/skills/

# Marketplace skill
git clone --depth 1 https://github.com/greedychipmunk/agent-skills.git /tmp/gc
cp -r /tmp/gc/roblox-game-developer ~/.claude/skills/
```

**Recommendation:** don't install everything. The monoliths (`roblox-game`, `roblox-dev`)
overlap heavily with each other and with the sentinelcore set, and competing descriptions
make trigger selection worse. Pick one of:

- **Focused stack (preferred):** `sentinelcore/*` (7) + `dig1t/luau-best-practices` +
  `dig1t/luau-type-expert` + `dig1t/rojo-pro`. Small files, sharp triggers, no router indirection.
- **Monolith:** `brockmartin/roblox-game-skill` alone, if you want genre scaffolding and
  MCP-driven autonomous building.

The `SKILL.md` format is portable — these also work in Cursor, Codex, Copilot, Gemini CLI,
and Antigravity IDE.

---

## 3. Luau Language & Type System

### Type modes

Always put `--!strict` at the top of a new file.

| Mode | Behavior |
|------|----------|
| `--!nocheck` | Disables type checking entirely |
| `--!nonstrict` | Unknown types become `any` (default) |
| `--!strict` | Full type tracking, catches mismatches |

### Annotations

```lua
--!strict

local count: number = 0
local name: string = "Player"

local function add(a: number, b: number): number
    return a + b
end

-- Optional parameter
local function greet(name: string, title: string?): string
    return (title or "") .. name
end

-- Multiple returns
local function divmod(a: number, b: number): (number, number)
    return math.floor(a / b), a % b
end

-- Variadic
local function sum(...: number): number
    local total = 0
    for _, v in {...} do total += v end
    return total
end
```

### Type aliases, generics, unions, intersections

```lua
type UserId = number

type PlayerData = {
    coins: number,
    level: number,
    inventory: { string },
}

export type ItemRecord = {
    id: string,
    quantity: number,
    createdAt: number,
}

type Callback = (player: Player, data: any) -> boolean

type Result<T, E> = { ok: true, value: T } | { ok: false, error: E }
type Array<T> = { T }
type Map<K, V> = { [K]: V }

-- Literal (discriminated) unions
type Status = "pending" | "active" | "completed"

-- Intersection
type Named = { name: string }
type Aged = { age: number }
type Person = Named & Aged

-- Function intersection = overloads
type Stringify = ((n: number) -> string) & ((b: boolean) -> string)
```

### Narrowing / refinements

Luau narrows automatically inside conditionals.

```lua
local function process(value: string | number)
    if type(value) == "string" then
        print(value:upper())    -- value: string
    else
        print(value + 1)        -- value: number
    end
end

-- typeof() narrows Roblox instances
local function handlePart(obj: Instance)
    if typeof(obj) == "BasePart" then
        obj.Anchored = true
    end
end

-- Early return preserves the refinement
local function requirePlayer(player: Player?): Player
    if not player then
        error("Player required")
    end
    return player   -- player: Player
end
```

### Casts

`::` overrides the inferred type. One operand must be a subtype of the other, or `any`.

```lua
local data = {} :: { string }
local part = workspace:FindFirstChild("Part") :: Part?
```

### Generics

```lua
local function first<T>(arr: { T }): T?
    return arr[1]
end

type Container<T> = {
    value: T,
    set: (self: Container<T>, value: T) -> (),
    get: (self: Container<T>) -> T,
}
```

### Typed metatable OOP

```lua
--!strict

export type Vector2 = { x: number, y: number }

type Vector2Impl = {
    __index: Vector2Impl,
    new: (x: number, y: number) -> Vector2,
    add: (self: Vector2, other: Vector2) -> Vector2,
    magnitude: (self: Vector2) -> number,
}

local Vector2: Vector2Impl = {} :: Vector2Impl
Vector2.__index = Vector2

function Vector2.new(x: number, y: number): Vector2
    return setmetatable({ x = x, y = y }, Vector2) :: Vector2
end

function Vector2:add(other: Vector2): Vector2
    return Vector2.new(self.x + other.x, self.y + other.y)
end

function Vector2:magnitude(): number
    return math.sqrt(self.x^2 + self.y^2)
end

return Vector2
```

### Common type errors

| Error | Fix |
|-------|-----|
| `Type 'X' could not be converted into 'Y'` | Add explicit cast `:: Y`, or fix the type |
| `Unknown global 'X'` | Import the module or declare a global type |
| `Property 'X' is not compatible` | Match property types exactly |
| `W_001: Unknown require` | Use proper require path aliases |

### Naming conventions (official Roblox style)

```lua
-- PascalCase: types, classes, services, modules
type PlayerData = { ... }
local ShopService = {}

-- camelCase: variables, functions, methods
local playerCount = 0
function ShopService:purchaseItem() end

-- SCREAMING_SNAKE_CASE: constants
local MAX_PLAYERS = 50

-- Underscore prefix: private
local function _validateInput() end
```

Spell words out fully; avoid abbreviations. Don't fully capitalize acronyms —
`JsonTable`, not `JSONTable`.

### Performance-aware typing

- `table.field` beats `table["field"]`
- Keep metatables shallow — direct `__index` to a table
- Localize builtins: `local max = math.max`
- Avoid `getfenv`/`setfenv` (deoptimizes the whole function)
- `table.create(n)` when the size is known

---

## 4. Project Structure & Architecture

### Service hierarchy — what goes where

| Container | Contents |
|---|---|
| `ServerScriptService` | Server-only logic — game state, data, anti-cheat |
| `ReplicatedStorage` | Shared ModuleScripts, RemoteEvents, assets both sides need |
| `StarterPlayerScripts` | Client controllers — input, camera, UI logic |
| `StarterGui` | ScreenGuis (cloned into PlayerGui on spawn) |
| `ServerStorage` | Server-only assets — maps, tools to clone on demand |
| `Workspace` | The live 3D world. Keep it lean. |

### Script types

| Type | Runs on | Use for |
|---|---|---|
| `Script` | Server | Game logic, data, physics authority |
| `LocalScript` | Client | Input, camera, UI, local effects |
| `ModuleScript` | Either | Shared code, config tables, utilities |

### Filesystem layout

```
src/
├── Server/
│   ├── init.server.luau      # Bootstrap
│   ├── Services/             # Game services
│   │   ├── DataService.luau
│   │   └── CombatService.luau
│   └── Components/
├── Client/
│   ├── init.client.luau      # Bootstrap
│   ├── Controllers/
│   └── UI/
├── Shared/
│   ├── Types.luau
│   ├── Constants.luau
│   └── Util/
└── Packages/                 # Wally packages
```

### File organization within a module

```lua
--!strict

-- 1. Services/imports
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Signal = require(ReplicatedStorage.Packages.Signal)

-- 2. Constants
local MAX_RETRIES = 3

-- 3. Types
type Config = { enabled: boolean, maxItems: number }

-- 4. Module table
local MyModule = {}

-- 5. Private state
local _initialized = false
local _cache: { [string]: any } = {}

-- 6. Private functions
local function _helperFunction() end

-- 7. Public API
function MyModule.init() end

-- 8. Return
return MyModule
```

### Service pattern (server)

```lua
--!strict
local MyService = {}
local _started = false

function MyService:Start()
    assert(not _started, "MyService already started")
    _started = true
    -- Initialize connections, load data
end

function MyService:Stop()
    -- Cleanup for hot-reloading
end

return MyService
```

### Controller pattern (client)

```lua
--!strict
local MyController = {}
local _player = game:GetService("Players").LocalPlayer

function MyController:Init()
    -- Setup without yielding
end

function MyController:Start()
    -- Connect events, start loops
end

return MyController
```

### Full script template

```lua
--!strict
-- [ScriptName]
-- [Brief description]
-- Container: [ServerScriptService/StarterPlayerScripts/ReplicatedStorage]

----- Services -----
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

----- Constants -----
local MAX_VALUE = 100

----- Types -----
type PlayerData = {
    coins: number,
    level: number,
    inventory: { string },
}

----- Variables -----
local activeConnections: { [Player]: { RBXScriptConnection } } = {}

----- Private Functions -----
local function cleanup(player: Player)
    local connections = activeConnections[player]
    if connections then
        for _, conn in connections do
            conn:Disconnect()
        end
        activeConnections[player] = nil
    end
end

----- Event Handlers -----
local function onPlayerAdded(player: Player)
    activeConnections[player] = {}
end

----- Initialization -----
Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(cleanup)

-- Handle players already in game (Studio hot-reload)
for _, player in Players:GetPlayers() do
    task.spawn(onPlayerAdded, player)
end
```

### Error handling

```lua
-- pcall every fallible external call
local success, result = pcall(function()
    return dataStore:GetAsync(key)
end)

if not success then
    warn("DataStore failed:", result)
    return nil
end
```

```lua
-- Result pattern
type Result<T> = { ok: true, value: T } | { ok: false, error: string }

local function fetchData(id: string): Result<Data>
    local success, data = pcall(function()
        return dataStore:GetAsync(id)
    end)
    if not success then
        return { ok = false, error = tostring(data) }
    end
    return { ok = true, value = data }
end
```

```lua
-- assert for programming errors — things that should never happen
function processPlayer(player: Player)
    assert(player, "player is required")
    assert(player:IsA("Player"), "expected Player instance")
end
```

### Memory management

```lua
-- Always disconnect
local connection = event:Connect(handler)
connection:Disconnect()

-- Maids / Janitors / Troves
local maid = Maid.new()
maid:GiveTask(event:Connect(handler))
maid:GiveTask(instance)
maid:GiveTask(function() --[[ custom cleanup ]] end)
maid:Destroy()

-- Weak-valued cache
local cache = setmetatable({}, { __mode = "v" })
```

### Core principles

1. **Server authority** — server owns game state; client is presentation only
2. **Fail fast** — validate early, error loudly in development
3. **Explicit > implicit** — clear intent beats clever code
4. **Minimal surface area** — expose only what's needed

---

## 5. Networking — RemoteEvents & RemoteFunctions

| Type | Direction | Returns? | Use when |
|---|---|---|---|
| `RemoteEvent` | Any | No | Notifying server of a player action, broadcasting state |
| `RemoteFunction` | Client→Server | Yes (yields caller) | Client needs a result back |
| `UnreliableRemoteEvent` | Any | No | High-frequency updates where dropped packets are fine |

**Default to `RemoteEvent`.** Never use a server→client `RemoteFunction` — an exploiter's
frozen callback stalls your server thread indefinitely.

### Placement

Remotes live in `ReplicatedStorage`, created by a server Script that runs before any
LocalScript.

```
ReplicatedStorage/
  Remotes/
    DealDamage        (RemoteEvent)
    GetInventory      (RemoteFunction)
    SyncPosition      (UnreliableRemoteEvent)
```

```lua
-- Script in ServerScriptService
local folder = Instance.new("Folder")
folder.Name = "Remotes"
folder.Parent = game:GetService("ReplicatedStorage")

local function make(class, name)
    local r = Instance.new(class)
    r.Name = name
    r.Parent = folder
    return r
end
```

### Basics

```lua
-- Server: listen
RemoteEvent.OnServerEvent:Connect(function(player, ...) end)
-- Client: fire
RemoteEvent:FireServer(...)
-- Server → one client
RemoteEvent:FireClient(player, ...)
-- Server → all clients
RemoteEvent:FireAllClients(...)
```

### Common mistakes

| Mistake | Fix |
|---|---|
| `OnServerEvent` in a LocalScript | Use `OnClientEvent` on client; `OnServerEvent` is server-only |
| Remotes in `ServerStorage` | Move to `ReplicatedStorage` |
| Trusting the payload beyond player identity | Validate every field |
| Server→client `RemoteFunction` | Use a `RemoteEvent` — a frozen client stalls the server thread |
| No `WaitForChild` in LocalScript | Remotes may not exist yet |
| Multiple `OnServerInvoke` assignments | Only the last wins — keep it in one place |
| Firing inside a tight loop without throttle | Use `UnreliableRemoteEvent` or accumulate delta time |

---

## 6. Security & Anti-Exploit

> **Golden rule: never trust the client.** Every RemoteEvent payload is attacker-controlled.
> Validate type, range, ownership, and cooldown on the server for every request.

FilteringEnabled is always on in modern Roblox — client-side changes do not replicate
unless the server explicitly applies them.

### Secure vs insecure

| Pattern | Insecure | Secure |
|---|---|---|
| Dealing damage | LocalScript sets `Humanoid.Health` | Server reduces health after validation |
| Awarding currency | LocalScript increments leaderstats | Server validates, then increments |
| Leaderstats ownership | LocalScript owns the IntValue | Server creates and owns all leaderstats |
| Position changes | LocalScript teleports character | Server validates and moves character |
| Tool use | Client fires damage on hit | Server raycasts and applies damage |
| Cooldowns | Client tracks cooldown locally | Server tracks cooldown per player |

### Server authority

```lua
-- BAD: client tells the server what happened
RemoteEvent.OnServerEvent:Connect(function(player, damage)
    target.Health -= damage  -- client controls damage!
end)

-- GOOD: server calculates everything
RemoteEvent.OnServerEvent:Connect(function(player, targetId)
    local target = getValidTarget(player, targetId)
    if not target then return end

    local damage = calculateDamage(player)  -- server-side
    target.Health -= damage
end)
```

### Validate all input

```lua
RemoteFunction.OnServerInvoke = function(player, itemId, quantity)
    -- Type
    if typeof(itemId) ~= "string" then return end
    if typeof(quantity) ~= "number" then return end

    -- Range + integrality
    if quantity < 1 or quantity > 99 then return end
    if quantity ~= math.floor(quantity) then return end

    -- Business logic
    if not Items[itemId] then return end
    if not canAfford(player, itemId, quantity) then return end

    return purchaseItem(player, itemId, quantity)
end
```

### Rate limiting

```lua
local lastAction: { [Player]: number } = {}
local COOLDOWN = 0.5

local function isRateLimited(player: Player): boolean
    local now = os.clock()
    local last = lastAction[player] or 0
    if now - last < COOLDOWN then
        return true
    end
    lastAction[player] = now
    return false
end
```

Clean `lastAction[player]` up in `Players.PlayerRemoving` — otherwise it leaks.

### Common mistakes

| Mistake | Why it's exploitable | Fix |
|---|---|---|
| `FireServer(damage)` with the server trusting it | Client sends any value | Server computes damage from its own tool data |
| Currency in a LocalScript variable | Client can modify memory | Server-owned only |
| Client-side distance check before firing | Check is bypassable | Server re-checks after receiving the event |
| No cooldown on RemoteEvent handlers | Spam = infinite resources | Per-player cooldown on the server |
| Trusting `WalkSpeed` set by the client | Client sets it arbitrarily high | Server owns and caps WalkSpeed |
| Sensitive logic in a ReplicatedStorage module | Clients can `require` it | Move to `ServerScriptService` |

---

## 7. Data Persistence — DataStores

| Method | Signature | Notes |
|---|---|---|
| `GetDataStore` | `DSS:GetDataStore(name, scope?)` | Returns a `GlobalDataStore` |
| `GetOrderedDataStore` | `DSS:GetOrderedDataStore(name, scope?)` | For leaderboards |
| `GetAsync` | `store:GetAsync(key)` | Returns value or nil |
| `SetAsync` | `store:SetAsync(key, value)` | No return value needed |
| `UpdateAsync` | `store:UpdateAsync(key, fn)` | Atomic read-modify-write |
| `RemoveAsync` | `store:RemoveAsync(key)` | Deletes key, returns old value |
| `GetSortedAsync` | `orderedStore:GetSortedAsync(asc, pageSize)` | Returns `DataStorePages` |

```lua
-- Server Script (ServerScriptService)
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local playerStore = DataStoreService:GetDataStore("PlayerData_v1")

local DEFAULT_DATA = {
    coins = 0,
    level = 1,
    xp = 0,
}
```

Always wrap in `pcall`. Always version the store name (`_v1`, `_v2`) so a schema change
can't collide with old data shapes.

**For real player data, use ProfileService / ProfileStore.** Raw `SetAsync` has no session
locking, which is the #1 cause of data loss and duplication across servers.

### Common mistakes

| Mistake | Consequence | Fix |
|---|---|---|
| No `pcall` around datastore calls | Unhandled error crashes the script | Always wrap in `pcall` |
| Saving on every `Changed` event | Hits rate limits (60 + numPlayers×10 writes/min) | Throttle; save on remove + periodic interval |
| No `BindToClose` handler | Data lost on server shutdown | Always flush all sessions in `BindToClose` |
| Giving default data on load failure | Player silently loses progress | Return `nil` on failure; kick or retry |
| `SetAsync` for atomic counters | Race condition across servers | Use `UpdateAsync` for read-modify-write |
| Storing Instances or functions | Data silently drops | Store only strings, numbers, booleans, plain tables |
| Reusing the store name after a schema change | Old shape clashes with new code | Append `_v2`, `_v3` on breaking changes |

---

## 8. Performance Optimization

| Technique | Impact | When to use |
|---|---|---|
| StreamingEnabled | High | Large open worlds |
| Object pooling | High | Frequent spawn/destroy |
| Cache references outside loops | High | Heartbeat / RenderStepped |
| `task.wait()` over `wait()` | Medium | All scripts |
| MeshParts over Unions | Medium | Many unique shapes |
| LOD (hide at distance) | Medium | Complex models |
| Anchor static parts | Medium | Reduce physics budget |
| Limit PointLights | High | Any scene with many lights |

### StreamingEnabled

```lua
workspace.StreamingEnabled = true
workspace.StreamingMinRadius = 64
workspace.StreamingTargetRadius = 128
```

- Parts outside the radius are `nil` on the client — always guard with `if part then`.
- Set `Model.LevelOfDetail = Disabled` on models that must always be present.
- Pre-stream before a cutscene or teleport:
  `workspace:RequestStreamAroundAsync(targetPosition, 5)`

### Common mistakes

| Mistake | Fix |
|---|---|
| `workspace:FindFirstChild` every frame | Cache the reference on character/model load |
| Destroying and re-creating bullets/effects | Use an object pool |
| `wait()` in tight loops | `task.wait()` |
| All parts with unique materials | Standardize to a small shared set |
| ParticleEmitters enabled off-screen | Disable `Enabled` when the source isn't visible |
| Physics on decorative parts | `Anchored = true` |

Profile with the **MicroProfiler** (Ctrl+F6 in Studio) before optimizing anything.

---

## 9. GUI Systems

| Container | Parent | Use case |
|---|---|---|
| `ScreenGui` | `PlayerGui` | HUDs, menus, overlays — always faces the screen |
| `SurfaceGui` | `BasePart` | World-space UI on a part surface (signs, screens) |
| `BillboardGui` | `BasePart` or `Model` | Floats above a part in 3D (name tags, health bars) |

```lua
-- LocalScript in StarterGui or StarterPlayerScripts
local player = game:GetService("Players").LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "HUD"
screenGui.ResetOnSpawn = false   -- keep GUI across respawns
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = playerGui
```

```lua
local surfaceGui = Instance.new("SurfaceGui")
surfaceGui.Face = Enum.NormalId.Front
surfaceGui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
surfaceGui.PixelsPerStud = 50
surfaceGui.Parent = workspace.ScreenPart
```

Use `UDim2.fromScale` plus `UIAspectRatioConstraint` for responsive layouts. `TextScaled = true`
for text that must survive mobile.

### Common mistakes

| Mistake | Fix |
|---|---|
| GUI disappears on respawn | `ResetOnSpawn = false`, or use `StarterPlayerScripts` |
| UI looks wrong on mobile | `UDim2.fromScale` + `UIAspectRatioConstraint` |
| Script can't find `PlayerGui` | `player:WaitForChild("PlayerGui")` |
| Tween doesn't run | Property must be tweenable — `Text` is not; `Position`/`Size` are |
| BillboardGui visible through walls | Verify `AlwaysOnTop = false` |
| `AbsoluteSize` is zero on the first frame | Read it inside `task.defer` or after the first render step |
| Clicks pass through overlapping frames | Add a transparent input-blocking Frame, or `Modal = true` |
| SurfaceGui flickers | `LightInfluence = 0`; ensure the part isn't too thin |
| Text tiny on mobile | `TextScaled = true` |
| UI hard to test on mobile | Studio **Device Emulator** (Test tab → Device) |

---

## 10. Animations

| Object | Purpose |
|---|---|
| `Animation` | Asset reference — holds `AnimationId` |
| `Animator` | Lives inside Humanoid or AnimationController; loads and drives tracks |
| `AnimationController` | Replaces Humanoid for non-character rigs |
| `AnimationTrack` | Returned by `LoadAnimation`; controls playback |

| Scenario | Script type | Location |
|---|---|---|
| Local player character | `LocalScript` | `StarterCharacterScripts` |
| NPC / server-owned model | `Script` | Inside the model or `ServerScriptService` |

> Never play player-character animations from a `Script` — they won't replicate correctly
> to the local client.

```lua
-- LocalScript in StarterCharacterScripts
local character = script.Parent
local animator = character:WaitForChild("Humanoid"):WaitForChild("Animator")

local animation = Instance.new("Animation")
animation.AnimationId = "rbxassetid://1234567890"

local track = animator:LoadAnimation(animation)
track:Play()
```

### Common mistakes

| Mistake | Fix |
|---|---|
| Playing character animations in a `Script` | Use a `LocalScript` in `StarterCharacterScripts` |
| `LoadAnimation` called on `Humanoid` (deprecated) | Call it on `Animator` |
| Two animations fighting over the same joints | Assign different `Priority` values |
| `Stopped` fires immediately | Zero-length animation, or wrong `Looped` setting |
| `GetMarkerReachedSignal` never fires | Marker name misspelled, or animation not re-uploaded after adding markers |
| NPC animation not visible to other clients | Play from a `Script` (server), not a `LocalScript` |
| `AnimationController` track won't play | Missing `Animator` child inside the `AnimationController` |

---

## 11. Monetization

| System | Use for | Repeatable? | Min price |
|--------|---------|-------------|-----------|
| Game Pass | Permanent perks/access | No (one-time) | 1 Robux |
| Developer Product | Consumables, currency, boosts | Yes (unlimited) | 1 Robux |
| UGC Item | Avatar marketplace sales | N/A | 1 Robux |
| Premium Payout | Passive playtime income | Automatic | No setup |

### Game Pass — dashboard setup

1. [create.roblox.com](https://create.roblox.com) → select experience → **Monetization → Passes**
2. **Create a Pass** → upload a 512×512 PNG icon, set name, description, price
3. Save → note the **Pass ID**

```lua
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local PASS_ID = 000000

Players.PlayerAdded:Connect(function(player)
    local owns = false
    local ok = pcall(function()
        owns = MarketplaceService:UserOwnsGamePassAsync(player.UserId, PASS_ID)
    end)
    if ok and owns then
        -- grant the perk
    end
end)
```

### Developer Products — `ProcessReceipt`

Only **one** `ProcessReceipt` handler is allowed per server. Grant the item, persist it,
*then* return `PurchaseGranted`. If the grant or the save fails, return `NotProcessedYet`
so Roblox retries. Use `receiptInfo.PurchaseId` as a DataStore key to detect
already-processed receipts.

### Common mistakes

| Mistake | Fix |
|---------|-----|
| Ownership check in a LocalScript | Move to a server Script — client checks are exploitable |
| `ProcessReceipt` throws | Wrap in `pcall`; always return a decision enum |
| Not saving the purchase to DataStore | Player loses the item on crash — persist before `PurchaseGranted` |
| Multiple `ProcessReceipt` handlers | Only one per server — combine all product logic |
| Double-granting on receipt retry | Key on `receiptInfo.PurchaseId` |
| Selling UGC without program access | Apply to the UGC program first |
| Price below platform minimum | Minimum is 1 Robux for most item types |
| DevEx blocked despite enough Robux | Check every eligibility rule: 13+, verified email, no violations, Premium subscription, *earned* (not purchased) Robux |

---

## 12. Tooling — Rojo, Wally, luau-lsp

### Rojo

Bridges the filesystem and Roblox Studio: write code in VS Code, sync live to Studio via
the plugin, build `.rbxl`/`.rbxm` for deployment, and get real Git version control.

Current: **7.6.1 stable**, **7.7.0-rc.1** (websocket sync and syncback).

```bash
rojo init my-game       # scaffold a project
rojo serve              # live sync to the Studio plugin
rojo build -o game.rbxl # build a place file
```

`default.project.json` maps filesystem paths onto DataModel containers. Multi-environment
setups use separate `dev.project.json` / `prod.project.json` files.

### luau-lsp

```bash
luau-lsp analyze src/
luau-lsp analyze --sourcemap=sourcemap.json src/
luau-lsp analyze --definitions:@roblox=globalTypes.d.luau src/
luau-lsp analyze --no-flags-enabled src/
```

### `.luaurc`

```json
{
    "languageMode": "strict",
    "lint": {
        "LocalShadow": "disabled",
        "ImportUnused": "enabled"
    },
    "aliases": {
        "@shared": "src/Shared",
        "@server": "src/Server"
    }
}
```

Critical lint rules: `UnknownGlobal` (typos), `LocalUnused` (dead code),
`ImplicitReturn` (inconsistent returns), `UninitializedLocal` (use before assign).
28 rules total.

### The rest of the stack

- **Wally** — package manager; dependencies land in `Packages/`
- **Aftman / Rokit** — toolchain manager, pins Rojo/Wally/luau-lsp versions per project
- **StyLua** — formatter
- **TestEZ / Jest-Lua** — test runners

---

## 13. Sharp Edges Catalog

From `brockmartin/roblox-game-skill/references/sharp-edges.md`, severity-rated.

| ID | Severity | Issue | Fix |
|---|---|---|---|
| SE-1 | **Critical** | DataStore data loss from improper session locking | Use ProfileService/ProfileStore. Never raw `SetAsync` for player data. |
| SE-2 | **Critical** | Client-side currency manipulation | All currency math server-side. Client is display-only. |
| SE-3 | **Critical** | `ProcessReceipt` mishandling (duplicates/refunds) | Grant the item, *then* return `PurchaseGranted`. If the grant fails, return `NotProcessedYet`. |
| SE-4 | High | Memory leaks from undisconnected events | Store every `:Connect()` return; `:Disconnect()` on cleanup. Use Maid/Trove. |
| SE-5 | High | RemoteEvent flooding / exploitation | Per-player rate limiting — track last-fire timestamps server-side. |
| SE-6 | High | `BindToClose` timeout | You get ~30s. Flush all sessions in parallel, not serially. |
| SE-7 | Medium | Part count on mobile | Budget aggressively; use StreamingEnabled and LOD. |
| SE-8 | Medium | Yielding in module `require` | A yielding module stalls every requiring script. Keep `require` non-yielding. |
| SE-9 | Medium | Table length with nil gaps | `#t` is undefined with holes. Track count explicitly or avoid gaps. |
| SE-10 | Low | Deprecated `wait()`/`spawn()`/`delay()` | Use the `task` library. |
| SE-11 | Medium | Infinite yield warning | `WaitForChild` without a timeout hangs forever if the instance never arrives. |
| SE-12 | Low | String patterns vs regex | Luau patterns are *not* regex — `%` is the escape character, not `\`. |

---

## 14. Anti-Patterns Cheat Sheet

```lua
-- Legacy scheduler → task library
wait(1)        -- BAD
task.wait(1)   -- GOOD

spawn(fn)      -- BAD
task.spawn(fn) -- GOOD

delay(1, fn)      -- BAD
task.delay(1, fn) -- GOOD

-- Polling when events exist
while true do
    if something then break end
    task.wait()
end
-- GOOD: use events/signals

-- String concatenation in loops — O(n²)
local s = ""
for i = 1, 1000 do s = s .. tostring(i) end
-- GOOD: table.concat

-- FindFirstChild chains
workspace.Folder.SubFolder.Part   -- errors if any link is missing
-- GOOD: safe navigation
local folder = workspace:FindFirstChild("Folder")
local part = folder and folder:FindFirstChild("SubFolder")
    and folder.SubFolder:FindFirstChild("Part")
```

### Prefer

```lua
-- Generalized iteration (modern Luau)
for _, v in ipairs(array) do end  -- old
for _, v in array do end          -- modern

-- If expressions
local x = if condition then a else b

-- continue
for _, item in items do
    if not item.valid then continue end
    process(item)
end

-- Optional chaining via and
local name = player and player.Character and player.Character.Name
```

### Do / Don't

| Do | Don't |
|----|-------|
| `task.wait()` | `wait()` |
| `task.spawn()` | `spawn()` |
| `task.delay()` | `delay()` |
| `for _, v in t` | `for _, v in pairs(t)` |
| Validate on server | Trust client data |
| Use types | `any` everywhere |
| Disconnect events | Leave connections dangling |
| Use constants | Magic numbers/strings |
| Early return | Deep nesting |
| Small functions | 200+ line functions |

---

## 15. Official Documentation Endpoints

Roblox publishes AI-optimized documentation. Use these when a reference file doesn't cover
a topic or you need current API detail.

| Resource | URL | Use for |
|----------|-----|--------|
| LLM docs index | `https://create.roblox.com/docs/llms.txt` | Browse all doc pages by topic |
| Full docs (single file) | `https://create.roblox.com/docs/llms-full.txt` | Comprehensive single-file reference |
| Per-page markdown | `https://create.roblox.com/docs/en-us/{path}.md` | Read a specific page in clean markdown |
| Engine API index | `https://create.roblox.com/docs/reference/engine/llms.txt` | Luau API classes, methods, events |
| Open Cloud API index | `https://create.roblox.com/docs/cloud/llms.txt` | REST endpoints for external tools |
| Deprecated API inventory | `https://create.roblox.com/docs/reference/engine/deprecated.md` | Check whether an API is deprecated |

> **Important:** Engine APIs (Luau via `game:GetService()`) and Open Cloud APIs
> (HTTP REST via `x-api-key`) are **completely separate systems**. Using the wrong index
> produces non-functional code.

Other primary sources: the Luau language spec at <https://luau.org>, the
[Roblox Lua Style Guide](https://roblox.github.io/lua-style-guide/), and DevForum
[release notes](https://devforum.roblox.com/c/updates/release-notes/58).

---

## 16. Sources

Skill repositories downloaded:

- [brockmartin/roblox-game-skill](https://github.com/brockmartin/roblox-game-skill) — the monolithic "ultimate" Roblox skill
- [MSayib/roblox-dev-skill](https://github.com/MSayib/roblox-dev-skill) — 5100+ lines, self-updating knowledge base
- [sentinelcore/roblox-skills](https://github.com/sentinelcore/roblox-skills) — 7 focused skills
- [dig1t/skills](https://github.com/dig1t/skills) — `luau-best-practices`, `luau-type-expert`, `rojo-pro`
- [greedychipmunk/agent-skills](https://github.com/greedychipmunk/agent-skills) — `roblox-game-developer`

Referenced but not downloaded:

- [CyanoTex/Roblox-Claude-Code-Skills](https://github.com/CyanoTex/Roblox-Claude-Code-Skills) — clone failed
- [anthropics/skills issue #915](https://github.com/anthropics/skills/issues/915) — open request for a first-party Roblox/Luau skill
- [gamedev-skills/awesome-gamedev-agent-skills](https://github.com/gamedev-skills/awesome-gamedev-agent-skills) — 66 game-dev skills (Godot/Unity/Unreal/web); no Roblox coverage
- [rohitg00/awesome-claude-code-toolkit](https://github.com/rohitg00/awesome-claude-code-toolkit) — general Lua developer agent, not Roblox-specific
- [Roblox Engineer on mcpmarket](https://mcpmarket.com/tools/skills/roblox-engineer) — marketplace listing
- [Roblox Game Development on claudemarketplaces](https://claudemarketplaces.com/skills/greedychipmunk/agent-skills/roblox-game-development) — marketplace listing for the greedychipmunk skill

Code samples in sections 3–14 are drawn from the `SKILL.md` files of the repositories
above; each remains under its own upstream license.
