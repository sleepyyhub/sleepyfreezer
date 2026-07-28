--!nocheck
-- Clovyre obfuscator — Roblox Studio plugin (VM / bytecode virtualization).
--
-- Adds two toolbar buttons that obfuscate the Source of the currently selected
-- Script / LocalScript / ModuleScript into a new ModuleScript beside it:
--   • "VM"          — bytecode virtualization (Clovyre)
--   • "VM+Protect"  — virtualization, then the Clovexx passes over the interpreter
--
-- Installation:
--   1. Put the bundled ModuleScript (dist/Clovyre.luau) inside this plugin as a
--      child named "Clovyre" (so it sits at script.Clovyre).
--   2. Save this folder as a Studio plugin (right-click > Save as Local Plugin).
--
-- Note: reading/writing script Source requires script-injection permission,
-- which Studio grants to local/published plugins on first use.

local Selection = game:GetService("Selection")
local Clovyre = require(script.Clovyre)

local toolbar = plugin:CreateToolbar("Clovyre")
local vmButton = toolbar:CreateButton("VM", "Virtualize the selected script", "")
local vmProtectButton = toolbar:CreateButton("VM+Protect", "Virtualize + protect the interpreter", "")

local SCRIPT_CLASSES = { Script = true, LocalScript = true, ModuleScript = true }

local function obfuscateSelected(protect: boolean)
	local selected = Selection:Get()
	if #selected == 0 then
		warn("[Clovyre] Nothing selected. Select a Script/LocalScript/ModuleScript first.")
		return
	end

	local made = 0
	for _, inst in selected do
		if SCRIPT_CLASSES[inst.ClassName] then
			local okRead, source = pcall(function()
				return inst.Source
			end)
			if not okRead then
				warn(("[Clovyre] Could not read Source of %s: %s"):format(inst:GetFullName(), tostring(source)))
				continue
			end

			local okObf, result = pcall(function()
				return Clovyre.obfuscate(source, {
					seed = math.random(1, 2 ^ 31 - 1),
					protect = protect,
					fallbackOnUnsupported = true,
				})
			end)
			if not okObf then
				warn(("[Clovyre] Failed to obfuscate %s: %s"):format(inst:GetFullName(), tostring(result)))
				continue
			end

			local out = Instance.new("ModuleScript")
			out.Name = inst.Name .. " (Clovyre)"
			out.Source = result
			out.Parent = inst.Parent
			made += 1
		end
	end

	if made > 0 then
		print(("[Clovyre] Virtualized %d script(s)%s."):format(made, protect and " (protected)" or ""))
	else
		warn("[Clovyre] No scripts were obfuscated (selection had no script objects).")
	end
end

vmButton.Click:Connect(function()
	vmButton:SetActive(false)
	local ok, err = pcall(obfuscateSelected, false)
	if not ok then warn("[Clovyre] Error: " .. tostring(err)) end
end)

vmProtectButton.Click:Connect(function()
	vmProtectButton:SetActive(false)
	local ok, err = pcall(obfuscateSelected, true)
	if not ok then warn("[Clovyre] Error: " .. tostring(err)) end
end)
