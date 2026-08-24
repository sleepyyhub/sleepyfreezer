-- Head-to-head between two variants, alternating rounds.
-- Edit the pair below, or run tools/duel.sh which rewrites it.
--
--   luau luck/bench/duel.luau

local H = require("./harness")

local A = "solo"
local B = "current"
local ROUNDS = 21

local winner = H.duel(A, B, ROUNDS)
print(("\n  faster: %s\n"):format(winner))
