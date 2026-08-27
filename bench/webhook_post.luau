do
-- A win gets posted. Where it goes depends on what was won.
local R = RIG
local H = R.H
H.pump(300000)
local L = R.genvTable.LUCK
if not L then print("no getgenv().LUCK") return end

local fails, checks = {}, 0
local function check(n, c, d)
    checks += 1
    if not c then fails[#fails + 1] = n .. (d and ("  -- " .. d) or "") end
end
local function clear() while #POSTS > 0 do table.remove(POSTS) end end
local function lastPost() return POSTS[#POSTS] end
local function wentTo(pool)
    local p = lastPost()
    if not p then return false end
    for _, url in ipairs(pool) do if p.url == url then return true end end
    return false
end

local seq = 0
local function win(prize)
    seq += 1
    clear()
    L.PostWin("WHCODE" .. seq, prize)
    H.pump(300000)
    return lastPost()
end

print("WEBHOOK")
print("================================================================")

check("it is on", L.HookOn == true)
check("there is a rare channel", #L.HookRare == 1, tostring(#L.HookRare))
check("and a normal one with a spare", #L.HookNormal == 2, tostring(#L.HookNormal))
check("the threshold is a hundred million", L.HookRareMinGen == 100000000,
    tostring(L.HookRareMinGen))
check("the top tiers are OG and Secret",
    L.HookRareTiers.og == true and L.HookRareTiers.secret == true)

-- the data actually loaded
local vacca = L.PrizeInfo("La Vacca")
check("the game's data is readable", vacca ~= nil)
check("tier is read", vacca and vacca.tier == "Secret", vacca and tostring(vacca.tier))
check("generation is read", vacca and vacca.gen == 250000000,
    vacca and tostring(vacca.gen))
local og = L.PrizeInfo("OG Pet")
check("a written-out generation is parsed", og and og.gen == 1.5e9,
    og and tostring(og.gen))

-- routing
win("La Vacca")
check("Secret over the threshold goes to the rare channel", wentTo(L.HookRare))
win("OG Pet")
check("OG over the threshold goes there too", wentTo(L.HookRare))
win("Meowl")
check("a common prize goes to the normal channel", wentTo(L.HookNormal))

-- the literal reading: BOTH conditions, not either
win("Small Secret")
check("a Secret UNDER the threshold is not rare", wentTo(L.HookNormal),
    "went to the rare channel")
win("Big Common")
check("a big generation on a low tier is not rare either", wentTo(L.HookNormal))

-- and the switch flips it
L.HookRareEither = true
win("Small Secret")
check("HookRareEither sends a Secret on its own", wentTo(L.HookRare))
win("Big Common")
check("and a big generation on its own", wentTo(L.HookRare))
L.HookRareEither = false

-- an unknown prize is not guessed at
win("Never Heard Of It")
check("an unknown prize goes to the normal channel", wentTo(L.HookNormal))

-- what the post says
local p = win("La Vacca")
check("something was posted", p ~= nil)
if p then
    local b = tostring(p.body)
    check("it says Sniped!", b:find("Sniped!", 1, true) ~= nil)
    check("it carries the user", b:find("User", 1, true) ~= nil
        and b:find(tostring(R.genvTable.LUCK and "clover"), 1, true) ~= nil, b:sub(1, 200))
    check("it carries the code", b:find("Code", 1, true) ~= nil
        and b:find("WHCODE", 1, true) ~= nil)
    check("it carries the brainrot", b:find("Brainrot", 1, true) ~= nil
        and b:find("La Vacca", 1, true) ~= nil)
    check("and the rarity it found", b:find("Secret", 1, true) ~= nil)
    check("it does not ping anyone", b:find("allowed_mentions", 1, true) ~= nil)
end

-- one post per code, however many times the result arrives
clear()
L.PostWin("ONCEONLY", "Meowl")
L.PostWin("ONCEONLY", "Meowl")
L.PostWin("ONCEONLY", "Meowl")
H.pump(300000)
check("the same code posts once", #POSTS == 1, tostring(#POSTS))

-- a loss must never post
clear()
R.setInvokeBehaviour(function() return false, "Invalid Code" end)
R.notifyRemote.OnClientEvent:FireAll("WHLOSE1", 5.5, "Sounds.Sfx.Blop", "Top")
H.pump(300000)
check("a rejected code posts nothing", #POSTS == 0, tostring(#POSTS))

-- End to end in the server's own words. It answers "<Animal> spawned!", so
-- that is what these send -- a test written against invented wording proves
-- nothing about the real thing.
clear()
R.setInvokeBehaviour(function() return true, "La Vacca spawned!" end)
R.notifyRemote.OnClientEvent:FireAll("WHWIN1", 5.5, "Sounds.Sfx.Blop", "Top")
H.pump(300000)
check("a win posts by itself", #POSTS >= 1, tostring(#POSTS))
if POSTS[1] then
    check("the suffix is stripped off the name",
        tostring(POSTS[1].body):find("La Vacca", 1, true) ~= nil
            and tostring(POSTS[1].body):find("spawned", 1, true) == nil,
        tostring(POSTS[1].body):sub(1, 240))
    check("and it routed as rare", wentTo(L.HookRare))
end

-- a two word name has to survive the same trip
clear()
R.setInvokeBehaviour(function() return true, "Dragon Cannelloni spawned!" end)
R.notifyRemote.OnClientEvent:FireAll("WHWIN2", 5.5, "Sounds.Sfx.Blop", "Top")
H.pump(300000)
check("a two word name posts", #POSTS >= 1, tostring(#POSTS))
if POSTS[1] then
    check("with both words and no suffix",
        tostring(POSTS[1].body):find("Dragon Cannelloni", 1, true) ~= nil
            and tostring(POSTS[1].body):find("spawned", 1, true) == nil,
        tostring(POSTS[1].body):sub(1, 240))
    check("routed as rare on its generation", wentTo(L.HookRare))
end

-- an ordinary one in the same wording goes the other way
clear()
R.setInvokeBehaviour(function() return true, "Meowl spawned!" end)
R.notifyRemote.OnClientEvent:FireAll("WHWIN3", 5.5, "Sounds.Sfx.Blop", "Top")
H.pump(300000)
check("a common one posts to the normal channel", wentTo(L.HookNormal))
check("named without the suffix", POSTS[1]
    and tostring(POSTS[1].body):find("Meowl", 1, true) ~= nil
    and tostring(POSTS[1].body):find("spawned", 1, true) == nil)

-- Everything below forces failures, and a failure rests that url. os.clock
-- barely moves in here, so a rested url stays rested for the rest of the run --
-- which is why the end-to-end checks are above this line rather than after it.
-- rate limiting falls through to the spare
clear()
FORCE_STATUS = function(url) if url == L.HookNormal[1] then return 429 end end
L.PostWin("RATED1", "Meowl")
H.pump(300000)
check("a 429 on the first is retried on the spare", #POSTS == 2, tostring(#POSTS))
check("and the spare is the one that took it",
    POSTS[#POSTS] and POSTS[#POSTS].url == L.HookNormal[2])

-- and it stays off the rate-limited one while it cools
clear()
L.PostWin("RATED2", "Meowl")
H.pump(300000)
check("the cooling one is skipped next time", #POSTS == 1, tostring(#POSTS))
check("straight to the spare", POSTS[1] and POSTS[1].url == L.HookNormal[2])
FORCE_STATUS = nil

-- a rare one that cannot reach its own channel still gets posted
clear()
FORCE_STATUS = function(url) if url == L.HookRare[1] then return 500 end end
L.PostWin("RAREFALL", "La Vacca")
H.pump(300000)
check("a rare that its channel refuses falls back to the normal one",
    #POSTS >= 2 and POSTS[#POSTS].url ~= L.HookRare[1],
    tostring(#POSTS) .. " posts")
FORCE_STATUS = nil

-- the switch
clear()
L.HookOn = false
check("HookOn=false posts nothing", L.PostWin("OFFCODE", "Meowl") == false)
H.pump(300000)
check("and nothing went out", #POSTS == 0, tostring(#POSTS))
L.HookOn = true

print("")
print(("checks: %d   failures: %d"):format(checks, #fails))
for _, f in ipairs(fails) do print("  FAIL  " .. f) end
print(("runtime errors: %d"):format(H.errors and #H.errors or 0))
if H.errors then
    local seen = {}
    for _, e in ipairs(H.errors) do
        local k = tostring(e)
        if not seen[k] then seen[k] = true; print("  ERR  " .. k) end
    end
end
end
