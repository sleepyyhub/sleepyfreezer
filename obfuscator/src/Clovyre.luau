--!strict
-- Clovyre.luau — VM-based (bytecode virtualization) obfuscator.
-- Compiles Luau to a custom register-VM proto and emits an interpreter that runs
-- it. Falls back to the source-level Clovexx obfuscator for any program using a
-- construct the VM does not yet support, so output is always correct.

local Parser = require("./Parser")
local Compiler = require("./vm/Compiler")
local Runtime = require("./vm/Runtime")
local Obfuscator = require("./Obfuscator")

local Clovyre = {}

export type Options = {
	seed: number?,
	protect: boolean?, -- also run the Clovexx passes over the emitted interpreter
	fallbackOnUnsupported: boolean?,
}

function Clovyre.obfuscate(src: string, opts: Options?): string
	local o: Options = opts or {}
	local ast = Parser.parse(src)

	local ok, result = pcall(Compiler.compile, ast)
	if not ok then
		local isUnsupported = type(result) == "table" and (result :: any).clovyre_unsupported ~= nil
		if isUnsupported and o.fallbackOnUnsupported ~= false then
			return Obfuscator.obfuscate(src, { seed = o.seed })
		end
		error(if isUnsupported then "Clovyre: unsupported construct: " .. tostring((result :: any).clovyre_unsupported) else result, 0)
	end

	local vmSource = Runtime.emit((result :: any).proto, (result :: any).globals)

	if o.protect then
		-- Rename + string-encrypt the interpreter itself (numbers/junk off to keep
		-- the proto data intact and small).
		return Obfuscator.obfuscate(vmSource, {
			seed = o.seed,
			renameLocals = true,
			encryptStrings = true,
			encodeNumbers = false,
			junk = false,
			wrap = true,
		})
	end

	return vmSource
end

return Clovyre
