--!strict
-- Rename.luau — scope-aware local-variable renaming.
-- Only local bindings are renamed. Globals, field names, method names and table
-- record keys are left untouched (they are resolved by name at runtime).

local Rename = {}

type Scope = { [string]: string }

type Ctx = {
	scopes: { Scope },
	gen: any, -- NameGen
}

local function push(ctx: Ctx)
	table.insert(ctx.scopes, {})
end
local function pop(ctx: Ctx)
	ctx.scopes[#ctx.scopes] = nil
end

-- declare a new local in the current (top) scope; returns the fresh name
local function declare(ctx: Ctx, name: string): string
	local fresh = ctx.gen:next()
	ctx.scopes[#ctx.scopes][name] = fresh
	return fresh
end

-- declare a binding that keeps a fixed name (used for implicit `self`)
local function declareFixed(ctx: Ctx, name: string, fixed: string)
	ctx.scopes[#ctx.scopes][name] = fixed
end

-- resolve a name to its renamed local, or nil if it is a global
local function resolve(ctx: Ctx, name: string): string?
	for i = #ctx.scopes, 1, -1 do
		local m = ctx.scopes[i][name]
		if m ~= nil then return m end
	end
	return nil
end

local renameExpr: (ctx: Ctx, node: any) -> ()
local renameBlockScoped: (ctx: Ctx, block: any) -> ()
local renameBlockInline: (ctx: Ctx, block: any) -> ()

local function renameFunction(ctx: Ctx, func: any, implicitSelf: boolean)
	push(ctx)
	if implicitSelf then
		declareFixed(ctx, "self", "self")
	end
	for i, p in func.params do
		func.params[i] = declare(ctx, p)
	end
	renameBlockInline(ctx, func.body)
	pop(ctx)
end

function renameExpr(ctx: Ctx, node: any)
	local k = node.kind
	if k == "Name" then
		local r = resolve(ctx, node.name)
		if r ~= nil then
			node.name = r
		end
	elseif k == "Paren" then
		renameExpr(ctx, node.expr)
	elseif k == "Field" then
		renameExpr(ctx, node.obj) -- field name is not renamed
	elseif k == "Index" then
		renameExpr(ctx, node.obj)
		renameExpr(ctx, node.index)
	elseif k == "Call" then
		renameExpr(ctx, node.func)
		for _, a in node.args do renameExpr(ctx, a) end
	elseif k == "MethodCall" then
		renameExpr(ctx, node.obj) -- method name not renamed
		for _, a in node.args do renameExpr(ctx, a) end
	elseif k == "Function" then
		renameFunction(ctx, node, false)
	elseif k == "Table" then
		for _, f in node.fields do
			if f.type == "key" then
				renameExpr(ctx, f.key)
			end
			-- rec name is a field key: not renamed
			renameExpr(ctx, f.value)
		end
	elseif k == "Binop" then
		renameExpr(ctx, node.lhs)
		renameExpr(ctx, node.rhs)
	elseif k == "Unop" then
		renameExpr(ctx, node.operand)
	elseif k == "IfExpr" then
		for _, cl in node.clauses do
			renameExpr(ctx, cl.cond)
			renameExpr(ctx, cl.value)
		end
		renameExpr(ctx, node.elseValue)
	elseif k == "Number" or k == "String" or k == "Nil" or k == "True"
		or k == "False" or k == "Vararg" then
		-- literals: nothing
	else
		error("Rename: unknown expr kind " .. tostring(k))
	end
end

local function renameStat(ctx: Ctx, st: any)
	local k = st.kind
	if k == "LocalAssign" then
		for _, e in st.exprs do renameExpr(ctx, e) end -- RHS in current scope
		for i, n in st.names do
			st.names[i] = declare(ctx, n)
		end
	elseif k == "LocalFunction" then
		st.name = declare(ctx, st.name) -- visible to itself (recursion)
		renameFunction(ctx, st.func, false)
	elseif k == "FunctionDecl" then
		renameExpr(ctx, st.target) -- base var resolved; field/method names kept
		renameFunction(ctx, st.func, st.method ~= nil)
	elseif k == "Assign" then
		for _, tg in st.targets do renameExpr(ctx, tg) end
		for _, e in st.exprs do renameExpr(ctx, e) end
	elseif k == "CompoundAssign" then
		renameExpr(ctx, st.target)
		renameExpr(ctx, st.expr)
	elseif k == "CallStat" then
		renameExpr(ctx, st.call)
	elseif k == "Do" then
		renameBlockScoped(ctx, st.body)
	elseif k == "While" then
		renameExpr(ctx, st.cond)
		renameBlockScoped(ctx, st.body)
	elseif k == "Repeat" then
		push(ctx)
		renameBlockInline(ctx, st.body)
		renameExpr(ctx, st.cond) -- until sees body locals
		pop(ctx)
	elseif k == "If" then
		for _, cl in st.clauses do
			if cl.cond ~= nil then renameExpr(ctx, cl.cond) end
			renameBlockScoped(ctx, cl.body)
		end
	elseif k == "NumericFor" then
		renameExpr(ctx, st.start)
		renameExpr(ctx, st.limit)
		if st.step ~= nil then renameExpr(ctx, st.step) end
		push(ctx)
		st.var = declare(ctx, st.var)
		renameBlockInline(ctx, st.body)
		pop(ctx)
	elseif k == "GenericFor" then
		for _, e in st.exprs do renameExpr(ctx, e) end
		push(ctx)
		for i, n in st.names do
			st.names[i] = declare(ctx, n)
		end
		renameBlockInline(ctx, st.body)
		pop(ctx)
	elseif k == "Return" then
		for _, e in st.exprs do renameExpr(ctx, e) end
	elseif k == "Break" or k == "Continue" then
		-- nothing
	else
		error("Rename: unknown stat kind " .. tostring(k))
	end
end

function renameBlockInline(ctx: Ctx, block: any)
	for _, st in block.stmts do
		renameStat(ctx, st)
	end
end

function renameBlockScoped(ctx: Ctx, block: any)
	push(ctx)
	renameBlockInline(ctx, block)
	pop(ctx)
end

-- Rename all locals in `block`. `gen` is a NameGen instance.
function Rename.apply(block: any, gen: any)
	local ctx: Ctx = { scopes = {}, gen = gen }
	push(ctx) -- top-level chunk scope
	renameBlockInline(ctx, block)
	pop(ctx)
end

return Rename
