# Coordinator role — standing process

## Principle
`Understood — new standing process: trust the builder's light gates (they're part of the builder contract), coordinator runs only the heavy stage + build, and chains the next task immediately. Finishing the in-flight render, then heavy stage + next subagent:`

Builder owns light gates; coordinator owns heavy stage + build + chaining. This supersedes older "coordinator re-runs everything" patterns.

## What builder does (light stage)
- Runs all `AWECRAFT_LOGIC` harness arms that are fast/headless (`player`, `interact`, `light`, `fluids`, `chunkio`, `bandmap`, `save`, etc.), render snapshots where required, and any spec-probe arms declared in the task.
- Must pass `G0 0 errors` and task-specific `ok:true` gates before reporting `DONE`.
- Leaves logs under `.scratch/<task>-gates/` and `tasks/<id>/results.html` + screenshots.

Coordinator **trusts** these light gates — do not re-run them (INFRA LESSON v3: parent + subagent thrash the single-session KV cache; re-running light gates doubles cost for no value).

## What coordinator does (heavy stage only)
1. Finish any in-flight `render` that the builder left running (xvfb → PNG), verify it.
2. Run **only** the heavy gates:
   - `boundary` walk (`r4` `p95` / `fwd` — HARNESS §3 standing values, e.g. `walk p95≈73/89` after AC-0155)
   - `genhash` parity (`25/25` byte-identical)
   - Full `battery` if heavy stage requires it (otherwise trust builder's battery)
   - `./build_windows.sh` (symlinks first per BUILD RECIPE: `ln -sfn /home/angrygiant/tools /tmp/dsh_home/tools && ln -sfn /home/angrygiant/.local /tmp/dsh_home/.local`), then `8080` byte-match curl + `5180=200` + `8443` note
3. Docs closeout: `HARNESS.md` §3 only if standing values moved, `TASKS.yaml` `done` + queue removal, `CONTINUITY.md` `00p` checkpoint, commit `EXPLICIT PATHS` + `GIT_SSH_COMMAND="ssh -F /dev/null" git push`.

## Chaining
- Immediately after heavy stage passes, chain the next task: `python3 tasks/scripts/tasks.py next` → launch **ONE blocking xhigh subagent** (INFRA LESSON v3: parent idle while child runs, `HOME=/tmp/dsh_home` on every godot call, logs → `.scratch/<next>-gates/`).
- Do not wait for light gates to be re-verified — builder will verify its own light gates.
- Report both `localhost` + LAN `http://192.168.0.224:8080/...` + `http://192.168.0.224:5180` after push.

## References
- Delegation & env: `godot/CONTINUITY.md` §00p INFRA LESSON v3 + BUILD RECIPE
- Architecture & verify: `godot/ARCHITECTURE.md` §7
- Queue: `python3 tasks/scripts/tasks.py next` — `godot/CONTINUITY.md` §6 authoritative
- Task contract: `tasks/templates/two-phase.md` + `tasks/TASKS.yaml`
