# Clovexx — a Luau obfuscator

A from-scratch, source-level obfuscator for Luau / Roblox scripts. It parses real
Luau (types, string interpolation, compound assignment, generics, attributes),
transforms the AST, and emits minified, obfuscated Luau that runs identically to
the original.

This is **your** obfuscator: no external service, no per-seat cost, and the output
is not fingerprintable as any commercial product. It is a *source transformer*,
not a bytecode virtualizer — see [Strength & limits](#strength--limits).

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
  Obfuscator.luau       pipeline + reserved-name collection + IIFE wrap
  passes/
    Rename.luau         scope-aware local renaming
    StringEncrypt.luau  encrypted string pool + injected decoder
    NumberEncode.luau   integer-literal encoding
    Junk.luau           dead-code / unused-local injection
build.py                bundles src/ into dist/Clovexx.luau
dist/Clovexx.luau       generated single-file ModuleScript (commit artifact)
roblox/                 Studio plugin
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
python3 tests/run.py roundtrip     # parse -> serialize equivalence
python3 tests/run.py obfuscate     # full-pipeline equivalence (src/)
CLOVEXX_BUNDLE=1 python3 tests/run.py obfuscate   # same, via dist/Clovexx.luau
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
