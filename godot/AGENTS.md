# godot/ — the game (scope rules)

Traps that bite when you work inside the Godot project. **What the game is made of — shape,
autoloads, scene tree, native extension, data/save formats, conventions — is owned by
`ARCHITECTURE.md`.** Read it before a code task; this file does not restate it.

## Running anything

- Engine `~/tools/godot/godot` (**4.7.1.stable.official.a13da4feb**), always an absolute path,
  always `--path godot` **from the repo root**.
- Every godot call: `export HOME=/tmp/dsh_home; mkdir -p $HOME` **in the same bash command** —
  the real HOME is not writable and the engine segfaults (rc=134) on the first `user://` write.
- **One godot process at a time** — two in parallel corrupt the `.godot/` cache. Before every call
  check `pgrep -af '[g]odot'` and wait: another agent may hold the slot, and a coordinator gate job
  holds it until its `.scratch/AC-NNNN-gates/HEAVY_GATES_DONE` marker appears. **Never kill a
  godot process you did not start.**
- Arms, battery, standing gate values, run recipes → `HARNESS.md`. Machine, sandbox, build/serve,
  daemons, git → `OPS.md`. Link to them; never restate them.

## Traps

- The scene tree is **built at runtime**: `scenes/main.tscn` holds a single `Main` node and
  everything else is instantiated in code. Opening a `.tscn` tells you nothing — read `main.gd`.
- `godot/bin/`, `.godot/`, `exports/` are build outputs: never hand-edit, never commit.
- The C++ extension is **required**: with `godot/bin/libchunkio.so` missing the game prints
  `AWECRAFT CANNOT START` and quits. A fresh worktree has no `.so` — copy it from the main tree
  (`OPS.md` §2). C++ rules → `../gdext/AGENTS.md`.
- Renders on this box are a **proxy** (software GL), not the shipped `forward_plus` look: evidence
  about geometry/layout/UI only. `HARNESS.md` §2 owns the warning and the shot hooks.
- Working output and gate logs go to the **repo-root** `.scratch/` (git-ignored). `godot/.scratch/`
  is legacy — its newest entry is AC-0237; do not add to it.

## Architecture sync — the owner of invariant 2 in `../AGENTS.md`

A task that changes structure — a new or removed autoload, a moved or renamed component, a new
subsystem or native layer, a changed data or save format, a changed convention — updates
`ARCHITECTURE.md` **in the same task**. A task that leaves that file wrong is not done; the
`awecraft-closeout` skill checks it at closeout.

## Subdirectory scopes (loaded automatically when you touch a file there)

| Directory | Scope rules |
|---|---|
| `world/` | `world/AGENTS.md` |
| `scenes/` | `scenes/AGENTS.md` |
| `autoload/` | `autoload/AGENTS.md` |
| `../gdext/` | `../gdext/AGENTS.md` |
