# AC-0513 — HDR/depth prototype feasibility (journal)

## Coordinator pre-work (round 121): the 4.7.1 API REFLECTED FROM THE ENGINE, not from docs

The filing and the shared plan both demand that API semantics be "recorded from Godot 4.7.1, not inferred from an older documentation page". Done before handing to a builder, because it is cheap (a headless reflection probe, no render) and it decides whether the whole technique is even available.

**Probe:** `.scratch/AC-0513/apiprobe.gd`, run as `godot --headless --path godot -s ../.scratch/AC-0513/apiprobe.gd`. Engine reports **`4.7.1-stable (official)`**, hash `a13da4fe…`.

**Results — the three classes the prototype depends on all EXIST:**
- **`CompositorEffect` EXISTS, 15 methods:** `_render_callback`, `set_effect_callback_type`, `set_access_resolved_color`, `set_access_resolved_depth`, `set_needs_motion_vectors`, `set_needs_normal_roughness`, `set_needs_separate_specular`, plus the enabled accessors. **So both "access resolved colour" and "access resolved depth" are first-class switches** — which is the good case for the plan's pre-tonemap requirement: the engine offers the resolved-colour/depth access the prototype needs rather than requiring a guess.
- **`RenderSceneBuffersRD` EXISTS, 27 methods**, including `create_texture`, `create_texture_view`, `get_color_texture`, `get_depth_texture`, `get_render_target`, `get_internal_size`, `get_target_size`, `get_texture_slice`, `clear_context`, and the scaling/AA/taa/debanding accessors. So owned-export copies (the plan's "copy borrowed scene buffers into stable render-thread-owned exports") are supported by `create_texture`/`create_texture_view`.
- **`Compositor` EXISTS** (`set_compositor_effects`, `get_compositor_effects`) — so attaching an effect to a viewport is possible.
- `RenderSceneDataRD` reported **0 methods** through `ClassDB.class_get_method_list(cls, true)`; that is likely an introspection quirk (a singleton-ish or abstract class) rather than proof it has no API. **The builder should probe it directly rather than trusting this line.**

**What this does NOT settle, and the builder must still measure:** the actual **callback enum semantics** (`set_effect_callback_type` — which point is pre-tonemap), whether the resolved colour/depth are genuinely pre-tonemap at that callback, **reverse-Z depth convention**, same-frame SubViewport dependency ordering, and everything about water/refraction channel reading. Existence of the API is not proof of the *semantics* the plan requires — that distinction is the whole reason this ticket exists.

**The 0.5 ± 0.002 midpoint test remains the decisive measurement** and is unaffected by any of the above.

---

## Builder round 2 — measurement run (2026-11-05, dev box, llvmpipe)

**Resume point.** The fixture measures and reports; it is not a product change and
the product is unchanged (`g0 rc=0 census 0/0`, genhash 25/25 identical to the
current tree's reference sets AC-0512/AC-0511/AC-0527/AC-0485). Authoritative run:
`.scratch/AC-0513-gates/fixture-fullE.log` (1250 frames, 11 phases); evidence page
`tasks/AC-0513/AC-0513-results.html`; measurement deviations D9–D14 appended to
`AC-0513-deviations.txt`. Nine verdicts are recorded with numbers; none of them is
proven on real hardware.

**Measured verdicts (short form).** (1) same-frame source read: NOT proven — measured
one-frame lag (parity census: det 598/599 inverted, sat 299/599 alternating) with
`UPDATE_ALWAYS`; (2) pre-tonemap HDR read: the channel WORKS (compute copy → owned
RGBA16F → `texture_get_data`, status ok, 0.186 ms/frame at 640×360), the 0.5 midpoint
gate NOT met (export reads 1.0; the fixture's blend band carries 0 in the satellite
half — a wiring defect to repair); (3) reverse-Z confirmed, ≤1 mm NOT met — a
transparent fullscreen pass publishes its geometric depth, not the `DEPTH` it assigns;
(4) actor occlusion order-dependent (near actor survives only in the late order,
with `depth_test_greater`); (5) main-pass depth readers work (screen `DEPTH_TEXTURE`
+ encoded colour channel); (6) alpha-tested foliage proven both ways (leaf cells draw,
cut-out cells expose the resolve); (7) water colour composite resolves (mm solved
−0.36/+0.098/+1.46), depth composite needs the gate-3 fix; (8) 100 resize cycles ran
with the export copy ok at every sampled cycle, RD counters unavailable on llvmpipe;
(9) teardown measured (objects 1706→1683, resources 27→26, clean exit).

**API facts this run settled** (all in D9–D14, all dev-only): GDGLSL markers are
rejected by `shader_compile_spirv_from_source` (raw GLSL only); compute lists are
handle-based and `compute_list_end()` takes no handle; `RDUniform` is
type/binding/add_id only (`UNIFORM_TYPE_SAMPLER_WITH_TEXTURE` = sampler id then
texture id); `return` is illegal in `fragment()`; a `SubViewport` must be given its
shared `World3D` **after** `add_child` (before → it renders its own empty world and
every source sample reads 0); the scene colour RID is sampleable but not copyable.

**Open, in priority order for the coordinator.** (a) repair the fixture's blend-band
wiring so the midpoint gate produces a number (satellite half reads 0 in R,G);
(b) close the same-frame dependency and re-measure the parity census; (c) publish
terrain depth through geometry (depth prepass) and re-run the ≤1 mm case at the 24-bit
quantum (0.0954 mm at 40 m); (d) swap the fixture's leaf/hole sample points (labels
inverted vs the 4×4 texture layout); (e) every number above needs a hardware-GPU
re-measure — llvmpipe cannot answer timing, depth-buffer format, or leak-count
questions (`get_driver_allocation_count` returns 0 here).
