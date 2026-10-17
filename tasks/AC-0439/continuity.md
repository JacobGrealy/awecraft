## RUN - Fri Oct 16 20:47:04 EDT 2026 - AC-0439

- Plan written (tasks/AC-0439/plan.html). Fix: re-key the AC-0429 floor weight `ws` from
  `smoothstep(0, 0.3, w)` (fires at ~630 m radial — INSIDE the atmosphere) to a new
  `Aero.sky_outside(alt_rad)` = smoothstep(A, A+0.25A, alt) pushed as `u_space_out` (world.gd
  _ac0401_push block 3, per-frame value-gated). Inside (alt<A): AC-0428 continuous-air look;
  outside (alt>=A): AC-0429 space floor; window [1200,1500] m = the limb's 0.25A tail.
- BEFORE user frame on current build (captures/before-inside-h800.png, seed 44 T=0.5 R50
  1280x720, SAT_ALT=800 + HORIZON aim => radial 941, w=0.799, drain 600, steps 300/600):
  rc=0 in 229 s, Forward+ llvmpipe, census 0/0, body LOADED, u_air=[208,241,251].
  Profile: rows 0-220 (above horizon) 57.7->123.3 blue+sun; rows 220-320 collapse 121.6->0.0
  (max raw step 37.81 = the boundary the sky model drew); rows 340-520 (below horizon) 0.00
  FLAT BLACK = the defect; rows 540-700 limb air column 0.1->10.3; row 719 limb 151.16.
  Thirds 98.25/17.19/9.93. Step at horizon row 0.00. s300 vs final sky rows within ~3 lum
  (cloud drift only). THE USER'S FRAME IS REPRODUCED.

### Implementation (4 files)
1. `godot/core/aero.gd`: `Aero.sky_outside(alt_rad)` = smoothstep(A, A+0.25A, alt) (the limb's
   0.25A tail; one home A) + ATMOSPHERE_HEIGHT consumer-list note.
2. `godot/core/aero_sky_gradient.gdshader`: uniform `u_space_out` (default 0.0 = conservative
   air floor); `ws = u_space_out` in sky_on() (was smoothstep(0,0.3,w)); all ws consumers
   unchanged; u_no_floor=0 contract + sky_off + thin untouched.
3. `godot/world/world.gd`: `_ac0439_space_out` state var; per-frame value-gated push of
   u_space_out in _ac0401_push block (3) alongside u_space_sky (same radial/seam/gate).
4. `godot/ARCHITECTURE.md`: sky-pass note + no_sky_floor Settings-row description synced.

### Light gates (all post-edit; heavy set = coordinator's)
- G0: rc=0, SCRIPT ERROR 0, SHADER ERROR 0 (census ok; exit status checked — the UAF pair).
- SMOKE player;interact;light;fluids;genhash: rc=0, 0/0, 5/5 RESULT lines.
- genhash: smoke run + standalone r2, BOTH 25/25 byte-identical to the current-tree reference
  (.scratch/HEAVY-r14/genhash.log, == .scratch/AC-0311-gates/p2_genhash_r1.log); r2 == smoke run
  (deterministic).
- PROBE meshprobe: ok=true, c_match 1866/1866, arr_match 32/32, compact_ok 32/32, rc=0, 0/0.
- shaderforce: rc=0, 0/0, 12/12 ok, failed []; aero_sky_gradient declared=27 params=27
  (u_space_out declared + pushed), verdict ok; Forward+ llvmpipe boot line present.

### Acceptance renders (all: xvfb+lavapipe vulkan, 1280,720, T=0.5, R50, drain 600, no
AWECRAFT_LOGIC, file-existence checked; step snaps s300/s600 settle the world)
- before-inside-h800.png (rc=0 229s): THE DEFECT REPRODUCED — rows 0-220 (above horizon) 57.7->
  123.3 blue+sun; rows 220-320 collapse to 0.0 (max raw step 37.81 = the sky-drawn boundary);
  rows 340-520 (below horizon) 0.00 FLAT BLACK; limbs 151.16; thirds 98.25/17.19/9.93.
- after-inside-h800.png (rc=0 229s, w=0.799): ONE CONSISTENT SKY — rows 340-520 248.4-248.8
  (air family, u_air), max raw step 1.43, step at horizon row 0.21, thirds 103.85/234.85/248.48,
  sky-region min 36.35 (NO black sky pixel).
- after-outside-limb2000.png (rc=0 334s, w=1.0, radial 2141): SPACE BELOW PRESERVED — black-space
  band rows 0-330 (rows 0-280 exactly 0.00, spread 0.00), 1624 stars in band, the ONLY big step
  21.12 at row 427 = the planet's limb; body disc rows 440+ (85-166).
- ab-off-inside-h800.png (NOSKYFLOOR=0, rc=0 226s): OFF contract held — row 0 identical (57.69),
  below-horizon 248.8-249.1 (the u_air floor at every altitude, pre-AC-0429), max step 1.43,
  thirds 103.62/232.47/248.48 (sub-2/255 anchor-family difference vs ON — display-invisible).
- Transition altitude: A = 1200 m radial (AWECRAFT_ATMO); window [1200,1500] m = the limb's
  0.25A tail. 941 m frame: ws = 0.0 exactly; 2141 m frame: ws = 1.0 exactly.

### Close
- plan.html (with the reproduced before frame), results page (self-contained, all numbers),
  measure.py (AC-0429 copy) + skyband.py (this ticket's sky-region census) in the ticket folder.
- FENCES respected: main.gd / game.gd / drop.gd / debug.gd untouched; AC-0067 / AC-0384 /
  AC-0425 untouched; no TASKS.yaml hand edit; no commit/push. Heavy gates + closeout =
  coordinator's.
