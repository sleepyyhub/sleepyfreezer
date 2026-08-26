-- Make the redeem remote answer like a real one: a round trip, not an instant return.
-- Without this the fake server replies inside the same call and discovery finishes
-- before the UI block would have run anyway, so the harness cannot tell the two
-- orderings apart.
RIG.setInvokeBehaviour(function(remote, code)
    task.wait(0.12)
    return false, "Invalid Code"
end)
