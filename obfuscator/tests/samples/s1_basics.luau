--!strict
-- basics: locals, arithmetic, strings, tables, loops, functions
local function fib(n: number): number
	if n < 2 then return n end
	return fib(n - 1) + fib(n - 2)
end

local total = 0
for i = 1, 10 do
	total += fib(i)
end

local t = { a = 1, b = 2, [3] = "three", "list1", "list2" }
local sum = 0
for k, v in pairs(t) do
	if type(v) == "number" then
		sum += v
	end
end

local name = "world"
local greeting = `hello {name}, sum={sum}, total={total}`
print(greeting)
print(#t, t.a + t.b, t[3])

local mt = { x = 10 }
function mt.getX(self)
	return self.x
end
print(mt.getX(mt))

local i = 0
while i < 3 do
	i += 1
end
repeat
	i -= 1
until i <= 0
print("i is", i)

local floor = 17 // 5
local pow = 2 ^ 10
local concat = "a" .. "b" .. "c" .. tostring(floor) .. tostring(pow)
print(concat)
