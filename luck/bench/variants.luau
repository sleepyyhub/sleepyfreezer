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
    local cold
    local live = function(msg, _, _, position)
        if position ~= "Top" then return end
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

return V
