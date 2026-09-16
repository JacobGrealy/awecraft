# Coordinator role — standing process

## Principle

**Builder owns the light gates; the coordinator owns the heavy stage, the build and
chaining.** This supersedes the older "coordinator re-runs everything" pattern — re-running a
builder's light gates doubles cost for no extra information (single-session cache thrash).

## What the builder (subagent) does — light stage

- Reads, by path: `godot/CONTINUITY.md` (top checkpoint only), `godot/ARCHITECTURE.md`,
  `godot/HARNESS.md`, `godot/OPS.md`, then its own `tasks/AC-NNNN/spec.html`.
- Runs only the fast/headless gates its spec needs — **G0 + SMOKE + PROBE + at most one
  render** — logging to `.scratch/AC-NNNN-gates/`, writing `tasks/AC-NNNN/AC-NNNN-results.html`
  plus any screenshots.
- **G0 means zero `SCRIPT ERROR` lines, not `rc=0`.** The engine exits 0 even when scripts fail
  to compile (verified 2026-09-16: a broken `harness.gd` parse exits 0), so the error count is
  the gate.
- **Syncs `godot/ARCHITECTURE.md`** if the change was architectural — standing rule 1 in
  `AGENTS.md`. A task that leaves that file wrong is not done.
- Then exits. It does not run the heavy gates and does not wait for them.

## What the coordinator does — heavy stage only

1. Finish/verify any in-flight render the builder left running.
2. **Heavy gates** (exactly the ones the builder must not run):
   - `boundary` r4 walk/p95 — standing values in `godot/HARNESS.md` §3
   - `genhash` parity 25/25 whenever `godot/world/*` or `data.gd` was touched
   - the full `battery` when the spec calls for it; otherwise trust the builder's SMOKE
   - `r50` perf/flake arms only when scheduled (nightly class — 15–45 min wall)
   - `./build_windows.sh`, then gate curls: **`:8080` byte-match + `:5180` = 200**.
     `:8443` is dead (the web product is gone) — never gate on it. See `godot/OPS.md` §3.
3. **Docs closeout** — all of it, or the task is not closed:
   - `godot/ARCHITECTURE.md` updated if anything structural changed (standing rule 1)
   - `godot/HARNESS.md` §3 only if standing gate values moved
   - `tasks/TASKS.yaml`: status `done` + queue removal — **via `tasks.py` only**
   - `godot/CONTINUITY.md`: a new **monotonic** checkpoint; compact when there are more than
     2 checkpoints or the top one exceeds ~6 KB; every OPEN-for-user item promoted to a ticket
     *before* compaction can drop it
   - **harvest**: any durable rule discovered in the task is written into `godot/OPS.md`
     (machine/build/daemon) or the process docs (pipeline/delegation) — never left only in
     `tasks/AC-NNNN/continuity.md`
   - commit **explicit paths**, then `GIT_SSH_COMMAND="ssh -F /dev/null" git push`
     (the tree carries long-lived untracked dirs — never `git add -A`)

## Chaining

Immediately after the heavy stage passes, chain the next task:
`python3 tasks/scripts/tasks.py next` → launch **ONE** blocking subagent for it.

## Godot contention

One godot process at a time. Before every godot call, check `pgrep -af '[g]odot'` and wait if
another holder exists — a coordinator gate job (watch its `HEAVY_GATES_DONE` marker) or another
agent's run. **Never kill a godot process you did not start**; a parallel agent may hold the
slot.

## Routing

Every doc path, standing rule and maintenance trigger lives in `AGENTS.md`. This file does not
duplicate that index — it only says what the coordinator does.
