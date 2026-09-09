# AC-0140: main.gd is the thin coordinator - game node lifecycle, menu,
# sky/fog, and the harness dispatch (scenes/harness.gd).
extends Node3D

class_name Main

const WorldRes = preload("res://world/world.tscn")
const PlayerRes = preload("res://player/player.tscn")
const InventoryScript = preload("res://ui/inventory.gd")
const AtlasScript = preload("res://core/atlas.gd")
const DayNight = preload("res://core/daynight.gd")
const MenuRes = preload("res://scenes/menu.tscn")
const AeroLib = preload("res://core/aero.gd")
const ChunkIO = preload("res://core/chunk_io.gd")  # AC-0155
const _ChunkScriptM = preload("res://world/chunk.gd")  # AC-0120 (snapshot material cache)
const HarnessScript = preload("res://scenes/harness.gd")
const ConsoleScript = preload("res://ui/console.gd")  # AC-0121

var harness: HarnessScript
var console: CanvasLayer  # AC-0121
var world: Node3D
var camera: Camera3D
var player: Node3D
var drops: Node
var entities: Node
var sun: DirectionalLight3D
var world_env: WorldEnvironment
var env: Environment
# AC-0242: 1.0 under forward_plus, 0.0 under gl_compatibility (AeroLib.srgb_pre()).
var _srgb_pre: float = 0.0
var inventory_ui: CanvasLayer
var menu_ui: Menu
var stats_overlay: CanvasLayer
var _stats_log_t := -1000000.0
var _stats_prev_t := -1
var _stats_prev_proc := 0.0
var _stats_acc := 0.0
var aero := false
var _batt := false
var sky_mat: ShaderMaterial  # AC-0235: the sky-pass gradient (replaces the AeroSky dome)
var cloud_layers: Array = []  # AC-0235 retest 5: [{node, mat, h}] - 3 layers, varying height/size/speed
var _cloud_time := 0.0  # AC-0235: cloud drift clock (advanced per frame)
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

	# AC-0140: the test harness (scenes/harness.gd)
	harness = HarnessScript.new()
	add_child(harness)

	sun = DirectionalLight3D.new()
	sun.shadow_enabled = false
	add_child(sun)

	world_env = WorldEnvironment.new()
	env = Environment.new()
	# AC-0242: cache the renderer fix value once (renderer is final by _ready).
	_srgb_pre = AeroLib.srgb_pre()
	# AC-0235: the sky gradient + sun moved from the AeroSky dome
	# (a flipped sphere) into the engine SKY PASS - no geometry.
	# NOTE: the sky shader carries render_mode disable_fog - with env fog
	# enabled the engine fog path otherwise paints the flat fog color over
	# the whole sky background (the AC-0235 'no sun / flat sky' bug).
	env.background_mode = Environment.BG_SKY
	var _sky_res := Sky.new()
	_sky_res.radiance_size = Sky.RADIANCE_SIZE_32  # IBL is unused in this game - smallest cubemap
	sky_mat = ShaderMaterial.new()
	sky_mat.shader = load("res://core/aero_sky_gradient.gdshader")
	sky_mat.set_shader_parameter("u_srgb_pre", _srgb_pre)  # AC-0242
	_sky_res.sky_material = sky_mat
	env.sky = _sky_res
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	if OS.get_environment("AWECRAFT_NO_FOG") == "1":
		env.fog_enabled = false
	world_env.environment = env
	add_child(world_env)
	# AC-0242: apply the renderer fix to the shared water/lava materials; the
	# per-chunk materials ride the per-frame push in _update_sky.
	for bid in Data.fluid_anim_mats:
		Data.fluid_anim_mats[bid].set_shader_parameter("u_srgb_pre", _srgb_pre)
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
	# AC-0235: harness seed for the cloud drift clock (drift A/B shots).
	var ct0 := OS.get_environment("AWECRAFT_CLOUD_T0")
	if ct0 != "":
		_cloud_time = ct0.to_float()
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
		await harness.run_battery(seed_env, battery_env)
		return
	if logic == "mainmenuexit":
		await harness._mainmenuexit_test()
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

var _batt_drop_freeze := false

func _create_game_nodes() -> void:
	world = WorldRes.instantiate()
	world.name = "World"
	add_child(world)
	if OS.get_environment("AWECRAFT_NO_WORLD_VIS") == "1":
		world.visible = false
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
	# AC-0121: the debug console overlay (backtick/F3 toggle).
	if console != null:
		console.queue_free()
	console = ConsoleScript.new()
	console.name = "Console"
	add_child(console)
	Game.console = console
	if _star_node != null:
		_star_node.queue_free()
		_star_node = null
	_star_mat = ShaderMaterial.new()
	_star_mat.shader = load("res://core/star.gdshader")
	_star_mat.set_shader_parameter("u_opacity", 1.0)
	_star_mat.set_shader_parameter("u_srgb_pre", _srgb_pre)  # AC-0242
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
	var uv2a := PackedVector2Array()
	var idx := PackedInt32Array()
	var sr: float = float(OS.get_environment("AWECRAFT_STAR_R").to_float()) if OS.get_environment("AWECRAFT_STAR_R") != "" else 320.0  # AC-0235 star debug: harness radius override
	for i in 500:
		var u1: float = _vl_mb_next(st)
		var u2: float = _vl_mb_next(st)
		var phi: float = acos(2.0 * u1 - 1.0)
		var theta: float = u2 * TAU
		var p := Vector3(sr * sin(phi) * sin(theta), sr * cos(phi), sr * sin(phi) * cos(theta))
		# AC-0235 retest 5: per-star variation (user: the stars were all
		# too bright and uniform). brightness = mostly dim, a few bright
		# (pow 2.2); hue = mostly white with blue-white / warm / red
		# minorities (real stellar classes); size in the color alpha
		# (mostly small, a few big, pow 3.0) - the shader reads all
		# three from VERTEX_COLOR and picks the shape from a stable
		# hash of the star center.
		# AC-0235 retest 5 cont: the 4.7 spatial shader exposes NO
		# VERTEX_COLOR builtin, so the per-star data rides UV2: x = size
		# factor, y = hue_class * 20 + brightness_q (b15, 0-15, dim-heavy
		# pow 2.2 baked here). The shader unpacks both.
		var b15: float = floor(pow(_vl_mb_next(st), 2.2) * 15.0)
		var hu: float = _vl_mb_next(st)
		var hue_c: float = 0.0  # 0 white, 1 blue-white, 2 warm, 3 red-orange
		if hu > 0.95:
			hue_c = 3.0
		elif hu > 0.85:
			hue_c = 2.0
		elif hu > 0.70:
			hue_c = 1.0
		var sz: float = 0.9 + 1.6 * pow(_vl_mb_next(st), 2.5)  # retest 6: at r=320, ~1.2-2 world units = 1.5-3 screen pixels
		var uv2v := Vector2(sz, hue_c * 20.0 + b15)
		var base := v.size()
		for cv in [Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(1.0, 1.0), Vector2(0.0, 1.0)]:
			v.append(p)
			u.append(cv)
			uv2a.append(uv2v)
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
	arrs[Mesh.ARRAY_TEX_UV2] = uv2a
	arrs[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrs)
	# AC-0235 star fix: 4.7 ArrayMesh does NOT compute the AABB from
	# add_surface_from_arrays (it stays zero), and the degenerate AABB
	# made the MeshInstance3D flakily culled - the field never drew at
	# the 320-unit radius on the harness renderer. Set the shell
	# bounds explicitly (the node tracks the camera, so the box always
	# contains the eye and intersects every frustum).
	var ar: float = sr + 3.0
	m.set_custom_aabb(AABB(Vector3(-ar, -ar, -ar), Vector3(ar * 2.0, ar * 2.0, ar * 2.0)))
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
	world.recenter(target.x, target.z, true, target.y)
	await _await_core_3x3(target, 3000)
	player = _spawn_player()
	_restore_player(ps if height_ok else {})
	if Game.world != null:
		world.recenter(player.position.x, player.position.z, true, player.position.y)  # AC-0234
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

func _run_game(seed_env: String, logic: String, cam: String, snapshot_path: String) -> void:
	Game.new_world(44 if seed_env == "" else seed_env.to_int())
	if logic == "settings":
		harness._settings_test()
		get_tree().quit()
		return
	if _harness_env_set():
		OS.set_environment("AWECRAFT_IGNORE_SETTINGS", "1")
		Settings.load_settings()
		OS.set_environment("AWECRAFT_IGNORE_SETTINGS", "")
	# AC-0232 (dither dropped in AC-0241): harness preload for the fog
	# setting — the AWECRAFT_TM_HO pattern: written to Settings.values WITHOUT
	# save so the harness never clobbers the user's cfg, and the game code
	# path runs exactly the settings-wired way (main.gd reads the value every
	# frame). AWECRAFT_FOG_PCT=n (0-100).
	var fpe := OS.get_environment("AWECRAFT_FOG_PCT")
	if fpe != "":
		Settings.values["fog_start_pct"] = clampi(fpe.to_int(), Settings.PCT_MIN, Settings.PCT_MAX)
	if OS.get_environment("AWECRAFT_DSSTATS") == "1":
		Settings.set_value("debug_stats", true)
	_create_game_nodes()
	var spawn: Vector3 = world.spawn_point()
	await harness.run(seed_env, logic, cam, snapshot_path, spawn)
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
	# AC-0235: the procedural cloud deck. AC-0235 retest 5: THREE
	# layers with varying height, feature size and drift speed
	# (user: vary height/size/speed) - the pattern is world-anchored
	# in the shader, so following the player's XZ does not smear it.
	# h = layer altitude, scale = feature size in blocks, cov =
	# coverage multiplier (lower layers are thinner, faster).
	if AeroLib.clouds_on():
		var CL := [
			{"h": AeroLib.CLOUD_H, "size": 6144.0, "scale": 256.0, "wind": Vector2(0.005, 0.002), "cov": 1.00},
			{"h": 330.0, "size": 5120.0, "scale": 160.0, "wind": Vector2(0.012, 0.005), "cov": 0.75},
			{"h": 275.0, "size": 4096.0, "scale": 110.0, "wind": Vector2(0.025, 0.010), "cov": 0.55},
		]
		for cl in CL:
			var cm := ShaderMaterial.new()
			cm.shader = load("res://core/cloud_layer.gdshader")
			cm.set_shader_parameter("u_srgb_pre", _srgb_pre)
			cm.set_shader_parameter("u_wind", cl["wind"])
			cm.set_shader_parameter("u_scale", 1.0 / float(cl["scale"]))
			var q := QuadMesh.new()
			q.size = Vector2(cl["size"], cl["size"])  # reaches the camera far plane (4096) down to ~5 deg elevation
			var ln := MeshInstance3D.new()
			ln.name = "CloudLayer"
			ln.mesh = q
			ln.material_override = cm
			ln.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
			add_child(ln)
			cloud_layers.append({"node": ln, "mat": cm, "h": cl["h"], "cov": cl["cov"]})
	if AeroLib.wash_on():
		aero_wash_mesh = QuadMesh.new()
		var wm := ShaderMaterial.new()
		wm.shader = load("res://core/aero_wash.gdshader")
		wm.set_shader_parameter("wash_color", AeroLib.WASH_COLOR)
		wm.set_shader_parameter("wash_amount", AeroLib.WASH_AMOUNT)
		wm.set_shader_parameter("top_glow", AeroLib.WASH_TOP_GLOW)
		wm.set_shader_parameter("u_srgb_pre", _srgb_pre)
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
	# AC-0241 follow-up: freeze the clock for A/B render shots - the snapshot
	# runs 3000+ frames and the day drifts a quarter cycle (frame-dependent
	# on software renderers), which changes u_day and tints every unshaded
	# frame differently between runs.
	if OS.get_environment("AWECRAFT_TIME_FREEZE") != "1":
		Game.time_of_day = fmod(Game.time_of_day + minf(delta, 0.05) / DayNight.DAY_LEN, 1.0)
	if stats_overlay != null:
		_stats_acc += delta
		if _stats_acc >= 0.25:
			_stats_acc = 0.0
			_refresh_stats()
	_update_sky()
	# AC-0235: cloud layer follows the player's XZ; the drift
	# clock advances per frame (clamped like the day clock).
	for cl in cloud_layers:
		if player != null:
			cl["node"].position = Vector3(player.position.x, float(cl["h"]), player.position.z)
		_cloud_time += minf(delta, 0.05)
	if aero:
		var ac := _aero_camera()
		if ac != null:
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
	# AC-0171: the stats overlay feeds the session log (2 s cadence) when
	# debug logging is on.
	if bool(Settings.values.get("debug_logging", false)) \
			and now - _stats_log_t >= 2000:
		_stats_log_t = now
		var st := _stats_text(cpu_pct).replace("\n", " | ")
		Debug.session_log_line("[stats] " + st)

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
	# AC-0227's dither band was dropped in AC-0241 (the AC-0226 fog fade is
	# the only distance fade now); the u_day + player light ride the same
	# per-frame push.
	for k in _ChunkScriptM._mat_cache:
		var cm = _ChunkScriptM._mat_cache[k]
		if cm is ShaderMaterial:
			cm.set_shader_parameter("u_player_pos", ppos)
			cm.set_shader_parameter("u_player_light", plvl)
			cm.set_shader_parameter("u_player_radius", prad)
			cm.set_shader_parameter("u_srgb_pre", _srgb_pre)

	sun.light_color = AeroLib.SUN_TINT if aero else Color.WHITE
	sun.light_energy = DayNight.sun_energy(t) * (AeroLib.SUN_BOOST if aero else 1.0)
	sun.look_at(DayNight.sun_direction(t), Vector3.UP)
	var sky := DayNight.sky_display(t)
	env.background_color = sky
	env.ambient_light_color = AeroLib.AMBIENT_TINT if aero else Color.WHITE
	env.ambient_light_energy = DayNight.ambient_energy(t) * (AeroLib.AMBIENT_BOOST if aero else 1.0)
	env.fog_light_color = sky
	# AC-0235: the sky-pass gradient + sun (same AeroLib uniforms as the
	# old dome; the cloud_* keys belong to the cloud layer now).
	if sky_mat != null:
		var u := AeroLib.sky_uniforms(t)
		for k in u.keys():
			if k != "cloud_color" and k != "cloud_amount":
				sky_mat.set_shader_parameter(k, u[k])
	if not cloud_layers.is_empty():
		var u2 := AeroLib.sky_uniforms(t)
		# AC-0235 retest 2: clouds go dark at night (MC-style).
		var cday := DayNight.day(t)
		var ctint := Color8(46, 50, 66).lerp(Color(u2["cloud_color"]), cday)
		for cl in cloud_layers:
			cl["mat"].set_shader_parameter("u_cloud_time", _cloud_time)
			cl["mat"].set_shader_parameter("u_coverage", float(u2["cloud_amount"]) * float(cl["cov"]))
			cl["mat"].set_shader_parameter("u_cloud_tint", ctint)

func _update_fog() -> void:
	var rr: int = world.render_radius
	env.fog_depth_begin = DayNight.fog_near(rr)
	# AC-0232: the full-fog boundary is now the "fog_start_pct" setting (a
	# percent of the (R+1)*16 render edge; default 87 ~= the shipped AC-0226
	# 0.875, still ahead of the worst-case pop-in face at every R >= 7).
	# Read every process frame in play mode — the Options slider applies
	# live (within a frame).
	env.fog_depth_end = DayNight.fog_far(rr, float(Settings.values["fog_start_pct"]))

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

