# Clovyre 1.7.1 — authorised red-team devirtualisation report

Artifact: `clovyre1.7.1obfuscated.txt`, 3,750,237 bytes, 4 lines.
Result: **fully devirtualised**. 283 VM protos / 23,669 reachable instructions recovered,
7,059 lines of readable Luau reconstructed, 288/288 differential tests identical.

## 1. Executive verdict

Clovyre 1.7.1 is a **deterministic, self-contained, static-key virtualiser**. Every key it
uses is either a literal in the payload or derived from literals by pure functions that ship
in the loader. Nothing depends on runtime entropy, host state, or network. Therefore the whole
protection is a *pure function of the file*, and a static re-implementation of six primitives
(≈120 lines of Python) decrypts strings, constants, and the entire instruction stream without
ever executing the artifact.

Estimated deobfuscation difficulty: **3.5 / 10** for a competent analyst.
- Understanding the loader: ~1 hour (the loader is emitted *unobfuscated at the source level* —
  real control flow, real `if/elseif`, only identifiers are mangled).
- Static decryptor: ~1 hour.
- Full structuring decompiler: the long pole (~1 day), and that cost is generic to any
  register VM, not specific to Clovyre.

The rolling rekeying is **cosmetic**: it re-encrypts ciphertext with a fresh key after each use
but the plaintext is invariant, and the *first* decryption is fully predictable from the file.
Measured directly (§4.6): const key word `838992545 → 1574681392 → 469793663` across three
reads, plaintext `"a%20b%2Fc"` identical every time.

Recovered payload: a Roblox "Clovexx / Clover" exploit-hub GUI (auto code redeemer, animal
rarity cache, AI "riddle" assistant with learn/forget memory, theme engine) that ships
**5 Discord webhooks, 3 licence/API tokens and 3 backend URLs in cleartext constants**.

## 2. Protection architecture map

### 2.1 Layer 0 — file layout
```
line 1-3  --[[ Clovyre 1.7.1 ]]
line 4    return(function(...)
            local STR = { 3194 obfuscated strings }        -- 83,633 B
            <loader + VM, 251,744 B of real code>
            local PAYLOAD = { 17-slot proto record }       -- 3.4 MB, 96% numeric
            local ok = pcall(INTEGRITY, PAYLOAD)
            if not ok then error("...integrity validation failed",0) end
            return VM_CLOSURE(PAYLOAD,{})(...)
          end)(...)
```
96% of the file is numeric data; the executable part is only 252 KB and *has ordinary control
flow* — no flattening, no opaque predicates in the loader itself.

### 2.2 Layer 1 — string table (`l_O1O1O___I`, memoised)
```
plain[j] = (byte[j] - (81 + j*6 + idx*13)) % 256      -- j 1-based, idx = table index
```
Positional Caesar, keyed only by the index. Entries 1–49 are loader strings (`"Instance"`,
`"function"`, the two error messages, the 41 whitelisted global names). Entries 50+ are
layer-2 ciphertext for the VM constant pool.

### 2.3 Layer 2 — environment gate
```lua
local n = 0
local ok = pcall(function()
  if typeof(game) == "Instance"       then n += 1 end
  if typeof(UDim.new(0,0)) == "UDim"  then n += 1 end
  if type(game.GetService)=="function"then n += 1 end
end)
if not ok or n ~= 3 then error("Clovyre Script:(internal): line 1: attempt to index nil with 'new'", 0) end
```
Three property probes, disguised behind a fake "line 1" runtime error. Satisfied by a 12-line
stub (`harness/stubs.lua`).

### 2.4 Layer 2b — global whitelist
`l_OI_O0` is a fixed 41-entry name→value table captured at load time; `GETGLOBAL/SETGLOBAL`
index it. This is the VM's `_ENV`. It also *documents the payload's capability surface*:
`syn`, `http_request`, `request`, `getgenv`, `getgc`, `getconnections`, `firesignal`,
`readfile/writefile/isfile`, `require`, `debug`.

### 2.5 Cryptographic primitives (all static, all invertible in the file)
| Symbol | Role | Definition |
|---|---|---|
| `F(x,rk,r)` | round fn | `(x*(50916+415r) + (rk%65536) + 22464r) % 65536` |
| `dec32(v,i,kA,kB,p)` | 6-round unbalanced Feistel, 32-bit | `rk=(kA + i*kB + 33304p) mod 2^32`, 6 rounds r=6..1, signed output |
| `enc32` | inverse of `dec32` | rounds r=1..6 |
| `lin(i,xk,p)` | additive mask | `(xk + 63076i + 59016p + 4701*(i mod 257)) mod 2^32` |
| `strdec(s,i,kA,k1)` | keystream | `st = (kA + 4023i + 29229k1 + 3135|s|) mod 2^31`, then `st = (73160st + 98237j + 4023i) mod 2^31`, `b - st mod 256` |
| `hash(h,v,c)` | integrity | `h = (330h + …) mod 2^31` over lengths/bytes |

Both Feistel and keystream are **key-recoverable-free**: the analyst never needs the key,
because the key material (`kA=proto[11]`, `kB=proto[5]`, `xk=dec32(proto[3],725817,…)`) is in
the record itself.

### 2.6 Proto record (17 slots)
| Slot | Contents | Encoding |
|---|---|---|
| 1 | constant-pool key B | plain |
| 2 | unused / decoy | plain |
| 3 | instruction additive key `xk` | `dec32(·,725817,kA,kB,0)` |
| 4 | constant-pool key A | plain |
| 5 | `kB` | plain |
| 6 | numparams | `dec32(·,119285,…)` |
| 7 | integrity seal | `dec32(·,889611,…)` |
| 8 | child protos (array) | nested records |
| 9 | is-vararg | `dec32(·,209172,…)` |
| 10 | entry pc | `dec32(·,407647,…)` |
| 11 | `kA` | plain |
| 12 | constant pool `{ct, k1, k2}[]` | 2-layer |
| 13 | upvalue descriptors (pairs) | `dec32(·,idx,kA,kB,0)` |
| 14 | flat instruction words, 8 per instr | 2-layer |
| 15 | unused / decoy | plain |
| 16 | opcode de-blind addend `u1` | `dec32(·,515945,…)` |
| 17 | opcode de-blind multiplier `u2` | `dec32(·,671020,…)` |

### 2.7 Instruction encoding — 8 words per instruction, base = `pc*8`
| Offset | Field | Notes |
|---|---|---|
| +5 | `seed` | decrypted with `prev=0`; feeds every other field |
| +3 | `A` (blinded opcode) | `op = ((A - u1) * u2) mod 65521` |
| +7 | `B` | destination / base register |
| +2 | `C` | operand / jump target |
| +1 | `D` | operand |
| +4 | `E` | **explicit next-pc** (threaded, not `pc+1`) |
| +8 | checksum | `(64A + 93B + 88C + 14D + 52E + 13·seed) mod 2^31` |
| +6 | — | **never read: decoy slot** |

Per word: `field = lin⁻¹( dec32(word, idx, kA, kB, prev), idx, xk, prev )`.
After decode the interpreter *re-encrypts all seven words under a fresh seed*
`(24382·seed + 12585·pc + 52529·A + 319876829) mod 2^31` and stores them back.

### 2.8 Dispatcher
A single `if/elseif` chain of 45 handlers. Each opcode has **three** accepted blinded values
(`op == a or op == b or op == c`) — a 3-way encoding polymorphism, not three dispatchers.
Control flow is *threaded*: `pc = E` unconditionally before the handler runs; branch handlers
overwrite `pc` with `C`. Because `E` is arbitrary, the instruction array is shuffled and
**40.4% of instruction slots (16,076 of 39,745) are unreachable decoys**.

### 2.9 Constants — rolling rekey
`l1I00OOllII(entry, idx, cKA, cKB)`:
```
k1  = dec32(entry[2], 4(idx-1)+2, cKA, cKB, 0)
tag = dec32(entry[3], 4(idx-1)+3, cKA, cKB, k1)
str = strdec(entry[1], idx, cKA, k1)
k1' = (39445k1 + 35494idx + 20884|str| + 2128576704) mod 2^31   (min 4096)
entry[1..3] := re-encrypt(str, tag, k1')                      -- state advances
return  tag==1807967222 and str  or  tag==286231453 and math.huge
     or tag==277167739 and -math.huge or tonumber(str)
```
Numbers are stored as **decimal strings** with a type tag; only ±inf get special tags.

### 2.10 Integrity seal (`IIO_OI`)
Recursive over the proto tree; folds lengths and elements of slots 14, 12, 13, 8 and the scalar
vector `[6,9,15,10,11,5,4,1,16,17,3]` into `h` (start `1581604043`) and compares with
`dec32(proto[7],889611,…)`. Runs **once**, under `pcall`, before execution.

### 2.11 Closures / upvalues
`CLOSURE B,C` reads child `C`'s slot 13 as `(kind, index)` pairs: `kind==1` → capture parent
**register** (which holds a one-element box created by `NEWCELL`/the cell-`NEWTABLE` variant),
else capture parent upvalue `index+1`. Upvalues are ordinary Lua boxes `{value}` read/written by
`GETUPVAL/SETUPVAL/GETCELL/SETCELL`. This maps 1:1 onto native Luau upvalue semantics, so the
reconstruction can use real captured locals.

## 3. Vulnerability table

Severity = impact on the protection's stated goal (hiding code + secrets). "Removes?" = does the
fix eliminate the class of attack or only raise cost.

| # | Stage / signature | Root cause | Prereq | Attack | Exposes | Sev | Conf | Fix | Removes? |
|---|---|---|---|---|---|---|---|---|---|
| V1 | `l_O1O1O___I` (loader, first function) | String key is a pure function of the *index*: `81+6j+13i`. No secret. | file only | 5-line script | all 49 loader strings incl. both error messages and the 41-name global whitelist | High | Certain | Derive the mask from a value that is not in the file (impossible offline) — or accept it | Cost only |
| V2 | slots 1,4,5,11 stored **in cleartext** next to the data they key | key co-located with ciphertext | file only | read `proto[11], proto[5], proto[4], proto[1]` | every Feistel/keystream key in the tree | **Critical** | Certain | none possible for a self-contained script: any key the VM can compute, the analyst can compute | Cost only |
| V3 | `_0l1O_0O10` / `_1_ll0_0_1l` | 6-round Feistel with a 16-bit affine round function and **no key schedule** (round key = one 32-bit value) | file only | reimplement in 12 lines; or invert algebraically | plaintext of every instruction word | High | Certain | irrelevant while V2 holds | No |
| V4 | instruction word `+8` checksum | verifier is *local* to one instruction and uses only fields the patcher already controls | file only | recompute `(64A+93B+88C+14D+52E+13s) mod 2^31` after editing | free instruction patching | High | Certain | make the seal cover the whole stream + a value derived outside the file | Cost only |
| V5 | 3-value opcode aliasing (`op==a or op==b or op==c`) | aliases are **hard-coded literals in the dispatcher** | file only | read them off the `elseif` chain | complete opcode map in one pass | Med | Certain | generate aliases per-build *and* make the mapping data-driven from an encrypted table | Cost only |
| V6 | `op = ((A-u1)*u2) % 65521` with `u1,u2` from slots 16/17 | blinding is invertible and keyed by in-file data | file only | invert | opcode identity | Med | Certain | — | No |
| V7 | slot `+6` never read | decoy occupies a fixed offset | file only | ignore offset 6 | 1/8 of the stream is noise, removed for free | Low | Certain | randomise which offset is the decoy per instruction | Cost only |
| V8 | 40.4% unreachable instructions | decoys are only reachable-set noise; reachability is computable from the `E` chain | file only | DFS from `entry` | 16,076 decoys eliminated automatically | Low | Certain | make decoys reachable-but-neutralised (predicated on opaque state) | Cost only |
| V9 | **rolling rekey of constants and instructions** | rekey changes *ciphertext only*; plaintext invariant; first decryption is deterministic from the file | file only | decrypt statically once, or hook `l1I00OOllII`'s return | all 3,311 constants incl. 11 secrets | **Critical** | Certain (measured, §4.6) | nothing short of not shipping the plaintext (e.g. server-held constants) | **No — it changes *when* you capture, not *whether*** |
| V10 | env gate `typeof(game)=="Instance"` … | three observable property probes, all forgeable | ability to define globals | 12-line stub | lets the artifact run in a bare Luau REPL for tracing | High | Certain | attest via a value only a real client holds (still forgeable) | Cost only |
| V11 | gate wrapped in `pcall`, result compared to a counter | failure is *silent and local*: patch the counter or the comparison | file edit | set `_1ll1l=3` / delete the `if` | analysis in-place | Med | Certain | spread the gate result into key material so failure corrupts decryption | **Yes (partially)** — makes tamper fail closed |
| V12 | `pcall(IIO_OI, PAYLOAD)` at the tail | seal is checked **once**, out-of-band, and its result is not used as a key | file edit | delete the `if not ok` line, or the whole `pcall` | unrestricted payload editing | High | Certain | fold the seal into `xk`/`kA` so a bad seal produces garbage instructions | **Yes** |
| V13 | seal covers pre-execution state only | rekeying mutates slots 12/14, so the seal is **invalid after the first call** (verified: re-running `IIO_OI` after one call → `integrity validation failed`) | run once | let it run, then edit constants freely | post-load tamper is undetectable | Med | Certain | seal the *plaintext*, not the ciphertext | **Yes** |
| V14 | `_llOllIll_Il1` is a plain local closure | any inner proto can be instantiated from outside with attacker-chosen upvalues | file edit | `return {run=_llOllIll_Il1, root=PAYLOAD}` | arbitrary sub-function execution / differential oracle (§7) | High | Certain | none while the VM lives in the same chunk | Cost only |
| V15 | constants store numbers as **decimal strings** | `tonumber(strdec(...))` | file only | — | numeric constants are self-describing after one decrypt | Low | Certain | store numbers as encrypted words | Cost only |
| V16 | 11 live credentials in the constant pool | secrets are compiled in | file only | any of the above | 5 Discord webhooks, 3 tokens, 3 URLs (see §8) | **Critical** | Certain | move them server-side behind an authenticated endpoint | **Yes** |
| V17 | loader control flow is not obfuscated | only identifiers are mangled | file only | read it | the entire scheme, in one sitting | High | Certain | virtualise the loader too (bootstrap VM) | Cost only |

## 4. Attack attempts

Successful (all reproducible from `tools/`):

1. **Static string recovery** — inverted `l_O1O1O___I`; 3,194 entries, 49 immediately plaintext.
2. **Payload parsing** — recursive-descent parse of the 3.4 MB table literal → 283 protos.
3. **Static key extraction** — slots 11/5/4/1/3/16/17 per proto.
4. **Static instruction decryption** — all 39,745 instructions; **every checksum verified**
   (assertion in `clov.Proto.ins`, zero failures). Proof the model is exact.
5. **Static constant decryption** — 3,311 constants, no execution.
6. **Rolling-rekey test** (`harness/run4.lua`): const key word changes on every read
   (`838992545 → 1574681392 → 469793663`); 91/184 instruction words re-encrypted after call 1
   and again after call 2; output byte-identical. **Rekeying provides no confidentiality.**
7. **Integrity-seal analysis** — seal passes on the pristine payload (`true`) and **fails after
   one execution** (`false, "integrity validation failed"`), i.e. it is single-shot and cannot
   detect post-load tampering.
8. **Environment-gate bypass** — 12-line stub; artifact loads and runs in stock `luau`.
9. **Dispatcher/opcode recovery** — 45 opcodes × 3 aliases read off the `elseif` chain (§5).
10. **Decoy elimination** — DFS over the `E` chain: 23,669 reachable / 39,745 (40.4% decoy).
11. **Control-flow reconstruction** — linearisation of the threaded graph + structuring
    (if/else, and/or, while, numeric for, generic for, break/continue).
12. **Decompilation** — liveness-driven expression folding → 7,059 lines of Luau.
13. **Runtime hooking / capture-at-use-site** — instantiating any inner proto via the exposed
    `run()` gives a live oracle; combined with static decode it makes rekeying irrelevant.
14. **Differential execution** — §7: 288/288 identical, plus a 12-step stateful test.

Unsuccessful / not needed:
- **Symbolic execution**: unnecessary; the cipher is deterministic and keyless-to-the-analyst.
- **Recovering original identifiers/comments**: impossible — erased at compile time.
- **Full-program end-to-end replay**: not attempted; the payload is a Roblox GUI needing a real
  DataModel. Deliberately *not* executed, since it contacts Discord webhooks (out of scope).
- **Perfect structuring**: 47 residual `-- UNSTRUCTURED` markers (0.67% of lines), see §8.

## 5. Recovered opcode / dispatcher mapping

`op = ((word[base+3] - proto[16]') * proto[17]') mod 65521`, three accepted values each.
Registers `R[]`, constants `K[]`, globals `G[]` (41-name whitelist), upvalue boxes `U[]`.

| Op | Aliases | Semantics |
|---|---|---|
| MOVE | 45999, 32361, 9046 | `R[B]=R[C]` |
| LOADK | 13880, 21673, 40041 | `R[B]=K[C]` |
| LOADNIL | 31571, 60208, 22488 | `R[B]=nil` |
| LOADBOOL | 62089, 62615, 6816 | `R[B]=(C~=0)` |
| GETGLOBAL | 13065, 18187, 42445 | `R[B]=G[K[C]]` |
| SETGLOBAL | 25433, 20384, 50179 | `G[K[C]]=R[B]` |
| GETTABLE | 56960, 46786, 65338 | `R[B]=R[C][R[D]]` |
| SETTABLE | 22173, 30676, 51946 | `R[B][R[C]]=R[D]` |
| SELF | 24553, 35812, 13221 | `R[B+1]=R[C]; R[B]=R[C][R[D]]` |
| NEWTABLE | 20468, 52269, 14367 | `R[B]={}` |
| NEWTABLE(cell) | 38230, 49821, 18575 | `R[B]={}` — always an upvalue box |
| NEWCELL | 30586, 29393, 60002 | `R[B]={R[B]}` (box current value) |
| GETCELL | 11283, 50674, 57035 | `R[B]=R[C][1]` |
| SETCELL | 31238, 38566, 43805 | `R[B][1]=R[C]` |
| GETUPVAL | 56679, 59247, 32078 | `R[B]=U[C][1]` |
| SETUPVAL | 40256, 15161, 53347 | `U[C][1]=R[B]` |
| ADD | 17917, 58382, 51565 | `R[B]=R[C]+R[D]` |
| SUB | 54908, 20988, 10778 | `-` |
| MUL | 51212, 60858, 22263 | `*` |
| DIV | 28622, 63059, 33134 | `/` |
| IDIV | 14040, 5823, 40762 | `//` |
| MOD | 15861, 27931, 50318 | `%` |
| POW | 60732, 55942, 19296 | `^` |
| CONCAT | 37674, 41898, 31535 | `..` (binary) |
| UNM | 47444, 5176, 35466 | `-R[C]` |
| NOT | 46838, 14145, 41727 | `not R[C]` |
| LEN | 44713, 42315, 34259 | `#R[C]` |
| EQ | 61552, 12201, 50784 | `==` |
| NE | 48178, 45000, 20421 | `~=` |
| LT | 62583, 25728, 13713 | `<` |
| LE | 54543, 29633, 28955 | `<=` |
| GT | 9381, 20369, 46238 | `>` |
| GE | 7602, 38098, 46559 | `>=` |
| JMP | 41822, 52837, 44167 | `pc=B` |
| TEST | 55236, 64176, 8194 | `if R[B] then pc=C end` |
| TESTNOT | 40519, 65399, 43087 | `if not R[B] then pc=C end` |
| FORPREP | 18760, 33932, 51005 | `R[B]-=R[B+2]; pc=C` |
| FORLOOP | 42954, 33052, 6705 | `R[B]+=R[B+2]`; if in range `R[B+3]=R[B]; pc=C` |
| TFORCALL | 34961, 20287, 23990 | call/`next` on `R[B],R[B+1],R[B+2]` → `R[B+3..B+2+D]` |
| TFORLOOP | 52797, 34444, 52611 | `if R[B+3]~=nil then R[B+2]=R[B+3]; pc=C end` |
| CALL | 34963, 61257, 26750 | `nargs=C-1` (0 ⇒ to top), `nres=D-1` (0 ⇒ multret) |
| RETURN | 41767, 35479, 13663 | `n=C-1` (0 ⇒ to top) |
| VARARG | 30306, 48922, 26748 | `R[B..]` from the saved `...` |
| SETLIST | 46564, 16769, 51002 | `R[B][D+i]=R[B+i]` |
| CLOSURE | 8150, 35413, 12905 | instantiate child `C` with slot-13 upvalue descriptors |

Two decodes that are *not* opcodes and matter: `pc` always comes from field `E`, and the
`error("invalid virtual instruction")` arm is reached only on checksum failure or an unknown
blinded opcode — i.e. it is the anti-tamper trap, and it is purely local.

## 6. Reconstructed source

Full reconstruction: `recon_redacted.lua` (7,059 lines, credentials replaced by
`REDACTED_SECRET_n`). The unredacted copy is left untracked on disk only.

Fidelity classes:
- **Exact recovered data** — all constants, all opcodes, all operands, proto arity/vararg flags,
  upvalue capture graph, global whitelist, both error strings.
- **Strongly inferred** — `a and b` / `a or b` reconstruction from `TEST`+single-assignment
  blocks; method-call sugar `o:m(x)` from `GETTABLE R[B],R[B+1],k` + `CALL` with `R[B+1]`
  retained as arg 1; numeric/generic `for` from FORPREP/FORLOOP/TFORCALL/TFORLOOP idioms.
- **Behaviourally equivalent** — register names (`v<n>`), captured-local names (`c<reg>_<seq>`),
  statement ordering inside basic blocks, and `local` placement. Names/comments/formatting are
  irrecoverable and are **not** claimed to be original.
- **Unresolved** — 47 `-- UNSTRUCTURED` markers (§8).

## 7. Behavioural-equivalence harness

`harness/` — build with `cat stubs.lua art_mod.lua <driver> > run.lua && luau run.lua`.
`art_mod.lua` is the artifact with **one** edit (V14): the tail `return VM(PAYLOAD,{})(...)`
becomes `return {run=VM, root=PAYLOAD, verify=INTEGRITY}`. No other byte is changed; the
integrity seal still passes.

- `drv1.lua` — sanity: seal passes; three inner protos instantiated and called.
- `drv2.lua` — **differential**: 18 root-level protos × 16 input tuples (strings, numbers,
  booleans, nil, tables, mixed arity) through both the live VM and the reconstruction,
  comparing full return tuples *and* error status. Result: **288 identical, 0 mismatches**.
- `drv3.lua` — **stateful / mutable-upvalue / aliasing**: proto `[27,1]` (a heartbeat animation
  callback with two mutating upvalue accumulators, a computed-key table write and an aliased
  target object) driven 12 times with varying `dt`; compares both accumulators and the emitted
  `ColorSequence` keypoints each step. Result: **12/12 steps identical**.
- `drv4.lua` — rekey/seal instrumentation (§4.6, §4.7).

## 8. Remaining unknowns and confidence

| Item | Status | Confidence |
|---|---|---|
| Cipher/keying model | complete; every one of 39,745 instruction checksums verifies | Certain |
| Opcode semantics | 45/45 handlers read directly from source | Certain |
| Constant values | 3,311 decoded statically, confirmed live | Certain |
| Structuring | 7,012/7,059 lines structured; **47 residual markers** (13 JMP, 30 TEST, 2 TFOR pairs) — irreducible `goto`-shaped control flow in ~15 of 283 protos; the underlying instructions *are* decoded, only the surface syntax is unresolved | High |
| Slot 2 | never read by the loader, VM, or the integrity seal — pure decoy | High |
| Slot 15 | hashed by the seal but never otherwise consumed — decoy that is nonetheless authenticated | High |
| Original identifiers / comments | unrecoverable | Certain |
| Reconstruction of `fn_main` as a runnable chunk | exceeds Luau's 200-locals-per-function limit (a decompiler artifact, not a semantic one); sub-functions run fine | Certain |
| Payload behaviour beyond static reading | not executed end-to-end by design (it contacts Discord webhooks) | — |

Recovered credentials — values withheld, `REDACTED_SECRET_n` in the tracked source:

| ID | Type | Len | SHA-256 (first 16) | Recoverable by an attacker? |
|---|---|---|---|---|
| S1 | Discord CDN URL | 210 | `9f299a1e64af3c2e` | Yes — trivially |
| S2–S6 | Discord webhook URLs (×5) | 121 each | `50caa06f…`, `61ab170b…`, `2b83879d…`, `e9aa039a…`, `366faf2c…` | Yes |
| S7 | backend URL | 43 | `28ef5fa767068780` | Yes |
| S8 | backend URL | 38 | `ad34ac30b8226fe6` | Yes |
| S9 | token/key | 36 | `7fc28be93747cf4f` | Yes |
| S10 | licence key | 32 | `8b3aadcaec98ae75` | Yes |
| S11 | token/key | 32 | `86568b27cc14d992` | Yes |

All eleven are plain constants in the pool; **any** of the §4 attacks yields them, and the
rolling rekey does not delay recovery by a single step. Treat all as compromised: rotate the
webhooks and both backend tokens.

## 9. Prioritised hardening

**P0 — removes the weakness**
1. Stop shipping secrets. Webhooks and tokens must live behind an authenticated server
   endpoint; the client should never hold a value whose disclosure matters. (V16)
2. Fail-closed anti-tamper: fold the integrity seal and the environment-gate result into the
   key schedule (`xk`, `kA`, opcode blinding) instead of comparing them. A wrong seal must
   produce garbage instructions, not an `error()` an analyst deletes. (V11, V12)
3. Seal the *plaintext*, and re-verify continuously — the current seal is invalid after the
   first call, so post-load tampering is free. (V13)

**P1 — materially raises cost**
4. Virtualise (or at least flatten) the loader. Today the whole scheme is readable prose. (V17)
5. Make the opcode map data-driven and per-build randomised; drop the 3-alias trick, which
   costs an analyst one `sort | uniq`. (V5)
6. Global seal over the entire instruction stream, keyed by a value not present in the file,
   instead of a 6-term local checksum. (V4)
7. Make decoys reachable-but-inert under opaque predicates so a reachability DFS can't delete
   40% of the program. (V8); randomise the decoy word offset (V7).
8. Split constants across protos and derive the constant keys from the *execution path*
   (e.g. a running hash of executed pcs) so out-of-order/static decryption diverges. This is
   the only change that would have broken my static pass.

**P2 — cosmetic, do them but expect nothing**
9. Non-index-derived string masking (V1); per-round key schedule in the Feistel (V3);
   binary-encoded numeric constants (V15); more environment probes (V10).

**Explicitly not worth more investment**: rolling rekeying. It is measurably a no-op against
both static and dynamic recovery (§4.6) — the plaintext is invariant and the first decryption
is deterministic. It only changes *when* an attacker must capture, and static analysis never
has to capture at all.
