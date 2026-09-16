# docs/ — index of design essays

These are long-form design documents (HTML) written while working a design problem. They
are **not** the source of truth for how the code works today — that is
`godot/ARCHITECTURE.md` — but they carry the reasoning, options and rejected alternatives
behind the current design.

| Doc | Topic | Status |
|---|---|---|
| `worldgen-current.html` | **World generation & streaming, end to end (current state)** — the atlas of the live pipeline: bands, LOD tiers, scheduler, light (the reference for the AC-0283/0284/0286/0287 epic) | tracked |
| `world-generation.html` | World generation atlas — the earlier survey of terrain/cave/ore generation | tracked |
| `humanoid-brainstorm.html` | Humanoid models / animation brainstorm (mobs, rigs) | tracked |
| `creature-chisel-plan.html` | Chiseled creature & character system plan (micro-voxel characters) | **local only — not committed** |
| `halo-loot-brainstorm.html` | Halo feel + infinite loot brainstorm | **local only — not committed** |

Conventions:
- Design essays live here; operational docs do not (see `AGENTS.md` for the placement rule).
- A doc marked "not committed" is untracked on purpose — do not `git add` it as a side
  effect of an unrelated commit.
- When an essay's design ships, the durable outcome belongs in `godot/ARCHITECTURE.md` or
  `godot/OPS.md`; the essay stays as history and should be labelled with what shipped.
