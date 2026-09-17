---
name: awecraft-delegate
description: Use when launching, relaunching or routing a builder subagent for an AweCraft ticket, when choosing which subagent tool and reasoning effort to use, or when a builder run was interrupted and must be resumed.
---

# Delegating an AweCraft ticket

The agent is the orchestrator; **subagents do all code and research**. The builder's verbatim prompt
is the SINGLE TEMPLATE in `tasks/templates/two-phase.md` — paste it, replace `AC-NNNN`, and never
inline a document's contents into it (paths only; inlining bloats the prompt and drifts).

## 1. Prepare

1. Pick the ticket: `python3 tasks/scripts/tasks.py next` (the queue is the work order).
2. Mark it: `python3 tasks/scripts/tasks.py set --id AC-NNNN --status in-progress`.
3. Ensure the spec exists: `python3 tasks/scripts/spec_template.py AC-NNNN` (slim by default — path
   pointers; `--full` only when the tables genuinely must be inline).

## 2. Route by effort — current tool names

The `subagent-reasoning` plugin (`~/.dsh/plugins/subagent-reasoning.js`) pins the child's reasoning
effort **by the tool name used to launch it**:

| Launch tool | Effort | Use for |
|---|---|---|
| `subagent_xhigh` | xhigh | **non-trivial tickets** — plan + implement in one turn |
| `subagent_medium` | medium | the **trivial bypass** only |
| `subagent_low` | low | never for implementation |
| `subagent_fork` | (unpinned → `subagentEffort`, currently medium) | inherits this conversation: reviews, continuations, follow-up analysis — not primary implementation |

Anything else falls back to the configured `subagentEffort`. Do not name the retired aliases
`subagent_plan` / `subagent`.

**Trivial bypass** (medium, spec-only, no plan): the ticket's labels contain `trivial`, or its title
matches `build-scripts`.

## 3. Launch rules

- **ONE subagent at a time** — the local model serves a single request, and DSH host restart kills
  in-flight children. After one, inspect `tasks/AC-NNNN/continuity.md`, the ticket folder and
  `.scratch/AC-NNNN/`, then relaunch with a resume pointer at the log's last entry.
- The builder makes **no commits, no pushes and no `tasks/TASKS.yaml` edits** (read-only
  `git log/show/diff/status` is fine) — the coordinator owns git and the registry.
- A ticket touching `godot/world/*` or the lighting path may run **at most ONE** boundary r4 A/B
  probe as a self-check; on a trade-off it records an honest deviation and exits (no option loop).

## 4. After it returns

Check the deliverable set before trusting it: `tasks/AC-NNNN/plan.html`, the self-contained
`tasks/AC-NNNN/AC-NNNN-results.html`, appended `continuity.md` entries, and gate logs under
`.scratch/AC-NNNN-gates/`. Then run the heavy stage — `awecraft-heavy-gates` — and close out with
`awecraft-closeout`.

Gate policy for the builder's VERIFY block: `awecraft-run-verify`. Ticket mechanics:
`awecraft-file-ticket`.
