---
name: awecraft-run-verify
description: Use when running or choosing AweCraft verification gates - G0, smoke, probe, render - when interpreting an AWECRAFT_LOGIC RESULT, or when deciding whether a change is actually proven.
---

# Choosing and running AweCraft gates

This skill owns **which gate and how strong**; `godot/HARNESS.md` owns the arms, the standing values
and the recipes, and `godot/AGENTS.md` owns the shape of a godot call. Never restate either.

## The call shape (owned by godot/AGENTS.md)

One godot process at a time, `HOME=/tmp/dsh_home` in the same bash command, absolute engine path,
`--path godot` from the repo root. Recipes: `godot/HARNESS.md` §4. Check `pgrep -af '[g]odot'` first —
a parallel agent or a coordinator gate job may hold the slot.

## The tiers

| Tier | What it is | When |
|---|---|---|
| **G0** | one headless load: **zero `SCRIPT ERROR` lines** | always, every task, hard |
| **SMOKE** | 2–4 dependency-mapped modes (+ `genhash` when `world/*` or `autoload/data.gd` changed) | every code task |
| **PROBE** | the task's own arm, when the spec defines one | when the spec defines one |
| **RENDER** | at most **one** shot, `AWECRAFT_RADIUS=1–2`, ~300 s budget, under `xvfb-run -a` | only when the change is visual |
| **HEAVY** | boundary r4, flake, genhash re-run, r50 nightly, full battery | **coordinator only** — `awecraft-heavy-gates` |

**G0 is not `rc=0`.** The engine exits 0 even when scripts fail to compile (verified 2026-09-16: a
broken `godot/scenes/harness.gd` parse printed 5 SCRIPT ERROR lines and exited 0). Count the errors.

## Picking the modes

`godot/HARNESS.md` §1 is the reference table (and `tasks/harness_data.yaml` the machine source) —
map **by dependency**, not by habit: the arms that exercise the area you changed, plus the parity
arms. `genhash` is the world-generation parity gate (`godot/world/*`, `godot/autoload/data.gd`);
`boundary` is the streaming arm; the fluid arms hold the zero-write invariant; the C++-lane arms
prove no GDScript reference kernel silently took over. The battery list is authoritative in the data
file.

## Reading a result

- Compare against the **standing values** in `godot/HARNESS.md` §3. A moved value is a **finding**:
  either the change intended it — then re-establish it and say so explicitly — or it is a regression.
  Never "re-baseline" silently.
- Documented non-fatal log noise (§3) is not chased; G0 still requires zero `SCRIPT ERROR` from our
  own code paths.
- A render is evidence about **geometry, layout and UI** only — the recipe is a proxy renderer, not
  the shipped `forward_plus` look (§2 owns the warning).

## Evidence

Log to `.scratch/AC-NNNN-gates/` at the **repo root**, and write the self-contained
`tasks/AC-NNNN/AC-NNNN-results.html` (G0 output, RESULT JSON, deviations, PNG only when visual).
Report **values**, not prose.
