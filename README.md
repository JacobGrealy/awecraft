# AweCraft

A voxel sandbox game in the spirit of Minecraft: procedurally generated terrain, mining
and building, crafting, survival, mobs, fluids, day/night. Built on **Godot 4.7.1**, with a
C++ GDExtension (`gdext/`) handling the hot paths — world generation, meshing, chunk I/O
and the light engine.

The product target is **Windows**: a stamped `.exe` is served over the LAN and playtested
in-game. Development and all automated verification happen on this Linux box, headless.

## Where to look

`AGENTS.md` is the map: it indexes every document, standing invariant and agent procedure. For a
human, the short version is — current state and resume steps are the top checkpoint of
`godot/CONTINUITY.md`, what to work on next is `python3 tasks/scripts/tasks.py next`, the code
structure is `godot/ARCHITECTURE.md`, and running, verifying or building anything is
`godot/HARNESS.md` plus `godot/OPS.md`.

## Run it (Linux dev box)

```bash
export HOME=/tmp/dsh_home; mkdir -p $HOME        # the real HOME is read-only here

~/tools/godot/godot --headless --path godot --quit          # load check: expect 0 script errors
xvfb-run -a ~/tools/godot/godot --path godot                # windowed (needs a Vulkan device)
AWECRAFT_LOGIC=player ~/tools/godot/godot --headless --path godot   # one test arm
```

Every `AWECRAFT_LOGIC` arm, the `AWECRAFT_BATTERY` runner, render hooks, standing gate
values and the sandboxed recipes live in **`godot/HARNESS.md`**. Machine/sandbox rules are
in **`godot/OPS.md`** — the short version: always prefix every godot call with
`HOME=/tmp/dsh_home`, always pass an absolute engine path plus `--path godot` from the repo
root, and never run two godot processes at once.

## Build the Windows product

```bash
./build_windows.sh              # gdext (linux+windows) + export + restart the download daemon
./build_windows.sh --no-serve   # export only
```

Artifacts land in `exports/windows/` (git-ignored, retention = newest 3 stamped pairs) and
are served at `http://192.168.0.224:8080/AweCraft.exe`. Use `AweCraft_debug_console.console.exe`
on Windows when you need the engine log in a console window.

## Source layout

| Path | What it is |
|---|---|
| `godot/` | the Godot project (`--path godot`) — GDScript game logic, shaders, assets, and the docs about running it |
| `gdext/` | C++ GDExtension sources, built with SCons into `gdext/bin/libchunkio.{so,dll}` |
| `tasks/` | the ticket system: `TASKS.yaml`, `scripts/tasks.py` (the only writer), `webui.py`, `templates/`, per-ticket folders |
| `docs/` | design essays (HTML) — see `docs/INDEX.md` |
| `exports/` | built Windows artifacts (git-ignored) |
| `.scratch/` | working scratch: gate logs, screenshots, probe output (git-ignored) |

## How work happens

Every change is a ticket (`AC-NNNN`) in `tasks/TASKS.yaml`. Mutate it only through
`python3 tasks/scripts/tasks.py <cmd>` — hand-editing that file is forbidden. The ticket
board is served on the LAN:

```bash
python3 tasks/webui.py --daemon          # → http://192.168.0.224:5180/
```

Changes to the project's structure must update `godot/ARCHITECTURE.md` in the same task — see the
invariants in `AGENTS.md`. How work is delegated, verified and closed out lives in the project
skills under `.dsh/skills/` (start with `awecraft-delegate`), with the paste-ready subagent prompt
in `tasks/templates/two-phase.md`.
