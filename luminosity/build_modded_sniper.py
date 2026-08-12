#!/usr/bin/env python3
"""Generate luminosity_modded_sniper.lua from luminosity.lua.

The modded sniper is meant to look and behave identically to the main build,
so it is not hand-written — it is the main file with three regions swapped:

  1. remote resolution   hash/bait/boundary walk  ->  plaintext lookup
  2. code normalisation  keep as typed            ->  uppercased
  3. webhook flavour     role ping + rarity colour -> orange, no ping

Everything else — every pixel of UI, the assembler, the packet path, the
scanner, the intro — is carried over byte for byte, so the two panels cannot
drift apart. Re-run this after touching luminosity.lua.
"""

import pathlib
import re
import sys

HERE = pathlib.Path(__file__).parent
SRC = HERE / "luminosity.lua"
OUT = HERE / "luminosity_modded_sniper.lua"

src = SRC.read_text()


def cut(text, start_marker, end_marker, replacement, label):
    i = text.find(start_marker)
    j = text.find(end_marker, i + 1)
    if i < 0 or j < 0:
        sys.exit(f"anchor missing for {label}: {i} {j}")
    return text[:i] + replacement + text[j:]


# ---------------------------------------------------------------- header
HEADER = '''--[[  LUMINOSITY // MODDED  —  Sniper  ]]--
-- Target: the modded place ONLY
-- Executor: any. Generated from luminosity.lua by build_modded_sniper.py —
-- same panel, same assembler, same packet path, pixel for pixel. Do not edit
-- this file by hand; edit the main script and regenerate.
--
-- What differs from the main build, and only this:
--   remote   RF/RequestRedemption, plaintext and stable (no hash, no bait)
--   codes    uppercased client side, matching CodesController line 82
--   webhook  orange marker, no role ping, no tracker
--   place    armed everywhere EXCEPT the main game
--
-- It shares no GUI name, no globals and no cache with the main script.
'''
i = src.find("local Players")
src = HEADER + "\n" + src[i:]

# ---------------------------------------------------------- place guard
src = src.replace(
    """-- This build is the main Steal a Brainrot build and nothing else. The modded
-- place has its own separate scripts; they share no state, no GUI name and no
-- globals with this one. If we are not in the main place, nothing arms.
L.MAIN_PLACE = 109983668079237
L.RightPlace = (game.PlaceId == L.MAIN_PLACE)""",
    """-- Modded-only build. It arms anywhere EXCEPT the main game, so it can never
-- fire a remote inside real Steal a Brainrot. The main script is the exact
-- mirror of this test and the two never overlap.
L.MAIN_PLACE = 109983668079237
L.RightPlace = (game.PlaceId ~= L.MAIN_PLACE)""",
)

# ------------------------------------------------------------- remotes
REMOTES = '''----------------------------------------------------------------------
-- REMOTES
--
-- Nothing to outsmart here. The modded place names its remotes in plain
-- text and keeps them stable across joins, so there is no hash to track,
-- no uuid bait to avoid and no layout boundary to find — a FindFirstChild
-- and we are done. That is the whole reason this is a separate build: the
-- main script looks for a 64-hex name that does not exist in this place.
--
--   RF/RequestRedemption            (code)  -> ok, message
--   RE/NotificationService/Notify   (message, ...)
--
-- Source: ReplicatedStorage.Controllers.CodesController line 44.
----------------------------------------------------------------------
L.Net = safe(function() return RepS:WaitForChild("Packages", 10):WaitForChild("Net", 10) end)

L.Keys = { Notify = "NotificationService/Notify", Redeem = "RequestRedemption" }
L.Remotes = {
    Redeem = { key = nil, instance = nil, class = nil, index = nil },
    Notify = { key = nil, instance = nil, class = nil },
}

L.ResolveRemotes = function()
    if not L.Net then
        local pk = RepS:FindFirstChild("Packages")
        L.Net = pk and pk:FindFirstChild("Net")
        if not L.Net then return L.Remotes end
    end
    if not alive(L.Remotes.Notify.instance) then
        local inst = L.Net:FindFirstChild("RE/" .. L.Keys.Notify)
        if inst then L.Remotes.Notify = {key = L.Keys.Notify, instance = inst, class = inst.ClassName} end
    end
    if not alive(L.Remotes.Redeem.instance) then
        local inst = L.Net:FindFirstChild("RF/" .. L.Keys.Redeem)
        if inst then
            L.Remotes.Redeem = {key = L.Keys.Redeem, instance = inst, class = inst.ClassName, index = nil}
            L._rf = inst
        end
    end
    return L.Remotes
end

----------------------------------------------------------------------
-- CAPTURE  (main-build feature, inert here)
--
-- The main script installs a one-shot __namecall hook when its layout
-- heuristic fails, and shows a hint card telling you to redeem LUMI by
-- hand so it can learn the remote. None of that applies to a plaintext
-- remote, so the hooks are stubs and the card never shows. The stubs stay
-- so the shared UI code below is identical in both builds — nothing is
-- installed in the client here, ever.
----------------------------------------------------------------------
L.CAPTURE_CODE = "LUMI"
L.Capturing = false
L.CaptureSupported = function() return false end
L.StartCapture = function() return false end
L.StopCapture = function() end

L.RemoteReport = function()
    L.ResolveRemotes()
    local e = L.Remotes.Redeem
    if not e.instance then
        print("[LuminosityModded] Redeem remote: NOT FOUND")
        return
    end
    print("[LuminosityModded] Redeem remote")
    print(("    name     : %s"):format(e.instance.Name))
    print(("    class    : %s"):format(tostring(e.class)))
end

'''
src = cut(src, "----------------------------------------------------------------------\n-- REMOTES",
          "-- Direct invoke. Same instance", REMOTES, "remotes")

# The main build's getgenv remote cache is pointless for a plaintext lookup
# and would be a shared global between the two builds. Drop it.
src = re.sub(
    r"-- Resolving the redeem remote means walking.*?\nend\n\n",
    "",
    src,
    count=1,
    flags=re.S,
)

# ------------------------------------------------------------ sanitize
src = src.replace(
    """L.Sanitize = function(code)
    if not code or code == "" then return nil end
    if code:find("<", 1, true) then
        code = code:gsub("<br%s*/>"," "):gsub("<[^>]->","")
        code = code:gsub("^%s+",""):gsub("%s+$","")
    end
    if #code > 50 or code:find("[^%w]") then
        code = code:gsub("[^%w]","")
        if #code == 0 then return nil end
        if #code > 50 then code = code:sub(1,50) end
    end
    return code
end""",
    """-- This place uppercases and strips non-alphanumerics client side before
-- the string ever reaches the server (CodesController line 82), which the
-- main game does not. Match it exactly, so what we send is byte-identical
-- to a hand-typed redeem.
L.Sanitize = function(code)
    if not code or code == "" then return nil end
    if code:find("<", 1, true) then
        code = code:gsub("<br%s*/>"," "):gsub("<[^>]->","")
        code = code:gsub("^%s+",""):gsub("%s+$","")
    end
    if code:find("[^%w]") then
        code = code:gsub("[^%w]","")
    end
    if #code == 0 then return nil end
    if #code > 50 then code = code:sub(1,50) end
    return code:upper()
end""",
)

# Constants that only the main build uses: the tracker endpoint, the legacy
# hook and the role id. Dropping them keeps the two builds from sharing any
# destination at all.
for dead in ("L.LegacyHook = ", "L.TrackerUrl = ", "L.Role = "):
    src = re.sub(r"^" + re.escape(dead) + r".*\n", "", src, count=1, flags=re.M)

# ------------------------------------------------------------- webhook
# No tracker: the modded build must not report into the main build's tracker.
src = re.sub(
    r"L\.Enc = function\(v\).*?while task\.wait\(30\) do L\.Track\(\"heartbeat\"\) end\nend\)\n",
    """-- No tracker here. The modded build stays off the main build's telemetry.
L.Track = function() end
""",
    src,
    count=1,
    flags=re.S,
)

src = src.replace(
    """    local color
    if rarity and L.RarityColors[rarity:lower()] then
        color = L.RarityColors[rarity:lower()]
    else
        color = 7910655
    end""",
    """    -- Modded pulls are always the orange marker: a rarity from this place
    -- means nothing next to a real one.
    local color = 15105570""",
)
src = src.replace(
    """            footer = {text = "Luminosity"},""",
    """            footer = {text = "Modded place · Luminosity"},""",
)
src = src.replace(
    """    body.content = "<@&" .. L.Role .. ">\\nLuminosity snipes ez"
    body.allowed_mentions = {roles = {L.Role}}""",
    """    -- No role ping from the modded place.
    body.content = "Luminosity snipes ez"
    body.allowed_mentions = {parse = {}}""",
)

# --------------------------------------------------------------- names
src = src.replace('PG:FindFirstChild("LuminosityUI")', 'PG:FindFirstChild("LuminosityModdedSniper")')
src = src.replace('Name="LuminosityUI"', 'Name="LuminosityModdedSniper"')
src = src.replace('Text="LUMINOSITY", TextColor3=T.HIGH', 'Text="LUMINOSITY · MODDED", TextColor3=T.HIGH')
src = src.replace("[Luminosity]", "[LuminosityModded]")

# The hint card is a capture-flow element and capture cannot happen here.
src = src.replace(
    """L.ShowHint = function(on)
    HintCard.Visible = on""",
    """L.ShowHint = function(on)
    -- Always false in this build: there is nothing to capture.
    on = false
    HintCard.Visible = on""",
)

OUT.write_text(src)
print(f"wrote {OUT} ({len(src.splitlines())} lines)")
