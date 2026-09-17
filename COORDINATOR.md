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

## Chaining

The moment the heavy stage passes, chain: `tasks.py next` → launch **ONE** blocking subagent for it.
The next builder is static reading for most of its life, so the previous closeout commit may land
first — but **never** let two subagents run at once (the local model serves one request at a time).

## Routing

Every doc path, invariant and skill name is indexed in `AGENTS.md`. This file does not duplicate that
index — it only says what the coordinator does.
