# AC-0524 — Windows Forward+ descent/ascent protocol (handover, not evidence)

**Why this exists.** The scope requires Windows Forward+ descent/ascent evidence. This box is
Linux + **llvmpipe** (software Vulkan), a development proxy: every figure in
`AC-0524-results.html` is labelled **development-only** and none of it is a shipped-appearance
claim. This protocol is the product-side measurement, to be run on the Windows Forward+ build.

**Product build.** `./build_windows.sh` (real HOME, export templates
`~/.local/share/godot/export_templates/4.7.1.stable`), Forward+ (project.godot
`renderer/rendering_method="forward_plus"`, `tones_mapper=0` = Linear).

## 1. Poses (identical to the development set)

User config on every shot: `AWECRAFT_RADIUS=24`, `AWECRAFT_FOG_PCT=83` (fog_far 332 /
render_edge 400), seed 44, `AWECRAFT_CLOUDS=0`, `AWECRAFT_SIZE=1280,720`,
**blur OFF** (never enable DoF — it destroys the colour measurement),
`AWECRAFT_SNAP_DRAIN=600`, `AWECRAFT_AC0512=1 AWECRAFT_AC0512_ALT=100` (the census).

| id | env | carries |
|---|---|---|
| `gnd-day` / `gnd-dusk` / `gnd-night` | `AWECRAFT_AIM=8.5,143.5,8.5,-0.38,0.10`, `AWECRAFT_TIME=0.5 / 0.75 / 0.0` | near tier + local horizon + satellite tier at the same materials |
| `a300-day` / `a300-night` | `AWECRAFT_CAM=air AWECRAFT_AIR_ALT=300 AWECRAFT_AIR_PITCH=30`, `AWECRAFT_TIME=0.5 / 0.0` | the handover annulus + the body disc |
| `a941-day` | same, `AWECRAFT_AIR_ALT=941` | the user's documented flight altitude (AC-0449) |
| `*-geom` | the same pose + `AWECRAFT_AC0524_GEOM=1` | the geometry-presence map (dev isolation; **present only if the isolation is still in the tree**) |

## 2. Descent (flying down: satellite tier → detailed terrain)

1. Load the world, fly to 941 m, settle 60 s, then descend at ~10 m/s through
   941 → 500 → 400 → 332 → 200 → 60 m, **without stopping** (the handover is a
   motion measurement; a static A/B at each stop is not the same test).
2. Record 1 frame per second at 1280×720 (`AWECRAFT_SNAP_STEPS` style multi-snap,
   or an external capture) into `AC0524/descent/`.
3. Per frame, run the same instrument (`python3 .scratch/AC-0524/matrix.py`):
   the near/solid pixel classes, the per-material linear colours, the signed
   satellite − near difference, and the census occupancy counters.
4. **Acceptance (per case, not as one aggregate):**
   * the signed normalized-linear difference at a matched material crossing
     `render_edge` → `fog_far` stays inside the stated threshold
     **|Δluma| ≤ 0.05 linear** (the development set's accepted threshold — see
     results page §5), with no frame above 0.10;
   * no **brightness flash**: the frame-to-frame luma jump at the tier crossing
     ≤ 0.05 linear, and the crossing is monotone (no overshoot);
   * no blue veil: the satellite-tier blue-minus-red channel excess at a grass /
     sand / snow cell ≤ 0.03 linear (a water cell is blue by material, so it is
     measured against its own near-tier water, never against the sky).

## 3. Ascent (the reverse)

Same poses, ascending 60 → 941 m at the same speed, same per-frame instrument
run. The descent and ascent series must agree within 0.03 linear at matched
altitudes (the hysteresis check — a publication/attach lag shows up here, not
in the colour).

## 4. The (A)/(B) control on the product

* the census occupancy counters (the AC-0512 arm) give the per-ray chunk truth;
* the dev geometry map (`AWECRAFT_AC0524_GEOM=1`, if the isolation is still in
  the tree) gives the empirical geometry truth;
* `AWECRAFT_SAT_BODY=0` (the accepted AC-0512 negative-control fixture) gives the
  "exterior absent by construction" control.
Report each material/time cell with its counts and its signal named. **Do not
publish an aggregate "x% of the exterior" figure as a general property** —
AC-0512's 61.4 % is one pose, one frame, one seed.

## 5. Reporting

Every Windows figure is labelled product; every figure from this box is labelled
development-only. If the Windows numbers differ from the development numbers, the
difference is the finding — do not blend them.
