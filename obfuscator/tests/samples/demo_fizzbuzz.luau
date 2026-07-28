local function classify(n)
	if n % 15 == 0 then return "FizzBuzz"
	elseif n % 3 == 0 then return "Fizz"
	elseif n % 5 == 0 then return "Buzz"
	end
	return tostring(n)
end

local results = {}
for i = 1, 15 do
	results[i] = classify(i)
end
print(table.concat(results, " "))

local scores = { alice = 88, bob = 72, cara = 95 }
local best, bestName = -1, "?"
for name, s in scores do
	if s > best then best, bestName = s, name end
end
print(("top: %s (%d)"):format(bestName, best))
