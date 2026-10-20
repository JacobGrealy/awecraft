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
