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

## Never queue an ID you have not seen returned

`tasks.py add` returns the REAL id (`Added AC-NNNN: <title>`) and it is allocated against a registry a
**parallel session shares** — so an ID you *expect* is very likely somebody else's existing ticket, and
`queue add <id> --at ...` **moves** whatever that ID happens to be. This bit the coordinator FOUR times
in one session (AC-0342, AC-0352, AC-0360, AC-0362), each time displacing another session's ticket.

So: **file first, read the id from the command's own output, then queue that id** — and never pipe the
`add` output away, because then you have to guess. To repair a displacement, the committed registry is
the authority: `git show HEAD:tasks/TASKS.yaml` lists the queue order as last agreed, so restore the
victim with `queue add <id> --at "after <the ticket it followed>"` and then verify with a check that the
committed base order is a subsequence of the new one:

```
git show HEAD:tasks/TASKS.yaml | python3 -c "..."   # extract the committed queue
# then assert: [x for x in committed if x in current] == [x for x in current if x in committed]
```

Also: `--priority` accepts only **1, 2 or 3** (a 4 is rejected, which is a safe failure only if you do
not also pipe stderr away).
