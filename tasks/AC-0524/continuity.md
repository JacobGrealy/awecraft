
## RUN — 2026-11-07 11:13:50 — AC-0524
- builder: measure-first endpoint colour parity (plan.html contract). Render set planned up front (see journal).
- Instrument: `.scratch/AC-0524/matrix.py` (ray→class, material labels from the AC-0512 census,
  signed normalized-linear near vs satellite, sky-like census) + `decode.py` (the 12 shipped faces,
  hue/ocean/height decode) + `endpoints.py` (the shipped-formula twin of both endpoints).
- Dev isolation (TEMPORARY, must be removed before close): `u_geom` in
  godot/core/satellite_body.gdshader + the env push in godot/world/satellite_body.gd
  (`AWECRAFT_AC0524_GEOM=1`) = flat magenta geometry map.
- Renders: `.scratch/AC-0524/render.sh` per case, chain `chain2.sh` (SERIAL, drain 600, R24/F83,
  seed 44, 1280x720, blur OFF). Set: a300-day a300-geom gnd-day gnd-dusk a300-night gnd-night
  a941-day. Skipped (stated): gnd-geom, a941-night.
- Baselines taken BEFORE edits: g0 0/0, genhash 25/25 == AC-0512 and AC-0513 sets, lightstate leaks 0.
- Findings so far: (1) decode re-verified clean (ocean/height rule exact, 0.23% hue-outside-FCC);
  (3)/(4) companding round trip x^1.03 (single companding, Linear tonemap once);
  (2) quantified: engine light (sun+ambient) multiplies the LIT satellite endpoint while the near
  endpoint is unshaded — ratio 1.70 day / 1.71 dusk / 0.78 night, sign flips with time.
- ANALYSED (`.scratch/AC-0524/matrix2.py`, vectorized; per-ray ray/sphere classes, census material
  labels, signed normalized-linear near vs satellite, AC-0512 sky model T=14, magenta geometry map):
  out-{a300-day,a300-geom,gnd-day,gnd-dusk,a300-night,gnd-night,a941-day}.json.
- (A)/(B), satellite tier past render_edge, 300 m day, signal = geometry map:
  grass 185,521 px -> sky-like 17,765, ALL 17,718 DRAWN (A), 47 absent (B);
  sand 15,232 -> sky-like 412 (380 drawn); water 11,670 -> sky-like 1,906 (ALL drawn);
  snow 34,283 -> sky-like 20,220 (ALL drawn). AC-0512's 61.4 % reproduces ONLY for snow/ice
  (59.0 % sky-like), NOT as a property of the exterior (grass 9.6 %, sand 2.7 %, water 16.3 %).
  941 m day: solid 259,900 px, sky-like 26,507 = 10.2 %. Near tier, ground vantage: grass-labelled
  341,737 px, chunk occupancy "drawn" 341,737, sky-like 341,561 (99.9 %) - chunk-level signal.
- CAUSE (suspect 2, demonstrated): satellite grass at 300 m day renders linear (0.600,0.843,0.819)
  luma 0.790 vs its own baked intent (0.037,0.135,0.015) luma 0.107 (+0.68, hue toward the blue
  ambient/air) at haz_a 0.087; at night the same cell is ~22x DARKER than the matched near pair.
  Lit satellite (engine sun + BLUE ambient + air mix) vs unshaded near. (1)(3)(4) clean.
- FINDING (instrument): AC-0512's gaps.py fed the WORLD point to SphereMath's face/home mapping;
  the chart is SPHERE-LOCAL (centre (0,-R,0)) - its per-ray census lookups were frame-shifted.
- Gates on the clean tree (isolation removed): g0 0/0, genhash 25/25 == AC-0512 + AC-0513 sets,
  lightstate leaks 0 in every cell, low_on_high_n=0, all arms ok.
