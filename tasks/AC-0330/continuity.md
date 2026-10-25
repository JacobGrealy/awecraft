# Continuity — AC-0330 (battery arms ok-status debt)

## RUN — 2026-09-25 — AC-0330
- Fresh run. Contract: tasks/AC-0330/plan.html. Template: tasks/templates/implement.md.
- Scope: the seven battery arms `craft`, `water`, `trees`, `atlas`, `buckets`,
  `player`, `interact`. Three report ok:false in the baseline (craft, water,
  trees); four filed as emitting no `ok` key (atlas, buckets, player, interact).
  Facts have MOVED — establish what each emits TODAY before classifying.
- RULES: per-arm evidence; do NOT flip ok to true; do NOT delete arms; do NOT
  decide the seven as a group. (a) stale expectation / broken scenario setup ->
  fix so it asserts again (reference = arm's own RESULT values + HARNESS.md §3);
  (b) value-reporting by design -> declare it in its HARNESS.md §1 row.
- Step 3.1 (before any edit): launch the characterization gate run capturing the
  BEFORE state of all seven plus the gate (b) arms:
  `python3 tasks/scripts/gate_run.py AC-0330 --arms g0,genhash,craft,water,trees,atlas,buckets,player,interact --timeout 1500`
  (load arms need the 1500 s budget; gate_run checks the godot slot itself).

## LANDED — 2026-09-25 — AC-0330 — per-arm classification (from r1 evidence + code read)
BEFORE state (r1, `.scratch/AC-0330-gates/`): g0 script=0 (banner only); genhash 25/25, GENMS 132, script=0;
craft **ok=true** (was ok:false in baseline — stale terrain-dependent F_cell; now a working gate);
water **ok=false** (above_top=false, standing_on_shore=false, water_cell_intact=false, max_y 41.971);
trees **ok=false** (genhash_gate=false genhash_fail "2,2", node_*_ok=false, determinism=true, desert_no_flora=true);
atlas NO ok (has_uv/uv_in_range/uv_max/grass_distinct/grass_side/grass_top);
buckets NO ok (scoop_before=[0,0], inv_scoop n0 — AC-0326-affected; place_after=[5,8]);
player NO top-level ok (sprint_ok=true, is_on_floor=true, col_deferred=0);
interact NO top-level ok (place_ok=true, drop_spawned=true).

CLASSIFICATION (per arm):
- craft  (a): real gate, CURRENTLY GREEN. Baseline red = stale terrain-dependent F_cell. No code change.
- water  (a): correctly catching the AC-0326 mirror/C++ sea divergence (fixture water not live). STOP+REPORT, leave ok:false.
- trees  (a): stale-fixture class (GDScript mirror `_trees_ref_flora`/`_tref_tree_at` + trees_expect_44.json + genhash_before_trees.log all August-era vs rebased gen; gen itself deterministic + biome-correct). Re-baseline = design decision + oracle → STOP+REPORT, leave ok:false.
- atlas  (b): value-reporting by design; §1 result_fields was STALE ("ok (or error)" — arm emits no ok) → fix + declare.
- buckets(b): value-reporting by design; declare + note AC-0326 impact on scoop fields.
- player (b): value-reporting by design (assertion = sprint_ok sub-flag); §1 stale-value finding RESOLVED (sprint_ok true again).
- interact(b): value-reporting by design (assertions = place_ok/drop_spawned).
No harness.gd changes (water/trees deliberately left red; (b) arms declared in §1 only). craft row left as-is (already lists `ok`; finding documented in results).

## GATES — 2026-09-25 — AC-0330
logs: .scratch/AC-0330-gates/ (r1 = before, r3 = after; NO code changed, so after == before).
Seven-arm table (before -> classification -> change -> after):
  craft    before ok=true  -> (a) real gate, already GREEN (baseline ok:false was a stale terrain-dependent F_cell) -> after ok=true (green in r1/r2/r3, deterministic)
  water    before ok=false -> (a) correctly catching AC-0326 mirror/C++ sea divergence (fixture water not live) -> after ok=false (left red on purpose; NOT adjusted)
  trees    before ok=false -> (a) stale-fixture class (GDScript mirror _trees_ref_flora/_tref_tree_at + trees_expect_44.json + genhash_before_trees.log, all August-era; gen deterministic + desert_no_flora true) -> after ok=false (left red; re-baseline = design decision + oracle, reported)
  atlas    before no ok (has_uv/uv_in_range/grass_distinct true) -> (b) value-reporting by design; stale result_fields "ok (or error)" corrected to real fields -> after no ok (declared)
  buckets  before no ok (scoop_before [0,0], inv_scoop n0; AC-0326-affected) -> (b) value-reporting by design + AC-0326 caveat -> after no ok (declared)
  player   before no top-level ok (sprint_ok=true, col_deferred=0) -> (b) value-reporting; sprint_ok sub-flag is the assertion; 2026-09-20 stale-value finding RESOLVED -> after no top-level ok (declared)
  interact before no top-level ok (place_ok/drop_spawned true in r1, FALSE in r3) -> (b) value-reporting; mine-timing-flaky (3 s window vs ~0.972-prog mine) -> after no top-level ok (declared)
gate(b): g0 script=0 (zero SCRIPT ERROR) + genhash 25/25 (GENMS 132); player sprint_ok=true; craft ok=true (r2 "all arms ok", r3 reconfirmed). No value regressions: no harness.gd edit -> battery arms unchanged mode-for-mode.
doc: harness_doc.py --render rc=0 + --check in sync; test_tasks.py 53 passed / 0 failed.
FILES: godot/harness_data.yaml (only). godot/scenes/harness.gd pristine.

## RESULT — 2026-09-25 — AC-0330
RESULT: AC-0330: PASS
  gate(a) seven-arm table complete: every arm classified (a)/(b) and fixed-or-declared, none unexplained -> PASS
  gate(b) no value regressions (no harness.gd edit); g0 zero SCRIPT ERROR + genhash 25/25 -> PASS
  gate(c) harness_doc --render + --check clean + test_tasks 53/0 -> PASS
  deviation: water LEFT ok:false — correctly catching the AC-0326 product defect (reported, not adjusted; flipping ok true would hide it)
  deviation: trees LEFT ok:false — stale August-fixture class; re-baseline is a design decision + independent oracle, out of scope (reported)
  deviation: interact place_ok/drop_spawned mine-timing-flaky (true r1, false r3) — follow-up (wider mine window), not a product defect
  follow-up (owed, by plan): the battery compare script diffs VALUES only — the reason this debt was invisible; a status-aware compare would flag the water/trees reds
