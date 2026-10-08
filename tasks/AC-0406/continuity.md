# AC-0406 continuity (append-only journal)

## RUN - Thu Oct  8 00:30:42 EDT 2026 - AC-0406

- 00:31 read: CONTINUITY (r25 checkpoint), ARCHITECTURE (CloudLayer §3 + _ac0401_push seam §4),
  AC-0406 ticket notes (TASKS.yaml), AC-0405-results.html (the volume: 24-step march, 6-tap
  self-shadow, peak-normalised HG g=0.65, gains 2.5/0.30; spread 68.9; tint 181,229,190; cost
  781 s vs 496 s off at r700), HARNESS §2/§4/§5, OPS, cloud_layer.gdshader (672 lines), the
  _ac0401_push seam (world.gd:4959), Aero.fog_display (aero.gd:157 — the single-source air colour,
  8-bit-sRGB-rounded then srgb_to_linear, so it is LINEAR), satellite_body.gd:590 (the precedent:
  Aero.fog_display(day_t) pushed as u_air), AC-0405's render recipe (.scratch/AC-0405/run_renders.sh:
  CAM=planet + SAT_ALT, R24/F83, T=0.5 freeze, CLOUD_T0=411200, SNAP_DRAIN=1200, 1200 s cap), and
  the four before-frames (r120/r300/r700/r2600-on.png). Defect confirmed by eye: r120 is a dark
  stormy ceiling, r300/r700 dark deck band.
- 00:31 design (locked): in vmarchseg — (a) ambient in-scatter accumulator A (Σ T·ds, the exit-
  transmittance-weighted in-scatter of the sky dome, NO darkEdge, NO self-shadow — that
  attenuation IS the MS), (b) self-shadow factor becomes 3 terms with decreasing extinction
  (exp(-τ) + 0.35·exp(-0.45τ) + 0.25·exp(-0.15τ)) / 1.6 so τ=0 stays exactly 1.0 (lit tops and the
  2.5 gain unchanged), (c) HG phase mixed 0.5 toward the constant 1.0 (isotropic on the same 4π
  scale, so the blend stays normalised; peak = 1.0 unchanged → silver lining kept). In fragment():
  ALBEDO gains `u_vol_amb · air_srgb · A` where air_srgb = pow(u_vol_air, 1/2.2) (u_vol_air is the
  LINEAR fog_display value; the ALBEDO expression is sRGB-domain and gets the pow(2.2) pre-decode).
  New uniforms: u_vol_air (world.gd pushes Aero.fog_display per frame, value-gated), u_vol_ms1 0.35,
  u_vol_ms2 0.25, u_vol_iso 0.5, u_vol_amb 0.7 (shipped-tuning class, like u_vol_sigma — no new
  Settings toggle: this is the lighting model of the existing default-ON cloud_volume feature; the
  OFF path's byte-identity is the short-circuit, untouched).
- 00:32 plan.html written. Next: implement shader + world.gd push, G0, smoke+genhash, boundary r4,
  4 acceptance renders (r2600/r700/r300/r120) as one background job, then measure before/after.
- 00:58 implemented: cloud_layer.gdshader (5 new uniforms u_vol_air/ms1/ms2/iso/amb; vmarchseg carries A in .w;
  MS 3-octave sh; iso phase blend; ambient in fragment) + world.gd _ac0401_push item (5) pushing
  u_vol_air = Aero.fog_display(Game.time_of_day) value-gated. ARCHITECTURE.md CloudLayer bullet updated.
- 00:59 G0: rc=0, zero SCRIPT ERROR, zero SHADER ERROR (one GDScript parse error on first pass — a bare
  multi-line if-condition needs parens in GDScript; fixed, re-run clean). No backtrace (AC-0403 class did
  not trigger).
- 01:00 smoke battery (player;interact;light;fluids;genhash): ok:true, exit 0. genhash 25/25 byte-identical
  to AC-0405's reference. Boundary r4 (one-shot self-check): ok:true, p50 13=13, p95 34→35, max 227→164,
  storm_walk_p99 124→99, fence fields 0; built_final 51 vs AC-0405's 64 (census class, non-gated — noted).
- 01:00 render driver launched as background job (4 frames: r700/r2600/r300/r120, AC-0405's exact recipe,
  1200 s cap each, DSSTATS for the FPS overlay). Before-set measured with measure.py (analyze2 lineage):
  r120 underside band [80,290) mean 140.5 / p10 43.5 / min 12.3; r300 interior band [215,360) mean 127.7 /
  p10 23.0 / min 0.0; r700 deck-mask (8.84% coverage) mean 59.3 / p10 8.0 / min 0.0; r700 lower_mid std
  68.9 (reproduced exactly), px_center 181,229,190 (reproduced exactly). The before dark side is confirmed
  numerically: p10 values 8-23 with pure-black pixels present.
- 01:31 FIRST PASS RETUNE (the measurement loop the plan owed): r700-on landed rc=0 wall=802s (vs 781s
  before: +2.7%, the added terms are cheap), zero shader/script errors, Forward+ boot asserted. But the
  lower_mid spread COLLAPSED 68.9 -> 39.1 (below the 40.2 no-cloud floor) and the deck-mask mean ran
  59.3 -> 184.7 (p10 8 -> 130): u_vol_amb 0.7 floods the whole edge-on deck to near-sky brightness —
  the flatten-everything failure the prompt warned against. px_center tint held 181,229,190 exactly.
  Retuned to u_vol_amb 0.45 / u_vol_ms1 0.30 / u_vol_ms2 0.18 / u_vol_iso 0.4 (derived from the
  measured 0.7 data point: ambient luminance on the 700 m deck ~150 -> target ~95, valley p10 ~110,
  tops still clamped at 1.25). Killed the in-flight job (r2600 old-build done, r300 old-build
  interrupted) and relaunched all four frames on the retuned build — the acceptance set must be one
  build. First-pass r700 data kept as the deviation record.
- 02:24 retuned build rendered: 4/4 frames rc=0, zero shader/script errors each, Forward+ asserted,
  walls r700 776s / r2600 810s / r300 880s / r120 792s (all inside the 1200 s cap; r700 flat vs 781s
  baseline). Measured: r120 underside mean 140.5->179.4, p10 43.5->146.0, min 12.3->23.1; r300 interior
  mean 127.7->184.5, p10 23.0->140.0, min 0.0->126.2; r700 deck-mask mean 59.3->139.9 (p10 8->110.4,
  p90 114->179.3), coverage 8.84->8.15%; spread 68.9->44.9 (above the 40.2 no-cloud floor and the 32.4
  reference; the old 68.9 was black-slab-bimodality inflation, min 0->98.4); px_center tint
  181,229,190 IDENTICAL; lit tops still clamp at 255 (calibration untouched). Visual: r120 a bright
  mottled ceiling with near dark masses in front of a brighter far layer (parallax kept), r300 a soft
  grey mottled band, r700 a structured grey deck, r2600 the bright lumpy orbit cloud ring.
- 02:30 captures copied to tasks/AC-0406/ (r120/r300/r700/r2600-on.png); AC-0406-results.html written
  (acceptance table, cost line, gates with exit statuses, deviations incl. the first-pass flatten
  failure + no-new-toggle justification). Gates final: G0 ok (exit 0, census 0/0, no backtrace),
  smoke ok:true, genhash 25/25 byte-identical, boundary r4 ok:true (latency flat; built_final 51 vs 64
  noted as census drift), renders 4/4. Exit: heavy set is the coordinator's; no commits (fence).
  DONE - light gates green, acceptance measured.
