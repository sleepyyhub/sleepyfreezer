--!strict
-- Junk.luau — inject semantically inert noise: unused local declarations and
-- opaque dead branches guarded by a variable-based always-false predicate
-- (so a linter cannot fold them away as trivially constant).
-- Runs after renaming, so its generated names are already final and opaque.

local Junk = {}

local function num(n: number): any
	return { kind = "Number", raw = tostring(n) }
end

-- A junk statement: `local <fresh> = <rndExpr>` (never referenced).
local function junkLocal(gen: any, rng: () -> number): any
	local a = math.floor(rng() * 1000000)
	local b = 1 + math.floor(rng() * 999)
	local expr
	local pick = math.floor(rng() * 3)
	if pick == 0 then
		expr = num(a)
	elseif pick == 1 then
		expr = { kind = "Binop", op = "*", lhs = num(a), rhs = num(b) }
	else
		expr = { kind = "Binop", op = "+", lhs = num(a), rhs = num(b) }
	end
	return { kind = "LocalAssign", names = { gen:next() }, exprs = { expr } }
end

-- A dead branch: declares a fresh local set to R, then `if v ~= R then <junk> end`
-- which never executes (v == R), but the guard reads a variable so it survives
-- constant-folding lint passes.
local function deadBranch(gen: any, rng: () -> number): { any }
	local r = math.floor(rng() * 1000000)
	local vName = gen:next()
	local decl = { kind = "LocalAssign", names = { vName }, exprs = { num(r) } }
	local body = { kind = "Block", stmts = { junkLocal(gen, rng) } }
	local guard = {
		kind = "Binop", op = "~=",
		lhs = { kind = "Name", name = vName },
		rhs = num(r),
	}
	local iff = { kind = "If", clauses = { { cond = guard, body = body } } }
	return { decl, iff }
end

local processBlock: (block: any, gen: any, rng: () -> number, density: number) -> ()

local function processExpr(node: any, gen: any, rng: () -> number, density: number)
	local k = node.kind
	if k == "Function" then
		processBlock(node.body, gen, rng, density)
	elseif k == "Paren" then processExpr(node.expr, gen, rng, density)
	elseif k == "Field" or k == "Index" then
		processExpr(node.obj, gen, rng, density)
		if node.index then processExpr(node.index, gen, rng, density) end
	elseif k == "Call" then
		processExpr(node.func, gen, rng, density)
		for _, a in node.args do processExpr(a, gen, rng, density) end
	elseif k == "MethodCall" then
		processExpr(node.obj, gen, rng, density)
		for _, a in node.args do processExpr(a, gen, rng, density) end
	elseif k == "Table" then
		for _, f in node.fields do
			if f.type == "key" then processExpr(f.key, gen, rng, density) end
			processExpr(f.value, gen, rng, density)
		end
	elseif k == "Binop" then
		processExpr(node.lhs, gen, rng, density)
		processExpr(node.rhs, gen, rng, density)
	elseif k == "Unop" then
		processExpr(node.operand, gen, rng, density)
	elseif k == "IfExpr" then
		for _, cl in node.clauses do
			processExpr(cl.cond, gen, rng, density)
			processExpr(cl.value, gen, rng, density)
		end
		processExpr(node.elseValue, gen, rng, density)
	end
end

-- Recurse into any nested blocks of a statement (so junk reaches inner scopes),
-- and into function-expression bodies inside its expressions.
local function recurseStat(st: any, gen: any, rng: () -> number, density: number)
	local k = st.kind
	if k == "LocalFunction" or k == "FunctionDecl" then
		processBlock(st.func.body, gen, rng, density)
	elseif k == "Do" then
		processBlock(st.body, gen, rng, density)
	elseif k == "While" then
		processExpr(st.cond, gen, rng, density)
		processBlock(st.body, gen, rng, density)
	elseif k == "Repeat" then
		processBlock(st.body, gen, rng, density)
		processExpr(st.cond, gen, rng, density)
	elseif k == "If" then
		for _, cl in st.clauses do
			if cl.cond ~= nil then processExpr(cl.cond, gen, rng, density) end
			processBlock(cl.body, gen, rng, density)
		end
	elseif k == "NumericFor" or k == "GenericFor" then
		processBlock(st.body, gen, rng, density)
		-- also walk control exprs for nested function literals
		if st.start then processExpr(st.start, gen, rng, density) end
		if st.limit then processExpr(st.limit, gen, rng, density) end
		if st.step then processExpr(st.step, gen, rng, density) end
		if st.exprs then for _, e in st.exprs do processExpr(e, gen, rng, density) end end
	elseif k == "LocalAssign" then
		for _, e in st.exprs do processExpr(e, gen, rng, density) end
	elseif k == "Assign" then
		for _, e in st.exprs do processExpr(e, gen, rng, density) end
	elseif k == "CompoundAssign" then
		processExpr(st.expr, gen, rng, density)
	elseif k == "CallStat" then
		processExpr(st.call, gen, rng, density)
	elseif k == "Return" then
		for _, e in st.exprs do processExpr(e, gen, rng, density) end
	end
end

function processBlock(block: any, gen: any, rng: () -> number, density: number)
	local newStmts = {}
	for _, st in block.stmts do
		-- First recurse into the statement's inner blocks / function bodies.
		recurseStat(st, gen, rng, density)
		-- Maybe insert junk before this statement.
		if rng() < density then
			if rng() < 0.4 then
				for _, j in deadBranch(gen, rng) do table.insert(newStmts, j) end
			else
				table.insert(newStmts, junkLocal(gen, rng))
			end
		end
		table.insert(newStmts, st)
	end
	block.stmts = newStmts
end

function Junk.apply(block: any, gen: any, rng: () -> number)
	processBlock(block, gen, rng, 0.35)
end

return Junk
