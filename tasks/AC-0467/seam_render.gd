extends SceneTree
# AC-0467 stage A gate (d) — the home-seam render (plan §5, "the AC-0434
# vantage"): a surface-FLUSH block on a home seam, the player standing
# ON the seam line, the camera ABOVE looking straight down.
#
# SCENE: the x=16 seam (columns (0,0)/(1,0)). A flat spot is scanned for
# over the edge (z 0..15 — the cell where the two sides' edge-column tops
# are EQUAL, so the ground is flush across the seam there). The surface-
# flush block REPLACES the top block of the seam-line cell (world (16, z))
# with block id 2 (the faceedit/interact "known breakable") — its top face
# sits at the same level as the surrounding ground (flush), and the seam
# line runs along its west edge. The player (feet) stands ON the line at
# that spot; the camera is a DEDICATED Camera3D 15 m above the spot
# looking straight down (the first-person rig is set non-current so it
# does not fight it).
#
# BOOT: the seam_band_probe pattern — -s mode loads no game autoloads, so
# the project autoloads are added in project order and the real entry
# scene is booted the game's own way (AWECRAFT_TIME set, AWECRAFT_LOGIC
# unset → main._run_game, no arm). No Save slot is touched on this boot
# path (Save.active_slot stays -1 — main.gd), so the placed block dies
# with the process.
#
# RUN (from the repo root, via a script FILE — never a command line that
# contains the engine path; gate_run's slot test is pgrep -f "[g]odot"):
#   xvfb-run -a bash .scratch/AC-0467-gates/run_render_<off|on>.sh
# AWECRAFT_SNAP_PATH = the output PNG (absolute). One RESULT JSON line on
# stdout; exit 0 iff the scene landed (player on the line, camera up,
# png written).

const BLOCK_ID := 2  # the faceedit/interact "known breakable" (contrast on the pad)


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var t0 := Time.get_ticks_msec()
	var r: Dictionary = {"ok": false}
	OS.set_environment("AWECRAFT_TIME", "0.25")
	_add_autoloads()
	if not _autoloads_ok():
		r["fail"] = "autoloads_missing"
		_finish(r, t0)
		return
	var mres := load("res://scenes/main.tscn")
	var main = (mres as PackedScene).instantiate()
	root.add_child(main)
	var w = main.world  # untyped: the ChunkWorld API is dynamic here
	var dbg: Node = root.get_node("Debug")
	if w == null:
		r["fail"] = "world_not_created"
		_finish(r, t0)
		return
	var spawn: Vector3 = w.spawn_point()
	w.recenter(spawn.x, spawn.z, true)
	var need: Array = [[0, 0], [1, 0], [0, 1], [1, 1]]
	if not await _await_built(w, need, 3000):
		r["fail"] = "not_built"
		_finish(r, t0)
		return
	var cA = w.chunks.get(w._key(0, 0))
	var cB = w.chunks.get(w._key(1, 0))
	# the flat spot: equal edge-column tops across the seam (z 0..15)
	var topa: Array = []
	var topb: Array = []
	var zflat := -1
	var zbest := 0
	var bestd := 999
	for z in 16:
		var ta := _edge_top(cA, 15, z)
		var tb := _edge_top(cB, 0, z)
		topa.append(ta)
		topb.append(tb)
		var d := absi(ta - tb) if ta >= 0 and tb >= 0 else 999
		if d < bestd:
			bestd = d
			zbest = z
		if ta >= 0 and tb >= 0 and ta == tb and zflat < 0:
			zflat = z
	var z: int = zflat if zflat >= 0 else zbest  # prefer flat; else the least stepped
	var top: int = int(topb[z])
	r["seam"] = {"axis": "x16", "z_flat": zflat, "z": z, "topA": int(topa[z]), "topB": top}
	# the surface-flush block: REPLACE the seam-cell top block (flush top
	# face at top+1 = the surrounding ground level, the flat spot)
	var id_before: int = int(w.get_block(16, top, z))
	dbg.set_block(16, top, z, BLOCK_ID)
	if int(w.get_block(16, top, z)) != BLOCK_ID:
		r["fail"] = "set_block_refused"
		_finish(r, t0)
		return
	r["block"] = {"cell": [16, top, z], "id": BLOCK_ID, "was_id": id_before}
	# wait for the remesh of both seam columns (edit registered -> rebuilt)
	if not await _await_remesh(w, [cA, cB], 3000):
		r["fail"] = "remesh_timeout"
		_finish(r, t0)
		return
	# the player ON the line: the teleport recenters the band on the flat
	# point (16, z) — the seam line then runs along world x = 0. main's
	# boot spawns the player AFTER its own sim-band settle, so wait for it
	# first (Debug.teleport is a silent no-op while it is null).
	var pl: Node3D = null
	for i in 3000:
		pl = root.get_node("Game").player
		if pl != null:
			break
		await process_frame
	if pl == null:
		r["fail"] = "no_player"
		_finish(r, t0)
		return
	dbg.fly(true)
	dbg.teleport(16.0, float(top + 1), float(z))
	var need2: Array = [[0, 0], [1, 0], [2, 0], [0, 1], [1, 1], [2, 1], [0, -1], [1, -1], [2, -1]]
	if not await _await_built(w, need2, 3000):
		r["fail"] = "not_built_after_recenter"
		_finish(r, t0)
		return
	dbg.fly(false)
	var feet: Vector3 = Vector3(0.0, float(top + 1), float(z))
	# the camera ABOVE: a dedicated node (the first-person rig steps aside)
	var plc = pl.get_node_or_null("Camera3D")
	if plc != null:
		plc.current = false
	var cam := Camera3D.new()
	cam.name = "SeamCam"
	main.add_child(cam)
	cam.position = Vector3(0.0, float(top + 1) + 15.0, float(z))
	cam.rotation.x = -PI / 2.0  # look straight down (image right = world +x)
	cam.fov = 75.0
	cam.near = 0.05
	cam.far = 100.0
	cam.current = true
	r["cam"] = [cam.position.x, cam.position.y, cam.position.z]
	# settle: re-assert the player's feet on the line (de-penetration must
	# not drift the shot) and hold the camera; give the renderer (the
	# llvmpipe GPU upload lags the CPU-side mesh landing) a full second+
	for i in 360:
		pl.position = feet
		pl.look(0.0, 0.0)
		cam.position = Vector3(0.0, float(top + 1) + 15.0, float(z))
		cam.rotation.x = -PI / 2.0
		await physics_frame
	var flag_on: bool = OS.get_environment("AWECRAFT_WARP_HOME") == "1"
	r["flag_on"] = flag_on
	var ident_a: bool = cA.transform.is_equal_approx(Transform3D(Basis.IDENTITY, Vector3.ZERO))
	var ident_b: bool = cB.transform.is_equal_approx(Transform3D(Basis.IDENTITY, Vector3.ZERO))
	r["node_identity"] = [ident_a, ident_b]
	if flag_on and not (ident_a and ident_b):
		r["fail"] = "nodes_not_identity"
		_finish(r, t0)
		return
	var path: String = OS.get_environment("AWECRAFT_SNAP_PATH")
	if path == "":
		r["fail"] = "no_snap_path"
		_finish(r, t0)
		return
	var img: Image = root.get_viewport().get_texture().get_image()
	var err: int = img.save_png(path)
	if err != OK:
		r["fail"] = "snap_failed_%d" % err
		_finish(r, t0)
		return
	r["png"] = path
	r["size"] = [img.get_width(), img.get_height()]
	# pixel readout: the seam line projects to the image's horizontal
	# centre (the camera is on the line looking straight down; image
	# right = world +x). Sample the ground a step west/east of the line
	# and on it, at the frame centre (world z = the seam point).
	var cxp := img.get_width() / 2
	var cyp := img.get_height() / 2
	r["px"] = {
		"west": _px(img, cxp - 30, cyp),
		"line": _px(img, cxp, cyp),
		"east": _px(img, cxp + 30, cyp),
		"west_far": _px(img, cxp - 90, cyp),
		"east_far": _px(img, cxp + 90, cyp),
	}
	r["player_feet"] = [roundf(feet.x * 1000.0) / 1000.0, roundf(feet.y * 1000.0) / 1000.0, roundf(feet.z * 1000.0) / 1000.0]
	r["player_actual"] = [roundf(pl.position.x * 1000.0) / 1000.0, roundf(pl.position.y * 1000.0) / 1000.0, roundf(pl.position.z * 1000.0) / 1000.0]
	r["ok"] = r.has("png")
	_finish(r, t0)


# ---------------------------------------------------------------- helpers
func _finish(r: Dictionary, t0: int) -> void:
	r["ms"] = Time.get_ticks_msec() - t0
	print("RESULT " + JSON.stringify(r))
	quit(0 if bool(r.get("ok", false)) else 1)


func _px(img: Image, x: int, y: int) -> Array:
	var c: Color = img.get_pixel(x, y)
	return [int(roundf(c.r * 255.0)), int(roundf(c.g * 255.0)), int(roundf(c.b * 255.0))]


func _edge_top(c, brow: int, k: int) -> int:
	for y in range(mini(int(c.top) + 1, int(root.get_node("Data").HEIGHT) - 1), -1, -1):
		if int(c.get_local(brow, y, k)) != 0:
			return y
	return -1


# wait until every needed column is resident + data + mesh_built
func _await_built(w, need: Array, max_frames: int) -> bool:
	for i in max_frames:
		var ok := true
		for cc in need:
			var c = w.chunks.get(w._key(int(cc[0]), int(cc[1])))
			if c == null or c.data.is_empty() or not c.mesh_built:
				ok = false
				break
		if ok:
			return true
		await process_frame
	return false


# wait for the edit to register (any column dirty) and then clear (the
# rebuild landed); if the edit is remeshed synchronously before the first
# poll (no dirty ever seen), accept a long clean streak instead
func _await_remesh(w, cols: Array, max_frames: int) -> bool:
	var seen_dirty := false
	var clean_streak := 0
	for i in max_frames:
		var dirty := false
		for c in cols:
			if c != null and c.any_col_dirty():
				dirty = true
				break
		if dirty:
			seen_dirty = true
			clean_streak = 0
		else:
			clean_streak += 1
			if seen_dirty and clean_streak >= 3:
				await process_frame
				return true
			if not seen_dirty and clean_streak >= 600:
				return true
		await process_frame
	return false


# ---------------------------------------------------------------- boot
func _add_autoloads() -> void:
	var f := FileAccess.open("res://project.godot", FileAccess.READ)
	if f == null:
		_finish({"ok": false, "fail": "project_godot"}, Time.get_ticks_msec())
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
			continue
		var n: Node
		if res is PackedScene:
			n = (res as PackedScene).instantiate()
		elif res is GDScript:
			n = (res as GDScript).new()
		else:
			continue
		n.name = aname
		root.add_child(n)


func _autoloads_ok() -> bool:
	for n in ["Game", "Data", "Audio", "Debug", "Settings", "Save"]:
		if root.get_node_or_null(n) == null:
			return false
	return root.get_node("Game").cpp_ext_ok == true
