--!strict
-- Opcodes.luau — the Clovyre register-VM instruction set.
-- Shared by the compiler and the emitted interpreter so numbers never drift.
-- Each instruction is {op, a, b, c} (unused operands are 0).

local Opcodes = {}

-- Ordered list; index in this list IS the opcode number (1-based).
Opcodes.LIST = {
	"LOADK",      -- A Bx    R[A] = K[Bx]
	"LOADBOOL",   -- A B     R[A] = (B ~= 0)
	"LOADNIL",    -- A       R[A] = nil
	"MOVE",       -- A B     R[A] = R[B]
	"GETGLOBAL",  -- A Bx    R[A] = ENV[K[Bx]]
	"SETGLOBAL",  -- A Bx    ENV[K[Bx]] = R[A]
	"GETUPVAL",   -- A B     R[A] = U[B][1]
	"SETUPVAL",   -- A B     U[B][1] = R[A]
	"NEWTABLE",   -- A       R[A] = {}
	"GETTABLE",   -- A B C   R[A] = R[B][R[C]]
	"SETTABLE",   -- A B C   R[A][R[B]] = R[C]
	"SETLIST",    -- A B C   R[A][C+i] = R[A+i] for i=1..(B-1 or top-A-1)
	"ADD",        -- A B C   R[A] = R[B] + R[C]
	"SUB",
	"MUL",
	"DIV",
	"MOD",
	"POW",
	"IDIV",       -- floor division //
	"CONCAT",     -- A B C   R[A] = R[B] .. R[C]
	"EQ",         -- A B C   R[A] = (R[B] == R[C])
	"NE",
	"LT",
	"LE",
	"GT",
	"GE",
	"NOT",        -- A B     R[A] = not R[B]
	"UNM",        -- A B     R[A] = -R[B]
	"LEN",        -- A B     R[A] = #R[B]
	"JMP",        -- sBx     pc += sBx
	"JMPIF",      -- A sBx   if R[A] then pc += sBx
	"JMPIFNOT",   -- A sBx   if not R[A] then pc += sBx
	"CALL",       -- A B C   R[A](R[A+1..A+B-1]) -> R[A..A+C-2]; B/C=0 => top
	"SELF",       -- A B C   R[A+1]=R[B]; R[A]=R[B][R[C]]
	"RETURN",     -- A B     return R[A..A+B-2]; B=0 => up to top
	"VARARG",     -- A B     R[A..A+B-2] = ...; B=0 => all, set top
	"CLOSURE",    -- A Bx    R[A] = closure(protos[Bx])
	"NEWCELL",    -- A       R[A] = { nil }   (fresh boxed cell)
	"CELLGET",    -- A B     R[A] = R[B][1]
	"CELLSET",    -- A B     R[A][1] = R[B]
	"BOX",        -- A       R[A] = { R[A] }  (wrap value in a fresh cell in place)
	"FORPREP",    -- A sBx   numeric-for init; jump to loop test
	"FORLOOP",    -- A sBx   numeric-for step/test
	"TFORCALL",   -- A C     generic-for: call iterator, C results
	"TFORLOOP",   -- A sBx   generic-for: test control var, loop
}

Opcodes.NUM = {} :: { [string]: number }
for i, name in Opcodes.LIST do
	Opcodes.NUM[name] = i
end

return Opcodes
