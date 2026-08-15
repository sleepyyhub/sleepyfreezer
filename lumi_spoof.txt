--!nocheck
-- Luminosity Spoof - RNG Machine visual spoof for "Steal a Brainrot"
-- Client-side only. Nothing here is sent to the server; the offer you buy is
-- still the real one. This only changes what your client draws.
--
-- Verified against the live client (place 109983668079237):
--   RNGMachineController.renderModel    -> BrainrotAssets.getModelBestEffort(Offer.Name, cb, 20)
--   RNGMachineController._setupLandedBrainrot -> prompt.ObjectText = Offer.Name
--   RNGMachineController.createLandedOverhead -> AnimalOverheadController:Populate{Index = Offer.Name}
--   Datas.Animals is keyed by Index; DisplayName is a separate field.

local Players           = game:GetService("Players")
local UIS               = game:GetService("UserInputService")
local TS                = game:GetService("TweenService")
local RepS              = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local LP                = Players.LocalPlayer
local PG                = LP:WaitForChild("PlayerGui")
local IS_MOBILE         = UIS.TouchEnabled and not UIS.KeyboardEnabled and not UIS.MouseEnabled

local L = {}

local T = {
    VOID    = Color3.fromRGB(6, 6, 14),
    SURFACE = Color3.fromRGB(14, 18, 32),
    RAISED  = Color3.fromRGB(22, 28, 48),
    FIELD   = Color3.fromRGB(10, 14, 28),
    LINE    = Color3.fromRGB(40, 55, 95),
    ACCENT  = Color3.fromRGB(100, 170, 255),
    GLOW    = Color3.fromRGB(80, 140, 255),
    HIGH    = Color3.fromRGB(190, 225, 255),
    DEEP    = Color3.fromRGB(55, 100, 200),
    TEXT    = Color3.fromRGB(235, 240, 255),
    MUTED   = Color3.fromRGB(110, 135, 175),
    RED     = Color3.fromRGB(255, 110, 140),
    GREEN   = Color3.fromRGB(130, 255, 95),
    ORANGE  = Color3.fromRGB(255, 185, 110),
    PURPLE  = Color3.fromRGB(175, 135, 255),
    WHITE   = Color3.fromRGB(255, 255, 255),
    CYAN    = Color3.fromRGB(100, 230, 255),
}

local function safe(fn, ...) local ok, r = pcall(fn, ...); return ok and r or nil end
local function alive(i) return i and typeof(i) == "Instance" and i.Parent ~= nil end
local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function esc(s) return (s:gsub("(%W)", "%%%1")) end

local function findModule(parentName, childName)
    local folder = RepS:FindFirstChild(parentName)
    local m = folder and folder:FindFirstChild(childName)
    if m and m:IsA("ModuleScript") then return m end
    for _, d in ipairs(RepS:GetDescendants()) do
        if d:IsA("ModuleScript") and d.Name == childName then return d end
    end
    return nil
end

local function loadModule(parentName, childName)
    local m = findModule(parentName, childName)
    if not m then return nil end
    local v = safe(require, m)
    return (type(v) == "table") and v or nil
end

L.BrainrotAssets = loadModule("Shared",      "BrainrotAssets")
L.Animals        = loadModule("Shared",      "Animals")
L.CustomRichText = loadModule("Controllers", "CustomRichTextController")
L.AnimalOverhead = loadModule("Controllers", "AnimalOverheadController")
L.AnimalData     = loadModule("Datas",       "Animals")
L.MutationData   = loadModule("Datas",       "Mutations")

-- ---------------------------------------------------------------------------
-- Name pool.
--
-- Every consumer in the game indexes Datas.Animals by the *key* (what the
-- controller calls "Index"), not by DisplayName:
--   Animals:GetPrice(name)  -> Animals[name].Price          (unguarded index)
--   AOC.Populate            -> Animals[Index].Rarity        (unguarded index)
--   createLandedOverhead    -> Animals[ResultName].HideOverhead
-- so a spoofed name that is not a key produces either a hard error or a
-- silently missing overhead. 8 of the 541 entries have a DisplayName that
-- differs from the key, and four separate Lucky Block keys share the single
-- DisplayName "Lucky Block" -- picking that name breaks the roll outright.
--
-- So: the pool holds keys, and the UI shows DisplayName purely as a label.
-- ---------------------------------------------------------------------------
L.AllNames = {}      -- array of keys (Index values)
L.Label = {}         -- key -> text shown in the list
L.AllMutations = {"Normal"}

L.LoadPools = function()
    if #L.AllNames == 0 and type(L.AnimalData) == "table" then
        local displayCount = {}
        for key, info in pairs(L.AnimalData) do
            if type(key) == "string" and type(info) == "table" then
                local dn = (type(info.DisplayName) == "string") and info.DisplayName or key
                displayCount[dn] = (displayCount[dn] or 0) + 1
            end
        end
        for key, info in pairs(L.AnimalData) do
            if type(key) == "string" and type(info) == "table" then
                local dn = (type(info.DisplayName) == "string") and info.DisplayName or key
                -- Disambiguate collisions ("Lucky Block" x4) so every row maps
                -- to exactly one key and the user can tell them apart.
                L.Label[key] = (displayCount[dn] > 1 and dn ~= key)
                    and ("%s (%s)"):format(dn, key) or dn
                L.AllNames[#L.AllNames + 1] = key
            end
        end
        table.sort(L.AllNames, function(a, b)
            local la, lb = L.Label[a] or a, L.Label[b] or b
            if la == lb then return a < b end
            return la < lb
        end)
    end
    if #L.AllMutations == 1 and type(L.MutationData) == "table" then
        for key in pairs(L.MutationData) do
            if type(key) == "string" then L.AllMutations[#L.AllMutations + 1] = key end
        end
        table.sort(L.AllMutations, function(a, b)
            if a == "Normal" then return true end
            if b == "Normal" then return false end
            return a < b
        end)
    end
    return #L.AllNames > 0
end
L.LoadPools()

L.DisplayOf = function(key) return L.Label[key] or tostring(key) end

L.MutationDisplay = function(mut)
    if not mut or mut == "Normal" then return "" end
    local d = type(L.MutationData) == "table" and L.MutationData[mut]
    if type(d) ~= "table" then return mut end
    return d.DisplayWithRichText or d.DisplayText or mut
end

local genv = (type(getgenv) == "function") and safe(getgenv) or nil
local Store = genv and genv.__LuminositySpoof
if type(Store) ~= "table" then
    Store = {Installed = false, Orig = {}, Owner = {}}
    if genv then genv.__LuminositySpoof = Store end
end

L.Enabled     = false
L.FakeName    = nil
L.FakeMut     = "Normal"
L.SpoofMut    = false
L.ForceUnlock = false
L.HideOdds    = true
L.KeepAfterBuy = true
Store.Cfg     = L

L.RealName, L.RealMut, L.MachineState = nil, nil, "Idle"
L.LastRead = 0
L.SpoofLuck = false
L.FakeLuck = 25
L.LUCKS = {2, 4, 6, 8, 10, 12, 15, 20, 25, 30, 35}

-- ---------------------------------------------------------------------------
-- Where the roll actually comes from.
--
-- The controller does NOT render from the RNGMachine_<userid> replicator --
-- that one only carries State/SpinCosts/SkillTree. _reconcileActivityDisplay
-- calls getSelectedActivity(), which reads
--     RNGMachineActivity.Data.Sessions[tostring(UserId)]
-- and hands that session straight to _renderActivityOffer, which reads
-- Offer.Name (model + overhead + prompt) and session.Multiplier (luck VFX).
--
-- So that session table is the single source every visual comes from. Editing
-- it in place and letting the game render normally is what makes the result
-- identical to a genuine roll, instead of repainting the aftermath.
-- ---------------------------------------------------------------------------
L.Reps = {}

L.GetRep = function(id)
    if L.Reps[id] then return L.Reps[id] end
    local pkgs = RepS:FindFirstChild("Packages")
    local mod = pkgs and pkgs:FindFirstChild("ReplicatorClient")
    if not mod then return nil end
    local RC = safe(require, mod)
    if type(RC) ~= "table" or type(RC.get) ~= "function" then return nil end
    L.Reps[id] = safe(RC.get, id)
    return L.Reps[id]
end

L.Session = function()
    local a = L.GetRep("RNGMachineActivity")
    local d = a and safe(function() return a.Data end)
    if type(d) ~= "table" or type(d.Sessions) ~= "table" then return nil end
    local s = d.Sessions[tostring(LP.UserId)]
    return (type(s) == "table") and s or nil
end

L.Controller = function()
    if L.Ctl then return L.Ctl end
    L.Ctl = loadModule("Controllers", "RNGMachineController")
    return L.Ctl
end

-- Models are not preloaded (ReplicatedStorage.Models.Animals is empty); they
-- stream on demand. getModelBestEffort returns nil for anything not already
-- resident and only delivers through its callback, and renderModel throws that
-- callback away if the stage token moved on while the asset was in flight --
-- which is exactly why the spoofed model kept failing to appear. Requesting it
-- up front puts it in the AssetStreamController cache so the callback resolves
-- immediately.
L.Warm = function(name)
    if type(name) ~= "string" then return end
    local ASC = loadModule("Controllers", "AssetStreamController")
    if ASC and type(ASC.requestAssets) == "function" then
        safe(ASC.requestAssets, "m", {name})
    end
end

L.Locked = {}
L.LockedMut = {}

L.LockCurrent = function()
    if not L.KeepAfterBuy then return end
    if not (L.Enabled and L.RealName and L.FakeName) then return end
    if L.RealName == L.FakeName then return end
    L.Locked[L.RealName] = L.FakeName
    L.LockedMut[L.RealName] = L.SpoofMut and L.FakeMut or nil
end

L.ClearLocked = function()
    table.clear(L.Locked)
    table.clear(L.LockedMut)
end

L.ReadOffer = function()
    local s = L.Session()
    if not s then
        if L.RealName then L.LockCurrent() end
        L.RealName, L.RealMut, L.MachineState = nil, nil, "Idle"
        return nil, nil
    end
    L.MachineState = s.State or "Idle"
    local offer = s.Offer
    if L.MachineState == "Offer" and type(offer) == "table" then
        -- Once spoofed, Offer.Name holds the fake, so the untouched original is
        -- kept alongside it rather than re-read from a field we overwrote.
        L.RealName = offer.__LumiReal or offer.Name
        L.RealMut  = offer.__LumiRealMut ~= nil and offer.__LumiRealMut or offer.Mutation
        if L.RealMut == false then L.RealMut = nil end
    else
        -- Offer gone: bought or expired. Pin the pair so a bought brainrot
        -- keeps the face it was sold under.
        if L.RealName then L.LockCurrent() end
        L.RealName, L.RealMut = nil, nil
    end
    return L.RealName, L.RealMut
end

-- Rewrite the session in place. Returns true only when something actually
-- changed, so the steady state costs nothing and we never re-render on a tick
-- where there was no work to do.
L.ApplyToSession = function(s)
    if not (L.Enabled and L.FakeName) then return false end
    if type(s) ~= "table" or s.State ~= "Offer" then return false end
    local o = s.Offer
    if type(o) ~= "table" then return false end

    local real = o.__LumiReal or o.Name
    if type(real) ~= "string" then return false end
    if not (L.AnimalData and L.AnimalData[real]) then return false end

    local fake = L.Locked[real] or L.FakeName
    if not (L.AnimalData and L.AnimalData[fake]) then return false end

    local changed = false

    if o.Name ~= fake then
        if o.__LumiReal == nil then o.__LumiReal = real end
        o.Name = fake
        changed = true
    end

    if L.SpoofMut or L.LockedMut[real] ~= nil then
        local want = L.SwapMut(o.__LumiRealMut ~= nil and o.__LumiRealMut or o.Mutation, real)
        if o.__LumiRealMut == nil then o.__LumiRealMut = o.Mutation or false end
        if o.Mutation ~= want then
            o.Mutation = want
            changed = true
        end
    end

    -- session.Multiplier is what setLuckySpinVfx() is given, so this is the
    -- luck explosion / spin colouring a real high roll comes with.
    if L.SpoofLuck then
        if s.__LumiRealMult == nil then s.__LumiRealMult = s.Multiplier or false end
        if s.Multiplier ~= L.FakeLuck then
            s.Multiplier = L.FakeLuck
            changed = true
        end
    end

    if changed then L.Warm(fake) end
    return changed
end

-- _reconcileActivityDisplay short-circuits whenever its identity string
-- ("<UserId>:Offer:<ExpiresAt>") is unchanged, so editing the session alone
-- will not redraw anything. _renderActivityOffer is public on the controller
-- and is the exact call the game makes itself, so driving it directly gives a
-- real render rather than a patched-up one.
L.ForceRender = function(s)
    local C = L.Controller()
    if not C or type(C._renderActivityOffer) ~= "function" then return false end
    if type(s) ~= "table" or s.State ~= "Offer" or type(s.Offer) ~= "table" then return false end
    return safe(function() C:_renderActivityOffer(s, true) end) ~= nil or true
end

-- Runs on every replicator update and on the poll tick.
L.Sync = function(force)
    local s = L.Session()
    if not s then return end
    local changed = L.ApplyToSession(s)
    if changed or force then L.ForceRender(s) end
end

L.Active = function()
    if not L.Enabled then return false end
    if not L.FakeName then return false end
    L.ReadOffer()
    return L.RealName ~= nil
end

-- Re-entrancy guard. Several hooked functions call each other
-- (ColorBrainrotName -> GetAnimalTag + GetDisplayName, GetSellValue ->
-- GetPrice). Swapping at every level would map an already-swapped name a
-- second time; the original only ever resolves once, so we do too.
local depth = 0

L.SwapName = function(n)
    if type(n) ~= "string" then return n end
    if not L.Enabled then return n end
    if depth > 1 then return n end
    local locked = L.Locked[n]
    if locked then return locked end
    if not L.Active() then return n end
    if n ~= L.RealName then return n end
    return L.FakeName
end

L.SwapMut = function(m, realName)
    if not L.Enabled then return m end
    if depth > 1 then return m end
    if realName and L.LockedMut[realName] ~= nil then
        local v = L.LockedMut[realName]
        return (v ~= "Normal") and v or nil
    end
    if not L.SpoofMut then return m end
    if L.FakeMut == "Normal" then return nil end
    return L.FakeMut
end

L.StripOdds = function(text)
    if not (L.Enabled and L.HideOdds) then return text end
    if type(text) ~= "string" then return text end
    if not text:lower():find("1 in", 1, true) then return text end
    local out = text:gsub("[1I]%s*[iI][nN]%s*[%d][%d%.,]*%s*[KMBTQkmbtq]?", "")
    out = out:gsub("%s*[%-|·]%s*$", ""):gsub("^%s*[%-|·]%s*", "")
    return (out:gsub("%s%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- ---------------------------------------------------------------------------
-- Hooks
--
-- Everything the machine draws already flows through these functions, so the
-- game renders the spoofed brainrot through its own code path: real model,
-- real VFX, real overhead, real landing animation. No cloning, no parking, no
-- second model in the workspace.
-- ---------------------------------------------------------------------------

-- (module key, function name, which argument holds the brainrot name)
-- getEffect(effectName) and getEventAsset(category, name) do NOT take a
-- brainrot name -- hooking them corrupts spawn-effect and event lookups.
local BA_FNS = {"getModel", "getModelBestEffort", "getSize", "getTrait", "preload"}

local AN_NAME_FNS = {
    "GetDisplayName", "ColorBrainrotName", "GetRarityStringFormat",
    "GetRarityWeight", "GetAnimalTag", "GetGeneration", "GetGenerationNoTraits",
    "GetSellValue", "GetPrice", "GetZoom", "GetBoundingBox",
    "GetAnimatedModel", "AttachOnViewport", "AttachOnViewportWithOptimizations",
}

L.Install = function()
    if Store.Installed then return true end
    local BA, AN, CRT, AOC = L.BrainrotAssets, L.Animals, L.CustomRichText, L.AnimalOverhead
    if not (BA and AN and CRT and AOC) then return false end

    local O = Store.Orig
    Store.Owner = {BA = BA, AN = AN, CRT = CRT, AOC = AOC}

    -- BrainrotAssets.*(name, ...) -- plain dot calls, name is always arg 1.
    for _, fname in ipairs(BA_FNS) do
        local orig = BA[fname]
        if type(orig) == "function" then
            O["BA." .. fname] = orig
            BA[fname] = function(name, ...)
                depth += 1
                local a, b, c = pcall(orig, L.SwapName(name), ...)
                depth -= 1
                if not a then error(b, 0) end
                return b, c
            end
        end
    end

    -- Animals:*(name, ...) -- colon calls, so arg 1 is self and arg 2 is the
    -- name. Guarded for the handful of dot-call sites.
    for _, fname in ipairs(AN_NAME_FNS) do
        local orig = AN[fname]
        if type(orig) == "function" then
            O["AN." .. fname] = orig
            AN[fname] = function(a, b, ...)
                depth += 1
                local ok, r1, r2
                if type(a) == "string" then
                    ok, r1, r2 = pcall(orig, L.SwapName(a), b, ...)
                else
                    ok, r1, r2 = pcall(orig, a, L.SwapName(b), ...)
                end
                depth -= 1
                if not ok then error(r1, 0) end
                return r1, r2
            end
        end
    end

    -- Animals:ApplyMutation(model, name, mutation) and
    -- Animals:ApplyTraits(model, name, traits) both carry the name in arg 3.
    -- The generic wrapper above would have swapped the *model* here.
    for _, fname in ipairs({"ApplyMutation", "ApplyTraits"}) do
        local orig = AN[fname]
        if type(orig) == "function" then
            O["AN." .. fname] = orig
            AN[fname] = function(self, model, name, fourth, ...)
                depth += 1
                local swapped = L.SwapName(name)
                local arg4 = (fname == "ApplyMutation") and L.SwapMut(fourth, name) or fourth
                local ok, r = pcall(orig, self, model, swapped, arg4, ...)
                depth -= 1
                if not ok then error(r, 0) end
                return r
            end
        end
    end

    -- IsLocked(self, cfg) takes a *table* with an .Index field, not a string.
    -- Comparing that table against a name string never matched, which is why
    -- Force Unlock did nothing.
    do
        local orig = AN.IsLocked
        if type(orig) == "function" then
            O["AN.IsLocked"] = orig
            AN.IsLocked = function(self, cfg, ...)
                if L.Enabled and L.ForceUnlock and type(cfg) == "table" then
                    local idx = cfg.Index
                    if type(idx) == "string" and (idx == L.RealName or L.Locked[idx]) then
                        return false
                    end
                end
                if L.Enabled and type(cfg) == "table" and type(cfg.Index) == "string" then
                    local swapped = L.SwapName(cfg.Index)
                    if swapped ~= cfg.Index then
                        local copy = table.clone(cfg)
                        copy.Index = swapped
                        depth += 1
                        local ok, r = pcall(orig, self, copy, ...)
                        depth -= 1
                        if ok then return r end
                    end
                end
                return orig(self, cfg, ...)
            end
        end
    end

    -- The machine's mutation screen goes through CustomRichTextController.apply
    -- (updateMutationScreen -> apply(label, text, {attachToInstance = true})).
    if type(CRT.apply) == "function" then
        O["CRT.apply"] = CRT.apply
        CRT.apply = function(label, text, ...)
            if L.Enabled and typeof(label) == "Instance" then
                local isScreen = safe(function()
                    return CollectionService:HasTag(label, "RNGMachineMutationScreen")
                end)
                if isScreen and L.SpoofMut then
                    text = L.MutationDisplay(L.FakeMut)
                elseif type(text) == "string" then
                    text = L.StripOdds(text)
                    for real, fake in pairs(L.Locked) do
                        text = text:gsub(esc(real), L.DisplayOf(fake))
                        text = text:gsub(esc(L.DisplayOf(real)), L.DisplayOf(fake))
                    end
                    if L.Active() and L.RealName ~= L.FakeName then
                        text = text:gsub(esc(L.RealName), L.DisplayOf(L.FakeName))
                        text = text:gsub(esc(L.DisplayOf(L.RealName)), L.DisplayOf(L.FakeName))
                    end
                end
            end
            return O["CRT.apply"](label, text, ...)
        end
    end

    -- AnimalOverheadController:Populate{Index = ...} builds the floating name,
    -- price, rarity and mutation. Swapping Index here fixes all four at once,
    -- because Populate reads Datas.Animals[Index] for every one of them.
    if type(AOC.Populate) == "function" then
        O["AOC.Populate"] = AOC.Populate
        AOC.Populate = function(self, cfg, ...)
            if type(cfg) == "table" and L.Enabled then
                local realIndex = cfg.Index
                if type(realIndex) == "string" then
                    local swapped = L.SwapName(realIndex)
                    if swapped ~= realIndex and L.AnimalData and L.AnimalData[swapped] then
                        cfg.Index = swapped
                    end
                end
                if L.SpoofMut or (type(realIndex) == "string" and L.LockedMut[realIndex] ~= nil) then
                    cfg.Mutation = L.SwapMut(cfg.Mutation, realIndex)
                end
            end
            depth += 1
            local ok, r = pcall(O["AOC.Populate"], self, cfg, ...)
            depth -= 1
            if not ok then error(r, 0) end
            return r
        end
    end

    -- Called directly by Populate but also from other overhead paths.
    if type(AOC.ResolveDisplayName) == "function" then
        O["AOC.ResolveDisplayName"] = AOC.ResolveDisplayName
        AOC.ResolveDisplayName = function(self, index, traits, ...)
            depth += 1
            local ok, r = pcall(O["AOC.ResolveDisplayName"], self, L.SwapName(index), traits, ...)
            depth -= 1
            if not ok then error(r, 0) end
            return r
        end
    end

    Store.Installed = true
    return true
end

L.Uninstall = function()
    if not Store.Installed then return end
    local O, W = Store.Orig, Store.Owner
    local map = {BA = W.BA, AN = W.AN, CRT = W.CRT, AOC = W.AOC}
    for key, fn in pairs(O) do
        local mod, name = key:match("^(%w+)%.(.+)$")
        local target = mod and map[mod]
        if target then target[name] = fn end
    end
    table.clear(O)
    Store.Installed = false
end

-- ---------------------------------------------------------------------------
-- World enforcement
-- ---------------------------------------------------------------------------

L.Machine = function()
    local m = workspace:FindFirstChild("RNGMachine")
    return alive(m) and m or nil
end

-- The rolled brainrot is NOT parented under RNGMachine. renderModel creates a
-- folder called RNGMachineDisplay directly under workspace and puts the model
-- (and its Purchase prompt) in there.
L.Display = function()
    local f = workspace:FindFirstChild("RNGMachineDisplay")
    return alive(f) and f or nil
end

-- renderModel caches display models in a local table keyed
-- "Brainrot:<Offer.Name>:<mutation>" and reuses one while its .Parent is set.
-- Because the key is built from Offer.Name, spoofing the name at the source
-- changes the key too, so a stale real-name model is never reused. Clearing
-- the folder is only needed when going back to unspoofed.
L.Refresh = function()
    local f = L.Display()
    if not f then return end
    for _, c in ipairs(f:GetChildren()) do
        safe(function() c:Destroy() end)
    end
end

-- Restore a session we previously edited, so turning the spoof off puts the
-- real roll back instead of leaving the fake frozen on screen.
L.RestoreSession = function()
    local s = L.Session()
    if type(s) ~= "table" then return false end
    local changed = false
    local o = s.Offer
    if type(o) == "table" then
        if o.__LumiReal ~= nil then o.Name, o.__LumiReal, changed = o.__LumiReal, nil, true end
        if o.__LumiRealMut ~= nil then
            o.Mutation = (o.__LumiRealMut ~= false) and o.__LumiRealMut or nil
            o.__LumiRealMut, changed = nil, true
        end
    end
    if s.__LumiRealMult ~= nil then
        s.Multiplier = (s.__LumiRealMult ~= false) and s.__LumiRealMult or nil
        s.__LumiRealMult, changed = nil, true
    end
    if changed then L.ForceRender(s) end
    return changed
end

L.LastSweep = 0

L.Enforce = function()
    if not L.Enabled then return end

    local fakeDisplay = L.FakeName and L.DisplayOf(L.FakeName) or nil

    -- The Purchase prompt is built with ObjectText = Offer.Name and never goes
    -- through any hooked function, so it has to be rewritten in place.
    local disp = L.Display()
    if disp and fakeDisplay then
        for _, d in ipairs(disp:GetDescendants()) do
            if d:IsA("ProximityPrompt") then
                local want = L.Locked[d.ObjectText] or
                    ((L.Active() and d.ObjectText == L.RealName) and L.FakeName or nil)
                if want then
                    local text = L.DisplayOf(want)
                    if d.ObjectText ~= text then d.ObjectText = text end
                end
            end
        end
    end

    local m = L.Machine()
    if m then
        if L.HideOdds then
            for _, d in ipairs(m:GetDescendants()) do
                if d:IsA("TextLabel") or d:IsA("TextButton") then
                    local stripped = L.StripOdds(d.Text)
                    if stripped ~= d.Text then d.Text = stripped end
                end
            end
        end

        if L.SpoofMut then
            for _, part in ipairs(CollectionService:GetTagged("RNGMachineMutationScreenLine")) do
                if part:IsA("BasePart") and part:IsDescendantOf(workspace) then
                    part.LocalTransparencyModifier = (L.FakeMut ~= "Normal") and 1 or 0
                end
            end
        end
    end
end

L.Reapply = function()
    if not L.Enabled then
        L.RestoreSession()
        L.Refresh()
        return
    end
    L.ReadOffer()
    L.Warm(L.FakeName)
    -- Re-point the session at the new choice, then force one render so a name
    -- picked mid-offer takes effect instead of waiting for the next roll.
    local s = L.Session()
    if s then
        local o = s.Offer
        if type(o) == "table" and o.__LumiReal ~= nil then o.Name = o.__LumiReal end
        L.ApplyToSession(s)
        L.ForceRender(s)
    end
    L.Enforce()
end

-- The controller reacts to the activity replicator through ListenRaw. Hooking
-- the same signal lets the session be rewritten as the update lands, so in the
-- common case the game's own reconcile already sees the fake and draws it
-- natively -- no second render, no visible swap.
L.Hooked = false
L.HookReplication = function()
    if L.Hooked then return end
    local a = L.GetRep("RNGMachineActivity")
    if not a or type(a.ListenRaw) ~= "function" then return end
    local ok = safe(function()
        a:ListenRaw(function()
            if not L.Enabled then return end
            local s = L.Session()
            if s then L.ApplyToSession(s) end
        end)
        return true
    end)
    if ok then L.Hooked = true end
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------

local old = PG:FindFirstChild("LuminositySpoofUI")
if old then old:Destroy() end

local function New(cls, props, kids)
    local i = Instance.new(cls)
    for k, v in pairs(props or {}) do i[k] = v end
    for _, c in ipairs(kids or {}) do c.Parent = i end
    return i
end
local function Corner(p, r) return New("UICorner", {CornerRadius = UDim.new(0, r or 10), Parent = p}) end
local function Pad(p, a, b, c, d) return New("UIPadding", {
    PaddingTop = UDim.new(0, a or 0), PaddingBottom = UDim.new(0, b or a or 0),
    PaddingLeft = UDim.new(0, c or a or 0), PaddingRight = UDim.new(0, d or c or a or 0), Parent = p}) end
local function Stroke(p, col, th, tr)
    return New("UIStroke", {Color = col or T.LINE, Thickness = th or 1, Transparency = tr or 0.4, Parent = p})
end
local function tw(o, t, style, dir, goal)
    return TS:Create(o, TweenInfo.new(t, style or Enum.EasingStyle.Quart, dir or Enum.EasingDirection.Out), goal)
end

local Gui = New("ScreenGui", {Name = "LuminositySpoofUI", ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling, IgnoreGuiInset = true,
    DisplayOrder = 9999, Parent = PG})

local NOTIF_W = IS_MOBILE and 270 or 320
local NotifRoot = New("Frame", {AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 14),
    Size = UDim2.fromOffset(NOTIF_W, 0), AutomaticSize = Enum.AutomaticSize.Y,
    BackgroundTransparency = 1, Parent = Gui})
New("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder,
    HorizontalAlignment = Enum.HorizontalAlignment.Right, Padding = UDim.new(0, 8), Parent = NotifRoot})

L.Notifs, L.NotifOrder = {}, 0

local function killNotif(s)
    if s.dead then return end
    s.dead = true; L.Notifs[s.key] = nil
    tw(s.frame, 0.26, nil, nil, {Position = UDim2.fromOffset(NOTIF_W + 40, 0), BackgroundTransparency = 1}):Play()
    for _, o in ipairs(s.fade) do
        tw(o, 0.22, nil, nil, o:IsA("UIStroke") and {Transparency = 1}
            or (o:IsA("Frame") and {BackgroundTransparency = 1} or {TextTransparency = 1})):Play()
    end
    task.delay(0.3, function() if s.frame then s.frame:Destroy() end end)
end

L.Notify = function(msg, color, sub)
    msg = tostring(msg or ""); if msg == "" then return end
    color = color or T.HIGH
    local e = L.Notifs[msg]
    if e and not e.dead then
        e.count += 1; e.badge.Text = "x" .. e.count; e.badge.Visible = true
        if sub then e.sub.Text = sub end
        e.token += 1; local tok = e.token
        tw(e.badge, 0.12, Enum.EasingStyle.Back, nil, {TextSize = 17}):Play()
        task.delay(0.12, function() if not e.dead then tw(e.badge, 0.16, Enum.EasingStyle.Back, nil, {TextSize = 13}):Play() end end)
        task.delay(3.4, function() if not e.dead and e.token == tok then killNotif(e) end end)
        return
    end
    L.NotifOrder += 1
    local h = sub and 72 or 52
    local frame = New("Frame", {Size = UDim2.new(1, 0, 0, h), Position = UDim2.fromOffset(NOTIF_W + 40, 0),
        BackgroundColor3 = T.SURFACE, BackgroundTransparency = 1, BorderSizePixel = 0,
        ClipsDescendants = true, LayoutOrder = L.NotifOrder, Parent = NotifRoot})
    Corner(frame, 12)
    local stroke = Stroke(frame, T.LINE, 1, 1)
    local bar = New("Frame", {Size = UDim2.new(0, 4, 1, -16), Position = UDim2.new(0, 8, 0, 8),
        BackgroundColor3 = color, BackgroundTransparency = 1, BorderSizePixel = 0, Parent = frame})
    Corner(bar, 2)
    local body = New("TextLabel", {Size = UDim2.new(1, -58, 0, sub and 22 or 52),
        Position = UDim2.new(0, 20, 0, sub and 11 or 0), BackgroundTransparency = 1,
        Text = msg, TextColor3 = color, Font = Enum.Font.GothamBold, TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = sub and Enum.TextYAlignment.Top or Enum.TextYAlignment.Center,
        TextTruncate = Enum.TextTruncate.AtEnd, TextTransparency = 1, Parent = frame})
    local subLbl = New("TextLabel", {Size = UDim2.new(1, -58, 0, 30), Position = UDim2.new(0, 20, 0, 35),
        BackgroundTransparency = 1, Text = sub or "", TextColor3 = T.MUTED,
        Font = Enum.Font.Gotham, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = true, Visible = sub ~= nil,
        TextTransparency = 1, Parent = frame})
    local badge = New("TextLabel", {Size = UDim2.fromOffset(32, 20), Position = UDim2.new(1, -40, 0, 9),
        BackgroundTransparency = 1, Text = "", TextColor3 = T.WHITE, Font = Enum.Font.GothamBold,
        TextSize = 13, TextXAlignment = Enum.TextXAlignment.Right, Visible = false,
        TextTransparency = 1, Parent = frame})
    local s = {key = msg, frame = frame, badge = badge, sub = subLbl, count = 1, token = 0, dead = false,
               fade = {body, subLbl, badge, bar, stroke}}
    L.Notifs[msg] = s
    tw(frame, 0.3, Enum.EasingStyle.Quint, nil, {Position = UDim2.fromOffset(0, 0), BackgroundTransparency = 0.08}):Play()
    tw(stroke, 0.3, nil, nil, {Transparency = 0.45}):Play()
    tw(bar, 0.3, nil, nil, {BackgroundTransparency = 0}):Play()
    tw(body, 0.3, nil, nil, {TextTransparency = 0}):Play()
    if sub then tw(subLbl, 0.3, nil, nil, {TextTransparency = 0.15}):Play() end
    tw(badge, 0.3, nil, nil, {TextTransparency = 0.1}):Play()
    local tok = s.token
    task.delay(3.4, function() if not s.dead and s.token == tok then killNotif(s) end end)
end

local PANEL_W = IS_MOBILE and 300 or 350
local PANEL_H = 700
local Panel = New("Frame", {Size = UDim2.fromOffset(PANEL_W, PANEL_H),
    Position = UDim2.new(0.5, -(PANEL_W / 2), 0.5, -(PANEL_H / 2)),
    BackgroundColor3 = T.SURFACE, BackgroundTransparency = 1, BorderSizePixel = 0, Parent = Gui})
Corner(Panel, 18); Pad(Panel, 16)

local GlowStroke = New("UIStroke", {Color = T.GLOW, Thickness = 1.5, Transparency = 1, Parent = Panel})
Corner(GlowStroke, 18)

local PanelGrad = New("UIGradient", {Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, T.SURFACE),
    ColorSequenceKeypoint.new(0.4, T.SURFACE:Lerp(T.DEEP, 0.3)),
    ColorSequenceKeypoint.new(0.7, T.SURFACE),
    ColorSequenceKeypoint.new(1, T.SURFACE:Lerp(T.DEEP, 0.15)),
}), Rotation = 30, Parent = Panel})

task.spawn(function()
    while Panel.Parent do
        tw(GlowStroke, 2.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, {Transparency = 0.3, Color = T.GLOW}):Play()
        task.wait(2.5)
        tw(GlowStroke, 2.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, {Transparency = 0.8, Color = T.ACCENT}):Play()
        task.wait(2.5)
    end
end)

task.spawn(function()
    while Panel.Parent do
        tw(PanelGrad, 8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, {Rotation = 210}):Play(); task.wait(8)
        tw(PanelGrad, 8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, {Rotation = 30}):Play(); task.wait(8)
    end
end)

local Header = New("Frame", {Size = UDim2.new(1, 0, 0, 24), BackgroundTransparency = 1, Parent = Panel})
local Handle = New("TextButton", {Size = UDim2.new(1, -56, 1, 0), BackgroundTransparency = 1,
    AutoButtonColor = false, Text = "", Parent = Header})

local Dot = New("Frame", {Size = UDim2.fromOffset(9, 9), Position = UDim2.new(0, 2, 0.5, -5),
    BackgroundColor3 = T.MUTED, BorderSizePixel = 0, Parent = Handle})
Corner(Dot, 5)
task.spawn(function()
    while Dot.Parent do
        tw(Dot, 1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, {BackgroundColor3 = T.CYAN,
            Size = UDim2.fromOffset(11, 11), Position = UDim2.new(0, 1, 0.5, -6)}):Play()
        task.wait(1.2)
        tw(Dot, 1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, {BackgroundColor3 = T.MUTED,
            Size = UDim2.fromOffset(9, 9), Position = UDim2.new(0, 2, 0.5, -5)}):Play()
        task.wait(1.2)
    end
end)

local Brand = New("TextLabel", {Size = UDim2.new(1, -20, 1, 0), Position = UDim2.fromOffset(16, 0),
    BackgroundTransparency = 1, Text = "LUMINOSITY", TextColor3 = T.HIGH,
    Font = Enum.Font.GothamBlack, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left,
    TextTransparency = 1, Parent = Handle})
local SubBrand = New("TextLabel", {Size = UDim2.new(0, 80, 1, 0), Position = UDim2.new(0, 104, 0, 0),
    BackgroundTransparency = 1, Text = "SPOOF", TextColor3 = T.PURPLE,
    Font = Enum.Font.GothamBold, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left,
    TextTransparency = 1, Parent = Handle})

local MinBtn = New("TextButton", {Size = UDim2.fromOffset(22, 22), Position = UDim2.new(1, -48, 0.5, -11),
    BackgroundColor3 = T.RAISED, AutoButtonColor = false, Text = "-", TextColor3 = T.MUTED,
    Font = Enum.Font.GothamBold, TextSize = 12, BackgroundTransparency = 1, TextTransparency = 1, Parent = Header})
Corner(MinBtn, 7)
local CloseBtn = New("TextButton", {Size = UDim2.fromOffset(22, 22), Position = UDim2.new(1, -22, 0.5, -11),
    BackgroundColor3 = T.RAISED, AutoButtonColor = false, Text = "x", TextColor3 = T.MUTED,
    Font = Enum.Font.GothamBold, TextSize = 13, BackgroundTransparency = 1, TextTransparency = 1, Parent = Header})
Corner(CloseBtn, 7)

local Content = New("Frame", {Size = UDim2.new(1, 0, 1, -36), Position = UDim2.new(0, 0, 0, 36),
    BackgroundTransparency = 1, Parent = Panel})
New("UIListLayout", {Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = Content})

local function ToggleRow(label, order, onChange)
    local Box = New("Frame", {Size = UDim2.new(1, 0, 0, 42), BackgroundColor3 = T.RAISED,
        BackgroundTransparency = 0, LayoutOrder = order, Parent = Content})
    Corner(Box, 12); Pad(Box, 0, 0, 12, 12)
    local BoxStroke = Stroke(Box, T.LINE, 1, 0.5)
    local Tag = New("TextLabel", {Size = UDim2.new(1, -50, 1, 0), BackgroundTransparency = 1,
        Text = label, TextColor3 = T.MUTED, Font = Enum.Font.GothamSemibold, TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left, Parent = Box})
    local Sw = New("TextButton", {Size = UDim2.fromOffset(40, 22), Position = UDim2.new(1, 0, 0.5, 0),
        AnchorPoint = Vector2.new(1, 0.5), BackgroundColor3 = T.SURFACE, AutoButtonColor = false,
        Text = "", Parent = Box})
    Corner(Sw, 11)
    local SwStroke = Stroke(Sw, T.LINE, 1, 0.5)
    local Kn = New("Frame", {Size = UDim2.fromOffset(16, 16), Position = UDim2.new(0, 3, 0.5, -8),
        BackgroundColor3 = T.MUTED, BorderSizePixel = 0, Parent = Sw})
    Corner(Kn, 8)
    local Glow = New("Frame", {Size = UDim2.fromOffset(20, 20), Position = UDim2.new(0, 1, 0.5, -10),
        BackgroundColor3 = T.ACCENT, BorderSizePixel = 0, BackgroundTransparency = 1, Parent = Sw})
    Corner(Glow, 10)
    local state = false
    local function set(on)
        state = on
        tw(Sw, 0.2, nil, nil, {BackgroundColor3 = on and T.ACCENT or T.SURFACE}):Play()
        tw(SwStroke, 0.2, nil, nil, {Color = on and T.HIGH or T.LINE}):Play()
        tw(Glow, 0.25, nil, nil, {BackgroundTransparency = on and 0.75 or 1}):Play()
        TS:Create(Kn, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
            Position = on and UDim2.new(1, -19, 0.5, -8) or UDim2.new(0, 3, 0.5, -8),
            BackgroundColor3 = on and T.WHITE or T.MUTED}):Play()
        tw(Tag, 0.2, nil, nil, {TextColor3 = on and T.TEXT or T.MUTED}):Play()
        tw(BoxStroke, 0.2, nil, nil, {Color = on and T.ACCENT or T.LINE, Transparency = on and 0.3 or 0.5}):Play()
        if onChange then onChange(on) end
    end
    Sw.MouseButton1Click:Connect(function() set(not state) end)
    return {Set = set, Get = function() return state end}
end

local SpoofToggle = ToggleRow("Visual Spoof", 1, function(on)
    L.Enabled = on
    if on then
        if L.Install() then
            L.HookReplication()
            L.Warm(L.FakeName)
            L.Notify("Spoof ON", T.GREEN, "Showing " .. L.DisplayOf(L.FakeName))
            L.Reapply()
        else
            L.Enabled = false
            L.Notify("Modules not loaded", T.RED, "Rejoin or wait for the game to finish loading.")
        end
    else
        L.Notify("Spoof OFF", T.MUTED)
        L.RestoreSession()
        L.Refresh()
    end
end)

local MutToggle = ToggleRow("Spoof Mutation", 2, function(on)
    L.SpoofMut = on
    if L.Enabled then L.Reapply() end
end)

local KeepToggle = ToggleRow("Keep After Buy", 3, function(on)
    L.KeepAfterBuy = on
    if not on then
        L.ClearLocked()
        L.Notify("Locked pairs cleared", T.MUTED, "Bought brainrots go back to normal")
    end
end)

local OddsToggle = ToggleRow("Hide 1-in Odds", 4, function(on)
    L.HideOdds = on
end)

local UnlockToggle = ToggleRow("Force Unlock", 5, function(on)
    L.ForceUnlock = on
end)

-- session.Multiplier drives setLuckySpinVfx, so this is the luck explosion and
-- spin colouring that a genuine high roll comes with.
local LuckToggle = ToggleRow("Spoof Luck", 6, function(on)
    L.SpoofLuck = on
    if L.Enabled then L.Reapply() end
end)

local LuckBox = New("Frame", {Size = UDim2.new(1, 0, 0, 42), BackgroundColor3 = T.RAISED,
    LayoutOrder = 7, Parent = Content})
Corner(LuckBox, 12); Pad(LuckBox, 0, 0, 12, 12)
Stroke(LuckBox, T.LINE, 1, 0.5)
New("TextLabel", {Size = UDim2.new(0, 70, 1, 0), BackgroundTransparency = 1, Text = "Luck",
    TextColor3 = T.MUTED, Font = Enum.Font.GothamSemibold, TextSize = 12,
    TextXAlignment = Enum.TextXAlignment.Left, Parent = LuckBox})
local LuckPrev = New("TextButton", {Size = UDim2.fromOffset(26, 26), Position = UDim2.new(0, 72, 0.5, -13),
    BackgroundColor3 = T.SURFACE, AutoButtonColor = false, Text = "<", TextColor3 = T.HIGH,
    Font = Enum.Font.GothamBold, TextSize = 14, Parent = LuckBox})
Corner(LuckPrev, 8)
local LuckLabel = New("TextLabel", {Size = UDim2.new(1, -172, 1, 0), Position = UDim2.fromOffset(104, 0),
    BackgroundTransparency = 1, Text = "25x", TextColor3 = T.ORANGE,
    Font = Enum.Font.GothamBold, TextSize = 13, Parent = LuckBox})
local LuckNext = New("TextButton", {Size = UDim2.fromOffset(26, 26), Position = UDim2.new(1, -26, 0.5, -13),
    BackgroundColor3 = T.SURFACE, AutoButtonColor = false, Text = ">", TextColor3 = T.HIGH,
    Font = Enum.Font.GothamBold, TextSize = 14, Parent = LuckBox})
Corner(LuckNext, 8)

local luckIndex = 9 -- 25x
local function setLuck(i)
    luckIndex = ((i - 1) % #L.LUCKS) + 1
    L.FakeLuck = L.LUCKS[luckIndex]
    LuckLabel.Text = L.FakeLuck .. "x"
    if L.Enabled and L.SpoofLuck then L.Reapply() end
end
LuckPrev.MouseButton1Click:Connect(function() setLuck(luckIndex - 1) end)
LuckNext.MouseButton1Click:Connect(function() setLuck(luckIndex + 1) end)
setLuck(luckIndex)

local MutBox = New("Frame", {Size = UDim2.new(1, 0, 0, 42), BackgroundColor3 = T.RAISED,
    LayoutOrder = 8, Parent = Content})
Corner(MutBox, 12); Pad(MutBox, 0, 0, 12, 12)
Stroke(MutBox, T.LINE, 1, 0.5)
New("TextLabel", {Size = UDim2.new(0, 70, 1, 0), BackgroundTransparency = 1, Text = "Mutation",
    TextColor3 = T.MUTED, Font = Enum.Font.GothamSemibold, TextSize = 12,
    TextXAlignment = Enum.TextXAlignment.Left, Parent = MutBox})
local MutPrev = New("TextButton", {Size = UDim2.fromOffset(26, 26), Position = UDim2.new(0, 72, 0.5, -13),
    BackgroundColor3 = T.SURFACE, AutoButtonColor = false, Text = "<", TextColor3 = T.HIGH,
    Font = Enum.Font.GothamBold, TextSize = 14, Parent = MutBox})
Corner(MutPrev, 8)
local MutLabel = New("TextLabel", {Size = UDim2.new(1, -172, 1, 0), Position = UDim2.fromOffset(104, 0),
    BackgroundTransparency = 1, Text = "Normal", TextColor3 = T.TEXT, RichText = true,
    Font = Enum.Font.GothamBold, TextSize = 13, TextTruncate = Enum.TextTruncate.AtEnd, Parent = MutBox})
local MutNext = New("TextButton", {Size = UDim2.fromOffset(26, 26), Position = UDim2.new(1, -26, 0.5, -13),
    BackgroundColor3 = T.SURFACE, AutoButtonColor = false, Text = ">", TextColor3 = T.HIGH,
    Font = Enum.Font.GothamBold, TextSize = 14, Parent = MutBox})
Corner(MutNext, 8)

local mutIndex = 1
local function setMut(i)
    if #L.AllMutations == 0 then return end
    mutIndex = ((i - 1) % #L.AllMutations) + 1
    L.FakeMut = L.AllMutations[mutIndex]
    local disp = L.MutationDisplay(L.FakeMut)
    MutLabel.Text = (disp ~= "" and disp) or "Normal"
    if L.Enabled and L.SpoofMut then L.Reapply() end
end
MutPrev.MouseButton1Click:Connect(function() setMut(mutIndex - 1) end)
MutNext.MouseButton1Click:Connect(function() setMut(mutIndex + 1) end)

local SearchBox = New("Frame", {Size = UDim2.new(1, 0, 0, 34), BackgroundColor3 = T.FIELD,
    LayoutOrder = 9, Parent = Content})
Corner(SearchBox, 10); Pad(SearchBox, 0, 0, 10, 10)
Stroke(SearchBox, T.LINE, 1, 0.6)
local SearchInput = New("TextBox", {Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1,
    Text = "", PlaceholderText = "Search brainrots...", PlaceholderColor3 = T.MUTED,
    TextColor3 = T.TEXT, Font = Enum.Font.Gotham, TextSize = 12,
    TextXAlignment = Enum.TextXAlignment.Left, ClearTextOnFocus = false, Parent = SearchBox})

local ListFrame = New("ScrollingFrame", {Size = UDim2.new(1, 0, 1, -478), LayoutOrder = 10,
    BackgroundColor3 = T.FIELD, BorderSizePixel = 0, ScrollBarThickness = 3,
    ScrollBarImageColor3 = T.ACCENT, ScrollBarImageTransparency = 0.4,
    CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollingDirection = Enum.ScrollingDirection.Y, Parent = Content})
Corner(ListFrame, 12); Pad(ListFrame, 6, 6, 6, 6)
Stroke(ListFrame, T.LINE, 1, 0.6)
New("UIListLayout", {Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = ListFrame})

L.Rows = {}

local function markRows()
    for key, row in pairs(L.Rows) do
        local on = (key == L.FakeName)
        tw(row.stroke, 0.15, nil, nil, {Color = on and T.ACCENT or T.LINE, Transparency = on and 0.2 or 0.7}):Play()
        tw(row.label, 0.15, nil, nil, {TextColor3 = on and T.TEXT or T.MUTED}):Play()
        tw(row.frame, 0.15, nil, nil, {BackgroundColor3 = on and T.RAISED or T.SURFACE}):Play()
        row.tick.Visible = on
    end
end

local function makeRow(key, order)
    local frame = New("Frame", {Size = UDim2.new(1, 0, 0, 28), BackgroundColor3 = T.SURFACE,
        BorderSizePixel = 0, LayoutOrder = order, Parent = ListFrame})
    Corner(frame, 8)
    local stroke = Stroke(frame, T.LINE, 1, 0.7)
    local btn = New("TextButton", {Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1,
        AutoButtonColor = false, Text = "", Parent = frame})
    local label = New("TextLabel", {Size = UDim2.new(1, -34, 1, 0), Position = UDim2.fromOffset(10, 0),
        BackgroundTransparency = 1, Text = L.DisplayOf(key), TextColor3 = T.MUTED,
        Font = Enum.Font.GothamSemibold, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd, Parent = frame})
    local tick = New("TextLabel", {Size = UDim2.fromOffset(20, 28), Position = UDim2.new(1, -26, 0, 0),
        BackgroundTransparency = 1, Text = "*", TextColor3 = T.ACCENT, Font = Enum.Font.GothamBold,
        TextSize = 14, Visible = false, Parent = frame})
    btn.MouseButton1Click:Connect(function()
        L.FakeName = key
        markRows()
        if L.Enabled then
            L.Notify("Showing " .. L.DisplayOf(key), T.CYAN,
                L.RealName and ("Real roll: " .. L.DisplayOf(L.RealName)) or nil)
            L.Reapply()
        end
    end)
    L.Rows[key] = {frame = frame, stroke = stroke, label = label, tick = tick, search = L.DisplayOf(key):lower() .. " " .. key:lower()}
end

L.BuildList = function()
    for _, c in ipairs(ListFrame:GetChildren()) do
        if c:IsA("Frame") then c:Destroy() end
    end
    table.clear(L.Rows)
    for i, key in ipairs(L.AllNames) do makeRow(key, i) end
    markRows()
end

L.Filter = function()
    local q = trim(SearchInput.Text):lower()
    local shown = 0
    for _, row in pairs(L.Rows) do
        local vis = (q == "") or (row.search:find(q, 1, true) ~= nil)
        row.frame.Visible = vis
        if vis then shown += 1 end
    end
    return shown
end
SearchInput:GetPropertyChangedSignal("Text"):Connect(L.Filter)

local StatusBar = New("Frame", {Size = UDim2.new(1, 0, 0, 28), BackgroundColor3 = T.RAISED,
    LayoutOrder = 11, Parent = Content})
Corner(StatusBar, 9); Pad(StatusBar, 0, 0, 10, 10)
Stroke(StatusBar, T.LINE, 1, 0.6)
local StatusDot = New("Frame", {Size = UDim2.fromOffset(7, 7), Position = UDim2.new(0, 4, 0.5, -4),
    BackgroundColor3 = T.MUTED, BorderSizePixel = 0, Parent = StatusBar})
Corner(StatusDot, 4)
local StatusLbl = New("TextLabel", {Size = UDim2.new(1, -16, 1, 0), Position = UDim2.fromOffset(16, 0),
    BackgroundTransparency = 1, Text = "Waiting for machine", TextColor3 = T.MUTED,
    Font = Enum.Font.Gotham, TextSize = 10, TextTruncate = Enum.TextTruncate.AtEnd,
    TextXAlignment = Enum.TextXAlignment.Left, Parent = StatusBar})

task.spawn(function()
    while Gui.Parent do
        safe(L.HookReplication)
        L.ReadOffer()
        if L.Enabled then safe(L.Sync) end
        safe(L.Enforce)

        local machine = L.Machine()
        local color, text
        if not machine then
            color, text = T.MUTED, "Machine not loaded"
        elseif not L.Enabled then
            color, text = T.MUTED, "Spoof off  ·  " .. L.DisplayOf(L.FakeName)
        elseif L.RealName then
            color = T.GREEN
            text = ("Faking %s -> %s"):format(L.DisplayOf(L.RealName), L.DisplayOf(L.FakeName))
            if L.SpoofMut then text = text .. "  ·  " .. L.FakeMut end
        else
            color, text = T.CYAN, ("Armed  ·  %s"):format(L.MachineState)
        end
        StatusLbl.Text = text
        StatusLbl.TextColor3 = color
        tw(StatusDot, 0.2, nil, nil, {BackgroundColor3 = color}):Play()

        task.wait(0.15)
    end
end)

local function draggable(frame, handle)
    local dragging, start, spos
    handle.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging = true; start = i.Position; spos = frame.Position
            i.Changed:Connect(function() if i.UserInputState == Enum.UserInputState.End then dragging = false end end)
        end
    end)
    UIS.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
            local d = i.Position - start
            frame.Position = UDim2.new(spos.X.Scale, spos.X.Offset + d.X, spos.Y.Scale, spos.Y.Offset + d.Y)
        end
    end)
end
draggable(Panel, Handle)

local Fab = New("TextButton", {Size = UDim2.fromOffset(50, 50), Position = UDim2.new(0, 20, 1, -90),
    BackgroundColor3 = T.SURFACE, AutoButtonColor = false, Text = "", Visible = false, Parent = Gui})
Corner(Fab, 16)
local FabStroke = Stroke(Fab, T.PURPLE, 1.5, 0.5)
New("TextLabel", {Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1,
    Text = "SPF", TextColor3 = T.HIGH, Font = Enum.Font.GothamBlack, TextSize = 13, Parent = Fab})
local FabGlow = New("Frame", {Size = UDim2.new(1, 6, 1, 6), Position = UDim2.new(0, -3, 0, -3),
    BackgroundColor3 = T.PURPLE, BorderSizePixel = 0, BackgroundTransparency = 1, Parent = Fab})
Corner(FabGlow, 18)
task.spawn(function()
    while Fab.Parent do
        if Fab.Visible then
            tw(FabGlow, 2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, {BackgroundTransparency = 0.85}):Play()
            task.wait(2)
            tw(FabGlow, 2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, {BackgroundTransparency = 1}):Play()
        end
        task.wait(2)
    end
end)
draggable(Fab, Fab)

local minimized = false
MinBtn.MouseButton1Click:Connect(function()
    minimized = not minimized
    if minimized then
        Content.Visible = false; MinBtn.Text = "+"
        tw(Panel, 0.28, nil, nil, {Size = UDim2.fromOffset(PANEL_W, 48)}):Play()
        tw(GlowStroke, 0.28, nil, nil, {Thickness = 1}):Play()
    else
        MinBtn.Text = "-"
        tw(Panel, 0.28, nil, nil, {Size = UDim2.fromOffset(PANEL_W, PANEL_H)}):Play()
        tw(GlowStroke, 0.28, nil, nil, {Thickness = 1.5}):Play()
        task.delay(0.1, function() if not minimized then Content.Visible = true end end)
    end
end)

local function hidePanel()
    if not Panel.Visible then return end
    tw(Panel, 0.22, nil, nil, {BackgroundTransparency = 1}):Play()
    tw(GlowStroke, 0.22, nil, nil, {Transparency = 1}):Play()
    task.delay(0.22, function()
        Panel.Visible = false; Panel.BackgroundTransparency = 0.7
        Fab.Visible = true; Fab.Size = UDim2.fromOffset(0, 0)
        tw(Fab, 0.32, Enum.EasingStyle.Back, nil, {Size = UDim2.fromOffset(50, 50)}):Play()
        tw(FabStroke, 0.32, nil, nil, {Transparency = 0.5}):Play()
    end)
end

local function showPanel()
    if Panel.Visible then return end
    tw(Fab, 0.2, nil, nil, {Size = UDim2.fromOffset(0, 0)}):Play()
    task.delay(0.2, function()
        Fab.Visible = false; Fab.Size = UDim2.fromOffset(50, 50); Panel.Visible = true
    end)
end

CloseBtn.MouseButton1Click:Connect(hidePanel)
Fab.MouseButton1Click:Connect(showPanel)

L.MenuKey = Enum.KeyCode.G
UIS.InputBegan:Connect(function(i, gpe)
    if gpe then return end
    if i.KeyCode == L.MenuKey then
        if Panel.Visible then hidePanel() else showPanel() end
    end
end)

task.spawn(function()
    tw(Panel, 0.45, nil, nil, {BackgroundTransparency = 0.7}):Play()
    tw(GlowStroke, 0.45, nil, nil, {Transparency = 0.5}):Play()
    tw(Brand, 0.4, nil, nil, {TextTransparency = 0}):Play()
    tw(SubBrand, 0.4, nil, nil, {TextTransparency = 0.15}):Play()
    tw(Dot, 0.4, nil, nil, {BackgroundTransparency = 0}):Play()
    tw(MinBtn, 0.4, nil, nil, {BackgroundTransparency = 0, TextTransparency = 0}):Play()
    tw(CloseBtn, 0.4, nil, nil, {BackgroundTransparency = 0, TextTransparency = 0}):Play()

    for _ = 1, 60 do
        if L.LoadPools() then break end
        L.BrainrotAssets = L.BrainrotAssets or loadModule("Shared", "BrainrotAssets")
        L.Animals        = L.Animals        or loadModule("Shared", "Animals")
        L.CustomRichText = L.CustomRichText or loadModule("Controllers", "CustomRichTextController")
        L.AnimalOverhead = L.AnimalOverhead or loadModule("Controllers", "AnimalOverheadController")
        L.AnimalData     = L.AnimalData     or loadModule("Datas", "Animals")
        L.MutationData   = L.MutationData   or loadModule("Datas", "Mutations")
        task.wait(0.25)
    end

    if not L.FakeName then
        for _, key in ipairs(L.AllNames) do
            if L.DisplayOf(key):lower():find("meowl", 1, true) then L.FakeName = key; break end
        end
    end
    L.FakeName = L.FakeName or L.AllNames[1]
    L.BuildList()

    local startMut = 1
    for i, m in ipairs(L.AllMutations) do
        if m == "Crystal" then startMut = i; break end
    end
    setMut(startMut)

    local missing = {}
    if not L.BrainrotAssets then missing[#missing + 1] = "BrainrotAssets" end
    if not L.Animals        then missing[#missing + 1] = "Animals" end
    if not L.CustomRichText then missing[#missing + 1] = "CustomRichText" end
    if not L.AnimalOverhead then missing[#missing + 1] = "AnimalOverhead" end

    if #missing > 0 then
        L.Notify("Modules missing", T.RED, table.concat(missing, ", "))
    else
        L.Notify("Spoof ready", T.HIGH,
            ("%d brainrots  ·  %d mutations"):format(#L.AllNames, #L.AllMutations - 1))
    end
end)
