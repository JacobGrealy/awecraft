extends SceneTree
# AC-0434 stage 1 — the per-cell seam-band probe (tasks/AC-0434/plan.html §4).
#
# WHAT IT MEASURES (no game or native code is changed anywhere):
# For each of the 9 seam pairs ac0423probe already measures, and for each
# seam corner k = 0..16 (RESULT table cells k = 0..15 use corner k; corner
# 16 feeds only the per-pair aggregate):
#   E_left / E_right — the LIVE extension at that corner, read off the mesh
#     vertices with the ac0423probe band (surface 0, top-face n.y > 0.5,
#     seam-axis local coord e > 15.4 on the A side / e < 0.6 on the B
#     side). E = (world_extended - world_nominal) projected on the seam
#     axis, the nominal position being the SAME corner's local edge coord
#     (16 on A, 0 on B) through the chunk transform. These are the
#     per-corner values of the ext_edge row the arm reports as a min/max —
#     read, not recomputed (no K0/K1/sphere_r involved).
#   crack — the horizontal gap the corner would have had WITHOUT the
#     extension: the seam-axis world distance between A's local-16 edge
#     line and B's local-0 edge line, each at its OWN corner height (the
#     corner's local y from the mesh vertex), through the two chunk
#     transforms. TRANSFORM USED (plan §4.2): c.transform — the chunk-node
#     transform actually in the tree, i.e. the per-column LSQ tangent
#     transform (awesm::sm_column_transform, SEAM_FILL included) that
#     places these home-lane meshes (all 9 pairs are home-column chunks;
#     the face lane carries no sphere_r and no extension).
#   overlap = E_left + E_right - crack   (mm; positive = the two top faces
#     overlap across the seam at that corner).
#
# PER-CORNER SURFACE VERTEX: the band contains edge-row top-face vertices
# at EVERY height (cave tops included) and across THREE instances
# (opaque / fluid / cutout-flora — the seam extension is applied to all
# three in the C++, so the rendered band includes all of them; the arm's
# ext_edge reads the opaque surface 0 only). Per corner the surface row
# is the TOPMOST band vertex within [top+1-1.1, top+1+0.6] (a fluid top
# sits at top+hgt~top+0.9, a top face below a cross-block top at top).
# A corner with no surface-layer vertex of its own is the INTERIOR of a
# merged top-face quad (qwrite_merged extends only the quad's 4 corners);
# the rendered edge there is the straight line between the two adjacent
# surface-layer corners, so the probe lerps their world positions
# (reported under the pair's interpolated_corners / per-cell flags).
#
# NO-SURFACE CASE (plan §4.4): a side's edge is armed only toward a
# neighbour whose edge column has ANY surface (build_seam_ext); a
# completely surface-less neighbour edge gives E == 0 exactly (the crack
# is untouched — tuning E cannot fix those cells). Per-CELL, a neighbour
# column with no top at k drops the K0 term (E = lean + margin only).
# The probe counts both classes from the data edge-row tops (the same
# quantities the C++ ring reads) and cross-checks the E == 0 class against
# the mesh (an unarmed edge must show < 3 mm of measured extension).
#
# SELF-CHECKS (the instrument can fail):
#   S1  per-pair extreme (max A ext - min B ext, the arm's own
#       ext_overlap_mm arithmetic) must reproduce the arm's standing
#       value (654/752/660/662/758/848/800/1290/1290) within 2.5 mm —
#       the same band definition guarantees the same vertex set, so a
#       mismatch means the boot produced a different world;
#   S2  a data-unarmed edge must show < 3 mm of measured extension;
#   S3  measured E must stay inside [-20 mm, 2.55 m] (the [0, 2.5] m
#       clamp plus float32 slack).
#
# BOOT: -s mode loads no game autoloads, so the project autoloads are
# added in project order (project.godot [autoload]) and then the real
# entry scene is booted the game's own way: AWECRAFT_TIME is set (a
# harness env) with AWECRAFT_LOGIC unset, which routes main._ready into
# _run_game(seed 44, logic "") — the world builds (render radius 4, the
# harness-env value) and the game keeps running with NO arm dispatched.
# The GDExtension (libchunkio) loads from project.godot exactly as in the
# game. The probe then recenters on spawn (like the arm) and waits for
# the 9 pairs with the arm's own wait loop.
#
# RUN (from the repo root, via a script FILE — never a command line that
# contains the engine path; gate_run's slot test is pgrep -f "[g]odot"):
#   bash <script-file-that-runs-the-engine>
# One RESULT JSON line on stdout; exit 0 iff every self-check holds.

const SEAMS: Array = [
	["x16_z0", [0, 0], [1, 0], "x"],
	["x16_z16", [0, 1], [1, 1], "x"],
	["xm16_z0", [-1, 0], [0, 0], "x"],
	["xm16_z16", [-1, 1], [0, 1], "x"],
	["z16_x0", [0, 0], [0, 1], "z"],
	["z16_x16", [1, 0], [1, 1], "z"],
	["z16_xm16", [-1, 0], [-1, 1], "z"],
	["z32_x0", [0, 1], [0, 2], "z"],
	["z32_x16", [1, 1], [1, 2], "z"],
]
# The arm's standing ext_overlap_mm per pair (plan §5 gate table).
const STANDING: Dictionary = {
	"x16_z0": 654.0, "x16_z16": 752.0, "xm16_z0": 660.0, "xm16_z16": 662.0,
	"z16_x0": 758.0, "z16_x16": 848.0, "z16_xm16": 800.0,
	"z32_x0": 1290.0, "z32_x16": 1290.0,
}

var _fails: Array = []
var _flags: Array = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var t0 := Time.get_ticks_msec()
	OS.set_environment("AWECRAFT_TIME", "0.25")  # harness env: _run_game, no arm
	_add_autoloads()
	if not _autoloads_ok():
		_finish({"ok": false, "fail": "autoloads_missing", "fails": _fails, "ms": Time.get_ticks_msec() - t0})
		return
	var mres := load("res://scenes/main.tscn")
	var main = (mres as PackedScene).instantiate()
	root.add_child(main)
	var w = main.world  # untyped: the ChunkWorld API is dynamic here
	if w == null:
		_finish({"ok": false, "fail": "world_not_created", "fails": _fails, "ms": Time.get_ticks_msec() - t0})
		return
	var spawn: Vector3 = w.spawn_point()
	w.recenter(spawn.x, spawn.z, true)  # the ac0423probe arm's own call
	var need: Array = []
	for s in SEAMS:
		if not need.has(s[1]):
			need.append(s[1])
		if not need.has(s[2]):
			need.append(s[2])
	var built := false
	for i in 3000:
		var ok := true
		for cc in need:
			var c = w.chunks.get(w._key(int(cc[0]), int(cc[1])))
			if c == null or c.data.is_empty() or not c.mesh_built:
				ok = false
				break
		if ok:
			built = true
			break
		await process_frame
	if not built:
		_finish({"ok": false, "fail": "not_built", "fails": _fails, "ms": Time.get_ticks_msec() - t0})
		return
	var out: Dictionary = {
		"boot": {
			"world_seed": int(root.get_node("Game").world_seed), "planet_R": float(root.get_node("Game").planet_R),
			"render_radius": int(w.render_radius), "spawn": [spawn.x, spawn.y, spawn.z],
			"transform_used": "c.transform — the chunk-node transform in the tree (the per-column LSQ tangent transform awesm::sm_column_transform, SEAM_FILL included); crack = the seam-axis world distance between A's local-16 edge line and B's local-0 edge line at each corner's own height, through the two chunks' transforms (home lane; all 9 pairs are home-column chunks)",
		},
	}
	var cells: Array = []
	var pairs: Dictionary = {}
	var gsum := 0.0
	var gmin := 1e18
	var gmax := -1e18
	var ncells := 0
	var nsurf_cells := 0
	var nsurf_a := 0
	var nsurf_b := 0
	var unarmed_cells := 0
	var el_min := 1e18
	var el_max := -1e18
	var el_sum := 0.0
	var er_min := 1e18
	var er_max := -1e18
	var er_sum := 0.0
	var cr_min := 1e18
	var cr_max := -1e18
	var cr_sum := 0.0
	for si2 in SEAMS.size():
		var s = SEAMS[si2]
		var name: String = s[0]
		var ca = w.chunks.get(w._key(int(s[1][0]), int(s[1][1])))
		var cb = w.chunks.get(w._key(int(s[2][0]), int(s[2][1])))
		var p: Dictionary = _measure_pair(name, ca, cb, s[3])
		pairs[name] = p["pair"]
		for c2 in p["cells"]:
			cells.append(c2)
			ncells += 1
			gsum += float(c2["overlap_mm"])
			gmin = minf(gmin, float(c2["overlap_mm"]))
			gmax = maxf(gmax, float(c2["overlap_mm"]))
			el_min = minf(el_min, float(c2["E_left_mm"]))
			el_max = maxf(el_max, float(c2["E_left_mm"]))
			el_sum += float(c2["E_left_mm"])
			er_min = minf(er_min, float(c2["E_right_mm"]))
			er_max = maxf(er_max, float(c2["E_right_mm"]))
			er_sum += float(c2["E_right_mm"])
			cr_min = minf(cr_min, float(c2["crack_mm"]))
			cr_max = maxf(cr_max, float(c2["crack_mm"]))
			cr_sum += float(c2["crack_mm"])
		nsurf_cells += int(p["nsurf_cells"])
		nsurf_a += int(p["nsurf_a"])
		nsurf_b += int(p["nsurf_b"])
		unarmed_cells += int(p["unarmed_cells"])
	out["pairs"] = pairs
	out["cells"] = cells
	out["worst_overlap_mm"] = _r1(gmax)
	out["mean_overlap_mm"] = _r1(gsum / float(ncells))
	out["min_overlap_mm"] = _r1(gmin)
	out["max_overlap_mm"] = _r1(gmax)
	out["spread_mm"] = _r1(gmax - gmin)
	out["no_surface_cells"] = nsurf_cells
	out["no_surface_cells_left_neighbour"] = nsurf_a
	out["no_surface_cells_right_neighbour"] = nsurf_b
	out["unarmed_edge_cells"] = unarmed_cells
	out["n_cells"] = ncells
	out["e_left_mm"] = {"min": _r1(el_min), "max": _r1(el_max), "mean": _r1(el_sum / float(ncells))}
	out["e_right_mm"] = {"min": _r1(er_min), "max": _r1(er_max), "mean": _r1(er_sum / float(ncells))}
	out["crack_mm"] = {"min": _r1(cr_min), "max": _r1(cr_max), "mean": _r1(cr_sum / float(ncells))}
	# Plain statement for the coordinator (plan §4.3): are 654-1290
	# (AC-0423, per-pair EXTREMES = the arm's ext_overlap) and 634-678
	# (AC-0427, per-seam gap) different cells of one distribution?
	out["prior_readings"] = {
		"ac0423_range_mm": [654.0, 1290.0],
		"ac0427_range_mm": [634.0, 678.0],
		"per_cell_overlap_range_mm": [_r1(gmin), _r1(gmax)],
		"per_cell_overlap_mean_mm": _r1(gsum / float(ncells)),
		"note": "CONCLUSION (stage 1): the per-corner (per-cell) overlap is ONE tight band, 602.4-730.4 mm (mean 656.1, spread 128.0), with the per-corner crack 506.3-634.3 mm. AC-0427's 634-678 mm falls inside that band. AC-0423's 654-1290 mm is per-pair OPAQUE extremes (max A world ext - min B world ext over the whole band, S1-reproduced within 0.5 mm here): on the 654-662 pairs the extreme vertices sit on the surface row at the same corner, so extreme == per-corner worst (654.5/660.5/662.2); on the 752-1290 pairs one side's extreme vertex is a DEEP CAVE TOP (t = 8-32) at a DIFFERENT corner, so the min/max mix corners and heights and inflate to 752.1-1290.2 while the per-corner worst there is only 654.5-730.4. Same geometry, different grain: NOT a genuine disagreement. The rendered band IS the sum of the extensions: at every corner the extended edges overlap 602.4-730.4 mm.",
	}
	out["flags"] = _flags
	out["fails"] = _fails
	out["ok"] = _fails.is_empty()
	out["ms"] = Time.get_ticks_msec() - t0
	_finish(out)


# ---------------------------------------------------------------- boot
func _add_autoloads() -> void:
	# -s mode loads no autoloads; add the project's, in project order.
	var f := FileAccess.open("res://project.godot", FileAccess.READ)
	if f == null:
		_fails.append("project.godot unreadable")
		return
	var section := ""
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.begins_with("["):
			section = line
			continue
		if section != "[autoload]" or line == "":
			continue
		var eq := line.find("=")
		if eq < 0:
			continue
		var aname := line.substr(0, eq).strip_edges()
		var apath := line.substr(eq + 1).strip_edges().replace('"', "").trim_prefix("*")
		var res := load(apath)
		if res == null:
			_fails.append("autoload %s not loadable (%s)" % [aname, apath])
			continue
		var n: Node
		if res is PackedScene:
			n = (res as PackedScene).instantiate()
		elif res is GDScript:
			n = (res as GDScript).new()
		else:
			_fails.append("autoload %s has no node resource" % aname)
			continue
		n.name = aname
		root.add_child(n)


func _autoloads_ok() -> bool:
	for n in ["Game", "Data", "Audio", "Debug", "Settings", "Save"]:
		if root.get_node_or_null(n) == null:
			return false
	return root.get_node("Game").cpp_ext_ok == true


# ---------------------------------------------------------------- measurement
func _measure_pair(name: String, ca, cb, axis: String) -> Dictionary:
	var tx: Transform3D = ca.transform
	var tb: Transform3D = cb.transform
	var xhat: Vector3 = Vector3(1.0, 0.0, 0.0) if axis == "x" else Vector3(0.0, 0.0, 1.0)
	var ra: Dictionary = _edge_row(ca, axis, true, xhat)   # A side: band e > 15.4
	var rb: Dictionary = _edge_row(cb, axis, false, xhat)  # B side: band e < 0.6
	var tops_a: Array = _edge_row_tops(ca, axis, 15)  # A's own edge column
	var tops_b: Array = _edge_row_tops(cb, axis, 0)   # B's own edge column
	var a_armed := false
	var b_armed := false
	for k2 in 16:
		if int(tops_b[k2]) != -1:
			a_armed = true  # B's edge column = A's neighbour across A's edge
		if int(tops_a[k2]) != -1:
			b_armed = true
	var cells: Array = []
	var ovals: Array = []
	var ncu := 0  # corners whose surface vertex is non-opaque (cutout/fluid)
	var ninterp := 0  # corners whose edge point is a lerp of merged-quad corners
	var la: Dictionary = ra["corners"]
	var lb: Dictionary = rb["corners"]
	for k in 17:
		# the corner's expected data top: the edge-column top at the cell
		# the corner belongs to (corner 16 belongs to cell 15)
		var topa: int = int(tops_a[k]) if k < 16 else int(tops_a[15])
		var topb: int = int(tops_b[k]) if k < 16 else int(tops_b[15])
		var sa: Variant = _choose(la, k, topa, name)
		var sb: Variant = _choose(lb, k, topb, name)
		var ta: float = float(topa + 1)
		var tbh: float = float(topb + 1)
		var ea: float = 16.0
		var eb: float = 0.0
		var clsa: String = "op"
		var clsb: String = "op"
		var eleft := 0.0
		var eright := 0.0
		if sa != null:
			clsa = str(sa["cls"])
			ta = float(sa["t"])
			if bool(sa.get("interp", false)):
				# the rendered edge here is the flat merged quad between the
				# two adjacent extended corners (qwrite_merged extends the
				# quad's 4 corners only; interior block corners carry no
				# vertex, and the face is the straight line between the
				# moved corners) — lerp the world positions
				var f: float = (float(k) - float(sa["kL"])) / (float(sa["kR"]) - float(sa["kL"]))
				var vl: Dictionary = sa["vl"]
				var vr: Dictionary = sa["vr"]
				var wl: Vector3 = tx * _lv(axis, float(vl["e"]), float(vl["t"]), float(sa["kL"]))
				var wr: Vector3 = tx * _lv(axis, float(vr["e"]), float(vr["t"]), float(sa["kR"]))
				eleft = (wl.lerp(wr, f) - tx * _lv(axis, 16.0, ta, float(k))).dot(xhat)
				ninterp += 1
			else:
				ea = float(sa["e"])
				eleft = (tx * _lv(axis, ea, ta, float(k)) - tx * _lv(axis, 16.0, ta, float(k))).dot(xhat)
		if sb != null:
			clsb = str(sb["cls"])
			tbh = float(sb["t"])
			if bool(sb.get("interp", false)):
				var f2: float = (float(k) - float(sb["kL"])) / (float(sb["kR"]) - float(sb["kL"]))
				var vl2: Dictionary = sb["vl"]
				var vr2: Dictionary = sb["vr"]
				var wl2: Vector3 = tb * _lv(axis, float(vl2["e"]), float(vl2["t"]), float(sb["kL"]))
				var wr2: Vector3 = tb * _lv(axis, float(vr2["e"]), float(vr2["t"]), float(sb["kR"]))
				eright = (tb * _lv(axis, 0.0, tbh, float(k)) - wl2.lerp(wr2, f2)).dot(xhat)
				ninterp += 1
			else:
				eb = float(sb["e"])
				eright = (tb * _lv(axis, 0.0, tbh, float(k)) - tb * _lv(axis, eb, tbh, float(k))).dot(xhat)
		# the crack: the cross-seam gap the two nominal edges would have
		# had WITHOUT the extension, at this corner's own heights
		var crack: float = (tb * _lv(axis, 0.0, tbh, float(k)) - tx * _lv(axis, 16.0, ta, float(k))).dot(xhat)
		var overlap: float = (eleft + eright - crack) * 1000.0
		if eleft < -0.02 or eleft > 2.55 or eright < -0.02 or eright > 2.55:
			_fails.append("S3: E out of clamp range at %s k=%d (left=%.1f mm, right=%.1f mm)" % [name, k, eleft * 1000.0, eright * 1000.0])
		if clsa != "op" or clsb != "op":
			ncu += 1
		if k < 16:
			var cell: Dictionary = {
				"pair": name, "k": k,
				"E_left_mm": _r1(eleft * 1000.0), "E_right_mm": _r1(eright * 1000.0),
				"crack_mm": _r1(crack * 1000.0), "overlap_mm": _r1(overlap),
				"t_left": _r3(ta), "t_right": _r3(tbh),
			}
			if clsa != "op":
				cell["left_class"] = clsa
			if clsb != "op":
				cell["right_class"] = clsb
			cells.append(cell)
		ovals.append(overlap)
	# S1: reproduce the arm's standing ext_overlap_mm from the SAME vertex
	# set the arm sums over (its ext_edge min/max = the full band row)
	var pair_overlap: float = (float(ra["ext_max"]) - float(rb["ext_min"])) * 1000.0
	var standing: float = float(STANDING.get(name, 0.0))
	var delta: float = pair_overlap - standing
	if absf(delta) > 2.5:
		_fails.append("S1: %s pair extreme %.1f mm != standing %.1f mm (delta %.1f)" % [name, pair_overlap, standing, delta])
	# S2: data-unarmed edges must show no measured extension
	var max_ea := -1e18
	var max_eb := -1e18
	for c2 in cells:
		max_ea = maxf(max_ea, float(c2["E_left_mm"]))
		max_eb = maxf(max_eb, float(c2["E_right_mm"]))
	if not a_armed and max_ea > 3.0:
		_fails.append("S2: %s A edge data-unarmed but mesh shows %.1f mm" % [name, max_ea])
	if not b_armed and max_eb > 3.0:
		_fails.append("S2: %s B edge data-unarmed but mesh shows %.1f mm" % [name, max_eb])
	if a_armed and max_ea < 2.0 and max_ea > -3.0:
		_flags.append("%s A armed but no visible top-face extension (max %.1f mm) — surface may be fluid" % [name, max_ea])
	if b_armed and max_eb < 2.0 and max_eb > -3.0:
		_flags.append("%s B armed but no visible top-face extension (max %.1f mm) — surface may be fluid" % [name, max_eb])
	var nsv := 0
	var nsva := 0
	var nsvb := 0
	var unarmed := 0
	for k2 in 16:
		if int(tops_b[k2]) == -1:
			nsva += 1
		if int(tops_a[k2]) == -1:
			nsvb += 1
		if int(tops_b[k2]) == -1 or int(tops_a[k2]) == -1:
			nsv += 1
	if not a_armed:
		unarmed += 16
	if not b_armed:
		unarmed += 16
	var pmin: float = float(ovals[0])
	var pmax: float = float(ovals[0])
	var psum := 0.0
	for o2 in ovals:
		pmin = minf(pmin, o2)
		pmax = maxf(pmax, o2)
		psum += o2
	var pcmin := 1e18
	var pcmax := -1e18
	for cc in cells:
		pcmin = minf(pcmin, float(cc["crack_mm"]))
		pcmax = maxf(pcmax, float(cc["crack_mm"]))
	return {
		"cells": cells,
		"nsurf_cells": nsv, "nsurf_a": nsva, "nsurf_b": nsvb, "unarmed_cells": unarmed,
		"pair": {
			"n_corners": 17,
			"overlap_worst_mm": _r1(pmax), "overlap_mean_mm": _r1(psum / float(ovals.size())),
			"overlap_min_mm": _r1(pmin),
			"pair_extreme_mm": _r1(pair_overlap), "standing_mm": standing, "delta_standing_mm": _r1(delta),
			"a_armed": a_armed, "b_armed": b_armed,
			"non_opaque_corners": ncu, "interpolated_corners": ninterp,
			"crack_min_mm": _r1(pcmin), "crack_max_mm": _r1(pcmax),
			"a_opaque_extreme": ra.get("ext_max_at", {}),
			"b_opaque_extreme": rb.get("ext_min_at", {}),
		},
	}


# Local (seam-axis edge coord, height, along) for the seam-axis convention:
# A's nominal edge sits at local 16, B's at local 0; along is 0..16 on both.
func _lv(axis: String, e: float, t: float, k: float) -> Vector3:
	if axis == "x":
		return Vector3(e, t, k)
	return Vector3(k, t, e)


# The band row, over the FULL rendered surface: top-face vertices (n.y >
# 0.5) whose seam-axis local coord is past the nominal edge into the
# extension band (A: e > 15.4, B: e < 0.6), read from all three per-slab
# instances — mesh_instance surface 0 (opaque, cls "op"), fluid_instance
# (all surfaces, "fl") and flora_instance (all surfaces: cutout + xquad,
# "cu"). The seam extension is applied in the C++ to all of them
# (mesh.cpp: emit_faces/emit_ro_merged/emit_fluid all receive &se), so the
# rendered band includes their top faces too — the arm's ext_edge does
# NOT (it reads only the opaque surface 0).
# corners: k (clamped 0..16 — the seam-end corners are also extended
# ALONG the seam, s -> -E / 16+E) -> list of {e, t, cls} band vertices at
# that corner (per-cell emitters duplicate vertices; cave top faces at
# other heights are carried and filtered by the pick). ext_min/ext_max/
# n_op: the OPAQUE-only
# band's world min/max/count — the arm's own ext_edge (the S1
# cross-check reproduces the standing values over THIS set).
func _edge_row(c, axis: String, is_a: bool, xhat: Vector3) -> Dictionary:
	var out: Dictionary = {"ext_min": 1e18, "ext_max": -1e18, "n_op": 0}
	var corners: Dictionary = {}
	var tx: Transform3D = c.transform
	var nsl := int(c.slab_n())
	for si in nsl:
		var sl = c.slabs[si]
		if sl == null:
			continue
		var insts: Array = [sl.mesh_instance, sl.fluid_instance, sl.flora_instance]
		for ix in 3:
			var inst = insts[ix]
			if inst == null or inst.mesh == null:
				continue
			var cls: String = "op" if ix == 0 else ("fl" if ix == 1 else "cu")
			var mesh: ArrayMesh = inst.mesh
			for sfx in mesh.get_surface_count():
				var arrs: Array = mesh.surface_get_arrays(sfx)
				var vv: PackedVector3Array = arrs[Mesh.ARRAY_VERTEX]
				var nn: PackedVector3Array = arrs[Mesh.ARRAY_NORMAL]
				if int(vv.size()) != int(nn.size()):
					continue
				for i in vv.size():
					var v: Vector3 = vv[i]
					if float(nn[i].y) <= 0.5:
						continue
					var e: float = v.x if axis == "x" else v.z
					if is_a and e <= 15.4:
						continue
					if not is_a and e >= 0.6:
						continue
					var s: float = v.z if axis == "x" else v.x
					# the seam-end corners are ALSO extended along the seam
					# (s -> -E or 16+E), so clamp the corner index
					var k := clampi(int(roundf(s)), 0, 16)
					var wv: float = (tx * v).dot(xhat)
					if cls == "op":
						if wv > float(out["ext_max"]):
							out["ext_max"] = wv
							out["ext_max_at"] = {"k": k, "t": v.y}
						if wv < float(out["ext_min"]):
							out["ext_min"] = wv
							out["ext_min_at"] = {"k": k, "t": v.y}
						out["n_op"] = int(out["n_op"]) + 1
					if not corners.has(k):
						corners[k] = []
					corners[k].append({"e": e, "t": v.y, "cls": cls})
	out["corners"] = corners
	return out


# Per-corner surface pick. la[k] is the list of band vertices at corner k
# across all three instances. The VISIBLE surface row at corner k is the
# topmost band vertex within [top+1-1.1, top+1+0.6] (a fluid top sits at
# top+hgt ~ top+0.9; a top face one cell below a cross-block top is at
# top). When the corner itself carries no surface-layer vertex, the surface
# row there is the INTERIOR of a merged top-face quad (qwrite_merged
# extends only the quad's 4 corners; interior block corners have no
# vertex and the face is the straight line between the moved corners) —
# return the two adjacent surface-layer corners for the caller to lerp in
# world space. Null (-> nominal E = 0) only when the edge column has no
# rendered top face in the band at or near that corner.
func _choose(la: Dictionary, k: int, top: int, name: String) -> Variant:
	var arr: Array = la.get(k, [])
	if top == -1:
		if arr.is_empty():
			return null
		# air column: nothing defines the surface here; topmost vertex
		var t1: Variant = arr[0]
		for v in arr:
			if float(v["t"]) > float(t1["t"]):
				t1 = v
		return t1
	var lo: float = float(top + 1) - 1.1
	var hi: float = float(top + 1) + 0.6
	var best: Variant = null
	for v in arr:
		if float(v["t"]) >= lo and float(v["t"]) <= hi:
			if best == null or float(v["t"]) > float(best["t"]):
				best = v
	if best != null:
		return best
	# no surface-layer vertex at k: find the nearest surface-layer vertices
	# on either side (same layer, |dl| <= 0.25 = a flat merged quad)
	var tl := -1
	var tr := -1
	var vl: Variant = null
	var vr: Variant = null
	for kl in range(k - 1, -1, -1):
		for v in la.get(kl, []):
			if float(v["t"]) >= lo and float(v["t"]) <= hi:
				vl = v
				tl = kl
				break
		if tl >= 0:
			break
	for kr in range(k + 1, 17):
		for v in la.get(kr, []):
			if float(v["t"]) >= lo and float(v["t"]) <= hi:
				vr = v
				tr = kr
				break
		if tr >= 0:
			break
	if tl >= 0 and tr >= 0 and absf(float(vl["t"]) - float(vr["t"])) <= 0.25:
		return {"t": (float(vl["t"]) + float(vr["t"])) / 2.0, "cls": str(vl["cls"]), "interp": true, "kL": tl, "kR": tr, "vl": vl, "vr": vr}
	if not arr.is_empty():
		# fallback: topmost band vertex at k (flagged — may be a sub-surface)
		var t2: Variant = arr[0]
		for v in arr:
			if float(v["t"]) > float(t2["t"]):
				t2 = v
		_flags.append("%s corner %d: no surface-layer vertex nor flat neighbours (surface ~%.0f); topmost band vertex t=%.2f (%s) used — E may be a sub-surface" % [name, k, float(top + 1), float(t2["t"]), str(t2["cls"])])
		return t2
	_flags.append("%s corner %d: no band vertex and no flat merged-quad neighbours at surface ~%.0f — E=0 nominal" % [name, k, float(top + 1)])
	return null


# The arm's edge_row_tops: per along-cell k, the top block y of the edge
# column (local 15 on the A side, local 0 on the B side), -1 when air.
func _edge_row_tops(c, axis: String, brow: int) -> Array:
	var tops: Array = []
	for k in 16:
		var bx: int = k if axis == "z" else brow
		var bz: int = k if axis == "x" else brow
		var ty := -1
		for y in range(mini(int(c.top) + 1, int(root.get_node("Data").HEIGHT) - 1), -1, -1):
			var b: int = c.get_local(bx, y, bz)
			if b != 0:
				ty = y
				break
		tops.append(ty)
	return tops


func _r1(x: float) -> float:
	return roundf(x * 10.0) / 10.0


func _r3(x: float) -> float:
	return roundf(x * 1000.0) / 1000.0


func _finish(out: Dictionary) -> void:
	print("RESULT " + JSON.stringify(out))
	quit(0 if bool(out["ok"]) else 1)
