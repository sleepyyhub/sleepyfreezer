--!strict
-- Compiler.luau — compile a parsed Luau chunk to Clovyre VM protos.
--
-- All locals are boxed in single-element cells, so closures and per-iteration
-- loop-variable capture are correct by construction (each declaration makes a
-- fresh cell). Registers are 0-based; constants and protos are 1-based.
--
-- Any construct the VM cannot express raises { clovyre_unsupported = <reason> },
-- which the pipeline catches to fall back to the source-level obfuscator.

local Opcodes = require("./Opcodes")
local OP = Opcodes.NUM

local Compiler = {}

local function unsupported(reason: string): never
	error({ clovyre_unsupported = reason }, 0)
end

-- ---------------------------------------------------------------------------
-- Number literal evaluation
-- ---------------------------------------------------------------------------
local function evalNumber(raw: string): number
	local clean = (raw:gsub("_", ""))
	local lower = clean:lower()
	if lower:sub(1, 2) == "0x" then
		if not clean:find("[%.pP]") then
			local v = tonumber(clean:sub(3), 16)
			if v == nil then unsupported("bad hex literal") end
			return v :: number
		end
		local v = tonumber(clean)
		if v == nil then unsupported("hex float literal") end
		return v :: number
	elseif lower:sub(1, 2) == "0b" then
		local body = clean:sub(3)
		if body == "" then unsupported("bad binary literal") end
		local v = 0
		for i = 1, #body do
			local d = body:sub(i, i)
			if d == "0" then v = v * 2
			elseif d == "1" then v = v * 2 + 1
			else unsupported("bad binary digit") end
		end
		return v
	end
	local v = tonumber(clean)
	if v == nil then unsupported("bad number literal") end
	return v :: number
end

-- ---------------------------------------------------------------------------
-- FuncState
-- ---------------------------------------------------------------------------
type FuncState = {
	parent: FuncState?,
	instrs: { { number } }, -- each {op,a,b,c}
	k: { any },
	kmap: { [string]: number },
	protos: { any },
	np: number,
	va: boolean,
	freereg: number,
	nactive: number,
	ms: number,
	-- active locals: array of { name, reg }, innermost last
	locals: { { name: string, reg: number } },
	blocks: { { firstlocal: number, firstreg: number } },
	loops: { { breaks: { number }, continues: { number } } },
	upvals: { { name: string, desc: { number } } },
	globals: { [string]: boolean },
}

local BINOP = {
	["+"] = "ADD", ["-"] = "SUB", ["*"] = "MUL", ["/"] = "DIV",
	["%"] = "MOD", ["^"] = "POW", ["//"] = "IDIV", [".."] = "CONCAT",
	["=="] = "EQ", ["~="] = "NE", ["<"] = "LT", ["<="] = "LE",
	[">"] = "GT", [">="] = "GE",
}

-- ---------------------------------------------------------------------------
-- Register / emit helpers
-- ---------------------------------------------------------------------------
local function updateMs(fs: FuncState)
	if fs.freereg > fs.ms then fs.ms = fs.freereg end
end

local function alloc(fs: FuncState): number
	local r = fs.freereg
	fs.freereg += 1
	updateMs(fs)
	return r
end

local function emit(fs: FuncState, op: number, a: number, b: number, c: number): number
	table.insert(fs.instrs, { op, a or 0, b or 0, c or 0 })
	return #fs.instrs - 1 -- 0-based index
end

local function pc(fs: FuncState): number
	return #fs.instrs -- index of the NEXT instruction
end

local function patchJumpHere(fs: FuncState, idx: number)
	-- set the jump at instruction `idx` to target the current pc
	local target = pc(fs)
	local off = target - (idx + 1)
	local instr = fs.instrs[idx + 1]
	-- offset slot: JMP uses a, others (JMPIF/JMPIFNOT/FOR*) use b
	if instr[1] == OP.JMP then instr[2] = off else instr[3] = off end
end

local function patchJumpTo(fs: FuncState, idx: number, target: number)
	local off = target - (idx + 1)
	local instr = fs.instrs[idx + 1]
	if instr[1] == OP.JMP then instr[2] = off else instr[3] = off end
end

local function addConst(fs: FuncState, v: any): number
	local key = (type(v) == "string" and "s:" .. v) or ("n:" .. string.format("%.17g", v))
	local existing = fs.kmap[key]
	if existing then return existing end
	table.insert(fs.k, v)
	local idx = #fs.k
	fs.kmap[key] = idx
	return idx
end

-- ---------------------------------------------------------------------------
-- Scope / locals
-- ---------------------------------------------------------------------------
local function enterBlock(fs: FuncState)
	table.insert(fs.blocks, { firstlocal = #fs.locals, firstreg = fs.nactive })
end

local function leaveBlock(fs: FuncState)
	local blk = table.remove(fs.blocks)
	-- drop locals declared in this block
	while #fs.locals > blk.firstlocal do
		table.remove(fs.locals)
	end
	fs.nactive = blk.firstreg
	fs.freereg = blk.firstreg
end

-- declare a local name occupying register `reg`; boxing is emitted by caller.
local function declareLocal(fs: FuncState, name: string, reg: number)
	table.insert(fs.locals, { name = name, reg = reg })
	if reg + 1 > fs.nactive then fs.nactive = reg + 1 end
end

local function findLocal(fs: FuncState, name: string): number?
	for i = #fs.locals, 1, -1 do
		if fs.locals[i].name == name then return fs.locals[i].reg end
	end
	return nil
end

local function findUpval(fs: FuncState, name: string): number?
	-- returns 1-based upvalue index, creating descriptors along the chain
	for i, u in fs.upvals do
		if u.name == name then return i end
	end
	local parent = fs.parent
	if parent == nil then return nil end
	local plocal = findLocal(parent, name)
	if plocal ~= nil then
		table.insert(fs.upvals, { name = name, desc = { 1, plocal } }) -- capture parent local cell
		return #fs.upvals
	end
	local pu = findUpval(parent, name)
	if pu ~= nil then
		table.insert(fs.upvals, { name = name, desc = { 0, pu - 1 } }) -- capture parent upvalue (0-based)
		return #fs.upvals
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- Forward decls
-- ---------------------------------------------------------------------------
local compileExprInto: (fs: FuncState, e: any, dest: number) -> ()
local compileBlock: (fs: FuncState, block: any) -> ()
local compileCall: (fs: FuncState, node: any, dest: number, nresults: number) -> ()
local compileFunction: (fs: FuncState, func: any, name: string?) -> number
local compileCallOrVararg: (fs: FuncState, e: any, dest: number, need: number) -> ()

local function isMultiExpr(e: any): boolean
	return e.kind == "Call" or e.kind == "MethodCall" or e.kind == "Vararg"
end

-- compile e into a fresh temp register; returns that register.
local function exprTemp(fs: FuncState, e: any): number
	local d = alloc(fs)
	compileExprInto(fs, e, d)
	fs.freereg = d + 1
	return d
end

-- compile e producing multiple values at dest (sets `top`); for multiret.
local function compileMulti(fs: FuncState, e: any, dest: number)
	if e.kind == "Call" or e.kind == "MethodCall" then
		compileCall(fs, e, dest, -1)
	elseif e.kind == "Vararg" then
		emit(fs, OP.VARARG, dest, 0, 0)
	else
		compileExprInto(fs, e, dest)
	end
end

-- ---------------------------------------------------------------------------
-- Assignment targets
-- ---------------------------------------------------------------------------
-- store the value in register `vreg` into the lvalue `target`.
local function storeTo(fs: FuncState, target: any, vreg: number)
	if target.kind == "Name" then
		local rl = findLocal(fs, target.name)
		if rl ~= nil then
			emit(fs, OP.CELLSET, rl, vreg, 0)
			return
		end
		local u = findUpval(fs, target.name)
		if u ~= nil then
			emit(fs, OP.SETUPVAL, vreg, u, 0)
			return
		end
		fs.globals[target.name] = true
		local kc = addConst(fs, target.name)
		emit(fs, OP.SETGLOBAL, vreg, kc, 0)
	elseif target.kind == "Field" then
		local ro = exprTemp(fs, target.obj)
		local kr = alloc(fs)
		emit(fs, OP.LOADK, kr, addConst(fs, target.name), 0)
		emit(fs, OP.SETTABLE, ro, kr, vreg)
		fs.freereg = fs.nactive
	elseif target.kind == "Index" then
		local ro = exprTemp(fs, target.obj)
		local rk = exprTemp(fs, target.index)
		emit(fs, OP.SETTABLE, ro, rk, vreg)
		fs.freereg = fs.nactive
	else
		unsupported("assignment target " .. tostring(target.kind))
	end
end

-- ---------------------------------------------------------------------------
-- Calls
-- ---------------------------------------------------------------------------
function compileCall(fs: FuncState, node: any, dest: number, nresults: number)
	local isMethod = node.kind == "MethodCall"
	local argStart
	local selfCount = 0
	if isMethod then
		compileExprInto(fs, node.obj, dest + 1) -- self
		emit(fs, OP.LOADK, dest, addConst(fs, node.method), 0)
		emit(fs, OP.GETTABLE, dest, dest + 1, dest) -- R[dest]=self[method]
		argStart = dest + 2
		selfCount = 1
	else
		compileExprInto(fs, node.func, dest)
		argStart = dest + 1
	end
	fs.freereg = argStart

	local args = node.args
	local nargs = #args
	local B
	if nargs == 0 then
		B = selfCount + 1
	else
		for i = 1, nargs - 1 do
			local r = argStart + i - 1
			compileExprInto(fs, args[i], r)
			fs.freereg = r + 1
		end
		local last = args[nargs]
		local lastReg = argStart + nargs - 1
		if isMultiExpr(last) then
			compileMulti(fs, last, lastReg)
			B = 0
		else
			compileExprInto(fs, last, lastReg)
			fs.freereg = lastReg + 1
			B = selfCount + nargs + 1
		end
	end
	local C = if nresults == -1 then 0 else nresults + 1
	emit(fs, OP.CALL, dest, B, C)
	if nresults ~= -1 then
		fs.freereg = dest + math.max(nresults, 0)
	end
end

-- ---------------------------------------------------------------------------
-- Expressions
-- ---------------------------------------------------------------------------
local function compileTable(fs: FuncState, node: any, dest: number)
	emit(fs, OP.NEWTABLE, dest, 0, 0)
	fs.freereg = dest + 1
	local arrayIndex = 0
	local fields = node.fields
	local n = #fields
	for i, f in fields do
		if f.type == "list" then
			if i == n and isMultiExpr(f.value) then
				fs.freereg = dest + 1
				compileMulti(fs, f.value, dest + 1)
				emit(fs, OP.SETLIST, dest, 0, arrayIndex)
			else
				local vr = exprTemp(fs, f.value)
				local kr = alloc(fs)
				emit(fs, OP.LOADK, kr, addConst(fs, arrayIndex + 1), 0)
				emit(fs, OP.SETTABLE, dest, kr, vr)
				arrayIndex += 1
			end
		elseif f.type == "rec" then
			local kr = alloc(fs)
			emit(fs, OP.LOADK, kr, addConst(fs, f.name), 0)
			local vr = exprTemp(fs, f.value)
			emit(fs, OP.SETTABLE, dest, kr, vr)
		else -- key
			local kr = exprTemp(fs, f.key)
			local vr = exprTemp(fs, f.value)
			emit(fs, OP.SETTABLE, dest, kr, vr)
		end
		fs.freereg = dest + 1
	end
end

local function compileBinop(fs: FuncState, node: any, dest: number)
	local op = node.op
	if op == "and" or op == "or" then
		compileExprInto(fs, node.lhs, dest)
		local jmp
		if op == "and" then
			jmp = emit(fs, OP.JMPIFNOT, dest, 0, 0)
		else
			jmp = emit(fs, OP.JMPIF, dest, 0, 0)
		end
		compileExprInto(fs, node.rhs, dest)
		patchJumpHere(fs, jmp)
		fs.freereg = dest + 1
		return
	end
	local mapped = BINOP[op]
	if mapped == nil then unsupported("binop " .. op) end
	local rb = alloc(fs)
	compileExprInto(fs, node.lhs, rb)
	fs.freereg = rb + 1
	local rc = alloc(fs)
	compileExprInto(fs, node.rhs, rc)
	emit(fs, OP[mapped], dest, rb, rc)
	fs.freereg = dest + 1
end

function compileExprInto(fs: FuncState, e: any, dest: number)
	if fs.freereg < dest + 1 then fs.freereg = dest + 1 end
	updateMs(fs)
	local k = e.kind
	if k == "Nil" then
		emit(fs, OP.LOADNIL, dest, 0, 0)
	elseif k == "True" then
		emit(fs, OP.LOADBOOL, dest, 1, 0)
	elseif k == "False" then
		emit(fs, OP.LOADBOOL, dest, 0, 0)
	elseif k == "Number" then
		emit(fs, OP.LOADK, dest, addConst(fs, evalNumber(e.raw)), 0)
	elseif k == "String" then
		emit(fs, OP.LOADK, dest, addConst(fs, e.value), 0)
	elseif k == "Vararg" then
		emit(fs, OP.VARARG, dest, 2, 0) -- exactly one value
	elseif k == "Name" then
		local rl = findLocal(fs, e.name)
		if rl ~= nil then
			emit(fs, OP.CELLGET, dest, rl, 0)
		else
			local u = findUpval(fs, e.name)
			if u ~= nil then
				emit(fs, OP.GETUPVAL, dest, u, 0)
			else
				fs.globals[e.name] = true
				emit(fs, OP.GETGLOBAL, dest, addConst(fs, e.name), 0)
			end
		end
	elseif k == "Paren" then
		compileExprInto(fs, e.expr, dest)
	elseif k == "Field" then
		compileExprInto(fs, e.obj, dest)
		local kr = alloc(fs)
		emit(fs, OP.LOADK, kr, addConst(fs, e.name), 0)
		emit(fs, OP.GETTABLE, dest, dest, kr)
	elseif k == "Index" then
		compileExprInto(fs, e.obj, dest)
		local rk = alloc(fs)
		compileExprInto(fs, e.index, rk)
		emit(fs, OP.GETTABLE, dest, dest, rk)
	elseif k == "Call" or k == "MethodCall" then
		compileCall(fs, e, dest, 1)
	elseif k == "Function" then
		local pidx = compileFunction(fs, e, nil)
		emit(fs, OP.CLOSURE, dest, pidx, 0)
	elseif k == "Table" then
		compileTable(fs, e, dest)
	elseif k == "Binop" then
		compileBinop(fs, e, dest)
	elseif k == "IfExpr" then
		local endJumps = {}
		for _, cl in e.clauses do
			local cr = alloc(fs)
			compileExprInto(fs, cl.cond, cr)
			fs.freereg = dest + 1
			local skip = emit(fs, OP.JMPIFNOT, cr, 0, 0)
			compileExprInto(fs, cl.value, dest)
			fs.freereg = dest + 1
			table.insert(endJumps, emit(fs, OP.JMP, 0, 0, 0))
			patchJumpHere(fs, skip)
		end
		compileExprInto(fs, e.elseValue, dest)
		for _, j in endJumps do patchJumpHere(fs, j) end
	elseif k == "Unop" then
		local rb = alloc(fs)
		compileExprInto(fs, e.operand, rb)
		if e.op == "not" then emit(fs, OP.NOT, dest, rb, 0)
		elseif e.op == "-" then emit(fs, OP.UNM, dest, rb, 0)
		elseif e.op == "#" then emit(fs, OP.LEN, dest, rb, 0)
		else unsupported("unop " .. e.op) end
	else
		unsupported("expr " .. tostring(k))
	end
	fs.freereg = dest + 1
end

-- ---------------------------------------------------------------------------
-- Statements
-- ---------------------------------------------------------------------------
-- Evaluate `exprs` producing exactly `want` values into registers base..base+want-1.
local function compileExprList(fs: FuncState, exprs: { any }, base: number, want: number)
	local n = #exprs
	if n == 0 then
		for i = 0, want - 1 do emit(fs, OP.LOADNIL, base + i, 0, 0) end
		fs.freereg = base + want
		return
	end
	for i = 1, n - 1 do
		local r = base + i - 1
		if r < base + want then
			compileExprInto(fs, exprs[i], r)
			fs.freereg = r + 1
		else
			-- extra expression: still evaluate for side effects
			local t = alloc(fs)
			compileExprInto(fs, exprs[i], t)
			fs.freereg = fs.nactive < base + want and base + want or fs.freereg
		end
	end
	local last = exprs[n]
	local lastReg = base + n - 1
	if isMultiExpr(last) and n <= want then
		-- expand to fill remaining wanted slots
		local need = want - (n - 1)
		compileCallOrVararg(fs, last, lastReg, need)
	else
		if n <= want then
			compileExprInto(fs, last, lastReg)
			-- pad remaining with nil
			for r = lastReg + 1, base + want - 1 do
				emit(fs, OP.LOADNIL, r, 0, 0)
			end
		else
			-- more expressions than wanted: evaluate last for side effect into scratch
			local t = alloc(fs)
			compileExprInto(fs, last, t)
		end
	end
	fs.freereg = base + want
end

-- helper used above: compile a call/vararg wanting exactly `need` results
function compileCallOrVararg(fs: FuncState, e: any, dest: number, need: number)
	if e.kind == "Vararg" then
		emit(fs, OP.VARARG, dest, need + 1, 0)
	else
		compileCall(fs, e, dest, need)
	end
end

local function compileLocalAssign(fs: FuncState, st: any)
	local names = st.names
	local nn = #names
	local base = fs.freereg
	-- evaluate RHS into base..base+nn-1
	compileExprList(fs, st.exprs, base, nn)
	-- box each and declare
	for i = 1, nn do
		local reg = base + i - 1
		emit(fs, OP.BOX, reg, 0, 0)
		declareLocal(fs, names[i], reg)
	end
	fs.nactive = base + nn
	fs.freereg = fs.nactive
end

local function compileAssign(fs: FuncState, st: any)
	local targets = st.targets
	local nt = #targets
	if nt == 1 and not isMultiExpr(st.exprs[1] or {}) and #st.exprs == 1 then
		-- common fast path: single target = single value
		local vr = exprTemp(fs, st.exprs[1])
		storeTo(fs, targets[1], vr)
		fs.freereg = fs.nactive
		return
	end
	local base = fs.freereg
	compileExprList(fs, st.exprs, base, nt)
	for i = 1, nt do
		storeTo(fs, targets[i], base + i - 1)
	end
	fs.freereg = fs.nactive
end

local function compileCompound(fs: FuncState, st: any)
	local target = st.target
	local mapped = BINOP[st.op]
	if mapped == nil then unsupported("compound op " .. st.op) end
	if target.kind == "Name" then
		local cur = alloc(fs)
		compileExprInto(fs, target, cur)
		local rhs = alloc(fs)
		compileExprInto(fs, st.expr, rhs)
		emit(fs, OP[mapped], cur, cur, rhs)
		storeTo(fs, target, cur)
	elseif target.kind == "Field" or target.kind == "Index" then
		local ro = exprTemp(fs, target.obj)
		local rk
		if target.kind == "Field" then
			rk = alloc(fs)
			emit(fs, OP.LOADK, rk, addConst(fs, target.name), 0)
		else
			rk = exprTemp(fs, target.index)
		end
		local cur = alloc(fs)
		emit(fs, OP.GETTABLE, cur, ro, rk)
		local rhs = alloc(fs)
		compileExprInto(fs, st.expr, rhs)
		emit(fs, OP[mapped], cur, cur, rhs)
		emit(fs, OP.SETTABLE, ro, rk, cur)
	else
		unsupported("compound target")
	end
	fs.freereg = fs.nactive
end

local function compileReturn(fs: FuncState, st: any)
	local exprs = st.exprs
	local n = #exprs
	if n == 0 then
		emit(fs, OP.RETURN, 0, 1, 0)
		return
	end
	local base = fs.freereg
	for i = 1, n - 1 do
		compileExprInto(fs, exprs[i], base + i - 1)
		fs.freereg = base + i
	end
	local last = exprs[n]
	local lastReg = base + n - 1
	if isMultiExpr(last) then
		compileMulti(fs, last, lastReg)
		emit(fs, OP.RETURN, base, 0, 0)
	else
		compileExprInto(fs, last, lastReg)
		emit(fs, OP.RETURN, base, n + 1, 0)
	end
	fs.freereg = fs.nactive
end

local function curLoop(fs: FuncState)
	return fs.loops[#fs.loops]
end

local function compileIf(fs: FuncState, st: any)
	local endJumps = {}
	for i, cl in st.clauses do
		if cl.cond ~= nil then
			local cr = alloc(fs)
			compileExprInto(fs, cl.cond, cr)
			fs.freereg = fs.nactive
			local skip = emit(fs, OP.JMPIFNOT, cr, 0, 0)
			enterBlock(fs)
			compileBlock(fs, cl.body)
			leaveBlock(fs)
			if i < #st.clauses then
				table.insert(endJumps, emit(fs, OP.JMP, 0, 0, 0))
			end
			patchJumpHere(fs, skip)
		else
			enterBlock(fs)
			compileBlock(fs, cl.body)
			leaveBlock(fs)
		end
	end
	for _, j in endJumps do patchJumpHere(fs, j) end
end

local function compileWhile(fs: FuncState, st: any)
	local top = pc(fs)
	local cr = alloc(fs)
	compileExprInto(fs, st.cond, cr)
	fs.freereg = fs.nactive
	local exit = emit(fs, OP.JMPIFNOT, cr, 0, 0)
	table.insert(fs.loops, { breaks = {}, continues = {} })
	enterBlock(fs)
	compileBlock(fs, st.body)
	leaveBlock(fs)
	local loop = table.remove(fs.loops)
	for _, j in loop.continues do patchJumpTo(fs, j, top) end
	emit(fs, OP.JMP, top - (pc(fs) + 1), 0, 0)
	patchJumpHere(fs, exit)
	for _, j in loop.breaks do patchJumpHere(fs, j) end
end

local function compileRepeat(fs: FuncState, st: any)
	local top = pc(fs)
	table.insert(fs.loops, { breaks = {}, continues = {} })
	enterBlock(fs)
	compileBlock(fs, st.body)
	-- until-cond is evaluated in the body scope (can see body locals)
	local contTarget = pc(fs)
	local cr = alloc(fs)
	compileExprInto(fs, st.cond, cr)
	local again = emit(fs, OP.JMPIFNOT, cr, 0, 0)
	patchJumpTo(fs, again, top)
	leaveBlock(fs)
	local loop = table.remove(fs.loops)
	for _, j in loop.continues do patchJumpTo(fs, j, contTarget) end
	for _, j in loop.breaks do patchJumpHere(fs, j) end
end

local function compileNumericFor(fs: FuncState, st: any)
	local base = fs.nactive
	fs.freereg = base
	local ri = alloc(fs) -- idx (control)
	compileExprInto(fs, st.start, ri)
	local rl = alloc(fs)
	compileExprInto(fs, st.limit, rl)
	local rs = alloc(fs)
	if st.step ~= nil then
		compileExprInto(fs, st.step, rs)
	else
		emit(fs, OP.LOADK, rs, addConst(fs, 1), 0)
	end
	local rv = alloc(fs) -- loop var (raw), base+3
	fs.nactive = base + 4
	fs.freereg = base + 4

	local prep = emit(fs, OP.FORPREP, base, 0, 0)
	local bodyStart = pc(fs)
	table.insert(fs.loops, { breaks = {}, continues = {} })
	enterBlock(fs)
	emit(fs, OP.BOX, rv, 0, 0) -- fresh cell each iteration
	declareLocal(fs, st.var, rv)
	compileBlock(fs, st.body)
	leaveBlock(fs)
	local loop = table.remove(fs.loops)
	local forloop = pc(fs)
	for _, j in loop.continues do patchJumpTo(fs, j, forloop) end
	emit(fs, OP.FORLOOP, base, bodyStart - (forloop + 1), 0)
	patchJumpTo(fs, prep, forloop)
	for _, j in loop.breaks do patchJumpHere(fs, j) end
	fs.nactive = base
	fs.freereg = base
end

local function compileGenericFor(fs: FuncState, st: any)
	local base = fs.nactive
	fs.freereg = base
	-- iterator setup: exactly 3 values (func, state, control) at base..base+2
	compileExprList(fs, st.exprs, base, 3)
	local m = #st.names
	fs.nactive = base + 3 + m
	fs.freereg = base + 3 + m

	local prep = emit(fs, OP.JMP, 0, 0, 0)
	local bodyStart = pc(fs)
	table.insert(fs.loops, { breaks = {}, continues = {} })
	enterBlock(fs)
	for i = 1, m do
		local reg = base + 3 + i - 1
		emit(fs, OP.BOX, reg, 0, 0)
		declareLocal(fs, st.names[i], reg)
	end
	compileBlock(fs, st.body)
	leaveBlock(fs)
	local loop = table.remove(fs.loops)
	local tforcall = pc(fs)
	for _, j in loop.continues do patchJumpTo(fs, j, tforcall) end
	emit(fs, OP.TFORCALL, base, 0, m)
	local tforloop = pc(fs)
	emit(fs, OP.TFORLOOP, base, bodyStart - (tforloop + 1), 0)
	patchJumpTo(fs, prep, tforcall)
	for _, j in loop.breaks do patchJumpHere(fs, j) end
	fs.nactive = base
	fs.freereg = base
end

local function compileLocalFunction(fs: FuncState, st: any)
	-- name is visible to its own body (recursion): declare first, then compile
	local reg = fs.freereg
	emit(fs, OP.NEWCELL, reg, 0, 0)
	declareLocal(fs, st.name, reg)
	fs.nactive = reg + 1
	fs.freereg = reg + 1
	local tmp = alloc(fs)
	local pidx = compileFunction(fs, st.func, st.name)
	emit(fs, OP.CLOSURE, tmp, pidx, 0)
	emit(fs, OP.CELLSET, reg, tmp, 0)
	fs.freereg = fs.nactive
end

local function compileFunctionDecl(fs: FuncState, st: any)
	local func = st.func
	local target = st.target
	if st.method ~= nil then
		-- `function a:b(...)` => a.b = function(self, ...)
		local params = { "self" }
		for _, p in func.params do table.insert(params, p) end
		func = { kind = "Function", params = params, isVararg = func.isVararg, body = func.body }
		target = { kind = "Field", obj = st.target, name = st.method }
	end
	local tmp = alloc(fs)
	local pidx = compileFunction(fs, func, nil)
	emit(fs, OP.CLOSURE, tmp, pidx, 0)
	storeTo(fs, target, tmp)
	fs.freereg = fs.nactive
end

local function compileStat(fs: FuncState, st: any)
	local k = st.kind
	if k == "LocalAssign" then compileLocalAssign(fs, st)
	elseif k == "Assign" then compileAssign(fs, st)
	elseif k == "CompoundAssign" then compileCompound(fs, st)
	elseif k == "CallStat" then
		local dest = fs.freereg
		compileCall(fs, st.call, dest, 0)
		fs.freereg = fs.nactive
	elseif k == "Do" then
		enterBlock(fs); compileBlock(fs, st.body); leaveBlock(fs)
	elseif k == "If" then compileIf(fs, st)
	elseif k == "While" then compileWhile(fs, st)
	elseif k == "Repeat" then compileRepeat(fs, st)
	elseif k == "NumericFor" then compileNumericFor(fs, st)
	elseif k == "GenericFor" then compileGenericFor(fs, st)
	elseif k == "Return" then compileReturn(fs, st)
	elseif k == "LocalFunction" then compileLocalFunction(fs, st)
	elseif k == "FunctionDecl" then compileFunctionDecl(fs, st)
	elseif k == "Break" then
		if #fs.loops == 0 then unsupported("break outside loop") end
		table.insert(curLoop(fs).breaks, emit(fs, OP.JMP, 0, 0, 0))
	elseif k == "Continue" then
		if #fs.loops == 0 then unsupported("continue outside loop") end
		table.insert(curLoop(fs).continues, emit(fs, OP.JMP, 0, 0, 0))
	else
		unsupported("stat " .. tostring(k))
	end
end

function compileBlock(fs: FuncState, block: any)
	for _, st in block.stmts do
		compileStat(fs, st)
		fs.freereg = fs.nactive
	end
end

-- ---------------------------------------------------------------------------
-- Function compilation
-- ---------------------------------------------------------------------------
local function newFuncState(parent: FuncState?, rootGlobals: { [string]: boolean }): FuncState
	return {
		parent = parent,
		instrs = {}, k = {}, kmap = {}, protos = {},
		np = 0, va = false, freereg = 0, nactive = 0, ms = 0,
		locals = {}, blocks = {}, loops = {}, upvals = {},
		globals = rootGlobals,
	}
end

local function finalizeProto(fs: FuncState): any
	-- ensure a trailing return
	local last = fs.instrs[#fs.instrs]
	if last == nil or last[1] ~= OP.RETURN then
		emit(fs, OP.RETURN, 0, 1, 0)
	end
	local code = {}
	for _, ins in fs.instrs do
		code[#code + 1] = ins[1]
		code[#code + 1] = ins[2]
		code[#code + 1] = ins[3]
		code[#code + 1] = ins[4]
	end
	local uv = {}
	for _, u in fs.upvals do uv[#uv + 1] = u.desc end
	return {
		code = code, k = fs.k, protos = fs.protos,
		np = fs.np, va = fs.va, ms = fs.ms + 2, uv = uv,
	}
end

-- compile a Function node under parent `fs`; returns 1-based proto index in fs.protos
function compileFunction(fs: FuncState, func: any, name: string?): number
	local child = newFuncState(fs, fs.globals)
	child.np = #func.params
	child.va = func.isVararg
	-- params occupy registers 0..np-1; box each in place
	for i, p in func.params do
		local reg = i - 1
		emit(child, OP.BOX, reg, 0, 0)
		declareLocal(child, p, reg)
	end
	-- implicit self for methods is already a regular param in the AST? No: method
	-- decls carry `method` separately. compileFunctionDecl handles self via param.
	child.nactive = child.np
	child.freereg = child.np
	compileBlock(child, func.body)
	local proto = finalizeProto(child)
	table.insert(fs.protos, proto)
	return #fs.protos
end

-- compile the top-level chunk; returns { proto = mainProto, globals = {names} }
function Compiler.compile(chunk: any): { proto: any, globals: { string } }
	local globals: { [string]: boolean } = {}
	local main = newFuncState(nil, globals)
	main.va = true -- main chunk is vararg
	compileBlock(main, chunk)
	local proto = finalizeProto(main)
	local gl = {}
	for name in globals do gl[#gl + 1] = name end
	table.sort(gl)
	return { proto = proto, globals = gl }
end

return Compiler
