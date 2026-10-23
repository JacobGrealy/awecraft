# AC-0472 — face-key overlap: home drain erasing face light keys

## RUN — 2026-10-23 — AC-0472
- Builder: MEDIUM. Plan: tasks/AC-0472/plan.html (measure first, then guard).
- Anchors confirmed: `_star_settled_drain` at world.gd:6219 (loop 6223-6245);
  face dispatch `_face_star_pass` at 15019 (face keys dispatch only face>=2,
  home keys face 0/1); key shape `_key`="0:cx:cz" (home), `_key_f`="face:ccx:ccz" (face>=2).
  Face keys DO land in `star_owed` (world.gd:6536 face edit, 15983 face land).
- Scenario carriers: (a) boundary walk home<->face = `planetwalk` (the lap);
  (b) stationary settle in the overlap = `facefeed` (two stationary edge stands).
  Both are existing arms -> expose counters in their RESULT (no new arm, no registry edit).

## MEASURE (step 2, pre-guard, instrument only) — r1
- planetwalk (scenario a, boundary walk home<->chart face, the 12-face lap, 25/26 covered):
  face_inspected=753 face_erased=0 face_overwritten=0 face_wrong=0
- facefeed (scenario b, two stationary edge settles):
  face_inspected=135 face_erased=0 face_overwritten=0 face_wrong=0
- READING: the drain DOES inspect face keys (the [0,196]^2 overlap is real; resident face keys
  like 4:0:11 / 5:0:11 / 8:0:8 are overlap-region) but NEVER overwrites/erases one — every face
  key is skipped at the `star.column_settled(cx,cz)` check (the home engine has no settled column
  at the face chunk's index when the face chunk is resident: the player is on the face, home
  columns there are evicted/unsettled). ZERO overwrites/erasures/wrong values in BOTH scenarios
  => the hazard is THEORETICAL (reachable path, untravelled), not a live bug.
- Logs: .scratch/AC-0472-gates/planetwalk-r1.log, facefeed-r1.log, summary.json.

## LANDED (step 3, guard)
- world.gd `_star_settled_drain`: added `if _isface: continue` (world.gd:6271) — the home drain
  now skips ONLY keys with a face part (face>=2). Home keys (face 0/1) are untouched, so the
  double-settle AC-0463 L3 stays ruled out (face keys still dispatch via _face_star_pass).
  Counter vars/methods (_ac0472_*) kept as the tripwire (read 0 with the guard).
- harness.gd: counters exposed in planetwalk (scenario a) + facefeed (scenario b) RESULT only;
  no new arm, no other harness change (avoids the harness_data.yaml registry edit the fences forbid).
- Cadence/ownership unchanged: star_for untouched; the guard enforces existing lane ownership, not a reassignment.

## GATES (step 3 re-run, post-guard) — all GREEN
- g0: rc=0 script=0 shader=0.
- light (r1/r3): surface_eff=15 cave_eff=0 torch_level=14 torch_far_before=0 torch_far_after=9
  cave_pocket=[8,120,-50] — FIELD-IDENTICAL to AC-0463 baseline (only cave_census_ms timing differs).
- lightstate (r1/r3, AWECRAFT_LS_RADIUS=16): all grid chunks leaks=0, wash_detected=false,
  worst=null; ab.arr_diff_cells=1 cell [0,141,0] mean_eff 2.01 (light-VALUE fields match baseline).
  INVARIANTS hold; low_on_high_n (pacing) NOT gated per OPS.md §7.
- genhash (r1/r3): 25/25 BYTE-IDENTICAL to AC-0463 baseline.
- residency (r1/r2/r3, same-tree A/B): leak=false, STABLE, face=74 home=93 keys_same=true on all
  three runs (the AC-0463 baseline home=103 was a timing sample; the plateau is the ticket's 74/93).
- planetwalk (r1 pre-guard / r2 / r3 post-guard): 25/26 covered, mesh+body on every crossing, ok=true.
  ac0472 counters: 753/0/0/0 pre-guard -> 0/0/0/0 post-guard (the guard makes the home drain touch
  ZERO face keys).
- facefeed (r1 pre-guard / r2 / r3 post-guard): ok, both stands; ac0472 135/0/0/0 -> 0/0/0/0; the
  face settle MD5s (a/b/c) are byte-identical pre- vs post-guard.
- CONCLUSION: guard is provably inert (every gate identical / invariant-preserving) and effective
  (home drain now touches zero face keys). Hazard = THEORETICAL, guard = DEFENCE.
- Deliverables: continuity.md (this file), AC-0472-deviations.txt, AC-0472-results.html.

## Coordinator triage — AC-0472: the hazard is THEORETICAL, and we now know the invariant that keeps it inert (round 65)
- THE MEASUREMENT ANSWERED IT RATHER THAN THE FIX: across a boundary walk the home drain inspected **753** face keys and across two stationary edge stands **135** — and in both scenarios it ERASED ZERO and OVERWROTE ZERO, so there was no wrong `last_eff` value at all. The hazard is reachable but untravelled: the guard is DEFENCE, not a live-bug fix, and the record says exactly that rather than claiming a fix for a bug nobody had.
- THE REASON IT STAYS INERT IS THE FINDING WORTH KEEPING: every face key is skipped at the `column_settled` check, because the HOME ENGINE HAS NO SETTLED COLUMN AT A FACE CHUNK'S INDEX WHILE THAT FACE CHUNK IS RESIDENT. The two namespaces collide numerically but the home engine's own state has no entry there — so the overlap is safe by an invariant of the engine's bookkeeping, not by luck. That is a much better thing to know than "nobody has seen it happen": it tells a future reader WHY it does not happen.
- THE GUARD IS THE CHEAP CORRECT ONE: `if _isface: continue` — it skips ONLY keys with a face part (face >= 2) and leaves home keys untouched, so the double-settle AC-0463 L3 ruled out structurally stays ruled out. Post-guard the counters read 0/0/0/0 and the facefeed settle MD5s are unchanged, which shows the guard is both effective and inert.
- GATES: genhash 25/25 byte-identical, light field-identical (15/0/14/0/9, pocket [8,120,-50]), lightstate INVARIANTS held (leaks 0, wash false) with pacing not gated per OPS.md §7, residency leak false / STABLE at 74/93 confirmed by a same-tree A/B (r1 = r2), planetwalk 25/26 with mesh and body.
- WHY THIS TICKET WAS WORTH DOING EVEN THOUGH NOTHING WAS BROKEN: it converted a plausible-sounding hazard I had written into a journal into a measured statement with a named invariant and a guard. The alternative was leaving "there might be a cross-lane key collision" in the record forever, where it would either be trusted or dismissed without evidence. Negative results deserve the same rigour as positive ones.
