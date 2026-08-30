## RUN — 2026-08-29 17:43:16 — AC-0143

- start: clean run (prior attempt died before any work).

## RUN — Sat Aug 29 18:16:01 EDT 2026 — AC-0143 (Stage A: sphere math library + probe)
- M1 (medium): writing godot/core/sphere_math.gd (pure static sphere math)
- M1a (medium): header + consts + face_for_dir
- M1a DONE: sphere_math.gd [42 lines] header + face_for_dir (fixed tie-break)
- M1b (medium): uv_to_world + world_to_face
- M1b DONE: sphere_math.gd now 83 lines (header + face_for_dir + uv_to_world + world_to_face)
- M1c (medium): world_to_face fix + _EDGES table F0-F3
- M1c DONE: world_to_face fixed (C=d/d_dom affine inverse) + _EDGES F0-F3 appended [file now open-ended, table continues next run]
- M1d (medium): _EDGES table F4-F7
- M1d DONE: _EDGES F4-F7 appended (table still open)
- M1e (medium): _EDGES F8-F11 + close + neighbor_key
