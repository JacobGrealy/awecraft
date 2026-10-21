extends SceneTree
# AC-0467 stage A — the flag-ON-aware copy of tasks/AC-0434/seam_band_probe.gd.
#
# WHY A COPY (not an edit): the AC-0434 probe computes the crack THROUGH
# THE TWO CHUNK TRANSFORMS (tx * local-16 vs tb * local-0) — valid only
# while the node transform IS the placement (flag off). With
# AWECRAFT_WARP_HOME=1 the home nodes wear IDENTITY and the mesh vertices
# are in world space, so the transform-based crack degenerates to
# -16 m (each column's local 0 is 16 m from the other's in the world
# frame) and the overlap is meaningless. This copy adds the IDENTITY
# branch: the nominal corner's world position is the CANONICAL HOME WARP
# (R + t) * normalize(SphereMath.home_point(fx, fz, R)) - (0, R, 0),
# fx = cx*16 + e, fz = cz*16 + k — the same construction the warp
# post-pass runs on the mesh (chunk.gd _warp_home_slabs / AweMesh.
# warp_home_verts) — and the band vertices are read as world points
# (their local seam-axis coordinate is recovered by subtracting the
# column offset; the warp distorts sub-mm over the 0.6 m band margin).
# Flag off (the self-check run): every quantity is computed EXACTLY as
# the AC-0434 original (S1 must reproduce its standing 654/752/660/662/
# 758/848/800/1290/1290), which proves the copy is a faithful copy.
#
# WHAT IT MEASURES (same as the original, per seam corner k = 0..16):
#   E_left / E_right — the LIVE extension at that corner, read off the
#     mesh vertices (surface 0, top-face n.y > 0.5, band e > 15.4 /
#     e < 0.6 in the column's LOCAL seam-axis coordinate).
#   crack — the seam-axis world distance between the two NOMINAL edge
#     points at the corner's own heights, each through its side's OWN
#     placement (the node transform flag off; the canonical home warp
#     flag on — flag on it is 0 by construction, the whole point).
#   overlap = E_left + E_right - crack (mm; positive = the two top faces
#     overlap across the seam at that corner).
#
# EXPECTED FLAG-ON READOUT (the gate (c) question): the K-table extension
# (mesh.cpp build_seam_ext, computed from sm_column_transform — NOT the
# node transform) still fires at its flag-off magnitude, so E_left /
# E_right are UNCHANGED while the crack collapses to ~0: the per-corner
# overlap grows by the old crack (~+0.5-0.6 m, i.e. it WIDENS rather
# than narrows) — the signal that the extension apparatus is still
# firing and stage B (its deletion) is not yet safe. If it only
# narrows or collapses, the extension is NOT what it reads as —
# report that instead.
#
# BOOT: -s mode loads no game autoloads, so the project autoloads are
# added in project order and the real entry scene is booted the game's
# own way (AWECRAFT_TIME set, AWECRAFT_LOGIC unset). RUN (from the repo
# root, via a script FILE — never a command line that contains the
# engine path; gate_run's slot test is pgrep -f "[g]odot"):
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
# The arm's standing ext_overlap_mm per pair (AC-0434 S1 — flag-off only).
const STANDING: Dictionary = {
	"x16_z0": 654.0, "x16_z16": 752.0, "xm16_z0": 660.0, "xm16_z16": 662.0,
	"z16_x0": 758.0, "z16_x16": 848.0, "z16_xm16": 800.0,
	"z32_x0": 1290.0, "z32_x16": 1290.0,
}

var _fails: Array = []
var _flags: Array = []
var SM: GDScript  # the global class; loaded explicitly for the -s boot


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var t0 := Time.get_ticks_msec()
	SM = load("res://core/sphere_math.gd")
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
	var flag_on: bool = OS.get_environment("AWECRAFT_WARP_HOME") != "0"  # AC-0467 stage B: default ON (boot label only — the measurement reads the live tree transforms + identity detection)
	var out: Dictionary = {
		"boot": {
			"world_seed": int(root.get_node("Game").world_seed), "planet_R": float(root.get_node("Game").planet_R),
			"render_radius": int(w.render_radius), "spawn": [spawn.x, spawn.y, spawn.z],
			"warp_home_flag": flag_on,
			"transform_used": ("the chunk-node transform in the tree (per-column LSQ tangent transform, SEAM_FILL included) — the AC-0434 original definition"
				if not flag_on else "IDENTITY nodes + the canonical home warp (R + t) * normalize(home_point(fx, fz, R)) - (0, R, 0) for nominal corners; band vertices read as world points (local coord = world - column offset)"),
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
		var p: Dictionary = _measure_pair(name, ca, cb, s[3], flag_on)
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
			_fails.append("autoload %s has no node resource" % [aname, apath])
			continue
		n.name = aname
		root.add_child(n)


func _autoloads_ok() -> bool:
	for n in ["Game", "Data", "Audio", "Debug", "Settings", "Save"]:
		if root.get_node_or_null(n) == null:
			return false
	return root.get_node("Game").cpp_ext_ok == true


# ---------------------------------------------------------------- measurement
func _measure_pair(name: String, ca, cb, axis: String, flag_on: bool) -> Dictionary:
	var tx: Transform3D = ca.transform
	var tb: Transform3D = cb.transform
	var ident_a: bool = tx.is_equal_approx(Transform3D(Basis.IDENTITY, Vector3.ZERO))
	var ident_b: bool = tb.is_equal_approx(Transform3D(Basis.IDENTITY, Vector3.ZERO))
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
				# moved corners) — lerp the WORLD positions (the "w" key is
				# the vertex's world point: node-transformed flag off, the
				# vertex as-is flag on — identical to tx * v when tx is the
				# placement, which it is flag off)
				var f: float = (float(k) - float(sa["kL"])) / (float(sa["kR"]) - float(sa["kL"]))
				var vl: Dictionary = sa["vl"]
				var vr: Dictionary = sa["vr"]
				var wl: Vector3 = Vector3(vl["w"])
				var wr: Vector3 = Vector3(vr["w"])
				eleft = (wl.lerp(wr, f) - _nom(ca, axis, 16.0, ta, float(k))).dot(xhat)
				ninterp += 1
			else:
				eleft = (Vector3(sa["w"]) - _nom(ca, axis, 16.0, ta, float(k))).dot(xhat)
		if sb != null:
			clsb = str(sb["cls"])
			tbh = float(sb["t"])
			if bool(sb.get("interp", false)):
				var f2: float = (float(k) - float(sb["kL"])) / (float(sb["kR"]) - float(sb["kL"]))
				var vl2: Dictionary = sb["vl"]
				var vr2: Dictionary = sb["vr"]
				var wl2: Vector3 = Vector3(vl2["w"])
				var wr2: Vector3 = Vector3(vr2["w"])
				eright = (_nom(cb, axis, 0.0, tbh, float(k)) - wl2.lerp(wr2, f2)).dot(xhat)
				ninterp += 1
			else:
				eright = (_nom(cb, axis, 0.0, tbh, float(k)) - Vector3(sb["w"])).dot(xhat)
		# the crack: the cross-seam gap the two NOMINAL edges have at this
		# corner's own heights, each through its side's OWN placement
		# (node transform flag off — the AC-0434 definition; the canonical
		# home warp flag on — 0 by construction, the same flat point)
		var crack: float = (_nom(cb, axis, 0.0, tbh, float(k)) - _nom(ca, axis, 16.0, ta, float(k))).dot(xhat)
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
	# set the arm sums over (its ext_edge min/max = the full band row) —
	# the standing values are the FLAG-OFF placement's, so the check runs
	# only when neither node is identity (the flag-on run reports the
	# delta for information, no fail)
	var pair_overlap: float = (float(ra["ext_max"]) - float(rb["ext_min"])) * 1000.0
	var standing: float = float(STANDING.get(name, 0.0))
	var delta: float = pair_overlap - standing
	if not ident_a and not ident_b and absf(delta) > 2.5:
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


# The nominal corner's WORLD position through the side's OWN placement:
# flag off (the transform IS the placement) — tx * local (the AC-0434
# definition, bit-for-bit); flag on (identity node, world-space mesh) —
# the canonical home warp (R + t) * normalize(home_point(fx, fz, R)) -
# (0, R, 0), fx = cx*16 + e, fz = cz*16 + k (the same construction the
# warp post-pass runs on the mesh vertices).
func _nom(c, axis: String, e: float, t: float, k: float) -> Vector3:
	var R: float = float(root.get_node("Game").planet_R)
	if c.transform.is_equal_approx(Transform3D(Basis.IDENTITY, Vector3.ZERO)):
		var fx: float = float(int(c.cx)) * 16.0 + (e if axis == "x" else k)
		var fz: float = float(int(c.cz)) * 16.0 + (k if axis == "x" else e)
		var dir: Vector3 = SM.home_point(fx, fz, R)
		return (R + t) * (dir / dir.length()) - Vector3(0.0, R, 0.0)
	var lv: Vector3 = Vector3(e, t, k) if axis == "x" else Vector3(k, t, e)
	return c.transform * lv


# The band row, over the FULL rendered surface: top-face vertices (n.y >
# 0.5) whose seam-axis LOCAL coord is past the nominal edge into the
# extension band (A: e > 15.4, B: e < 0.6), read from all three per-slab
# instances — mesh_instance surface 0 (opaque, cls "op"), fluid_instance
# (all surfaces, "fl") and flora_instance (all surfaces: cutout + xquad,
# "cu"). The seam extension is applied in the C++ to all of them, so the
# rendered band includes their top faces too. corners: k (clamped 0..16)
# -> list of {e (LOCAL seam-axis coord), t, cls, w (the vertex's WORLD
# point)} band vertices at that corner. ext_min/ext_max/n_op: the
# OPAQUE-only band's world min/max/count (the S1 cross-check set —
# flag off only).
# IDENTITY (flag on): the vertex IS in world space; its LOCAL flat
# coordinates are recovered with the EXACT inverse of the home warp
# (the warp is world = (R + ly) * normalize((fx, R, fz)) - (0, R, 0), so
# with P = w + (0, R, 0): ly = |P| - R and (fx, fz) = (d.x, d.z) * R / d.y
# with d = P / |P| — the radial scale (R + ly) / R ~ 1 + 140/4000 is NOT
# negligible over the 16 m along span: a plain "world - column offset"
# would shift the corner index by one at the far end of the along axis),
# then the column offset (cx*16 / cz*16) is subtracted. The stored "t" is
# the local radial height ly (the same height the nominal corner's forward
# warp evaluates at), and "w" is the vertex's world point.
func _edge_row(c, axis: String, is_a: bool, xhat: Vector3) -> Dictionary:
	var out: Dictionary = {"ext_min": 1e18, "ext_max": -1e18, "n_op": 0}
	var corners: Dictionary = {}
	var tx: Transform3D = c.transform
	var ident: bool = tx.is_equal_approx(Transform3D(Basis.IDENTITY, Vector3.ZERO))
	var Rg: float = float(root.get_node("Game").planet_R)
	var coloff: float = float(int(c.cx if axis == "x" else c.cz)) * 16.0
	var rowoff: float = float(int(c.cz if axis == "x" else c.cx)) * 16.0
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
					var e: float = float(v.x if axis == "x" else v.z)
					var s: float = float(v.z if axis == "x" else v.x)
					var t: float = v.y
					if ident:
						# the exact inverse of the home warp (see above) —
						# (fx, fz) in flat home metres, then the seam-axis
						# / along-axis assignment per axis (the same ternary
						# as the non-identity lines above)
						var pw: Vector3 = v + Vector3(0.0, Rg, 0.0)
						var dl: float = pw.length()
						var dy: float = pw.y / dl
						var fx: float = (pw.x / dl) * (Rg / dy)
						var fz: float = (pw.z / dl) * (Rg / dy)
						e = (fx - coloff) if axis == "x" else (fz - coloff)
						s = (fz - rowoff) if axis == "x" else (fx - rowoff)
						t = dl - Rg
					if is_a and e <= 15.4:
						continue
					if not is_a and e >= 0.6:
						continue
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
					corners[k].append({"e": e, "t": t, "cls": cls, "w": tx * v})
	out["corners"] = corners
	return out


# Per-corner surface pick (unchanged from the AC-0434 original). la[k] is
# the list of band vertices at corner k across all three instances. The
# VISIBLE surface row at corner k is the topmost band vertex within
# [top+1-1.1, top+1+0.6]; when the corner itself carries no surface-layer
# vertex, the surface row there is the INTERIOR of a merged top-face
# quad — return the two adjacent surface-layer corners for the caller to
# lerp in world space. Null (-> nominal E = 0) only when the edge column
# has no rendered top face in the band at or near that corner.
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


# The arm's edge_row_tops (unchanged): per along-cell k, the top block y
# of the edge column (local 15 on the A side, local 0 on the B side),
# -1 when air.
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
