# AC-0090 — continuity journal (append-only)

Ticket: `threejs-procedural-ragdoll-character-style` — a Three.js **web** prototype, separate from the
Godot game. No `godot/` file was touched.

## Resume point

**Done.** The prototype, both harnesses and the writeup are complete.

| | |
|---|---|
| Prototype | `prototypes/ac-0090-ragdoll/` — static, offline, no build step, no `node_modules`, no CDN |
| Run it | `python3 prototypes/ac-0090-ragdoll/serve.py` → <http://127.0.0.1:8177/prototypes/ac-0090-ragdoll/> |
| Offline gates | `node prototypes/ac-0090-ragdoll/tools/meshcheck.mjs` — **80 checks, 0 failures** |
| Browser gates | `python3 prototypes/ac-0090-ragdoll/tools/verify.py` — **7 gates, all pass, exit 0** |
| Evidence | `tasks/AC-0090/AC-0090-results.html` + 17 PNGs |
| Reasoning | `docs/ragdoll-character-style.html` |

To reproduce the browser gates, the Playwright environment needs:

```
HOME=/tmp/dsh_home \
PYTHONPATH=/home/angrygiant/.local/lib/python3.13/site-packages \
PLAYWRIGHT_BROWSERS_PATH=/home/angrygiant/.cache/ms-playwright \
python3 prototypes/ac-0090-ragdoll/tools/verify.py
```

`node` is only at `$HOME/.nvm/versions/node/v24.19.0/bin`, not on `PATH`.

## Chronology

1. **Framed the problem and chose the technique.** Three failure modes (intersection crease, butt joint,
   joint tear) and four candidate fixes. Chose the *tube envelope* — one tapered tube spanning a limb's
   whole joint chain — with the implicit-remesh approach kept as a second quality tier so the comparison
   would be a button rather than a claim.

2. **Built the body generator.** A plan is joints + shapes + locomotion wiring; five presets (biped,
   quadruped, hexapod, hopper, flyer) exercise the body-plan space. Seeded and deterministic.

3. **Built the rig, weights and shaders.** Arc-length joint weights baked into the vertex buffer, toon
   bands, rim, inverted-hull outline, three quality tiers, a debug view per primitive and a blend-window view.

4. **Built two harnesses before trusting any picture.** 80 offline geometry checks and 7 browser gates.

5. **The gates found a dozen real defects, all of which survived a screenshot.** In order of discovery:
   inverted winding (a *relative* volume is not an orientation test), identity bind pose, double-counted FK
   offset, three weight-indexing bugs, a scratch buffer aliasing its own input, a cap fan skipping a ring,
   pole rings emitted as coincident points, and an inverted superellipsoid bound. Full list and symptoms:
   `docs/ragdoll-character-style.html` §9.

6. **Found the last and worst defect by bypassing the screenshot.** The body mesh was never drawn: its
   model matrix was never assigned, so it rendered at the world origin while its object sat 4.9 units away,
   and only the outline hull appeared. The scene graph was correct, the projection maths was correct, the
   shader compiled and linked, `gl.getError()` was 0 and the console was silent. What found it was dumping
   the shader uniforms and comparing `uModel` against `matrixWorld`, then confirming with a plain
   `MeshBasicMaterial`, which drew immediately.

7. **Repaired the harness's own dishonest gates.** Two gates could not fail: a DQS-vs-LBS assertion whose
   two sides returned the same number to four decimals, and a seam metric comparing two arms that read the
   same geometry attribute. Both were replaced; the unsupportable DQS claims were deleted rather than
   tuned. The determinism check was logged but never stored in the report and never affected the exit code
   — it is now a real gate.

8. **Final state:** 80 offline checks and 7 browser gates pass; the browser run exits 0.

## Things worth not re-learning

- **A page that renders nothing can have a perfectly healthy scene graph.** Check uniforms against object
  transforms before believing "nothing renders", and bisect by swapping in a `MeshBasicMaterial`.
- **The WebGL drawing buffer is discarded after presentation.** Reading it back from a later task returns
  stale or empty content. `main.js` takes `?preserve=1` for that reason; the harness uses real screenshots
  for evidence instead, which cannot lie about what is on screen.
- **A gate whose two sides cannot disagree is worse than no gate.** Read the numbers, not the pass column.
- **Never use `/tmp` for scratch copies of source in this repo** — it is swept between tool calls. Work
  under `.scratch/AC-0090/`.
- **Never slice a file by two string indices without checking what is between them.** A `s[a:b]`
  replacement silently deleted ~500 lines of `geom.js` that lived between the two anchors, and the file was
  untracked so git could not recover it.
