-- Candidate hot paths. build(ctx) returns { get, gate }.
--   get()      -> the function that would actually be connected right now
--   gate(bool) -> auto on/off
--
-- get() rather than a fixed handler is what makes the swapped-connection
-- variants honest: in the real script the gate is applied by rebinding the
-- OnClientEvent connection, so the live function carries no wrapper. A
-- benchmark that called through a dispatch closure would be charging them
-- for an indirection they do not have.
--
-- All variants must behave identically: a "Top" message with a fresh code
-- sends once, a repeat sends nothing, a non-Top message sends nothing, a
-- table payload is unwrapped, and auto off sends nothing.
--
-- ctx = { invoke, remote, sent, payloadText }

local V = {}

V.current = function(ctx)
    local invoke, remote, sent = ctx.invoke, ctx.remote, ctx.sent
    local payloadText = ctx.payloadText
    local ready = true
    local handler = function(msg, _, _, position)
        if position ~= "Top" then return end
        if not ready then return end
        if type(msg) ~= "string" then
            msg = payloadText(msg, 0)
            if not msg then return end
        end
        if sent[msg] then return end
        sent[msg] = true
        invoke(remote, msg)
    end
    return {
        get = function() return handler end,
        gate = function(on) ready = on end,
    }
end

V.swapgate = function(ctx)
    local invoke, remote, sent = ctx.invoke, ctx.remote, ctx.sent
    local payloadText = ctx.payloadText
    local live = function(msg, _, _, position)
        if position ~= "Top" then return end
        if type(msg) ~= "string" then
            msg = payloadText(msg, 0)
            if not msg then return end
        end
        if sent[msg] then return end
        sent[msg] = true
        invoke(remote, msg)
    end
    local idle = function() end
    local current = live
    return {
        get = function() return current end,
        gate = function(on) current = on and live or idle end,
    }
end

V.rawdedup = function(ctx)
    local invoke, remote, sent = ctx.invoke, ctx.remote, ctx.sent
    local payloadText = ctx.payloadText
    local rawget, rawset = rawget, rawset
    local ready = true
    local handler = function(msg, _, _, position)
        if position ~= "Top" then return end
        if not ready then return end
        if type(msg) ~= "string" then
            msg = payloadText(msg, 0)
            if not msg then return end
        end
        if rawget(sent, msg) then return end
        rawset(sent, msg, true)
        invoke(remote, msg)
    end
    return {
        get = function() return handler end,
        gate = function(on) ready = on end,
    }
end

V.lastslot = function(ctx)
    local invoke, remote, sent = ctx.invoke, ctx.remote, ctx.sent
    local payloadText = ctx.payloadText
    local ready, last = true, nil
    local handler = function(msg, _, _, position)
        if position ~= "Top" then return end
        if not ready then return end
        if type(msg) ~= "string" then
            msg = payloadText(msg, 0)
            if not msg then return end
        end
        if msg == last then return end
        if sent[msg] then return end
        last = msg
        sent[msg] = true
        invoke(remote, msg)
    end
    return {
        get = function() return handler end,
        gate = function(on) ready = on end,
    }
end

V.foldedgate = function(ctx)
    local invoke, remote = ctx.invoke, ctx.remote
    local payloadText = ctx.payloadText
    local open = ctx.sent
    local closed = setmetatable({}, {__index = function() return true end})
    local sent = open
    local handler = function(msg, _, _, position)
        if position ~= "Top" then return end
        if type(msg) ~= "string" then
            msg = payloadText(msg, 0)
            if not msg then return end
        end
        if sent[msg] then return end
        sent[msg] = true
        invoke(remote, msg)
    end
    return {
        get = function() return handler end,
        gate = function(on) sent = on and open or closed end,
    }
end

V.swapgate_cold = function(ctx)
    local invoke, remote, sent = ctx.invoke, ctx.remote, ctx.sent
    local payloadText = ctx.payloadText
    local cold
    local live = function(msg, _, _, position)
        if position ~= "Top" then return end
        if type(msg) == "string" then
            if sent[msg] then return end
            sent[msg] = true
            return invoke(remote, msg)
        end
        return cold(msg)
    end
    cold = function(msg)
        local text = payloadText(msg, 0)
        if not text then return end
        if sent[text] then return end
        sent[text] = true
        invoke(remote, text)
    end
    local idle = function() end
    local current = live
    return {
        get = function() return current end,
        gate = function(on) current = on and live or idle end,
    }
end

-- Position compared first and the whole body inlined with no separate
-- readiness concept: the gate swaps the connection, and the dedup store
-- happens before the send so a re-entrant fire cannot double up.
V.minimal = function(ctx)
    local invoke, remote, sent = ctx.invoke, ctx.remote, ctx.sent
    local payloadText = ctx.payloadText
    local live
    live = function(msg, _, _, position)
        if position ~= "Top" or sent[msg] then return end
        if type(msg) ~= "string" then
            local text = payloadText(msg, 0)
            if not text or sent[text] then return end
            sent[text] = true
            return invoke(remote, text)
        end
        sent[msg] = true
        return invoke(remote, msg)
    end
    local idle = function() end
    local current = live
    return {
        get = function() return current end,
        gate = function(on) current = on and live or idle end,
    }
end

V.minimal_raw = function(ctx)
    local invoke, remote, sent = ctx.invoke, ctx.remote, ctx.sent
    local payloadText = ctx.payloadText
    local rawget, rawset = rawget, rawset
    local live
    live = function(msg, _, _, position)
        if position ~= "Top" or rawget(sent, msg) then return end
        if type(msg) ~= "string" then
            local text = payloadText(msg, 0)
            if not text or rawget(sent, text) then return end
            rawset(sent, text, true)
            return invoke(remote, text)
        end
        rawset(sent, msg, true)
        return invoke(remote, msg)
    end
    local idle = function() end
    local current = live
    return {
        get = function() return current end,
        gate = function(on) current = on and live or idle end,
    }
end

-- Reference points, not candidates. floorcall does nothing but the send, so
-- it is the irreducible cost of this benchmark: two closure calls. empty
-- returns immediately. If the real variants sit close to floorcall, the
-- logic between them is smaller than the measurement can see.
V.floorcall = function(ctx)
    local invoke, remote = ctx.invoke, ctx.remote
    local handler = function(msg)
        return invoke(remote, msg)
    end
    return {get = function() return handler end, gate = function() end}
end

-- Structurally different rather than a reordering: with exactly one surface
-- armed, the same announcement cannot arrive twice, so the dedup lookup and
-- store are dead weight. The gate swaps between this and a deduping handler,
-- so the table comes back the moment a second surface goes live.
V.solo = function(ctx)
    local invoke, remote, sent = ctx.invoke, ctx.remote, ctx.sent
    local payloadText = ctx.payloadText
    local state = ctx.state or {}
    local cold
    -- Models the shipped handler, which hands every non-Top message to a
    -- side function that checks for a pending verdict. An earlier version of
    -- this variant just returned, which made it look 8ns cheaper on side
    -- toasts than it is and made solo_inline look like a regression.
    local side = function()
        if state.pending then return end
    end
    local live = function(msg, _, _, position)
        if position ~= "Top" then return side(msg) end
        if type(msg) == "string" then
            return invoke(remote, msg)
        end
        return cold(msg)
    end
    cold = function(msg)
        local text = payloadText(msg, 0)
        if not text then return end
        invoke(remote, text)
    end
    local idle = function() end
    local current = live
    return {
        get = function() return current end,
        gate = function(on) current = on and live or idle end,
        solo = true,
    }
end

-- solo still pays a function call to reject a side toast, and side toasts
-- are the commonest message on this remote. The rejection is inlined to a
-- single field read, so only an actual pending verdict costs a call.
V.solo_inline = function(ctx)
    local invoke, remote = ctx.invoke, ctx.remote
    local payloadText = ctx.payloadText
    local state = ctx.state or {}
    local cold, side
    local live = function(msg, _, _, position)
        if position ~= "Top" then
            if state.pending then return side(msg) end
            return
        end
        if type(msg) == "string" then
            return invoke(remote, msg)
        end
        return cold(msg)
    end
    cold = function(msg)
        local text = payloadText(msg, 0)
        if text then invoke(remote, text) end
    end
    side = function() end
    local idle = function() end
    local current = live
    return {
        get = function() return current end,
        gate = function(on) current = on and live or idle end,
        solo = true,
    }
end

-- The type check flipped: a table payload is the rare case, so the string
-- case is reached with one comparison against an interned constant and the
-- table case tail-calls out.
V.solo_typelast = function(ctx)
    local invoke, remote = ctx.invoke, ctx.remote
    local payloadText = ctx.payloadText
    local state = ctx.state or {}
    local cold
    local live = function(msg, _, _, position)
        if position ~= "Top" then
            if state.pending then return cold(msg) end
            return
        end
        if type(msg) ~= "string" then return cold(msg) end
        return invoke(remote, msg)
    end
    cold = function(msg)
        local text = payloadText(msg, 0)
        if text then invoke(remote, text) end
    end
    local idle = function() end
    local current = live
    return {
        get = function() return current end,
        gate = function(on) current = on and live or idle end,
        solo = true,
    }
end

-- The type check dropped as well. A table payload goes out as-is and the
-- server rejects it; the deferred tail already extracts the real code from
-- the original message and resends, which is the same "fire raw, correct
-- after" contract the string path runs under. Leaves one comparison and the
-- call between the handler being entered and the packet leaving.
V.solo_bare = function(ctx)
    local invoke, remote = ctx.invoke, ctx.remote
    local state = ctx.state or {}
    local side = function() end
    local live = function(msg, _, _, position)
        if position ~= "Top" then
            if state.pending then return side(msg) end
            return
        end
        return invoke(remote, msg)
    end
    local idle = function() end
    local current = live
    return {
        get = function() return current end,
        gate = function(on) current = on and live or idle end,
        solo = true,
        raw = true,
    }
end

-- Second reference: a handler that does nothing at all. The gap between this
-- and floorcall is the send call; the gap between this and zero is whatever
-- the timing loop itself costs.
V.noop = function()
    local handler = function() end
    return {get = function() return handler end, gate = function() end,
            sends = false}
end

-- Third reference, bounding the modelling error in the other two. The fake
-- send is a Lua closure; the real one is InvokeServer, a C function, and
-- Luau reaches those through a cheaper path. This calls a C builtin instead,
-- which the compiler turns into a FASTCALL and so undershoots a generic C
-- call. floorcall is therefore the ceiling on the send call and this is the
-- floor; the live cost sits between them.
V.floorcall_c = function(ctx)
    local remote = ctx.remote
    local rawequal = rawequal
    local handler = function(msg)
        return rawequal(remote, msg)
    end
    return {get = function() return handler end, gate = function() end,
            sends = false}
end

return V
