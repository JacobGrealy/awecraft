---
name: awecraft-closeout
description: Use when closing out an AweCraft ticket after its gates pass - docs sync, rule harvest, TASKS.yaml status, CONTINUITY checkpoint and compaction, commit and push.
---

# Closing out a ticket

**All of this, or the ticket is not closed.** This skill owns the closeout checklist, the harvest
rule and CONTINUITY maintenance; the architecture rule itself is owned by `godot/AGENTS.md` and is
only *verified* here.

## 1. Docs closeout

- **`godot/ARCHITECTURE.md`** — was the change structural (a new or removed autoload, a moved or
  renamed component, a new subsystem or native layer, a changed data or save format, a changed
  convention)? Verify it was updated **in the same task**; a task that leaves that file wrong is not
  done.
- **`godot/HARNESS.md`** §3 — touch it only if standing gate values actually moved (and go through
  `tasks/harness_data.yaml` + `harness_doc.py --render`, never the generated block by hand).
- **`tasks/TASKS.yaml`** — status `done` and removal from the queue, **through
  `python3 tasks/scripts/tasks.py` only**: `set --id AC-NNNN --status done` then
  `queue remove AC-NNNN`.

## 2. Harvest — the rule that keeps this project working

A durable rule discovered inside a task is written into **`godot/OPS.md`** (machine, build, daemon)
or the **process skills** (pipeline, delegation). Never leave a standing rule only inside
`tasks/AC-NNNN/continuity.md`, which is a journal — that hole is exactly why `godot/OPS.md` §7 exists
(a whole INFRA LESSON section was once compacted away and survived only in a dead task folder).

## 3. CONTINUITY checkpoint

- Add a new **monotonic** checkpoint: `## <n>. CHECKPOINT <date> (<rev>)`, `n` strictly increasing,
  **never reused**.
- **Promote before you compact**: every OPEN-for-user item becomes a ticket *before* the next
  compaction can drop it (that is how AC-0299 was created). A standing decision never lives only in a
  checkpoint.
- **Compact by content size, not line count** — checkpoints are single unwrapped lines, so a
  line-based trigger never fires (the file once sat at 9 lines / ~8 KB). Trigger: **more than 2
  checkpoints, or a top checkpoint over ~6 KB.** Keep the newest 2, move the rest to
  `godot/CONTINUITY.archive.md` (newest first).

## 4. Commit and push

- Commit **explicit paths**. This tree carries long-lived untracked directories (`.scratch/`,
  `.tmp_*/`, `references/`, several ticket folders, two design essays) — **never `git add -A`**, and
  never sweep in another session's in-flight files (`godot/OPS.md` §5 has the do-not-commit list).
- Push with the sandbox-safe form: `GIT_SSH_COMMAND="ssh -F /dev/null" git push`.
- Then record the outcome on the ticket (`tasks.py note --id AC-NNNN`) — gates, build stamp, commit
  sha, and the server addresses — and report to the user with **both** localhost and LAN URLs.
