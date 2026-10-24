# AC-0142 continuity — split-mobs-into-json

## RUN — 2026-08-29 — AC-0142 spec written, parked after AC-0141
- Task added AC-0142 p2, queued at position 5 (after AC-0141), status open.
- Spec filled: goal data/mobs.json alongside blocks/items split, requirements loader in data.gd, gates G0+probes+valid JSON, scope mobs.json + data.gd.
- Parked per user — runs with/after AC-0141 data JSON split.

## RUN — 2026-10-24 11:05 — AC-0142 builder (medium), applying tasks/AC-0142/plan.html
- Read the plan, AC-0141 results/deviations, the table (data.gd:112-124), the
  AC-0141 loader (_load_table data.gd:143-159 / _decode_table_value :162-178),
  the load sites (:214-215) and every consumer of `mobs`.
- **BLOCKED BEFORE ANY EDIT — the plan cannot be applied as written:**
  - The mobs table is NAME-keyed: keys are "pig"/"sheep"/… (data.gd:113-123) and
    callers use the names as string keys — `Data.mobs.get(key)` (entities/mob.gd:50,
    :166, :178; scenes/harness.gd:23680), `Data.mobs["bunny"]["h"]` (harness.gd:5980),
    and the mobs arm iterates `Data.mobs.keys()` expecting the 9 names
    (harness.gd:5960). The dump-diff proof requires the in-memory dict to keep
    exactly those string keys, so mobs.json must carry string top-level keys.
  - But `_load_table` (data.gd:152) DELIBERATELY script-errors on any non-int
    top-level key (`if not k.is_valid_int(): push_error(...); return null.size()`),
    and the plan §2 restates that as the contract ("top-level keys are converted
    back to int in the loader with a deliberate script error on a non-int key").
    Reusing it unchanged on a name-keyed mobs.json therefore produces exactly the
    intentional SCRIPT ERROR (G0 red, `mobs` null, dump diff non-empty, mobs arm
    crash). The plan's "reuse _load_table" and its int-key rule are mutually
    exclusive for this table.
  - Making it work is a DESIGN DECISION the plan does not make: e.g. an
    `int_keys := true` parameter on _load_table (mobs loaded with
    int_keys=false, string keys pass through verbatim) — which also decides
    whether the AC-0141 negative test (non-int key in blocks/items.json is a
    hard error, AC-0141 deviation 3) stays hard for the int-keyed tables or
    weakens to string pass-through. The plan forbids inventing that and forbids
    a second decoder, so there is no in-plan implementation.
- No code changed, no gate run, no mobs.json created. No godot process started.

## Coordinator — PLAN REPAIRED after a correct PLAN-INSUFFICIENT (round 72)
- THE BUILDER WAS RIGHT AND THE PLAN WAS WRONG. I wrote "reuse `_load_table`" and "top-level keys converted back to int" in the same breath, but THE MOB TABLE IS NAME-KEYED (`"pig"`), with callers doing `Data.mobs.get("pig")` (entities/mob.gd:50, harness.gd:5980, and an arm iterating `Data.mobs.keys()`), while `_load_table` DELIBERATELY script-errors on a non-int top-level key — that error branch is AC-0141's defence for blocks/items. Both instructions could not hold, and the builder proved the contradiction from source (`"pig".is_valid_int()` is false, so the error branch fires on the first key: G0 red, `mobs` null, dump diff non-empty) rather than discovering it at runtime.
- IT ALSO RULED OUT THE OBVIOUS NON-FIX: re-keying mobs.json with integers cannot work, because the empty-diff proof requires the in-memory dict to keep its NAME keys. That is the useful kind of refusal — it closed the door I would otherwise have walked through.
- THE REPAIR (mine to make, not the builder's): `_load_table` gains an `int_keys := true` parameter. Blocks and items keep `int_keys=true` and their hard non-int-key error and negative test; MOBS load with `int_keys=false` and pass string keys through verbatim. One loader, one encoder, one dump-diff proof — only the key policy differs, and it is explicit at the call site rather than implicit in the file.
- WORTH RECORDING AS A PATTERN: this is the third time a builder returning PLAN-INSUFFICIENT has saved a bad landing (the earlier two were the AC-0459 parser list and the AC-0465 producer count). The cheap correct refusal keeps outperforming my confident-sounding plans, and the reason is consistent — I plan from anchors and intent, while the code carries constraints (key shapes, ownership, ordering) that only a reader of the actual lines sees.

## RUN — 2026-10-24 11:11 — AC-0142 builder (medium, 2nd run after plan repair)
- Read plan (REPAIRED: _load_table gains int_keys:=true; mobs load int_keys=false, string keys verbatim),
  last continuity entry (the correct PLAN-INSUFFICIENT is recorded, not re-litigated),
  the mobs table (data.gd:112-124), the AC-0141 loader (_load_table :143-159 / _decode_table_value :162-178),
  the load sites (:214-215), AC-0141 results/deviations (the dump recipe), gate_run.py, HARNESS mobs row.

## LANDED — 2026-10-24 11:33 — AC-0142
- godot/data/mobs.json created (9 mobs, 5476 B) via .scratch/AC-0142/gen_mobs_json.py
  (verbatim transcription of the pre-AC-0142 table; ints tagged {"i": n}, floats bare,
  hex colours -> {"c": [n/255.0 x3, 1.0]} exact round-trip doubles, order preserved).
- data.gd: mob table literal (:112-124) -> `var mobs := {}` + AC-0142/AC-0037 provenance
  comment; _load_table gains `int_keys := true` (the hard non-int-key error now under
  `if int_keys:`; else-branch passes string keys through verbatim — blocks/items call
  sites untouched); _init gains `mobs = _load_table("res://data/mobs.json", false)`.
- DUMP DIFF EMPTY: .scratch/AC-0142/dump_before.txt == dump_after.txt (2200 B each,
  156 lines, mobs_count=9, var_to_str canonical — sorted keys, full-precision colours).
- Negative tests: missing mobs.json -> "Cannot call method 'get_as_text' on a null value"
  + Nil-assignment SCRIPT ERRORs (rc=1); corrupt mobs.json -> "Unable to iterate on
  object of type 'Nil'" + Nil-assignment (rc=1); both raw logs under .scratch/AC-0142/,
  mobs.json restored. G0 census (>0 SCRIPT ERROR) catches both.
## GATES — 2026-10-24 11:52 — AC-0142 all green
- gate_run.py AC-0142 --arms g0,genhash,save,load,mobs (one background job, logs in
  .scratch/AC-0142-gates/): g0 rc=0 census 0/0 (3 s); genhash rc=0 ok (3.7 s) —
  25/25 GENHASH lines byte-identical to the standing baseline
  .scratch/AC-0311-gates/p2_genhash_r1.log; save rc=0 ok=true 43.9 s (clear_ok /
  clear_pre_ok / hp_ok / hunger_ok / iso_ok all true); load rc=0 ok=true 755.3 s
  simband_ms=6739 (cols=41); mobs rc=0 ok=true 34.0 s — rig_ok / bunny_ok /
  fall_ok / chase_ok / spider_ok / wolf_ok / arrow_ok / tables_ok all true,
  total=20, ring_ready=true, day_passive=2130, night_hostile=1089,
  fall_watch {ymin=yland=-1.025390625, land_d=[3,0]}, wolf_tamed=true,
  wolf_bench=true, wolf_at0=6.0006, wolf_wf0=5.8216, wolf_wf1=4.6396.
- Dump proof consolidated under .scratch/AC-0142-gates/ (dump_before/after/diff +
  the two negative raw logs + dump_proof.txt): 2200 B each, mobs_count=9, diff
  empty (0 B).
- Docs synced in-task: ARCHITECTURE.md §2 (Data row) + §5 (mobs.json named,
  int_keys distinction, AC-0142 dump-diff numbers) and autoload/AGENTS.md
  (the data.gd bullet — mobs are JSON now, the "still code / split is AC-0142"
  sentence is gone).
- Temp instrument deleted: godot/dump_ac0142.gd (recipe in AC-0142-deviations.txt
  #5; the generator + runner are kept in .scratch/AC-0142/).
- Deliverables: tasks/AC-0142/{AC-0142-results.html, AC-0142-deviations.txt,
  continuity.md}. No git add/commit/push. Left for the coordinator: nothing —
  AC-0141's flagged stale autoload/AGENTS.md line (its deviation #5) is fixed by
  this ticket's edit.
