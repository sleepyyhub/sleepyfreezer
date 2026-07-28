--!strict
-- Obfuscator.luau — top-level pipeline.
-- Passes (in order): string encryption, number encoding, local renaming,
-- junk injection, and an IIFE wrapper. Output is minified Luau source.

local Parser = require("./Parser")
local Serializer = require("./Serializer")
local NameGen = require("./NameGen")
local Rename = require("./passes/Rename")
local StringEncrypt = require("./passes/StringEncrypt")
local NumberEncode = require("./passes/NumberEncode")
local Junk = require("./passes/Junk")

local Obfuscator = {}

export type Options = {
	seed: number?,
	renameLocals: boolean?,
	encryptStrings: boolean?,
	encodeNumbers: boolean?,
	junk: boolean?,
	wrap: boolean?,
}

-- Collect every identifier that textually appears, so generated names never clash.
local function collectReserved(block: any, reserved: { [string]: boolean })
	local function addName(n: string?)
		if n ~= nil then reserved[n] = true end
	end
	local walkExpr: (node: any) -> ()
	local walkBlock: (b: any) -> ()

	local function walkFunc(f: any)
		for _, p in f.params do addName(p) end
		walkBlock(f.body)
	end

	function walkExpr(node: any)
		local k = node.kind
		if k == "Name" then addName(node.name)
		elseif k == "Paren" then walkExpr(node.expr)
		elseif k == "Field" then addName(node.name); walkExpr(node.obj)
		elseif k == "Index" then walkExpr(node.obj); walkExpr(node.index)
		elseif k == "Call" then
			walkExpr(node.func)
			for _, a in node.args do walkExpr(a) end
		elseif k == "MethodCall" then
			addName(node.method)
			walkExpr(node.obj)
			for _, a in node.args do walkExpr(a) end
		elseif k == "Function" then walkFunc(node)
		elseif k == "Table" then
			for _, f in node.fields do
				if f.type == "rec" then addName(f.name) end
				if f.type == "key" then walkExpr(f.key) end
				walkExpr(f.value)
			end
		elseif k == "Binop" then walkExpr(node.lhs); walkExpr(node.rhs)
		elseif k == "Unop" then walkExpr(node.operand)
		elseif k == "IfExpr" then
			for _, cl in node.clauses do walkExpr(cl.cond); walkExpr(cl.value) end
			walkExpr(node.elseValue)
		end
	end

	local function walkStat(st: any)
		local k = st.kind
		if k == "LocalAssign" then
			for _, n in st.names do addName(n) end
			for _, e in st.exprs do walkExpr(e) end
		elseif k == "LocalFunction" then
			addName(st.name); walkFunc(st.func)
		elseif k == "FunctionDecl" then
			addName(st.method); walkExpr(st.target); walkFunc(st.func)
		elseif k == "Assign" then
			for _, t in st.targets do walkExpr(t) end
			for _, e in st.exprs do walkExpr(e) end
		elseif k == "CompoundAssign" then walkExpr(st.target); walkExpr(st.expr)
		elseif k == "CallStat" then walkExpr(st.call)
		elseif k == "Do" then walkBlock(st.body)
		elseif k == "While" then walkExpr(st.cond); walkBlock(st.body)
		elseif k == "Repeat" then walkBlock(st.body); walkExpr(st.cond)
		elseif k == "If" then
			for _, cl in st.clauses do
				if cl.cond ~= nil then walkExpr(cl.cond) end
				walkBlock(cl.body)
			end
		elseif k == "NumericFor" then
			addName(st.var); walkExpr(st.start); walkExpr(st.limit)
			if st.step ~= nil then walkExpr(st.step) end
			walkBlock(st.body)
		elseif k == "GenericFor" then
			for _, n in st.names do addName(n) end
			for _, e in st.exprs do walkExpr(e) end
			walkBlock(st.body)
		elseif k == "Return" then
			for _, e in st.exprs do walkExpr(e) end
		end
	end

	function walkBlock(b: any)
		for _, st in b.stmts do walkStat(st) end
	end

	walkBlock(block)
end

-- Wrap the whole chunk in an IIFE so the injected pool/decoder and all top-level
-- locals live in a private scope. `return (function(...) ... end)(...)` preserves
-- a ModuleScript's return value.
local function wrapIIFE(block: any): any
	local func = { kind = "Function", params = {}, isVararg = true, body = block }
	local call = { kind = "Call", func = { kind = "Paren", expr = func }, args = { { kind = "Vararg" } } }
	return { kind = "Block", stmts = { { kind = "Return", exprs = { call } } } }
end

function Obfuscator.obfuscate(src: string, opts: Options?): string
	local o: Options = opts or {}
	local seed = o.seed or 20260728
	local renameLocals = o.renameLocals ~= false
	local encryptStrings = o.encryptStrings ~= false
	local encodeNumbers = o.encodeNumbers ~= false
	local junk = o.junk ~= false
	local wrap = o.wrap ~= false

	local block = Parser.parse(src)

	local reserved: { [string]: boolean } = {}
	collectReserved(block, reserved)
	local gen = NameGen.new(reserved, seed)
	local rng = NameGen.makeRng(seed * 7 + 13)

	if encryptStrings then
		StringEncrypt.apply(block, gen, rng)
	end
	if encodeNumbers then
		NumberEncode.apply(block, rng)
	end
	if renameLocals then
		Rename.apply(block, gen)
	end
	if junk then
		Junk.apply(block, gen, rng)
	end
	if wrap then
		block = wrapIIFE(block)
	end

	return Serializer.serialize(block)
end

return Obfuscator
