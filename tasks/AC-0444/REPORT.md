AC-0444 — the teal band in the sky
WHERE: the lod_avg far LOD tier, its a=0 (unlit/side) faces = the AC-0443 "R24 horizon
  dark patch"; distant boxes' sides edge-on above the horizon: dark (41,62,69) where the
  sky model computes bright (208,240,250).
PROOF: lod_avg->magenta turns the whole band magenta; a=1->cyan/a=0->magenta isolates the
  band to the a=0 faces; fog off empties the region => far tier (and band) is fog-gated.
SYMPTOM? NO: not the sky (aero0 keeps it; sky is bright there), not clouds (0443), not body
  (body0 identical), not limb (limb0 identical). The 5 sky fixes (0417/0419/0422/0429/0439)
  never touch far-tier face shading => far-LOD/tier-seam artifact, not sky accumulation.
BAND-GONE: not patched (a symptom-hiding patch is not wanted); known cloud-independent
  far-LOD artifact. Consolidate by closing the tier seam: shade far-tier a=0 faces to the
  chunk_lit shaded brightness (u_amb is a partial parity, not a closure) = far-LOD ticket.
FIVE FIXES HOLD: limb@A smooth (0417); bright day sky + opaque planet (0419); continuous
  horizon dL=0 (0422); below-hz space, no bottom edge (0429); below-hz air (205,250,250) (0439).
GATES (light): SMOKE rc=0, 0 err, ok:true; genhash 25/25 byte-identical to current baselines
  (HEAVY-r22/AC-0441/AC-0439-r2; the AC-0367 ref is stale); shaderforce rc=0 ok 12/12; G0
  census 0 SCRIPT/SHADER ERROR, all rc=0.
NOTES: all probes reverted (git diff clean on the world/shader files); fences untouched;
  no commit/push (coordinator's closeout).
