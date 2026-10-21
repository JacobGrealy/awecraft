extends SceneTree
# AC-0467 stage B instrument — the interact arm's place_ok=false anomaly
# (flag-OFF run: after_mine_cell reads 2 three frames after the mine loop
# observed 0; hit2 then sees the target solid and the place lands in the
# player's own cell, rejected). This probe mirrors the arm's EXACT
# sequence (set dirt -> teleport to the arm's aim camera -> start_mine ->
# wall-clock wait until the target clears -> release -> 3 frames ->
# after_mine read -> drop pickup loop -> teleport above the hole ->
# aim_hit -> place) and instruments every read of the target cell with
# the FULL data-layer state:
#   get       = world.get_block (the arm's read)
#   node      = the chunk node exists in world.chunks
#   data_empty= the node's slab data is empty (the record-only fallback
#               gate in get_block/set_block, world.gd)
#   edits     = the record-only edits-dict entry for the cell (the value
#               get_block returns when data is empty)
#   raw       = node.get_local (the real slab data, no fallback)
# Any 0 -> 2 reversion shows up here as exactly one layer flipping.
# One RESULT JSON line; exit 0 iff the sequence completed.

var _frame := 0


func _initialize() -> void:
	call_deferred("_run")


func _state(w: Node, tx: int, ty: int, tz: int) -> Dictionary:
	var cx := int(floorf(float(tx) / 16.0))
	var cz := int(floorf(float(tz) / 16.0))
	var c: Node = w.chunks.get(w._key(cx, cz))
	var edv: Variant = null
	var e: Variant = w.edits.get(w._key(cx, cz), null)
	if e != null:
		edv = (e as Dictionary).get((ty << 8) | ((tz & 15) << 4) | (tx & 15), null)
	if edv != null:
		edv = int((edv as Dictionary).get("b", -1))
	var raw: Variant = null
	if c != null and not c.data.is_empty():
		raw = int(c.get_local(tx & 15, ty, tz & 15))
	return {
		"frame": _frame,
		"get": int(w.get_block(tx, ty, tz)),
		"node": c != null,
		"data_empty": (c == null) or c.data.is_empty(),
		"edits": edv,
		"raw": raw,
	}


func _run() -> void:
	var t0 := Time.get_ticks_msec()
	var r: Dictionary = {"ok": false}
	_add_autoloads()
	if not _autoloads_ok():
		r["fail"] = "autoloads_missing"
		_finish(r, t0)
		return
	var mres := load("res://scenes/main.tscn")
	var main = (mres as PackedScene).instantiate()
	root.add_child(main)
	var w = main.world
	var p: Node3D = null
	for i in 3000:
		p = root.get_node("Game").player
		if p != null:
			break
		await physics_frame
	if p == null:
		r["fail"] = "no_player"
		_finish(r, t0)
		return
	var sp0: Vector3 = w.spawn_point()
	var sw := 0
	while sw < 900 and w.surface_top(int(sp0.x), int(sp0.z)) <= 0:
		_frame += 1
		await physics_frame
		sw += 1
	var aim: Dictionary = main._find_aim_spot()
	if aim.is_empty():
		r["fail"] = "no_aim_spot"
		_finish(r, t0)
		return
	var target: Vector3i = aim["cell"]
	r["target"] = [int(target.x), int(target.y), int(target.z)]
	r["aim_cam"] = [float(aim["cam"].x), float(aim["cam"].y), float(aim["cam"].z)]
	var changes: Array = []
	var last := ""
	# mirror the arm exactly from here
	w.set_block(int(target.x), int(target.y), int(target.z), 2)
	var cam: Vector3 = aim["cam"]
	var dbg: Node = root.get_node("Debug")
	dbg.fly(true)
	dbg.teleport(float(cam.x), float(cam.y) - p.EYE, float(cam.z))
	p.look(float(aim["yaw"]), float(aim["pitch"]))
	for i in 4:
		_frame += 1
		await physics_frame
	p.start_mine()
	var frames := 0
	var t_end := Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < t_end and w.get_block(int(target.x), int(target.y), int(target.z)) != 0:
		_frame += 1
		await physics_frame
		frames += 1
		var s := _state(w, int(target.x), int(target.y), int(target.z))
		var k := str(s)
		if k != last:
			changes.append(s)
			last = k
	p.release_mine()
	for i in 3:
		_frame += 1
		await physics_frame
	var after_mine_s := _state(w, int(target.x), int(target.y), int(target.z))
	r["mine_frames"] = frames
	r["state_changes_during_mine"] = changes
	r["after_mine"] = after_mine_s
	# the drop pickup loop (mirrored)
	var inv_n := 0
	var teleported := false
	var game: Node = root.get_node("Game")
	for i in 300:
		_frame += 1
		var dn: Node3D = null
		if game.drops.get_child_count() > 0:
			dn = game.drops.get_child(0)
		if dn != null and not teleported and dn.settled:
			dbg.teleport(float(dn.position.x), float(dn.position.y) + 1.4, float(dn.position.z))
			teleported = true
		inv_n = main._count_item(p, 2)
		if inv_n > 0:
			break
		await physics_frame
	r["drop_teleported"] = teleported
	r["inv_n"] = inv_n
	p.sel = main._slot_of(p, 2)
	dbg.teleport(float(target.x) + 0.5, float(target.y) + 1.05, float(target.z) + 0.5)
	p.look(0.0, -p.PITCH_LIMIT)
	for i in 3:
		_frame += 1
		await physics_frame
	var pre_aim := _state(w, int(target.x), int(target.y), int(target.z))
	var hit2: Dictionary = p.aim_hit()
	r["pre_aim_state"] = pre_aim
	r["hit2"] = [
		int(hit2.get("cell", Vector3i.ZERO).x),
		int(hit2.get("cell", Vector3i.ZERO).y),
		int(hit2.get("cell", Vector3i.ZERO).z),
	]
	r["hit2_id"] = int(hit2.get("id", -1))
	p.place()
	for i in 2:
		_frame += 1
		await physics_frame
	var place_cell: Vector3i = hit2.get("cell", Vector3i.ZERO) + hit2.get("normal", Vector3i.ZERO) if hit2.hit else Vector3i.ZERO
	r["place_cell"] = [int(place_cell.x), int(place_cell.y), int(place_cell.z)]
	if place_cell != Vector3i.ZERO:
		r["after_place"] = _state(w, int(place_cell.x), int(place_cell.y), int(place_cell.z))
	else:
		r["after_place"] = null
	r["ok"] = true
	r["ms"] = Time.get_ticks_msec() - t0
	_finish(r, t0)


func _finish(r: Dictionary, t0: int) -> void:
	r["ms"] = r.get("ms", Time.get_ticks_msec() - t0)
	print("RESULT " + JSON.stringify(r))
	quit(0 if r.get("ok", false) else 1)


# ---------------------------------------------------------------- boot
func _add_autoloads() -> void:
	var f := FileAccess.open("res://project.godot", FileAccess.READ)
	if f == null:
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
