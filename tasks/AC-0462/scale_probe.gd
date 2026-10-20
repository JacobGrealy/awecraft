# AC-0462b — the scale probe: which world->cell conversion matches the mesh?
#
# Standalone SceneTree tool (no game tree, no autoloads — plan §2). Run:
#   HOME=/tmp/dsh_home ~/tools/godot/godot --headless --path godot \
#       -s tasks/AC-0462/scale_probe.gd
#
# GROUND TRUTH (plan §6 — stated, as the plan requires): each sample point
# sits inside a known cell of the chunk transform
# SphereMath.face_chunk_transform(face, ccx, ccz, R) — the transform the
# FACE CHUNK NODE carries (world.gd:15363 sets c.transform to exactly it),
# i.e. the transform that places the mesh's 16x16 local cell grid. The
# truth is NOT the warp/canonical pointwise model (PlanetGrid.cell_to_world
# is preloaded per plan §2 and would measure a different question); the
# warp, the shipped default, pulls the LSQ placement onto the chart within
# the fit residual (~0.4 m << 1 cell at these chunks), so that difference
# cannot flip which candidate wins — if the numbers ever say otherwise,
# the table shows it.
#
# SAMPLES: every cell of the sample chunks — face 5 (mirror class) and
# face 11 (non-mirror class), ccx/ccz in {0, 1, 31, 63} (63:63 is the
# boundary chunk the faceedit arm lands on), R = 4000. For a cell (iu, iv)
# the local square is (lx, lz) = (face_local_x(face, iu, ccx), iv & 15);
# the sample is the local centre plus a 0.3 in-cell offset, on the chunk
# plane (local y = 0), mapped to world by B. The anchor is the sample's
# OWN chunk — the same construction world.player_anchor does after its
# world_to_face lookup (world.gd:15249-15254): origin B.origin, basis
# columns ALREADY divided by the nominal face_cell_scale (bx = B.basis.x /
# sc.x). Each candidate of plan §3 then recovers a cell from the point,
# with the ccx*16/ccz*16 + AC-0462-fix mirror form (player.gd:2830-2831)
# applied before comparison to the true absolute column. Error = Chebyshev
# distance in cells on the absolute u/v columns.
#
# NEGATIVE SELF-CHECK (the instrument can fail): a deliberately broken
# conversion (the shipped form + 5 u-cells) is also evaluated; the probe
# fails if it does NOT read non-exact.
extends SceneTree

const SM := preload("res://core/sphere_math.gd")
const PG := preload("res://core/planet_grid.gd")  # plan §2: preloaded (reference)

const R := 4000.0
const FACES := [5, 11]        # mirror class / non-mirror class
const CHUNKS := [0, 1, 31, 63]
const IN_CELL := 0.3          # in-cell offset from the local centre, cell units
const NEG_OFFSET := 5.0       # the negative self-check's deliberate u error, cells
const CANDS := ["shipped", "no_second_div", "norm_basis", "raw_nominal"]


func _blank() -> Dictionary:
	var out := {}
	for k in CANDS + ["negative_broken"]:
		out[k] = {"n": 0, "sum": 0, "worst": 0, "exact": 0}
	return out


# AC-0462-fix absolute-column form (player.gd:2830-2831): the local [0,16)
# cell coordinate -> the absolute face column, x flipped on the mirror class.
func _abs_cols(mirror: bool, ccx: int, ccz: int, l: Vector3) -> Vector2:
	var ax: float = float(ccx) * 16.0 + (16.0 - l.x if mirror else l.x)
	var az: float = float(ccz) * 16.0 + l.z
	return Vector2(ax, az)


func _err(a: Vector2, iu: int, iv: int) -> int:
	var cu: int = int(floorf(a.x))
	var cv: int = int(floorf(a.y))
	return maxi(absi(cu - iu), absi(cv - iv))


func _acc(d: Dictionary, k: String, e: int) -> void:
	d[k]["n"] += 1
	d[k]["sum"] += e
	d[k]["worst"] = maxi(d[k]["worst"], e)
	if e == 0:
		d[k]["exact"] += 1


func _summarize(d: Dictionary) -> Dictionary:
	var out := {}
	for k in CANDS:
		var s: Dictionary = d[k]
		out[k] = {
			"worst_cells": s["worst"],
			"mean_cells": float(s["sum"]) / float(s["n"]),
			"exact_frac": float(s["exact"]) / float(s["n"]),
			"n": s["n"],
		}
	return out


func _initialize() -> void:
	var t0 := Time.get_ticks_msec()
	var total := 0
	var truth_recover := 0
	var fails: Array = []
	var notes: Array = []
	var cand_all := _blank()
	var cand_face: Dictionary = {}
	var scales: Dictionary = {}
	for f in FACES:
		cand_face[str(f)] = _blank()
		var cf: Dictionary = cand_face[str(f)]
		for ccx in CHUNKS:
			for ccz in CHUNKS:
				var B: Transform3D = SM.face_chunk_transform(f, ccx, ccz, R)
				var sc: Vector2 = SM.face_cell_scale(f, R)
				var mirror: bool = SM.face_mirror_x(f)
				var bx := B.basis.x / sc.x   # player_anchor's pre-divided column
				var bz := B.basis.z / sc.y
				var ex2: float = B.basis.x.length_squared()
				var ez2: float = B.basis.z.length_squared()
				# Per-chunk scale report (plan §3 last bullet): the three
				# lengths the disagreement is between.
				var iu_mid: int = ccx * 16 + 8
				var c_a: Vector3 = B * Vector3(float(SM.face_local_x(f, iu_mid, ccx)) + 0.5, 0.0, 8.5)
				var c_b: Vector3 = B * Vector3(float(SM.face_local_x(f, iu_mid + 1, ccx)) + 0.5, 0.0, 8.5)
				scales["%d:%d:%d" % [f, ccx, ccz]] = {
					"basis_x_len": B.basis.x.length(),
					"sc_x": sc.x,
					"spacing_u": c_b.distance_to(c_a),
				}
				for lx in range(16):
					var iu: int = ccx * 16 + (15 - lx if mirror else lx)
					for lz in range(16):
						var iv: int = ccz * 16 + lz
						var p: Vector3 = B * Vector3(float(lx) + 0.5 + IN_CELL, 0.0, float(lz) + 0.5 + IN_CELL)
						total += 1
						var o: Vector3 = p - B.origin
						# The four candidates of plan §3 (y = o·bn for all four —
						# identical across candidates, so x/z columns are the comparison).
						var locals: Array = [
							["shipped", Vector3(o.dot(bx) / sc.x, 0.0, o.dot(bz) / sc.y)],
							["no_second_div", Vector3(o.dot(bx), 0.0, o.dot(bz))],
							["norm_basis", Vector3(o.dot(B.basis.x) / ex2, 0.0, o.dot(B.basis.z) / ez2)],
							["raw_nominal", Vector3(o.dot(B.basis.x) / sc.x, 0.0, o.dot(B.basis.z) / sc.y)],
						]
						for ce in locals:
							var a: Vector2 = _abs_cols(mirror, ccx, ccz, ce[1])
							_acc(cand_all, str(ce[0]), _err(a, iu, iv))
							_acc(cf, str(ce[0]), _err(a, iu, iv))
						# Negative self-check: shipped + a deliberate 5-cell u error.
						var an: Vector2 = _abs_cols(mirror, ccx, ccz, locals[0][1])
						_acc(cand_all, "negative_broken", _err(Vector2(an.x + NEG_OFFSET, an.y), iu, iv))
						# Ground-truth sanity: the CONSUMER's own path (world_to_face —
						# the chart map the anchor derives cells through, as
						# world.player_anchor does at world.gd:15231) must recover the
						# same cell for the same point, or the truth is suspect.
						var wf: Dictionary = SM.world_to_face(p + Vector3(0.0, R, 0.0), R)
						if int(wf["face"]) == f \
								and int(floorf(float(wf["u"]) * 1024.0)) == iu \
								and int(floorf(float(wf["v"]) * 1024.0)) == iv:
							truth_recover += 1
	var res: Dictionary = {
		"R": R,
		"ground_truth": "face_chunk_transform(face, ccx, ccz, R) — the face chunk node transform (world.gd:15363) that places the mesh's 16x16 local cell grid; NOT the warp/canonical model (plan §6)",
		"samples": total,
		"truth_recover": truth_recover,
		"candidates": _summarize(cand_all),
		"candidates_face": {},
		"scales": scales,
		"negative_self_check": {
			"description": "shipped + " + str(int(NEG_OFFSET)) + " u-cells; exact_frac < 0.5 proves the instrument can fail",
			"worst_cells": cand_all["negative_broken"]["worst"],
			"mean_cells": float(cand_all["negative_broken"]["sum"]) / float(cand_all["negative_broken"]["n"]),
			"exact_frac": float(cand_all["negative_broken"]["exact"]) / float(cand_all["negative_broken"]["n"]),
		},
		"fails": fails,
		"notes": notes,
	}
	for f in FACES:
		res["candidates_face"][str(f)] = _summarize(cand_face[str(f)])
	if total != FACES.size() * CHUNKS.size() * CHUNKS.size() * 256:
		fails.append("sample_count %d != expected" % total)
	if truth_recover < total:
		fails.append("truth_recover %d/%d — the consumer's own world_to_face does not recover the truth cell everywhere" % [truth_recover, total])
	if res["negative_self_check"]["exact_frac"] >= 0.5:
		fails.append("negative_self_check exact_frac >= 0.5 — the instrument cannot discriminate")
	var exact_names: Array = []
	for k in CANDS:
		if res["candidates"][k]["exact_frac"] >= 1.0:
			exact_names.append(k)
	if exact_names.is_empty():
		notes.append("no candidate is exact on every sample — the per-candidate table plus the per-chunk scales are the deliverable (plan §4); see the results page for what that implies")
	else:
		notes.append("exact candidates: " + ", ".join(exact_names))
	res["ok"] = fails.is_empty()
	res["ms"] = Time.get_ticks_msec() - t0
	print("RESULT ", JSON.stringify(res))
	quit(0)
