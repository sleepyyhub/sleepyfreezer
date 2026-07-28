--!strict
-- control-flow + upvalue hazards for the VM
-- multi-level nested upvalues
local function outer(a)
	local function middle(b)
		local function inner(c)
			return a + b + c
		end
		return inner
	end
	return middle
end
print(outer(100)(20)(3))

-- break out of nested loops with a flag
local found = nil
for i = 1, 5 do
	for j = 1, 5 do
		if i * j == 12 then
			found = { i, j }
			break
		end
	end
	if found then break end
end
print(found[1], found[2])

-- continue skipping, accumulate
local evens = {}
for i = 1, 10 do
	if i % 2 ~= 0 then continue end
	table.insert(evens, i)
end
print(table.concat(evens, ","))

-- repeat/until reading a local declared in the body
local k = 0
repeat
	local doubled = k * 2
	k += 1
until doubled >= 8
print("k stopped at", k)

-- while with compound condition and early accumulation
local n, acc = 1, 0
while n <= 100 and acc < 50 do
	acc += n
	n += 1
end
print("acc,n =", acc, n)

-- closures sharing one upvalue (get/set pair)
local function makeCounter()
	local count = 0
	local function get() return count end
	local function inc() count += 1 end
	return get, inc
end
local get, inc = makeCounter()
inc(); inc(); inc()
print("counter =", get())

-- multiple assignment with function returning multiple values
local function minmax(t)
	local lo, hi = t[1], t[1]
	for _, v in t do
		if v < lo then lo = v end
		if v > hi then hi = v end
	end
	return lo, hi
end
local lo, hi = minmax({ 5, 2, 9, 1, 7 })
print("min,max =", lo, hi)
