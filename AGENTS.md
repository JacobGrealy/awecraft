# AweCraft — Agent Guide

Voxel Minecraft-like — Godot 4.7.1, `godot/`, engine `~/tools/godot/godot` (`--path godot`). **Windows-only** (AC-0124).

## Start every session
1. `godot/CONTINUITY.md` **§00o only** (top checkpoint, ~20 lines) — current state + resume steps. Skip `00n`.. history unless debugging.
2. `godot/ARCHITECTURE.md` — architecture + subagent contract (read before any code task)

## Quick commands (from repo root)
- Headless check: `~/tools/godot/godot --headless --path godot --quit`
- Logic tests: `AWECRAFT_LOGIC=player|interact|light|fluids|buckets ~/tools/godot/godot --headless --path godot`
- Render: `xvfb-run -a ~/tools/godot/godot --path godot --rendering-method gl_compatibility`
- Windows build: `./build_windows.sh` → `exports/windows/AweCraft.exe` (+ LAN `http://192.168.0.224:8080/AweCraft.exe`)

## Role
You are the **orchestrator/coordinator** — plan, launch subagents, verify results, commit+push. Subagents do ALL code/research.

## Where details live
- **Commands, env hooks, build, daemons, machine, screenshots** → `godot/CONTINUITY.md`
- **Architecture, autoloads, scene layout, verify, migration checklist** → `godot/ARCHITECTURE.md`
- **Task protocol, queue, orchestration, subagent contract, harness** → `tasks/templates/two-phase.md` + `tasks/TASKS.yaml` (`python3 tasks/scripts/tasks.py next`; queue state in `godot/CONTINUITY.md` §6)
- **Ops rules** (commit+push after each task, push workarounds, daemon survival, Godot one-at-a-time, render limits) → `godot/CONTINUITY.md`
- **Game semantics** (Minecraft wiki canonical) → `godot/CONTINUITY.md` footer

## Task status
Run `python3 tasks/scripts/tasks.py next` — `godot/CONTINUITY.md` §6 is authoritative. Report running servers with both `localhost` and LAN addresses.
