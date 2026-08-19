extends CharacterBody3D

const EYE := 1.62
const P_H := 1.8
const P_HALF := 0.3
const GRAV := 26.0
const JUMP := 8.4
const WALK := 4.3
const SPRINT := 5.6
const SWIM := 3.2
const LAVA_SPEED := 1.1
const FLY_VS := 0.85
const MOUSE_SENS := 0.0022
const PITCH_LIMIT := 1.55
const REACH := 6.0
const INV_SIZE := 36
const STACK_MAX := 64
const ARMOR_SIZE := 4
const CRAFT_GRID_SIZE := 9
const STORAGE_OFF := 27
const ARMOR_SLOTS := ["head", "chest", "legs", "boots"]

@onready var camera: Camera3D = $Camera3D

var flying := false
var _yaw := 0.0
var _pitch := 0.0
var _chunk_x := 0
var _chunk_z := 0
var _debug_layer: CanvasLayer = null
var _debug_label: Label = null
var inv: Array = []
var sel := 0
var armor: Array = []
var hp := 20.0
var hunger := 20.0
var dead := false
var air := 10.0
var lava_t := 0.0
var drown_t := 0.0
var fall_start := -1.0
var _regen_t := 0.0
var _starve_t := 0.0
signal damaged(src: String)
var held: Dictionary = {}
var drag_held := false
var craft_grid: Array = []
var craft_out: Dictionary = {}
var ui_mode := ""
var highlight: MeshInstance3D = null
var held_box: MeshInstance3D = null
var held_sprite: Sprite3D = null
var _held_mats := {}
var _held_texs := {}
var _held_key := ""
var _mining := false
var _dragging := false
var _mine_cell := Vector3i(0, 0, 0)
var _mine_id := -1
var _mine_prog := 0.0


func _ready() -> void:
	Game.player = self
	if Game.world != null:
		position = Game.world.spawn_point()
		_chunk_x = int(floorf(position.x / 16.0))
		_chunk_z = int(floorf(position.z / 16.0))
	_init_inv()
	_build_highlight()
	_build_held()
	_build_debug()
	camera.current = true
	_apply_rotation()
	_update_debug_label()


func _process(_dt: float) -> void:
	if camera == null or held_box == null or held_sprite == null:
		return
	var it: Dictionary = inv_selected()
	var key := "%d:%d:%d:%s" % [sel, int(it["id"]), int(it["n"]), ui_mode]
	if key == _held_key:
		return
	_held_key = key
	_update_held(int(it["id"]), int(it["n"]))


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and (Input.mouse_mode == Input.MOUSE_MODE_CAPTURED or _dragging):
		var mm: InputEventMouseMotion = event
		apply_look(mm)
	if Game.mode != "play":
		return
	if event is InputEventMouseButton:
		if ui_mode != "":
			return
		var mb: InputEventMouseButton = event
		var was_captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
		if mb.pressed and not was_captured:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if was_captured:
					start_mine()
				else:
					_dragging = true
			else:
				_dragging = false
				if _mining:
					release_mine()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			if was_captured:
				use_selected()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			sel = clampi(sel - 1, 0, 8)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			sel = clampi(sel + 1, 0, 8)
	elif event is InputEventKey and event.pressed and not event.echo:
		var kc: int = int(event.physical_keycode)
		if kc == int(KEY_E):
			if ui_mode == "":
				open_inventory("inv")
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			else:
				close_inventory()
		elif kc == int(KEY_V):
			Debug.seed_inv()
		elif kc == int(KEY_ESCAPE) and ui_mode != "":
			close_inventory()
		elif ui_mode == "" and kc >= int(KEY_1) and kc <= int(KEY_9):
			sel = int(kc - int(KEY_1))


func _physics_process(dt: float) -> void:
	if Game.mode != "play":
		return
	if dead:
		return
	if Input.is_action_just_pressed("fly"):
		flying = not flying
		Game.message("Flying" if flying else "Landed")
	if Input.is_action_just_pressed("time"):
		_cycle_time()
	if Input.is_action_just_pressed("debug"):
		_debug_label.visible = not _debug_label.visible
	var in_water := _block_at(position.x, position.y + 0.5, position.z) == 5
	var in_lava := _block_at(position.x, position.y + 0.5, position.z) == 24
	var swim_up := in_water or _block_at(position.x, position.y, position.z) == 5
	var ix := 0.0
	var iz := 0.0
	if Input.is_action_pressed("move_forward"):
		iz += 1.0
	if Input.is_action_pressed("move_back"):
		iz -= 1.0
	if Input.is_action_pressed("move_left"):
		ix -= 1.0
	if Input.is_action_pressed("move_right"):
		ix += 1.0
	var ln := Vector2(ix, iz).length()
	if ln > 0.0:
		ix /= ln
		iz /= ln
	var sprint := Input.is_key_pressed(KEY_SHIFT)
	var speed: float
	if flying:
		speed = SPRINT
	elif swim_up:
		speed = SWIM
	elif in_lava:
		speed = LAVA_SPEED
	elif sprint:
		speed = SPRINT
	else:
		speed = WALK
	var sin_y := sin(_yaw)
	var cos_y := cos(_yaw)
	var tx := (-sin_y * iz + cos_y * ix) * speed
	var tz := (-cos_y * iz - sin_y * ix) * speed
	var k: float
	if flying:
		k = 10.0
	elif swim_up:
		k = 4.0
	else:
		k = 12.0
	velocity.x = lerpf(velocity.x, tx, minf(1.0, k * dt))
	velocity.z = lerpf(velocity.z, tz, minf(1.0, k * dt))
	if flying:
		var vy := 0.0
		if Input.is_action_pressed("jump"):
			vy += 1.0
		if sprint:
			vy -= 1.0
		velocity.y = lerpf(velocity.y, vy * SPRINT * FLY_VS, minf(1.0, 10.0 * dt))
	elif in_water:
		velocity.y = lerpf(velocity.y, -3.5, minf(1.0, 4.0 * dt))
		if Input.is_action_pressed("jump"):
			velocity.y = lerpf(velocity.y, 4.5, minf(1.0, 8.0 * dt))
	elif in_lava:
		velocity.y = lerpf(velocity.y, -0.7, minf(1.0, 3.0 * dt))
		if Input.is_action_pressed("jump"):
			velocity.y = lerpf(velocity.y, 1.4, minf(1.0, 6.0 * dt))
	elif swim_up and Input.is_action_pressed("jump"):
		velocity.y = lerpf(velocity.y, 4.5, minf(1.0, 8.0 * dt))
	else:
		velocity.y -= GRAV * dt
		if Input.is_action_pressed("jump") and is_on_floor():
			velocity.y = JUMP
			fall_start = -1.0
	var was_ground := is_on_floor()
	if flying:
		fall_start = -1.0
	elif not was_ground and velocity.y < 0.0 and fall_start < 0.0:
		fall_start = position.y
	move_and_slide()
	if not flying and is_on_floor() and not was_ground and fall_start >= 0.0:
		var fall := fall_start - position.y
		if fall > 3.5:
			damage_player(floorf(fall - 3.0), "fall")
		fall_start = -1.0
	_recenter()
	_update_interaction(dt)
	if position.y < -12.0:
		damage_player(100.0, "void")
	if in_lava:
		lava_t += dt
		if lava_t > 0.5:
			lava_t = 0.0
			damage_player(4.0, "lava")
	else:
		lava_t = 0.0
	var head_in_water := _block_at(position.x, position.y + EYE, position.z) == 5
	if head_in_water and not flying:
		air = maxf(0.0, air - dt)
		if air <= 0.0:
			drown_t += dt
			if drown_t > 2.0:
				drown_t = 0.0
				damage_player(2.0, "drown")
		else:
			drown_t = 0.0
	else:
		air = minf(10.0, air + dt * 2.0)
		drown_t = 0.0
	if not flying and is_on_floor() and Input.is_key_pressed(KEY_SHIFT):
		hunger = maxf(0.0, hunger - dt * 0.06)
	if hunger > 18.0 and hp < 20.0:
		_regen_t += dt
		if _regen_t >= 2.0:
			_regen_t = 0.0
			hp = minf(20.0, hp + 1.0)
	else:
		_regen_t = 0.0
	if hunger <= 0.0:
		_starve_t += dt
		if _starve_t >= 4.0:
			_starve_t = 0.0
			damage_player(1.0, "starve")
	else:
		_starve_t = 0.0
	if _debug_label.visible:
		_update_debug_label()


func _init_inv() -> void:
	inv.clear()
	for i in INV_SIZE:
		inv.append({"id": 0, "n": 0})
	armor.clear()
	for i in ARMOR_SIZE:
		armor.append(0)
	craft_grid.clear()
	for i in CRAFT_GRID_SIZE:
		craft_grid.append({"id": 0, "n": 0})
	held = {}
	craft_out = {}
	ui_mode = ""


func _build_highlight() -> void:
	highlight = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(1.02, 1.02, 1.02)
	highlight.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.0, 0.0, 0.0, 0.28)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	highlight.material_override = mat
	highlight.visible = false
	if Game.world != null:
		Game.world.add_child(highlight)
	else:
		add_child(highlight)


func _build_held() -> void:
	if camera == null:
		return
	var mesh := BoxMesh.new()
	held_box = MeshInstance3D.new()
	held_box.mesh = mesh
	held_box.material_override = StandardMaterial3D.new()
	held_box.position = Vector3(0.45, -0.42, -0.8)
	held_box.scale = Vector3(0.35, 0.35, 0.35)
	held_box.visible = false
	camera.add_child(held_box)
	held_sprite = Sprite3D.new()
	held_sprite.position = Vector3(0.45, -0.42, -0.8)
	held_sprite.scale = Vector3(0.35, 0.35, 0.35)
	held_sprite.billboard = 1
	held_sprite.visible = false
	camera.add_child(held_sprite)


func _update_held(id: int, n: int) -> void:
	if ui_mode != "" or id == 0 or n <= 0:
		held_box.visible = false
		held_sprite.visible = false
		return
	var binfo = Data.block(id)
	if binfo != null:
		held_box.material_override = _held_mat(id, binfo)
		held_box.visible = true
		held_sprite.visible = false
		return
	held_box.visible = false
	var it = Data.items.get(id)
	var col := Color(0.7, 0.7, 0.7, 1.0)
	if it != null and it.has("icon"):
		col = Color(it["icon"])
	held_sprite.texture = _tint_tex(col)
	held_sprite.visible = true


func _held_mat(id: int, binfo: Dictionary) -> StandardMaterial3D:
	var m = _held_mats.get(id)
	if m != null:
		return m
	m = StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = false
	var r := Data.block_rect(id, "side")
	if Data.atlas_tex != null and r != Vector2i(-1, -1) and Data.atlas_tex.get_image() != null:
		var tile := Data.atlas_tex.get_image().get_region(Rect2i(r, Vector2i(Data.TILE_PX, Data.TILE_PX)))
		m.albedo_texture = ImageTexture.create_from_image(tile)
	else:
		m.albedo_color = binfo["color"]["side"]
	_held_mats[id] = m
	return m


func _tint_tex(col: Color) -> ImageTexture:
	var k := col.to_html()
	var t = _held_texs.get(k)
	if t != null:
		return t
	var img := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(col)
	t = ImageTexture.create_from_image(img)
	_held_texs[k] = t
	return t


func aim_dir() -> Vector3:
	return (Basis.from_euler(Vector3(_pitch, _yaw, 0.0)) * Vector3(0.0, 0.0, -1.0)).normalized()


func aim_hit() -> Dictionary:
	if Game.world == null:
		return {"hit": false, "cell": Vector3i.ZERO, "id": 0, "normal": Vector3i.ZERO, "t": 0.0}
	return VoxelMath.raycast_blocks(camera.global_position, aim_dir(), REACH, Game.world.get_block)


func start_mine() -> void:
	var mob := aim_mob()
	if mob != null:
		attack_mob(mob)
		return
	_mining = true
	_mine_id = -1
	_mine_prog = 0.0


func aim_mob() -> Node3D:
	if Game.entities == null:
		return null
	if aim_hit().hit:
		return null
	var o := camera.global_position
	var d := aim_dir()
	var best: Node3D = null
	var bt := INF
	for c in Game.entities.get_children():
		if not (c is Node3D) or not c.has_method("center"):
			continue
		var cc: Vector3 = c.center()
		var t := (cc - o).dot(d)
		if t < 0.0 or t > REACH:
			continue
		if (o + d * t - cc).length() < 0.7 and t < bt:
			bt = t
			best = c
	return best


func attack_mob(mob: Node3D) -> void:
	var item = Data.items.get(int(inv_selected()["id"]))
	var dmg := 1.0
	if item != null and float(item.get("dmg", 0)) > 0.0:
		dmg = float(item["dmg"])
	mob.hurt(dmg, position)
	hunger = maxf(0.0, hunger - 0.5)
	Audio.play("hit")
	if mob.hp <= 0.0:
		mob.try_kill()


func release_mine() -> void:
	_mining = false
	_mine_id = -1
	_mine_prog = 0.0


func use_selected() -> void:
	if Game.mode != "play" or Game.world == null:
		return
	var item: Dictionary = inv_selected()
	var sid := int(item["id"])
	if sid == 0 or int(item["n"]) <= 0:
		return
	var info = Data.items.get(sid)
	if info != null and info.has("food"):
		eat_selected(info)
		return
	if info != null and info.has("bucket"):
		use_bucket(info)
		return
	place_item(item)


func eat_selected(info: Dictionary) -> void:
	var hit := aim_hit()
	if not hit.hit:
		return
	if hp < 20.0 or hunger < 19.9:
		hp = minf(20.0, hp + float(info["food"]))
		hunger = minf(20.0, hunger + float(info["food"]))
		inv_consume_selected()
		Audio.play("eat")
	else:
		Game.message("Too full")


func place() -> void:
	if Game.mode != "play" or Game.world == null:
		return
	place_item(inv_selected())


func place_item(item: Dictionary) -> void:
	if int(item["id"]) == 0:
		return
	if Data.block(int(item["id"])) == null:
		return
	var hit := aim_hit()
	if not hit.hit:
		return
	var target: Vector3i = hit.cell + hit.normal
	if Game.world.get_block(target.x, target.y, target.z) != 0:
		return
	if _box_intersects_player(target):
		return
	Game.world.set_block(target.x, target.y, target.z, int(item["id"]))
	inv_consume_selected()
	Audio.play("place")


func use_bucket(info: Dictionary) -> void:
	var hit := VoxelMath.raycast_cell(camera.global_position, aim_dir(), REACH, Game.world.get_block, true)
	if not hit.hit:
		return
	var cell: Vector3i = hit.cell
	var hid := int(hit.id)
	var bid := int(info.get("bucket"))
	if bid == 0:
		if hid != 5 and hid != 24:
			return
		if _box_intersects_player(cell):
			return
		Game.world.set_fluid(cell.x, cell.y, cell.z, 0, 0)
		inv_consume_selected()
		inv_add(140 if hid == 5 else 141, 1)
		Audio.play("splash")
		return
	var target := cell + Vector3i(hit.normal)
	var cur: int = Game.world.get_block(target.x, target.y, target.z)
	if cur == bid:
		return
	var cinfo = Data.block(cur)
	var replaceable := cur == 0 or (cinfo != null and bool(cinfo.get("cross", false)) and not bool(cinfo.solid) and cur != 5 and cur != 24)
	if not replaceable:
		return
	if _box_intersects_player(target):
		return
	Game.world.set_fluid(target.x, target.y, target.z, bid, 8)
	inv_consume_selected()
	inv_add(139, 1)
	Audio.play("splash")


func _box_intersects_player(cell: Vector3i) -> bool:
	var pmin := Vector3(position.x - P_HALF, position.y, position.z - P_HALF)
	var pmax := Vector3(position.x + P_HALF, position.y + P_H, position.z + P_HALF)
	var bmin := Vector3(float(cell.x), float(cell.y), float(cell.z))
	var bmax := bmin + Vector3.ONE
	return pmin.x < bmax.x and pmax.x > bmin.x and pmin.y < bmax.y and pmax.y > bmin.y and pmin.z < bmax.z and pmax.z > bmin.z


func _update_interaction(dt: float) -> void:
	if ui_mode != "":
		highlight.visible = false
		return
	var hit := aim_hit()
	if hit.hit:
		highlight.visible = true
		highlight.global_position = Vector3(float(hit.cell.x) + 0.5, float(hit.cell.y) + 0.5, float(hit.cell.z) + 0.5)
	else:
		highlight.visible = false
		if _mining:
			_mine_id = -1
			_mine_prog = 0.0
	if not _mining or not hit.hit:
		return
	var info = Data.block(int(hit.id))
	if info == null or float(info.get("hard", 1e9)) >= 1e8:
		return
	if hit.cell != _mine_cell or int(hit.id) != _mine_id:
		_mine_cell = hit.cell
		_mine_id = int(hit.id)
		_mine_prog = 0.0
	var held_item = Data.items.get(int(inv_selected()["id"]))
	var mult := 1.0
	if held_item != null and str(held_item.get("tool", "")) != "" and float(held_item.get("speed", 1.0)) > 1.0 and str(held_item["tool"]) == Data.block_tool(int(hit.id)):
		mult = float(held_item["speed"])
	_mine_prog += dt * mult / maxf(0.15, float(info["hard"]))
	if _mine_prog >= 1.0:
		Game.world.set_block(_mine_cell.x, _mine_cell.y, _mine_cell.z, 0)
		hunger = maxf(0.0, hunger - 0.1)
		var is_pick := held_item != null and str(held_item.get("tool", "")) == "pick"
		var center := Vector3(float(_mine_cell.x) + 0.5, float(_mine_cell.y) + 0.5, float(_mine_cell.z) + 0.5)
		for d in Data.block_drops(_mine_id, is_pick):
			if randf() < float(d["ch"]):
				Game.world.spawn_drop(int(d["id"]), center)
		Audio.play("break")
		_mine_id = -1
		_mine_prog = 0.0


func _cycle_time() -> void:
	if sin((Game.time_of_day - 0.25) * TAU) < -0.08:
		Game.time_of_day = 0.5
		Game.message("Noon")
	else:
		Game.time_of_day = 0.0
		Game.message("Midnight")


func _block_at(wx: float, wy: float, wz: float) -> int:
	if Game.world == null:
		return 0
	return Game.world.get_block(int(floorf(wx)), int(floorf(wy)), int(floorf(wz)))


func _recenter() -> void:
	var pcx := int(floorf(position.x / 16.0))
	var pcz := int(floorf(position.z / 16.0))
	if pcx != _chunk_x or pcz != _chunk_z:
		_chunk_x = pcx
		_chunk_z = pcz
		if Game.world != null:
			Game.world.recenter(position.x, position.z)


func _apply_rotation() -> void:
	rotation.y = _yaw
	camera.rotation.x = _pitch


func _build_debug() -> void:
	_debug_layer = CanvasLayer.new()
	_debug_layer.layer = 100
	add_child(_debug_layer)
	_debug_label = Label.new()
	_debug_label.position = Vector2(8, 8)
	_debug_label.visible = false
	_debug_layer.add_child(_debug_label)


func _update_debug_label() -> void:
	if _debug_label == null:
		return
	var fly_txt := "  FLY" if flying else ""
	_debug_label.text = "FPS %d  pos (%.1f, %.1f, %.1f)  time %.2f%s" % [Engine.get_frames_per_second(), position.x, position.y, position.z, Game.time_of_day, fly_txt]


func look(yaw: float, pitch: float) -> void:
	_yaw = yaw
	_pitch = clampf(pitch, -PITCH_LIMIT, PITCH_LIMIT)
	_apply_rotation()


func apply_look(mm: InputEventMouseMotion) -> void:
	_yaw -= mm.relative.x * MOUSE_SENS
	_pitch = clampf(_pitch - mm.relative.y * MOUSE_SENS, -PITCH_LIMIT, PITCH_LIMIT)
	_apply_rotation()


func get_yaw() -> float:
	return _yaw


func get_pitch() -> float:
	return _pitch


func is_mining() -> bool:
	return _mining


func is_dragging() -> bool:
	return _dragging


func set_fly(enabled: bool) -> void:
	flying = enabled
	Game.message("Flying" if enabled else "Landed")


func start() -> void:
	camera.current = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _stack_max(id: int) -> int:
	var info = Data.items.get(id)
	if info != null and info.has("stack"):
		return int(info["stack"])
	return STACK_MAX


func inv_add(id: int, n: int) -> bool:
	var max_n := _stack_max(id)
	var lim := mini(INV_SIZE, inv.size())
	for i in lim:
		var it: Dictionary = inv[i]
		if int(it["id"]) == id and int(it["n"]) < max_n:
			var take := mini(n, max_n - int(it["n"]))
			it["n"] = int(it["n"]) + take
			n -= take
			if n <= 0:
				return true
	for i in lim:
		var it: Dictionary = inv[i]
		if int(it["id"]) == 0 and n > 0:
			var take := mini(n, max_n)
			it["id"] = id
			it["n"] = take
			n -= take
			if n <= 0:
				return true
	return false


func count_item(id: int) -> int:
	var c := 0
	for it in inv:
		if int(it["id"]) == id:
			c += int(it["n"])
	return c


func find_slot(id: int) -> int:
	for i in mini(INV_SIZE, inv.size()):
		if int(inv[i]["id"]) == id:
			return i
	return -1


func remove_item(id: int, n: int) -> bool:
	for i in range(INV_SIZE - 1, -1, -1):
		if i >= inv.size():
			continue
		var it: Dictionary = inv[i]
		if int(it["id"]) == id:
			var take := mini(n, int(it["n"]))
			it["n"] = int(it["n"]) - take
			n -= take
			if int(it["n"]) <= 0:
				it["id"] = 0
				it["n"] = 0
			if n <= 0:
				return true
	return false


func armor_points() -> int:
	var s := 0
	for a in armor:
		if int(a) != 0:
			var it = Data.items.get(int(a))
			if it != null and it.has("dr"):
				s += int(it["dr"])
	return s


func damage_player(n: float, src: String) -> void:
	if dead:
		return
	var ap := armor_points()
	if ap > 0:
		var reduce := minf(0.8, float(ap) * 0.04)
		n = maxf(1.0, roundf(n * (1.0 - reduce)))
	hp -= n
	Audio.play("hurt")
	damaged.emit(src)
	if hp <= 0.0:
		hp = 0.0
		dead = true
		drag_held = false
		release_mine()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func respawn() -> void:
	dead = false
	hp = 20.0
	hunger = 20.0
	air = 10.0
	lava_t = 0.0
	drown_t = 0.0
	fall_start = -1.0
	_regen_t = 0.0
	_starve_t = 0.0
	flying = false
	armor.clear()
	for i in ARMOR_SIZE:
		armor.append(0)
	velocity = Vector3.ZERO
	if Game.world == null:
		return
	var sx := int(floorf(position.x))
	var sz := int(floorf(position.z))
	var sy := Data.HEIGHT - 2
	while sy > 1 and _block_at(float(sx), float(sy), float(sz)) == 0:
		sy -= 1
	position = Vector3(float(sx) + 0.5, float(sy) + 1.01, float(sz) + 0.5)


func _inv_get(i: int) -> Dictionary:
	if i >= 0 and i < inv.size():
		return inv[i]
	return {"id": 0, "n": 0}


func _inv_set(i: int, v: Dictionary) -> void:
	while inv.size() <= i:
		inv.append({"id": 0, "n": 0})
	inv[i] = v


func open_inventory(mode: String) -> void:
	ui_mode = mode
	release_mine()


func close_inventory() -> void:
	ui_mode = ""
	drag_held = false
	release_mine()
	if held != {} and int(held.get("id", 0)) != 0:
		inv_add(int(held["id"]), int(held["n"]))
		held = {}
	for i in CRAFT_GRID_SIZE:
		craft_grid[i] = {"id": 0, "n": 0}
	craft_out = {}


func recompute_craft() -> void:
	var m = Data.match_shaped(craft_grid)
	if m == null:
		m = Data.match_shapeless(craft_grid)
	craft_out = {} if m == null else {"id": int(m["id"]), "n": int(m["n"])}


func _slot_click(s: Dictionary, set_slot: Callable, area: String, button: int, shift: bool, release: bool = false) -> void:
	var has_s := int(s["id"]) != 0
	var had_held := held != {} and int(held.get("id", 0)) != 0
	if release:
		if had_held and drag_held:
			if not has_s:
				set_slot.call({"id": int(held["id"]), "n": int(held["n"])})
				held = {}
			elif int(s["id"]) == int(held["id"]):
				var rmax := _stack_max(int(s["id"]))
				var rt := mini(int(held["n"]), rmax - int(s["n"]))
				s["n"] = int(s["n"]) + rt
				held["n"] = int(held["n"]) - rt
				if int(held["n"]) <= 0:
					held = {}
			else:
				set_slot.call({"id": int(held["id"]), "n": int(held["n"])})
				held = {"id": int(s["id"]), "n": int(s["n"])}
		drag_held = false
		return
	if shift:
		if has_s and (area == "storage" or area == "hotbar"):
			var target: String = "hotbar" if area == "storage" else "storage"
			var off := 0 if target == "hotbar" else STORAGE_OFF
			for i in 9:
				var t: Dictionary = _inv_get(i + off)
				if int(t["id"]) != 0 and int(t["id"]) == int(s["id"]) and int(t["n"]) < _stack_max(int(t["id"])):
					var m := mini(int(s["n"]), _stack_max(int(t["id"])) - int(t["n"]))
					t["n"] = int(t["n"]) + m
					s["n"] = int(s["n"]) - m
					if int(s["n"]) <= 0:
						break
			for i in 9:
				if int(s["n"]) <= 0:
					break
				if int(_inv_get(i + off)["id"]) == 0:
					var m2 := mini(int(s["n"]), _stack_max(int(s["id"])))
					_inv_set(i + off, {"id": int(s["id"]), "n": m2})
					s["n"] = int(s["n"]) - m2
			set_slot.call(s if int(s["n"]) > 0 else {"id": 0, "n": 0})
		drag_held = false
		return
	if button == 2:
		if held != {} and int(held.get("id", 0)) != 0:
			if not has_s:
				set_slot.call({"id": int(held["id"]), "n": 1})
				held["n"] = int(held["n"]) - 1
			elif int(s["id"]) == int(held["id"]) and int(s["n"]) < _stack_max(int(s["id"])):
				s["n"] = int(s["n"]) + 1
				held["n"] = int(held["n"]) - 1
			if int(held["n"]) <= 0:
				held = {}
		elif has_s:
			held = {"id": int(s["id"]), "n": 1}
			if int(s["n"]) <= 1:
				set_slot.call({"id": 0, "n": 0})
			else:
				s["n"] = int(s["n"]) - 1
		drag_held = not had_held and int(held.get("id", 0)) != 0
		return
	if held != {} and int(held.get("id", 0)) != 0:
		if not has_s:
			set_slot.call({"id": int(held["id"]), "n": int(held["n"])})
			held = {}
		elif int(s["id"]) == int(held["id"]):
			var max_n := _stack_max(int(s["id"]))
			var t := mini(int(held["n"]), max_n - int(s["n"]))
			s["n"] = int(s["n"]) + t
			held["n"] = int(held["n"]) - t
			if int(held["n"]) <= 0:
				held = {}
		else:
			set_slot.call({"id": int(held["id"]), "n": int(held["n"])})
			held = {"id": int(s["id"]), "n": int(s["n"])}
		drag_held = false
	elif has_s:
		held = {"id": int(s["id"]), "n": int(s["n"])}
		set_slot.call({"id": 0, "n": 0})
		drag_held = true
	else:
		drag_held = false


func _cg_set(_i: int, v: Dictionary) -> void:
	craft_grid[_i] = v


func inv_slot_click(index: int, area: String, button: int, shift: bool, release: bool = false) -> void:
	var i: int = index + STORAGE_OFF if area == "storage" else index
	_slot_click(_inv_get(i), func(v: Dictionary) -> void: _inv_set(i, v), area, button, shift, release)


func craft_grid_click(index: int, button: int, shift: bool, release: bool = false) -> void:
	if index < 0 or index >= craft_grid.size():
		return
	if shift and not release:
		return
	_slot_click(craft_grid[index], func(v: Dictionary) -> void: craft_grid[index] = v, "craft", button, false, release)
	recompute_craft()


func craft_output_click() -> void:
	if craft_out == {} or int(craft_out.get("id", 0)) == 0:
		return
	var ok := inv_add(int(craft_out["id"]), int(craft_out["n"]))
	if ok:
		for i in CRAFT_GRID_SIZE:
			var c: Dictionary = craft_grid[i]
			if int(c["id"]) != 0:
				c["n"] = int(c["n"]) - int(craft_out["n"])
				if int(c["n"]) <= 0:
					c["id"] = 0
					c["n"] = 0
		recompute_craft()
		Audio.play("pickup")


func armor_slot_click(index: int, button: int, shift: bool, release: bool = false) -> void:
	if index < 0 or index >= armor.size():
		return
	var kind: String = ARMOR_SLOTS[index]
	var had_held := held != {} and int(held.get("id", 0)) != 0
	if release:
		if had_held and drag_held:
			var it3 = Data.items.get(int(held["id"]))
			if it3 != null and str(it3.get("armor", "")) == kind and int(armor[index]) == 0:
				armor[index] = int(held["id"])
				held = {}
		drag_held = false
		return
	if button == 2:
		if had_held:
			var it = Data.items.get(int(held["id"]))
			if it != null and str(it.get("armor", "")) == kind:
				if int(held["n"]) > 1:
					armor[index] = int(held["id"])
					held["n"] = int(held["n"]) - 1
				elif int(armor[index]) == 0:
					armor[index] = int(held["id"])
					held = {}
		drag_held = false
		return
	if shift:
		drag_held = false
		return
	if had_held:
		var it2 = Data.items.get(int(held["id"]))
		if it2 != null and str(it2.get("armor", "")) == kind:
			if int(armor[index]) == 0:
				armor[index] = int(held["id"])
				held = {}
			elif int(armor[index]) != int(held["id"]):
				var old := int(armor[index])
				armor[index] = int(held["id"])
				held = {"id": old, "n": 1}
	elif int(armor[index]) != 0:
		held = {"id": int(armor[index]), "n": 1}
		armor[index] = 0
	drag_held = not had_held and int(held.get("id", 0)) != 0


func inv_selected() -> Dictionary:
	if sel >= 0 and sel < inv.size():
		return inv[sel]
	return {"id": 0, "n": 0}


func inv_consume_selected() -> void:
	var it: Dictionary = inv[sel]
	it["n"] = int(it["n"]) - 1
	if int(it["n"]) <= 0:
		it["id"] = 0
		it["n"] = 0
