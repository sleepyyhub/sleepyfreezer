-- Same local bindings the real script makes at lines 749 and 758,
-- plus stubs for the tail-side locals the hot block closes over.
local codeFrom, payloadText, selectArg = L.CodeFrom, L.PayloadText, select
local clock, defer, protected = os.clock, task.defer, pcall

local firedSeen = {}
L.FiredSeen = firedSeen
L.FIRED_TTL = 30

local rawFire = function() end
local killFeed = function() end
L.Dispatch = function() end
L.Note = nil
L.NotifyRedeem = false

-- State the real script would be in once a verified RemoteFunction is armed
-- and the remote-notify detector is live: SyncFast() reads exactly these.
L.RedeemRemote = { InvokeServer = fakeInvokeServer, FireServer = fakeFireServer }
L.RedeemRemoteIsEvent = false
L.RedeemRemoteTested = true   -- verified -> fastSafe, no pcall on the send
L.RedeemPath = "remote"
L.RawFire = true              -- raw mode (no codeFrom on the hot path)
L.Instrument = false
L.RaceArmed = false
L.MultiSurface = false
L.Solo = true
L.PoleOn = false
L.AutoOn = true
L.GuessCode = false
L.Threshold = 1
L.RemoteDetectOn = false      -- BindFast() at block end needs a real signal; skip it
L.SignalMode = "Immediate"
L.Fps = 60
