--!strict
-- Runtime.luau — emits the Clovyre VM: interpreter + serialized proto data +
-- bootstrap. The interpreter is a fixed register-machine dispatch loop; only the
-- proto data changes per program.
--
-- Proto shape (runtime):
--   { code = {int...4-per-instr}, k = {const...}, protos = {Proto...},
--     np = numParams, va = 0|1 vararg, ms = maxStack, uv = {{f,i}...} }
-- Constants are only numbers and strings (nil/bool are dedicated opcodes).

local Opcodes = require("./Opcodes")
local Serializer = require("../Serializer")

local Runtime = {}

local function numLit(n: number): string
	if n == math.floor(n) and math.abs(n) < 2 ^ 53 then
		return string.format("%d", n)
	end
	return string.format("%.17g", n)
end

-- Serialize a proto to a Luau table-literal expression.
local function serProto(proto: any): string
	local parts = {}

	local codeParts = {}
	for _, v in proto.code do
		table.insert(codeParts, numLit(v))
	end
	table.insert(parts, "code={" .. table.concat(codeParts, ",") .. "}")

	local kParts = {}
	for _, kv in proto.k do
		if type(kv) == "string" then
			table.insert(kParts, Serializer.quote(kv))
		else
			table.insert(kParts, numLit(kv))
		end
	end
	table.insert(parts, "k={" .. table.concat(kParts, ",") .. "}")

	local pParts = {}
	for _, child in proto.protos do
		table.insert(pParts, serProto(child))
	end
	table.insert(parts, "protos={" .. table.concat(pParts, ",") .. "}")

	table.insert(parts, "np=" .. numLit(proto.np))
	table.insert(parts, "va=" .. (if proto.va then "1" else "0"))
	table.insert(parts, "ms=" .. numLit(proto.ms))

	local uvParts = {}
	for _, d in proto.uv do
		uvParts[#uvParts + 1] = "{" .. numLit(d[1]) .. "," .. numLit(d[2]) .. "}"
	end
	table.insert(parts, "uv={" .. table.concat(uvParts, ",") .. "}")

	return "{" .. table.concat(parts, ",") .. "}"
end

Runtime.serProto = serProto

-- The interpreter body. Opcode names are locals defined in a header generated
-- from Opcodes.LIST, so the numbers can never drift from the compiler's.
local INTERP = [==[
local function makeClosure(proto, upvals)
	return function(...)
		local R = {}
		local code = proto.code
		local K = proto.k
		local protos = proto.protos
		local np = proto.np
		local nargs = select("#", ...)
		local args = { ... }
		for i = 0, np - 1 do
			R[i] = args[i + 1]
		end
		local varargs
		if proto.va == 1 then
			varargs = { n = 0 }
			local vn = 0
			for i = np + 1, nargs do
				vn = vn + 1
				varargs[vn] = args[i]
			end
			varargs.n = vn
		end
		local pc = 0
		local top = 0
		while true do
			local o = pc * 4
			local op = code[o + 1]
			local a = code[o + 2]
			local b = code[o + 3]
			local c = code[o + 4]
			pc = pc + 1
			if op == LOADK then R[a] = K[b]
			elseif op == LOADBOOL then R[a] = (b ~= 0)
			elseif op == LOADNIL then R[a] = nil
			elseif op == MOVE then R[a] = R[b]
			elseif op == GETGLOBAL then R[a] = ENV[K[b]]
			elseif op == SETGLOBAL then ENV[K[b]] = R[a]
			elseif op == GETUPVAL then R[a] = upvals[b][1]
			elseif op == SETUPVAL then upvals[b][1] = R[a]
			elseif op == NEWTABLE then R[a] = {}
			elseif op == GETTABLE then R[a] = R[b][R[c]]
			elseif op == SETTABLE then R[a][R[b]] = R[c]
			elseif op == SETLIST then
				local n = if b == 0 then top - (a + 1) else b - 1
				local t = R[a]
				for i = 1, n do t[c + i] = R[a + i] end
			elseif op == ADD then R[a] = R[b] + R[c]
			elseif op == SUB then R[a] = R[b] - R[c]
			elseif op == MUL then R[a] = R[b] * R[c]
			elseif op == DIV then R[a] = R[b] / R[c]
			elseif op == MOD then R[a] = R[b] % R[c]
			elseif op == POW then R[a] = R[b] ^ R[c]
			elseif op == IDIV then R[a] = R[b] // R[c]
			elseif op == CONCAT then R[a] = R[b] .. R[c]
			elseif op == EQ then R[a] = (R[b] == R[c])
			elseif op == NE then R[a] = (R[b] ~= R[c])
			elseif op == LT then R[a] = (R[b] < R[c])
			elseif op == LE then R[a] = (R[b] <= R[c])
			elseif op == GT then R[a] = (R[b] > R[c])
			elseif op == GE then R[a] = (R[b] >= R[c])
			elseif op == NOT then R[a] = not R[b]
			elseif op == UNM then R[a] = -R[b]
			elseif op == LEN then R[a] = #R[b]
			elseif op == JMP then pc = pc + a
			elseif op == JMPIF then if R[a] then pc = pc + b end
			elseif op == JMPIFNOT then if not R[a] then pc = pc + b end
			elseif op == CALL then
				local fn = R[a]
				local nargs2 = if b == 0 then top - (a + 1) else b - 1
				local ca = {}
				for i = 1, nargs2 do ca[i] = R[a + i] end
				local res = table.pack(fn(table.unpack(ca, 1, nargs2)))
				if c == 0 then
					local nres = res.n
					top = a + nres
					for i = 0, nres - 1 do R[a + i] = res[i + 1] end
				else
					for i = 0, c - 2 do R[a + i] = res[i + 1] end
				end
			elseif op == SELF then
				R[a + 1] = R[b]
				R[a] = R[b][R[c]]
			elseif op == RETURN then
				local nret = if b == 0 then top - a else b - 1
				local out = {}
				for i = 1, nret do out[i] = R[a + i - 1] end
				return table.unpack(out, 1, nret)
			elseif op == VARARG then
				local n = if b == 0 then varargs.n else b - 1
				if b == 0 then top = a + n end
				for i = 0, n - 1 do R[a + i] = varargs[i + 1] end
			elseif op == CLOSURE then
				local pr = protos[b]
				local ups = {}
				for i = 1, #pr.uv do
					local d = pr.uv[i]
					if d[1] == 1 then ups[i] = R[d[2]] else ups[i] = upvals[d[2] + 1] end
				end
				R[a] = makeClosure(pr, ups)
			elseif op == NEWCELL then R[a] = {}
			elseif op == CELLGET then R[a] = R[b][1]
			elseif op == CELLSET then R[a][1] = R[b]
			elseif op == BOX then R[a] = { R[a] }
			elseif op == FORPREP then
				R[a] = R[a] - R[a + 2]
				pc = pc + b
			elseif op == FORLOOP then
				local step = R[a + 2]
				local idx = R[a] + step
				R[a] = idx
				local limit = R[a + 1]
				local cont = if step >= 0 then idx <= limit else idx >= limit
				if cont then
					R[a + 3] = idx
					pc = pc + b
				end
			elseif op == TFORCALL then
				local it = R[a]
				local res
				if type(it) == "function" then
					res = table.pack(it(R[a + 1], R[a + 2]))
				else
					-- Luau generalized iteration over a table
					local nk, nv = next(it, R[a + 2])
					res = { nk, nv }
				end
				for i = 0, c - 1 do R[a + 3 + i] = res[i + 1] end
			elseif op == TFORLOOP then
				if R[a + 3] ~= nil then
					R[a + 2] = R[a + 3]
					pc = pc + b
				end
			end
		end
	end
end
]==]

-- Build the opcode-constant header from the shared list.
local function opcodeHeader(): string
	local lines = {}
	for i, name in Opcodes.LIST do
		table.insert(lines, "local " .. name .. "=" .. tostring(i))
	end
	return table.concat(lines, "\n") .. "\n"
end

-- Build the ENV initializer from the set of referenced global names.
local function envInit(globals: { string }): string
	local parts = {}
	for _, g in globals do
		-- ENV[name] = <global>   (the global resolves in the emitted scope)
		table.insert(parts, string.format("[%s]=%s", Serializer.quote(g), g))
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

-- Emit the complete VM program source for a main proto.
function Runtime.emit(mainProto: any, globals: { string }): string
	local out = {}
	table.insert(out, opcodeHeader())
	table.insert(out, "local ENV=" .. envInit(globals))
	table.insert(out, INTERP)
	table.insert(out, "local MAIN=" .. serProto(mainProto))
	table.insert(out, "return makeClosure(MAIN,{})(...)")
	return table.concat(out, "\n")
end

return Runtime
