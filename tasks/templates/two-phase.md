# AC-0105 — two-phase subagent workflow (reusable coordinator templates)

Process artifact for the DSH-coordinated AweCraft pipeline (local LLM, ONE
subagent at a time, sequential). Replace every `AC-NNNN` with the real task id
before pasting. Templates reference docs BY PATH only — never inline their
content into a prompt.

Workflow:

    [trivial-bypass check: labels `trivial` | title match | world/*-untouched
     + <2 files + no Data.* ids — see TRIVIAL-LABEL BYPASS]
            ──yes──► Run 2 (medium builder, spec.html only — no plan.html)
           │no
           ▼
    Run 1 (xhigh, read-only research, via the `subagent_plan` tool)
           ──► tasks/AC-NNNN/plan.html
           │
           ▼
    COORDINATOR GATE (plan.html exists + §3 constants verbatim)
           │pass                          │fail
           ▼                             ▼
    Run 2 (medium builder, via the        bounce Run 1 back with the
    `subagent` tool)                      stale lines

---

## EFFORT ROUTING — how each run is launched (user 2026-08-25)

The `$DSH_HOME` plugin `subagent-reasoning` pins the child's reasoning effort
**by the tool name used to launch it** (not by a per-run flag — the subagent
tools take no effort argument):

    subagent_plan          → xhigh   (planner / Run-1 research)
    subagent               → medium  (builder / Run-2 implementation)
    subagent_implement     → medium  (same as `subagent`, if present)
    anything else / no match → fallback: the patch's `subagentEffort` config
                                (currently `medium`)

Consequently:
- **Run 1 is launched with the `subagent_plan` tool.** Launching a research
  pass with plain `subagent` would downgrade it to medium — do not.
- **Run 2 is launched with the `subagent` tool** (background; completion
  arrives as a notice — the blocking rule still applies).
- The mapping lives in `~/.dsh/cordis.patch.yml` +
  `~/.dsh/plugins/subagent-reasoning.js` and is composed **at DSH host start**:
  a patch/plugin edit takes effect on the NEXT restart. A host restart KILLS
  in-flight subagents — after one, inspect `tasks/AC-NNNN/continuity.md`
  (the builder's continuity log, if present — see the RUN 2 CONTINUITY LOG
  block) + the task folder + `.scratch/AC-NNNN/` for partial progress and
  relaunch with a resume message pointing at the log's last entry (do not
  redo completed steps).

---

## RUN 1 TEMPLATE — xhigh, read-only research → plan.html

Paste as the prompt to the **`subagent_plan` tool** (the plugin pins that tool
to **xhigh**). Read-only research → writes `tasks/AC-NNNN/plan.html`.

```
You are the Run-1 research subagent for AweCraft task AC-NNNN.

READ FIRST, in order, BY PATH (do not paste their contents into your reply):
1. godot/CONTINUITY.md          — state checkpoint, ops rules, task context
2. godot/ARCHITECTURE.md        — architecture + subagent contract (mandatory)
3. tasks/HARNESS.md             — every AWECRAFT_LOGIC mode, RESULT shapes,
                                  envs, smoke-tier protocol, run recipes
4. tasks/AC-NNNN/spec.html      — this task's requirements + verify gates
5. The AC-NNNN entry in tasks/TASKS.yaml (its notes), if the spec references it.

YOUR JOB — RESEARCH ONLY. You must NOT edit any code, scene, .gd, or other
file except the single output below. No godot runs, no builds.

Investigate the repo (grep/read godot/ sources as needed) and WRITE exactly
one file: tasks/AC-NNNN/plan.html — a small self-contained HTML page with
EXACTLY these 7 sections, IN THIS ORDER:

  1. Goal                 — 1 sentence: what AC-NNNN changes and why.
  2. Files to touch       — every godot/ path you expect to edit or read,
                            with a one-line note per file (function/area).
  3. Frozen spec refs     — index.html build 20260816-r12 (source of truth) +
                            the EXACT world constants the task depends on,
                            cited VERBATIM from the current source:
                            SEA, HEIGHT, CHUNK from godot/autoload/data.gd and
                            the biome thresholds from godot/world/generator.gd
                            biome_at() (t/m cutoffs). Quote each value with
                            file:line. Do not paraphrase or round values.
  4. Data.* ids           — the block/item ids the task touches (Data.* in
                            godot/autoload/data.gd, TOOL_GRIDS, B_* ids in
                            godot/world/generator.gd), each with file:line.
  5. Harness gates        — the AWECRAFT_LOGIC mode(s) from
                            godot/scenes/main.gd that verify this task
                            (grep 'AWECRAFT_LOGIC=' / the mode branches in
                            main.gd; the mode table in tasks/HARNESS.md is
                            the reference). For each: mode name, expected
                            RESULT JSON shape (key fields), and the ok:true
                            condition the run must satisfy.
  6. Snapshot/render names — the AWECRAFT_SNAPSHOT output path(s) (under
                            tasks/AC-NNNN/) + AWECRAFT_CAM preset(s) to use,
                            plus the R=1 render command shape from
                            tasks/HARNESS.md §4.
  7. Risks/edge cases     — what could break (e.g. genhash parity if world/*
                            is touched, fluid invariants, xtab/ktab exemption),
                            and the fallback if the plan is wrong.

CONSTANTS RULE (this is the gate the coordinator checks): every frozen-spec
value in §3/§4 must match the CURRENT data.gd / generator.gd byte-for-byte —
copy it straight out of the file. If you are unsure of a value, grep the file
again; never write from memory.

When done, reply in <= 20 lines: the 7 section titles, the file paths you
cite, and any open questions. Your deliverable is tasks/AC-NNNN/plan.html.
```

---

## COORDINATOR GATE — after Run 1, before Run 2

The coordinator (not the subagent) checks, in order:

1. `tasks/AC-NNNN/plan.html` exists. (No file → bounce Run 1 back.)
2. All 7 sections present, in order.
3. Every frozen-spec constant in §3/§4 is cited **verbatim** — the coordinator
   re-greps the cited file:line and compares the value character-for-character
   against current `godot/autoload/data.gd` / `godot/world/generator.gd`.
   Helper: re-run `python3 tasks/scripts/spec_template.py AC-NNNN --full --out
   .scratch/<task>-consts.html` (the --full flag inlines the constants tables,
   parsed fresh) and diff the cited values against that table.

Decision:

- PASS (all constants verbatim, 7 sections) → **queue Run 2** (medium builder).
- FAIL (any constant stale/wrong or section missing) → **bounce Run 1 back**
  with the exact stale lines listed (value cited vs value in file) and ask for
  the file to be re-cited from the current source. Do NOT patch plan.html by
  hand and do NOT queue Run 2 on a failed gate.

---

## RUN 2 TEMPLATE — medium, builder

Paste as the prompt to the **`subagent` tool** (the plugin pins `subagent` to
**medium**). Only send after the gate PASSES.

```
You are the Run-2 builder subagent for AweCraft task AC-NNNN.

READ FIRST, in order, BY PATH:
1. tasks/AC-NNNN/plan.html    — your implementation plan (7 sections; the
                                 gate has verified its constants are current)
2. tasks/AC-NNNN/spec.html    — requirements + deliverables
3. tasks/HARNESS.md           — harness modes, RESULT shapes, run recipes,
                                 AC-0061 SMOKE-tier protocol
4. godot/CONTINUITY.md + godot/ARCHITECTURE.md (ops rules + subagent contract)

IMPLEMENT per plan.html — sections 2 (files) and 4 (Data.* ids) are your
edit map. Stay inside the plan; if you must deviate, record the deviation in
the results page.

CONTINUITY LOG (mandatory — makes an interrupted run resumable): keep an
append-only log at tasks/AC-NNNN/continuity.md. After every discovery or
milestone — a file changed, a key finding or deviation decision, a verify
gate run green/red, a blocker — APPEND one short entry: what happened,
current state, next step. Write it to disk promptly (don't batch at the end).
If the log already exists when you start, this run is a RESUME: read it FIRST
and continue from its last entry — do not redo any step it records as done.

VERIFY (AC-0061 tiered protocol, SMOKE tier — see tasks/HARNESS.md §3):
  G0    one godot headless load: zero SCRIPT ERROR lines (hard gate).
  SMOKE one smoke battery launch with the 2–4 dependency-mapped modes for
        this change area (HARNESS.md dependency table: e.g. world/* →
        player;interact;light;fluids + genhash) + genhash ALWAYS when
        world/* or data.gd is touched (25/25 byte-identical GENHASH lines).
  PROBE the task-specific probe mode(s) from spec.html's Task-specific gates,
        when one is defined (env-gated, headless, ≤ 60 s) — this is yours.
        The HEAVY items in that section (boundary/perf/flake/r50) are NOT
        yours (see below).
  RENDER ≤ 1 render at AWECRAFT_RADIUS=1 into the snapshot path from
        plan.html §6 (xvfb, gl_compatibility); view it; save the PNG under
        tasks/AC-NNNN/.
  HEAVY the heavy gates (boundary r4, perf, flake, r50, full battery where
        SMOKE does not cover it) are the COORDINATOR's background gate job —
        you exit after G0+SMOKE+PROBE+RENDER; do not run them and do not
        wait for them.

ONE-SHOT BOUNDARY (user 2026-08-27, from AC-0079 RUN 2b's ~40 min burn): if
this task's scope touches godot/world/* or lighting.gd, you may run AT MOST
ONE boundary r4 A/B probe yourself as a self-check. If it fails or shows a
walk-p95 trade-off (the AC-0079-D2 33→63 class): do NOT try Option 1 then
Option 2 in the same session — write the HONEST DEVIATION in results +
continuity, name the follow-up you would file (target + approach), and EXIT.
A hard failure (script error, ok:false on a non-trade-off field) is still a
normal bounce.

One godot at a time (concurrent runs corrupt the .godot cache). All runs:
one bash command, HOME set first, from repo root (recipes in HARNESS.md §4).

DELIVER: screenshots into tasks/AC-NNNN/ + a self-contained
tasks/AC-NNNN/AC-NNNN-results.html (G0 output, smoke RESULT JSON, render
PNG, deviations). Report <= 20 lines: files changed, RESULT values, gates
green/red.
```

---

## TRIVIAL-LABEL BYPASS RULE

Before launching Run 1, the coordinator checks the task in `tasks/TASKS.yaml`:

    BYPASS  if labels contain `trivial`
        OR the title matches:  build-scripts | menu Exit | webapp artifacts
        OR (user 2026-08-27) the scope check passes: NO file under godot/world/*
             is touched AND fewer than 2 files total AND no Data.* ids are
             touched (no Data.* block/item id behavior change)

- BYPASS=yes → **skip Run 1 entirely** (no plan.html, no gate). The task gets
  its spec from the AC-0102 template: `python3 tasks/scripts/spec_template.py
  AC-NNNN` (writes `tasks/AC-NNNN/spec.html`; if the spec already exists use
  it), then launch the **Run 2 medium builder directly via the `subagent`
  tool** with that spec.html (same prompt as Run 2 above, minus the plan.html
  reference — point at spec.html + HARNESS.md; verification stays G0 + SMOKE +
  ≤1 R=1 render).
- BYPASS=no → normal two-phase flow (Run 1 → gate → Run 2).

Rationale: trivial tasks are self-evident from the spec; the research pass
buys nothing and costs a full xhigh round on a single-request LLM. The scope
check (2026-08-27) covers single-file UI/tool/build fixes where the Run-1
pass costs ~15 min of xhigh for a 7-section plan.html that says nothing the
spec doesn't.

---

## Notes for the coordinator

- Local LLM serves ONE request at a time: never queue Run 1 and Run 2 (or any
  two subagents) concurrently. Run 2 goes out only after the gate is green.
- plan.html is a RESEARCH artifact: it never triggers a code change by itself
  and is not a "launch".
- Templates keep doc references as paths (CONTINUITY.md, ARCHITECTURE.md,
  HARNESS.md, spec.html, plan.html). Inlining their content bloats every
  prompt and drifts out of date.
- The verbatim-constants gate is checkable mechanically: re-grep the cited
  file:line (or re-run spec_template.py) and diff. A one-value mismatch is a
  full bounce of Run 1, not a negotiation.
- **HEAVY-GATE PIPELINE (user rule 2026-08-26, from AC-0078; sliced 2026-08-27):**
  Run-2 (above) verifies ONLY G0 + SMOKE (+ the task's own probe, when the
  spec defines one) + ≤1 render, then EXITS — the heavy gates run as a
  **coordinator BACKGROUND bash job (or `workflow` worker — no LLM slot either
  way)**: one script, godot invocations SEQUENTIAL (one godot at a time), then
  `./build_windows.sh` (XDG pattern) + 8080/5180 curls, logging everything to
  `.scratch/AC-NNNN-gates/gates.log` and writing a `.scratch/AC-NNNN-gates/
  HEAVY_GATES_DONE` marker at the end. Sliced gate set (2026-08-27): **boundary
  r4 ×1** (was ×2) + **flake ×1** (was ×4) + genhash re-run + the task probe,
  and **ONLY when the scope touches `godot/world/*` | `lighting.gd`**
  (HARNESS.md §3 dependency table) — UI/tool tasks get SMOKE only; **r50 /
  RECSLICE = nightly batch, NOT per task** (was per-task). IMMEDIATELY after
  kicking N's gate job, launch **N+1's Run-1** (`subagent_plan`, xhigh) in
  parallel — research overlaps the gates. The N+1 Run-1 prompt MUST tell the
  child: godot is busy with N's gates — do static file research first, and
  before EVERY godot call check `pgrep -f 'godot'` (and the N
  `HEAVY_GATES_DONE` marker) and wait if a gate job holds a godot process.
  **Commit/push N only after its heavy gates pass** (code + results +
  plan + build in one commit), and **N+1's Run-2 is launched only after N's
  heavy pass + commit** (N+1's Run-1 may overlap the gates; its Run-2 may not
  start on an uncommitted/failed N). If N's gates FAIL: the one-shot rule
  decides — a trade-off-class miss (walk p95 33→63, AC-0079-D2 shape) is an
  HONEST-DEVIATION + follow-up task + deliver as-delivered (do NOT loop
  Option 1 → Option 2 in one medium session — AC-0079 RUN 2b burned ~40 min);
  a hard failure bounces N's Run-2 (fresh rework → re-SMOKE → re-gate). The
  already-running N+1 Run-1 stays valid (research only, no tree changes). The
  background job owns godot until its marker — no other godot (coordinator or
  otherwise) meanwhile.
