--!strict
-- StringEncrypt.luau — move every string literal into an encrypted pool that is
-- decoded at runtime by an injected decoder function.
--
-- Cipher: additive stream. For pool entry i (1-based) and byte position j:
--     cipher[j] = (plain[j] + (BASE + j*JMUL + i*IMUL)) % 256
-- The injected decoder inverts it. No external libraries required.

local Parser = require("../Parser")
local Serializer = require("../Serializer")

local StringEncrypt = {}

local transformBlock: (block: any, subst: (value: string) -> any) -> ()

-- Replace String expression nodes with a call to the decoder, collecting values.
local function transformExpr(node: any, subst: (value: string) -> any): any
	local k = node.kind
	if k == "String" then
		return subst(node.value)
	elseif k == "Paren" then
		node.expr = transformExpr(node.expr, subst)
	elseif k == "Field" then
		node.obj = transformExpr(node.obj, subst)
	elseif k == "Index" then
		node.obj = transformExpr(node.obj, subst)
		node.index = transformExpr(node.index, subst)
	elseif k == "Call" then
		node.func = transformExpr(node.func, subst)
		for i, a in node.args do node.args[i] = transformExpr(a, subst) end
	elseif k == "MethodCall" then
		node.obj = transformExpr(node.obj, subst)
		for i, a in node.args do node.args[i] = transformExpr(a, subst) end
	elseif k == "Function" then
		transformBlock(node.body, subst)
	elseif k == "Table" then
		for _, f in node.fields do
			if f.type == "key" then f.key = transformExpr(f.key, subst) end
			f.value = transformExpr(f.value, subst)
		end
	elseif k == "Binop" then
		node.lhs = transformExpr(node.lhs, subst)
		node.rhs = transformExpr(node.rhs, subst)
	elseif k == "Unop" then
		node.operand = transformExpr(node.operand, subst)
	elseif k == "IfExpr" then
		for _, cl in node.clauses do
			cl.cond = transformExpr(cl.cond, subst)
			cl.value = transformExpr(cl.value, subst)
		end
		node.elseValue = transformExpr(node.elseValue, subst)
	end
	return node
end

function transformBlock(block: any, subst: (value: string) -> any)
	for _, st in block.stmts do
		local k = st.kind
		if k == "LocalAssign" then
			for i, e in st.exprs do st.exprs[i] = transformExpr(e, subst) end
		elseif k == "LocalFunction" then
			transformBlock(st.func.body, subst)
		elseif k == "FunctionDecl" then
			transformBlock(st.func.body, subst)
		elseif k == "Assign" then
			for i, t in st.targets do st.targets[i] = transformExpr(t, subst) end
			for i, e in st.exprs do st.exprs[i] = transformExpr(e, subst) end
		elseif k == "CompoundAssign" then
			st.target = transformExpr(st.target, subst)
			st.expr = transformExpr(st.expr, subst)
		elseif k == "CallStat" then
			st.call = transformExpr(st.call, subst)
		elseif k == "Do" then
			transformBlock(st.body, subst)
		elseif k == "While" then
			st.cond = transformExpr(st.cond, subst)
			transformBlock(st.body, subst)
		elseif k == "Repeat" then
			transformBlock(st.body, subst)
			st.cond = transformExpr(st.cond, subst)
		elseif k == "If" then
			for _, cl in st.clauses do
				if cl.cond ~= nil then cl.cond = transformExpr(cl.cond, subst) end
				transformBlock(cl.body, subst)
			end
		elseif k == "NumericFor" then
			st.start = transformExpr(st.start, subst)
			st.limit = transformExpr(st.limit, subst)
			if st.step ~= nil then st.step = transformExpr(st.step, subst) end
			transformBlock(st.body, subst)
		elseif k == "GenericFor" then
			for i, e in st.exprs do st.exprs[i] = transformExpr(e, subst) end
			transformBlock(st.body, subst)
		elseif k == "Return" then
			for i, e in st.exprs do st.exprs[i] = transformExpr(e, subst) end
		end
	end
end

-- Build the pool + decoder preamble as Luau source, then parse it to statements.
local function buildPreamble(
	poolName: string, decName: string, cacheName: string,
	ciphers: { string }, base: number, jmul: number, imul: number
): { any }
	local entries = {}
	for _, c in ciphers do
		table.insert(entries, Serializer.quote(c))
	end
	local src = string.format(
		"local %s={%s}\n" ..
		"local %s={}\n" ..
		"local function %s(i)\n" ..
		"  local c=%s[i]\n" ..
		"  if c~=nil then return c end\n" ..
		"  local s=%s[i]\n" ..
		"  local o={}\n" ..
		"  for j=1,#s do\n" ..
		"    local b=string.byte(s,j)\n" ..
		"    local k=(%d+j*%d+i*%d)%%256\n" ..
		"    o[j]=string.char((b-k)%%256)\n" ..
		"  end\n" ..
		"  local r=table.concat(o)\n" ..
		"  %s[i]=r\n" ..
		"  return r\n" ..
		"end\n",
		poolName, table.concat(entries, ","),
		cacheName,
		decName,
		cacheName,
		poolName,
		base, jmul, imul,
		cacheName
	)
	local blk = Parser.parse(src)
	return blk.stmts
end

function StringEncrypt.apply(block: any, gen: any, rng: () -> number)
	local indexOf: { [string]: number } = {}
	local values: { string } = {}

	local function subst(value: string): any
		local idx = indexOf[value]
		if idx == nil then
			table.insert(values, value)
			idx = #values
			indexOf[value] = idx
		end
		return {
			kind = "Call",
			func = { kind = "Name", name = "\0DEC" }, -- placeholder, fixed below
			args = { { kind = "Number", raw = tostring(idx) } },
		}
	end

	transformBlock(block, subst)

	if #values == 0 then
		return
	end

	local base = 1 + math.floor(rng() * 250)
	local jmul = 1 + math.floor(rng() * 13)
	local imul = 1 + math.floor(rng() * 13)

	local ciphers: { string } = {}
	for i, v in values do
		local out = {}
		for j = 1, #v do
			local b = string.byte(v, j)
			local k = (base + j * jmul + i * imul) % 256
			out[j] = string.char((b + k) % 256)
		end
		ciphers[i] = table.concat(out)
	end

	local poolName = gen:next()
	local decName = gen:next()
	local cacheName = gen:next()

	-- Point every placeholder decoder call at the real name.
	local function fixup(node: any)
		if type(node) ~= "table" then return end
		if node.kind == "Name" and node.name == "\0DEC" then
			node.name = decName
		end
		for _, v in node do
			if type(v) == "table" then fixup(v) end
		end
	end
	fixup(block)

	local preamble = buildPreamble(poolName, decName, cacheName, ciphers, base, jmul, imul)

	local newStmts = {}
	for _, st in preamble do table.insert(newStmts, st) end
	for _, st in block.stmts do table.insert(newStmts, st) end
	block.stmts = newStmts
end

return StringEncrypt
