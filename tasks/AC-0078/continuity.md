## RUN 0 (coordinator, 2026-08-26)
- AC-0078 = AC-0034 child 4/4 (plan AC-0071 P1.5+P1.6): (1) fluid locality — per-chunk fluid prescreen + 32-block sleep signature, wake sources unchanged, sim results BIT-IDENTICAL; (2) first-load fast path — 3x3 sync core for New AND Continue; Continue stops waiting for the full radius, streams around the existing player.
- Spec v1 filled (gates G1-G6): G2 bit-identical fence (full battery exact), G3 fluid-locality measurement (Run-1 defines), G4 New 3x3 core verify + Continue spawn-no-wait (Run-1 defines the probe), G5 no-regression floor = POST-AC-0079 anchors (walk p95 ~62-65, fwd_p95 <= 3500 + probe >= 8, RECSLICE <= 12.2, perf total ~5715), G6 windows build + 8080/5180.
- Fresh-tree anchors (post-AC-0079, 2026-08-26): boundary r4 walk p95 62-65 / max ~111-134 / fwd_p95 2932-3238 / first10 10 / irb 81 / flap 0; r2 fwd 463-593; r50 RECSLICE 10.0/8.0, walk ~44-67; perf r4 total 5715 / first_draw 192 / read_sync_gen 0; genhash 25/25 (61de26e9); battery exact (sea 2730/2730+1406/1406, torch 14, 2.82, 25/9, place/drop true); exe 109559968B @17:42.
- Ops: HOME=/tmp/dsh_home pattern; one godot at a time; headless probes only in Run-1; r50 timeout 1200000 (background); scratch .scratch/AC-0078/; no git/builds/TASKS.yaml; never kill python server pids (8080/5180).
- Run-1 LAUNCHING (subagent_plan, xhigh).

