# nyx-dumper

A tiny, **readable** Roblox offset extractor. One Python file. It reads
Roblox's memory (never writes), pulls out offsets, saves `offsets.h`, and
opens the folder for you.

Read `dumper.py` top to bottom before running it — that's the whole point of
it being a script instead of an `.exe`. No network, no writes to Roblox, no
account access.

## Run it

1. Install **Python 3** from [python.org](https://www.python.org/downloads/)
   — tick **"Add Python to PATH"** during setup.
2. Download `dumper.py` from this folder (the **Raw** button → Save As).
3. **Join a Roblox game** and wait until you're fully loaded in.
4. **Double-click `dumper.py`.** A console opens and does the work. When it
   finishes it writes `offsets.h` next to the script and opens the folder.

If double-clicking just flashes and closes, open a terminal in the folder
and run `python dumper.py` so you can read the error.

## If it says Hyperion blocked it

Roblox's anti-cheat often refuses to let anything read its memory. That's
expected. Do this instead:

1. `Ctrl+Shift+Esc` → **Details** tab
2. Right-click **RobloxPlayerBeta.exe** → **Create dump file**
3. Note the path it gives you, then run:
   ```
   python dumper.py "C:\path\to\RobloxPlayerBeta.DMP"
   ```
   Same output, but from the dump — this path always works.

## What comes out

`offsets.h` — ready to `#include`. Anything it couldn't find is written as a
`// (unresolved)` comment. Those just need their signature updated for the
current build; send the console output back and it's a quick fix.

## The signatures

The `SIGNATURES` table at the top of `dumper.py` decides what gets found.
String-based entries are reliable across updates. The code-signature slots
are starter examples showing the format — fill them in with patterns from
the target build.
