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
- **No GPU, no display** (AC-0391, 2026-10-03). Everything that renders is software:
  `mesa-vulkan-drivers` (lavapipe Vulkan ICD — `/usr/share/vulkan/icd.d/lvp_icd.json`,
  `libvulkan_lvp.so`), `xvfb` (virtual X — a Vulkan surface needs one), `vulkan-tools`
  (`vulkaninfo`) — all preinstalled on this box. The software-Vulkan path (Forward+ via
  lavapipe) is PROVEN working, 2026-10-03: recipe + the mandatory path assertion +
  measured fps/budgets in `godot/HARNESS.md` §2/§4.
- Native extension: `python3 -m SCons -C gdext platform=linux|windows target=template_release`
  — `./build_windows.sh` runs both for you (§4).
- **The builder model is a local 27B and its throughput IS the schedule** (measured 2026-10-19,
  AC-0454). `subagent_medium` / `subagent_xhigh` / `subagent_low` all run `homeserver1` /
  `Qwen3.8-27B-UD-Q4_K_XL`, and one slot is all there is. The law, over 127 builder sessions
  replayed from `~/.dsh/sessions/`:

  ```
  wall_seconds = -938 + 0.0674 * output_tokens      R² = 0.933     ~15 tokens/s
  ```

  A run's wall clock is 93% explained by how many tokens it writes; **gates and builds are noise
  beside it** (the full 8-arm set for AC-0433 run 2 took 10.3 min against a 66 min run). The
  population median builder run is about **2.1 h / 125-142k output tokens / 115-122 steps**.
  Output composition: **reasoning 64-80%**, tool-call arguments 20-25%, assistant prose ~2%.

  Consequence, and it is a standing rule: **effort and token count are the knobs, not the machine.**
  Plan before launching (`awecraft-plan`), keep the builder medium (`awecraft-delegate` §2), and
  never hand a builder a whole large file — `godot/scenes/harness.gd` is 36,630 lines / 1.5 MB,
  about 430k tokens, which is larger than the 250k context window and kills the run.
  `python3 tasks/scripts/builder_stats.py` is the AUTHORITY for the values above — re-run it (about
  two minutes over ~300 sessions) rather than trusting this paragraph. Judge any change to the
  delegation flow with it: a real win shows up as fewer steps and fewer output tokens per run, not as
  a faster token rate. Do not read a single run's wall clock as evidence — decode speed varies
  (a quiet run has been measured at 28 tok/s against this 15 tok/s law), so one fast run proves
  nothing on its own.

  **The response cap is 32,768 tokens, and reasoning is charged against it** (`llm-pi-ai`
  `DEFAULT_MAX_TOKENS`, `packages/llm/llm-pi-ai/src/config.ts`; `~/.dsh/settings.yaml` sets no
  `maxTokens` for the 27B). Truncation appears as `stopReason: length` in the session log and is RARE:
  across 9,533 builder responses the median response is 452 tokens and p99 is 8,487, so ordinary work
  has ~98% headroom. The exposure is therefore one BALLOONED response — in practice a whole-file
  `write` or a runaway reasoning block, which is why `tasks/templates/implement.md` fences rewriting a
  file. Note that a child session's header records no `reasoningEffort`, so truncations CANNOT be
  attributed to an effort level from the logs; record the effort first if that question matters. And
  do not raise the cap to "fix" truncation — a 60k single response is a bad response, not a saved one.

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
- **A generated IMAGE needs a structural variance check, not just data and mapping checks** (found by
  AC-0310, 2026-09-29): a satellite bake passed its planet census, its colour-correlation check, its limb
  and solid-angle geometry, its great-circle edge check and its seam-gaplessness check, and was still a
  ONE-DIMENSIONAL SLICE repeated down every row - because `np.tile(arr, (NPIX, 1))` replicates into ROWS,
  so an array indexed by the row coordinate silently became a function of the column index. The guard that
  belongs with any composite visual artifact asserts, ON THE WRITTEN FILE DECODED BACK FROM DISK, that the
  image varies along BOTH axes (distinct rows and columns against a floor the real data clears) plus a
  spread on each channel, and it must be negative-tested against a deliberately degenerate replica. When
  3-D renders are unavailable (degraded llvmpipe, as on this box) a data-driven PNG is a legitimate visual
  gate for the coordinator to inspect by eye - the numeric checks cannot see a smear.
- **GDScript's literal parser can MIS-ROUND a long decimal literal** (found by AC-0367 piece A,
  2026-09-27): the value `0.011499999999999996` parsed 4 ulp LOW, which showed up as an 8-sample
  1-ulp drift between the GDScript and C++ lanes of a ported noise. The fix is to spell an exact
  constant as a DIVISION (`-6629298651489368.0/2^59`) rather than a long decimal string. Any ported
  constant that must be bit-exact in both lanes is a candidate for this trap, and the lockstep
  genprobe block is what catches it - a drift of one ulp is invisible to every other gate.
- **EVERY gate run must be memory-capped, and the big ones must be SAMPLED over time.** Cap with
  `bash -c "ulimit -v <KB>; … godot …"` (AC-0356 used 8 GB for arms whose measured peaks are
  0.4–1.1 GB) and sample RSS every 10–15 s for any large-radius run. THE REASON IS NOT TIDINESS:
  gate runs execute inside the **`dsh-web.service` cgroup**, so a runaway gate does not fail
  politely — it OOM-kills the harness itself. AC-0356 was exactly that: an unbounded leak in a
  large-radius run (fluid writes firing one two-phase light re-flood each, into an unbounded
  deque — ~4.4 GB/min, ~50 GB in twelve minutes) drove the cgroup to 52.6 G, the kernel killed
  `dsh-web.service`, systemd's `OOMPolicy=stop` + `Restart=always` restarted it, and every restart
  tore down in-flight gate children, lost subagent work in flight and reset goal state (13 session
  instances in 24 h, each looked like a mysterious "the subagent died again"). Judging a memory
  question by a single peak hides exactly this: report the TRAJECTORY.
- **A harness restart is the default explanation for a job that dies with no output** — check it by
  counting recent session instances (`ls -t ~/.dsh/sessions/*/session.jsonl.zstd | head`) before
  blaming the work. A lost subagent LAUNCH leaves no trace at all (no journal entry, no plan file),
  which is how you tell it apart from a run that started and was interrupted — and it is why every
  builder writes its plan, results page and continuity journal as it goes rather than at the end.
- **Heavy gate scripts should be RESUMABLE**: skip a gate whose log already contains a `RESULT`
  (or `GENHASH` — the genhash arm prints only `GENHASH` lines, a trap that silently re-ran it).
  A restart then costs one gate instead of a whole stage. Both lessons are AC-0356's.
- **Never decide anything about a `res://` resource with `FileAccess.file_exists` (or
  `FileAccess.open` / `Image.load_from_file`) — use `ResourceLoader.exists` to probe and
  `ResourceLoader.load` to load** (found by AC-0384, 2026-10-01, the white-planet export bug):
  `FileAccess` does NOT consult the import system. An exported PCK ships the **imported** form of
  an imported resource (a `.png` → its `.ctex`), not the raw source file, so in an export
  `FileAccess.file_exists("res://…/x.png")` is **FALSE** while `ResourceLoader.exists("res://…/x.png")`
  is **TRUE**. Every gate we own runs from the **source tree**, where the raw `.png` is on disk and
  `FileAccess.file_exists` is TRUE — so the branch is unreachable in every test and the bug ships.
  The satellite body chose its texture source this way (`godot/world/satellite_body.gd`), so the
  canonical seed-44 path was skipped in the Windows build and the body drew with unset textures
  (Godot's default WHITE). **PROVEN, not asserted**: a `--export-pack` PCK probed with `--main-pack`
  gives `FileAccess.file_exists` = **false** / `ResourceLoader.exists` = **true** /
  `ResourceLoader.load().get_image()` = 1024² for the satellite png, 12/12 faces import-loadable
  (`.scratch/AC-0384-gates/`). The correct split: **`res://` imported resources → `ResourceLoader`;
  `user://` runtime files and non-imported raw data (`.json`) → `FileAccess`** (a `.json` has no
  importer, ships raw in the PCK, and `FileAccess.file_exists` is TRUE for it in an export too).
  **The general shape (the class that keeps recurring): any decision that is true in the editor and
  false in an export is invisible to every gate we own** — the arm's escape is to (a) use the
  export-true predicate, and (b) record *which* predicate chose the path in the arm's RESULT so a
  silent fall-through is visible (AC-0384 added `src_predicate` to the satellite arm).

- **AddressSanitizer CANNOT instrument the engine on this box — Valgrind memcheck is the substitute**
  (AC-0408, 2026-10-08, while hunting the slab use-after-free). Godot dlopens GDExtensions with
  **RTLD_DEEPBIND**, and the ASan runtime refuses to back a DEEPBIND library (upstream sanitizers
  issue 611). Verified in BOTH directions: a bare instrumented `.so` gives rc=1 "ASan runtime does
  not come first in initial library list" (the extension dlopens after the non-instrumented
  libraries), and `LD_PRELOAD=libasan` gives "trying to dlopen libchunkio.so with RTLD_DEEPBIND flag
  which is incompatible with sanitizer runtime". The instrumented `libchunkio` itself builds fine
  (~41 s: `g++ … -fsanitize=address -fno-omit-frame-pointer -DASAN_ENABLED` — godot-cpp has
  first-class ASan support and `#error`s without the define), so the wall is the engine's loader,
  not the build; the only ASan route left is an ASan-built engine (a coordinator-lane decision).
  **Valgrind** (3.25.1 on this box) runs memcheck with NO instrumentation against the production
  `.so`: the exact crash recipe (the 27-s `lightstate R16`) takes **~38 minutes per pass** (15–20×
  wall), so a crash-hunt soak is managed-background-job scale — AC-0408's resumable soak (per-run
  DONE markers, 90-min caps) is `.scratch/AC-0408-asan/vg_soak.sh`; its run 1 came back clean
  (`ERROR SUMMARY: 0 errors from 0 contexts`), runs 2–4 + the player arm remain.

## 3. Daemons and ports

| Port | Service | Started by | Notes |
|---|---|---|---|
| **8080** (falls back to 8081/8082, prints the picked port) | Windows build download | `./build_windows.sh` — a `setsid`-detached `python3 -m http.server` serving `exports/windows/` | pidfile `.scratch/serve_win_export.pid`, log `.scratch/awecraft-winexport-http.log`. It serves from disk, so a new build needs no restart. `AweCraft.exe` (un-stamped) is the always-latest copy = the serve contract. It survives session ends. |
| **5180** | tasks board webui (LAN, **no auth**) | `python3 tasks/webui.py --daemon` (`--replace` to take the port from a stale instance) | the UI over `tasks/TASKS.yaml`; binds `0.0.0.0`, dev box only. Without `--replace` it prints "already running (pid X, port Y)" and exits 0. |
| **8000** | docs LAN share — the design essays in `docs/` (**no auth**) | a **managed background job** (not `setsid`, see §2) running `.scratch/serve-docs.py`, the `python3 -m http.server` pattern plus an alias for `/cave-compare.html` (that doc lives in `tasks/cave-compare/`, and the plain root 404s on it) and a `SIGALRM` auto-stop | `http://192.168.0.224:8000/`. **A managed job is capped at ~7.5 h** — two of these ended cleanly on the runner's `SIGALRM` while their own 12 h/24 h alarms were still pending — so it needs re-arming after a long gap. For a share that outlives the session, start it in **your own shell** instead: `setsid python3 -m http.server 8000 --bind 0.0.0.0 --directory docs >/dev/null 2>&1 &` |
| ~~8443~~ | legacy web-export HTTPS daemon | — | **Dead.** The web product is gone (no `build_web.sh`, no `web/` in this tree) and nothing listens. Historical notes only — do not put it in a gate. |

Gate curls: `curl -sI http://127.0.0.1:8080/AweCraft.exe` → 200 and
`curl -sI http://127.0.0.1:5180/` → 200. Report both `localhost` and the LAN address.

**Serving wrinkle (2026-09-28):** `build_windows.sh` may report `pidfile stale` then `port 8080 busy
— trying next` and start its server on 8081, while the ORIGINAL 8080 server is still alive and serving the
SAME export directory (its document root is the export dir, so a rebuild is picked up in place). Verify by
content, not by port: `curl -s http://127.0.0.1:8080/BUILD.txt | head -3` prints the git revision and stamp
of what is actually being downloaded, and if that matches the build you just made then the canonical URL is
correct and nothing needs fixing. Do not try to kill the 8080 holder from inside an agent sandbox — it lives
outside the bwrap PID namespace, so it is invisible to `ps` there even though `ss` shows the listener.

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

- Rendering needs a virtual X server: `xvfb-run -a` + `AWECRAFT_SNAPSHOT=<absolute path>`; the
  exact recipes, every render hook and the memory/timeout budgets are in `godot/HARNESS.md`
  §2/§4.
- **Use the SHIPPED Forward+ renderer for all visual verification (AC-0391, 2026-10-03)** —
  `VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json` + `--rendering-driver vulkan`
  (lavapipe, software Vulkan — the same renderer, a software driver). Every Forward+ run's log
  must assert the boot line `- Forward+ -` (the adapter is ALSO named "llvmpipe" — the renderer
  string is the discriminator; the assertion contract is in HARNESS.md §2). The legacy
  `--rendering-method gl_compatibility` (llvmpipe OpenGL — the Compatibility renderer, a
  different graphics API) remains only for compat-specific A/B questions.
- It is **software** rendering (lavapipe): budget up to **300 s** per shot and keep
  `AWECRAFT_RADIUS` ≤ 4. Measured 2026-10-03 at 1280×720 R4: ~5 FPS (the `AWECRAFT_DSSTATS=1`
  overlay), `wallshot` hook 83 s (it rc=124'd at the 300 s timeout under the old proxy), a full
  R4 snapshot run ~290 s. One render at a time (see §2). Practicality verdict: renders are
  POSSIBLE and marginally PRACTICAL — **one render per visual ticket, not per gate run**.
- Renders on this box run the shipped renderer with a software driver: they ARE evidence about
  the Forward+ path (shader compilation, feature availability, layout, colour) but NOT about
  real-GPU performance or GPU-specific precision edges. The authoritative look and speed are
  the user's Windows build (AC-0241).
- **Engine-build quirks (measured 2026-10-17, AC-0440):** (a) `StandardMaterial3D.wireframe =
  true` is IGNORED on the Forward+/lavapipe path — the box renders as a solid fill; outline
  looks must be real geometry (or verified on the Windows build). (b) This build's `MultiMesh`
  is the Godot-3-style API: the mesh rides `MultiMesh.mesh` (not `base_mesh`),
  `instance_count` (not `transform_count`), and the material rides the base mesh (see
  `entities/particle_pool.gd` for the working pattern); `get_instance_transform()` read-back
  returns the identity after `set_instance_transform()` — the write path renders correctly,
  don't trust the read-back for diagnostics.

## 7. Gates: know an arm's variance before you trust it as an oracle

Two rounds in a row (AC-0469 G4, AC-0463 L2) a gate was specified as "identical" against an arm that
swings by more than the change it is being asked to detect. Both times the code was correct and the
threshold was wrong:

- **`boundary` crossing_frame p50** has read 14, 21, 26, 31 and 32 across runs of effectively the same
  tree; **p95** held at 37-40. Judge a crossing-latency change on p95, never on p50.
- **`lightstate` RESULT is not JSON-deterministic.** A same-tree A/B (two runs, no code change) drifts
  in its pacing fields (grid census, hole counts). Compare its light-VALUE fields, not its JSON.

**The rule:** before using any arm as an identity oracle for a refactor, establish its run-to-run
variance first — either from earlier runs in `.scratch/`, or from a same-tree A/B. If the arm's own
spread is comparable to the effect being claimed, the arm cannot prove or refute that effect, and the
proof has to come from a structural argument instead (a diff that reduces the new expression to the
old one, a cross-check with a counted sample, or an expression audit). A green gate that would also
have been green with the change reverted proves nothing.

## 8. Why this file exists (rule harvest)

The sandbox/push/git rules above used to be referenced as "CONTINUITY.md §00p INFRA LESSON v3 +
BUILD RECIPE". Compaction dropped that section, and the rules survived only inside
`tasks/AC-0110/continuity.md` and one handoff file. This file is their home now, and the closeout
step — the `awecraft-closeout` skill — enforces the harvest: **a durable rule discovered in a task
is written here (machine/build/daemon) or into the process skills (pipeline/delegation) before
the task folder is abandoned.**
