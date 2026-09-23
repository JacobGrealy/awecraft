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

- **ONE local-LLM subagent at a time.** `subagent_xhigh`, `subagent_medium` and `subagent_low` are
  all configured against the **same local model** (`homeserver1` / `Qwen3.8-27B-UD-Q4_K_XL`), so they
  share a single slot: never put two subagent calls in one step, never start the next before the
  previous returns, and expect nothing from a concurrent launch except contention. (`subagent_fork`
  is not in that set — it is the in-process path on the agent default model.)
- A **DSH host restart kills in-flight children**. After one, inspect `tasks/AC-NNNN/continuity.md`,
  the ticket folder and `.scratch/AC-NNNN/`, then relaunch with a resume pointer at the log's last
  entry.
- The builder makes **no commits, no pushes and no `tasks/TASKS.yaml` edits** (read-only
  `git log/show/diff/status` is fine) — the coordinator owns git and the registry.
- **Do not let a builder open the render/shot PNGs.** A snapshot is 0.6–1.3 MB and reading a few of
  them with vision exhausts a builder's budget with nothing to show: three AC-0347 P3 launches died
  that way (two "failed" mid-sentence right after they started inspecting shots). Put the rule IN the
  prompt — verify shots by filename, byte size and the snapshot run's `RESULT` fields, and **the
  coordinator inspects the images**, which is the job that actually needs eyes.
- **Keep the launch prompt lean.** A prompt well past a screenful failed outright ("subagent run
  failed") and a trimmed rewrite of the same task ran; the depth belongs in the ticket notes and the
  repo files the builder reads anyway. Route: spec + pointers + fences, not a restatement of the
  ticket.
- **Budget the builder's reading too.** Tell it which documents to read *selectively* (HARNESS.md
  sections by number + greps, never whole) — the arm table alone has burned a launch to its limit.
- A ticket touching `godot/world/*` or the lighting path may run **at most ONE** boundary r4 A/B
  probe as a self-check; on a trade-off it records an honest deviation and exits (no option loop).

## 4. After it returns

Check the deliverable set before trusting it: `tasks/AC-NNNN/plan.html`, the self-contained
`tasks/AC-NNNN/AC-NNNN-results.html`, appended `continuity.md` entries, and gate logs under
`.scratch/AC-NNNN-gates/`. Then run the heavy stage — `awecraft-heavy-gates` — and close out with
`awecraft-closeout`.

Gate policy for the builder's VERIFY block: `awecraft-run-verify`. Ticket mechanics:
`awecraft-file-ticket`.
