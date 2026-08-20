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
		return {"sel": 0, "slots": [], "armor": [], "points": 0, "held": {}, "craft_grid": [], "craft_out": {}}
	var p = Game.player
	var slots: Array = []
	for i in p.inv.size():
		if int(p.inv[i]["id"]) != 0:
			slots.append({"i": i, "id": int(p.inv[i]["id"]), "n": int(p.inv[i]["n"])})
	var grid: Array = []
	for i in p.craft_grid.size():
		if int(p.craft_grid[i]["id"]) != 0:
			grid.append({"i": i, "id": int(p.craft_grid[i]["id"]), "n": int(p.craft_grid[i]["n"])})
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
