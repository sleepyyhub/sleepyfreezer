2.1.0 recovered strings:
  1 'RunService'
  2 'Instance'
  3 'UDim'
  4 'function'
  5 "Clovyre Script:(internal): line 1: attempt to index nil with 'new'"
  6 'number'
  7 'print'
  8 'invalid virtual instruction'
  9 'invalid virtual package'
  10 'invalid transport bytecode'
  11 'invalid virtual constant'
  12 '#'
  13 '|w|\x9fÚw#SÒzÎ\x9ehq¿íÄ4DlD\x9aÔjX¾\x9cQ`Ó+öj1\x03Î\x90C¯\x9fö^µ"òÎùÿ\x9f¼¶O½ÙÕ,$\x0eÖ?_=a\x0fªª\x9aÁÒª'

# Clovyre 2.1.0 — quick assessment (game-master round)

Verdict: NOT Special Grade (Star 0/5). Best build yet, right idea, wrong source.

## New in 2.1.0
- Keys depend on a runtime value I000OI_ (derived from game.PlaceId) — first
  time keys are not a pure function of the file.
  - transport keystream: 760011212 + I000OI_*17021
  - payload keystream:   1441151799 + I000OI_*10002
  - instruction keys:    proto[...] + I000OI_*26262
- Added a transport/packaging layer (error "invalid transport bytecode").
- Per-instruction opcode-alias rotation (_lIl100), position-derived (static).
- String mask: (187 + 5*i + 6*idx) % 256  (still index-derived, V1).

## Why the threshold is NOT crossed
1. I000OI_ is clamped to % 1000003 -> ~20 bits (1,000,003 candidates).
   Brute-force over all candidates: ~2.4s key-derivation model; minutes with a
   full deserialize oracle, on one core.
2. Every layer has a hard structural/checksum oracle (invalid transport
   bytecode / invalid virtual package / const seals) -> confirms a guessed
   I000OI_ offline. Perfect brute-force oracle.
3. game.PlaceId is PUBLIC (in the game URL) -> for a targeted script the
   attacker computes I000OI_ directly, no brute-force needed.

Killer test: still decodable without executing (brute-force, or directly with
known PlaceId).

## To actually reach Star 0
- Runtime-bound value needs >=128 bits (drop the % 1000003 clamp).
- Remove per-layer catchable errors that confirm a guess (fail as silent
  garbage, not error()).
- Bind to something the attacker cannot read (public PlaceId fails this);
  use real runtime input / a running execution hash (the 59542 residual).
