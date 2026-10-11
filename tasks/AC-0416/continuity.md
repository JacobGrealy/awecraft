## RUN - 2026-10-10 18:33 UTC - AC-0416

- subagent started; reading spec + read-first docs

## Resume point
- FIX IS IN and verified. Only delivery remains: results page + final report + (coordinator) heavy gates.
- Files changed: `godot/world/world.gd` (`_ring_rebuild_sector` — the fix), `godot/scenes/harness.gd`
  (the `farhigh` standing arm, calibrated), `tasks/harness_data.yaml` (the farhigh row),
  `godot/ARCHITECTURE.md` (AC-0338 ring bullet: flat → column-facet), `tasks/AC-0416/plan.html`
  (measured-first block filled). Captures in `tasks/AC-0416/captures/`. Logs in `.scratch/AC-0416/`.

## Chronology
- MEASURED FIRST (per the ticket's top instruction): built + calibrated the `farhigh` standing arm
  (3 legs: home battery / live ring mesh / satellite body), then re-measured on the current tree.
  DEFECT IS LIVE. Pre-fix baseline saved: `.scratch/AC-0416/farhigh-PREFIX-baseline.log` +
  `farhigh-PREFIX-result.json` (the canonical pre-fix numbers — the ticket's regression proof).
  Pre-fix: leg 2 = 3 cols / 360 verts all FLAT (none on the facet); leg 1 flat_max 519 m tracking the
  sagitta (16 m @ 358 confirmed); ring census ms 17.612 / max 0.769.
- Pre-fix render → `tasks/AC-0416/captures/ac0416-before.png` (Vulkan Forward+ llvmpipe, alt 300,
  R24, FOG 83, time 0.30, seed 44, 1280x720, body LOADED). Pre-fix genhash baseline 25/25.
- IMPLEMENTED the fix in `world.gd` `_ring_rebuild_sector`: per column `T = SphereMath.column_transform(cx, cz, Game.planet_R)`,
  `Mn = T.basis.inverse().transposed()`; vertices `T * Vector3(v.x, si*16+v.y, v.z)`; normals
  `(Mn * n).normalized()`; water vertices + normals the same. T/Mn computed once per column. No C++ change.
  Deviation from the ticket's `flat_to_world` form (stated): `flat_to_world` would put a `v.x==16`
  boundary vertex on the NEIGHBOUR column's facet; the fix uses the slab's OWN column (the high-tier
  convention) so the far/high edges stay coincident.
- Post-fix `farhigh`: ok=True. Leg 2 = 3 cols / 360 verts all FACET, max_dev 0.0 (the ring now sits on
  the facet). Leg 1 env_bad 0, flat_max 519 (counterfactual sagitta, kept by design). Leg 3 unchanged.
  Ring census (per-vertex cost, MEASURED not assumed): ms 17.612 → 24.967 (+42%), max 0.769 → 1.21 (+57%).
- G0 census on the post-fix farhigh log: 0 SCRIPT / 0 SHADER ERROR, rc 0.
- Post-fix genhash: 25/25, BYTE-IDENTICAL to pre-fix (the fix is placement-only — no voxel-data drift).
- Smoke battery `player;interact;light;fluids;genhash`: ok=true. Probes: farab ok (h_mismatch 0),
  meshprobe ok, ladder ok, halo ok, lightstate healthy (low_on_high_n 0, wash false, worst null).
  Boundary r4 self-check: ok=True (p95 35 ms, crossing-frame p95 37 ms).
- Post-fix render → `tasks/AC-0416/captures/ac0416-after.png` (same recipe). A/B pixel diff is
  DETERMINISTIC (after vs after-rerun, same recipe = 0 px): 4525 px, max_delta 134, all at the nadir
  far-tier slab (bbox x536-806 y610-719); the hazy upper band is the satellite body (unchanged).
  Nadir crops `ac0416-{before,after}-nadir.png` show the far-tier slab proud→integrated. No-seam: the
  far tier now rides the SAME facet as the near tier (leg 2 max_dev 0.0); the AC-0415 wall band is intact.
- Docs: harness_data.yaml farhigh row updated (leg 3 `body_fit_max`/`body_excess`; BATTSKIP = the arm
  quits the process), `harness_doc.py --render` + `--check` in sync; ARCHITECTURE.md AC-0338 ring bullet
  flat → column-facet; plan.html measured-first block filled.
