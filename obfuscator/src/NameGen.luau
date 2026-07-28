--!strict
-- NameGen.luau — deterministic generator of fresh, opaque identifiers that are
-- guaranteed not to collide with any name already present in the program.

local NameGen = {}
NameGen.__index = NameGen

export type NameGen = typeof(setmetatable({} :: {
	reserved: { [string]: boolean },
	counter: number,
	rng: () -> number,
	alphabet: { string },
}, NameGen))

-- A tiny deterministic PRNG (LCG) so output is reproducible from a seed.
local function makeRng(seed: number): () -> number
	local state = (seed % 2147483647)
	if state <= 0 then state += 2147483646 end
	return function(): number
		state = (state * 16807) % 2147483647
		return state / 2147483647
	end
end

NameGen.makeRng = makeRng

-- Identifier characters that read as visually confusable (I, l, 1, O, 0, _).
local CONFUSABLE = { "I", "l", "_" }
local CONFUSABLE_TAIL = { "I", "l", "_", "1", "0", "O" }

function NameGen.new(reserved: { [string]: boolean }, seed: number): NameGen
	local self = setmetatable({
		reserved = reserved,
		counter = 0,
		rng = makeRng(seed),
		alphabet = CONFUSABLE,
	}, NameGen)
	return self
end

-- Returns a fresh identifier of confusable characters, never previously issued
-- and never present in the reserved set.
function NameGen.next(self: NameGen): string
	while true do
		self.counter += 1
		local len = 6 + math.floor(self.rng() * 8) -- 6..13 chars
		local chars = { CONFUSABLE[1 + math.floor(self.rng() * #CONFUSABLE)] }
		for _ = 2, len do
			table.insert(chars, CONFUSABLE_TAIL[1 + math.floor(self.rng() * #CONFUSABLE_TAIL)])
		end
		local name = table.concat(chars)
		if not self.reserved[name] then
			self.reserved[name] = true -- reserve so it is never reused
			return name
		end
	end
end

return NameGen
