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

## Addendum — the review that changed the result

The images were re-checked with an image-capable view, which the earlier passes could not do. That review
found the worst defect in the whole ticket and invalidated numbers that had already been committed.

**The defect: forward kinematics subtracted the joint twice.** `world[i]` was built with a helper that
already returns `T(origin) · R · T(-joint)` — a rest→posed *point* transform — and the skin matrix then
multiplied by `restInv = T(-joint)` as well. At rest the skin matrix came out `T(-joint)` instead of the
identity, so every vertex was dragged to its own bone's joint. Every creature rendered as a featureless
lump the size of its torso, with no limbs.

It passed **every** gate: watertight, correctly oriented, every bone skinned geometry, no orphans, unit
normals, deterministic, animating, and 7/7 browser gates. What caught it was rendering a biped at a known
camera and looking — then confirming mechanically by reproducing the shader's transform on the CPU from the
buffers the shader actually reads (`boneData` + `aBi`/`aBw`): 1.815 units of mesh rendered 0.474 units tall.
The same rig offline gave 1.816.

**Consequences worth carrying forward:**

- Max edge stretch went from 2.4–10.1× to **1.09–1.86×**. The "honest residual" the writeup had been
  reporting as a property of the weights was entirely this bug.
- Three of the last five defects were **the verification measuring the wrong thing**, not the code being
  wrong: `project()` mirrored Y (NDC +1 is the top), the W1 gate asserted a *projected bounding box*
  instead of pixels and passed while the subject was 34×81 px in a 1440×860 frame, and the "per-primitive"
  debug view hashed the *part* index so it painted three flat colours.
- A "make it chunkier" dial (`BLOB_BULK = 1.9`) buried every limb inside the torso — the preset radii are
  base sizes the limb attachment points are laid out against, not free parameters. Back to 1.0.
- The claim "DQS buys nothing" was measured against the broken FK. With it fixed the offline mirror does
  separate (LBS 1.21–1.86× vs DQS 1.20–1.79×, better on four of five presets). The shader path stays out,
  but for the honest reason — the GPU implementation was never validated — not because the effect is zero.

**Lesson for the journal:** numeric gates find subtle structural faults no eye would catch, and the eye
finds catastrophic visual ones no number is asking about. Both are needed. A gate is only as good as its
question.
