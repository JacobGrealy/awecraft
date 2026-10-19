---
name: awecraft-plan
description: Use before launching any AweCraft builder — the coordinator's planning pass that writes tasks/AC-NNNN/plan.html, decides the design, and hands a medium builder a contract to apply. Also use when repairing a plan after a failed run (PLAN-INSUFFICIENT or a triage hit).
---

# The planning pass (coordinator)

The coordinator plans; the builder applies. This skill owns the plan: how to orient, what to
decide, and what `tasks/AC-NNNN/plan.html` must contain. Launching and routing: `awecraft-delegate`.
The plan's structure: `tasks/templates/plan.html`. The builder's prompt: `tasks/templates/implement.md`.

## Why this exists

A builder run's wall clock is its own output-token count divided by ~15, and 64–80% of that output is
reasoning — the measurement, the current values and the re-measure recipe are `godot/OPS.md` §1
("the builder model's throughput IS the schedule"). Effort is the cost driver, so effort must be spent
where it buys something: orientation and design judgement are exactly the work a small model does
badly and a large-context model does cheaply, while applying a resolved plan is exactly the work a
small model does fine. The plan is where that trade is made.

Consequence: **a ticket with no plan is a ticket that will burn hours.** The 6.3-hour run on
AC-0433 was a builder orienting in `ARCHITECTURE.md` and designing in flight.

## The pass, in order

1. **Read the ticket, not the world.** `python3 tasks/scripts/tasks.py show AC-NNNN`, the last
   entry of `tasks/AC-NNNN/continuity.md`, `git log --oneline -8`, and the top checkpoint of
   `godot/CONTINUITY.md`. Do not start with `ARCHITECTURE.md` whole — 2,323 lines of prefill to
   answer a question you have not asked yet.
2. **Find the sites.** `grep` for the symbol or the string, then `read` a line range around each
   hit. You are looking for one thing per file: the anchor. If a site takes more than two greps,
   the ticket is under-specified — that is itself the finding.
3. **Decide.** Every fork the builder could hit gets resolved here and written down with its
   reason: which of two mechanisms, which fallback, which is out of scope. The design is the
   coordinator's job now — that is the whole point of the split.
4. **Write `tasks/AC-NNNN/plan.html`** from `tasks/templates/plan.html`. Non-negotiables:
   - every file in §2 carries an **anchor** (`file:line` or a grep string);
   - every gate in §4 carries an **expected value**, so a mismatch is a finding not a judgement;
   - §3 states the **edit shape** (old behaviour → new behaviour + the invariant that must not
     move), never the full final source;
   - §7 carries the fences verbatim, including the `PLAN-INSUFFICIENT` clause.
5. **Check the plan against the split rule.** If it does not fit in ~250 lines, or it needs two
   gate sets, or §3 has more than a handful of edits — **split the ticket** (`awecraft-file-ticket`)
   instead of writing a longer plan. A plan that takes an hour to write is a symptom.
6. **Hand off.** `tasks.py set --id AC-NNNN --status in-progress`; make sure the spec exists
   (`python3 tasks/scripts/spec_template.py AC-NNNN`); if `tasks/scripts/context_pack.py` exists,
   generate `.scratch/AC-NNNN/context.md` so the builder reads one file instead of seven; then
   launch `subagent_medium` with the `implement.md` prompt.

## Timebox

**≤10 minutes of coordinator work and ≤250 lines of plan.** Over that, stop writing and split.
The coordinator's own reading is cheap (fast model, large window) but not free — if the pass is
drifting past the box, the ticket is too big and splitting is the answer, not more planning.

## Plans for the two non-default paths

- **`design`-labelled tickets** (`awecraft-delegate` routes them to `subagent_xhigh` with
  `two-phase.md`): the plan's §3 becomes the *question*, not the edit — "measure X three ways and
  refute one of these two candidate mechanisms", with the expected observation per branch. The
  builder is allowed to think here; that is what xhigh is for. Even so, §2 anchors and §4 expected
  values are mandatory — a design run without anchors is how a 6-hour run happens.
- **`trivial` tickets** (`implement.md` minus the plan, `subagent_medium`): no planning pass. If
  you find yourself writing a plan for one, it was not trivial — label it properly and plan it.

## Repairing a plan (the escalation loop)

`awecraft-delegate` owns the triage signals. When one fires, the FIRST fix is almost always here,
not in the model's effort — `H1` no diff, `H3` an unbacked number, `H5` scope escape and `H6`
`PLAN-INSUFFICIENT` are plan defects:

- `PLAN-INSUFFICIENT` names exactly one missing thing. Add it to §2/§3 with its anchor, then
  relaunch `subagent_medium` with the SAME plan plus the fix. Do not escalate effort yet.
- `H1`/`H5` usually mean §2's file list was wrong or §3 was ambiguous about where the edit goes.
  Tighten both, relaunch medium.
- Only after a **second** hit on the same ticket does the ladder go to `subagent_xhigh` — now the
  implication is that the work needs design judgement inside the implementation, which no plan
  can supply. Third hit: split.

Record the escalation in `continuity.md` — one line: `ESCALATED xhigh: <signal> — <plan fix>`.
That log is the only evidence of whether the medium default is holding, so it is not optional.
