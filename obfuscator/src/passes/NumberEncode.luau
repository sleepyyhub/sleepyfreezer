--!strict
-- NumberEncode.luau — replace integer literals with equivalent arithmetic/bitwise
-- expressions that evaluate to the same value. Non-integers and out-of-range
-- values are left untouched to guarantee exactness.

local NumberEncode = {}

local MAXINT = 2147483647 -- keep within bit32 range and clean tostring output

local function parseValue(raw: string): number?
	local clean = (raw:gsub("_", ""))
	local lower = clean:lower()
	if lower:sub(1, 2) == "0x" then
		if clean:find("[%.pP]") then return nil end -- hex float: skip
		return tonumber(clean:sub(3), 16)
	elseif lower:sub(1, 2) == "0b" then
		local body = clean:sub(3)
		if body == "" then return nil end
		local v = 0
		for k = 1, #body do
			local d = body:sub(k, k)
			if d == "0" then v = v * 2
			elseif d == "1" then v = v * 2 + 1
			else return nil end
		end
		return v
	else
		return tonumber(clean)
	end
end

local function num(n: number): any
	return { kind = "Number", raw = tostring(n) }
end

local function encode(v: number, rng: () -> number): any
	local method = math.floor(rng() * 3)
	local expr
	if method == 0 then
		local r = 1 + math.floor(rng() * 4096)
		expr = { kind = "Binop", op = "-", lhs = num(v + r), rhs = num(r) }
	elseif method == 1 then
		local a = math.floor(rng() * (v + 1))
		local b = v - a
		expr = { kind = "Binop", op = "+", lhs = num(a), rhs = num(b) }
	else
		local mask = math.floor(rng() * MAXINT)
		local x = bit32.bxor(v, mask)
		expr = {
			kind = "Call",
			func = { kind = "Field", obj = { kind = "Name", name = "bit32" }, name = "bxor" },
			args = { num(x), num(mask) },
		}
	end
	return { kind = "Paren", expr = expr }
end

local transformBlock: (block: any, rng: () -> number) -> ()

local function transformExpr(node: any, rng: () -> number): any
	local k = node.kind
	if k == "Number" then
		local v = parseValue(node.raw)
		if v ~= nil and v == math.floor(v) and v >= 0 and v <= MAXINT then
			return encode(v, rng)
		end
		return node
	elseif k == "Paren" then
		node.expr = transformExpr(node.expr, rng)
	elseif k == "Field" then
		node.obj = transformExpr(node.obj, rng)
	elseif k == "Index" then
		node.obj = transformExpr(node.obj, rng)
		node.index = transformExpr(node.index, rng)
	elseif k == "Call" then
		node.func = transformExpr(node.func, rng)
		for i, a in node.args do node.args[i] = transformExpr(a, rng) end
	elseif k == "MethodCall" then
		node.obj = transformExpr(node.obj, rng)
		for i, a in node.args do node.args[i] = transformExpr(a, rng) end
	elseif k == "Function" then
		transformBlock(node.body, rng)
	elseif k == "Table" then
		for _, f in node.fields do
			if f.type == "key" then f.key = transformExpr(f.key, rng) end
			f.value = transformExpr(f.value, rng)
		end
	elseif k == "Binop" then
		node.lhs = transformExpr(node.lhs, rng)
		node.rhs = transformExpr(node.rhs, rng)
	elseif k == "Unop" then
		node.operand = transformExpr(node.operand, rng)
	end
	return node
end

function transformBlock(block: any, rng: () -> number)
	for _, st in block.stmts do
		local k = st.kind
		if k == "LocalAssign" then
			for i, e in st.exprs do st.exprs[i] = transformExpr(e, rng) end
		elseif k == "LocalFunction" then
			transformBlock(st.func.body, rng)
		elseif k == "FunctionDecl" then
			transformBlock(st.func.body, rng)
		elseif k == "Assign" then
			for i, t in st.targets do st.targets[i] = transformExpr(t, rng) end
			for i, e in st.exprs do st.exprs[i] = transformExpr(e, rng) end
		elseif k == "CompoundAssign" then
			st.target = transformExpr(st.target, rng)
			st.expr = transformExpr(st.expr, rng)
		elseif k == "CallStat" then
			st.call = transformExpr(st.call, rng)
		elseif k == "Do" then
			transformBlock(st.body, rng)
		elseif k == "While" then
			st.cond = transformExpr(st.cond, rng)
			transformBlock(st.body, rng)
		elseif k == "Repeat" then
			transformBlock(st.body, rng)
			st.cond = transformExpr(st.cond, rng)
		elseif k == "If" then
			for _, cl in st.clauses do
				if cl.cond ~= nil then cl.cond = transformExpr(cl.cond, rng) end
				transformBlock(cl.body, rng)
			end
		elseif k == "NumericFor" then
			st.start = transformExpr(st.start, rng)
			st.limit = transformExpr(st.limit, rng)
			if st.step ~= nil then st.step = transformExpr(st.step, rng) end
			transformBlock(st.body, rng)
		elseif k == "GenericFor" then
			for i, e in st.exprs do st.exprs[i] = transformExpr(e, rng) end
			transformBlock(st.body, rng)
		elseif k == "Return" then
			for i, e in st.exprs do st.exprs[i] = transformExpr(e, rng) end
		end
	end
end

function NumberEncode.apply(block: any, rng: () -> number)
	transformBlock(block, rng)
end

return NumberEncode
