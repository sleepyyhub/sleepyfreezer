# Clovexx & Clovyre — Luau obfuscators

Two from-scratch obfuscators for Luau / Roblox scripts, sharing one front end:

- **Clovexx** — a *source-level* obfuscator. Parses real Luau, transforms the AST,
  and emits minified, obfuscated Luau (renaming, string encryption, number
  encoding, junk). Fast, small output.
- **Clovyre** — a *VM / bytecode* obfuscator (the strong tier). Compiles your
  Luau to a custom register-machine bytecode and ships an interpreter that runs
  it. Your original control flow, names, strings and constants are **gone**,
  replaced by an opcode array and a dispatch loop. This is the Luraph-class
  technique, and it can layer the Clovexx passes on top of its own interpreter.

Both are **yours**: no external service, no per-seat cost, and the output is not
fingerprintable as any commercial product.

---

## Clovyre (VM / bytecode virtualization)

Clovyre compiles each Luau function to a proto — `{ code, k, protos, ... }` — where
`code` is a flat array of opcode integers. At runtime a small interpreter walks
that array. The compiler reproduces Lua semantics faithfully:

- **Closures & upvalues** — every local is boxed in a one-element cell, so nested
  closures and **per-iteration loop-variable capture** are correct by construction.
- **Multiple returns / varargs** — full Lua multi-value calling convention (the
  `top` register discipline), including `f(g())`, `{...}`, `select("#", ...)`.
- **Metatables** — arithmetic, comparison, concat, length and indexing use native
  operators inside the VM, so `__index`, `__add`, `__eq`, … all just work.
- **Generalized `for`** — iterating a table directly (`for k,v in t do`) as well as
  iterator functions (`pairs`/`ipairs`).
- **`if`/`while`/`repeat`-until (sees body locals)/numeric & generic `for`/`break`/
  `continue`**, method calls with implicit `self`, `if-then-else` expressions.

**Correctness guarantee:** any construct the VM can't express raises an internal
marker and Clovyre **falls back to Clovexx** for that program — so output always
runs. In practice the compiler virtualizes essentially the whole parseable Luau
surface (the full test suite virtualizes with zero fallback).

```lua
local Clovyre = require(path.to.Clovyre)
local out = Clovyre.obfuscate(source, {
    seed = 12345,
    protect = true,   -- also run the Clovexx passes over the emitted interpreter
})
```

Options: `seed` (deterministic), `protect` (default false), `fallbackOnUnsupported`
(default true).

### Studio plugin

`roblox/ClovyrePlugin.server.luau` adds **VM** and **VM+Protect** toolbar buttons
that virtualize the selected script into a new ModuleScript. Put the bundled
`dist/Clovyre.luau` inside the plugin as a child named `Clovyre`.

### Trade-offs

- Strong protection, but **larger and slower** output than Clovexx — the program
  now runs through an interpreter. Best for the code you most want to protect.
- The interpreter shape is fixed per build; run `protect = true` to rename and
  string-encrypt it so the VM itself isn't sitting in the clear.
- Same honest ceiling as any obfuscator: a determined reverser with a VM-lifting
  toolkit can still make progress. This raises the cost a lot; it is not DRM.

---

## Clovexx (source-level)

A source transformer: parses real Luau (types, string interpolation, compound
assignment, generics, attributes), transforms the AST, and emits minified,
obfuscated Luau that runs identically to the original.

## What it does

The pipeline runs these passes (all on by default):

| Pass | Effect |
|------|--------|
| **String encryption** | Every string literal is moved into an encrypted pool and replaced by a call to an injected runtime decoder (additive stream cipher, memoized). No `bit32`/`loadstring` needed. |
| **Number encoding** | Integer literals become equivalent arithmetic / `bit32.bxor` expressions (`10` → `802237*199`-style, exact). Non-integers are left untouched for exactness. |
| **Local renaming** | Scope-aware renaming of every local, parameter and loop variable to opaque confusable identifiers (`l1OlOl1`, `I0l_I_O`). Globals, field names, method names and table keys are preserved. |
| **Junk / dead code** | Unused local declarations and opaque, variable-guarded dead branches interleaved through every scope. |
| **Minify + wrap** | Whitespace/comments stripped; the whole chunk is wrapped in `return (function(...) ... end)(...)` so a ModuleScript's return value is preserved. |

Every transform is verified behavior-preserving by the test harness (below).

## Usage in Roblox

`dist/Clovexx.luau` is a single self-contained ModuleScript (no dependencies).

```lua
local Clovexx = require(path.to.Clovexx)

local obfuscated = Clovexx.obfuscate(sourceString, {
    seed = 12345,        -- optional; same seed => same output
    encryptStrings = true,
    encodeNumbers  = true,
    renameLocals   = true,
    junk           = true,
    wrap           = true,
})
```

### Studio plugin

`roblox/ClovexxPlugin.server.luau` adds a **Clovexx → Obfuscate** toolbar button
that obfuscates the selected script's `Source` into a new ModuleScript beside it.
Put the bundled `dist/Clovexx.luau` inside the plugin as a child named `Clovexx`,
then save the folder as a local plugin. (Reading script `Source` needs the
script-injection permission Studio grants plugins on first use.)

## Options

All options default to `true` except `seed`. Pass any subset:

- `seed: number` — deterministic PRNG seed. Omit for a fixed default.
- `encryptStrings`, `encodeNumbers`, `renameLocals`, `junk`, `wrap: boolean` —
  toggle individual passes.

## Project layout

```
src/
  Lexer.luau            Luau tokenizer (numbers, strings, interpolation, symbols)
  Parser.luau           recursive-descent parser; parses & discards Luau types
  Serializer.luau       AST -> minified Luau source
  NameGen.luau          deterministic opaque-identifier generator
  Obfuscator.luau       Clovexx pipeline + reserved-name collection + IIFE wrap
  Clovyre.luau          Clovyre pipeline (compile -> emit VM, Clovexx fallback)
  passes/
    Rename.luau         scope-aware local renaming
    StringEncrypt.luau  encrypted string pool + injected decoder
    NumberEncode.luau   integer-literal encoding
    Junk.luau           dead-code / unused-local injection
  vm/
    Opcodes.luau        shared register-VM instruction set
    Compiler.luau       AST -> bytecode proto (registers, upvalues, multi-value)
    Runtime.luau        emits interpreter + serialized proto data + bootstrap
build.py                bundles src/ into dist/Clovexx.luau and dist/Clovyre.luau
dist/                   generated single-file ModuleScripts (commit artifacts)
roblox/                 Studio plugins (Clovexx + Clovyre)
tests/                  equivalence harness + sample scripts
```

## Building the bundle

```
python3 build.py         # regenerates dist/Clovexx.luau from src/
```

## Testing

The harness runs each sample through the real Luau interpreter, obfuscates it,
runs the result, and asserts byte-identical program output.

```
python3 tests/run.py roundtrip                     # parse -> serialize equivalence
python3 tests/run.py obfuscate                     # Clovexx full-pipeline equivalence
python3 tests/run.py clovyre                       # Clovyre VM equivalence
CLOVEXX_BUNDLE=1 python3 tests/run.py obfuscate    # Clovexx via dist bundle
CLOVYRE_BUNDLE=1 python3 tests/run.py clovyre      # Clovyre via dist bundle
CLOVYRE_PROTECT=1 python3 tests/run.py clovyre     # Clovyre with protect mode
```

Requires a `luau` binary on `PATH` or in `$LUAU`.

## Strength & limits

This is honest about what it is:

- It **raises the cost** of reading your script substantially: no readable
  identifiers, no plaintext strings, no literal constants, plus dead-code noise.
- It is **not** a VM/bytecode virtualizer. A determined reverse-engineer with the
  right tools can still recover control flow, because the structure is ordinary
  Luau. Commercial tools like Luraph add a custom bytecode VM on top; that is a
  much larger, separate phase-2 effort.
- Output is **exact**: strings, numbers and control flow are preserved. Type
  annotations are stripped (they are runtime no-ops).

### Known limitations

- Type-annotation *stripping* covers the common Luau surface; extremely exotic
  type expressions may need the parser's type-skipper extended.
- `goto`/labels are not part of Luau and are not handled.
- The junk pass emits lint-noisy (but correct) code; disable `junk` if you run
  the output through a strict linter.
