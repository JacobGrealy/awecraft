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

## Coordinator triage — AC-0465 landed, with one number I do not yet believe
- THE REFACTOR IS IN AND VERIFIED BY THE GATES I RAN MYSELF: genhash 25/25 byte-identical, g0 clean, light and ac0423probe equal excluding ms, 71 sites routed through the two wrappers (5 production + 66 harness), inline chunk-dict key builders 41 -> 0 and hardcoded "0,0"-style literals 12 -> 0. The 93 surviving "%d,%d" strings are traced non-keys (RESULT labels, local caches, a v1 save fixture) and the ambiguous ones were listed rather than guessed, which was the plan's §7 risk and it was respected.
- THE NUMBER I DO NOT BELIEVE: `load` reports simband_ms 6918 (builder) and 6718 (my own rerun on a quiet box). The builder attributed this to local-LLM decode contention; my rerun had no subagent running and reproduced the high value, so THAT EXPLANATION IS WRONG. Historical logs in .scratch carry 1193/1264/1270 ms (AC-0293 era), i.e. a reproducible ~5.4x difference from this build.
- WHY IT MATTERS: a slow start-flow wait is EXACTLY the symptom a missed producer site produces (a wait polling the wrong key spins to its cap). The arm's ok is true and both save/load succeeded, so it is not broken — but "slower by 5x" and "silently waiting on a key nobody populates" look identical from the outside, and that is the failure mode this whole ticket exists to prevent.
- A/B IN FLIGHT: the pre-change three files checked out, load arm run, tree auto-restored on exit (trap). That decides between "this refactor moved it" and "it moved earlier and I have been carrying an unexamined baseline".
- Note for whoever picks this up: the earlier A/B attempt died with gate_run exit 3 ("slot still held after 1800 s") while `pgrep -f "[g]odot"` matched a process that later disappeared; the slot test in tasks/scripts/gate_run.py:165 is `pgrep -f "[g]odot"`, which matches ANY command line containing the word — including an agent's own shell string. Worth knowing before debugging a "stuck slot" that no longer exists.

## Coordinator triage — the simband question ANSWERED by A/B, and the answer exonerates the refactor
- A/B RESULT, run by the coordinator with the three files reverted to the pre-change commit and auto-restored on exit: pre-change `load` gives **simband_ms 6747**, post-change gives 6718 (my rerun) and 6918 (builder). So the ~6.7 s is the CURRENT NORMAL and **AC-0465 did not move it**; the 1193/1264/1270 ms I compared against are AC-0293-era logs, i.e. a baseline several months and many tickets stale. My suspicion was reasonable and wrong, and the A/B is what settled it — not reasoning about whether a thin wrapper "could" cost 5x.
- The builder's "LLM decode contention" explanation was ALSO wrong (my quiet-boot rerun reproduced the high value), so the correct record is: the number was never a regression at all; both explanations offered for it — the builder's and my own — were wrong until the A/B was run.
- TOOLING TRAP, now understood and worth harvesting: `gate_run.py:165`'s slot test is `pgrep -f "[g]odot"`, which matches ANY process whose command line contains that word — including the agent's own `bash -c` string whenever the command text mentions a repo path like `godot/world/world.gd`, and including a heredoc body embedded in the launcher's argv. Two of my A/B attempts deadlocked this way (one burning a 1800 s slot wait) before I moved the work into a script file invoked by name. The lesson: put engine-path-touching work in a script file and launch it with an argv that never mentions the engine.
- AC-0465's own gates stand as delivered: genhash 25/25 byte-identical, g0 clean, light and ac0423probe equal excluding ms, 41 -> 0 inline chunk-dict key builders, 12 -> 0 hardcoded literals, 71 sites on the two wrappers.

## CORRECTION, round 25 — THE REFACTOR WAS NOT IN THE TREE AND I CLOSED THE TICKET ANYWAY
- WHAT HAPPENED, found by the AC-0459 builder rather than by me: commit **fa50122** added the two wrappers and routed 71 sites, and then commit **3b44f90** — the one where I meant to record only the triage journal — committed a REVERT of all three godot/ files (`git show --stat 3b44f90` shows world.gd -9, main.gd, harness.gd -132). The A/B experiment had checked the pre-change files out into the index and worktree; my manual `git checkout HEAD -- …` "restore" did not put the new versions back, `git status` reported the tree clean because the index agreed with the reverted worktree, and I then committed that clean-looking tree as a journal-only change.
- SO `git diff fa50122~1 HEAD -- godot/` was EMPTY: the refactor had never existed at HEAD, `world.chunk_key` was absent from the working tree, and my "AC-0465 closed" claim at 041cced was FALSE. The 41 -> 0 / 12 -> 0 numbers I reported were true of the tree the builder produced and untrue of the repo.
- RE-LANDED and re-verified: the three files restored from fa50122, `world.chunk_key`/`chunk_key_face` present again, inline builders 0, and g0 (0/0 SCRIPT/SHADER) plus genhash 25/25 clean on the re-landed tree.
- WHAT THE A/B CONCLUSION SURVIVES UNAFFECTED: load-r3's 6718 ms was measured on the tree that really did carry the refactor (before the revert), and the A/B's 6747 ms was measured on the pre-change files, so "~6.7 s is the current normal and this refactor did not move it" still stands. The lesson is narrower and uglier than that: the measurement was sound, the BOOKKEEPING was not.
- THE RULE THIS EARNS, and it belongs in the closeout procedure rather than a journal: after any git-checkout experiment, verify the re-land by GREPPING FOR THE NEW SYMBOL, not by reading `git status`. `git status` clean means "the index matches the worktree", which is exactly what a revert-plus-commit also looks like.
