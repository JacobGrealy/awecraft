# HANDOFF — emergent recenter queue (AC-0282) — 2026-09-14

For a FRESH PLANNING session. Read this + `godot/CONTINUITY.md` §00Z r7 +
`godot/ARCHITECTURE.md`. The ticket `AC-0282` (queue head) carries the full
spec text; this file is the map + the decisions already made + the open ones.

## 0. Where we are
- Shipped & gated & user-tested-in-game: commit `83cfcfe` (+docs `1cdc015`),
  build on `:8080` (sha `998e1df78ca7e586…`), Windows-only game.
- The user confirmed in-game that the 16x-flight-to-nowhere scenario behaves
  per spec ("nothing different should happen you stop… it's still per disc,
  the target just isn't changing constantly").
- Then the user rejected the *mechanism* 83cfcfe used: a timer-driven mode
  switch (moving state → windowed probes). The behavior must EMERGE from the
  recenter queue, with NO timer. That is AC-0282. **Do not code before
  planning the design in a fresh session** — the user asked for exactly that.

## 1. The spec (user's words, binding — full text in the ticket)
1. Every chunk crossing recomputes the ENTIRE work queue.
2. Highest-priority chunks build from y=player-y (slab fan: player slab,
   then one below, then one above, …).
3. Never show a slab whose lighting isn't calculated (per-chunk light settle
   + flush; the late-landing fix in 83cfcfe implements the fix for the
   "lighting too bright" complaint — KEEP IT).
4. Already-passed discs don't keep building down while you keep moving —
   and this is NOT a timer: "3.5 s is a description of approximately what
   should happen based on our constraints, it in itself is not a constraint.
   So there should not be some kind of internal timer that changes what we do."
   It emerges because every recenter injects new outer-edge work that must be
   processed before deeper discs resume.
- Bands: tier 0 = separate band, full column, before everything else.
  High/med/low = discs, filled from the player's Y.
- "we need to rescore all slabs every recenter, are we doing that? otherwise
  further slabs are going to have the same priority as closer slabs"

## 2. Answer to the rescore question (verified in code, 83cfcfe)
YES — scores are never stored. `_grid_score(e)` is recomputed on every pick
(pure function of the LIVE recenter anchor `last_pcx/pcz`, the LIVE player
slab via the live probe, and live completion stamps). The next pick after any
recenter re-orders the entire queue automatically.
**The real gap is the order SHAPE, not staleness:** the (layer, taxi) bake
order is LAYER-MAJOR (`layer*10000 + taxi`), so a passed column's deep slab
(layer 1, taxi 9 → 10009) outranks a fresh edge column's slab (layer 2,
taxi 50 → 20050). Deep fill therefore progresses in the gaps between
recenters — the "whole columns behind me" the user saw pre-83cfcfe. 83cfcfe's
window masked it with the mode switch the user now rejects.

## 3. Current mechanism to REMOVE (all in `godot/world/world.gd`, 83cfcfe)
- `_lod_player_moving()` (position-delta re-arming `_lod_move_ms`, the
  AHEAD_FAST_MS=3500 quiet window) + `_lod_move_anchor`/`_lod_move_ms` vars +
  the per-frame anchor update in `threadmesh_poll`.
- `_lod_windowed_for(c)` (moving ∧ not tier-0).
- Probe windowing: `_entry_best_pending(c, windowed)` /
  `_hslab_best_pending(c, windowed)` (`if windowed and r > 2: continue`) and
  the cached variants' fingerprint element 5 (`_lod_windowed_for(c)`).
- `_grid_score`: the `elif _lod_windowed_for(c): return 1e30` rule.
- Build-pass hold on windowed -1 (~6939) and loadwin break on windowed -1
  (~6813), low-wave gate (~6809).
→ After removal every probe is the FULL probe; -1 = genuine completion and
frees the entry (original pre-7f1888d behavior — `git show
51ce580:godot/world/world.gd` is the reference).

## 4. Planned direction (PLAN before coding)
1. Fresh-edge priority: the recenter walk already separates WANT (entries
   that ENTER the queue this recenter — the new outer-edge columns) from STUB
   (carried). Tag entries at finalize (`e["fresh"]`) and give fresh entries a
   score prefix so ALL their slabs (full column, fanned from the player's Y)
   complete before carried deep work resumes. While moving, each crossing
   keeps injecting fresh work → deep fill starves (emergent, no timer). At
   rest no fresh work arrives → the queue drains deep, one disc's Y at a time.
   Prefix magnitude: below tier-0 (-1e10), above any (layer, taxi) value
   (max ~120k) — e.g. -2.5e9 (the AC-0274 load target already uses -5e9;
   avoid the sum colliding with -1e10).
2. KEEP: tier-0 prefix (-1e10), AC-0274 load-target prefix (-5e9), the
   late-landing light fix (~5740 per-slab + ~5872 full-column: slab landing
   in an already-settled chunk → un-settle, hide, re-arm flush).
3. Data prep stays column-wise (WorldGen.generate = whole 384-block column) —
   user asked, confirmed: data prep is the cheap step, every MESH dispatch is
   per-slab (zero full-column mesh call sites).
4. Measure headless BEFORE and AFTER: the real-time walk arm
   (`player.flying=true`, Y pinned to `spawn_point().y`,
   `get_physics_process_delta_time()` — fixed-dt fly patterns run 10x too
   slow; spawn pocket is walled, probe gentle terrain via
   `WorldGen.terrain_height`). Metrics: while moving — carried deep-slab
   dispatches ~0, fresh-edge dispatches >0, tier-0 full column builds; at
   rest — fresh ring drains, then the deep fan; arrival (16x flight to
   nowhere, stop) — fill starts at the fresh outer ring ("outside in").

## 5. Open questions for the planning session
1. **The ahead-lead snapback (AC-0277)** recenters once when the player stops
   (3.5 s quiet). The user's model says stopping should STOP recenters
   entirely — does the snapback go, or is one final recenter acceptable?
2. Fresh prefix scope: outrank ALL carried slabs (deep included) or only
   carried slabs below some layer? (User: "it needs to process those before
   it can start doing deeper discs again" reads as ALL carried slabs.)
3. Does "one disc y at a time" mean the current global layer-sweep (all
   columns' layer N, then N+1) or per-column completion (a column's full Y
   fan before moving to the next)? (Current code = global layer-sweep; the
   user described the observed fill as expected, so likely keep.)
4. "Staying long enough" = emergent from work volume — confirm NO knob/const
   for it exists in the code path.

## 6. Key code map (`godot/world/world.gd`)
- `_layer_rank_of` (~494), `_grid_score` (~747), `_is_tier0_col` (~1626)
- window mechanism: ~494-540 (funcs), ~3242 (vars), threadmesh_poll ~5494
- probes + caches: `_entry_best_pending` (~576), `_hslab_best_pending`
  (~628), `_*_cached` + fingerprints (~591/~669)
- recenter walk + finalize: ~8290+ (WANT/STUB/MERGE phases, ahead lead)
- drain passes: build (~6939), loadwin (~6813), data (~6991), low-wave (~6809)
- light late-landing: ~5740 (per-slab), ~5872 (full-column)
- `godot/world/chunk.gd`: `light_settled`, `flush_slabs`, `hide_all_high`
  (unchanged, from 7f1888d)

## 7. Gates & baselines (83cfcfe — re-run after the redesign)
- `HOME=/tmp/dsh_home AWECRAFT_LOGIC=lightstate AWECRAFT_LS_RADIUS=16
  timeout N /home/angrygiant/tools/godot/godot --headless --path godot`
  → hole_slabs_now **1776**, demoted **48**, double_lod 0, wash false,
  settle 2400, hole_traj **[281,0,0,0,0]** (final sample 0)
- r16 → ok=true, lost 0/0, far census 1282/199/100 (re-baselined by design)
- ladder → boundary_flip_n **126**; meshprobe → match_rate **1.0**
- battery: `HOME=/tmp/dsh_home bash .scratch/run_battery.sh .scratch/<out>`
  → compare vs `.scratch/percol_battery` (7f1888d baseline): expect ~23/31
  byte-identical + ~8 timing-jitter; wallshot = PRE-EXISTING hang at
  "MSG Flying" (baseline d99ffee hangs too) — not a regression signal
- **INFRA TRAPS**: headless ALWAYS `HOME=/tmp/dsh_home` + absolute godot
  path (real HOME = engine segfault on user:// dir); `./build_windows.sh`
  with REAL HOME; `:8080` authoritative (serves from disk, auto-picks new
  builds); push `GIT_SSH_COMMAND="ssh -F /dev/null" git push`; a git
  worktree of a past commit lacks the untracked `godot/bin/libchunkio.so`
  (copy from main tree) or headless parse fails; harness.gd must stay
  pristine (temp measurement arms in + out).

## 8. Tolerated behaviors (no action)
far-census re-baseline per window change; stragglers 5-8; loh 0-4 jitter;
spawn ground hidden until first flush; genhash NO_RESULT; wallshot hang
(pre-existing since Aug 22); 0 pick during pure flight.

## 9. Do NOT commit
`.scratch/`, `.tmp_ac0247/`, `docs/halo-loot-brainstorm.html`,
`references/`, `tasks/AC-0092/`, `tasks/AC-0125/plan.html`,
`tasks/AC-0140/`, other untracked `tasks/AC-01xx/` dirs.
