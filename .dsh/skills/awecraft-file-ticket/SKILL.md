---
name: awecraft-file-ticket
description: Use when filing, splitting, queueing or updating an AweCraft ticket (AC-NNNN), or when deciding how a large task should decompose into pieces.
---

# Filing and shaping tickets

`tasks/AGENTS.md` owns the registry rules; this skill owns how a ticket is written and split.

## Write it

```bash
python3 tasks/scripts/tasks.py add --title "<kebab-case-title>" --source user|agent \
    --priority 1|2|3 --notes-file <file>
python3 tasks/scripts/tasks.py set  --id AC-NNNN --status open|in-progress|blocked|done|cancelled
python3 tasks/scripts/tasks.py note --id AC-NNNN --append-file <file>
python3 tasks/scripts/tasks.py queue add AC-NNNN [--at N] | queue remove AC-NNNN | queue list
python3 tasks/scripts/tasks.py show AC-NNNN | next | list
```

`notes` must contain **both** sections, in this order:

1. **`1) User Story`** — plain language: what this changes for the player (or, for tooling, for the
   person doing the work). No file paths here.
2. **`2) Technical Details`** — files/lines/AC refs, the gates that will verify it, and any
   deliberately deferred scope.

Keep the numbers honest and specific: `file:line`, measured values, what proves it. If a claim was
not verified, say so.

## Split it

A large task with clear boundaries is split into **named pieces in order (P1/P2/P3…), worked one at a
time** — each piece delegated to a single blocking subagent, gated, and committed before the next
piece starts. Do **not** force a split on one coherent change.

## Queue discipline

- The queue is the **work order** — `tasks.py next` reads it. Queuing is a decision about what happens
  next, so queue only work that is actually ready.
- **Do not reorder another session's tickets without asking.** A parallel agent may be working the
  front of the queue: check `git status` for its dirty files before you take that slot, and leave
  `tasks/TASKS.yaml` alone if it already carries that session's uncommitted edits.
- Ticket folders, specs and results pages: `tasks/AGENTS.md`. Delegation: `awecraft-delegate`.
