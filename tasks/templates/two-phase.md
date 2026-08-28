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
AT LEAST these 3 sections, IN THIS ORDER:

  1. Goal                 — 1 sentence: what AC-NNNN changes and why.
  2. Files to touch       — every godot/ path you expect to edit or read,
                             with a one-line note per file (function/area).
  3. Harness gates        — the AWECRAFT_LOGIC mode(s) from
                             godot/scenes/main.gd that verify this task
                             (the mode table in tasks/HARNESS.md is the ref).
                             For each: mode name + the ok:true condition.

Then add any of the following ONLY if the task needs them (let your
xhigh reasoning decide — do not add boilerplate):

  - Frozen spec refs     — index.html build 20260816-r12 + the EXACT world
                           constants (SEA/HEIGHT/CHUNK, biome_at thresholds)
                           cited verbatim with file:line. Required only when
                           world/* or generator is touched.
  - Data.* ids           — Data.* / B_* ids with file:line. Only when ids change.
  - Snapshot/render names — AWECRAFT_SNAPSHOT path(s) + CAM preset. Only when
                           a render is part of the gate.
  - Risks/edge cases     — what could break + fallback. Only when non-trivial.

Keep the plan lean — one page is enough for a P3 tweak; xhigh depth is for
reasoning, not paperwork.

When done, reply in <= 20 lines: the section titles you wrote, the file paths
you cite, and any open questions. Your deliverable is tasks/AC-NNNN/plan.html.
```

---

## COORDINATOR GATE — after Run 1, before Run 2

The coordinator (not the subagent) checks:

1. `tasks/AC-NNNN/plan.html` exists. (No file → bounce Run 1 back.)
2. Sections 1-3 present, in order, with at least one harness gate citing
   `tasks/HARNESS.md`. Optional sections (Frozen refs / Data.* ids / renders /
   risks) are allowed but not required — gate them only if present.

Decision:

- PASS → **queue Run 2** (medium builder).
- FAIL (missing plan or missing §1-3) → **bounce Run 1 back** with what is
  missing. Do NOT patch plan.html by hand and do NOT queue Run 2 on a failed gate.

Note: the old verbatim-constants gate (re-grep data.gd / generator.gd) now
runs only when the plan includes a Frozen spec refs section — trivial / UI
tasks skip it.

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

VERIFY (AC-0061 tiered, see tasks/HARNESS.md §3):
  G0    one godot headless load: zero SCRIPT ERROR lines (hard gate — always).
  SMOKE + PROBE + RENDER as needed (let xhigh plan guide you; HARNESS.md §3
        is the ref). Typical: SMOKE = 2–4 dependency-mapped modes for the
        change area + genhash when world/* or data.gd is touched; PROBE = the
        task's probe mode from spec.html when defined (≤60s, headless).
  RENDER only when the change is visual (new block/mesh/shader/held/UI):
        ≤1 render at AWECRAFT_RADIUS=1 into tasks/AC-NNNN/ (xvfb,
        gl_compatibility) and save the PNG. Non-visual tasks (data-only,
        harness, webui, build scripts) skip the render.
  HEAVY boundary/perf/flake/r50 and full battery beyond SMOKE are the
        COORDINATOR's background gate job — you exit after your gates; do not
        run or wait for them.

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

DELIVER: a self-contained tasks/AC-NNNN/AC-NNNN-results.html for every
task (G0 output + smoke RESULT JSON + deviations; include render PNG only
when the change is visual). Report <= 20 lines: files changed, RESULT values,
gates green/red.
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
