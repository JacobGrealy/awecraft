# AweCraft — agent guide

Voxel Minecraft-like. Godot **4.7.1**, project root `godot/`, engine `~/tools/godot/godot`
(`--path godot` from the repo root). **Windows-only product** (AC-0124); this Linux box is for
development and headless verification. `README.md` is the human entry point.

## Role

The agent is the **orchestrator/coordinator**: plan, launch subagents, verify, commit + push.
Subagents do all code and research. Procedure lives in the project skills (`.dsh/skills/`), not here.

## Start of session

1. `python3 tasks/scripts/tasks.py next` — what to work on (the queue is the work order).
2. `godot/CONTINUITY.md` — the **top checkpoint only** (current state + resume steps).
3. `godot/ARCHITECTURE.md` — before any code task.

## Invariants — never violate these, whatever else you read

1. **Every change is a ticket** (`AC-NNNN`) and you work off it. `tasks/TASKS.yaml` is mutated
   **only** through `python3 tasks/scripts/tasks.py <cmd>`; hand edits are forbidden. Never reorder
   another session's tickets without asking.
2. **`godot/ARCHITECTURE.md` is updated in the same task as any architectural change** — an autoload,
   a moved or renamed component, a new subsystem or native layer, a data or save format, a changed
   convention. A task that leaves it wrong is not done. Owner: `godot/AGENTS.md`.
3. **Never hand-edit generated or build outputs**: `exports/`, `godot/bin/*`, `gdext/bin/`, `.godot/`,
   `tasks/.tasks.lock`, and the `BEGIN/END GENERATED` blocks in `godot/HARNESS.md` — edit
   `tasks/harness_data.yaml`, then `python3 tasks/scripts/harness_doc.py --render`.
4. **One godot process at a time**, every call prefixed with `HOME=/tmp/dsh_home` in the same bash
   command and using an absolute engine path. Never kill a godot process you did not start. Owner:
   `godot/AGENTS.md`.
5. **Every fact has exactly one home — link, never restate.** The root owns the entry point, the role
   and these invariants; `godot/` owns the game and how to run, verify and build it; `tasks/` owns the
   ticket system and its tooling, with no prose docs there; `docs/` owns design essays; the skills own
   procedure.
6. **Harvest durable rules at closeout** — into `godot/OPS.md` (machine, build, daemon) or the process
   skills. A standing rule never lives only in `tasks/AC-NNNN/continuity.md`, which is a journal.
7. **Never run two local-LLM subagents at once.** `subagent_xhigh`, `subagent_medium` and
   `subagent_low` all draw on the **same single local model slot**, so they cannot run in parallel:
   launch one, wait for it to return, then launch the next. Procedure: `awecraft-delegate`.

## Where to go

Scope rules load automatically when you `read`/`write`/`edit` a file under that directory — a `grep`
or bash sweep does not trigger them, so open the file when you need its rules.

| Need | Go to |
|---|---|
| the game, the C++ lanes, the ticket system, the essays | that directory's `AGENTS.md`: `godot/`, `godot/world/`, `godot/scenes/`, `godot/autoload/`, `gdext/`, `tasks/`, `tasks/scripts/`, `docs/` |
| arms, battery, standing gate values, run recipes | `godot/HARNESS.md` |
| machine, sandbox, daemons, build + serve, git | `godot/OPS.md` |
| a design essay | `docs/INDEX.md` |
| procedure | the skills below |

## Procedure — load the one skill you need

- `awecraft-delegate` — launch a builder: effort routing, the paste-ready prompt
- `awecraft-file-ticket` — filing, the notes format, decomposition, `tasks.py` commands
- `awecraft-run-verify` — which gates and how: G0 semantics, smoke tiers, render limits
- `awecraft-heavy-gates` — the background gate job, godot contention, build + serve checks
- `awecraft-closeout` — docs sync, harvest, commit + push, CONTINUITY checkpoint and compaction
