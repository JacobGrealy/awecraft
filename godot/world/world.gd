extends Node3D

const ChunkScript = preload("res://world/chunk.gd")
const DropScript = preload("res://entities/drop.gd")

const LIGHT_FLUSH_MARGIN := 2
const LIGHT_NEIGHBOR := 1
const FLUSH_FRAME_BUDGET_MS := 40
const FLUSH_MAX_PER_FRAME := 2
const BULK_LIGHT_CELLS_MAX := 3000
const FLUID_TICK_INTERVAL := 0.2
const FLUID_DIRS := [
	[1, 0],
	[-1, 0],
	[0, 1],
	[0, -1],
]

const BUILD_FAST_US := 15000
const DRAIN_FRAME_BUDGET_US := 30000

var render_radius := 4
var fluid_tick_radius := 14
var collision_enabled := true
var chunks := {}
var chunk_keys := {}
var edits := {}
var light_dirty := {}
var light_pending: Array = []
var light_pending_set := {}
var flush_eff: Dictionary = {}
var flush_active := false
var perf_flush_frames := 0
var perf_max_frame_ms := 0
var perf_single_build_ms := 0
var perf_build_units := 0
var perf_drain_frames := 0
var perf_max_drain_ms := 0
var perf_gen_ms := 0
var perf_build_ms := 0
var fluid_tick_samples: Array = []
var fluid_dirty := {}
var fluid_sim_enabled := true
var fluid_timer: Timer = null
var build_queue: Array = []
var queued_keys := {}
var last_build_us := 0
var last_pcx := 0
var last_pcz := 0
var timing := false
var fluid_sleep := true
var tick_time := false
var _fluid_write := false
var _fluid_stable := 0
var _fluid_sig := ""
var tex_refresh: Array = []


func _ready() -> void:
	timing = OS.get_environment("AWECRAFT_TIMING") == "1"
	fluid_sleep = OS.get_environment("AWECRAFT_FLUID_SLEEP") != "0"
	tick_time = OS.get_environment("AWECRAFT_TICKTIME") == "1"
	Game.world = self
	fluid_timer = Timer.new()
	fluid_timer.wait_time = FLUID_TICK_INTERVAL
	fluid_timer.autostart = true
	fluid_timer.timeout.connect(_on_fluid_tick)
	add_child(fluid_timer)


func _on_fluid_tick() -> void:
	if fluid_sim_enabled and (Game.mode == "play" or Game.mode == "pause"):
		tick_fluids()


func _process(_delta: float) -> void:
	if light_dirty.is_empty() and fluid_dirty.is_empty() and build_queue.is_empty() and light_pending.is_empty() and tex_refresh.is_empty():
		return
	var was_active := flush_active
	var added := false
	for key in light_dirty:
		var c = chunks.get(key)
		if c != null and c.mesh_built and not light_pending_set.has(key):
			light_pending.append(key)
			light_pending_set[key] = true
			added = true
	light_dirty = {}
	if added and not was_active:
		flush_active = true
		flush_eff = {}
		perf_flush_frames = 0
		perf_max_frame_ms = 0
		perf_single_build_ms = 0
	elif added and was_active:
		flush_eff = {}
	var fluid_list: Array[Node3D] = []
	for key in fluid_dirty:
		var c = chunks.get(key)
		if c != null and c.mesh_built and not light_pending_set.has(key):
			fluid_list.append(c)
	fluid_dirty = {}
	if not light_pending.is_empty():
		var pb := _pending_box()
		var pbox_ok := false
		if int(pb["mnx"]) >= 0:
			pbox_ok = _box_ready(int(pb["mnx"]) - LIGHT_FLUSH_MARGIN, int(pb["mnz"]) - LIGHT_FLUSH_MARGIN, int(pb["mxx"]) + LIGHT_FLUSH_MARGIN, int(pb["mxz"]) + LIGHT_FLUSH_MARGIN)
		if flush_eff.is_empty() and pbox_ok and _bulk_box_cells() <= BULK_LIGHT_CELLS_MAX:
			flush_eff = _bulk_light()
		var t0 := Time.get_ticks_msec()
		var built := 0
		var spun := 0
		var max_spin := light_pending.size()
		while built < FLUSH_MAX_PER_FRAME and not light_pending.is_empty():
			if built > 0 and Time.get_ticks_msec() - t0 > FLUSH_FRAME_BUDGET_MS:
				break
			var key2: String = light_pending.pop_front()
			light_pending_set.erase(key2)
			var c2 = chunks.get(key2)
			if c2 == null or not c2.mesh_built:
				continue
			if not _build_ready(int(c2.cx), int(c2.cz)):
				light_pending.append(key2)
				light_pending_set[key2] = true
				spun += 1
				if spun >= max_spin:
					break
				continue
			var tb := Time.get_ticks_msec()
			var eff = flush_eff
			c2.build_mesh(get_block, eff)
			var dt := Time.get_ticks_msec() - tb
			if dt > perf_single_build_ms:
				perf_single_build_ms = dt
			built += 1
		if built > 0:
			perf_flush_frames += 1
			var ft := Time.get_ticks_msec() - t0
			if ft > perf_max_frame_ms:
				perf_max_frame_ms = ft
		if light_pending.is_empty():
			flush_active = false
			flush_eff = {}
	for c in fluid_list:
		var cc: Node3D = c
		if _build_ready(int(cc.cx), int(cc.cz)):
			cc.build_mesh(get_block, cc.last_eff)
		else:
			fluid_dirty[_key(int(cc.cx), int(cc.cz))] = true
	_drain_build_queue()
	_drain_tex_refresh()


func refresh_textures() -> void:
	tex_refresh = chunks.keys().duplicate()


func _drain_tex_refresh() -> void:
	if tex_refresh.is_empty():
		return
	var t0 := Time.get_ticks_msec()
	var done := 0
	while done < FLUSH_MAX_PER_FRAME and not tex_refresh.is_empty():
		if done > 0 and Time.get_ticks_msec() - t0 > FLUSH_FRAME_BUDGET_MS:
			break
		var key = tex_refresh.pop_back()
		var c: Node3D = chunks.get(key)
		if c == null or not c.mesh_built:
			continue
		if not _build_ready(int(c.cx), int(c.cz)):
			tex_refresh.push_back(key)
			continue
		c.build_mesh(get_block, c.last_eff)
		done += 1


func _dequeue(key: String) -> void:
	queued_keys.erase(key)
	for i in range(build_queue.size()):
		if build_queue[i]["key"] == key:
			build_queue.remove_at(i)
			return


func _insert_sorted(e: Dictionary) -> void:
	var i := 0
	while i < build_queue.size() and int(build_queue[i]["d"]) <= int(e.d):
		i += 1
	build_queue.insert(i, e)
	queued_keys[e["key"]] = "data" if bool(e["data_only"]) else "build"


func _enqueue_build(cx: int, cz: int) -> void:
	var key := _key(cx, cz)
	var c = chunks.get(key)
	if c == null or c.mesh_built:
		return
	var old = queued_keys.get(key)
	if old == "build":
		return
	if old == "data":
		_dequeue(key)
	_insert_sorted({"key": key, "cx": cx, "cz": cz, "d": absi(cx - last_pcx) + absi(cz - last_pcz), "data_only": false})


func _enqueue_data(cx: int, cz: int) -> void:
	var key := _key(cx, cz)
	var old = queued_keys.get(key)
	if old != null:
		return
	var c = chunks.get(key)
	if c != null and not c.data.is_empty():
		return
	_insert_sorted({"key": key, "cx": cx, "cz": cz, "d": absi(cx - last_pcx) + absi(cz - last_pcz), "data_only": true})


func _build_ready(cx: int, cz: int) -> bool:
	for n in [[1, 0], [-1, 0], [0, 1], [0, -1]]:
		var nc = chunks.get(_key(cx + int(n[0]), cz + int(n[1])))
		if nc == null or nc.data.is_empty():
			return false
	return true


func _box_ready(mnx: int, mnz: int, mxx: int, mxz: int) -> bool:
	for cx in range(mnx, mxx + 1):
		for cz in range(mnz, mxz + 1):
			var c = chunks.get(_key(cx, cz))
			if c == null or c.data.is_empty():
				return false
	return true


func _startup_pending() -> bool:
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var c = chunks.get(_key(last_pcx + dx, last_pcz + dz))
			if c == null or not c.mesh_built:
				return true
	return false


func _pending_box() -> Dictionary:
	var mnx := 2147483647
	var mnz := 2147483647
	var mxx := -2147483647
	var mxz := -2147483647
	for key in light_pending:
		var c = chunks.get(key)
		if c == null:
			continue
		var x0: int = c.cx * ChunkScript.SIZE
		var z0: int = c.cz * ChunkScript.SIZE
		mnx = mini(mnx, x0)
		mxx = maxi(mxx, x0 + ChunkScript.SIZE - 1)
		mnz = mini(mnz, z0)
		mxz = maxi(mxz, z0 + ChunkScript.SIZE - 1)
	if mnx > mxx:
		return {"mnx": -1, "mnz": -1, "mxx": -1, "mxz": -1}
	return {"mnx": mnx, "mnz": mnz, "mxx": mxx, "mxz": mxz}


func _drain_build_queue() -> void:
	if build_queue.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	var budget := 3 if _startup_pending() else (2 if last_build_us < BUILD_FAST_US else 1)
	var units := 0
	while budget > 0 and not build_queue.is_empty():
		if Time.get_ticks_usec() - t0 > DRAIN_FRAME_BUDGET_US:
			break
		var found := -1
		var phase := ""
		var i := 0
		while i < build_queue.size():
			var e: Dictionary = build_queue[i]
			var key: String = e["key"]
			var c = chunks.get(key)
			var cx: int = int(e["cx"])
			var cz: int = int(e["cz"])
			var lim := render_radius + (1 if bool(e["data_only"]) else 0)
			if c == null or c.mesh_built or absi(cx - last_pcx) > lim or absi(cz - last_pcz) > lim:
				build_queue.remove_at(i)
				queued_keys.erase(key)
				continue
			if c.data.is_empty():
				found = i
				phase = "data"
				break
			if bool(e["data_only"]):
				build_queue.remove_at(i)
				queued_keys.erase(key)
				continue
			if _build_ready(cx, cz):
				found = i
				phase = "build"
				break
			i += 1
		if found < 0:
			break
		var e2: Dictionary = build_queue[found]
		var key2: String = e2["key"]
		var c2: Node3D = chunks.get(key2)
		var cx2: int = int(e2["cx"])
		var cz2: int = int(e2["cz"])
		if phase == "data":
			var tg := Time.get_ticks_msec()
			c2.data = WorldGen.generate(cx2, cz2, Game.world_seed)
			c2.init_fl()
			_apply_edits_to_chunk(c2)
			var dg := Time.get_ticks_msec() - tg
			if timing:
				print("GENCHUNK %d,%d gen_ms=%d" % [cx2, cz2, dg])
			perf_gen_ms += dg
			units += 1
			budget -= 1
			continue
		build_queue.remove_at(found)
		queued_keys.erase(key2)
		var tb := Time.get_ticks_msec()
		c2.build_mesh(get_block)
		var dt := Time.get_ticks_msec() - tb
		last_build_us = dt * 1000
		if timing:
			print("BUILDCHUNK %d,%d gen_ms=0 build_ms=%d" % [cx2, cz2, dt])
		perf_build_ms += dt
		units += 1
		budget -= 1
	if units > 0:
		perf_build_units += units
		perf_drain_frames += 1
		var fm := (Time.get_ticks_usec() - t0) / 1000.0
		if fm > perf_max_drain_ms:
			perf_max_drain_ms = fm


func _key(cx: int, cz: int) -> String:
	var k := cx * 65536 + cz
	var s = chunk_keys.get(k)
	if s == null:
		s = "%d,%d" % [cx, cz]
		chunk_keys[k] = s
	return s


func _make_chunk_node(cx: int, cz: int) -> Node3D:
	var c: Node3D = ChunkScript.new()
	c.cx = cx
	c.cz = cz
	c.position = Vector3(cx * 16, 0, cz * 16)
	c.collision_enabled = collision_enabled
	add_child(c)
	chunks[_key(cx, cz)] = c
	return c


func create_chunk(cx: int, cz: int, mesh_now: bool) -> Node3D:
	var c: Node3D = _make_chunk_node(cx, cz)
	c.data = WorldGen.generate(cx, cz, Game.world_seed)
	c.init_fl()
	_apply_edits_to_chunk(c)
	if mesh_now:
		c.build_mesh(get_block)
	return c


func stub_chunk(cx: int, cz: int) -> Node3D:
	return _make_chunk_node(cx, cz)


func _chunk_data(cx: int, cz: int) -> Node3D:
	var c = chunks.get(_key(cx, cz))
	if c == null:
		c = create_chunk(cx, cz, false)
		if absi(cx - last_pcx) <= render_radius and absi(cz - last_pcz) <= render_radius:
			_enqueue_build(cx, cz)
	elif c.data.is_empty():
		var tg := Time.get_ticks_msec()
		c.data = WorldGen.generate(cx, cz, Game.world_seed)
		c.init_fl()
		_apply_edits_to_chunk(c)
		if timing:
			print("ONDEMANDGEN %d,%d gen_ms=%d" % [cx, cz, Time.get_ticks_msec() - tg])
	return c


func recenter(wx: float, wz: float, mesh_now := true) -> void:
	last_pcx = int(floorf(wx / 16.0))
	last_pcz = int(floorf(wz / 16.0))
	var pcx := last_pcx
	var pcz := last_pcz
	var to_free: Array[String] = []
	for key in chunks:
		var c: Node3D = chunks[key]
		if absi(c.cx - pcx) > render_radius or absi(c.cz - pcz) > render_radius:
			if absi(c.cx - pcx) > render_radius + 1 or absi(c.cz - pcz) > render_radius + 1:
				to_free.append(key)
	for key in to_free:
		var c: Node3D = chunks[key]
		chunks.erase(key)
		_dequeue(key)
		light_pending_set.erase(key)
		light_pending.erase(key)
		c.queue_free()
	if not mesh_now:
		var make: Array[Dictionary] = []
		for dx in range(-render_radius, render_radius + 1):
			for dz in range(-render_radius, render_radius + 1):
				var cx := pcx + dx
				var cz := pcz + dz
				if not chunks.has(_key(cx, cz)):
					make.append({"cx": cx, "cz": cz, "d": absi(dx) + absi(dz)})
		make.sort_custom(func(a, b): return a.d < b.d)
		for e in make:
			create_chunk(e.cx, e.cz, false)
		return
	for dx in range(-render_radius, render_radius + 1):
		for dz in range(-render_radius, render_radius + 1):
			var cx := pcx + dx
			var cz := pcz + dz
			if not chunks.has(_key(cx, cz)):
				stub_chunk(cx, cz)
	for dx in range(-(render_radius + 1), render_radius + 2):
		for dz in range(-(render_radius + 1), render_radius + 2):
			if maxi(absi(dx), absi(dz)) != render_radius + 1:
				continue
			var cx := pcx + dx
			var cz := pcz + dz
			if not chunks.has(_key(cx, cz)):
				stub_chunk(cx, cz)
	for key in chunks:
		var c: Node3D = chunks[key]
		if c.mesh_built:
			continue
		if absi(c.cx - pcx) <= render_radius and absi(c.cz - pcz) <= render_radius:
			_enqueue_build(int(c.cx), int(c.cz))
		elif absi(c.cx - pcx) <= render_radius + 1 and absi(c.cz - pcz) <= render_radius + 1:
			_enqueue_data(int(c.cx), int(c.cz))


func get_block(x: int, y: int, z: int) -> int:
	if y < 0 or y >= Data.HEIGHT:
		return 0
	var c := _chunk_data(int(floorf(float(x) / 16.0)), int(floorf(float(z) / 16.0)))
	return c.get_local(x & 15, y, z & 15)


func set_block(x: int, y: int, z: int, id: int, create := true) -> void:
	if y < 0 or y >= Data.HEIGHT:
		return
	var cx := int(floorf(float(x) / 16.0))
	var cz := int(floorf(float(z) / 16.0))
	var c: Node3D
	if create:
		c = _chunk_data(cx, cz)
	else:
		c = chunks.get(_key(cx, cz))
	if c == null:
		return
	var lx := x & 15
	var lz := z & 15
	c.set_local(lx, y, lz, id)
	var fi := (y << 8) | (lz << 4) | lx
	if is_fluid_id(id):
		if c.fl[fi] == 0:
			c.fl[fi] = 7
	else:
		c.fl[fi] = 0
	c.col_dirty = true
	_mark_light_around(cx, cz)
	if _fluid_near(x, y, z):
		_fluid_write = true
	_record_edit(cx, cz, fi, id, int(c.fl[fi]))


func _mark_light_around(cx: int, cz: int) -> void:
	for dx in range(-LIGHT_NEIGHBOR, LIGHT_NEIGHBOR + 1):
		for dz in range(-LIGHT_NEIGHBOR, LIGHT_NEIGHBOR + 1):
			light_dirty[_key(cx + dx, cz + dz)] = true


func _mark_fluid_around(cx: int, cz: int) -> void:
	for dx in range(-LIGHT_NEIGHBOR, LIGHT_NEIGHBOR + 1):
		for dz in range(-LIGHT_NEIGHBOR, LIGHT_NEIGHBOR + 1):
			fluid_dirty[_key(cx + dx, cz + dz)] = true


func _record_edit(cx: int, cz: int, fi: int, b: int, f: int) -> void:
	var key := _key(cx, cz)
	if not edits.has(key):
		edits[key] = {}
	edits[key][fi] = {"b": b, "f": f}


func _apply_edits_to_chunk(c: Node3D) -> void:
	var key := _key(c.cx, c.cz)
	if not edits.has(key):
		return
	var data: PackedByteArray = c.data
	if data.is_empty():
		return
	var fl: PackedByteArray = c.fl
	if fl.size() != data.size():
		fl.resize(data.size())
	var cells: Dictionary = edits[key]
	for fkey in cells:
		var e: Dictionary = cells[fkey]
		data[int(fkey)] = int(e.get("b", 0))
		fl[int(fkey)] = int(e.get("f", 0))
	c.col_dirty = true
	_mark_light_around(c.cx, c.cz)
	_mark_fluid_around(c.cx, c.cz)


func _bulk_box_cells() -> int:
	var pb := _pending_box()
	if int(pb["mnx"]) < 0:
		return 0
	var mnx: int = int(pb["mnx"])
	var mnz: int = int(pb["mnz"])
	var mxx: int = int(pb["mxx"])
	var mxz: int = int(pb["mxz"])
	return (mxx - mnx + 1 + LIGHT_FLUSH_MARGIN * 2) * (mxz - mnz + 1 + LIGHT_FLUSH_MARGIN * 2) * Data.HEIGHT


func _bulk_light() -> Dictionary:
	var pb := _pending_box()
	if int(pb["mnx"]) < 0:
		return {}
	var mnx: int = int(pb["mnx"])
	var mnz: int = int(pb["mnz"])
	var mxx: int = int(pb["mxx"])
	var mxz: int = int(pb["mxz"])
	var box := {
		"min": Vector3i(mnx - LIGHT_FLUSH_MARGIN, 0, mnz - LIGHT_FLUSH_MARGIN),
		"max": Vector3i(mxx + LIGHT_FLUSH_MARGIN, Data.HEIGHT - 1, mxz + LIGHT_FLUSH_MARGIN),
	}
	return Lighting.compute_light_flat(box, self)


func _build_batch(list: Array, margin: int) -> void:
	if list.is_empty():
		return
	var mnx := 2147483647
	var mnz := 2147483647
	var mxx := -2147483647
	var mxz := -2147483647
	for c in list:
		var cc: Node3D = c
		var x0: int = cc.cx * ChunkScript.SIZE
		var z0: int = cc.cz * ChunkScript.SIZE
		mnx = mini(mnx, x0)
		mxx = maxi(mxx, x0 + ChunkScript.SIZE - 1)
		mnz = mini(mnz, z0)
		mxz = maxi(mxz, z0 + ChunkScript.SIZE - 1)
	var box := {
		"min": Vector3i(mnx - margin, 0, mnz - margin),
		"max": Vector3i(mxx + margin, Data.HEIGHT - 1, mxz + margin),
	}
	var eff := Lighting.compute_light_flat(box, self)
	for c in list:
		var cc: Node3D = c
		cc.build_mesh(get_block, eff)


func surface_top(x: int, z: int) -> int:
	for y in range(Data.HEIGHT - 1, -1, -1):
		var b := get_block(x, y, z)
		if b != 0:
			var info = Data.block(b)
			if info.solid:
				return y
	return 0


func spawn_point() -> Vector3:
	var top := surface_top(WorldGen.SPAWN_X, WorldGen.SPAWN_Z)
	return Vector3(WorldGen.SPAWN_X + 0.5, float(top) + 1.0, WorldGen.SPAWN_Z + 0.5)


func light_at(x: int, y: int, z: int) -> Dictionary:
	var r := 8
	var mn := Vector3i(x - r, maxi(y - r, 0), z - r)
	var mx := Vector3i(x + r, mini(y + r, Data.HEIGHT - 1), z + r)
	var res: Dictionary = Lighting.compute_light_split({"min": mn, "max": mx}, self)
	var c := Vector3i(x, y, z)
	return {"sky": int(res.sky.get(c, 0)), "block": int(res.block.get(c, 0)), "eff": int(res.eff.get(c, 0))}


func mesh_info() -> Array:
	var out := []
	for key in chunks:
		var c: Node3D = chunks[key]
		var e := {"pos": [int(c.position.x), int(c.position.z)], "built": c.mesh_built}
		var mi = c.mesh_instance
		if mi and mi.mesh:
			var m: ArrayMesh = mi.mesh
			e["aabb"] = [m.get_aabb().position, m.get_aabb().size]
			var vc := []
			for s in range(m.get_surface_count()):
				var arrs = m.surface_get_arrays(s)
				vc.append((arrs[Mesh.ARRAY_VERTEX] as PackedVector3Array).size())
			e["verts"] = vc
		var fi = c.fluid_instance
		if fi and fi.mesh:
			var fm: ArrayMesh = fi.mesh
			e["faabb"] = [fm.get_aabb().position, fm.get_aabb().size]
			var fvc := []
			for s in range(fm.get_surface_count()):
				var farrs = fm.surface_get_arrays(s)
				fvc.append((farrs[Mesh.ARRAY_VERTEX] as PackedVector3Array).size())
			e["fverts"] = fvc
		out.append(e)
	return out


func spawn_drop(id: int, pos: Vector3) -> void:
	if Game.drops == null:
		return
	if Game.drops.get_child_count() >= 80:
		return
	var d: Node3D = DropScript.new()
	d.id = id
	d.position = pos
	Game.drops.add_child(d)


func is_fluid_id(id: int) -> bool:
	return id == 5 or id == 24


func fluid_replaceable(b: int) -> bool:
	if b == 0:
		return true
	var info = Data.block(b)
	if info == null:
		return false
	# Web: fluidReplaceable(b) = b===0 || (BLOCKS[b] && BLOCKS[b].cross). In the web,
	# cross marks only small cutout plants, and water/lava use `blend` — never cross —
	# so fluid cells are NOT replaceable by other fluid cells. That is exactly why
	# the natural sea is stable: a sea cell sees water below (no down-flow) and water
	# on all four sides (no sideways flow), so it never moves. Godot's Data reuses
	# cross=true for the translucent render pass, so fluid ids must be excluded here
	# to keep the simulation faithful and the sea from churning or draining.
	if is_fluid_id(b):
		return false
	return bool(info.get("cross", false)) and not bool(info.solid)


func set_fluid(x: int, y: int, z: int, id: int, lvl: int, create := false) -> void:
	if y < 0 or y >= Data.HEIGHT:
		return
	lvl = clampi(lvl, 0, 8)
	var cx := int(floorf(float(x) / 16.0))
	var cz := int(floorf(float(z) / 16.0))
	var c: Node3D
	if create:
		c = _chunk_data(cx, cz)
	else:
		c = chunks.get(_key(cx, cz))
	if c == null:
		return
	var lx := x & 15
	var lz := z & 15
	var i := (y << 8) | (lz << 4) | lx
	if c.get_local(lx, y, lz) == id and c.fl[i] == lvl:
		return
	c.set_local(lx, y, lz, id)
	c.fl[i] = lvl
	_fluid_write = true
	_mark_fluid_around(cx, cz)
	_record_edit(cx, cz, i, id, lvl)


func fluid_level(x: int, y: int, z: int) -> int:
	if y < 0 or y >= Data.HEIGHT:
		return 0
	var cx := int(floorf(float(x) / 16.0))
	var cz := int(floorf(float(z) / 16.0))
	var c = chunks.get(_key(cx, cz))
	if c == null or c.data.is_empty():
		return 0
	var i := (y << 8) | ((z & 15) << 4) | (x & 15)
	var v: int = c.fl[i]
	if v == 0:
		var b: int = c.data[i]
		if is_fluid_id(b):
			v = 8
	return v


func fluid_at(x: int, y: int, z: int) -> Array:
	return [get_block(x, y, z), fluid_level(x, y, z)]


func _nb_block(nc: Node3D, li: int, gx: int, gy: int, gz: int) -> int:
	if nc != null and not nc.data.is_empty():
		return nc.data[li]
	return get_block(gx, gy, gz)


func tick_fluids() -> void:
	if chunks.is_empty():
		return
	var cl: Array[Vector2i] = []
	if Game.player != null:
		var px := floori(Game.player.position.x)
		var pz := floori(Game.player.position.z)
		var cx0 := int(floorf(float(px - fluid_tick_radius) / 16.0))
		var cx1 := int(floorf(float(px + fluid_tick_radius) / 16.0))
		var cz0 := int(floorf(float(pz - fluid_tick_radius) / 16.0))
		var cz1 := int(floorf(float(pz + fluid_tick_radius) / 16.0))
		for cx in range(cx0, cx1 + 1):
			for cz in range(cz0, cz1 + 1):
				cl.append(Vector2i(cx, cz))
	else:
		for key in chunks:
			var c: Node3D = chunks[key]
			cl.append(Vector2i(c.cx, c.cz))
	var t0 := Time.get_ticks_usec()
	var sig := "all"
	if Game.player != null and not cl.is_empty():
		sig = "%d:%d" % [cl.size(), int(cl[0].x) * 4096 + int(cl[0].y)]
	if sig != _fluid_sig:
		_fluid_sig = sig
		_fluid_stable = 0
	if _fluid_write:
		_fluid_write = false
		_fluid_stable = 0
	else:
		_fluid_stable += 1
	if fluid_sleep and _fluid_stable >= 3:
		if tick_time:
			print("TICKMS ", (Time.get_ticks_usec() - t0) / 1000.0)
		fluid_tick_samples.append((Time.get_ticks_usec() - t0) / 1000.0)
		return
	var hmax := Data.HEIGHT - 1
	for pos in cl:
		var c: Node3D = chunks.get(_key(pos.x, pos.y))
		if c == null or c.data.is_empty():
			continue
		var data: PackedByteArray = c.data
		var fl: PackedByteArray = c.fl
		var cx: int = int(c.cx)
		var cz: int = int(c.cz)
		var wx0: int = cx * 16
		var wz0: int = cz * 16
		var ne: Node3D = chunks.get(_key(cx + 1, cz))
		var nw: Node3D = chunks.get(_key(cx - 1, cz))
		var ns: Node3D = chunks.get(_key(cx, cz + 1))
		var nn: Node3D = chunks.get(_key(cx, cz - 1))
		for y in range(1, hmax):
			var ib: int = (y - 1) << 8
			var ia: int = y << 8
			var ib2: int = (y - 2) << 8
			for lz in range(16):
				var lb: int = lz << 4
				for lx in range(16):
					var i := ia | lb | lx
					var b: int = data[i]
					var l: int
					if fl[i] == 0:
						# Natural (worldgen) water is a stationary source (fl=0, MC-style):
						# oceans/rivers generate stationary and do not flow until
						# block-updated. fl=0 cells are skipped entirely (no lava reaction,
						# no fall, no sideways spread) so the natural ocean produces ZERO
						# writes and stays 100% stable. Player/bucket water arrives with an
						# explicit fl (8) and runs the full fall/spread pass below.
						continue
					else:
						if not is_fluid_id(b):
							fl[i] = 0
							continue
						l = fl[i]
					var x := wx0 + lx
					var z := wz0 + lz
					var below: int = data[ib | lb | lx]
					if b == 5 and below == 24:
						set_block(x, y - 1, z, 25 if l == 8 else 9, false)
						continue
					if b == 24 and below == 5:
						set_block(x, y - 1, z, 9, false)
						continue
					var n_l: int = 7 if l == 8 else l - 1
					if fluid_replaceable(below):
						set_fluid(x, y - 1, z, b, 8, false)
						set_fluid(x, y, z, 0, 0, false)
					elif n_l <= 0:
						continue
					else:
						var hold := false
						if is_fluid_id(below) and y >= 2 and fluid_replaceable(data[ib2 | lb | lx]):
							hold = true
						if not hold:
							for d in FLUID_DIRS:
								var ddx: int = int(d[0])
								var ddz: int = int(d[1])
								var nx := x + ddx
								var nz := z + ddz
								var nb: int
								if ddx == 1 and lx == 15:
									nb = _nb_block(ne, ia | lb, nx, y, nz)
								elif ddx == -1 and lx == 0:
									nb = _nb_block(nw, ia | lb | 15, nx, y, nz)
								elif ddz == 1 and lz == 15:
									nb = _nb_block(ns, ia | lx, nx, y, nz)
								elif ddz == -1 and lz == 0:
									nb = _nb_block(nn, ia | 240 | lx, nx, y, nz)
								else:
									nb = data[ia | ((nz & 15) << 4) | (nx & 15)]
								if fluid_replaceable(nb):
									set_fluid(nx, y, nz, b, n_l, false)
								elif nb == 5 and b == 24:
									set_block(nx, y, nz, 9, false)
								elif nb == 24 and b == 5:
									set_block(nx, y, nz, 9, false)
	if tick_time:
		print("TICKMS ", (Time.get_ticks_usec() - t0) / 1000.0)
	fluid_tick_samples.append((Time.get_ticks_usec() - t0) / 1000.0)


func _fluid_near(x: int, y: int, z: int) -> bool:
	if is_fluid_id(get_block(x, y, z)) or fluid_level(x, y, z) > 0:
		return true
	if y > 0:
		if is_fluid_id(get_block(x, y - 1, z)) or fluid_level(x, y - 1, z) > 0:
			return true
	if y < Data.HEIGHT - 1:
		if is_fluid_id(get_block(x, y + 1, z)) or fluid_level(x, y + 1, z) > 0:
			return true
	if is_fluid_id(get_block(x + 1, y, z)) or fluid_level(x + 1, y, z) > 0:
		return true
	if is_fluid_id(get_block(x - 1, y, z)) or fluid_level(x - 1, y, z) > 0:
		return true
	if is_fluid_id(get_block(x, y, z + 1)) or fluid_level(x, y, z + 1) > 0:
		return true
	if is_fluid_id(get_block(x, y, z - 1)) or fluid_level(x, y, z - 1) > 0:
		return true
	return false
