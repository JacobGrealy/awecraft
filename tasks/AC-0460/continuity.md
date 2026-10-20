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
