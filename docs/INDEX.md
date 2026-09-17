# docs/ — index of design essays

These are long-form design documents (HTML) written while working a design problem. They
are **not** the source of truth for how the code works today — that is
`godot/ARCHITECTURE.md` — but they carry the reasoning, options and rejected alternatives
behind the current design.

| Doc | Topic | Status |
|---|---|---|
| `planet-epic.html` | **Round planet epic (plan)** — grid lock (W/R = π/2 → 1 m blocks at R = 4000), spherical placement, cross-face movement, radial-gravity flight, satellite LOD tier | **approved 2026-09-17** · tickets AC-0306…AC-0311 (tracked) |
| `flight-world-epic.html` | **Flight-ready world epic — lighting & far-band (design + measurements)** — the five decisions (starlight engine, no-caves + h-only far data, no-pop promotion, save filter pending), the RP before/after re-profile, the honest done-when verdict, and the open AC-0299 user decisions | **in flight — awaiting the AC-0299 answers** (tracked) |
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
