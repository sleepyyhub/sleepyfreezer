--!strict
-- Parser.luau — recursive-descent parser producing an AST.
-- Luau type annotations (: T, :: T, type/export type, <generics>, attributes)
-- are parsed and discarded; the AST is runtime-semantic only.
-- String interpolation is desugared into concatenation of tostring() calls.

local Lexer = require("./Lexer")

type Token = Lexer.Token

local Parser = {}

-- AST node kinds are plain tables with a `kind` field. See Serializer for the
-- full accepted set. Blocks are { kind = "Block", stmts = { ... } }.

type State = {
	toks: { Token },
	pos: number,
}

local function cur(s: State): Token
	return s.toks[s.pos]
end

local function nextTok(s: State): Token
	local t = s.toks[s.pos]
	s.pos += 1
	return t
end

local function check(s: State, kind: string, value: string?): boolean
	local t = s.toks[s.pos]
	if t.kind ~= kind then return false end
	if value ~= nil and t.value ~= value then return false end
	return true
end

local function accept(s: State, kind: string, value: string?): boolean
	if check(s, kind, value) then
		s.pos += 1
		return true
	end
	return false
end

local function perr(s: State, msg: string): never
	local t = cur(s)
	error(string.format("Parser error (line %d, near '%s'): %s", t.line, t.value, msg), 0)
end

local function expect(s: State, kind: string, value: string?): Token
	if not check(s, kind, value) then
		perr(s, string.format("expected %s%s", kind, if value then " '" .. value .. "'" else ""))
	end
	return nextTok(s)
end

-- Forward decls
local parseExpr: (s: State) -> any
local parseBlock: (s: State, terminators: { [string]: boolean }) -> any
local skipType: (s: State) -> ()

-- ===================================================================
-- Type stripping
-- ===================================================================

local function skipBalanced(s: State, open: string, close: string)
	expect(s, "Symbol", open)
	local depth = 1
	while depth > 0 do
		local t = cur(s)
		if t.kind == "Eof" then perr(s, "unterminated '" .. open .. "'") end
		if t.kind == "Symbol" and t.value == open then
			depth += 1
		elseif t.kind == "Symbol" and t.value == close then
			depth -= 1
		end
		s.pos += 1
	end
end

-- Consume a <...> generic/attribute group by balancing angle tokens.
local function skipAngles(s: State)
	expect(s, "Symbol", "<")
	local depth = 1
	while depth > 0 do
		local t = cur(s)
		if t.kind == "Eof" then perr(s, "unterminated '<'") end
		if t.kind == "Symbol" then
			if t.value == "<" then
				depth += 1
			elseif t.value == ">" then
				depth -= 1
			elseif t.value == ">=" then
				-- ">>" style close; treat as one '>'
				depth -= 1
			end
		end
		s.pos += 1
	end
end

local function skipTypePrimary(s: State)
	local t = cur(s)
	if t.kind == "Symbol" and t.value == "(" then
		skipBalanced(s, "(", ")")
		if accept(s, "Symbol", "->") then
			skipType(s) -- function return type
		end
		return
	elseif t.kind == "Symbol" and t.value == "{" then
		skipBalanced(s, "{", "}")
		return
	elseif t.kind == "String" then
		s.pos += 1 -- singleton string type
		return
	elseif t.kind == "Symbol" and t.value == "..." then
		s.pos += 1
		if check(s, "Name") or (check(s, "Keyword") and (t.value == "nil")) then
			skipTypePrimary(s)
		end
		return
	elseif t.kind == "Name" or (t.kind == "Keyword" and (t.value == "nil" or t.value == "true" or t.value == "false")) then
		s.pos += 1
		-- qualified name a.b
		while check(s, "Symbol", ".") do
			s.pos += 1
			expect(s, "Name")
		end
		-- generics
		if check(s, "Symbol", "<") then
			skipAngles(s)
		end
		-- typeof(...) already handled as Name 'typeof' then '(' below
		if check(s, "Symbol", "(") then
			-- e.g. typeof(expr)
			skipBalanced(s, "(", ")")
		end
		return
	end
	perr(s, "expected a type")
end

function skipType(s: State)
	skipTypePrimary(s)
	while true do
		if accept(s, "Symbol", "?") then
			-- optional
		elseif check(s, "Symbol", "|") or check(s, "Symbol", "&") then
			s.pos += 1
			skipTypePrimary(s)
		elseif accept(s, "Symbol", "->") then
			skipType(s)
		else
			break
		end
	end
end

-- optional ': Type'
local function skipTypeAnnotation(s: State)
	if accept(s, "Symbol", ":") then
		skipType(s)
	end
end

-- optional '<attrib>' after a local binding name, e.g. <const>, <close>
local function skipAttribute(s: State)
	if check(s, "Symbol", "<") then
		skipAngles(s)
	end
end

-- optional generic parameter list on a function, e.g. <T, U...>
local function skipGenerics(s: State)
	if check(s, "Symbol", "<") then
		skipAngles(s)
	end
end

-- ===================================================================
-- Expressions
-- ===================================================================

local UNARY: { [string]: boolean } = { ["-"] = true, ["#"] = true, ["not"] = true }

-- binary precedence: {left, right}
local BINPRI: { [string]: { number } } = {
	["or"] = { 1, 1 }, ["and"] = { 2, 2 },
	["<"] = { 3, 3 }, [">"] = { 3, 3 }, ["<="] = { 3, 3 },
	[">="] = { 3, 3 }, ["~="] = { 3, 3 }, ["=="] = { 3, 3 },
	[".."] = { 5, 4 }, -- right assoc
	["+"] = { 6, 6 }, ["-"] = { 6, 6 },
	["*"] = { 7, 7 }, ["/"] = { 7, 7 }, ["//"] = { 7, 7 }, ["%"] = { 7, 7 },
	["^"] = { 10, 9 }, -- right assoc, above unary (8)
}
local UNARY_PRI = 8

local function parseFunctionBody(s: State): any
	skipGenerics(s)
	expect(s, "Symbol", "(")
	local params: { string } = {}
	local isVararg = false
	if not check(s, "Symbol", ")") then
		repeat
			if accept(s, "Symbol", "...") then
				isVararg = true
				skipTypeAnnotation(s) -- ...: T
				break
			else
				local name = expect(s, "Name").value
				table.insert(params, name)
				skipTypeAnnotation(s)
			end
		until not accept(s, "Symbol", ",")
	end
	expect(s, "Symbol", ")")
	skipTypeAnnotation(s) -- return type
	local body = parseBlock(s, { ["end"] = true })
	expect(s, "Keyword", "end")
	return { kind = "Function", params = params, isVararg = isVararg, body = body }
end

local function parseTable(s: State): any
	expect(s, "Symbol", "{")
	local fields = {}
	while not check(s, "Symbol", "}") do
		if check(s, "Symbol", "[") then
			s.pos += 1
			local key = parseExpr(s)
			expect(s, "Symbol", "]")
			expect(s, "Symbol", "=")
			local value = parseExpr(s)
			table.insert(fields, { type = "key", key = key, value = value })
		elseif check(s, "Name") and s.toks[s.pos + 1].kind == "Symbol" and s.toks[s.pos + 1].value == "=" then
			local name = nextTok(s).value
			s.pos += 1 -- '='
			local value = parseExpr(s)
			table.insert(fields, { type = "rec", name = name, value = value })
		else
			local value = parseExpr(s)
			table.insert(fields, { type = "list", value = value })
		end
		if not (accept(s, "Symbol", ",") or accept(s, "Symbol", ";")) then
			break
		end
	end
	expect(s, "Symbol", "}")
	return { kind = "Table", fields = fields }
end

-- Desugar an interpolated string token into a concatenation of tostring() calls.
local function desugarInterp(s: State, tok: Token): any
	local parts = tok.parts :: { Lexer.InterpPart }
	local nodes = {}
	for _, p in parts do
		if p.kind == "lit" then
			if p.value ~= "" then
				table.insert(nodes, { kind = "String", value = p.value })
			end
		else
			local expr = Parser.parseExpressionFromSource(p.value)
			table.insert(nodes, {
				kind = "Call",
				func = { kind = "Name", name = "tostring" },
				args = { expr },
			})
		end
	end
	if #nodes == 0 then
		return { kind = "String", value = "" }
	end
	local acc = nodes[1]
	-- ensure result is a string even if single expr part: tostring already returns string;
	-- but a single lit is a String node — fine.
	for i = 2, #nodes do
		acc = { kind = "Binop", op = "..", lhs = acc, rhs = nodes[i] }
	end
	-- If the whole thing is a single literal string, still fine.
	return { kind = "Paren", expr = acc }
end

local function parsePrimary(s: State): any
	local t = cur(s)
	if t.kind == "Symbol" and t.value == "(" then
		s.pos += 1
		local e = parseExpr(s)
		expect(s, "Symbol", ")")
		return { kind = "Paren", expr = e }
	elseif t.kind == "Name" then
		s.pos += 1
		return { kind = "Name", name = t.value }
	end
	perr(s, "unexpected symbol")
end

local function parseArgs(s: State): { any }
	local t = cur(s)
	if t.kind == "String" then
		s.pos += 1
		return { { kind = "String", value = t.value } }
	elseif t.kind == "InterpString" then
		s.pos += 1
		return { desugarInterp(s, t) }
	elseif t.kind == "Symbol" and t.value == "{" then
		return { parseTable(s) }
	end
	expect(s, "Symbol", "(")
	local args = {}
	if not check(s, "Symbol", ")") then
		repeat
			table.insert(args, parseExpr(s))
		until not accept(s, "Symbol", ",")
	end
	expect(s, "Symbol", ")")
	return args
end

local function parseSuffixed(s: State): any
	local e = parsePrimary(s)
	while true do
		local t = cur(s)
		if t.kind == "Symbol" and t.value == "." then
			s.pos += 1
			local name = expect(s, "Name").value
			e = { kind = "Field", obj = e, name = name }
		elseif t.kind == "Symbol" and t.value == "[" then
			s.pos += 1
			local idx = parseExpr(s)
			expect(s, "Symbol", "]")
			e = { kind = "Index", obj = e, index = idx }
		elseif t.kind == "Symbol" and t.value == ":" then
			s.pos += 1
			local method = expect(s, "Name").value
			local args = parseArgs(s)
			e = { kind = "MethodCall", obj = e, method = method, args = args }
		elseif (t.kind == "Symbol" and (t.value == "(" or t.value == "{")) or t.kind == "String" or t.kind == "InterpString" then
			local args = parseArgs(s)
			e = { kind = "Call", func = e, args = args }
		else
			break
		end
	end
	return e
end

local function parseSimple(s: State): any
	local t = cur(s)
	if t.kind == "Number" then
		s.pos += 1
		return { kind = "Number", raw = t.value }
	elseif t.kind == "String" then
		s.pos += 1
		return { kind = "String", value = t.value }
	elseif t.kind == "InterpString" then
		s.pos += 1
		return desugarInterp(s, t)
	elseif t.kind == "Keyword" and t.value == "nil" then
		s.pos += 1
		return { kind = "Nil" }
	elseif t.kind == "Keyword" and t.value == "true" then
		s.pos += 1
		return { kind = "True" }
	elseif t.kind == "Keyword" and t.value == "false" then
		s.pos += 1
		return { kind = "False" }
	elseif t.kind == "Symbol" and t.value == "..." then
		s.pos += 1
		return { kind = "Vararg" }
	elseif t.kind == "Symbol" and t.value == "{" then
		return parseTable(s)
	elseif t.kind == "Keyword" and t.value == "function" then
		s.pos += 1
		return parseFunctionBody(s)
	end
	return parseSuffixed(s)
end

local function parseSubExpr(s: State, limit: number): any
	local t = cur(s)
	local node
	if (t.kind == "Symbol" and UNARY[t.value]) or (t.kind == "Keyword" and t.value == "not") then
		s.pos += 1
		local operand = parseSubExpr(s, UNARY_PRI)
		node = { kind = "Unop", op = t.value, operand = operand }
	else
		node = parseSimple(s)
	end
	while true do
		local o = cur(s)
		local opv: string? = nil
		if o.kind == "Symbol" and BINPRI[o.value] then
			opv = o.value
		elseif o.kind == "Keyword" and (o.value == "and" or o.value == "or") then
			opv = o.value
		end
		if opv == nil then break end
		local pri = BINPRI[opv]
		if pri[1] <= limit then break end
		s.pos += 1
		local rhs = parseSubExpr(s, pri[2])
		node = { kind = "Binop", op = opv, lhs = node, rhs = rhs }
	end
	return node
end

function parseExpr(s: State): any
	local e = parseSubExpr(s, 0)
	-- strip `:: Type` casts
	while accept(s, "Symbol", "::") do
		skipType(s)
	end
	return e
end

-- ===================================================================
-- Statements
-- ===================================================================

local function parseIf(s: State): any
	expect(s, "Keyword", "if")
	local clauses = {}
	local cond = parseExpr(s)
	expect(s, "Keyword", "then")
	local body = parseBlock(s, { ["end"] = true, ["else"] = true, ["elseif"] = true })
	table.insert(clauses, { cond = cond, body = body })
	while check(s, "Keyword", "elseif") do
		s.pos += 1
		local c = parseExpr(s)
		expect(s, "Keyword", "then")
		local b = parseBlock(s, { ["end"] = true, ["else"] = true, ["elseif"] = true })
		table.insert(clauses, { cond = c, body = b })
	end
	if accept(s, "Keyword", "else") then
		local b = parseBlock(s, { ["end"] = true })
		table.insert(clauses, { cond = nil, body = b })
	end
	expect(s, "Keyword", "end")
	return { kind = "If", clauses = clauses }
end

local function parseFor(s: State): any
	expect(s, "Keyword", "for")
	local firstName = expect(s, "Name").value
	skipTypeAnnotation(s)
	if check(s, "Symbol", "=") then
		s.pos += 1
		local startE = parseExpr(s)
		expect(s, "Symbol", ",")
		local limitE = parseExpr(s)
		local stepE = nil
		if accept(s, "Symbol", ",") then
			stepE = parseExpr(s)
		end
		expect(s, "Keyword", "do")
		local body = parseBlock(s, { ["end"] = true })
		expect(s, "Keyword", "end")
		return { kind = "NumericFor", var = firstName, start = startE, limit = limitE, step = stepE, body = body }
	else
		local names = { firstName }
		while accept(s, "Symbol", ",") do
			table.insert(names, expect(s, "Name").value)
			skipTypeAnnotation(s)
		end
		expect(s, "Keyword", "in")
		local exprs = { parseExpr(s) }
		while accept(s, "Symbol", ",") do
			table.insert(exprs, parseExpr(s))
		end
		expect(s, "Keyword", "do")
		local body = parseBlock(s, { ["end"] = true })
		expect(s, "Keyword", "end")
		return { kind = "GenericFor", names = names, exprs = exprs, body = body }
	end
end

local function parseLocal(s: State): any
	expect(s, "Keyword", "local")
	if accept(s, "Keyword", "function") then
		local name = expect(s, "Name").value
		local func = parseFunctionBody(s)
		return { kind = "LocalFunction", name = name, func = func }
	end
	local names = {}
	repeat
		local name = expect(s, "Name").value
		table.insert(names, name)
		skipAttribute(s)
		skipTypeAnnotation(s)
	until not accept(s, "Symbol", ",")
	local exprs = {}
	if accept(s, "Symbol", "=") then
		repeat
			table.insert(exprs, parseExpr(s))
		until not accept(s, "Symbol", ",")
	end
	return { kind = "LocalAssign", names = names, exprs = exprs }
end

local function parseFunctionStat(s: State): any
	expect(s, "Keyword", "function")
	local base = { kind = "Name", name = expect(s, "Name").value }
	local target: any = base
	while accept(s, "Symbol", ".") do
		target = { kind = "Field", obj = target, name = expect(s, "Name").value }
	end
	local method: string? = nil
	if accept(s, "Symbol", ":") then
		method = expect(s, "Name").value
	end
	local func = parseFunctionBody(s)
	return { kind = "FunctionDecl", target = target, method = method, func = func }
end

local COMPOUND: { [string]: string } = {
	["+="] = "+", ["-="] = "-", ["*="] = "*", ["/="] = "/",
	["//="] = "//", ["%="] = "%", ["^="] = "^", ["..="] = "..",
}

local function parseExprStat(s: State): any
	local first = parseSuffixed(s)
	local t = cur(s)
	if t.kind == "Symbol" and (t.value == "=" or t.value == ",") then
		local targets = { first }
		while accept(s, "Symbol", ",") do
			table.insert(targets, parseSuffixed(s))
		end
		expect(s, "Symbol", "=")
		local exprs = { parseExpr(s) }
		while accept(s, "Symbol", ",") do
			table.insert(exprs, parseExpr(s))
		end
		return { kind = "Assign", targets = targets, exprs = exprs }
	elseif t.kind == "Symbol" and COMPOUND[t.value] then
		local op = COMPOUND[t.value]
		s.pos += 1
		local rhs = parseExpr(s)
		return { kind = "CompoundAssign", op = op, target = first, expr = rhs }
	else
		if first.kind ~= "Call" and first.kind ~= "MethodCall" then
			perr(s, "syntax error (expected statement)")
		end
		return { kind = "CallStat", call = first }
	end
end

local function parseStatement(s: State): any?
	local t = cur(s)
	if t.kind == "Symbol" and t.value == ";" then
		s.pos += 1
		return nil
	elseif t.kind == "Keyword" then
		local v = t.value
		if v == "local" then return parseLocal(s)
		elseif v == "if" then return parseIf(s)
		elseif v == "while" then
			s.pos += 1
			local cond = parseExpr(s)
			expect(s, "Keyword", "do")
			local body = parseBlock(s, { ["end"] = true })
			expect(s, "Keyword", "end")
			return { kind = "While", cond = cond, body = body }
		elseif v == "repeat" then
			s.pos += 1
			local body = parseBlock(s, { ["until"] = true })
			expect(s, "Keyword", "until")
			local cond = parseExpr(s)
			return { kind = "Repeat", body = body, cond = cond }
		elseif v == "for" then return parseFor(s)
		elseif v == "do" then
			s.pos += 1
			local body = parseBlock(s, { ["end"] = true })
			expect(s, "Keyword", "end")
			return { kind = "Do", body = body }
		elseif v == "function" then return parseFunctionStat(s)
		elseif v == "break" then s.pos += 1; return { kind = "Break" }
		elseif v == "continue" then s.pos += 1; return { kind = "Continue" }
		end
	elseif t.kind == "Name" and t.value == "type" and s.toks[s.pos + 1].kind == "Name" then
		-- `type X = ...` alias declaration (discard)
		s.pos += 1
		expect(s, "Name")
		skipGenerics(s)
		expect(s, "Symbol", "=")
		skipType(s)
		return nil
	elseif t.kind == "Name" and t.value == "export" and s.toks[s.pos + 1].kind == "Name" and s.toks[s.pos + 1].value == "type" then
		s.pos += 2
		expect(s, "Name")
		skipGenerics(s)
		expect(s, "Symbol", "=")
		skipType(s)
		return nil
	end
	return parseExprStat(s)
end

function parseBlock(s: State, terminators: { [string]: boolean }): any
	local stmts = {}
	while true do
		local t = cur(s)
		if t.kind == "Eof" then break end
		if t.kind == "Keyword" and terminators[t.value] then break end
		if t.kind == "Keyword" and t.value == "return" then
			s.pos += 1
			local exprs = {}
			local nt = cur(s)
			local isEnd = nt.kind == "Eof"
				or (nt.kind == "Keyword" and terminators[nt.value])
				or (nt.kind == "Symbol" and nt.value == ";")
			if not isEnd then
				table.insert(exprs, parseExpr(s))
				while accept(s, "Symbol", ",") do
					table.insert(exprs, parseExpr(s))
				end
			end
			accept(s, "Symbol", ";")
			table.insert(stmts, { kind = "Return", exprs = exprs })
			break
		end
		local st = parseStatement(s)
		if st ~= nil then
			table.insert(stmts, st)
		end
	end
	return { kind = "Block", stmts = stmts }
end

function Parser.parse(src: string): any
	local toks = Lexer.tokenize(src)
	local s: State = { toks = toks, pos = 1 }
	local block = parseBlock(s, {})
	if cur(s).kind ~= "Eof" then
		perr(s, "unexpected trailing tokens")
	end
	return block
end

function Parser.parseExpressionFromSource(src: string): any
	local toks = Lexer.tokenize(src)
	local s: State = { toks = toks, pos = 1 }
	local e = parseExpr(s)
	if cur(s).kind ~= "Eof" then
		perr(s, "unexpected tokens after expression")
	end
	return e
end

return Parser
