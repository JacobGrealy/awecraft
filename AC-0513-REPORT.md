# AC-0513 — Feasibility report: two-source pre-tonemap HDR/depth composite on Godot 4.7.1

**Verdict: REJECTED on two independent, API-level blockers.** The technique described in
`docs/satellite-lod-handover-plan.html` (§p0/pipeline/blend) cannot be built on this engine version as
specified. This is the outcome the plan pre-authorised (*"P0 is explicitly allowed to reject it"*).

Engine: **4.7.1-stable (official)**, hash `a13da4feb8d8aefc283c3763d33a2f170a18d541`.
All figures below are from **llvmpipe (software Vulkan) on Linux**, i.e. **development-only**; see §6 for
what remains unproven on real hardware.

---

## 1. What was built

An **isolated** Godot fixture (separate scene in `godot/fixtures/`, untracked, **unreachable from
`main.tscn`**) implementing the plan's two-source architecture: two `SubViewport` sources, a
`CompositorEffect` export of pre-tonemap colour and resolved depth into owned `RGBA16F` textures via
`RenderSceneBuffersRD`, and a resolve that blends them.

**The product is untouched:** `g0` rc=0 with 0 script / 0 shader errors, **genhash 25/25 byte-identical**
to the reference set, and the fixture cannot be reached from the shipped scene.

Evidence: `tasks/AC-0513/AC-0513-results.html`, `AC-0513-deviations.txt` (D1–D20),
`tasks/AC-0513/continuity.md`. Logs: `.scratch/AC-0513-gates/`.

---

## 2. The instrument IS proven — this is not a broken measurement

The filing's decisive gate is the **linear 0/1 midpoint** of a two-source blend, acceptance **0.5 ± 0.002**.

**Measured: `0.500000`, 8 of 8 samples**, read back from the pre-tonemap `R16G16B16A16_SFLOAT` export.

The contrast values are what make it a proof rather than a coincidence — the same endpoints blended at
other stages give visibly different midpoints:

| blend stage | midpoint |
|---|---|
| **pre-tonemap linear (measured)** | **0.500000** |
| 8-bit display, decoded | 0.502886 (188/255) |
| **sRGB-domain blend** | **0.214041** |
| **AGX post-tonemap** | 0.398039 (vs 0.674510 pre-tonemap, **−0.2765**) |

So the fixture demonstrably measured the correct stage, and **would have failed had it measured any other.**
Everything in §3 is therefore a finding, not an artifact of a broken harness.

> Note: an earlier round of this ticket mis-wired the blend band (the satellite half read 0), which produced
> no midpoint at all. That was a fixture defect, now repaired — it is **not** the basis of the rejection.

---

## 3. BLOCKER 1 — 4.7.1 exposes no handle on "this frame's source texture"

**The requirement:** the resolve must read both sources' textures *from the frame they were rendered in*.
The plan is explicit that *"a merely coincidental child-node order or an `await process_frame` is not a
render graph."*

**Measured lag census (after repairing an earlier defective echo instrument that had been sampling the
wrong pixel):**

- **lag-0 in `0` of `599` frames**, from **both** sources.
- Parity held **599/599** on both sources (so the sources agree with each other).
- The echo instrument matches a CPU-read texel **exactly**, i.e. the instrument is sound.
- The **echo always lands one frame behind**, with `UPDATE_ALWAYS` set.

**Configurations tried, all failing to produce a single lag-0 frame:**

- source-viewports-created-first vs main-camera-created-first (this only shifts the failure *mode*, 7 → 25)
- `POST_SKY` callback
- `POST_TRANSPARENT` callback
- `SubViewport.update()` forced
- `render_priority` ordering
- cull-mask separation
- a shared `WorldRoot`

**Conclusion:** there is no API surface in 4.7.1 that lets a `CompositorEffect` observe *this frame's*
source texture from a separately-rendered `SubViewport`. The dependency is not merely implicit — it is
**one frame stale by construction**, and a one-frame-stale terrain composite is exactly the class of artifact
the handover work exists to eliminate.

---

## 4. BLOCKER 2 — a fullscreen pass publishes its GEOMETRIC depth, never the `DEPTH` it assigns

**The requirement:** the resolve must write a *chosen* depth for the terrain it composites, so that
subsequent passes (actor occlusion, water, refraction) test against it. The plan: *"assigns source-derived
`DEPTH` on every non-discard branch."*

**Measured:** an opaque prepass quad placed at world **−40.000** with `depth_draw_never`, read back through a
transparent reader. Result: **raw `0.00242948` → 41.16 m, a `+1.16 m` error, in EVERY sub-case** — including
the decisive one where the pass **explicitly assigns `DEPTH` 40.000 while its geometry sits 1 m away**.

**So the assigned `DEPTH` is discarded and the geometric depth is published instead.** The resolve can never
hand a chosen depth downstream, which defeats its core purpose.

This is **not** a precision problem: the 24-bit quantum at 40 m is **0.0954 mm**, and the observed error is
**1.16 m** — three orders of magnitude larger. The semantics, not the format, are the blocker.

---

## 5. Everything else, so the work is not lost

These are measured results from the same fixture and are reusable if the architecture is revisited or replaced.

**Works:**
- **Main-pass depth readers** — screen `DEPTH_TEXTURE` plus an encoded colour channel both read correctly,
  **with the requirement that the reader be transparent** (an opaque reader with `hint_depth_texture` sees the
  Forward+ depth-prepass **clear value** instead).
- **Water colour composite** — resolves; solved offsets **−0.36 / +0.098 / +1.46 mm**. (Depth side inherits
  blocker 2.)
- **Window resize** — **100 cycles**, export copy intact at every sampled cycle. (RD allocation counters are
  unavailable on llvmpipe.)
- **Teardown** — clean exit, objects 1706 → 1683, resources 27 → 26.
- **Alpha-tested foliage, colour side** — proven both directions. **The correct alpha mode is
  `TRANSPARENCY_DISABLED` + `alpha_scissor_threshold`**; with `TRANSPARENCY_ALPHA_SCISSOR` the leaves vanish
  entirely. **Depth side fails at −919 mm** at all four sample points, because an alpha-scissored plane writes
  no depth (an instance of blocker 2).

**Partial:**
- **Actor occlusion** — far actors are occluded correctly in **both** draw orders; **near** actors survive only
  in the **late** order, and only with `depth_test_greater`. So occlusion is draw-order dependent.

**Fail:**
- Same-frame source read (blocker 1).
- Chosen-depth publication (blocker 2).
- ≤ 1 mm depth error — **not met**; measured +1.16 m, and the cause is blocker 2 rather than precision.

---

## 6. What llvmpipe CANNOT answer — re-test these on hardware

Do not treat the two blockers as permanent until they are re-checked on a real GPU. Every item below is
**unmeasured**, not merely unconfirmed:

1. **Whether real hardware can show lag-0.** The census was 0/599 on llvmpipe with every configuration tried;
   a hardware run is the only way to know if the API behaves differently.
2. **Timing**, in any form — the copy measured **0.186 ms/frame at 640×360** on llvmpipe, which is not
   predictive of product cost.
3. **The depth-buffer format** behind the +1.16 m offset — llvmpipe's choice may not be the product's, though
   the error's magnitude (three orders above the 24-bit quantum) suggests it is not a format issue.
4. **Leak counts** — `get_driver_allocation_count` returns **0 / −1** here, so "no leaks" is unproven.

---

## 7. API facts this work settled (worth not rediscovering)

Each cost real time to find:

- **A `SubViewport` must be given its shared `World3D` AFTER `add_child`.** Set it *before*, and the viewport
  renders its own **empty world** and **every source sample reads 0** — a silent, total failure.
- **`shader_compile_spirv_from_source` rejects GDGLSL markers**; raw GLSL only.
- **Compute lists are handle-based**, and `compute_list_end()` takes **no** handle argument.
- **`RDUniform` has only `type` / `binding` / `add_id`.** `UNIFORM_TYPE_SAMPLER_WITH_TEXTURE` takes the
  **sampler id first, then the texture id**.
- **`return` is illegal inside `fragment()`.**
- **The scene colour RID is sampleable but not copyable.**
- **4.7.1 has 29 sRGB `DataFormat`s of 233** — an earlier round's "no sRGB format exists" was wrong.
- `CompositorEffect` **exists** with `set_access_resolved_color` / `set_access_resolved_depth`;
  `RenderSceneBuffersRD` **exists** with `create_texture` / `create_texture_view` / `get_color_texture` /
  `get_depth_texture`. The APIs are present — the *semantics* are what fail (§3, §4).

---

## 8. What this means for the plan, and options

**The plan's architecture assumed two capabilities that 4.7.1 does not provide.** Before any further
handover work, one of these has to be chosen deliberately:

1. **Accept a one-frame-stale composite.** Cheapest, and the plan already tolerates a small transition; but a
   one-frame lag under fast rotation is a *moving* seam, which is worse than the static one being fixed. If
   chosen, it must be measured under rotation rather than accepted on paper.
2. **Abandon the separate-source approach** and render the satellite tier **in the same viewport** as the detail
   terrain, resolving via depth in a normal material. Gives up independent scheduling and per-source resolution,
   but sidesteps both blockers entirely — no cross-frame texture, no assigned-depth publication.
3. **Change engines / wait for an API** that exposes this-frame source textures and assigned-depth publication.
   The blockers are version-level, so this is the honest option if the architecture is non-negotiable.
4. **Narrow the goal**: `AC-0512` measured that **61.4% of the exterior "gaps" are endpoint COLOUR mismatch**,
   not missing geometry. That may be fixable in the existing single-source renderer — cheaper than either
   composite architecture, and it addresses the largest measured share of the visible defect.

**Recommendation for the next agent:** read `AC-0512`'s classification before committing to any composite
architecture. The largest measured component of the problem may not require one at all.
