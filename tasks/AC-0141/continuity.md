# AC-0141 continuity — split-blocks-items-into-json

## RUN — 2026-08-29 — AC-0141 spec written, parked after AC-0140
- Task added AC-0141 p2, queued at position 4 (after AC-0140), status open.
- Spec filled: goal data/blocks.json + items.json (+ recipes/tiles optional), requirements loader in data.gd, gates G0+battery/genhash+spot-checks, scope data/*.json + data.gd + spec_template.py.
- Parked per user — runs after AC-0140 harness extraction.

## RUN — 2026-10-24 09:39 — AC-0141 (HIGH builder: data move blocks+items to JSON, dump-diff proof)

## LANDED — 2026-10-24 10:37 — AC-0141
- godot/data/blocks.json (34 entries) + items.json (48 entries) created; ints tagged {"i":n} (Godot JSON parses every bare number as float — probe-proven), colours {"c":[r,g,b,a]}, top-level id keys converted back to int in the new _load_table loader (data.gd:~140).
- data.gd: items literal (:63-:114) and blocks literal (_init) -> _load_table("res://data/..."); loader + _decode_table_value added after `var tiles := {}`; lookups/constants untouched; provenance comments (AC-0270/0271/0292/0040/0205/0040-banana) kept verbatim.
- DUMP DIFF EMPTY: .scratch/AC-0141/dump_before.txt == dump_after.txt (12070 B each, 84 lines: 34 blocks + 48 items + 2 counts; var_to_str canonical, sorted).
- Negative tests: missing/corrupt JSON -> SCRIPT ERROR in the run log (G0 census sees it).

## DONE — 2026-10-24 10:57 — AC-0141 gates all green
- g0 rc=0 census 0/0; genhash 25/25 byte-identical to baseline .scratch/AC-0311-gates/p2_genhash_r1.log (GENMS 134); save ok (inv_match=true, blocks 6/6, slot0/iso/hp/hunger/time all true); load ok simband_ms=6785 (751 s wall, cols=41, inflight 0/0); interact rc=0 place_ok=true (no flake this run); lightstate INVARIANTS leaks 0 / wash false / worst null (demoted=1 stragglers=3 vc_diff=4 = the AC-0474/AC-0463 r5+ machine pattern, identical to the previous ticket; the harness_data 41/0 row is stale).
- Dump proof: dump_before.txt == dump_after.txt (12070 B, 84 lines: 34 blocks + 48 items), diff empty (.scratch/AC-0141/).
- ARCHITECTURE.md §2 row + §5 bullet updated (invariant 2). spec_template.py and the gate scripts needed NO change (const-only scrape; no table scraping; genhash baseline unchanged).
- Temp instruments deleted: godot/probe_ac0141.gd, godot/dump_ac0141.gd (recipe in deviations #6).
- Deliverables: tasks/AC-0141/{AC-0141-results.html, AC-0141-deviations.txt, continuity.md}. No git add/commit. Left for coordinator: autoload/AGENTS.md stale "JSON split still open" line (deviations #5).
