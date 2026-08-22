extends Node3D

const WorldRes = preload("res://world/world.tscn")
const PlayerRes = preload("res://player/player.tscn")
const InventoryScript = preload("res://ui/inventory.gd")
const AtlasScript = preload("res://core/atlas.gd")
const DayNight = preload("res://core/daynight.gd")
const MenuScript = preload("res://ui/menu.gd")
const AeroLib = preload("res://core/aero.gd")

var world: Node3D
var camera: Camera3D
var player: Node3D
var drops: Node
var entities: Node
var sun: DirectionalLight3D
var world_env: WorldEnvironment
var env: Environment
var inventory_ui: CanvasLayer
var menu_ui: CanvasLayer
var aero := false
var aero_sky: MeshInstance3D
var aero_sky_mat: ShaderMaterial
var aero_wash: MeshInstance3D
var aero_wash_mesh: QuadMesh


func _ready() -> void:
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
	if logic != "":
		await _run_game(seed_env, logic, cam, snapshot_path)
		return
	if (snapshot_path != "" or _harness_env_set()) and not (menu_boot and snapshot_path != ""):
		await _run_game(seed_env, logic, cam, snapshot_path)
		return

	var headless_idle := DisplayServer.get_name() == "headless" \
		and logic == "" and snapshot_path == "" and not menu_boot and not _harness_env_set()
	# menu-first boot on every display platform (desktop + web); AWECRAFT_MENU=0 = explicit game-first skip
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


const HARNESS_ENVS := [
	"AWECRAFT_LOGIC", "AWECRAFT_SNAPSHOT", "AWECRAFT_INV", "AWECRAFT_FLUID_SHOT", "AWECRAFT_CAM",
	"AWECRAFT_HELD", "AWECRAFT_WALK_SHOT", "AWECRAFT_EMPTYHAND", "AWECRAFT_SWING", "AWECRAFT_FPV_ITEM",
	"AWECRAFT_ANIM_SHOT", "AWECRAFT_PROBE", "AWECRAFT_BCELL", "AWECRAFT_MESH_INFO", "AWECRAFT_ONLY",
	"AWECRAFT_DBG", "AWECRAFT_SETTLE_TICKS", "AWECRAFT_SEED", "AWECRAFT_TIME", "AWECRAFT_ANIM_PHASE",
	"AWECRAFT_SIZE", "AWECRAFT_HP", "AWECRAFT_HUNGER",
]


func _harness_env_set() -> bool:
	for e in HARNESS_ENVS:
		if OS.get_environment(e) != "":
			return true
	return false


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


func _make_menu() -> CanvasLayer:
	menu_ui = MenuScript.new()
	menu_ui.name = "Menu"
	menu_ui.on_play = Callable(self, "_menu_play")
	menu_ui.on_new_world = Callable(self, "_menu_new_world")
	menu_ui.on_resume = Callable(self, "_menu_resume")
	menu_ui.on_quit_to_menu = Callable(self, "_quit_to_menu")
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


func _continue_slot(slot: int) -> void:
	var data := Save.load_full(int(slot))
	if data.is_empty():
		return
	Save.active_slot = int(slot)
	if world != null:
		_free_game_nodes()
	Game.new_world(int(data.get("seed", 1)))
	_create_game_nodes()
	world.edits = data.get("edits", {})
	var ps: Dictionary = data.get("player", {})
	var pos: Array = ps.get("pos", [])
	var target: Vector3
	if pos.size() == 3:
		target = Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
	else:
		target = world.spawn_point()
	world.recenter(target.x, target.z, true)
	await _await_world_build(target, 3000)
	player = _spawn_player()
	_restore_player(ps)
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
		Debug.give_item(int(pp[0]), int(pp[1]) if pp.size() > 1 else 1)
	player.sel = _slot_of(player, int(pairs[0].split(":")[0]))
	Game.message("Debug items given (%s)" % spec)


func _free_game_nodes() -> void:
	if player != null:
		player.queue_free()
	if inventory_ui != null:
		inventory_ui.queue_free()
	if world != null:
		world.queue_free()
	if drops != null:
		drops.queue_free()
	if entities != null:
		entities.queue_free()
	player = null
	inventory_ui = null
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
	func recenter(_x: float, _z: float) -> void:
		pass


func _settings_test() -> void:
	if FileAccess.file_exists(Settings.PATH):
		DirAccess.remove_absolute(Settings.PATH)
	Settings.load_settings()
	var defaults_ok := int(Settings.values["render_dist"]) == 50 and int(Settings.values["sim_dist"]) == 1
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
					for yy in range(75, -1, -1):
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
					if hgt2 <= Data.SEA or hgt2 > 40:
						continue
					var gxx2 := int(floorf(float(x) / 16.0))
					var gzz2 := int(floorf(float(z) / 16.0))
					var g2 = gen_cache.get("%d,%d" % [gxx2, gzz2])
					if g2 == null:
						continue
					var top2 := 0
					for yy in range(75, -1, -1):
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
					elif mh2 < 38:
						ch = "-"
					elif mh2 < 44:
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
				for yy in range(74, -1, -1):
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
		if logic == "wallshot":
			world.recenter(spawn.x, spawn.z, true)
			await _await_spawn_floor(spawn, 300)
			player = _spawn_player()
			await _wallshot_test()
			return
		if logic == "editperf":
			await _editperf_test(spawn)
			return
		if logic == "perf":
			var t0 := Time.get_ticks_msec()
			world.recenter(spawn.x, spawn.z, true)
			var recenter_ms := Time.get_ticks_msec() - t0
			await _perf_test(spawn, t0, recenter_ms)
			return
		if logic == "atlas":
			world.collision_enabled = false
			world.render_radius = 0
			world.recenter(spawn.x, spawn.z, true)
			await _atlas_test(spawn)
			return
		if logic == "genhash":
			var t0 := Time.get_ticks_msec()
			for cx in range(-2, 3):
				for cz in range(-2, 3):
					var d := WorldGen.generate(cx, cz, Game.world_seed)
					var h := HashingContext.new()
					h.start(HashingContext.HASH_MD5)
					h.update(d)
					var md5: PackedByteArray = h.finish()
					var hx := ""
					for i in range(8):
						hx += "%02x" % md5[i]
					print("GENHASH ", cx, " ", cz, " ", hx)
			print("GENMS ", Time.get_ticks_msec() - t0)
			get_tree().quit()
			return
		if logic == "trees":
			await _trees_test()
			return
		if logic == "save":
			await _save_test()
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
				if cc.mesh_instance != null:
					cc.mesh_instance.visible = false
				if cc.fluid_instance != null:
					cc.fluid_instance.visible = false
	if OS.get_environment("AWECRAFT_DBG") != "":
		for dx in range(-2, 3):
			for dz in range(-2, 3):
				var k = "%d,%d" % [dx, dz]
				var c = world.chunks.get(k)
				if c == null:
					print("DBGCHUNK ", k, " MISSING")
					continue
				var has_mi = c.mesh_instance != null
				var sc := -1
				if c.mesh_instance and c.mesh_instance.mesh:
					sc = c.mesh_instance.mesh.get_surface_count()
				var ab = ""
				if c.mesh_instance and c.mesh_instance.mesh:
					var aabb = c.mesh_instance.mesh.get_aabb()
					ab = "%s/%s" % [aabb.position, aabb.size]
				print("DBGCHUNK ", k, " built=", c.mesh_built, " mi=", has_mi, " surf=", sc, " pos=", [int(c.position.x), int(c.position.z)], " aabb=", ab)

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

	if snapshot_path != "":
		await _snapshot_finish(cam)


func _snapshot_finish(cam: String) -> void:
	var snapshot_path := OS.get_environment("AWECRAFT_SNAPSHOT")
	var spawn: Vector3 = world.spawn_point()
	var fluid_shot := OS.get_environment("AWECRAFT_FLUID_SHOT") == "1"
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
			var aim := _find_aim_spot()
			if not aim.is_empty():
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
				player.look(aim["yaw"], aim["pitch"])
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
	await _await_world_build(drain_at, 3000)
	for i in 8:
		await get_tree().physics_frame
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


func _update_sky() -> void:
	if sun == null:
		return
	var t := Game.time_of_day
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
	get_tree().quit()


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
	var p = Game.player
	for i in 5:
		await get_tree().physics_frame
	var aim := _find_aim_spot()
	if aim.is_empty():
		Debug.result({"error": "no breakable aim spot near spawn"})
		get_tree().quit()
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
	var settled := false
	for i in range(60):
		await get_tree().physics_frame
		var f: float = p.swing_frac()
		if f > 0.3 and f < 0.95:
			saw_mid = true
			mid_frac = f
		if not p.swing_active():
			settled = p.hand_pose_offset().length() < 0.001
			break
	r["saw_mid_swing"] = saw_mid
	r["mid_frac"] = roundf(mid_frac * 100.0) / 100.0
	r["settled"] = settled
	ok = ok and saw_mid and settled
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
	var punch_moved := 0.0
	for i in range(40):
		await get_tree().physics_frame
		var off: float = p.hand_pose_offset().length()
		if off > punch_moved:
			punch_moved = off
		if not p.swing_active():
			break
	r["punch_max_offset"] = roundf(punch_moved * 1000.0) / 1000.0
	r["punch_done"] = not p.swing_active()
	ok = ok and punch_moved > 0.1 and r["punch_done"]
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
		var off2: float = p.hand_pose_offset().length()
		if off2 > loop_max_off:
			loop_max_off = off2
		if f2 > 0.5:
			in_high = true
		elif in_high and f2 < 0.25:
			cycles += 1
			in_high = false
	p._lmb_down = false
	var settle_ok := false
	for i in 16:
		await get_tree().physics_frame
		if not p.swing_active() and p.hand_pose_offset().length() < 0.001:
			settle_ok = true
			break
	r["loop_cycles_0.9s"] = cycles
	r["loop_max_offset"] = roundf(loop_max_off * 1000.0) / 1000.0
	r["loop_held_stayed_active"] = held_stayed_active
	r["loop_settles_on_release"] = settle_ok
	ok = ok and cycles >= 3 and cycles <= 5 and held_stayed_active and settle_ok
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


func _probe_water_positions() -> Dictionary:
	var out := {}
	for key in world.chunks.keys():
		var c: Node3D = world.chunks.get(key)
		if c == null:
			continue
		var d: PackedByteArray = c.data
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
		var d: PackedByteArray = c.data
		for i in range(d.size()):
			if d[i] == 5:
				var v: int = c.fl[i]
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
	for lx in range(16):
		for dz in range(-1, 2):
			for dy in range(-2, 4):
				Debug.set_block(x0 + lx, by + dy, wz + dz, 0)
	by = mini(by, Data.HEIGHT - 8)
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
	# stable: fixture adds exactly 1 cell, sources never churn (stay 8 after 5 ticks),
	# fixture box reaches steady state, and the natural world loses no fluid cells (no drain)
	var sea_stable: bool = (
		water_delta == 1
		and shore == [5, 7]
		and src_top == [5, 8]
		and src_bot == [5, 8]
		and src_top2 == [5, 8]
		and w_settle == w_after
		and no_drain
	)
	print("FLUIDSTAT region_water_before=%d region_water_final=%d sea_surface_before=%d sea_surface_final=%d" % [total_before, prev, sea_before, _water_at_level(region_keys, Data.SEA)])
	Debug.result({
		"shore_after": shore,
		"source_after": src_top,
		"water_delta": water_delta,
		"water_on_lava_result": r_a,
		"sideways_lava_result": r_b,
		"sea_stable": sea_stable,
	})


func _buckets_test() -> void:
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
	get_tree().quit()


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
			if c == null or c.col_dirty:
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
	Save.clear(0)
	Save.clear(2)
	var ok: bool = saved_ok and slot0_ok and iso_ok and clear_pre_ok and clear_ok
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
		"iso_ok": iso_ok,
		"iso_base": iso_base,
		"pos_before": pos_before,
		"pos_after": pos_after,
	})
	get_tree().quit()


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
		p.hold_swing(0.5, p.SWING_ITEM)
		for i in 10:
			await get_tree().physics_frame
		var ah: Vector3 = _toolpose_centroid(cam, head_mi)
		var ap: Vector3 = _toolpose_centroid(cam, handle_mi)
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
		var arc_ok := d_idle > 0.05 and d_apex <= 0.8 * d_idle
		var dtool := true
		for c in tool.get_children():
			if c is MeshInstance3D:
				var tm = (c as MeshInstance3D).material_override
				dtool = dtool and tm is StandardMaterial3D and (tm as StandardMaterial3D).depth_draw_mode == BaseMaterial3D.DEPTH_DRAW_DISABLED
		tool_d_ok = tool_d_ok and dtool
		var row_ok: bool = String(p.held_tool_type) == String(exp_type[tid]) and pos_ok and arc_ok and diag_ok and dtool
		ok = ok and row_ok
		res["tool_%d" % tid] = {
			"type": String(p.held_tool_type),
			"idle_head": [roundf(ih.x * 1000.0) / 1000.0, roundf(ih.y * 1000.0) / 1000.0, roundf(ih.z * 1000.0) / 1000.0],
			"idle_handle": [roundf(ip.x * 1000.0) / 1000.0, roundf(ip.y * 1000.0) / 1000.0, roundf(ip.z * 1000.0) / 1000.0],
			"apex_head": [roundf(ah.x * 1000.0) / 1000.0, roundf(ah.y * 1000.0) / 1000.0, roundf(ah.z * 1000.0) / 1000.0],
			"apex_handle": [roundf(ap.x * 1000.0) / 1000.0, roundf(ap.y * 1000.0) / 1000.0, roundf(ap.z * 1000.0) / 1000.0],
			"head_in_front": ih.z < ip.z, "head_above": ih.y > ip.y, "head_centered": absf(ih.x) < absf(ip.x),
			"d_idle": roundf(d_idle * 1000.0) / 1000.0, "d_apex": roundf(d_apex * 1000.0) / 1000.0,
			"closer_pct": roundf((1.0 - d_apex / d_idle) * 100.0),
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


func _perf_test(spawn: Vector3, t0: int, recenter_ms: int) -> void:
	var pcx := int(floorf(spawn.x / 16.0))
	var pcz := int(floorf(spawn.z / 16.0))
	var frames := 0
	var max_frame_ms := 0
	var all := false
	while frames < 1200:
		var fb := Time.get_ticks_msec()
		await get_tree().physics_frame
		var fe := Time.get_ticks_msec()
		if fe - fb > max_frame_ms:
			max_frame_ms = fe - fb
		frames += 1
		all = true
		for key in world.chunks:
			var c: Node3D = world.chunks[key]
			if absi(c.cx - pcx) <= world.render_radius and absi(c.cz - pcz) <= world.render_radius:
				if not c.mesh_built:
					all = false
					break
		if all:
			break
	if OS.get_environment("AWECRAFT_MESH_INFO") != "":
		for e in world.mesh_info():
			print("MINFO ", JSON.stringify(e))
	var built := 0
	for key in world.chunks:
		var c: Node3D = world.chunks[key]
		if c.mesh_built:
			built += 1
	var total_ms := Time.get_ticks_msec() - t0
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
	})
	get_tree().quit()


func _atlas_test(spawn: Vector3) -> void:
	var pcx := int(floorf(spawn.x / 16.0))
	var pcz := int(floorf(spawn.z / 16.0))
	var c = world.chunks.get("%d,%d" % [pcx, pcz])
	for i in 900:
		if c != null and c.mesh_built and c.mesh_instance != null and c.mesh_instance.mesh != null:
			break
		await get_tree().physics_frame
	if c == null or c.mesh_built != true or c.mesh_instance == null or c.mesh_instance.mesh == null:
		Debug.result({"error": "spawn chunk not meshed"})
		get_tree().quit()
		return
	var mesh: ArrayMesh = c.mesh_instance.mesh
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
			if h <= Data.SEA + 1 or h > 74:
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
	var mesh: ArrayMesh
	if fluid:
		if c.fluid_instance == null or c.fluid_instance.mesh == null:
			return null
		mesh = c.fluid_instance.mesh
	else:
		if c.mesh_instance == null or c.mesh_instance.mesh == null:
			return null
		mesh = c.mesh_instance.mesh
	var lx := int(cell["x"]) - int(c.cx) * 16
	var lz := int(cell["z"]) - int(c.cz) * 16
	var yv := float(int(cell["y"])) + (0.875 if fluid else 1.0)
	var want: Array = [[lx, lz], [lx + 1, lz], [lx + 1, lz + 1], [lx, lz + 1]]
	for s in range(mesh.get_surface_count()):
		var arrs = mesh.surface_get_arrays(s)
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
		var data: PackedByteArray = c.data
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


func _water_at_level(keys: Array, y: int) -> int:
	var n := 0
	for key in keys:
		var c: Node3D = world.chunks.get(key)
		if c == null:
			continue
		var data: PackedByteArray = c.data
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
		var data: PackedByteArray = c.data
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
			if hd <= Data.SEA + 1 or hd > 40:
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
		var d0: PackedByteArray = cc0.data
		var nleaf := 0
		var nflower := 0
		for i in range(d0.size()):
			var v: int = d0[i]
			if v == 7:
				nleaf += 1
			elif v == 18 or v == 19:
				nflower += 1
		var ops := 0
		if cc0.mesh_instance and cc0.mesh_instance.mesh:
			ops = cc0.mesh_instance.mesh.get_surface_count()
		var leaf_v := -1
		var flower_v := -1
		var cutout_v := -1
		if nleaf > 0 or nflower > 0:
			if cc0.flora_instance == null or cc0.flora_instance.mesh == null:
				mesh_info = {"error": "no_flora_instance", "nleaf": nleaf, "nflower": nflower}
			else:
				var fm: ArrayMesh = cc0.flora_instance.mesh
				var sc := fm.get_surface_count()
				for s in range(sc):
					var arrs = fm.surface_get_arrays(s)
					var vs: PackedVector3Array = arrs[Mesh.ARRAY_VERTEX]
					if s == 0:
						cutout_v = vs.size()
					if s == 1:
						flower_v = vs.size()
				if nleaf == 0 and nflower > 0:
					flower_v = cutout_v
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
