# Subagent delegation — the paste-ready builder prompt

Replace every `AC-NNNN` with the real task id before pasting. Templates reference docs **BY PATH** —
never inline their contents into a prompt.

**Routing, effort pinning and the launch rules are owned by the `awecraft-delegate` skill. The heavy
stage the coordinator runs afterwards is owned by `awecraft-heavy-gates`; the closeout by
`awecraft-closeout`.** This file is only the prompt text.

```
You are the single subagent for AweCraft task AC-NNNN.

READ FIRST, in order, BY PATH (do not paste their contents into your reply):
1. godot/CONTINUITY.md          — the TOP checkpoint only (state + resume steps)
2. godot/ARCHITECTURE.md        — architecture + conventions (mandatory)
3. tasks/AC-NNNN/spec.html      — this task's requirements + verify gates
4. godot/HARNESS.md             — RUN RECIPES §4 and gate semantics §5; the §1 mode
                                  table is a LOOKUP: read only the rows for the modes
                                  your task runs (use `--full` spec.html if you need
                                  them inline). §3 holds the standing values.
5. godot/OPS.md                 — machine, sandbox, build/daemons/git rules
                                  (read before ANY godot or git command)
6. The AC-NNNN entry in tasks/TASKS.yaml (its notes), if the spec references it.
   Scope rules for the directories you touch (godot/AGENTS.md, godot/world/AGENTS.md,
   godot/scenes/AGENTS.md, gdext/AGENTS.md, ...) load automatically when you read or
   edit a file there — read the matching one BEFORE you edit.

YOUR JOB — PLAN + IMPLEMENT in one turn.

0. First action: append "## RUN — $(date) — AC-NNNN" to
   tasks/AC-NNNN/continuity.md (creates the resume point). Do this before any
   edit or godot call.

1. PLAN — write tasks/AC-NNNN/plan.html — a small HTML page with AT LEAST
   these 3 sections, in order:

     1. Goal                 — 1 sentence: what AC-NNNN changes and why.
     2. Files to touch       — every godot/ path you expect to edit or read.
     3. Harness gates        — the AWECRAFT_LOGIC mode(s) that verify this task
                                (the mode table in godot/HARNESS.md is the ref).
                                For each: mode name + the ok:true condition.

Then add any of the following ONLY if the task needs them (do not add boilerplate):

     - Frozen refs          — EXACT world constants with file:line. Only when world/* touched.
     - Data.* ids           — Data.* / B_* ids with file:line. Only when ids change.
     - Snapshot/render names — AWECRAFT_SNAPSHOT path(s) + CAM preset. Only when visual.
     - Risks/edge cases     — what could break + fallback. Only when non-trivial.
     - Fences               — e.g. "no commits/pushes (coordinator handles; read-only git log/show allowed); no TASKS.yaml edits outside queue"

Fences rule: "no git" means no commits/pushes/new branches — coordinator commits. Read-only `git log/show/diff/status` to review previous commits is allowed; do not run `git commit/push/add`.

   Keep it lean — one page is enough for a P3 tweak; depth is for reasoning, not paperwork.

2. IMPLEMENT per your plan — stay inside the plan; if you must deviate, record
   it in the results page.

CONTINUITY LOG (mandatory — makes an interrupted run resumable): keep an
append-only log at tasks/AC-NNNN/continuity.md. After every milestone — a file
changed, a key finding, a gate green/red — APPEND one short entry: what
happened, current state, next step. Write it promptly (don't batch at the end).
If the log already exists when you start, this run is a RESUME: read it FIRST
and continue from its last entry.

VERIFY (single: you own the LIGHT gates, then exit — policy: `awecraft-run-verify`):
  G0    one godot headless load: zero SCRIPT ERROR lines (hard gate — always).
        rc=0 is NOT the gate: the engine exits 0 even when scripts fail to compile.
  SMOKE + PROBE + RENDER as needed (godot/HARNESS.md §1 rows + §3 values are the ref).
        Typical: SMOKE = 2–4 dependency-mapped modes for the change area + genhash
        when world/* or data.gd is touched; PROBE = the task's probe mode from
        spec.html when defined (≤60s, headless).
  RENDER only when the change is visual (mesh/shader/held/UI):
        ≤1 render at AWECRAFT_RADIUS=1 into tasks/AC-NNNN/ (xvfb,
        gl_compatibility — a PROXY renderer: it cannot show Forward+-only
        features such as DOF, so the shipped look is confirmed on the Windows
        build, AC-0241) and save the PNG. Non-visual tasks skip the render.
  HEAVY boundary/perf/flake/r50 and full battery beyond SMOKE are the
        COORDINATOR's background gate job — you exit after your gates; do not
        run or wait for them.

ONE-SHOT BOUNDARY: if this task touches godot/world/* or lighting.gd, you may
run AT MOST ONE boundary r4 A/B probe as a self-check. If it fails or shows a
walk-p95 trade-off (AC-0079-D2 33→63 class): write the HONEST DEVIATION in
results + continuity, name the follow-up, and EXIT (no option loop). A hard
failure is still a bounce.

One godot at a time (corrupts the .godot cache). All runs: one bash command,
HOME set first, from repo root (recipes in godot/HARNESS.md §4). Before every
godot call check `pgrep -af '[g]odot'` and wait if another agent or a
coordinator gate job holds the slot — never kill a godot you did not start.

DELIVER: a self-contained tasks/AC-NNNN/AC-NNNN-results.html for every
task (G0 output + smoke RESULT JSON + deviations; include render PNG only
when visual). Report <= 20 lines: files changed, RESULT values, gates green/red.

ARCHITECTURE SYNC (invariant 2 in AGENTS.md, owned by godot/AGENTS.md): if your change
alters the structure — an autoload, a component that moved/appeared/disappeared,
a new subsystem or native layer, a data or save format, a convention — update
godot/ARCHITECTURE.md in THIS task and say so in the report. A task that leaves
that file wrong is not done.
```

---

## TRIVIAL FAST-PATH — medium, spec-only (no plan.html)

BYPASS when the ticket's labels contain `trivial`, or its title matches `build-scripts`.

- BYPASS=yes → generate `tasks/AC-NNNN/spec.html` if it is missing
  (`python3 tasks/scripts/spec_template.py AC-NNNN`), then launch the trivial builder with the same
  template above minus step 1 (no `plan.html`).
- BYPASS=no → the full plan+implement flow above.
