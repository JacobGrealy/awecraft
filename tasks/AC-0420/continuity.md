## RUN - 2026-10-11 15:22 EDT - AC-0420

### Journal (append-only)

- **Plan**: `plan.html`. Temp probe arm `ac0420probe` added to harness.gd (in+out same task).
- **Item 2 (idle slide)** — measured BEFORE: 21.2–21.6 mm/s flat rate on natural terrain
  (steady 26.7–27.1), exactly (−0.707,−0.707) downhill; 0.0 on all three flat-pad spots.
  Per-frame mechanism reconstructed: slide removal = (v·n̂)n̂ with n̂ the EXACT radial
  (0.0000° off); floor colliders are per-slab StaticBody3D/ConcavePolygonShape3D whose faces
  are per-cell 1 m down-wound (n.y<0) triangles, double-sided in physics (ray-confirmed);
  on 1-block steps the gravity tangential component bleeds through step contacts at
  steady v = G·sinθ/k (k=12 walk lerp) = the measured rate; on a large flat pad (no step
  side-contacts) the bleed is 0 (matches). Fix: player.gd post-`move_and_slide()` guard —
  grounded + no input + <0.2 m/s → zero the tangential part of the POST-slide velocity.
  (v1 bug: rebuilding from pre-slide vloc re-injected the gravity y-impulse each frame;
  fixed by using the post-slide velocity.) AFTER: 0.0 mm/s, 0.0 mm drift, ≤6.8e-5 m/s at
  all five spots.
- **Item 1 (cracks)** — measured: geometry is NOT a gap (across-edge −1.61 mm = the
  AC-0398 double coverage; along-edge 0.0; radial V 0.01–0.02 mm). Vertex-colour Δ across
  seams up to [0.502, 0.0, 0.545] (per-vertex light bake steps per chunk) + depth Δz
  3/12/48/107/191 mm at 50/100/200/300/400 m vs the 1.6 mm overlap (z-fight band beyond
  ~50 m). Visual: seam lines visible at 8 m (captures/probe-close2.png) and the full 16 m
  grid at 100 m (probe-t100.png). No fix applied — options A (seam lighting continuity,
  architectural, follow-up ticket) / B (near plane + polygon offset) / C (keep grout, kill
  flicker) documented in results.html for the coordinator.
- **Item 3 (LOD die-off)** — per-tier table (R24/F83 wall 332, low_start clamped 16):
  tier0 stop 332.0 / A 321.4 / B 296.6 / C 181.4 m altitude (C 90 % fogged at 81.6 m; C
  outer ring 272–400 m never drawn, already past the wall at ground level). Answer: the
  coarse/distant tiers (LOD 2/3) cross the SHARED 332 m discard wall first as altitude
  rises — by construction. BUG FOUND + FIXED: `_ac0401_push` was change-gated on the wall
  value only, but chunk ShaderMaterials are built lazily after the first push → never
  updated → shader default 332.0 (invisible at R24/F83 where wall==332; fatal at any other
  render distance, e.g. R50 wall 714 → die-off pinned at 332). Fix: gate also on the
  material-set size (`ChunkScript._mat_cache` + fluid mats). Render proof: pre-fix audit
  chunk_lit_opaque/cutout/flower = never set (probe-render-r50.log), post-fix all six mats
  = wall 69.6, mats_off_wall [] (probe-render-r50-postfix2.log, EXIT=0).
- **Shots**: player-camera shots via the temp arm's AWECRAFT_PROBE_SHOTS (frozen observer,
  the planet-preset mechanism) + nadir-aim prefill. Streaming settles at ~165 built
  chunks (full-detail core ~100 m) for a stationary frozen player; the LOD rings render
  beyond that (visible in probe-t200nfog.png). AWECRAFT_TM_HO=64 / GEN_BUDGET don't move
  the steady state (residency cap, not a throughput cap). Shot list in results.html.
- **One stochastic UAF hit**: first post-fix render run = clean log + SIGSEGV at
  world.gd:5426 (star poll, the AC-0403 signature); immediate re-run clean (EXIT=0).
  Unrelated to AC-0420 changes; all headless runs clean.
- **Gates (pristine, temp arm removed — harness.gd back to 35,391 lines, zero _ac0420
  residue)**: G0 EXIT=0 0/0; SMOKE player;interact;light;fluids;genhash all ok (genhash
  25/25 byte-identical); meshprobe ac0211_ok; spherewalk ok; boundary r4 ok (built_final
  68, burst_p95 6932 ms). Logs: .scratch/AC-0420/*-pristine.log.
- **Deliverables**: `AC-0420-results.html`, `captures/` (12 PNGs). Files changed:
  player.gd (idle guard), world.gd (_ac0401_push gate). Fences held: no
  main.gd/game.gd/drop.gd/debug.gd edits, no commits/pushes, no TASKS.yaml hand edits.
- **Resume point**: builder work COMPLETE. Remaining: coordinator heavy gates + closeout
  (awecraft-closeout: docs sync check — no architectural change owed; commit + push;
  TASKS.yaml status via tasks.py). Open follow-ups suggested in results.html: item-1
  lighting-continuity ticket (A/B/C decision); far-edge flight fade design call.

