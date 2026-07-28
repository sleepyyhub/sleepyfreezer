--!strict
-- Lexer.luau — tokenizer for Luau source.
-- Emits a flat array of tokens. Comments (including --! pragmas) are skipped.
-- Type-syntax punctuation (: :: -> ? & |) is emitted as ordinary symbols so the
-- parser can consume-and-discard Luau type annotations.

local Lexer = {}

export type Token = {
	kind: string, -- "Name" | "Keyword" | "Number" | "String" | "InterpString" | "Symbol" | "Eof"
	value: string, -- raw lexeme (for String: the decoded value; for InterpString: "")
	parts: { InterpPart }?, -- only for InterpString
	line: number,
}

export type InterpPart = {
	kind: string, -- "lit" | "expr"
	value: string, -- lit: decoded text; expr: raw Luau source of the {expression}
}

local KEYWORDS: { [string]: boolean } = {
	["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true,
	["elseif"] = true, ["end"] = true, ["false"] = true, ["for"] = true,
	["function"] = true, ["if"] = true, ["in"] = true, ["local"] = true,
	["nil"] = true, ["not"] = true, ["or"] = true, ["repeat"] = true,
	["return"] = true, ["then"] = true, ["true"] = true, ["until"] = true,
	["while"] = true, ["continue"] = true,
}

-- Multi-char symbols, longest first so greedy matching works.
local SYMBOLS = {
	"...", "..=", "//=", "::", "->", "==", "~=", "<=", ">=", "..",
	"+=", "-=", "*=", "/=", "%=", "^=", "//",
	"+", "-", "*", "/", "%", "^", "#", "&", "|", "?",
	"(", ")", "{", "}", "[", "]", ";", ":", ",", ".", "<", ">", "=",
}

local function isDigit(c: string): boolean
	return c >= "0" and c <= "9"
end

local function isHexDigit(c: string): boolean
	return isDigit(c) or (c >= "a" and c <= "f") or (c >= "A" and c <= "F")
end

local function isAlpha(c: string): boolean
	return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_"
end

local function isAlphaNum(c: string): boolean
	return isAlpha(c) or isDigit(c)
end

type State = {
	src: string,
	pos: number,
	line: number,
	len: number,
}

local function peek(s: State, o: number?): string
	local i = s.pos + (o or 0)
	if i > s.len then return "" end
	return string.sub(s.src, i, i)
end

local function err(s: State, msg: string): never
	error(string.format("Lexer error (line %d): %s", s.line, msg), 0)
end

-- Reads a long-bracket body starting at `[`; returns text and new pos, or nil if
-- the position isn't actually a long bracket. `level` is number of '=' signs.
local function readLongBracket(s: State): (string?, number?)
	local start = s.pos
	if peek(s) ~= "[" then return nil, nil end
	local i = s.pos + 1
	local level = 0
	while string.sub(s.src, i, i) == "=" do
		level += 1
		i += 1
	end
	if string.sub(s.src, i, i) ~= "[" then
		return nil, nil -- not a long bracket, just a '['
	end
	i += 1
	-- A newline immediately after the opening bracket is skipped.
	if string.sub(s.src, i, i) == "\r" then i += 1 end
	if string.sub(s.src, i, i) == "\n" then
		s.line += 1
		i += 1
	end
	local close = "]" .. string.rep("=", level) .. "]"
	local endIdx = string.find(s.src, close, i, true)
	if not endIdx then
		s.pos = start
		err(s, "unterminated long bracket")
	end
	local body = string.sub(s.src, i, endIdx - 1)
	for _ in string.gmatch(body, "\n") do s.line += 1 end
	return body, endIdx + #close
end

local function skipTrivia(s: State)
	while s.pos <= s.len do
		local c = peek(s)
		if c == "\n" then
			s.line += 1
			s.pos += 1
		elseif c == " " or c == "\t" or c == "\r" or c == "\v" or c == "\f" then
			s.pos += 1
		elseif c == "-" and peek(s, 1) == "-" then
			s.pos += 2
			-- block comment?
			if peek(s) == "[" then
				local body, newPos = readLongBracket(s)
				if body ~= nil then
					s.pos = newPos :: number
					continue
				end
			end
			-- line comment
			while s.pos <= s.len and peek(s) ~= "\n" do
				s.pos += 1
			end
		else
			break
		end
	end
end

local ESCAPES: { [string]: string } = {
	a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v",
	["\\"] = "\\", ['"'] = '"', ["'"] = "'", ["\n"] = "\n", ["\r"] = "\r",
}

local function utf8Encode(cp: number): string
	if utf8 and utf8.char then
		return utf8.char(cp)
	end
	return string.char(cp % 256) -- fallback; sample scripts rarely need this
end

-- Reads a quoted string body (after the opening quote consumed). Returns decoded value.
local function readQuoted(s: State, quote: string): string
	local out = {}
	while true do
		local c = peek(s)
		if c == "" then err(s, "unterminated string") end
		if c == quote then
			s.pos += 1
			break
		elseif c == "\n" then
			err(s, "unterminated string (newline)")
		elseif c == "\\" then
			s.pos += 1
			local e = peek(s)
			if e == "x" then
				s.pos += 1
				local h = string.sub(s.src, s.pos, s.pos + 1)
				if not (isHexDigit(string.sub(h, 1, 1)) and isHexDigit(string.sub(h, 2, 2))) then
					err(s, "bad \\x escape")
				end
				table.insert(out, string.char(tonumber(h, 16) :: number))
				s.pos += 2
			elseif e == "z" then
				s.pos += 1
				while true do
					local w = peek(s)
					if w == " " or w == "\t" or w == "\r" or w == "\v" or w == "\f" then
						s.pos += 1
					elseif w == "\n" then
						s.line += 1
						s.pos += 1
					else
						break
					end
				end
			elseif e == "u" then
				s.pos += 1
				if peek(s) ~= "{" then err(s, "bad \\u escape") end
				s.pos += 1
				local hs = ""
				while isHexDigit(peek(s)) do
					hs ..= peek(s)
					s.pos += 1
				end
				if peek(s) ~= "}" then err(s, "unterminated \\u escape") end
				s.pos += 1
				table.insert(out, utf8Encode(tonumber(hs, 16) :: number))
			elseif isDigit(e) then
				local ds = ""
				for _ = 1, 3 do
					if isDigit(peek(s)) then
						ds ..= peek(s)
						s.pos += 1
					else
						break
					end
				end
				table.insert(out, string.char(tonumber(ds) :: number))
			elseif ESCAPES[e] ~= nil then
				if e == "\n" then s.line += 1 end
				table.insert(out, ESCAPES[e])
				s.pos += 1
			else
				err(s, "invalid escape '\\" .. e .. "'")
			end
		else
			table.insert(out, c)
			s.pos += 1
		end
	end
	return table.concat(out)
end

-- Reads an interpolated string `...`. Returns list of parts.
local function readInterp(s: State): { InterpPart }
	local parts: { InterpPart } = {}
	local lit = {}
	local function flushLit()
		if #lit > 0 then
			table.insert(parts, { kind = "lit", value = table.concat(lit) })
			lit = {}
		end
	end
	while true do
		local c = peek(s)
		if c == "" then err(s, "unterminated interpolated string") end
		if c == "`" then
			s.pos += 1
			break
		elseif c == "\\" then
			-- interpolation supports the same escapes plus \` and \{
			s.pos += 1
			local e = peek(s)
			if e == "`" or e == "{" or e == "}" then
				table.insert(lit, e)
				s.pos += 1
			elseif ESCAPES[e] ~= nil then
				if e == "\n" then s.line += 1 end
				table.insert(lit, ESCAPES[e])
				s.pos += 1
			elseif e == "x" then
				s.pos += 1
				local h = string.sub(s.src, s.pos, s.pos + 1)
				table.insert(lit, string.char(tonumber(h, 16) :: number))
				s.pos += 2
			elseif isDigit(e) then
				local ds = ""
				for _ = 1, 3 do
					if isDigit(peek(s)) then ds ..= peek(s); s.pos += 1 else break end
				end
				table.insert(lit, string.char(tonumber(ds) :: number))
			else
				table.insert(lit, e)
				s.pos += 1
			end
		elseif c == "{" then
			flushLit()
			s.pos += 1
			-- capture balanced expression source (respecting nested braces/strings)
			local depth = 1
			local exprStart = s.pos
			while depth > 0 do
				local d = peek(s)
				if d == "" then err(s, "unterminated interpolation expression") end
				if d == "{" then
					depth += 1; s.pos += 1
				elseif d == "}" then
					depth -= 1
					if depth == 0 then break end
					s.pos += 1
				elseif d == '"' or d == "'" then
					s.pos += 1
					readQuoted(s, d)
				elseif d == "`" then
					s.pos += 1
					readInterp(s)
				elseif d == "\n" then
					s.line += 1; s.pos += 1
				else
					s.pos += 1
				end
			end
			local exprSrc = string.sub(s.src, exprStart, s.pos - 1)
			table.insert(parts, { kind = "expr", value = exprSrc })
			s.pos += 1 -- consume '}'
		elseif c == "\n" then
			err(s, "unterminated interpolated string (newline)")
		else
			table.insert(lit, c)
			s.pos += 1
		end
	end
	flushLit()
	if #parts == 0 then
		parts = { { kind = "lit", value = "" } }
	end
	return parts
end

local function readNumber(s: State): string
	local start = s.pos
	if peek(s) == "0" and (peek(s, 1) == "x" or peek(s, 1) == "X") then
		s.pos += 2
		while isHexDigit(peek(s)) or peek(s) == "_" or peek(s) == "." do s.pos += 1 end
		if peek(s) == "p" or peek(s) == "P" then
			s.pos += 1
			if peek(s) == "+" or peek(s) == "-" then s.pos += 1 end
			while isDigit(peek(s)) or peek(s) == "_" do s.pos += 1 end
		end
	elseif peek(s) == "0" and (peek(s, 1) == "b" or peek(s, 1) == "B") then
		s.pos += 2
		while peek(s) == "0" or peek(s) == "1" or peek(s) == "_" do s.pos += 1 end
	else
		while isDigit(peek(s)) or peek(s) == "_" do s.pos += 1 end
		if peek(s) == "." then
			s.pos += 1
			while isDigit(peek(s)) or peek(s) == "_" do s.pos += 1 end
		end
		if peek(s) == "e" or peek(s) == "E" then
			s.pos += 1
			if peek(s) == "+" or peek(s) == "-" then s.pos += 1 end
			while isDigit(peek(s)) or peek(s) == "_" do s.pos += 1 end
		end
	end
	return string.sub(s.src, start, s.pos - 1)
end

function Lexer.tokenize(src: string): { Token }
	local s: State = { src = src, pos = 1, line = 1, len = #src }
	-- skip shebang-style first line if present (rare)
	local tokens: { Token } = {}

	while true do
		skipTrivia(s)
		if s.pos > s.len then
			table.insert(tokens, { kind = "Eof", value = "", line = s.line })
			break
		end
		local c = peek(s)
		local line = s.line

		if isAlpha(c) then
			local start = s.pos
			while isAlphaNum(peek(s)) do s.pos += 1 end
			local word = string.sub(s.src, start, s.pos - 1)
			table.insert(tokens, {
				kind = if KEYWORDS[word] then "Keyword" else "Name",
				value = word, line = line,
			})
		elseif isDigit(c) or (c == "." and isDigit(peek(s, 1))) then
			table.insert(tokens, { kind = "Number", value = readNumber(s), line = line })
		elseif c == '"' or c == "'" then
			s.pos += 1
			local v = readQuoted(s, c)
			table.insert(tokens, { kind = "String", value = v, line = line })
		elseif c == "`" then
			s.pos += 1
			local parts = readInterp(s)
			table.insert(tokens, { kind = "InterpString", value = "", parts = parts, line = line })
		elseif c == "[" and (peek(s, 1) == "[" or peek(s, 1) == "=") then
			local body, newPos = readLongBracket(s)
			if body ~= nil then
				s.pos = newPos :: number
				table.insert(tokens, { kind = "String", value = body :: string, line = line })
			else
				s.pos += 1
				table.insert(tokens, { kind = "Symbol", value = "[", line = line })
			end
		else
			local matched: string? = nil
			for _, sym in SYMBOLS do
				if string.sub(s.src, s.pos, s.pos + #sym - 1) == sym then
					matched = sym
					break
				end
			end
			if not matched then err(s, "unexpected character '" .. c .. "'") end
			s.pos += #(matched :: string)
			table.insert(tokens, { kind = "Symbol", value = matched :: string, line = line })
		end
	end

	return tokens
end

return Lexer
