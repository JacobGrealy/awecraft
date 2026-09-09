extends Node

const MobScript = preload("res://entities/mob.gd")

var time:
	get:
		return Game.time_of_day
	set(t):
		Game.time_of_day = t


var player:
	get:
		return Game.player


var hunger:
	get:
		return 0.0 if Game.player == null else Game.player.hunger
	set(v):
		if Game.player != null:
			Game.player.hunger = clampf(float(v), 0.0, 20.0)

func snap(path) -> void:
	await RenderingServer.frame_post_draw
	var image := get_tree().root.get_viewport().get_texture().get_image()
	image.save_png(path)
	print("SNAP ", path, " ", image.get_width(), "x", image.get_height())

func result(dict) -> void:
	var json := JSON.stringify(dict)
	print("RESULT ", json)
	var file := FileAccess.open("user://debug_result.json", FileAccess.WRITE)
	if file:
		file.store_string(json)
		file.close()

func set_block(x, y, z, id) -> void:
	if Game.world:
		Game.world.set_block(x, y, z, id)

func block_at(x, y, z):
	if Game.world:
		return Game.world.get_block(x, y, z)
	return 0

func set_fluid(x, y, z, id, lvl) -> void:
	if Game.world:
		Game.world.set_fluid(x, y, z, id, lvl)

func fluid_at(x, y, z):
	if Game.world:
		return Game.world.fluid_at(x, y, z)
	return [0, 0]

func light_at(x, y, z):
	if Game.world:
		return Game.world.light_at(x, y, z)
	return {"sky": 0, "block": 0, "eff": 0}

func tick_fluids() -> void:
	if Game.world:
		Game.world.tick_fluids()

func give_item(id, n) -> void:
	if Game.player == null:
		return
	Game.player.inv_add(int(id), int(n))

func sel(index) -> void:
	if Game.player == null:
		return
	Game.player.sel = clampi(int(index), 0, 35)

func seed_inv() -> void:
	if Game.player == null:
		return
	var p = Game.player
	for i in p.inv.size():
		p.inv[i] = {"id": 0, "n": 0}
	for i in p.craft_grid.size():
		p.craft_grid[i] = {"id": 0, "n": 0}
	for i in p.table_grid.size():
		p.table_grid[i] = {"id": 0, "n": 0}
	for i in p.armor.size():
		p.armor[i] = 0
	p.held = {}
	p.inv[9] = {"id": 6, "n": 5}
	p.recompute_craft()
	Game.message("Seeded: 5 oak logs in storage[0]")

func teleport(x, y, z) -> void:
	if Game.player == null:
		return
	Game.player.position = Vector3(x, y, z)
	if Game.world != null:
		Game.world.recenter(x, z)

func aim_at(x, y, z) -> void:
	if Game.player == null:
		return
	Game.player.position = Vector3(x, y - Game.player.EYE, z)
	Game.player.look(0.0, 0.0)
	if Game.world != null:
		Game.world.recenter(x, z)

func inv_click(index: int, button: int = 0, shift: bool = false) -> void:
	if Game.player == null:
		return
	var p = Game.player
	var i := int(index)
	var ui: String = p.ui_mode
	if ui == "craft":
		if i >= 0 and i <= 8:
			p.craft_grid_click(i, int(button), bool(shift))
		elif i == 9:
			p.craft_output_click()
		return
	if i >= 0 and i <= 8:
		p.craft_grid_click(i, int(button), bool(shift))
	elif i == 9:
		p.craft_output_click()
	elif i >= 10 and i <= 13:
		p.armor_slot_click(i - 10, int(button), bool(shift))
	elif i >= 14 and i <= 40:
		p.inv_slot_click(i - 14, "storage", int(button), bool(shift))
	elif i >= 41 and i <= 49:
		p.inv_slot_click(i - 41, "hotbar", int(button), bool(shift))


func craft() -> void:
	if Game.player != null:
		Game.player.craft_output_click()


func damage_player(n) -> void:
	if Game.player != null:
		Game.player.damage_player(float(n), "debug")


func eat(item_id) -> void:
	if Game.player == null:
		return
	var p = Game.player
	var i: int = p.find_slot(int(item_id))
	if i < 0:
		return
	p.sel = i
	p.use_selected()


func dump_survival():
	if Game.player == null:
		return {"hp": 0.0, "hunger": 0.0, "armor": [0, 0, 0, 0], "points": 0, "reduce": 0.0, "dead": true}
	var p = Game.player
	var pts: int = p.armor_points()
	var armor_ids: Array = []
	for a in p.armor:
		armor_ids.append(int(a))
	return {
		"hp": roundf(p.hp * 100.0) / 100.0,
		"hunger": roundf(p.hunger * 1000.0) / 1000.0,
		"armor": armor_ids,
		"points": pts,
		"reduce": minf(0.8, float(pts) * 0.04),
		"dead": p.dead,
	}


func inv_dump():
	if Game.player == null:
		return {"sel": 0, "slots": [], "armor": [], "points": 0, "held": {}, "craft_grid": [], "table_grid": [], "craft_out": {}}
	var p = Game.player
	var slots: Array = []
	for i in p.inv.size():
		if int(p.inv[i]["id"]) != 0:
			slots.append({"i": i, "id": int(p.inv[i]["id"]), "n": int(p.inv[i]["n"])})
	var grid: Array = []
	for i in p.craft_grid.size():
		if int(p.craft_grid[i]["id"]) != 0:
			grid.append({"i": i, "id": int(p.craft_grid[i]["id"]), "n": int(p.craft_grid[i]["n"])})
	var tgrid: Array = []
	for i in p.table_grid.size():
		if int(p.table_grid[i]["id"]) != 0:
			tgrid.append({"i": i, "id": int(p.table_grid[i]["id"]), "n": int(p.table_grid[i]["n"])})
	var armor_ids: Array = []
	for a in p.armor:
		armor_ids.append(int(a))
	return {
		"sel": int(p.sel),
		"slots": slots,
		"armor": armor_ids,
		"points": p.armor_points(),
		"held": {} if p.held == {} else {"id": int(p.held["id"]), "n": int(p.held["n"])},
		"craft_grid": grid,
		"table_grid": tgrid,
		"craft_out": {} if p.craft_out == {} else {"id": int(p.craft_out["id"]), "n": int(p.craft_out["n"])},
	}


func armor_dump():
	if Game.player == null:
		return {"armor": [0, 0, 0, 0], "points": 0}
	var p = Game.player
	var armor_ids: Array = []
	for a in p.armor:
		armor_ids.append(int(a))
	return {"armor": armor_ids, "points": p.armor_points()}


func spawn_mob(key, x, y, z) -> Node3D:
	if Game.entities == null:
		return null
	var m: Node3D = MobScript.new()
	m.key = str(key)
	Game.entities.add_child(m)
	m.position = Vector3(float(x), float(y), float(z))
	return m

func mobs_list():
	var out: Array = []
	if Game.entities != null:
		for c in Game.entities.get_children():
			if c is Node3D and c.has_method("center"):
				out.append({
					"key": c.key,
					"hp": roundf(float(c.hp) * 100.0) / 100.0,
					"pos": [roundf(c.position.x * 100.0) / 100.0, roundf(c.position.y * 100.0) / 100.0, roundf(c.position.z * 100.0) / 100.0],
					"tamed": bool(c.tamed),
				})
	return out

# AC-0170: debug logging that tees into the in-game console when the
# Options "debug_logging" toggle is on (off = stdout / push_error only).
func log(msg) -> void:
	print("[dbg] ", msg)
	_tee_console(str(msg), "log")


func error(msg) -> void:
	push_error(str(msg))
	_tee_console(str(msg), "error")


func _tee_console(msg: String, tag: String) -> void:
	if not bool(Settings.values.get("debug_logging", false)):
		return
	if Game.console != null:
		Game.console.add_log("[%s] %s" % [tag, msg])
	session_log_line("[%s] %s" % [tag, msg])


# AC-0172: one-click bug capture - F8 in play or the console command
# bugreport. Builds user://bugs/awecraft_bug_<stamp>.zip with the
# report (seed / player pos / chunk origin / band / settings / stats /
# console tail), a viewport screenshot, and the session log when
# debug logging is on. Async (one frame for the render target); the F8
# handler and the console dispatch can call it fire-and-forget; the
# report announces itself via a message.
func bug_report() -> void:
	# headless never emits frame_post_draw (no rendering) - the viewport
	# image below is then a placeholder instead of a real frame.
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
	var t := Time.get_datetime_dict_from_system()
	var stamp := "%04d%02d%02d_%02d%02d%02d" % [
		int(t.year), int(t.month), int(t.day),
		int(t.hour), int(t.minute), int(t.second)]
	DirAccess.make_dir_recursive_absolute("user://bugs")
	var zip_path := "user://bugs/awecraft_bug_%s.zip" % stamp
	# a second capture in the same second gets a numbered name
	var n2 := 2
	while FileAccess.file_exists(zip_path):
		zip_path = "user://bugs/awecraft_bug_%s_%d.zip" % [stamp, n2]
		n2 += 1
	var lines: Array = []
	lines.append("AweCraft bug report - %s" % Time.get_datetime_string_from_system())
	lines.append("godot %s  build %s" % [
		Engine.get_version_info().string, Build.ID])
	lines.append("seed %s" % Settings.values.get("seed", "?"))
	lines.append("mode %s  time_of_day %.3f" % [
		Game.mode, Game.time_of_day])
	if Game.player != null:
		var p: Vector3 = Game.player.position
		lines.append("player %s" % p)
		lines.append("chunk_origin (%d, 0, %d)" % [
			int(floor(p.x / 16.0)), int(floor(p.z / 16.0))])
		lines.append("flying %s  dead %s" % [
			Game.player.flying, Game.player.dead])
	lines.append("band sim_dist=%s render_dist=%s" % [
		Settings.values.get("sim_dist"), Settings.values.get("render_dist")])
	lines.append("debug_logging %s  debug_stats %s" % [
		bool(Settings.values.get("debug_logging", false)),
		bool(Settings.values.get("debug_stats", false))])
	lines.append("stats fps=%d ram_proc=%.1fMB vram=%.0fMB" % [
		int(Performance.get_monitor(Performance.TIME_FPS)),
		float(OS.get_static_memory_usage()) / 1048576.0,
		float(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)) / 1048576.0])
	for k in Settings.values:
		lines.append("setting %s = %s" % [k, Settings.values[k]])
	if Game.console != null:
		lines.append("--- console log ---")
		var ct: String = Game.console.log_view.get_parsed_text()
		for ln in ct.split("\n"):
			if ln.strip_edges() != "":
				lines.append("console| %s" % ln)
	if Game.console != null and bool(Settings.values.get("debug_logging", false)):
		lines.append("--- debug output (session log) ---")
		if session_log_file != "" and FileAccess.file_exists(session_log_file):
			var sf := FileAccess.open(session_log_file, FileAccess.READ)
			if sf != null:
				var sdata: String = sf.get_as_text()
				sf.close()
				for ln in sdata.split("\n"):
					if ln.strip_edges() != "":
						lines.append("log| %s" % ln)
	var entries: Array = []
	entries.append(["report.txt",
		("\n".join(lines) + "\n").to_utf8_buffer()])
	# screenshot - may be a frame or two stale, fine for a bug report.
	# A null/empty image (headless has no render target) becomes a
	# small placeholder so the bundle always has a screenshot entry.
	var image := get_tree().root.get_viewport().get_texture().get_image()
	if image == null or image.get_width() <= 0:
		image = Image.create_empty(8, 8, false, Image.FORMAT_RGBA8)
		image.fill(Color(0.5, 0.5, 0.5))
	entries.append(["screenshot.png", image.save_png_to_buffer()])
	if session_log_file != "" and FileAccess.file_exists(session_log_file):
		var sf2 := FileAccess.open(session_log_file, FileAccess.READ)
		if sf2 != null:
			entries.append(["session.log", sf2.get_buffer(sf2.get_length())])
			sf2.close()
	if not ZipMini.make_zip(entries, zip_path):
		push_error("bug report: zip write failed")
		Game.message("Bug report FAILED")
		return
	print("[dbg] bug report -> %s" % zip_path)
	Game.message("Bug report saved")


# AC-0171: per-run session log - a NEW user://logs/awecraft_<stamp>.log
# each launch, pruned to the 5 newest (the 6th run deletes the oldest).
# The file is created lazily on the first line after the toggle is on.
# the file is opened per line and closed again - a long-lived handle
# buffers its writes and a second reader (the test, or the user) would
# see an empty file until process exit. (This 4.7 build has no
# FileAccess.APPEND flag, and READ_WRITE fails on a file that does not
# exist yet - so: WRITE to create, READ_WRITE + seek_end to append.)
var session_log_file := ""


func session_log_line(s: String) -> void:
	if not bool(Settings.values.get("debug_logging", false)):
		return
	if session_log_file == "":
		_session_log_start()
		if session_log_file == "":
			return
	var mode := FileAccess.READ_WRITE
	if not FileAccess.file_exists(session_log_file):
		mode = FileAccess.WRITE
	var f := FileAccess.open(session_log_file, mode)
	if f == null:
		return
	f.seek_end(0)
	f.store_line(Time.get_time_string_from_system() + " " + s)
	f.close()


func _session_log_start() -> void:
	var err := DirAccess.make_dir_recursive_absolute("user://logs")
	if err != OK and err != ERR_ALREADY_EXISTS:
		return
	var t := Time.get_datetime_dict_from_system()
	var stamp := "%04d%02d%02d_%02d%02d%02d" % [
		int(t.year), int(t.month), int(t.day),
		int(t.hour), int(t.minute), int(t.second)]
	session_log_file = "user://logs/awecraft_%s.log" % stamp
	# a same-second relaunch must not truncate the previous run's file
	while FileAccess.file_exists(session_log_file):
		var t2 := Time.get_datetime_dict_from_system()
		stamp = "%04d%02d%02d_%02d%02d%02d" % [
			int(t2.year), int(t2.month), int(t2.day),
			int(t2.hour), int(t2.minute), int(t2.second)]
		session_log_file = "user://logs/awecraft_%s.log" % stamp
	# create it now (WRITE) so the prune below counts it: 6 files in ->
	# the oldest one out -> 5 kept.
	var f0 := FileAccess.open(session_log_file, FileAccess.WRITE)
	if f0 != null:
		f0.close()
	_session_prune()


# keep only the 5 newest awecraft_*.log (names sort chronologically)
func _session_prune() -> void:
	var files: Array = []
	var da := DirAccess.open("user://logs")
	if da == null:
		return
	da.list_dir_begin()
	var f := da.get_next()
	while f != "":
		if f.begins_with("awecraft_") and f.ends_with(".log") and not da.current_is_dir():
			files.append(f)
		f = da.get_next()
	da.list_dir_end()
	files.sort()
	while files.size() > 5:
		var old: String = files.pop_front()
		DirAccess.remove_absolute("user://logs/" + old)


func session_log_path() -> String:
	return session_log_file


func set_time(t) -> void:
	Game.time_of_day = t

func fly(enabled) -> void:
	if Game.player != null:
		Game.player.set_fly(bool(enabled))

func swing(frac: float = 0.5, kind: int = -1) -> void:
	if Game.player != null:
		Game.player.hold_swing(float(frac), int(kind))

func swing_clear() -> void:
	if Game.player != null:
		Game.player.clear_swing()

func swing_read() -> Dictionary:
	if Game.player == null:
		return {"active": false, "frac": 0.0, "fist": false}
	var p = Game.player
	var fist := false
	if p.held_fist != null:
		fist = p.held_fist.visible
	return {"active": true, "frac": p.swing_frac(), "fist": fist}
