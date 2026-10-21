
## RUN — Wed Oct 21 13:08:19 EDT 2026 — AC-0468
- builder: medium, single slot. Contract: tasks/AC-0468/plan.html. Test-tooling only.
- TODO: seamcensus reverse map placement-aware; ac0423probe warp-on fix/retire; harness_data.yaml + render.

## LANDED — AC-0468
- seamcensus: reverse map placement-aware. `_seamc_visible_mesh` returns [mi, yoff, ws] (ws =
  world-space high tier under the home warp); NEW `_seamc_world_to_local` (exact inverse of the
  warp post-pass: ly = |p|-R, (fx,fz) via SphereMath.world_to_face — the game's own home
  world->cell chart map; AC-0462 lesson: exact inverse, no per-axis projection) + `_seamc_slab_local`
  (per-slab local frame map, bad-vertex flag per quad). Threaded through `_seamc_emit_planes`,
  `_seamc_recover_faces`, `_seamc_validate` (winding loop + recover), `_seamcensus_test`
  (placement state + RESULT "placement" field). Flag-off path byte-identical (ws false).
  Low tier stays slab-local in BOTH states (the ring warps at draw; slot arrays never warped).
- ac0423probe: warp-on path RETIRED (plan §4.3) — `_ac0423probe_test` reports
  status "retired_warp_on" + instrument pointer (seam_band_flagon.gd + gate_bothdirs.py) when
  AWECRAFT_WARP_HOME != 0; flag-off path untouched (standing nine reproducible). Dispatch comment
  updated. Decision + why: in the reply/deviations.
- G0: rc=0 script=0 shader=0 (rev 1).

## GATES — AC-0468
- Default tree (rev 1 logs, .scratch/AC-0468-gates/): g0 rc=0 0/0; genhash 25/25 byte-identical
  to the AC-0467 default-state reference set (genhash-r22.log); seamcensus rc=0 0/0 ok=true
  placement="canonical_warp" — 0/64 seams on 393,216 rows (rows_ok 393,216), missing/spurious/
  shifted/spurious_single all 0, fixture 44/44 + 12/12 on seam, map_anomalies 0 (was 48343),
  winding 48402/0 (same quad count as flag-off); ac0423probe rc=0 0/0 ok=true
  status="retired_warp_on" + instrument pointer (explicit non-measurement).
- Flag-off (AWECRAFT_WARP_HOME=0, rev 2 logs): g0 rc=0 0/0; genhash 25/25 identical; seamcensus
  ok=true placement="legacy_local" — 0/64 seams / 393,216 rows, fixture 44/44, map_anomalies 0,
  winding 48402/0 (byte-identical standing values; only settle.waited frame count differs);
  ac0423probe full RESULT JSON byte-identical to AC-0467 flag-off (ac0423probe-r20.log) excl ms —
  the standing nine gaps reproduced (x16_z0 552.0/558.0/554.7/20 … z32_x16 -615.0/570.0/171.08/38).
- Cross-check (unchanged instrument, default tree): tasks/AC-0467/seam_band_flagon.gd (the
  flag-ON-aware copy of tasks/AC-0434/seam_band_probe.gd) rc=0 self-checks pass + gate_bothdirs.py
  PASS: n_cells=144, worst gap 64.0 mm (z32_x16), worst overlap 64.0 mm (z32_x0), 0 cells > 100 mm
  grout either direction — identical to AC-0467 stage B's measured values; no game path moved.
- Docs: harness_data.yaml seamcensus row updated; harness_doc.py --render + --check in sync;
  HARNESS.md "Not in table" bullet added for the ac0423probe retirement (rowless-probe class);
  results page rendered via results_page.py (merged 9-arm summary-both.json).
