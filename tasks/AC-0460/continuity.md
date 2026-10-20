## RUN — Tue Oct 20 11:02:37 EDT 2026 — AC-0460

LANDED (stage 1, 2026-10-20): chunk.gd `Chunk.warped_chunks` static counter (incremented once per
build inside `_warp_face_slabs` past the face-lane guard; flag-off path never touches it); ONE
harness arm `warpcensus` (dispatch branch + `_warpcensus_test`: boot at spawn, player stood at the
home/face boundary flat (hw-8, 0), recenter, 240 bounded frames, census = warp flag, resident
face-chunk count, `Chunk.warped_chunks` (read via `load("res://world/chunk.gd")` — no class_name),
first meshed face chunk's raw mesh-AABB centre vs SphereMath.uv_to_world expected world centre,
aabb_delta_m); `tasks/harness_data.yaml` warpcensus row + harness_doc.py --render (in sync).
main.gd needed NO edit — the per-arm dispatch lives in harness.gd only (main.gd routes every arm
through harness.run; neighbours like ac0423probe do not appear in main.gd either).
GATES (2026-10-20): flag-OFF light set (rev 1: g0 r2 + smoke player/interact/light/fluids + genhash +
ac0423probe + warpcensus): every arm rc=0, SCRIPT=0/SHADER=0; warpcensus warped_chunks=0,
face_chunks=72, aabb_delta_m=3099.39 (raw local-frame control, large by construction),
frames=240, ok=true. genhash 25/25 identical to .scratch/AC-0461-gates/genhash-r2.log; ac0423probe
RESULT byte-equal to tasks/AC-0433/captures/ac0423probe-r2.log excl ms (BOTH flag states).
Flag-ON set (rev 2, --env AWECRAFT_WARP=1): same rc/SCRIPT/SHADER; warpcensus warped_chunks=78>0,
face_chunks=72, aabb_center=[2862.65,-1206.76,17.78] vs expected [2862.9,-1206.52,17.57],
aabb_delta_m=0.4 <= 120, frames=240, ok=true. harness_doc.py --check exit 0 (in sync: modes,
standing-values). interact place_ok flake documented (deviation 4). Render A/B: first pair invalid
(death screens — AIM env takes FLAT coords, deviation 6); the valid pair uses flat AIM +
AWECRAFT_NOCLIP=1 (existing hooks).
OUTCOME (stage 1, 2026-10-20): DELIVERED. The AC-0458 warp is provably applied to real face
chunks in a live world: warpcensus flag-OFF control warped_chunks=0 / aabb_delta_m=3099.39
(local-frame AABB, large by construction) vs flag-ON warped_chunks=78 / aabb_delta_m=0.4
(AABB in world space, 0.4 m from the SphereMath expected chunk centre) at 240 bounded frames,
72 resident face chunks, first chunk 4:63:0 (both states). §3.3 render A/B composable with
existing hooks (AWECRAFT_SNAPSHOT + AWECRAFT_AIM flat coords + AWECRAFT_NOCLIP=1): the pair
differs (md5) with coherent images = the plan's pass condition, but at the rasterization-noise
floor (max per-pixel 2/765) because the warp re-expresses the AC-0433 face_chunk_transform
placement to sub-pixel precision at R=4000 — confirmatory, the census is the proof (deviations
6/7/8). genhash 25/25 (flag-insensitive, == AC-0461 ref); ac0423probe == AC-0433 ref excl ms
(both flags); harness_doc --check exit 0. Findings owed upstream: the boundary light_at/
compute_light_split script-error class under the live renderer (deviation 7) and the interact
place_ok input-timing flake (deviation 4). No git actions, no TASKS.yaml, no new tickets.

## Coordinator triage — AC-0460 stage 1 (the proof)
- THE OBLIGATION FROM AC-0461 IS CLOSED, in numbers rather than pixels. Independent rerun of the arm by the coordinator, both flag states, rc=0 with SCRIPT=0/SHADER=0, RESULT identical to the builder's:
  - flag OFF: warped_chunks = 0 (control), first face chunk 4:63:0, mesh AABB centre (8.0, 0.0, 8.0) — the legacy chunk-local frame, aabb_delta_m 3099.39 from the true world position.
  - flag ON: warped_chunks = 78, same chunk, mesh AABB centre (2862.65, -1206.76, 17.78) against expected (2862.9, -1206.52, 17.57) — aabb_delta_m 0.4 m. World space, confirmed.
  So the warp reaches the world: 78 face chunks really are built with pointwise world-space vertices, and the flag-off control proves the counter cannot lie.
- The pixel A/B differed but only at the rasterisation-noise floor (max per-pixel 2/765), which is consistent rather than disappointing: a ~2 m displacement at 2 km altitude is sub-pixel. The census is the proof; the pixels are the sanity check. The builder also caught that its FIRST A/B pair was two death screens because AWECRAFT_AIM takes FLAT coordinates, not world — it reported that as invalid rather than passing it.
- FINDING OWED UPSTREAM, not caused by this ticket and not fixed here: recurring `light_at` / `compute_light_split` script errors at the boundary under the LIVE renderer, 0 under the headless arm. That is a lighting-path report for a separate ticket, recorded so it is not lost.
- AC-0460 STAYS OPEN: this is stage 1 (proof). The single-lane rewrite — one dispatch/landing contract for both lanes, carrying the AC-0433 P0.5 landing-order fix — is stage 2 and needs its own plan.

## Coordinator boundary-shot investigation (round 10)
- PURPOSE: settle the lighting finding from stage 1 before any lane rewrite — if AWECRAFT_WARP caused script errors, flipping the flag on would ship them.
- RAN the boundary recipe myself (AWECRAFT_AIM="3133,60,0,0,-0.4", NOCLIP, R=4, drain 300, 1280x720, lavapipe) with the flag OFF and ON. RESULT: rc=0 both, **SCRIPT ERROR 0 / SHADER ERROR 0 in BOTH** (gate_census). So the `sky`/`light_at` errors the builder saw are SHOT-SPECIFIC and not caused by the warp; the flag does not introduce script errors at the boundary in this configuration.
- The two frames differ (different md5) but are visually identical apart from rasterisation noise, consistent with the census result: the warp's ~2 m displacement is sub-pixel at this scale.
- NEW DEFECT FOUND AND FILED: a large pure-black unlit block in the lower right of the frame, present IDENTICALLY with the flag on and off — so it is pre-existing and player-visible at the boundary, not part of this migration. Filed as **AC-0464** with both captures, the exact recipe, and the note that the first step is to identify WHAT the object is (the AC-0440/AC-0443 projection method), not to guess at the shader.
- Consequence for this ticket: stage 2 (the single streaming lane) is NOT blocked by a warp-induced lighting defect, and the flag remains safe to develop against. The unlit block is a separate queue item.

## Coordinator audit — what reads a face chunk's node transform (round 11)
- QUESTION: the AC-0458 warp sets the chunk node to identity, so anything that read the node transform for face chunks would break. Before restoring occluders or considering the flag default, the consumers had to be enumerated, not assumed.
- FINDING: `SphereMath.face_chunk_transform` has exactly ONE production caller — world.gd:15363 (`c.transform = SphereMath.face_chunk_transform(...)`) — and every other call site is a harness arm. `_col_sphere_transform` (the home lane) is the same story at world.gd:11412. Greps for `.transform` / `global_transform` / `.position` filtered to chunk/col/face found only that write, a debug overlay at world.gd:4604 and a comment at 1816 — i.e. NO production reader of a face chunk's node transform. Godot's own parenting is the only consumer, and the warp already compensates (identity node + world-space vertices).
- CONSEQUENCE: flipping the default is much lower risk than it looked. The remaining exposures are (a) occlusion culling, which AC-0461 disabled under the warp — addressed by this stage, and (b) consumers that use legacy COORDINATE maths rather than node transforms, whose error is bounded by the M1 measurement (centimetres at h=0, up to ~2 m at h=140).
- This audit is the reason stage 2a is small: the work is restoring a feature, not unwinding hidden coupling.

## RUN — 2026-10-20 16:18 UTC — AC-0460 stage 2a (occluder from warped AABB)
- Started. Reading anchors in chunk.gd; plan is tasks/AC-0460/plan.html.
- LANDED (stage 2a, 2026-10-20): chunk.gd `_assemble_slab` occluder block — the flag-OFF branch is
  byte-identical (git diff: only the stale AC-0461 comment above it changed); the new
  `elif full_solid and _occl_enabled() and _warp_on` branch builds the occluder from the slab's
  own world-space mesh AABB (`s.mesh_instance.mesh.get_aabb()`, world-space under the identity
  node): BoxOccluder3D size = the AABB size, OccluderInstance3D position = `aabb.get_center()`
  (the child's position IS the world centre). Guard: empty mesh or any AABB axis <= 0.01 leaves
  `s.occluder = null` (no zero-volume occluder). New probe `tasks/AC-0460/occ_probe.gd` (pure
  SphereMath, the AC-0433 probe style, absolute `--script` path). ONE field added to the
  warpcensus RESULT (`occluders` = face chunks' non-null slab occluders) + its harness_data row;
  harness_doc.py --render + --check in sync. No other files touched.
- GATES (stage 2a, 2026-10-20, all on the FINAL tree; logs in .scratch/AC-0460-gates/):
  - Flag-OFF light set (r8, gate_run g0,smoke,ac0423probe,warpcensus, timeout 600): every arm
    rc=0, SCRIPT=0/SHADER=0; genhash 25/25; ac0423probe == tasks/AC-0433/captures/ac0423probe-r2.log
    excl ms; warpcensus warp=0, warped_chunks=0, face_chunks=72, aabb_center [8,0,8],
    aabb_delta_m=3099.39, occluders=0 (headless-gated), ok=true — the stage-1 standing values
    reproduced. interact place_ok=false (the documented stage-1 flake, arm ok=true).
  - Flag-ON light set (r7, same + --env AWECRAFT_WARP=1): same rc/SCRIPT/SHADER; genhash 25/25;
    ac0423probe == capture excl ms; warpcensus warp=1, warped_chunks=78, face_chunks=72,
    aabb_center [2862.65,-1206.76,17.78] vs expected [2862.9,-1206.52,17.57], aabb_delta_m=0.4,
    occluders=0 (headless-gated), ok=true.
  - Render-recipe evidence (xvfb-run + Forward+/lavapipe, the AC-0391 recipe; boot line asserts
    Forward+): warpcensus flag-ON (warpcensus-xvfb-on2.log, FINAL code) rc=0, SCRIPT=0,
    warped_chunks=78, **occluders=89 > 0** — the new branch executes at runtime and 89 face-slab
    occluders are created from their own warped mesh AABBs; flag-OFF pair (warpcensus-xvfb-off.log;
    its flag-OFF path is byte-identical in the final tree) rc=0, SCRIPT=0, occluders=335 (legacy
    constant boxes on every full-solid face slab, incl. buried ones with empty opaque mesh — see
    deviation 11), warped_chunks=0, aabb_delta_m=3099.39.
  - Probe (occ_probe-r7.log; rc=0, gate_census 0/0): chunk 4:63:0 (face 4, mirrored, R=4000 from
    Game.planet_R). Corner cloud of the full 16x384x16 local column: min [2828.32,-1241.95,0]
    max [3175.1,-900.04,38.96]. All 24 slab-derived occluder CENTRES inside that cloud (the plan's
    centre assertion holds). Sizes: z axis 35.69-38.96 m (inside [1,40]); x 80.26-86.57, y
    81.69-88.16 m (worst 86.57/88.16) — OUTSIDE the plan's [1,40] band on x/y for every slab:
    ok=false, 48 size-band fails, an HONEST deviation (deviation 9 — the face lane's documented
    49-98 m chunk scale, sphere_math.gd:470-487; the warp re-expresses that legacy scale).
    Guard predicate negative test passes (degenerate_rejected=true). legacy_offset_m=3105.51 —
    where the legacy constant box (local (8,y0+8,8)) would sit under the identity node: ~3.1 km
    from the derived centre; the number that made AC-0461 disable occluders under the warp.
  - harness_doc.py --check: exit 0 (in sync: modes, standing-values) after --render.
- OUTCOME (stage 2a, 2026-10-20): DELIVERED with one honest gate deviation. Under the warp a
  solid slab again carries an occluder built from its own world-space bounds (xvfb: 89 occluders,
  0 script errors; probe: centres inside the corner cloud, guard verified); with the flag off
  nothing changes (byte-identical branch, standing values reproduced incl. warped_chunks 0,
  aabb_delta_m 3099.39, genhash 25/25, ac0423probe byte-equal excl ms). The probe's plan size
  band [1,40] m x/y is not met (derived 80.3-88.2 m) because a face-lane chunk is a documented
  49-98 m world footprint (1 local unit = 1 chart cell = 6.14 m arc at R=4000) — deviation 9;
  the band needs a coordinator re-scope, not a builder loosening. occluders is structurally 0 in
  the headless light set (DisplayServer gate, chunk.gd:453-456) — the render-recipe runs carry
  the field's evidence (deviation 10). No git actions, no TASKS.yaml, no new tickets.

## Coordinator triage — stage 2a (warped occluder)
- CODE: flag-off branch byte-identical; under the warp the occluder is now a BoxOccluder3D sized from the slab's own world-space mesh AABB with the OccluderInstance3D at the AABB centre, and degenerate/empty AABBs leave `s.occluder = null`. Independently rerun: the probe is green after MY correction below.
- MY PLAN'S BAND WAS WRONG (third plan-level error the builders have caught in this series, and the second mine in two tickets): I asserted an occluder axis size in [1, 40] m. A face chunk is 16 cells at ~6.14 m of arc = a documented 49-98 m footprint (sphere_math.gd:470-487), so the measured 80-88 m horizontal and 36-39 m vertical boxes are CORRECT. The builder reported red rather than loosening the band, which is exactly the behaviour the fence asks for. Fixed by the coordinator in tasks/AC-0460/occ_probe.gd: the two largest axes must be in [16, 110] m and the smallest in [1, 128] m, both derived from the documented footprint; rerun rc=0, census 0/0, ok=true, worst horizontal 86.57/88.16 m.
- REAL FINDING, not yet fixed: under the live renderer the warp path creates 89 occluders where the legacy path creates 335. The cause is structural, not sloppy: legacy gave a full-solid slab an occluder whether or not it had a mesh, while the warp path can only derive the box FROM a mesh, so fully-buried mesh-less full-solid slabs fall to the guard and lose theirs. That is a ~73% reduction in occlusion coverage in warp mode — a perf caveat that must be closed before the flag default is considered, by deriving the box for a mesh-less full-solid slab from its cell footprint instead of skipping it.
- Occluder counting is structurally 0 headless (DisplayServer gate), so this evidence necessarily comes from the xvfb runs; noted so nobody "fixes" a zero again.

## RUN — 2026-10-20 13:44 EDT — AC-0460 stage 2b (footprint fallback for mesh-less slabs)
- Started. Reading anchors: chunk.gd warp branch (1482-1511), _warp_face_slabs (1733-1752), Slab (417), probe occ_probe.gd (stage-2a band assertions 62-88). Plan = tasks/AC-0460/plan.html §4/§5/§6.
- LANDED (stage 2b, 2026-10-20): godot/world/chunk.gd — (1) `_assemble_slab` warp branch: a
  full-solid slab whose mesh AABB is missing or degenerate now falls back to a box from the
  slab's own cell footprint (`_warp_slab_footprint_aabb`: the 16x16 corner lattice at h = y0 and
  h = y0 + 16, 4 edges x 17 cell-step points x both heights = 136 samples, same degenerate guard
  on the result) — face-lane (face >= 2) only, the home pair keeps stage-2a behaviour (deviation
  14); flag-off branch untouched. (2) The warp construction EXTRACTED from `_warp_face_slabs`'
  loop body into `_warp_cell_point` (same arithmetic, same order — no second copy of the chart
  inverse); the loop calls it. tasks/AC-0460/occ_probe.gd — stage-2b fallback assertions added
  (plan §5): fallback box centre inside the corner cloud, sizes in the same [16,110]/[1,128] m
  bands, fallback-vs-mesh (8-corner) centre agreement <= 60 m; every existing assertion and the
  guard negative control kept. No other files touched.
- GATES (stage 2b, 2026-10-20, FINAL tree; logs .scratch/AC-0460-gates/):
  - Flag-OFF light set (r9, gate_run g0,smoke,ac0423probe,warpcensus): every arm rc=0,
    SCRIPT=0/SHADER=0, ok=true; genhash 25 GENHASH lines byte-identical to the stage-2a
    reference (genhash-r8.log); ac0423probe equal to tasks/AC-0433/captures/ac0423probe-r2.log
    excl ms; warpcensus warp=0, warped_chunks=0, aabb_delta_m=3099.39, occluders=0 (headless) —
    stage-1 standing values reproduced. interact place_ok=false (documented flake, deviation 16).
  - Flag-ON light set (r10, same + AWECRAFT_WARP=1): same rc/SCRIPT/SHADER; warpcensus warp=1,
    warped_chunks=78, aabb_center [2862.65,-1206.76,17.78], aabb_delta_m=0.4 (bit-identical to
    stage 2a through the helper extraction), occluders=0 (headless-gated).
  - Render recipe, flag ON — THE GATE THAT MATTERS (warpcensus-xvfb-on3.log; xvfb-run -a +
    VK_ICD_FILENAMES lvp_icd.json + --rendering-driver vulkan, boot line asserts Forward+):
    rc=0, SCRIPT=0/SHADER=0, warped_chunks=78, aabb_delta_m=0.4, **occluders=335** — parity with
    the legacy 335 (warpcensus-xvfb-off.log, stage 2a); target >= 300 MET (stage 2a was 89).
  - Probe (occ_probe-r8.log; rc=0, gate_census 0/0): ok=true, fails=[]; fallback worst size
    [86.57, 88.16, 38.96] m (same bands as the mesh-derived boxes), worst
    fallback-vs-mesh centre delta 0.0 m; degenerate_rejected=true (negative control firing);
    chunk cloud + 24 slab centres/bands as before.
- OUTCOME (stage 2b, 2026-10-20): DELIVERED, all four gates green, no red. Under the warp a
  mesh-less full-solid slab again gets an occluder — the live-renderer count is 335 vs 335
  legacy (the stage-2a 89 is closed), derived from the slab's own warped cell footprint through
  the SAME construction the mesh uses (the mapping now lives in one helper). The probe proves
  the fallback box describes the same slab (centre delta 0.0 m, inside the cloud, in the
  documented bands) and the guard still rejects degenerate boxes. Flag off: nothing changes
  (genhash 25/25 identical, ac0423probe byte-equal excl ms, standing values reproduced). No git
  actions, no TASKS.yaml, no new tickets.

## Coordinator triage — stage 2b (occluder coverage)
- INDEPENDENTLY VERIFIED, because it is the claim that unblocks the flag default: coordinator-run xvfb warpcensus with the flag on gives **occluders 335, warped_chunks 78**, rc=0, SCRIPT/SHADER 0/0 — exact parity with the legacy 335 and recovery from the 89 that stage 2a shipped.
- Probe: ok=true, fallback box worst size 86.57 x 88.16 x 38.96 m (inside the documented bands), centre inside the cloud, and the fallback-vs-mesh centre delta is 0.0 m — i.e. the footprint fallback lands on the same slab as the mesh-derived box rather than approximating it loosely.
- The warp mapping is now a shared helper (_warp_cell_point extracted from _warp_face_slabs) used by both the mesh warp and the footprint fallback, so there is one chart inverse in the file, not two that could drift. Deviation 14 is honest and bounded: the home pair (face<2) keeps the stage-2a null behaviour because the warp never applies there; the occluder census counts face chunks so the gate is unaffected.
- Cost: one extra GDScript call per vertex in the warp pass (deviation 15). No p95 was measured because the plan named none — that measurement belongs with the flag-default decision, not here.
- STATE: warp mode is now feature-equivalent to the legacy path for occlusion, collision, light, and geometry space, with seams fixed. The flag default is the next decision and it needs perf evidence (frame time with the warp on vs off), which this ticket has not produced.

## RUN — Tue Oct 20 14:18 EDT 2026 — AC-0460 stage 3 (warp cost measurement)
- Started. Anchors confirmed: chunk.gd statics @1730, _warp_face_slabs @1744-1760, _warp_cell_point @1770; harness.gd _warpcensus_test @35929-36008 (RESULT @36008); harness_data.yaml warpcensus row @768. Plan = tasks/AC-0460/plan.html (stage 3).
- LANDED (stage 3, 2026-10-20): chunk.gd — three statics beside warped_chunks (warp_us, warp_verts, warp_surfaces); _warp_face_slabs loop now times each surface's vertex loop (Time.get_ticks_usec() around the per-surface i-loop only, summed; nothing inside the per-vertex body) and accumulates. harness.gd _warpcensus_test — reset of the three accumulators at arm start (load() cached), and RESULT adds warp_ms_total, warp_verts, warp_us_per_vert, warp_ms_per_chunk; all existing fields unchanged. harness_data.yaml warpcensus row result_fields updated; harness_doc.py --render + --check in sync.
- GATES (stage 3, 2026-10-20, FINAL tree; logs .scratch/AC-0460-gates/):
  - Flag-OFF light set (r11, gate_run g0,smoke,ac0423probe,warpcensus): every arm rc=0,
    SCRIPT=0/SHADER=0, ok=true; warpcensus warp=0, warped_chunks=0, <b>the control:</b>
    warp_ms_total=0, warp_verts=0, warp_us_per_vert=0.0, warp_ms_per_chunk=0.0 (the cost
    fields read zero — the instrumentation sits inside the guarded path); face_chunks=72,
    aabb_delta_m=3099.39, first_chunk 4:63:0 (standing values reproduced); genhash 25/25
    byte-identical to the stage-2a reference (genhash-r8.log); ac0423probe equal to
    tasks/AC-0433/captures/ac0423probe-r2.log excl ms. interact place_ok=true (r11).
  - Flag-ON light set, RUN 1 (r12, same + AWECRAFT_WARP=1): every arm rc=0, 0/0, ok=true;
    warpcensus warp=1, warped_chunks=78 (UNCHANGED from stage 2b — the instrumentation
    changes no behaviour), aabb_center [2862.65,-1206.76,17.78] (bit-identical to stage 2b),
    aabb_delta_m=0.4, occluders=0 (headless-gated); MEASURED: warp_ms_total=687,
    warp_verts=560288, warp_us_per_vert=1.226, warp_ms_per_chunk=8.808. genhash 25/25;
    ac0423probe == capture excl ms. interact place_ok=false (documented flake).
  - Flag-ON light set, RUN 2 (r13): same rc/SCRIPT/SHADER; warped_chunks=78, aabb_delta_m=0.4
    (bit-identical to run 1); MEASURED: warp_ms_total=695, warp_verts=560248,
    warp_us_per_vert=1.24, warp_ms_per_chunk=8.91. genhash 25/25 (identical to run 1 and to
    the flag-OFF run — flag-insensitive); ac0423probe == capture excl ms. interact
    place_ok=false (documented flake, deviation 17).
  - VARIANCE (run 1 -> run 2): warp_ms_total 687 -> 695 (+1.2%); warp_ms_per_chunk
    8.808 -> 8.91 (+1.2%); warp_us_per_vert 1.226 -> 1.24 (+1.1%); warp_verts 560288 vs
    560248 (40 vertices, 0.007% — the face-lane build schedule at the frame-240 boundary;
    warped_chunks 78 in both). Well inside the plan's ~30% bar.
  - harness_doc.py --check: exit 0 (in sync: modes, standing-values) after --render.
- OUTCOME (stage 3, 2026-10-20): DELIVERED, all gates green, no red. The warp's cost,
  measured inside the warp pass across the 240-frame boundary run: ~690 ms total for 78
  warped chunks and ~560,200 vertices = ~8.9 ms/chunk, ~1.23 us/vertex (1.226-1.24 us
  across the two runs). Flag-off control: every cost field exactly 0 — the accumulators
  are unreachable without the flag (they sit in _warp_face_slabs, which build_mesh_face
  calls only when _warp_on). No change to what the warp computes: aabb_center/
  aabb_delta_m/warped_chunks/face_chunks bit-identical to stage 2b in both flag-ON runs;
  flag-OFF standing values reproduced (genhash 25/25 identical, ac0423probe byte-equal
  excl ms). Caveats per plan §7: the timing includes allocator noise (the loop allocates
  a Vector3 per vertex) and runs on this box's headless CPU, not the shipped platform;
  nothing was optimised — this ticket measures. Files: godot/world/chunk.gd (three
  statics + per-surface timing), godot/scenes/harness.gd (arm reset + 4 RESULT fields),
  tasks/harness_data.yaml (row result_fields; HARNESS.md re-rendered), continuity,
  deviations 17, results page Stage-3 section. No git actions, no TASKS.yaml, no new
  tickets.

## Coordinator triage — stage 3 (warp cost) — THE NUMBER CHANGES THE PLAN
- Independently reproduced: warped_chunks 78, warp_ms_total 689, warp_verts 560,248, warp_us_per_vert 1.231, warp_ms_per_chunk 8.833 — matching the builder's two runs (687/695, 1.2% variance) inside the 30% bar.
- THE FINDING: `World.FACE_STREAM_BUDGET_MS := 12.0` (world.gd:14990) is the whole per-pass budget for streaming face chunks. Warping ONE face chunk costs **8.8 ms — 73% of an entire streaming pass**, before the mesher's own work. In GDScript, at 1.23 us/vertex over ~7,200 vertices per 98 m chunk, the warp as implemented would cut face-streaming throughput to roughly one chunk per pass and put an 8.8 ms hitch on the frame that builds it. On the Windows target it will not be better.
- CONCLUSION, stated plainly: **the warp is correct and feature-equivalent (seams 0, occluders 335/335, collision/light in world space) but NOT shippable on the streaming path as written.** The flag must stay off. This is the migration's real engineering problem, and no amount of further correctness work changes it.
- THE FIX DIRECTION (this ticket's next stage): move the warp into the native lane. The mesher is already C++ (gdext/src/mesh.cpp) and builds the vertex arrays there, so warping in the same pass costs a handful of trig ops per vertex in optimised native code instead of a GDScript loop with per-vertex Vector3 allocations. Expected to fall from ~1.2 us to ~0.02-0.05 us per vertex; that must be measured, not assumed.
- Cost control recorded: the timing includes allocator noise (per-vertex Vector3 alloc), and it is headless-CPU — both stated in the ticket's deviations, so nobody later mistakes 8.8 ms for a GPU number.
## RUN — Tue Oct 20 14:41:13 EDT 2026 — AC-0460 stage 4 (native warp)
- LANDED (stage 4, 2026-10-20): gdext/src/mesh.cpp — AweMesh::warp_face_verts
  (PackedVector3Array, int face, int ccx, int ccz, double R) at the class tail + its
  bind_method (beside slab_boundary_air): the drop-in native of the AC-0458 vertex warp in
  doubles — continuous mirror inverse (non-mirror u1024 = ccx*16 + lx, mirror
  u1024 = ccx*16 + 16 - lx), v1024 = ccz*16 + lz, world = (R + ly) * normalize(sm_uv_to_world)
  - (0, R, 0); reuses sm_uv_to_world / sm_face_mirror_x (READ ONLY, per plan §3). Plan said
  "static"; godot-cpp cannot bind a static member (deviation 18) — stateless non-static,
  identical signature/call shape. godot/world/chunk.gd _warp_face_slabs — per-surface dispatch:
  native call when AweMesh exposes warp_face_verts (mc.has_method), GDScript loop as the
  fallback (stale .so degrades, does not crash); the stage-3 cost statics (warp_us /
  warp_verts / warp_surfaces) wrap whichever path runs. New probe
  tasks/AC-0460/native_parity_probe.gd (faces 2..11, both mirror classes, 2000 LCG verts per
  chunk, existence assertion, same-size contract, negative control). Build: rc=0,
  6.9 s incremental (mesh.cpp recompile + relink; the plan's ~24 s estimate was for a colder
  build), .so copied gdext/bin -> godot/bin (deviation 21).
- GATES (stage 4, 2026-10-20; logs .scratch/AC-0460-gates/):
  - Flag-OFF light set (rev 15, g0,smoke,ac0423probe,warpcensus, timeout 600): every arm
    rc=0, SCRIPT=0/SHADER=0, ok=true; genhash 25/25; ac0423probe ok; warpcensus warp=0,
    warped_chunks=0, face_chunks=72, aabb_delta_m=3099.39, first_chunk 4:63:0 (standing
    values reproduced) and the CONTROL: warp_ms_total=0, warp_verts=0, warp_us_per_vert=0.0,
    warp_ms_per_chunk=0.0 (cost fields stay 0 — the instrumentation sits inside the guarded
    path). interact place_ok=false (the documented flake).
  - Parity probe (parity-r1.log; rc=0, gate_census 0/0): ok=FALSE (a FINDING, not a build
    defect), chunks=10, verts=20000, negative_detected=true, R=4000 (Game.planet_R),
    max_parity_m=2736.2021 — the FACE-11 pre-existing C++ chart bug (deviation 19;
    parity-perface-r1.log: faces 2-10 all <= 1.0e-3 m, face 11 = 2736.2021). The plan's
    1e-4 bound is unreachable at R=4000 for float32-stored outputs (deviation 20). The
    existence assertion and same-size contract PASSED (the method is there; the .so is
    fresh) — the probe failed on the numbers, exactly the behaviour plan §8 risk 2 wants.
  - Flag-ON light set, RUN 1 (flagon-run1.log, rev 16 arms): every arm rc=0, 0/0, ok=true;
    warped_chunks=78 UNCHANGED, aabb_center [2862.65,-1206.76,17.78] + aabb_delta_m=0.4
    (bit-identical to stages 2b/3 — the native path changes no geometry at this boundary),
    genhash 25/25; MEASURED: warp_ms_total=34, warp_verts=560288, warp_ms_per_chunk=0.436,
    warp_us_per_vert=0.062 vs stage 3's 8.833 / 1.231 => 20.3x per chunk / 19.9x per vertex.
  - Flag-ON light set, RUN 2 (flagon-run2.log): same rc/SCRIPT/SHADER/ok; warped_chunks=78,
    aabb bit-identical to run 1; warp_ms_total=33, warp_verts=560248, warp_ms_per_chunk=0.423,
    warp_us_per_vert=0.058 => 20.9x / 21.2x. run1->run2 variance: +3% per chunk, +6.9% per
    vertex, 40 verts (0.007% — the same frame-240 schedule effect as stage 3). Well inside
    the plan's ~30% bar and 4x past the 5x target.
- OUTCOME (stage 4, 2026-10-20): the warp is now NATIVE and ~20x faster
  (0.436 / 0.423 ms per chunk vs 8.833; 0.062 / 0.058 us per vertex vs 1.231) — 27% of the
  12 ms FACE_STREAM_BUDGET_MS at stage 3 becomes ~4%: the cost objection to the flag is
  answered. Geometry at the boundary is bit-identical to the validated stages (aabb_center /
  aabb_delta_m / warped_chunks unchanged in both flag-ON runs; flag-OFF untouched). RED on
  the parity gate, reported plainly: (1) face 11 disagrees by 2736.2 m because of a
  PRE-EXISTING bug in the C++ header's face table (no case 11 — the C++ gen lane's face-11
  placement has been on the wrong half of the -Z face since AC-0423; deviation 19); (2) the
  1e-4 bound is below the float32 storage floor at R=4000 (deviation 20) — faces 2-10 sit
  at <= 1.0e-3 m, the expected float32-vs-double noise. Neither is a defect of this stage's
  code: the warp reuses the header exactly and the probe's job (fail loudly, never silently)
  worked. Next: the coordinator re-scopes the parity bound and decides the face-11 fix
  (one line in sphere_math_cpp.h, with its C++ gen-lane consequence), then the flag default.
  Files: gdext/src/mesh.cpp, godot/world/chunk.gd, tasks/AC-0460/native_parity_probe.gd,
  continuity, deviations 18-21, results page Stage-4 section. No git actions, no
  TASKS.yaml, no new tickets. godot/bin/libchunkio.so is a build output — never committed.

## Coordinator triage — stage 4 (native warp) — AND A REAL BUG FOUND
- COST SOLVED: native warp measured at 0.423 ms/chunk / 0.059 us/vert (stage 3 GDScript: 8.833 / 1.231) — 20.9x. Coordinator reran it twice: identical 0.423 / 0.059 / 33 ms total. Against FACE_STREAM_BUDGET_MS 12.0 the warp is now ~3.5% of a streaming pass instead of 73%, so the cost objection to shipping it is gone.
- PRE-EXISTING NATIVE BUG FOUND BY THE PARITY PROBE, and it is bigger than this ticket: `sm_uv_to_world` in gdext/src/sphere_math_cpp.h had NO `case 11`; face 11 fell to `default`, which duplicates face 10's mapping (cx = u instead of cx = u - 1). Every native caller asking for face 11 got the wrong half of the -Z cube face — a measured 2,736 m error at R=4000. That covers the AC-0423 seam-V extension on face 11 as well as the new warp. FIXED by the coordinator (one case arm, mirroring sphere_math.gd:105) and the extension rebuilt: parity went 2,736.2021 m -> 0.001007 m.
- Standing guards re-run on the FIXED .so: light set all green (g0/player/interact/light/fluids/genhash/ac0423probe), and the nine seam overlaps are unchanged at 654/752/660/662/758/848/800/1290/1290 — the face-11 fix does not disturb the standing face/homeseam values, because those sites are not face 11. That is the evidence that the fix changed only what was wrong.
- MY PARITY BOUND WAS WRONG (fourth plan-level error in this series, third mine): I specified 1e-4 m, which is below the float32 storage floor at R=4000 (4000 * 2^-23 = 0.000477 m, and a few ulps through normalize is already ~0.001 m) — physically unachievable for any implementation. Corrected to 2e-3 m with the derivation in the probe; that still catches a wrong face by three orders of magnitude (the face-11 bug was 2,736 m). The builder flagged it instead of quietly loosening.
- Files: gdext/src/mesh.cpp (warp_face_verts + binding), godot/world/chunk.gd (native dispatch with a GDScript fallback so a stale .so degrades), gdext/src/sphere_math_cpp.h (the face-11 case), tasks/AC-0460/native_parity_probe.gd. godot/bin/libchunkio.so is a build output and is NOT committed.
