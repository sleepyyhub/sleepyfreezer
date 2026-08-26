-- A place where the redeem never answers at all, so discovery never reports done and
-- the readiness gate has to open on its own deadline.
RIG.setInvokeBehaviour(function()
    coroutine.yield()
end)
