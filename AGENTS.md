# AweCraft — Agent Guide (read first, every session)

Repo = a voxel Minecraft-like game in two parts:
1. **Web game = SPEC (frozen)**: `index.html` (build `20260816-r12`, Three.js single-file). Source of truth for ALL behavior/data. Do NOT modify.
2. **Godot port = live work**: `godot/` (GDScript, Godot 4.7.1, engine `~/tools/godot/godot`, always `--path godot`).

## After any restart/compaction, read in this order
1. `godot/CONTINUITY.md` — state checkpoint: commands, ops rules, structure, task list.
2. `godot/ARCHITECTURE.md` — architecture + subagent contract (mandatory before ANY code task).
3. `REMAINING_FEATURES.html` — web-feature backlog (maps to Godot M7-M13).
Then continue the task list in CONTINUITY.md §6. Do not re-derive state; the checkpoint files are authoritative.

## Commands (from repo root, all PROVEN)
- Headless logic check (MUST end with zero script errors): `~/tools/godot/godot --headless --path godot --quit`
- Logic tests (print `RESULT {...}` JSON then quit): `AWECRAFT_LOGIC=player|interact|light|fluids|buckets ~/tools/godot/godot --headless --path godot`
- Render (software GL under virtual X, llvmpipe): `xvfb-run -a ~/tools/godot/godot --path godot --rendering-method gl_compatibility` (+ env hooks: `AWECRAFT_SNAPSHOT=path.png`, `AWECRAFT_CAM=top|iso`, `AWECRAFT_SEED`, `AWECRAFT_TIME`, `AWECRAFT_RADIUS`, `AWECRAFT_FLUID_SHOT=1`)
- Web build (run AFTER EVERY feature/fix): `./build_web.sh` → `web/`
- Windows build (run AFTER EVERY feature/fix, since AC-0074 2026-08-22): `./build_windows.sh` → `exports/windows/AweCraft.exe` (+ `AweCraft_debug_console.exe` + `.console.exe` wrapper) and (re)starts the LAN serve daemon (http 0.0.0.0:8080, pidfile `.scratch/serve_win_export.pid`, `--no-serve` to skip)
- Web serve (SINGLE server, no plain-HTTP twin): `python3 serve_web.py --ssl` (https 0.0.0.0:8443, self-signed `web/ssl/`, gzips) — log to `.scratch/awecraft-web-https.log`
- When reporting any running server, ALWAYS give both localhost and LAN: web `https://localhost:8443/` + `https://192.168.0.224:8443/` (self-signed, browser warns once); windows exes `http://localhost:8080/AweCraft.exe` + `http://192.168.0.224:8080/AweCraft.exe`

## Ops rules
- **AFTER EACH completed + verified task: `git add -A` (`.gitignore` excludes .scratch/web/export) + commit (incl. `tasks/AC-NNNN/`) + PUSH to `origin`** (user rule 2026-08-19). Remote added 2026-08-19: https://github.com/JacobGrealy/awecraft (public, ssh, branch `master`).
- **Serving daemons (setsid-detached, SURVIVE opencode restarts — plain `nohup &` dies on every session restart, that's what kept taking the web server down):** (1) HTTPS web = `python3 serve_web.py --ssl --daemon` (pidfile `.scratch/serve_web.pid`, log `.scratch/awecraft-web-https.log`, https 8443); (2) Windows-export download = `python3 -m http.server 8080 --bind 0.0.0.0 --directory exports/windows` (pidfile `.scratch/serve_win_export.pid`, log `.scratch/awecraft-winexport-http.log`, spawned/restarted by `build_windows.sh`). Both have port-in-use guards. NEVER kill any of these python server pids from subagents (they only kill specific godot/Xvfb pids).
- Godot runs **ONE at a time** (concurrent runs corrupt the `.godot` cache and hang). Never run two godot processes in parallel, including subagents.
- Renders: ~300000 ms bash timeout, keep render radius R=1-2, always headless-verify FIRST, at most one small render after.
- Kill stray godot/Xvfb/chrome pids (by pid, never pkill your own shell) before re-running if something hung.
- Machine: 6 cores, ~63 GB RAM, Ubuntu 25.10, no audio device (dummy driver), no passwordless sudo.
- Screenshots: subagents save final PNGs into their task folder `tasks/AC-NNNN/` and embed them in `AC-NNNN-results.html` — user reviews via that HTML. (Legacy renders already in `screenshots/`.) Scratch (logs/intermediates) goes in project-local `.scratch/` — prefer it over `/tmp`. `/tmp/**` is pre-allowed in `~/.config/opencode/opencode.json` but `.scratch/` is the default.

## Orchestration discipline (coordinator = the main agent)
- **TASK PROTOCOL (user 2026-08-19)**: every task = `AC-NNNN` in `tasks/TASKS.yaml` (single source of truth — work-todo schema: id/title/source/priority/status/labels/created_at/updated_at/completed_at/waiting_on/notes/comments[] + top-level `queue:` = committed work order; TASKS.md removed 2026-08-19 per user — YAML is the only registry file, human view later via AC-0046 webui). BEFORE every subagent launch: create `tasks/AC-NNNN/` + write `spec.html` (requirements, web refs, verify gates, deliverables) and set status in-progress. The subagent saves its screenshots into that folder and writes a final `AC-NNNN-results.html` (self-contained summary, embedded screenshots where they make sense). On completion the coordinator updates TASKS.yaml, then commit+push. Once AC-0046 lands: use `tasks/scripts/tasks.py` CLI + webui instead of hand edits.
- **Subagents do ALL code AND research/implementing.** Coordinator only: plans, launches tasks, reads short reports, views screenshots, edits coordination files (this file, CONTINUITY.md, plans).
- The coordinator must NOT open large source files or run exploratory greps in its own context — put the question in the subagent prompt instead.
- **User-reported problems go at the TOP of the todo list (high priority), ahead of planned work**, and are researched+fixed via subagents.
- Subagent report limit: **MAX ~20 lines** (files changed, RESULT values, deviations). Anything longer goes into the task's `AC-NNNN-results.html`. This protects the coordinator's context.
- Subagent prompts must be self-contained: point at ARCHITECTURE.md + CONTINUITY.md (paths, not inlined content), state the task, the verification, the report limit. Reliability pattern: SMALL tasks, headless-verify first, honest partial > empty, zero script errors is a hard gate.
- **NEVER launch more than one subagent at a time.** This machine's LLM API serves ONE concurrent request only — parallel `task` calls will stall or collide. All subagents run strictly sequentially.
- **SUBAGENTS ARE BLOCKING (user 2026-08-24): do NOT multitask while a subagent is running.** The subagent uses the same local LLM, which serves ONE request at a time — any other model/tool work by the coordinator (reading files, edits, planning, other launches) contends with it. Treat every subagent launch as a blocking call: launch it, then do NOTHING else until its completion notice arrives; only then verify its work and continue. No parallel coordinator work, no second launches, no "quick" reads in the meantime.
- **SUBAGENT EFFORT IS ROUTED BY TOOL NAME (user 2026-08-25).** The `$DSH_HOME` plugin `subagent-reasoning` pins each child's reasoning effort from the **tool used to launch it** (subagent tools take no per-run effort flag): `subagent_plan` → **xhigh** (planner / Run-1 research), `subagent` / `subagent_implement` → **medium** (builder / Run-2 implementation); anything else falls back to the patch's `subagentEffort` config (currently `medium`). So in the two-phase workflow (see `tasks/templates/two-phase.md`): **launch Run 1 (research → plan.html) with the `subagent_plan` tool, and Run 2 (implementation) with the `subagent` tool.** Launching a research pass with plain `subagent` downgrades it to medium — do not. The mapping lives in `~/.dsh/cordis.patch.yml` + `~/.dsh/plugins/subagent-reasoning.js`, is composed **at DSH host start** (an edit takes effect on the NEXT restart), and a host restart **KILLS in-flight subagents** — after one, inspect the task folder + `.scratch/AC-NNNN/` for partial progress and relaunch with a resume message pointing at the disk state (don't redo finished steps).
- Sequential godot work is therefore automatic; batch independent subagent work into ONE task prompt if possible.
- **Checkpoint rule**: before launching any large task, update `godot/CONTINUITY.md` (§6 task statuses + new findings) so a mid-task context loss is recoverable.
- Long unattended runs: work the task list end-to-end (verify → web build → next task) **until the list is empty**, checkpointing between tasks. Do NOT pause for approval or feel-checks — user directive 2026-08-18: "work through the task list until they are all complete, do not stop for me". Only stop if blocked or at a genuine decision point.
- Bash hygiene for the coordinator: capture long output to `/tmp/opencode/*.log` and grep/tail it; never dump full logs into context.

## Web test loop (user's primary surface)
After each Godot feature or fix: `./build_web.sh` → ensure server running (`serve_web.py`) → report localhost + LAN URLs → user tests in browser → next task. Browser bugs are first-class: reproduce reasoning from the spec (`index.html` is the reference) but fix in `godot/`.

## Task status (canonical)
`godot/CONTINUITY.md` §6 — AC-0062–AC-0074 all done (2026-08-22/23: 0067 viewmodel-on-top, 0070 tool voxxel redo, 0072 sliders, 0073 tool orientation+scale, 0068 water per wiki, 0074 windows export pipeline); AC-0071 streaming plan delivered (gates AC-0034); next in queue: **AC-0034 chunk streaming** (user moved up 2026-08-22).

## Game semantics reference (user 2026-08-20)
- Minecraft wiki is the canonical reference for how tools/crafting/blocks should behave — AweCraft must match it **exactly unless the user specifies otherwise**: https://minecraft.wiki/w/Tool , https://minecraft.wiki/w/Block (plus related: Tool_durability, Mining, Crafting_table, Item_repair, Item).
