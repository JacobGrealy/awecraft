# AC-0465 continuity — single chunk-key producer (pure refactor, no format change)

## RUN — Tue Oct 20 20:26 EDT 2026 — AC-0465
- Plan read: tasks/AC-0465/plan.html (contract). Context pack .scratch/AC-0465/context.md read.
- Scope: add world.chunk_key(cx,cz) + world.chunk_key_face(face,ccx,ccz) beside _key/_key_f in
  godot/world/world.gd; route every by-hand chunk-dict key builder (main.gd 598/1704/1827/1873/1908 +
  harness.gd chunk-dict sites only) through them. Format unchanged. Gates: g0,genhash,light,
  ac0423probe + save/load arms + grep before/after.

## LANDED — AC-0465
- world.gd: +func chunk_key (after _key @11402), +func chunk_key_face (after _key_f @15284). Thin delegates, format unchanged.
- main.gd: 5 sites converted (598 both branches, 1704, 1827, 1873, 1908).
- harness.gd: 66 sites converted (37 inline literal lookups + 17 variable/list-mediated + 12 hardcoded
  "0,0"/"0,1"/"196,%d" literals). Full list + 93 non-key skips: tasks/AC-0465/AC-0465-deviations.txt.
- Grep gate: direct inline chunk-dict literal lookups 41 -> 0 (main 4->0, harness 37->0);
  "%d,%d" totals main 5->0, harness 145->93 (all 93 traced non-key); hardcoded-literal lookups 12->0.
- Next: gates (g0 first, then genhash/light/ac0423probe, then save/load arms).
- FIX: 9 `:=` inferences broken by untyped `world` (parse error on first gate run) -> explicit
  `: String` (7339, 9098, 9466, 10786, 25091, 25107, 27534, 27559, 28259).
- Gates (post-fix tree): g0 r2 0/0 SCRIPT/SHADER ok; genhash r2 25/25 byte-identical to AC-0462
  reference (GENMS 132 vs 129); light r1 equal excl ms (cave_census_ms 453 vs 447);
  ac0423probe r1 equal excl ms (5532). save r1 ok=true (r_saved/r_loaded 4000, v1_softfail true).
- load arm re-run (bash-1155) with load=3600s timeout (R50 arm, ~28 min): PENDING.
- GATES FINAL (all post-fix tree, logs in .scratch/AC-0465-gates/):
  g0 r2 rc=0 SCRIPT=0/SHADER=0; genhash r2 25/25 byte-identical to AC-0462 genhash-r9 reference
  (GENMS 132 vs 129); light r1 equal excl ms (453 vs 447, all fields match AC-0462 r9);
  ac0423probe r1 equal excl ms vs AC-0462 r10 (JSON diff, ms 5532); save r2 ok=true 44 s
  (r_saved/r_loaded 4000, clamps 8000/2000, v1_softfail true, all subchecks ok);
  load r2 ok=true wall_ms 612342, simband_ms 6918, screen_hidden_ms 6959, cols/meshed 41, gen 5509,
  queue_final 5468, inflight 0, SCRIPT=0, zero "SIMBAND not fully built" lines (cap never armed).
  simband ran ~5x idle-box baseline (~1.2-2.1 s) under local-LLM decode CPU contention; the
  missed-site regression signature (3000-frame cap + log line) is absent.
- Grep gate: direct inline 41->0; hardcoded literals 12->0; "%d,%d" main 5->0 harness 145->93
  (all 93 traced non-key); "%d:%d:%d" main 1->0 harness 4->2 (RESULT labels).
- results page written: tasks/AC-0465/AC-0465-results.html. No git ops per fence.
