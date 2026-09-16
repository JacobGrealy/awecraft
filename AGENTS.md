# AweCraft — agent guide

Voxel Minecraft-like. Godot **4.7.1**, project root `godot/`, engine `~/tools/godot/godot`
(`--path godot` from the repo root). **Windows-only product** (AC-0124); this Linux box is
for development and headless verification. `README.md` is the human entry point.

## Read first

1. `godot/CONTINUITY.md` — the **top checkpoint only** (current state + resume steps).
   Older checkpoints only when debugging.
2. `godot/ARCHITECTURE.md` — structure, autoloads, conventions. Read before any code task.

## Then, by need

| Need | Go to |
|---|---|
| run/verify anything: arms, battery, standing gate values, recipes | `godot/HARNESS.md` |
| machine, sandbox, daemons, build + serve, push | `godot/OPS.md` |
| what to work on, queue, any ticket | `python3 tasks/scripts/tasks.py next\|show\|list\|queue` |
| role process, gates, chaining, closeout | `COORDINATOR.md` |
| the delegation contract (subagent prompt) | `tasks/templates/two-phase.md` |
| a design essay | `docs/INDEX.md` |

## Role

The agent is the **orchestrator/coordinator**: plan, launch subagents, verify, commit+push.
Subagents do all code and research. Standing process → `COORDINATOR.md`.

## Standing rules

1. **`godot/ARCHITECTURE.md` is updated in the same task as any architectural change.** A new
   or removed autoload, a moved or renamed component, a new subsystem or native layer, a
   changed data or save format, a changed convention — update that file before the task is
   done. A task that leaves it wrong is not done. `COORDINATOR.md` enforces this at closeout.
2. **Mutate `tasks/TASKS.yaml` only via `python3 tasks/scripts/tasks.py <cmd>`.** Hand edits
   are forbidden — it is the single-writer API file.
3. **Never hand-edit generated or build outputs**: `exports/`, `godot/bin/*`, `gdext/bin/`,
   `.godot/`, `tasks/.tasks.lock`.
4. **One godot process at a time**, every call prefixed with `HOME=/tmp/dsh_home` and an
   absolute engine path — see `godot/OPS.md` §2 for why (a wrong HOME segfaults the engine).
5. **Every fact has exactly one home.** Placement test: the entry point and role process live
   at the repo root; the game and everything about running, verifying and building it live in
   `godot/`; the ticket system and its tooling live in `tasks/` (no prose docs there); design
   essays live in `docs/`. Never restate another doc's content — link to it.
6. **Harvest rules at closeout.** A durable rule discovered inside a task is written into
   `godot/OPS.md` (machine/build/daemon) or the process docs (pipeline/delegation) — never
   left only in `tasks/AC-NNNN/continuity.md`, which is a journal.

## Task format

When filing a task, `notes` must contain two sections: **`1) User Story`** (plain language:
what this changes for the player) and **`2) Technical Details`** (files/lines/AC refs, verify
steps).

## Task decomposition

A large task with clear boundaries is split into named pieces in order (P1/P2/P3…), worked
one at a time — each piece delegated to a single blocking subagent, gated, and committed
before the next piece starts. Do not force a split on one coherent change.

## Task status

`python3 tasks/scripts/tasks.py next` — `tasks/TASKS.yaml` is the single source of work
state. Report running servers with both `localhost` and LAN addresses
(`http://192.168.0.224:8080/AweCraft.exe`, board `http://192.168.0.224:5180/`).

## Maintenance

- **Compact `godot/CONTINUITY.md` by content size, not line count.** Its checkpoints are
  single unwrapped lines, so a line-based trigger never fires (the file sat at 9 lines /
  ~8 KB). Trigger: **more than 2 checkpoints, or a top checkpoint over ~6 KB.** Keep the
  newest 2, move the rest to `godot/CONTINUITY.archive.md` (newest first).
- **Checkpoint ids are monotonic**: `## <n>. CHECKPOINT <date> (<rev>)`, `n` strictly
  increasing, never reused (the two duplicate `00Z` labels were renumbered 10/11 at AC-0298).
- **Promote before you compact**: an OPEN-for-user item must become a ticket *before* the next
  compaction can drop it (that is how AC-0299 was created). A standing decision must never
  live only in a checkpoint.
