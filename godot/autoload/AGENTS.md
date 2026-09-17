# godot/autoload/ — the six singletons (scope rules)

The autoloads, their **order** and their duties are owned by `../ARCHITECTURE.md` §2. Read it before
touching any of them. This file owns the rules that table does not carry.

- **Load order is behaviour.** `project.godot` registers them in a fixed order, and `Data` and
  `Debug` are used by everything downstream. Adding, removing or renaming an autoload edits
  `project.godot` **and** the §2 table in the same task (invariant 2, `../AGENTS.md`).
- **`data.gd` is the table home** — blocks, items, mobs, recipes, atlas rects, world constants. The
  JSON split is still open (AC-0141/AC-0142), so never assume a data file exists. It is also the
  generation input: a change here owes the gates in `../world/AGENTS.md`.
- **`audio.gd`** is a procedural synth, and headless has no audio device: an arm can assert that the
  *trigger* fired, never the sound.
- **`settings.gd`** owns one clamp chain (sim → render, window apply, chunk meshes per frame).
  Changing a default or a range moves standing gate values — re-establish them (`../HARNESS.md` §3).
- **`save.gd`** owns slot save/continue. Saves live under `user://`, which in this sandbox is
  `/tmp/dsh_home/…` and does not survive a reboot. Format changes follow `../ARCHITECTURE.md` §5.
- **`debug.gd`** is the headless test API plus error/crash capture, session logs and the console tee.
  Arms call it — do not reimplement its dumps inside an arm.

`../core/*.gd` (pure-logic helpers with no node dependencies) and the rest of the runtime shape:
`../ARCHITECTURE.md` §3.
