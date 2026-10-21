# Continuity — AC-0434

## RUN — 2026-10-21 02:22 EDT — AC-0434 stage 1 (measure the per-cell seam band)

Stage 1 of AC-0434 per tasks/AC-0434/plan.html. Measurement ticket: add one probe
(tasks/AC-0434/seam_band_probe.gd), change NO game or native code. Deliverable: per-cell
table of E_left/E_right/crack/overlap across the ac0423probe seam pairs, plus a statement
on whether 654–1290 (AC-0423) vs 634–678 (AC-0427) are one distribution or a disagreement,
plus the no-surface cell count. Gates: g0, genhash (25/25), ac0423probe (nine standing
overlaps 654/752/660/662/758/848/800/1290/1290), standalone probe with paired rc +
gate_census.

### Chronology (2026-10-21, MEDIUM builder, stage 1)

GATES (all in .scratch/AC-0434-gates/): g0 rc=0 script=0 shader=0 (g0-r1.log);
genhash rc=0, 25/25 GENHASH lines (genhash-r1.log); ac0423probe rc=0 — reproduced all
nine standing overlaps EXACTLY, 654/752/660/662/758/848/800/1290/1290 mm (ac0423probe-r1.log,
ms=5571). summary.json carries all four arms (g0, genhash, ac0423probe, probe).

PROBE (tasks/AC-0434/seam_band_probe.gd, standalone -s SceneTree boot). Iterations
probe-r1..r8.log; FINAL is probe-r8.log (rc=0, SCRIPT/SHADER 0, gate_census ok). RESULT:
ok=true, 0 fails, 0 flags, 144 cells.

KEY DISCOVERIES (mesh-structure facts that shaped the per-corner pick — all in
AC-0434-deviations.txt §2):
- The seam extension (mesh.cpp) is applied to ALL three per-slab instances (opaque
  s_ao, fluid tops, cutout leaves) — the arm's ext_edge reads opaque surface 0 only,
  so the arm's standing values are OPAQUE-ONLY. The per-corner table uses the full
  surface; 20 of the 153 corners have their surface row on the cutout instance
  (non_opaque_corners per pair).
- Merged top-face quads (qwrite_merged) extend ONLY their 4 corner vertices
  (seam_ext_corner); interior block corners carry no vertex, so the rendered edge
  there is the straight line between the moved corners. The probe lerps the two
  adjacent surface-layer corners' world positions (interpolated_corners per pair).
- Seam-END corners are also extended ALONG the seam (s -> -E / 16+E), so corner
  indices are clamped to 0..16.

HEADLINE RESULTS (per-corner, i.e. the physically real per-cell quantity):
- Per-cell overlap 602.4–730.4 mm, mean 656.1, spread 128.0 (all 144 cells).
- Per-cell crack 506.3–634.3 mm (mean 559.7); E_left 546.4–674.3 (mean 604.0);
  E_right 562.4–690.3 (mean 611.8).
- No-surface cells: 0 of 144 (per side 0/0; un-armed whole edges 0) — every seam edge
  in this world is fully armed on both sides; nothing is in the E-tuning-unreachable
  class.
- S1 (opaque-only per-pair extreme vs standing) reproduces all nine within 0.5 mm.

RECONCILIATION (the ticket's core question): AC-0427's 634–678 mm is INSIDE the
per-corner band. AC-0423's 654–1290 mm is the per-pair OPAQUE extreme (max A world
ext − min B world ext over the whole band): on the 654–662 pairs the extreme sits on
the surface row at one corner (extreme == per-corner worst), but on the 752–1290 pairs
one side's extreme vertex is a DEEP CAVE TOP (t = 8–32) at a DIFFERENT corner, so the
min/max mixes corners + heights and inflates to 752.1–1290.2 while per-corner worst
there is only 654.5–730.4. ONE geometry, TWO grains — NOT a genuine disagreement.
The visible band IS the sum of the extensions (per-corner E_left + E_right − crack =
602.4–730.4 mm); no hidden mechanism.

DELIVERABLES: tasks/AC-0434/seam_band_probe.gd (probe), AC-0434-deviations.txt
(7 conventions), probe-result.json (full RESULT incl. 144-row cells[]),
AC-0434-results.html (self-contained; all 742 numbers greppable from gate logs).
No game/native code touched; no fix chosen. Resume: nothing outstanding for stage 1 —
await coordinator review of the per-cell table + reconciliation statement.
