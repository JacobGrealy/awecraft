# AC-0090 — procedural primitive characters (Three.js prototype)

A standalone research prototype: characters generated from primitive shapes that read as **one seamless
body**, toon-shaded, animated entirely by a procedural locomotion rig. **This is not the Godot game** —
nothing here is game code and nothing under `godot/` is involved.

The design reasoning, the alternatives that were rejected, the measured results and the six defects that
numeric gates caught are in **`../../docs/ragdoll-character-style.html`**.

## Run it

ES modules cannot be loaded over `file://`, so serve the repository root and open the page:

```bash
python3 prototypes/ac-0090-ragdoll/serve.py          # binds 0.0.0.0:8177, prints every URL
```

then open <http://127.0.0.1:8177/prototypes/ac-0090-ragdoll/>.
`--host 127.0.0.1` keeps it local; the default binds all interfaces so another machine on the LAN can open
it too. No build step, no `node_modules`, no CDN — three.js is vendored under `vendor/three/` at a pinned
revision and the page works with the network off.

**Controls:** drag to orbit, wheel to zoom, shift-drag to pan. The panel switches quality tier,
character, speed, toon bands, and the two seam debug views.

## What to look at

| Control | What it shows |
|---|---|
| **Tier: `hard` → `smooth`** | The seam A/B on the *same vertex buffer*: raw primitives vs the baked joint blend. |
| **Tier: `remesh`** | The same body as one implicit surface (smooth-min distance field, polygonised). Bakes on the CPU — the stats panel reports the time and triangle count. |
| **`per-primitive`** | Flat colour per primitive, i.e. the construction you are trying to hide. |
| **`blend windows`** | Tints exactly the vertices whose skin weights mix two bones — where the seam work happens. |
| **`wireframe`**, **`joints`** | The geometry and the rig. |
| **seed slider** | Regenerates all five creatures from a new seed (deterministic). |

## Verify it

Two independent harnesses. Neither needs a GPU.

```bash
# 70 offline checks: watertightness, orientation, rest pose, weights, deformation, determinism
node prototypes/ac-0090-ragdoll/tools/meshcheck.mjs          # add --json for machine output

# browser gates W0..W5: load, render, seam A/B, animation per body plan, controls, perf
HOME=/tmp/dsh_home \
  PYTHONPATH=$HOME/.local/lib/python3.13/site-packages \
  PLAYWRIGHT_BROWSERS_PATH=$HOME/.cache/ms-playwright \
  python3 prototypes/ac-0090-ragdoll/tools/verify.py
```

`verify.py` writes `tasks/AC-0090/*.png` and `.scratch/AC-0090/report.json`.
The page exposes `window.__AC0090` (`info()`, `stats()`, `set()`, `camera()`, `pixelStats()`,
`seamMetric()`, `boneState()`) so the harness drives the same paths a person does — there is no test-only
code path in the prototype.

## Layout

```
index.html          page + import map (three.js from ./vendor)
src/mat4.js         column-major 4x4 math
src/rng.js          seeded deterministic PRNG
src/bodyplan.js     the plan structure: joints, shapes, part registration
src/presets.js      the five body plans + the seed dial
src/geom.js         tube/lump tessellation, arc-length skin weights, mesh packing
src/rig.js          bone frames, forward kinematics, skin matrices
src/anim.js         the procedural locomotion rig (2/N/0 legs, flyer)
src/metaball.js     implicit tier: distance fields + surface nets
src/shaders.js      skinning (LBS + dual quaternion) and the toon shader
src/skin.js         mesh -> drawable objects; the quality tiers
src/ui.js           the control panel
src/main.js         scene, camera, layout, control loop, test API
tools/meshcheck.mjs offline checks (node)
tools/verify.py     browser gates (playwright)
serve.py            static server for the repo root
```
