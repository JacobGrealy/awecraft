# AC-0105 — single-phase subagent workflow (reusable coordinator templates)

Process artifact for the DSH-coordinated AweCraft pipeline (local LLM, ONE
subagent at a time, sequential). Replace every `AC-NNNN` with the real task id
before pasting. Templates reference docs BY PATH only — never inline their
content into a prompt.

Workflow (single-phase, user 2026-08-28):

    [trivial-bypass check: labels `trivial` | title match `build-scripts`]
             ──yes──► Single (medium builder, spec.html only — no plan.html)
            │no
            ▼
    Single (xhigh, plan+implement, via the `subagent_plan` tool)
            ──► tasks/AC-NNNN/plan.html + code + tasks/AC-NNNN/continuity.md
            ──► tasks/AC-NNNN/AC-NNNN-results.html + .scratch/AC-NNNN/ gate logs

One DSH spin per task (no Run-1 → gate → Run-2 handoff). The plan is a lean
artifact written in the same turn; xhigh decides how deep it needs to be.

---

## EFFORT ROUTING — how the single is launched (user 2026-08-25, updated 2026-08-28)

The `$DSH_HOME` plugin `subagent-reasoning` pins the child's reasoning effort
**by the tool name used to launch it**:

    subagent_plan          → xhigh   (single — plan+implement)
    subagent               → medium  (trivial fast-path only)
    subagent_implement     → medium  (same as `subagent`, if present)
    anything else / no match → fallback: `subagentEffort` (currently `medium`)

- **Non-trivial tasks → `subagent_plan` (xhigh, single).** The plan and the
  code land in one turn; no second launch.
- **Trivial tasks → `subagent` (medium, single)** with `spec.html` only.

The mapping lives in `~/.dsh/cordis.patch.yml` +
`~/.dsh/plugins/subagent-reasoning.js` (composed at DSH host start; a host
restart KILLS in-flight subagents — after one, inspect
`tasks/AC-NNNN/continuity.md` + task folder + `.scratch/AC-NNNN/` and relaunch
with a resume pointing at the log's last entry).

---

## SINGLE TEMPLATE — xhigh, plan+implement → plan.html + code

Paste as the prompt to the **`subagent_plan` tool** (the plugin pins that tool
to **xhigh**). Writes `tasks/AC-NNNN/plan.html` then implements it in the same
turn.

```
You are the single subagent (xhigh) for AweCraft task AC-NNNN.

READ FIRST, in order, BY PATH (do not paste their contents into your reply):
1. godot/CONTINUITY.md          — state checkpoint, ops rules, task context
2. godot/ARCHITECTURE.md        — architecture + subagent contract (mandatory)
3. tasks/HARNESS.md             — every AWECRAFT_LOGIC mode, RESULT shapes,
                                   envs, smoke-tier protocol, run recipes
4. tasks/AC-NNNN/spec.html      — this task's requirements + verify gates
5. The AC-NNNN entry in tasks/TASKS.yaml (its notes), if the spec references it.

YOUR JOB — PLAN + IMPLEMENT in one turn.

0. First action: append "## RUN — $(date) — AC-NNNN" to
   tasks/AC-NNNN/continuity.md (creates the resume point). Do this before any
   edit or godot call.

1. PLAN — write tasks/AC-NNNN/plan.html — a small HTML page with AT LEAST
   these 3 sections, in order:

     1. Goal                 — 1 sentence: what AC-NNNN changes and why.
     2. Files to touch       — every godot/ path you expect to edit or read.
     3. Harness gates        — the AWECRAFT_LOGIC mode(s) that verify this task
                                (the mode table in tasks/HARNESS.md is the ref).
                                For each: mode name + the ok:true condition.

   Then add any of the following ONLY if the task needs them (let your
   xhigh reasoning decide — do not add boilerplate):

     - Frozen refs          — EXACT world constants with file:line. Only when world/* touched.
     - Data.* ids           — Data.* / B_* ids with file:line. Only when ids change.
     - Snapshot/render names — AWECRAFT_SNAPSHOT path(s) + CAM preset. Only when visual.
     - Risks/edge cases     — what could break + fallback. Only when non-trivial.

   Keep it lean — one page is enough for a P3 tweak; depth is for reasoning, not paperwork.

2. IMPLEMENT per your plan — stay inside the plan; if you must deviate, record
   it in the results page.

CONTINUITY LOG (mandatory — makes an interrupted run resumable): keep an
append-only log at tasks/AC-NNNN/continuity.md. After every milestone — a file
changed, a key finding, a gate green/red — APPEND one short entry: what
happened, current state, next step. Write it promptly (don't batch at the end).
If the log already exists when you start, this run is a RESUME: read it FIRST
and continue from its last entry.

VERIFY (single: you own the gates, then exit):
  G0    one godot headless load: zero SCRIPT ERROR lines (hard gate — always).
  SMOKE + PROBE + RENDER as needed (let your plan guide you; HARNESS.md §3
        is the ref). Typical: SMOKE = 2–4 dependency-mapped modes for the
        change area + genhash when world/* or data.gd is touched; PROBE = the
        task's probe mode from spec.html when defined (≤60s, headless).
  RENDER only when the change is visual (mesh/shader/held/UI):
        ≤1 render at AWECRAFT_RADIUS=1 into tasks/AC-NNNN/ (xvfb,
        gl_compatibility) and save the PNG. Non-visual tasks skip the render.
  HEAVY boundary/perf/flake/r50 and full battery beyond SMOKE are the
        COORDINATOR's background gate job — you exit after your gates; do not
        run or wait for them.

ONE-SHOT BOUNDARY: if this task touches godot/world/* or lighting.gd, you may
run AT MOST ONE boundary r4 A/B probe as a self-check. If it fails or shows a
walk-p95 trade-off (AC-0079-D2 33→63 class): write the HONEST DEVIATION in
results + continuity, name the follow-up, and EXIT (no option loop). A hard
failure is still a bounce.

One godot at a time (corrupts the .godot cache). All runs: one bash command,
HOME set first, from repo root (recipes in HARNESS.md §4).

DELIVER: a self-contained tasks/AC-NNNN/AC-NNNN-results.html for every
task (G0 output + smoke RESULT JSON + deviations; include render PNG only
when visual). Report <= 20 lines: files changed, RESULT values, gates green/red.
```

---

## TRIVIAL FAST-PATH — medium, spec-only (no plan.html)

Before launching, the coordinator checks `tasks/TASKS.yaml`:

    BYPASS  if labels contain `trivial`
        OR the title matches: `build-scripts` (covers AC-0100)

- BYPASS=yes → skip the xhigh single. Generate `tasks/AC-NNNN/spec.html` via
  `python3 tasks/scripts/spec_template.py AC-NNNN` (if not already present),
  then launch the **`subagent` tool (medium)** with a prompt that points at
  `spec.html` + `HARNESS.md` only (same VERIFY/DELIVER as above, but no plan.html).
- BYPASS=no → the single xhigh flow above (plan+implement in one turn).

---

## Notes for the coordinator

- Local LLM serves ONE request at a time: never launch two subagents concurrently.
  The heavy-gate background job is NOT a subagent (no LLM slot) — it may overlap
  the next task's single (which is static research for most of its life), but
  the gate's godot step must not overlap the single's godot step: before EVERY
  godot call the single checks `ps -eo pid,comm,args | grep -E '^\s*[0-9]+ (godot|Xvfb)'`
  and the `HEAVY_GATES_DONE` marker and waits if a gate job holds godot.
- **HEAVY-GATE PIPELINE (user 2026-08-26, sliced 2026-08-27):** the single's VERIFY
  above is G0+SMOKE+PROBE+(≤1 render) only; the heavy gates run as a
  **coordinator BACKGROUND bash job**: one script, godot SEQUENTIAL, then
  `./build_windows.sh` + 8080/5180 curls, logging to `.scratch/AC-NNNN-gates/gates.log`
  + `HEAVY_GATES_DONE` marker. Sliced set: **boundary r4 ×1** + **flake ×1** +
  genhash re-run + task probe, and **ONLY when scope touches `godot/world/*`|`lighting.gd`**
  (HARNESS.md §3) — UI/tool tasks get SMOKE only; **r50 = nightly**. Commit/push N
  only after heavy pass (code+results+plan+build in one commit); heavy fail =
  honest-deviation+follow-up or bounce.
- Templates keep doc references as paths (CONTINUITY.md, ARCHITECTURE.md,
  HARNESS.md, spec.html, plan.html). Inlining their content bloats prompts and
  drifts out of date. Report `plan.html` by path only — do NOT inline plan gates
  verbatim.
