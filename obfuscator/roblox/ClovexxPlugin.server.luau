--!nocheck
-- Clovexx obfuscator — Roblox Studio plugin.
--
-- Adds a toolbar button that obfuscates the Source of the currently selected
-- Script / LocalScript / ModuleScript and writes the result into a new
-- ModuleScript named "<original> (Clovexx)" placed next to the original.
--
-- Installation:
--   1. Put the bundled ModuleScript (dist/Clovexx.luau) inside this plugin as a
--      child named "Clovexx" (so it sits at script.Clovexx), OR anywhere and
--      adjust the require below.
--   2. Save this whole folder as a Studio plugin (right-click > Save as Local
--      Plugin), or publish it as a plugin.
--
-- Note: reading/writing script Source requires script-injection permission,
-- which Studio grants to local/published plugins on first use.

local Selection = game:GetService("Selection")
local Clovexx = require(script.Clovexx)

local toolbar = plugin:CreateToolbar("Clovexx")
local button = toolbar:CreateButton(
	"Obfuscate",
	"Obfuscate the selected script's source",
	"rbxasset://textures/ui/GuiImagePlaceholder.png"
)

local SCRIPT_CLASSES = {
	Script = true,
	LocalScript = true,
	ModuleScript = true,
}

local function obfuscateSelected()
	local selected = Selection:Get()
	if #selected == 0 then
		warn("[Clovexx] Nothing selected. Select a Script/LocalScript/ModuleScript first.")
		return
	end

	local made = 0
	for _, inst in selected do
		if SCRIPT_CLASSES[inst.ClassName] then
			local ok, sourceOrErr = pcall(function()
				return inst.Source
			end)
			if not ok then
				warn(("[Clovexx] Could not read Source of %s: %s"):format(inst:GetFullName(), tostring(sourceOrErr)))
				continue
			end

			local success, result = pcall(function()
				return Clovexx.obfuscate(sourceOrErr, {
					seed = math.random(1, 2 ^ 31 - 1),
				})
			end)
			if not success then
				warn(("[Clovexx] Failed to obfuscate %s: %s"):format(inst:GetFullName(), tostring(result)))
				continue
			end

			local out = Instance.new("ModuleScript")
			out.Name = inst.Name .. " (Clovexx)"
			out.Source = result
			out.Parent = inst.Parent
			made += 1
		end
	end

	if made > 0 then
		print(("[Clovexx] Obfuscated %d script(s). New ModuleScript(s) created next to the original(s)."):format(made))
	else
		warn("[Clovexx] No scripts were obfuscated (selection had no script objects).")
	end
end

button.Click:Connect(function()
	local ok, err = pcall(obfuscateSelected)
	button:SetActive(false)
	if not ok then
		warn("[Clovexx] Error: " .. tostring(err))
	end
end)
