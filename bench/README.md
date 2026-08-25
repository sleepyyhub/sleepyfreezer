# LUCK bench harness

Loads the real script against a fake Roblox client under the standalone Luau
interpreter, connects the game's own notification handler ahead of ours, then
fires announcements and times detect -> send.

    # from this directory, with a luau binary on PATH
    { cat bench_pre.luau; echo; echo "do"; cat ../LUCK_fast.lua; echo "end"; \
      echo; cat bench_post.luau; } > run.luau
    luau run.luau

`bench_report.txt` is the output, with the original for comparison.

It measures Lua work only. It says nothing about the wire, or about the
network send step the packet waits for after the invoke.
