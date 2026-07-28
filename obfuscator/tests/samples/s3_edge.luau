--!strict
-- edge cases: numeric formats, operator precedence, nested tables, generics
local hex = 0xFF
local hexsep = 0xFF_FF
local bin = 0b1010
local float = 3.14e2
local small = .5
local big = 1_000_000

print(hex, hexsep, bin, float, small, big)

-- precedence: should be 1 + (2*3) ^ 2 handled correctly, and concat right-assoc
local p = 1 + 2 * 3 ^ 2 - 4 / 2
print(p)
local s = 1 .. 2 .. 3
print(s)
print(not true and false or true)
print(-2 ^ 2) -- -(2^2) = -4 in Lua

-- nested tables and mixed keys
local cfg = {
	name = "root",
	children = {
		{ id = 1, tags = { "a", "b" } },
		{ id = 2, tags = { "c" } },
	},
	[true] = "yes",
	["complex key"] = 99,
}
print(cfg.name, cfg.children[1].id, cfg.children[1].tags[2], cfg[true], cfg["complex key"])

-- generic function with type params
local function identity<T>(v: T): T
	return v
end
print(identity(5), identity("hi"))

-- long string and escapes
local long = [[line1
line2 with ]] .. [==[nested ]] bracket]==]
print(long)
local esc = "tab\there\nnewline\65\x42"
print(esc)

-- and/or as values
local default = nil
local val = default or "fallback"
print(val)

-- ternary-ish and continue in loop
local acc = {}
for i = 1, 10 do
	if i % 2 == 0 then
		continue
	end
	table.insert(acc, i)
end
print(table.concat(acc, ","))
