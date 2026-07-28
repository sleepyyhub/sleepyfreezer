--!strict
-- stress: closures over loop vars, pcall, varargs forwarding, string funcs, recursion
local closures = {}
for i = 1, 3 do
	closures[i] = function()
		return i
	end
end
print(closures[1](), closures[2](), closures[3]())

-- pcall and error
local ok, msg = pcall(function()
	error("boom")
end)
print(ok, msg:match("boom") ~= nil)

-- varargs forwarding + select
local function wrap(...)
	local n = select("#", ...)
	return n, ...
end
print(wrap("a", "b", "c"))

-- table.pack/unpack
local packed = table.pack(10, 20, 30)
print(packed.n, table.unpack(packed))

-- string.format and gsub with a function replacement
local formatted = string.format("%d-%s-%.2f", 7, "x", 3.14159)
print(formatted)
local shouted = string.gsub("hello world", "%w+", function(w)
	return w:upper()
end)
print(shouted)

-- nested tables with methods, self-reference
local Node = {}
Node.__index = Node
function Node.new(v)
	return setmetatable({ value = v, kids = {} }, Node)
end
function Node:add(child)
	table.insert(self.kids, child)
	return self
end
function Node:sum()
	local s = self.value
	for _, k in self.kids do
		s += k:sum()
	end
	return s
end
local root = Node.new(1):add(Node.new(2):add(Node.new(4))):add(Node.new(3))
print(root:sum())

-- and/or chains, ternary emulation, numeric edge
local function clamp(x, lo, hi)
	return (x < lo and lo) or (x > hi and hi) or x
end
print(clamp(5, 0, 10), clamp(-3, 0, 10), clamp(99, 0, 10))
