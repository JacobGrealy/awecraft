# AweCraft — operations

The machine, the sandbox, the build/serve pipeline and the daemons.

**Boundary:** `godot/HARNESS.md` owns the test arms, the battery, standing gate values and
the per-call godot command recipes (including the `HOME=/tmp/dsh_home` prefix). This file owns
the machine, the build, the daemons and git. Do not restate one in the other — link.

## 1. Machine

- Linux dev box, repo at `/home/angrygiant/github_projects/AweCraft` (the repo root *is* the
  AweCraft checkout — there is no nested `AweCraft/godot` path).
- Engine: `~/tools/godot/godot` → `4.7.1.stable.official.a13da4feb`. **Always an absolute
  path, always `--path godot`, run from the repo root.**
- Export templates: `~/.local/share/godot/export_templates/4.7.1.stable`.
- The product is Windows-only (AC-0124). Linux is development + verification only.
- Native extension: `python3 -m SCons -C gdext platform=linux|windows target=template_release`
  — `./build_windows.sh` runs both for you (§4).

## 2. Sandbox rules (why a godot call looks the way it does)

**The rules for issuing a godot call — the `HOME` prefix, the absolute engine path, `--path godot`
from the repo root, one process at a time — are owned by `godot/AGENTS.md`.** This section is the
machine reason behind them.

- **The real HOME is not writable here** and the engine segfaults (rc=134) on the first write to
  `user://` — a bare `--quit` with the real HOME crashes (AC-0108). Hence `HOME=/tmp/dsh_home`.
- `/tmp` is ephemeral per bash call, so `HOME=/tmp/dsh_home` means **saves do not persist
  between calls/reboots**. Durable output goes into `.scratch/`, which is git-ignored.
- **One godot process at a time** — two in parallel corrupt the `.godot/` cache. A parallel agent
  may hold the slot: check before you launch, and never kill a process you did not start
  (`godot/AGENTS.md`).
- `./build_windows.sh` uses the **real** HOME (it needs the export templates) — do not run it
  under the sandbox HOME.
- A `git worktree` of a past commit does **not** contain the untracked `godot/bin/libchunkio.so`
  (see §5) — copy it from the main tree or headless startup cannot parse the extension.
- `godot/scenes/harness.gd` stays pristine — rule and reason in `godot/scenes/AGENTS.md`.
- **Long background work must be launched as a managed background job, not `nohup … &`** — the
  sandbox runs every bash call under `bwrap … --die-with-parent`, so a `nohup`-detached child is
  torn down the moment the tool call returns (a heavy gate script silently died after one arm,
  AC-0313). The managed job (the tool's background mode) survives and can be collected; a script
  that must outlive a call has to be started that way.

## 3. Daemons and ports

| Port | Service | Started by | Notes |
|---|---|---|---|
| **8080** (falls back to 8081/8082, prints the picked port) | Windows build download | `./build_windows.sh` — a `setsid`-detached `python3 -m http.server` serving `exports/windows/` | pidfile `.scratch/serve_win_export.pid`, log `.scratch/awecraft-winexport-http.log`. It serves from disk, so a new build needs no restart. `AweCraft.exe` (un-stamped) is the always-latest copy = the serve contract. It survives session ends. |
| **5180** | tasks board webui (LAN, **no auth**) | `python3 tasks/webui.py --daemon` (`--replace` to take the port from a stale instance) | the UI over `tasks/TASKS.yaml`; binds `0.0.0.0`, dev box only. Without `--replace` it prints "already running (pid X, port Y)" and exits 0. |
| ~~8443~~ | legacy web-export HTTPS daemon | — | **Dead.** The web product is gone (no `build_web.sh`, no `web/` in this tree) and nothing listens. Historical notes only — do not put it in a gate. |

Gate curls: `curl -sI http://127.0.0.1:8080/AweCraft.exe` → 200 and
`curl -sI http://127.0.0.1:5180/` → 200. Report both `localhost` and the LAN address.

## 4. Windows build + serve

```bash
./build_windows.sh              # gdext (linux + windows) → export release + debug-console → (re)start :8080
./build_windows.sh --no-serve   # export only, leave the daemon alone
```

Artifacts in `exports/windows/` (git-ignored, never committed):
- `AweCraft-YYYYMMDD-HHMM.exe` — stamped release build, and `_debug_console.exe` (engine logs
  on) plus Godot's `…_debug_console.console.exe` wrapper: **double-click the wrapper on Windows**
  to get the log in a console window (it must sit next to the debug exe).
- `AweCraft.exe` / `AweCraft_debug_console.exe` (+ wrapper) — un-stamped copies of the newest
  build; this is what `:8080` serves.
- `BUILD.txt` — git sha + branch + stamp.
- Retention: the newest **3** stamped pairs; older pairs are deleted after a successful build.

The user downloads it at `http://192.168.0.224:8080/AweCraft.exe` (or `127.0.0.1` locally).

## 5. Git

- **Commit explicit paths.** This tree carries long-lived untracked directories (`.scratch/`,
  `.tmp_*/`, `references/`, several `tasks/AC-01xx/` folders, two design essays) — `git add -A`
  would swallow them.
- Push with the sandbox-safe form: `GIT_SSH_COMMAND="ssh -F /dev/null" git push` (the sandbox
  HOME has no usable ssh config or known_hosts).
- **Do not commit**: `.scratch/`, `.tmp_*/`, `references/`, `docs/halo-loot-brainstorm.html`,
  `tasks/AC-0092/`, `tasks/AC-0125/plan.html`, `tasks/AC-0140/` and the other untracked
  per-task directories. Build outputs (`exports/`, `godot/bin/*`, `gdext/bin/`, `.godot/`) are
  git-ignored by design — the native `.so`/`.dll` are built locally, never committed.

## 6. Render limits

- Rendering needs a virtual X server: `xvfb-run -a` + `AWECRAFT_SNAPSHOT=<path>`; the exact
  recipes and every render hook are in `godot/HARNESS.md` §2/§4.
- It is **software** rendering (llvmpipe/lavapipe): budget up to **300 s** per shot and keep
  `AWECRAFT_RADIUS` at 1–2. One render at a time (see §2).
- Renders on this box are a *convenience*: the rendered pipeline may not be the shipped one, so
  treat a render as evidence about geometry/UI layout, not about final colour or effects. The
  authoritative look is the user's Windows build of the shipped renderer (AC-0241).

## 7. Why this file exists (rule harvest)

The sandbox/push/git rules above used to be referenced as "CONTINUITY.md §00p INFRA LESSON v3 +
BUILD RECIPE". Compaction dropped that section, and the rules survived only inside
`tasks/AC-0110/continuity.md` and one handoff file. This file is their home now, and the closeout
step — the `awecraft-closeout` skill — enforces the harvest: **a durable rule discovered in a task
is written here (machine/build/daemon) or into the process skills (pipeline/delegation) before
the task folder is abandoned.**
