## RUN — Mon Oct 26 09:05:12 EDT 2026 — AC-0510

## LANDED — AC-0510 — Mon Oct 26 ~09:40 EDT 2026
- BEFORE renders captured (as-shipped: fog ON + wash ON, user config R24/F83): before-pitch (alt 941, pitch30), before-nadir (alt 941), before-nadir300 (alt 300 — the frontier crossing the fog window). All Forward+ (llvmpipe), zero SCRIPT/SHADER ERROR.
- settings.gd: fog_enabled default true -> false (key STAYS: saved cfg with fog_enabled=true still honoured; menu.gd row untouched — separate ticket).
- aero.gd: wash_on() -> false always (the AeroWash quad never created, aero_wash.gdshader never loaded; AWECRAFT_AERO_WASH env inert; wash was never a Settings key).
- main.gd: env-init fog block collapsed (default false, AWECRAFT_NO_FOG kept); _update_fog now gates ONLY env.fog_enabled — the depth window (fog_near/fog_far) is still pushed either way, so the fogsettings probe + the lod_avg u_fog_far wall home keep one number.
- world.gd: UNCHANGED by decision — its "fog push" is the AC-0401 u_fog_far ownership wall (the satellite body's op ramp + the near-tier discard), not atmosphere; the body is fenced and riding it is what makes "chunks appear out of the satellite LOD".
- lod_avg.gdshader: haz_b does not exist (deleted AC-0400/AC-0404/AC-0415 — the far tier rides the same env fog as the near tier) — 3c answered, no edit.
- Next: gates g0,genhash,lightstate (gate_run.py), then AFTER renders (same 3 vantages), then .scratch/AC-0510/frontier.py pixel analysis.

## GATES — AC-0510
- g0: rc=0, SCRIPT ERROR 0, SHADER ERROR 0 (3.8 s) — log .scratch/AC-0510-gates/g0-r1.log
- genhash: rc=0, 25/25 GENHASH lines (4.1 s) — genhash-r1.log
- lightstate: rc=0 ok, wash_detected=false (standing value UNCHANGED -> no re-baseline; worst=null, 0 leaks/22 chunks, census 0/0). Machine-timing class: demoted 1 (standing 41; AC-0311 same-build precedent 1/3), stragglers 3 (standing 0), vc_diff 4 (standing 1-2), arr_diff_cells 1 (one-cell class holds).
- harness_doc.py --check: "in sync: modes, standing-values" (no yaml edit made).
- Renders: 6/6 rc=0, Forward+ boot line each, 0 errors. BEFORE (as-shipped) vs AFTER pairs at 941 m (pitch + nadir) and 300 m nadir — see frontier-measure.log.
- Headline findings: 941 m pairs BYTE-IDENTICAL (fog window holds no ground there; wash faded sub-8-bit) — at the user's documented altitude the blue was never the fog/wash (it is the fenced body haz + sky). Frontier at 300 m: old veil colour (158.6,208.7,208.0) [fog-wall ring] / fully-fogged air (215,249,249); new annulus (114.7,152.4,115.7) = body terrain resolving out of the air; new near tier (71.3,119.7,49.8). Wall jump mean 9.5->20.0 (max 153->249) — the fog was hiding the per-chunk slab edges at the frontier (FINDING, reported, not restored). No unbuilt holes/gaps/pops (near-class body-pale reading 0.09%->0.05%; annulus air-rim 33.7%->33.6% continuous in both). Wash measured 1-4/255 blue lift (isolated on the fog-ineligible body class) — now gone; NOT the mist the user saw with fog off. Aerial readability: 941 m unchanged (reads as altitude — curvature/disc/sky); at 300 m the fog's partial aerial perspective is gone, cue is texture + body-haze gradient (reported).
- Deliverables: AC-0510-results.html (gates + measurement + lightstate wash statement), AC-0510-deviations.txt (8 items), 6 PNGs in tasks/AC-0510/, measurement logs in .scratch/AC-0510-gates/. ARCHITECTURE.md WorldEnvironment bullet synced (invariant 2). No git, no TASKS.yaml, no new tickets.
