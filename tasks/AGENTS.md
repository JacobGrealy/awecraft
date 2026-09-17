# tasks/ — the ticket system (scope rules)

- **`TASKS.yaml` is written only through `python3 tasks/scripts/tasks.py <cmd>`** — hand edits are
  forbidden. The script takes `flock` on `tasks/.tasks.lock`, dumps canonical YAML, replaces the file
  atomically and re-reads it to verify the change landed and nothing else moved. Reading:
  `tasks.py next|show|list|queue`; `next` reads the **queue**, which is the work order.
- Statuses are `open`, `in-progress`, `blocked`, `done`, `cancelled`; priorities are 1–3.
- **Do not reorder another session's tickets without asking.** A parallel agent may be working the
  front of the queue; check `git status` for its dirty files before you take a slot.
- **No prose docs live here.** Design reasoning → `../docs/`; how to run, verify or build → `../godot/`;
  process and procedure → the project skills. A ticket folder is a filing cabinet, not a manual.
- Per-ticket folder `tasks/AC-NNNN/`:
  - `spec.html` — generated, `python3 tasks/scripts/spec_template.py AC-NNNN` (slim by default; `--full`
    inlines the tables). The spec is the requirement, not the plan.
  - `plan.html` — the builder's plan for the task.
  - `AC-NNNN-results.html` — the builder's self-contained evidence page (G0 output, RESULT JSON,
    deviations, PNGs when visual).
  - `continuity.md` — an **append-only journal**: a resume point and a chronology. A durable rule
    discovered in a task is **harvested** at closeout into `../godot/OPS.md` or the process skills —
    never left here.
- Filing a ticket needs both notes sections: **`1) User Story`** (plain language — what this changes
  for the player) and **`2) Technical Details`** (files/lines/AC refs, verify steps).
- **Never `git add -A`.** Several ticket folders, `AC-0092/`, `AC-0125/plan.html`, `AC-0140/` and
  `tasks/.tasks.lock` are intentionally untracked — the do-not-commit list is `../godot/OPS.md` §5.
- Tooling rules for the scripts themselves: `scripts/AGENTS.md`.
