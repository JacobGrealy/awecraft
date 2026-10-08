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
| **G0** | one headless load: **zero `SCRIPT ERROR` AND zero `SHADER ERROR` lines, AND the process exits 0** (AC-0396/AC-0403) | always, every task, hard |
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

**The blind spot runs the other way too, and this project has a live defect in it** (AC-0403,
2026-10-08): the slab use-after-free dies with signal 11 (rc 134) while leaving **zero SCRIPT ERROR
and zero SHADER ERROR lines** — the backtrace is a C++ `handle_crash` dump the census never counts.
**A CLEAN ERROR CENSUS IS NOT EVIDENCE OF A CLEAN RUN: G0 = census AND the process exit status,
paired; either alone is a false pass** (the `gate_census.py` docstring carries the record). That is
the standing rule, not a one-off: the crash is unreproduced on this box, so the paired check is the
only thing that would catch its next occurrence.

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
- A value that has drifted OUT of band may be a **STALE BOUND rather than a regression** (AC-0408,
  2026-10-08). Before calling it a regression, answer three questions: **what does the counter
  actually count** (its mechanism, not its name — `staged_dropped` is a churn census of in-progress
  builds being staged repeatedly, not lost work), **what the bound was derived from, and when** (the
  old ceiling was calibrated from a single reading on the pre-carve tree), and **whether the world
  changed underneath it** (the carve era added per-slab work per walk; the counter tracked it while
  the drain's health fields stayed green). If it is a stale bound, re-base it **WITH THE REASONING
  RECORDED in the standing row** (`HARNESS.md` §3 owns the row, the value and the tripwires — link,
  don't restate) and **never to make the number green**: the AC-0408 re-base still reads above the
  old bound, and that is the point. Then **replace the bare threshold with tripwires that catch a
  RISING value** — the health fields, not the counter itself. Two counters went through this in one
  round with opposite verdicts: `staged_dropped` was the stale bound (re-based with reasoning) and
  `unbodied_built_final` (a must-be-zero) could not be resolved stale-or-real on the spot — it was
  flagged as its own follow-up (AC-0409), not relaxed. A bare "must be 0 / below N" that is quietly
  allowed to be violated is exactly how a real regression becomes invisible.
- Documented non-fatal log noise (§3) is not chased; G0 still requires zero `SCRIPT ERROR` from our
  own code paths.
- A render is evidence about **geometry, layout and UI** only — the recipe is a proxy renderer, not
  the shipped `forward_plus` look (§2 owns the warning).

## Evidence

Log to `.scratch/AC-NNNN-gates/` at the **repo root**, and write the self-contained
`tasks/AC-NNNN/AC-NNNN-results.html` (G0 output, RESULT JSON, deviations, PNG only when visual).
Report **values**, not prose.

## Acceptance must test the case the user is actually looking at

A gate certifies the case it measures — the case it cannot measure is the case that survives. The
limb-glow acceptance (AC-0404) was verified by altitude — the gate-open rung, where the near tiers
draw 0 px — and reported as satisfying the request, but the gate controlled **WHEN** the glow drew,
not **WHICH MATERIAL** carried it: the annulus haze term painted the rim in the user's actual state
(gate closed, near tiers drawn, player away from the origin) where no gate was looking, so the
defect survived the acceptance and took a user report plus a full audit to find. The user's eye has
now caught several defects that measurements passed, on this project, repeatedly — when eye and
measurement disagree, the eye is describing something the measurement did not capture, and the user
is the authority (AC-0407's ticket says it). Acceptance criteria must include the case the user is
actually looking at — their altitude, their distance from the origin, their settings — not the case
that is easiest to measure.

## A fix often introduces the next defect

The seam-fade fix (AC-0400) passed its own acceptance — pixel-verified at the reported altitudes,
byte-identical at ground level — and still CREATED the next defect: pointing the fade at full air
colour left a haze term that forced the annulus's outer 48 m to 100% air at EVERY view distance —
an air-coloured ring on a near tier, visible only away from the origin. It took a user report and a
full audit of every near-tier shader to find it (AC-0404). Treat every fix as a candidate cause of
the next report: the fix's acceptance covers the reported case, but the fix's BLAST RADIUS — every
state the changed term touches — is what needs the audit, and for visual work the user's state and
the gate's state can differ in exactly one variable (here: distance from the world origin).

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
