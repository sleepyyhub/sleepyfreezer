--!strict
-- Serializer.luau — emit valid Luau source from an AST.
-- Minified output: single spaces only where required to keep tokens apart.

local Serializer = {}

type Writer = {
	buf: { string },
	last: string, -- last char emitted (for separator decisions)
}

local function isWordChar(c: string): boolean
	return c ~= "" and (c:match("[%w_]") ~= nil)
end

-- Emit raw text, inserting a space if needed so adjacent tokens don't merge
-- (e.g. two identifiers, or a `-` immediately before a numeric `-`).
local function emit(w: Writer, text: string)
	if text == "" then return end
	local first = string.sub(text, 1, 1)
	local needSpace = false
	if isWordChar(w.last) and isWordChar(first) then
		needSpace = true
	elseif w.last == "-" and first == "-" then
		needSpace = true -- avoid forming a comment
	elseif w.last == "." and first == "." then
		needSpace = true -- avoid merging into '..'
	elseif w.last == ":" and first == ":" then
		needSpace = true
	elseif w.last:match("%d") ~= nil and string.sub(text, 1, 2) == ".." then
		needSpace = true -- keep a numeric literal apart from a following '..'
	end
	if needSpace then
		table.insert(w.buf, " ")
	end
	table.insert(w.buf, text)
	w.last = string.sub(text, #text, #text)
end

-- string escaping to a double-quoted literal
local function quote(sv: string): string
	local out = { '"' }
	for i = 1, #sv do
		local b = string.byte(sv, i)
		local c = string.sub(sv, i, i)
		if c == '"' then table.insert(out, '\\"')
		elseif c == "\\" then table.insert(out, "\\\\")
		elseif b == 10 then table.insert(out, "\\n")
		elseif b == 13 then table.insert(out, "\\r")
		elseif b == 9 then table.insert(out, "\\t")
		-- Zero-pad numeric escapes to 3 digits: an unpadded "\2" followed by
		-- literal digits ("56") would be lexed as "\256" (an invalid byte).
		elseif b < 32 or b >= 127 then table.insert(out, string.format("\\%03d", b))
		else table.insert(out, c) end
	end
	table.insert(out, '"')
	return table.concat(out)
end

Serializer.quote = quote

local writeExpr: (w: Writer, node: any) -> ()
local writeBlock: (w: Writer, block: any) -> ()

-- precedence for parenthesization when serializing binops
local BINPRI: { [string]: number } = {
	["or"] = 1, ["and"] = 2,
	["<"] = 3, [">"] = 3, ["<="] = 3, [">="] = 3, ["~="] = 3, ["=="] = 3,
	[".."] = 5, ["+"] = 6, ["-"] = 6,
	["*"] = 7, ["/"] = 7, ["//"] = 7, ["%"] = 7, ["^"] = 10,
}
local RIGHT: { [string]: boolean } = { [".."] = true, ["^"] = true }

local function writeParams(w: Writer, func: any)
	emit(w, "(")
	local parts = {}
	for _, p in func.params do table.insert(parts, p) end
	if func.isVararg then table.insert(parts, "...") end
	for i, p in parts do
		if i > 1 then emit(w, ",") end
		emit(w, p)
	end
	emit(w, ")")
end

local function writeFunctionBody(w: Writer, func: any)
	writeParams(w, func)
	writeBlock(w, func.body)
	emit(w, "end")
end

local function writeCallArgs(w: Writer, args: { any })
	emit(w, "(")
	for i, a in args do
		if i > 1 then emit(w, ",") end
		writeExpr(w, a)
	end
	emit(w, ")")
end

-- Write expr, wrapping in parens if its precedence is below `minPri`.
local function writeSub(w: Writer, node: any, minPri: number)
	local needParen = false
	if node.kind == "Binop" then
		if (BINPRI[node.op] or 99) < minPri then needParen = true end
	end
	if needParen then emit(w, "(") end
	writeExpr(w, node)
	if needParen then emit(w, ")") end
end

function writeExpr(w: Writer, node: any)
	local k = node.kind
	if k == "Nil" then emit(w, "nil")
	elseif k == "True" then emit(w, "true")
	elseif k == "False" then emit(w, "false")
	elseif k == "Vararg" then emit(w, "...")
	elseif k == "Number" then emit(w, node.raw)
	elseif k == "String" then emit(w, quote(node.value))
	elseif k == "Name" then emit(w, node.name)
	elseif k == "Paren" then
		emit(w, "(")
		writeExpr(w, node.expr)
		emit(w, ")")
	elseif k == "Field" then
		writeExpr(w, node.obj)
		emit(w, ".")
		emit(w, node.name)
	elseif k == "Index" then
		writeExpr(w, node.obj)
		emit(w, "[")
		writeExpr(w, node.index)
		emit(w, "]")
	elseif k == "Call" then
		writeExpr(w, node.func)
		writeCallArgs(w, node.args)
	elseif k == "MethodCall" then
		writeExpr(w, node.obj)
		emit(w, ":")
		emit(w, node.method)
		writeCallArgs(w, node.args)
	elseif k == "Function" then
		emit(w, "function")
		writeFunctionBody(w, node)
	elseif k == "Table" then
		emit(w, "{")
		for i, f in node.fields do
			if i > 1 then emit(w, ",") end
			if f.type == "list" then
				writeExpr(w, f.value)
			elseif f.type == "rec" then
				emit(w, f.name)
				emit(w, "=")
				writeExpr(w, f.value)
			else -- key
				emit(w, "[")
				writeExpr(w, f.key)
				emit(w, "]")
				emit(w, "=")
				writeExpr(w, f.value)
			end
		end
		emit(w, "}")
	elseif k == "Binop" then
		local pri = BINPRI[node.op] or 0
		local leftMin = if RIGHT[node.op] then pri + 1 else pri
		local rightMin = if RIGHT[node.op] then pri else pri + 1
		writeSub(w, node.lhs, leftMin)
		emit(w, node.op)
		writeSub(w, node.rhs, rightMin)
	elseif k == "Unop" then
		emit(w, node.op)
		-- unary binds at 8; parenthesize operands weaker than that
		local operand = node.operand
		local needParen = operand.kind == "Binop" and (BINPRI[operand.op] or 99) < 8
		if needParen then emit(w, "(") end
		writeExpr(w, operand)
		if needParen then emit(w, ")") end
	elseif k == "IfExpr" then
		for i, cl in node.clauses do
			emit(w, if i == 1 then "if" else "elseif")
			writeExpr(w, cl.cond)
			emit(w, "then")
			writeExpr(w, cl.value)
		end
		emit(w, "else")
		writeExpr(w, node.elseValue)
	else
		error("Serializer: unknown expr kind " .. tostring(k))
	end
end

local function writeTargetChain(w: Writer, node: any)
	writeExpr(w, node)
end

local function writeStat(w: Writer, st: any)
	local k = st.kind
	if k == "LocalAssign" then
		emit(w, "local")
		for i, n in st.names do
			if i > 1 then emit(w, ",") end
			emit(w, n)
		end
		if #st.exprs > 0 then
			emit(w, "=")
			for i, e in st.exprs do
				if i > 1 then emit(w, ",") end
				writeExpr(w, e)
			end
		end
	elseif k == "LocalFunction" then
		emit(w, "local")
		emit(w, "function")
		emit(w, st.name)
		writeFunctionBody(w, st.func)
	elseif k == "FunctionDecl" then
		emit(w, "function")
		writeTargetChain(w, st.target)
		if st.method then
			emit(w, ":")
			emit(w, st.method)
		end
		writeFunctionBody(w, st.func)
	elseif k == "Assign" then
		for i, tg in st.targets do
			if i > 1 then emit(w, ",") end
			writeExpr(w, tg)
		end
		emit(w, "=")
		for i, e in st.exprs do
			if i > 1 then emit(w, ",") end
			writeExpr(w, e)
		end
	elseif k == "CompoundAssign" then
		writeExpr(w, st.target)
		emit(w, st.op .. "=")
		writeExpr(w, st.expr)
	elseif k == "CallStat" then
		writeExpr(w, st.call)
	elseif k == "Do" then
		emit(w, "do")
		writeBlock(w, st.body)
		emit(w, "end")
	elseif k == "While" then
		emit(w, "while")
		writeExpr(w, st.cond)
		emit(w, "do")
		writeBlock(w, st.body)
		emit(w, "end")
	elseif k == "Repeat" then
		emit(w, "repeat")
		writeBlock(w, st.body)
		emit(w, "until")
		writeExpr(w, st.cond)
	elseif k == "If" then
		for i, cl in st.clauses do
			if i == 1 then
				emit(w, "if")
				writeExpr(w, cl.cond)
				emit(w, "then")
			elseif cl.cond ~= nil then
				emit(w, "elseif")
				writeExpr(w, cl.cond)
				emit(w, "then")
			else
				emit(w, "else")
			end
			writeBlock(w, cl.body)
		end
		emit(w, "end")
	elseif k == "NumericFor" then
		emit(w, "for")
		emit(w, st.var)
		emit(w, "=")
		writeExpr(w, st.start)
		emit(w, ",")
		writeExpr(w, st.limit)
		if st.step ~= nil then
			emit(w, ",")
			writeExpr(w, st.step)
		end
		emit(w, "do")
		writeBlock(w, st.body)
		emit(w, "end")
	elseif k == "GenericFor" then
		emit(w, "for")
		for i, n in st.names do
			if i > 1 then emit(w, ",") end
			emit(w, n)
		end
		emit(w, "in")
		for i, e in st.exprs do
			if i > 1 then emit(w, ",") end
			writeExpr(w, e)
		end
		emit(w, "do")
		writeBlock(w, st.body)
		emit(w, "end")
	elseif k == "Return" then
		emit(w, "return")
		for i, e in st.exprs do
			if i > 1 then emit(w, ",") end
			writeExpr(w, e)
		end
	elseif k == "Break" then
		emit(w, "break")
	elseif k == "Continue" then
		emit(w, "continue")
	else
		error("Serializer: unknown stat kind " .. tostring(k))
	end
end

function writeBlock(w: Writer, block: any)
	for _, st in block.stmts do
		writeStat(w, st)
		-- statement separator: a semicolon is always safe and unambiguous
		emit(w, ";")
	end
end

function Serializer.serialize(block: any): string
	local w: Writer = { buf = {}, last = "" }
	writeBlock(w, block)
	return table.concat(w.buf)
end

return Serializer
