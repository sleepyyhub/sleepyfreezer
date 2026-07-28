--!strict
-- OOP with metatables, methods, closures, varargs, multiple returns
local Account = {}
Account.__index = Account

export type Account = {
	balance: number,
	owner: string,
}

function Account.new(owner: string, initial: number?): Account
	local self = setmetatable({}, Account)
	self.owner = owner
	self.balance = initial or 0
	return self
end

function Account:deposit(amount: number)
	self.balance += amount
	return self.balance
end

function Account:withdraw(amount: number): (boolean, number)
	if amount > self.balance then
		return false, self.balance
	end
	self.balance -= amount
	return true, self.balance
end

local a = Account.new("alice", 100)
a:deposit(50)
local ok, bal = a:withdraw(30)
print(a.owner, ok, bal)

-- closures / upvalues
local function counter(start: number)
	local n = start
	return function()
		n += 1
		return n
	end
end
local c = counter(10)
print(c(), c(), c())

-- varargs and select
local function sumAll(...: number): number
	local s = 0
	for _, v in { ... } do
		s += v
	end
	return s
end
print(sumAll(1, 2, 3, 4, 5), select("#", 1, 2, 3))

-- multiple assignment and swap
local x, y, z = 1, 2, 3
x, y = y, x
print(x, y, z)

-- string library and casts
local raw = "Hello, World"
print(raw:upper(), raw:lower(), raw:sub(1, 5), #raw)
local n = tonumber("42") :: number
print(n * 2)
