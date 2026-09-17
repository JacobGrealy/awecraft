---
name: awecraft-heavy-gates
description: Use when running the coordinator's heavy gate set or the Windows build for an AweCraft ticket, when a gate run must be backgrounded, or when godot is contended by another agent.
---

# The heavy stage (coordinator only)

The builder owns the light gates (`awecraft-run-verify`); **the coordinator owns the heavy stage, the
Windows build and the serve check.** Re-running a builder's light gates doubles cost for no extra
information.

## The sliced heavy set

**`boundary` r4 ×1 + `flake` ×1 + `genhash` re-run + the task's probe** — and only when the scope
touches `godot/world/*` or the lighting path. UI/tool-only tickets get SMOKE only (`godot/HARNESS.md`
§3). `r50` is nightly class (15–45 min wall); the full `battery` runs when the spec calls for it.

## Run it as ONE background job

- One script, **godot sequential**, logging to `.scratch/AC-NNNN-gates/gates.log` (repo root).
- The job writes the marker `.scratch/AC-NNNN-gates/HEAVY_GATES_DONE` when it finishes — that marker
  is how another agent knows the slot is free. Do not busy-poll; you are notified when the job ends.
- **Never two godot processes**: before every call check `pgrep -af '[g]odot'` and the marker, and
  **never kill a godot process you did not start** (a parallel agent may hold the slot).
- Then the build, in the same job: `./build_windows.sh` (gdext linux + windows, then export; it uses
  the **real** HOME, not the sandbox one) followed by the gate curls.

## Serve check and reporting

- `curl -sI http://127.0.0.1:8080/AweCraft.exe` → **200**, and `curl -sI http://127.0.0.1:5180/` →
  **200**. The `:8080` download daemon serves `exports/windows/` **from disk**, so a new build needs
  no restart; `AweCraft.exe` (un-stamped) is the always-latest copy = the serve contract.
- `:8443` is **dead** (the web product is gone) — never gate on it (`godot/OPS.md` §3).
- Report running servers with **both** addresses: `http://localhost:8080/AweCraft.exe` and
  `http://192.168.0.224:8080/AweCraft.exe`; board `http://192.168.0.224:5180/`.
- A heavy failure is an **honest deviation + a follow-up ticket**, or a bounce — never a silent
  re-baseline. Commit/push only after the heavy stage passes (`awecraft-closeout`).
