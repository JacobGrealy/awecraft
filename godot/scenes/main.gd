extends Node3D

const WorldRes = preload("res://world/world.tscn")
const PlayerRes = preload("res://player/player.tscn")
const InventoryScript = preload("res://ui/inventory.gd")
const AtlasScript = preload("res://core/atlas.gd")
const DayNight = preload("res://core/daynight.gd")
const MenuRes = preload("res://scenes/menu.tscn")
const AeroLib = preload("res://core/aero.gd")
const ChunkIO = preload("res://core/chunk_io.gd")  # AC-0155

var world: Node3D
var camera: Camera3D
var player: Node3D
var drops: Node
var entities: Node
var sun: DirectionalLight3D
var world_env: WorldEnvironment
var env: Environment
var inventory_ui: CanvasLayer
var menu_ui: Menu
var stats_overlay: CanvasLayer
var _stats_prev_t := -1
var _stats_prev_proc := 0.0
var _stats_acc := 0.0
var aero := false
var _batt := false
var aero_sky: MeshInstance3D
var aero_sky_mat: ShaderMaterial
var aero_wash: MeshInstance3D
var aero_wash_mesh: QuadMesh
var _star_node: MeshInstance3D
var _star_mat: ShaderMaterial


func _ready() -> void:
	# AC-0208: fail fast — if the C++ extension is missing, Game._ready already
	# pushed the error + banner and requested quit; boot nothing.
	if not Game.cpp_ext_ok:
		return
	var import_pack := OS.get_environment("AWECRAFT_IMPORT_PACK")
	if import_pack != "":
		var imp := AtlasScript.import_pack(import_pack)
		print("ATLAS_IMPORT ", JSON.stringify(imp))
		Debug.result(imp)
		get_tree().quit()
		return

	sun = DirectionalLight3D.new()
	sun.shadow_enabled = false
	add_child(sun)

	world_env = WorldEnvironment.new()
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	if OS.get_environment("AWECRAFT_NO_FOG") == "1":
		env.fog_enabled = false
	world_env.environment = env
	add_child(world_env)
	aero = AeroLib.enabled()
	if aero:
		_setup_aero()

	var snapshot_path := OS.get_environment("AWECRAFT_SNAPSHOT")
	var logic := OS.get_environment("AWECRAFT_LOGIC")
	var cam := OS.get_environment("AWECRAFT_CAM")
	var size_env := OS.get_environment("AWECRAFT_SIZE")
	if size_env != "":
		var parts := size_env.split(",")
		get_window().size = Vector2i(parts[0].to_int(), parts[1].to_int())
	if size_env == "":
		Settings.apply_window(get_window())
	Settings.apply_audio()
	var seed_env := OS.get_environment("AWECRAFT_SEED")
	var time_env := OS.get_environment("AWECRAFT_TIME")
	if time_env != "":
		Game.time_of_day = fmod(time_env.to_float(), 1.0)
	var anim_phase_env := OS.get_environment("AWECRAFT_ANIM_PHASE")
	if anim_phase_env != "":
		for bid in Data.fluid_anim_mats:
			Data.fluid_anim_mats[bid].set_shader_parameter("phase", anim_phase_env.to_float())
	_update_sky()

	var menu_shot := OS.get_environment("AWECRAFT_MENU_SHOT")
	if menu_shot != "":
		_setup_menu_camera()
		var menu := _make_menu()
		if OS.get_environment("AWECRAFT_MENU_VIEW") == "options":
			menu.open_options("main")
		for i in 6:
			await get_tree().process_frame
		await Debug.snap(menu_shot)
		Debug.result({"menu": true, "mode": Game.mode, "build": Build.ID, "values": Settings.values})
		get_tree().quit()
		return

	var menu_boot := OS.get_environment("AWECRAFT_MENU_BOOT") == "1"
	var battery_env := OS.get_environment("AWECRAFT_BATTERY")
	if battery_env != "":
		await _run_battery(seed_env, battery_env)
		return
	if logic == "mainmenuexit":
		await _mainmenuexit_test()
		return
	if logic != "":
		await _run_game(seed_env, logic, cam, snapshot_path)
		return
	if (snapshot_path != "" or _harness_env_set()) and not (menu_boot and snapshot_path != ""):
		await _run_game(seed_env, logic, cam, snapshot_path)
		return

	var headless_idle := DisplayServer.get_name() == "headless" \
		and logic == "" and snapshot_path == "" and not menu_boot and not _harness_env_set()
	# menu-first boot on every display platform; AWECRAFT_MENU=0 = explicit game-first skip
	var want_menu := not headless_idle and OS.get_environment("AWECRAFT_MENU") != "0"
	if want_menu:
		await _boot_menu()
		if menu_boot:
			await menu_ui.play_clicked()
			if OS.get_environment("AWECRAFT_PAUSE_SHOT") == "1":
				await _pause_shot_finish()
			elif snapshot_path != "":
				await _snapshot_finish(cam)
	elif not headless_idle:
		await _run_game(seed_env, logic, cam, snapshot_path)


const _BATT_RESET_WASD := ["move_forward", "move_back", "move_left", "move_right"]


var _batt_drop_freeze := false


func _batt_reset_state(spawn: Vector3) -> void:
	_batt_drop_freeze = true
	Game.mode = "pause"
	var old_player: Node = Game.player
	Game.player = null
	if old_player != null:
		old_player.free()
	for e in world.chunks.values():
		e.clear_data()  # AC-0203: was fill(0) on both flat arrays
	for ch in Game.drops.get_children():
		ch.free()
	world.light_dirty.clear()
	world.light_pending.clear()
	world.light_pending_set.clear()
	world.fluid_dirty.clear()
	world.tex_refresh.clear()
	world.fluid_sim_enabled = false
	world.render_radius = 4
	for a in _BATT_RESET_WASD:
		if Input.is_action_pressed(a):
			Input.action_release(a)
	Game.time_of_day = 0.3
	world.recenter(spawn.x, spawn.z, true)
	await _await_world_build(spawn, 3000)


func _genhash_print(seed_env: String) -> void:
	if seed_env != "":
		Game.world_seed = seed_env.to_int()
	var t0 := Time.get_ticks_msec()
	for cx in range(-2, 3):
		for cz in range(-2, 3):
			var d := WorldGen.generate(cx, cz, Game.world_seed)
			var h := HashingContext.new()
			h.start(HashingContext.HASH_MD5)
			h.update(d)
			var md5: PackedByteArray = h.finish()
			var hx := ""
			for i in range(16):
				hx += "%02x" % md5[i]
			print("GENHASH ", cx, " ", cz, " ", hx)
	print("GENMS ", Time.get_ticks_msec() - t0)


# AC-0197: per-column encoded-byte probe (storage gate). Generates N real
# columns (spawn + golden-angle ring for terrain spread), self-lights each,
# encodes through the current codec and reports the on-disk byte stats +
# per-column top (max non-air y). Codec-agnostic: run against v2 (before)
# and v3 (after) for the byte delta.
func _colbytes_test(seed_env: String) -> void:
	var seed := Game.world_seed
	if seed_env != "":
		seed = seed_env.to_int()
	var hmax := Data.HEIGHT
	var n := int(OS.get_environment("AWECRAFT_COLBYTES_N"))
	if n <= 0:
		n = 25
	Lighting._tables()
	var pts: Array = [[0, 0]]
	var k := 0
	while pts.size() < n:
		var ang := float(k) * 2.399963229728653
		var cxr := int(floorf(cos(ang) * 24.0))
		var czr := int(floorf(sin(ang) * 24.0))
		if cxr != 0 or czr != 0:
			pts.append([cxr, czr])
		k += 1
	var per: Array = []
	var tot := 0
	var mn_b := 1073741824
	var mx_b := 0
	var top_min := 1073741824
	var top_max := -1
	var t0 := Time.get_ticks_msec()
	for p in pts:
		var cx := int(p[0])
		var cz := int(p[1])
		var d := WorldGen.generate(cx, cz, seed)
		var f := PackedByteArray()
		f.resize(d.size())
		# AC-0203: the pull kernel now reads the slab store.
		var l := Lighting.compute_light_flat_chunk_pull(ChunkIO.palettize_flat(d, 24), cx, cz, hmax, [], [], [])
		var blob := ChunkIO.encode_column(d, f, seed, hmax, l)
		var top := -1
		var y := hmax - 1
		while y >= 0:
			var row := y << 8
			var anyv := false
			var i := 0
			while i < 256:
				if d[row + i] != 0:
					anyv = true
					break
				i += 1
			if anyv:
				top = y
				break
			y -= 1
		if top < top_min:
			top_min = top
		if top > top_max:
			top_max = top
		tot += blob.size()
		if blob.size() < mn_b:
			mn_b = blob.size()
		if blob.size() > mx_b:
			mx_b = blob.size()
		per.append({"cx": cx, "cz": cz, "top": top, "bytes": blob.size()})
	Debug.result({
		"ok": true,
		"n": pts.size(),
		"seed": seed,
		"codec_version": ChunkIO.VERSION,
		"bytes_min": mn_b,
		"bytes_avg": tot / pts.size(),
		"bytes_max": mx_b,
		"top_min": top_min,
		"top_max": top_max,
		"ms": Time.get_ticks_msec() - t0,
		"per_col": per,
	})
	get_tree().quit()


func _slabwrite_test() -> void:
	# AC-0203 harness (game context — needs the Data autoload): the
	# _slab_write point-write invariant vs a flat reference. A random
	# walk of 2000 writes over a natural column + a palette-boundary
	# column exercises the palette-growth / repack (bits widen) /
	# raw-ification (>16 ids) / null-ification (nz -> 0) paths.
	var h: int = Data.HEIGHT
	var ok := true
	var details: Array = []
	for seedcol in [[3, -5, 987654], [0, 0, 424242]]:
		var base: PackedByteArray = WorldGen.generate(int(seedcol[0]), int(seedcol[1]), int(seedcol[2]))
		var slabs: Array = ChunkIO._slabs_deepcopy(ChunkIO.palettize_flat(base, _ChunkScriptM.slab_n()))
		var ref := PackedByteArray(base)
		var rng := RandomNumberGenerator.new()
		rng.seed = 99 + int(seedcol[2]) % 7
		for k in range(1000):
			var y := rng.randi() % h
			var lz := rng.randi() % 16
			var lx := rng.randi() % 16
			var idx := (y << 8) | (lz << 4) | lx
			var v: int
			if ref[idx] == 0:
				v = 1 + rng.randi() % 20
			else:
				v = rng.randi() % 21
			_ChunkScriptM._slab_write(slabs, y, lz, lx, v)
			ref[idx] = v
		var rt := ChunkIO._slabs_flat(slabs) == ref
		details.append({"col": str(seedcol[0]) + "," + str(seedcol[1]), "rt": rt})
		ok = ok and rt
	# explicit boundary column: 16 / 17(raw) / 5 / 2 / 1 / 8 / 9 unique per slab
	var bnd := PackedByteArray()
	bnd.resize(256 * h)
	for x in range(256):
		bnd[x] = (x % 16) + 1
		bnd[4096 + x] = (x % 17) + 1
		bnd[8192 + x] = (x % 5) + 1
		bnd[12288 + x] = 1 + (x & 1)
		bnd[20480 + x] = (x % 8) + 1
		bnd[24576 + x] = (x % 9) + 1
	for x in range(4096):
		bnd[16384 + x] = 7
	var slabs2: Array = ChunkIO._slabs_deepcopy(ChunkIO.palettize_flat(bnd, _ChunkScriptM.slab_n()))
	var ref2 := PackedByteArray(bnd)
	var rng2 := RandomNumberGenerator.new()
	rng2.seed = 7
	for k in range(1000):
		var y := rng2.randi() % 64
		var lz := rng2.randi() % 16
		var lx := rng2.randi() % 16
		var idx := (y << 8) | (lz << 4) | lx
		var v: int
		if ref2[idx] == 0:
			v = 1 + rng2.randi() % 20
		else:
			v = rng2.randi() % 21
		_ChunkScriptM._slab_write(slabs2, y, lz, lx, v)
		ref2[idx] = v
	var rt2 := ChunkIO._slabs_flat(slabs2) == ref2
	details.append({"col": "boundary", "rt": rt2})
	ok = ok and rt2
	Debug.result({"ok": ok, "h": h, "cols": details})


func _batt_run_mode(mode: String, spawn: Vector3, seed_env: String) -> void:
	if mode == "settings":
		_settings_test()
		return
	_create_game_nodes()
	var sp: Vector3 = world.spawn_point()
	world.fluid_sim_enabled = false
	match mode:
		"player":
			world.recenter(spawn.x, spawn.z, true)
			await _await_spawn_floor(spawn, 300)
			player = _spawn_player()
			await _player_logic_test_body()
		"interact":
			world.recenter(spawn.x, spawn.z, true)
			player = _spawn_player()
			await _interact_test_body()
		"light":
			world.collision_enabled = false
			world.recenter(float(WorldGen.SPAWN_X), float(WorldGen.SPAWN_Z), false)
			_light_test(spawn)
		"fluids":
			world.collision_enabled = false
			world.recenter(float(WorldGen.SPAWN_X), float(WorldGen.SPAWN_Z), false)
			_fluids_test(spawn)
		"buckets":
			world.collision_enabled = false
			world.recenter(float(WorldGen.SPAWN_X), float(WorldGen.SPAWN_Z), true)
			player = _spawn_player()
			await _buckets_test_body()
		"genhash":
			_genhash_print(seed_env)
		_:
			print("BATTSKIP ", mode)
	if sp != spawn:
		print("BATTWARN spawn_moved ", mode)
	Game.time_of_day = 0.3


func _run_battery(seed_env: String, battery_env: String) -> void:
	_batt = true
	OS.set_environment("AWECRAFT_IGNORE_SETTINGS", "1")
	Settings.load_settings()
	OS.set_environment("AWECRAFT_IGNORE_SETTINGS", "")
	var modes: Array = []
	for m in battery_env.split(";"):
		if m != "":
			modes.append(m)
	var t_start := Time.get_ticks_msec()
	var summary: Dictionary = {}
	var ok_all := true
	for mode in modes:
		var t0 := Time.get_ticks_msec()
		Game.new_world(44 if seed_env == "" else seed_env.to_int())
		_create_game_nodes()
		var spawn: Vector3 = world.spawn_point()
		await _batt_run_mode(mode, spawn, seed_env)
		print("BATTMODE %s ms=%d" % [mode, Time.get_ticks_msec() - t0])
		var rf := FileAccess.open("user://debug_result.json", FileAccess.READ)
		var parsed: Dictionary = {}
		if rf != null:
			var rd: Variant = JSON.parse_string(rf.get_as_text())
			if typeof(rd) == TYPE_DICTIONARY:
				parsed = rd
			rf.close()
		parsed["ms"] = Time.get_ticks_msec() - t0
		summary[mode] = parsed
		if mode != "genhash" and not parsed.get("ok", true):
			ok_all = false
		if mode != modes[modes.size() - 1]:
			await _batt_reset_state(spawn)
		_batt_drop_freeze = false
		Game.mode = "play"
	Debug.result({"battery": summary, "ok": ok_all, "total_ms": Time.get_ticks_msec() - t_start})
	get_tree().quit()


func _create_game_nodes() -> void:
	world = WorldRes.instantiate()
	world.name = "World"
	add_child(world)
	if OS.get_environment("AWECRAFT_NO_COLLISION") == "1":
		world.collision_enabled = false
	var rad := OS.get_environment("AWECRAFT_RADIUS")
	if rad != "":
		world.render_radius = rad.to_int()
	else:
		Settings.apply_world()
		if _harness_env_set():
			world.render_radius = 4

	drops = Node.new()
	drops.name = "Drops"
	add_child(drops)
	Game.drops = drops
	entities = Node.new()
	entities.name = "Entities"
	add_child(entities)
	Game.entities = entities
	inventory_ui = InventoryScript.new()
	inventory_ui.name = "Inventory"
	add_child(inventory_ui)
	Game.hotbar = inventory_ui
	if _star_node != null:
		_star_node.queue_free()
		_star_node = null
	_star_mat = ShaderMaterial.new()
	_star_mat.shader = load("res://core/star.gdshader")
	_star_mat.set_shader_parameter("u_opacity", 1.0)
	_star_node = MeshInstance3D.new()
	_star_node.name = "Stars"
	_star_node.mesh = _build_star_mesh()
	_star_node.material_override = _star_mat
	_star_node.visible = false
	add_child(_star_node)
	if stats_overlay != null:
		stats_overlay.queue_free()
	stats_overlay = CanvasLayer.new()
	stats_overlay.name = "StatsOverlay"
	stats_overlay.layer = 25
	var sl := Label.new()
	sl.name = "StatsLabel"
	sl.position = Vector2(8, 8)
	sl.add_theme_color_override("font_color", Color(0.45, 1.0, 0.55, 1.0))
	sl.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.9))
	sl.add_theme_constant_override("shadow_offset_x", 1)
	sl.add_theme_constant_override("shadow_offset_y", 1)
	sl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sl.text = "FPS: -  CPU: -\nRAM: -\nVRAM: -"
	stats_overlay.add_child(sl)
	add_child(stats_overlay)
	_stats_prev_t = -1
	_stats_prev_proc = 0.0
	_stats_acc = 0.0
	_refresh_stats()


static func _vl_mb_wrap(a: int) -> int:
	var r := a & 0xFFFFFFFF
	if r >= 0x80000000:
		r -= 0x100000000
	return r


static func _vl_mb_ursh(x: int, n: int) -> int:
	return (x & 0xFFFFFFFF) >> n


static func _vl_mb_imul(a: int, b: int) -> int:
	return _vl_mb_wrap(a * b)


static func _vl_mb_next(st: Array) -> float:
	var a: int = _vl_mb_wrap(int(st[0]))
	a = _vl_mb_wrap(a + 0x6D2B79F5)
	var t0: int = _vl_mb_imul(a ^ _vl_mb_ursh(a, 15), 1 | a)
	var t1: int = _vl_mb_wrap(t0 + _vl_mb_imul(t0 ^ _vl_mb_ursh(t0, 7), 61 | t0))
	var t: int = t1 ^ t0
	st[0] = a
	var r: int = t ^ _vl_mb_ursh(t, 14)
	return float(_vl_mb_ursh(r, 0)) / 4294967296.0


func _build_star_mesh() -> ArrayMesh:
	var st := [42]
	var v := PackedVector3Array()
	var u := PackedVector2Array()
	var idx := PackedInt32Array()
	for i in 500:
		var u1: float = _vl_mb_next(st)
		var u2: float = _vl_mb_next(st)
		var phi: float = acos(2.0 * u1 - 1.0)
		var theta: float = u2 * TAU
		var p := Vector3(320.0 * sin(phi) * sin(theta), 320.0 * cos(phi), 320.0 * sin(phi) * cos(theta))
		var base := v.size()
		for cv in [Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(1.0, 1.0), Vector2(0.0, 1.0)]:
			v.append(p)
			u.append(cv)
		idx.append(base)
		idx.append(base + 1)
		idx.append(base + 2)
		idx.append(base)
		idx.append(base + 2)
		idx.append(base + 3)
	var arrs: Array = []
	arrs.resize(Mesh.ARRAY_MAX)
	arrs[Mesh.ARRAY_VERTEX] = v
	arrs[Mesh.ARRAY_TEX_UV] = u
	arrs[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrs)
	return m


const HARNESS_ENVS := [
	"AWECRAFT_LOGIC", "AWECRAFT_SNAPSHOT", "AWECRAFT_SNAPSHOT2", "AWECRAFT_INV", "AWECRAFT_FLUID_SHOT", "AWECRAFT_CAM",
	"AWECRAFT_HELD", "AWECRAFT_WALK_SHOT", "AWECRAFT_EMPTYHAND", "AWECRAFT_SWING", "AWECRAFT_FPV_ITEM",
	"AWECRAFT_ANIM_SHOT", "AWECRAFT_PROBE", "AWECRAFT_BCELL", "AWECRAFT_MESH_INFO", "AWECRAFT_ONLY",
	"AWECRAFT_DBG", "AWECRAFT_SETTLE_TICKS", "AWECRAFT_SEED", "AWECRAFT_TIME", "AWECRAFT_ANIM_PHASE",
	"AWECRAFT_SIZE", "AWECRAFT_HP", "AWECRAFT_HUNGER", "AWECRAFT_BATTERY",
	"AWECRAFT_BS_CASE", "AWECRAFT_BS_QUIESCE",
]


func _harness_env_set() -> bool:
	for e in HARNESS_ENVS:
		if OS.get_environment(e) != "":
			return true
	return false


const _ChunkScriptM = preload("res://world/chunk.gd")  # AC-0120 G3 probe (harness-only)

# AC-0120 G3: material-allocation probe — distinct materials attached to built
# chunk meshes (mesh + fluid + flora instances; mesh_info() misses flora)
# plus the chunk.gd build-path alloc counter. Env-gated by AWECRAFT_MESH_INFO.
func _matinfo_counts() -> Dictionary:
	var mat_ids := {}
	var std_ids := {}
	var built_n := 0
	for key in world.chunks:
		var c: Node3D = world.chunks[key]
		if not c.mesh_built:
			continue
		built_n += 1
		for s in c.slabs:
			for inst in [s.mesh_instance, s.fluid_instance, s.flora_instance]:
				if inst == null or inst.mesh == null:
					continue
				var am: ArrayMesh = inst.mesh
				for ss in range(am.get_surface_count()):
					var mat = am.surface_get_material(ss)
					if mat == null:
						continue
					mat_ids[mat.get_instance_id()] = true
					if mat is StandardMaterial3D:
						std_ids[mat.get_instance_id()] = true
	return {"built_chunks": built_n, "distinct_std": std_ids.size(),
			"distinct_all": mat_ids.size(), "total_allocs": int(_ChunkScriptM._mat_alloc_count)}


func _boot_menu() -> void:
	await get_tree().process_frame
	_setup_menu_camera()
	_make_menu()


func _pause_shot_finish() -> void:
	var snapshot_path := OS.get_environment("AWECRAFT_SNAPSHOT")
	var spawn: Vector3 = world.spawn_point()
	await _await_world_build(spawn, 3000)
	for i in 6:
		await get_tree().physics_frame
	var ke := InputEventKey.new()
	ke.physical_keycode = KEY_P
	ke.pressed = true
	Input.parse_input_event(ke)
	for i in 8:
		await get_tree().physics_frame
	await Debug.snap(snapshot_path)
	Debug.result({"pause_shot": true, "mode": Game.mode, "w": int(get_viewport().size.x), "h": int(get_viewport().size.y)})
	get_tree().quit()


func _setup_menu_camera() -> void:
	if camera != null:
		return
	camera = _make_camera()
	camera.position = Vector3.ZERO
	camera.current = true


func _make_menu() -> Menu:
	menu_ui = MenuRes.instantiate()
	menu_ui.name = "Menu"
	menu_ui.on_play = Callable(self, "_menu_play")
	menu_ui.on_new_world = Callable(self, "_menu_new_world")
	menu_ui.on_resume = Callable(self, "_menu_resume")
	menu_ui.on_quit_to_menu = Callable(self, "quit_to_menu")
	menu_ui.on_continue = Callable(self, "_menu_continue")
	add_child(menu_ui)
	return menu_ui


func _menu_play() -> void:
	var slot := Save.first_occupied_slot()
	if slot >= 0:
		await _menu_continue(slot)
		return
	var seed := int(Settings.values.get("seed", 44))
	Settings.set_value("seed", seed)
	var s2 := Save.first_empty_slot()
	Save.active_slot = s2
	await start_game(seed)
	Save.save_now(s2)


func _menu_new_world(seed: int) -> void:
	Settings.set_value("seed", int(seed))
	var slot := Save.first_empty_slot()
	Save.active_slot = slot
	await start_game(int(seed))
	Save.save_now(slot)


func _menu_continue(slot: int) -> void:
	await _continue_slot(slot)


func _menu_resume() -> void:
	Game.resume()


func _autosave() -> void:
	if Save.active_slot >= 0 and Game.world != null and Game.player != null:
		Save.save_now(Save.active_slot)


func quit_to_menu() -> void:
	_autosave()
	_free_game_nodes()
	Game.mode = "menu"
	if menu_ui != null:
		menu_ui.show_main()
		menu_ui.refresh_slots()


# AC-0143 M5: v2 save edits ("0:face:ccx:ccz:local") -> runtime form
# ("<ccx>,<ccz>" -> {local: {b,f}}). Only 5-part keys are converted; any
# other shape means the save soft-failed in _continue_slot first.
func _conv_edits_v2(edits_raw) -> Dictionary:
	var conv: Dictionary = {}
	if typeof(edits_raw) != TYPE_DICTIONARY:
		return conv
	for ek in edits_raw:
		var ep: PackedStringArray = String(ek).split(":")
		if ep.size() != 5:
			continue
		var ck: String = "%d,%d" % [int(ep[2]), int(ep[3])]
		if not conv.has(ck):
			conv[ck] = {}
		conv[ck][int(ep[4])] = edits_raw[ek]
	return conv


func _continue_slot(slot: int) -> void:
	var data := Save.load_full(int(slot))
	if data.is_empty():
		return
	# AC-0091 SOFT-FAIL: a save recorded at a different world height (H=80
	# pre-AC-0091 saves lack the "height" key entirely) is treated as a NEW
	# world at the SAME seed: edits and the saved player pose are dropped
	# (their y-space no longer matches the terrain), spawn_point is used.
	# Never a script error.
	var height_ok: bool = int(data.get("height", 0)) == Data.HEIGHT
	# AC-0143 M5 SOFT-FAIL: v2 saves carry planets:[{id,R,orbit}] and edits
	# keyed "planet_id:face:cx:cz:local" (home pair: face 0 = ccx >= 0 half,
	# face 1 = ccx < 0 half; planet 0). Old saves (no planets, old "cx,cz"
	# edit keys, or a non-home face/planet in an edit key) are discarded:
	# fresh world at the same seed + one clear log line. R is clamped to
	# [2000, 8000] on load (AC-0147 range). P1a never records non-home edits
	# (faces 2-11 are data-level only; player edits land with AC-0144+).
	var planets = data.get("planets", null)
	var planets_ok: bool = typeof(planets) == TYPE_ARRAY and (planets as Array).size() > 0
	var edits_raw = data.get("edits", {})
	var edits_v2_ok: bool = typeof(edits_raw) == TYPE_DICTIONARY
	if edits_v2_ok:
		for ek in edits_raw:
			var ep: PackedStringArray = String(ek).split(":")
			if ep.size() != 5 or int(ep[0]) != 0 or int(ep[1]) < 0 or int(ep[1]) > 1:
				edits_v2_ok = false
				break
	if height_ok and (not planets_ok or not edits_v2_ok):
		print("SAVE SOFT-FAIL (old save format: planets_ok=%d edits_v2_ok=%d) - edits discarded, fresh world" % [int(planets_ok), int(edits_v2_ok)])
	Save.active_slot = int(slot)
	if world != null:
		_free_game_nodes()
	Game.new_world(int(data.get("seed", 1)))
	if planets_ok:
		var home = (planets as Array)[0]
		if typeof(home) == TYPE_DICTIONARY:
			Game.planet_R = clampf(float((home as Dictionary).get("R", 4000.0)), 2000.0, 8000.0)
	_create_game_nodes()
	if height_ok and planets_ok and edits_v2_ok:
		world.edits = _conv_edits_v2(edits_raw)
	var ps: Dictionary = data.get("player", {})
	var pos: Array = ps.get("pos", [])
	var target: Vector3
	if height_ok and pos.size() == 3:
		target = Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
	else:
		target = world.spawn_point()
	world.recenter(target.x, target.z, true)
	await _await_core_3x3(target, 3000)
	player = _spawn_player()
	_restore_player(ps if height_ok else {})
	if Game.world != null:
		world.recenter(player.position.x, player.position.z)
	Game.time_of_day = float(data.get("time", 0.0))
	Game.start()
	_apply_aw_query()


func _restore_player(ps: Dictionary) -> void:
	if player == null or ps.is_empty():
		return
	var p = player
	var pos: Array = ps.get("pos", [])
	if pos.size() == 3:
		p.position = Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
	p.look(float(ps.get("yaw", 0.0)), float(ps.get("pitch", 0.0)))
	p.sel = int(ps.get("sel", 0))
	p.hp = float(ps.get("hp", 20.0))
	p.hunger = float(ps.get("hunger", 20.0))
	var inv: Array = ps.get("inv", [])
	if inv.size() == p.inv.size():
		for i in inv.size():
			var it = inv[i]
			p.inv[i] = {"id": int(it.get("id", 0)), "n": int(it.get("n", 0))}
	var armor: Array = ps.get("armor", [])
	if armor.size() == p.armor.size():
		for i in armor.size():
			p.armor[i] = int(armor[i])
	if p.has_method("refresh_held"):
		p.refresh_held()


func start_game(seed: int) -> void:
	Game.new_world(seed)
	_create_game_nodes()
	var spawn: Vector3 = world.spawn_point()
	world.recenter(spawn.x, spawn.z, true)
	world.start_loading("Generating world...")  # AC-0178: first-spawn loading window
	await _await_spawn_floor(spawn, 300)
	player = _spawn_player()
	Game.start()
	_apply_aw_query()


func _apply_aw_query() -> void:
	var spec := ""
	for a in OS.get_cmdline_user_args():
		var s := String(a)
		if s.begins_with("aw="):
			spec = s.substr(3)
	if spec == "" or player == null:
		return
	var pairs := spec.split("|")
	for pair in pairs:
		var pp := pair.split(":")
		if not pp[0].is_valid_int():
			continue
		Debug.give_item(int(pp[0]), int(pp[1]) if pp.size() > 1 else 1)
	player.sel = _slot_of(player, int(pairs[0].split(":")[0]))
	Game.message("Debug items given (%s)" % spec)
	if spec.contains("waterfall"):
		_web_waterfall()


func _web_waterfall() -> void:
	if player == null or world == null:
		return
	var sp: Vector3 = world.spawn_point()
	var fx := int(sp.x)
	var fz := int(sp.z)
	var sy: int = _fluidfall_build(fx, fz)
	Debug.set_fluid(fx, sy + 8, fz, 5, 8)
	var px := fx + 9
	var pz := fz + 9
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			for dy in range(1, 4):
				Debug.set_block(px + dx, sy + dy, pz + dz, 0)
	Debug.teleport(float(px) + 0.5, float(sy), float(pz) + 0.5)
	var p: Node3D = player
	var from := p.position + Vector3(0.0, p.EYE, 0.0)
	var to := Vector3(float(fx) + 0.5, float(sy) + 0.5, float(fz) + 0.5)
	var dir := (to - from).normalized()
	p.look(atan2(-dir.x, -dir.z), asin(clampf(dir.y, -1.0, 1.0)))


func _free_game_nodes() -> void:
	if player != null:
		player.queue_free()
	if inventory_ui != null:
		inventory_ui.queue_free()
	if stats_overlay != null:
		stats_overlay.queue_free()
	if world != null:
		world.queue_free()
	if drops != null:
		drops.queue_free()
	if entities != null:
		entities.queue_free()
	player = null
	inventory_ui = null
	stats_overlay = null
	world = null
	drops = null
	entities = null
	Game.world = null
	Game.player = null
	Game.drops = null
	Game.entities = null
	Game.hotbar = null


class _StubWorld:
	var render_radius := 0
	var fluid_tick_radius := 0
	var band0_r := 0  # AC-0152: settings wiring target
	func recenter(_x: float, _z: float) -> void:
		pass


func _settings_test() -> void:
	if FileAccess.file_exists(Settings.PATH):
		DirAccess.remove_absolute(Settings.PATH)
	Settings.load_settings()
	# AC-0152: Bedrock Realms default is Simulate 4 (was 1 pre-task).
	var defaults_ok := int(Settings.values["render_dist"]) == 50 and int(Settings.values["sim_dist"]) == 4
	Settings.set_value("render_dist", 2)
	var min_ok := int(Settings.values["render_dist"]) == 4
	Settings.set_value("render_dist", 999)
	var max_ok := int(Settings.values["render_dist"]) == 96
	Settings.set_value("sim_dist", 8)
	var sim_set_ok := int(Settings.values["sim_dist"]) == 8
	Settings.set_value("render_dist", 4)
	var sim_lower_ok := int(Settings.values["sim_dist"]) == 4
	Settings.set_value("render_dist", 5)
	Settings.set_value("sim_dist", 9)
	var sim_raise_ok := int(Settings.values["sim_dist"]) == 5
	var cfi := ConfigFile.new()
	cfi.set_value("settings", "render_dist", 10)
	cfi.set_value("settings", "sim_dist", 20)
	cfi.save(Settings.PATH)
	Settings.load_settings()
	var load_clamp_ok := int(Settings.values["render_dist"]) == 10 and int(Settings.values["sim_dist"]) == 10
	var w := _StubWorld.new()
	Game.world = w
	Settings.apply_world()
	var apply_world_ok := w.render_radius == 10 and w.fluid_tick_radius == 160
	Settings.set_value("render_dist", 7)
	Settings.set_value("sim_dist", 3)
	Settings.apply_render_distance()
	Settings.apply_sim_distance()
	var apply_dist_ok := w.render_radius == 7 and w.fluid_tick_radius == 48
	Game.world = null
	Settings.set_value("volume", 37)
	Settings.load_settings()
	var volume_ok := int(Settings.values["volume"]) == 37
	Settings.set_value("hunger_enabled", false)
	var hsaved := -1
	var cf2 := ConfigFile.new()
	if cf2.load(Settings.PATH) == OK:
		hsaved = 1 if bool(cf2.get_value("settings", "hunger_enabled", true)) else 0
	Settings.load_settings()
	var hunger_off_ok := bool(Settings.values["hunger_enabled"]) == false
	Settings.set_value("hunger_enabled", true)
	Settings.load_settings()
	var hunger_on_ok := bool(Settings.values["hunger_enabled"]) == true
	OS.set_environment("AWECRAFT_IGNORE_SETTINGS", "1")
	Settings.load_settings()
	var hunger_default_ok := bool(Settings.values["hunger_enabled"]) == true
	OS.set_environment("AWECRAFT_IGNORE_SETTINGS", "")
	Settings.load_settings()
	Settings.set_value("volume", 100)
	Settings.reset_defaults()
	Debug.result({
		"defaults": {"render": 50, "sim": 1, "ok": defaults_ok},
		"range": {"min": 4, "max": 96, "min_ok": min_ok, "max_ok": max_ok},
		"sim_clamp": {"set_ok": sim_set_ok, "render_lower_8to4": sim_lower_ok, "sim_raise_9at5": sim_raise_ok},
		"load_clamp": {"saved": [10, 20], "after_load": [10, 10], "ok": load_clamp_ok},
		"apply": {"world": [10, 160], "dist": [7, 48], "ok": apply_world_ok and apply_dist_ok},
		"volume_ok": volume_ok,
		"hunger": {"saved_off": hsaved, "reloaded_off": hunger_off_ok, "back_on": hunger_on_ok, "default_true": hunger_default_ok},
		"ok": defaults_ok and min_ok and max_ok and sim_set_ok and sim_lower_ok and sim_raise_ok and load_clamp_ok and apply_world_ok and apply_dist_ok and volume_ok and hsaved == 0 and hunger_off_ok and hunger_on_ok and hunger_default_ok,
	})


func _run_game(seed_env: String, logic: String, cam: String, snapshot_path: String) -> void:
	Game.new_world(44 if seed_env == "" else seed_env.to_int())
	if logic == "settings":
		_settings_test()
		get_tree().quit()
		return
	if _harness_env_set():
		OS.set_environment("AWECRAFT_IGNORE_SETTINGS", "1")
		Settings.load_settings()
		OS.set_environment("AWECRAFT_IGNORE_SETTINGS", "")
	if OS.get_environment("AWECRAFT_DSSTATS") == "1":
		Settings.set_value("debug_stats", true)
	_create_game_nodes()

	if OS.get_environment("AWECRAFT_PROBE") != "":
		var oc := 0
		var omx := 0.0
		var omz := 0.0
		var mh := -1
		var mhx := 0
		var mhz := 0
		for px in range(-192, 193, 8):
			for pz in range(-192, 193, 8):
				var th := WorldGen.terrain_height(px, pz, Game.world_seed)
				if th < Data.SEA:
					oc += 1
					omx += float(px)
					omz += float(pz)
				if th > mh:
					mh = th
					mhx = px
					mhz = pz
		var cenx := omx / float(oc) if oc > 0 else -1.0
		var cenz := omz / float(oc) if oc > 0 else -1.0
		var lmh := -1
		var lmx := 0
		var lmz := 0
		for px in range(-40, 41, 2):
			for pz in range(-40, 41, 2):
				var th := WorldGen.terrain_height(px, pz, Game.world_seed)
				if th > lmh:
					lmh = th
					lmx = px
					lmz = pz
		print("PROBE ocean_cells=", oc, " centroid=", [int(cenx), int(cenz)], " max_h=", mh, " max_at=", [mhx, mhz], " local_max=", [lmh, lmx, lmz])
		if OS.get_environment("AWECRAFT_PROBE") == "biome":
			var mism := 0
			var shown := 0
			var cxm := int(floorf(-160.0 / 16.0))
			var czm := int(floorf(160.0 / 16.0))
			var gen_cache := {}
			for z in range(-160, 161, 4):
				for x in range(-160, 161, 4):
					var bt := WorldGen.biome_at(x, z, Game.world_seed)
					var gxx := int(floorf(float(x) / 16.0))
					var gzz := int(floorf(float(z) / 16.0))
					var gkey := "%d,%d" % [gxx, gzz]
					if not gen_cache.has(gkey):
						gen_cache[gkey] = WorldGen.generate(gxx, gzz, Game.world_seed)
					var g: PackedByteArray = gen_cache[gkey]
					var hgt := 0
					for yy in range(Data.HEIGHT - 1, -1, -1):  # AC-0091: full column (was 75)
						if g[(yy << 8) | ((z & 15) << 4) | (x & 15)] != 0:
							hgt = yy
							break
					var topb: int = g[(hgt << 8) | ((z & 15) << 4) | (x & 15)]
					if topb == 5 or hgt <= Data.SEA:
						continue
					var gb := "none"
					if topb == 12:
						gb = "snow"
					elif topb == 4:
						gb = "desert"
					else:
						continue
					if bt != gb:
						mism += 1
						if shown < 8:
							print("BIMISMATCH x=%d z=%d api=%s gen=%s topb=%d h=%d" % [x, z, bt, gb, topb, hgt])
							shown += 1
			print("BIMISMATCH total=", mism)
			var dbg_pts: Array = []
			for z in range(-160, 161, 4):
				for x in range(-160, 161, 4):
					var bt2 := WorldGen.biome_at(x, z, Game.world_seed)
					var hgt2 := WorldGen.terrain_height(x, z, Game.world_seed)
					# AC-0091: grassland band top remapped 40 -> 152 (= 2.6*40+48).
					if hgt2 <= Data.SEA or hgt2 > 152:
						continue
					var gxx2 := int(floorf(float(x) / 16.0))
					var gzz2 := int(floorf(float(z) / 16.0))
					var g2 = gen_cache.get("%d,%d" % [gxx2, gzz2])
					if g2 == null:
						continue
					var top2 := 0
					for yy in range(Data.HEIGHT - 1, -1, -1):  # AC-0091: full column (was 75)
						if g2[(yy << 8) | ((z & 15) << 4) | (x & 15)] != 0:
							top2 = g2[(yy << 8) | ((z & 15) << 4) | (x & 15)]
							break
					if top2 == 12 and bt2 != "snow":
						dbg_pts.append([x, z])
					elif top2 == 4 and bt2 != "desert":
						dbg_pts.append([x, z])
					if dbg_pts.size() >= 3:
						break
				if dbg_pts.size() >= 3:
					break
			for p in dbg_pts:
				var dx: int = p[0]
				var dz: int = p[1]
				var gxx3 := int(floorf(float(dx) / 16.0))
				var gzz3 := int(floorf(float(dz) / 16.0))
				var at := AweNoise.fbm2(float(dx) / 260.0 + 900.0, float(dz) / 260.0 + 900.0, Game.world_seed + 21, 3)
				var am := AweNoise.fbm2(float(dx) / 260.0 + 1700.0, float(dz) / 260.0 + 1700.0, Game.world_seed + 33, 3)
				var cta := PackedFloat64Array()
				cta.resize(256)
				var cma := PackedFloat64Array()
				cma.resize(256)
				WorldGen._fbm2chunk(gxx3 * 16, 260.0, 900.0, gzz3 * 16, 260.0, 900.0, Game.world_seed + 21, 3, cta)
				WorldGen._fbm2chunk(gxx3 * 16, 260.0, 1700.0, gzz3 * 16, 260.0, 1700.0, Game.world_seed + 33, 3, cma)
				var di := (dz & 15) * 16 + (dx & 15)
				print("FBS x=%d z=%d api=(%f,%f) chunk=(%f,%f)" % [dx, dz, at, am, cta[di], cma[di]])
		if OS.get_environment("AWECRAFT_PROBE") == "map":
			for pz in range(-32, 48, 2):
				var row := ""
				var brow := ""
				for px in range(-32, 48, 2):
					var mh2 := WorldGen.terrain_height(px, pz, Game.world_seed)
					var ch := " "
					if mh2 < Data.SEA:
						ch = "~"
						row += ch
						brow += "."
						continue
					var bm2 := WorldGen.biome_at(px, pz, Game.world_seed)
					var bch := " "
					if bm2 == "plains":
						bch = "p"
					elif bm2 == "forest":
						bch = "f"
					elif bm2 == "snow":
						bch = "s"
					elif bm2 == "desert":
						bch = "d"
					if mh2 <= Data.SEA + 2:
						ch = "."
					elif mh2 < 147:  # AC-0091: 38 -> 147 (= 2.6*38+48)
						ch = "-"
					elif mh2 < 162:  # AC-0091: 44 -> 162 (= 2.6*44+48)
						ch = "+"
					else:
						ch = "#"
					row += ch
					brow += bch
				print("MAP y=%d %s" % [pz, row])
				print("BIO y=%d %s" % [pz, brow])
		if OS.get_environment("AWECRAFT_PROBE") == "scan":
			for s in range(1, 121):
				var slmh := -1
				for spx in range(-48, 49, 4):
					for spz in range(-48, 49, 4):
						var sth := WorldGen.terrain_height(spx, spz, s)
						if sth > slmh:
							slmh = sth
				var sod := 9999
				for spx in range(-96, 97, 8):
					for spz in range(-96, 97, 8):
						if WorldGen.terrain_height(spx, spz, s) < Data.SEA:
							var sd := absi(spx - 8) + absi(spz - 8)
							if sd < sod:
								sod = sd
				print("SEED ", s, " local_max=", slmh, " ocean_dist=", sod)
		if OS.get_environment("AWECRAFT_BCELL") != "":
			for spec in OS.get_environment("AWECRAFT_BCELL").split(";"):
				var p := spec.split(",")
				var bxc := int(p[0])
				var bzc := int(p[1])
				var th3 := WorldGen.terrain_height(bxc, bzc, Game.world_seed)
				var bt3 := WorldGen.biome_at(bxc, bzc, Game.world_seed)
				var top3 := 0
				var ty3 := -1
				for yy in range(Data.HEIGHT - 1, -1, -1):  # AC-0091: full column (was 74)
					top3 = world.get_block(bxc, yy, bzc)
					if top3 != 0:
						ty3 = yy
						break
				print("BCELL x=%d z=%d h=%d biome=%s topb=%d at_y=%d" % [bxc, bzc, th3, bt3, top3, ty3])
		get_tree().quit()
		return

	var spawn: Vector3 = world.spawn_point()

	if logic != "":
		world.fluid_sim_enabled = false
		if logic == "player":
			world.recenter(spawn.x, spawn.z, true)
			await _await_spawn_floor(spawn, 300)
			player = _spawn_player()
			await _player_logic_test()
			return
		if logic == "look":
			world.recenter(spawn.x, spawn.z, true)
			player = _spawn_player()
			await _look_test()
			return
		if logic == "interact":
			world.recenter(spawn.x, spawn.z, true)
			player = _spawn_player()
			await _interact_test()
			return
		if logic == "craft":
			world.recenter(spawn.x, spawn.z, true)
			player = _spawn_player()
			await _craft_test()
			return
		if logic == "guiclick":
			world.recenter(spawn.x, spawn.z, true)
			player = _spawn_player()
			await _guiclick_test()
			return
		if logic == "combat":
			world.recenter(spawn.x, spawn.z, true)
			await _await_spawn_floor(spawn, 300)
			player = _spawn_player()
			await _combat_test(spawn)
			return
		if logic == "swing":
			world.recenter(spawn.x, spawn.z, true)
			await _await_spawn_floor(spawn, 300)
			player = _spawn_player()
			await _swing_test()
			return
		if logic == "survival":
			world.recenter(spawn.x, spawn.z, true)
			await _await_spawn_floor(spawn, 300)
			player = _spawn_player()
			await _survival_test(spawn)
			return
		if logic == "hunger":
			world.recenter(spawn.x, spawn.z, true)
			await _await_spawn_floor(spawn, 300)
			player = _spawn_player()
			await _hunger_toggle_test(spawn)
			return
		if logic == "light":
			world.collision_enabled = false
			world.recenter(float(WorldGen.SPAWN_X), float(WorldGen.SPAWN_Z), false)
			_light_test(spawn)
			get_tree().quit()
			return
		if logic == "lightprobe":
			world.collision_enabled = false
			await _lightprobe_test(spawn)
			get_tree().quit()
			return
		if logic == "pullprobe":
			# AC-0210: the C++ PULL wiring probe (wired entry vs GDScript
			# kernel, both the build_mesh top=-1 form and the top-clamped
			# form; flood p95 before/after).
			world.collision_enabled = false
			await _pullprobe_test(spawn)
			get_tree().quit()
			return
		if logic == "lightcache":
			await _lightcache_test(spawn)
			return
		if logic == "debugstats":
			await _debugstats_test()
			return
		if logic == "basis":
			await _basis_test(spawn)
			get_tree().quit()
			return
		if logic == "sphere":
			await _sphere_test(spawn)
			get_tree().quit()
			return
		if logic == "lightaudit":
			await _lightaudit_test(spawn)
			return
		if logic == "nightday":
			await _nightday_test(spawn)
			return
		if logic == "nightlot":
			await _nightlot_test(spawn)
			return
		if logic == "viewlight":
			player = _spawn_player()
			await _viewlight_test(spawn)
			return
		if logic == "floor":
			await _floor_test(spawn)
			return
		if logic == "leaves":
			await _leaves_test(spawn)
			return
		if logic == "sharpx":
			await _sharpx_test(spawn)
			return
		if logic == "occlude":
			await _occlude_test(spawn)
			return
		if logic == "stars":
			player = _spawn_player()
			_stars_test(spawn)
			return
		if logic == "daynight":
			world.collision_enabled = false
			world.render_radius = 0
			world.recenter(float(WorldGen.SPAWN_X), float(WorldGen.SPAWN_Z), false)
			await _daynight_test()
			return
		if logic == "tint":
			await _tint_test()
			return
		if logic == "fluids":
			world.collision_enabled = false
			world.recenter(float(WorldGen.SPAWN_X), float(WorldGen.SPAWN_Z), false)
			_fluids_test(spawn)
			get_tree().quit()
			return
		if logic == "fluidprobe":
			world.collision_enabled = false
			world.recenter(float(WorldGen.SPAWN_X), float(WorldGen.SPAWN_Z), false)
			_fluidprobe_test()
			get_tree().quit()
			return
		if logic == "fluidfall":
			world.collision_enabled = false
			world.render_radius = 2
			world.recenter(float(WorldGen.SPAWN_X), float(WorldGen.SPAWN_Z), false)
			_fluidfall_test(spawn)
			get_tree().quit()
			return
		if logic == "webfall":
			world.collision_enabled = false
			world.render_radius = 2
			world.recenter(float(WorldGen.SPAWN_X), float(WorldGen.SPAWN_Z), false)
			await _webfall_test(spawn)
			get_tree().quit()
			return
		if logic == "fluidsettle":
			world.collision_enabled = false
			world.recenter(float(WorldGen.SPAWN_X), float(WorldGen.SPAWN_Z), false)
			_fluidsettle_test()
			return
		if logic == "buckets":
			world.collision_enabled = false
			world.recenter(float(WorldGen.SPAWN_X), float(WorldGen.SPAWN_Z), true)
			player = _spawn_player()
			await _buckets_test()
			return
		if logic == "water":
			world.recenter(spawn.x, spawn.z, true)
			player = _spawn_player()
			await _water_test(spawn)
			return
		if logic == "fpv":
			world.recenter(spawn.x, spawn.z, true)
			player = _spawn_player()
			await _fpv_test()
			return
		if logic == "held":
			world.recenter(spawn.x, spawn.z, true)
			player = _spawn_player()
			await _held_test()
			return
		if logic == "toolres":
			world.recenter(spawn.x, spawn.z, true)
			player = _spawn_player()
			await _toolres_test()
			return
		if logic == "toolpose":
			world.recenter(spawn.x, spawn.z, true)
			player = _spawn_player()
			await _toolpose_test()
			return
		if logic == "viewmodel":
			world.recenter(spawn.x, spawn.z, true)
			player = _spawn_player()
			await _await_spawn_floor(spawn, 600)
			await _viewmodel_shot()
			return
		if logic == "wallshot":
			world.recenter(spawn.x, spawn.z, true)
			await _await_spawn_floor(spawn, 300)
			player = _spawn_player()
			await _wallshot_test()
			return
		if logic == "editperf":
			await _editperf_test(spawn)
			return
		if logic == "breakspike":
			await _breakspike_test(spawn)
			return
		if logic == "editslab":
			await _editslab_test(spawn)
			return
		if logic == "perf":
			var t0 := Time.get_ticks_msec()
			var pmem_before: int = OS.get_static_memory_usage()
			world.recenter(spawn.x, spawn.z, true)
			var recenter_ms := Time.get_ticks_msec() - t0
			await _perf_test(spawn, t0, recenter_ms, pmem_before)
			return
		if logic == "boundary":
			world.fluid_sim_enabled = true
			world.tick_time = OS.get_environment("AWECRAFT_TICKTIME") == "1"
			var bt0 := Time.get_ticks_msec()
			world.recenter(spawn.x, spawn.z, true)
			await _await_boundary_core(spawn, 900)
			player = _spawn_player()
			await _boundary_test(spawn, bt0)
			return
		if logic == "spin":
			player = _spawn_player()
			await _spin_test(spawn)
			return
		if logic == "r16":
			await _r16_test(spawn)
			return
		if logic == "atlas":
			world.collision_enabled = false
			world.render_radius = 0
			world.recenter(spawn.x, spawn.z, true)
			await _atlas_test(spawn)
			return
		if logic == "bandmap":
			await _bandmap_test(spawn)
			return
		if logic == "lodband":
			await _lodband_test(spawn)
			return
		if logic == "lodswap":
			await _lodswap_test(spawn)
			return
		if logic == "edgeretain":
			await _edgeretain_test(spawn)
			return
		if logic == "editfront":
			await _editfront_test(spawn)
			return
		if logic == "editmat":
			await _editmat_test(spawn)
			return
		if logic == "editmatshot":
			await _editmat_shot(spawn)
			return
		if logic == "chunkio":
			await _chunkio_test(spawn)
			return
		if logic == "chunkiocpp":
			await _chunkiocpp_test(spawn)
			return
		if logic == "nofallback":
			await _nofallback_test(spawn)
			return
		if logic == "genprobe":
			await _genprobe_test()
			return
		if logic == "meshprobe":
			world.collision_enabled = false
			await _meshprobe_test(spawn)
			get_tree().quit()
			return
		if logic == "stripsprobe":
			world.collision_enabled = false
			await _stripsprobe_test(spawn)
			get_tree().quit()
			return
		if logic == "tick":
			await _tick_test(spawn)
			return
		if logic == "load":
			await _load_test(spawn)
			return
		if logic == "genhash":
			_genhash_print(seed_env)
			get_tree().quit()
			return
		if logic == "colbytes":
			await _colbytes_test(seed_env)
			return
		if logic == "slabwrite":
			_slabwrite_test()
			get_tree().quit()
			return
		if logic == "trees":
			await _trees_test()
			return
		if logic == "save":
			await _save_test()
			return
		if logic == "continue":
			await _continue_probe()
			return
		if logic == "dropshot":
			world.recenter(spawn.x, spawn.z, true)
			await _await_spawn_floor(spawn, 300)
			player = _spawn_player()
			await _dropshot_test(spawn, snapshot_path)
			return
		if logic == "crossshot":
			world.recenter(spawn.x, spawn.z, true)
			await _await_spawn_floor(spawn, 300)
			await _crossshot_test(spawn, snapshot_path)
			return
		if logic == "quitmenu":
			Save.clear(0)
			Save.clear(1)
			Save.clear(2)
			_make_menu()
			var qslot := Save.first_empty_slot()
			Save.active_slot = qslot
			world.recenter(spawn.x, spawn.z, true)
			await _await_spawn_floor(spawn, 300)
			player = _spawn_player()
			Game.start()
			await _quitmenu_test(qslot, spawn)
			return
		world.collision_enabled = false
		world.recenter(float(WorldGen.SPAWN_X), float(WorldGen.SPAWN_Z), true)
		if OS.get_environment("AWECRAFT_MESH_INFO") != "":
			for e in world.mesh_info():
				print("MINFO ", JSON.stringify(e))
		Debug.result(_logic_check())
		get_tree().quit()
		return

	world.recenter(spawn.x, spawn.z, true)
	var only_env := OS.get_environment("AWECRAFT_ONLY")
	if only_env != "":
		var only_set := {}
		for k in only_env.split(";"):
			only_set[k] = true
		for key in world.chunks:
			var cc = world.chunks[key]
			if not only_set.has(key):
				for s in cc.slabs:
					if s.mesh_instance != null:
						s.mesh_instance.visible = false
					if s.fluid_instance != null:
						s.fluid_instance.visible = false
	if OS.get_environment("AWECRAFT_DBG") != "":
		for dx in range(-2, 3):
			for dz in range(-2, 3):
				var k = "%d,%d" % [dx, dz]
				var c = world.chunks.get(k)
				if c == null:
					print("DBGCHUNK ", k, " MISSING")
					continue
				for si in c.slabs.size():
					var s = c.slabs[si]
					var has_mi = s.mesh_instance != null
					var sc := -1
					if s.mesh_instance and s.mesh_instance.mesh:
						sc = s.mesh_instance.mesh.get_surface_count()
					var ab = ""
					if s.mesh_instance and s.mesh_instance.mesh:
						var aabb = s.mesh_instance.mesh.get_aabb()
						ab = "%s/%s" % [aabb.position, aabb.size]
					print("DBGCHUNK ", k, " slab=", si, " built=", c.mesh_built, " mi=", has_mi, " surf=", sc, " pos=", [int(c.position.x), int(c.position.z)], " aabb=", ab)

	if cam == "top":
		camera = _make_camera()
		camera.position = Vector3(spawn.x, spawn.y + 105.0, spawn.z + 0.5)
		camera.look_at(Vector3(spawn.x, 0.0, spawn.z), Vector3(0, 0, 1))
		camera.current = true
	elif cam == "iso":
		camera = _make_camera()
		camera.position = Vector3(spawn.x + 55.0, spawn.y + 75.0, spawn.z - 55.0)
		camera.look_at(Vector3(7.5, 28.0, 7.5), Vector3(0, 1, 0))
		camera.current = true
	elif cam == "iso2":
		camera = _make_camera()
		camera.position = Vector3(spawn.x + 18.0, spawn.y + 26.0, spawn.z - 18.0)
		camera.look_at(Vector3(spawn.x - 4.0, spawn.y - 6.0, spawn.z + 4.0), Vector3(0, 1, 0))
		camera.current = true
	elif cam == "lodring":
		camera = _make_camera()
		camera.position = Vector3(200.0, spawn.y + 124.0, -140.0)
		camera.look_at(Vector3(200.0, spawn.y + 2.0, 8.0), Vector3(0, 1, 0))
		camera.current = true
	elif cam == "sky":
		camera = _make_camera()
		camera.position = Vector3(spawn.x, spawn.y + 6.0, spawn.z)
		var ssun := AeroLib.sky_uniforms(Game.time_of_day)["sun_dir"] as Vector3
		ssun = Vector3(ssun.x, clampf(ssun.y, 0.06, 1.0), ssun.z).normalized()
		camera.look_at(camera.position + ssun, Vector3.UP)
		camera.current = true
	elif cam == "eyeup":
		camera = _make_camera()
		camera.position = Vector3(spawn.x, spawn.y + 1.62, spawn.z)
		var body := AeroLib.sky_uniforms(Game.time_of_day)["sun_dir"] as Vector3
		var eyaw := atan2(-body.x, -body.z)
		var epitch := clampf(asin(clampf(body.y, -1.0, 1.0)) * 0.5, -0.9, 0.7)
		var edir := Vector3(-cos(epitch) * sin(eyaw), sin(epitch), -cos(epitch) * cos(eyaw)).normalized()
		camera.look_at(camera.position + edir, Vector3.UP)
		camera.current = true
	elif cam == "sandpad":
		var pad_top := _build_sand_pad(spawn)
		camera = _make_camera()
		camera.position = Vector3(spawn.x + 7.5, pad_top + 2.1, spawn.z + 7.5)
		camera.look_at(Vector3(spawn.x, pad_top + 0.3, spawn.z), Vector3(0, 1, 0))
		camera.current = true
	elif cam == "shaft":
		var rfx := int(spawn.x) + 2
		var rfz := int(spawn.z) + 2
		var rsy: int = _fluidfall_build(rfx, rfz)
		camera = _make_camera()
		camera.position = Vector3(float(rfx) + 15.0, float(rsy) + 19.0, float(rfz) + 15.0)
		camera.look_at(Vector3(float(rfx) + 0.5, float(rsy) + 2.0, float(rfz) + 0.5), Vector3(0, 1, 0))
		camera.current = true
		await _await_world_build(Vector3(float(rfx), float(rsy), float(rfz)), 3000)
		for i in 12:
			await get_tree().physics_frame
		Debug.set_fluid(rfx, rsy + 8, rfz, 5, 8)
		for i in 50:
			await get_tree().physics_frame
		await Debug.snap(snapshot_path)
		var floor_last := -1
		var floor_quiet := 0
		for i in range(3000):
			await get_tree().physics_frame
			var sc: Array = _fluidfall_scan(rfx, rfz, rsy)
			var scells: Dictionary = sc[1]
			var fc := 0
			for k in scells:
				if int(str(k).split(",")[1]) == rsy:
					fc += 1
			if fc == 0:
				floor_quiet = 0
				continue
			if fc == floor_last:
				floor_quiet += 1
			else:
				floor_quiet = 0
				floor_last = fc
			if floor_quiet >= 24:
				break
		for i in 12:
			await get_tree().physics_frame
		var snap2 := OS.get_environment("AWECRAFT_SNAPSHOT2")
		if snap2 == "":
			snap2 = snapshot_path
		await Debug.snap(snap2)
		Debug.result({"shaft": true, "fx": rfx, "fz": rfz, "sy": rsy, "mid": snapshot_path, "settled": snap2})
		get_tree().quit()
		return
	elif OS.get_environment("AWECRAFT_ANIM_SHOT") == "1":
		var wc = _find_water_cell(spawn)
		if wc.has("cell"):
			var wci: Vector3i = wc["cell"]
			camera = _make_camera()
			camera.position = Vector3(float(wci.x) + 0.5, float(wci.y) + 13.0, float(wci.z) + 0.5)
			camera.look_at(Vector3(float(wci.x) + 0.5, float(wci.y), float(wci.z) + 0.5), Vector3(0, 0, 1))
			camera.current = true
		else:
			print("ANIM_SHOT no water cell near spawn")
	else:
		await _await_spawn_floor(spawn, 300)
		player = _spawn_player()
		Game.start()

	if snapshot_path != "" and player == null:
		# AC-0035: named-camera snapshot paths (top/iso/eyeup/...) skip the
		# spawn above; G6-style shots need the player in-frame (viewmodel hand
		# + player-light halo) so spawn on demand.
		await _await_spawn_floor(spawn, 300)
		player = _spawn_player()
		Game.start()

	if snapshot_path != "":
		await _snapshot_finish(cam)


func _snapshot_finish(cam: String) -> void:
	var snapshot_path := OS.get_environment("AWECRAFT_SNAPSHOT")
	var spawn: Vector3 = world.spawn_point()
	var fluid_shot := OS.get_environment("AWECRAFT_FLUID_SHOT") == "1"
	if cam == "cave":
		await _cave_snapshot_finish(cam, snapshot_path, spawn)
		return
	var held_env := OS.get_environment("AWECRAFT_HELD")
	if held_env != "" and player != null:
		var hid: int = held_env.to_int()
		if _count_item(player, hid) <= 0:
			Debug.give_item(hid, 1)
		player.sel = _slot_of(player, hid)
		var aim := _find_aim_spot()
		if not aim.is_empty():
			Debug.fly(true)
			Debug.teleport(aim["cam"].x, aim["cam"].y - player.EYE, aim["cam"].z)
			player.look(aim["yaw"], aim["pitch"])
		await _await_world_build(player.position, 3000)
		for i in 10:
			await get_tree().physics_frame
		await Debug.snap(snapshot_path)
		Debug.result({"held": hid, "w": int(get_viewport().size.x), "h": int(get_viewport().size.y), "cam": cam})
		get_tree().quit()
		return
	var aimed := false
	if player != null:
		if fluid_shot:
			Debug.fly(true)
			Debug.give_item(140, 1)
			Debug.give_item(139, 1)
			player.sel = _slot_of(player, 140)
			var aim := _find_shore_aim()
			if not aim.is_empty():
				Debug.teleport(aim["cam"].x, aim["cam"].y - player.EYE, aim["cam"].z)
				player.look(aim["yaw"], aim["pitch"])
				aimed = true
		else:
			# AC-0035: deterministic snapshot camera override
			# (x,y,z,yaw,pitch; x/y/z at EYE height). The raycast aim below
			# depends on chunk-build timing (SNAPDRAIN), which shifts the
			# frame between runs; a fixed cam makes G6 shots reproducible.
			var aimenv := OS.get_environment("AWECRAFT_AIM")
			if aimenv != "":
				var p := aimenv.split(",")
				if p.size() == 5:
					Debug.fly(true)
					Debug.give_item(3, 12)
					Debug.give_item(111, 1)
					Debug.teleport(float(p[0]), float(p[1]) - player.EYE, float(p[2]))
					player.look(float(p[3]), float(p[4]))
					aimed = true
			var aim := _find_aim_spot()
			if not aimed and not aim.is_empty():
				Debug.fly(true)
				Debug.give_item(3, 12)
				Debug.give_item(111, 1)
				if int(aim["id"]) != 2 and int(aim["id"]) != 3:
					Debug.give_item(int(aim["id"]), 3)
				var fpv_env := OS.get_environment("AWECRAFT_FPV_ITEM")
				if fpv_env != "":
					var fpid: int = fpv_env.to_int()
					if _count_item(player, fpid) <= 0:
						Debug.give_item(fpid, 1)
					player.sel = _slot_of(player, fpid)
				Debug.teleport(aim["cam"].x, aim["cam"].y - player.EYE, aim["cam"].z)
				# AC-0035: the eyeup night shot must show sky (stars) + ground
				# (player-light halo) + viewmodel in one frame. The held item
				# sits ~17 deg below the horizon and ~24 deg off-axis, so a
				# slight UP pitch (~8.6 deg) keeps it in-frame while leaving
				# ~38% sky on top for the stars.
				var epitch: float = aim["pitch"]
				if cam == "eyeup":
					epitch = 0.15
				player.look(aim["yaw"], epitch)
				aimed = true
	var inv_env := OS.get_environment("AWECRAFT_INV")
	if inv_env != "" and player != null:
		for i in player.inv.size():
			player.inv[i] = {"id": 0, "n": 0}
		if inv_env == "1":
			Debug.give_item(6, 5)
			Debug.give_item(8, 12)
			Debug.give_item(100, 6)
			Debug.give_item(111, 1)
			Debug.give_item(127, 1)
			player.inv_slot_click(player.find_slot(127), "hotbar", 0, false)
			player.armor_slot_click(0, 0, false)
			Debug.give_item(132, 1)
			player.inv_slot_click(player.find_slot(132), "hotbar", 0, false)
			player.armor_slot_click(1, 0, false)
			for i in range(13, 36):
				player.inv[i] = {"id": 140 + (i % 8), "n": (i % 7) + 1}
		elif inv_env == "table":
			Debug.give_item(8, 12)
			Debug.give_item(100, 8)
			Debug.give_item(105, 8)
			for i in range(13, 36):
				player.inv[i] = {"id": 105, "n": (i % 8) + 1}
			player.table_grid[0] = {"id": 8, "n": 1}
			player.table_grid[1] = {"id": 8, "n": 1}
			player.table_grid[2] = {"id": 8, "n": 1}
			player.table_grid[4] = {"id": 100, "n": 1}
			player.table_grid[7] = {"id": 100, "n": 1}
		player.open_inventory("table" if inv_env == "table" else "inv")
		if inv_env == "1":
			inventory_ui.autofill_first()
			inventory_ui.hover_item(111)
			player.held = {"id": 111, "n": 1}
			var mid: Vector2 = get_viewport().get_visible_rect().size * 0.5
			var mmv := InputEventMouseMotion.new()
			mmv.position = mid - Vector2(120, 60)
			mmv.global_position = mid - Vector2(120, 60)
			Input.parse_input_event(mmv)
	var drain_at := spawn
	if player != null:
		drain_at = player.position
	# AC-0135: AWECRAFT_AIM teleports can force a cold recenter of the R band;
	# under llvmpipe that outbuilds the fixed 3000-frame drain (SNAPDRAIN).
	# Env override (default 3000 = existing behavior, gates untouched) lets a
	# far teleport settle before the snapshot.
	var drain_max := 3000
	var drain_env := OS.get_environment("AWECRAFT_SNAP_DRAIN")
	var aim_pose := Vector3.ZERO
	var aim_pose_on := false
	if drain_env != "":
		drain_max = max(1, drain_env.to_int())
		if player != null and aimed:
			# AC-0135: while the band builds around a far aim target, collision
			# de-penetration against the freshly built chunks can shove the
			# aim player out of its pocket. Re-pin the aim pose every 300
			# frames while the drain runs (fire-and-forget companion) and once
			# more right after it.
			aim_pose = player.position
			aim_pose_on = true
			_aim_pose_guard(aim_pose, player._yaw, player._pitch, drain_max)
	await _await_world_build(drain_at, drain_max)
	if aim_pose_on and player != null:
		player.position = aim_pose
		player.look(player._yaw, player._pitch)
	for i in 8:
		await get_tree().physics_frame
	# AC-0135: a long AWECRAFT_SNAP_DRAIN drifts the clock — _update_sky
	# advances Game.time_of_day in real time (main.gd:1553). Re-pin the
	# requested AWECRAFT_TIME right before the snapshot. Gated on the drain
	# override being set so default runs keep their exact prior behavior.
	if drain_env != "":
		var stime_env := OS.get_environment("AWECRAFT_TIME")
		if stime_env != "":
			Game.time_of_day = fmod(stime_env.to_float(), 1.0)
			_update_sky()

	if OS.get_environment("AWECRAFT_WALK_SHOT") == "1" and player != null:
		await _walk_shot_finish(snapshot_path, spawn)
		return
	var emptyhand_env := OS.get_environment("AWECRAFT_EMPTYHAND")
	if emptyhand_env == "1" and player != null:
		for i in player.inv.size():
			player.inv[i] = {"id": 0, "n": 0}
		player.sel = 0
	var swing_env := OS.get_environment("AWECRAFT_SWING")
	if swing_env != "" and player != null:
		player.hold_swing(swing_env.to_float())
		for i in 3:
			await get_tree().physics_frame
	var hp_env := OS.get_environment("AWECRAFT_HP")
	if hp_env != "" and player != null:
		player.hp = clampf(hp_env.to_float(), 0.0, 20.0)
	var hunger_env := OS.get_environment("AWECRAFT_HUNGER")
	if hunger_env != "" and player != null:
		player.hunger = clampf(hunger_env.to_float(), 0.0, 20.0)
	if not (fluid_shot and aimed):
		await Debug.snap(snapshot_path)
	if aimed:
		if fluid_shot:
			player.use_selected()
			for i in 60:
				await get_tree().physics_frame
			await Debug.snap(snapshot_path)
		else:
			player.place()
			for i in 4:
				await get_tree().physics_frame
			await Debug.snap(snapshot_path.replace(".png", "_placed.png"))
	var opts_snap := OS.get_environment("AWECRAFT_OPTS_SNAP")
	if opts_snap != "":
		if menu_ui == null:
			_make_menu()
		menu_ui.show_main()
		menu_ui.open_options("main")
		for i in 10:
			await get_tree().process_frame
		await Debug.snap(opts_snap)
	Debug.result({"m4": "ok", "w": int(get_viewport().size.x), "h": int(get_viewport().size.y), "cam": cam})
	get_tree().quit()


func _walk_shot_finish(path: String, spawn: Vector3) -> void:
	var p = Game.player
	var pad_top := _build_walk_pad(spawn, 10)
	Debug.teleport(8.5, pad_top, 8.5)
	for i in 40:
		await get_tree().physics_frame
	var wid_env := OS.get_environment("AWECRAFT_FPV_ITEM")
	if wid_env != "":
		var wid: int = wid_env.to_int()
		if _count_item(p, wid) <= 0:
			Debug.give_item(wid, 1)
		p.sel = _slot_of(p, wid)
	for i in 6:
		await get_tree().physics_frame
	Input.action_press("move_forward")
	await get_tree().physics_frame
	for i in 300:
		if p.hand_pose_offset().y > 0.008:
			break
		await get_tree().physics_frame
	await get_tree().physics_frame
	await Debug.snap(path)
	for i in 8:
		await get_tree().physics_frame
	await Debug.snap(path.replace(".png", "_w2.png"))
	Input.action_release("move_forward")
	Debug.result({"m4": "ok", "walk_shot": true, "w": int(get_viewport().size.x), "h": int(get_viewport().size.y)})
	get_tree().quit()


func _spawn_player() -> Node3D:
	var p := PlayerRes.instantiate()
	p.name = "Player"
	add_child(p)
	return p


func _make_camera() -> Camera3D:
	var c := Camera3D.new()
	c.fov = 75.0
	add_child(c)
	return c


func _build_sand_pad(spawn: Vector3) -> float:
	var sx := int(spawn.x)
	var sz := int(spawn.z)
	var top := -1
	for dx in range(-6, 6):
		for dz in range(-6, 6):
			var h := WorldGen.terrain_height(sx + dx, sz + dz, Game.world_seed)
			top = maxi(top, h)
	for dx in range(-6, 6):
		for dz in range(-6, 6):
			var x := sx + dx
			var z := sz + dz
			var h := WorldGen.terrain_height(x, z, Game.world_seed)
			for y in range(h + 1, h + 14):
				world.set_block(x, y, z, 0)
			for y in range(h + 1, top + 3):
				world.set_block(x, y, z, 4)
	return float(top) + 3.0


func _build_walk_pad(sp: Vector3, radius: int) -> float:
	var stx := int(sp.x)
	var stz := int(sp.z)
	var top := -1
	for dx in range(-radius, radius + 1):
		for dz in range(-radius, radius + 1):
			var h := WorldGen.terrain_height(stx + dx, stz + dz, Game.world_seed)
			top = maxi(top, h)
	var touched := {}
	for dx in range(-radius, radius + 1):
		for dz in range(-radius, radius + 1):
			var x := stx + dx
			var z := stz + dz
			var h := WorldGen.terrain_height(x, z, Game.world_seed)
			for y in range(h + 1, h + 14):
				world.set_block(x, y, z, 0)
			for y in range(h + 1, top + 3):
				world.set_block(x, y, z, 4)
			touched[world._key(int(floorf(float(x) / 16.0)), int(floorf(float(z) / 16.0)))] = true
	world.light_dirty.clear()
	world.light_pending.clear()
	world.light_pending_set.clear()
	world.fluid_dirty.clear()
	for key in touched:
		var c = world.chunks.get(key)
		if c != null and c.mesh_built:
			c.build_mesh(world.get_block, {})
	return float(top) + 3.0


func _setup_aero() -> void:
	if AeroLib.grade_on():
		AeroLib.apply_grade(env)
	if AeroLib.sky_on():
		var sm := ShaderMaterial.new()
		sm.shader = load("res://core/aero_sky.gdshader")
		sm.set_shader_parameter("cam_pos", Vector3.ZERO)
		aero_sky_mat = sm
		var sph := SphereMesh.new()
		sph.radius = AeroLib.SKY_RADIUS
		sph.height = AeroLib.SKY_RADIUS * 2.0
		sph.rings = 24
		sph.flip_faces = true
		aero_sky = MeshInstance3D.new()
		aero_sky.name = "AeroSky"
		aero_sky.mesh = sph
		aero_sky.material_override = sm
		add_child(aero_sky)
	if AeroLib.wash_on():
		aero_wash_mesh = QuadMesh.new()
		var wm := ShaderMaterial.new()
		wm.shader = load("res://core/aero_wash.gdshader")
		wm.set_shader_parameter("wash_color", AeroLib.WASH_COLOR)
		wm.set_shader_parameter("wash_amount", AeroLib.WASH_AMOUNT)
		wm.set_shader_parameter("top_glow", AeroLib.WASH_TOP_GLOW)
		aero_wash = MeshInstance3D.new()
		aero_wash.name = "AeroWash"
		aero_wash.mesh = aero_wash_mesh
		aero_wash.material_override = wm
		aero_wash.visible = false
		add_child(aero_wash)


func _aero_camera() -> Camera3D:
	if camera != null and camera.is_inside_tree():
		return camera
	if player != null:
		var pc := player.get_node_or_null("Camera3D")
		if pc != null:
			return pc
	return null


var _last_mode := ""


func _process(delta: float) -> void:
	Game.time_of_day = fmod(Game.time_of_day + minf(delta, 0.05) / DayNight.DAY_LEN, 1.0)
	if stats_overlay != null:
		_stats_acc += delta
		if _stats_acc >= 0.25:
			_stats_acc = 0.0
			_refresh_stats()
	_update_sky()
	if aero and aero_sky != null:
		var ac := _aero_camera()
		if ac != null:
			aero_sky.global_position = ac.global_position
			aero_sky_mat.set_shader_parameter("cam_pos", ac.global_position)
			if aero_wash != null:
				aero_wash.visible = true
				var gt := ac.global_transform
				aero_wash.global_position = gt.origin + gt.basis * Vector3(0.0, 0.0, -0.12)
				aero_wash.global_basis = gt.basis
				var vw := get_viewport().get_visible_rect().size
				var aspect := maxf(vw.x / maxf(vw.y, 1.0), 0.1)
				var half_h := tan(float((ac as Camera3D).fov) * PI / 360.0) * 0.12
				var sz := Vector2(2.0 * half_h * aspect, 2.0 * half_h)
				if aero_wash_mesh.size != sz:
					aero_wash_mesh.size = sz
	if world != null and Game.mode == "play":
		_update_fog()
	if _last_mode != Game.mode:
		var from := _last_mode
		_last_mode = Game.mode
		if menu_ui != null:
			if Game.mode == "pause" and from == "play":
				menu_ui.show_pause()
			elif Game.mode == "play" and from == "pause":
				menu_ui.hide_pause()


func _refresh_stats() -> void:
	if stats_overlay == null:
		return
	var label = stats_overlay.get_node_or_null("StatsLabel")
	if label == null:
		return
	stats_overlay.visible = bool(Settings.values["debug_stats"])
	var now := Time.get_ticks_msec()
	var proc_s := float(Performance.get_monitor(Performance.TIME_PROCESS))
	var cpu_pct := -1.0
	if _stats_prev_t >= 0 and now > _stats_prev_t:
		cpu_pct = maxf((proc_s - _stats_prev_proc) / float(now - _stats_prev_t) * 100.0, 0.0)
	(label as Label).text = _stats_text(cpu_pct)
	_stats_prev_t = now
	_stats_prev_proc = proc_s


func _stats_text(cpu_pct: float) -> String:
	var fps := int(Performance.get_monitor(Performance.TIME_FPS))
	var cpu := "%.1f%%" % cpu_pct if cpu_pct >= 0.0 else "n/a"
	var mem := OS.get_memory_info()
	var total := float(mem.get("physical", -1))
	var free := float(mem.get("free", -1))
	var proc_mb := float(OS.get_static_memory_usage()) / 1048576.0
	var sys := "n/a"
	if total > 0.0 and free >= 0.0:
		var used := total - free
		sys = "%.0f/%.0f MB (%.0f%%)" % [used / 1048576.0, total / 1048576.0, used / total * 100.0]
	var vram_mb := float(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)) / 1048576.0
	return "FPS: %d  CPU proc: %s (of 1 core)\nRAM: proc %.1f MB (engine static)  sys %s\nVRAM: %.0f MB (render)" % [fps, cpu, proc_mb, sys, vram_mb]


func _stats_settle(ms: int) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < ms:
		await get_tree().process_frame


func _debugstats_test() -> void:
	var save_phase := OS.get_environment("AWECRAFT_DSSTATS_SAVE") == "1"
	var persisted := false
	if not save_phase:
		Settings.load_settings()
		persisted = bool(Settings.values["debug_stats"])
	var vis_on := false
	var vis_off := false
	var text_ok := false
	var sample := ""
	var cfg_saved := false
	if save_phase:
		Settings.set_value("debug_stats", true)
		var cf := ConfigFile.new()
		cfg_saved = cf.load(Settings.PATH) == OK and bool(cf.get_value("settings", "debug_stats", false))
	else:
		Settings.set_value("debug_stats", true)
		_refresh_stats()
		await _stats_settle(400)
		vis_on = stats_overlay != null and stats_overlay.visible
		var label = stats_overlay.get_node_or_null("StatsLabel") if stats_overlay != null else null
		if label != null:
			var t := String((label as Label).text).to_lower()
			text_ok = t.contains("fps") and t.contains("cpu") and t.contains("ram") and t.contains("vram")
			sample = String((label as Label).text).replace("\n", " | ")
		Settings.set_value("debug_stats", false)
		_refresh_stats()
		await _stats_settle(400)
		vis_off = stats_overlay != null and not stats_overlay.visible
	var ok_final := cfg_saved if save_phase else (persisted and vis_on and text_ok and vis_off)
	Debug.result({
		"phase": "save" if save_phase else "probe",
		"ok": ok_final,
		"persisted_after_restart": persisted,
		"visible_when_on": vis_on,
		"visible_when_off": vis_off,
		"text_has_fields": text_ok,
		"cfg_saved": cfg_saved,
		"stats_sample": sample,
	})
	get_tree().quit()


func _update_sky() -> void:
	if sun == null:
		return
	var t := Game.time_of_day
	# AC-0128: per-frame u_day uniform for the unlit chunk shaders (web parity:
	# DayNight.day(t), the web day factor, updated every frame at index.html
	# :3222).
	var day := DayNight.day(t)
	_ChunkScriptM.set_day_factor(day)
	if _star_node != null:
		var scam: Camera3D = null
		if player != null:
			scam = player.get_node_or_null("Camera3D")
		if scam != null:
			# AC-0133 fix (web parity, index.html :3248): position copy ONLY —
			# the field's rotation is never set, so it stays fixed in world
			# orientation (fixed to the sky, not to the screen).
			_star_node.global_position = scam.global_position
			_star_node.visible = true
		else:
			_star_node.visible = false
	if _star_mat != null:
		_star_mat.set_shader_parameter("u_opacity", 1.0 - day)

	var ppos := Vector3.ZERO
	var plvl := 0.0
	var prad := 5.0
	if player != null:
		ppos = player.position
		plvl = float(player.PLAYER_LIGHT_LEVEL)
		prad = float(player.PLAYER_LIGHT_RADIUS)
	for k in _ChunkScriptM._mat_cache:
		var cm = _ChunkScriptM._mat_cache[k]
		if cm is ShaderMaterial:
			cm.set_shader_parameter("u_player_pos", ppos)
			cm.set_shader_parameter("u_player_light", plvl)
			cm.set_shader_parameter("u_player_radius", prad)
	sun.light_color = AeroLib.SUN_TINT if aero else Color.WHITE
	sun.light_energy = DayNight.sun_energy(t) * (AeroLib.SUN_BOOST if aero else 1.0)
	sun.look_at(DayNight.sun_direction(t), Vector3.UP)
	var sky := DayNight.sky_display(t)
	env.background_color = sky
	env.ambient_light_color = AeroLib.AMBIENT_TINT if aero else Color.WHITE
	env.ambient_light_energy = DayNight.ambient_energy(t) * (AeroLib.AMBIENT_BOOST if aero else 1.0)
	env.fog_light_color = sky
	if aero and aero_sky_mat != null:
		var u := AeroLib.sky_uniforms(t)
		for k in u.keys():
			aero_sky_mat.set_shader_parameter(k, u[k])


func _update_fog() -> void:
	var rr: int = world.render_radius
	env.fog_depth_begin = DayNight.fog_near(rr)
	env.fog_depth_end = DayNight.fog_far(rr)


func _daynight_test() -> void:
	Game.time_of_day = 0.25
	_update_sky()
	var r25 := _sky_readout(0.25, false)
	var t0 := Time.get_ticks_msec()
	var td0 := Game.time_of_day
	while Time.get_ticks_msec() - t0 < 5000:
		await get_tree().process_frame
	var elapsed_ms := Time.get_ticks_msec() - t0
	var actual := Game.time_of_day - td0
	if actual < -0.5:
		actual += 1.0
	var expected := elapsed_ms / 1000.0 / DayNight.DAY_LEN
	var delta_ok := expected > 0.0 and absf(actual - expected) <= expected * 0.02
	var r75 := _sky_readout(0.75, true)
	var col := DayNight.sky_display(0.5)
	Debug.result({
		"time_025": r25,
		"time_075": r75,
		"cycle_elapsed_ms": elapsed_ms,
		"cycle_expected": roundf(expected * 1000000.0) / 1000000.0,
		"cycle_actual": roundf(actual * 1000000.0) / 1000000.0,
		"cycle_delta_ok": delta_ok,
		"colcheck": [roundf(col.r * 10000.0) / 10000.0, roundf(col.g * 10000.0) / 10000.0, roundf(col.b * 10000.0) / 10000.0],
		"ok": delta_ok,
	})
	get_tree().quit()


func _sky_readout(t: float, apply: bool) -> Dictionary:
	if apply:
		Game.time_of_day = t
		_update_sky()
	var d := DayNight.sun_direction(t)
	var r := sun.rotation_degrees
	return {
		"t": t,
		"night": DayNight.is_night(t),
		"sun_dir": [roundf(d.x * 10000.0) / 10000.0, roundf(d.y * 10000.0) / 10000.0, roundf(d.z * 10000.0) / 10000.0],
		"sun_rot": [roundf(r.x * 100.0) / 100.0, roundf(r.y * 100.0) / 100.0, roundf(r.z * 100.0) / 100.0],
		"energy": roundf(sun.light_energy * 10000.0) / 10000.0,
		"ambient": roundf(env.ambient_light_energy * 10000.0) / 10000.0,
		"sky": [roundf(env.background_color.r * 10000.0) / 10000.0, roundf(env.background_color.g * 10000.0) / 10000.0, roundf(env.background_color.b * 10000.0) / 10000.0],
		"fog": [roundf(env.fog_light_color.r * 10000.0) / 10000.0, roundf(env.fog_light_color.g * 10000.0) / 10000.0, roundf(env.fog_light_color.b * 10000.0) / 10000.0],
	}


func _player_logic_test() -> void:
	await _player_logic_test_body()
	get_tree().quit()


func _player_logic_test_body() -> void:
	var p = Game.player
	for i in 10:
		await get_tree().physics_frame
	var start: Vector3 = p.position
	Input.action_press("move_forward")
	for i in 40:
		await get_tree().physics_frame
	Input.action_release("move_forward")
	for i in 8:
		await get_tree().physics_frame
	var after_fwd := Vector2(p.position.x, p.position.z)
	var horizontal_moved := after_fwd.distance_to(Vector2(start.x, start.z))
	for i in 60:
		if p.is_on_floor():
			break
		await get_tree().physics_frame
	var on_floor: bool = p.is_on_floor()
	var peak: float = p.position.y
	Input.action_press("jump")
	for i in 240:
		await get_tree().physics_frame
		if p.position.y > peak:
			peak = p.position.y
		if i > 10 and p.is_on_floor() and p.velocity.y <= 0.0:
			break
	Input.action_release("jump")
	for i in 8:
		await get_tree().physics_frame
	Debug.fly(true)
	Input.action_press("jump")
	for i in 40:
		await get_tree().physics_frame
	Input.action_release("jump")
	var after_fly_y: float = p.position.y
	Debug.fly(false)
	var time_before := Game.time_of_day
	Input.action_press("time")
	await get_tree().physics_frame
	Input.action_release("time")
	for i in 3:
		await get_tree().physics_frame
	var time_after := Game.time_of_day
	Debug.result({
		"start": [roundf(start.x * 100.0) / 100.0, roundf(start.y * 100.0) / 100.0, roundf(start.z * 100.0) / 100.0],
		"after_fwd": [roundf(after_fwd.x * 100.0) / 100.0, roundf(after_fwd.y * 100.0) / 100.0],
		"horizontal_moved": roundf(horizontal_moved * 100.0) / 100.0,
		"is_on_floor": on_floor,
		"jump_peak_y": roundf(peak * 100.0) / 100.0,
		"after_fly_y": roundf(after_fly_y * 100.0) / 100.0,
		"time_before": time_before,
		"time_after": time_after,
	})


func _look_test() -> void:
	var p = Game.player
	for i in 5:
		await get_tree().physics_frame
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var yaw0: float = p.get_yaw()
	var pitch0: float = p.get_pitch()
	var mb := InputEventMouseButton.new()
	mb.button_index = MOUSE_BUTTON_LEFT
	mb.pressed = true
	Input.parse_input_event(mb)
	var dragging := false
	var mined_during := false
	for i in 12:
		await get_tree().physics_frame
		if p.is_mining():
			mined_during = true
		if p.is_dragging():
			dragging = true
			break
	var mm := InputEventMouseMotion.new()
	mm.relative = Vector2(300.0, 120.0)
	Input.parse_input_event(mm)
	for i in 12:
		await get_tree().physics_frame
		if p.is_mining():
			mined_during = true
		if p.get_yaw() != yaw0 or p.get_pitch() != pitch0:
			break
	var mb2 := InputEventMouseButton.new()
	mb2.button_index = MOUSE_BUTTON_LEFT
	mb2.pressed = false
	Input.parse_input_event(mb2)
	for i in 12:
		await get_tree().physics_frame
		if p.is_mining():
			mined_during = true
		if not p.is_dragging():
			break
	var yaw_a: float = p.get_yaw()
	var pitch_a: float = p.get_pitch()
	var drag_mined: bool = mined_during or p.is_mining()
	var after_drag_not_dragging: bool = not p.is_dragging()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	var mm2 := InputEventMouseMotion.new()
	mm2.relative = Vector2(100.0, 0.0)
	p.apply_look(mm2)
	var yaw_b: float = p.get_yaw()
	var pitch_b: float = p.get_pitch()
	var drag_yaw_delta: float = yaw_a - yaw0
	var drag_pitch_delta: float = pitch_a - pitch0
	var locked_yaw_delta: float = yaw_b - yaw_a
	var locked_pitch_delta: float = pitch_b - pitch_a
	var drag_yaw_ok: bool = absf(drag_yaw_delta + 300.0 * 0.0022) < 0.001
	var drag_pitch_ok: bool = absf(drag_pitch_delta + 120.0 * 0.0022) < 0.001
	var locked_yaw_ok: bool = absf(locked_yaw_delta + 0.22) < 0.000001
	var locked_pitch_ok: bool = absf(locked_pitch_delta) < 0.000001
	Debug.result({
		"yaw0": yaw0,
		"pitch0": pitch0,
		"yaw_after_drag": yaw_a,
		"pitch_after_drag": pitch_a,
		"yaw_after_locked": yaw_b,
		"pitch_after_locked": pitch_b,
		"drag_yaw_delta": roundf(drag_yaw_delta * 10000.0) / 10000.0,
		"drag_pitch_delta": roundf(drag_pitch_delta * 10000.0) / 10000.0,
		"locked_yaw_delta": roundf(locked_yaw_delta * 10000.0) / 10000.0,
		"locked_pitch_delta": roundf(locked_pitch_delta * 10000.0) / 10000.0,
		"dragging": dragging and after_drag_not_dragging,
		"drag_mined": drag_mined,
		"drag_yaw_ok": drag_yaw_ok,
		"drag_pitch_ok": drag_pitch_ok,
		"locked_yaw_ok": locked_yaw_ok,
		"locked_pitch_ok": locked_pitch_ok,
		"ok": drag_yaw_ok and drag_pitch_ok and locked_yaw_ok and locked_pitch_ok and dragging and after_drag_not_dragging and not drag_mined,
	})
	get_tree().quit()


func _interact_test() -> void:
	await _interact_test_body()
	get_tree().quit()


func _interact_test_body() -> void:
	var p = Game.player
	if _batt_drop_freeze:
		Game.mode = "play"
	for i in 5:
		await get_tree().physics_frame
	var aim := _find_aim_spot()
	if aim.is_empty():
		Debug.result({"error": "no breakable aim spot near spawn"})
		return
	var target: Vector3i = aim["cell"]
	var tid: int = int(aim["id"])
	world.set_block(target.x, target.y, target.z, 2)
	tid = 2
	var cam: Vector3 = aim["cam"]
	Debug.fly(true)
	Debug.teleport(cam.x, cam.y - p.EYE, cam.z)
	p.look(aim["yaw"], aim["pitch"])
	for i in 4:
		await get_tree().physics_frame
	var highlight_visible: bool = p.highlight.visible
	p.start_mine()
	var frames := int(ceilf(float(Data.block(tid).hard) * 60.0)) + 20
	for i in range(frames):
		await get_tree().physics_frame
	p.release_mine()
	for i in 3:
		await get_tree().physics_frame
	var after_mine: int = world.get_block(target.x, target.y, target.z)
	var drop_spawned: bool = Game.drops.get_child_count() >= 1
	var inv_grew := {"id": tid, "n": 0}
	var teleported := false
	for i in 300:
		var dn: Node3D = null
		if Game.drops.get_child_count() > 0:
			dn = Game.drops.get_child(0)
		if dn != null and not teleported and dn.settled:
			Debug.teleport(dn.position.x, dn.position.y + 1.4, dn.position.z)
			teleported = true
		inv_grew["n"] = _count_item(p, tid)
		if inv_grew["n"] > 0:
			break
		await get_tree().physics_frame
	p.sel = _slot_of(p, tid)
	Debug.teleport(float(target.x) + 0.5, float(target.y) + 1.05, float(target.z) + 0.5)
	p.look(0.0, -p.PITCH_LIMIT)
	for i in 3:
		await get_tree().physics_frame
	var hit2: Dictionary = p.aim_hit()
	var place_cell := Vector3i.ZERO
	if hit2.hit:
		place_cell = hit2.cell + hit2.normal
	p.place()
	for i in 2:
		await get_tree().physics_frame
	var after_place := -1
	if place_cell != Vector3i.ZERO:
		after_place = world.get_block(place_cell.x, place_cell.y, place_cell.z)
	Debug.result({
		"target_cell": [target.x, target.y, target.z],
		"breakable_id": tid,
		"highlight_visible": highlight_visible,
		"after_mine_cell": after_mine,
		"drop_spawned": drop_spawned,
		"inv_grew": inv_grew,
		"place_cell": [place_cell.x, place_cell.y, place_cell.z],
		"after_place_cell": after_place,
		"place_ok": after_place == tid,
	})


func _dropshot_test(spawn: Vector3, path: String) -> void:
	var p = Game.player
	await _await_world_build(spawn, 3000)
	var target: Vector3i = Vector3i(int(spawn.x) + 2, int(spawn.y), int(spawn.z))
	for dy in range(6, -1, -1):
		if world.get_block(target.x, target.y + dy, target.z) != 0:
			target.y = target.y + dy
			break
	world.set_block(target.x, target.y, target.z, 2)
	Debug.fly(true)
	Debug.teleport(float(target.x) + 0.5, float(target.y) + 3.0, float(target.z) + 0.5)
	var dir := Vector3(float(target.x) + 0.5 - (p.position.x), float(target.y) + 0.5 - (p.position.y + p.EYE), float(target.z) + 0.5 - p.position.z)
	if dir.length() > 0.01:
		dir = dir.normalized()
		p.look(atan2(-dir.x, -dir.z), asin(clampf(dir.y, -1.0, 1.0)))
	for i in 4:
		await get_tree().physics_frame
	p.start_mine()
	var frames := int(ceilf(float(Data.block(2).hard) * 60.0)) + 20
	for i in range(frames):
		await get_tree().physics_frame
	p.release_mine()
	var spawned := false
	for i in 60:
		if Game.drops.get_child_count() > 0:
			spawned = true
			break
		await get_tree().physics_frame
	for i in 50:
		await get_tree().physics_frame
	var cam := Vector3(float(target.x) + 3.5, float(target.y) + 2.2, float(target.z) + 3.5)
	var look_at := Vector3(float(target.x) + 0.5, float(target.y) + 0.6, float(target.z) + 0.5)
	camera = _make_camera()
	camera.position = cam
	camera.look_at(look_at, Vector3(0, 1, 0))
	camera.current = true
	for i in 8:
		await get_tree().physics_frame
	await Debug.snap(path)
	Debug.result({"dropshot": true, "spawned": spawned, "drop_count": Game.drops.get_child_count(), "cam": "dropshot"})
	get_tree().quit()


func _crossshot_test(spawn: Vector3, path: String) -> void:
	await _await_world_build(spawn, 3000)
	var tx := int(spawn.x) + 2
	var tz := int(spawn.z) + 2
	var ty := int(spawn.y)
	for dy in range(8, -1, -1):
		if world.get_block(tx, ty + dy, tz) != 0:
			ty = ty + dy
			break
	var placed := 0
	var ids := [18, 19, 18, 19]
	var offs := [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]
	for i in range(4):
		if world.get_block(tx + int(offs[i].x), ty + 1, tz + int(offs[i].y)) == 0:
			world.set_block(tx + int(offs[i].x), ty + 1, tz + int(offs[i].y), ids[i])
			placed += 1
	for i in 10:
		await get_tree().physics_frame
	var cam := Vector3(float(tx) + 2.8, float(ty) + 2.4, float(tz) + 2.8)
	var look_at := Vector3(float(tx) + 0.5, float(ty) + 0.7, float(tz) + 0.5)
	camera = _make_camera()
	camera.position = cam
	camera.look_at(look_at, Vector3(0, 1, 0))
	camera.current = true
	for i in 8:
		await get_tree().physics_frame
	await Debug.snap(path)
	Debug.result({"crossshot": true, "placed": placed, "tx": tx, "ty": ty, "tz": tz})
	get_tree().quit()


func _heldpair(p):
	if p == null or p.held == {} or int(p.held.get("id", 0)) == 0:
		return [0, 0]
	return [int(p.held["id"]), int(p.held["n"])]


func _mb(pos: Vector2, button: int, pressed: bool, shift := false) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = button
	e.pressed = pressed
	e.position = pos
	e.global_position = pos
	e.shift_pressed = shift
	Input.parse_input_event(e)


func _mm(pos: Vector2, rel: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = pos
	e.global_position = pos
	e.relative = rel
	e.button_mask = 1
	Input.parse_input_event(e)


func _guiclick_test() -> void:
	var p = Game.player
	for i in 4:
		await get_tree().physics_frame
	Debug.seed_inv()
	p.open_inventory("inv")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	for i in 6:
		await get_tree().physics_frame
	var r := {}
	var ok := true
	r["held0"] = _heldpair(p)
	ok = ok and r["held0"] == [0, 0]
	p.inv_slot_click(0, "storage", 0, false, false)
	r["held_down"] = _heldpair(p)
	r["storage_down"] = [int(p._inv_get(9)["id"]), int(p._inv_get(9)["n"])]
	ok = ok and r["held_down"] == [6, 5] and r["storage_down"] == [0, 0]
	p.inv_slot_click(0, "hotbar", 0, false, true)
	r["held_up"] = _heldpair(p)
	r["hot0_up"] = [int(p._inv_get(0)["id"]), int(p._inv_get(0)["n"])]
	ok = ok and r["held_up"] == [0, 0] and r["hot0_up"] == [6, 5]
	p.inv_slot_click(0, "hotbar", 0, false, false)
	r["held_grab2"] = _heldpair(p)
	ok = ok and r["held_grab2"] == [6, 5]
	p.inv_slot_click(2, "hotbar", 0, false, true)
	r["hot2_move"] = [int(p._inv_get(2)["id"]), int(p._inv_get(2)["n"])]
	r["hot0_move"] = [int(p._inv_get(0)["id"]), int(p._inv_get(0)["n"])]
	ok = ok and _heldpair(p) == [0, 0] and r["hot2_move"] == [6, 5] and r["hot0_move"] == [0, 0]
	Debug.give_item(8, 3)
	p.inv_slot_click(p.find_slot(8), "hotbar", 0, false, false)
	p.inv_slot_click(0, "hotbar", 0, false, false)
	r["two_click"] = [int(p._inv_get(0)["id"]), int(p._inv_get(0)["n"]), _heldpair(p)]
	p.inv_slot_click(0, "hotbar", 0, false, true)
	r["two_click_up"] = [int(p._inv_get(0)["id"]), int(p._inv_get(0)["n"]), _heldpair(p)]
	ok = ok and r["two_click"] == [8, 3, [0, 0]] and r["two_click_up"] == [8, 3, [0, 0]]
	p.inv_slot_click(0, "storage", 0, false, false)
	p.inv_slot_click(0, "storage", 0, false, true)
	r["storage_same"] = [int(p._inv_get(9)["id"]), int(p._inv_get(9)["n"]), _heldpair(p)]
	ok = ok and r["storage_same"] == [0, 0, [0, 0]]
	Debug.seed_inv()
	for i in 8:
		await get_tree().physics_frame
	var hv = Game.hotbar
	var s23: Control = hv._slots[23]
	var s50: Control = hv._slots[50]
	print("AC45_IDX held=", hv._held.get_index(), " panel=", hv._panel.get_index(), " total=", hv.get_child_count())
	p.inv_slot_click(0, "storage", 0, false, false)
	ok = ok and _heldpair(p) == [6, 5]
	Game.hotbar._release_drop(p, s50.position + s50.size * 0.5)
	r["drop_hot0"] = [int(p._inv_get(0)["id"]), int(p._inv_get(0)["n"]), _heldpair(p)]
	ok = ok and r["drop_hot0"] == [6, 5, [0, 0]]
	p.inv_slot_click(0, "hotbar", 0, false, false)
	Game.hotbar._release_drop(p, s23.position + s23.size * 0.5)
	r["drop_storage"] = [int(p._inv_get(9)["id"]), int(p._inv_get(9)["n"]), _heldpair(p)]
	ok = ok and r["drop_storage"] == [6, 5, [0, 0]]
	ok = ok and await _guiclick_real(p, r, ok)
	Debug.result({"ok": ok, "data": r})
	get_tree().quit()


func _slotc(si: int) -> Vector2:
	var s: Control = Game.hotbar._slots[si]
	return Vector2(s.position.x + 24.0, s.position.y + 24.0)


func _guiclick_real(p, r, ok: bool) -> bool:
	p.held = {}
	p.drag_held = false
	for i in 36:
		p.inv[i] = {"id": 0, "n": 0}
	p.inv[0] = {"id": 8, "n": 3}
	p.inv[1] = {"id": 9, "n": 2}
	p.inv[5] = {"id": 6, "n": 5}
	p.inv[9] = {"id": 2, "n": 4}
	p.inv[10] = {"id": 5, "n": 3}
	p.inv[11] = {"id": 7, "n": 2}
	p.inv[12] = {"id": 4, "n": 4}
	for i in 10:
		await get_tree().physics_frame
	# R1: real press on storage slot 23 (inv[9]) picks the stack up
	var c23 := _slotc(23)
	_mb(c23, 1, true)
	for i in 3:
		await get_tree().physics_frame
	r["R1_held"] = _heldpair(p)
	r["R1_src"] = [int(p._inv_get(9)["id"]), int(p._inv_get(9)["n"])]
	ok = ok and r["R1_held"] == [2, 4] and r["R1_src"] == [0, 0]
	# R2: real release over hotbar slot 52 (inv[2], empty) drops it
	var c52 := _slotc(52)
	_mm(c52, c52 - c23)
	for i in 3:
		await get_tree().physics_frame
	_mb(c52, 1, false)
	for i in 3:
		await get_tree().physics_frame
	r["R2_dst"] = [int(p._inv_get(2)["id"]), int(p._inv_get(2)["n"])]
	r["R2_held"] = _heldpair(p)
	ok = ok and r["R2_dst"] == [2, 4] and r["R2_held"] == [0, 0]
	# R3: click pick (hotbar 51) + click place into other (hotbar 50) = swap, release into empty 53
	_mb(_slotc(51), 1, true)
	for i in 2:
		await get_tree().physics_frame
	_mb(_slotc(50), 1, true)
	for i in 2:
		await get_tree().physics_frame
	var c53 := _slotc(53)
	_mb(c53, 1, false)
	for i in 3:
		await get_tree().physics_frame
	r["R3_hot0"] = [int(p._inv_get(0)["id"]), int(p._inv_get(0)["n"])]
	r["R3_hot1"] = [int(p._inv_get(1)["id"]), int(p._inv_get(1)["n"])]
	r["R3_hot3"] = [int(p._inv_get(3)["id"]), int(p._inv_get(3)["n"])]
	r["R3_held"] = _heldpair(p)
	ok = ok and r["R3_hot0"] == [9, 2] and r["R3_hot1"] == [0, 0] and r["R3_hot3"] == [8, 3] and r["R3_held"] == [0, 0]
	# R4: press-drag-release hotbar 50 (inv[0]) -> storage slot 30 (inv[16])
	var c30 := _slotc(30)
	_mb(_slotc(50), 1, true)
	for i in 2:
		await get_tree().physics_frame
	_mm(c30, c30 - _slotc(50))
	for i in 2:
		await get_tree().physics_frame
	_mb(c30, 1, false)
	for i in 3:
		await get_tree().physics_frame
	r["R4_dst"] = [int(p._inv_get(16)["id"]), int(p._inv_get(16)["n"])]
	r["R4_src"] = [int(p._inv_get(0)["id"]), int(p._inv_get(0)["n"])]
	ok = ok and r["R4_dst"] == [9, 2] and r["R4_src"] == [0, 0]
	# R5: press-drag-release storage slot 26 (inv[12]) -> storage slot 49 (row 3, inv[35])
	var c26 := _slotc(26)
	var c49 := _slotc(49)
	_mb(c26, 1, true)
	for i in 2:
		await get_tree().physics_frame
	_mm(c49, c49 - c26)
	for i in 2:
		await get_tree().physics_frame
	_mb(c49, 1, false)
	for i in 3:
		await get_tree().physics_frame
	r["R5_dst"] = [int(p._inv_get(35)["id"]), int(p._inv_get(35)["n"])]
	r["R5_src"] = [int(p._inv_get(12)["id"]), int(p._inv_get(12)["n"])]
	ok = ok and r["R5_dst"] == [4, 4] and r["R5_src"] == [0, 0]
	# R6: shift-click storage slot 24 (inv[10]) -> first empty hotbar slot (inv[1])
	var c24 := _slotc(24)
	_mb(c24, 1, true, true)
	for i in 2:
		await get_tree().physics_frame
	_mb(c24, 1, false, true)
	for i in 3:
		await get_tree().physics_frame
	r["R6_dst"] = [int(p._inv_get(0)["id"]), int(p._inv_get(0)["n"])]
	r["R6_src"] = [int(p._inv_get(10)["id"]), int(p._inv_get(10)["n"])]
	ok = ok and r["R6_dst"] == [5, 3] and r["R6_src"] == [0, 0]
	# R7: shift-click hotbar slot 55 (inv[5]) -> first empty storage slot (inv[9])
	var c55 := _slotc(55)
	_mb(c55, 1, true, true)
	for i in 2:
		await get_tree().physics_frame
	_mb(c55, 1, false, true)
	for i in 3:
		await get_tree().physics_frame
	r["R7_dst"] = [int(p._inv_get(9)["id"]), int(p._inv_get(9)["n"])]
	r["R7_src"] = [int(p._inv_get(5)["id"]), int(p._inv_get(5)["n"])]
	ok = ok and r["R7_dst"] == [6, 5] and r["R7_src"] == [0, 0]
	# R8: craft-output click with hotbar full -> lands in first storage slot (inv[9])
	for i in 36:
		p.inv[i] = {"id": 0, "n": 0}
	p.held = {}
	p.drag_held = false
	for i in 9:
		p.inv[i] = {"id": 150 + i, "n": 1}
	p.close_inventory()
	p.open_inventory("inv")
	p.craft_grid[0] = {"id": 6, "n": 1}
	p.recompute_craft()
	for i in 6:
		await get_tree().physics_frame
	r["R8_out_pre"] = [int(p.craft_out.get("id", 0)), int(p.craft_out.get("n", 0))]
	var c18 := _slotc(18)
	_mb(c18, 1, true)
	for i in 2:
		await get_tree().physics_frame
	_mb(c18, 1, false)
	for i in 3:
		await get_tree().physics_frame
	r["R8_planks"] = _count_item(p, 8)
	r["R8_inv9"] = [int(p._inv_get(9)["id"]), int(p._inv_get(9)["n"])]
	ok = ok and r["R8_out_pre"] == [8, 4] and r["R8_planks"] == 4 and r["R8_inv9"] == [8, 4]
	# P1: pickup order — empty inventory, item lands in the first HOTBAR slot
	for i in 36:
		p.inv[i] = {"id": 0, "n": 0}
	p.held = {}
	p.drag_held = false
	Debug.give_item(8, 5)
	r["P1_landing"] = _slot_of(p, 8)
	r["P1_inv0"] = [int(p._inv_get(0)["id"]), int(p._inv_get(0)["n"])]
	ok = ok and r["P1_landing"] == 0 and r["P1_inv0"] == [8, 5]
	# P2: merge-where-present still wins (hotbar stack grows)
	for i in 36:
		p.inv[i] = {"id": 0, "n": 0}
	p.inv[2] = {"id": 8, "n": 10}
	Debug.give_item(8, 5)
	r["P2_merge"] = [int(p._inv_get(2)["id"]), int(p._inv_get(2)["n"])]
	r["P2_landing"] = _slot_of(p, 8)
	ok = ok and r["P2_merge"] == [8, 15] and r["P2_landing"] == 2
	# P3: hotbar full -> overflow to first storage slot (inv[9])
	for i in 36:
		p.inv[i] = {"id": 0, "n": 0}
	for i in 9:
		p.inv[i] = {"id": 150 + i, "n": 1}
	Debug.give_item(8, 3)
	r["P3_landing"] = _slot_of(p, 8)
	r["P3_inv9"] = [int(p._inv_get(9)["id"]), int(p._inv_get(9)["n"])]
	ok = ok and r["P3_landing"] == 9 and r["P3_inv9"] == [8, 3]
	# C1: recipe-row click in the E-inventory (planks): pull the log from storage,
	# fill the 2x2 grid, show output, click output -> planks to hotbar, grid cleared
	for i in 36:
		p.inv[i] = {"id": 0, "n": 0}
	p.held = {}
	p.drag_held = false
	p.close_inventory()
	p.open_inventory("inv")
	p.inv[9] = {"id": 6, "n": 4}
	for i in 8:
		await get_tree().physics_frame
	var hv = Game.hotbar
	var c1row = _find_recipe_row(hv, 8)
	r["C1_row"] = c1row != null
	if c1row != null:
		var cp1: Vector2 = hv._recipe_box.position + c1row.position + c1row.size * 0.5
		_mb(cp1, 1, true)
		for i in 2:
			await get_tree().physics_frame
		_mb(cp1, 1, false)
		for i in 4:
			await get_tree().physics_frame
	var c1g: Array = []
	for i in 4:
		c1g.append(int(p.craft_grid[i]["id"]))
	r["C1_grid"] = c1g
	r["C1_out"] = [int(p.craft_out.get("id", 0)), int(p.craft_out.get("n", 0)) if p.craft_out != {} else 0]
	ok = ok and r["C1_row"] and r["C1_grid"] == [6, 0, 0, 0] and r["C1_out"] == [8, 4]
	_mb(_slotc(18), 1, true)
	for i in 2:
		await get_tree().physics_frame
	_mb(_slotc(18), 1, false)
	for i in 4:
		await get_tree().physics_frame
	r["C1_planks"] = _count_item(p, 8)
	r["C1_logs_left"] = _count_item(p, 6)
	var c1ga: Array = []
	for i in 4:
		c1ga.append(int(p.craft_grid[i]["id"]))
	r["C1_grid_after"] = c1ga
	ok = ok and r["C1_planks"] == 4 and r["C1_logs_left"] == 3 and r["C1_grid_after"] == [0, 0, 0, 0]
	# C2: recipe-row click in the table GUI (wooden pickaxe 3x3 pattern)
	p.close_inventory()
	for i in 36:
		p.inv[i] = {"id": 0, "n": 0}
	p.held = {}
	p.drag_held = false
	p.open_inventory("table")
	p.inv[10] = {"id": 8, "n": 3}
	p.inv[11] = {"id": 100, "n": 2}
	p.inv[12] = {"id": 8, "n": 5}
	for i in 8:
		await get_tree().physics_frame
	var c2row = _find_recipe_row(hv, 111)
	r["C2_row"] = c2row != null
	if c2row != null:
		var cp2: Vector2 = hv._recipe_box.position + c2row.position + c2row.size * 0.5
		_mb(cp2, 1, true)
		for i in 2:
			await get_tree().physics_frame
		_mb(cp2, 1, false)
		for i in 4:
			await get_tree().physics_frame
	var c2tg: Array = []
	for i in 9:
		c2tg.append(int(p.table_grid[i]["id"]))
	r["C2_tgrid"] = c2tg
	r["C2_out"] = [int(p.craft_out.get("id", 0)), int(p.craft_out.get("n", 0)) if p.craft_out != {} else 0]
	ok = ok and r["C2_row"] and r["C2_tgrid"] == [8, 8, 8, 0, 100, 0, 0, 100, 0] and r["C2_out"] == [111, 1]
	_mb(_slotc(18), 1, true)
	for i in 2:
		await get_tree().physics_frame
	_mb(_slotc(18), 1, false)
	for i in 4:
		await get_tree().physics_frame
	r["C2_pick"] = _count_item(p, 111)
	var c2tga: Array = []
	for i in 9:
		c2tga.append(int(p.table_grid[i]["id"]))
	r["C2_tgrid_after"] = c2tga
	r["C2_planks_left"] = _count_item(p, 8)
	r["C2_sticks_left"] = _count_item(p, 100)
	ok = ok and r["C2_pick"] == 1 and r["C2_tgrid_after"] == [0, 0, 0, 0, 0, 0, 0, 0, 0] and r["C2_planks_left"] == 5 and r["C2_sticks_left"] == 0
	return ok


func _find_recipe_row(hv, out_id: int):
	for row in hv._recipe_rows:
		if int(row.out_id) == out_id:
			return row
	return null


func _craft_test() -> void:
	var p = Game.player
	for i in 4:
		await get_tree().physics_frame
	var r := {}
	var ok := true
	Debug.give_item(6, 2)
	r["logs_start"] = _count_item(p, 6)
	ok = ok and r["logs_start"] == 2
	p.inv[0] = {"id": 6, "n": 2}
	p.inv[9] = {"id": 0, "n": 0}
	p.open_inventory("inv")
	Debug.inv_click(41, 2)
	r["held_r1"] = [int(p.held.get("id", 0)), int(p.held.get("n", 0)) if p.held != {} else 0]
	Debug.inv_click(0, 0)
	r["out_a"] = [int(p.craft_out.get("id", 0)), int(p.craft_out.get("n", 0)) if p.craft_out != {} else 0]
	ok = ok and int(p.craft_out.get("id", 0)) == 8 and int(p.craft_out.get("n", 0)) == 4
	Debug.craft()
	r["planks_a"] = _count_item(p, 8)
	r["logs_a"] = _count_item(p, 6)
	ok = ok and r["planks_a"] == 4 and r["logs_a"] == 1
	for i in 36:
		if i != 1 and int(p.inv[i]["id"]) == 8:
			p.inv[i] = {"id": 0, "n": 0}
	Debug.inv_click(41, 2)
	Debug.inv_click(0, 0)
	r["out_b"] = [int(p.craft_out.get("id", 0)), int(p.craft_out.get("n", 0)) if p.craft_out != {} else 0]
	ok = ok and int(p.craft_out.get("id", 0)) == 8 and int(p.craft_out.get("n", 0)) == 4
	Debug.craft()
	r["planks_b"] = _count_item(p, 8)
	r["logs_b"] = _count_item(p, 6)
	ok = ok and r["planks_b"] == 8 and r["logs_b"] == 0
	Debug.inv_click(42, 2)
	Debug.inv_click(0, 0)
	Debug.inv_click(42, 2)
	Debug.inv_click(1, 0)
	r["out_c"] = [int(p.craft_out.get("id", 0)), int(p.craft_out.get("n", 0)) if p.craft_out != {} else 0]
	ok = ok and int(p.craft_out.get("id", 0)) == 100 and int(p.craft_out.get("n", 0)) == 4
	Debug.craft()
	r["sticks_c"] = _count_item(p, 100)
	r["planks_c"] = _count_item(p, 8)
	ok = ok and r["sticks_c"] == 4 and r["planks_c"] == 6
	p.inv[3] = {"id": 127, "n": 1}
	Debug.inv_click(44, 0)
	Debug.inv_click(10, 0)
	r["armor_head"] = int(p.armor[0])
	r["points_head"] = p.armor_points()
	ok = ok and r["armor_head"] == 127 and r["points_head"] == 1
	p.inv[3] = {"id": 131, "n": 1}
	Debug.inv_click(44, 0)
	Debug.inv_click(10, 0)
	r["armor_swap"] = [int(p.armor[0]), int(p.held.get("id", 0)) if p.held != {} else 0, p.armor_points()]
	ok = ok and int(p.armor[0]) == 131 and int(p.held.get("id", 0)) == 127 and p.armor_points() == 2
	Debug.inv_click(44, 0)
	Debug.inv_click(10, 0)
	r["armor_uneq"] = [int(p.armor[0]), int(p.held.get("id", 0)) if p.held != {} else 0]
	ok = ok and int(p.armor[0]) == 0 and int(p.held.get("id", 0)) == 131
	Debug.inv_click(45, 0)
	Debug.inv_click(42, 2)
	Debug.inv_click(0, 0)
	r["out_nomatch"] = [int(p.craft_out.get("id", 0)), int(p.craft_out.get("n", 0)) if p.craft_out != {} else 0]
	ok = ok and p.craft_out == {}
	p.close_inventory()
	r["close_ui"] = p.ui_mode
	r["close_grid0"] = int(p.craft_grid[0]["id"])
	r["planks_close"] = _count_item(p, 8)
	ok = ok and p.ui_mode == "" and r["close_grid0"] == 0 and _count_item(p, 8) == 5
	Debug.give_item(8, 1)
	Debug.inv_click(42, 2)
	p.close_inventory()
	r["held_return"] = [int(p.held.get("id", 0)) if p.held != {} else 0, _count_item(p, 8)]
	ok = ok and p.held == {} and _count_item(p, 8) == 6
	for i in 36:
		p.inv[i] = {"id": 0, "n": 0}
	p.held = {}
	p.open_inventory("inv")
	p.inv[0] = {"id": 6, "n": 5}
	for i in range(1, 9):
		p.inv[i] = {"id": 150 + i, "n": 3}
	Debug.inv_click(41, 2)
	Debug.inv_click(0, 0)
	Debug.craft()
	r["A_inv9"] = [int(p._inv_get(9)["id"]), int(p._inv_get(9)["n"])]
	var a_hot_planks := 0
	for i in 9:
		if int(p._inv_get(i)["id"]) == 8:
			a_hot_planks += int(p._inv_get(i)["n"])
	var a_vis_planks := 0
	for i in range(9, 36):
		if int(p._inv_get(i)["id"]) == 8:
			a_vis_planks += int(p._inv_get(i)["n"])
	r["A_hot_planks"] = a_hot_planks
	r["A_vis_planks"] = a_vis_planks
	ok = ok and r["A_inv9"] == [8, 4] and a_hot_planks == 0 and a_vis_planks == 4
	for i in 36:
		p.inv[i] = {"id": 2, "n": 1}
	p.inv[0] = {"id": 6, "n": 6}
	p.held = {}
	Debug.inv_click(41, 2)
	Debug.inv_click(0, 0)
	r["B_out_pre"] = [int(p.craft_out.get("id", 0)), int(p.craft_out.get("n", 0)) if p.craft_out != {} else 0]
	Debug.craft()
	r["B_out"] = [int(p.craft_out.get("id", 0)), int(p.craft_out.get("n", 0)) if p.craft_out != {} else 0]
	r["B_logs"] = _count_item(p, 6)
	r["B_grid0"] = [int(p.craft_grid[0]["id"]), int(p.craft_grid[0]["n"])]
	ok = ok and r["B_out_pre"] == [8, 4] and r["B_out"] == [8, 4] and r["B_logs"] == 5 and r["B_grid0"] == [6, 1]
	for i in 36:
		p.inv[i] = {"id": 0, "n": 0}
	p.held = {}
	for i in 8:
		p.inv[i] = {"id": 150 + i, "n": 2}
	p.inv[9] = {"id": 12, "n": 3}
	p.inv_slot_click(0, "storage", 0, true, false)
	r["C1_inv8"] = [int(p._inv_get(8)["id"]), int(p._inv_get(8)["n"])]
	r["C1_inv9"] = [int(p._inv_get(9)["id"]), int(p._inv_get(9)["n"])]
	ok = ok and r["C1_inv8"] == [12, 3] and r["C1_inv9"] == [0, 0]
	for i in 36:
		p.inv[i] = {"id": 0, "n": 0}
	p.held = {}
	p.inv[0] = {"id": 5, "n": 7}
	p.inv_slot_click(0, "hotbar", 0, true, false)
	r["C2_inv9"] = [int(p._inv_get(9)["id"]), int(p._inv_get(9)["n"])]
	r["C2_inv0"] = [int(p._inv_get(0)["id"]), int(p._inv_get(0)["n"])]
	ok = ok and r["C2_inv9"] == [5, 7] and r["C2_inv0"] == [0, 0]
	for i in 36:
		p.inv[i] = {"id": 0, "n": 0}
	p.held = {}
	p.inv[35] = {"id": 2, "n": 5}
	p.inv_slot_click(26, "storage", 0, false, false)
	r["D0_held"] = _heldpair(p)
	r["D0_inv35"] = [int(p._inv_get(35)["id"]), int(p._inv_get(35)["n"])]
	p.inv_slot_click(4, "hotbar", 0, false, true)
	r["D1_hot4"] = [int(p._inv_get(4)["id"]), int(p._inv_get(4)["n"])]
	p.inv_slot_click(4, "hotbar", 0, false, false)
	p.inv_slot_click(26, "storage", 0, false, true)
	r["D2_inv35"] = [int(p._inv_get(35)["id"]), int(p._inv_get(35)["n"])]
	r["D2_hot4"] = [int(p._inv_get(4)["id"]), int(p._inv_get(4)["n"])]
	r["D2_held"] = _heldpair(p)
	r["D_dirt"] = _count_item(p, 2)
	ok = ok and r["D0_held"] == [2, 5] and r["D0_inv35"] == [0, 0] and r["D1_hot4"] == [2, 5] and r["D2_inv35"] == [2, 5] and r["D2_hot4"] == [0, 0] and r["D2_held"] == [0, 0] and r["D_dirt"] == 5
	# --- AC-0052: 2x2 vs 3x3 crafting gate (pickaxe pattern = 3 planks row + 2 sticks) ---
	p.close_inventory()
	# A: pickaxe pattern in the 2x2 E-grid -> NULL output, inputs unmodified
	p.open_inventory("inv")
	p.craft_grid[0] = {"id": 8, "n": 1}
	p.craft_grid[1] = {"id": 8, "n": 1}
	p.craft_grid[2] = {"id": 8, "n": 1}
	p.craft_grid[3] = {"id": 100, "n": 1}
	p.recompute_craft()
	r["A_out"] = [int(p.craft_out.get("id", 0)), int(p.craft_out.get("n", 0)) if p.craft_out != {} else 0]
	var a_grid: Array = []
	for gi in 4:
		a_grid.append([int(p.craft_grid[gi]["id"]), int(p.craft_grid[gi]["n"])])
	r["A_grid"] = a_grid
	ok = ok and r["A_out"] == [0, 0] and a_grid == [[8, 1], [8, 1], [8, 1], [100, 1]]
	# B: same pattern in the table 3x3 grid -> pickaxe 111, output click consumes all 5 inputs
	p.open_inventory("table")
	p.table_grid[0] = {"id": 8, "n": 1}
	p.table_grid[1] = {"id": 8, "n": 1}
	p.table_grid[2] = {"id": 8, "n": 1}
	p.table_grid[4] = {"id": 100, "n": 1}
	p.table_grid[7] = {"id": 100, "n": 1}
	p.recompute_craft()
	r["B_out"] = [int(p.craft_out.get("id", 0)), int(p.craft_out.get("n", 0)) if p.craft_out != {} else 0]
	ok = ok and r["B_out"] == [111, 1]
	Debug.craft()
	var b_filled := 0
	for i in p.table_grid.size():
		if int(p.table_grid[i]["id"]) != 0:
			b_filled += 1
	r["B_pick"] = _count_item(p, 111)
	r["B_filled"] = b_filled
	ok = ok and r["B_pick"] == 1 and b_filled == 0
	# C: grid-2 recipe (planks) still works in the 2x2 E-grid
	p.close_inventory()
	p.open_inventory("inv")
	p.craft_grid[0] = {"id": 6, "n": 1}
	p.recompute_craft()
	r["C_out"] = [int(p.craft_out.get("id", 0)), int(p.craft_out.get("n", 0)) if p.craft_out != {} else 0]
	ok = ok and r["C_out"] == [8, 4]
	# D: grid-3 recipe (iron sword, shapeless) NULL in 2x2, = 109 in table
	p.craft_grid[0] = {"id": 105, "n": 3}
	p.craft_grid[1] = {"id": 100, "n": 2}
	p.recompute_craft()
	r["D_out_inv"] = [int(p.craft_out.get("id", 0)), int(p.craft_out.get("n", 0)) if p.craft_out != {} else 0]
	ok = ok and r["D_out_inv"] == [0, 0]
	p.open_inventory("table")
	p.table_grid[0] = {"id": 105, "n": 3}
	p.table_grid[1] = {"id": 100, "n": 2}
	p.recompute_craft()
	r["D_out_table"] = [int(p.craft_out.get("id", 0)), int(p.craft_out.get("n", 0)) if p.craft_out != {} else 0]
	ok = ok and r["D_out_table"] == [109, 1]
	Debug.craft()
	r["D_sword"] = _count_item(p, 109)
	ok = ok and r["D_sword"] == 1
	# E: closing the table returns grid items to inv (space allows); full inv -> item drops
	p.table_grid[0] = {"id": 8, "n": 4}
	p.close_inventory()
	r["E_planks"] = _count_item(p, 8)
	ok = ok and r["E_planks"] == 4
	var drops_base: int = int(Game.drops.get_child_count())
	for i in 36:
		p.inv[i] = {"id": 2, "n": 64}
	p.open_inventory("table")
	p.table_grid[0] = {"id": 6, "n": 3}
	p.close_inventory()
	r["E_drops"] = int(Game.drops.get_child_count()) - drops_base
	r["E_logs"] = _count_item(p, 6)
	ok = ok and r["E_drops"] == 3 and r["E_logs"] == 0
	# F: table use beats placement — holding a placeable, use_selected on a table opens the table
	for i in 36:
		p.inv[i] = {"id": 0, "n": 0}
	p.held = {}
	p.close_inventory()
	var fsp: Vector3 = world.spawn_point()
	var fsx := int(fsp.x)
	var fsz := int(fsp.z)
	var ftop: int = world.surface_top(fsx, fsz)
	var fx := -1
	var fz := -1
	for dx in range(-8, 9, 2):
		for dz in range(-8, 9, 2):
			var tx2 := fsx + dx
			var tz2 := fsz + dz
			var flat := true
			for fxx in range(-1, 2):
				for fzz in range(-1, 2):
					if world.surface_top(tx2 + fxx, tz2 + fzz) != ftop:
						flat = false
			if not flat:
				continue
			var clear := true
			for k2 in range(1, 5):
				if world.surface_top(tx2, tz2 - k2) > ftop:
					clear = false
			if not clear:
				continue
			fx = tx2
			fz = tz2
			break
		if fx >= 0:
			break
	if fx < 0:
		fx = fsx
		fz = fsz
	var fsc := Vector3i(fx, ftop + 1, fz - 4)
	Debug.set_block(fsc.x, fsc.y, fsc.z, 20)
	Debug.fly(true)
	var feye := Vector3(float(fx) + 0.5, float(ftop + 1) + 0.5, float(fz) + 0.5)
	Debug.aim_at(feye.x, feye.y, feye.z)
	for i in 6:
		await get_tree().physics_frame
	var fhit: Dictionary = p.aim_hit()
	r["F_aim"] = [bool(fhit.hit), int(fhit.get("id", 0))]
	p.inv[0] = {"id": 1, "n": 5}
	p.sel = 0
	p.use_selected()
	r["F_mode"] = String(p.ui_mode)
	r["F_held"] = [int(p.inv[0]["id"]), int(p.inv[0]["n"])]
	r["F_cell"] = world.get_block(fsc.x, fsc.y, fsc.z)
	ok = ok and int(fhit.get("id", 0)) == 20 and r["F_mode"] == "table" and r["F_held"] == [1, 5] and r["F_cell"] == 20
	p.close_inventory()
	# --- AC-0132: torch recipe probe (Tneg/T1/T2/T3/T4) ---
	for i in 36:
		p.inv[i] = {"id": 0, "n": 0}
	p.held = {}
	# Tneg: single coal alone -> no match (exact-count; torch needs coal + stick)
	p.open_inventory("inv")
	p.craft_grid[0] = {"id": 106, "n": 1}
	p.recompute_craft()
	r["Tneg_out"] = [int(p.craft_out.get("id", 0)), int(p.craft_out.get("n", 0)) if p.craft_out != {} else 0]
	ok = ok and r["Tneg_out"] == [0, 0]
	# T1: E vertical C-over-S (coal top-left, stick bottom-left) -> torch x4
	p.craft_grid[2] = {"id": 100, "n": 1}
	p.recompute_craft()
	r["T1_out"] = [int(p.craft_out.get("id", 0)), int(p.craft_out.get("n", 0)) if p.craft_out != {} else 0]
	ok = ok and r["T1_out"] == [22, 4]
	Debug.craft()
	r["T1_torch"] = _count_item(p, 22)
	ok = ok and r["T1_torch"] == 4
	var t1_grid: Array = []
	for gi in 4:
		t1_grid.append([int(p.craft_grid[gi]["id"]), int(p.craft_grid[gi]["n"])])
	r["T1_grid"] = t1_grid
	ok = ok and t1_grid == [[0, 0], [0, 0], [0, 0], [0, 0]]
	# T2: E horizontal (coal top-left, stick top-right) -> placement-independent, +4 torch
	p.craft_grid[0] = {"id": 106, "n": 1}
	p.craft_grid[1] = {"id": 100, "n": 1}
	p.recompute_craft()
	r["T2_out"] = [int(p.craft_out.get("id", 0)), int(p.craft_out.get("n", 0)) if p.craft_out != {} else 0]
	ok = ok and r["T2_out"] == [22, 4]
	Debug.craft()
	r["T2_torch"] = _count_item(p, 22)
	ok = ok and r["T2_torch"] == 8
	var t2_filled := 0
	for i in p.craft_grid.size():
		if int(p.craft_grid[i]["id"]) != 0:
			t2_filled += 1
	r["T2_filled"] = t2_filled
	ok = ok and t2_filled == 0
	# T3: table vertical C-over-S (grid:2 reaches the 3x3 table) -> +4 torch
	p.close_inventory()
	p.open_inventory("table")
	p.table_grid[0] = {"id": 106, "n": 1}
	p.table_grid[3] = {"id": 100, "n": 1}
	p.recompute_craft()
	r["T3_out"] = [int(p.craft_out.get("id", 0)), int(p.craft_out.get("n", 0)) if p.craft_out != {} else 0]
	ok = ok and r["T3_out"] == [22, 4]
	Debug.craft()
	r["T3_torch"] = _count_item(p, 22)
	ok = ok and r["T3_torch"] == 12
	var t3_filled := 0
	for i in p.table_grid.size():
		if int(p.table_grid[i]["id"]) != 0:
			t3_filled += 1
	r["T3_filled"] = t3_filled
	ok = ok and t3_filled == 0
	# T4: regression — existing grid-2 recipe 9(Cobblestone)+100(Stick) -> Arrow 143 x4
	p.close_inventory()
	p.open_inventory("inv")
	p.craft_grid[0] = {"id": 9, "n": 1}
	p.craft_grid[2] = {"id": 100, "n": 1}
	p.recompute_craft()
	r["T4_out"] = [int(p.craft_out.get("id", 0)), int(p.craft_out.get("n", 0)) if p.craft_out != {} else 0]
	ok = ok and r["T4_out"] == [143, 4]
	Debug.craft()
	r["T4_arrow"] = _count_item(p, 143)
	ok = ok and r["T4_arrow"] == 4
	var t4_grid: Array = []
	for gi in 4:
		t4_grid.append([int(p.craft_grid[gi]["id"]), int(p.craft_grid[gi]["n"])])
	r["T4_grid"] = t4_grid
	ok = ok and t4_grid == [[0, 0], [0, 0], [0, 0], [0, 0]]
	Debug.result({
		"ok": ok,
		"data": r,
		"inv": Debug.inv_dump(),
		"armor": Debug.armor_dump(),
	})
	get_tree().quit()


func _survival_test(spawn: Vector3) -> void:
	var p = Game.player
	for i in 60:
		await get_tree().physics_frame
	var r := {}
	var ok := true
	var sx := int(spawn.x)
	var sz := int(spawn.z)
	var ctop: int = world.surface_top(sx, sz)
	var px := -1
	var pz := -1
	for dx in range(-8, 9, 2):
		for dz in range(-8, 9, 2):
			var tx := sx + dx
			var tz := sz + dz
			var flat := true
			for fx in range(-1, 2):
				for fz in range(-1, 2):
					if world.surface_top(tx + fx, tz + fz) != ctop:
						flat = false
			if not flat:
				continue
			var clear := true
			for k in range(1, 5):
				if world.surface_top(tx, tz - k) > ctop:
					clear = false
			if not clear:
				continue
			px = tx
			pz = tz
			break
		if px >= 0:
			break
	if px < 0:
		Debug.result({"error": "no flat survival spot near spawn"})
		get_tree().quit()
		return
	var sc := Vector3i(px, ctop + 1, pz - 4)
	Debug.set_block(sc.x, sc.y, sc.z, 3)
	Debug.fly(true)
	var eye := Vector3(float(px) + 0.5, float(ctop + 1) + 0.5, float(pz) + 0.5)
	Debug.aim_at(eye.x, eye.y, eye.z)
	for i in 3:
		await get_tree().physics_frame
	var mine_hits: bool = false
	for i in 4:
		await get_tree().physics_frame
		if p.aim_hit().hit:
			mine_hits = true
			break
	var h0: float = p.hunger
	var drops_before: int = Game.drops.get_child_count()
	var t0 := Time.get_ticks_msec()
	p.start_mine()
	var bare_frames := -1
	for i in range(300):
		await get_tree().physics_frame
		if world.get_block(sc.x, sc.y, sc.z) == 0:
			bare_frames = i + 1
			break
	var bare_ms := Time.get_ticks_msec() - t0
	for i in 4:
		await get_tree().physics_frame
	var drop_bare: int = Game.drops.get_child_count() - drops_before
	Debug.set_block(sc.x, sc.y, sc.z, 3)
	Debug.give_item(111, 1)
	p.sel = _slot_of(p, 111)
	Debug.aim_at(eye.x, eye.y, eye.z)
	for i in 3:
		await get_tree().physics_frame
	t0 = Time.get_ticks_msec()
	p.start_mine()
	var pick_frames := -1
	for i in range(300):
		await get_tree().physics_frame
		if world.get_block(sc.x, sc.y, sc.z) == 0:
			pick_frames = i + 1
			break
	var pick_ms := Time.get_ticks_msec() - t0
	var h_end: float = p.hunger
	var drop_pick := -1
	for i in 12:
		for ch in Game.drops.get_children():
			if int(ch.id) == 9:
				drop_pick = 9
		if drop_pick >= 0:
			break
		await get_tree().physics_frame
	var tool_ratio := float(bare_ms) / float(pick_ms) if pick_ms > 0 else 0.0
	ok = ok and bare_frames > 0 and pick_frames > 0
	ok = ok and absf(tool_ratio - 2.0) < 0.25
	ok = ok and drop_bare == 0
	ok = ok and drop_pick == 9
	p.armor = [0, 0, 0, 0]
	p.hp = 20.0
	p.damage_player(5.0, "t")
	var dmg_none: float = 20.0 - p.hp
	p.armor = [131, 132, 133, 134]
	p.hp = 20.0
	p.damage_player(5.0, "t")
	var dmg_armor: float = 20.0 - p.hp
	ok = ok and dmg_none == 5.0 and dmg_armor == 2.0
	Debug.fly(false)
	Debug.teleport(float(px) + 0.5, float(ctop + 1) + 0.05, float(pz) + 0.5)
	for i in 60:
		if p.is_on_floor():
			break
		await get_tree().physics_frame
	if not p.is_on_floor():
		Debug.result({"error": "no floor for sprint phase"})
		get_tree().quit()
		return
	var h_s0: float = p.hunger
	var ke := InputEventKey.new()
	ke.physical_keycode = KEY_SHIFT
	ke.keycode = KEY_SHIFT
	ke.pressed = true
	Input.parse_input_event(ke)
	for i in 60:
		await get_tree().physics_frame
	ke.pressed = false
	Input.parse_input_event(ke)
	var hunger_drain: float = h_s0 - p.hunger
	ok = ok and hunger_drain > 0.05 and hunger_drain < 0.08
	p.hunger = 20.0
	p.hp = 20.0
	for i in 3:
		await get_tree().physics_frame
	p.hp = 15.0
	var rp0 := Time.get_ticks_msec()
	var regen_gain := 0.0
	for i in range(300):
		await get_tree().physics_frame
		if p.hp > 15.0:
			regen_gain = p.hp - 15.0
			break
	var regen_ms := Time.get_ticks_msec() - rp0
	ok = ok and regen_gain >= 1.0 and regen_ms >= 1900 and regen_ms <= 2600
	p.hp = 20.0
	p.hunger = 0.0
	var sp0 := Time.get_ticks_msec()
	for i in range(700):
		await get_tree().physics_frame
		if p.hp <= 18.0:
			break
	var starve_ms := Time.get_ticks_msec() - sp0
	var starve_dmg: float = 20.0 - p.hp
	ok = ok and starve_dmg == 2.0 and starve_ms >= 7500 and starve_ms <= 9500
	Debug.set_block(sc.x, sc.y, sc.z, 3)
	var tgtc := Vector3(float(sc.x) + 0.5, float(sc.y) + 0.5, float(sc.z) + 0.5)
	var d: Vector3 = (tgtc - (p.position + Vector3(0.0, p.EYE, 0.0))).normalized()
	p.look(atan2(-d.x, -d.z), asin(clampf(d.y, -1.0, 1.0)))
	for i in 3:
		await get_tree().physics_frame
	var aim_food: bool = p.aim_hit().hit
	Debug.give_item(147, 1)
	p.sel = _slot_of(p, 147)
	var wb := 0
	while wb < 20 and int(p.inv[p.sel]["n"]) <= 0:
		await get_tree().physics_frame
		wb += 1
	p.hp = 10.0
	p.hunger = 10.0
	p.use_selected()
	for i in 3:
		await get_tree().physics_frame
	var eat_cooked := {"hp_gain": p.hp - 10.0, "hunger_gain": p.hunger - 10.0, "left": int(p.inv[p.sel]["n"])}
	Debug.give_item(146, 1)
	p.sel = _slot_of(p, 146)
	wb = 0
	while wb < 20 and int(p.inv[p.sel]["n"]) <= 0:
		await get_tree().physics_frame
		wb += 1
	p.use_selected()
	for i in 3:
		await get_tree().physics_frame
	var eat_raw := {"hp_gain": p.hp - 15.0, "hunger_gain": p.hunger - 15.0, "left": int(p.inv[p.sel]["n"])}
	p.hp = 20.0
	p.hunger = 20.0
	Debug.give_item(147, 1)
	p.sel = _slot_of(p, 147)
	wb = 0
	while wb < 20 and int(p.inv[p.sel]["n"]) <= 0:
		await get_tree().physics_frame
		wb += 1
	var full_left_before: int = int(p.inv[p.sel]["n"])
	p.use_selected()
	for i in 3:
		await get_tree().physics_frame
	var eat_full := {"hp": p.hp, "hunger": p.hunger, "consumed": full_left_before - int(p.inv[p.sel]["n"])}
	ok = ok and aim_food and eat_cooked.hp_gain == 5.0 and eat_cooked.hunger_gain == 5.0 and eat_cooked.left == 0
	ok = ok and eat_raw.hp_gain == 2.0 and eat_raw.hunger_gain == 2.0 and eat_raw.left == 0
	ok = ok and eat_full.hp == 20.0 and eat_full.hunger == 20.0 and eat_full.consumed == 0
	p.armor = [0, 0, 0, 0]
	p.dead = false
	p.hp = 2.0
	p.damage_player(5.0, "t")
	var died: bool = p.dead and p.hp == 0.0
	p.respawn()
	for i in 90:
		if p.is_on_floor():
			break
		await get_tree().physics_frame
	var respawn_ok: bool = not p.dead and p.hp == 20.0 and p.hunger == 20.0 and p.armor == [0, 0, 0, 0] and p.is_on_floor()
	ok = ok and died and respawn_ok
	r = {
		"tool_ratio": roundf(tool_ratio * 100.0) / 100.0,
		"bare_ms": bare_ms,
		"pick_ms": pick_ms,
		"bare_frames": bare_frames,
		"pick_frames": pick_frames,
		"drop_bare": drop_bare,
		"drop_pick": drop_pick,
		"dmg_none": dmg_none,
		"dmg_armor": dmg_armor,
		"hunger_drain": roundf(hunger_drain * 1000.0) / 1000.0,
		"hunger_mine": roundf((h0 - h_end) / 2.0 * 1000.0) / 1000.0,
		"hunger_regen": {"gain": regen_gain, "ms": regen_ms},
		"starve": {"dmg": starve_dmg, "ms": starve_ms},
		"eat": {"cooked": eat_cooked, "raw": eat_raw, "full": eat_full},
		"respawn": respawn_ok,
		"dump": Debug.dump_survival(),
		"ok": ok,
	}
	Debug.result(r)
	get_tree().quit()


func _hunger_toggle_test(spawn: Vector3) -> void:
	var p = Game.player
	for i in 60:
		await get_tree().physics_frame
	var ok := true
	var sx := int(spawn.x)
	var sz := int(spawn.z)
	var ctop: int = world.surface_top(sx, sz)
	var px := -1
	var pz := -1
	for dx in range(-8, 9, 2):
		for dz in range(-8, 9, 2):
			var tx := sx + dx
			var tz := sz + dz
			var flat := true
			for fx in range(-1, 2):
				for fz in range(-1, 2):
					if world.surface_top(tx + fx, tz + fz) != ctop:
						flat = false
			if not flat:
				continue
			var clear := true
			for k in range(1, 5):
				if world.surface_top(tx, tz - k) > ctop:
					clear = false
			if not clear:
				continue
			px = tx
			pz = tz
			break
		if px >= 0:
			break
	if px < 0:
		Debug.result({"error": "no flat hunger spot near spawn"})
		get_tree().quit()
		return
	Debug.teleport(float(px) + 0.5, float(ctop + 1) + 0.05, float(pz) + 0.5)
	for i in 60:
		if p.is_on_floor():
			break
		await get_tree().physics_frame
	if not p.is_on_floor():
		Debug.result({"error": "no floor for hunger test"})
		get_tree().quit()
		return
	var prior := bool(Settings.values["hunger_enabled"])
	var m = Debug.spawn_mob("chicken", float(px) + 2.0, float(ctop) + 1.0, float(pz) + 2.0)
	for i in 10:
		await get_tree().physics_frame
	Settings.set_value("hunger_enabled", false)
	for i in 3:
		await get_tree().physics_frame
	var pin_ok := false
	p.hunger = 5.0
	p.hp = 15.0
	for i in 5:
		await get_tree().physics_frame
		pin_ok = pin_ok or absf(p.hunger - 20.0) < 0.001
	ok = ok and pin_ok
	p._regen_t = 0.0
	var min_hp := 999.0
	var regen_ms := -1
	var t0 := Time.get_ticks_msec()
	var atk_ok := true
	for i in 3:
		p.attack_mob(m)
		atk_ok = atk_ok and absf(p.hunger - 20.0) < 0.001
	ok = ok and atk_ok
	for i in range(300):
		await get_tree().physics_frame
		min_hp = minf(min_hp, p.hp)
		if p.hp > 15.0:
			regen_ms = Time.get_ticks_msec() - t0
			break
	var off_hunger: float = p.hunger
	var off_regen_gain: float = p.hp - 15.0
	ok = ok and absf(off_hunger - 20.0) < 0.001
	ok = ok and min_hp >= 15.0
	ok = ok and off_regen_gain >= 1.0
	ok = ok and regen_ms >= 1900 and regen_ms <= 2700
	Settings.set_value("hunger_enabled", true)
	for i in 3:
		await get_tree().physics_frame
	p.hp = 20.0
	p.hunger = 0.0
	p._starve_t = 0.0
	var s0 := Time.get_ticks_msec()
	for i in range(800):
		await get_tree().physics_frame
		if p.hp < 20.0:
			break
	var st_ms := Time.get_ticks_msec() - s0
	var st_dmg: float = 20.0 - p.hp
	ok = ok and st_dmg == 1.0 and st_ms >= 3900 and st_ms <= 5000
	Settings.set_value("hunger_enabled", prior)
	if m != null and is_instance_valid(m):
		m.queue_free()
	var r := {
		"pin_to_full": pin_ok,
		"off": {"hunger": off_hunger, "min_hp": min_hp, "regen_gain": roundf(off_regen_gain * 100.0) / 100.0, "regen_ms": regen_ms, "attack_cost_zero": atk_ok},
		"on": {"starve_dmg": st_dmg, "starve_ms": st_ms},
		"ok": ok,
	}
	Debug.result(r)
	get_tree().quit()


func _editperf_test(spawn: Vector3) -> void:
	world.recenter(spawn.x, spawn.z, true)
	var pcx := int(floorf(spawn.x / 16.0))
	var pcz := int(floorf(spawn.z / 16.0))
	var awaited := 0
	while awaited < 1200:
		var allm := true
		for key in world.chunks:
			var cc: Node3D = world.chunks[key]
			if absi(cc.cx - pcx) <= world.render_radius and absi(cc.cz - pcz) <= world.render_radius and not cc.mesh_built:
				allm = false
				break
		if allm:
			break
		await get_tree().physics_frame
		awaited += 1
	var sx := int(spawn.x)
	var sz := int(spawn.z)
	var cell := Vector3i(sx, world.surface_top(sx, sz), sz)
	var okc := _breakable(world.get_block(cell.x, cell.y, cell.z))
	if not okc:
		for dx in range(-8, 9, 2):
			if okc:
				break
			for dz in range(-8, 9, 2):
				var t2: int = world.surface_top(sx + dx, sz + dz)
				if _breakable(world.get_block(sx + dx, t2, sz + dz)):
					cell = Vector3i(sx + dx, t2, sz + dz)
					okc = true
					break
	if not okc:
		Debug.result({"error": "no breakable surface cell near spawn"})
		get_tree().quit()
		return
	var edited_id: int = world.get_block(cell.x, cell.y, cell.z)
	var t_edit := Time.get_ticks_msec()
	world.set_block(cell.x, cell.y, cell.z, 0)
	var w2 := 0
	while w2 < 300 and not (world.light_dirty.is_empty() and world.light_pending.is_empty()):
		await get_tree().physics_frame
		w2 += 1
	await get_tree().physics_frame
	Debug.result({
		"cell": [cell.x, cell.y, cell.z],
		"edited_id": edited_id,
		"cell_after": world.get_block(cell.x, cell.y, cell.z),
		"flush_done": world.light_dirty.is_empty() and world.light_pending.is_empty(),
		"flush_frames": world.perf_flush_frames,
		"max_frame_build_ms": world.perf_max_frame_ms,
		"single_build_ms": world.perf_single_build_ms,
		"total_ms": Time.get_ticks_msec() - t_edit,
	})
	get_tree().quit()


# AC-0187 probe (AWECRAFT_LOGIC=editfront, harness-only, never runs in game):
# the real gate. R=50 with the far queue populated in the thousands (the
# recenter enqueues the whole 8253 stream set, so at spawn-3x3 build time
# queue_size sits at ~7710 like the standing load), then BREAK a surface
# cell and separately PLACE one, measuring edit -> first mesh apply of the
# chunk (the hole/appearance visible) via world's handoff timestamp hook.
# Gates: queue_size in the thousands, remesh < 50 ms per case, zero drop
# frames (mesh presence every frame), chunk meshed before and after.
func _editfront_test(spawn: Vector3) -> void:
	var t0 := Time.get_ticks_msec()
	var R := 50
	world.render_radius = R
	world.recenter(spawn.x, spawn.z, true)
	var pcx := int(world.last_pcx)
	var pcz := int(world.last_pcz)
	var wb := 0
	while wb < 3600:
		var allm := true
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var c = world.chunks.get("%d,%d" % [pcx + dx, pcz + dz])
				if c == null or not c.mesh_built:
					allm = false
					break
			if not allm:
				break
		if allm:
			break
		await get_tree().process_frame
		wb += 1
	var rw := 0
	while world._rec_pending and rw < 3600:
		await get_tree().process_frame
		rw += 1
	var T = world.chunks.get("%d,%d" % [pcx, pcz])
	if T == null or not T.mesh_built:
		Debug.result({"ok": false, "error": "player chunk never built"})
		get_tree().quit()
		return
	var sx := int(spawn.x)
	var sz := int(spawn.z)
	var cell := Vector3i(sx, world.surface_top(sx, sz), sz)
	var okc := _breakable(world.get_block(cell.x, cell.y, cell.z))
	if not okc:
		for dx in range(-8, 9, 2):
			if okc:
				break
			for dz in range(-8, 9, 2):
				var t2: int = world.surface_top(sx + dx, sz + dz)
				if _breakable(world.get_block(sx + dx, t2, sz + dz)):
					cell = Vector3i(sx + dx, t2, sz + dz)
					okc = true
					break
	if not okc:
		Debug.result({"ok": false, "error": "no breakable surface cell near spawn"})
		get_tree().quit()
		return
	var tq := 0
	var pkey := "%d,%d" % [pcx, pcz]
	while tq < 2400 and not (world.light_dirty.is_empty() and world.light_pending.is_empty() and not world._tm_inflight_keys.has(pkey)):
		await get_tree().process_frame
		tq += 1
	var q_before := int(world.queue_size)
	var scoped0 := int(world.perf_edit_front_scoped)
	var full0 := int(world.perf_edit_front_full)
	var br := await _editfront_case(T, cell, 0)
	var tw := 0
	while tw < 2400 and not (world.light_dirty.is_empty() and world.light_pending.is_empty() and not world._tm_inflight_keys.has(pkey)):
		await get_tree().process_frame
		tw += 1
	var pl := await _editfront_case(T, cell, 2)
	Debug.result({
		"ok": bool(br["ok"]) and bool(pl["ok"]) and q_before > 1000,
		"R": R,
		"queue_size": q_before,
		"queue_after": int(world.queue_size),
		"tm_cap": int(world.threadmesh_max),
		"inflight_at_break": int(br["inflight"]),
		"scoped": int(world.perf_edit_front_scoped) - scoped0,
		"full": int(world.perf_edit_front_full) - full0,
		"break": br,
		"place": pl,
		"elapsed_ms": Time.get_ticks_msec() - t0,
	})
	get_tree().quit()


func _editfront_case(T: Node3D, cell: Vector3i, new_id: int) -> Dictionary:
	var key := "%d,%d" % [int(T.cx), int(T.cz)]
	var gen0 := int(T.mesh_gen)
	var inflight0 := int(world.threadmesh_inflight.size())
	var drop_frames := 0
	var present_before := _editfront_present(T)
	world._editprobe_key = key
	world._editprobe_ms = -1.0
	world._editprobe_wms = 0
	world._editprobe_kind = ""
	world._editprobe_drop = 0
	var prof: Array = world._prof_ring
	var prof_last: Array = []
	for i in range(prof.size()):
		prof_last.append(prof[i])
		if prof_last.size() >= 8:
			prof_last.pop_front()
	var t0u := Time.get_ticks_usec()
	world._editprobe_t0_usec = t0u
	var sb0 := Time.get_ticks_usec()
	world.set_block(cell.x, cell.y, cell.z, new_id)
	var dispatch_ms := (Time.get_ticks_usec() - sb0) / 1000.0
	var frames := 0
	while frames < 600 and world._editprobe_ms < 0.0:
		await get_tree().process_frame
		frames += 1
		if not _editfront_present(T):
			drop_frames += 1
	var ms := float(world._editprobe_ms)
	world._editprobe_key = ""
	var present_after := _editfront_present(T)
	return {
		"ms": ms,
		"frames": frames,
		"drop_frames": drop_frames,
		"inflight": inflight0,
		"cell": [cell.x, cell.y, cell.z],
		"cell_after": world.get_block(cell.x, cell.y, cell.z),
		"gen_delta": int(T.mesh_gen) - gen0,
		"present_before": present_before,
		"present_after": present_after,
		"dispatch_ms": dispatch_ms,
		"wms": world._editprobe_wms,
		"ph": world._editprobe_ph,
		"dnbs": world._editprobe_dnbs,
		"dstrips": world._editprobe_dstrips,
		"dq": world._editprobe_dq,
		"prof": prof_last,
		"nq": world._editprobe_nq,
		"prime": world._editprobe_prime,
		"done_ms": world._editprobe_done_ms,
		"handoff_ms": int((world._editprobe_handoff_at - t0u) / 1000.0),
		"ns": world._editprobe_ns,
		"phet": world._editprobe_phet,
		"kind": world._editprobe_kind,
		"drops": world._editprobe_drop,
		"ok": ms >= 0.0 and ms < 50.0 and drop_frames == 0 and present_before and present_after and world.get_block(cell.x, cell.y, cell.z) == new_id,
	}


func _editfront_present(T: Node3D) -> bool:
	for s in T.slabs:
		if s.mesh_instance != null and s.mesh_instance.mesh != null:
			return true
		if s.fluid_instance != null and s.fluid_instance.mesh != null:
			return true
		if s.flora_instance != null and s.flora_instance.mesh != null:
			return true
	return false


# AC-0187 black-lines fix probe (AWECRAFT_LOGIC=editmat, harness-only):
# the scoped (edit) build emits opaque faces in PLAIN-atlas UV space, so the
# edited slab's opaque material must sample the PLAIN atlas, not the merged
# one. Builds a stable chunk at small R, breaks a surface block, and reads
# the scoped-rebuilt slab's opaque surface IMMEDIATELY after the scoped
# handoff (before the light wave's full merged-UV rebuild): asserts the
# material's sampled texture IS the plain lit atlas (ChunkScript._lit_atlas_tex)
# and NOT the merged texture (ChunkScript._merge_atlas()["tex"]), and that
# every opaque UV is within [0,1]. Deterministic — no render timing.
func _editmat_test(spawn: Vector3) -> void:
	var t0 := Time.get_ticks_msec()
	var R := 2
	world.render_radius = R
	world.recenter(spawn.x, spawn.z, true)
	var pcx := int(world.last_pcx)
	var pcz := int(world.last_pcz)
	var pkey := "%d,%d" % [pcx, pcz]
	var wb := 0
	var quiet := 0
	while wb < 3600:
		var allm := true
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var c = world.chunks.get("%d,%d" % [pcx + dx, pcz + dz])
				if c == null or not c.mesh_built:
					allm = false
					break
			if not allm:
				break
		var idle: bool = world.light_dirty.is_empty() and world.light_pending.is_empty() and world.threadmesh_inflight.is_empty() and world._col_pending.is_empty()
		if allm and idle:
			quiet += 1
		else:
			quiet = 0
		if quiet >= 5:
			break
		await get_tree().process_frame
		wb += 1
	var T = world.chunks.get(pkey)
	if T == null or not T.mesh_built:
		Debug.result({"ok": false, "error": "player chunk never built"})
		get_tree().quit()
		return
	var sx := int(spawn.x)
	var sz := int(spawn.z)
	var cell := Vector3i(sx, world.surface_top(sx, sz), sz)
	var okc := _breakable(world.get_block(cell.x, cell.y, cell.z))
	if not okc:
		for dx in range(-8, 9, 2):
			if okc:
				break
			for dz in range(-8, 9, 2):
				var t2: int = world.surface_top(sx + dx, sz + dz)
				if _breakable(world.get_block(sx + dx, t2, sz + dz)):
					cell = Vector3i(sx + dx, t2, sz + dz)
					okc = true
					break
	if not okc:
		Debug.result({"ok": false, "error": "no breakable surface cell near spawn"})
		get_tree().quit()
		return
	var r1 := await _editmat_case(T, cell)
	Debug.result({
		"ok": bool(r1.get("ok", false)),
		"mode": "editmat",
		"R": R,
		"cell": [cell.x, cell.y, cell.z],
		"atlas_present": Data.atlas_tex != null,
		"opaque_mat_is_plain": r1.get("opaque_mat_is_plain", false),
		"merged_tex_present": r1.get("merged_tex_present", false),
		"uv_min": r1.get("uv_min", []),
		"uv_max": r1.get("uv_max", []),
		"uv_in_range": r1.get("uv_in_range", false),
		"probe": r1,
		"elapsed_ms": Time.get_ticks_msec() - t0,
	})
	get_tree().quit()


func _editmat_case(T: Node3D, cell: Vector3i) -> Dictionary:
	var key := "%d,%d" % [int(T.cx), int(T.cz)]
	var mesh_before := {}
	for i in range(T.slabs.size()):
		var sb = T.slabs[i]
		if sb.mesh_instance != null and sb.mesh_instance.mesh != null:
			mesh_before[i] = sb.mesh_instance.mesh
	world._editprobe_key = key
	world._editprobe_ms = -1.0
	world._editprobe_kind = ""
	world._editprobe_t0_usec = Time.get_ticks_usec()
	world.set_block(cell.x, cell.y, cell.z, 0)
	var frames := 0
	while frames < 600 and world._editprobe_ms < 0.0:
		await get_tree().process_frame
		frames += 1
	if world._editprobe_ms < 0.0:
		world._editprobe_key = ""
		return {"ok": false, "error": "scoped handoff never landed"}
	var kind: String = world._editprobe_kind
	world._editprobe_key = ""
	var read_si := -1
	var read_mesh = null
	var read_mat = null
	var read_tex = null
	for i in range(T.slabs.size()):
		var sb = T.slabs[i]
		if sb.mesh_instance == null or sb.mesh_instance.mesh == null:
			continue
		var old = mesh_before.get(i, null)
		if sb.mesh_instance.mesh == old:
			continue
		if sb.mesh_instance.mesh.get_surface_count() < 1:
			continue
		read_si = i
		read_mesh = sb.mesh_instance.mesh
		read_mat = read_mesh.surface_get_material(0)
		if read_mat is ShaderMaterial:
			read_tex = read_mat.get_shader_parameter("tex")
		break
	var plain: Texture2D = _ChunkScriptM._lit_atlas_tex()
	var merged: Dictionary = _ChunkScriptM._merge_atlas()
	var merged_tex = merged.get("tex", null)
	var merged_present: bool = merged_tex != null
	var is_plain: bool = read_tex != null and read_tex == plain and (not merged_present or read_tex != merged_tex)
	var uv_min := Vector2(INF, INF)
	var uv_max := Vector2(-INF, -INF)
	var uv_count := 0
	var uv_ok := false
	if read_mesh != null and read_mesh.get_surface_count() > 0:
		var arrs = read_mesh.surface_get_arrays(0)
		var uvs: PackedVector2Array = arrs[Mesh.ARRAY_TEX_UV]
		uv_count = uvs.size()
		for u in uvs:
			uv_min.x = minf(uv_min.x, u.x)
			uv_min.y = minf(uv_min.y, u.y)
			uv_max.x = maxf(uv_max.x, u.x)
			uv_max.y = maxf(uv_max.y, u.y)
		uv_ok = uv_count > 0 and uv_min.x >= 0.0 and uv_min.y >= 0.0 and uv_max.x <= 1.0 and uv_max.y <= 1.0
	return {
		"ok": kind == "edit" and is_plain and uv_ok,
		"kind": kind,
		"frames": frames,
		"read_slab": read_si,
		"opaque_mat_is_plain": is_plain,
		"mat_class": String(read_mat.get_class()) if read_mat != null else "",
		"tex_class": String(read_tex.get_class()) if read_tex != null else "",
		"plain_class": String(plain.get_class()) if plain != null else "",
		"merged_tex_present": merged_present,
		"uv_count": uv_count,
		"uv_min": [uv_min.x, uv_min.y],
		"uv_max": [uv_max.x, uv_max.y],
		"uv_in_range": uv_ok,
		"cell_after": world.get_block(cell.x, cell.y, cell.z),
	}


# AC-0187 black-lines fix render shot (AWECRAFT_LOGIC=editmatshot +
# AWECRAFT_SNAPSHOT, xvfb gl_compatibility only): breaks a surface block near
# spawn, lets the scoped remesh + light wave settle, then snaps a top-down view
# of the edited region to confirm no black lines / wrong texels on the rebuilt
# slab. The scoped-window material identity is the headless editmat gate; this
# is a steady-state visual sanity check of the edited block.
func _editmat_shot(spawn: Vector3) -> void:
	var snapshot_path := OS.get_environment("AWECRAFT_SNAPSHOT")
	var R := 2
	world.render_radius = R
	world.recenter(spawn.x, spawn.z, true)
	var pcx := int(world.last_pcx)
	var pcz := int(world.last_pcz)
	var pkey := "%d,%d" % [pcx, pcz]
	var wb := 0
	var quiet := 0
	while wb < 3600:
		var allm := true
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var c = world.chunks.get("%d,%d" % [pcx + dx, pcz + dz])
				if c == null or not c.mesh_built:
					allm = false
					break
			if not allm:
				break
		var idle: bool = world.light_dirty.is_empty() and world.light_pending.is_empty() and world.threadmesh_inflight.is_empty() and world._col_pending.is_empty()
		if allm and idle:
			quiet += 1
		else:
			quiet = 0
		if quiet >= 5:
			break
		await get_tree().process_frame
		wb += 1
	var sx := int(spawn.x)
	var sz := int(spawn.z)
	var cell := Vector3i(sx, world.surface_top(sx, sz), sz)
	var okc := _breakable(world.get_block(cell.x, cell.y, cell.z))
	if not okc:
		for dx in range(-8, 9, 2):
			if okc:
				break
			for dz in range(-8, 9, 2):
				var t2: int = world.surface_top(sx + dx, sz + dz)
				if _breakable(world.get_block(sx + dx, t2, sz + dz)):
					cell = Vector3i(sx + dx, t2, sz + dz)
					okc = true
					break
	if not okc:
		Debug.result({"ok": false, "error": "no breakable surface cell near spawn"})
		get_tree().quit()
		return
	player = _spawn_player()
	await _await_spawn_floor(spawn, 600)
	Debug.fly(true)
	world.set_block(cell.x, cell.y, cell.z, 0)
	var st := 0
	var squiet := 0
	while st < 600:
		var s_idle: bool = world.light_dirty.is_empty() and world.light_pending.is_empty() and world.threadmesh_inflight.is_empty() and world._col_pending.is_empty()
		if s_idle:
			squiet += 1
		else:
			squiet = 0
		if squiet >= 5:
			break
		await get_tree().process_frame
		st += 1
	var feet_y := float(cell.y) + 7.4
	Debug.teleport(float(cell.x) + 0.5, feet_y, float(cell.z) + 0.5)
	player.look(0.0, -1.55)
	for i in range(15):
		await get_tree().physics_frame
	await Debug.snap(snapshot_path)
	Debug.result({"editmatshot": true, "ok": true, "cell": [cell.x, cell.y, cell.z], "w": int(get_viewport().size.x), "h": int(get_viewport().size.y)})
	get_tree().quit()


# AC-0126 probe (env-gated by AWECRAFT_LOGIC=breakspike, never runs in
# game): the post-break light+mesh frame spike. Pinned cells (seed 44,
# AWECRAFT_RADIUS=6, plan §4 — every edit 3x3 is worker-buildable and
# excludes the spawn chunk):
#   interior: break (-32,31,32), chunk (-2,2), contained light delta = 1
#   edge:     break (-49,31,41), chunk (-4,2), contained light delta = 296
#   coalesce: 5 Grass cells in chunk (1,2), 3 breaks this frame + 2 next
# Flow: recenter -> FULL steady state at r=6 (all in-radius chunks built,
# light/col queues empty; generous wait, no timeout before the break) ->
# scripted break(s) -> per-frame ms window from the break frame until
# SETTLE (light_dirty + light_pending + threadmesh_inflight + _col_pending
# empty AND every edit-set chunk mesh_built AND !any_col_dirty), bounded at
# 600 physics frames -> RESULT with post-settle per-chunk eff-MD5, the
# mesh_info 3x3 subset, the 4 edit counters, flush_done.
func _breakspike_test(spawn: Vector3) -> void:
	var case_name := OS.get_environment("AWECRAFT_BS_CASE")
	var cells: Array = []
	var ecx := 0
	var ecz := 0
	if case_name == "interior":
		cells = [[-32, 31, 32]]
		ecx = -2
		ecz = 2
	elif case_name == "edge":
		cells = [[-49, 31, 41]]
		ecx = -4
		ecz = 2
	elif case_name == "coalesce":
		cells = [[16, 34, 41], [17, 34, 42], [16, 34, 40], [17, 34, 41], [17, 35, 43]]
		ecx = 1
		ecz = 2
	elif case_name == "noop":
		# Diagnostic only: no break — ambient frame cost at steady state.
		pass
	else:
		Debug.result({"error": "unknown AWECRAFT_BS_CASE: %s" % case_name})
		get_tree().quit()
		return
	var edit_keys: Array = []
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			edit_keys.append("%d,%d" % [ecx + dx, ecz + dz])
	var rr: int = world.render_radius
	var rr1: int = rr + 1
	world.recenter(spawn.x, spawn.z, true)
	# Steady state: in-radius fully mesh-built and the queues idle for 5
	# consecutive ticks (drain quiescent). NOTE: the stub ring at rr+1 can
	# NEVER mesh-build (outer orthogonal neighbors don't exist ->
	# _build_ready never true), so a full-footprint wait is unsatisfiable —
	# the ring entries persist as data_only residuals and the drain's idle
	# scan of them is sub-ms at uncapped tick rate.
	# IMPORTANT: the runner passes --fixed-fps 600. Default headless paces
	# ticks at 60 Hz, and a wall-time measurement across `await physics_frame`
	# then includes the pacing period (13-21 ms/frame floor — proven by the
	# empty-SceneTree idle test), making the p95 gates unmeasurable. At an
	# uncapped tick the same await measures true per-frame processing cost.
	# AWECRAFT_BS_QUIESCE=0 skips the 5-tick quiescence (break mid-drain).
	# Wall guard 120 s (tick-rate independent); awaited is a hang guard too.
	var bs_debug := OS.get_environment("AWECRAFT_BS_DEBUG") == "1"
	var bs_quiesce: bool = OS.get_environment("AWECRAFT_BS_QUIESCE") != "0"
	var bs_steady_ms: Array = []
	var quiet := 0
	var st_t0 := Time.get_ticks_msec()
	var awaited := 0
	while awaited < 60000 and Time.get_ticks_msec() - st_t0 < 120000:
		var n_in := 0
		for key in world.chunks:
			var cc: Node3D = world.chunks[key]
			if absi(cc.cx) <= rr and absi(cc.cz) <= rr and cc.mesh_built:
				n_in += 1
		var queues_idle: bool = world.light_dirty.is_empty() and world.light_pending.is_empty() \
			and world.threadmesh_inflight.is_empty() and world._col_pending.is_empty()
		if n_in == (2 * rr + 1) * (2 * rr + 1) and queues_idle:
			quiet += 1
		else:
			quiet = 0
		if quiet >= (5 if bs_quiesce else 1):
			break
		var st_fb := Time.get_ticks_msec()
		await get_tree().physics_frame
		if bs_debug:
			bs_steady_ms.append(Time.get_ticks_msec() - st_fb)
		awaited += 1
	# Scripted break(s). Coalesce: 3 this frame, 2 one frame later (the
	# second batch runs inside the window loop, frame 1).
	var batch2: Array = []
	if case_name == "coalesce":
		for i in 3:
			world.set_block(int(cells[i][0]), int(cells[i][1]), int(cells[i][2]), 0)
		batch2 = [cells[3], cells[4]]
	elif case_name != "noop":
		for cl in cells:
			world.set_block(int(cl[0]), int(cl[1]), int(cl[2]), 0)
	# Per-frame ms window from the break frame until settle (bound 600).
	var frame_ms: Array = []
	var frame_ms_off: Array = []
	var settle_frames := -1
	var frame_n := 0
	var batch2_done := batch2.is_empty()
	var bs_bm := float(world.perf_build_ms)
	var noop_cap := 60 if case_name == "noop" else 600
	while frame_n < noop_cap:
		var fb := Time.get_ticks_msec()
		await get_tree().physics_frame
		var fms := Time.get_ticks_msec() - fb
		frame_ms.append(fms)
		if bs_debug:
			var inkeys: Array = []
			for te in world.threadmesh_inflight:
				inkeys.append(te["key"])
			print("BSF frame=%d ms=%d inflight=%s col_pending=%d light_pending=%d build_ms_delta=%.1f qsize=%d built7=%d" % [
				frame_n + 1, fms, inkeys,
				world._col_pending.size(), world.light_pending.size(),
				float(world.perf_build_ms) - bs_bm, world.queue_size,
				_bs_built_count(7)])
			bs_bm = float(world.perf_build_ms)
		if not batch2_done:
			batch2_done = true
			for cl in batch2:
				world.set_block(int(cl[0]), int(cl[1]), int(cl[2]), 0)
		frame_n += 1
		if case_name == "noop":
			if frame_n == 30:
				# Second pass with world processing OFF: isolates engine
				# pacing from world._process cost (diagnostic).
				world.set_process(false)
			if frame_n > 30:
				frame_ms_off.append(fms)
			continue
		if batch2_done and _breakspike_settled(edit_keys):
			settle_frames = frame_n
			break
	if bs_debug and not bs_steady_ms.is_empty():
		var st_sorted: Array = bs_steady_ms.duplicate()
		st_sorted.sort()
		print("BSSTADY frames=%d p50=%d p95=%d max=%d tail30=%s" % [
			bs_steady_ms.size(), int(_percentile(bs_steady_ms, 0.50)),
			int(_percentile(bs_steady_ms, 0.95)),
			int(bs_steady_ms.max()), bs_steady_ms.slice(-30)])
	# Post-settle identity snapshot: per-chunk eff-MD5 + mesh_info subset.
	var eff_md5: Dictionary = {}
	for key in edit_keys:
		var cc: Node3D = world.chunks.get(key)
		if cc != null and cc.last_eff != null and cc.last_eff.has("arr"):
			eff_md5[key] = _bs_md5(cc.last_eff["arr"])
	var minfo: Dictionary = {}
	for e in world.mesh_info():
		var kx: int = int(int(e["pos"][0]) / 16)
		var kz: int = int(int(e["pos"][1]) / 16)
		var k := "%d,%d" % [kx, kz]
		if edit_keys.has(k):
			minfo[k] = {"v": e.get("verts", []), "f": e.get("fverts", [])}
	var cell_after: Array = []
	for cl in cells:
		cell_after.append(world.get_block(int(cl[0]), int(cl[1]), int(cl[2])))
	Debug.result({
		"case": case_name,
		"seed": Game.world_seed,
		"radius": rr,
		"cells": cells,
		"cell_after": cell_after,
		"steady_waited": awaited,
		"frame_window": {
			"frames": frame_ms.size(),
			"p50": int(_percentile(frame_ms, 0.50)),
			"p95": int(_percentile(frame_ms, 0.95)),
			"max": int(frame_ms.max()) if not frame_ms.is_empty() else 0,
		},
		"frame_window_off": {
			"frames": frame_ms_off.size(),
			"p50": int(_percentile(frame_ms_off, 0.50)) if not frame_ms_off.is_empty() else 0,
			"p95": int(_percentile(frame_ms_off, 0.95)) if not frame_ms_off.is_empty() else 0,
			"max": int(frame_ms_off.max()) if not frame_ms_off.is_empty() else 0,
		},
		"settle_frames": settle_frames,
		"settle_bounded": settle_frames > 0 and settle_frames <= 600,
		"eff_md5": eff_md5,
		"minfo": minfo,
		"counters": {
			"edit_dispatches": world.perf_edit_dispatches,
			"edit_defers": world.perf_edit_defers,
			"edit_syncs": world.perf_edit_syncs,
			"edit_light_passes": world.perf_edit_light_passes,
			"light_self_computes": world.perf_light_self_computes,
		},
		"flush_done": world.light_dirty.is_empty() and world.light_pending.is_empty(),
	})
	get_tree().quit()


func _bs_built_count(ring: int) -> int:
	var n := 0
	for key in world.chunks:
		var cc: Node3D = world.chunks[key]
		if absi(cc.cx) <= ring and absi(cc.cz) <= ring and cc.mesh_built:
			n += 1
	return n


func _breakspike_settled(edit_keys: Array) -> bool:
	if not (world.light_dirty.is_empty() and world.light_pending.is_empty()
			and world.threadmesh_inflight.is_empty() and world._col_pending.is_empty()):
		return false
	for key in edit_keys:
		var cc: Node3D = world.chunks.get(key)
		if cc == null or not cc.mesh_built or cc.any_col_dirty():
			return false
	return true


func _bs_md5(d: PackedByteArray) -> String:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_MD5)
	h.update(d)
	var md5: PackedByteArray = h.finish()
	var hx := ""
	for i in 16:
		hx += "%02x" % md5[i]
	return hx


func _editslab_test(spawn: Vector3) -> void:
	world.recenter(spawn.x, spawn.z, true)
	var pcx := int(floorf(spawn.x / 16.0))
	var pcz := int(floorf(spawn.z / 16.0))
	var awaited := 0
	while awaited < 1200:
		var allm := true
		for key in world.chunks:
			var cc: Node3D = world.chunks[key]
			if absi(cc.cx - pcx) <= world.render_radius and absi(cc.cz - pcz) <= world.render_radius and not cc.mesh_built:
				allm = false
				break
		if allm:
			break
		await get_tree().physics_frame
		awaited += 1
	var ec = world.chunks.get("%d,%d" % [pcx, pcz])
	for i in 5:
		ec.perf_slab_body_builds[i] = 0
		ec.perf_slab_body_ms[i] = 0.0
	var sx := int(spawn.x)
	var sz := int(spawn.z)
	var edits: Array = []
	var t0 := Time.get_ticks_msec()
	for y in range(14, 19):
		world.set_block(sx + 2, y, sz + 2, 3)
	world.set_block(sx + 2, 15, sz + 2, 0)
	edits.append(await _editslab_flush(ec, 15, t0, [sx + 2, 15, sz + 2]))
	t0 = Time.get_ticks_msec()
	world.set_block(sx + 3, 24, sz + 3, 3)
	world.set_block(sx + 3, 24, sz + 3, 0)
	edits.append(await _editslab_flush(ec, 24, t0, [sx + 3, 24, sz + 3]))
	t0 = Time.get_ticks_msec()
	for y in range(30, 35):
		world.set_block(sx + 4, y, sz + 4, 3)
	world.set_block(sx + 4, 32, sz + 4, 0)
	edits.append(await _editslab_flush(ec, 32, t0, [sx + 4, 32, sz + 4]))
	var expected: Array = [[0, 1], [1], [1, 2]]
	var ok := true
	for i in range(3):
		if edits[i]["slabs_touched"] != expected[i] or int(edits[i]["total_ms"]) > 241 or int(edits[i]["cell_after"]) != 0:
			ok = false
	var finfo := ""
	for e in world.mesh_info():
		if e.pos == [int(ec.position.x), int(ec.position.z)]:
			finfo = JSON.stringify(e)
			break
	Debug.result({
		"mode": "editslab",
		"ok": bool(ok),
		"pre_total_ms": 241,
		"edits": edits,
		"mesh_built": bool(ec.mesh_built),
		"final_minfo": finfo,
	})
	get_tree().quit()


func _editslab_flush(c: Node3D, y: int, t0: int, cell: Array) -> Dictionary:
	var w2 := 0
	while w2 < 300 and not (world.light_dirty.is_empty() and world.light_pending.is_empty()):
		await get_tree().physics_frame
		w2 += 1
	await get_tree().physics_frame
	var touched: Array = []
	var col_ms := 0.0
	for i in 5:
		if int(c.perf_slab_body_builds[i]) > 0:
			touched.append(i)
		col_ms += float(c.perf_slab_body_ms[i])
		c.perf_slab_body_builds[i] = 0
		c.perf_slab_body_ms[i] = 0.0
	return {
		"y": y,
		"slabs_touched": touched,
		"col_ms": roundf(col_ms * 10.0) / 10.0,
		"total_ms": int(Time.get_ticks_msec() - t0),
		"cell_after": int(world.get_block(int(cell[0]), int(cell[1]), int(cell[2]))),
		"mesh_built": bool(c.mesh_built),
	}


func _find_aim_spot() -> Dictionary:
	var sp: Vector3 = world.spawn_point()
	var sx := int(sp.x)
	var sz := int(sp.z)
	var top: int = world.surface_top(sx, sz)
	var candidates: Array[Vector3i] = []
	if _breakable(world.get_block(sx, top, sz)):
		candidates.append(Vector3i(sx, top, sz))
	for dx in range(-8, 9, 2):
		for dz in range(-8, 9, 2):
			var t2: int = world.surface_top(sx + dx, sz + dz)
			if _breakable(world.get_block(sx + dx, t2, sz + dz)):
				candidates.append(Vector3i(sx + dx, t2, sz + dz))
	var dz_list := [2, 3, -2, -3, 4, -4, 5, -5]
	for tc in candidates:
		var tcenter := Vector3(float(tc.x) + 0.5, float(tc.y) + 0.5, float(tc.z) + 0.5)
		for dz in dz_list:
			for dh in range(0, 12):
				var cam := Vector3(float(tc.x) + 0.5, float(tc.y) + 0.5 + float(dh), float(tc.z) + 0.5 + float(dz))
				var dir := (tcenter - cam).normalized()
				var hit = VoxelMath.raycast_blocks(cam, dir, 6.0, world.get_block)
				if not hit.hit or hit.cell != tc:
					continue
				var feet := cam - Vector3(0.0, 1.62, 0.0)
				if not _clear_feet(feet):
					continue
				var yaw := atan2(-dir.x, -dir.z)
				var pitch := asin(clampf(dir.y, -1.0, 1.0))
				if absf(pitch) > 1.55:
					continue
				return {"cell": tc, "id": world.get_block(tc.x, tc.y, tc.z), "cam": cam, "yaw": yaw, "pitch": pitch}
	return {}


func _find_water_cell(spawn: Vector3) -> Dictionary:
	var sx := int(spawn.x)
	var sz := int(spawn.z)
	for r in range(0, 64, 4):
		for dx in range(-r, r + 1, 4):
			for dz in range(-r, r + 1, 4):
				var x := sx + dx
				var z := sz + dz
				var th: int = WorldGen.terrain_height(x, z, Game.world_seed)
				if th < 0 or th >= Data.SEA - 1:
					continue
				for y in range(Data.SEA - 1, maxi(th, 0) - 1, -1):
					if world.fluid_level(x, y, z) > 0 or world.get_block(x, y, z) == 5:
						return {"cell": Vector3i(x, y, z)}
	return {}


func _find_shore_aim() -> Dictionary:
	var sp: Vector3 = world.spawn_point()
	var sx := int(sp.x)
	var sz := int(sp.z)
	var cands: Array = []
	for dx in range(-48, 49, 2):
		for dz in range(-48, 49, 2):
			var x := sx + dx
			var z := sz + dz
			var th: int = WorldGen.terrain_height(x, z, Game.world_seed)
			if th < Data.SEA or th > Data.SEA + 5:
				continue
			var ocean := Vector2i.ZERO
			for od in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				if WorldGen.terrain_height(x + od.x * 8, z + od.y * 8, Game.world_seed) < Data.SEA:
					ocean = od
					break
			if ocean == Vector2i.ZERO:
				continue
			cands.append({"x": x, "z": z, "ocean": ocean, "d": absi(dx) + absi(dz)})
	cands.sort_custom(func(a, b): return int(a["d"]) < int(b["d"]))
	if cands.is_empty():
		return {}
	for cand in cands:
		var x: int = int(cand["x"])
		var z: int = int(cand["z"])
		var oc: Vector2i = cand["ocean"]
		var t: int = world.surface_top(x, z)
		if world.get_block(x, t + 1, z) != 0:
			continue
		var cell := Vector3i(x, t + 1, z)
		var ground := cell - Vector3i(0, 1, 0)
		var gcenter := Vector3(float(ground.x) + 0.5, float(ground.y) + 0.5, float(ground.z) + 0.5)
		for bd2 in [4.0, 5.0, 6.0]:
			for up in [4.0, 5.0, 6.0]:
				var eye := gcenter + Vector3(-float(oc.x) * bd2, up, -float(oc.y) * bd2)
				if not _clear_feet(eye - Vector3(0.0, 1.62, 0.0)):
					continue
				var ax := -0.3 * float(oc.x)
				var az := -0.3 * float(oc.y)
				var ap := Vector3(gcenter.x + ax, float(ground.y) + 1.0, gcenter.z + az)
				var dir := (ap - eye).normalized()
				var t_hit := (eye.y - (float(ground.y) + 1.0)) / absf(dir.y)
				if t_hit > 5.5:
					continue
				var hit = VoxelMath.raycast_cell(eye, dir, 14.0, world.get_block, true)
				if not hit.hit or hit.cell != ground or hit.normal != Vector3i(0, 1, 0):
					continue
				var yaw := atan2(-dir.x, -dir.z)
				var pitch := asin(clampf(dir.y, -1.0, 1.0))
				if absf(pitch) > 1.55:
					continue
				if int(hit.id) == 5 or int(hit.id) == 24:
					continue
				return {"cell": cell, "cam": eye, "yaw": yaw, "pitch": pitch}
	return {}


func _breakable(id: int) -> bool:
	var info = Data.block(id)
	return info != null and info.solid and float(info.get("hard", 1e9)) < 1e8


func _clear_feet(feet: Vector3) -> bool:
	for oy in [0.0, 0.95, 1.79]:
		var x := int(floorf(feet.x))
		var y := int(floorf(feet.y + oy))
		var z := int(floorf(feet.z))
		if y < 0 or y >= Data.HEIGHT:
			continue
		var info = Data.block(world.get_block(x, y, z))
		if info != null and info.solid:
			return false
	return true


func _swing_test() -> void:
	var p = Game.player
	for i in 6:
		await get_tree().physics_frame
	var r := {}
	var ok := true
	Debug.give_item(6, 1)
	p.sel = _slot_of(p, 6)
	for i in 4:
		await get_tree().physics_frame
	r["box_visible"] = p.held_box.visible
	r["fist_when_item"] = p.held_fist.visible
	ok = ok and r["box_visible"] and not r["fist_when_item"]
	p.start_mine()
	var saw_mid := false
	var mid_frac := 0.0
	var swing_max_rot := 0.0
	var swing_min_rot := INF
	var settled := false
	for i in range(60):
		await get_tree().physics_frame
		var f: float = p.swing_frac()
		var pr: Vector3 = p.hand_pose_rot()
		var rotmag := Vector2(pr.x, pr.z).length()
		swing_max_rot = maxf(swing_max_rot, rotmag)
		swing_min_rot = minf(swing_min_rot, rotmag)
		if f > 0.3 and f < 0.95:
			saw_mid = true
			mid_frac = f
		if not p.swing_active():
			settled = p.hand_pose_rot().length() < 0.05
			break
	r["saw_mid_swing"] = saw_mid
	r["mid_frac"] = roundf(mid_frac * 100.0) / 100.0
	r["swing_max_rot"] = roundf(swing_max_rot * 1000.0) / 1000.0
	r["swing_min_rot"] = roundf(swing_min_rot * 1000.0) / 1000.0
	r["settled"] = settled
	ok = ok and saw_mid and settled and swing_max_rot > 0.4
	for i in 4:
		await get_tree().physics_frame
	for i in p.inv.size():
		p.inv[i] = {"id": 0, "n": 0}
	p.sel = 0
	for i in 4:
		await get_tree().physics_frame
	r["fist_empty_hand"] = p.held_fist.visible
	ok = ok and r["fist_empty_hand"]
	p.start_swing()
	var punch_max_rot := 0.0
	var punch_settled := false
	for i in range(40):
		await get_tree().physics_frame
		var pr2: Vector3 = p.hand_pose_rot()
		var rotmag2 := Vector2(pr2.x, pr2.z).length()
		if rotmag2 > punch_max_rot:
			punch_max_rot = rotmag2
		if not p.swing_active():
			punch_settled = p.hand_pose_rot().length() < 0.05
			break
	r["punch_max_rot"] = roundf(punch_max_rot * 1000.0) / 1000.0
	r["punch_settled"] = punch_settled
	r["punch_done"] = not p.swing_active()
	ok = ok and punch_max_rot > 0.3 and punch_settled and r["punch_done"]
	Debug.give_item(6, 1)
	p.sel = _slot_of(p, 6)
	for i in 4:
		await get_tree().physics_frame
	p.start_mine()
	p._lmb_down = true
	var t0 := Time.get_ticks_msec()
	var cycles := 0
	var in_high := false
	var loop_max_off := 0.0
	var held_stayed_active := true
	while Time.get_ticks_msec() - t0 < 900:
		await get_tree().physics_frame
		if not p.swing_active():
			held_stayed_active = false
		var f2: float = p.swing_frac()
		var pr3: Vector3 = p.hand_pose_rot()
		var rotmag3 := Vector2(pr3.x, pr3.z).length()
		if rotmag3 > loop_max_off:
			loop_max_off = rotmag3
		if f2 > 0.5:
			in_high = true
		elif in_high and f2 < 0.25:
			cycles += 1
			in_high = false
	p._lmb_down = false
	var settle_ok := false
	for i in 16:
		await get_tree().physics_frame
		if not p.swing_active() and p.hand_pose_rot().length() < 0.05:
			settle_ok = true
			break
	r["loop_cycles_0.9s"] = cycles
	r["loop_max_rot"] = roundf(loop_max_off * 1000.0) / 1000.0
	r["loop_held_stayed_active"] = held_stayed_active
	r["loop_settles_on_release"] = settle_ok
	ok = ok and cycles >= 3 and cycles <= 5 and held_stayed_active and settle_ok and loop_max_off > 0.4
	var toolork := {}
	var expected_type := {111: "pick", 115: "axe", 119: "shovel", 123: "sword", 113: "pick"}
	for tid in expected_type:
		Debug.give_item(tid, 1)
		p.sel = _slot_of(p, tid)
		for i in 6:
			await get_tree().physics_frame
		var present: bool = p.held_tool != null and p.held_tool.visible
		var vtype: String = String(p.held_tool_type)
		var fist: bool = p.held_fist.visible
		var sprite: bool = p.held_sprite.visible
		var box: bool = p.held_box.visible
		toolork[tid] = present and vtype == expected_type[tid] and not fist and not sprite and not box
		r["tool_%d" % tid] = {"present": present, "type": vtype, "fist": fist, "sprite": sprite, "box": box, "ok": bool(toolork[tid])}
		if tid == 111 or tid == 113:
			r["headcolor_%d" % tid] = p.held_head_color().to_html()
	ok = ok and (toolork as Dictionary).size() == 5
	for tid in toolork:
		ok = ok and bool(toolork[tid])
	r["tier_differs_111_vs_113"] = r.get("headcolor_111") != r.get("headcolor_113")
	ok = ok and bool(r["tier_differs_111_vs_113"])
	Debug.give_item(6, 1)
	p.sel = _slot_of(p, 6)
	for i in 6:
		await get_tree().physics_frame
	r["box_after_tool"] = p.held_box.visible
	r["tool_hidden_after_block"] = p.held_tool.visible
	ok = ok and r["box_after_tool"] and not r["tool_hidden_after_block"]
	for i in p.inv.size():
		p.inv[i] = {"id": 0, "n": 0}
	p.sel = 0
	for i in 6:
		await get_tree().physics_frame
	r["fist_after_empty"] = p.held_fist.visible
	r["tool_hidden_empty"] = p.held_tool.visible
	ok = ok and r["fist_after_empty"] and not r["tool_hidden_empty"]
	var pad_top := _build_walk_pad(world.spawn_point(), 10)
	Debug.teleport(8.5, pad_top, 8.5)
	for i in 24:
		await get_tree().physics_frame
	var w_p0: Vector3 = p.position
	Input.action_press("move_forward")
	var w_ymin := INF
	var w_ymax := -INF
	var w_xmin := INF
	var w_xmax := -INF
	var w_cross := 0
	var w_prev := 0.0
	var w_bobs0: float = p.sway_bobs()
	var w_hvmax := 0.0
	for i in 120:
		await get_tree().physics_frame
		var wo: Vector3 = p.hand_pose_offset()
		w_hvmax = maxf(w_hvmax, Vector2(p.velocity.x, p.velocity.z).length())
		w_ymin = minf(w_ymin, wo.y)
		w_ymax = maxf(w_ymax, wo.y)
		w_xmin = minf(w_xmin, wo.x)
		w_xmax = maxf(w_xmax, wo.x)
		if (w_prev > 0.0 and wo.y <= 0.0) or (w_prev < 0.0 and wo.y >= 0.0):
			w_cross += 1
		w_prev = wo.y
	var w_p1: Vector3 = p.position
	Input.action_release("move_forward")
	var w_bobs: float = p.sway_bobs() - w_bobs0
	var w_idle := 0.0
	var w_idle_early := 0.0
	for i in 180:
		await get_tree().physics_frame
		var wi: Vector3 = p.hand_pose_offset()
		if i < 60:
			w_idle_early = maxf(w_idle_early, wi.length())
		else:
			w_idle = maxf(w_idle, wi.length())
	r["walk_idle_early_max"] = roundf(w_idle_early * 10000.0) / 10000.0
	r["walk_bobs"] = roundf(w_bobs * 100.0) / 100.0
	r["walk_dist"] = roundf(w_p1.distance_to(w_p0) * 100.0) / 100.0
	r["walk_hv_max"] = roundf(w_hvmax * 100.0) / 100.0
	r["walk_y_min"] = roundf(w_ymin * 10000.0) / 10000.0
	r["walk_y_max"] = roundf(w_ymax * 10000.0) / 10000.0
	r["walk_x_min"] = roundf(w_xmin * 10000.0) / 10000.0
	r["walk_x_max"] = roundf(w_xmax * 10000.0) / 10000.0
	r["walk_y_crossings"] = w_cross
	r["walk_idle_max_off"] = roundf(w_idle * 100000.0) / 100000.0
	ok = ok and w_bobs > 4.0 and w_bobs < 10.0
	ok = ok and absf(w_bobs * 2.0 - float(w_cross)) <= 2.5
	ok = ok and w_ymax > 0.004 and w_ymin < -0.004
	ok = ok and w_idle < 1e-4
	Debug.result({"ok": ok, "data": r})
	get_tree().quit()


func _count_item(p, id: int) -> int:
	var c := 0
	for it in p.inv:
		if int(it["id"]) == id:
			c += int(it["n"])
	return c


func _slot_of(p, id: int) -> int:
	for i in p.inv.size():
		if int(p.inv[i]["id"]) == id:
			return i
	return 0


func _logic_check() -> Dictionary:
	var spawn: Vector3 = world.spawn_point()
	var sx := int(spawn.x)
	var sz := int(spawn.z)
	var sy := int(spawn.y)
	var top_at_spawn := 0
	for y in range(sy + 2, -1, -1):
		var b = world.get_block(sx, y, sz)
		if b != 0:
			top_at_spawn = b
			break
	var bedrock = world.get_block(sx, 0, sz)
	var ocean := false
	for i in range(256):
		var ox := -64 + (i % 16) * 8
		var oz := -64 + (i / 16) * 8
		if WorldGen.terrain_height(ox, oz, Game.world_seed) < Data.SEA:
			ocean = world.get_block(ox, Data.SEA, oz) == WorldGen.B_WATER
			break
	var stone_at_depth := -1
	for i in range(64):
		var ox := 8 + (i % 8) * 4
		var oz := 8 + (i / 8) * 4
		var oy := 12 + (i % 5) * 2
		if world.get_block(ox, oy, oz) == WorldGen.B_STONE:
			stone_at_depth = oy
			break
	var biomes := {}
	for bx in range(-400, 401, 40):
		for bz in range(-400, 401, 40):
			biomes[WorldGen.biome_at(bx, bz, Game.world_seed)] = true
	return {
		"spawn_h": spawn.y,
		"top_at_spawn": top_at_spawn,
		"y0_bedrock": bedrock,
		"ocean_water_at_sea": ocean,
		"stone_at_depth": stone_at_depth,
		"biome_count": biomes.size(),
		"biomes": biomes.keys(),
	}


func _light_test(spawn: Vector3) -> void:
	var sx := int(spawn.x)
	var sz := int(spawn.z)
	var top: int = world.surface_top(sx, sz)

	var surface_eff := -1
	for dx in range(-6, 7, 3):
		for dz in range(-6, 7, 3):
			var t: int = world.surface_top(sx + dx, sz + dz)
			var cell := Vector3i(sx + dx, t + 1, sz + dz)
			if world.get_block(cell.x, cell.y, cell.z) != 0:
				continue
			var l: Dictionary = world.light_at(cell.x, cell.y, cell.z)
			if int(l.eff) >= 15:
				surface_eff = int(l.eff)
				break
		if surface_eff >= 0:
			break

	var lavas: Array[Vector3i] = []
	for lx in range(sx - 36, sx + 37):
		for lz in range(sz - 36, sz + 37):
			for ly in range(0, 8):
				if world.get_block(lx, ly, lz) == WorldGen.B_LAVA:
					lavas.append(Vector3i(lx, ly, lz))

	var cave_eff := -1
	var torch_eff := -1
	var far_before := -1
	var far_after := -1
	var depth := 6
	while depth < 30 and cave_eff < 0:
		var cy: int = top - depth
		if cy >= 5:
			for dx in range(-16, 17):
				if cave_eff >= 0:
					break
				for dz in range(-16, 17):
					var cx := sx + dx
					var cz := sz + dz
					if world.get_block(cx, cy, cz) != 0:
						continue
					if not _is_solid(cx, cy + 1, cz):
						continue
					if cy < 23:
						var farx := cx + 5
						var clear := true
						for lav in lavas:
							if absi(lav.x - cx) + absi(lav.y - cy) + absi(lav.z - cz) < 15 \
									or absi(lav.x - farx) + absi(lav.y - cy) + absi(lav.z - cz) < 15:
								clear = false
								break
						if not clear:
							continue
					var pocket := Vector3i(cx, cy, cz)
					var far := pocket + Vector3i(5, 0, 0)
					for i in range(1, 6):
						var c := pocket + Vector3i(i, 0, 0)
						if world.get_block(c.x, c.y, c.z) != 0:
							world.set_block(c.x, c.y, c.z, 0)
					var lb: Dictionary = world.light_at(far.x, far.y, far.z)
					if int(lb.eff) > 5:
						continue
					var l0: Dictionary = world.light_at(pocket.x, pocket.y, pocket.z)
					cave_eff = int(l0.eff)
					far_before = int(lb.eff)
					world.set_block(pocket.x, pocket.y, pocket.z, 22)
					var lt: Dictionary = world.light_at(pocket.x, pocket.y, pocket.z)
					var la: Dictionary = world.light_at(far.x, far.y, far.z)
					torch_eff = int(lt.eff)
					far_after = int(la.eff)
					break
		depth += 1

	Debug.result({
		"surface_eff": surface_eff,
		"cave_eff": cave_eff,
		"torch_level": torch_eff,
		"torch_far_before": far_before,
		"torch_far_after": far_after,
	})


# AC-0207: the STRIPS losslessness probe (the #1 gate for the C++ strips
# port, gdext/src/strips.cpp). Per chunk: the GDScript strip kernels
# (world._side_eff_strip / _side_blk_strip / _corner_eff_strip — the
# harness reference the game no longer calls, AC-0208) vs
# AweStrips.compute_strips (C++) on IDENTICAL inputs: same slab arrays,
# same last_eff rows, and the SAME memoized face strips (captured once per
# side via world._face_of and fed to both sides). Gate: 100% exact — eff x8
# + blk x4 + blk_b x4 strips byte-identical per chunk. Also A/Bs the FACE
# compute (AweStrips.compute_face vs world._compute_face_blk_gd on the same
# captured neighbor faces — both pure), reports the per-dispatch + per-side
# _side_blk_strip before/after wall (the 74 ms * 4 idle-hitch gate), and the
# settled idle-frame window (the 60 fps gate). If a face-cache state change
# lands between the GDScript reference and the C++ call (a build landing
# mid-probe), the chunk retries once, then is counted state_changed (never
# a false mismatch).
func _stripsprobe_test(spawn: Vector3) -> void:
	var t0 := Time.get_ticks_msec()
	var NENV := OS.get_environment("AWECRAFT_STRIPSPROBE_N")
	var N := int(NENV) if NENV != "" else 32
	N = clampi(N, 1, 128)
	world.fluid_sim_enabled = false
	world.collision_enabled = false
	world.render_radius = 4
	world.recenter(spawn.x, spawn.z, true)
	# Wait until N mesh-built chunks (the r4 band set drains well inside the
	# cap; a timeout still probes whatever is ready), then let the E2 re-
	# light wave settle so the face-cache state is stable during compares.
	var waited := 0
	var built := 0
	while built < N and waited < 3600:
		built = 0
		for key in world.chunks:
			var c = world.chunks.get(key)
			if c != null and not c.data.is_empty() and c.mesh_built:
				built += 1
		if built >= N:
			break
		await get_tree().physics_frame
		waited += 1
	var lp_waited := 0
	while not world.light_pending.is_empty() and lp_waited < 1800:
		await get_tree().physics_frame
		lp_waited += 1
	# Deterministic sample: ready chunks ordered by (cz, cx).
	var samples: Array = []
	for key in world.chunks:
		var c = world.chunks.get(key)
		if c != null and not c.data.is_empty() and c.mesh_built:
			samples.append(c)
	samples.sort_custom(func(a, b): return int(a.cz) * 1024 + int(a.cx) < int(b.cz) * 1024 + int(b.cx))
	samples.resize(mini(samples.size(), N))
	var sc: Variant = world._strips_cpp_inst()
	var cpp: bool = sc != null
	Lighting._tables()
	var h: int = Data.HEIGHT
	var SIDES: Array = [[1, 0], [-1, 0], [0, 1], [0, -1]]
	var CORNERS: Array = [[1, 1], [-1, 1], [1, -1], [-1, -1]]
	var match_chunks := 0
	var eff_match := 0
	var blk_match := 0
	var blkb_match := 0
	var state_changed := 0
	var face_chunks := 0
	var face_compared := 0
	var gd_wall_us := 0
	var cpp_wall_us := 0
	var gd_side_us := 0
	var cpp_side_us := 0
	var sides_timed := 0
	var mismatch: Array = []
	for c in samples:
		var cx: int = int(c.cx)
		var cz: int = int(c.cz)
		var chunk_ok := false
		var strips_ok := false
		for attempt in range(2):
			# Capture the memoized neighbor face strips ONCE (fed to the C++
			# side; the GDScript reference pulls the same memo internally).
			var faces0: Array = []
			for s in SIDES:
				var nc = world.chunks.get(world._key(cx + int(s[0]), cz + int(s[1])))
				var f: PackedByteArray = PackedByteArray()
				if nc != null and not nc.data.is_empty():
					f = world._face_of(nc, world._shared_face(int(s[0]), int(s[1])))
				faces0.append(f)
			# The GDScript reference (the pre-port path, toggle-independent).
			# Per-attempt deltas are committed to the totals ONLY on success
			# (a state-changed retry is discarded, never counted).
			var at_gd_wall := 0
			var at_gd_side := 0
			var at_n_sides := 0
			var t1 := Time.get_ticks_usec()
			var g_effs: Array = []
			var g_blks: Array = []
			var g_blks_b: Array = []
			for si in range(4):
				var s: Array = SIDES[si]
				var nc = world.chunks.get(world._key(cx + int(s[0]), cz + int(s[1])))
				var e := PackedByteArray()
				var b := PackedByteArray()
				if nc != null and not nc.data.is_empty() and not nc.last_eff.is_empty():
					e = world._side_eff_strip(nc, int(s[0]), int(s[1]), h)
					var t2 := Time.get_ticks_usec()
					var sb: Dictionary = world._side_blk_strip(nc, int(s[0]), int(s[1]), h)
					at_gd_side += Time.get_ticks_usec() - t2
					at_n_sides += 1
					b = sb["v"]
					g_blks_b.append(sb["b"])
				else:
					g_blks_b.append(PackedByteArray())
				g_effs.append(e)
				g_blks.append(b)
			for s in CORNERS:
				var nc = world.chunks.get(world._key(cx + int(s[0]), cz + int(s[1])))
				var e := PackedByteArray()
				if nc != null and not nc.data.is_empty() and not nc.last_eff.is_empty():
					e = world._corner_eff_strip(nc, int(s[0]), int(s[1]), h)
				g_effs.append(e)
			at_gd_wall += Time.get_ticks_usec() - t1
			# State check: a landing between the capture and now invalidates
			# the face memo -> retry (never a false mismatch).
			var changed := false
			for si in range(4):
				var nc = world.chunks.get(world._key(cx + int(SIDES[si][0]), cz + int(SIDES[si][1])))
				var f2: PackedByteArray = PackedByteArray()
				if nc != null and not nc.data.is_empty():
					f2 = world._face_of(nc, world._shared_face(int(SIDES[si][0]), int(SIDES[si][1])))
				if f2 != faces0[si]:
					changed = true
			if changed:
				continue
			gd_wall_us += at_gd_wall
			gd_side_us += at_gd_side
			sides_timed += at_n_sides
			# The C++ side — IDENTICAL inputs (same slabs, eff rows, faces).
			var at_cpp_wall := 0
			var at_cpp_side := 0
			var sides: Array = []
			for si in range(4):
				var s: Array = SIDES[si]
				var nc = world.chunks.get(world._key(cx + int(s[0]), cz + int(s[1])))
				var sd: Dictionary = {"data": [], "eff": PackedByteArray(), "face": PackedByteArray(), "have": false}
				if nc != null and not nc.data.is_empty() and not nc.last_eff.is_empty():
					sd["data"] = nc.data
					sd["eff"] = nc.last_eff["arr"]
					sd["face"] = faces0[si]
					sd["have"] = true
					var t3 := Time.get_ticks_usec()
					sc.side_blk_v(nc.data, nc.last_eff["arr"], int(s[0]), int(s[1]), h, Lighting._att, Lighting._glow)
					at_cpp_side += Time.get_ticks_usec() - t3
				sides.append(sd)
			var corners: Array = []
			for s in CORNERS:
				var nc = world.chunks.get(world._key(cx + int(s[0]), cz + int(s[1])))
				var cd: Dictionary = {"eff": PackedByteArray(), "have": false}
				if nc != null and not nc.data.is_empty() and not nc.last_eff.is_empty():
					cd["eff"] = nc.last_eff["arr"]
					cd["have"] = true
				corners.append(cd)
			var t4 := Time.get_ticks_usec()
			var cr: Dictionary = sc.compute_strips(sides, corners, h, Lighting._att, Lighting._glow)
			at_cpp_wall += Time.get_ticks_usec() - t4
			cpp_wall_us += at_cpp_wall
			cpp_side_us += at_cpp_side
			# Byte-identical compare: eff x8 + blk x4 + blk_b x4.
			var ceffs: Array = cr["eff"]
			var cblks: Array = cr["blk"]
			var cblksb: Array = cr["blk_b"]
			var e_ok := true
			var b_ok := true
			var bb_ok := true
			for i in range(8):
				if PackedByteArray(g_effs[i]) != PackedByteArray(ceffs[i]):
					e_ok = false
			for i in range(4):
				if PackedByteArray(g_blks[i]) != PackedByteArray(cblks[i]):
					b_ok = false
				if PackedByteArray(g_blks_b[i]) != PackedByteArray(cblksb[i]):
					bb_ok = false
			if e_ok:
				eff_match += 1
			if b_ok:
				blk_match += 1
			if bb_ok:
				blkb_match += 1
			if e_ok and b_ok and bb_ok:
				match_chunks += 1
				strips_ok = true
			else:
				if mismatch.size() < 8:
					mismatch.append({"cx": cx, "cz": cz, "eff_ok": e_ok, "blk_ok": b_ok, "blkb_ok": bb_ok})
			chunk_ok = true
			break
		if not chunk_ok:
			state_changed += 1
		# The FACE compute A/B (both pure — no race): AweStrips.compute_face
		# vs world._compute_face_blk_gd on the SAME captured neighbor faces.
		if cpp:
			var nstrips: Array = []
			for s in [[1, 0], [-1, 0], [0, 1], [0, -1]]:
				var nc = world.chunks.get(world._key(cx + int(s[0]), cz + int(s[1])))
				var f: PackedByteArray = PackedByteArray()
				if nc != null and not nc.data.is_empty():
					f = world._face_of(nc, world._shared_face(int(s[0]), int(s[1])))
				nstrips.append(f)
			var gfaces: Array = world._compute_face_blk_gd(c, h, nstrips)
			var cfaces: Array = sc.compute_face(c.data, h, Lighting._att, Lighting._glow, nstrips[0], nstrips[1], nstrips[2], nstrips[3])["faces"]
			var f_ok := true
			for i in range(4):
				if PackedByteArray(gfaces[i]) != PackedByteArray(cfaces[i]):
					f_ok = false
					if mismatch.size() < 12:
						mismatch.append({"cx": cx, "cz": cz, "face_i": i, "gd_sz": PackedByteArray(gfaces[i]).size(), "cpp_sz": PackedByteArray(cfaces[i]).size()})
			face_compared += 1
			if f_ok:
				face_chunks += 1
	# The settled idle-frame window (the 60 fps gate): drain the remaining
	# in-range builds + re-light wave, then sample 300 physics frames.
	var settle_waited := 0
	while settle_waited < 1800:
		var all_built := true
		for key in world.chunks:
			var c = world.chunks.get(key)
			if c != null and int(c.band) <= 2 and not c.mesh_built:
				all_built = false
				break
		if all_built and world.light_pending.is_empty():
			break
		await get_tree().physics_frame
		settle_waited += 1
	var idle_frames: Array = []
	var last_t := Time.get_ticks_usec()
	for i in range(300):
		await get_tree().physics_frame
		var nt := Time.get_ticks_usec()
		idle_frames.append(nt - last_t)
		last_t = nt
	idle_frames.sort()
	var n_samples := samples.size()
	var compared := n_samples - state_changed
	var match_rate: float = float(match_chunks) / float(compared) if compared > 0 else 0.0
	var face_rate: float = float(face_chunks) / float(face_compared) if face_compared > 0 else 0.0
	Debug.result({
		"ok": cpp and n_samples >= 8 and compared >= 8 and match_rate >= 1.0 and face_rate >= 1.0,
		"cpp": cpp,
		"n_chunks": n_samples,
		"compared": compared,
		"match_chunks": match_chunks,
		"match_rate": match_rate,
		"eff_match": eff_match,
		"blk_match": blk_match,
		"blkb_match": blkb_match,
		"state_changed": state_changed,
		"face_compared": face_compared,
		"face_match": face_chunks,
		"face_rate": face_rate,
		"strips_compared": compared * 16,
		"gd_dispatch_ms": round(float(gd_wall_us) / 1000.0 / float(maxi(n_samples, 1)) * 1000.0) / 1000.0,
		"cpp_dispatch_ms": round(float(cpp_wall_us) / 1000.0 / float(maxi(n_samples, 1)) * 1000.0) / 1000.0,
		"gd_side_ms": round(float(gd_side_us) / 1000.0 / float(maxi(sides_timed, 1)) * 1000.0) / 1000.0,
		"cpp_side_ms": round(float(cpp_side_us) / 1000.0 / float(maxi(sides_timed, 1)) * 1000.0) / 1000.0,
		"speedup": round(float(gd_side_us) / float(cpp_side_us)) if cpp_side_us > 0 else 0.0,
		"idle_frames": idle_frames.size(),
		"idle_p50_ms": int(idle_frames[int(idle_frames.size() * 0.50)]) if not idle_frames.is_empty() else 0,
		"idle_p95_ms": int(idle_frames[int(idle_frames.size() * 0.95)]) if not idle_frames.is_empty() else 0,
		"idle_max_ms": int(idle_frames.back()) if not idle_frames.is_empty() else 0,
		"mismatch": mismatch,
		"wall_ms": Time.get_ticks_msec() - t0,
	})


# AC-0189: C++ lighting (gdext/src/lighting.cpp) LOSSLESS probe. Samples N
# built chunks; for each, runs the GDScript pull kernel AND the C++ pull
# kernel on the SAME inputs (the chunk's slabs, fresh strips, the chunk's
# own top, the pre-warmed _att/_glow tables) and compares eff / mask /
# ring / blk_src byte-for-byte. Also reports per-path flood p50/p95/max
# (GDScript timing enabled directly; the C++ side records in the native
# class) — the speedup gate's before/after. RESULT: match rate (gate =
# 1.0, i.e. 100% exact at every cell), per-field match counts, max diff,
# first mismatches, per-path wall ms, both flood stat blocks.
# AC-0210: the GD side calls _pull_kernel_gd DIRECTLY (the public entry now
# dispatches to C++ — the pull wiring — so it would no longer be a
# GDScript reference).
func _lightprobe_test(spawn: Vector3) -> void:
	var t0 := Time.get_ticks_msec()
	var NENV := OS.get_environment("AWECRAFT_LIGHTPROBE_N")
	var N := int(NENV) if NENV != "" else 32
	N = clampi(N, 1, 128)
	world.fluid_sim_enabled = false
	world.collision_enabled = false
	world.render_radius = 4
	world.recenter(spawn.x, spawn.z, true)
	# Wait until N chunks with data + mesh built (the r4 band set drains
	# well inside the cap; a timeout still probes whatever is ready).
	var waited := 0
	var built := 0
	while built < N and waited < 3600:
		built = 0
		for key in world.chunks:
			var c = world.chunks.get(key)
			if c != null and not c.data.is_empty() and c.mesh_built:
				built += 1
		if built >= N:
			break
		await get_tree().physics_frame
		waited += 1
	# Deterministic sample: ready chunks ordered by (cz, cx).
	var samples: Array = []
	for key in world.chunks:
		var c = world.chunks.get(key)
		if c != null and not c.data.is_empty() and c.mesh_built:
			samples.append(c)
	samples.sort_custom(func(a, b): return int(a.cz) * 1024 + int(a.cx) < int(b.cz) * 1024 + int(b.cx))
	samples.resize(mini(samples.size(), N))
	var lc: Variant = Lighting.light_cpp()
	var cpp: bool = lc != null
	# Reset both flood histograms so the numbers below cover exactly the
	# probe's calls (the build before this may have filled them).
	# AC-0210: pin the _flood_probe latch too (first _flood_flat call
	# re-reads the env — with the C++ pull wired in, that first call now
	# happens inside the probe and would silently kill the GD histogram).
	Lighting._flood_on_done = true
	Lighting._flood_on = true
	Lighting.flood_stats()
	if cpp:
		lc.reset_flood_stats()
	var h: int = Data.HEIGHT
	var gd_wall_us := 0
	var cpp_wall_us := 0
	var match_chunks := 0
	var arr_match := 0
	var mask_match := 0
	var ring_match := 0
	var src_match := 0
	var max_diff := 0
	var mismatch: Array = []
	for c in samples:
		var cx: int = int(c.cx)
		var cz: int = int(c.cz)
		var top: int = int(c.top)
		var st: Dictionary = world._strips_for(cx, cz)
		var tt := Time.get_ticks_usec()
		# AC-0210: the GD side must be the GDScript kernel DIRECTLY — the
		# public compute_light_flat_chunk_pull entry now dispatches to C++
		# (the pull wiring), so calling it here would compare C++ vs C++.
		var gd: Dictionary = Lighting._pull_kernel_gd(c.data, cx, cz, h, st["eff"], st["blk"], st["blk_b"], top)
		gd_wall_us += Time.get_ticks_usec() - tt
		if not cpp:
			continue
		tt = Time.get_ticks_usec()
		var cm: Dictionary = lc.compute_chunk_pull(c.data, cx, cz, h, st["eff"], st["blk"], st["blk_b"], top, Lighting._att, Lighting._glow)
		cpp_wall_us += Time.get_ticks_usec() - tt
		var a_ok: bool = (PackedByteArray(gd["arr"]) == PackedByteArray(cm["arr"]))
		var m_ok: bool = (PackedByteArray(gd["mask"]) == PackedByteArray(cm["mask"]))
		var r_ok: bool = (PackedInt32Array(gd["ring"]) == PackedInt32Array(cm["ring"]))
		var s_ok: bool = (bool(gd["blk_src"]) == bool(cm["blk_src"]))
		if a_ok:
			arr_match += 1
		if m_ok:
			mask_match += 1
		if r_ok:
			ring_match += 1
		if s_ok:
			src_match += 1
		if a_ok and m_ok and r_ok and s_ok:
			match_chunks += 1
		# Diagnostics: first mismatches per field + the max eff diff.
		if not a_ok:
			var ga: PackedByteArray = gd["arr"]
			var ca: PackedByteArray = cm["arr"]
			for i in range(ga.size()):
				var df := absi(int(ga[i]) - int(ca[i]))
				if df > max_diff:
					max_diff = df
				if df > 0 and mismatch.size() < 4:
					mismatch.append({"cx": cx, "cz": cz, "field": "arr", "i": i, "gd": int(ga[i]), "cpp": int(ca[i])})
		if not m_ok:
			var gm: PackedByteArray = gd["mask"]
			var cm2: PackedByteArray = cm["mask"]
			for i in range(gm.size()):
				if gm[i] != cm2[i] and mismatch.size() < 8:
					mismatch.append({"cx": cx, "cz": cz, "field": "mask", "i": i, "gd": int(gm[i]), "cpp": int(cm2[i])})
		if not r_ok and mismatch.size() < 8:
			mismatch.append({"cx": cx, "cz": cz, "field": "ring", "i": -1, "gd": (gd["ring"] as PackedInt32Array).size(), "cpp": (cm["ring"] as PackedInt32Array).size()})
		if not s_ok and mismatch.size() < 8:
			mismatch.append({"cx": cx, "cz": cz, "field": "blk_src", "i": -1, "gd": int(gd["blk_src"]), "cpp": int(cm["blk_src"])})
	var gd_flood: Dictionary = Lighting.flood_stats()
	Lighting._flood_on = false
	var cpp_flood: Dictionary = {"n": 0}
	if cpp:
		cpp_flood = lc.flood_stats()
	var n_samples := samples.size()
	var match_rate: float = float(match_chunks) / float(n_samples) if n_samples > 0 else 0.0
	Debug.result({
		"ok": cpp and n_samples >= 8 and match_rate >= 1.0,
		"cpp": cpp,
		"n_chunks": n_samples,
		"match_chunks": match_chunks,
		"match_rate": match_rate,
		"arr_match": arr_match,
		"mask_match": mask_match,
		"ring_match": ring_match,
		"blk_src_match": src_match,
		"cells_compared": n_samples * 256 * h,
		"max_diff": max_diff,
		"mismatch": mismatch,
		"gd_wall_ms": round(gd_wall_us / 1000.0 * 1000.0) / 1000.0,
		"cpp_wall_ms": round(cpp_wall_us / 1000.0 * 1000.0) / 1000.0,
		"gd_flood": gd_flood,
		"cpp_flood": cpp_flood,
		"wall_ms": Time.get_ticks_msec() - t0,
	})


# AC-0210: the PULL wiring probe. For N built chunks, runs the WIRED entry
# Lighting.compute_light_flat_chunk_pull (the AC-0210 dispatch: C++
# AweLighting.compute_chunk_pull whenever the library registered the class,
# GDScript otherwise) AND the GDScript reference Lighting._pull_kernel_gd on
# the SAME inputs, comparing eff / mask / ring / blk_src byte-for-byte.
# Two call forms per chunk: the build_mesh form (top = -1, full height —
# exactly what the chunk-border-crossing hitch path runs) and the
# top-clamped form (top = the chunk's own top). Also reports both paths'
# flood p50/p95/max (GD histogram via Lighting._flood_on, C++ via the native
# class) — the 20 ms -> 1 ms gate's before/after. RESULT: match rate (gate =
# 1.0, 100% exact at every cell of every variant), variant/chunk match
# counts, max diff, first mismatches, per-path wall ms, both flood blocks.
func _pullprobe_test(spawn: Vector3) -> void:
	var t0 := Time.get_ticks_msec()
	var NENV := OS.get_environment("AWECRAFT_PULLPROBE_N")
	var N := int(NENV) if NENV != "" else 32
	N = clampi(N, 1, 128)
	world.fluid_sim_enabled = false
	world.collision_enabled = false
	world.render_radius = 4
	world.recenter(spawn.x, spawn.z, true)
	# Wait until N chunks with data + mesh built (the r4 band set drains
	# well inside the cap; a timeout still probes whatever is ready).
	var waited := 0
	var built := 0
	while built < N and waited < 3600:
		built = 0
		for key in world.chunks:
			var c = world.chunks.get(key)
			if c != null and not c.data.is_empty() and c.mesh_built:
				built += 1
		if built >= N:
			break
		await get_tree().physics_frame
		waited += 1
	# Deterministic sample: ready chunks ordered by (cz, cx).
	var samples: Array = []
	for key in world.chunks:
		var c = world.chunks.get(key)
		if c != null and not c.data.is_empty() and c.mesh_built:
			samples.append(c)
	samples.sort_custom(func(a, b): return int(a.cz) * 1024 + int(a.cx) < int(b.cz) * 1024 + int(b.cx))
	samples.resize(mini(samples.size(), N))
	var lc: Variant = Lighting.light_cpp()
	var cpp: bool = lc != null
	# Reset both flood histograms so the numbers below cover exactly the
	# probe's calls (the build before this may have filled them).
	# AC-0210: pin the _flood_probe latch too — _flood_flat re-reads the
	# AWECRAFT_FLOODMS env on its FIRST call (overwriting _flood_on), and
	# with the C++ pull wired in that first call now happens INSIDE the
	# probe, which would silently kill the GD histogram.
	Lighting._flood_on_done = true
	Lighting._flood_on = true
	Lighting.flood_stats()
	if cpp:
		lc.reset_flood_stats()
	var h: int = Data.HEIGHT
	var gd_wall_us := 0
	var cpp_wall_us := 0
	var match_chunks := 0
	var variant_matches := 0
	var variants := 0
	var max_diff := 0
	var mismatch: Array = []
	for c in samples:
		var cx: int = int(c.cx)
		var cz: int = int(c.cz)
		var st: Dictionary = world._strips_for(cx, cz)
		var chunk_ok := true
		for tv in [-1, int(c.top)]: # build_mesh form + top-clamped form
			var top: int = int(tv)
			variants += 1
			var tt := Time.get_ticks_usec()
			var gd: Dictionary = Lighting._pull_kernel_gd(c.data, cx, cz, h, st["eff"], st["blk"], st["blk_b"], top)
			gd_wall_us += Time.get_ticks_usec() - tt
			var wr: Dictionary = gd
			if cpp:
				tt = Time.get_ticks_usec()
				wr = Lighting.compute_light_flat_chunk_pull(c.data, cx, cz, h, st["eff"], st["blk"], st["blk_b"], top)
				cpp_wall_us += Time.get_ticks_usec() - tt
			var a_ok: bool = (PackedByteArray(gd["arr"]) == PackedByteArray(wr["arr"]))
			var m_ok: bool = (PackedByteArray(gd["mask"]) == PackedByteArray(wr["mask"]))
			var r_ok: bool = (PackedInt32Array(gd["ring"]) == PackedInt32Array(wr["ring"]))
			var s_ok: bool = (bool(gd["blk_src"]) == bool(wr["blk_src"]))
			if a_ok and m_ok and r_ok and s_ok:
				variant_matches += 1
			else:
				chunk_ok = false
			# Diagnostics: first mismatches per field + the max eff diff.
			if not a_ok:
				var ga: PackedByteArray = gd["arr"]
				var wa: PackedByteArray = wr["arr"]
				for i in range(ga.size()):
					var df := absi(int(ga[i]) - int(wa[i]))
					if df > max_diff:
						max_diff = df
					if df > 0 and mismatch.size() < 4:
						mismatch.append({"cx": cx, "cz": cz, "top": top, "field": "arr", "i": i, "gd": int(ga[i]), "cpp": int(wa[i])})
			if not m_ok:
				var gm: PackedByteArray = gd["mask"]
				var wm: PackedByteArray = wr["mask"]
				for i in range(gm.size()):
					if gm[i] != wm[i] and mismatch.size() < 8:
						mismatch.append({"cx": cx, "cz": cz, "top": top, "field": "mask", "i": i, "gd": int(gm[i]), "cpp": int(wm[i])})
			if not r_ok and mismatch.size() < 8:
				mismatch.append({"cx": cx, "cz": cz, "top": top, "field": "ring", "i": -1, "gd": (gd["ring"] as PackedInt32Array).size(), "cpp": (wr["ring"] as PackedInt32Array).size()})
			if not s_ok and mismatch.size() < 8:
				mismatch.append({"cx": cx, "cz": cz, "top": top, "field": "blk_src", "i": -1, "gd": int(gd["blk_src"]), "cpp": int(wr["blk_src"])})
		if chunk_ok:
			match_chunks += 1
	var gd_flood: Dictionary = Lighting.flood_stats()
	Lighting._flood_on = false
	var cpp_flood: Dictionary = {"n": 0}
	if cpp:
		cpp_flood = lc.flood_stats()
	var n_samples := samples.size()
	var match_rate: float = float(variant_matches) / float(variants) if variants > 0 else 0.0
	Debug.result({
		"ok": cpp and n_samples >= 8 and match_rate >= 1.0,
		"cpp": cpp,
		"n_chunks": n_samples,
		"variants": variants,
		"variant_matches": variant_matches,
		"match_chunks": match_chunks,
		"match_rate": match_rate,
		"cells_compared": variants * 256 * h,
		"max_diff": max_diff,
		"mismatch": mismatch,
		"gd_wall_ms": round(gd_wall_us / 1000.0 * 1000.0) / 1000.0,
		"cpp_wall_ms": round(cpp_wall_us / 1000.0 * 1000.0) / 1000.0,
		"gd_flood": gd_flood,
		"cpp_flood": cpp_flood,
		"wall_ms": Time.get_ticks_msec() - t0,
	})


# AC-0190: the MESH losslessness probe (#1 gate for the C++ mesh port).
# AC-0208: the GDScript ChunkScript.build_accs was REMOVED — the arm now
# proves the DISPATCH INVARIANT per chunk: AweMesh.build_accs (C++,
# gdext/src/mesh.cpp) over FULL-slab nbs (the legacy deep-copy shape) vs
# the SAME C++ build_accs over the compact snap_rings nbs (the shape the
# dispatch actually hands the worker) on IDENTICAL inputs — fresh slab
# copies both sides, the SAME nbs/ctx/ms, and eff = {} (both builds
# recompute light through the shared C++ pull kernel, so the light compare
# also covers the mesh's self-light path). Gate: 100% exact q/v/n/c/u/i on
# every acc of every sampled chunk + identical light arr/mask/ring/blk_src
# + identical vertex totals (the MINFO invariant — the applied mesh is the
# trimmed q quads). The comparison honors the _surface() trim contract: q
# must match, then the FIRST 4*q verts (v/n/c/u) and 6*q indices. Field
# names (verts_gd/verts_cpp, gres/cres) keep the AC-0190 schema; both
# sides are C++ now.
func _meshprobe_test(spawn: Vector3) -> void:
	var t0 := Time.get_ticks_msec()
	var NENV := OS.get_environment("AWECRAFT_MESHPROBE_N")
	var N := int(NENV) if NENV != "" else 32
	N = clampi(N, 1, 128)
	world.fluid_sim_enabled = false
	world.collision_enabled = false
	world.render_radius = 4
	world.recenter(spawn.x, spawn.z, true)
	# Wait until N mesh-built chunks (deterministic seed 44 default).
	var waited := 0
	var built := 0
	while built < N and waited < 3600:
		built = 0
		for key in world.chunks:
			var c = world.chunks.get(key)
			if c != null and not c.data.is_empty() and c.mesh_built:
				built += 1
		if built >= N:
			break
		await get_tree().physics_frame
		waited += 1
	var samples: Array = []
	for key in world.chunks:
		var c = world.chunks.get(key)
		if c != null and not c.data.is_empty() and c.mesh_built:
			samples.append(c)
	samples.sort_custom(func(a, b): return int(a.cz) * 1024 + int(a.cx) < int(b.cz) * 1024 + int(b.cx))
	samples.resize(mini(samples.size(), N))
	var mc: Variant = _ChunkScriptM.mesh_cpp()
	var cpp: bool = mc != null
	var match_chunks := 0
	var q_match := 0
	var v_match := 0
	var n_match := 0
	var c_match := 0
	var u_match := 0
	var i_match := 0
	var accs_compared := 0
	var arr_match := 0
	var mask_match := 0
	var ring_match := 0
	var src_match := 0
	var verts_gd := 0
	var verts_cpp := 0
	var gd_wall_us := 0
	var cpp_wall_us := 0
	var gd_wms_sum := 0
	var cpp_wms_sum := 0
	var skipped := 0
	var mismatch: Array = []
	# AC-0211: the surrounding-step checks (full-nbs vs compact-ring build —
	# the dispatch invariant, slab_copy parity, rows_eq verdicts) + the
	# dispatch nbs cost (us, GDScript deep-copy path vs C++ ring path).
	# AC-0208: the sync_snap-vs-_build_snap sub-check was removed with the
	# GDScript _build_snap (sync snap is C++-only now).
	var compact_ok := 0
	var slabcopy_ok := 0
	var rowsok := 0
	var nbs_gd_us := 0
	var nbs_cpp_us := 0
	for c in samples:
		var cx: int = int(c.cx)
		var cz: int = int(c.cz)
		# Reconstruct the EXACT dispatch inputs (world.gd
		# _mesh_dispatch_impl: 4 diagonal nbs, ctx + strips + top + band-2
		# coarse, ms rects). AC-0208: the GDScript build_accs reference is
		# GONE — the arm now proves the DISPATCH INVARIANT: the C++
		# build_accs over FULL-slab nbs (the legacy deep-copy shape, gres)
		# must equal the C++ build_accs over the compact snap_rings nbs
		# (the shape the dispatch actually hands the worker, cres). Field
		# names (verts_gd/verts_cpp, gres/cres) keep the original schema;
		# both sides are C++ now.
		# AC-0211: time the GDScript nbs construction (the dispatch cost
		# the C++ compact ring replaces — _slabs_deepcopy is the utility
		# that survived AC-0208 for the save path).
		var tcn0 := Time.get_ticks_usec()
		var nbs: Dictionary = {}
		var nb_ok := true
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				if (dx == 0) == (dz == 0):
					continue
				var nc = world.chunks.get(world._key(cx + dx, cz + dz))
				if nc == null or nc.data.is_empty():
					nb_ok = false
					break
				nbs["%d,%d" % [dx, dz]] = {"d": ChunkIO._slabs_deepcopy(nc.data), "f": ChunkIO._slabs_deepcopy(nc.fl)}
			if not nb_ok:
				break
		nbs_gd_us += Time.get_ticks_usec() - tcn0
		if not nb_ok:
			skipped += 1
			continue
		var st: Dictionary = world._strips_for(cx, cz)
		var ctx_w: Dictionary = world._tm_ctx.duplicate()
		ctx_w["eff_strips"] = st["eff"]
		ctx_w["blk_strips"] = st["blk"]
		ctx_w["blk_strips_b"] = st["blk_b"]
		ctx_w["top"] = int(c.top)
		if int(c.band) == 2:
			ctx_w["coarse"] = true
			ctx_w["uv_scale"] = 2
		var ms_w: Dictionary
		if not world._tm_ms_full.rects.is_empty():
			ms_w = {"rects": world._tm_ms_full.rects.duplicate(), "h": float(world._tm_ms_full.get("h", 0.0))}
		else:
			ms_w = {"rects": {}}
		var tt := Time.get_ticks_usec()
		var gres: Dictionary = mc.build_accs(ChunkIO._slabs_deepcopy(c.data), ChunkIO._slabs_deepcopy(c.fl), cx, cz, nbs, ctx_w, ms_w, {}, 0, -1, 0, Lighting._att, Lighting._glow)
		gd_wall_us += Time.get_ticks_usec() - tt
		if not cpp:
			continue
		# AC-0211 sub-check (1): the compact snap-ring nbs — the SAME C++
		# build_accs over the ring shape must produce the identical result
		# (cres = the compact-ring C++ build).
		var tcn1 := Time.get_ticks_usec()
		var cnbs: Dictionary = {}
		for ddx in range(-1, 2):
			for ddz in range(-1, 2):
				if (ddx == 0) == (ddz == 0):
					continue
				var ncc = world.chunks.get(world._key(cx + ddx, cz + ddz))
				if ncc == null or ncc.data.is_empty():
					continue
				cnbs["%d,%d" % [ddx, ddz]] = mc.snap_rings(ncc.data, ncc.fl, ddx, ddz)
		var _cd = mc.slab_copy(c.data)
		var _cf = mc.slab_copy(c.fl)
		nbs_cpp_us += Time.get_ticks_usec() - tcn1
		tt = Time.get_ticks_usec()
		var cres: Dictionary = mc.build_accs(_cd, _cf, cx, cz, cnbs, ctx_w, ms_w, {}, 0, -1, 0, Lighting._att, Lighting._glow)
		cpp_wall_us += Time.get_ticks_usec() - tt
		gd_wms_sum += int(gres.get("wms", 0))
		cpp_wms_sum += int(cres.get("wms", 0))
		var chunk_ok: bool = true
		var gs: Array = gres["slabs"]
		var cs: Array = cres["slabs"]
		if int(gs.size()) != int(cs.size()):
			chunk_ok = false
			if mismatch.size() < 12:
				mismatch.append({"cx": cx, "cz": cz, "field": "slab_count", "gd": int(gs.size()), "cpp": int(cs.size())})
		else:
			for si in range(int(gs.size())):
				var grow: Array = gs[si]
				var csl: Array = cs[si]
				if bool(grow[6]) != bool(csl[6]):
					chunk_ok = false
					if mismatch.size() < 12:
						mismatch.append({"cx": cx, "cz": cz, "slab": si, "field": "full_solid", "gd": bool(grow[6]), "cpp": bool(csl[6])})
				for a in range(6):
					var gm: Dictionary = grow[a]
					var cm: Dictionary = csl[a]
					var m: Dictionary = _acc_cmp(gm, cm)
					accs_compared += 1
					if m["q"]:
						q_match += 1
					if m["v"]:
						v_match += 1
					if m["n"]:
						n_match += 1
					if m["c"]:
						c_match += 1
					if m["u"]:
						u_match += 1
					if m["i"]:
						i_match += 1
					verts_gd += int(gm["q"]) * 4
					verts_cpp += int(cm["q"]) * 4
					if not (bool(m["q"]) and bool(m["v"]) and bool(m["n"]) and bool(m["c"]) and bool(m["u"]) and bool(m["i"])):
						chunk_ok = false
						if mismatch.size() < 12:
							mismatch.append({
								"cx": cx, "cz": cz, "slab": si, "acc": a,
								"fields": m, "q_gd": int(gm["q"]), "q_cpp": int(cm["q"]),
								"diag_v": _acc_diag(gm, cm, "v", 3, 4) if not bool(m["v"]) else null,
								"diag_u": _acc_diag(gm, cm, "u", 2, 4) if not bool(m["u"]) else null,
								"diag_c": _acc_diag(gm, cm, "c", 4, 4) if not bool(m["c"]) else null,
								"diag_n": _acc_diag(gm, cm, "n", 3, 4) if not bool(m["n"]) else null,
								"diag_i": _acc_diag(gm, cm, "i", 1, 6) if not bool(m["i"]) else null,
							})
		# Light (both builds self-light through the shared C++ pull kernel).
		var gld: Dictionary = gres["light"]
		var cld: Dictionary = cres["light"]
		var la_ok: bool = (PackedByteArray(gld.get("arr", PackedByteArray())) == PackedByteArray(cld.get("arr", PackedByteArray())))
		var lm_ok: bool = (PackedByteArray(gld.get("mask", PackedByteArray())) == PackedByteArray(cld.get("mask", PackedByteArray())))
		var lr_ok: bool = (PackedInt32Array(gld.get("ring", PackedInt32Array())) == PackedInt32Array(cld.get("ring", PackedInt32Array())))
		var ls_ok: bool = (bool(gld.get("blk_src", false)) == bool(cld.get("blk_src", false)))
		if la_ok:
			arr_match += 1
		if lm_ok:
			mask_match += 1
		if lr_ok:
			ring_match += 1
		if ls_ok:
			src_match += 1
		if not (la_ok and lm_ok and lr_ok and ls_ok):
			chunk_ok = false
			if mismatch.size() < 12:
				mismatch.append({"cx": cx, "cz": cz, "field": "light", "arr": la_ok, "mask": lm_ok, "ring": lr_ok, "blk_src": ls_ok})
		# AC-0211: the surrounding-step gates (C++ lane).
		if cpp:
			# (1) full-nbs vs compact-ring build — the dispatch invariant
			# (the main compare above is the SAME pair, detailed per-acc).
			if _ac0211_res_eq(gres["slabs"], cres["slabs"]) and _ac0211_light_eq(gres["light"], cres["light"]):
				compact_ok += 1
			elif mismatch.size() < 12:
				mismatch.append({"cx": cx, "cz": cz, "field": "compact_ring", "slabs": _ac0211_res_eq(gres["slabs"], cres["slabs"]), "light": _ac0211_light_eq(gres["light"], cres["light"])})
			# (2) slab_copy parity (the dispatch's own-column value-copy).
			if _ac0211_slabcopy_eq(ChunkIO._slabs_deepcopy(c.data), _cd) and _ac0211_slabcopy_eq(ChunkIO._slabs_deepcopy(c.fl), _cf):
				slabcopy_ok += 1
			elif mismatch.size() < 12:
				mismatch.append({"cx": cx, "cz": cz, "field": "slab_copy"})
			# (3) rows_eq verdicts vs the GDScript row loop (the scoped
			# handoff stale check) — over the first non-null slab window.
			var s0 := -1
			for kk in range(c.data.size()):
				if c.data[kk] != null:
					s0 = kk
					break
			if s0 < 0:
				s0 = 0
			var ylo := s0 * 16
			var yhi := s0 * 16 + 15
			var modc: Array = ChunkIO._slabs_deepcopy(c.data)
			modc[s0] = null
			var cpp_eq_true: bool = mc.rows_eq(c.data, c.data, ylo, yhi)
			var cpp_eq_false: bool = mc.rows_eq(c.data, modc, ylo, yhi)
			var gd_eq_true := true
			var y3 := ylo
			while y3 <= yhi and gd_eq_true:
				gd_eq_true = c.row_bytes(y3) == _ChunkScriptM._slabs_row(c.data, y3)
				y3 += 1
			var gd_eq_false := true
			y3 = ylo
			while y3 <= yhi and gd_eq_false:
				gd_eq_false = c.row_bytes(y3) == _ChunkScriptM._slabs_row(modc, y3)
				y3 += 1
			if cpp_eq_true == gd_eq_true and cpp_eq_false == gd_eq_false and cpp_eq_true == true and cpp_eq_false == false:
				rowsok += 1
			elif mismatch.size() < 12:
				mismatch.append({"cx": cx, "cz": cz, "field": "rows_eq", "cpp_t": cpp_eq_true, "gd_t": gd_eq_true, "cpp_f": cpp_eq_false, "gd_f": gd_eq_false})
			# (4) AC-0208: the sync_snap-vs-_build_snap sub-check was
			# REMOVED — _build_snap (the GDScript sync snap fill) is gone
			# with the build_accs fallback; sync snap is C++-only now (the
			# nofallback arm covers the no-GDScript invariant).
		if chunk_ok:
			match_chunks += 1
	var n_samples := int(samples.size()) - skipped
	var match_rate: float = float(match_chunks) / float(n_samples) if n_samples > 0 else 0.0
	# AC-0211: the surrounding-step gates are part of ok (C++ lane).
	var ac0211_ok: bool = (not cpp) or (n_samples > 0 and compact_ok == n_samples and slabcopy_ok == n_samples and rowsok == n_samples)
	Debug.result({
		"ok": cpp and n_samples >= 8 and match_rate >= 1.0 and verts_gd == verts_cpp and verts_gd > 0 and ac0211_ok,
		"ac0211_ok": ac0211_ok,
		"compact_ok": compact_ok,
		"slabcopy_ok": slabcopy_ok,
		"rowsok": rowsok,
		"nbs_gd_us": nbs_gd_us,
		"nbs_cpp_us": nbs_cpp_us,
		"cpp": cpp,
		"n_samples": n_samples,
		"skipped": skipped,
		"match_chunks": match_chunks,
		"match_rate": match_rate,
		"accs_compared": accs_compared,
		"q_match": q_match,
		"v_match": v_match,
		"n_match": n_match,
		"c_match": c_match,
		"u_match": u_match,
		"i_match": i_match,
		"arr_match": arr_match,
		"mask_match": mask_match,
		"ring_match": ring_match,
		"blk_src_match": src_match,
		"verts_gd": verts_gd,
		"verts_cpp": verts_cpp,
		"gd_wms_avg": round(float(gd_wms_sum) / float(maxi(n_samples, 1)) * 1000.0) / 1000.0,
		"cpp_wms_avg": round(float(cpp_wms_sum) / float(maxi(n_samples, 1)) * 1000.0) / 1000.0,
		"gd_wall_ms": round(gd_wall_us / 1000.0 * 1000.0) / 1000.0,
		"cpp_wall_ms": round(cpp_wall_us / 1000.0 * 1000.0) / 1000.0,
		"mismatch": mismatch,
		"wall_ms": Time.get_ticks_msec() - t0,
	})


# AC-0211: surrounding-step compare helpers (the meshprobe arm).
# Two build_accs result slab sets are equal iff every slab row's 6 accs
# (trimmed q/v/n/c/u/i) + full_solid flag match (the worker contract).
func _ac0211_res_eq(s1: Array, s2: Array) -> bool:
	if int(s1.size()) != int(s2.size()):
		return false
	for si in range(int(s1.size())):
		var r1: Array = s1[si]
		var r2: Array = s2[si]
		if bool(r1[6]) != bool(r2[6]):
			return false
		for a in range(6):
			var d1: Dictionary = r1[a]
			var d2: Dictionary = r2[a]
			if int(d1["q"]) != int(d2["q"]):
				return false
			if PackedVector3Array(d1["v"]) != PackedVector3Array(d2["v"]):
				return false
			if PackedVector3Array(d1["n"]) != PackedVector3Array(d2["n"]):
				return false
			if PackedColorArray(d1["c"]) != PackedColorArray(d2["c"]):
				return false
			if PackedVector2Array(d1["u"]) != PackedVector2Array(d2["u"]):
				return false
			if PackedInt32Array(d1["i"]) != PackedInt32Array(d2["i"]):
				return false
	return true


func _ac0211_light_eq(l1: Dictionary, l2: Dictionary) -> bool:
	if PackedByteArray(l1.get("arr", PackedByteArray())) != PackedByteArray(l2.get("arr", PackedByteArray())):
		return false
	if PackedByteArray(l1.get("mask", PackedByteArray())) != PackedByteArray(l2.get("mask", PackedByteArray())):
		return false
	if PackedInt32Array(l1.get("ring", PackedInt32Array())) != PackedInt32Array(l2.get("ring", PackedInt32Array())):
		return false
	if bool(l1.get("blk_src", false)) != bool(l2.get("blk_src", false)):
		return false
	return true


# Two paletted slab arrays are equal iff every slab's n/b/nz + p + i match
# (null == null). The slab_copy parity check.
func _ac0211_slabcopy_eq(a: Array, b: Array) -> bool:
	if int(a.size()) != int(b.size()):
		return false
	for k in range(int(a.size())):
		var va = a[k]
		var vb = b[k]
		if va == null or vb == null:
			if va != vb:
				return false
			continue
		var da: Dictionary = va
		var db: Dictionary = vb
		if int(da["n"]) != int(db["n"]) or int(da["b"]) != int(db["b"]) or int(da["nz"]) != int(db["nz"]):
			return false
		if PackedByteArray(da["p"]) != PackedByteArray(db["p"]):
			return false
		if PackedByteArray(da["i"]) != PackedByteArray(db["i"]):
			return false
	return true


# AC-0190: the per-acc trim-contract compare (see _meshprobe_test).
func _acc_cmp(gm: Dictionary, cm: Dictionary) -> Dictionary:
	var gq := int(gm["q"])
	var cq := int(cm["q"])
	var out := {"q": gq == cq, "v": false, "n": false, "c": false, "u": false, "i": false}
	if gq != cq:
		return out
	if gq == 0:
		return {"q": true, "v": true, "n": true, "c": true, "u": true, "i": true}
	var gv: PackedVector3Array = (gm["v"] as PackedVector3Array).duplicate()
	gv.resize(gq * 4)
	var cv: PackedVector3Array = (cm["v"] as PackedVector3Array).duplicate()
	cv.resize(gq * 4)
	out["v"] = gv == cv
	var gn: PackedVector3Array = (gm["n"] as PackedVector3Array).duplicate()
	gn.resize(gq * 4)
	var cn: PackedVector3Array = (cm["n"] as PackedVector3Array).duplicate()
	cn.resize(gq * 4)
	out["n"] = gn == cn
	var gc: PackedColorArray = (gm["c"] as PackedColorArray).duplicate()
	gc.resize(gq * 4)
	var cc: PackedColorArray = (cm["c"] as PackedColorArray).duplicate()
	cc.resize(gq * 4)
	out["c"] = gc == cc
	var gu: PackedVector2Array = (gm["u"] as PackedVector2Array).duplicate()
	gu.resize(gq * 4)
	var cu: PackedVector2Array = (cm["u"] as PackedVector2Array).duplicate()
	cu.resize(gq * 4)
	out["u"] = gu == cu
	var gi: PackedInt32Array = (gm["i"] as PackedInt32Array).duplicate()
	gi.resize(gq * 6)
	var ci: PackedInt32Array = (cm["i"] as PackedInt32Array).duplicate()
	ci.resize(gq * 6)
	out["i"] = gi == ci
	return out


# AC-0190: first-difference diagnostic for one acc field (index + both
# values), used by the probe's mismatch list to localize a divergence.
func _acc_diag(gm: Dictionary, cm: Dictionary, field: String, elems: int, per: int) -> String:
	var gq := int(gm["q"])
	var cq := int(cm["q"])
	var n := mini(gq, cq) * per * elems
	var ga: Array = gm[field]
	var ca: Array = cm[field]
	var lim := mini(n, mini(int(ga.size()), int(ca.size())))
	for k in range(lim):
		var gv: Variant = ga[k]
		var cv: Variant = ca[k]
		if elems == 1:
			if int(gv) != int(cv):
				return "i=%d gd=%d cpp=%d" % [k, int(gv), int(cv)]
		elif elems == 2:
			var g2: Vector2 = gv
			var c2: Vector2 = cv
			if g2 != c2:
				return "i=%d gd=%s cpp=%s" % [k, str(g2), str(c2)]
		elif elems == 3:
			var g3: Vector3 = gv
			var c3: Vector3 = cv
			if g3 != c3:
				return "i=%d gd=%s cpp=%s" % [k, str(g3), str(c3)]
		else:
			var gc: Color = gv
			var cc: Color = cv
			if gc != cc:
				return "i=%d gd=%s cpp=%s" % [k, str(gc), str(cc)]
	return "none-in-range n=%d" % lim


# AC-0091 basis-sanity probe (spec gate; env-gated by AWECRAFT_LOGIC=basis,
# never runs in game): bedrock at y=0; sea surface at y=126 in an ocean
# column; spawn surface solid + air above; sky-lit surface reports light 15
# day / 15 sky; MC Y in RESULT = internal y - 64 (coordinate-surface
# contract). Probe only — no logic changes here.
func _basis_test(spawn: Vector3) -> void:
	var out := {}
	var ok := true
	var bx := int(WorldGen.SPAWN_X)
	var bz := int(WorldGen.SPAWN_Z)
	# 1. bedrock at y=0 in the spawn column (boot sync-gen chunk).
	var bed: int = world.get_block(bx, 0, bz)
	out["bedrock_y0"] = bed
	out["bedrock_ok"] = bed == WorldGen.B_BEDROCK
	ok = ok and out["bedrock_ok"]
	# 2. sea surface at Data.SEA in an ocean column: nearest column with
	#    terrain strictly below the sea, so water occupies y=Data.SEA.
	var ox := -1
	var oz := -1
	var best := 1 << 30
	for z2 in range(-64, 65, 4):
		for x2 in range(-64, 65, 4):
			if WorldGen.terrain_height(x2, z2, Game.world_seed) < Data.SEA:
				var dd := absi(x2 - bx) + absi(z2 - bz)
				if dd < best:
					best = dd
					ox = x2
					oz = z2
	out["ocean_at"] = [ox, oz]
	if ox < 0:
		out["sea_ok"] = false
		ok = false
	else:
		world.recenter(float(ox), float(oz), false)
		await _await_core_3x3(Vector3(float(ox), 0.0, float(oz)), 3000)
		var sw: int = world.get_block(ox, Data.SEA, oz)
		var swa: int = world.get_block(ox, Data.SEA + 1, oz)
		var ob: int = world.get_block(ox, 0, oz)
		out["sea_cell"] = sw
		out["sea_above"] = swa
		out["ocean_bedrock_y0"] = ob
		out["sea_ok"] = sw == WorldGen.B_WATER and swa == 0 and ob == WorldGen.B_BEDROCK
		ok = ok and out["sea_ok"]
		world.recenter(float(bx), float(bz), false)
		await _await_core_3x3(spawn, 3000)
	# 3. spawn column: surface block solid, air directly above it.
	var top: int = world.surface_top(bx, bz)
	var sb: int = world.get_block(bx, top, bz)
	var sab: int = world.get_block(bx, top + 1, bz)
	out["spawn_top_y"] = top
	out["spawn_top_solid"] = bool(Data.block(sb).solid)
	out["spawn_above_air"] = sab == 0
	ok = ok and out["spawn_top_solid"] and out["spawn_above_air"]
	# 4. sky-lit surface at noon: the air cell just above the spawn surface
	#    reports sky 15 / eff 15.
	Game.time_of_day = 0.5
	var l: Dictionary = world.light_at(bx, top + 1, bz)
	out["surface_sky"] = int(l.sky)
	out["surface_eff"] = int(l.eff)
	out["surface_light_ok"] = int(l.sky) == 15 and int(l.eff) == 15
	ok = ok and out["surface_light_ok"]
	# 5. MC Y exposure = internal y - 64 (the only place MC Y appears).
	out["mc_y"] = {
		"bedrock": 0 - 64,
		"sea": Data.SEA - 64,
		"spawn_top": top - 64,
		"world_top": (Data.HEIGHT - 1) - 64,
	}
	out["ok"] = ok
	Debug.result(out)


# AC-0129 probe (env-gated by AWECRAFT_LOGIC=lightaudit, never runs in game):
# steady-settle, scan baked last_eff for cross-chunk cliffs, deterministic torch
# tunnel A/B (mesh seq vs light_at). Probe only — no logic changes here.
func _la_settle(max_frames: int) -> int:
	var rr: int = world.render_radius
	var quiet := 0
	var t0 := Time.get_ticks_msec()
	var awaited := 0
	while awaited < max_frames and Time.get_ticks_msec() - t0 < 120000:
		var n_in := 0
		for key in world.chunks:
			var cc: Node3D = world.chunks[key]
			if absi(cc.cx) <= rr and absi(cc.cz) <= rr and cc.mesh_built:
				n_in += 1
		var queues_idle: bool = world.light_dirty.is_empty() and world.light_pending.is_empty() \
			and world.threadmesh_inflight.is_empty() and world._col_pending.is_empty()
		if n_in == (2 * rr + 1) * (2 * rr + 1) and queues_idle:
			quiet += 1
		else:
			quiet = 0
		if quiet >= 5:
			break
		await get_tree().physics_frame
		awaited += 1
	return awaited


func _la_cliff_pair(x1: int, y1: int, z1: int, e1: int, id1: int, x2: int, y2: int, z2: int, e2: int, id2: int, hard: Array, fluid: Array) -> void:
	var p: Array = [x1, y1, z1, e1, x2, y2, z2, e2, id1, id2]
	if (id1 == 0 or id1 == 28) and (id2 == 0 or id2 == 28):
		hard.append(p)
	else:
		fluid.append(p)


# AC-0134 spec R3 re-anchor: per-chunk own-column CLOSED masks for the 4
# boundary columns. m[t*H + y] = 1 iff a solid (att==0) sits ABOVE y in that
# chunk-local column — the kernel's own-sky test (such a cell has sky_n=0).
# col 0=E (x=15) 1=W (x=0) 2=S (z=15) 3=N (z=0); t = the along-boundary coord.
func _la_col_masks(o: Node3D, H: int) -> Array:
	var d: PackedByteArray = o.flat_data()
	var out: Array = []
	for k in range(4):
		var m := PackedByteArray()
		m.resize(16 * H)
		for t in range(16):
			var open := true
			for y in range(H - 1, -1, -1):
				var idx: int
				match k:
					0: idx = (y << 8) | (t << 4) | 15
					1: idx = (y << 8) | (t << 4)
					2: idx = (y << 8) | (15 << 4) | t
					_: idx = (y << 8) | t
				m[t * H + y] = 0 if open else 1
				if Lighting._att[d[idx]] == 0:
					open = false
		out.append(m)
	return out


# AC-0134 transient diagnostic (fix-6): lava pair — the 2-hop cliff cell.
# Runs at the FIRST settle (before the tunnel test): lava is natural, the
# pair (A=(-2,0) cell local (1,15,15) lit vs B=(-2,1) cell (1,15,0) dark)
# isolates whether A's FACE carries A's imported (non-in-chunk) level.
func _ac134_diag_lava(H: int) -> void:
	var ka: String = world._key(-2, 0)
	var kb: String = world._key(-2, 1)
	var na = world.chunks.get(ka)
	var nbb = world.chunks.get(kb)
	if na == null or nbb == null:
		print("DIAG134 lava chunks missing")
		return
	var iS: int = (15 << 8) | (15 << 4) | 1  # lavaA local (x=1,z=15,y=15)
	print("DIAG134 lavaA built=%s eff_empty=%s gen=%d face_blk=%s" % [str(na.mesh_built), str(na.last_eff.is_empty()), int(na.eff_gen), str(world._face_blk.has(ka))])
	print("DIAG134 lavaA_cell baked_eff=%d id=%d" % [int(na.last_eff["arr"][iS]), int(na.get_at(iS))])
	var fba: Array = world._face_blk.get(ka, [])
	if fba.size() >= 2:
		print("DIAG134 faceS[15*16+1]=%d data_match=%s" % [int(fba[1][2][15 * 16 + 1]), str(int(na.data_gen) == int(fba[0]))])
	var fresh_a: Array = world._compute_face_blk(na)
	print("DIAG134 fresh_computeA faceS[15*16+1]=%d" % [int(fresh_a[2][15 * 16 + 1])])
	var sba: Dictionary = world._side_blk_strip(na, 0, -1, H)
	print("DIAG134 stripS_v v[15*16+1]=%d b[15*16+1]=%d" % [int(sba["v"][15 * 16 + 1]), int(sba["b"][15 * 16 + 1])])
	if not nbb.last_eff.is_empty():
		print("DIAG134 lavaB_baked_(1,15,0)eff=%d id=%d gen=%d" % [int(nbb.last_eff["arr"][(15 << 8) | 1]), int(nbb.get_at((15 << 8) | 1)), int(nbb.eff_gen)])
	# --- fix-6 source trace for A's (1,15,15) = 14 ---
	var iA: int = (15 << 8) | (15 << 4) | 1
	var stripsA = world._strips_for(-2, 0)
	var resA = Lighting.compute_light_flat_chunk_pull(na.data, -2, 0, H, stripsA["eff"], stripsA["blk"], stripsA["blk_b"])
	print("DIAG134 lavaA_fresh_eff=%d mask=%d" % [int(resA["arr"][iA]), int(resA["mask"][iA])])
	var blk0: Array = [PackedByteArray(), PackedByteArray(), PackedByteArray(), PackedByteArray()]
	var resA0 = Lighting.compute_light_flat_chunk_pull(na.data, -2, 0, H, stripsA["eff"], blk0, blk0)
	print("DIAG134 lavaA_fresh_eff_nostrips=%d" % int(resA0["arr"][iA]))
	var bsz: Array = []
	for bb in stripsA["blk"]:
		bsz.append(int(bb.size()))
	print("DIAG134 stripsA blk_sizes=%s blk_s_v[15*16+1]=%d" % [str(bsz), int(stripsA["blk"][3][15 * 16 + 1])])
	var col15: Array = []
	var col14: Array = []
	for yy in range(15, 20):
		col15.append(int(na.get_at((yy << 8) | (15 << 4) | 1)))
		col14.append(int(na.get_at((yy << 8) | (14 << 4) | 1)))
	print("DIAG134 colA x=1 z=15 ids y15..19=%s z=14 ids y15..19=%s" % [str(col15), str(col14)])
	print("DIAG134 A_baked neighbors: (1,15,14)=%d (0,15,15)=%d (2,15,15)=%d (1,14,15)=%d (1,15,15)=%d" % [int(na.last_eff["arr"][(15 << 8) | (14 << 4) | 1]), int(na.last_eff["arr"][(15 << 8) | (15 << 4) | 0]), int(na.last_eff["arr"][(15 << 8) | (15 << 4) | 2]), int(na.last_eff["arr"][(14 << 8) | (15 << 4) | 1]), int(na.last_eff["arr"][iA])])
	var kc: String = world._key(-2, -1)
	var ncC = world.chunks.get(kc)
	if ncC == null or ncC.data.is_empty():
		print("DIAG134 C(-2,-1) missing/empty")
	else:
		var lavas: Array = []
		var dc: PackedByteArray = ncC.flat_data()
		for y in range(H):
			var row := y << 8
			for z in range(16):
				for x in range(16):
					if dc[row | (z << 4) | x] == 24 and lavas.size() < 6:
						lavas.append([x, y, z])
		print("DIAG134 C lava positions(local)=%s built=%s eff_empty=%s gen=%d face_blk=%s" % [str(lavas), str(ncC.mesh_built), str(ncC.last_eff.is_empty()), int(ncC.eff_gen), str(world._face_blk.has(kc))])
		var fcc: Array = world._face_blk.get(kc, [])
		if fcc.size() >= 2:
			print("DIAG134 C faceS[15*16+1]=%d data_match=%s deps=%s" % [int(fcc[1][2][15 * 16 + 1]), str(int(ncC.data_gen) == int(fcc[0])), str(fcc[2])])
		var freshC: Array = world._compute_face_blk(ncC)
		print("DIAG134 C fresh faceS[15*16+1]=%d" % int(freshC[2][15 * 16 + 1]))
		var depsA: Array = world._face_blk.get(ka, [])
		if depsA.size() >= 3:
			print("DIAG134 A face deps=%s" % str(depsA[2]))
	var strips2 = world._strips_for(-2, 1)
	var bsz2: Array = []
	for bb2 in strips2["blk"]:
		bsz2.append(int(bb2.size()))
	print("DIAG134 strips(-2,1) blk_sizes=%s" % str(bsz2))
	var res2 = Lighting.compute_light_flat_chunk_pull(nbb.data, -2, 1, H, strips2["eff"], strips2["blk"], strips2["blk_b"])
	print("DIAG134 lavaB_fresh_(1,15,0)eff=%d" % int(res2["arr"][(15 << 8) | 1]))

# AC-0134 transient diagnostic (fix-6): torch tunnel — runs AFTER the
# tunnel test (the torch only exists after _la_tunnel places it + settles).
func _ac134_diag_torch(H: int, tunnel: Dictionary) -> void:
	var torch: Array = tunnel.get("torch", [])
	var dir: Vector3i = tunnel.get("dir", Vector3i.ZERO)
	if torch.is_empty():
		print("DIAG134 no torch")
		return
	var tcx := int(floorf(float(int(torch[0])) / 16.0))
	var tcz := int(floorf(float(int(torch[2])) / 16.0))
	var k: String = world._key(tcx, tcz)
	var nc = world.chunks.get(k)
	if nc == null:
		print("DIAG134 torch chunk missing")
		return
	var lx := int(torch[0]) - tcx * 16
	var ly := int(torch[1])
	var lz := int(torch[2]) - tcz * 16
	var fi: int
	var ft: int
	var nkey: String
	if dir.x > 0:
		fi = 0
		ft = lz
		nkey = world._key(tcx + 1, tcz)
	elif dir.x < 0:
		fi = 1
		ft = lz
		nkey = world._key(tcx - 1, tcz)
	elif dir.z < 0:
		fi = 3
		ft = lx
		nkey = world._key(tcx, tcz - 1)
	else:
		fi = 2
		ft = lx
		nkey = world._key(tcx, tcz + 1)
	var iFace: int
	if dir.x != 0:
		iFace = (ly << 8) | (lz << 4) | (15 if dir.x > 0 else 0)
	else:
		iFace = (ly << 8) | ((15 if dir.z > 0 else 0) << 4) | lx
	print("DIAG134 torch baked facecell_eff=%d id=%d" % [int(nc.last_eff["arr"][iFace]), int(nc.get_at(iFace))])
	var cur: Array = world._face_blk.get(k, [])
	if cur.size() >= 2:
		print("DIAG134 face cache fi=%d val=%d data_match=%s" % [fi, int(cur[1][fi][ly * 16 + ft]), str(int(nc.data_gen) == int(cur[0]))])
	var fresh: Array = world._compute_face_blk(nc)
	print("DIAG134 fresh_compute fi=%d val=%d" % [fi, int(fresh[fi][ly * 16 + ft])])
	var nb = world.chunks.get(nkey)
	if nb == null:
		print("DIAG134 receiving chunk missing")
		return
	var iRecv: int
	if dir.x != 0:
		iRecv = (ly << 8) | (lz << 4) | (0 if dir.x > 0 else 15)
	else:
		iRecv = (ly << 8) | ((0 if dir.z > 0 else 15) << 4) | lx
	if not nb.last_eff.is_empty():
		print("DIAG134 recv_baked_eff=%d id=%d gen=%d" % [int(nb.last_eff["arr"][iRecv]), int(nb.get_at(iRecv)), int(nb.eff_gen)])
	var strips = world._strips_for(int(nb.cx), int(nb.cz))
	var res = Lighting.compute_light_flat_chunk_pull(nb.data, int(nb.cx), int(nb.cz), H, strips["eff"], strips["blk"], strips["blk_b"])
	print("DIAG134 recv_fresh_eff=%d" % int(res["arr"][iRecv]))

func _lightaudit_test(spawn: Vector3) -> void:
	Lighting._tables()
	var rr: int = world.render_radius
	var H: int = Data.HEIGHT
	world.recenter(spawn.x, spawn.z, true)
	await _la_settle(60000)
	_ac134_diag_lava(H)
	var chunks_built := 0
	for key in world.chunks:
		var cc: Node3D = world.chunks[key]
		if absi(cc.cx) <= rr and absi(cc.cz) <= rr and cc.mesh_built:
			chunks_built += 1
	# AC-0134 spec R3: hard = both cells CLOSED in their own column (a true
	# block-light cliff between sealed cells, must stay 0 post-fix). At least
	# one cell open-own-column with a Δ>1 = expected post-fix (sky no longer
	# crosses the boundary: open column 15 next to sealed neighbor 0) and is
	# informational only (sky_pairs never flips ok).
	var hard_pairs: Array = []
	var fluid_pairs: Array = []
	var sky_pairs: Array = []
	var masks_cache: Dictionary = {}
	for key in world.chunks:
		var o: Node3D = world.chunks[key]
		if not o.mesh_built or o.last_eff.is_empty():
			continue
		var oarr: PackedByteArray = o.last_eff["arr"]
		var od: PackedByteArray = o.flat_data()
		var ocx: int = int(o.cx)
		var ocz: int = int(o.cz)
		var om: Array = masks_cache.get(key, [])
		if om.is_empty():
			om = _la_col_masks(o, H)
			masks_cache[key] = om
		for y in range(H):
			var row := y << 8
			for lz in range(16):
				var idx := row | (lz << 4) | 15
				var id_o: int = od[idx]
				if Lighting._att[id_o] > 0:
					var e_o: int = oarr[idx]
					var n: Node3D = world.chunks.get(world._key(ocx + 1, ocz))
					if n != null and n.mesh_built and not n.last_eff.is_empty():
						var nidx := row | (lz << 4)
						var id_n: int = n.get_at(nidx)
						if Lighting._att[id_n] > 0:
							var e_n: int = n.last_eff["arr"][nidx]
							if absi(e_o - e_n) > 1:
								var nkey: String = world._key(ocx + 1, ocz)
								var nm: Array = masks_cache.get(nkey, [])
								if nm.is_empty():
									nm = _la_col_masks(n, H)
									masks_cache[nkey] = nm
								if int(om[0][lz * H + y]) == 1 and int(nm[1][lz * H + y]) == 1:
									_la_cliff_pair(ocx * 16 + 15, y, ocz * 16 + lz, e_o, id_o, (ocx + 1) * 16, y, ocz * 16 + lz, e_n, id_n, hard_pairs, fluid_pairs)
								else:
									sky_pairs.append([ocx * 16 + 15, y, ocz * 16 + lz, e_o, (ocx + 1) * 16, y, ocz * 16 + lz, e_n, id_o, id_n])
			for lx in range(16):
				var idx := row | (15 << 4) | lx
				var id_o: int = od[idx]
				if Lighting._att[id_o] > 0:
					var e_o: int = oarr[idx]
					var n: Node3D = world.chunks.get(world._key(ocx, ocz + 1))
					if n != null and n.mesh_built and not n.last_eff.is_empty():
						var nidx := row | lx
						var id_n: int = n.get_at(nidx)
						if Lighting._att[id_n] > 0:
							var e_n: int = n.last_eff["arr"][nidx]
							if absi(e_o - e_n) > 1:
								var nkey: String = world._key(ocx, ocz + 1)
								var nm: Array = masks_cache.get(nkey, [])
								if nm.is_empty():
									nm = _la_col_masks(n, H)
									masks_cache[nkey] = nm
								if int(om[2][lx * H + y]) == 1 and int(nm[3][lx * H + y]) == 1:
									_la_cliff_pair(ocx * 16 + lx, y, ocz * 16 + 15, e_o, id_o, ocx * 16 + lx, y, (ocz + 1) * 16, e_n, id_n, hard_pairs, fluid_pairs)
								else:
									sky_pairs.append([ocx * 16 + lx, y, ocz * 16 + 15, e_o, ocx * 16 + lx, y, (ocz + 1) * 16, e_n, id_o, id_n])
	var hard_sorted: Array = hard_pairs.duplicate()
	hard_sorted.sort_custom(func(a, b): return absi(int(a[3]) - int(a[7])) > absi(int(b[3]) - int(b[7])))
	var top8: Array = []
	for i in range(mini(8, hard_sorted.size())):
		top8.append(hard_sorted[i])
	var maxd := 0
	for p in hard_sorted:
		maxd = maxi(maxd, absi(int(p[3]) - int(p[7])))
	var fsorted: Array = fluid_pairs.duplicate()
	fsorted.sort_custom(func(a, b): return absi(int(a[3]) - int(a[7])) > absi(int(b[3]) - int(b[7])))
	var ftop3: Array = []
	for i in range(mini(3, fsorted.size())):
		ftop3.append(fsorted[i])
	# sky_pairs: informational only (open/closed Δ is the EXPECTED post-fix
	# state — sky no longer crosses the boundary); never flips ok.
	var ssorted: Array = sky_pairs.duplicate()
	ssorted.sort_custom(func(a, b): return absi(int(a[3]) - int(a[7])) > absi(int(b[3]) - int(b[7])))
	var stop3: Array = []
	for i in range(mini(3, ssorted.size())):
		stop3.append(ssorted[i])
	var smaxd := 0
	for p in ssorted:
		smaxd = maxi(smaxd, absi(int(p[3]) - int(p[7])))
	var ws: Dictionary = {}
	for p in top8:
		var px: int = int(p[0])
		var py: int = int(p[1])
		var pz: int = int(p[2])
		for bx in range(px - 15, px + 16):
			for bz in range(pz - 15, pz + 16):
				for by in range(maxi(py - 15, 0), mini(py + 15, H - 1) + 1):
					var bid: int = world.get_block(bx, by, bz)
					if bid == 22 or bid == 23 or bid == 24:
						ws[bid] = true
	var worst_sources: Array = []
	for k in ws:
		worst_sources.append(int(k))
	worst_sources.sort()
	var tunnel = await _la_tunnel()
	if tunnel != null:
		_ac134_diag_torch(H, tunnel)
	Debug.result({
		"mode": "lightaudit",
		"seed": Game.world_seed,
		"chunks_built": chunks_built,
		"queue_size": world.queue_size,
		"cliffs": {"count": hard_pairs.size(), "max_delta": maxd, "pairs": top8},
		"fluid_pairs": {"count": fluid_pairs.size(), "pairs": ftop3},
		"sky_pairs": {"count": sky_pairs.size(), "max_delta": smaxd, "pairs": stop3},
		"tunnel": tunnel,
		"worst_sources": worst_sources,
		"ok": hard_pairs.size() == 0 and (tunnel == null or bool(tunnel.get("ok", false))),
	})
	get_tree().quit()


func _la_tunnel() -> Variant:
	var H: int = Data.HEIGHT
	var found := false
	var torch: Array = []
	var dir := Vector3i.ZERO
	for tcx in range(-4, 5):
		if found:
			break
		for tcz in range(-4, 5):
			if found:
				break
			for ty in range(H - 1, 7, -1):
				if found:
					break
				for tlx in range(16):
					if found:
						break
					for tlz in range(16):
						if found:
							break
						var tx: int = tcx * 16 + tlx
						var tz: int = tcz * 16 + tlz
						if world.get_block(tx, ty, tz) != 0:
							continue
						if not _is_solid(tx, ty - 1, tz):
							continue
						if tlx <= 5:
							dir = Vector3i(-1, 0, 0)
						elif tlx >= 10:
							dir = Vector3i(1, 0, 0)
						elif tlz <= 5:
							dir = Vector3i(0, 0, -1)
						elif tlz >= 10:
							dir = Vector3i(0, 0, 1)
						else:
							continue
						var run_ok := true
						for i in range(1, 6):
							if world.get_block(tx + dir.x * i, ty, tz + dir.z * i) != 0:
								run_ok = false
							if world.get_block(tx - dir.x * i, ty, tz - dir.z * i) != 0:
								run_ok = false
						if not run_ok:
							continue
						var ex: int = tx + dir.x * 5
						var ez: int = tz + dir.z * 5
						var qx: int = tx - dir.x * 5
						var qz: int = tz - dir.z * 5
						var ecx := int(floorf(float(ex) / 16.0))
						var ecz := int(floorf(float(ez) / 16.0))
						var qcx := int(floorf(float(qx) / 16.0))
						var qcz := int(floorf(float(qz) / 16.0))
						if ecx == qcx and ecz == qcz:
							continue
						var ec: Node3D = world.chunks.get(world._key(ecx, ecz))
						var qc: Node3D = world.chunks.get(world._key(qcx, qcz))
						if ec == null or not ec.mesh_built or ec.last_eff.is_empty():
							continue
						if qc == null or not qc.mesh_built or qc.last_eff.is_empty():
							continue
						var dl: Dictionary = world.light_at(tx, ty, tz)
						if int(dl.eff) != 0:
							continue
						found = true
						torch = [tx, ty, tz]
						break
	if not found:
		return null
	world.set_block(int(torch[0]), int(torch[1]), int(torch[2]), 22)
	await _la_settle(600)
	var seq: Array = []
	var ref: Array = []
	for i in range(-5, 6):
		var sx: int = int(torch[0]) + dir.x * i
		var sz: int = int(torch[2]) + dir.z * i
		var c2: Node3D = world.chunks.get(world._key(int(floorf(float(sx) / 16.0)), int(floorf(float(sz) / 16.0))))
		var qe := -1
		if c2 != null and not c2.last_eff.is_empty():
			qe = int(c2.last_eff["arr"][(int(torch[1]) << 8) | ((sz & 15) << 4) | (sx & 15)])
		seq.append(qe)
		var ql: Dictionary = world.light_at(sx, int(torch[1]), sz)
		ref.append(int(ql.eff))
	var tok := true
	for i in range(10):
		if absi(int(seq[i]) - int(seq[i + 1])) > 1:
			tok = false
	for i in range(11):
		if absi(i - 5) <= 8 and int(ref[i]) != int(seq[i]):
			tok = false
	return {"torch": torch, "dir": [dir.x, 0, dir.z], "seq": seq, "ref": ref, "ok": tok}


# AC-0128 probe (env-gated by AWECRAFT_LOGIC=nightday, never runs in game):
# steady-settle r4; deterministic cave-open-to-sky cell + deterministic torch
# cell + informational mouth cell; reads ACTUAL u_day uniform + ACTUAL baked
# vColor from the slab surfaces + the DayNight day factor. The PRE (pre-fix)
# tree reports mechanism "pre-lit-std" with the ambient-floor numbers.
# AC-0109 G1 spin probe. Camera-only drive: the player camera is parked at
# the settled eye position and yawed 0..360 in 120 x 3-degree steps (pitch 0).
# The player and world never move -> no recenter -> drain queue must stay
# flat. Per step: verts_visible from a per-instance vertex cache built ONCE
# after settle (no per-frame surface reads), chunk visible = ALL its
# instances visible. transitions = a visible->invisible edge where the chunk
# was invisible again within the previous 8 steps (on-screen flicker).
# Then a bottom-look sample (pitch -90) and a return-to-start sample.
const SPIN_STEPS := 120
const SPIN_FLICKER_WINDOW := 8

func _spin_test(spawn: Vector3) -> void:
	var t0 := Time.get_ticks_msec()
	world.render_radius = 4
	world.recenter(spawn.x, spawn.z, true)
	# Bounded settle (AC-0137-class transients can leave a few r4 chunks
	# unbuilt forever — proceed with what is built, report the count).
	var settled := 0
	while settled < 2400:
		var n_in := 0
		var n_tot := 0
		for key in world.chunks:
			var cc: Node3D = world.chunks[key]
			if absi(int(cc.cx)) <= 4 and absi(int(cc.cz)) <= 4:
				n_tot += 1
				if cc.mesh_built:
					n_in += 1
		if n_tot >= 64 and n_in == n_tot:
			break
		await get_tree().physics_frame
		settled += 1
	var cam: Camera3D = player.camera
	get_window().size = Vector2i(1280, 720)
	var eye := cam.global_position
	# AC-0212: cull-lane awareness. "manual" (AWECRAFT_FRUSTUM=manual): the
	# AC-0109 per-frame pass hides instances via .visible — the probe reads
	# that (legacy behavior, unchanged). "engine" (NEW DEFAULT): .visible
	# stays true and the render server culls each MeshInstance3D by its mesh
	# AABB vs the camera frustum (no margin) — the probe replicates that
	# exact test per step (see _aabb_fully_outside) so the same counters
	# measure the engine cull instead of the removed manual pass.
	var manual: bool = world.cull_mode == "manual"
	var chunk_rows := []
	var built_n := 0
	var total_built := 0
	var instances_total := 0
	var instances_hidden := 0
	for key in world.chunks:
		var c: Node3D = world.chunks[key]
		if absi(int(c.cx)) > 4 or absi(int(c.cz)) > 4 or not c.mesh_built:
			continue
		built_n += 1
		var row := []
		for s in c.slabs:
			for inst in [s.mesh_instance, s.fluid_instance, s.flora_instance]:
				if inst == null or inst.mesh == null:
					continue
				var v := 0
				var am: ArrayMesh = inst.mesh
				for su in range(am.get_surface_count()):
					var arrs := am.surface_get_arrays(su)
					v += (arrs[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
				total_built += v
				instances_total += 1
				if not inst.visible:
					instances_hidden += 1
				# slab instances are chunk-origin children (pure translation:
				# chunk at (cx*16,0,cz*16), instance at local origin) ->
				# world AABB = mesh AABB + instance global position.
				var lm: AABB = inst.mesh.get_aabb()
				row.append([inst, v, AABB(lm.position + inst.global_position, lm.size)])
		chunk_rows.append(row)
	if built_n == 0:
		Debug.result({"mode": "spin", "seed": Game.world_seed, "radius": 4, "ok": false, "err": "no built chunks", "settled_frames": settled})
		get_tree().quit()
		return
	var yaw_step := TAU / float(SPIN_STEPS)
	var vis_start := -1
	var vis_bottom := -1
	var vis_end := -1
	var verts_start := -1
	var verts_sideways := -1
	var transitions := 0
	var prev_vis := []
	var last_invis := {}
	var queue_samples := []
	# AC-0212: per-instance counters (the no-pop signal at H=384, where the
	# chunk-level "ALL instances visible" definition is degenerate — a 24-slab
	# column is never fully inside the frustum, so vis_* stays 0 in BOTH
	# lanes). inst_vis_* = visible instance count at each key pose;
	# inst_transitions = an instance culled then back within the 8-step
	# window (on-screen pop-in/out).
	var inst_vis_start := -1
	var inst_vis_sidelook := -1
	var inst_vis_bottom := -1
	var inst_vis_end := -1
	var inst_transitions := 0
	var prev_inst_vis := []
	var last_inst_invis := {}
	# The cull pass may have already latched the camera transform before any
	# chunks existed (world starts before the player/camera) — force a fresh
	# evaluation at the first probe pose so step 0 and the final return pose
	# are both measured through the pass (manual lane only; the engine lane
	# culls at render time from the live camera pose).
	if manual:
		world.invalidate_cull_cache()
	for step in range(SPIN_STEPS + 1):
		var set_xf := Transform3D(Basis(Vector3.UP, float(step) * yaw_step), eye)
		cam.global_transform = set_xf
		await get_tree().process_frame
		if step == 0:
			# Phase sync: the first set lands on a physics_frame emission, so
			# the world's _process of that frame already ran — give the cull
			# pass one full frame to evaluate T0 before sampling.
			await get_tree().process_frame
		queue_samples.append(int(world.queue_size))
		# AC-0212: the probe's per-step "is it on screen" source.
		var planes: Array = []
		if not manual:
			planes = _spin_frustum_planes(cam)
		var verts_vis := 0
		var vis_count := 0
		var insts_seen := 0
		var step_vis := []
		var step_inst_vis := []
		for ci in range(built_n):
			var all_vis := true
			for e in chunk_rows[ci]:
				var inst = e[0]
				var iv: bool = is_instance_valid(inst) and _spin_inst_vis(e, manual, planes)
				step_inst_vis.append(iv)
				if iv:
					insts_seen += 1
					# legacy verts semantics: a chunk's verts count only while
					# its running all-visible state holds (stops at the first
					# hidden instance).
					if all_vis:
						verts_vis += int(e[1])
				else:
					all_vis = false
			step_vis.append(all_vis)
			if all_vis:
				vis_count += 1
		if step == 0:
			vis_start = vis_count
			verts_start = verts_vis
			inst_vis_start = insts_seen
		elif step == SPIN_STEPS / 4:
			verts_sideways = verts_vis
			inst_vis_sidelook = insts_seen
		var flips := []
		if step >= 1:
			for ci in range(built_n):
				if step_vis[ci] != prev_vis[ci]:
					flips.append(ci)
				if not step_vis[ci] and prev_vis[ci]:
					# sentinel far enough that a first-ever edge never flickers
					var li: int = last_invis.get(ci, -9999)
					if li >= step - SPIN_FLICKER_WINDOW:
						transitions += 1
					last_invis[ci] = step
			# AC-0212: per-instance flicker (the no-pop signal that stays
			# meaningful at H=384, where no 24-slab column is ever FULLY in
			# the frustum, so the chunk-level all-visible counter is degenerate).
			for ii in range(step_inst_vis.size()):
				if not step_inst_vis[ii] and prev_inst_vis[ii]:
					var lii: int = last_inst_invis.get(ii, -9999)
					if lii >= step - SPIN_FLICKER_WINDOW:
						inst_transitions += 1
					last_inst_invis[ii] = step
		prev_vis = step_vis
		prev_inst_vis = step_inst_vis
		if OS.get_environment("AWECRAFT_SPINDBG") != "":
			print("SPINDBG step=%d vis=%d verts=%d q=%d lp=%d tmi=%d ld=%d tr=%d flips=%s" % [step, vis_count, verts_vis, int(world.queue_size), int(world.light_pending.size()), int(world.threadmesh_inflight.size()), int(world.light_dirty.size()), int(world.tex_refresh.size()), flips])
	# bottom look: pitch -90 (straight down), 3 frames for the cull pass
	cam.global_transform = Transform3D(Basis(Vector3.RIGHT, -PI / 2.0), eye)
	for i in 3:
		await get_tree().process_frame
	var bplanes: Array = _spin_frustum_planes(cam) if not manual else []
	vis_bottom = _spin_vis_count(chunk_rows, manual, bplanes)
	inst_vis_bottom = _spin_inst_vis_count(chunk_rows, manual, bplanes)
	# back to the start orientation, 3 frames, state must be restored
	cam.global_transform = Transform3D(Basis(Vector3.UP, 0.0), eye)
	for i in 3:
		await get_tree().process_frame
	var eplanes: Array = _spin_frustum_planes(cam) if not manual else []
	vis_end = _spin_vis_count(chunk_rows, manual, eplanes)
	inst_vis_end = _spin_inst_vis_count(chunk_rows, manual, eplanes)
	var qmin: int = int(queue_samples[0])
	var qmax: int = int(queue_samples[0])
	for q in queue_samples:
		qmin = mini(qmin, int(q))
		qmax = maxi(qmax, int(q))
	var queue_flat: bool = qmin == qmax
	var verts_drop: bool = verts_sideways < total_built
	# AC-0212: the gate gains the per-instance no-pop pair (both lanes,
	# any world height): no instance flicker + the return pose restores the
	# same visible-instance set as step 0.
	var ok: bool = transitions == 0 and inst_transitions == 0 and verts_drop \
		and vis_end == vis_start and inst_vis_end == inst_vis_start and queue_flat
	Debug.result({
		"mode": "spin",
		"seed": Game.world_seed,
		"radius": 4,
		"ok": ok,
		# AC-0212: cull lane + the world's cull counters (manual lane:
		# passes = camera-change re-evaluations, flips = visibility writes;
		# engine lane: both 0 — the manual pass never runs, which is the
		# counter reading that proves the per-frame cull cost is gone).
		"cull_mode": world.cull_mode,
		"manual_pass": manual,
		"perf_cull_passes": int(world.perf_cull_passes),
		"perf_cull_flips": int(world.perf_cull_flips),
		"instances_total": instances_total,
		"instances_hidden": instances_hidden,
		"transitions": transitions,
		# AC-0212: per-instance no-pop counters (H=384 meaningful)
		"inst_transitions": inst_transitions,
		"inst_vis_start": inst_vis_start,
		"inst_vis_sidelook": inst_vis_sidelook,
		"inst_vis_bottom": inst_vis_bottom,
		"inst_vis_end": inst_vis_end,
		"vis_start": vis_start,
		"vis_bottom": vis_bottom,
		"vis_end": vis_end,
		"verts_visible_start": verts_start,
		"verts_visible_sidelook": verts_sideways,
		"total_built": total_built,
		"queue_flat": queue_flat,
		"queue_samples": queue_samples,
		"steps": SPIN_STEPS,
		"built_chunks": built_n,
		"settled_frames": settled,
		"elapsed_ms": Time.get_ticks_msec() - t0,
	})
	get_tree().quit()

func _spin_vis_count(chunk_rows: Array, manual: bool, planes: Array) -> int:
	var vis_count := 0
	for row in chunk_rows:
		var all_vis := true
		for e in row:
			var inst = e[0]
			if not is_instance_valid(inst) or not _spin_inst_vis(e, manual, planes):
				all_vis = false
				break
		if all_vis:
			vis_count += 1
	return vis_count

# AC-0212: visible-instance count at a pose (the H=384-meaningful version of
# the chunk-level counter — a 24-slab column is never fully in the frustum).
func _spin_inst_vis_count(chunk_rows: Array, manual: bool, planes: Array) -> int:
	var n := 0
	for row in chunk_rows:
		for e in row:
			if is_instance_valid(e[0]) and _spin_inst_vis(e, manual, planes):
				n += 1
	return n

# AC-0212: per-instance "is it on screen" per the ACTIVE cull lane. Manual:
# the AC-0109 pass wrote .visible. Engine: replicate the render server's
# exact test — the instance stays on screen unless its world AABB is fully
# outside one of the six camera-frustum planes (no margin).
func _spin_inst_vis(e: Array, manual: bool, planes: Array) -> bool:
	if manual:
		return e[0].visible
	return not _aabb_fully_outside(e[2], planes)

# AC-0212: margin-free 6-plane construction — same camera math as world.gd
# _cull_frustum_planes (AC-0109), which the engine's per-instance cull uses.
func _spin_frustum_planes(cam: Camera3D) -> Array:
	var B := cam.global_transform.basis
	var O := cam.global_transform.origin
	var sz := get_viewport().get_visible_rect().size
	var aspect := float(sz.x) / maxf(float(sz.y), 1.0)
	var tv := tan(deg_to_rad(float(cam.fov)) * 0.5)
	var th := tv * aspect
	var nr := maxf(float(cam.near), 0.01)
	var fr := maxf(float(cam.far), nr + 1.0)
	var cn0 := O + B * Vector3(-th * nr, -tv * nr, -nr)
	var cn1 := O + B * Vector3(th * nr, -tv * nr, -nr)
	var cn2 := O + B * Vector3(-th * nr, tv * nr, -nr)
	var cn3 := O + B * Vector3(th * nr, tv * nr, -nr)
	var cf0 := O + B * Vector3(-th * fr, -tv * fr, -fr)
	var cf1 := O + B * Vector3(th * fr, -tv * fr, -fr)
	var cf2 := O + B * Vector3(-th * fr, tv * fr, -fr)
	var cf3 := O + B * Vector3(th * fr, tv * fr, -fr)
	var cen := O + B * Vector3(0.0, 0.0, -fr * 0.5)
	return [
		_spin_plane(cn0, cn1, cn3, cen),
		_spin_plane(cf0, cf1, cf3, cen),
		_spin_plane(cn0, cn2, cf2, cen),
		_spin_plane(cn1, cn3, cf3, cen),
		_spin_plane(cn2, cn3, cf2, cen),
		_spin_plane(cn0, cn1, cf1, cen),
	]

func _spin_plane(a: Vector3, b: Vector3, c: Vector3, cen: Vector3) -> Plane:
	var n: Vector3 = (b - a).cross(c - a)
	if n.length_squared() < 0.00000001:
		return Plane(Vector3(0, 0, -1), a)
	n = n.normalized()
	if n.dot(cen - a) < 0.0:
		n = -n
	return Plane(n, a)

# AC-0212: AABB fully outside the frustum = for SOME plane, the AABB's
# supporting point along the plane normal (the closest corner to the
# frustum interior) is already on the far side. Exact convex test, no
# corner enumeration.
func _aabb_fully_outside(aabb: AABB, planes: Array) -> bool:
	for i in planes.size():
		var p: Plane = planes[i]
		var n: Vector3 = p.normal
		# AABB.position = min corner, +size = max corner (the supporting
		# point along +n).
		var mn: Vector3 = aabb.position
		var mx: Vector3 = aabb.position + aabb.size
		var sp := Vector3(
			mx.x if n.x >= 0.0 else mn.x,
			mx.y if n.y >= 0.0 else mn.y,
			mx.z if n.z >= 0.0 else mn.z)
		if p.distance_to(sp) < 0.0:
			return true
	return false


# AC-0212 R16 (the task's #1 gate): 16-radius build + moving inside a chunk.
# Per-frame processing cost (frame ms; run with --fixed-fps 600 so the tick
# is uncapped and the await measures true per-frame CPU) in two phases:
#   A. static  — 600 physics frames, camera parked at the spawn eye.
#   B. moving  — 900 physics frames, camera on a 12 m circle inside the
#      spawn chunk (no recenter, no streaming; the frustum changes every
#      frame — the worst case for the AC-0109 manual cull pass, which
#      re-evaluated EVERY resident chunk on every camera change).
# Effective fps = 1000 / frame_ms. The no-5fps-drop gate is an A/B: run
# this arm with AWECRAFT_FRUSTUM=manual (before) and the engine default
# (after); the moving-phase fps must not drop by 5.
func _r16_test(spawn: Vector3) -> void:
	var t0 := Time.get_ticks_msec()
	world.render_radius = maxi(world.render_radius, 16)
	var rr: int = world.render_radius
	world.recenter(spawn.x, spawn.z, true)
	var pcx := int(floorf(spawn.x / 16.0))
	var pcz := int(floorf(spawn.z / 16.0))
	var passes0 := int(world.perf_cull_passes)
	var flips0 := int(world.perf_cull_flips)
	var build_t0 := Time.get_ticks_msec()
	# 16-radius build: every band<=2 chunk in the r16 square meshed (the
	# perf arm's "all" definition). 25-min wall cap: on a stall the arm
	# proceeds with the partial build (reported, not fatal).
	var frames := 0
	var max_frames := 400000
	var total_sq := (2 * rr + 1) * (2 * rr + 1)
	var built_all := false
	var built_n := 0
	# The full square scan is O(resident chunks) — run it every 30 frames
	# (the 30-frame post-settle below absorbs the quantization; a per-frame
	# scan at r16 would burn a core for the whole build).
	while frames < max_frames and Time.get_ticks_msec() - t0 < 1500000:
		await get_tree().physics_frame
		frames += 1
		if frames % 30 == 0:
			built_all = true
			built_n = 0
			for key in world.chunks:
				var c: Node3D = world.chunks[key]
				if int(c.band) > 2:
					continue
				if absi(c.cx - pcx) <= rr and absi(c.cz - pcz) <= rr:
					if c.mesh_built:
						built_n += 1
					else:
						built_all = false
						break
			if built_all:
				break
		if frames % 600 == 0:
			var nb := 0
			for key in world.chunks:
				var cc: Node3D = world.chunks[key]
				if int(cc.band) <= 2 and absi(cc.cx - pcx) <= rr and absi(cc.cz - pcz) <= rr and cc.mesh_built:
					nb += 1
			print("R16PROG frames=%d built=%d/%d t=%d ms" % [frames, nb, total_sq, Time.get_ticks_msec() - build_t0])
	var build_ms := Time.get_ticks_msec() - build_t0
	# Let the last handoffs land before measuring.
	for i in 30:
		await get_tree().physics_frame
	player = _spawn_player()
	for i in 30:
		await get_tree().physics_frame
	var cam: Camera3D = player.camera
	get_window().size = Vector2i(1280, 720)
	var eye := cam.global_position
	const STATIC_FRAMES := 600
	const MOVING_FRAMES := 900
	var static_ms: Array = []
	for i in STATIC_FRAMES:
		var fb := Time.get_ticks_msec()
		await get_tree().physics_frame
		static_ms.append(Time.get_ticks_msec() - fb)
	# 12 m circle centered on the spawn chunk center (spans [2,14] in x/z,
	# fully inside the 16 m chunk); yaw follows the circle so the frustum —
	# and therefore the cull decision — changes every single frame.
	var cen := Vector3(pcx * 16.0 + 8.0, eye.y, pcz * 16.0 + 8.0)
	var moving_ms: Array = []
	for i in MOVING_FRAMES:
		var ang := TAU * float(i) / float(MOVING_FRAMES)
		var pos := cen + Vector3(cos(ang) * 6.0, 0.0, sin(ang) * 6.0)
		cam.global_transform = Transform3D(Basis(Vector3.UP, ang + PI), pos)
		var fb := Time.get_ticks_msec()
		await get_tree().physics_frame
		moving_ms.append(Time.get_ticks_msec() - fb)
	# Tail settle after the last camera change.
	for i in 30:
		await get_tree().physics_frame
	var s := _r16_stats(static_ms)
	var m := _r16_stats(moving_ms)
	Debug.result({
		"mode": "r16",
		"seed": Game.world_seed,
		"radius": rr,
		"ok": true,
		"built": built_n,
		"built_all": built_all,
		"total_chunks": total_sq,
		"resident": int(world.chunks.size()),
		"build_ms": build_ms,
		"build_frames": frames,
		# AC-0212 probe counters: the manual pass's re-evaluations/flips
		# during the WHOLE arm (build + both phases). Engine lane: 0/0.
		"cull_mode": world.cull_mode,
		"perf_cull_passes": int(world.perf_cull_passes) - passes0,
		"perf_cull_flips": int(world.perf_cull_flips) - flips0,
		"static": s,
		"moving": m,
		"drop_fps_static_vs_moving": int(roundf(float(s["fps_p50"]) - float(m["fps_p50"]))),
		"static_frames": STATIC_FRAMES,
		"moving_frames": MOVING_FRAMES,
		"elapsed_ms": Time.get_ticks_msec() - t0,
	})
	get_tree().quit()


func _r16_stats(ms_list: Array) -> Dictionary:
	var n := ms_list.size()
	if n == 0:
		return {"n": 0, "p50_ms": 0, "p95_ms": 0, "max_ms": 0, "fps_p50": 0, "fps_p95": 0, "fps_min": 0}
	var p50 := int(_percentile(ms_list, 0.50))
	var p95 := int(_percentile(ms_list, 0.95))
	var mx := int(ms_list.max())
	return {
		"n": n,
		"p50_ms": p50,
		"p95_ms": p95,
		"max_ms": mx,
		"fps_p50": int(roundf(1000.0 / maxf(float(p50), 0.5))),
		"fps_p95": int(roundf(1000.0 / maxf(float(p95), 0.5))),
		"fps_min": int(roundf(1000.0 / maxf(float(mx), 0.5))),
	}

func _nd_settle(max_frames: int) -> int:
	var rr: int = world.render_radius
	var quiet := 0
	var t0 := Time.get_ticks_msec()
	var awaited := 0
	while awaited < max_frames and Time.get_ticks_msec() - t0 < 120000:
		var n_in := 0
		for key in world.chunks:
			var cc: Node3D = world.chunks[key]
			if absi(cc.cx) <= rr and absi(cc.cz) <= rr and cc.mesh_built:
				n_in += 1
		var queues_idle: bool = world.light_dirty.is_empty() and world.light_pending.is_empty() \
			and world.threadmesh_inflight.is_empty() and world._col_pending.is_empty()
		if n_in == (2 * rr + 1) * (2 * rr + 1) and queues_idle:
			quiet += 1
		else:
			quiet = 0
		if quiet >= 5:
			break
		await get_tree().physics_frame
		awaited += 1
	return awaited


func _nd_sorted_chunks() -> Array:
	var out: Array = []
	for key in world.chunks:
		var cc: Node3D = world.chunks[key]
		if absi(cc.cx) <= 4 and absi(cc.cz) <= 4 and cc.mesh_built and not cc.last_eff.is_empty():
			out.append(cc)
	out.sort_custom(func(a, b):
		if a.cx != b.cx:
			return a.cx < b.cx
		return a.cz < b.cz
	)
	return out


func _nd_pick_cells() -> Dictionary:
	var H: int = Data.HEIGHT
	var cave: Array = []
	var mouth: Array = []
	for cc in _nd_sorted_chunks():
		if cave.size() > 0 and mouth.size() > 0:
			break
		var d: PackedByteArray = cc.flat_data()
		var eff: PackedByteArray = cc.last_eff["arr"]
		var srcs: Array = []
		for i in range(d.size()):
			var bid: int = d[i]
			if bid == 22 or bid == 23 or bid == 24:
				srcs.append([i & 15, i >> 8, (i >> 4) & 15])
		for y in range(H):
			var row := y << 8
			for lz in range(16):
				for lx in range(16):
					var idx := row | (lz << 4) | lx
					if d[idx] != 0 or eff[idx] != 15:
						continue
					var open_col := true
					for yy in range(y + 1, H):
						if d[(yy << 8) | (lz << 4) | lx] != 0:
							open_col = false
							break
					if not open_col:
						continue
					var near14 := false
					var near15 := false
					for s2 in srcs:
						var dist := maxi(maxi(absi(lx - int(s2[0])), absi(lz - int(s2[2]))), absi(y - int(s2[1])))
						if dist <= 14:
							near14 = true
						if dist <= 15:
							near15 = true
					var ndir: Array = []
					if near14 and mouth.size() == 0:
						mouth = [cc.cx, cc.cz, lx, y, lz]
					# AC-0128: the face mask samples the cave cell + 4 axis
					# probes (adjacent cells, distance -1), so a clean mask=0
					# cave needs NO own-chunk source within Chebyshev 15.
					if near15:
						continue
					for dd in [[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]]:
						var ax := lx + int(dd[0])
						var ay := y + int(dd[1])
						var az := lz + int(dd[2])
						if ax < 0 or ax > 15 or ay < 0 or ay > H - 1 or az < 0 or az > 15:
							continue
						var nid: int = d[(ay << 8) | (az << 4) | ax]
						if nid == 0 or nid == 5 or nid == 24 or nid == 22 or nid == 23:
							continue
						ndir = dd
						break
					if ndir.is_empty():
						continue
					if cave.size() == 0:
						cave = [cc.cx, cc.cz, lx, y, lz, ndir[0], ndir[1], ndir[2]]
					break
				if cave.size() > 0 and mouth.size() > 0:
					break
			if cave.size() > 0 and mouth.size() > 0:
				break
	return {"cave": cave, "mouth": mouth}


func _nd_tunnel() -> Array:
	var H: int = Data.HEIGHT
	var found := false
	var torch: Array = []
	var dir := Vector3i.ZERO
	for tcx in range(-4, 5):
		if found:
			break
		for tcz in range(-4, 5):
			if found:
				break
			for ty in range(H - 1, 7, -1):
				if found:
					break
				for tlx in range(16):
					if found:
						break
					for tlz in range(16):
						if found:
							break
						var tx: int = tcx * 16 + tlx
						var tz: int = tcz * 16 + tlz
						if world.get_block(tx, ty, tz) != 0:
							continue
						if not _is_solid(tx, ty - 1, tz):
							continue
						if tlx <= 5:
							dir = Vector3i(-1, 0, 0)
						elif tlx >= 10:
							dir = Vector3i(1, 0, 0)
						elif tlz <= 5:
							dir = Vector3i(0, 0, -1)
						elif tlz >= 10:
							dir = Vector3i(0, 0, 1)
						else:
							continue
						var run_ok := true
						for i in range(1, 6):
							if world.get_block(tx + dir.x * i, ty, tz + dir.z * i) != 0:
								run_ok = false
							if world.get_block(tx - dir.x * i, ty, tz - dir.z * i) != 0:
								run_ok = false
						if not run_ok:
							continue
						var ex: int = tx + dir.x * 5
						var ez: int = tz + dir.z * 5
						var qx: int = tx - dir.x * 5
						var qz: int = tz - dir.z * 5
						var ecx := int(floorf(float(ex) / 16.0))
						var ecz := int(floorf(float(ez) / 16.0))
						var qcx := int(floorf(float(qx) / 16.0))
						var qcz := int(floorf(float(qz) / 16.0))
						if ecx == qcx and ecz == qcz:
							continue
						var ec: Node3D = world.chunks.get(world._key(ecx, ecz))
						var qc: Node3D = world.chunks.get(world._key(qcx, qcz))
						if ec == null or not ec.mesh_built or ec.last_eff.is_empty():
							continue
						if qc == null or not qc.mesh_built or qc.last_eff.is_empty():
							continue
						var dl: Dictionary = world.light_at(tx, ty, tz)
						if int(dl.eff) != 0:
							continue
						found = true
						torch = [tx, ty, tz]
						break
	if not found:
		return []
	world.set_block(int(torch[0]), int(torch[1]), int(torch[2]), 22)
	await _nd_settle(600)
	return torch


func _nd_read_face(mis: Array, pos: Vector3, nrm: Vector3) -> Dictionary:
	var axis := 0
	if absf(nrm.y) > 0.5:
		axis = 1
	elif absf(nrm.z) > 0.5:
		axis = 2
	var pa: int = -1
	var pb: int = -1
	for a in range(3):
		if a != axis:
			if pa < 0:
				pa = a
			else:
				pb = a
	var cxv := pos[pa] + 0.5
	var cyv := pos[pb] + 0.5
	var plane_val := pos[axis]
	for mi in mis:
		if mi == null or mi.mesh == null:
			continue
		var mesh: ArrayMesh = mi.mesh
		for si in range(mesh.get_surface_count()):
			var arrs := mesh.surface_get_arrays(si)
			var verts: PackedVector3Array = arrs[Mesh.ARRAY_VERTEX]
			var norms: PackedVector3Array = arrs[Mesh.ARRAY_NORMAL]
			var idx: PackedInt32Array = arrs[Mesh.ARRAY_INDEX]
			for t in range(idx.size() / 3):
				var i0 := int(idx[t * 3])
				var i1 := int(idx[t * 3 + 1])
				var i2 := int(idx[t * 3 + 2])
				if norms[i0].dot(nrm) < 0.99999 or norms[i1].dot(nrm) < 0.99999 or norms[i2].dot(nrm) < 0.99999:
					continue
				if absf(verts[i0][axis] - plane_val) > 1e-4 or absf(verts[i1][axis] - plane_val) > 1e-4 or absf(verts[i2][axis] - plane_val) > 1e-4:
					continue
				var a2 := Vector2(verts[i0][pa], verts[i0][pb])
				var b2 := Vector2(verts[i1][pa], verts[i1][pb])
				var c2 := Vector2(verts[i2][pa], verts[i2][pb])
				var p2 := Vector2(cxv, cyv)
				var d1 := (p2 - a2).cross(b2 - a2)
				var d2 := (p2 - b2).cross(c2 - b2)
				var d3 := (p2 - c2).cross(a2 - c2)
				if (d1 >= 0.0 or d1 <= 0.0) and (d2 >= 0.0 or d2 <= 0.0) and (d3 >= 0.0 or d3 <= 0.0) and not (d1 == 0.0 and d2 == 0.0 and d3 == 0.0):
					var has_neg := (d1 < 0.0) or (d2 < 0.0) or (d3 < 0.0)
					var has_pos := (d1 > 0.0) or (d2 > 0.0) or (d3 > 0.0)
					if not (has_neg and has_pos):
						var col: Color = arrs[Mesh.ARRAY_COLOR][i0]
						var mat: Material = mesh.surface_get_material(si)
						var mech := "pre-lit-std"
						var ud: Variant = null
						if mat is ShaderMaterial:
							mech = "unlit-formula"
							ud = float(mat.get_shader_parameter("u_day"))
						return {"mech": mech, "u_day": ud, "col": [roundf(col.r * 100000.0) / 100000.0, roundf(col.g * 100000.0) / 100000.0, roundf(col.b * 100000.0) / 100000.0]}
	return {"mech": "no-face", "u_day": null, "col": null}


# AC-0128 RUN 3: darkside = a cell whose BAKED eff is block-derived (eff
# exceeds the own-chunk sky flood - no lateral sky can explain it) yet the
# block-light flood did not VISIT (mask=0, fresh pull compute with the
# current neighbor strips). Settled state => 0 by construction: the pull eff
# = max(sky_self_flood, blk_self_flood, strip_injection_flood) and the mask
# covers exactly the two block terms. >0 = a stale eff/mask pair or an E2
# wave that has not settled. (The old RUN 2 definition - no own-chunk glow
# source within Chebyshev 13 - counted 24401 cells, all sky-derived: not a
# miss under the flood-visited mask.)
func _nd_darkside_count() -> int:
	var H: int = Data.HEIGHT
	var cnt := 0
	for cc in _nd_sorted_chunks():
		var d: PackedByteArray = cc.flat_data()
		var eff: PackedByteArray = cc.last_eff["arr"]
		var cx: int = int(cc.cx)
		var cz: int = int(cc.cz)
		var strips: Dictionary = world._strips_for(cx, cz)
		var pk: Dictionary = Lighting.compute_light_flat_chunk_pull(d, cx, cz, H, strips["eff"], strips["blk"], strips["blk_b"])
		var mask: PackedByteArray = pk["mask"]
		var sky: Dictionary = Lighting.compute_light_split({"min": Vector3i(cx * 16, 0, cz * 16), "max": Vector3i(cx * 16 + 15, H - 1, cz * 16 + 15)}, world)["sky"]
		for y in range(H):
			var row := y << 8
			for lz in range(16):
				for lx in range(16):
					var idx := row | (lz << 4) | lx
					if eff[idx] <= 0:
						continue
					var blocked := false
					for yy in range(y + 1, H):
						var bid2: int = d[(yy << 8) | (lz << 4) | lx]
						if bid2 != 0 and bid2 != 5:
							blocked = true
							break
					if not blocked:
						continue
					if mask[idx] > 0:
						continue
					var cell := Vector3i(cx * 16 + lx, y, cz * 16 + lz)
					if int(eff[idx]) <= int(sky.get(cell, 0)):
						continue
					cnt += 1
	return cnt


func _nightday_test(spawn: Vector3) -> void:
	Lighting._tables()
	world.recenter(spawn.x, spawn.z, true)
	await _nd_settle(60000)
	var picked := _nd_pick_cells()
	var cave: Array = picked.cave
	var mouth: Array = picked.mouth
	var torch: Array = await _nd_tunnel()
	if cave.is_empty() or torch.is_empty():
		Debug.result({"mode": "nightday", "seed": Game.world_seed, "radius": world.render_radius, "ok": false, "err": "no deterministic cell", "cave": cave, "torch": torch, "mouth": mouth})
		get_tree().quit()
		return
	var darkside := _nd_darkside_count()
	var ccx: int = int(cave[0])
	var ccz: int = int(cave[1])
	var clx: int = int(cave[2])
	var cy: int = int(cave[3])
	var clz: int = int(cave[4])
	var cdd: Array = [cave[5], cave[6], cave[7]]
	var cchunk: Node3D = world.chunks.get(world._key(ccx, ccz))
	var nax := clx + int(cdd[0])
	var nay := cy + int(cdd[1])
	var naz := clz + int(cdd[2])
	var npos := Vector3(float(nax), float(nay), float(naz))
	for k in range(3):
		if int(cdd[k]) < 0:
			npos[k] += 1.0
	var nnrm := Vector3(-int(cdd[0]), -int(cdd[1]), -int(cdd[2]))
	var tchunk: Node3D = world.chunks.get(world._key(int(floorf(float(torch[0]) / 16.0)), int(floorf(float(torch[2]) / 16.0))))
	var tpos: Vector3 = Vector3(float(int(torch[0]) & 15), float(int(torch[1])), float(int(torch[2]) & 15))
	var tnrm := Vector3(0, 1, 0)
	var tfound := false
	var tdata: PackedByteArray = tchunk.flat_data()
	var tidx := (int(torch[1]) << 8) | ((int(torch[2]) & 15) << 4) | (int(torch[0]) & 15)
	for dd in [[0, 1, 0], [1, 0, 0], [-1, 0, 0], [0, 0, 1], [0, 0, -1], [0, -1, 0]]:
		var ax := (int(torch[0]) & 15) + int(dd[0])
		var ay := int(torch[1]) + int(dd[1])
		var az := (int(torch[2]) & 15) + int(dd[2])
		var aid := 0
		if ax >= 0 and ax < 16 and ay >= 0 and ay < Data.HEIGHT and az >= 0 and az < 16:
			aid = int(tdata[(ay << 8) | (az << 4) | ax])
		if aid == 0:
			tpos = Vector3(float(int(torch[0]) & 15), float(int(torch[1])), float(int(torch[2]) & 15))
			for k in range(3):
				if int(dd[k]) > 0:
					tpos[k] += 1.0
			tnrm = Vector3(int(dd[0]), int(dd[1]), int(dd[2]))
			tfound = true
			break
	if not tfound:
		Debug.result({"mode": "nightday", "seed": Game.world_seed, "radius": world.render_radius, "ok": false, "err": "torch face not found", "cave": cave, "torch": torch, "mouth": mouth})
		get_tree().quit()
		return
	var cave_slab = cchunk.slabs[nay / 16]
	var torch_slab = tchunk.slabs[int(torch[1]) / 16]
	var cave_eff: int = int(cchunk.last_eff["arr"][(cy << 8) | (clz << 4) | clx])
	var torch_eff: int = int(tchunk.last_eff["arr"][(int(torch[1]) << 8) | ((int(torch[2]) & 15) << 4) | (int(torch[0]) & 15)])
	Game.time_of_day = 0.5
	_update_sky()
	var df_day := DayNight.day(Game.time_of_day)
	var cave_day: Variant = _nd_read_face([cave_slab.mesh_instance, cave_slab.flora_instance, cave_slab.fluid_instance], npos, nnrm)
	if cave_day == null or not (cave_day is Dictionary and cave_day.has("col")):
		cave_day = {"mech": "no-face", "u_day": null, "col": null}
	var torch_day: Variant = _nd_read_face([torch_slab.fluid_instance, torch_slab.mesh_instance, torch_slab.flora_instance], tpos, tnrm)
	if torch_day == null or not (torch_day is Dictionary and torch_day.has("col")):
		torch_day = {"mech": "no-face", "u_day": null, "col": null}
	Game.time_of_day = 0.0
	_update_sky()
	var df_night := DayNight.day(Game.time_of_day)
	var cave_night: Variant = _nd_read_face([cave_slab.mesh_instance, cave_slab.flora_instance, cave_slab.fluid_instance], npos, nnrm)
	if cave_night == null or not (cave_night is Dictionary and cave_night.has("col")):
		cave_night = {"mech": "no-face", "u_day": null, "col": null}
	var torch_night: Variant = _nd_read_face([torch_slab.fluid_instance, torch_slab.mesh_instance, torch_slab.flora_instance], tpos, tnrm)
	if torch_night == null or not (torch_night is Dictionary and torch_night.has("col")):
		torch_night = {"mech": "no-face", "u_day": null, "col": null}
	var out := {
		"mode": "nightday",
		"seed": Game.world_seed,
		"radius": world.render_radius,
		"darkside_candidates": darkside,
		"df_day": roundf(df_day * 100000.0) / 100000.0,
		"df_night": roundf(df_night * 100000.0) / 100000.0,
		"cave": [ccx * 16 + clx, cy, ccz * 16 + clz],
		"cave_eff": cave_eff,
		"torch": [torch[0], torch[1], torch[2]],
		"torch_eff": torch_eff,
		"mouth": ([mouth[0] * 16 + mouth[2], mouth[3], mouth[1] * 16 + mouth[4]] if mouth.size() > 0 else null),
	}
	for tag in ["day", "night"]:
		var rd: Dictionary = cave_day if tag == "day" else cave_night
		var rt: Dictionary = torch_day if tag == "day" else torch_night
		var cd: Variant = rd.col
		var ct: Variant = rt.col
		var cud: Variant = rd.u_day
		var tud: Variant = rt.u_day
		var cL: Variant = null
		var tL: Variant = null
		if cd != null and cud != null:
			# in-repo L formula (AC-0128 structure, const+gain = 1.0; user-directed
			# 0.20 floor, AC-0135 Run-2): (0.20 + 0.80 * max(uDay*r, g)) * 15
			cL = roundf((0.20 + 0.80 * maxf(float(cud) * float(cd[0]), float(cd[1]))) * 15.0 * 100000.0) / 100000.0
		elif cd != null:
			cL = roundf(float(cd[0]) * 15.0 * 100000.0) / 100000.0
		if ct != null and tud != null:
			tL = roundf((0.20 + 0.80 * maxf(float(tud) * float(ct[0]), float(ct[1]))) * 15.0 * 100000.0) / 100000.0
		elif ct != null:
			tL = roundf(float(ct[0]) * 15.0 * 100000.0) / 100000.0
		out["cave_" + tag] = {"col": cd, "u_day": cud, "class": cL, "mech": rd.mech}
		out["torch_" + tag] = {"col": ct, "u_day": tud, "class": tL, "mech": rt.mech}
	out["mech"] = cave_day.mech
	var okcave_day: float = -1.0
	var okcave_night: float = -1.0
	var oktday: float = -1.0
	var oktnight: float = -1.0
	if out.cave_day.class != null:
		okcave_day = float(out.cave_day.class)
	if out.cave_night.class != null:
		okcave_night = float(out.cave_night.class)
	if out.torch_day.class != null:
		oktday = float(out.torch_day.class)
	if out.torch_night.class != null:
		oktnight = float(out.torch_night.class)
	out["ok"] = out.mech == "unlit-formula" and okcave_day >= 14.1 and okcave_night < 5.0 and oktday == oktnight
	Debug.result(out)
	get_tree().quit()


# AC-0134 probe (env-gated by AWECRAFT_LOGIC=nightlot, never runs in game):
# the sealed-cave eff lottery census (plan §5.2). Phase A: initial-load
# settle + A1 material enumeration + A2 sealed-cave eff census (BAKED
# last_eff, NOT light_at; the mask = a fresh pull with the current strips;
# class 2 = the darkside-identical test eff>0 && mask==0 && eff>fresh-sky,
# fresh-sky = compute_light_split over the own-chunk box - the same logic
# _nd_darkside_count uses, anchor 5168 in seed 44) + A3 >=3-chunk chain.
# Phase B: recenter away/back re-roll diff (the user's "random" - re-entry
# re-pulls with the current neighbor strips). Phase C: midnight guard -
# every face bright at night (opposite air cell block-flood-visited: mask=1;
# cell-based enumeration = one face per solid-air boundary, behaviorally
# identical to the mesh walk) needs a glow source within Chebyshev 14 (the
# search runs to 15 for ring-crossing injections; the le15 variant is
# reported separately). ok = skylight==0 && legacy==0 && other==0
# && chain lottery-max==0 && recenter_diffs==0 && bright no_source==0.
var _nl_src_region: PackedByteArray = PackedByteArray()
var _nl_src_n := 0
var _nl_other_samples: Array = []


func _nl_settle_around(pcx: int, pcz: int, max_frames: int) -> int:
	# _nd_settle (main.gd:4012) with an explicit band center: the away
	# settle targets the AWAY band, not the origin band. NLDBG prints the
	# terminal state (n_in, idle, cap).
	var rr: int = world.render_radius
	var quiet := 0
	var t0 := Time.get_ticks_msec()
	var awaited := 0
	var n_in := 0
	var idle := false
	while awaited < max_frames and Time.get_ticks_msec() - t0 < 120000:
		n_in = 0
		for key in world.chunks:
			var cc: Node3D = world.chunks[key]
			if absi(int(cc.cx) - pcx) <= rr and absi(int(cc.cz) - pcz) <= rr and cc.mesh_built:
				n_in += 1
		idle = world.light_dirty.is_empty() and world.light_pending.is_empty() \
			and world.threadmesh_inflight.is_empty() and world._col_pending.is_empty()
		if n_in == (2 * rr + 1) * (2 * rr + 1) and idle:
			quiet += 1
		else:
			quiet = 0
		if quiet >= 5:
			break
		await get_tree().physics_frame
		awaited += 1
	print("NLDBG settle center=(%d,%d) waited_frames=%d n_in=%d/%d idle=%s" % [pcx, pcz, awaited, n_in, (2 * rr + 1) * (2 * rr + 1), idle])
	return awaited


func _nl_sorted_chunks() -> Array:
	var out: Array = []
	var rr: int = world.render_radius
	for key in world.chunks:
		var cc: Node3D = world.chunks[key]
		if absi(cc.cx) <= rr and absi(cc.cz) <= rr and cc.mesh_built:
			out.append(cc)
	out.sort_custom(func(a, b):
		if a.cx != b.cx:
			return a.cx < b.cx
		return a.cz < b.cz
	)
	return out


func _nl_classify_mat(m: Variant, sample_tag: String) -> String:
	if m == null:
		if _nl_other_samples.size() < 8:
			_nl_other_samples.append("null @ " + sample_tag)
		return "other"
	if m is ShaderMaterial:
		var sm: ShaderMaterial = m
		var sh: Shader = sm.shader
		if sh != null:
			var p: String = sh.resource_path
			if p.ends_with("chunk_lit_opaque.gdshader"):
				return "chunk_lit_opaque"
			if p.ends_with("chunk_lit_cutout.gdshader"):
				return "chunk_lit_cutout"
			if p.ends_with("chunk_lit_flower.gdshader"):
				return "chunk_lit_flower"
			if p.ends_with("chunk_lit_fluid.gdshader"):
				return "chunk_lit_fluid"
			# v3 (defect b): per-chunk fluid meshes use fluid_anim.gdshader
			# ShaderMaterials that fail the Data.fluid_anim_mats identity check;
			# the plan allows fluid-anim as legitimate, so classify by path.
			if p.ends_with("fluid_anim.gdshader"):
				return "fluid_anim"
		if _nl_other_samples.size() < 8:
			_nl_other_samples.append("ShaderMaterial shader=%s @ %s" % ["<null>" if sh == null else sh.resource_path, sample_tag])
		return "other"
	for bid in Data.fluid_anim_mats:
		if Data.fluid_anim_mats[bid] == m:
			return "fluid_anim"
	if m is StandardMaterial3D:
		return "legacy"
	if _nl_other_samples.size() < 8:
		_nl_other_samples.append("class=%s @ %s" % [m.get_class(), sample_tag])
	return "other"


func _nl_materials(chunks: Array) -> Dictionary:
	var counts := {"chunk_lit_opaque": 0, "chunk_lit_cutout": 0, "chunk_lit_flower": 0, "chunk_lit_fluid": 0, "fluid_anim": 0, "legacy": 0, "other": 0}
	var legacy_chunks: Array = []
	var other_chunks: Array = []
	for cc in chunks:
		var hit := {}
		for s in cc.slabs:
			for inst_kind in ["mesh", "fluid", "flora"]:
				var inst: Node3D
				if inst_kind == "mesh":
					inst = s.mesh_instance
				elif inst_kind == "fluid":
					inst = s.fluid_instance
				else:
					inst = s.flora_instance
				if inst == null or inst.mesh == null:
					continue
				var mesh: ArrayMesh = inst.mesh
				for si in range(mesh.get_surface_count()):
					var tag: String = "chunk (%d,%d) %s surf %d" % [int(cc.cx), int(cc.cz), inst_kind, si]
					var cls: String = _nl_classify_mat(mesh.surface_get_material(si), tag)
					if cls != "other":
						hit[cls] = true
					else:
						hit["other"] = true
		for cls in hit:
			counts[cls] += 1
		if hit.has("legacy"):
			legacy_chunks.append([int(cc.cx), int(cc.cz)])
		if hit.has("other"):
			other_chunks.append([int(cc.cx), int(cc.cz)])
	return {"counts": counts, "legacy_chunks": legacy_chunks, "other_chunks": other_chunks}


func _nl_interior(cell: Vector3i) -> bool:
	# true iff the cell's Chebyshev-15 ring lies fully inside the LOADED
	# band (chunks -rr..rr). Outside it, the source search misses sources in
	# the unloaded edge chunks (±(rr+1)) and false-reports "no source".
	var lo: int = -world.render_radius * 16 + 15
	var hi: int = world.render_radius * 16
	return cell.x >= lo and cell.x <= hi and cell.z >= lo and cell.z <= hi


func _nl_census_chunk(cc: Node3D) -> Dictionary:
	# sealed-cave cell (plan §5.2 A2): id 0 (air) in a CLOSED own-column
	# (column scan from the top: the cell is below the first non-passable
	# cell, so own sky = 0 by the column scan) with >=1 solid neighbor.
	# Classes: 0 eff==0; 1 eff>0 && mask>0 (legitimate block light);
	# 2 eff>0 && mask==0 && eff>fresh-sky (the sky-carry lottery -
	# darkside-identical); 3 eff>0 && mask==0 && eff<=fresh-sky (legit
	# in-chunk sky - counted in total only).
	var H: int = Data.HEIGHT
	var d: PackedByteArray = cc.flat_data()
	var eff: PackedByteArray = cc.last_eff["arr"]
	var cx: int = int(cc.cx)
	var cz: int = int(cc.cz)
	var strips: Dictionary = world._strips_for(cx, cz)
	var pk: Dictionary = Lighting.compute_light_flat_chunk_pull(d, cx, cz, H, strips["eff"], strips["blk"], strips["blk_b"])
	var mask: PackedByteArray = pk["mask"]
	var skys: Dictionary = Lighting.compute_light_split({"min": Vector3i(cx * 16, 0, cz * 16), "max": Vector3i(cx * 16 + 15, H - 1, cz * 16 + 15)}, world)["sky"]
	# AC-0134 POST discriminator: pure in-chunk kernel (empty strips).
	# Class 2 (the bug) = e > in-chunk eff => light crossed a chunk boundary.
	# Class 3 = e > 0, mask==0, e <= in-chunk eff => legit in-chunk sky
	# (lateral skylight from an open column of this chunk, MC-correct).
	var eff_ns: PackedByteArray = Lighting.compute_light_flat_chunk_pull(d, cx, cz, H, [], [], [])["arr"]
	# AC-0134 diagnostic: pk["arr"] = fresh kernel with the CURRENT strips.
	# For a class-2 cell (baked eff > in-chunk eff): if the current strips
	# reproduce the value the import is ACTIVE (strip content is the cause);
	# if not, the baked eff is STALE (baked from an earlier data/strip state
	# that was never re-lit).
	var eff_ws: PackedByteArray = pk["arr"]
	var stale := 0
	var strip_now := 0
	var stale_samples: Array = []
	var cells: Dictionary = {}
	var inchunk_sky := 0
	var ehist: Array = []
	for _ev in range(16):
		ehist.append(0)
	var total := 0
	var eff0 := 0
	var block_lit := 0
	var skylight := 0
	var sky_legit := 0
	var sky_list: Array = []
	for y in range(H):
		var row := y << 8
		for lz in range(16):
			for lx in range(16):
				var idx := row | (lz << 4) | lx
				if d[idx] != 0:
					continue
				var blocked := false
				for yy in range(y + 1, H):
					var bid2: int = d[(yy << 8) | (lz << 4) | lx]
					if bid2 != 0 and bid2 != 5:
						blocked = true
						break
				if not blocked:
					continue
				var solid_nb := false
				for dd in [[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]]:
					var ax := lx + int(dd[0])
					var ay := y + int(dd[1])
					var az := lz + int(dd[2])
					if ax < 0 or ax > 15 or ay < 0 or ay > H - 1 or az < 0 or az > 15:
						continue
					if Lighting._att[d[(ay << 8) | (az << 4) | ax]] == 0:
						solid_nb = true
						break
				if not solid_nb:
					continue
				total += 1
				var e: int = eff[idx]
				var cell := Vector3i(cx * 16 + lx, y, cz * 16 + lz)
				var cls := 0
				if e == 0:
					eff0 += 1
				elif mask[idx] > 0:
					cls = 1
					block_lit += 1
				elif e > int(eff_ns[idx]):
					# LEAK (the bug): baked eff above the pure in-chunk eff
					# => light crossed a chunk boundary.
					cls = 2
					skylight += 1
					if sky_list.size() < 8:
						sky_list.append([cx, cz, cx * 16 + lx, y, cz * 16 + lz, e])
					if int(eff_ws[idx]) < e:
						stale += 1
						if stale_samples.size() < 8:
							stale_samples.append([cx, cz, lx, y, lz, e, int(eff_ws[idx]), int(eff_ns[idx])])
					else:
						strip_now += 1
				else:
					# legit in-chunk sky: lateral skylight from an open
					# column of THIS chunk (MC-correct, deterministic).
					cls = 3
					sky_legit += 1
					if e > int(skys.get(cell, 0)):
						inchunk_sky += 1
				ehist[e] += 1
				cells[cell] = [e, cls]
	return {"cells": cells, "mask": mask, "total": total, "eff0": eff0, "block_lit": block_lit, "skylight": skylight, "sky_legit": sky_legit, "inchunk_sky": inchunk_sky, "sky_list": sky_list, "ehist": ehist, "stale": stale, "strip_now": strip_now, "stale_samples": stale_samples}


func _nl_census_all() -> Dictionary:
	var out: Dictionary = {}
	var t_c: int = Time.get_ticks_msec()
	var n_c := 0
	for cc in _nl_sorted_chunks():
		n_c += 1
		out[world._key(int(cc.cx), int(cc.cz))] = _nl_census_chunk(cc)
		if n_c % 10 == 0:
			print("NLDBG census prog chunks=%d/%d elapsed_ms=%d" % [n_c, _nl_sorted_chunks().size(), Time.get_ticks_msec() - t_c])
	print("NLDBG census done chunks=%d elapsed_ms=%d" % [n_c, Time.get_ticks_msec() - t_c])
	return out


func _nl_chain(census: Dictionary) -> Dictionary:
	# deterministic first qualifying chain (plan §5.2 A3): components of the
	# >=1-sealed-cell built-chunk graph (cheby-1 chunk adjacency) in sort
	# order; the first component of size >=3, its BFS-first 3 chunks.
	# "max" = max baked eff over those 3 chunks' sealed cells (plan literal);
	# "max_class3" = the same over class-2 (cross-chunk import) cells only;
	# "max_class3_nosrc" = the same over SOURCELESS class-2 cells (the sky-
	# leak bug; sourced ones are legit AC-0129 cross-chunk block light — the
	# gate uses this one); "block_lit_cells" = the class-1 count in the chain.
	var rr: int = world.render_radius
	var sealed_chunks: Array = []
	for key in world.chunks:
		var cc: Node3D = world.chunks[key]
		if absi(cc.cx) <= rr and absi(cc.cz) <= rr and cc.mesh_built \
				and census.has(key) and int(census[key]["total"]) > 0:
			sealed_chunks.append(cc)
	sealed_chunks.sort_custom(func(a, b):
		if a.cx != b.cx:
			return a.cx < b.cx
		return a.cz < b.cz
	)
	var visited := {}
	for root_c in sealed_chunks:
		var rk = world._key(int(root_c.cx), int(root_c.cz))
		if visited.has(rk):
			continue
		var comp: Array = []
		var frontier: Array = [root_c]
		visited[rk] = true
		while frontier.size() > 0:
			var cur: Node3D = frontier.pop_front()
			comp.append(cur)
			for ncc in sealed_chunks:
				var nk = world._key(int(ncc.cx), int(ncc.cz))
				if visited.has(nk):
					continue
				if maxi(absi(int(ncc.cx) - int(cur.cx)), absi(int(ncc.cz) - int(cur.cz))) == 1:
					visited[nk] = true
					frontier.append(ncc)
		if comp.size() < 3:
			continue
		var chain: Array = []
		var mn := 999
		var mx := -1
		var mx3 := 0
		var mx3n := 0
		var blk := 0
		for i in range(3):
			var oc: Node3D = comp[i]
			chain.append([int(oc.cx), int(oc.cz)])
			var ccens: Dictionary = census[world._key(int(oc.cx), int(oc.cz))]
			print("NLDBG chain chunk (%d,%d) sealed=%d eff0=%d block_lit=%d skylight=%d sky_legit=%d" % [int(oc.cx), int(oc.cz), int(ccens["total"]), int(ccens["eff0"]), int(ccens["block_lit"]), int(ccens["skylight"]), int(ccens["sky_legit"])])
			for cell in ccens["cells"]:
				var cv: Array = ccens["cells"][cell]
				var e2: int = int(cv[0])
				var c3: int = int(cv[1])
				mn = mini(mn, e2)
				mx = maxi(mx, e2)
				if c3 == 2:
					mx3 = maxi(mx3, e2)
					var rr3: int = _nl_src_within(cell, 15)
					if _nl_interior(cell) and (rr3 < 0 or rr3 > 14):
						mx3n = maxi(mx3n, e2)
				elif c3 == 1:
					blk += 1
		return {"found": true, "chain": chain, "component": comp.size(), "min": mn, "max": mx, "max_class3": mx3, "max_class3_nosrc": mx3n, "block_lit_cells": blk}
	return {"found": false, "chain": [], "component": 0, "min": -1, "max": -1, "max_class3": 0, "max_class3_nosrc": 0, "block_lit_cells": 0}


func _nl_srcs_build() -> void:
	# every glow source (ids 22/23/24) in any chunk with data, flattened
	# into a region grid over chunks -7..7 (a source within Chebyshev 15 of
	# any band cell is within one chunk of the band edge, well inside).
	# idx = ((x + 112) * 240 + (z + 112)) * H + y (AC-0091: H = Data.HEIGHT).
	var H: int = Data.HEIGHT
	_nl_src_region = PackedByteArray()
	_nl_src_region.resize(240 * 240 * H)
	_nl_src_n = 0
	for key in world.chunks:
		var cc: Node3D = world.chunks[key]
		if cc.data.is_empty():
			continue
		var d: PackedByteArray = cc.flat_data()
		var cx: int = int(cc.cx)
		var cz: int = int(cc.cz)
		for i in range(d.size()):
			var bid: int = d[i]
			if bid == 22 or bid == 23 or bid == 24:
				var x: int = cx * 16 + (i & 15)
				var z: int = cz * 16 + ((i >> 4) & 15)
				var y: int = i >> 8
				var xp: int = x + 112
				var zp: int = z + 112
				if xp >= 0 and xp < 240 and zp >= 0 and zp < 240:
					var ridx: int = (xp * 240 + zp) * H + y
					if _nl_src_region[ridx] == 0:
						_nl_src_region[ridx] = 1
						_nl_src_n += 1


func _nl_src_within(cell: Vector3i, rmax: int) -> int:
	# minimum Chebyshev radius (0..rmax) to any glow source, else -1.
	var H: int = Data.HEIGHT
	var xp: int = cell.x + 112
	var zp: int = cell.z + 112
	var y: int = cell.y
	if xp < 0 or xp >= 240 or zp < 0 or zp >= 240 or y < 0 or y >= H:
		return -1
	if _nl_src_region[xp * 240 * H + zp * H + y] > 0:
		return 0
	for r in range(1, rmax + 1):
		for dx in range(-r, r + 1):
			var xx: int = xp + dx
			if xx < 0 or xx >= 240:
				continue
			for dy in range(-r, r + 1):
				var yy: int = y + dy
				if yy < 0 or yy >= H:
					continue
				var zz: int = zp - r
				if zz >= 0 and zz < 240 and _nl_src_region[xx * 240 * H + zz * H + yy] > 0:
					return r
				zz = zp + r
				if zz >= 0 and zz < 240 and _nl_src_region[xx * 240 * H + zz * H + yy] > 0:
					return r
		for dx in range(-r, r + 1):
			var xx: int = xp + dx
			if xx < 0 or xx >= 240:
				continue
			for dz in range(-(r - 1), r):
				var zz: int = zp + dz
				if zz < 0 or zz >= 240:
					continue
				var yy: int = y - r
				if yy >= 0 and yy < H and _nl_src_region[xx * 240 * H + zz * H + yy] > 0:
					return r
				yy = y + r
				if yy >= 0 and yy < H and _nl_src_region[xx * 240 * H + zz * H + yy] > 0:
					return r
		for dy in range(-(r - 1), r):
			var yy: int = y + dy
			if yy < 0 or yy >= H:
				continue
			for dz in range(-(r - 1), r):
				var zz: int = zp + dz
				if zz < 0 or zz >= 240:
					continue
				var xx: int = xp - r
				if xx >= 0 and xx < 240 and _nl_src_region[xx * 240 * H + zz * H + yy] > 0:
					return r
				xx = xp + r
				if xx >= 0 and xx < 240 and _nl_src_region[xx * 240 * H + zz * H + yy] > 0:
					return r
	return -1


# AC-0134 run-2 DIAGNOSTIC (transient): follow the fresh eff backward from a
# phantom bright cell (mask=1, no glow source within Chebyshev 14). A cell at
# value v must be sustained by an adjacent cell at >= v+att, so a strictly
# increasing walk terminates in <=15 steps at a source or an inconsistency
# (stop line = the phantom's origin: a value nothing sustains).
func _nl_phantom_walk(wcell: Vector3i, faces: int, rmin: int) -> void:
	var H: int = Data.HEIGHT
	Lighting._tables()
	var caches: Dictionary = {}
	var pos := wcell
	var line: Array = []
	for step in range(30):
		var cx: int = int(floorf(pos.x / 16.0))
		var cz: int = int(floorf(pos.z / 16.0))
		var kx: String = world._key(cx, cz)
		if not caches.has(kx):
			caches[kx] = _nl_fresh_eff(kx)
		var arr: PackedByteArray = caches[kx]
		if arr == null:
			line.append([pos.x, pos.y, pos.z, "nochunk"])
			break
		var lx: int = pos.x - cx * 16
		var lz: int = pos.z - cz * 16
		var idx: int = (pos.y << 8) | (lz << 4) | lx
		var v: int = int(arr[idx])
		var extra := ""
		if step == 0:
			var cc0: Node3D = world.chunks.get(kx)
			if cc0 != null and not cc0.last_eff.is_empty():
				extra = "baked=%d" % int(cc0.last_eff["arr"][idx])
		line.append([pos.x, pos.y, pos.z, v, extra])
		if v <= 1:
			break
		var best: int = -1
		var bpos: Vector3i = pos
		for dd in [[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]]:
			var np: Vector3i = pos + Vector3i(int(dd[0]), int(dd[1]), int(dd[2]))
			if np.y < 0 or np.y >= H:
				continue
			var ncx: int = int(floorf(np.x / 16.0))
			var ncz: int = int(floorf(np.z / 16.0))
			var nk: String = world._key(ncx, ncz)
			if not caches.has(nk):
				caches[nk] = _nl_fresh_eff(nk)
			var a2: PackedByteArray = caches[nk]
			if a2 == null:
				continue
			var nidx: int = (np.y << 8) | ((np.z - ncz * 16) << 4) | (np.x - ncx * 16)
			var nv: int = int(a2[nidx])
			if nv > best:
				best = nv
				bpos = np
		if best <= v:
			line.append(["stop best=%d v=%d" % [best, v]])
			break
		pos = bpos
	print("NLDBG phantom_walk faces=%d rmin=%d from (%d,%d,%d): %s" % [faces, rmin, wcell.x, wcell.y, wcell.z, line])


func _nl_fresh_eff(key: String) -> Variant:
	var cc: Node3D = world.chunks.get(key)
	if cc == null or cc.data.is_empty():
		return null
	var H: int = Data.HEIGHT
	var st: Dictionary = world._strips_for(int(cc.cx), int(cc.cz))
	return Lighting.compute_light_flat_chunk_pull(cc.data, int(cc.cx), int(cc.cz), H, st["eff"], st["blk"], st["blk_b"])["arr"]


func _nightlot_test(spawn: Vector3) -> void:
	Lighting._tables()
	var t0 := Time.get_ticks_msec()
	# Phase A: initial load + settle
	world.recenter(spawn.x, spawn.z, true)
	await _nl_settle_around(0, 0, 60000)
	var chunks := _nl_sorted_chunks()
	var nmat := _nl_materials(chunks)
	var censusA := _nl_census_all()
	# Phase B measurement (v3.1): the user-visible eff is the BAKED array
	# (last_eff["arr"] -> vColor). A fresh-pull census (censusA/B) always
	# converges to the same fixed point (the strip reads neighbors' final
	# last_eff at dispatch), so the re-roll must be diffed on the baked
	# arrays: snapshot now, compare after the return.
	var bakedA: Dictionary = {}
	for key in censusA:
		var cca: Node3D = world.chunks.get(key)
		if cca != null and not cca.last_eff.is_empty():
			bakedA[key] = cca.last_eff["arr"].duplicate()
	_nl_srcs_build()
	var tl := 0
	var te0 := 0
	var tbl := 0
	var tsk := 0
	var tsl := 0
	# AC-0134 (fix-7): class 2 = cross-chunk import (baked eff above the
	# pure in-chunk kernel eff). Under the sky-carry eff strip (fix-7) a
	# class-2 cell is LEGIT when the current strips reproduce it (stale ==
	# 0, the gate) — imported sky corner-bleed has no glow source, so the
	# old "glow within 14" split (leak_sourced/leak_nosrc) is informational
	# only. inchunk_sky = the legit class-3 subset: lateral skylight from an
	# open column of the cell's OWN chunk.
	var tin := 0
	var leak_sourced := 0
	var leak_nosrc := 0
	var leak_nosrc_edge := 0
	var leak_nosrc_max := 0
	var leak_nosrc_first8: Array = []
	var tstale := 0
	var tstrip := 0
	var stale_first8: Array = []
	var ehist: Array = []
	for _v in range(16):
		ehist.append(0)
	var sky_first8: Array = []
	var allcells: Dictionary = {}
	for key in censusA:
		var ce: Dictionary = censusA[key]
		tl += int(ce["total"])
		te0 += int(ce["eff0"])
		tbl += int(ce["block_lit"])
		tsk += int(ce["skylight"])
		tsl += int(ce["sky_legit"])
		tin += int(ce["inchunk_sky"])
		tstale += int(ce["stale"])
		tstrip += int(ce["strip_now"])
		for i2 in range(16):
			ehist[i2] += int(ce["ehist"][i2])
		for cell in ce["cells"]:
			allcells[cell] = [int(ce["cells"][cell][0]), int(ce["cells"][cell][1])]
		for p in ce["sky_list"]:
			if sky_first8.size() < 8:
				sky_first8.append(p)
		for p in ce["stale_samples"]:
			if stale_first8.size() < 8:
				stale_first8.append(p)
	for cell in allcells:
		var pv: Array = allcells[cell]
		if int(pv[1]) == 2:
			var ee: int = int(pv[0])
			var rr2: int = _nl_src_within(cell, 15)
			if rr2 < 0 or rr2 > 14:
				if _nl_interior(cell):
					leak_nosrc += 1
					leak_nosrc_max = maxi(leak_nosrc_max, ee)
					if leak_nosrc_first8.size() < 8:
						leak_nosrc_first8.append([cell.x, cell.y, cell.z, ee, rr2])
				else:
					leak_nosrc_edge += 1
			else:
				leak_sourced += 1
	var bno := 0
	var bno15 := 0
	for cell in allcells:
		var pv: Array = allcells[cell]
		if int(pv[1]) == 1:
			var rr15: int = _nl_src_within(cell, 15)
			if rr15 < 0 or rr15 > 14:
				bno += 1
			if rr15 < 0:
				bno15 += 1
	var chain := _nl_chain(censusA)
	print("NLDBG censusA chunks=%d sealed=%d eff0=%d block_lit=%d leak=%d (sourced=%d nosrc_int=%d nosrc_edge=%d max=%d stale=%d strip_now=%d) sky_legit=%d inchunk=%d srcs=%d" % [censusA.size(), tl, te0, tbl, tsk, leak_sourced, leak_nosrc, leak_nosrc_edge, leak_nosrc_max, tstale, tstrip, tsl, tin, _nl_src_n])
	# Phase B: the re-roll (the user's "random") - TWO recenter events >=200
	# blocks away, then back. One hop only makes the origin band a candidate
	# (cand_since=1): data + last_eff + eff-cache entries survive, so re-entry
	# serves the cached initial eff for the cave chunks (v3.1 measured:
	# cache_hits=45/81, baked_diffs=0 - the lottery cells sit in the late-
	# built, never-evicted west chunks). The second hop (cand_since=2) FREES
	# the origin (world.gd:1386-1402: chunks.erase + queued_keys.erase +
	# _eff_cache_evict) -> the return is a full regeneration + rebuild, and
	# with the west look the build order differs from the initial east-first
	# load -> the build-order lottery re-resolves (a true re-roll).
	var px_away: float = spawn.x + 256.0
	var pz_away: float = spawn.z + 256.0
	world.recenter(px_away, pz_away, true)
	await _nl_settle_around(int(floorf(px_away / 16.0)), int(floorf(pz_away / 16.0)), 60000)
	world.recenter(spawn.x + 384.0, spawn.z + 384.0, true)
	await _nl_settle_around(24, 24, 60000)
	print("NLDBG hop2 origin_freed=%d chunks=%d" % [int(world.chunks.get("0,0") == null), world.chunks.size()])
	world.recenter(spawn.x, spawn.z, true)
	# v3 (defect a): the return recenter alone dead-ends. _remove_entry
	# (world.gd:910) never erases queued_keys, so every build entry consumed at
	# initial load leaves a stale "build" mapping; _rec_want_step (world.gd:1485)
	# reads old=="build" as "still queued" and skips the re-entrant chunks
	# (candidate, mesh_built=false, data kept) -> nothing is re-queued -> the
	# band never rebuilds (v2: 7200 frames, n_in=0/81, idle=true). Erase the
	# stale mappings for in-band unbuilt chunks, then issue a no-move recenter
	# so the WANT pass re-queues them. At this moment band_buckets holds only
	# out-of-band away-ring data entries (no live in-band build entries), so the
	# erase touches only stale mappings. FOLLOW-UP (world.gd, out of AC-0134
	# fence): _remove_entry should erase queued_keys — also a latent walk-back
	# hole in normal play (self-heals only after the chunk is freed).
	var rr_nl: int = world.render_radius
	var stale := 0
	for key in world.chunks:
		var cc: Node3D = world.chunks[key]
		if absi(int(cc.cx)) <= rr_nl and absi(int(cc.cz)) <= rr_nl and not cc.mesh_built:
			if world.queued_keys.get(key) == "build":
				world.queued_keys.erase(key)
				stale += 1
	print("NLDBG return_stale_build=%d queue_size=%d inband_built=%d" % [stale, world.queue_size, _nl_sorted_chunks().size()])
	# How many origin chunks will the eff cache serve on re-entry (hit = no
	# re-pull, baked eff stays initial)? Validation mirrors _eff_for (world.gd:1179).
	var n_cache := 0
	var per_chunk_diff: Dictionary = {}
	for key in censusA:
		var ccc: Node3D = world.chunks.get(key)
		if ccc == null:
			continue
		var ent: Dictionary = world._eff_cache.get(key, {})
		var hit: bool = not ent.is_empty() and ent.get("data") == ccc.data \
				and ent.get("ngen") == world._ngens_for(int(ccc.cx), int(ccc.cz))
		if hit:
			n_cache += 1
		per_chunk_diff[key] = hit
	print("NLDBG cache_hits=%d/%d" % [n_cache, censusA.size()])
	# The re-roll needs a DIFFERENT build order than the initial load: with an
	# identical order (no player -> _look_dir pinned (1,0), px=pz=0) the drain
	# is fully deterministic and re-entry re-derives the same eff (diffs would
	# be 0 by construction). A real walk-back turns around: face back toward
	# spawn (west) so the score-driven pick order reverses along x.
	# _refresh_look_dir() (world.gd:702) early-returns when Game.player == null,
	# so the probe-set direction holds.
	world._look_dir = Vector2(-1.0, 0.0)
	world.recenter(spawn.x, spawn.z, true)
	await _nl_settle_around(0, 0, 60000)
	var censusB := _nl_census_all()
	var allcellsB: Dictionary = {}
	var bsealed := 0
	for key in censusB:
		var ce: Dictionary = censusB[key]
		bsealed += int(ce["total"])
		for cell in ce["cells"]:
			allcellsB[cell] = [int(ce["cells"][cell][0]), int(ce["cells"][cell][1])]
	var diffs := 0
	for cell in allcells:
		var pa: Array = allcells[cell]
		var pb: Variant = allcellsB.get(cell)
		if pb == null or int(pb[0]) != int(pa[0]) or int(pb[1]) != int(pa[1]):
			diffs += 1
	# v3.1: the REAL re-roll measurement — diff the BAKED eff arrays
	# (last_eff["arr"], snapshot A vs now) over the sealed cells. This is
	# what the user sees (vColor); the per-chunk line pairs each chunk's
	# cache-hit flag with its baked-diff count.
	var baked_diffs := 0
	var baked_samples: Array = []
	var per_chunk: Array = []
	for key in censusA:
		var ccb: Node3D = world.chunks.get(key)
		var ea: PackedByteArray = bakedA.get(key, PackedByteArray())
		if ccb == null or ea.is_empty() or ccb.last_eff.is_empty():
			continue
		var eb: PackedByteArray = ccb.last_eff["arr"]
		var cd := 0
		for cell in censusA[key]["cells"]:
			var idx: int = int(cell.y) * 256 + int(cell.z) * 16 + int(cell.x)
			if ea[idx] != eb[idx]:
				cd += 1
				if baked_samples.size() < 8:
					baked_samples.append([int(cell.x), int(cell.y), int(cell.z), int(ea[idx]), int(eb[idx])])
		baked_diffs += cd
		if cd > 0:
			per_chunk.append([int(ccb.cx), int(ccb.cz), "hit" if per_chunk_diff.get(key) else "miss", cd])
	print("NLDBG baked_diffs=%d cache_hits=%d/%d per_chunk=%s samples=%s" % [baked_diffs, n_cache, censusA.size(), per_chunk, baked_samples])
	print("NLDBG censusB chunks=%d sealed=%d built_now=%d" % [censusB.size(), bsealed, _nl_sorted_chunks().size()])
	# Phase C: the midnight guard (the visual symptom)
	Game.time_of_day = 0.0
	_update_sky()
	_nl_srcs_build()
	var H: int = Data.HEIGHT
	var att := Lighting._att
	var offs: Array = [[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]]
	var bright_total := 0
	var bright_no_source := 0
	var bright_no15 := 0
	# AC-0134: the 15-ring source search only sees LOADED chunks (the r4
	# band). Edge cells whose ring reaches an unloaded edge chunk false-
	# positive as "no source" (the light is legit cross-chunk block light,
	# AC-0129). Gate on INTERIOR cells only (see _nl_interior); report the
	# band-wide total too.
	var bright_no_source_interior := 0
	var mask_air := 0
	var t_c: int = Time.get_ticks_msec()
	var n_c := 0
	# AC-0134 run-2 DIAGNOSTIC: capture phantom bright cells (mask=1, no
	# source within 14) for a backward max-plus walk (see _nl_phantom_walk).
	var phantoms: Array = []
	for key in censusB:
		var ce: Dictionary = censusB[key]
		var mask: PackedByteArray = ce["mask"]
		var cc: Node3D = world.chunks.get(key)
		if cc == null:
			continue
		var d: PackedByteArray = cc.flat_data()
		var cx: int = int(cc.cx)
		var cz: int = int(cc.cz)
		for y in range(H):
			var row := y << 8
			for lz in range(16):
				for lx in range(16):
					var idx := row | (lz << 4) | lx
					if d[idx] != 0 or mask[idx] == 0:
						continue
					mask_air += 1
					# solid-neighbor test first (cheap); the source search only
					# matters for cells that actually own a bright face.
					var faces := 0
					for dd in offs:
						var ax := lx + int(dd[0])
						var ay := y + int(dd[1])
						var az := lz + int(dd[2])
						if ax < 0 or ax > 15 or ay < 0 or ay > H - 1 or az < 0 or az > 15:
							continue
						if att[d[(ay << 8) | (az << 4) | ax]] == 0:
							faces += 1
					if faces == 0:
						continue
					bright_total += faces
					var wx: int = cx * 16 + lx
					var wz: int = cz * 16 + lz
					var wcell := Vector3i(wx, y, wz)
					var rmin: int = _nl_src_within(wcell, 15)
					if rmin < 0 or rmin > 14:
						bright_no_source += faces
						if _nl_interior(wcell):
							bright_no_source_interior += faces
							if phantoms.size() < 8:
								phantoms.append([wcell, faces, rmin])
						if rmin < 0:
							bright_no15 += faces
		n_c += 1
		if n_c % 10 == 0:
			print("NLDBG phaseC prog chunks=%d mask_air=%d elapsed_ms=%d" % [n_c, mask_air, Time.get_ticks_msec() - t_c])
	print("NLDBG phaseC mask_air=%d faces=%d no_src14=%d no_src15=%d no_src_int=%d elapsed_ms=%d" % [mask_air, bright_total, bright_no_source, bright_no15, bright_no_source_interior, Time.get_ticks_msec() - t_c])
	for ph in phantoms:
		_nl_phantom_walk(Vector3i(ph[0]), int(ph[1]), int(ph[2]))
	# AC-0134 ok (fix-7 GATE REFINEMENT — documented deviation from the
	# run-2 spec): the run-2 gate (leak_nosrc == 0, "class-2 cell with no
	# GLOW source within 14") assumed imports are BLOCK-only. That premise
	# is wrong physics: sky light crosses chunk boundaries in Minecraft,
	# and AC-0129's shipped sky-carry eff strip implements exactly that
	# (its lightaudit — 0 cliffs — depended on it; a blk-only eff strip
	# produces 1173 false "cliffs": 14 on the open side, 0 across the
	# boundary, the in-chunk value provably not block light). The direct
	# physical test for a class-2 (imported, unmasked) cell is STALENESS:
	# the fresh kernel with the CURRENT strips must reproduce the baked
	# value (stale = baked > fresh-with-strips, summed as leak_stale).
	# Strips only carry the neighbor's true settled eff (sky-carry) or
	# sourced final block light, so a reproduced value is physical by
	# induction; an unreproduced value is stale/phantom (the AC-0134 bug
	# class — stale eff from an earlier world state). leak_nosrc (no glow
	# within 14) AND chain.max_class3_nosrc (the same glow-distance test on
	# the first 3-chunk canary) are kept INFORMATIONAL: under sky-carry
	# both are expected > 0 because legit sky corner-bleed has no glow
	# source. This run: leak_stale == 0 (every imported cell reproduced by
	# the current strips) => the 4-valued chain cells are reproducible sky,
	# not phantoms. baked_diffs (Phase B) guards path independence of the
	# BAKED eff.
	var ok: bool = tstale == 0 and int(nmat["counts"]["legacy"]) == 0 \
			and int(nmat["counts"]["other"]) == 0 \
			and int(diffs) == 0 and int(baked_diffs) == 0 \
			and bright_no_source_interior == 0
	Debug.result({
		"mode": "nightlot",
		"seed": Game.world_seed,
		"radius": world.render_radius,
		"chunks_built": chunks.size(),
		"materials": {
			"chunk_lit_opaque": int(nmat["counts"]["chunk_lit_opaque"]),
			"chunk_lit_cutout": int(nmat["counts"]["chunk_lit_cutout"]),
			"chunk_lit_flower": int(nmat["counts"]["chunk_lit_flower"]),
			"chunk_lit_fluid": int(nmat["counts"]["chunk_lit_fluid"]),
			"fluid_anim": int(nmat["counts"]["fluid_anim"]),
			"legacy": int(nmat["counts"]["legacy"]),
			"other": int(nmat["counts"]["other"]),
			"legacy_chunks": nmat["legacy_chunks"],
			"other_chunks": nmat["other_chunks"],
		},
		"sealed_cells": {"total": tl, "eff0": te0, "block_lit": tbl, "leak": tsk, "leak_sourced": leak_sourced, "leak_nosrc": leak_nosrc, "leak_nosrc_edge": leak_nosrc_edge, "leak_nosrc_max": leak_nosrc_max, "leak_stale": tstale, "leak_strip_now": tstrip, "sky_legit": tsl, "inchunk_sky": tin, "ehist": ehist},
		"leak_cells": sky_first8,
		"leak_nosrc_cells": leak_nosrc_first8,
		"leak_stale_cells": stale_first8,
		"chain": chain["chain"],
		"chain_max_eff": int(chain.get("max", -1)),
		"chain_max_eff_class3": int(chain.get("max_class3", -1)),
		"chain_max_eff_class3_nosrc": int(chain.get("max_class3_nosrc", 0)),
		"chain_block_lit_cells": int(chain.get("block_lit_cells", 0)),
		"chain_min_eff": int(chain.get("min", -1)),
		"recenter_diffs": diffs,
		"recenter_diffs_baked": baked_diffs,
		"block_lit_no_src_le14": bno,
		"block_lit_no_src_le15": bno15,
		"bright_faces": {"total": bright_total, "no_source": bright_no_source, "no_source_le15": bright_no15, "no_source_interior": bright_no_source_interior},
		"src_count": _nl_src_n,
		"other_samples": _nl_other_samples,
		"elapsed_ms": Time.get_ticks_msec() - t0,
		"ok": ok,
	})
	get_tree().quit()



# AC-0035 probe (env-gated by AWECRAFT_LOGIC=viewlight, never runs in game):
# steady-settle r4; deterministic cells borrowed from the proven _light_test
# battery pattern (surface eff-15 / light-0 pocket / torch 14); measures the
# viewmodel rendered light (the in-repo AC-0128 L formula at the player eye
# cell; user-directed 0.20 floor since AC-0135 Run-2) + star opacity at
# t 0.0/0.5 + the player-light contribution. PRE (no feature) reports the
# current mechanism (shared lit material albedo white -> mat_L 1.0 at every
# cell = the bug; no stars; no player light). POST reports the unshaded
# player-local values + the star node + the player light.
func _vl_r5(x: float) -> float:
	return roundf(x * 100000.0) / 100000.0


func _vl_measure(cell: Vector3i) -> Dictionary:
	player.position = Vector3(float(cell.x) + 0.5, float(cell.y) - 1.0, float(cell.z) + 0.5)
	var l: Dictionary = world.light_at(cell.x, cell.y, cell.z)
	var sky: float = float(l.sky)
	var blk: float = float(l.block)
	var day := DayNight.day(Game.time_of_day)
	var lno := 0.20 + 0.80 * maxf(day * sky / 15.0, blk / 15.0)
	var lvl: float = 0.0
	var lvm := lno
	if player.has_method("vm_refresh"):
		lvl = float(player.PLAYER_LIGHT_LEVEL)
		lvm = maxf(lno, 0.12 + 0.88 * minf(lvl, 15.0) / 15.0)
		player.vm_refresh(true)
	var mat_l := 1.0
	var mo = player.held_box.material_override if player.held_box != null else null
	if mo is StandardMaterial3D:
		mat_l = float((mo as StandardMaterial3D).albedo_color.r)
	return {
		"sky": int(sky),
		"blk": int(blk),
		"eff": int(l.eff),
		"vm_no_pl": _vl_r5(lno),
		"vm": _vl_r5(lvm),
		"pl_contrib": _vl_r5(lvm - lno),
		"mat_L": _vl_r5(mat_l),
	}


func _viewlight_test(spawn: Vector3) -> void:
	var t0 := Time.get_ticks_msec()
	Lighting._tables()
	world.recenter(spawn.x, spawn.z, true)
	await _nd_settle(60000)
	var has_vm: bool = player != null and player.has_method("vm_refresh")
	var star_present: bool = _star_mat != null
	var sx := int(spawn.x)
	var sz := int(spawn.z)
	var top: int = world.surface_top(sx, sz)
	var surface_cell := Vector3i(-1, -1, -1)
	for dx in range(-6, 7, 3):
		if surface_cell.x >= 0:
			break
		for dz in range(-6, 7, 3):
			var tt: int = world.surface_top(sx + dx, sz + dz)
			var cell := Vector3i(sx + dx, tt + 1, sz + dz)
			if world.get_block(cell.x, cell.y, cell.z) != 0:
				continue
			var l: Dictionary = world.light_at(cell.x, cell.y, cell.z)
			if int(l.eff) >= 15:
				surface_cell = cell
				break
	var lavas: Array[Vector3i] = []
	for lx in range(sx - 36, sx + 37):
		for lz in range(sz - 36, sz + 37):
			for ly in range(0, 8):
				if world.get_block(lx, ly, lz) == WorldGen.B_LAVA:
					lavas.append(Vector3i(lx, ly, lz))
	var pocket := Vector3i(-1, -1, -1)
	var depth := 6
	while depth < 30 and pocket.x < 0:
		var cy: int = top - depth
		if cy >= 5:
			for dx in range(-16, 17):
				if pocket.x >= 0:
					break
				for dz in range(-16, 17):
					var cx := sx + dx
					var cz := sz + dz
					if world.get_block(cx, cy, cz) != 0:
						continue
					if not _is_solid(cx, cy + 1, cz):
						continue
					if cy < 23:
						var farx := cx + 5
						var clear := true
						for lav in lavas:
							if absi(lav.x - cx) + absi(lav.y - cy) + absi(lav.z - cz) < 15 \
									or absi(lav.x - farx) + absi(lav.y - cy) + absi(lav.z - cz) < 15:
								clear = false
								break
						if not clear:
							continue
					var far := Vector3i(cx + 5, cy, cz)
					for i in range(1, 6):
						var c := Vector3i(cx + i, cy, cz)
						if world.get_block(c.x, c.y, c.z) != 0:
							world.set_block(c.x, c.y, c.z, 0)
					var lb: Dictionary = world.light_at(far.x, far.y, far.z)
					if int(lb.eff) > 5:
						continue
					var l0: Dictionary = world.light_at(cx, cy, cz)
					if int(l0.eff) != 0:
						continue
					pocket = Vector3i(cx, cy, cz)
					break
		depth += 1
	if surface_cell.x < 0 or pocket.x < 0:
		Debug.result({"mode": "viewlight", "seed": Game.world_seed, "radius": world.render_radius, "ok": false, "err": "no deterministic cell", "surface": [surface_cell.x, surface_cell.y, surface_cell.z], "pocket": [pocket.x, pocket.y, pocket.z], "elapsed_ms": Time.get_ticks_msec() - t0})
		get_tree().quit()
		return
	player.inv_add(22, 1)
	player.sel = player.find_slot(22)
	player.refresh_held()
	for i in 3:
		await get_tree().process_frame
	var noon_day: float = DayNight.day(0.5)
	var mid_day: float = DayNight.day(0.0)
	Game.time_of_day = 0.5
	_update_sky()
	var op_noon := -1.0
	if star_present:
		op_noon = float(_star_mat.get_shader_parameter("u_opacity"))
	var outdoor := _vl_measure(surface_cell)
	Game.time_of_day = 0.0
	_update_sky()
	var op_mid := -1.0
	if star_present:
		op_mid = float(_star_mat.get_shader_parameter("u_opacity"))
	var cave0 := _vl_measure(pocket)
	world.set_block(pocket.x, pocket.y, pocket.z, 22)
	var torch := _vl_measure(pocket)
	var lvl: float = float(player.PLAYER_LIGHT_LEVEL) if has_vm else 0.0
	var pl_d0: float = 0.12 + 0.88 * minf(lvl, 15.0) / 15.0
	var out := {
		"mode": "viewlight",
		"seed": Game.world_seed,
		"radius": world.render_radius,
		"mechanism": "post-viewlight" if has_vm else "pre-no-viewlight",
		"uDay_noon": _vl_r5(noon_day),
		"uDay_mid": _vl_r5(mid_day),
		"outdoor": outdoor,
		"cave0": cave0,
		"torch": torch,
		"star": {
			"present": star_present,
			"count": 500 if star_present else 0,
			"opacity_noon": _vl_r5(op_noon) if star_present else null,
			"opacity_midnight": _vl_r5(op_mid) if star_present else null,
		},
		"player_light": {"level": lvl, "d0": _vl_r5(pl_d0)},
		"ambient_night": _vl_r5(DayNight.ambient_energy(0.0)),
		"surface_cell": [surface_cell.x, surface_cell.y, surface_cell.z],
		"pocket_cell": [pocket.x, pocket.y, pocket.z],
		"elapsed_ms": Time.get_ticks_msec() - t0,
	}
	var ok := false
	if has_vm:
		ok = float(outdoor.mat_L) >= 0.94 and float(cave0.vm_no_pl) <= 0.20 + 0.001 \
				and float(cave0.vm) > float(cave0.vm_no_pl) \
				and absf(float(torch.mat_L) - 0.94667) <= 0.01 \
				and star_present and op_noon < 0.05 and op_mid > 0.95
	out["ok"] = ok
	Debug.result(out)
	get_tree().quit()


# AC-0135 probe (env-gated by AWECRAFT_LOGIC=floor, never runs in game):
# steady-settle r4; deterministic sealed eff-0 pocket + eff-15 open-sky cell
# + torch placed in the pocket; measures the exact unlit formula the four
# chunk_lit shaders run (AC-0128 structure, const+gain = 1.0; user-directed
# 0.20 floor, AC-0135 Run-2 2026-08-29):
#   L = 0.20 + 0.80 * max(u_day * sky, blk)
# at midnight (t 0.0, u_day 0) and noon (t 0.5, u_day 1). The 0.20 constant
# is the user-directed night ambient floor (~20% of full sunlight): an eff-0
# cave renders 0.20 (3.0/15) day AND night; const+gain = 1.0 keeps noon
# full-sky EXACT 1.0. Pinned here: eff-0 at midnight = 0.20 (L15 3.0) exactly,
# pocket day==night, torch 0.94667 (0.20+0.80*14/15) day==night, open-sky
# noon 1.0, open-midnight == pocket-midnight, u_day 0.0/1.0.
func _floor_scan_cells() -> Dictionary:
	var H: int = Data.HEIGHT
	var pocket := Vector3i(-1, -1, -1)
	var open_cell := Vector3i(-1, -1, -1)
	for cc in _nd_sorted_chunks():
		if pocket.x >= 0 and open_cell.x >= 0:
			break
		if absi(int(cc.cx)) > 3 or absi(int(cc.cz)) > 3:
			continue
		var d: PackedByteArray = cc.flat_data()
		var eff: PackedByteArray = cc.last_eff["arr"]
		for y in range(H):
			if pocket.x >= 0 and open_cell.x >= 0:
				break
			var row := y << 8
			for lz in range(16):
				if pocket.x >= 0 and open_cell.x >= 0:
					break
				for lx in range(16):
					var idx := row | (lz << 4) | lx
					if d[idx] != 0:
						continue
					var e: int = eff[idx]
					if e == 0 and pocket.x < 0:
						pocket = Vector3i(int(cc.cx) * 16 + lx, y, int(cc.cz) * 16 + lz)
					elif e == 15 and open_cell.x < 0:
						open_cell = Vector3i(int(cc.cx) * 16 + lx, y, int(cc.cz) * 16 + lz)
	return {"pocket": pocket, "open": open_cell}


func _floor_L(cell: Vector3i, day: float) -> Dictionary:
	var l: Dictionary = world.light_at(cell.x, cell.y, cell.z)
	var sky: float = float(l.sky)
	var blk: float = float(l.block)
	var lno := 0.20 + 0.80 * maxf(day * sky / 15.0, blk / 15.0)
	return {"sky": int(sky), "blk": int(blk), "eff": int(l.eff), "L": _vl_r5(lno), "L15": _vl_r5(lno * 15.0)}


func _floor_mat_u_day() -> float:
	for k in _ChunkScriptM._mat_cache:
		var cm = _ChunkScriptM._mat_cache[k]
		if cm is ShaderMaterial:
			return float(cm.get_shader_parameter("u_day"))
	return -1.0


func _floor_test(spawn: Vector3) -> void:
	var t0 := Time.get_ticks_msec()
	Lighting._tables()
	world.recenter(spawn.x, spawn.z, true)
	await _nd_settle(60000)
	var cells: Dictionary = _floor_scan_cells()
	var pocket: Vector3i = cells.pocket
	var open_cell: Vector3i = cells.open
	if pocket.x < 0 or open_cell.x < 0:
		Debug.result({"mode": "floor", "seed": Game.world_seed, "radius": world.render_radius, "ok": false, "err": "no deterministic cell", "pocket": [pocket.x, pocket.y, pocket.z], "open": [open_cell.x, open_cell.y, open_cell.z], "elapsed_ms": Time.get_ticks_msec() - t0})
		get_tree().quit()
		return
	Game.time_of_day = 0.0
	_update_sky()
	var pocket_mid := _floor_L(pocket, DayNight.day(0.0))
	var open_mid := _floor_L(open_cell, DayNight.day(0.0))
	var u_mid := _floor_mat_u_day()
	Game.time_of_day = 0.5
	_update_sky()
	var pocket_noon := _floor_L(pocket, DayNight.day(0.5))
	var open_noon := _floor_L(open_cell, DayNight.day(0.5))
	var u_noon := _floor_mat_u_day()
	world.set_block(pocket.x, pocket.y, pocket.z, 22)
	var torch_mid := _floor_L(pocket, DayNight.day(0.0))
	var torch_noon := _floor_L(pocket, DayNight.day(0.5))
	world.set_block(pocket.x, pocket.y, pocket.z, 0)
	var out := {
		"mode": "floor",
		"seed": Game.world_seed,
		"radius": world.render_radius,
		"mech": "user-directed-0.20-const-floor (AC-0128 L-formula structure, AC-0135 Run-2)",
		"spec_floor": 0.20,
		"actual_floor": _vl_r5(float(pocket_mid.L)),
		"u_day_mid": _vl_r5(u_mid),
		"u_day_noon": _vl_r5(u_noon),
		"pocket": [pocket.x, pocket.y, pocket.z],
		"open": [open_cell.x, open_cell.y, open_cell.z],
		"pocket_mid": pocket_mid,
		"pocket_noon": pocket_noon,
		"open_mid": open_mid,
		"open_noon": open_noon,
		"torch_mid": torch_mid,
		"torch_noon": torch_noon,
		"elapsed_ms": Time.get_ticks_msec() - t0,
	}
	var ok := int(pocket_mid.eff) == 0 \
			and absf(float(pocket_mid.L) - 0.20) <= 0.001 \
			and absf(float(pocket_mid.L15) - 3.0) <= 0.001 \
			and float(pocket_mid.L) == float(pocket_noon.L) \
			and absf(float(torch_mid.L) - 0.94667) <= 0.001 \
			and float(torch_mid.L) == float(torch_noon.L) \
			and absf(float(open_noon.L) - 1.0) <= 0.001 \
			and float(open_mid.L) == float(pocket_mid.L) \
			and int(open_noon.eff) == 15 \
			and u_mid == 0.0 and u_noon == 1.0
	out["ok"] = ok
	Debug.result(out)
	get_tree().quit()


# AC-0138 probe (env-gated by AWECRAFT_LOGIC=leaves, inert unless set):
# steady-settle spawn; finds the first lit exposed leaves (id 7) cell in
# deterministic chunk order, samples the ACTUAL cutout-surface vertex
# (vColor + UV) from the built mesh plus the atlas texel under that UV,
# then evaluates the shader-side L (AC-0135 formula, AC-0136 filter_nearest
# sampling) at day (u_day=1) and night (u_day=0). Gates: day L>0.25,
# night L>=0.18 (floor), albedo green >0.15, rendered green not black.
func _leaves_tile_center(aimg: Image) -> Array:
	if aimg == null:
		return [-1, -1, -1, -1]
	var rc := Data.block_rect(7, "side")
	if rc.x < 0:
		return [-1, -1, -1, -1]
	var a: Color = aimg.get_pixel(rc.x + 15, rc.y + 15)
	var b: Color = aimg.get_pixel(rc.x + 16, rc.y + 16)
	return [
		roundf((a.r + b.r) / 2.0 * 255.0),
		roundf((a.g + b.g) / 2.0 * 255.0),
		roundf((a.b + b.b) / 2.0 * 255.0),
		roundf((a.a + b.a) / 2.0 * 255.0),
	]


func _leaves_test(spawn: Vector3) -> void:
	var t0 := Time.get_ticks_msec()
	Lighting._tables()
	world.recenter(spawn.x, spawn.z, true)
	await _nd_settle(60000)
	var H: int = Data.HEIGHT
	var rc := Data.block_rect(7, "side")
	var u0: float = (float(rc.x) + 0.5) / 1024.0
	var u1: float = (float(rc.x) + 31.5) / 1024.0
	var v0: float = (float(rc.y) + 0.5) / 1024.0
	var v1: float = (float(rc.y) + 31.5) / 1024.0
	var cell := Vector3i(-1, -1, -1)
	var ccx := 0
	var ccy := 0
	var pick := false
	var dbg := {"chunks": 0, "leaf_cells": 0, "exposed": 0, "lit": 0}
	for lit_req in [true, false]:
		if pick:
			break
		for cc in _nd_sorted_chunks():
			if absi(int(cc.cx)) > 2 or absi(int(cc.cz)) > 2:
				continue
			var d: PackedByteArray = cc.flat_data()
			var eff: PackedByteArray = cc.last_eff["arr"]
			if eff.size() != H * 256:
				continue
			dbg["chunks"] += 1
			for y in range(10, H):
				if pick:
					break
				var row := y << 8
				for lz in range(16):
					if pick:
						break
					for lx in range(16):
						var idx := row | (lz << 4) | lx
						if d[idx] != 7:
							continue
						dbg["leaf_cells"] += 1
						if int(eff[idx]) > 0:
							dbg["lit"] += 1
						if lit_req and int(eff[idx]) <= 0:
							continue
						var wx := int(cc.cx) * 16 + lx
						var wz := int(cc.cz) * 16 + lz
						var exposed := false
						for fd in VoxelMath.FACES:
							var n: Vector3i = fd.n
							var ny := y + n.y
							if ny < 0 or ny >= H:
								continue
							var nb: int = world.get_block(wx + n.x, ny, wz + n.z)
							if nb == 7:
								continue
							var ninfo = Data.block(nb) if nb != 0 else null
							if nb != 0 and ninfo != null and bool(ninfo.solid):
								continue
							exposed = true
							break
						if not exposed:
							continue
						dbg["exposed"] += 1
						cell = Vector3i(wx, y, wz)
						ccx = int(cc.cx)
						ccy = int(cc.cz)
						pick = true
						break
	if not pick:
		Debug.result({"mode": "leaves", "seed": Game.world_seed, "radius": world.render_radius, "ok": false, "err": "no exposed leaves cell", "dbg": dbg, "elapsed_ms": Time.get_ticks_msec() - t0})
		get_tree().quit()
		return
	var linfo: Dictionary = world.light_at(cell.x, cell.y, cell.z)
	var u_day_cut := -1.0
	var mat_path := ""
	var cut_tex: Texture2D = null
	for k in _ChunkScriptM._mat_cache:
		var cm = _ChunkScriptM._mat_cache[k]
		if cm is ShaderMaterial and String(cm.shader.resource_path).ends_with("chunk_lit_cutout.gdshader"):
			u_day_cut = float(cm.get_shader_parameter("u_day"))
			mat_path = String(cm.shader.resource_path)
			cut_tex = cm.get_shader_parameter("tex")
	var aimg: Image = null
	if cut_tex != null:
		aimg = cut_tex.get_image()
	if aimg == null and Data.atlas_tex != null:
		aimg = Data.atlas_tex.get_image()
	var bake_check := {"tint": [roundf(Data.TINT_LEAVES.r * 255.0), roundf(Data.TINT_LEAVES.g * 255.0), roundf(Data.TINT_LEAVES.b * 255.0)]}
	var dimg: Image = Data.atlas_tex.get_image() if Data.atlas_tex != null else null
	if dimg != null:
		bake_check["data_fmt"] = str(int(dimg.get_format()))
		bake_check["data_px_320_31"] = [roundf(dimg.get_pixel(320, 31).r * 255.0), roundf(dimg.get_pixel(320, 31).g * 255.0), roundf(dimg.get_pixel(320, 31).b * 255.0), roundf(dimg.get_pixel(320, 31).a * 255.0)]
		bake_check["data_px_322_2"] = [roundf(dimg.get_pixel(322, 2).r * 255.0), roundf(dimg.get_pixel(322, 2).g * 255.0), roundf(dimg.get_pixel(322, 2).b * 255.0), roundf(dimg.get_pixel(322, 2).a * 255.0)]
	if aimg != null:
		bake_check["cut_fmt"] = str(int(aimg.get_format()))
		bake_check["cut_px_320_31"] = [roundf(aimg.get_pixel(320, 31).r * 255.0), roundf(aimg.get_pixel(320, 31).g * 255.0), roundf(aimg.get_pixel(320, 31).b * 255.0), roundf(aimg.get_pixel(320, 31).a * 255.0)]
	var colv := Color(0.0, 0.0, 0.0, 1.0)
	var uvv := Vector2.ZERO
	var found_v := false
	var scan := {"leaves_texels": 0, "black_texels": 0, "col_b_zero": 0, "col_rg_zero": 0}
	if aimg != null:
		var lxi := cell.x - ccx * 16
		var lzi := cell.z - ccy * 16
		for cc in _nd_sorted_chunks():
			if absi(int(cc.cx)) > 2 or absi(int(cc.cz)) > 2:
				continue
			for s in cc.slabs:
				var fi = s.flora_instance
				if fi == null or fi.mesh == null:
					continue
				var m: ArrayMesh = fi.mesh
				for si in range(m.get_surface_count()):
					var mat = m.surface_get_material(si)
					if not (mat is ShaderMaterial):
						continue
					if not String(mat.shader.resource_path).ends_with("chunk_lit_cutout.gdshader"):
						continue
					var arrs = m.surface_get_arrays(si)
					var pos: PackedVector3Array = arrs[Mesh.ARRAY_VERTEX]
					var uva: PackedVector2Array = arrs[Mesh.ARRAY_TEX_UV]
					var colsa: PackedColorArray = arrs[Mesh.ARRAY_COLOR]
					if uva.size() != pos.size() or colsa.size() != pos.size():
						continue
					for vi in range(pos.size()):
						var uv: Vector2 = uva[vi]
						if uv.x < u0 or uv.x > u1 or uv.y < v0 or uv.y > v1:
							continue
						scan["leaves_texels"] += 1
						var tx := clampi(int(floorf(uv.x * 1024.0)), 0, aimg.get_width() - 1)
						var ty := clampi(int(floorf(uv.y * 1024.0)), 0, aimg.get_height() - 1)
						var tp: Color = aimg.get_pixel(tx, ty)
						if maxf(tp.r, maxf(tp.g, tp.b)) < 0.031:
							scan["black_texels"] += 1
						var cv: Color = colsa[vi]
						if cv.b <= 0.001:
							scan["col_b_zero"] += 1
						if cv.r + cv.g <= 0.001:
							scan["col_rg_zero"] += 1
						if found_v:
							continue
						var p: Vector3 = pos[vi]
						var inx := absf(p.x - float(lxi)) < 0.01 or absf(p.x - float(lxi + 1)) < 0.01
						var iny := p.y >= float(cell.y) - 0.01 and p.y <= float(cell.y) + 1.01
						var inz := absf(p.z - float(lzi)) < 0.01 or absf(p.z - float(lzi + 1)) < 0.01
						if not (inx and iny and inz):
							continue
						found_v = true
						colv = cv
						uvv = uv
	var texel := [0, 0, 0, 0]
	if found_v and aimg != null:
		var tx := clampi(int(floorf(uvv.x * 1024.0)), 0, aimg.get_width() - 1)
		var ty := clampi(int(floorf(uvv.y * 1024.0)), 0, aimg.get_height() - 1)
		var tp: Color = aimg.get_pixel(tx, ty)
		texel = [roundf(tp.r * 255.0), roundf(tp.g * 255.0), roundf(tp.b * 255.0), roundf(tp.a * 255.0)]
	var L_day := 0.20 + 0.80 * maxf(1.0 * float(colv.r), float(colv.g))
	var L_night := 0.20 + 0.80 * maxf(0.0 * float(colv.r), float(colv.g))
	var sky15 := float(linfo.sky) / 15.0
	var blk15 := float(linfo.block) / 15.0
	var L_day_light := 0.20 + 0.80 * maxf(sky15, blk15)
	var L_night_light := 0.20 + 0.80 * blk15
	var g_day := float(texel[1]) / 255.0 * float(colv.b) * L_day
	var g_night := float(texel[1]) / 255.0 * float(colv.b) * L_night
	var ok := found_v \
			and L_day > 0.25 \
			and L_night >= 0.18 \
			and float(texel[1]) / 255.0 > 0.15 \
			and g_day > 0.02 \
			and g_night > 0.008
	var out := {
		"mode": "leaves",
		"seed": Game.world_seed,
		"radius": world.render_radius,
		"cell": [cell.x, cell.y, cell.z],
		"chunk": [ccx, ccy],
		"vcolor": [roundf(float(colv.r) * 1000.0) / 1000.0, roundf(float(colv.g) * 1000.0) / 1000.0, roundf(float(colv.b) * 1000.0) / 1000.0],
		"uv": [roundf(uvv.x * 10000.0) / 10000.0, roundf(uvv.y * 10000.0) / 10000.0],
		"atlas_texel_rgba": texel,
		"light": {"sky": int(linfo.sky), "block": int(linfo.block), "eff": int(linfo.eff)},
		"L_day": roundf(L_day * 1000.0) / 1000.0,
		"L_night": roundf(L_night * 1000.0) / 1000.0,
		"L_day_light": roundf(L_day_light * 1000.0) / 1000.0,
		"L_night_light": roundf(L_night_light * 1000.0) / 1000.0,
		"green_day": roundf(g_day * 1000.0) / 1000.0,
		"green_night": roundf(g_night * 1000.0) / 1000.0,
		"u_day_cut": roundf(u_day_cut * 1000.0) / 1000.0,
		"cut_mat": mat_path,
		"tile_center_rgba": _leaves_tile_center(aimg),
		"bake_check": bake_check,
		"dbg": dbg,
		"scan": scan,
		"found_v": found_v,
		"ok": ok,
		"elapsed_ms": Time.get_ticks_msec() - t0,
	}
	Debug.result(out)
	get_tree().quit()


# AC-0136 probe (env-gated by AWECRAFT_LOGIC=sharpx, inert unless set):
# texel-boundary framebuffer A/B for the chunk_lit sampler filter. Finds a
# deterministic sky-lit (outdoor) or eff-0 (cave) grass/dirt/stone side face
# near spawn, places the eye 2.5 m off the face center, and samples an 11-px
# strip across one high-contrast texel boundary at the tile center row:
# NEAREST => every strip pixel equals one of the two texel-center pixels
# (off<=1); LINEAR => interior pixels are blends (off>=6). 4.7.1 exposes no
# GDScript filter getter (verified empirically), so it also reports the
# texture classes in force (imported CompressedTexture2D vs runtime
# ImageTexture bake copies) for the cause-layer record. Framebuffer part
# needs a real renderer (xvfb render mode); headless skips the sampling.
func _sharpx_test(spawn: Vector3) -> void:
	var t0 := Time.get_ticks_msec()
	Lighting._tables()
	world.collision_enabled = false
	world.recenter(spawn.x, spawn.z, true)
	await _nd_settle(60000)
	var filters := {
		"imported_atlas_class": String(Data.atlas_tex.get_class()) if Data.atlas_tex != null else "",
		"filter_api_exposed": bool(Data.atlas_tex.has_method("get_filter")) if Data.atlas_tex != null else false,
		"lit_atlas_class": "",
		"lit_atlas_class_set": false,
	}
	var lt: Texture2D = _ChunkScriptM._lit_atlas_tex()
	if lt != null:
		filters["lit_atlas_class"] = String(lt.get_class())
		filters["lit_atlas_class_set"] = true
	player = _spawn_player()
	var outdoor := await _sharpx_wall_test([1, 3], true, 12)
	var cave := await _sharpx_wall_test([9, 1, 3], false, 20)
	var out := {
		"mode": "sharpx",
		"seed": Game.world_seed,
		"radius": world.render_radius,
		"tile_px": Data.TILE_PX,
		"headless": DisplayServer.get_name() == "headless",
		"filters": filters,
		"outdoor": outdoor,
		"cave": cave,
		"elapsed_ms": Time.get_ticks_msec() - t0,
	}
	var ov := String(outdoor.get("verdict", ""))
	out["ok"] = ov != "" and ov != "inconclusive" and ov != "no_pair"
	Debug.result(out)
	get_tree().quit()


func _sharpx_wall_test(ids: Array, is_outdoor: bool, max_r: int) -> Dictionary:
	var sp: Vector3 = world.spawn_point()
	var bx0 := int(sp.x)
	var bz0 := int(sp.z)
	var dirs := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
	var bid := 0
	var wall := Vector3i(-1, -1, -1)
	var dir := Vector3i.ZERO
	var found := false
	for r in range(0, max_r + 1):
		if found:
			break
		for x in range(-r, r + 1):
			if found:
				break
			for z in range(-r, r + 1):
				if found:
					break
				if maxi(absi(x), absi(z)) != r:
					continue
				for d in dirs:
					for y in range(Data.HEIGHT - 2, 1, -1):
						var bx := bx0 + x
						var bz := bz0 + z
						var b: int = world.get_block(bx, y, bz)
						if not ids.has(b):
							continue
						var ax := bx + int(d.x)
						var az := bz + int(d.z)
						if world.get_block(ax, y, az) != 0:
							continue
						var la: Dictionary = world.light_at(ax, y, az)
						var sky: int = int(la.sky)
						if is_outdoor and sky < 15:
							continue
						if not is_outdoor and (sky != 0 or int(la.block) != 0):
							continue
						if world.get_block(ax + int(d.x), y, az + int(d.z)) != 0:
							continue
						if world.get_block(ax + int(d.x) * 2, y, az + int(d.z) * 2) != 0:
							continue
						if world.get_block(ax + int(d.x), y, az + int(d.z)) != 0:
							continue
						bid = b
						wall = Vector3i(bx, y, bz)
						dir = d
						found = true
						break
	if not found:
		return {"found": false, "is_outdoor": is_outdoor, "verdict": ""}
	var face := Vector3(float(wall.x + 0.5), float(wall.y + 0.5), float(wall.z + 0.5))
	var eye := face + Vector3(float(dir.x) * 3.0, 0.0, float(dir.z) * 3.0)
	var yaw := atan2(float(dir.x), float(dir.z))
	Debug.fly(true)
	Debug.teleport(eye.x, eye.y - player.EYE, eye.z)
	player.look(yaw, 0.0)
	Game.time_of_day = 0.5
	_update_sky()
	await _await_world_build(eye, 3000)
	for i in 12:
		await get_tree().physics_frame
	var res := {
		"found": true,
		"is_outdoor": is_outdoor,
		"block": bid,
		"wall": [wall.x, wall.y, wall.z],
		"dir": [dir.x, dir.y, dir.z],
		"eye": [roundf(eye.x * 1000.0) / 1000.0, roundf(eye.y * 1000.0) / 1000.0, roundf(eye.z * 1000.0) / 1000.0],
		"aim": "%.4f,%.4f,%.4f,%.4f,%.4f" % [eye.x, eye.y, eye.z, yaw, 0.0],
		"verdict": "",
	}
	if DisplayServer.get_name() == "headless":
		res["verdict"] = "skipped_headless"
		return res
	for i in 4:
		await RenderingServer.frame_post_draw
	var img := get_tree().root.get_viewport().get_texture().get_image()
	if img == null or img.get_width() < 8:
		res["verdict"] = "no_image"
		return res
	var W := img.get_width()
	var H := img.get_height()
	var fov_rad := deg_to_rad(float(player.camera.fov))
	var pxm := (float(H) * 0.5) / tan(fov_rad * 0.5) / 2.5
	var rect: Vector2i = Data.block_rect(bid, "side")
	var at_img: Image = Data.atlas_tex.get_image()
	var row_order := [16, 15, 17, 14, 18, 13, 19, 12, 20, 11, 21, 10, 22, 9, 23, 8, 24, 7, 25, 6, 26, 5, 27, 4, 28, 3, 29, 2, 30, 1, 31, 0]
	var chosen_c := -1
	var chosen_r := -1
	var chosen_d := 0
	for ps in range(2):
		if chosen_c >= 0:
			break
		for rr in row_order:
			var bd := 0
			var bc := -1
			for c in range(Data.TILE_PX - 1):
				var ca: Color = at_img.get_pixel(int(rect.x) + c, int(rect.y) + rr)
				var cb: Color = at_img.get_pixel(int(rect.x) + c + 1, int(rect.y) + rr)
				var dm := _sharpx_d8(ca, cb)
				if dm > bd:
					bd = dm
					bc = c
			var thr: int = 24 if ps == 0 else 12
			if bd >= thr:
				chosen_c = bc
				chosen_r = rr
				chosen_d = bd
				break
	if chosen_c < 0:
		res["verdict"] = "no_pair"
		return res
	var uvm := Vector2((float(chosen_c) + 1.0) / float(Data.TILE_PX), (float(chosen_r) + 0.5) / float(Data.TILE_PX))
	var uva := Vector2((float(chosen_c) + 0.5) / float(Data.TILE_PX), uvm.y)
	var uvb := Vector2((float(chosen_c) + 1.5) / float(Data.TILE_PX), uvm.y)
	var sxb := Vector2i(int(round(float(W) * 0.5 + (uvm.x - 0.5) * pxm)), int(round(float(H) * 0.5 + (uvm.y - 0.5) * pxm)))
	var sax := Vector2i(int(round(float(W) * 0.5 + (uva.x - 0.5) * pxm)), sxb.y)
	var sbx := Vector2i(int(round(float(W) * 0.5 + (uvb.x - 0.5) * pxm)), sxb.y)
	var pa: Color = img.get_pixel(sax.x, sax.y)
	var pb: Color = img.get_pixel(sbx.x, sbx.y)
	var pm: Color = img.get_pixel(sxb.x, sxb.y)
	# AC-0136: off = ramp pixels WITHIN the predicted [sax, sbx] a-b window
	# (strip pixels outside it belong to neighboring texels, not blending).
	var xa := mini(sax.x, sbx.x)
	var xb := maxi(sax.x, sbx.x)
	var off := 0
	var strip: Array = []
	for k in range(-5, 6):
		var xx := sxb.x + k
		var p: Color = img.get_pixel(xx, sxb.y)
		strip.append(_sharpx_p8(p))
		if xx >= xa and xx <= xb and mini(_sharpx_d8(p, pa), _sharpx_d8(p, pb)) > 2:
			off += 1
	var rdb := _sharpx_d8(pa, pb)
	if rdb == 0:
		_sharpx_dump(wall, dir, bid)
	if rdb < 8:
		res["verdict"] = "pair_low_contrast"
	elif off <= 1:
		res["verdict"] = "pure_nearest"
	elif off >= 3:
		res["verdict"] = "blended_linear"
	else:
		res["verdict"] = "inconclusive"
	res["pair"] = {"c": chosen_c, "r": chosen_r, "atlas_d8": chosen_d, "render_d8": rdb}
	res["px"] = {"a": _sharpx_p8(pa), "b": _sharpx_p8(pb), "mid": _sharpx_p8(pm), "strip": strip, "off": off}
	res["samples"] = {"a": [sax.x, sax.y], "b": [sbx.x, sbx.y], "mid": [sxb.x, sxb.y]}
	return res


func _sharpx_dump(wall: Vector3i, dir: Vector3i, bid: int) -> void:
	var chars := {0: ".", 1: "g", 3: "d", 5: "~", 9: "s", 11: "b"}
	for k in range(3, -2, -1):
		var zz := wall.z + int(dir.z) * k
		for dy in range(-2, 3):
			var row := "DUMP z=%d y=%d " % [zz, wall.y + dy]
			for dx in range(-3, 4):
				var b: int = world.get_block(wall.x + dx, wall.y + dy, zz)
				row += chars.get(b, "#")
			print(row)
	var la: Dictionary = world.light_at(wall.x + int(dir.x), wall.y, wall.z + int(dir.z))
	print("DUMP face_light sky=%s blk=%s eff=%s wall_block=%d" % [la.sky, la.block, la.eff, bid])


func _sharpx_p8(c: Color) -> Array:
	return [int(c.r * 255.0 + 0.5), int(c.g * 255.0 + 0.5), int(c.b * 255.0 + 0.5)]


func _sharpx_d8(a: Color, b: Color) -> int:
	var da := absi(int(a.r * 255.0 + 0.5) - int(b.r * 255.0 + 0.5))
	var db := absi(int(a.g * 255.0 + 0.5) - int(b.g * 255.0 + 0.5))
	return maxi(da, absi(int(a.b * 255.0 + 0.5) - int(b.b * 255.0 + 0.5)))


# AC-0133 probe (env-gated by AWECRAFT_LOGIC=stars, never runs in game):
# transform-behavior A/B for the star field. Web parity (index.html :3248):
# the per-frame hook writes the star node's POSITION only (rotation never
# set), so the field is fixed in world orientation and recentered on the eye.
# Night (t=0.0, opacity 1.0); sample A at the spawn orientation, sample B
# after a 90-degree camera yaw (player.look = the AWECRAFT_AIM direct-set
# pattern). Sync: no await between set and read (one call stack, physics
# inert, Game.mode != "play"). ok = parent is not the camera AND the field
# basis is ~identity (angle from identity < 1 degree) at BOTH samples AND
# the field position tracks the eye (< 0.01) at both AND opacity > 0.95
# AND count 500. PRE (full camera-transform copy at the per-frame hook)
# fails basis_deg_b (90 degrees) = the honest A/B.
func _star_basis_deg(n: Node3D) -> float:
	var b := n.global_basis
	var tr: float = b.x.x + b.y.y + b.z.z
	return acos(clampf((tr - 1.0) / 2.0, -1.0, 1.0)) * 180.0 / PI


func _stars_test(spawn: Vector3) -> void:
	var t0 := Time.get_ticks_msec()
	if _star_node == null or _star_mat == null or player == null:
		Debug.result({"mode": "stars", "seed": Game.world_seed, "ok": false, "err": "missing star node", "elapsed_ms": Time.get_ticks_msec() - t0})
		get_tree().quit()
		return
	Game.time_of_day = 0.0
	_update_sky()
	var cam: Camera3D = player.get_node("Camera3D")
	player.look(0.0, 0.0)
	_update_sky()
	var eye_a: Vector3 = cam.global_position
	var star_pos_a: Vector3 = _star_node.global_position
	var star_rot_a: Vector3 = _star_node.global_rotation
	var basis_deg_a: float = _star_basis_deg(_star_node)
	var opacity_a: float = float(_star_mat.get_shader_parameter("u_opacity"))
	var sa: Array = _star_node.mesh.surface_get_arrays(0)
	var count: int = int((sa[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 6)
	player.look(PI / 2.0, 0.0)
	_update_sky()
	var eye_b: Vector3 = cam.global_position
	var star_pos_b: Vector3 = _star_node.global_position
	var star_rot_b: Vector3 = _star_node.global_rotation
	var basis_deg_b: float = _star_basis_deg(_star_node)
	var parent_name: String = ""
	if _star_node.get_parent() != null:
		parent_name = _star_node.get_parent().name
	var parent_ok: bool = _star_node.get_parent() != null and _star_node.get_parent() != cam and parent_name != "Camera3D"
	var ok: bool = parent_ok \
			and basis_deg_a < 1.0 and basis_deg_b < 1.0 \
			and star_pos_a.distance_to(eye_a) < 0.01 \
			and star_pos_b.distance_to(eye_b) < 0.01 \
			and opacity_a > 0.95 and count == 500
	Debug.result({
		"mode": "stars",
		"seed": Game.world_seed,
		"path": _star_node.get_path(),
		"parent_name": parent_name,
		"eye_a": [eye_a.x, eye_a.y, eye_a.z],
		"eye_b": [eye_b.x, eye_b.y, eye_b.z],
		"star_pos_a": [star_pos_a.x, star_pos_a.y, star_pos_a.z],
		"star_pos_b": [star_pos_b.x, star_pos_b.y, star_pos_b.z],
		"star_rot_a": [_vl_r5(star_rot_a.x * 180.0 / PI), _vl_r5(star_rot_a.y * 180.0 / PI), _vl_r5(star_rot_a.z * 180.0 / PI)],
		"star_rot_b": [_vl_r5(star_rot_b.x * 180.0 / PI), _vl_r5(star_rot_b.y * 180.0 / PI), _vl_r5(star_rot_b.z * 180.0 / PI)],
		"yaw_delta_deg": 90.0,
		"opacity_a": _vl_r5(opacity_a),
		"count": count,
		"elapsed_ms": Time.get_ticks_msec() - t0,
		"ok": ok,
	})
	get_tree().quit()


func _probe_water_positions() -> Dictionary:
	var out := {}
	for key in world.chunks.keys():
		var c: Node3D = world.chunks.get(key)
		if c == null:
			continue
		var d: PackedByteArray = c.flat_data()
		for i in range(d.size()):
			if d[i] == 5:
				var yy: int = i >> 8
				var gx: int = int(c.cx) * 16 + (i & 15)
				var gz: int = int(c.cz) * 16 + ((i >> 4) & 15)
				out[yy * 262144 + gx * 256 + gz] = yy
	return out


func _fluidprobe_test() -> void:
	var keys: Array = world.chunks.keys()
	var fl_hist := {}
	var sea_hist := {}
	for key in world.chunks.keys():
		var c: Node3D = world.chunks.get(key)
		if c == null:
			continue
		var d: PackedByteArray = c.flat_data()
		for i in range(d.size()):
			if d[i] == 5:
				var v: int = c.fl_at(i)
				fl_hist[v] = int(fl_hist.get(v, 0)) + 1
				if (i >> 8) == Data.SEA:
					sea_hist[v] = int(sea_hist.get(v, 0)) + 1
	print("PROBE fl_hist=%s sea_surface_hist=%s" % [fl_hist, sea_hist])
	var prev: Dictionary = _probe_water_positions()
	var prev_total := _count_fluid_cells(keys, 5)
	var prev_sea := _water_at_level(keys, Data.SEA)
	print("PROBE t0 total=%d sea=%d" % [prev_total, prev_sea])
	for i in 8:
		Debug.tick_fluids()
		var cur: Dictionary = _probe_water_positions()
		var adds := 0
		var ys := {}
		var samples: Array = []
		for k in cur:
			if not prev.has(k):
				adds += 1
				var yy: int = int(k) / 262144
				ys[yy] = int(ys.get(yy, 0)) + 1
				if samples.size() < 24:
					var rem: int = int(k) % 262144
					samples.append("%d,%d,%d" % [rem / 256, yy, rem % 256])
		for k in prev:
			if not cur.has(k):
				var rem2: int = int(k) % 262144
				print("PROBE t%d REMOVED %d,%d,%d" % [i + 1, rem2 / 256, int(k) / 262144, rem2 % 256])
		print("PROBE t%d adds=%d sea_delta=%d ys=%s samples=%s" % [i + 1, adds, _water_at_level(keys, Data.SEA) - prev_sea, ys, samples])
		prev = cur
		prev_total = _count_fluid_cells(keys, 5)
		prev_sea = _water_at_level(keys, Data.SEA)
	Debug.result({"done": true})


func _fluidfall_build(fx: int, fz: int) -> int:
	var tmax := 0
	for dx in range(-8, 9):
		for dz in range(-8, 9):
			var t: int = world.surface_top(fx + dx, fz + dz)
			if t > tmax:
				tmax = t
	var sy: int = maxi(clampi(tmax + 1, 4, Data.HEIGHT - 16), Data.SEA + 6)
	for dx in range(-9, 10):
		for dz in range(-9, 10):
			Debug.set_block(fx + dx, sy - 1, fz + dz, 3)
			Debug.set_block(fx + dx, sy, fz + dz, 0)
	for y in range(sy + 1, sy + 11):
		Debug.set_block(fx, y, fz, 0)
	return sy


func _fluidfall_scan(fx: int, fz: int, sy: int) -> Array:
	var cells := {}
	var total := 0
	var landed := true
	var y0 := sy - 1
	var y1 := sy + 10
	var cx0 := int(floorf(float(fx - 8) / 16.0))
	var cx1 := int(floorf(float(fx + 8) / 16.0))
	var cz0 := int(floorf(float(fz - 8) / 16.0))
	var cz1 := int(floorf(float(fz + 8) / 16.0))
	for cx in range(cx0, cx1 + 1):
		for cz in range(cz0, cz1 + 1):
			var c: Node3D = world.chunks.get("%d,%d" % [cx, cz])
			if c == null or c.data.is_empty():
				continue
			var d: PackedByteArray = c.flat_data()
			var f: PackedByteArray = c.flat_fl()
			var lx0: int = maxi(fx - 8, cx * 16) - cx * 16
			var lx1: int = mini(fx + 8, cx * 16 + 15) - cx * 16
			var lz0: int = maxi(fz - 8, cz * 16) - cz * 16
			var lz1: int = mini(fz + 8, cz * 16 + 15) - cz * 16
			for y in range(y0, y1 + 1):
				var ia := y << 8
				var ib := (y - 1) << 8
				for lz in range(lz0, lz1 + 1):
					for lx in range(lx0, lx1 + 1):
						var i := ia | (lz << 4) | lx
						if d[i] != 5:
							continue
						total += 1
						cells["%d,%d,%d" % [cx * 16 + lx, y, cz * 16 + lz]] = int(f[i])
						var below: int = d[ib | (lz << 4) | lx]
						if world.fluid_replaceable(below):
							landed = false
	return [total, cells, landed]


func _fluidfall_clear(fx: int, fz: int, sy: int) -> void:
	var sc: Array = _fluidfall_scan(fx, fz, sy)
	var cells: Dictionary = sc[1]
	for k in cells:
		var p: PackedStringArray = str(k).split(",")
		Debug.set_fluid(int(p[0]), int(p[1]), int(p[2]), 0, 0)


func _fluidfall_stationary(fx: int, fz: int, sy: int, dys: Array) -> Dictionary:
	var expected := {}
	for dy in dys:
		var y: int = sy + int(dy)
		expected["%d,%d,%d" % [fx, y, fz]] = 0
		Debug.set_fluid(fx, y, fz, 5, 0)
	var writes := 0
	var ticks := 0
	var stable := 0
	var prev_sig := ""
	while ticks < 40:
		ticks += 1
		Debug.tick_fluids()
		var sc: Array = _fluidfall_scan(fx, fz, sy)
		var sig := str(sc[1])
		if sig == prev_sig:
			stable += 1
		else:
			if ticks > 1:
				writes += 1
			stable = 0
			prev_sig = sig
		if stable >= 3 and ticks >= 8:
			break
	var sc2: Array = _fluidfall_scan(fx, fz, sy)
	var cells: Dictionary = sc2[1]
	var intact: bool = cells.size() == expected.size()
	for k in expected:
		if not cells.has(k) or int(cells[k]) != 0:
			intact = false
			break
	return {
		"stationary": bool(intact and writes == 0),
		"intact": bool(intact),
		"writes": writes,
		"total_water": int(sc2[0]),
		"settled": stable >= 3,
		"ticks": ticks,
	}


func _fluidfall_case(fx: int, fz: int, sy: int, drop_y: int, lvl: int) -> Dictionary:
	Debug.set_fluid(fx, drop_y, fz, 5, lvl)
	var min_count := -1
	var ticks := 0
	var stable := 0
	var prev_sig := ""
	var no_drain := true
	while ticks < 200:
		ticks += 1
		Debug.tick_fluids()
		var sc: Array = _fluidfall_scan(fx, fz, sy)
		var w: int = int(sc[0])
		if min_count < 0:
			min_count = w
		if w < min_count:
			no_drain = false
		min_count = mini(min_count, w)
		var sig := str(sc[1])
		if sig == prev_sig:
			stable += 1
		else:
			stable = 0
			prev_sig = sig
		if stable >= 3:
			break
	var sc2: Array = _fluidfall_scan(fx, fz, sy)
	var cells: Dictionary = sc2[1]
	var floor_cells := 0
	var descended := true
	for k in cells:
		var p: PackedStringArray = str(k).split(",")
		var yy: int = int(p[1])
		if yy == sy:
			floor_cells += 1
		if yy >= drop_y:
			descended = false
	return {
		"landed": bool(sc2[2]),
		"descended": descended,
		"spread": floor_cells >= 2,
		"floor_cells": floor_cells,
		"total_water": int(sc2[0]),
		"settled_ticks": ticks,
		"settled": stable >= 3 and ticks < 200,
		"no_drain": no_drain,
	}


func _fluidfall_test(spawn: Vector3) -> void:
	var cx0 := int(floorf(spawn.x / 16.0))
	var cz0 := int(floorf(spawn.z / 16.0))
	var fx := cx0 * 16 + 8
	var fz := cz0 * 16 + 8
	var sy: int = _fluidfall_build(fx, fz)
	print("FLUIDFALL build fx=%d fz=%d sy=%d" % [fx, fz, sy])
	# Case A: fl=0 sources (natural-water semantics) floating over the air hole must
	# stay exactly where they were — 0 writes over the ticks, both still (MC stationary).
	var a: Dictionary = _fluidfall_stationary(fx, fz, sy, [8, 3])
	print("FLUIDFALL caseA_source %s" % JSON.stringify(a))
	_fluidfall_clear(fx, fz, sy)
	var b: Dictionary = _fluidfall_case(fx, fz, sy, sy + 8, 8)
	print("FLUIDFALL caseB_full %s" % JSON.stringify(b))
	_fluidfall_clear(fx, fz, sy)
	var c: Dictionary = _fluidfall_case(fx, fz, sy, sy, 8)
	var center: Array = Debug.fluid_at(fx, sy, fz)
	var shore: Array = Debug.fluid_at(fx + 1, sy, fz)
	var far: Array = Debug.fluid_at(fx + 7, sy, fz)
	var beyond: Array = Debug.fluid_at(fx + 8, sy, fz)
	print("FLUIDFALL caseC_flat %s" % JSON.stringify(c))
	# Case A must prove STATIONARY: 0 writes, both sources still floating at exactly the
	# cells they were placed (intact), total water unchanged, and the tick stream settles.
	var a_ok: bool = bool(a.stationary) and bool(a.intact) and int(a.writes) == 0 \
		and int(a.total_water) == 2 and bool(a.settled)
	var b_ok: bool = bool(b.landed) and bool(b.descended) and bool(b.spread) and bool(b.no_drain) and bool(b.settled)
	var c_ok: bool = bool(c.settled) and bool(c.no_drain) and bool(c.landed) \
		and shore == [5, 7] and far == [5, 1] and beyond == [0, 0] and center == [5, 8] \
		and int(c.floor_cells) == 113
	Debug.result({
		"sy": sy,
		"caseA_source": a,
		"caseB_full": b,
		"caseC_flat": c,
		"shore": shore,
		"far": far,
		"beyond": beyond,
		"center": center,
		"caseA_ok": a_ok,
		"caseB_ok": b_ok,
		"caseC_ok": c_ok,
		"ok": a_ok and b_ok and c_ok,
	})


func _webfall_test(spawn: Vector3) -> void:
	player = _spawn_player()
	Game.start()
	var sp: Vector3 = world.spawn_point()
	_web_waterfall()
	var fx := int(sp.x)
	var fz := int(sp.z)
	var tmax := 0
	for dx in range(-8, 9):
		for dz in range(-8, 9):
			var t: int = world.surface_top(fx + dx, fz + dz)
			if t > tmax:
				tmax = t
	var sy: int = maxi(clampi(tmax + 1, 4, Data.HEIGHT - 16), Data.SEA + 6)
	var floor_last := -1
	var floor_quiet := 0
	var settled := false
	for i in range(1200):
		await get_tree().physics_frame
		var sc: Array = _fluidfall_scan(fx, fz, sy)
		var fc := 0
		for k in (sc[1] as Dictionary):
			if int(str(k).split(",")[1]) == sy:
				fc += 1
		if fc == 0:
			floor_quiet = 0
			continue
		if fc == floor_last:
			floor_quiet += 1
		else:
			floor_quiet = 0
			floor_last = fc
		if floor_quiet >= 24:
			settled = true
			break
	var sc2: Array = _fluidfall_scan(fx, fz, sy)
	Debug.result({
		"settled": settled,
		"landed": bool(sc2[2]),
		"floor_cells": floor_last,
		"total_water": int(sc2[0]),
		"sy": sy,
		"ok": settled and bool(sc2[2]) and floor_last >= 100,
	})


func _fluids_test(spawn: Vector3) -> void:
	var cx0 := int(floorf(spawn.x / 16.0))
	var cz0 := int(floorf(spawn.z / 16.0))
	var x0 := cx0 * 16
	var wz := cz0 * 16 + 8
	var tmax := 0
	for lz in range(7, 10):
		for lx in range(16):
			var t: int = world.surface_top(x0 + lx, cz0 * 16 + lz)
			if t > tmax:
				tmax = t
	var by := tmax + 5
	by = clampi(by, Data.SEA + 4, Data.HEIGHT - 8)
	for lx in range(16):
		for dz in range(-1, 2):
			for dy in range(-2, 4):
				Debug.set_block(x0 + lx, by + dy, wz + dz, 0)
	var wxc := x0 + 2
	var wxa := x0 + 8
	var wxb := x0 + 12
	# Stability: 2-cell source water column in stone; single cleared air cell beside the top source
	Debug.set_block(wxc, by - 1, wz, 3)
	Debug.set_fluid(wxc, by, wz, 5, 8)
	Debug.set_fluid(wxc, by + 1, wz, 5, 8)
	Debug.set_block(wxc + 1, by, wz, 3)
	Debug.set_block(wxc - 1, by, wz, 3)
	Debug.set_block(wxc, by, wz + 1, 3)
	Debug.set_block(wxc, by, wz - 1, 3)
	Debug.set_block(wxc - 1, by + 1, wz, 3)
	Debug.set_block(wxc, by + 1, wz + 1, 3)
	Debug.set_block(wxc, by + 1, wz - 1, 3)
	Debug.set_block(wxc + 2, by + 1, wz, 3)
	Debug.set_block(wxc + 1, by + 1, wz + 1, 3)
	Debug.set_block(wxc + 1, by + 1, wz - 1, 3)
	# Reaction A: source water (L=8) directly above a lava cell -> obsidian
	Debug.set_block(wxa, by - 2, wz, 3)
	Debug.set_block(wxa + 1, by - 1, wz, 3)
	Debug.set_block(wxa - 1, by - 1, wz, 3)
	Debug.set_block(wxa, by - 1, wz + 1, 3)
	Debug.set_block(wxa, by - 1, wz - 1, 3)
	Debug.set_block(wxa, by - 1, wz, 24)
	Debug.set_block(wxa + 1, by, wz, 3)
	Debug.set_block(wxa - 1, by, wz, 3)
	Debug.set_block(wxa, by, wz + 1, 3)
	Debug.set_block(wxa, by, wz - 1, 3)
	Debug.set_fluid(wxa, by, wz, 5, 8)
	# Reaction B: flowing water (L=7) sideways next to lava -> the lava becomes stone
	Debug.set_block(wxb, by - 1, wz, 3)
	Debug.set_block(wxb + 1, by - 1, wz, 3)
	Debug.set_block(wxb - 1, by, wz, 3)
	Debug.set_block(wxb, by, wz + 1, 3)
	Debug.set_block(wxb, by, wz - 1, 3)
	Debug.set_block(wxb + 2, by, wz, 3)
	Debug.set_block(wxb + 1, by, wz, 24)
	Debug.set_fluid(wxb, by, wz, 5, 7)
	var region_keys: Array = world.chunks.keys()
	var sea_before := _water_at_level(region_keys, Data.SEA)
	var sea_backed_before := _sea_solid_backed(region_keys)
	var total_before := _count_fluid_cells(region_keys, 5)
	var w_before := _water_in_box(region_keys, wxc - 1, wxc + 2, by - 1, by + 1, wz - 1, wz + 1)
	var no_drain := true
	var prev := total_before
	Debug.tick_fluids()
	var cur := _count_fluid_cells(region_keys, 5)
	no_drain = no_drain and cur >= prev
	prev = cur
	var w_after := _water_in_box(region_keys, wxc - 1, wxc + 2, by - 1, by + 1, wz - 1, wz + 1)
	var water_delta := w_after - w_before
	var shore: Array = Debug.fluid_at(wxc + 1, by + 1, wz)
	var src_top: Array = Debug.fluid_at(wxc, by + 1, wz)
	var src_bot: Array = Debug.fluid_at(wxc, by, wz)
	var r_a: int = Debug.block_at(wxa, by - 1, wz)
	var r_b: int = Debug.block_at(wxb + 1, by, wz)
	for i in 4:
		Debug.tick_fluids()
		cur = _count_fluid_cells(region_keys, 5)
		no_drain = no_drain and cur >= prev
		prev = cur
	var w_settle := _water_in_box(region_keys, wxc - 1, wxc + 2, by - 1, by + 1, wz - 1, wz + 1)
	var src_top2: Array = Debug.fluid_at(wxc, by + 1, wz)
	var sea_final := _water_at_level(region_keys, Data.SEA)
	var sea_backed_final := _sea_solid_backed(region_keys)
	# stable: fixture adds exactly 1 cell, sources never churn (stay 8 after 5 ticks),
	# fixture box reaches steady state, and the natural world loses no fluid cells (no drain).
	# Natural ocean is a stationary source field (fl=0, MC-style): it must produce ZERO
	# writes, so the sea-surface count (cells at y==Data.SEA) is EXACTLY unchanged; no
	# real (solid-backed) sea cell is ever lost either.
	var sea_stable: bool = (
		water_delta == 1
		and shore == [5, 7]
		and src_top == [5, 8]
		and src_bot == [5, 8]
		and src_top2 == [5, 8]
		and w_settle == w_after
		and no_drain
		and sea_final == sea_before
		and sea_backed_final >= sea_backed_before
	)
	print("FLUIDSTAT region_water_before=%d region_water_final=%d sea_surface_before=%d sea_surface_final=%d sea_backed_before=%d sea_backed_final=%d" % [total_before, prev, sea_before, sea_final, sea_backed_before, sea_backed_final])
	Debug.result({
		"shore_after": shore,
		"source_after": src_top,
		"water_delta": water_delta,
		"water_on_lava_result": r_a,
		"sideways_lava_result": r_b,
		"sea_stable": sea_stable,
		"sea_surface_before": sea_before,
		"sea_surface_final": sea_final,
		"sea_backed_before": sea_backed_before,
		"sea_backed_final": sea_backed_final,
	})


func _buckets_test() -> void:
	await _buckets_test_body()
	get_tree().quit()


func _buckets_test_body() -> void:
	var p = Game.player
	for i in 10:
		await get_tree().physics_frame
	Debug.fly(true)
	var sp: Vector3 = world.spawn_point()
	var sx := int(sp.x)
	var sz := int(sp.z)
	var wx := sx + 4
	var wz := sz + 2
	var gy: int = world.surface_top(wx, wz)
	if gy < 3:
		gy = 3
	if gy >= Data.HEIGHT - 6:
		gy = Data.HEIGHT - 8
	var wy := gy + 1
	for z in range(wz, wz + 7):
		for yy in range(wy, wy + 2):
			Debug.set_block(wx, yy, z, 0)
	Debug.set_fluid(wx, wy, wz, 5, 8)
	for i in 3:
		await get_tree().physics_frame
	var scoop_before: Array = Debug.fluid_at(wx, wy, wz)
	Debug.give_item(139, 1)
	p.sel = _slot_of(p, 139)
	Debug.aim_at(float(wx) + 0.5, float(wy) + 0.5, float(wz) + 5.0)
	for i in 3:
		await get_tree().physics_frame
	p.use_selected()
	for i in 3:
		await get_tree().physics_frame
	var after_scoop: Array = Debug.fluid_at(wx, wy, wz)
	var inv_scoop := {"id": 140, "n": _count_item(p, 140)}
	Debug.give_item(140, 1)
	p.sel = _slot_of(p, 140)
	Debug.set_block(wx, wy, wz + 2, 3)
	Debug.aim_at(float(wx) + 0.5, float(wy) + 0.5, float(wz) + 5.0)
	for i in 3:
		await get_tree().physics_frame
	p.use_selected()
	for i in 3:
		await get_tree().physics_frame
	var place_after: Array = Debug.fluid_at(wx, wy, wz + 3)
	var inv_place := {"id": 139, "n": _count_item(p, 139)}
	Debug.result({
		"scoop_before": scoop_before,
		"after_scoop": after_scoop,
		"inv_scoop": inv_scoop,
		"place_after": place_after,
		"inv_place": inv_place,
	})


func _water_test(spawn: Vector3) -> void:
	var p = Game.player
	for i in 10:
		await get_tree().physics_frame
	var sx := int(spawn.x)
	var sz := int(spawn.z)
	var wx := sx + 4
	var wz := sz
	var B := 42
	for x in range(wx - 1, wx + 5):
		for z in range(wz - 1, wz + 2):
			for y in range(B - 4, B + 3):
				var id := 0
				if y < B or (y == B and x != wx and x != wx + 1):
					id = 3
				Debug.set_block(x, y, z, id)
	for z in range(wz - 1, wz + 2):
		Debug.set_fluid(wx, B, z, 5, 8)
		Debug.set_fluid(wx + 1, B, z, 5, 8)
	var fix_chunks := {}
	for fx in [wx - 1, wx + 4]:
		for fz in [wz - 1, wz + 1]:
			fix_chunks["%d,%d" % [int(floorf(float(fx) / 16.0)), int(floorf(float(fz) / 16.0))]] = true
	var waited := 0
	while waited < 900:
		var allc := true
		for k in fix_chunks:
			var c: Node3D = world.chunks.get(k)
			if c == null or c.any_col_dirty():
				allc = false
				break
		if allc:
			break
		await get_tree().physics_frame
		waited += 1
	for i in 4:
		await get_tree().physics_frame
	p.look(-PI / 2, 0.0)
	Debug.teleport(float(wx) + 0.5, float(B), float(wz) + 0.5)
	for i in 4:
		await get_tree().physics_frame
	Input.action_press("jump")
	Input.action_press("move_forward")
	var timeline: Array = []
	var max_y := -1e9
	var above_top := false
	var first_above_frame := 0
	var landed_frame := 0
	var frames := 1300
	for f in range(1, frames + 1):
		await get_tree().physics_frame
		var py: float = p.position.y
		if py > max_y:
			max_y = py
		if not above_top and py >= float(B + 1):
			above_top = true
			first_above_frame = f
		if landed_frame == 0 and p.is_on_floor() and py >= float(B + 1) and int(floorf(p.position.x)) >= wx + 2:
			landed_frame = f
			Input.action_release("jump")
			Input.action_release("move_forward")
		if f % 50 == 0:
			var bx := int(floorf(p.position.x))
			var by := int(floorf(p.position.y + 0.5))
			var bz := int(floorf(p.position.z))
			timeline.append([f, roundf(p.position.x * 100.0) / 100.0, roundf(py * 1000.0) / 1000.0, Debug.block_at(bx, by, bz) == 5, roundf(p.velocity.x * 100.0) / 100.0])
	for i in 60:
		await get_tree().physics_frame
	var standing: bool = p.is_on_floor() and absf(p.position.y - float(B + 1)) < 0.05 and int(floorf(p.position.x)) >= wx + 2
	Debug.result({
		"B": B,
		"shore_top": B + 1,
		"timeline": timeline,
		"max_y": roundf(max_y * 1000.0) / 1000.0,
		"first_above_frame": first_above_frame,
		"above_top": above_top,
		"landed_frame": landed_frame,
		"standing_on_shore": standing,
		"final": [roundf(p.position.x * 1000.0) / 1000.0, roundf(p.position.y * 1000.0) / 1000.0, roundf(p.position.z * 1000.0) / 1000.0],
		"final_on_floor": p.is_on_floor(),
		"water_cell_intact": Debug.block_at(wx, B, wz) == 5,
		"ok": above_top and standing,
	})
	get_tree().quit()


func _combat_spawn_aimed(p: Node3D, key: String, t: float) -> Node3D:
	var info = Data.mobs.get(key)
	var h := float(info["h"])
	var c: Vector3 = p.camera.global_position + p.aim_dir() * t
	return Debug.spawn_mob(key, c.x, c.y - h * 0.55, c.z)


func _combat_test(spawn: Vector3) -> void:
	var p = Game.player
	Debug.fly(true)
	for i in 10:
		await get_tree().physics_frame
	p.position = Vector3(spawn.x, spawn.y + 12.0, spawn.z)
	p.look(0.0, -0.35)
	p.hp = 20.0
	p.hunger = 20.0
	for i in 4:
		await get_tree().physics_frame
	var m: Node3D = _combat_spawn_aimed(p, "chicken", 4.5)
	var h0: float = p.hunger
	p.start_mine()
	await get_tree().physics_frame
	var bare_ok: bool = absf(float(m.hp) - 3.0) < 0.001 and absf(p.hunger - (h0 - 0.5)) < 0.001
	var hp_after_first: float = m.hp
	p.start_mine()
	var double_hp: float = m.hp
	var double_ok: bool = absf(double_hp - 2.0) < 0.001 and absf(p.hunger - (h0 - 1.0)) < 0.001
	var drops_before: int = Game.drops.get_child_count()
	Debug.give_item(109, 1)
	p.sel = _slot_of(p, 109)
	for i in 2:
		await get_tree().physics_frame
	p.start_mine()
	for i in 4:
		await get_tree().physics_frame
	var death_drops: Array = []
	var wpn_ok := false
	if Game.drops.get_child_count() > drops_before:
		for i in range(drops_before, Game.drops.get_child_count()):
			var d = Game.drops.get_child(i)
			death_drops.append({"id": int(d.id), "n": 1})
	wpn_ok = death_drops.size() == 1 and int(death_drops[0]["id"]) == 146 and not is_instance_valid(m)
	p.look(3.14, -0.35)
	for i in 2:
		await get_tree().physics_frame
	var hunger_before_nt: float = p.hunger
	var drops_before_nt: int = Game.drops.get_child_count()
	p.start_mine()
	for i in 2:
		await get_tree().physics_frame
	var nt_ok: bool = absf(p.hunger - hunger_before_nt) < 0.001 and Game.drops.get_child_count() == drops_before_nt
	Debug.result({
		"bare": bare_ok,
		"bare_hp": roundf(hp_after_first * 100.0) / 100.0,
		"post_double_hp": roundf(double_hp * 100.0) / 100.0,
		"cooldown_ms": 0,
		"cooldown_ok": double_ok,
		"weapon_dmg": 4 if wpn_ok else null,
		"death_drops": death_drops,
		"death_ok": wpn_ok,
		"no_target": nt_ok,
		"ok": bool(bare_ok and double_ok and wpn_ok and nt_ok),
	})
	get_tree().quit()


func _vec_close(a: Array, b: Array, eps: float) -> bool:
	if a.size() != 3 or b.size() != 3:
		return false
	for i in 3:
		if absf(float(a[i]) - float(b[i])) > eps:
			return false
	return true


func _start_world_to_slot(seed: int, slot: int) -> void:
	Save.active_slot = int(slot)
	if world != null:
		_free_game_nodes()
	Game.new_world(int(seed))
	_create_game_nodes()
	world.edits = {}
	var spawn: Vector3 = world.spawn_point()
	world.recenter(spawn.x, spawn.z, true)
	await _await_spawn_floor(spawn, 300)
	player = _spawn_player()
	Game.start()


func _save_test() -> void:
	var S := 44
	Save.clear(0)
	Save.clear(1)
	Save.clear(2)
	var clear_pre_ok := true
	for s in 3:
		if FileAccess.file_exists("user://awecraft_save_%d.json" % s) or not Save.meta(s).is_empty():
			clear_pre_ok = false
	await _start_world_to_slot(S, 0)
	var sp: Vector3 = world.spawn_point()
	var sx := int(sp.x)
	var sz := int(sp.z)
	var top: int = world.surface_top(sx, sz)
	var tx := sx + 5
	var tz := sz + 5
	var ttop: int = world.surface_top(tx, tz)
	var ppos := Vector3(float(tx) + 0.5, float(ttop) + 1.0, float(tz) + 0.5)
	Debug.set_block(sx, top, sz, 3)
	Debug.set_block(sx + 1, top, sz, 4)
	Debug.set_block(sx, top + 1, sz, 6)
	Debug.set_block(sx, top - 2, sz, 16)
	Debug.set_block(sx + 2, top, sz + 1, 23)
	Debug.set_block(sx - 1, top, sz - 1, 22)
	var pl = Game.player
	Debug.give_item(111, 3)
	Debug.give_item(2, 5)
	pl.hp = 13.0
	pl.hunger = 7.0
	Debug.teleport(ppos.x, ppos.y, ppos.z)
	Game.time_of_day = 0.7
	pl.sel = 2
	for i in 20:
		await get_tree().physics_frame
	var inv_before: Array = []
	for it in pl.inv:
		inv_before.append([int(it["id"]), int(it["n"])])
	var pos_before: Array = [pl.position.x, pl.position.y, pl.position.z]
	var saved_ok := Save.save_now(0)
	var edited := {
		[sx, top, sz]: 3,
		[sx + 1, top, sz]: 4,
		[sx, top + 1, sz]: 6,
		[sx, top - 2, sz]: 16,
		[sx + 2, top, sz + 1]: 23,
		[sx - 1, top, sz - 1]: 22,
	}
	var unedited := [
		[sx + 8, top, sz + 8],
		[sx - 8, top, sz - 8],
		[sx + 5, top, sz - 9],
		[sx - 6, top, sz + 7],
	]
	var base_u: Array = []
	for u in unedited:
		base_u.append(world.get_block(u[0], u[1], u[2]))
	_free_game_nodes()
	await _continue_slot(0)
	var pl2 = Game.player
	var blocks_match := 0
	var blocks_total := edited.size()
	for k in edited:
		if world.get_block(k[0], k[1], k[2]) == edited[k]:
			blocks_match += 1
	var unedited_match := 0
	for i in unedited.size():
		if world.get_block(unedited[i][0], unedited[i][1], unedited[i][2]) == base_u[i]:
			unedited_match += 1
	var pos_after: Array = [pl2.position.x, pl2.position.y, pl2.position.z]
	var pos_ok: bool = _vec_close(pos_after, pos_before, 0.35)
	var sel_ok: bool = (pl2.sel == 2)
	var hp_ok: bool = absf(float(pl2.hp) - 13.0) < 0.01
	var hunger_ok: bool = absf(float(pl2.hunger) - 7.0) < 0.01
	var time_ok: bool = absf(Game.time_of_day - 0.7) < 0.001
	var inv_after: Array = []
	for it in pl2.inv:
		inv_after.append([int(it["id"]), int(it["n"])])
	var inv_match: bool = (inv_after == inv_before)
	var player_match: bool = pos_ok and sel_ok and hp_ok and hunger_ok and time_ok and inv_match
	var slot0_ok: bool = (blocks_match == blocks_total) and (unedited_match == unedited.size()) and player_match
	await _start_world_to_slot(S, 1)
	var iso_cell := [sx + 3, top, sz + 3]
	var iso_base: int = world.get_block(iso_cell[0], iso_cell[1], iso_cell[2])
	Debug.set_block(iso_cell[0], iso_cell[1], iso_cell[2], 25)
	Save.save_now(1)
	await _continue_slot(0)
	var iso_ok := true
	for k in edited:
		if world.get_block(k[0], k[1], k[2]) != edited[k]:
			iso_ok = false
	if world.get_block(iso_cell[0], iso_cell[1], iso_cell[2]) != iso_base:
		iso_ok = false
	Save.clear(1)
	var clear_ok := not FileAccess.file_exists("user://awecraft_save_1.json") and Save.meta(1).is_empty()
	# AC-0143 M5: a v1-format save (no planets, old "cx,cz" edit keys) must
	# soft-fail on load: edits discarded, fresh world, one clear log line.
	var v1_data := {
		"version": 1,
		"seed": S,
		"height": Data.HEIGHT,
		"time": 0.7,
		"ts": 123,
		"edits": {
			"%d,%d" % [int(sx) / 16, int(sz) / 16]: { 0: {"b": 3, "f": 0} },
		},
		"player": {
			"pos": [float(tx) + 0.5, float(ttop) + 1.0, float(tz) + 0.5],
			"yaw": 0.0, "pitch": 0.0, "sel": 0, "hp": 20.0, "hunger": 20.0,
			"inv": [], "armor": [],
		},
	}
	var v1_softfail: bool = false
	var vf := FileAccess.open("user://awecraft_save_0.json", FileAccess.WRITE)
	var v1_written: bool = vf != null
	if v1_written:
		vf.store_string(JSON.stringify(v1_data))
		vf.close()
		await _continue_slot(0)
		v1_softfail = world.edits.is_empty()
	Save.clear(0)
	Save.clear(2)
	var ok: bool = saved_ok and slot0_ok and iso_ok and clear_pre_ok and clear_ok and v1_written and v1_softfail
	Debug.result({
		"ok": ok,
		"saved_ok": saved_ok,
		"clear_ok": clear_ok,
		"clear_pre_ok": clear_pre_ok,
		"blocks_match": blocks_match,
		"blocks_total": blocks_total,
		"unedited_match": unedited_match,
		"unedited_total": unedited.size(),
		"player_match": player_match,
		"pos_ok": pos_ok, "sel_ok": sel_ok, "hp_ok": hp_ok, "hunger_ok": hunger_ok, "time_ok": time_ok,
		"inv_match": inv_match,
		"slot0_ok": slot0_ok,
		"v1_softfail": v1_softfail,
		"iso_ok": iso_ok,
		"iso_base": iso_base,
		"pos_before": pos_before,
		"pos_after": pos_after,
	})
	get_tree().quit()


# AC-0078 probe-only (env-gated by AWECRAFT_LOGIC=continue, never runs in game):
# measures the Continue path load->spawn wait. Mirrors _continue_slot
# (main.gd:378-403) with two extra clocks: core_ms = time until the 3x3 around
# the SAVED position is mesh_built (the designed P1.6 wait), full_radius_ms =
# time until the full radius is mesh_built (the current PRE wait).
func _continue_probe() -> void:
	var S := 44
	Save.clear(0)
	var t_start := Time.get_ticks_msec()
	await _start_world_to_slot(S, 0)
	var sp: Vector3 = world.spawn_point()
	var sx := int(sp.x)
	var sz := int(sp.z)
	var top: int = world.surface_top(sx, sz)
	var cdist := int(OS.get_environment("AWECRAFT_CONTINUE_DIST"))
	var tx := sx + 5 + cdist * 16
	var tz := sz + 5
	# Wait for the SAVE-TARGET chunk to be fully built + collision-bodied before
	# teleporting the player there (a legitimate save = resting on real ground).
	var ttx := int(floorf(float(tx) / 16.0))
	var ttz := int(floorf(float(tz) / 16.0))
	var ttwait := 0
	while ttwait < 600:
		var tc = world.chunks.get("%d,%d" % [ttx, ttz])
		if tc != null and not tc.data.is_empty() and tc.mesh_built and tc.has_any_slab_body():
			break
		await get_tree().physics_frame
		ttwait += 1
	var ttop: int = world.surface_top(tx, tz)
	Debug.set_block(sx, top, sz, 3)
	Debug.set_block(sx + 1, top, sz, 4)
	Debug.set_block(sx, top + 1, sz, 6)
	Debug.set_block(sx + 2, top, sz + 1, 23)
	Debug.set_block(sx - 1, top, sz - 1, 22)
	var pl = Game.player
	Debug.give_item(111, 3)
	Debug.teleport(float(tx) + 0.5, float(ttop) + 1.0, float(tz) + 0.5)
	pl.sel = 2
	for i in 20:
		await get_tree().physics_frame
	var save_y: float = Game.player.position.y
	var save_settled: bool = absf(save_y - (float(ttop) + 1.0)) < 0.5
	var saved_ok := Save.save_now(0)
	var new_world_ms := Time.get_ticks_msec() - t_start
	_free_game_nodes()
	var data := Save.load_full(0)
	Save.active_slot = 0
	Game.new_world(int(data.get("seed", 1)))
	_create_game_nodes()
	world.edits = _conv_edits_v2(data.get("edits", {}))
	var ps: Dictionary = data.get("player", {})
	var pos: Array = ps.get("pos", [])
	var target: Vector3
	if pos.size() == 3:
		target = Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
	else:
		target = world.spawn_point()
	var t_c0 := Time.get_ticks_msec()
	world.recenter(target.x, target.z, true)
	var tpcx := int(floorf(target.x / 16.0))
	var tpcz := int(floorf(target.z / 16.0))
	var wait_mode := OS.get_environment("AWECRAFT_CONTINUE_WAIT")  # ""|pre = current _await_world_build semantics; core = 3x3 wait (the designed fix)
	var core_ms := -1
	var waited := 0
	while waited < 3000:
		if core_ms < 0:
			var core := true
			for dx in range(-1, 2):
				for dz in range(-1, 2):
					var c = world.chunks.get("%d,%d" % [tpcx + dx, tpcz + dz])
					if c == null or c.data.is_empty() or not c.mesh_built:
						core = false
						break
				if not core:
					break
			if core:
				core_ms = Time.get_ticks_msec() - t_c0
		if wait_mode == "core":
			if core_ms >= 0:
				break
		else:
			# current _await_world_build semantics (main.gd:4079-4094 era): all
			# EXISTING in-radius chunks built -> exit (early-exit by design).
			var all := true
			for key in world.chunks:
				var cc: Node3D = world.chunks[key]
				if absi(cc.cx - tpcx) <= world.render_radius and absi(cc.cz - tpcz) <= world.render_radius and not cc.mesh_built:
					all = false
					break
			if all:
				break
		await get_tree().physics_frame
		waited += 1
	player = _spawn_player()
	var sc = world.chunks.get("%d,%d" % [tpcx, tpcz])
	var saved_chunk_built_at_spawn: bool = sc != null and not sc.data.is_empty() and sc.mesh_built
	var col_body_at_spawn: bool = sc != null and sc.has_any_slab_body()
	_restore_player(ps)
	if Game.world != null:
		world.recenter(player.position.x, player.position.z)
	Game.time_of_day = float(data.get("time", 0.0))
	Game.start()
	var load_spawn_ms := Time.get_ticks_msec() - t_c0
	var y0: float = Game.player.position.y
	var ytrace: Array = [roundf(y0 * 10.0) / 10.0]
	var body30 := false
	for i in 30:
		await get_tree().physics_frame
		ytrace.append(roundf(Game.player.position.y * 10.0) / 10.0)
		if i == 24:
			var sc30 = world.chunks.get("%d,%d" % [tpcx, tpcz])
			body30 = sc30 != null and sc30.has_any_slab_body()
	var fell: bool = (Game.player.position.y < y0 - 2.0)
	var pl2 = Game.player
	var edits_ok: bool = world.get_block(sx, top, sz) == 3 and world.get_block(sx + 1, top, sz) == 4 \
		and world.get_block(sx, top + 1, sz) == 6 and world.get_block(sx + 2, top, sz + 1) == 23 \
		and world.get_block(sx - 1, top, sz - 1) == 22
	var pos_ok: bool = pl2 != null and absf(pl2.position.x - (float(tx) + 0.5)) < 0.35 \
		and absf(pl2.position.z - (float(tz) + 0.5)) < 0.35
	Save.clear(0)
	Debug.result({
		"mode": "continue",
		"saved_ok": bool(saved_ok),
		"edits_ok": bool(edits_ok),
		"pos_ok": bool(pos_ok),
		"render_radius": int(world.render_radius),
		"new_world_ms": int(new_world_ms),
		"wait_mode": wait_mode,
		"core_ms": int(core_ms),
		"load_spawn_ms": int(load_spawn_ms),
		"save_settled": bool(save_settled),
		"save_y": roundf(save_y * 100.0) / 100.0,
		"saved_chunk_built_at_spawn": bool(saved_chunk_built_at_spawn),
		"col_body_at_spawn": bool(col_body_at_spawn),
		"fell_after_30f": bool(fell),
		"col_body_at_25f": bool(body30),
		"y_trace": ytrace,
		"last_pcx": int(world.last_pcx),
		"last_pcz": int(world.last_pcz),
		"player_pos": [roundf(pl2.position.x * 100.0) / 100.0, roundf(pl2.position.y * 100.0) / 100.0, roundf(pl2.position.z * 100.0) / 100.0] if pl2 != null else [],
	})
	get_tree().quit()


func _quitmenu_test(slot: int, spawn: Vector3) -> void:
	var sx := int(spawn.x)
	var sz := int(spawn.z)
	var top: int = world.surface_top(sx, sz)
	Debug.set_block(sx + 5, top, sz + 5, 3)
	Debug.set_block(sx + 6, top, sz + 5, 4)
	Debug.set_block(sx + 5, top + 1, sz + 5, 6)
	Debug.set_block(sx + 4, top - 2, sz + 5, 16)
	Debug.set_block(sx + 5, top, sz + 6, 23)
	Debug.set_block(sx + 4, top, sz + 4, 22)
	for i in 12:
		await get_tree().physics_frame
	Game.pause()
	for i in 8:
		await get_tree().physics_frame
	var paused_ok: bool = menu_ui != null and menu_ui._state == "pause"
	var wref := world
	var pref := player
	menu_ui._on_quit_btn_pressed()
	for i in 30:
		await get_tree().physics_frame
	var mode_ok := Game.mode == "menu"
	var menu_active: bool = menu_ui != null and menu_ui._state == "main"
	var world_cleared := world == null and Game.world == null and player == null and Game.player == null \
		and not is_instance_valid(wref) and not is_instance_valid(pref)
	var save_written := Save.file_exists(slot)
	var slotdata := Save.load_full(slot)
	var seed_ok := int(slotdata.get("seed", -1)) == int(Game.world_seed)
	var edits_ok := Save.edit_count(slotdata.get("edits", {})) >= 6
	var script_errors_seen := true
	var sef := OS.get_environment("AWECRAFT_STDERR_FILE")
	if sef != "":
		var cnt: Array = []
		OS.execute("grep", ["-c", "SCRIPT ERROR:", sef], cnt)
		script_errors_seen = not (cnt.size() == 0 or int(cnt[0]) == 0)
	var ok: bool = paused_ok and mode_ok and menu_active and world_cleared and save_written and seed_ok and edits_ok and not script_errors_seen
	Debug.result({
		"ok": ok,
		"paused_ok": paused_ok,
		"menu_scene_active": mode_ok and menu_active,
		"world_cleared": world_cleared,
		"save_written": save_written,
		"seed_ok": seed_ok,
		"edits_ok": edits_ok,
		"slot": slot,
		"script_errors_seen": script_errors_seen,
	})
	get_tree().quit()


func _mainmenuexit_test() -> void:
	await _boot_menu()
	for i in 6:
		await get_tree().process_frame
	var state_ok: bool = menu_ui != null and menu_ui._state == "main" and menu_ui.visible
	var exit_btn := _find_exit_button()
	Debug.result({
		"menu": "mainmenuexit",
		"menu_state": String(menu_ui._state) if menu_ui != null else "null",
		"menu_visible": menu_ui != null and menu_ui.visible,
		"exit_found": exit_btn != null,
		"ready_to_quit": state_ok and exit_btn != null,
	})
	if not (state_ok and exit_btn != null):
		get_tree().quit(1)
		return
	exit_btn.pressed.emit()


func _find_exit_button() -> Button:
	var stack := [menu_ui.main_box]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is Button and (n as Button).text == "Exit":
			return n as Button
		for c in n.get_children():
			stack.append(c)
	return null


func _await_spawn_floor(spawn: Vector3, max_frames: int) -> void:
	var pcx := int(floorf(spawn.x / 16.0))
	var pcz := int(floorf(spawn.z / 16.0))
	var waited := 0
	while waited < max_frames:
		var c = world.chunks.get("%d,%d" % [pcx, pcz])
		if c != null and c.mesh_built:
			return
		await get_tree().physics_frame
		waited += 1


func _await_world_build(where: Vector3, max_frames: int) -> void:
	var pcx := int(floorf(where.x / 16.0))
	var pcz := int(floorf(where.z / 16.0))
	var waited := 0
	while waited < max_frames:
		var all := true
		for key in world.chunks:
			var cc: Node3D = world.chunks[key]
			if absi(cc.cx - pcx) <= world.render_radius and absi(cc.cz - pcz) <= world.render_radius and not cc.mesh_built:
				all = false
				break
		if all:
			return
		await get_tree().physics_frame
		waited += 1
	print("SNAPDRAIN not fully drained after %d frames" % max_frames)


# AC-0135: fire-and-forget companion to _await_world_build for long
# AWECRAFT_SNAP_DRAIN runs. Re-pins the aim player's pose every 300 physics
# frames so collision de-penetration (fresh chunk bodies closing in on a far
# teleport target) cannot drift the snapshot camera.
func _aim_pose_guard(pose: Vector3, yaw: float, pitch: float, max_frames: int) -> void:
	var waited := 0
	while waited < max_frames:
		for i in 300:
			await get_tree().physics_frame
		waited += 300
		if player == null:
			return
		player.position = pose
		player.look(yaw, pitch)


func _await_core_3x3(where: Vector3, max_frames: int) -> void:
	var pcx := int(floorf(where.x / 16.0))
	var pcz := int(floorf(where.z / 16.0))
	var waited := 0
	while waited < max_frames:
		var allb := true
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var c = world.chunks.get("%d,%d" % [pcx + dx, pcz + dz])
				if c == null or c.data.is_empty() or not c.mesh_built:
					allb = false
					break
		if allb:
			return
		await get_tree().physics_frame
		waited += 1
	print("CORE3X3 not fully built after %d frames" % max_frames)


func _viewmodel_shot() -> void:
	var p = Game.player
	var shot := OS.get_environment("AWECRAFT_VMSHOT")
	var item := OS.get_environment("AWECRAFT_VMITEM")
	var frac_env := OS.get_environment("AWECRAFT_VMFRACTION")
	if item != "":
		Debug.give_item(item.to_int(), 1)
		p.sel = _slot_of(p, item.to_int())
	await _await_world_build(p.position, 300)
	for i in 10:
		await get_tree().physics_frame
	var cam: Camera3D = p.camera
	var idle_ih := Vector3.INF
	var idle_ip := Vector3.INF
	var apex_ih := Vector3.INF
	var apex_ip := Vector3.INF
	if p.held_tool != null and p.held_tool.visible:
		var head_mi := p.held_tool.get_node_or_null("head") as MeshInstance3D
		var handle_mi := p.held_tool.get_node_or_null("handle") as MeshInstance3D
		idle_ih = _toolpose_centroid(cam, head_mi)
		idle_ip = _toolpose_centroid(cam, handle_mi)
	if frac_env != "":
		p.hold_swing(frac_env.to_float(), p.SWING_ITEM)
		for i in 6:
			await get_tree().physics_frame
		if p.held_tool != null and p.held_tool.visible:
			var head_mi := p.held_tool.get_node_or_null("head") as MeshInstance3D
			var handle_mi := p.held_tool.get_node_or_null("handle") as MeshInstance3D
			apex_ih = _toolpose_centroid(cam, head_mi)
			apex_ip = _toolpose_centroid(cam, handle_mi)
	if shot != "":
		await Debug.snap(shot)
	Debug.result({
		"vmshot": shot, "frac": frac_env, "idle_head": [roundf(idle_ih.x * 1000.0) / 1000.0, roundf(idle_ih.y * 1000.0) / 1000.0, roundf(idle_ih.z * 1000.0) / 1000.0],
		"idle_handle": [roundf(idle_ip.x * 1000.0) / 1000.0, roundf(idle_ip.y * 1000.0) / 1000.0, roundf(idle_ip.z * 1000.0) / 1000.0],
		"apex_head": [roundf(apex_ih.x * 1000.0) / 1000.0, roundf(apex_ih.y * 1000.0) / 1000.0, roundf(apex_ih.z * 1000.0) / 1000.0],
		"apex_handle": [roundf(apex_ip.x * 1000.0) / 1000.0, roundf(apex_ip.y * 1000.0) / 1000.0, roundf(apex_ip.z * 1000.0) / 1000.0],
	})
	get_tree().quit()


func _held_test() -> void:
	var p = Game.player
	for i in 10:
		await get_tree().physics_frame
	var res: Dictionary = {}
	Debug.give_item(18, 3)
	p.sel = _slot_of(p, 18)
	for i in 6:
		await get_tree().physics_frame
	var cross_ok := false
	var cross: Dictionary = {}
	if p.held_box != null and p.held_box.visible:
		var me = p.held_box.mesh
		if me is ArrayMesh:
			var am: ArrayMesh = me
			if am.get_surface_count() > 0:
				var ss = am.surface_get_arrays(0)
				var verts: PackedVector3Array = ss[Mesh.ARRAY_VERTEX]
				var uvs: PackedVector2Array = ss[Mesh.ARRAY_TEX_UV]
				var cols: PackedColorArray = ss[Mesh.ARRAY_COLOR]
				var idx: PackedInt32Array = ss[Mesh.ARRAY_INDEX]
				var tl := Data.block_rect(18, "top")
				var minx := INF
				var miny := INF
				var maxx := -INF
				var maxy := -INF
				for uvv in uvs:
					minx = minf(minx, uvv.x)
					miny = minf(miny, uvv.y)
					maxx = maxf(maxx, uvv.x)
					maxy = maxf(maxy, uvv.y)
				var px := [int(round(minx * Data.ATLAS_PX)), int(round(miny * Data.ATLAS_PX)), int(round(maxx * Data.ATLAS_PX)), int(round(maxy * Data.ATLAS_PX))]
				var inx0 := (float(tl.x) + 0.5) / Data.ATLAS_PX
				var inx1 := (float(tl.x) + 31.5) / Data.ATLAS_PX
				var iny0 := (float(tl.y) + 0.5) / Data.ATLAS_PX
				var iny1 := (float(tl.y) + 31.5) / Data.ATLAS_PX
				var uv_ok := absf(minx - inx0) < 0.002 and absf(maxx - inx1) < 0.002 \
					and absf(miny - iny0) < 0.002 and absf(maxy - iny1) < 0.002
				var mat = p.held_box.material_override
				var mat_ok := mat is StandardMaterial3D \
					and (mat as StandardMaterial3D).transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR \
					and (mat as StandardMaterial3D).cull_mode == BaseMaterial3D.CULL_DISABLED
				var want: Color = Color(0.9, 0.9, 0.9) * Data.block_tint(18, "top")
				var c0: Color = cols[0]
				var col_ok := absf(c0.r - want.r) < 0.002 and absf(c0.g - want.g) < 0.002 and absf(c0.b - want.b) < 0.002
				cross_ok = idx.size() / 3 == 4 and verts.size() == 8 and uv_ok and mat_ok and col_ok
				cross = {"tris": idx.size() / 3, "verts": verts.size(), "tile_top": [int(tl.x), int(tl.y)], "uv_px": px, "mat_ok": mat_ok, "col_ok": col_ok, "atlas_same": (mat as StandardMaterial3D).albedo_texture == Data.atlas_tex}
	res["cross_ok"] = cross_ok
	res["cross_18"] = cross
	res["sprite_hidden"] = p.held_sprite != null and p.held_sprite.visible == false
	Debug.give_item(1, 3)
	p.sel = _slot_of(p, 1)
	for i in 6:
		await get_tree().physics_frame
	var box_ok := false
	var boxd: Dictionary = {}
	if p.held_box != null and p.held_box.visible:
		var me2 = p.held_box.mesh
		if me2 is ArrayMesh:
			var am2: ArrayMesh = me2
			if am2.get_surface_count() > 0:
				var ss2 = am2.surface_get_arrays(0)
				var uvs2: PackedVector2Array = ss2[Mesh.ARRAY_TEX_UV]
				var cols2: PackedColorArray = ss2[Mesh.ARRAY_COLOR]
				var idx2: PackedInt32Array = ss2[Mesh.ARRAY_INDEX]
				var names: Array = ["side", "side", "top", "bottom", "side", "side"]
				var spans := {}
				var all_ok := true
				for fi in 6:
					var b0 := fi * 4
					var mnx := INF
					var mny := INF
					var mxx := -INF
					var myy := -INF
					for j in 4:
							mnx = minf(mnx, uvs2[b0 + j].x)
							mny = minf(mny, uvs2[b0 + j].y)
							mxx = maxf(mxx, uvs2[b0 + j].x)
							myy = maxf(myy, uvs2[b0 + j].y)
					var fn := String(names[fi])
					var tl2 := Data.block_rect(1, fn)
					var fx0 := (float(tl2.x) + 0.5) / Data.ATLAS_PX
					var fx1 := (float(tl2.x) + 31.5) / Data.ATLAS_PX
					var fy0 := (float(tl2.y) + 0.5) / Data.ATLAS_PX
					var fy1 := (float(tl2.y) + 31.5) / Data.ATLAS_PX
					var fok := absf(mnx - fx0) < 0.002 and absf(mxx - fx1) < 0.002 \
						and absf(mny - fy0) < 0.002 and absf(myy - fy1) < 0.002
					all_ok = all_ok and fok
					spans[fn] = {"tile": [int(tl2.x), int(tl2.y)], "uv_px": [int(round(mnx * Data.ATLAS_PX)), int(round(mny * Data.ATLAS_PX)), int(round(mxx * Data.ATLAS_PX)), int(round(myy * Data.ATLAS_PX))], "ok": fok}
				var tcol: Color = cols2[10]
				var top_want := Color(1.0, 1.0, 1.0) * Data.block_tint(1, "top")
				var tint_top_ok := absf(tcol.r - top_want.r) < 0.002 and absf(tcol.g - top_want.g) < 0.002 and absf(tcol.b - top_want.b) < 0.002
				var scol: Color = cols2[0]
				var side_want := Color(0.8, 0.8, 0.8) * Data.block_tint(1, "side")
				var tint_side_ok := absf(scol.r - side_want.r) < 0.002 and absf(scol.g - side_want.g) < 0.002 and absf(scol.b - side_want.b) < 0.002
				var mat2 = p.held_box.material_override
				var mat2_ok := mat2 is StandardMaterial3D and (mat2 as StandardMaterial3D).albedo_texture == Data.atlas_tex
				box_ok = idx2.size() / 3 == 12 and uvs2.size() == 24 and all_ok and tint_top_ok and tint_side_ok and mat2_ok
				boxd = {"tris": idx2.size() / 3, "faces": spans, "tint_top_ok": tint_top_ok, "tint_side_ok": tint_side_ok, "atlas_same": mat2_ok}
	res["box_ok"] = box_ok
	res["box_1"] = boxd
	res["scale_ok"] = p.held_box != null and p.held_box.scale == Vector3(0.7, 0.7, 0.7) and p.held_sprite != null and p.held_sprite.scale == Vector3(0.7, 0.7, 0.7)
	var depth: Dictionary = {}
	var depth_ok := true
	p.sel = _slot_of(p, 18)
	for i in 6:
		await get_tree().physics_frame
	var dm1 = p.held_box.material_override
	depth["cross"] = p.held_box.visible and dm1 is StandardMaterial3D \
		and (dm1 as StandardMaterial3D).depth_draw_mode == BaseMaterial3D.DEPTH_DRAW_DISABLED
	p.sel = _slot_of(p, 1)
	for i in 6:
		await get_tree().physics_frame
	var dm2 = p.held_box.material_override
	depth["block"] = p.held_box.visible and dm2 is StandardMaterial3D \
		and (dm2 as StandardMaterial3D).depth_draw_mode == BaseMaterial3D.DEPTH_DRAW_DISABLED
	Debug.give_item(111, 1)
	p.sel = _slot_of(p, 111)
	for i in 6:
		await get_tree().physics_frame
	var tcnt := 0
	var tool_d := false
	if p.held_tool != null and p.held_tool.visible:
		for c in p.held_tool.get_children():
			if c is MeshInstance3D:
				tcnt += 1
				var tm = (c as MeshInstance3D).material_override
				if tm is StandardMaterial3D and (tm as StandardMaterial3D).depth_draw_mode == BaseMaterial3D.DEPTH_DRAW_DISABLED:
					tool_d = true
	depth["tool"] = tool_d and tcnt > 0
	Debug.give_item(107, 1)
	p.sel = _slot_of(p, 107)
	for i in 6:
		await get_tree().physics_frame
	var spr_d := false
	if p.held_sprite != null and p.held_sprite.visible:
		spr_d = p.held_sprite.no_depth_test == true
	depth["sprite"] = spr_d
	var eslot := -1
	for i in p.inv.size():
		if int(p.inv[i]["id"]) == 0:
			eslot = i
			break
	p.sel = eslot
	for i in 6:
		await get_tree().physics_frame
	var fist_d := false
	if p.held_fist != null and p.held_fist.visible and p.held_fist.material_override is StandardMaterial3D:
		fist_d = (p.held_fist.material_override as StandardMaterial3D).depth_draw_mode == BaseMaterial3D.DEPTH_DRAW_DISABLED
	depth["fist"] = fist_d
	depth_ok = depth_ok and bool(depth["cross"]) and bool(depth["block"]) and bool(depth["tool"]) and bool(depth["sprite"]) and bool(depth["fist"])
	res["depth"] = depth
	res["depth_ok"] = depth_ok
	Debug.result(res)
	get_tree().quit()


func _toolres_test() -> void:
	var p = Game.player
	for i in 10:
		await get_tree().physics_frame
	var r := {}
	var ok := true
	var old_diag := {111: 1.224, 113: 1.224, 115: 1.10, 119: 1.10, 123: 0.796}
	var exp_type := {111: "pick", 113: "pick", 115: "axe", 119: "shovel", 123: "sword"}
	for tid in [111, 113, 115, 119, 123]:
		Debug.give_item(tid, 1)
		p.sel = _slot_of(p, tid)
		for i in 6:
			await get_tree().physics_frame
		var present: bool = p.held_tool != null and p.held_tool.visible
		var fist: bool = p.held_fist.visible
		var sprite: bool = p.held_sprite.visible
		var box: bool = p.held_box.visible
		var ctype: String = String(p.held_tool_type)
		var tcnt := 0
		var aabb := AABB()
		var has_aabb := false
		if p.held_tool != null:
			for c in p.held_tool.get_children():
				if c is MeshInstance3D:
					tcnt += 1
					var me = (c as MeshInstance3D).mesh
					if me != null:
						var la: AABB = me.get_aabb()
						if not has_aabb:
							aabb = la
							has_aabb = true
						else:
							aabb = aabb.merge(la)
		var diag := 0.0
		if has_aabb:
			diag = Vector3(aabb.size).length()
		var headc: Color = p.held_head_color()
		var tint: Color = Data.item_tint(tid)
		var head_ok := headc.is_equal_approx(tint)
		var count := int(p.held_tool_voxel_count())
		var size_ok := has_aabb and absf(diag - float(old_diag[tid])) <= 0.25 * float(old_diag[tid])
		var row_ok: bool = present and ctype == String(exp_type[tid]) and not fist and not sprite and not box \
			and tcnt > 0 and count >= 20 and head_ok and size_ok
		r["tool_%d" % tid] = {
			"present": present, "type": ctype, "fist": fist, "sprite": sprite, "box": box,
			"voxel_children": tcnt, "voxel_count": count,
			"old_diag": float(old_diag[tid]), "new_diag": roundf(diag * 1000.0) / 1000.0,
			"head_html": headc.to_html(), "tint_html": tint.to_html(),
			"head_ok": head_ok, "size_ok": size_ok, "ok": row_ok,
		}
		ok = ok and row_ok
	var tier_nei := Data.item_tint(111) != Data.item_tint(113)
	r["tier_tint_111_ne_113"] = tier_nei
	ok = ok and tier_nei
	r["ok"] = ok
	Debug.result(r)
	get_tree().quit()


func _toolpose_centroid(cam: Camera3D, mi: MeshInstance3D) -> Vector3:
	if mi == null or mi.mesh == null:
		return Vector3(INF, INF, INF)
	var gt: Transform3D = mi.get_global_transform()
	var center: Vector3 = gt.basis * mi.mesh.get_aabb().get_center() + gt.origin
	return cam.to_local(center)


func _toolpose_test() -> void:
	var p = Game.player
	for i in 10:
		await get_tree().physics_frame
	var cam: Camera3D = p.camera
	var res: Dictionary = {}
	var ok := true
	if p.held_box != null:
		res["held_box_scale_x"] = roundf(p.held_box.scale.x * 1000.0) / 1000.0
	else:
		res["held_box_scale_x"] = -1.0
	if p.held_sprite != null:
		res["held_sprite_scale_x"] = roundf(p.held_sprite.scale.x * 1000.0) / 1000.0
	else:
		res["held_sprite_scale_x"] = -1.0
	var scale_ok := absf(float(res["held_box_scale_x"]) - 0.70) <= 0.05 and absf(float(res["held_sprite_scale_x"]) - 0.70) <= 0.05
	res["scale_ok"] = scale_ok
	ok = ok and scale_ok
	var old_diag := {111: 0.612, 115: 0.55, 119: 0.55, 123: 0.398}
	var exp_type := {111: "pick", 115: "axe", 119: "shovel", 123: "sword"}
	var tool_d_ok := true
	for tid in [111, 115, 119, 123]:
		Debug.give_item(tid, 1)
		p.sel = _slot_of(p, tid)
		for i in 10:
			await get_tree().physics_frame
		var tool = p.held_tool
		if tool == null or not tool.visible:
			res["tool_%d" % tid] = {"ok": false, "reason": "missing"}
			ok = false
			continue
		var head_mi := tool.get_node_or_null("head") as MeshInstance3D
		var handle_mi := tool.get_node_or_null("handle") as MeshInstance3D
		var ih: Vector3 = _toolpose_centroid(cam, head_mi)
		var ip: Vector3 = _toolpose_centroid(cam, handle_mi)
		var ir: Vector3 = p.hand_pose_rot()
		p.hold_swing(0.5, p.SWING_ITEM)
		for i in 10:
			await get_tree().physics_frame
		var ah: Vector3 = _toolpose_centroid(cam, head_mi)
		var ap: Vector3 = _toolpose_centroid(cam, handle_mi)
		var ar: Vector3 = p.hand_pose_rot()
		p.clear_swing()
		for i in 10:
			await get_tree().physics_frame
		var aabb := AABB()
		var has := false
		for c in tool.get_children():
			if c is MeshInstance3D and (c as MeshInstance3D).visible:
				var la: AABB = (c as MeshInstance3D).mesh.get_aabb()
				aabb = la if not has else aabb.merge(la)
				has = true
		var diag := 0.0
		if has:
			diag = Vector3(aabb.size).length()
		var old: float = float(old_diag[tid])
		var diag_ok := has and absf(diag - 2.0 * old) <= 0.15 * 2.0 * old
		var pos_ok := ih.z < ip.z and ih.y > ip.y and absf(ih.x) < absf(ip.x)
		var d_idle := Vector2(ih.x, ih.y).length()
		var d_apex := Vector2(ah.x, ah.y).length()
		var rot_delta := (ar - ir).length()
		var arc_ok := rot_delta > 0.4
		var hdy := ih.y - ip.y
		var hdx := ih.x - ip.x
		var vert_ok := hdy > 0.0 and hdy > 0.3 * absf(hdx)
		var below_ok := ip.y < -0.55
		var dtool := true
		for c in tool.get_children():
			if c is MeshInstance3D:
				var tm = (c as MeshInstance3D).material_override
				dtool = dtool and tm is StandardMaterial3D and (tm as StandardMaterial3D).depth_draw_mode == BaseMaterial3D.DEPTH_DRAW_DISABLED
		tool_d_ok = tool_d_ok and dtool
		var row_ok: bool = String(p.held_tool_type) == String(exp_type[tid]) and pos_ok and arc_ok and diag_ok and dtool and vert_ok and below_ok
		ok = ok and row_ok
		res["tool_%d" % tid] = {
			"type": String(p.held_tool_type),
			"idle_head": [roundf(ih.x * 1000.0) / 1000.0, roundf(ih.y * 1000.0) / 1000.0, roundf(ih.z * 1000.0) / 1000.0],
			"idle_handle": [roundf(ip.x * 1000.0) / 1000.0, roundf(ip.y * 1000.0) / 1000.0, roundf(ip.z * 1000.0) / 1000.0],
			"apex_head": [roundf(ah.x * 1000.0) / 1000.0, roundf(ah.y * 1000.0) / 1000.0, roundf(ah.z * 1000.0) / 1000.0],
			"apex_handle": [roundf(ap.x * 1000.0) / 1000.0, roundf(ap.y * 1000.0) / 1000.0, roundf(ap.z * 1000.0) / 1000.0],
			"head_in_front": ih.z < ip.z, "head_above": ih.y > ip.y, "head_centered": absf(ih.x) < absf(ip.x),
			"rest_dy": roundf(hdy * 1000.0) / 1000.0, "rest_dx": roundf(hdx * 1000.0) / 1000.0,
			"vertical_ok": vert_ok, "handle_below_cam": ip.y < -0.55,
			"rot_delta": roundf(rot_delta * 1000.0) / 1000.0, "arc_ok": arc_ok,
			"d_idle": roundf(d_idle * 1000.0) / 1000.0, "d_apex": roundf(d_apex * 1000.0) / 1000.0,
			"bbox_diag": roundf(diag * 1000.0) / 1000.0, "diag_2x_ok": diag_ok,
			"depth_disabled": dtool, "ok": row_ok,
		}
	var box_d := p.held_box != null and p.held_box.material_override is StandardMaterial3D \
		and (p.held_box.material_override as StandardMaterial3D).depth_draw_mode == BaseMaterial3D.DEPTH_DRAW_DISABLED
	var fist_d := p.held_fist != null and p.held_fist.material_override is StandardMaterial3D \
		and (p.held_fist.material_override as StandardMaterial3D).depth_draw_mode == BaseMaterial3D.DEPTH_DRAW_DISABLED
	var spr_d: bool = p.held_sprite != null and (p.held_sprite.no_depth_test == true)
	var depth_ok_all: bool = tool_d_ok and box_d and fist_d and spr_d
	res["depth"] = {"tool": tool_d_ok, "box": box_d, "fist": fist_d, "sprite": spr_d}
	res["depth_ok"] = depth_ok_all
	ok = ok and depth_ok_all
	res["ok"] = ok
	Debug.result(res)
	get_tree().quit()


func _force_viewmodel_depth_on(p) -> void:
	if p.held_box != null and p.held_box.material_override is StandardMaterial3D:
		(p.held_box.material_override as StandardMaterial3D).depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
	if p.held_fist != null and p.held_fist.material_override is StandardMaterial3D:
		(p.held_fist.material_override as StandardMaterial3D).depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
	if p.held_tool != null:
		for c in p.held_tool.get_children():
			if c is MeshInstance3D and (c as MeshInstance3D).material_override is StandardMaterial3D:
				((c as MeshInstance3D).material_override as StandardMaterial3D).depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
	if p.held_sprite != null:
		p.held_sprite.no_depth_test = false


var _is_stone := func(c: Color) -> bool: return absf(c.r - c.g) < 14 and absf(c.g - c.b) < 14 and c.r > 24 and c.r < 120


var _is_cyan := func(c: Color) -> bool: return c.b > 150 and c.g > 150 and c.r < 110 and c.b > c.r + 80


func _wallshot_region_count(path: String, pred: Callable, x0: int, x1: int, y0: int, y1: int) -> int:
	var img := Image.load_from_file(path)
	var n := 0
	for y in range(y0, y1, 2):
		for x in range(x0, x1, 2):
			if pred.call(img.get_pixel(x, y)):
				n += 1
	return n


func _wallshot_test() -> void:
	var p = Game.player
	var spawn: Vector3 = world.spawn_point()
	var sx := int(spawn.x)
	var sz := int(spawn.z)
	var feet_y := float(p.position.y)
	var ey := int(floorf(feet_y + p.EYE))
	world.collision_enabled = false
	Debug.fly(true)
	for wx in range(sx - 1, sx + 2):
		for wy in range(ey - 1, ey + 2):
			world.set_block(wx, wy, sz - 1, 3)
	for i in 40:
		await get_tree().physics_frame
	var before := OS.get_environment("AWECRAFT_WALL_BEFORE") == "1"
	var shots := OS.get_environment("AWECRAFT_WALL_SHOTS")
	var outdir := ProjectSettings.globalize_path("res://..") + "/tasks/AC-0067/"
	var res: Dictionary = {"before": before, "shots": shots, "wall_face_z": float(sz) - 1.0, "eye_to_wall_face": 0.5, "hand_to_wall_face": 0.3, "block": false, "item": false}
	var vmx0 := 820
	var vmx1 := 1240
	var vmy0 := 430
	var vmy1 := 700
	if shots == "" or shots.find("block") >= 0:
		Debug.give_item(1, 1)
		p.sel = _slot_of(p, 1)
		for i in 8:
			await get_tree().physics_frame
		if before:
			_force_viewmodel_depth_on(p)
		p.position = Vector3(sx + 0.5, feet_y, float(sz) + 0.5)
		p.look(0.0, 0.0)
		for i in 8:
			await get_tree().physics_frame
		var bpath := outdir + "held_on_wall%s.png" % ("_before" if before else "")
		await Debug.snap(bpath)
		res["block"] = true
		res["block_frame_stone"] = _wallshot_region_count(bpath, _is_stone, 0, 1280, 0, 720)
		res["block_vm_nonstone"] = _wallshot_region_count(bpath, func(c: Color) -> bool: return not _is_stone.call(c), vmx0, vmx1, vmy0, vmy1)
		var bm = p.held_box.material_override if p.held_box != null else null
		res["block_box_vis"] = p.held_box != null and p.held_box.visible
		res["block_depth_on"] = bm is StandardMaterial3D and (bm as StandardMaterial3D).depth_draw_mode == BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
	if shots == "" or shots.find("item") >= 0:
		Debug.give_item(107, 1)
		p.sel = _slot_of(p, 107)
		for i in 8:
			await get_tree().physics_frame
		if before:
			_force_viewmodel_depth_on(p)
		p.position = Vector3(sx + 0.5, feet_y, float(sz) + 0.5)
		p.look(0.0, 0.0)
		for i in 8:
			await get_tree().physics_frame
		var ipath := outdir + "held_item_on_wall%s.png" % ("_before" if before else "")
		await Debug.snap(ipath)
		res["item"] = true
		res["item_vm_cyan"] = _wallshot_region_count(ipath, _is_cyan, vmx0, vmx1, vmy0, vmy1)
		res["item_sprite_vis"] = p.held_sprite != null and p.held_sprite.visible
	Debug.result(res)
	get_tree().quit()


func _fpv_test() -> void:
	var p = Game.player
	for i in 10:
		await get_tree().physics_frame
	Debug.give_item(3, 5)
	p.sel = _slot_of(p, 3)
	for i in 6:
		await get_tree().physics_frame
	var block_visible := false
	var block_type_ok := false
	var sprite_hidden: bool = p.held_sprite != null and p.held_sprite.visible == false
	var region_ok := false
	var region_actual := [-1, -1]
	var region_want := Data.block_rect(3, "side")
	if p.held_box != null:
		block_visible = p.held_box.visible
		var me = p.held_box.mesh
		if me is ArrayMesh:
			block_type_ok = true
			var am: ArrayMesh = me
			if am.get_surface_count() > 0:
				var ss = am.surface_get_arrays(0)
				var uvs: PackedVector2Array = ss[Mesh.ARRAY_TEX_UV]
				var idx: PackedInt32Array = ss[Mesh.ARRAY_INDEX]
				if idx.size() / 3 == 12 and uvs.size() == 24:
					var mnx := INF
					var mny := INF
					var mxx := -INF
					var myy := -INF
					for j in 4:
						mnx = minf(mnx, uvs[j].x)
						mny = minf(mny, uvs[j].y)
						mxx = maxf(mxx, uvs[j].x)
						myy = maxf(myy, uvs[j].y)
					region_actual = [int(round(mnx * Data.ATLAS_PX)), int(round(mny * Data.ATLAS_PX))]
					var ex0 := (float(region_want.x) + 0.5) / Data.ATLAS_PX
					var ex1 := (float(region_want.x) + 31.5) / Data.ATLAS_PX
					var ey0 := (float(region_want.y) + 0.5) / Data.ATLAS_PX
					var ey1 := (float(region_want.y) + 31.5) / Data.ATLAS_PX
					region_ok = absf(mnx - ex0) < 0.002 and absf(mxx - ex1) < 0.002 \
						and absf(mny - ey0) < 0.002 and absf(myy - ey1) < 0.002
	Debug.give_item(111, 1)
	p.sel = _slot_of(p, 111)
	for i in 6:
		await get_tree().physics_frame
	var tool_visible := false
	var tool_type_ok := p.held_sprite is Sprite3D
	if p.held_sprite != null:
		tool_visible = p.held_sprite.visible
		tool_type_ok = tool_type_ok and p.held_box.visible == false
	p.sel = 30
	for i in 6:
		await get_tree().physics_frame
	var empty_hidden: bool = p.held_box.visible == false and p.held_sprite.visible == false
	p.look(0.7, 0.0)
	for i in 2:
		await get_tree().physics_frame
	var b: Basis = p.highlight.global_transform.basis
	var hx := b * Vector3(1, 0, 0)
	var hz := b * Vector3(0, 0, 1)
	var highlight_axis_ok := absf(hx.x - 1.0) < 0.001 and absf(hx.y) < 0.001 and absf(hx.z) < 0.001 \
		and absf(hz.x) < 0.001 and absf(hz.y) < 0.001 and absf(hz.z - 1.0) < 0.001
	Debug.result({
		"highlight_axis_ok": highlight_axis_ok,
		"block_held_ok": block_visible and block_type_ok and sprite_hidden and region_ok,
		"block_visible": block_visible,
		"block_type_ok": block_type_ok,
		"sprite_hidden_during_block": sprite_hidden,
		"region_actual": region_actual,
		"region_want": [int(region_want.x), int(region_want.y)],
		"tool_held_ok": tool_visible and tool_type_ok,
		"tool_visible": tool_visible,
		"tool_type_ok": tool_type_ok,
		"empty_hidden_ok": empty_hidden,
	})
	get_tree().quit()


func _count_shapes(n: Node) -> int:
	var c := 1 if n is CollisionShape3D else 0
	for ch: Node in n.get_children():
		c += _count_shapes(ch)
	return c


func _perf_test(spawn: Vector3, t0: int, recenter_ms: int, mem_before: int) -> void:
	var pcx := int(floorf(spawn.x / 16.0))
	var pcz := int(floorf(spawn.z / 16.0))
	var frames := 0
	var max_frame_ms := 0
	var first_draw_ms := -1
	var frame_ms_list: Array = []
	var all := false
	var rr_now: int = world.render_radius
	var max_frames := maxi(1200, (2 * rr_now + 1) * (2 * rr_now + 1) * 5)
	# AC-0197: env override for the R50 gate (a full drain exceeds the
	# default budget; the arm exits early once every mesh-eligible chunk is built).
	var mfenv := int(OS.get_environment("AWECRAFT_PERF_FRAMES"))
	if mfenv > 0:
		max_frames = mfenv
	while frames < max_frames:
		var fb := Time.get_ticks_msec()
		await get_tree().physics_frame
		var fe := Time.get_ticks_msec()
		if fe - fb > max_frame_ms:
			max_frame_ms = fe - fb
		frame_ms_list.append(fe - fb)
		frames += 1
		# AC-0197: progress line so a stalled R50 drain is visible
		# in the log (600 frames = 10 s of real time).
		if frames % 600 == 0:
			var nb := 0
			for kk in world.chunks:
				if (world.chunks[kk] as Node3D).mesh_built:
					nb += 1
			print("PERFPROG frames=%d chunks=%d built=%d gen=%d all=%s" % [frames, world.chunks.size(), nb, world.gen_count, str(all)])
		all = true
		for key in world.chunks:
			var c: Node3D = world.chunks[key]
			if int(c.band) > 2:
				continue
			if absi(c.cx - pcx) <= world.render_radius and absi(c.cz - pcz) <= world.render_radius:
				if not c.mesh_built:
					all = false
					break
		if first_draw_ms < 0:
			var sc = world.chunks.get("%d,%d" % [pcx, pcz])
			if sc != null and sc.mesh_built:
				first_draw_ms = fe - t0
		if all:
			break
	if OS.get_environment("AWECRAFT_MESH_INFO") != "":
		for e in world.mesh_info():
			print("MINFO ", JSON.stringify(e))
		var mi = _matinfo_counts()
		print("MATINFO built_chunks=%d distinct_std=%d distinct_all=%d total_allocs=%d" % [mi.built_chunks, mi.distinct_std, mi.distinct_all, mi.total_allocs])
	var built := 0
	var band3sq := 0
	# AC-0197: null-safe — the pre-AC-0197 world.gd has no such property
	# (the before-baseline run loads old world.gd with this same arm).
	# Untyped var on purpose: Object.get() returns Nil for the missing
	# property, and assigning Nil into a typed Array var is a runtime
	# error in GDScript (would kill the arm before Debug.result).
	var wml = world.get("perf_build_worker_ms_list")
	if wml == null:
		wml = []
	for key in world.chunks:
		var c: Node3D = world.chunks[key]
		if c.mesh_built:
			built += 1
		elif int(c.band) > 2 and absi(c.cx - pcx) <= world.render_radius and absi(c.cz - pcz) <= world.render_radius:
			band3sq += 1
	var total_ms := Time.get_ticks_msec() - t0
	var mem_after: int = OS.get_static_memory_usage()
	var ms_sorted: Array = frame_ms_list.duplicate()
	ms_sorted.sort()
	var shapes := _count_shapes(get_tree().root)
	var rr: int = world.render_radius
	var edge := (float(rr) + 1.0) * 16.0
	Debug.result({
		"chunks": built,
		"render_radius": rr,
		"fog_near": DayNight.fog_near(rr),
		"fog_far": DayNight.fog_far(rr),
		"fog_edge": edge,
		"fog_ok": DayNight.fog_far(rr) < edge,
		"total_chunks": world.chunks.size(),
		"all_meshed": all,
		"collision_shapes": shapes,
		"total_ms": total_ms,
		"frames": frames,
		"recenter_ms": recenter_ms,
		"max_frame_ms": max_frame_ms,
		"build_units": world.perf_build_units,
		"drain_frames": world.perf_drain_frames,
		"max_drain_ms": roundf(world.perf_max_drain_ms * 10.0) / 10.0,
		"gen_ms": world.perf_gen_ms,
		"build_ms": world.perf_build_ms,
		"first_draw_ms": first_draw_ms,
		"p50_ms": int(_percentile(frame_ms_list, 0.50)),
		"p95_ms": int(_percentile(frame_ms_list, 0.95)),
		"frame_max_ms": int(ms_sorted.back()) if not ms_sorted.is_empty() else 0,
		"mem_before_bytes": int(mem_before),
		"mem_after_bytes": int(mem_after),
		"chunks_built": built,
		"built_final": built,
		"band3_in_square": band3sq,
		"max_frames": max_frames,
		"build_worker_n": int(wml.size()),
		"build_worker_p50_ms": int(_percentile(wml, 0.50)),
		"build_worker_p95_ms": int(_percentile(wml, 0.95)),
		"build_worker_max_ms": int(wml.max()) if not wml.is_empty() else 0,
		"drain_s": roundf(total_ms / 1000.0 * 100.0) / 100.0,
		"light_self_computes": int(world.perf_light_self_computes),
		"light_batch_calls": int(world.perf_light_batch_calls),
		"light_batch_chunks": int(world.perf_light_batch_chunks),
		"light_cache_hits": int(world.perf_light_cache_hits),
		"collision_ms_total": int(world.perf_collision_ms),
		"collision_n": int(world.perf_collision_n),
		"collision_max_ms": int(world.perf_collision_max_ms),
		"staged_drained": int(world.perf_staged_drained),
		"staged_dropped": int(world.perf_staged_dropped),
		"read_sync_gen": int(world.perf_read_sync_gen),
		"read_sync_gen_ms": world.perf_read_sync_gen_ms,
		"create_sync_gen": int(world.perf_create_sync_gen),
		"staged_pending_final": int(world._col_pending.size()),
	})
	get_tree().quit()


func _percentile(arr: Array, pct: float) -> float:
	if arr.is_empty():
		return 0.0
	var s: Array = arr.duplicate()
	s.sort()
	var n: int = s.size()
	if n == 1:
		return float(s[0])
	var idx: float = (n - 1) * pct
	var lo: int = int(floorf(idx))
	var hi: int = int(ceilf(idx))
	if lo == hi:
		return float(s[lo])
	var frac: float = idx - float(lo)
	return float(s[lo]) + (float(s[hi]) - float(s[lo])) * frac


func _bm_quad_count(c) -> int:
	var n := 0
	for s in c.slabs:
		for mi in [s.mesh_instance, s.fluid_instance, s.flora_instance]:
			if mi != null and mi.mesh != null:
				var m: ArrayMesh = mi.mesh
				for si in m.get_surface_count():
					n += int(m.surface_get_arrays(si)[Mesh.ARRAY_INDEX].size()) / 6
	return n


func _chunkio_wait(diamond: Array, limit: int) -> int:
	var w := 0
	while w < limit:
		var ready := 0
		for dc in diamond:
			var c = world.chunks.get("%d,%d" % [dc[0], dc[1]])
			if c != null and not c.data.is_empty():
				ready += 1
		if ready == diamond.size():
			return w
		await get_tree().physics_frame
		w += 1
	return w

func _chunkio_hash(diamond: Array) -> Dictionary:
	var out := {}
	for dc in diamond:
		var c = world.chunks.get("%d,%d" % [dc[0], dc[1]])
		if c == null or c.data.is_empty():
			continue
		var h := HashingContext.new()
		h.start(HashingContext.HASH_MD5)
		h.update(c.flat_data())  # AC-0203: same 98304 B column -> same MD5
		var md: PackedByteArray = h.finish()
		var hx := ""
		for i in range(16):
			hx += "%02x" % md[i]
		out["%d,%d" % [dc[0], dc[1]]] = hx
	return out

func _chunkio_file_count(diamond: Array, slot: int) -> int:
	var n := 0
	for dc in diamond:
		if FileAccess.file_exists(ChunkIO.path_for(slot, 1 if dc[0] < 0 else 0, dc[0], dc[1])):
			n += 1
	return n

# AC-0155 probe: full-column save round-trip in one process. Fresh r=4 41-set
# generated (first visit) -> hash -> recenter far (evict, files written) ->
# recenter back (41 read from disk, byte-identical, GENMS 0) -> r=50 revisit
# (saved chunks served from disk, no re-gen). Headless, wall <= 60 s.
func _chunkio_test(spawn: Vector3) -> void:
	var t0 := Time.get_ticks_msec()
	var SLOT := 0
	Save.active_slot = SLOT
	ChunkIO.clear_dir(SLOT)
	world.fluid_sim_enabled = false
	var diamond := []
	for dx in range(-4, 5):
		for dz in range(-4, 5):
			if absi(dx) + absi(dz) <= 4:
				diamond.append([dx, dz])
	var diamond_n := diamond.size()
	# Phase A: fresh r=4 first visit.
	world.render_radius = 4
	world.recenter(spawn.x, spawn.z, true)
	await _chunkio_wait(diamond, 900)
	var gen_a: int = world.gen_count
	var disk_a: int = world.disk_reads
	var hashes := _chunkio_hash(diamond)
	# Phase B: recenter far twice -> the 41 evict -> files written.
	world.recenter(1000.0, 1000.0, true)
	for i in 30:
		await get_tree().physics_frame
	world.recenter(1000.0, 1000.0, true)
	var files_waited := 0
	while files_waited < 2400 and _chunkio_file_count(diamond, SLOT) < diamond_n:
		await get_tree().physics_frame
		files_waited += 1
	var files_exist := _chunkio_file_count(diamond, SLOT)
	# Phase C: revisit r=4 -> 41 read from disk.
	world.render_radius = 4
	world.recenter(spawn.x, spawn.z, true)
	await _chunkio_wait(diamond, 900)
	var byte_identical := 0
	var origin_disk := 0
	var origin_gen := 0
	var hashes_c := _chunkio_hash(diamond)
	for dc in diamond:
		var key := "%d,%d" % [dc[0], dc[1]]
		if hashes_c.get(key) == hashes.get(key):
			byte_identical += 1
		var o = world.chunk_origin.get(key)
		if o == "disk":
			origin_disk += 1
		elif o == "gen":
			origin_gen += 1
	var gen_delta_c: int = world.gen_count - gen_a
	var disk_delta_c: int = world.disk_reads - disk_a
	# Phase D: free the 41, then r=50 revisit -> served from disk.
	world.render_radius = 4
	world.recenter(1000.0, 1000.0, true)
	for i in 30:
		await get_tree().physics_frame
	world.recenter(1000.0, 1000.0, true)
	for i in 30:
		await get_tree().physics_frame
	world.render_radius = 50
	world.recenter(spawn.x, spawn.z, true)
	await _chunkio_wait(diamond, 1200)
	var d50_disk := 0
	var d50_gen := 0
	for dc in diamond:
		var o = world.chunk_origin.get("%d,%d" % [dc[0], dc[1]])
		if o == "disk":
			d50_disk += 1
		elif o == "gen":
			d50_gen += 1
	var wall := Time.get_ticks_msec() - t0
	var ok := files_exist == diamond_n and byte_identical == diamond_n and origin_disk == diamond_n and origin_gen == 0 and d50_disk == diamond_n and d50_gen == 0 and wall <= 60000
	Debug.result({
		"ok": ok,
		"wall_ms": wall,
		"diamond": diamond_n,
		"files_exist": files_exist,
		"byte_identical": byte_identical,
		"origin_disk": origin_disk,
		"origin_gen": origin_gen,
		"gen_delta_c": gen_delta_c,
		"disk_delta_c": disk_delta_c,
		"phaseA": {"gen": gen_a, "disk": disk_a},
		"r50": {"disk": d50_disk, "gen": d50_gen},
		"disk_reads_total": world.disk_reads,
		"disk_read_ms": world.disk_read_ms,
		"gen_count_total": world.gen_count,
		"io": {
			"enq": world._io_enq,
			"dedup": world._io_dedup,
			"wdedup": world._io_wdedup,
			"writes": world._io_write_n,
			"drops": world._io_drops,
			"fails": world._io_fails,
			"main_read_ms": world._io_main_read_ms,
			"main_write_ms": world._io_main_write_ms,
		},
	})
	get_tree().quit()


# AC-0165 probe (AWECRAFT_LOGIC=chunkiocpp, harness-only, never runs in
# game): the C++ (GDExtension) v4 paletted codec must be byte-identical to
# the GDScript v4 codec (encode section, flat decode, slab decode) on
# synthetic edge-case columns + real r=4 columns; reports the decode speed
# C++ vs GDScript (the AC-0203 slow recenter path).
# AC-0208: the NO-FALLBACK gate. The game now REQUIRES the C++ extension —
# there is no GDScript fallback for mesh / gen / light / strips / slab IO.
# This arm boots a real world, lets the C++ lanes do real work (r4 mesh
# build + gen), and proves (a) EVERY C++ usage counter advanced (the C++
# series ran the whole world) and (b) every GDScript-reference sentinel
# stayed ZERO (the game never touched the probe-only kernels). Light lane:
# a plain boot lights entirely inside the C++ mesh workers (self-light —
# the GDScript pull dispatch has no normal-boot callers), so the positive
# proof is a torch glow source whose C++-landed eff (last_eff) must light
# (torch_light > 5), plus the gd_pull_calls sentinel staying 0. Plus a
# direct C++ slab-IO roundtrip: a real column encoded (the GDScript
# encoder stays) and decoded through the runtime path (decode_column ->
# C++ decode_slabs) must land byte-identical and advance the C++ decode
# counter.
func _nofallback_test(spawn: Vector3) -> void:
	var t0 := Time.get_ticks_msec()
	var m0_mesh := int(world.mesh_cpp_builds)
	var m0_gen := int(world.gen_cpp_works)
	var m0_strips := int(world.strips_cpp_calls)
	var m0_light := int(Lighting.cpp_pull_calls)
	var m0_io := int(ChunkIO.cpp_slab_decodes)
	var res := {
		"ok": false,
		"m0_mesh": m0_mesh,
		"m0_gen": m0_gen,
		"m0_strips": m0_strips,
		"m0_light": m0_light,
		"m0_io": m0_io,
		"mesh_cpp_builds": 0,
		"gen_cpp_works": 0,
		"strips_cpp_calls": 0,
		"light_cpp_pull_calls": 0,
		"chunkio_cpp_slab_decodes": 0,
		"gd_strips_calls": 0,
		"gd_light_pull_calls": 0,
		"mesh_chunks": 0,
		"torch_placed": false,
		"torch_light": 0,
		"roundtrip_ok": false,
		"wall_ms": 0,
	}
	world.fluid_sim_enabled = false
	world.collision_enabled = false
	world.render_radius = 4
	world.recenter(spawn.x, spawn.z, true)
	var waited := 0
	var built := 0
	while built < 16 and waited < 3600:
		built = 0
		for key in world.chunks:
			var c = world.chunks.get(key)
			if c != null and not c.data.is_empty() and c.mesh_built:
				built += 1
		if built >= 16:
			break
		await get_tree().physics_frame
		waited += 1
	res["mesh_chunks"] = built
	# Force a glow-source light wave: place a torch (id 22, glow) on a
	# surface air cell. A plain boot lights entirely inside the C++ mesh
	# workers (self-light — the GDScript pull dispatch has no normal-boot
	# callers), so a glow source + light_at read is the positive proof the
	# C++ light lane works end-to-end; the gd_pull_calls sentinel (below)
	# is the no-fallback proof that the GDScript pull kernel stayed dead.
	var torch_placed := false
	var torch_pos := Vector3i(0, 0, 0)
	for key in world.chunks:
		var c = world.chunks.get(key)
		if c == null or c.data.is_empty() or not c.mesh_built:
			continue
		var wx := int(c.cx) * 16 + 8
		var wz := int(c.cz) * 16 + 8
		var gy := int(c.top) + 1
		if world.get_block(wx, gy, wz) == 0:
			world.set_block(wx, gy, wz, 22)
			torch_placed = true
			torch_pos = Vector3i(wx, gy, wz)
			break
	res["torch_placed"] = torch_placed
	# Let the light wave settle (the worker remeshes the lit chunks).
	var lp_waited := 0
	while not world.light_pending.is_empty() and lp_waited < 1200:
		await get_tree().physics_frame
		lp_waited += 1
	await get_tree().physics_frame
	await get_tree().physics_frame
	var torch_light := 0
	if torch_placed:
		# Read the eff the C++ workers LANDED in the torch's chunk (the
		# worker's self-light result — last_eff is the settled per-chunk
		# eff store, indexed (y<<8)|(lz<<4)|lx local to the chunk).
		var cchk = world.chunks.get(world._key(torch_pos.x / 16, torch_pos.z / 16))
		if cchk != null and not cchk.last_eff.is_empty():
			var lx := torch_pos.x - int(cchk.cx) * 16
			var lz := torch_pos.z - int(cchk.cz) * 16
			torch_light = int((cchk.last_eff["arr"] as PackedByteArray)[(torch_pos.y << 8) | (lz << 4) | lx])
	res["torch_light"] = torch_light
	# Direct C++ slab-IO roundtrip on one real column.
	var rt_ok := false
	for key in world.chunks:
		var c = world.chunks.get(key)
		if c == null or c.data.is_empty():
			continue
		var d: PackedByteArray = ChunkIO._slabs_flat(c.data)
		var f: PackedByteArray = ChunkIO._slabs_flat(c.fl)
		var before := int(ChunkIO.cpp_slab_decodes)
		var rt: Dictionary = ChunkIO.decode_column(ChunkIO.encode_column(d, f, 0, Data.HEIGHT), 0, Data.HEIGHT)
		rt_ok = not rt.is_empty() and (rt.get("data", PackedByteArray()) as PackedByteArray) == d and (rt.get("fl", PackedByteArray()) as PackedByteArray) == f and int(ChunkIO.cpp_slab_decodes) > before
		break
	res["roundtrip_ok"] = rt_ok
	res["mesh_cpp_builds"] = int(world.mesh_cpp_builds) - m0_mesh
	res["gen_cpp_works"] = int(world.gen_cpp_works) - m0_gen
	res["strips_cpp_calls"] = int(world.strips_cpp_calls) - m0_strips
	res["light_cpp_pull_calls"] = int(Lighting.cpp_pull_calls) - m0_light
	res["chunkio_cpp_slab_decodes"] = int(ChunkIO.cpp_slab_decodes) - m0_io
	res["gd_strips_calls"] = int(world.gd_strips_calls)
	res["gd_light_pull_calls"] = int(Lighting.gd_pull_calls)
	res["ok"] = res["mesh_cpp_builds"] > 0 and res["gen_cpp_works"] > 0 and res["strips_cpp_calls"] > 0 and res["chunkio_cpp_slab_decodes"] > 0 and res["gd_strips_calls"] == 0 and res["gd_light_pull_calls"] == 0 and res["mesh_chunks"] >= 16 and torch_placed and torch_light > 5 and rt_ok
	res["wall_ms"] = Time.get_ticks_msec() - t0
	Debug.result(res)
	get_tree().quit()


func _chunkiocpp_test(spawn: Vector3) -> void:
	var res := {
		"ok": false,
		"cpp_registered": ClassDB.class_exists("ChunkIOPalette"),
		"cols": 0,
		"real_cols": 0,
		"enc_pairs": 0,
		"enc_match": 0,
		"flat_pairs": 0,
		"flat_match": 0,
		"slab_match": 0,
		"roundtrip_ok": 0,
		"flat_gd_ms": 0.0,
		"flat_cpp_ms": 0.0,
		"slab_gd_ms": 0.0,
		"slab_cpp_ms": 0.0,
		"flat_speedup": 0.0,
		"slab_speedup": 0.0,
		"speedup_ok": false,
		"enc_bytes_avg": 0,
		"md5_orig": "",
		"md5_cpp": "",
	}
	if not res["cpp_registered"]:
		Debug.result(res)
		get_tree().quit()
		return
	var C = ClassDB.instantiate("ChunkIOPalette")
	if C == null:
		Debug.result(res)
		get_tree().quit()
		return
	var sub := int(Data.HEIGHT) / ChunkIO.S
	var samples := []
	samples.append(_ci_col_uniform(sub))
	samples.append(_ci_col_sparse(sub))
	samples.append(_ci_col_rainbow(sub))
	samples.append(_ci_col_raw(sub))
	samples.append(_ci_col_fluid(sub))
	world.fluid_sim_enabled = false
	world.render_radius = 4
	world.recenter(spawn.x, spawn.z, true)
	var waited := 0
	var built := 0
	while built < 12 and waited < 1200:
		await get_tree().physics_frame
		waited += 1
		built = 0
		for key in world.chunks.keys():
			var c = world.chunks.get(key)
			if c != null and not c.data.is_empty():
				built += 1
	var real := 0
	for key in world.chunks.keys():
		var c = world.chunks.get(key)
		if c == null or c.data.is_empty():
			continue
		samples.append({
			"data": ChunkIO._slabs_flat(c.data),
			"fl": ChunkIO._slabs_flat(c.fl),
			"top": int(c.top),
		})
		real += 1
		if real >= 12:
			break
	res["real_cols"] = real
	res["cols"] = samples.size()
	var iters := 40
	var enc_pairs := 0
	var enc_match := 0
	var flat_pairs := 0
	var flat_match := 0
	var slab_match := 0
	var roundtrip_ok := 0
	var gd_flat_ms := 0.0
	var cpp_flat_ms := 0.0
	var gd_slab_ms := 0.0
	var cpp_slab_ms := 0.0
	var enc_bytes := 0
	var md5_ref := ""
	for smp in samples:
		var d: PackedByteArray = smp["data"]
		var f: PackedByteArray = smp["fl"]
		var top: int = smp["top"]
		var enc_d_gd := ChunkIO._encode_array_v4(d, sub, top)
		var enc_d_cpp: PackedByteArray = C.encode_section(d, sub, top)
		enc_pairs += 1
		if enc_d_gd == enc_d_cpp:
			enc_match += 1
		var enc_f_gd := ChunkIO._encode_array_v4(f, sub, top)
		var enc_f_cpp: PackedByteArray = C.encode_section(f, sub, top)
		enc_pairs += 1
		if enc_f_gd == enc_f_cpp:
			enc_match += 1
		enc_bytes += enc_d_gd.size() + enc_f_gd.size()
		var dec_gd = ChunkIO._decode_array_v4(enc_d_gd, 0, sub)
		var dec_cpp = C.decode_section(enc_d_gd, 0, sub)
		var fdec_gd = ChunkIO._decode_array_v4(enc_f_gd, 0, sub)
		var fdec_cpp = C.decode_section(enc_f_gd, 0, sub)
		# AC-0208: the GDScript _decode_slabs_v4 was REMOVED — the slab check
		# is the C++ decode_slabs vs the RUNTIME decode_column handoff (the
		# v4 path lands the slab array through C++ inside decode_column) —
		# the C++ counter must advance to prove the runtime is C++-backed.
		var sl_cpp = C.decode_slabs(enc_d_gd, 0, sub)
		var col_full: PackedByteArray = ChunkIO.encode_column(d, f, 0, Data.HEIGHT)
		var dec_before := ChunkIO.cpp_slab_decodes
		var rt: Dictionary = ChunkIO.decode_column(col_full, 0, Data.HEIGHT)
		var rt_slabs: Array = rt.get("d_slabs", [])
		var ok_d: bool = int(dec_gd["off"]) > 0 and dec_gd["arr"] == d and (dec_cpp["arr"] as PackedByteArray) == d and (dec_cpp["arr"] as PackedByteArray) == dec_gd["arr"] and int(dec_cpp["off"]) == int(dec_gd["off"])
		var ok_f: bool = int(fdec_gd["off"]) > 0 and fdec_gd["arr"] == f and (fdec_cpp["arr"] as PackedByteArray) == f and (fdec_cpp["arr"] as PackedByteArray) == fdec_gd["arr"] and int(fdec_cpp["off"]) == int(fdec_gd["off"])
		var ok_s := int(sl_cpp["off"]) > 0 and not rt.is_empty() and (rt.get("data", PackedByteArray()) as PackedByteArray) == d and _ci_slabs_equal(rt_slabs, sl_cpp["slabs"]) and ChunkIO._slabs_flat(sl_cpp["slabs"]) == d and ChunkIO.cpp_slab_decodes > dec_before
		flat_pairs += 2
		if ok_d:
			flat_match += 1
		if ok_f:
			flat_match += 1
		if ok_s:
			slab_match += 1
		if ok_d and ok_f and ok_s:
			roundtrip_ok += 1
		if md5_ref == "":
			md5_ref = _ci_md5(d)
			res["md5_cpp"] = _ci_md5(dec_cpp["arr"])
		var t1 := Time.get_ticks_usec()
		for k in iters:
			ChunkIO._decode_array_v4(enc_d_gd, 0, sub)
		gd_flat_ms += float(Time.get_ticks_usec() - t1) / 1000.0 / float(iters)
		t1 = Time.get_ticks_usec()
		for k in iters:
			C.decode_section(enc_d_gd, 0, sub)
		cpp_flat_ms += float(Time.get_ticks_usec() - t1) / 1000.0 / float(iters)
		# AC-0208: no GDScript slab decode left to time — slab_gd_ms times
		# the runtime decode_column (the C++-backed slab handoff), so
		# slab_speedup is informational only (same C++ under both sides;
		# the ratio is ~1 + handoff overhead).
		t1 = Time.get_ticks_usec()
		for k in iters:
			ChunkIO.decode_column(col_full, 0, Data.HEIGHT)
		gd_slab_ms += float(Time.get_ticks_usec() - t1) / 1000.0 / float(iters)
		t1 = Time.get_ticks_usec()
		for k in iters:
			C.decode_slabs(enc_d_gd, 0, sub)
		cpp_slab_ms += float(Time.get_ticks_usec() - t1) / 1000.0 / float(iters)
	var n := float(samples.size())
	res["enc_pairs"] = enc_pairs
	res["enc_match"] = enc_match
	res["flat_pairs"] = flat_pairs
	res["flat_match"] = flat_match
	res["slab_match"] = slab_match
	res["roundtrip_ok"] = roundtrip_ok
	res["flat_gd_ms"] = gd_flat_ms / n
	res["flat_cpp_ms"] = cpp_flat_ms / n
	res["slab_gd_ms"] = gd_slab_ms / n
	res["slab_cpp_ms"] = cpp_slab_ms / n
	res["flat_speedup"] = gd_flat_ms / cpp_flat_ms if cpp_flat_ms > 0.0 else 0.0
	res["slab_speedup"] = gd_slab_ms / cpp_slab_ms if cpp_slab_ms > 0.0 else 0.0
	res["speedup_ok"] = res["flat_speedup"] >= 5.0
	res["enc_bytes_avg"] = int(enc_bytes / n)
	res["md5_orig"] = md5_ref
	res["ok"] = enc_match == enc_pairs and flat_match == flat_pairs and slab_match == samples.size() and roundtrip_ok == samples.size()
	Debug.result(res)
	get_tree().quit()


func _ci_md5(b: PackedByteArray) -> String:
	var hc := HashingContext.new()
	hc.start(HashingContext.HASH_MD5)
	hc.update(b)
	var h: PackedByteArray = hc.finish()
	var s := ""
	for byte in h:
		s += "%02x" % int(byte)
	return s


func _ci_slabs_equal(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		var sa = a[i]
		var sb = b[i]
		if sa == null and sb == null:
			continue
		if sa == null or sb == null:
			return false
		if int(sa["n"]) != int(sb["n"]):
			return false
		if int(sa["b"]) != int(sb["b"]):
			return false
		if int(sa["nz"]) != int(sb["nz"]):
			return false
		if (sa["p"] as PackedByteArray) != (sb["p"] as PackedByteArray):
			return false
		if (sa["i"] as PackedByteArray) != (sb["i"] as PackedByteArray):
			return false
	return true


# AC-0188 probe (AWECRAFT_LOGIC=genprobe, harness-only): the C++ AweNoise
# port (gdext/src/gen.cpp) must be bit-for-byte identical to the GDScript
# AweNoise — the #1 invariant of the native gen. Compares hash2i/hash3i,
# fade, vnoise2/vnoise3, fbm2/fbm3 at deterministic random points (seeded
# RNG — reproducible), plus the cave-density wiring (density_cave must equal
# AweNoise.fbm3 at the exact coarse-field coords/salt). Exact = f64 equality.
func _genprobe_test() -> void:
	var res := {
		"ok": false,
		"cpp_registered": ClassDB.class_exists("AweGen"),
		"n": 0,
		"exact": 0,
		"max_diff": 0.0,
		"fbm2": {"n": 0, "exact": 0},
		"fbm3": {"n": 0, "exact": 0},
		"vnoise2": {"n": 0, "exact": 0},
		"vnoise3": {"n": 0, "exact": 0},
		"hash2i": {"n": 0, "exact": 0},
		"hash3i": {"n": 0, "exact": 0},
		"fade": {"n": 0, "exact": 0},
		"cave": {"n": 0, "exact": 0},
	}
	if not res["cpp_registered"]:
		Debug.result(res)
		get_tree().quit()
		return
	var G = ClassDB.instantiate("AweGen")
	if G == null:
		Debug.result(res)
		get_tree().quit()
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 44
	# NB: counters live in `res` — lambda captures are by value, so the
	# lambda can only mutate things it holds by reference (the dict).
	var cmp := func(k: String, a: float, b: float) -> void:
		res["n"] = int(res["n"]) + 1
		res[k]["n"] = int(res[k]["n"]) + 1
		if a == b:
			res["exact"] = int(res["exact"]) + 1
			res[k]["exact"] = int(res[k]["exact"]) + 1
		else:
			var dd := absf(a - b)
			if dd > float(res["max_diff"]):
				res["max_diff"] = dd
	for i in 1200:
		var x := rng.randf_range(-1024.0, 1024.0)
		var z := rng.randf_range(-1024.0, 1024.0)
		var s := rng.randi_range(-200, 200)
		var oct := 2 + rng.randi_range(0, 2)
		cmp.call("fbm2", AweNoise.fbm2(x, z, s, oct), G.fbm2(x, z, s, oct))
	for i in 1200:
		var x := rng.randf_range(-1024.0, 1024.0)
		var y := rng.randf_range(-1024.0, 1024.0)
		var z := rng.randf_range(-1024.0, 1024.0)
		var s := rng.randi_range(-200, 200)
		var oct := 1 + rng.randi_range(0, 2)
		cmp.call("fbm3", AweNoise.fbm3(x, y, z, s, oct), G.fbm3(x, y, z, s, oct))
	for i in 600:
		var x := rng.randf_range(-2048.0, 2048.0)
		var z := rng.randf_range(-2048.0, 2048.0)
		var s := rng.randi_range(-200, 200)
		cmp.call("vnoise2", AweNoise.vnoise2(x, z, s), G.vnoise2(x, z, s))
	for i in 600:
		var x := rng.randf_range(-2048.0, 2048.0)
		var y := rng.randf_range(-2048.0, 2048.0)
		var z := rng.randf_range(-2048.0, 2048.0)
		var s := rng.randi_range(-200, 200)
		cmp.call("vnoise3", AweNoise.vnoise3(x, y, z, s), G.vnoise3(x, y, z, s))
	for i in 400:
		var x := rng.randi_range(-4096, 4096)
		var z := rng.randi_range(-4096, 4096)
		var s := rng.randi_range(-4096, 4096)
		cmp.call("hash2i", AweNoise.hash2i(x, z, s), G.hash2i(x, z, s))
	for i in 400:
		var x := rng.randi_range(-4096, 4096)
		var y := rng.randi_range(-4096, 4096)
		var z := rng.randi_range(-4096, 4096)
		var s := rng.randi_range(-4096, 4096)
		cmp.call("hash3i", AweNoise.hash3i(x, y, z, s), G.hash3i(x, y, z, s))
	for i in 200:
		var t := rng.randf_range(-2.0, 2.0)
		cmp.call("fade", AweNoise._fade(t), G.fade(t))
	for i in 300:
		# The cave-density wiring: exact coarse-field source function.
		var x := rng.randf_range(-1024.0, 1024.0)
		var y := rng.randf_range(0.0, 384.0)
		var z := rng.randf_range(-1024.0, 1024.0)
		var s := rng.randi_range(-200, 200)
		cmp.call("cave", AweNoise.fbm3(x / 16.0, y / 10.0, z / 16.0, s + 301, 2), G.density_cave(x, y, z, s))
	var tot := int(res["n"])
	res["match_rate"] = float(int(res["exact"])) / float(tot) if tot > 0 else 0.0
	res["ok"] = int(res["exact"]) == tot and tot > 0
	Debug.result(res)
	get_tree().quit()


func _ci_zeros(sub: int) -> PackedByteArray:
	var z := PackedByteArray()
	z.resize(sub * ChunkIO.S3)
	return z


func _ci_col_uniform(sub: int) -> Dictionary:
	var d := PackedByteArray()
	d.resize(sub * ChunkIO.S3)
	var i := 0
	while i < 14 * ChunkIO.S3:
		d[i] = 9
		i += 1
	return {"data": d, "fl": _ci_zeros(sub), "top": -1}


func _ci_col_sparse(sub: int) -> Dictionary:
	var d := PackedByteArray()
	d.resize(sub * ChunkIO.S3)
	d[0] = 11
	d[1] = 9
	d[100] = 11
	d[4095] = 9
	d[4096 + 10] = 7
	return {"data": d, "fl": _ci_zeros(sub), "top": 30}


func _ci_col_rainbow(sub: int) -> Dictionary:
	var d := PackedByteArray()
	d.resize(sub * ChunkIO.S3)
	var i := 0
	while i < sub * ChunkIO.S3:
		var x := i % 16
		var z := (i / 16) % 16
		var y := (i / 256) % 16
		d[i] = ((x + z + y * 7) % 15) + 1
		i += 1
	return {"data": d, "fl": _ci_zeros(sub), "top": -1}


func _ci_col_raw(sub: int) -> Dictionary:
	var d := PackedByteArray()
	d.resize(sub * ChunkIO.S3)
	var i := 0
	while i < sub * ChunkIO.S3:
		var x := i % 16
		var z := (i / 16) % 16
		var y := (i / 256) % 16
		d[i] = ((x * 13 + z * 7 + y * 3) % 20) + 1
		i += 1
	return {"data": d, "fl": _ci_zeros(sub), "top": -1}


func _ci_col_fluid(sub: int) -> Dictionary:
	var f := PackedByteArray()
	f.resize(sub * ChunkIO.S3)
	var i := 0
	while i < 4 * ChunkIO.S3:
		f[i] = 5
		if i % 64 == 0:
			f[i] = 8
		elif i % 64 == 1:
			f[i] = 7
		i += 1
	return {"data": _ci_zeros(sub), "fl": f, "top": -1}


func _lightcache_cache_fresh(key: String, max_frames: int) -> bool:
	var waited := 0
	while waited < max_frames:
		await get_tree().physics_frame
		waited += 1
		var c = world.chunks.get(key)
		if c == null or c.data.is_empty():
			continue
		if world.light_pending_set.has(key) or world.light_dirty.has(key) or world.edit_front_set.has(key):
			continue
		var cached = world._eff_cache.get(key)
		if cached == null or int(c.data_gen) != int(cached.stamp[0]) or int(c.fl_gen) != int(cached.stamp[1]):
			continue
		if (cached.eff as Dictionary).get("mask", null) == null:
			continue
		return true
	return false

func _lightcache_revisit(key: String) -> Node3D:
	var c: Node3D = world.chunks.get(key)
	if c != null:
		world.chunks.erase(key)
		c.queue_free()
	world._eff_cache_evict(key)
	await get_tree().physics_frame
	var nc = world.create_chunk(0, 0, false)
	world._enqueue_build(0, 0)
	var waited := 0
	while waited < 1200:
		if nc != null and bool(nc.mesh_built):
			break
		await get_tree().physics_frame
		waited += 1
	return nc

func _lightcache_test(spawn: Vector3) -> void:
	var t0 := Time.get_ticks_msec()
	var SLOT := 0
	Save.active_slot = SLOT
	ChunkIO.clear_dir(SLOT)
	world.fluid_sim_enabled = false
	world.collision_enabled = false
	world.render_radius = 2
	world.recenter(spawn.x, spawn.z, true)
	await _await_core_3x3(spawn, 3000)
	var key := "0,0"
	var c0: Node3D = world.chunks.get(key)
	var top: int = world.surface_top(8, 8)
	for i in range(5):
		world.set_block(8, top - i, 8, 0)
	world.set_block(8, top - 5, 8, 22)
	var fresh0 := await _lightcache_cache_fresh(key, 2400)
	c0 = world.chunks.get(key)
	var full0: Dictionary = world._eff_cache.get(key, {}).get("eff", {})
	var saved_arr: PackedByteArray = PackedByteArray(c0.last_eff.get("arr", PackedByteArray()))
	var saved_mask: PackedByteArray = PackedByteArray(full0.get("mask", PackedByteArray()))
	var blk_src0 := bool(full0.get("blk_src", false))
	var torch_l: Dictionary = world.light_at(8, top - 5, 8)
	var mask_sum := 0
	for m in saved_mask:
		mask_sum += int(m)
	var light_saved_nonzero := mask_sum > 0 and int(torch_l.get("block", 0)) >= 13
	world._queue_chunk_save(c0)
	world._drain_save_queue()
	var iw := 0
	while iw < 900 and not world._io_write_inflight.is_empty():
		await get_tree().physics_frame
		iw += 1
	var path := ChunkIO.path_for(SLOT, 0, 0, 0)
	var file_ok := FileAccess.file_exists(path)
	var disk_light_ok := false
	var disk_mask_ok := false
	if file_ok:
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			var bytes := f.get_buffer(f.get_length())
			f.close()
			var dec = ChunkIO.decode_column(bytes, int(Game.world_seed), int(Data.HEIGHT))
			if typeof(dec) == TYPE_DICTIONARY and not (dec as Dictionary).is_empty():
				var dl: Dictionary = (dec as Dictionary).get("light", {})
				disk_light_ok = PackedByteArray(dl.get("arr", PackedByteArray())) == saved_arr and bool(dl.get("blk_src", false)) == blk_src0
				disk_mask_ok = PackedByteArray(dl.get("mask", PackedByteArray())) == saved_mask
	var n1 = await _lightcache_revisit(key)
	await _lightcache_cache_fresh(key, 900)
	var built1 := n1 != null and bool(n1.mesh_built)
	var recompute_count := int(n1.light_recomputes) if built1 else -1
	var restored_arr := PackedByteArray(n1.last_eff.get("arr", PackedByteArray())) if built1 else PackedByteArray()
	var restored_full: Dictionary = world._eff_cache.get(key, {}).get("eff", {})
	var restored_mask := PackedByteArray(restored_full.get("mask", PackedByteArray()))
	var last1_empty := bool(n1 == null or (n1.last_eff as Dictionary).is_empty())
	var restored_no_recompute := built1 and recompute_count == 0 and not last1_empty
	var restored_matches_saved := restored_arr == saved_arr and restored_mask == saved_mask and disk_light_ok and disk_mask_ok
	var legacy_v1_recomputes := false
	if built1:
		var leg := ChunkIO.encode_column_legacy(n1.flat_data(), n1.flat_fl(), int(Game.world_seed), int(Data.HEIGHT))
		var f2 = FileAccess.open(path, FileAccess.WRITE)
		if f2 != null:
			f2.store_buffer(leg)
			f2.close()
		var n2 = await _lightcache_revisit(key)
		legacy_v1_recomputes = n2 != null and bool(n2.mesh_built) and int(n2.light_recomputes) >= 1 and bool(not (n2.last_eff as Dictionary).is_empty())
	Save.clear(SLOT)
	var wiped := not FileAccess.file_exists(path)
	var n3 = await _lightcache_revisit(key)
	var clear_wipes_light := wiped and n3 != null and bool(n3.mesh_built) and int(n3.light_recomputes) >= 1 and bool(not (n3.last_eff as Dictionary).is_empty())
	var wall := Time.get_ticks_msec() - t0
	var ok := built1 and fresh0 and file_ok and disk_light_ok and disk_mask_ok and light_saved_nonzero and restored_no_recompute and recompute_count == 0 and restored_matches_saved and legacy_v1_recomputes and clear_wipes_light and wall <= 90000
	Debug.result({
		"ok": ok,
		"wall_ms": wall,
		"light_saved_nonzero": light_saved_nonzero,
		"restored_no_recompute": restored_no_recompute,
		"recompute_count": recompute_count,
		"restored_matches_saved": restored_matches_saved,
		"legacy_v1_recomputes": legacy_v1_recomputes,
		"clear_wipes_light": clear_wipes_light,
		"disk_light_ok": disk_light_ok,
		"disk_mask_ok": disk_mask_ok,
		"file_ok": file_ok,
		"cache_fresh": fresh0,
		"mask_sum": mask_sum,
		"torch_block": int(torch_l.get("block", 0)),
		"saved_restores": world.light_saved_restores,
	})
	get_tree().quit()




# AC-0158 probe (AWECRAFT_LOGIC=tick): the 20 Hz game tick on the band-0
# diamond, in one process. The tick clock starts only once the 41-set is
# resident and tick_index resets to 0 at that point, so ticks 1..W are a
# pure function of (seed, tick index, full 41-set): the window md5 is
# byte-identical across fresh runs (determinism gate). Headless <= 60 s.
func _tick_md5(arr: PackedByteArray) -> String:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_MD5)
	h.update(arr)
	var md: PackedByteArray = h.finish()
	var hx := ""
	for i in range(16):
		hx += "%02x" % md[i]
	return hx

func _load_test(spawn: Vector3) -> void:
	# AC-0178: first-load wall probe at R=50. t0 = the recenter that starts
	# streaming; done = render circle fully meshed + both worker pools drained.
	# AWECRAFT_LOADBYPASS=0 runs the SAME arm under the legacy spread drain
	# (start_loading no-ops) — the A/B baseline. Counts are the real
	# provenance counters (disk_reads / gen_count / mesh_built).
	var lb := OS.get_environment("AWECRAFT_LOADBYPASS") != "0"
	world.collision_enabled = false
	world.fluid_sim_enabled = false
	world.render_radius = 50
	world.recenter(spawn.x, spawn.z, true)
	if lb:
		world.start_loading("AC-0178 load probe")
	var target: int = world.circle_count()
	var t0 := Time.get_ticks_msec()
	var spawn3x3_ms := -1
	var screen_hidden_ms := -1
	var screen_up := false
	while true:
		await get_tree().process_frame
		if spawn3x3_ms < 0 and not world._startup_pending():
			spawn3x3_ms = Time.get_ticks_msec() - t0
		if lb and world.loading_active and not screen_up:
			screen_up = bool(world._loading_screen.visible)
		if lb and not world.loading_active and screen_hidden_ms < 0:
			screen_hidden_ms = Time.get_ticks_msec() - t0
		# Completion = the _loading_tick predicate itself: circle fully meshed
		# AND both worker pools drained (stop_loading has run, screen hidden).
		if world.meshed_in_circle() >= target and world.threadmesh_inflight.is_empty() and world.threadgen_inflight.is_empty():
			break
		# AC-0178: 60-min in-arm cap — the bypass arm finishes the circle in
		# ~25-30 min (the screen hides once the pools drain); the spread
		# baseline (AWECRAFT_LOADBYPASS=0) needs ~50 min, so 60 covers both.
		if Time.get_ticks_msec() - t0 > 3600000:
			break
	var wall := Time.get_ticks_msec() - t0
	var meshed: int = world.meshed_in_circle()
	Debug.result({
		"ok": meshed >= target,
		"bypass": lb,
		"wall_ms": wall,
		"gen_per_s": roundf(1000.0 * world.gen_count / maxi(wall, 1)),
		"mesh_per_s": roundf(1000.0 * float(meshed) / maxi(wall, 1)),
		"cols": target,
		"meshed": meshed,
		"disk": world.disk_reads,
		"gen": world.gen_count,
		"spawn3x3_ms": spawn3x3_ms,
		"screen_hidden_ms": screen_hidden_ms,
		"queue_final": world.queue_size,
		"tg_inflight": world.threadgen_inflight.size(),
		"tm_inflight": world.threadmesh_inflight.size(),
		"loading_active_final": world.loading_active,
		"screen_up": screen_up,
		"screen_visible_final": bool(world._loading_screen.visible),
	})
	get_tree().quit()

func _tick_test(spawn: Vector3) -> void:
	var t0 := Time.get_ticks_msec()
	var W := 120
	world.collision_enabled = false
	world.fluid_sim_enabled = false
	world.game_tick_enabled = false
	world.render_radius = 4
	world.recenter(spawn.x, spawn.z, true)
	var diamond := []
	for dx in range(-4, 5):
		for dz in range(-4, 5):
			if absi(dx) + absi(dz) <= 4:
				diamond.append([dx, dz])
	var t_ready0 := Time.get_ticks_msec()
	var ready_waited := 0
	var n_ready := 0
	while ready_waited < 1800:
		n_ready = 0
		for dc in diamond:
			var c = world.chunks.get("%d,%d" % [dc[0], dc[1]])
			if c != null and not c.data.is_empty():
				n_ready += 1
		if n_ready == diamond.size():
			break
		await get_tree().physics_frame
		ready_waited += 1
	var set_ready := n_ready == diamond.size()
	# Settle: the hz measurement needs a QUIET world — with trickle builds
	# in flight, frames stretch past the TICK_MAX_CATCHUP window and the
	# accumulator drops ticks (measured 9 Hz vs 20 Hz at rest). Settle =
	# the full 41-set meshed AND the stream queue size stable for 90 frames
	# (40 unbuildable outer-ring entries linger in the queue forever, so
	# queue_size == 0 is NOT the criterion).
	var t_settle0 := Time.get_ticks_msec()
	var q_waited := 0
	var q_prev := -1
	var q_stable := 0
	var all_b0_meshed := false
	while q_waited < 1800:
		var qn: int = world.queue_size
		if qn == q_prev:
			q_stable += 1
		else:
			q_stable = 0
			q_prev = qn
		all_b0_meshed = true
		for dc in diamond:
			var c2 = world.chunks.get("%d,%d" % [dc[0], dc[1]])
			if c2 == null or not c2.mesh_built:
				all_b0_meshed = false
				break
		if q_stable >= 90 and all_b0_meshed:
			break
		if q_waited % 60 == 0:
			print("SETTLE f=%d q=%d stable=%d b0m=%s" % [q_waited, qn, q_stable, str(all_b0_meshed)])
		await get_tree().physics_frame
		q_waited += 1
	var queue_settled: bool = q_stable >= 90 and all_b0_meshed
	# Fresh tick epoch: the measurement window is ticks 1..W over the full
	# 41-set (fluid sim on, so the fluid pass rides the same clock).
	world.tick_index = 0
	world._tick_acc = 0.0
	world.random_tick_total = 0
	world.random_tick_map.clear()
	world.random_tick_seq.clear()
	world.game_tick_samples.clear()
	world.fluid_tick_samples.clear()
	world.fluid_tick_count = 0
	world.random_tick_log = true
	world.fluid_sim_enabled = true
	world.game_tick_enabled = true
	var t_win_start := Time.get_ticks_msec()
	var frame_wall0 := Time.get_ticks_msec()
	var frame_times: Array = []
	var frame_big := 0
	var half_wall := -1
	while world.tick_index < W:
		await get_tree().physics_frame
		var fd: int = Time.get_ticks_msec() - frame_wall0
		frame_wall0 = Time.get_ticks_msec()
		frame_times.append(fd)
		if fd > 100:
			frame_big += 1
		if half_wall < 0 and world.tick_index >= W / 2:
			half_wall = Time.get_ticks_msec()
	var t_win_end := Time.get_ticks_msec()
	var wall_ms := t_win_end - t_win_start
	frame_times.sort()
	var frame_p95: float = float(frame_times[mini(frame_times.size() - 1, int(0.95 * float(frame_times.size())))]) if not frame_times.is_empty() else -1.0
	var frame_max: int = int(frame_times.max()) if not frame_times.is_empty() else -1
	var t_analyze0 := Time.get_ticks_msec()
	var n_ticks: int = world.tick_index
	var hz := float(W) / (float(wall_ms) / 1000.0)
	# hz2 = the LAST-HALF rate: a few >0.2 s frames (worker handoff spikes)
	# drop catch-up ticks via TICK_MAX_CATCHUP and drag the full-window rate;
	# the steady-state clock rate is the half-window rate.
	var hz2 := float(W - W / 2) / (float(t_win_end - half_wall) / 1000.0) if half_wall > 0 else -1.0
	var fluid_hz := float(world.fluid_tick_count) / (float(wall_ms) / 1000.0)
	# Truncate the log to the first W ticks (the accumulator may overshoot
	# by up to TICK_MAX_CATCHUP on the final frame).
	if world.random_tick_seq.size() > W:
		world.random_tick_seq.resize(W)
	# (b) scope: every ticking subchunk belongs to a band-0 diamond column;
	# band 1-3 tick count must be exactly 0.
	var scope_bad := 0
	var band123_ticks := 0
	var cols_seen := {}
	var expected_subs: int = 41 * world.SUBCHUNKS_PER_COLUMN
	for sk in world.random_tick_map:
		var k: int = sk
		var col_base: int = k / 24
		var cz := int(col_base) % 16384 - 4096
		var cx := (int(col_base) - (cz + 4096)) / 16384 - 4096
		cols_seen["%d,%d" % [cx, cz]] = true
		var c = world.chunks.get("%d,%d" % [cx, cz])
		var b := int(c.band) if c != null else -1
		if b != 0 or (absi(cx - world.last_pcx) + absi(cz - world.last_pcz)) > 4:
			scope_bad += 1
		if b != 0:
			band123_ticks += 1
	# (c) distribution from the log: every subchunk gets exactly W ticks.
	var counts := {}
	var local_cnt := {}
	var recompute_mismatch := 0
	var cells_compared := 0
	var seq_bytes: PackedByteArray = PackedByteArray()
	var md5_first := ""
	var md5_last := ""
	var colhash_cache := {}
	for i in world.random_tick_seq.size():
		var seq: PackedInt32Array = world.random_tick_seq[i]
		var t: int = i + 1
		var bb := seq.to_byte_array()
		if i == 0:
			md5_first = _tick_md5(bb)
		if i == world.random_tick_seq.size() - 1:
			md5_last = _tick_md5(bb)
		seq_bytes.append_array(bb)
		var j := 0
		while j < seq.size():
			var base: int = int(seq[j])
			var sub: int = int(seq[j + 1])
			var lx: int = int(seq[j + 2])
			var ly: int = int(seq[j + 3])
			var lz: int = int(seq[j + 4])
			var cz := base % 16384 - 4096
			var cx := (base - (cz + 4096)) / 16384 - 4096
			var sk: int = base * 24 + sub
			counts[sk] = int(counts.get(sk, 0)) + 1
			var lc: int = (ly << 8) | (lx << 4) | lz
			local_cnt[lc] = int(local_cnt.get(lc, 0)) + 1
			# (d) recompute: the logged cell must equal the spec function.
			var hck: int = (t << 30) + base
			var hcol: int
			if colhash_cache.has(hck):
				hcol = int(colhash_cache[hck])
			else:
				hcol = world._rt_colhash(t, cx, cz)
				colhash_cache[hck] = hcol
			var h: int = world._rt_mix64(hcol ^ (sub * 0x9E3779B9))
			if (h & 15) != lx or ((h >> 4) & 15) != ly or ((h >> 8) & 15) != lz:
				recompute_mismatch += 1
			cells_compared += 1
			j += 5
	var min_count := 1 << 30
	var max_count := 0
	for sk in counts:
		if int(counts[sk]) < min_count:
			min_count = int(counts[sk])
		if int(counts[sk]) > max_count:
			max_count = int(counts[sk])
	var local_min := 1 << 30
	var local_max := 0
	for k in local_cnt:
		if int(local_cnt[k]) < local_min:
			local_min = int(local_cnt[k])
		if int(local_cnt[k]) > local_max:
			local_max = int(local_cnt[k])
	var samples := {}
	for probe_col in [[0, 0, 0], [0, 0, 11], [0, 0, 23], [4, 0, 0], [-4, 0, 23], [0, -4, 17]]:
		var pk: int = ((int(probe_col[0]) + 4096) * 16384 + (int(probe_col[1]) + 4096)) * 24 + int(probe_col[2])
		samples["%d,%d:%d" % [int(probe_col[0]), int(probe_col[1]), int(probe_col[2])]] = int(counts.get(pk, -1))
	# (f) per-tick ms (whole game tick: random pass + fluid pass).
	var ms: Array = []
	for i in mini(W, world.game_tick_samples.size()):
		ms.append(float(world.game_tick_samples[i]))
	ms.sort()
	var p95: float = float(ms[mini(ms.size() - 1, int(0.95 * float(ms.size())))]) if not ms.is_empty() else -1.0
	var ms_max: float = float(ms.max()) if not ms.is_empty() else -1.0
	var ms_sum := 0.0
	for m in ms:
		ms_sum += m
	# Region/rate contract self-check (redstone 1-tick dust; mob-spawn
	# 24-44 circle + (n-1) diamond — predicates only, feature work deferred).
	var region_ok: bool = world.in_mob_spawn_region(3, 0) and world.in_mob_spawn_region(24, 0) \
		and world.in_mob_spawn_region(44, 0) and world.in_mob_spawn_region(17, 17) \
		and not world.in_mob_spawn_region(4, 0) and not world.in_mob_spawn_region(45, 0) \
		and not world.in_mob_spawn_region(16, 16) and world.REDSTONE_DUST_DELAY_TICKS == 1
	var wall := Time.get_ticks_msec() - t0
	var ok: bool = set_ready and queue_settled and n_ticks >= W and hz2 >= 18.0 and hz2 <= 22.0 \
		and scope_bad == 0 and band123_ticks == 0 and cols_seen.size() == 41 \
		and counts.size() == expected_subs and min_count == W and max_count == W \
		and recompute_mismatch == 0 and cells_compared == W * expected_subs \
		and world.fluid_tick_count >= W and p95 >= 0.0 and region_ok and wall <= 60000
	Debug.result({
		"ok": ok,
		"wall_ms": wall,
		"phase_ms": {
			"boot_ready": t_ready0 - t0,
			"settle": t_win_start - t_settle0,
			"window": wall_ms,
			"analyze": Time.get_ticks_msec() - t_analyze0,
		},
		"queue_settled": queue_settled,
		"window": W,
		"n_ticks": n_ticks,
		"hz": hz,
		"hz2": hz2,
		"fluid_hz": fluid_hz,
		"fluid_tick_count": world.fluid_tick_count,
		"random_total": world.random_tick_total,
		"subchunks": counts.size(),
		"cols": cols_seen.size(),
		"min_count": min_count,
		"max_count": max_count,
		"expected_subs": expected_subs,
		"scope_bad": scope_bad,
		"band123_ticks": band123_ticks,
		"region_ok": region_ok,
		"samples": samples,
		"local_min": local_min,
		"local_max": local_max,
		"recompute_mismatch": recompute_mismatch,
		"cells_compared": cells_compared,
		"md5_first": md5_first,
		"md5_last": md5_last,
		"window_md5": _tick_md5(seq_bytes),
		"tick_ms_p95": p95,
		"tick_ms_max": ms_max,
		"tick_ms_mean": ms_sum / float(ms.size()) if not ms.is_empty() else -1.0,
		"frame_p95_ms": frame_p95,
		"frame_max_ms": frame_max,
		"frames_over_100ms": frame_big,
	})
	get_tree().quit()


func _bandmap_test(spawn: Vector3) -> void:
	# AC-0152/AC-0160/AC-0181 gate: headless band arithmetic + streaming
	# evidence at render 50. No full r50 drain (7845+ring chunks): counts
	# come from the stubbed streaming set; sample chunks carry quad counts
	# — after AC-0181 band 1 (taxi 5-12) is FULL mesh (quad_count >> 1)
	# and band 2 (taxi >= 13) is the COARSE 32-scale mesh; [12,0]/[13,0]
	# pin the new boundary.
	var t0 := Time.get_ticks_msec()
	var R := 50
	world.render_radius = R
	world.recenter(spawn.x, spawn.z, true)
	var pcx := 0
	var pcz := 0
	var spawn3x3_ms := -1
	var waited := 0
	var prev_b0 := {}
	while waited < 600:
		for c in world.chunks.values():
			if int(c.face) > 1 or int(c.band) != 0:
				continue
			var k0: String = "%d,%d" % [int(c.cx), int(c.cz)]
			var mb: bool = bool(c.mesh_built)
			if prev_b0.get(k0, false) and not mb:
				print("B0LOST %s f3x3=%d data_empty=%s cand=%s queued=%s" % [k0, waited, str(c.data.is_empty()), str(c.candidate), str(world.queued_keys.has(k0))])
			prev_b0[k0] = mb
		var allb := true
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var c = world.chunks.get("%d,%d" % [pcx + dx, pcz + dz])
				if c == null or not c.mesh_built:
					allb = false
					break
			if not allb:
				break
		if allb:
			spawn3x3_ms = Time.get_ticks_msec() - t0
			break
		await get_tree().physics_frame
		waited += 1
	# AC-0160 run 2: the trickle sample must measure the REAL post-recenter
	# queue (~8.2k entries), not the 16-entry pre-warm residue. The recenter
	# slice rebuilds the full queue seconds after the burst (it pauses
	# during the spawn window — see _recenter_slice), so wait for the swap
	# (queue_size > 4000, well past the 25-entry pre-warm) before starting
	# the 1500-frame window: the q trend then starts at ~8244 and trends
	# down (the trickle) instead of showing a 16 -> 8244 recenter artifact
	# mid-sample. spawn3x3_ms is unaffected (measured at the 3x3).
	var swap_waited := 0
	while world.queue_size <= 4000 and swap_waited < 900:
		for c in world.chunks.values():
			if int(c.face) > 1 or int(c.band) != 0:
				continue
			var k0: String = "%d,%d" % [int(c.cx), int(c.cz)]
			var mb: bool = bool(c.mesh_built)
			if prev_b0.get(k0, false) and not mb:
				print("B0LOST %s fswap=%d data_empty=%s cand=%s queued=%s" % [k0, swap_waited, str(c.data.is_empty()), str(c.candidate), str(world.queued_keys.has(k0))])
			prev_b0[k0] = mb
		await get_tree().physics_frame
		swap_waited += 1
	# AC-0160 run 2: the sample window is ALWAYS the full 1500 frames (the
	# trickle-trend gate). The old early exit (all samples have data -> break)
	# was calibrated for the starved data pass: with the drain fix the data
	# arrives in seconds and truncated the trend to a few hundred frames.
	# [14,0] (taxi 14, ~340 builds out) is dropped from the set: it couples
	# the full-mesh evidence to the arm's total wall budget (the gate is NOT
	# "drain the world in the arm"); [9,0]/[10,0] carry the band-2 (coarse
	# after AC-0181) evidence; [12,0]/[13,0] pin the AC-0181 boundary
	# (full at 12, coarse at 13).
	var samples := [[0, 0], [4, 0], [5, 0], [8, 0], [9, 0], [10, 0], [12, 0], [13, 0]]
	var have := {}
	var trickle := []
	var sample_waited := 0
	var max_wait := 1500
	while sample_waited < max_wait:
		for sc in samples:
			var c = world.chunks.get("%d,%d" % sc)
			if c != null and not c.data.is_empty():
				have["%d,%d" % sc] = true
		for c in world.chunks.values():
			if int(c.face) > 1 or int(c.band) != 0:
				continue
			var k0: String = "%d,%d" % [int(c.cx), int(c.cz)]
			var mb: bool = bool(c.mesh_built)
			if prev_b0.get(k0, false) and not mb:
				print("B0LOST %s f=%d data_empty=%s cand=%s queued=%s" % [k0, sample_waited, str(c.data.is_empty()), str(c.candidate), str(world.queued_keys.has(k0))])
			prev_b0[k0] = mb
		if sample_waited % 15 == 0:
			var bn := 0
			for c in world.chunks.values():
				if int(c.face) <= 1 and c.mesh_built:
					bn += 1
			trickle.append({"f": sample_waited, "q": world.queue_size, "built": bn})
		await get_tree().physics_frame
		sample_waited += 1
	trickle.append({"f": sample_waited, "q": world.queue_size, "built": -1})
	var n0 := 0
	var n1 := 0
	var n2 := 0
	var n3 := 0
	var home := 0
	var circle := 0
	var bb0 := 0
	var bb1 := 0
	var bb2 := 0
	for key in world.chunks:
		var c: Node3D = world.chunks[key]
		if int(c.face) > 1:
			continue
		home += 1
		var dx := int(c.cx) - pcx
		var dz := int(c.cz) - pcz
		if dx * dx + dz * dz <= R * R:
			circle += 1
		var b := int(c.band)
		if b == 0:
			n0 += 1
			if c.mesh_built:
				bb0 += 1
		elif b == 1:
			n1 += 1
			if c.mesh_built:
				bb1 += 1
		elif b == 2:
			n2 += 1
			if c.mesh_built:
				bb2 += 1
		else:
			n3 += 1
	var unbuilt0 := []
	var unbuilt1 := []
	for key in world.chunks:
		var c: Node3D = world.chunks[key]
		if int(c.face) > 1:
			continue
		var b := int(c.band)
		if (b == 0 or b == 1) and not c.mesh_built:
			var info: Dictionary = {
				"key": key, "data_empty": c.data.is_empty(),
				"queued": world.queued_keys.has(key), "cand": c.candidate,
			}
			if b == 0:
				unbuilt0.append(info)
			else:
				unbuilt1.append(info)
	# AC-0160: full-mesh band-2 sample evidence — band, mesh_built and the
	# full-mesh face count per sample chunk (the old impostor evidence
	# [build_impostor call + max-top recompute + impostor_y/id/fluid_top/
	# maxtop_check] died with the impostor machinery).
	var sample_report := []
	for k in have:
		var c = world.chunks.get(k)
		sample_report.append({
			"key": k, "band": int(c.band), "mesh_built": bool(c.mesh_built),
			"quad_count": _bm_quad_count(c),
		})
	Debug.result({
		"render_radius": R, "band0_r": world.band0_r, "band1_r": world.band1_r,
		"stream_set_home": home, "circle50_chunks": circle,
		"tick_set_band0": n0, "band_counts": {"b0": n0, "b1": n1, "b2": n2, "b3": n3},
		"spawn3x3_ms": spawn3x3_ms, "spawn3x3_frames": waited,
		"trickle": trickle,
		"queue_final": world.queue_size,
		"built": {"b0": bb0, "b1": bb1, "b2": bb2},
		"b0_unbuilt": unbuilt0, "b1_unbuilt": unbuilt1,
		"band2_sample": sample_report,
		"elapsed_ms": Time.get_ticks_msec() - t0,
	})
	get_tree().quit()


# AC-0181 probe (AWECRAFT_LOGIC=lodband, harness-only, never runs in game):
# walk radially +X from spawn (player chunk 0,3,6,9,12,13,14) at render 50.
# At each step: recenter, settle the taxi <= 14 neighborhood (and wait out
# any in-flight LOD transition), then classify EVERY meshed chunk's fidelity
# from its built UV period (full 16^3 = 31 px per block; coarse uv_scale 2
# = 15.5) and assert the AC-0182 dead-band contract: meshed + taxi <= 11
# => FULL, meshed + taxi >= 14 => COARSE, taxi 12-13 = transition (either,
# hysteresis dead band), band 3 never meshed, ahead-11 FULL / ahead-14
# COARSE at every step, and the spawn chunk's fidelity history is full*
# coarse* (no full->coarse->full pop).
func _lodband_test(spawn: Vector3) -> void:
	var t0 := Time.get_ticks_msec()
	var R := 50
	world.render_radius = R
	var steps := [0, 3, 6, 9, 12, 13, 14]
	var report := []
	var violations := []
	var spawn_hist := []
	for st in steps:
		world.recenter(spawn.x + float(st) * 16.0, spawn.z, true)
		var pcx := int(world.last_pcx)
		var pcz := int(world.last_pcz)
		# wait for the recenter slice walk to finish first: until it does,
		# built chunks still carry their PREVIOUS band + mesh (band
		# reassignment lags the recenter by the full stream-set walk) —
		# sampling then would report stale-band "violations" that are not
		# real. After it, band-changed chunks are cleared + re-queued, so
		# the settle below also waits for their re-mesh.
		var rw := 0
		while world._rec_pending and rw < 3600:
			await get_tree().physics_frame
			rw += 1
		# settle: every chunk with taxi <= 14 around the player is built and
		# has finished any in-flight LOD retain->swap (lod_pending clear).
		var sw := 0
		var max_sw := 9600 if st == 0 else 6000
		while sw < max_sw:
			var allb := true
			for dx in range(-14, 15):
				for dz in range(-14, 15):
					if absi(dx) + absi(dz) > 14:
						continue
					var c = world.chunks.get("%d,%d" % [pcx + dx, pcz + dz])
					if c == null or not c.mesh_built or bool(c.lod_pending):
						allb = false
						break
				if not allb:
					break
			if allb:
				break
			await get_tree().physics_frame
			sw += 1
		var full_ok := 0
		var coarse_ok := 0
		var trans := 0
		var uncl := 0
		var meshed := 0
		for key in world.chunks:
			var c: Node3D = world.chunks[key]
			if int(c.face) > 1 or not c.mesh_built:
				continue
			if int(c.band) == 3:
				violations.append("band3 meshed %s" % str(key))
				continue
			meshed += 1
			var taxi := absi(int(c.cx) - pcx) + absi(int(c.cz) - pcz)
			var f: int = _lod_fidelity(c)
			if taxi <= 11:
				if f == 1:
					full_ok += 1
				elif f == 2:
					violations.append("full-zone coarse %s (taxi %d)" % [str(key), taxi])
				else:
					uncl += 1
			elif taxi >= 14:
				if f == 2:
					coarse_ok += 1
				elif f == 1:
					violations.append("coarse-zone full %s (taxi %d)" % [str(key), taxi])
				else:
					uncl += 1
			else:
				trans += 1
		var a11 = world.chunks.get("%d,%d" % [pcx + 11, pcz])
		var a14 = world.chunks.get("%d,%d" % [pcx + 14, pcz])
		var sk = world.chunks.get("0,0")
		spawn_hist.append(_lod_fidelity(sk) if sk != null and sk.mesh_built else -1)
		report.append({
			"st": st, "pc": [pcx, pcz], "walk_frames": rw, "settle_frames": sw,
			"meshed": meshed, "full_ok": full_ok, "coarse_ok": coarse_ok,
			"transition": trans, "unclassified": uncl,
			"ahead11": _lod_fidelity(a11) if a11 != null and a11.mesh_built else -1,
			"ahead14": _lod_fidelity(a14) if a14 != null and a14.mesh_built else -1,
		})
	# monotonic landmark: the spawn chunk must go full* coarse* along the
	# outward walk (a FULL after a COARSE = high->low->high pop).
	var seen_c := false
	var mono := true
	for h in spawn_hist:
		if h == 2:
			seen_c = true
		elif h == 1:
			if seen_c:
				mono = false
		else:
			mono = false
	Debug.result({
		"render_radius": R, "steps": steps, "report": report,
		"spawn_hist": spawn_hist, "spawn_monotonic": mono,
		"violations": violations, "ok": violations.size() == 0 and mono,
		"elapsed_ms": Time.get_ticks_msec() - t0,
	})
	get_tree().quit()


func _lodswap_test(spawn: Vector3) -> void:
	var t0 := Time.get_ticks_msec()
	var R := 15
	world.render_radius = R
	world.recenter(spawn.x, spawn.z, true)
	var pcx0 := int(world.last_pcx)
	var pcz0 := int(world.last_pcz)
	var T = world.chunks.get("%d,%d" % [pcx0, pcz0])
	if T == null:
		Debug.result({"ok": false, "error": "spawn chunk missing"})
		get_tree().quit()
		return
	var samples := []
	var stt := {"ph": "boot"}
	var wboot := 0
	while wboot < 2400 and not T.mesh_built:
		await get_tree().process_frame
		_lodswap_snap(T, samples, stt, pcx0)
		wboot += 1
	if not T.mesh_built:
		Debug.result({"ok": false, "error": "spawn chunk never built"})
		get_tree().quit()
		return
	var first_built := samples.size()
	for st in range(1, 14):
		stt["ph"] = "out_%d" % st
		_lodswap_walk(st)
		for i in range(24):
			await get_tree().process_frame
			_lodswap_snap(T, samples, stt, pcx0)
	stt["ph"] = "cross1"
	var builds_c1 := int(T.lod_builds)
	_lodswap_walk(14)
	var w14 := 0
	while w14 < 2400:
		await get_tree().process_frame
		_lodswap_snap(T, samples, stt, pcx0)
		w14 += 1
		if T.mesh_built and _lod_fidelity(T) == 2:
			break
	stt["ph"] = "jitter"
	for j in range(12):
		_lodswap_walk(13 if j % 2 == 0 else 14)
		for i in range(10):
			await get_tree().process_frame
			_lodswap_snap(T, samples, stt, pcx0)
	stt["ph"] = "back13"
	_lodswap_walk(13)
	for i in range(10):
		await get_tree().process_frame
		_lodswap_snap(T, samples, stt, pcx0)
	stt["ph"] = "back12"
	_lodswap_walk(12)
	for i in range(10):
		await get_tree().process_frame
		_lodswap_snap(T, samples, stt, pcx0)
	var swaps_c2 := int(T.lod_swaps_instant)
	stt["ph"] = "back11"
	var back_start_f := samples.size()
	_lodswap_walk(11)
	var w11 := 0
	while w11 < 600:
		await get_tree().process_frame
		_lodswap_snap(T, samples, stt, pcx0)
		w11 += 1
		if T.mesh_built and _lod_fidelity(T) == 1:
			break
	var c2_swap_ms := float(T.lod_last_swap_ms)
	stt["ph"] = "fwd12"
	_lodswap_walk(12)
	for i in range(10):
		await get_tree().process_frame
		_lodswap_snap(T, samples, stt, pcx0)
	stt["ph"] = "fwd13"
	_lodswap_walk(13)
	for i in range(10):
		await get_tree().process_frame
		_lodswap_snap(T, samples, stt, pcx0)
	var swaps_c3 := int(T.lod_swaps_instant)
	stt["ph"] = "fwd14"
	var fwd_start_f := samples.size()
	_lodswap_walk(14)
	var w14b := 0
	while w14b < 600:
		await get_tree().process_frame
		_lodswap_snap(T, samples, stt, pcx0)
		w14b += 1
		if T.mesh_built and _lod_fidelity(T) == 2:
			break

	var holes := 0
	for s in samples:
		if int(s["f"]) >= first_built and not bool(s["mb"]):
			holes += 1
	var no_hole := holes == 0
	var retain_window := false
	for s in samples:
		if str(s["ph"]) == "cross1" and bool(s["pend"]) and bool(s["mb"]) and int(s["fid"]) == 1:
			retain_window = true
			break
	var c1_flips := 0
	var c1_flip_f := -1
	var c1_prev := -1
	for s in samples:
		if str(s["ph"]) != "cross1":
			continue
		var f1: int = int(s["fid"])
		if c1_prev == 1 and f1 == 2:
			c1_flips += 1
			c1_flip_f = int(s["f"])
		c1_prev = f1
	var c1_atomic := c1_flips == 1
	var in_flight := 0
	for s in samples:
		if str(s["ph"]) == "cross1" and int(s["f"]) >= c1_flip_f - 1:
			break
		if str(s["ph"]) == "cross1" and bool(s["pend"]) and bool(s["mb"]):
			in_flight += 1
	var j_band := -1
	var j_fid := -1
	var j_band_changes := 0
	var j_fid_changes := 0
	var j_frames := 0
	var j_holes := 0
	for s in samples:
		if str(s["ph"]) != "jitter":
			continue
		j_frames += 1
		var b2: int = int(s["band"])
		var f2: int = int(s["fid"])
		if not bool(s["mb"]):
			j_holes += 1
		if j_band < 0 or b2 != j_band:
			if j_band >= 0:
				j_band_changes += 1
			j_band = b2
		if j_fid < 0 or f2 != j_fid:
			if j_fid >= 0:
				j_fid_changes += 1
			j_fid = f2
	var flicker_ok := j_band_changes == 0 and j_fid_changes == 0 and j_holes == 0 and j_band == 2 and j_fid == 2
	var c2_flips := 0
	var c2_flip_f := -1
	var c2_prev := -1
	for s in samples:
		if not str(s["ph"]).begins_with("back"):
			continue
		var f3: int = int(s["fid"])
		if c2_prev == 2 and f3 == 1:
			c2_flips += 1
			c2_flip_f = int(s["f"])
		c2_prev = f3
	var c2_instant := int(T.lod_swaps_instant) - swaps_c2
	var c2_lag := c2_flip_f - back_start_f if c2_flip_f >= 0 else 999999
	var c2_ok := c2_flips == 1 and c2_instant >= 1 and c2_lag <= 8 and int(T.lod_builds) == 1
	var c3_flips := 0
	var c3_flip_f := -1
	var c3_prev := -1
	for s in samples:
		if not str(s["ph"]).begins_with("fwd"):
			continue
		var f4: int = int(s["fid"])
		if c3_prev == 1 and f4 == 2:
			c3_flips += 1
			c3_flip_f = int(s["f"])
		c3_prev = f4
	var c3_instant := int(T.lod_swaps_instant) - swaps_c3
	var c3_lag := c3_flip_f - fwd_start_f if c3_flip_f >= 0 else 999999
	var c3_ok := c3_flips == 1 and c3_instant >= 1 and c3_lag <= 8
	var end_cache := int(T.alt_lod) == 0 and int(T.band) == 2 and bool(T.mesh_built)
	var ok := no_hole and retain_window and c1_atomic and flicker_ok and c2_ok and c3_ok and end_cache
	Debug.result({
		"ok": ok, "radius": R, "T": [pcx0, pcz0],
		"first_built": first_built, "sample_frames": samples.size(),
		"no_hole": no_hole, "hole_frames": holes,
		"retain_window": retain_window, "cross1_in_flight_frames": in_flight,
		"cross1": {"fidelity_flips": c1_flips, "flip_frame": c1_flip_f, "atomic": c1_atomic, "builds": int(T.lod_builds) - builds_c1},
		"flicker": {"frames": j_frames, "band_changes": j_band_changes, "fidelity_changes": j_fid_changes, "band_end": j_band, "fid_end": j_fid, "ok": flicker_ok},
		"cross2": {"fidelity_flips": c2_flips, "flip_frame": c2_flip_f, "lag_frames": c2_lag, "instant_swaps": c2_instant, "swap_ms": c2_swap_ms, "ok": c2_ok},
		"cross3": {"fidelity_flips": c3_flips, "flip_frame": c3_flip_f, "instant_swaps": c3_instant, "swap_ms": float(T.lod_last_swap_ms), "ok": c3_ok},
		"lod_builds": int(T.lod_builds), "lod_swaps": int(T.lod_swaps), "lod_swaps_instant": int(T.lod_swaps_instant),
		"alt_lod_end": int(T.alt_lod), "end_cache": end_cache,
		"elapsed_ms": Time.get_ticks_msec() - t0,
	})
	get_tree().quit()


func _lodswap_snap(T, samples: Array, stt: Dictionary, pcx0: int) -> void:
	samples.append({
		"ph": stt["ph"], "f": samples.size(), "pcx": int(world.last_pcx) - pcx0,
		"mb": bool(T.mesh_built), "band": int(T.band),
		"fid": _lod_fidelity(T) if T.mesh_built else -1,
		"pend": bool(T.lod_pending),
	})


func _lodswap_walk(pcx: int) -> void:
	world.recenter(float(pcx * 16 + 8), 8.0)


# AC-0181 probe helper: classify a BUILT chunk's mesh fidelity from the UV
# period of its main (opaque merged) mesh. Every merged quad spans WxH
# blocks; its u-axis (strip) UV is 31/uv_scale px per block over ATLAS_PX,
# so any u-axis edge of world length L gives ppb = |du| * ATLAS_PX / L:
# 31 => full 16^3, 15.5 => coarse uv_scale 2. Returns 1 (full), 2 (coarse),
# 0 (unclassified), -1 (no mesh data).
func _lod_fidelity(c) -> int:
	var cands := PackedFloat32Array()
	for s in c.slabs:
		if cands.size() >= 64:
			break
		var mi = s.mesh_instance
		if mi == null or mi.mesh == null:
			continue
		var m: ArrayMesh = mi.mesh
		for si in m.get_surface_count():
			var a = m.surface_get_arrays(si)
			var pos: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
			var uv: PackedVector2Array = a[Mesh.ARRAY_TEX_UV]
			var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX]
			for qi in range(0, idx.size(), 6):
				var p0 := idx[qi]
				var p1 := idx[qi + 1]
				var p2 := idx[qi + 2]
				var p3 := idx[qi + 3]
				for ep in [[p0, p1], [p1, p2], [p2, p3], [p3, p0]]:
					var du: float = absf(uv[ep[0]].x - uv[ep[1]].x)
					var dv: float = absf(uv[ep[0]].y - uv[ep[1]].y)
					if du < 1e-6 or dv > 1e-6:
						continue  # v-axis edge (ms_h-scaled) or flat uv
					var L: float = (pos[ep[0]] - pos[ep[1]]).length()
					if L < 0.99:
						continue
					cands.append(du * Data.ATLAS_PX / L)
		if cands.size() >= 64:
			break
	if cands.is_empty():
		return -1
	cands.sort()
	var med: float = cands[cands.size() / 2]
	if absf(med - 31.0) < 1.0:
		return 1
	if absf(med - 15.5) < 1.0:
		return 2
	return 0


func _er_built_count() -> int:
	var n := 0
	for key in world.chunks:
		if world.chunks[key].mesh_built:
			n += 1
	return n


func _er_ring_counts(pcx: int, pcz: int) -> Dictionary:
	var in_set := 0
	var one_out := 0
	var one_retained := 0
	var one_visible := 0
	var two_out := 0
	var two_retained := 0
	for key in world.chunks:
		var c: Node3D = world.chunks[key]
		if int(c.face) > 1:
			continue
		var dx := int(c.cx) - pcx
		var dz := int(c.cz) - pcz
		var built: bool = c.mesh_built
		if world.in_stream_set(dx, dz):
			in_set += 1
			continue
		if (not world.in_circle_ring(dx, dz)) and (absi(dx) + absi(dz) > world.b1_eff() + 2):
			two_out += 1
			if built:
				two_retained += 1
		else:
			one_out += 1
			if built:
				one_retained += 1
				if _er_chunk_vis(c) > 0:
					one_visible += 1
	return {"in_set": in_set, "one_out": one_out, "one_retained": one_retained, "one_visible": one_visible, "two_out": two_out, "two_retained": two_retained}


func _er_chunk_vis(c) -> int:
	var n := 0
	for s in c.slabs:
		var mi = s.mesh_instance
		if mi != null and mi.mesh != null and mi.visible:
			n += 1
	return n


func _er_chunk_has_mesh(c) -> bool:
	for s in c.slabs:
		var mi = s.mesh_instance
		if mi != null and mi.mesh != null:
			return true
	return false


func _er_chunk_mesh_id(c) -> int:
	for s in c.slabs:
		var mi = s.mesh_instance
		if mi != null and mi.mesh != null:
			return int(mi.mesh.get_instance_id())
	return 0


func _er_track_state(e: Dictionary, pcx: int, pcz: int) -> String:
	var cc = world.chunks.get(e["k"])
	if cc == null:
		return "freed"
	var dx := int(cc.cx) - pcx
	var dz := int(cc.cz) - pcz
	if world.in_stream_set(dx, dz):
		return "set"
	if (not world.in_circle_ring(dx, dz)) and (absi(dx) + absi(dz) > world.b1_eff() + 2):
		return "two_out"
	return "one_out"


func _er_settle(st: Dictionary, back_phase: bool) -> void:
	for i in range(30):
		await get_tree().physics_frame
		for e in st["track"]:
			var cc = world.chunks.get(e["k"])
			if cc == null:
				continue
			var dx := int(cc.cx) - int(world.last_pcx)
			var dz := int(cc.cz) - int(world.last_pcz)
			if int(cc.band) >= 3:
				continue
			if not world.in_stream_set(dx, dz) and back_phase and _er_chunk_vis(cc) == 0:
				st["back_hidden"] += 1
			elif world.in_stream_set(dx, dz) and not bool(cc.mesh_built) and back_phase:
				st["back_hole"] += 1
	var wr := 0
	while wr < 1200 and world._rec_pending:
		await get_tree().process_frame
		wr += 1
	for i in range(6):
		await get_tree().physics_frame


func _er_sample(st: Dictionary, ph: String, pcx: int, pcz: int, back_phase: bool) -> void:
	var rc := _er_ring_counts(pcx, pcz)
	for key in world.chunks:
		var c: Node3D = world.chunks[key]
		if c.mesh_built:
			st["ever_built"][key] = true
	for key in st["ever_built"]:
		var c2: Node3D = world.chunks.get(key)
		if c2 == null:
			continue
		var dx2 := int(c2.cx) - pcx
		var dz2 := int(c2.cz) - pcz
		if not world.in_stream_set(dx2, dz2) and bool(c2.candidate) and not c2.mesh_built:
			st["killed"] += 1
	if int(rc["one_retained"]) > int(st["one_ret_max"]):
		st["one_ret_max"] = int(rc["one_retained"])
	if int(rc["two_retained"]) > int(st["two_ret_max"]):
		st["two_ret_max"] = int(rc["two_retained"])
	for e in st["track"]:
		var stt := _er_track_state(e, pcx, pcz)
		e["states"].append(stt)
		var cc = world.chunks.get(e["k"])
		if cc == null:
			if int(e["freed_at"]) < 0:
				e["freed_at"] = int(st["n"])
			continue
		if int(cc.band) < 3:
			if not bool(cc.mesh_built) or not _er_chunk_has_mesh(cc):
				e["killed_seen"] = true
				if back_phase:
					st["back_hole"] += 1
			elif int(_er_chunk_mesh_id(cc)) != int(e["mesh_id"]):
				e["remeshed"] = true
			var v := _er_chunk_vis(cc)
			if int(e["vis_min"]) < 0 or v < int(e["vis_min"]):
				e["vis_min"] = v
			if stt != "set" and v == 0:
				e["hidden_cand"] = true
		if stt == "two_out":
			e["two_out_events"] = int(e["two_out_events"]) + 1
	var row := {"ph": ph, "pcx": pcx - int(st["pcx0"]), "ring": rc, "states": {}}
	for e in st["track"]:
		row["states"][e["k"]] = str(e["states"][-1])
	st["samples"].append(row)
	st["n"] = int(st["n"]) + 1


func _edgeretain_test(spawn: Vector3) -> void:
	var t0 := Time.get_ticks_msec()
	var R := 8
	world.render_radius = R
	world.recenter(spawn.x, spawn.z, true)
	var pcx0 := int(world.last_pcx)
	var pcz0 := int(world.last_pcz)
	var core_ok := false
	var wboot := 0
	while wboot < 20000:
		var allb := true
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var c = world.chunks.get("%d,%d" % [pcx0 + dx, pcz0 + dz])
				if c == null or not c.mesh_built:
					allb = false
					break
			if not allb:
				break
		if allb:
			core_ok = true
			break
		if wboot % 2000 == 0:
			print("ERBOOT f=%d chunks=%d queue=%d" % [wboot, world.chunks.size(), world.queue_size])
		await get_tree().process_frame
		wboot += 1
	if not core_ok:
		Debug.result({"ok": false, "error": "core 3x3 never built", "radius": R, "chunks": world.chunks.size(), "queue": world.queue_size})
		get_tree().quit()
		return
	var track: Array = [
		{"k": "%d,%d" % [pcx0 - 8, pcz0]},
		{"k": "%d,%d" % [pcx0 - 6, pcz0 + 5]},
		{"k": "%d,%d" % [pcx0 - 5, pcz0 - 6]},
	]
	var edge_ok := true
	var edge_diag: Array = []
	for e in track:
		var we := 0
		var cc = world.chunks.get(e["k"])
		while we < 20000 and (cc == null or not cc.mesh_built or not _er_chunk_has_mesh(cc)):
			if we % 2000 == 0 and we > 0:
				print("EREDGE f=%d k=%s queue=%d built=%d" % [we, e["k"], world.queue_size, _er_built_count()])
			await get_tree().process_frame
			cc = world.chunks.get(e["k"])
			we += 1
		if cc == null or not cc.mesh_built or not _er_chunk_has_mesh(cc):
			edge_diag.append({"k": e["k"], "present": cc != null, "built": cc != null and bool(cc.mesh_built), "queued": str(world.queued_keys.get(e["k"], ""))})
			edge_ok = false
		else:
			e["mesh_id"] = _er_chunk_mesh_id(cc)
			e["band"] = int(cc.band)
			e["lod_builds"] = int(cc.lod_builds)
			e["states"] = []
			e["vis_min"] = -1
			e["freed_at"] = -1
			e["remeshed"] = false
			e["two_out_events"] = 0
			e["killed_seen"] = false
			e["hidden_cand"] = false
	if not edge_ok:
		Debug.result({"ok": false, "error": "tracked edge chunk never built", "radius": R, "chunks": world.chunks.size(), "queue": world.queue_size, "diag": edge_diag})
		get_tree().quit()
		return
	player = _spawn_player()
	var p = Game.player
	var max_h := -1
	for bx in range(int(spawn.x), int(spawn.x) + 8 * 16, 4):
		var h := WorldGen.terrain_height(bx, int(spawn.z), Game.world_seed)
		max_h = maxi(max_h, h)
	var fly_y := float(maxi(max_h, 0)) + 8.0
	p.position = Vector3(float(pcx0) * 16.0 + 8.0, fly_y, float(pcz0) * 16.0 + 8.0)
	p.velocity = Vector3.ZERO
	p.set_fly(true)
	p.look(PI / 2.0, 0.0)
	for i in range(6):
		await get_tree().physics_frame
	var st := {
		"pcx0": pcx0,
		"track": track,
		"ever_built": {},
		"killed": 0,
		"one_ret_max": 0,
		"two_ret_max": 0,
		"back_hole": 0,
		"back_hidden": 0,
		"samples": [],
		"n": 0,
	}
	for key in world.chunks:
		if world.chunks[key].mesh_built:
			st["ever_built"][key] = true
	_er_sample(st, "boot", pcx0, pcz0, false)
	p.position = Vector3(float(pcx0 + 1) * 16.0 + 8.0, fly_y, float(pcz0) * 16.0 + 8.0)
	p.velocity = Vector3.ZERO
	await _er_settle(st, false)
	_er_sample(st, "out1", int(world.last_pcx), int(world.last_pcz), false)
	p.position = Vector3(float(pcx0 + 2) * 16.0 + 8.0, fly_y, float(pcz0) * 16.0 + 8.0)
	p.velocity = Vector3.ZERO
	await _er_settle(st, false)
	_er_sample(st, "out2", int(world.last_pcx), int(world.last_pcz), false)
	for i in range(3):
		world.recenter(p.position.x, p.position.z, true)
		var wh := 0
		while wh < 600 and world._rec_pending:
			await get_tree().process_frame
			wh += 1
		for j in range(4):
			await get_tree().physics_frame
		_er_sample(st, "hold%d" % (i + 1), int(world.last_pcx), int(world.last_pcz), false)
	p.position = Vector3(float(pcx0 + 3) * 16.0 + 8.0, fly_y, float(pcz0) * 16.0 + 8.0)
	p.velocity = Vector3.ZERO
	await _er_settle(st, false)
	_er_sample(st, "out3", int(world.last_pcx), int(world.last_pcz), false)
	p.position = Vector3(float(pcx0 + 2) * 16.0 + 8.0, fly_y, float(pcz0) * 16.0 + 8.0)
	p.velocity = Vector3.ZERO
	await _er_settle(st, true)
	_er_sample(st, "back1", int(world.last_pcx), int(world.last_pcz), true)
	p.position = Vector3(float(pcx0 + 1) * 16.0 + 8.0, fly_y, float(pcz0) * 16.0 + 8.0)
	p.velocity = Vector3.ZERO
	await _er_settle(st, true)
	_er_sample(st, "back2", int(world.last_pcx), int(world.last_pcz), true)
	var e0: Dictionary = st["track"][0]
	var e1: Dictionary = st["track"][1]
	var e2: Dictionary = st["track"][2]
	var t1_one := int(e0["states"].count("one_out"))
	var t1_freed := int(e0["freed_at"]) >= 0
	var t1_ok := not t1_freed and t1_one >= 4 and int(e0["vis_min"]) > 0 \
			and not bool(e0["killed_seen"]) and not bool(e0["remeshed"]) and not bool(e0["hidden_cand"])
	var t2_ok := int(e1["two_out_events"]) == 1 and int(e1["freed_at"]) >= 3 \
			and int(e1["freed_at"]) <= 5 and not bool(e1["hidden_cand"])
	var t3_two_idx := int(e2["states"].find("two_out"))
	var t3_back_idx := -1
	for si in range(t3_two_idx + 1, int(e2["states"].size())):
		if str(e2["states"][si]) == "set":
			t3_back_idx = si
			break
	var t3_ok := t3_back_idx >= 7 \
			and not bool(e2["killed_seen"]) and not bool(e2["remeshed"]) and not bool(e2["hidden_cand"])
	var fog_near := DayNight.fog_near(R)
	var fog_far := DayNight.fog_far(R)
	var ring_face := (R + 1) * 16.0 - 8.0
	var fog_covers := ring_face <= fog_far
	var ok := int(st["killed"]) == 0 and t1_ok and t2_ok and t3_ok \
			and int(st["one_ret_max"]) >= 1 and int(st["two_ret_max"]) >= 1 \
			and int(st["back_hole"]) == 0 and int(st["back_hidden"]) == 0 and fog_covers
	var out := {
		"ok": ok,
		"radius": R,
		"fog": {"fog_near": fog_near, "fog_far": fog_far, "ring_near_face": ring_face, "fog_covers_ring": fog_covers},
		"one_retained_max": int(st["one_ret_max"]),
		"two_retained_max": int(st["two_ret_max"]),
		"killed_while_candidate": int(st["killed"]),
		"back_hole_frames": int(st["back_hole"]),
		"back_hidden_frames": int(st["back_hidden"]),
		"t1_axial_full": {"key": e0["k"], "band": int(e0["band"]), "states": e0["states"], "one_out_events": t1_one, "freed": t1_freed, "vis_min": int(e0["vis_min"]), "killed_seen": bool(e0["killed_seen"]), "remeshed": bool(e0["remeshed"]), "hidden_cand": bool(e0["hidden_cand"]), "ok": t1_ok},
		"t2_free_path": {"key": e1["k"], "band": int(e1["band"]), "states": e1["states"], "two_out_events": int(e1["two_out_events"]), "freed_at": int(e1["freed_at"]), "ok": t2_ok},
		"t3_back_path": {"key": e2["k"], "band": int(e2["band"]), "states": e2["states"], "reentered_at": t3_back_idx, "vis_min": int(e2["vis_min"]), "killed_seen": bool(e2["killed_seen"]), "remeshed": bool(e2["remeshed"]), "hidden_cand": bool(e2["hidden_cand"]), "ok": t3_ok},
		"samples": st["samples"],
		"elapsed_ms": Time.get_ticks_msec() - t0,
	}
	Debug.result(out)
	get_tree().quit()


func _await_boundary_core(spawn: Vector3, max_frames: int) -> void:
	var pcx := int(floorf(spawn.x / 16.0))
	var pcz := int(floorf(spawn.z / 16.0))
	var waited := 0
	while waited < max_frames:
		var allb := true
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var c = world.chunks.get("%d,%d" % [pcx + dx, pcz + dz])
				if c == null or not c.mesh_built:
					allb = false
					break
		if allb:
			return
		await get_tree().physics_frame
		waited += 1
	print("BOUNDARYCORE not fully built after %d frames" % max_frames)


func _boundary_test(spawn: Vector3, t0: int) -> void:
	var r: int = world.render_radius
	var walk_lines := 20
	var we := OS.get_environment("AWECRAFT_WALK")
	if we != "":
		walk_lines = we.to_int()
	var walk_speed := 16.0
	var se := OS.get_environment("AWECRAFT_WALK_SPEED")
	if se != "":
		walk_speed = se.to_float()
	var count_every := maxi(1, r / 4)

	var mx := int(spawn.x) + 8
	var mz := int(spawn.z)
	var my: int = world.surface_top(mx, mz)
	var orig_id: int = world.get_block(mx, my, mz)
	var new_id := 3 if orig_id != 3 else 2
	world.set_block(mx, my, mz, new_id)
	for i in 10:
		await get_tree().physics_frame

	var max_h := -1
	for bx in range(int(spawn.x), int(spawn.x) + walk_lines * 16 + 4, 4):
		var h := WorldGen.terrain_height(bx, mz, Game.world_seed)
		max_h = maxi(max_h, h)
	var fly_y := float(maxi(max_h, 0)) + 8.0

	var p = Game.player
	p.position = Vector3(spawn.x, fly_y, spawn.z)
	p.velocity = Vector3.ZERO
	p.set_fly(true)
	p.look(-PI / 2.0, 0.0)
	for i in 6:
		await get_tree().physics_frame

	world.fluid_tick_samples.clear()
	var mem_before: int = OS.get_static_memory_usage()
	var t_walk0 := Time.get_ticks_msec()

	var frame_ms_list: Array = []
	var max_ms := 0
	var loads := 0
	var unloads := 0
	var flap := 0
	var crossings := 0
	var cross_at: Array = []
	var cross_cx: Array = []
	var cross_cz: Array = []
	var cross_burst: Array = []
	var cross_resolved: Array = []
	var cross_fw: Array = []
	var cross_fw_resolved: Array = []
	var cross_tr: Array = []
	var cross_tr_resolved: Array = []
	var cross_bd: Array = []  # AC-0079 v3: world.build_dispatch_total at each crossing (pick-order probe)
	# AC-0079: spec wall reference = the player's chunk at crossing (symmetric ±r,
	# dx==0 column excluded). Wall keys are the full set of columns ±(r+1) for
	# presence/ever_built tracking; the gate itself is satisfied per the spec set
	# (every tracked wall chunk counts as built if currently mesh_built OR observed
	# mesh_built at any earlier frame — ever_built handles hysteresis frees of
	# trailing chunks while the player keeps walking).
	var cross_pcx: Array = []
	var cross_pcz: Array = []
	var wall_keys: Array = []
	var wall_ever_built: Dictionary = {}
	var prev_pcx := int(floorf(p.position.x / 16.0))
	var prev_keys: Dictionary = {}
	for key in world.chunks:
		prev_keys[key] = true
	var freed_recent: Dictionary = {}
	var min_irb := 1000000000
	var max_irb := 0
	var walk_frames := 0
	var walk_max_frames := 30000
	var prev_t := Time.get_ticks_msec()
	var light_comp_mark := int(world.perf_light_self_computes)
	var light_batch_mark := int(world.perf_light_batch_calls)
	var light_comp_cross: Array = []
	var light_batch_cross: Array = []
	var _framelog := OS.get_environment("AWECRAFT_FRAMELOG") == "1"
	while crossings < walk_lines and walk_frames < walk_max_frames:
		var fb := Time.get_ticks_msec()
		await get_tree().physics_frame
		var fe := Time.get_ticks_msec()
		var fms := fe - fb
		frame_ms_list.append(fms)
		if fms > max_ms:
			max_ms = fms
		if _framelog:
			print("FLOG %d %d %d" % [walk_frames, fms, fe])
		walk_frames += 1
		var cx_now := int(floorf(p.position.x / 16.0))
		var cz_now := int(floorf(p.position.z / 16.0))
		if walk_frames % count_every == 0:
			var cur_keys: Dictionary = {}
			var cur_chunks: Dictionary = {}
			var pir_present := 0
			var pir_built := 0
			for key in world.chunks:
				var c: Node3D = world.chunks[key]
				cur_keys[key] = true
				cur_chunks[key] = c
				if absi(int(c.cx) - cx_now) <= r and absi(int(c.cz) - cz_now) <= r:
					pir_present += 1
					if c.mesh_built:
						pir_built += 1
			if pir_built < min_irb:
				min_irb = pir_built
			if pir_built > max_irb:
				max_irb = pir_built
			for key in cur_keys:
				if not prev_keys.has(key):
					loads += 1
					if freed_recent.has(key):
						flap += 1
						freed_recent.erase(key)
			for key in prev_keys:
				if not cur_keys.has(key):
					unloads += 1
					freed_recent[key] = true
			prev_keys = cur_keys
			# AC-0079 ever_built: remember wall chunks observed mesh_built (they
			# may later be hysteresis-freed while the player keeps walking).
			for ci in range(wall_keys.size()):
				for key in wall_keys[ci]:
					if wall_ever_built.has(key):
						continue
					if cur_keys.has(key):
						var c: Node3D = world.chunks[key]
						if c.mesh_built:
							wall_ever_built[key] = true
			for ci in range(cross_burst.size()):
				if cross_resolved[ci]:
					continue
				var ccx: int = int(cross_cx[ci])
				var ccz: int = int(cross_cz[ci])
				var allb := true
				for zc in range(ccz - r, ccz + r + 1):
					var ch = world.chunks.get("%d,%d" % [ccx, zc])
					if ch == null or not ch.mesh_built:
						allb = false
						break
				if allb:
					cross_resolved[ci] = true
					cross_burst[ci] = fe - int(cross_at[ci])
			for ci in range(cross_fw.size()):
				if cross_fw_resolved[ci]:
					continue
				if _ac0079_wall_built(ci, 1, r, cross_pcx, cross_pcz, cur_chunks, wall_ever_built):
					cross_fw_resolved[ci] = true
					cross_fw[ci] = fe - int(cross_at[ci])
			for ci in range(cross_tr.size()):
				if cross_tr_resolved[ci]:
					continue
				if _ac0079_wall_built(ci, -1, r, cross_pcx, cross_pcz, cur_chunks, wall_ever_built):
					cross_tr_resolved[ci] = true
					cross_tr[ci] = fe - int(cross_at[ci])
		if cx_now > prev_pcx:
			crossings += cx_now - prev_pcx
			cross_at.append(fe)
			cross_cx.append(cx_now + r)
			cross_cz.append(cz_now)
			cross_burst.append(-1)
			cross_resolved.append(false)
			cross_fw.append(-1)
			cross_fw_resolved.append(false)
			cross_tr.append(-1)
			cross_tr_resolved.append(false)
			cross_pcx.append(cx_now)  # AC-0079: spec wall reference = player chunk at crossing
			cross_pcz.append(cz_now)
			cross_bd.append(int(world.build_dispatch_total))  # AC-0079 v3: dispatch marker
			var wk: Array = []
			for zc in range(cz_now - r - 1, cz_now + r + 2):
				for xc in range(cx_now - r - 1, cx_now + r + 2):
					wk.append("%d,%d" % [xc, zc])
			wall_keys.append(wk)
			prev_pcx = cx_now
			light_comp_cross.append(int(world.perf_light_self_computes) - light_comp_mark)
			light_batch_cross.append(int(world.perf_light_batch_calls) - light_batch_mark)
			light_comp_mark = int(world.perf_light_self_computes)
			light_batch_mark = int(world.perf_light_batch_calls)
		var dt := (fe - prev_t) / 1000.0
		prev_t = fe
		p.position.x += walk_speed * dt
		p.velocity = Vector3.ZERO

	var settle_frames := 0
	var settle_max := 1200
	var last_pir_built := -1
	var quiet := 0
	while settle_frames < settle_max:
		var fb := Time.get_ticks_msec()
		await get_tree().physics_frame
		var fe := Time.get_ticks_msec()
		var cx_now := int(floorf(p.position.x / 16.0))
		var cz_now := int(floorf(p.position.z / 16.0))
		settle_frames += 1
		if settle_frames % count_every == 0:
			var pir_built := 0
			for key in world.chunks:
				var c: Node3D = world.chunks[key]
				if absi(int(c.cx) - cx_now) <= r and absi(int(c.cz) - cz_now) <= r and c.mesh_built:
					pir_built += 1
			if pir_built == last_pir_built:
				quiet += 1
			else:
				quiet = 0
				last_pir_built = pir_built
		var all_resolved := true
		for ci in range(cross_burst.size()):
			if cross_resolved[ci]:
				continue
			var ccx: int = int(cross_cx[ci])
			var allb := true
			for zc in range(int(cross_cz[ci]) - r, int(cross_cz[ci]) + r + 1):
				var ch = world.chunks.get("%d,%d" % [ccx, zc])
				if ch == null or not ch.mesh_built:
					allb = false
					break
			if allb:
				cross_resolved[ci] = true
				cross_burst[ci] = fe - int(cross_at[ci])
			else:
				all_resolved = false
		# AC-0079: settle loop also observes ever_built every frame (chunk map
		# presence is enough to sample the live set).
		var settle_cur: Dictionary = {}
		for key in world.chunks:
			settle_cur[key] = world.chunks[key]
		for ci in range(wall_keys.size()):
			for key in wall_keys[ci]:
				if wall_ever_built.has(key):
					continue
				var c = settle_cur.get(key)
				if c != null and c.mesh_built:
					wall_ever_built[key] = true
		for ci in range(cross_fw.size()):
			if cross_fw_resolved[ci]:
				continue
			if _ac0079_wall_built(ci, 1, r, cross_pcx, cross_pcz, settle_cur, wall_ever_built):
				cross_fw_resolved[ci] = true
				cross_fw[ci] = fe - int(cross_at[ci])
			else:
				all_resolved = false
		for ci in range(cross_tr.size()):
			if cross_tr_resolved[ci]:
				continue
			if _ac0079_wall_built(ci, -1, r, cross_pcx, cross_pcz, settle_cur, wall_ever_built):
				cross_tr_resolved[ci] = true
				cross_tr[ci] = fe - int(cross_at[ci])
			else:
				all_resolved = false
		if all_resolved and quiet >= 30:
			break

	var resident_final: int = world.chunks.size()
	var built_final := 0
	var irb_final := 0
	var irp_final := 0
	var cx_end := int(floorf(p.position.x / 16.0))
	var cz_end := int(floorf(p.position.z / 16.0))
	for key in world.chunks:
		var c: Node3D = world.chunks[key]
		if c.mesh_built:
			built_final += 1
		if absi(int(c.cx) - cx_end) <= r and absi(int(c.cz) - cz_end) <= r:
			irp_final += 1
			if c.mesh_built:
				irb_final += 1

	var mem_after: int = OS.get_static_memory_usage()
	var walk_s := roundf((prev_t - t_walk0) / 1000.0 * 100.0) / 100.0
	var fluid_samples: Array = world.fluid_tick_samples
	var fluid_p95 := _percentile(fluid_samples, 0.95)
	var fluid_max := 0.0
	for s in fluid_samples:
		if float(s) > fluid_max:
			fluid_max = float(s)
	# AC-0080 re-entry rebuild gate: retreat toward the start so the marker
	# chunk (freed for small r during the walk) re-enters in-radius, let the
	# drain re-mesh it, then verify mesh + collision + preserved edit.
	var mkey := "%d,%d" % [int(floorf(float(mx) / 16.0)), int(floorf(float(mz) / 16.0))]
	var rx := mini(float(p.position.x) - 8.0 * 16.0, 16.0 * float(r) + 8.0)
	p.position.x = rx
	p.velocity = Vector3.ZERO
	var remesh_ok := false
	for i in 3000:
		await get_tree().physics_frame
		p.velocity = Vector3.ZERO
		var mc = world.chunks.get(mkey)
		if mc != null and mc.mesh_built and mc.has_any_slab_body() and world.get_block(mx, my, mz) == new_id:
			remesh_ok = true
			break
	# AC-0119: marker read moved AFTER the re-entry remesh — pre-change this
	# (at its old position, post-walk) only passed via read-path sync gen of
	# the freed marker chunk; now it verifies edit preservation through
	# free + re-entry at a point where the chunk is guaranteed rebuilt.
	var marker_ok: bool = world.get_block(mx, my, mz) == new_id
	var unbodied_final := 0
	for key in world.chunks:
		var c: Node3D = world.chunks[key]
		if c.mesh_built and not c.has_any_slab_body() and absi(int(c.cx) - cx_end) <= r and absi(int(c.cz) - cz_end) <= r:
			unbodied_final += 1
	# AC-0079 v3 pick-order probe: per crossing, the count of forward (dx > 0,
	# relative to the crossing player chunk) chunks among the FIRST 10
	# mesh-build dispatches AFTER the crossing (the next 10 dispatches in the
	# global dispatch log — they may span into the next crossing's interval).
	# Crossings with <10 dispatches remaining (end of log) are excluded from
	# the p95 (-1 in the per-crossing list). The direct measurement of look
	# priority — a non-prioritized drain yields ~4-6, a forward-first drain
	# >= 8 (the lead column's 9 chunks dispatch back-to-back right after the
	# crossing).
	var fwd_first10: Array = []
	var fwd_first10_list: Array = []
	var total_bd := int(world.build_dispatch_total)
	var log_base := int(total_bd) - int(world.build_dispatch_log.size())
	for ci in range(cross_bd.size()):
		var start := int(cross_bd[ci])
		var n10 := 0
		var fwd := 0
		for k in range(start, mini(start + 10, total_bd)):
			var li := k - log_base
			if li < 0 or li >= world.build_dispatch_log.size():
				break
			var v: Vector2i = world.build_dispatch_log[li]
			n10 += 1
			if v.x > int(cross_pcx[ci]):
				fwd += 1
		if n10 >= 10:
			fwd_first10_list.append(fwd)
			fwd_first10.append(fwd)
		else:
			fwd_first10_list.append(-1)
	if OS.get_environment("AWECRAFT_MESH_INFO") != "":
		var mi = _matinfo_counts()
		print("MATINFO built_chunks=%d distinct_std=%d distinct_all=%d total_allocs=%d" % [mi.built_chunks, mi.distinct_std, mi.distinct_all, mi.total_allocs])
	var ok := crossings == walk_lines and marker_ok
	Debug.result({
		"ok": ok,
		"radius": r,
		"walk_chunks": walk_lines,
		"walk_speed": roundf(walk_speed * 100.0) / 100.0,
		"walk_s": walk_s,
		"crossings": crossings,
		"p50_ms": int(_percentile(frame_ms_list, 0.50)),
		"p95_ms": int(_percentile(frame_ms_list, 0.95)),
		"max_ms": int(max_ms),
		"loads": loads,
		"unloads": unloads,
		"flap": flap,
		"burst_ms_per_crossing": cross_burst,
		"burst_p50_ms": int(_percentile(_resolved_bursts(cross_burst), 0.50)),
		"burst_p95_ms": int(_percentile(_resolved_bursts(cross_burst), 0.95)),
		"burst_max_ms": int(_max_int(cross_burst)),
		"forward_wall_ms_per_crossing": cross_fw,
		"forward_p95_ms": int(_percentile(_resolved_bursts(cross_fw), 0.95)),
		"forward_max_ms": int(_max_int(cross_fw)),
		"trailing_wall_ms_per_crossing": cross_tr,
		"trailing_p95_ms": int(_percentile(_resolved_bursts(cross_tr), 0.95)),
		"trailing_max_ms": int(_max_int(cross_tr)),
		"fwd_first10_per_crossing": fwd_first10_list,
		"fwd_first10_p95": int(_percentile(fwd_first10, 0.95)),
		"fluid_tick_ms_p95": roundf(fluid_p95 * 100.0) / 100.0,
		"fluid_tick_max_ms": roundf(fluid_max * 100.0) / 100.0,
		"fluid_tick_n": int(fluid_samples.size()),
		"mem_before_bytes": int(mem_before),
		"mem_after_bytes": int(mem_after),
		"mem_delta_mb": roundf((int(mem_after) - int(mem_before)) / 1048576.0 * 10.0) / 10.0,
		"marker": [mx, my, mz, orig_id, new_id],
		"marker_ok": bool(marker_ok),
		"remesh_ok": bool(remesh_ok),
		"resident_final": int(resident_final),
		"built_final": built_final,
		"in_radius_built_final": irb_final,
		"in_radius_present_final": irp_final,
		"in_radius_built_min": min_irb if min_irb < 1000000000 else 0,
		"in_radius_built_max": max_irb,
		"target_in_radius": (2 * r + 1) * (2 * r + 1),
		"queue_size": int(world.queue_size),
		"light_self_computes": int(world.perf_light_self_computes),
		"light_batch_calls": int(world.perf_light_batch_calls),
		"light_batch_chunks": int(world.perf_light_batch_chunks),
		"light_cache_hits": int(world.perf_light_cache_hits),
		"light_computes_per_crossing": light_comp_cross,
		"light_batches_per_crossing": light_batch_cross,
		"collision_ms_total": int(world.perf_collision_ms),
		"collision_n": int(world.perf_collision_n),
		"collision_max_ms": int(world.perf_collision_max_ms),
		"staged_drained": int(world.perf_staged_drained),
		"staged_dropped": int(world.perf_staged_dropped),
		"read_sync_gen": int(world.perf_read_sync_gen),
		"read_sync_gen_ms": world.perf_read_sync_gen_ms,
		"create_sync_gen": int(world.perf_create_sync_gen),
		"staged_pending_final": int(world._col_pending.size()),
		"unbodied_built_final": unbodied_final,
	})
	get_tree().quit()


func _resolved_bursts(bursts: Array) -> Array:
	var out: Array = []
	for b in bursts:
		if int(b) >= 0:
			out.append(int(b))
	return out


func _max_int(arr: Array) -> int:
	var m := -1
	for v in arr:
		if int(v) > m:
			m = int(v)
	return m if m >= 0 else 0


# AC-0079: spec wall check. dir=+1 forward (dx in 1..r), dir=-1 trailing (dx in -r..-1),
# relative to the crossing player chunk (cross_pcx); dx==0 column excluded;
# zc in -(r)..r. A chunk counts as built if it is present + mesh_built now, or was
# observed mesh_built at any earlier frame (ever_built) — hysteresis-freed trailing
# chunks still satisfy the wall ("built while in radius").
func _ac0079_wall_built(ci: int, dir: int, r: int, pcx_arr: Array, pcz_arr: Array, cur: Dictionary, ever_built: Dictionary) -> bool:
	var pcx: int = int(pcx_arr[ci])
	var ccz: int = int(pcz_arr[ci])
	var d0 := 1 if dir > 0 else -r
	var d1 := r if dir > 0 else -1
	for dx in range(d0, d1 + 1):
		for zc in range(ccz - r, ccz + r + 1):
			var key := "%d,%d" % [pcx + dx, zc]
			var c = cur.get(key)
			if c == null:
				if not ever_built.has(key):
					return false
			elif not c.mesh_built and not ever_built.has(key):
				return false
	return true


func _atlas_test(spawn: Vector3) -> void:
	var pcx := int(floorf(spawn.x / 16.0))
	var pcz := int(floorf(spawn.z / 16.0))
	var c = world.chunks.get("%d,%d" % [pcx, pcz])
	for i in 900:
		if c != null and c.mesh_built and c.first_opaque_mesh() != null:
			break
		await get_tree().physics_frame
	var mesh: ArrayMesh = c.first_opaque_mesh() if c != null else null
	if mesh == null:
		Debug.result({"error": "spawn chunk not meshed"})
		get_tree().quit()
		return
	var has_uv := false
	var uv_min := 1.0
	var uv_max := 0.0
	if mesh.get_surface_count() > 0:
		var arrs = mesh.surface_get_arrays(0)
		var uvs: PackedVector2Array = arrs[Mesh.ARRAY_TEX_UV]
		if uvs.size() > 0:
			has_uv = true
			for uv in uvs:
				uv_min = minf(uv_min, minf(uv.x, uv.y))
				uv_max = maxf(uv_max, maxf(uv.x, uv.y))
	var gt := Data.block_rect(1, "top")
	var gs := Data.block_rect(1, "side")
	Debug.result({
		"has_uv": has_uv,
		"uv_min": roundf(uv_min * 10000.0) / 10000.0,
		"uv_max": roundf(uv_max * 10000.0) / 10000.0,
		"uv_in_range": has_uv and uv_min >= 0.0 and uv_max <= 1.0,
		"grass_top": [int(gt.x), int(gt.y)],
		"grass_side": [int(gs.x), int(gs.y)],
		"grass_distinct": gt != gs,
	})
	get_tree().quit()


func _tint_test() -> void:
	world.collision_enabled = false
	world.render_radius = 1
	var seed := Game.world_seed
	var exp_grass := [93.0, 178.0, 55.0]
	var exp_water := [0.95 * 47.0, 0.95 * 107.0, 0.95 * 235.0]
	var out := {}
	var ok := true
	for bm in ["plains", "forest", "snow", "desert"]:
		var cell = _tint_find_cell(bm, seed)
		var tag = bm
		if bm == "plains" or bm == "forest":
			tag = bm + "_grass"
		elif bm == "snow":
			tag = "snow_grass"
		elif bm == "desert":
			tag = "sand"
		if cell == null:
			out[tag] = {"error": "no_cell"}
			ok = false
			continue
		var tcx := int(floorf(float(cell["x"]) / 16.0))
		var tcz := int(floorf(float(cell["z"]) / 16.0))
		world.recenter(float(cell["x"]), float(cell["z"]), true)
		if not await _tint_wait_built(tcx, tcz, 1500):
			out[tag] = {"error": "not_built", "at": [cell["x"], cell["z"]]}
			ok = false
			continue
		var c = world.chunks.get("%d,%d" % [tcx, tcz])
		var got = _tint_vertex(c, cell, false)
		if got == null:
			out[tag] = {"error": "no_vertex", "at": [cell["x"], cell["z"], cell["y"]]}
			ok = false
			continue
		var m := true
		if bm == "plains" or bm == "forest":
			m = _tint_close(got, exp_grass)
		else:
			m = _tint_neutral(got)
		out[tag] = {"at": [cell["x"], cell["z"], cell["y"]], "rgb": got, "match": m}
		if not m:
			ok = false
	var wf = _tint_find_water(seed)
	if wf == null:
		out["water"] = {"error": "no_water"}
		ok = false
	else:
		var wcx := int(floorf(float(wf["x"]) / 16.0))
		var wcz := int(floorf(float(wf["z"]) / 16.0))
		world.recenter(float(wf["x"]), float(wf["z"]), true)
		if not await _tint_wait_built(wcx, wcz, 1500):
			out["water"] = {"error": "not_built", "at": [wf["x"], wf["z"]]}
			ok = false
		else:
			var c = world.chunks.get("%d,%d" % [wcx, wcz])
			var got = _tint_vertex(c, wf, true)
			if got == null:
				out["water"] = {"error": "no_vertex", "at": [wf["x"], wf["z"]]}
				ok = false
			else:
				var m := _tint_close(got, exp_water)
				out["water"] = {"at": [wf["x"], wf["z"]], "biome": WorldGen.biome_at(wf["x"], wf["z"], seed), "rgb": got, "match": m}
				if not m:
					ok = false
	Debug.result({"ok": ok, "samples": out})
	get_tree().quit()


func _tint_find_cell(bm: String, seed: int):
	var want_top := 1
	if bm == "snow":
		want_top = 12
	elif bm == "desert":
		want_top = 4
	var gen_cache := {}
	for z in range(-160, 161, 2):
		for x in range(-160, 161, 2):
			if WorldGen.biome_at(x, z, seed) != bm:
				continue
			var h := WorldGen.terrain_height(x, z, seed)
			# AC-0091: world max height remapped 74 -> 300 (TERRAIN_H_MAX).
			if h <= Data.SEA + 1 or h > 300:
				continue
			var cx2 := int(floorf(float(x) / 16.0))
			var cz2 := int(floorf(float(z) / 16.0))
			var gkey := "%d,%d" % [cx2, cz2]
			if not gen_cache.has(gkey):
				gen_cache[gkey] = WorldGen.generate(cx2, cz2, seed)
			var topb: int = gen_cache[gkey][(h << 8) | ((z & 15) << 4) | (x & 15)]
			if topb != want_top:
				continue
			var flat := true
			for dz in range(-1, 2):
				for dx in range(-1, 2):
					if WorldGen.terrain_height(x + dx, z + dz, seed) != h:
						flat = false
			if flat:
				return {"x": x, "z": z, "y": h}
	return null


func _tint_find_water(seed: int):
	for z in range(-160, 161, 2):
		for x in range(-160, 161, 2):
			if WorldGen.terrain_height(x, z, seed) >= Data.SEA:
				continue
			var flat := true
			for dz in range(-1, 2):
				for dx in range(-1, 2):
					if WorldGen.terrain_height(x + dx, z + dz, seed) >= Data.SEA:
						flat = false
			if flat:
				return {"x": x, "z": z, "y": Data.SEA}
	return null


func _tint_wait_built(tcx: int, tcz: int, max_frames: int) -> bool:
	var frames := 0
	while frames < max_frames:
		var all := true
		for key in world.chunks:
			var c: Node3D = world.chunks[key]
			if absi(int(c.cx) - tcx) <= world.render_radius and absi(int(c.cz) - tcz) <= world.render_radius:
				if not c.mesh_built:
					all = false
					break
		if all:
			return true
		await get_tree().physics_frame
		frames += 1
	return false


func _tint_vertex(c: Node3D, cell: Dictionary, fluid: bool):
	if c == null:
		return null
	var lx := int(cell["x"]) - int(c.cx) * 16
	var lz := int(cell["z"]) - int(c.cz) * 16
	var yv := float(int(cell["y"])) + (0.875 if fluid else 1.0)
	var want: Array = [[lx, lz], [lx + 1, lz], [lx + 1, lz + 1], [lx, lz + 1]]
	for s in c.slabs:
		var inst = s.fluid_instance if fluid else s.mesh_instance
		if inst == null or inst.mesh == null:
			continue
		var mesh: ArrayMesh = inst.mesh
		for si in range(mesh.get_surface_count()):
			var arrs = mesh.surface_get_arrays(si)
			var vs: PackedVector3Array = arrs[Mesh.ARRAY_VERTEX]
			var cs: PackedColorArray = arrs[Mesh.ARRAY_COLOR]
			for i in range(vs.size() - 3):
				if absf(vs[i].y - yv) > 0.01:
					continue
				var okq := true
				var seen := {}
				for j in range(4):
					var vi: Vector3 = vs[i + j]
					var key := -1
					for w in want:
						if absf(vi.x - float(w[0])) < 0.01 and absf(vi.z - float(w[1])) < 0.01 and absf(vi.y - yv) < 0.01:
							key = w[0] * 1000 + w[1]
							break
					if key < 0 or seen.has(key) or not cs[i + j].is_equal_approx(cs[i]):
						okq = false
						break
					seen[key] = true
				if okq and seen.size() == 4:
					return [roundf(cs[i].r * 255.0), roundf(cs[i].g * 255.0), roundf(cs[i].b * 255.0)]
	return null


func _tint_close(got: Array, exp: Array) -> bool:
	for i in range(3):
		if absf(float(got[i]) - float(exp[i])) > 1.5:
			return false
	return true


func _tint_neutral(got: Array) -> bool:
	return absf(float(got[0]) - float(got[1])) <= 1.5 and absf(float(got[1]) - float(got[2])) <= 1.5 and float(got[0]) >= 200.0


func _water_in_box(keys: Array, x0: int, x1: int, y0: int, y1: int, z0: int, z1: int) -> int:
	var n := 0
	for key in keys:
		var c: Node3D = world.chunks.get(key)
		if c == null:
			continue
		var data: PackedByteArray = c.flat_data()
		for i in range(data.size()):
			if data[i] != 5:
				continue
			var yy: int = i >> 8
			if yy < y0 or yy > y1:
				continue
			var xx: int = int(c.cx) * 16 + (i & 15)
			if xx < x0 or xx > x1:
				continue
			var zz: int = int(c.cz) * 16 + ((i >> 4) & 15)
			if zz < z0 or zz > z1:
				continue
			n += 1
	return n


func _sea_solid_backed(keys: Array) -> int:
	var n := 0
	var y: int = Data.SEA
	if y < 1:
		return 0
	var ib := (y - 1) << 8
	var ia := y << 8
	for key in keys:
		var c: Node3D = world.chunks.get(key)
		if c == null or c.data.is_empty():
			continue
		var data: PackedByteArray = c.flat_data()
		for lz in range(16):
			var lb: int = lz << 4
			for lx in range(16):
				var i := ia | lb | lx
				if data[i] != 5:
					continue
				var below: int = data[ib | lb | lx]
				if below == 0 or world.is_fluid_id(below):
					continue
				n += 1
	return n


func _water_at_level(keys: Array, y: int) -> int:
	var n := 0
	for key in keys:
		var c: Node3D = world.chunks.get(key)
		if c == null:
			continue
		var data: PackedByteArray = c.flat_data()
		for i in range(data.size()):
			if (i >> 8) == y and data[i] == 5:
				n += 1
	return n


func _count_fluid_cells(keys: Array, id: int) -> int:
	var n := 0
	for key in keys:
		var c: Node3D = world.chunks.get(key)
		if c == null:
			continue
		var data: PackedByteArray = c.flat_data()
		for i in range(data.size()):
			if data[i] == id:
				n += 1
	return n


func _fluidsettle_test() -> void:
	var keys: Array = world.chunks.keys()
	var prev_w := _count_fluid_cells(keys, 5)
	var quiet := 0
	var i := 0
	var nmax := 400
	var hard := OS.get_environment("AWECRAFT_SETTLE_TICKS") != ""
	if hard:
		nmax = OS.get_environment("AWECRAFT_SETTLE_TICKS").to_int()
	while i < nmax:
		i += 1
		Debug.tick_fluids()
		var w := _count_fluid_cells(keys, 5)
		if w == prev_w:
			quiet += 1
		else:
			quiet = 0
		prev_w = w
		if not hard and quiet >= 3:
			break
	Debug.result({"ticks_to_settle": i, "quiet": quiet, "water_final": prev_w, "chunk_count": world.chunks.size()})
	get_tree().quit()


func _is_solid(x: int, y: int, z: int) -> bool:
	if y < 0 or y >= Data.HEIGHT:
		return false
	var info = Data.block(world.get_block(x, y, z))
	return info != null and bool(info.solid) and not bool(info.cross)


func _tref_tree_at(x: int, z: int, seed: int) -> int:
	var h := WorldGen.terrain_height(x, z, seed)
	if h <= Data.SEA + 1:
		return -1
	var d := 0.0
	var b := WorldGen.biome_at(x, z, seed)
	if b == "forest":
		d = 0.14
	elif b == "plains":
		d = 0.02
	elif b == "snow":
		d = 0.02
	if d <= 0.0:
		return -1
	if AweNoise.hash2i(x, z, seed + 55) >= d:
		return -1
	return h


func _trees_ref_flora(d: PackedByteArray, cx: int, cz: int, seed: int, trees: Dictionary, flowers: Dictionary) -> void:
	var hmax := Data.HEIGHT
	var bx := cx * 16
	var bz := cz * 16
	var tz := bz - 2
	while tz < bz + 18:
		var tx := bx - 2
		while tx < bx + 18:
			var h := _tref_tree_at(tx, tz, seed)
			if h >= 0:
				var glx := tx - bx
				var glz := tz - bz
				var skip := false
				if glx >= 0 and glx < 16 and glz >= 0 and glz < 16:
					var gb: int = d[(h << 8) | (glz << 4) | glx]
					if gb == 0 or gb == 5 or gb == 24:
						skip = true
					else:
						var gi = Data.block(gb)
						if gi == null or not bool(gi.solid):
							skip = true
				if not skip:
					var th := 4 + int(AweNoise.hash2i(tx, tz, seed + 66) * 3.0)
					trees["%d,%d" % [tx, tz]] = th
					var dy := 1
					while dy <= th:
						WorldGen._putc(d, tx, h + dy, tz, 6, bx, bz, hmax)
						dy += 1
					var ly := th - 1
					while ly <= th + 2:
						var rad := 1 if ly >= th + 1 else 2
						var dx := -rad
						while dx <= rad:
							var dz := -rad
							while dz <= rad:
								var sk := false
								if rad == 2 and absi(dx) == 2 and absi(dz) == 2:
									sk = true
								if ly == th + 2 and absi(dx) == 1 and absi(dz) == 1:
									sk = true
								if not sk:
											WorldGen._putc(d, tx + dx, h + ly, tz + dz, 7, bx, bz, hmax)
								dz += 1
							dx += 1
						ly += 1
			tx += 1
		tz += 1
	var lz := 0
	while lz < 16:
		var lx := 0
		while lx < 16:
			var x := bx + lx
			var z := bz + lz
			var h := WorldGen.terrain_height(x, z, seed)
			if h > Data.SEA and h < hmax - 2:
				var top: int = d[(h << 8) | (lz << 4) | lx]
				if top == 1 and AweNoise.hash2i(x, z, seed + 777) < 0.02:
					var fid := 18 if AweNoise.hash2i(x, z, seed + 778) < 0.5 else 19
					d[((h + 1) << 8) | (lz << 4) | lx] = fid
					flowers["%d,%d" % [x, z]] = fid
			lx += 1
		lz += 1


func _rget(dicts: Dictionary, x: int, y: int, z: int) -> int:
	if y < 0 or y >= Data.HEIGHT:
		return 0
	var key := "%d,%d" % [int(floorf(float(x) / 16.0)), int(floorf(float(z) / 16.0))]
	var dd = dicts.get(key)
	if dd == null:
		return -999
	return int(dd[(y << 8) | ((z & 15) << 4) | (x & 15)])


func _trees_md5(d: PackedByteArray) -> String:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_MD5)
	h.update(d)
	var md5: PackedByteArray = h.finish()
	var hx := ""
	for i in range(8):
		hx += "%02x" % md5[i]
	return hx


func _trees_test() -> void:
	var seed := Game.world_seed
	var radc := 1
	var out := {}
	var ok := true
	var per_chunk := {}
	var ref_data := {}
	var ref_trees := {}
	var ref_flowers := {}
	var cx := -radc
	while cx <= radc:
		var cz := -radc
		while cz <= radc:
			var key := "%d,%d" % [cx, cz]
			var d := WorldGen.generate(cx, cz, seed)
			var dref := d.duplicate()
			for i in range(dref.size()):
				var bv: int = dref[i]
				if bv == 6 or bv == 7 or bv == 18 or bv == 19:
					dref[i] = 0
			var cnt := {"log": 0, "leaf": 0, "rose": 0, "dan": 0}
			for i in range(d.size()):
				var v: int = d[i]
				if v == 6:
					cnt["log"] += 1
				elif v == 7:
					cnt["leaf"] += 1
				elif v == 18:
					cnt["rose"] += 1
				elif v == 19:
					cnt["dan"] += 1
			_trees_ref_flora(dref, cx, cz, seed, ref_trees, ref_flowers)
			var rcnt := {"log": 0, "leaf": 0, "rose": 0, "dan": 0}
			for i in range(dref.size()):
				var v: int = dref[i]
				if v == 6:
					rcnt["log"] += 1
				elif v == 7:
					rcnt["leaf"] += 1
				elif v == 18:
					rcnt["rose"] += 1
				elif v == 19:
					rcnt["dan"] += 1
			ref_data[key] = dref
			per_chunk[key] = {"act": cnt, "ref": rcnt, "match": cnt == rcnt}
			if cnt != rcnt:
				ok = false
			cz += 1
		cx += 1
	var npath := "/home/angrygiant/github_projects/AweCraft/.scratch/trees_expect_%d.json" % seed
	if FileAccess.file_exists(npath):
		var nf := FileAccess.open(npath, FileAccess.READ)
		var nj = JSON.parse_string(nf.get_as_text())
		nf.close()
		if nj is Dictionary:
			var ncnts: Dictionary = nj.get("counts", {})
			var nc_ok := true
			for key in per_chunk:
				var nc = ncnts.get(key)
				var actv: Dictionary = per_chunk[key]["act"]
				var same: bool = nc != null and nc.size() == actv.size()
				if same:
					for fk in actv:
						if not nc.has(fk) or float(int(nc[fk])) != float(int(actv[fk])):
							same = false
							break
				if not same:
					nc_ok = false
					print("NCDBG key=", key, " act=", JSON.stringify(actv), " json=", JSON.stringify(nc))
			var ntrees: Dictionary = nj.get("trees", {})
			var nt_ok := ntrees.size() == ref_trees.size()
			if nt_ok:
				for tk in ref_trees:
					if not ntrees.has(tk) or int(ntrees[tk]) != int(ref_trees[tk]):
						nt_ok = false
						break
			var nflowers: Dictionary = nj.get("flowers", {})
			var nf_ok := nflowers.size() == ref_flowers.size()
			if nf_ok:
				for fk in ref_flowers:
					if not nflowers.has(fk) or int(nflowers[fk]) != int(ref_flowers[fk]):
						nf_ok = false
						break
			out["node_count_ok"] = nc_ok
			out["node_trees_ok"] = nt_ok
			out["node_flowers_ok"] = nf_ok
			ok = ok and nc_ok and nt_ok and nf_ok
		else:
			out["node_error"] = "bad_json"
			ok = false
	else:
		out["node_error"] = "no_file"
	var desert_checked := -1
	var desert_ok := true
	for z in range(-64, 65, 4):
		if desert_checked > 0:
			break
		for x in range(-64, 65, 4):
			if WorldGen.biome_at(x, z, seed) != "desert":
				continue
			var hd := WorldGen.terrain_height(x, z, seed)
			# AC-0091: grassland band top remapped 40 -> 152 (= 2.6*40+48).
			if hd <= Data.SEA + 1 or hd > 152:
				continue
			desert_checked = hd
			if _rget(ref_data, x, hd + 1, z) == 6:
				desert_ok = false
			for yy in range(1, 9):
				var cv: int = _rget(ref_data, x, hd + yy, z)
				if cv == 18 or cv == 19:
					desert_ok = false
			break
	out["desert_checked"] = desert_checked
	out["desert_no_flora"] = desert_ok
	ok = ok and desert_ok
	var samples := []
	var th_seen := {}
	for tk in ref_trees:
		if th_seen.size() >= 3:
			break
		var thv: int = int(ref_trees[tk])
		if th_seen.has(thv):
			continue
		var parts: PackedStringArray = String(tk).split(",")
		var txi := int(parts[0])
		var tzi := int(parts[1])
		if txi < -16 or txi > 15 or tzi < -16 or tzi > 15:
			continue
		var hh := _tref_tree_at(txi, tzi, seed)
		var tcell = _tref_tree_cells(txi, tzi, hh, thv, ref_data)
		samples.append({"at": [txi, tzi], "h": hh, "th": thv, "ok": tcell["ok"], "fails": tcell["fails"]})
		if not tcell["ok"]:
			ok = false
		th_seen[thv] = true
	out["tree_samples"] = samples
	var fsamples := []
	var fid_seen := {}
	for fk in ref_flowers:
		if fid_seen.size() >= 2:
			break
		var fidv: int = int(ref_flowers[fk])
		if fid_seen.has(fidv):
			continue
		fid_seen[fidv] = true
		var fparts: PackedStringArray = String(fk).split(",")
		var fx := int(fparts[0])
		var fz := int(fparts[1])
		var fh := WorldGen.terrain_height(fx, fz, seed)
		var fcell = {
			"cell": _rget(ref_data, fx, fh + 1, fz),
			"ground": _rget(ref_data, fx, fh, fz),
			"above": _rget(ref_data, fx, fh + 2, fz),
		}
		var fok: bool = int(fcell["cell"]) == fidv and int(fcell["ground"]) == 1 and int(fcell["above"]) == 0
		fsamples.append({"at": [fx, fz], "want": fidv, "cell": fcell, "ok": fok})
		if not fok:
			ok = false
	out["flower_samples"] = fsamples
	var a1 := WorldGen.generate(0, 0, seed)
	var a2 := WorldGen.generate(0, 0, seed)
	var a3 := WorldGen.generate(-1, 2, seed)
	var a4 := WorldGen.generate(-1, 2, seed)
	out["determinism"] = (a1 == a2) and (a3 == a4)
	ok = ok and out["determinism"]
	var blpath := "/home/angrygiant/github_projects/AweCraft/.scratch/genhash_before_trees.log"
	var bl := {}
	if FileAccess.file_exists(blpath):
		var bf := FileAccess.open(blpath, FileAccess.READ)
		while not bf.eof_reached():
			var line := bf.get_line()
			if not line.begins_with("GENHASH "):
				continue
			var pp := line.split(" ")
			bl["%s,%s" % [pp[1], pp[2]]] = pp[3]
		bf.close()
	if bl.size() == 25:
		var gh_ok := true
		var gh_fail := ""
		var gx := -2
		while gx <= 2:
			var gz := -2
			while gz <= 2:
				var dd2 := WorldGen.generate(gx, gz, seed).duplicate()
				for i in range(dd2.size()):
					var vv: int = dd2[i]
					if vv == 6 or vv == 7 or vv == 18 or vv == 19:
						dd2[i] = 0
				var key2 := "%d,%d" % [gx, gz]
				if bl[key2] != _trees_md5(dd2):
					gh_ok = false
					gh_fail = key2
				gz += 1
			gx += 1
		out["genhash_gate"] = gh_ok
		if gh_fail != "":
			out["genhash_fail"] = gh_fail
		ok = ok and gh_ok
	else:
		out["genhash_gate"] = null
	print("TREES stat trees=%d flowers=%d rose=%d dan=%d" % [ref_trees.size(), ref_flowers.size(), _tref_count_fid(ref_flowers, 18), _tref_count_fid(ref_flowers, 19)])
	world.collision_enabled = false
	world.render_radius = 1
	world.recenter(8.0, 8.0, true)
	var waited := 0
	while waited < 900:
		var cc = world.chunks.get("0,0")
		if cc != null and cc.mesh_built:
			break
		await get_tree().physics_frame
		waited += 1
	var mesh_info := {}
	var cc0 = world.chunks.get("0,0")
	if cc0 != null and cc0.mesh_built:
		var d0: PackedByteArray = cc0.flat_data()
		var nleaf := 0
		var nflower := 0
		for i in range(d0.size()):
			var v: int = d0[i]
			if v == 7:
				nleaf += 1
			elif v == 18 or v == 19:
				nflower += 1
		var ops := 0
		var cv_sum := 0
		var fv_sum := 0
		var has_flora := false
		for s in cc0.slabs:
			if s.mesh_instance and s.mesh_instance.mesh:
				ops += s.mesh_instance.mesh.get_surface_count()
			if s.flora_instance == null or s.flora_instance.mesh == null:
				continue
			has_flora = true
			var fm: ArrayMesh = s.flora_instance.mesh
			var fs: PackedInt32Array = s.fsidx
			if fs.size() >= 2 and fs[0] >= 0:
				cv_sum += (fm.surface_get_arrays(fs[0])[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			if fs.size() >= 2 and fs[1] >= 0:
				fv_sum += (fm.surface_get_arrays(fs[1])[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		var flower_v := -1
		var cutout_v := -1
		if nleaf > 0 or nflower > 0:
			if not has_flora:
				mesh_info = {"error": "no_flora_instance", "nleaf": nleaf, "nflower": nflower}
			else:
				cutout_v = cv_sum
				flower_v = fv_sum
				if nleaf == 0 and nflower > 0:
					cutout_v = -1
				mesh_info = {"opaque_surfaces": ops, "cutout_verts": cutout_v, "flower_verts": flower_v, "nleaf": nleaf, "nflower": nflower}
				if nflower > 0:
					ok = ok and flower_v == nflower * 8
				if nleaf > 0:
					ok = ok and cutout_v > 0 and cutout_v % 4 == 0
	else:
		mesh_info = {"error": "chunk_not_built"}
	out["mesh"] = mesh_info
	Debug.result({"ok": ok, "data": out, "per_chunk": per_chunk})
	get_tree().quit()


func _tref_count_fid(fl: Dictionary, fid: int) -> int:
	var n := 0
	for k in fl:
		if int(fl[k]) == fid:
			n += 1
	return n


func _tref_tree_cells(x: int, z: int, h: int, th: int, dicts: Dictionary) -> Dictionary:
	var out := {"ok": true, "fails": []}
	var checks: Array = [
		[h + 1, 6, "trunk_base"],
		[h + th, -6, "trunk_top"],
		[h + th + 3, 0, "above_canopy"],
		[h + th + 2, 7, "canopy_top_center"],
	]
	for ck in checks:
		var got := _rget(dicts, x, int(ck[0]), z)
		var exp := int(ck[1])
		var cok := true
		if exp < 0:
			cok = int(got) == -exp or int(got) == 7
		else:
			cok = int(got) == exp
		if not cok:
			out["ok"] = false
			out["fails"].append(ck[2] + "=" + str(got))
	var corners: Array = [
		[1, h + th + 2, 1, 0],
		[2, h + th - 1, 0, 7],
		[2, h + th - 1, 2, 0],
		[2, h + th, 1, 7],
		[2, h + th + 1, 0, 0],
	]
	for ck in corners:
		var got := _rget(dicts, x + int(ck[0]), int(ck[1]), z + int(ck[2]))
		if got != int(ck[3]):
			out["ok"] = false
			out["fails"].append("%d,%d,%d=%d" % [ck[0], ck[1], ck[2], got])
	return out
# AC-0143 probe (env-gated by AWECRAFT_LOGIC=sphere, harness-only, never
# runs in game): runtime gate for core/sphere_math.gd.
# (1) gapless shared edges: both faces of every _EDGES segment agree
#     within 1e-9*R; dyadic samples (k/8) are bitwise-identical (counted;
#     the two 0.5-offset segments may differ by ~1 ulp on non-dyadic t).
# (2) world_to_face: face == face_for_dir, (u,v) in [0,1]^2, round-trip
#     within 1e-6*R.
# (3) neighbor_key: 12 edges x 5 cells + 8 corner cells x 4 dirs —
#     deterministic, table face B, edge-adjacent line, A->B->A within
#     +/-1 cell, corners stay at the corner.
# (4) home face (face 0) = AC-0091 flat world identity.
func _sphere_test(spawn: Vector3) -> void:
	var out := {}
	var ok := true
	var R := 4000.0
	var N := SphereMath.CELLS_PER_FACE
	# --- (1) gapless shared edges: dual-face direct (u,v) evaluation ---
	var n1 := 0
	var max_d1 := 0.0
	var bit_exact1 := 0
	for f in 12:
		for e in 4:
			var segs: Array = SphereMath._EDGES[f][e]
			for seg in segs:
				var tlo: float = float(seg[0])
				var span: float = float(seg[1]) - tlo
				# 8 dyadic samples (k/8, exact in float) + 9 non-dyadic (j/9).
				for k in 17:
					var t: float
					if k < 8:
						t = tlo + span * (float(k) / 8.0)
					else:
						t = tlo + span * (float(k - 8) / 9.0)
					var uA: float
					var vA: float
					if e == 0:
						uA = 1.0
						vA = t
					elif e == 1:
						uA = 0.0
						vA = t
					elif e == 2:
						uA = t
						vA = 1.0
					else:
						uA = t
						vA = 0.0
					var B: int = int(seg[2])
					var eB: int = int(seg[3])
					var s: float = float(seg[4]) + float(seg[5]) * t
					var uB: float
					var vB: float
					if eB == 0:
						uB = 1.0
						vB = s
					elif eB == 1:
						uB = 0.0
						vB = s
					elif eB == 2:
						uB = s
						vB = 1.0
					else:
						uB = s
						vB = 0.0
					var pA: Vector3 = SphereMath.uv_to_world(f, uA, vA, R)
					var pB: Vector3 = SphereMath.uv_to_world(B, uB, vB, R)
					n1 += 1
					var d1: float = maxf(maxf(absf(pA.x - pB.x), absf(pA.y - pB.y)), absf(pA.z - pB.z))
					if d1 > max_d1:
						max_d1 = d1
					if pA == pB:
						bit_exact1 += 1
					if d1 > 1e-9 * R:
						ok = false
						out["edge_fail"] = [f, e, k, B, [pA.x, pA.y, pA.z], [pB.x, pB.y, pB.z]]
	out["edge_samples"] = n1
	out["edge_max_d"] = max_d1
	out["edge_bitwise"] = bit_exact1
	# --- (2) world_to_face: face / range / round-trip ---
	var n2 := 0
	var max_d2 := 0.0
	var gvs: Array = [0.0, 0.25, 0.5, 0.75, 1.0]
	for f in 12:
		for u in gvs:
			for v in gvs:
				var p: Vector3 = SphereMath.uv_to_world(f, float(u), float(v), R)
				var r: Dictionary = SphereMath.world_to_face(p, R)
				var rf: int = int(r["face"])
				n2 += 1
				if rf != SphereMath.face_for_dir(p.normalized()):
					ok = false
					out["wtf_face_fail"] = [f, u, v, rf]
				var ru: float = float(r["u"])
				var rv: float = float(r["v"])
				if ru < -1e-9 or ru > 1.0 + 1e-9 or rv < -1e-9 or rv > 1.0 + 1e-9:
					ok = false
					out["wtf_range_fail"] = [f, u, v, ru, rv]
				var q: Vector3 = SphereMath.uv_to_world(rf, ru, rv, R)
				var d2: float = (q - p).length()
				if d2 > max_d2:
					max_d2 = d2
				if d2 > 1e-6 * R:
					ok = false
					out["wtf_roundtrip_fail"] = [f, u, v, d2]
	out["wtf_samples"] = n2
	out["wtf_max_d"] = max_d2
	# --- (3) neighbor_key: 12-edge walks + 8 corner walks ---
	var n3 := 0
	var max_rt := 0
	var ec: Array = [1, 256, 511, 768, 1022]
	for f in 12:
		for e in 4:
			var dirA: Vector2i
			if e == 0:
				dirA = Vector2i(1, 0)
			elif e == 1:
				dirA = Vector2i(-1, 0)
			elif e == 2:
				dirA = Vector2i(0, 1)
			else:
				dirA = Vector2i(0, -1)
			for c in ec:
				var cx: int
				var cz: int
				if e == 0:
					cx = N - 1
					cz = c
				elif e == 1:
					cx = 0
					cz = c
				elif e == 2:
					cx = c
					cz = N - 1
				else:
					cx = c
					cz = 0
				var r1: Dictionary = SphereMath.neighbor_key(f, cx, cz, dirA)
				var r1b: Dictionary = SphereMath.neighbor_key(f, cx, cz, dirA)
				n3 += 1
				if r1 != r1b:
					ok = false
					out["nk_nondet"] = [f, e, c]
				var B: int = int(r1["face"])
				var cxB: int = int(r1["cx"])
				var czB: int = int(r1["cz"])
				if B < 0 or B > 11 or cxB < 0 or cxB >= N or czB < 0 or czB >= N:
					ok = false
					out["nk_range"] = [f, e, c, r1]
				# expected landing from the table (same lookup as neighbor_key).
				var t: float = (cz + 0.5) / float(N) if e < 2 else (cx + 0.5) / float(N)
				var segs3: Array = SphereMath._EDGES[f][e]
				var seg3: Array = segs3[segs3.size() - 1]
				for sg in segs3:
					if t < float(sg[1]):
						seg3 = sg
						break
				var eB: int = int(seg3[3])
				if B != int(seg3[2]):
					ok = false
					out["nk_face"] = [f, e, c, B, int(seg3[2])]
				var on_line: bool
				if eB == 0:
					on_line = cxB == N - 1
				elif eB == 1:
					on_line = cxB == 0
				elif eB == 2:
					on_line = czB == N - 1
				else:
					on_line = czB == 0
				if not on_line:
					ok = false
					out["nk_edge"] = [f, e, c, r1, eB]
				var dirB: Vector2i
				if eB == 0:
					dirB = Vector2i(1, 0)
				elif eB == 1:
					dirB = Vector2i(-1, 0)
				elif eB == 2:
					dirB = Vector2i(0, 1)
				else:
					dirB = Vector2i(0, -1)
				var r2: Dictionary = SphereMath.neighbor_key(B, cxB, czB, dirB)
				var df: bool = int(r2["face"]) == f
				var dx: int = absi(int(r2["cx"]) - cx)
				var dy: int = absi(int(r2["cz"]) - cz)
				max_rt = maxi(max_rt, maxi(dx, dy))
				if not df or dx > 1 or dy > 1:
					ok = false
					out["nk_rt"] = [f, e, c, r1, r2]
	# 8 cube corners: owner cell from world_to_face; every step must land
	# within +/-1 cell of the same physical corner.
	var n4 := 0
	var min_dot := 2.0
	for sx in [-1, 1]:
		for sy in [-1, 1]:
			for sz in [-1, 1]:
				var pc: Vector3 = Vector3(float(sx), float(sy), float(sz)).normalized() * R
				var rc: Dictionary = SphereMath.world_to_face(pc, R)
				var fc: int = int(rc["face"])
				var uc: float = float(rc["u"])
				var vc: float = float(rc["v"])
				var cxc: int = 0 if uc < 0.5 else N - 1
				var czc: int = 0 if vc < 0.5 else N - 1
				var dirs4: Array = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
				for dir5 in dirs4:
					var rr: Dictionary = SphereMath.neighbor_key(fc, cxc, czc, dir5)
					n4 += 1
					var fr: int = int(rr["face"])
					var crx: int = int(rr["cx"])
					var crz: int = int(rr["cz"])
					if fr < 0 or fr > 11 or crx < 0 or crx >= N or crz < 0 or crz >= N:
						ok = false
						out["corner_range"] = [sx, sy, sz, [dir5.x, dir5.y], rr]
					var wc: Vector3 = SphereMath.uv_to_world(fr, (float(crx) + 0.5) / float(N), (float(crz) + 0.5) / float(N), R)
					var dot: float = wc.normalized().dot(pc.normalized())
					if dot < min_dot:
						min_dot = dot
					if dot < 0.999:
						ok = false
						out["corner_off"] = [sx, sy, sz, [dir5.x, dir5.y], rr, dot]
	out["nk_samples"] = n3
	out["nk_roundtrip_max"] = max_rt
	out["corner_samples"] = n4
	out["corner_min_dot"] = min_dot
	# --- (4) home face (face 0) = AC-0091 flat world identity ---
	var bx := int(WorldGen.SPAWN_X)
	var bz := int(WorldGen.SPAWN_Z)
	# sea surface at Data.SEA in the nearest ocean column (basis-probe method).
	var ox := -1
	var oz := -1
	var best := 1 << 30
	for z2 in range(-64, 65, 8):
		for x2 in range(-64, 65, 8):
			if WorldGen.terrain_height(x2, z2, Game.world_seed) < Data.SEA:
				var dd := absi(x2 - bx) + absi(z2 - bz)
				if dd < best:
					best = dd
					ox = x2
					oz = z2
	if ox < 0:
		out["home_sea_ok"] = false
		ok = false
	else:
		world.recenter(float(ox), float(oz), false)
		await _await_core_3x3(Vector3(float(ox), 0.0, float(oz)), 3000)
		var sw: int = world.get_block(ox, Data.SEA, oz)
		var swa: int = world.get_block(ox, Data.SEA + 1, oz)
		out["home_sea_at"] = [ox, oz]
		out["home_sea_cell"] = sw
		out["home_sea_ok"] = sw == WorldGen.B_WATER and swa == 0
		ok = ok and out["home_sea_ok"]
		world.recenter(float(bx), float(bz), false)
		await _await_core_3x3(Vector3(float(bx), 0.0, float(bz)), 3000)
	# spawn column (spawn chunk sync-generated at boot, AC-0119).
	var bed: int = world.get_block(bx, 0, bz)
	var top: int = world.surface_top(bx, bz)
	var sb: int = world.get_block(bx, top, bz)
	var sab: int = world.get_block(bx, top + 1, bz)
	out["home_bedrock_y0"] = bed
	out["home_spawn_top"] = top
	out["home_bedrock_ok"] = bed == WorldGen.B_BEDROCK
	out["home_spawn_top_ok"] = top == WorldGen.SPAWN_H
	out["home_spawn_solid"] = bool(Data.block(sb).solid)
	out["home_spawn_above_air"] = sab == 0
	# --- (5) world keying (M3): (face,cx,cz) resolver + storage round-trip ---
	var n5 := 0
	var bad5 := 0
	var max_cx5 := 0
	var max_cz5 := 0
	var cells5: Array = [1, 256, 511, 768, 1022]
	for face5 in 12:
		for edge5 in 4:
			for cell5 in cells5:
				# cell adjacent to the edge: edge axis fixed at its boundary
				# cell center, other axis at (cell5+0.5)/N.
				var ua5: float = 0.5
				var va5: float = 0.5
				var t5: float = (float(cell5) + 0.5) / float(N)
				if edge5 == 0:
					ua5 = (float(N) - 0.5) / float(N)
					va5 = t5
				elif edge5 == 1:
					ua5 = 0.5 / float(N)
					va5 = t5
				elif edge5 == 2:
					ua5 = t5
					va5 = (float(N) - 0.5) / float(N)
				else:
					ua5 = t5
					va5 = 0.5 / float(N)
				var P5: Vector3 = SphereMath.uv_to_world(face5, ua5, va5, R)
				var k5: Dictionary = world.key_for_sphere_pos(P5, R)
				var k5b: Dictionary = world.key_for_sphere_pos(P5, R)
				if k5 != k5b:
					bad5 += 1
				var f5: int = int(k5["face"])
				var ax5: int = int(k5["cx"])
				var az5: int = int(k5["cz"])
				var inrange5 := false
				if f5 >= 0 and f5 <= 11:
					if f5 == 0 or f5 == 1:
						inrange5 = absi(ax5) <= int(R) + 1 and absi(az5) <= int(R) + 1
					else:
						inrange5 = ax5 >= 0 and ax5 < N and az5 >= 0 and az5 < N
				if not inrange5:
					bad5 += 1
					n5 += 1
					continue
				max_cx5 = maxi(max_cx5, absi(ax5))
				max_cz5 = maxi(max_cz5, absi(az5))
				if f5 == 0 or f5 == 1:
					var ccx5: int = int(floorf(float(ax5) / 16.0))
					var ccz5: int = int(floorf(float(az5) / 16.0))
					var kkey5: String = "%d,%d" % [ccx5, ccz5]
					if not world.chunks.has(kkey5):
						world.create_chunk(ccx5, ccz5, false)
				var pre5: int = world.get_block_key(f5, ax5, az5, 10)
				world.set_block_key(f5, ax5, az5, 10, 250)
				var post5: int = world.get_block_key(f5, ax5, az5, 10)
				if post5 != 250 or pre5 == 250:
					bad5 += 1
				n5 += 1
	# (5b) home identity: key API == flat API on home-pair columns
	# (face 0 = x >= 0 half, face 1 = x < 0 half); the face-center sphere
	# position resolves to the flat origin.
	var home5 := true
	for yy5 in [0, 11, Data.SEA, WorldGen.SPAWN_H]:
		if world.get_block_key(0, 8, 8, yy5) != world.get_block(8, yy5, 8):
			home5 = false
		if world.get_block_key(1, -8, 8, yy5) != world.get_block(-8, yy5, 8):
			home5 = false
	var kc5: Dictionary = world.key_for_sphere_pos(Vector3(0.0, R, 0.0), R)
	if int(kc5["face"]) != 0 or int(kc5["cx"]) != 0 or int(kc5["cz"]) != 0:
		home5 = false
	out["key_n"] = n5
	out["key_bad"] = bad5
	out["key_max_cx"] = max_cx5
	out["key_max_cz"] = max_cz5
	out["key_home_ok"] = home5
	ok = ok and bad5 == 0 and home5
	ok = ok and out["home_bedrock_ok"] and out["home_spawn_top_ok"] and out["home_spawn_solid"] and out["home_spawn_above_air"]
	out["ok"] = ok
	Debug.result(out)


func _occl_stab() -> PackedByteArray:
	var stab := PackedByteArray()
	stab.resize(256)
	for bi in range(256):
		var b = Data.block(bi)
		if b != null and bool(b.solid) and not bool(b.cross):
			stab[bi] = 1
	return stab


func _occl_blk(wx: int, y: int, wz: int, c: Node3D, d: PackedByteArray) -> int:
	var lx := wx - int(c.cx) * 16
	var lz := wz - int(c.cz) * 16
	if lx >= 0 and lx < 16 and lz >= 0 and lz < 16:
		return int(d[(y << 8) | (lz << 4) | lx])
	return int(world.get_block(wx, y, wz))


func _occl_built_chunks(r: int) -> Array:
	var out: Array = []
	for key in world.chunks:
		var c: Node3D = world.chunks[key]
		if absi(int(c.cx)) <= r and absi(int(c.cz)) <= r and c.mesh_built:
			out.append(c)
	return out


func _occl_chunk_stats(c: Node3D, stab: PackedByteArray) -> Dictionary:
	var d: PackedByteArray = c.flat_data()
	var slab_ns: Array = []
	for i in range(Data.HEIGHT / 16):
		slab_ns.append(0)
	var srf := PackedInt32Array()
	srf.resize(256)
	for i in range(256):
		srf[i] = -1
	var interior := 0
	var cxw := int(c.cx) * 16
	var czw := int(c.cz) * 16
	for y in range(Data.HEIGHT):
		for lz in range(16):
			for lx in range(16):
				var idx := (y << 8) | (lz << 4) | lx
				var bid := int(d[idx])
				if stab[bid] == 0:
					slab_ns[y >> 4] += 1
					continue
				srf[lz * 16 + lx] = y
				if y == 0 or y == Data.HEIGHT - 1:
					continue
				var wx := cxw + lx
				var wz := czw + lz
				if stab[_occl_blk(wx, y - 1, wz, c, d)] == 0:
					continue
				if stab[_occl_blk(wx, y + 1, wz, c, d)] == 0:
					continue
				if stab[_occl_blk(wx - 1, y, wz, c, d)] == 0:
					continue
				if stab[_occl_blk(wx + 1, y, wz, c, d)] == 0:
					continue
				if stab[_occl_blk(wx, y, wz - 1, c, d)] == 0:
					continue
				if stab[_occl_blk(wx, y, wz + 1, c, d)] == 0:
					continue
				interior += 1
	return {"slab_ns": slab_ns, "srf": srf, "interior": interior}


func _occl_is_interior(wx: int, y: int, wz: int, stab: PackedByteArray) -> bool:
	if y <= 0 or y >= Data.HEIGHT - 1:
		return false
	if stab[int(world.get_block(wx, y - 1, wz))] == 0:
		return false
	if stab[int(world.get_block(wx, y + 1, wz))] == 0:
		return false
	if stab[int(world.get_block(wx - 1, y, wz))] == 0:
		return false
	if stab[int(world.get_block(wx + 1, y, wz))] == 0:
		return false
	if stab[int(world.get_block(wx, y, wz - 1))] == 0:
		return false
	if stab[int(world.get_block(wx, y, wz + 1))] == 0:
		return false
	return true


func _occl_cave_seed(c: Node3D, srf: PackedInt32Array, stab: PackedByteArray) -> Array:
	var r1: Array = _occl_cave_seed_range(c, srf, stab, 80, 260)
	if not r1.is_empty():
		return r1
	return _occl_cave_seed_range(c, srf, stab, 1, Data.HEIGHT - 2)


func _occl_cave_seed_range(c: Node3D, srf: PackedInt32Array, stab: PackedByteArray, ylo: int, yhi: int) -> Array:
	var d: PackedByteArray = c.flat_data()
	var cxw := int(c.cx) * 16
	var czw := int(c.cz) * 16
	for y in range(ylo, yhi + 1):
		for lz in range(16):
			for lx in range(16):
				var col := lz * 16 + lx
				if y > int(srf[col]) - 2:
					continue
				var idx := (y << 8) | (lz << 4) | lx
				if int(d[idx]) != 0:
					continue
				var wx := cxw + lx
				var wz := czw + lz
				var sn := 0
				if stab[_occl_blk(wx, y - 1, wz, c, d)] > 0:
					sn += 1
				if stab[_occl_blk(wx, y + 1, wz, c, d)] > 0:
					sn += 1
				if stab[_occl_blk(wx - 1, y, wz, c, d)] > 0:
					sn += 1
				if stab[_occl_blk(wx + 1, y, wz, c, d)] > 0:
					sn += 1
				if stab[_occl_blk(wx, y, wz - 1, c, d)] > 0:
					sn += 1
				if stab[_occl_blk(wx, y, wz + 1, c, d)] > 0:
					sn += 1
				if sn >= 4 and _occl_has_roof(wx, y, wz, stab):
					return [int(c.cx), int(c.cz), lx, y, lz]
	return []


func _occl_has_roof(wx: int, y: int, wz: int, stab: PackedByteArray) -> bool:
	for yy in range(y + 1, Data.HEIGHT):
		var cid: int = int(world.get_block(wx, yy, wz))
		if stab[cid] > 0:
			return true
	return false


func _occl_flood(seed: Array, stab: PackedByteArray, cap: int, region: int) -> Dictionary:
	var start := Vector3i(int(seed[0]) * 16 + int(seed[2]), int(seed[3]), int(seed[1]) * 16 + int(seed[4]))
	var visited := {start: true}
	var q: Array = [start]
	var head := 0
	var minx := start.x
	var miny := start.y
	var minz := start.z
	var maxx := start.x
	var maxy := start.y
	var maxz := start.z
	var dirs := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
	var open := false
	var colh := {}
	while head < q.size() and q.size() < cap:
		var p: Vector3i = q[head]
		head += 1
		for dd in dirs:
			var n: Vector3i = p + dd
			if n.y < 0 or n.y >= Data.HEIGHT:
				continue
			var nxc := int(floorf(float(n.x) / 16.0))
			var nzc := int(floorf(float(n.z) / 16.0))
			if nxc < -region or nxc > region or nzc < -region or nzc > region:
				continue
			if visited.has(n):
				continue
			if int(world.get_block(n.x, n.y, n.z)) != 0:
				continue
			visited[n] = true
			q.append(n)
			if n.x < minx:
				minx = n.x
			if n.y < miny:
				miny = n.y
			if n.z < minz:
				minz = n.z
			if n.x > maxx:
				maxx = n.x
			if n.y > maxy:
				maxy = n.y
			if n.z > maxz:
				maxz = n.z
			if not open:
				var ck := n.x * 100000 + n.z
				var th: int = int(colh.get(ck, -1))
				if th < 0:
					th = WorldGen.terrain_height(n.x, n.z, Game.world_seed)
					colh[ck] = th
				if n.y >= th:
					open = true
	return {"cells": q.size(), "aabb_min": [minx, miny, minz], "aabb_max": [maxx, maxy, maxz], "open": open}


func _occl_flat(a: Array, eps: float) -> bool:
	var m := float(a[0])
	for v in a:
		if absf(float(v) - m) > eps:
			return false
	return true


func _occl_quad_audit(chunks: Array, stab: PackedByteArray, col_surf: Dictionary) -> Dictionary:
	var total_verts := 0
	var total_faces := 0
	var verts_mesh := 0
	var verts_fluid := 0
	var verts_flora := 0
	var underground_verts := 0
	var underground_faces := 0
	var leaking_cells := 0
	var leaking_faces := 0
	var no_emitter := 0
	var eps := 0.001
	for c in chunks:
		var cx := int(c.cx)
		var cz := int(c.cz)
		var cxw := cx * 16
		var czw := cz * 16
		for s in c.slabs:
			var insts: Array = [s.mesh_instance, s.fluid_instance, s.flora_instance]
			var itype := 0
			for inst in insts:
				itype += 1
				if inst == null or inst.mesh == null:
					continue
				for su in inst.mesh.get_surface_count():
					var arrs: Array = inst.mesh.surface_get_arrays(su)
					var verts: PackedVector3Array = arrs[Mesh.ARRAY_VERTEX]
					total_verts += verts.size()
					if itype == 1:
						verts_mesh += verts.size()
					elif itype == 2:
						verts_fluid += verts.size()
					else:
						verts_flora += verts.size()
					var nq := verts.size() / 4
					total_faces += nq
					for k in range(nq):
						var v0 := verts[k * 4]
						var v1 := verts[k * 4 + 1]
						var v2 := verts[k * 4 + 2]
						var v3 := verts[k * 4 + 3]
						var xs := [v0.x, v1.x, v2.x, v3.x]
						var ys := [v0.y, v1.y, v2.y, v3.y]
						var zs := [v0.z, v1.z, v2.z, v3.z]
						var axis := -1
						if _occl_flat(xs, eps):
							axis = 0
						elif _occl_flat(ys, eps):
							axis = 1
						elif _occl_flat(zs, eps):
							axis = 2
						if axis < 0:
							continue
						var pw := 0
						if axis == 0:
							pw = cxw + int(round(v0.x))
						elif axis == 1:
							pw = int(round(v0.y))
						else:
							pw = czw + int(round(v0.z))
						var varax: Array = []
						if axis != 0:
							varax.append(0)
						if axis != 1:
							varax.append(1)
						if axis != 2:
							varax.append(2)
						var ranges := {}
						for va in varax:
							var vals: Array
							if va == 0:
								vals = xs
							elif va == 1:
								vals = ys
							else:
								vals = zs
							var lo := float(vals.min())
							var hi := float(vals.max())
							var wlo: int
							var whi: int
							if va == 0:
								wlo = cxw + int(round(lo))
								whi = cxw + int(round(hi))
							elif va == 2:
								wlo = czw + int(round(lo))
								whi = czw + int(round(hi))
							else:
								wlo = int(round(lo))
								whi = int(round(hi))
							ranges[va] = [wlo, whi - 1]
						var va0: int = varax[0]
						var va1: int = varax[1]
						var r0: Array = ranges[va0]
						var r1: Array = ranges[va1]
						var idA := 0
						var idB := 0
						var cen0 := (int(r0[0]) + int(r0[1])) / 2
						var cen1 := (int(r1[0]) + int(r1[1])) / 2
						var cellA := Vector3i.ZERO
						var cellB := Vector3i.ZERO
						if va0 == 0:
							cellA.x = cen0
							cellB.x = cen0
						elif va0 == 1:
							cellA.y = cen0
							cellB.y = cen0
						else:
							cellA.z = cen0
							cellB.z = cen0
						if va1 == 0:
							cellA.x = cen1
							cellB.x = cen1
						elif va1 == 1:
							cellA.y = cen1
							cellB.y = cen1
						else:
							cellA.z = cen1
							cellB.z = cen1
						if axis == 0:
							cellA.x = pw - 1
							cellB.x = pw
						elif axis == 1:
							cellA.y = pw - 1
							cellB.y = pw
						else:
							cellA.z = pw - 1
							cellB.z = pw
						idA = int(world.get_block(cellA.x, cellA.y, cellA.z))
						idB = int(world.get_block(cellB.x, cellB.y, cellB.z))
						var stabA := int(stab[idA])
						var stabB := int(stab[idB])
						var quad_under := false
						var quad_leak := false
						if stabA > 0 and stabB == 0:
							var cc := pw - 1
							for a in range(int(r0[0]), int(r0[1]) + 1):
								for b in range(int(r1[0]), int(r1[1]) + 1):
									var cell := Vector3i.ZERO
									if va0 == 0:
										cell.x = a
									elif va0 == 1:
										cell.y = a
									else:
										cell.z = a
									if va1 == 0:
										cell.x = b
									elif va1 == 1:
										cell.y = b
									else:
										cell.z = b
									if axis == 0:
										cell.x = cc
									elif axis == 1:
										cell.y = cc
									else:
										cell.z = cc
									var cid := int(world.get_block(cell.x, cell.y, cell.z))
									if cid == 0 or stab[cid] == 0:
										continue
									var surf := int(col_surf.get(Vector2i(cell.x, cell.z), -1))
									if cell.y < surf:
										quad_under = true
									if _occl_is_interior(cell.x, cell.y, cell.z, stab):
										quad_leak = true
										leaking_cells += 1
						elif stabB > 0 and stabA == 0:
							var cc := pw
							for a in range(int(r0[0]), int(r0[1]) + 1):
								for b in range(int(r1[0]), int(r1[1]) + 1):
									var cell := Vector3i.ZERO
									if va0 == 0:
										cell.x = a
									elif va0 == 1:
										cell.y = a
									else:
										cell.z = a
									if va1 == 0:
										cell.x = b
									elif va1 == 1:
										cell.y = b
									else:
										cell.z = b
									if axis == 0:
										cell.x = cc
									elif axis == 1:
										cell.y = cc
									else:
										cell.z = cc
									var cid := int(world.get_block(cell.x, cell.y, cell.z))
									if cid == 0 or stab[cid] == 0:
										continue
									var surf := int(col_surf.get(Vector2i(cell.x, cell.z), -1))
									if cell.y < surf:
										quad_under = true
									if _occl_is_interior(cell.x, cell.y, cell.z, stab):
										quad_leak = true
										leaking_cells += 1
						elif stabA > 0 and stabB > 0:
							quad_leak = true
							leaking_cells += 2
						elif idA == 0 and idB == 0:
							quad_leak = true
							leaking_cells += 2
						else:
							no_emitter += 1
						if quad_under:
							underground_faces += 1
							underground_verts += 4
						if quad_leak:
							leaking_faces += 1
	return {
		"total_verts": total_verts,
		"verts_mesh": verts_mesh,
		"verts_fluid": verts_fluid,
		"verts_flora": verts_flora,
		"total_faces": total_faces,
		"underground_verts": underground_verts,
		"underground_faces": underground_faces,
		"leaking_cells": leaking_cells,
		"leaking_faces": leaking_faces,
		"no_emitter": no_emitter,
	}


func _occlude_test(spawn: Vector3) -> void:
	var t0 := Time.get_ticks_msec()
	var stab := _occl_stab()
	world.recenter(spawn.x, spawn.z, true)
	var chunks: Array = []
	var frames := 0
	while frames < 2400:
		chunks = _occl_built_chunks(4)
		if chunks.size() >= 81:
			break
		await get_tree().physics_frame
		frames += 1
	chunks.sort_custom(func(a, b):
		if a.cx != b.cx:
			return a.cx < b.cx
		return a.cz < b.cz
	)
	var interior_voxels := 0
	var full_solid_slabs := 0
	var occluders := 0
	var box_sample: Array = []
	var col_surf := {}
	var cave_seed: Array = []
	var seen_cave: Array = []
	for c in chunks:
		var st := _occl_chunk_stats(c, stab)
		interior_voxels += st.interior
		for i in range(st.slab_ns.size()):
			if st.slab_ns[i] == 0:
				full_solid_slabs += 1
		for s in c.slabs:
			if s.occluder != null:
				occluders += 1
				if box_sample.is_empty():
					var bb: BoxOccluder3D = s.occluder.occluder
					box_sample = [s.occluder.position, bb.size, s.y0]
		var cxw := int(c.cx) * 16
		var czw := int(c.cz) * 16
		for col in range(256):
			if int(st.srf[col]) >= 0:
				col_surf[Vector2i(cxw + col / 16, czw + col % 16)] = int(st.srf[col])
		if cave_seed.is_empty():
			var sd := _occl_cave_seed(c, st.srf, stab)
			if not sd.is_empty():
				var stt := Vector3i(int(sd[0]) * 16 + int(sd[2]), int(sd[3]), int(sd[1]) * 16 + int(sd[4]))
				var dupc := false
				for r in seen_cave:
					if stt.x >= int(r.aabb_min[0]) and stt.x <= int(r.aabb_max[0]) and stt.y >= int(r.aabb_min[1]) and stt.y <= int(r.aabb_max[1]) and stt.z >= int(r.aabb_min[2]) and stt.z <= int(r.aabb_max[2]):
						dupc = true
						break
				if not dupc:
					var flc := _occl_flood(sd, stab, 20000, 4)
					seen_cave.append(flc)
					if not bool(flc.open):
						cave_seed = sd
	var audit := _occl_quad_audit(chunks, stab, col_surf)
	var cave := {"cells": 0, "aabb_min": null, "aabb_max": null, "seed": cave_seed}
	if not cave_seed.is_empty():
		var fl := _occl_flood(cave_seed, stab, 20000, 4)
		cave = fl
		cave["seed"] = cave_seed
	var out := {
		"mode": "occlude",
		"radius": 4,
		"chunks_built": chunks.size(),
		"total_verts": audit.total_verts,
		"verts_mesh": audit.verts_mesh,
		"verts_fluid": audit.verts_fluid,
		"verts_flora": audit.verts_flora,
		"total_faces": audit.total_faces,
		"underground_verts": audit.underground_verts,
		"underground_faces": audit.underground_faces,
		"interior_voxels": interior_voxels,
		"leaking_cells": audit.leaking_cells,
		"leaking_faces": audit.leaking_faces,
		"no_emitter": audit.no_emitter,
		"full_solid_slabs": full_solid_slabs,
		"occluders": occluders,
		"box_sample": box_sample,
		"cull_3d": ProjectSettings.get_setting("rendering/occlusion_culling/camera/cull_3d") == true,
		"use_occl": ProjectSettings.get_setting("rendering/occlusion_culling/use_occlusion_culling") == true,
		"cave": cave,
		"ok": audit.leaking_cells == 0,
	}
	Debug.result(out)
	get_tree().quit()


func _cave_snapshot_finish(cam: String, snapshot_path: String, spawn: Vector3) -> void:
	var stab := _occl_stab()
	var chunks: Array = []
	var frames := 0
	while frames < 2400:
		chunks = _occl_built_chunks(4)
		if chunks.size() >= 81:
			break
		await get_tree().physics_frame
		frames += 1
	chunks.sort_custom(func(a, b):
		if a.cx != b.cx:
			return a.cx < b.cx
		return a.cz < b.cz
	)
	var seed: Array = []
	var best_enclosed: Array = []
	var best_enclosed_cells := 0
	var best_any: Array = []
	var best_any_cells := 0
	var seen: Array = []
	for c in chunks:
		var st := _occl_chunk_stats(c, stab)
		var sd := _occl_cave_seed(c, st.srf, stab)
		if sd.is_empty():
			continue
		var start := Vector3i(int(sd[0]) * 16 + int(sd[2]), int(sd[3]), int(sd[1]) * 16 + int(sd[4]))
		var dup := false
		for r in seen:
			if start.x >= int(r.aabb_min[0]) and start.x <= int(r.aabb_max[0]) and start.y >= int(r.aabb_min[1]) and start.y <= int(r.aabb_max[1]) and start.z >= int(r.aabb_min[2]) and start.z <= int(r.aabb_max[2]):
				dup = true
				break
		if dup:
			continue
		var f := _occl_flood(sd, stab, 20000, 4)
		seen.append(f)
		var ncells := int(f.cells)
		var eye_clear := int(world.get_block(int(sd[0]) * 16 + int(sd[2]), int(sd[3]) + 1, int(sd[1]) * 16 + int(sd[4]))) == 0
		if not bool(f.open) and eye_clear and ncells > best_enclosed_cells:
			best_enclosed_cells = ncells
			best_enclosed = sd
		if ncells > best_any_cells:
			best_any_cells = ncells
			best_any = sd
	seed = best_enclosed if not best_enclosed.is_empty() else best_any
	if seed.is_empty():
		Debug.result({"mode": "cave", "cam": cam, "ok": false, "why": "no_cave"})
		get_tree().quit()
		return
	var cx0 := int(seed[0])
	var cz0 := int(seed[1])
	var lx0 := int(seed[2])
	var y0 := int(seed[3])
	var lz0 := int(seed[4])
	var wx0 := cx0 * 16 + lx0
	var wy0 := y0
	var wz0 := cz0 * 16 + lz0
	world.recenter(wx0, wz0, true)
	await _await_world_build(Vector3(float(wx0) + 0.5, float(wy0), float(wz0) + 0.5), 3000)
	if player == null:
		player = _spawn_player()
	Debug.fly(true)
	Debug.teleport(float(wx0) + 0.5, float(wy0) + player.EYE, float(wz0) + 0.5)
	var dirs6 := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1), Vector3i(0, 1, 0), Vector3i(0, -1, 0)]
	var aimdir := Vector3i.ZERO
	var torch_pos := Vector3i.ZERO
	var torches: Array = []
	var best_aim := 0
	for dd in dirs6:
		var nb: Vector3i = Vector3i(wx0, wy0, wz0) + dd
		var bid := int(world.get_block(nb.x, nb.y, nb.z))
		if stab[bid] > 0:
			var nb2: Vector3i = Vector3i(wx0, wy0, wz0) + dd * 2
			var sc := 1
			if int(world.get_block(nb2.x, nb2.y, nb2.z)) != 0:
				sc += 1
			if sc > best_aim:
				best_aim = sc
				aimdir = dd
	for k in [1, 2]:
		for dd in dirs6:
			if k == 1 and dd == Vector3i(0, 1, 0):
				continue
			var tp: Vector3i = Vector3i(wx0, wy0, wz0) + dd * k
			if int(world.get_block(tp.x, tp.y, tp.z)) == 0:
				if torch_pos == Vector3i.ZERO:
					torch_pos = tp
				torches.append(tp)
	for t in torches:
		Debug.set_block(int(t.x), int(t.y), int(t.z), 22)
	if not torches.is_empty():
		for i in 300:
			await get_tree().physics_frame
	if aimdir != Vector3i.ZERO:
		var eye := Vector3(float(wx0) + 0.5, float(wy0) + player.EYE, float(wz0) + 0.5)
		var target := Vector3(float(wx0) + 0.5 + float(aimdir.x), float(wy0) + 0.5 + float(aimdir.y), float(wz0) + 0.5 + float(aimdir.z))
		var dir := (target - eye).normalized()
		var yaw := atan2(-dir.x, -dir.z)
		var pitch := asin(clampf(dir.y, -1.0, 1.0))
		player.look(yaw, pitch)
	for i in 8:
		await get_tree().physics_frame
	await Debug.snap(snapshot_path)
	Debug.result({"mode": "cave", "cam": cam, "ok": true, "seed": [wx0, wy0, wz0], "torch": [torch_pos.x, torch_pos.y, torch_pos.z], "w": int(get_viewport().size.x), "h": int(get_viewport().size.y)})
	get_tree().quit()
