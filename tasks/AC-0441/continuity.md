## RUN - Sat Oct 17 03:09:39 EDT 2026 - AC-0441

- 03:35 — reading list complete (ticket notes, AC-0384 §29, CONTINUITY r26, ARCHITECTURE,
  AC-0428/AC-0436 results, the shader, HARNESS §2/3/4/5, OPS). Defect seen in both assessment
  frames: concentric stripes in the 120 m upper-left masses; striped horizon band at 300 m.
- 03:50 — plan.html written. Mechanism read of the code: the volume march (vmarchseg) is a FIXED
  24 count-based steps per annulus segment, samples at t = t0 + (i+0.5)*dl, NO jitter. Two facets:
  C1/C3 coarseness/non-adaptive density (long grazing chords -> 100s-of-metres steps vs ~186 m
  finest octave) and C2 coherent screen-space phase alignment (t0,dl vary smoothly -> adjacent
  pixels march the same phased grid -> parallel stripes). A/B separates them.
- 03:55 — implemented: cloud_layer.gdshader (u_jit uniform default 0.0 = bit-for-bit OFF grid;
  per-pixel per-segment grid jitter from two ahashes of quantized v_wp); world.gd (AWECRAFT_CLOUDJIT
  Settings env preload + AWECRAFT_VOLSTEPS boot-only cost instrument; _ac0401_push change-gated
  u_jit push + value-gated u_vol_steps push); settings.gd (cloud_jitter bool DEFAULT ON +
  sanitize_bool); menu.gd (row hi+24 + sync + handler).
- 04:00 — stripe instrument (.scratch/AC-0441/stripe.py, pure PIL): 2D power spectrum of a 64x64
  crop, 4-16 px band (periods 16-4 px), coherence = top-bin power / same-radius envelope, conjugate
  check, ripple_rms amplitude, cloud_scale_lfsd (16px block-mean std = the volume/brightness-spread
  guard). Calibrated on the assessment frames: the 21px and 16px and 10.7px bins are reproducible
  PIPELINE constants (present in the clean sky of every frame, ~0.26 ripple amplitude); the defect
  separates on ripple_rms 2.2-8.2 (cloud regions) vs 0.23-0.36 (clean sky), 8-30x, with the
  cloud-march-owned banding reading (constants excluded) in between.
- 04:05 — G0 EXIT=0 census 0/0; shaderforce EXIT=0 12/12 (cloud_layer declared=40 ok); SMOKE
  battery ok:true (player;interact;light;fluids;genhash) EXIT=0; genhash 25/25 BYTE-IDENTICAL to
  the AC-0439 reference (render-only change, as expected).
- 04:10 — A/B battery LAUNCHED (background job bash-949, .scratch/AC-0441/capture_ab.sh): a0-120
  (baseline, CLOUDJIT=0), a1-120 (VOLSTEPS=48), a2-120 (CLOUDJIT=1), a0-300 (baseline) — r24 recipe
  verbatim, drain 120, timeout 1200 s, ulimit 20 GB. Acceptance frames (drain 1200) queued after
  the A/B verdict. RESUME: check capture_ab.progress + per-run logs; CAP_DONE/CAP_FAIL markers.

- 04:32 — A/B battery DONE (all rc=0, Forward+ boot lines, shots exist): a0-120 105 s, a1-120 146 s (+39 %),
  a2-120 92 s (≤ baseline), a0-300 69 s. Defect reproduced in my controlled baseline to the digit
  (ripple 2.2-3.7, bandCoh 2.3-19.8, periods 6.4-16 px — same as the assessment frames).
- 04:40 — ADJUDICATION (measurement + 4x visual): steps 48 SOFTENED (ripple halved, residual stripes at 4x,
  +39 % wall) — the grid stays screen-coherent at any count. Jitter at 24 steps REMOVED (no parallel
  structure at 4x, fine uncorrelated grain; ripple/lfsd/lumspread ≈ baseline = energy kept, structure broken;
  cloud-march bandCoh collapsed 9.1→2.7 / 12.7→2.5 / 19.8→11.6 in 4/5 crops; the (30,100) residual is the
  near-white flat-top gradient/quantization class the cloudless-sky controls also carry). Cause = C2,
  coherent screen-space phase alignment.
- 04:58 — Acceptance battery DONE (rc=0 all): final-120 (drain 1200) 763 s, final-300 (drain 1200) 509 s,
  night-120 (drain 600) 381 s. Frames settled, weather identical to the assessment (seed 44 / T frozen /
  CLOUD_T0=411200). 120 m: mass renders as cloud, no stripes at 1x or 4x. 300 m: horizon band no longer
  stripes (3x A/B pairs in captures). lumspread: all stats within 0.06/255 of baseline (spread/white-top/
  deep-shadow preserved). Night: moon-lit deck ridge (AC-0436 look) intact, night clouds, no banding — the
  r24-era night frame predates AC-0436 (moonless night); the night-look delta vs it is AC-0436, not this ticket.
- 05:05 — PROBE gates: meshprobe 1.0 (verts 277720=277720, 32/32) EXIT=0; lightstate census 0/0, leaks 0,
  worst null, wash false, stragglers 0 EXIT=0 (vc_diff 4 = the documented settle-timing tail class).
- 05:10 — docs synced (ARCHITECTURE.md Settings row + CloudLayer tree entry; HARNESS.md env rows for
  AWECRAFT_CLOUDJIT + AWECRAFT_VOLSTEPS). Final G0 EXIT=0, census 0/0. Results page
  tasks/AC-0441/AC-0441-results.html + 16 captures written. LIGHT GATES COMPLETE:
  G0 EXIT=0 0/0 · shaderforce 12/12 EXIT=0 · SMOKE ok:true EXIT=0 · genhash 25/25 · meshprobe 1.0 ·
  lightstate 0/0. Cost: jitter ≤ baseline (92 vs 105 s, same 120-frame budget; zero added samples);
  steps-48 +39 % (146 s) — NOT taken. Heavy gates + commit = coordinator.
