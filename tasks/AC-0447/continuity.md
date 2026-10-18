## RUN - Sun Oct 18 08:45:29 EDT 2026 - AC-0447

- subagent started: ticket read (notes in TASKS.yaml). Reading the READ-FIRST list in order.
- Sun Oct 18 09:18:45 EDT 2026: plan.html written. Measuring next: baseline renders (t=0.0 night / 0.25 dawn / 0.5 day / 0.75 dusk) at the assessment recipe (R24/F83, 1280x720, seed 44, TIME_FREEZE=1, CLOUD_T0=411200, DRAIN=600). Curve closed form: day(t)=clamp((sin((t-0.25)TAU)+0.12)/0.35,0,1); t=0.0 -> 0.000 exactly (midnight), t=0.25/0.75 -> 0.343 (dusk!), t=0.5 -> 1.0. Previous night numbers: r24/r25 assessment + AC-0436 acceptance all used AWECRAFT_TIME=0.0 (true midnight); AC-0446 own night A/B (r3/r4) used t=0.75 (dusk) - to be re-verified on this tree.
- Sun Oct 18 10:12:01 EDT 2026: baseline battery green (5 runs RC=0, 0/0 errors, Forward+ boot line, files present; shots fired at drain-timeout = the documented faithful mid-build state, identical recipe across runs).
- Measured hour curve (band y440-599 Rec.709, this tree): t=0.0 avg 12.86 (day=0.000 exact); t=0.25 avg 21.84 (day=0.343); t=0.5 avg 99.96 (day=1.0); t=0.75 avg 21.07 (day=0.343) - DUSK IS 1.7x BRIGHTER THAN TRUE MIDNIGHT.
- PREVIOUS NIGHT NUMBERS: r24/r25/AC-0436 all used AWECRAFT_TIME=0.0 (true midnight), NOT dusk - my t=0.0 re-shoot reproduces the published r25 frame (avg 12.86 vs 12.86, identical histogram) and AC-0436 (12.86 vs 13.17, tree drift). The ticket's ~3/4-below-10 is r25's 76% figure, which used plain-average luma over full ground rows (I reproduce 74.9% on that frame) - a different convention than the standard band (15.9% <10, 81.6% in 0-15).
- AC-0446's own r3/r4 "night" A/B used t=0.75 (dusk) - the ticket's warning applies to it.
- Pixel-pair data (grass mode texel, top face, same pose aligned): day x=tex*1.0 -> (14,128,0); dusk x=tex*0.474 -> (0,25,0); night x=tex*0.432 -> (0,17,0); night side floor -> (0,0,0) 8.5% cluster. Tone-map probe battery running to pin P exactly.

## RUN (cont.) — tone curve pinned, toe fitted [in-game probe]

**In-game probe saga (summary):** standalone WorldEnvironment probe was broken (its env did not
behave like the game's; a 3D-quad "day texel -> (0,1,0)" was a red herring — the quad reads were
contaminated by the 2D crosshair dot and by the wrong camera node / local-vs-global position).
The VALID path: temporary autoload inserts unshaded quads ON the real ground (surface top y=141,
camera global (8.785, 142.6, 8.785) — NOT (0,1.62,0): that was the camera's LOCAL pos) and reads
viewport bytes. Runtime `Shader.new()` quads never rendered (compile/attach fail in this build);
`PlaneMesh` + `StandardMaterial3D` (unshaded, CULL_DISABLED) works. `albedo_color` is sRGB —
set albedo.g = g^(1/2.2) to emit LINEAR g.

**Measured game tone curve (G channel, unshaded quad, t=0.5, verified: 0.0172->18 == the night
grass top face byte (0,18,0) exactly):**
g_in: 0.0002 0.0005 0.001 0.002 0.004 0.007 0.012 0.0172 0.025 0.04 0.06 0.09 0.12
byte:    0     0     0     0     0     1     10    18    29   48   70  100  125
(Dead zone below ~0.005. Full red (1,0,0) -> (255,0,0) uncrushed. Grass day 0.1087 -> 128,
dusk 0.0211 -> 25, night-top 0.0172 -> 18, night-floor 0.00042 -> 0 — all consistent.)

**Night toe fit** (f applied to ALBEDO luma after predecode; f = 1 + w*A*(d/(g+d))^p,
w = (1-day)*switch): targets night top face byte ~45 (g'=0.0376, gain x2.19), floor byte ~12
(g'=0.0133, gain x31.7) => **A = 42.5, d = 0.00175, p = 1.5**.
Predictions: top face 18->45, side (g 0.00159) 0->~30, floor 0->~12 (hierarchy 45/30/12).
g*f(g) monotone over [0, 0.5]; g=0 stays 0; day w=0 => ac_f exactly 1.0 => bit-identical.
Dusk/dawn (w=0.657): top 25->~43, floor 0->~5 (side effect, reported).

## RUN (final) — implemented, verified, gates green

**Implementation** (switch `night_lift`, default OFF, AWECRAFT_NIGHTLIFT=0|1 boot env, menu row):
- 8x chunk_lit_*.gdshader (+_fade): `u_night_lift` uniform + toe after the AC-0242 predecode:
  `ALBEDO *= 1.0 + u_night_lift * 42.5 * pow(0.00175 / (ac47_lum + 0.00175), 1.5)` on luma.
  BUG CAUGHT: first after-battery failed 12x SHADER ERROR — `^` is not pow in the shading language;
  fixed with pow(); census caught it before any frame was trusted.
- world.gd: AWECRAFT_NIGHTLIFT boot read (no save), _ac0447_lift/_ac0447_n_mats state, (6b)
  per-frame value-gated push of w=(1-day)*switch to chunk + both fluid material sets.
- settings.gd: "night_lift": false + sanitize_bool (moonlight precedent); menu.gd: row/sync/handler;
  ARCHITECTURE.md: Settings-row clause.

**Evidence** (full numbers in AC-0447-results.html):
- Night t=0.0 band: avg 12.86->33.54, med 12.16->36.48, 0-15 bucket 81.6%->1.4%, L<5 11.5%->0.6%;
  grass-top strip 13.2->32.8 (zeros 3.0%->0.0%). Depth kept (70.4% of the mass in one 32-47 band).
- Ridge yaw 1.57: fg 24.6/mg 12.3/ridge 7.4 (34.3% zero) -> 41.8/32.9/30.1 (1.0% zero): dark
  foreground anchor + lit ridge.
- Day UNCHANGED within noise: subject diff (OFF vs ON day) 17,507 px / 1.90% vs CONTROL diff
  (two independent baseline day runs) 25,420 px / 2.76%; band avg ON 98.93 inside baseline pair
  99.96/99.22; diff signature 55% darker + 2,419 px delta>64 = the stochastic flicker class (same
  swap even between the two captures of one run), impossible for f=1.0.
- Gates: G0 RC=0 0/0; SMOKE 5/5 ok (probe revert fixed 13 headless get_pixel errors — my autoload,
  not the fence dirt); genhash 25/25 byte-identical vs HEAVY-r22 (the standing reference — the
  HARNESS row's AC-0367 pointer is STALE, finding for closeout); settings arm ok:true;
  meshprobe match_rate 1.0 (255,192/255,192); shaderforce 17/17 ok (16 + AC-0446 seam shader;
  row says 16).
- REVERTED: project.godot clean vs HEAD; probe_env_tmp.gd + godot/.probe_ac0447/ deleted.
- FINDING (not mine, untouched): fence files debug.gd/game.gd/drop.gd/main.gd (+22) + AC-0067 PNGs
  were already dirty vs HEAD 4f67b99 before this session started.

RESUME: nothing owed to the builder. Coordinator: heavy gates + closeout (TASKS.yaml via
tasks.py, commit — do NOT `git add -A`; the fence-file dirt is pre-existing and must not be
absorbed into this ticket's commit without a decision).
