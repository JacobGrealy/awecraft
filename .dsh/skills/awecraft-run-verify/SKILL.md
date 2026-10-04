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
| **G0** | one headless load: **zero `SCRIPT ERROR` AND zero `SHADER ERROR` lines** (AC-0396) | always, every task, hard |
| **SMOKE** | 2–4 dependency-mapped modes (+ `genhash` when `world/*` or `autoload/data.gd` changed) | every code task |
| **PROBE** | the task's own arm, when the spec defines one | when the spec defines one |
| **RENDER** | at most **one** shot, `AWECRAFT_RADIUS=1–2`, ~300 s budget, under `xvfb-run -a` | only when the change is visual |
| **HEAVY** | boundary r4, flake, genhash re-run, r50 nightly, full battery | **coordinator only** — `awecraft-heavy-gates` |

**G0 is not `rc=0`.** The engine exits 0 even when scripts fail to compile (verified 2026-09-16: a
broken `godot/scenes/harness.gd` parse printed 5 SCRIPT ERROR lines and exited 0). Count the errors.
**The same is true of shaders** (AC-0396): a shader that fails to compile is drawn with the engine's
fallback material (the white planet) and the process still exits 0 — the only trace is the
`SHADER ERROR` line, so G0 is zero `SCRIPT ERROR` **and** zero `SHADER ERROR` lines, counted by
`python3 tasks/scripts/gate_census.py <log>` (names each shader error). The lazy-compile trap: a run
that never builds a material reports zero shader errors while the shader is broken, so the standing
`shaderforce` arm (FORCES every shipped shader to compile, Forward+ only) is the check that keeps a
clean-looking run honest — run it (and census its log) in the heavy stage, not just G0.

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

## A shot that writes no file is not evidence of anything

Four failed snapshot attempts on 2026-10-04 produced no picture and no error message. Three traps, all
silent, all now known:

- **`AWECRAFT_SIZE` takes a COMMA** — `1280,720`. The parser splits on `,` (main.gd:115), so `1280x720`
  becomes `parts[1] = ""` → `to_int()` 0 → a **1280-by-zero window** and no snapshot at all.
- **`AWECRAFT_SNAP_DRAIN` must be large** (AC-0391's recipe uses 12000, not 1) — a small value captures
  an unbuilt world. Note the drain is in FRAMES: at the Forward+ path's ~5 FPS a 12000-frame drain is
  ~40 minutes, so a short `timeout` kills the run before the shot is taken.
- **The snapshot hook belongs to specific modes.** `AWECRAFT_LOGIC=satellite` with `AWECRAFT_SNAPSHOT`
  set runs cleanly and writes nothing. AC-0391's satellite evidence came from `LOGIC=wallshot` with
  `NO_WORLD_VIS=1`, `AERO=0`, `CLOUDS=0`, `TIME=0.5`, `RADIUS=4`.

**Before trusting any shot, check that the file exists and is newer than the run started.** And note the
related trap that cost a day: a shader compiles LAZILY, when a material is first built, so a run that
never builds the material reports **zero shader errors** while the shader is broken. A green check on a
code path the run never reached is a false pass, not a pass.

## The snapshot recipe that actually works (2026-10-04)

Five attempts failed before this one. **Set NO `AWECRAFT_LOGIC` arm** - with any arm set,
`main.gd:161` routes straight to `_run_game` and the *arm* owns the shot, so the snapshot write at
`main.gd:179` never executes. The working path is the MENU boot:

    AWECRAFT_SNAPSHOT=<ABSOLUTE path>        # no AWECRAFT_LOGIC
    AWECRAFT_SIZE=1280,720                   # COMMA, not x
    AWECRAFT_SNAP_DRAIN=600                  # FRAMES; 12000 at ~5 FPS exceeds any sane timeout
    AWECRAFT_RADIUS=4 AWECRAFT_TIME=0.5 AWECRAFT_CAM=<preset>

Under `xvfb-run` + lavapipe + `--rendering-driver vulkan`. Verified: rc=0, zero shader errors, zero
script errors, two PNGs written. **Always check the file exists afterwards** - a shot that writes
nothing reports success just the same.
