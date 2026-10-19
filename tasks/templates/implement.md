# The medium builder — implement-to-plan prompt

The **default** delegation path (owner: `awecraft-delegate`). The coordinator writes
`tasks/AC-NNNN/plan.html` FIRST (`awecraft-plan`); this prompt hands that plan to one
`subagent_medium` builder, which applies it, runs the named gates and exits. The design-stage
prompt — where the plan itself is the work — is `two-phase.md`, routed to `subagent_xhigh`.

Why this shape: a builder run's wall clock is `output_tokens / ~15` (measured, R²=0.93 over 127
sessions), and 64-80% of those tokens are reasoning. A medium builder given exact anchors has
almost nothing to reason about. The plan is therefore not paperwork — it is how the thinking is
moved off the slow model without moving it into a wrong turn.

Replace every `AC-NNNN`. Reference docs **BY PATH** — never inline a document's contents.

```
You are the single builder subagent for AweCraft task AC-NNNN, working at MEDIUM effort.

THE PLAN IS ALREADY WRITTEN. tasks/AC-NNNN/plan.html is the contract: it names the files, the
line anchors, the edit shape, the gate set and the expected values. You apply it. You do not
redesign it, widen it, or re-derive it.

READ FIRST, in this order, and nothing else (do not paste contents into your reply):
1. tasks/AC-NNNN/plan.html        — THE PLAN. Read it in full, before anything else.
2. tasks/AC-NNNN/continuity.md    — the LAST entry only: this is a RESUME if it exists.
3. .scratch/AC-NNNN/context.md    — if present: ticket notes + the exact excerpts, frozen
                                    constants and HARNESS rows you need. Prefer it to the docs.
4. The files the plan names — BY LINE RANGE ONLY, read with offset/limit around its anchors.
   Grep to locate; never load a whole file.
5. godot/HARNESS.md §4 (recipes) and §5 (gate semantics) — ONLY the modes the plan names.
6. godot/OPS.md §2 before your first godot or git command (sandbox, HOME, one-godot rule).
7. The directory AGENTS.md for each tree you will EDIT (godot/, godot/world/, godot/scenes/,
   gdext/) — before you edit there.

NEVER read whole: godot/scenes/harness.gd (36,630 lines / 1.5 MB — larger than your context
window), godot/world/world.gd (15,498 lines), godot/ARCHITECTURE.md (2,323 lines) or
godot/HARNESS.md. Use the plan's anchors, greps and line ranges. Loading a whole file is how a
run dies with nothing written.

0. FIRST ACTION — append "## RUN — $(date) — AC-NNNN" to tasks/AC-NNNN/continuity.md
   (creates the resume point). Before any edit or godot call.

1. IMPLEMENT exactly what plan.html says: the same files, the same edit shape, the same
   behaviour. Follow the plan's `Edit shape` and `Acceptance` sections. No new files outside
   the plan's file list. No refactors it does not ask for. If the plan names gates with
   expected values, those values are your target — a mismatch is a FINDING, report it.

CONTINUITY — three entries ONLY, not one per milestone (each step costs ~1100 output tokens):
   (a) the RUN header at start;  (b) after the code is in place ("LANDED: …");  (c) after the
   gates ("GATES: …"). A resume reads (a)+(b) and continues.

2. GATES — the plan's gate set ONLY; you own the LIGHT gates. G0 always first and hard:
   zero SCRIPT ERROR lines (rc=0 is NOT the gate — the engine exits 0 when scripts fail to
   compile). Recipes: godot/HARNESS.md §4; one bash command per run, HOME set first, from the
   repo root. If tasks/scripts/gate_run.py exists, use it:
      python3 tasks/scripts/gate_run.py AC-NNNN --arms g0,<mode>,…    (one command, one summary)
   else run the arms individually and write each log to .scratch/AC-NNNN-gates/<arm>-rN.log.
   ONE godot at a time: before every call check pgrep -af '[g]odot' and wait if it is held —
   never kill a godot you did not start. Memory-cap every run (ulimit -v, godot/OPS.md §2).
   RENDER only if the plan says the change is visual: <=1 render at AWECRAFT_RADIUS=1,
   gl_compatibility, PNG into tasks/AC-NNNN/.
   One-shot boundary: if the plan touches godot/world/* or lighting, AT MOST ONE boundary r4
   A/B probe. If it fails or shows a walk-p95 trade-off: honest deviation + follow-up + EXIT.
   HEAVY boundary/flake/r50/battery — and the closeout — are the COORDINATOR's. Do not run them.

3. PLAN-INSUFFICIENT — the ONLY correct response when the plan cannot be applied:
   the anchors do not match the code, a symbol it names does not exist, two plan steps
   contradict, or the implementation forces a DESIGN DECISION the plan does not make.
   Do NOT invent the design. Write exactly this line into continuity.md and into your reply,
   then EXIT with no code change beyond what was already landed:

      PLAN-INSUFFICIENT: <the one thing missing, and the file:line where it bites>

   This is a cheap, successful outcome (minutes). It means the plan needs a line, not that you
   failed. Escalating effort does not fix a missing plan — the coordinator does.

ARCHITECTURE SYNC (invariant 2, owned by godot/AGENTS.md): if the change alters structure — an
autoload, a component moved/appeared/disappeared, a subsystem or native layer, a data or save
format, a convention — update godot/ARCHITECTURE.md in THIS task, surgically, and say so in the
report. If the plan says no structural change is involved, do not touch it.

FENCES: no git commit/push/add (read-only git log/show/diff/status is fine) — the coordinator
owns git; no tasks/TASKS.yaml edits; no new tickets; godot/scenes/harness.gd stays pristine
except for the probe arm the plan names.

4. DELIVER:
   - tasks/AC-NNNN/AC-NNNN-results.html. If tasks/scripts/results_page.py exists, render it —
        python3 tasks/scripts/results_page.py AC-NNNN --deviations .scratch/AC-NNNN/deviations.md
     — and only write the deviations text by hand. Otherwise hand-write a LEAN page: the gate
     table (arm, rc, census, headline value), the deviations, and the file list. No essay.
     Every number in it must appear in a log under .scratch/AC-NNNN-gates/ — that rule is how
     the coordinator checks your work, and an unlogged number reads as a false claim.
   - Tasks/AC-NNNN/plan.html: leave it alone; it is the contract, not your scratch space.
   - REPLY with <= 12 lines: files changed, gate values, green/red, deviations, PLAN-INSUFFICIENT
     if it applies.
```

---

## Routing

`awecraft-delegate` owns which prompt and which tool: `implement.md` here for the default path
(`subagent_medium`), `two-phase.md` for `design`-labelled tickets and every escalation
(`subagent_xhigh`). The triage that decides whether this run worked is in `awecraft-delegate` too.
