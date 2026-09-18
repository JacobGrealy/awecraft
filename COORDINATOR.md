# Coordinator role — the loop

The agent's role: pick work, delegate it, verify it, close it out, chain the next. **This file owns
the role split and the loop only** — each step's procedure lives in one project skill
(`.dsh/skills/`), so nothing is restated here.

## The split

**The builder owns the light gates; the coordinator owns the heavy stage, the build and the
chaining.** Re-running a builder's light gates doubles cost for no extra information; the older
"coordinator re-runs everything" pattern is superseded.

| Phase | Owner | Procedure |
|---|---|---|
| Pick the next task | coordinator | `python3 tasks/scripts/tasks.py next` |
| Plan, implement, light gates | one blocking subagent | `awecraft-delegate` |
| Which gates are light, and exactly how to run them | builder | `awecraft-run-verify` |
| Heavy gates, Windows build, serve curls | coordinator, as a background job | `awecraft-heavy-gates` |
| Docs closeout, harvest, commit + push | coordinator | `awecraft-closeout` |
| Chain the next task | coordinator | this file → `awecraft-delegate` |

## Sizing — split before you delegate

**The coordinator owns the size of what it hands over.** A builder gets ONE turn with a finite budget,
so a ticket that is too big comes back as partial work with its red gates found late — or, worse, as a
"complete" ticket carrying two or three unrelated reds. Splitting is therefore the coordinator's job
*before* the launch, not the builder's problem after it.

**Split when** the work spans more than one subsystem or lane (say a C++ emit plus the GDScript
dispatch), or touches more than a handful of files, or carries an "and also", or forces more than a
couple of arm rebases, or needs temporary instrumentation (a re-profile is its own piece: arm in, run,
arm out). Each piece becomes its own ticket (`AC-NNNN`) with its own scope and gates, worked one at a
time: spec → one blocking subagent → light gates → coordinator heavy stage → commit + push → next piece.
Shape and naming of the pieces: `awecraft-file-ticket`.

**Precedent (learn from it):** AC-0312 asked one builder for three new draw tiers, the slab
materialization, a water-material exception for two of them, five arm rebases and a profgen re-profile
in a single turn. It came back with the tiers working but two unrelated reds (band-A texturing, and the
walk sim-disc at 53 % of its former coverage) plus a run-to-run segfault — none of which a smaller
ticket would have hidden. Split first; a big ticket is not a big builder, it is a big risk.

## Chaining

The moment the heavy stage passes, chain: `tasks.py next` → launch **ONE** blocking subagent for it.
The next builder is static reading for most of its life, so the previous closeout commit may land
first — but never two local-LLM subagents at once: they share one model slot (invariant 7,
`awecraft-delegate`).

## Routing

Every doc path, invariant and skill name is indexed in `AGENTS.md`. This file does not duplicate that
index — it only says what the coordinator does.
