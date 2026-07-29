# Clovyre 1.8.0 — devirtualisation report & flaw list (vs 1.7.1)

Artifact: `clovyre1.8.0obfuscated.txt`, 479,259 bytes, 4 lines.
Result: **fully devirtualised**. 33 protos, all **39,608 instruction words verified against
their embedded checksums** (0 failures), 394 constants decoded, 632-line readable Luau
reconstructed. Payload is a synthetic self-test harness ("CLOVYRE_HYDRA") — no live secrets.

## 1. Executive verdict

Same architecture as 1.7.1: string table → env gate → global whitelist → nested proto record
→ integrity pass → VM closure. Two mechanisms were genuinely hardened, several were **weakened
or unchanged**, and the fatal class of flaw (self-contained static keys) is untouched.

Estimated deobfuscation difficulty: **still ~3.5/10**. My 1.7.1 toolchain ported to 1.8.0 in
about an hour — only six numeric constants and a handful of slot indices changed. The all-
checksums-verify result is cryptographic proof the decode model is exact.

**The single most important finding:** 1.8.0 implements exactly the fail-closed anti-tamper I
recommended for 1.7.1 (V11/V12) — the integrity result is now folded into the instruction key
instead of being compared and discarded. **But it does not stop static analysis**, because the
folded value (the "residual") is still a pure function of the file's bytes. I compute it the
same way the loader does; with it, every instruction decrypts and every checksum passes.
Measured: pristine residual = 0; flipping one instruction word makes the loader emit
`invalid virtual instruction` (fail-closed against tampering ✓), yet a pristine file decodes
completely offline (static analysis defeated ✗ for the defender).

## 2. What changed vs 1.7.1

| Aspect | 1.7.1 | 1.8.0 | Effect |
|---|---|---|---|
| Feistel rounds | 6 | **3** | **weaker** |
| Feistel round fn | `x*(50916+415r)+…` | `x*(37224+486r)+rk+32473r` | equivalent |
| String mask | `81+6j+13i` | `23+7j+9i` | equivalent (still index-only) |
| Global whitelist | 41 (Roblox/http/exploit) | 11 pure-logic (`bit32,math,string,table,pcall,select,setmetatable,tonumber,tostring,type,error`) | sample-specific |
| Constant entry | `{ct,k1,k2}`, no per-entry seal | **`{tag,checksum,k1,str}` with per-constant integrity hash** (`error "invalid virtual constant"`) | **stronger** |
| Opcode blinding | `((A-u1)*u2)%65521` | **`(((A-u1)*u2)%65521 *7935+27397)%65521`** (double affine) | marginally stronger |
| Instruction fields | seed+5, op+3, decoy **+6** | seed+5, op+7, B+8, C+4, D+1, E+3, chk+6, decoy **+2** | shuffled |
| Checksum coeffs | `64,93,88,14,52,13` | `16,73,79,31,71,34` | equivalent |
| Integrity result | compared → `error` (skippable) | **folded into instruction key (residual)** | **stronger (fail-closed)** |
| Integrity call | optional for execution | **load-bearing** (skip → wrong keys) | **stronger** |
| Constant slot | 12 | 4 | cosmetic |
| Upvalue-desc slot | 13 | 12 | cosmetic |
| Children slot | 8 | 16 | cosmetic |
| Decoy rate | 40.4% | **45.6%** | marginally stronger |
| New error strings | — | "invalid virtual constant", "invalid virtual payload" | — |

## 3. Recovered architecture (1.8.0 specifics)

- **String table** `l_0_1O_` (403 entries): `plain[j] = (byte[j] - (23 + 7j + 9·idx)) % 256`.
- **`dec32`** — 3-round Feistel, `rk=(kA + idx·kB + prev·8579) mod 2³²`, rounds r=3,2,1;
  `F(x,rk,r)=(x·(37224+486r)+rk%65536+32473r)%65536`. `enc32` = rounds 1,2,3.
- **`lin`** (additive mask) `= (xk + 45170·idx + 5142·prev + 56028·(idx%257)) mod 2³²`.
- **`strdec`** keystream: `st=(kA%2³¹ + 484·idx + 51100·k1 + 2220·len)`, iterate
  `st=(40347·st + 10918·j + 484·idx) mod 2³¹`, byte subtract.
- **Proto record (17 slots)**: 1=entry pc, 2=numparams, 3=kA(base), 4=constant pool,
  5=kB(base), 6=integrity seal, 7=const-kA(base), 9=vararg, 10=const-kB(base), 11=xk,
  12=upvalue descriptors, 13=(hashed scalar), 14=instructions, 15=opcode-deblind u1,
  16=child protos, 17=opcode-deblind u2.
- **Residual / fail-closed key**: integrity fn `IOO00l` sets
  `residual[proto] = (hash − dec32(proto[6],859590,proto[3],proto[5],0)) mod 2³¹`.
  The VM then decrypts with `kA' = proto[3] + residual·33425`, `kB' = proto[5] + residual·33425`
  (and likewise const keys from slots 7/10). Pristine residual = 0.
- **Instruction** (8 words, base `pc·8`): field = `lin⁻¹(dec32(word,idx,kA',kB',prev),idx,xk,prev)`;
  seed at +5 (prev 0); opcode A=+7, B=+8, C=+4, D=+1, next-pc E=+3, checksum=+6, **decoy=+2**.
  Checksum `(16A+73B+79C+31D+71E+34·seed) mod 2³¹`. Re-encrypts 7 words after decode.
- **Opcode** `op = ((((A−u1)·u2) mod 65521)·7935 + 27397) mod 65521`; dispatched via one
  `if/elseif` chain, 45 handlers, 3 aliases each (identical opcode set to 1.7.1 minus the
  Roblox-specific ones; see `tools/clov18.py` OPS table).
- **Constants** `_0_Ol0O`: 4-field entry, per-constant seal `l011_OIlO0` (start `2044897271`,
  `h=(258h+30·byte+3036·i)`), rolling rekey after each read, decimal-string numbers with
  tags (string=1458442008, +inf=1533962859, −inf=796708246).
- **Integrity `IOO00l`**: recursive; folds slots 14,4,16,12 and scalar vector
  `[2,9,13,1,kA,kB,7,10,15,17,11]`; result becomes the residual (above).

## 4. Flaw list

Legend: **Removes?** = does the fix eliminate the class or only raise cost.

| # | Signature | Root cause | Attack | Sev | Removes? | Status vs 1.7.1 |
|---|---|---|---|---|---|---|
| V1 | string mask `23+7j+9i` | key = pure function of index, no secret | invert (5 lines) | High | cost only | **unchanged** |
| V2 | slots 3,5,7,10,11 in **cleartext** in each record | key co-located with ciphertext | read them, decrypt everything | **Critical** | no (impossible for a self-contained script) | **unchanged** |
| V3 | `dec32` now only **3 rounds**, affine 16-bit round fn, no key schedule | reversible; also weaker than 1.7.1 | reimplement in 12 lines | High | no | **worse** |
| V4 | instruction `+6` checksum | 6-term local combination of fields the patcher controls | recompute after edit | High | cost only | unchanged (coeffs differ) |
| V5 | opcode aliases are literals in the dispatcher | — | read the `elseif` chain | Med | cost only | unchanged |
| V6 | `op` double-affine blinding with in-file u1/u2 | invertible, keyed by record data | invert both layers | Med | no | slightly harder, same class |
| V7 | slot `+2` never read | fixed decoy offset | ignore offset 2 | Low | cost only | unchanged (offset moved) |
| V8 | 45.6% unreachable instructions | reachability computable from the `E` chain | DFS from entry | Low | cost only | slightly worse (more decoys, same removal) |
| V9 | rolling rekey (instr + const) | rekey changes ciphertext only; plaintext invariant; first decode deterministic | static decode once | **Critical** | **no** — shifts *when* you capture, not *whether* | unchanged |
| V10 | env gate `typeof(game)=="Instance"`… | forgeable probes | 12-line stub | High | cost only | unchanged |
| V11/12 | **residual folded into instruction key** | fail-closed on tamper ✓ **but residual is a pure function of file bytes** | compute residual identically, decode statically | **Critical** (for confidentiality) | **no** — raises tamper cost, does nothing vs static analysis (proved: all checksums verify) | **improved but not sufficient** |
| V13 | per-constant seal | detects constant tampering ✓ but the seal inputs are in the file | recompute after edit; or just read plaintext | Med | partial | **improved** |
| V14 | VM closure `l0Ol1_l1ll0` is a plain local | any inner proto instantiable externally | one-line edit exposes `run`/`root`/`verify` | High | cost only | unchanged |
| V15 | numbers stored as decimal strings | `tonumber(strdec(...))` | — | Low | cost only | unchanged |
| V17 | loader control flow unobfuscated | only identifiers mangled | read it | High | cost only | unchanged |

**Net:** 1.8.0 fixes the two anti-tamper flaws I called out for 1.7.1 (V11/V12 fail-closed,
V13 constant sealing) and adds decoys — genuine, welcome improvements against *patching*. It
**weakens** the cipher (6→3 rounds) and leaves every static-analysis flaw intact. Because the
keys and the residual are all pure functions of the shipped bytes, static devirtualisation is
exactly as feasible as before: I decoded the entire payload without executing it, and every one
of the 39,608 instruction checksums verified.

## 5. Evidence

- `tools/clov18.py` — decoder (residual, 3-round Feistel, constants, opcode table). Running it
  over the payload verifies all 39,608 checksums with zero failures.
- `recon18.lua` — 632-line reconstruction (32/33 protos fully structured; 1 proto, the payload's
  own deliberately-tangled inner interpreter, has 4 residual `-- UNSTRUCTURED` markers where
  *surface structuring*—not decoding—is incomplete; that proto's instructions are fully decoded
  and checksum-verified).
- `constants18.txt` — all 394 decoded constants.
- `harness18/tamper.lua` — demonstrates fail-closed behavior: 1-word edit →
  `invalid virtual instruction`.

## 6. Hardening recommendations (unchanged priorities)

The 1.8.0 changes are all in the "raises cost against patching" column. To actually stop
recovery, the P0 items from the 1.7.1 report still stand and are the only ones that matter:

1. **Derive keys from execution state, not file bytes.** The residual is the right *idea* but
   it is computed from the stored payload, so it is static. Key the constant/instruction
   schedule off a running hash of *executed* program counters + external input, so out-of-order
   / static decryption diverges. This is the one change that would break the static pass.
2. **Virtualise the loader.** It is still readable prose (V17); the whole scheme is legible in
   one sitting.
3. **Don't ship secrets in constants** (N/A for this test payload, critical for real ones).
4. Cipher strength went the wrong way — 3 rounds is weaker than 6 and buys nothing while V2
   holds. Restore rounds only after V2 is addressed, or it is wasted work.
