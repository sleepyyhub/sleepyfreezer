--!nolint
-- Reads a file path from arg, parses and re-serializes it, prints the result.
local Parser = require("../src/Parser")
local Serializer = require("../src/Serializer")

local path = ...
local f = assert(io.open(path, "r"))
local src = f:read("*a")
f:close()

local ast = Parser.parse(src)
local out = Serializer.serialize(ast)
io.write(out)
