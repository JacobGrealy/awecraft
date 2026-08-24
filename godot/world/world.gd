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
const DRAIN_MS_DEFAULT := 30

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
var band_buckets: Array = []
var dq_b := 0
var dq_i := 0
var mq_b := 0
var mq_i := 0
var queue_size := 0
var queued_keys := {}
var drain_budget_ms := DRAIN_MS_DEFAULT
var gen_budget_ms := -1
var last_build_us := 0
var last_pcx := 0
var last_pcz := 0
var timing := false
var _recprobe := false
var _rp_free_ms := 0.0
var _rp_stub_ms := 0.0
var _rp_stub_n := 0
var _rp_walk_ms := 0.0
var _rp_insert_ms := 0.0
var _rp_dequeue_ms := 0.0
var _rp_deq_n := 0
var _rp_drain_stub_ms := 0.0
var _rp_drain_stub_n := 0
var fluid_sleep := true
var tick_time := false
var _fluid_write := false
var _fluid_stable := 0
var _fluid_sig := ""
var tex_refresh: Array = []
var threadgen := false
var threadgen_max := 3
var threadgen_pool = null
var threadgen_inflight: Array = []
var _tg_slots = {}
var _tg_inflight_keys: Dictionary = {}
var _tg_debug := false
var _tg_enq := 0
var _tg_dedup := 0
var _tg_capdrop := 0
var _tg_handoff := 0
var _tg_stale := 0
var _tg_datadrop := 0

func _ready() -> void:
	timing = OS.get_environment("AWECRAFT_TIMING") == "1"
	var tg := OS.get_environment("AWECRAFT_THREADGEN")
	if OS.get_environment("AWECRAFT_FORCE_WEB") == "1":
		print("THREADGEN off (web sim) threadgen=false pool=0")
	elif tg != "0" and OS.has_feature("web_nothreads"):
		print("THREADGEN off (web_nothreads) threadgen=false pool=0")
	elif tg != "0":
		var nenv := OS.get_environment("AWECRAFT_THREADGEN_N")
		threadgen_max = maxi(1, mini(OS.get_processor_count() - 2, 3))
		if nenv != "":
			threadgen_max = maxi(1, nenv.to_int())
		threadgen_max = mini(threadgen_max, 6)
		threadgen_pool = Engine.get_singleton("WorkerThreadPool")
		threadgen = true
		_tg_debug = OS.get_environment("AWECRAFT_TGDEBUG") == "1"
		print("THREADGEN on threadgen=true pool=%d" % threadgen_max)
	_recprobe = OS.get_environment("AWECRAFT_RECPROBE") == "1"
	var dr := OS.get_environment("AWECRAFT_DRAIN_MS")
	if dr != "" and dr.to_int() > 0:
		drain_budget_ms = dr.to_int()
	var gb := OS.get_environment("AWECRAFT_GEN_BUDGET")
	if gb != "" and gb.to_int() >= 0:
		gen_budget_ms = gb.to_int()
	fluid_sleep = OS.get_environment("AWECRAFT_FLUID_SLEEP") != "0"
	tick_time = OS.get_environment("AWECRAFT_TICKTIME") == "1"
	Game.world = self
	fluid_timer = Timer.new()
	fluid_timer.wait_time = FLUID_TICK_INTERVAL
	fluid_timer.autostart = true
	fluid_timer.timeout.connect(_on_fluid_tick)
	add_child(fluid_timer)

func _exit_tree() -> void:
	threadgen = false

func _on_fluid_tick() -> void:
	if fluid_sim_enabled and (Game.mode == "play" or Game.mode == "pause"):
		tick_fluids()

func _process(_delta: float) -> void:
	if light_dirty.is_empty() and fluid_dirty.is_empty() and queue_size == 0 and light_pending.is_empty() and tex_refresh.is_empty():
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
	threadgen_poll()
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

func _convert_data_to_build(key: String) -> void:
	for b in range(band_buckets.size()):
		var arr: Array = band_buckets[b]
		for i in range(arr.size()):
			if arr[i]["key"] == key:
				arr[i]["data_only"] = false
				queued_keys[key] = "build"
				if b < mq_b or (b == mq_b and i < mq_i):
					mq_b = b
					mq_i = i
				return

func _enqueue_build(cx: int, cz: int) -> void:
	var key := _key(cx, cz)
	var c = chunks.get(key)
	if c != null and c.mesh_built:
		return
	var old = queued_keys.get(key)
	if old == "build":
		return
	if old == "data":
		_convert_data_to_build(key)
		return
	if band_buckets.is_empty():
		for i in range(2 * render_radius + 3):
			band_buckets.append([])
	var b := mini(absi(cx - last_pcx) + absi(cz - last_pcz), band_buckets.size() - 1)
	band_buckets[b].append({"key": key, "cx": cx, "cz": cz, "data_only": false})
	queued_keys[key] = "build"
	queue_size += 1
	if b < dq_b:
		dq_b = b
		dq_i = 0
	if b < mq_b:
		mq_b = b
		mq_i = 0

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

func _gen_unit(c: Node3D, cx: int, cz: int) -> int:
	var tg := Time.get_ticks_msec()
	if threadgen and absi(cx) > 0 and absi(cz) > 0:
		threadgen_enqueue(cx, cz, _key(cx, cz), c.get_instance_id())
		if timing:
			print("GENCHUNK %d,%d gen_ms=0 thread=1" % [cx, cz])
		return 0
	c.data = WorldGen.generate(cx, cz, Game.world_seed)
	c.init_fl()
	_apply_edits_to_chunk(c)
	var dg := Time.get_ticks_msec() - tg
	if timing:
		print("GENCHUNK %d,%d gen_ms=%d" % [cx, cz, dg])
	perf_gen_ms += dg
	return dg

func threadgen_enqueue(cx: int, cz: int, key: String, inst: int) -> void:
	if _tg_inflight_keys.has(key):
		_tg_dedup += 1
		return
	if threadgen_inflight.size() >= threadgen_max:
		_tg_capdrop += 1
		if _tg_debug:
			print("TGEN CAPDROP %d,%d inflight=%d" % [cx, cz, threadgen_inflight.size()])
		return
	var entry := {"key": key, "cx": cx, "cz": cz, "inst": inst, "args": [cx, cz, Game.world_seed, Data.HEIGHT, Data.SEA]}
	var tid = threadgen_pool.add_task(_threadgen_worker)
	entry["tid"] = tid
	_tg_slots[tid] = entry
	threadgen_inflight.append(entry)
	_tg_inflight_keys[key] = true
	_tg_enq += 1
	if _tg_debug:
		print("TGEN ENQ %d,%d inflight=%d" % [cx, cz, threadgen_inflight.size()])

func _threadgen_worker() -> void:
	var tid = threadgen_pool.get_caller_task_id()
	var entry = _tg_slots.get(tid)
	if entry == null:
		return
	var a: Array = entry["args"]
	var d := WorldGen.generate_args(int(a[0]), int(a[1]), int(a[2]), int(a[3]), int(a[4]))
	entry["result"] = d

func threadgen_poll() -> void:
	if threadgen_inflight.is_empty():
		return
	var i := 0
	while i < threadgen_inflight.size():
		var e: Dictionary = threadgen_inflight[i]
		var tid = int(e["tid"])
		if threadgen_pool.is_task_completed(tid):
			threadgen_inflight.remove_at(i)
			_tg_inflight_keys.erase(e["key"])
			_tg_slots.erase(tid)
			threadgen_handoff(e, e.get("result", null))
			continue
		i += 1

func threadgen_handoff(e: Dictionary, data: PackedByteArray) -> void:
	if data == null or data.size() == 0:
		return
	var key: String = e["key"]
	var c = chunks.get(key)
	if c == null:
		_tg_stale += 1
		if _tg_debug:
			print("TGEN STALE %d,%d (chunk gone)" % [int(e["cx"]), int(e["cz"])])
		return
	var expected_inst: int = int(e["inst"])
	if expected_inst >= 0 and int(c.get_instance_id()) != expected_inst:
		_tg_stale += 1
		if _tg_debug:
			print("TGEN STALE %d,%d (inst mismatch %d != %d)" % [int(e["cx"]), int(e["cz"]), expected_inst, int(c.get_instance_id())])
		return
	if c.data.size() != 0:
		_tg_datadrop += 1
		if _tg_debug:
			print("TGEN DATADROP %d,%d (data already set)" % [int(e["cx"]), int(e["cz"])])
		return
	c.data = data
	c.init_fl()
	_apply_edits_to_chunk(c)
	_tg_handoff += 1
	if timing or _tg_debug:
		print("GENHAND %d,%d" % [int(e["cx"]), int(e["cz"])])

func _build_unit(c: Node3D, cx: int, cz: int) -> int:
	var tb := Time.get_ticks_msec()
	c.build_mesh(get_block)
	var dt := Time.get_ticks_msec() - tb
	last_build_us = dt * 1000
	if timing:
		print("BUILDCHUNK %d,%d gen_ms=0 build_ms=%d" % [cx, cz, dt])
	perf_build_ms += dt
	return dt

func _drain_data_wave() -> int:
	if dq_b >= band_buckets.size():
		return 0
	var db := dq_b
	var di := dq_i
	while db < band_buckets.size():
		var arr: Array = band_buckets[db]
		if di >= arr.size():
			db += 1
			di = 0
			continue
		var e: Dictionary = arr[di]
		var cx: int = int(e["cx"])
		var cz: int = int(e["cz"])
		var c = chunks.get(e["key"])
		if c == null:
			if absi(cx - last_pcx) > render_radius + 1 or absi(cz - last_pcz) > render_radius + 1:
				di += 1
				continue
			var s0 := Time.get_ticks_usec() if _recprobe else 0
			stub_chunk(cx, cz)
			if _recprobe:
				_rp_drain_stub_ms += (Time.get_ticks_usec() - s0) / 1000.0
				_rp_drain_stub_n += 1
			c = chunks.get(e["key"])
		if not c.data.is_empty():
			di += 1
			continue
		var dg := _gen_unit(c, cx, cz)
		dq_b = db
		dq_i = di
		return dg
	dq_b = db
	dq_i = di
	return 0

func _mesh_head_ready() -> int:
	while mq_b < band_buckets.size():
		var marr: Array = band_buckets[mq_b]
		if mq_i >= marr.size():
			mq_b += 1
			mq_i = 0
			continue
		var me: Dictionary = marr[mq_i]
		var cx: int = int(me["cx"])
		var cz: int = int(me["cz"])
		var c = chunks.get(me["key"])
		if c == null:
			if absi(cx - last_pcx) > render_radius + 1 or absi(cz - last_pcz) > render_radius + 1:
				mq_i += 1
				continue
			return 0
		if bool(me["data_only"]):
			if c.data.is_empty():
				return 0
			mq_i += 1
			continue
		if c.data.is_empty():
			return 0
		if c.mesh_built:
			mq_i += 1
			continue
		return 1 if _build_ready(cx, cz) else 0
	return 0

func _drain_build_queue() -> void:
	if queue_size == 0:
		return
	var t0 := Time.get_ticks_usec()
	var budget := 3 if _startup_pending() else (2 if last_build_us < BUILD_FAST_US else 1)
	var budget_us := int(drain_budget_ms * 1000)
	var gen_used_ms := 0
	var units := 0
	while budget > 0:
		if Time.get_ticks_usec() - t0 > budget_us:
			break
		var u := 0
		var gm := 0
		if _mesh_head_ready() == 1:
			var he: Dictionary = band_buckets[mq_b][mq_i]
			var hc: Node3D = chunks.get(he["key"])
			_build_unit(hc, int(he["cx"]), int(he["cz"]))
			u = 1
		elif gen_budget_ms < 0 or gen_used_ms < gen_budget_ms:
			gm = _drain_data_wave()
			if gm > 0:
				u = 1
				gen_used_ms += gm
		if u == 0:
			break
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
		if threadgen:
			var key := _key(cx, cz)
			threadgen_enqueue(cx, cz, key, -1)
			c = chunks.get(key)
			if c != null:
				return c
		c = create_chunk(cx, cz, false)
		if absi(cx - last_pcx) <= render_radius and absi(cz - last_pcz) <= render_radius:
			_enqueue_build(cx, cz)
		return c
	if c.data.is_empty():
		var tg := Time.get_ticks_msec()
		c.data = WorldGen.generate(cx, cz, Game.world_seed)
		c.init_fl()
		_apply_edits_to_chunk(c)
		if timing:
			print("ONDEMANDGEN %d,%d gen_ms=%d" % [cx, cz, Time.get_ticks_msec() - tg])
	return c

func _build_queue_for_center(pcx: int, pcz: int) -> void:
	var rr := render_radius
	var nbands := 2 * rr + 3
	var new_buckets: Array = []
	for i in range(nbands):
		new_buckets.append([])
	var want: Dictionary = {}
	for dx in range(-rr, rr + 1):
		for dz in range(-rr, rr + 1):
			var cx := pcx + dx
			var cz := pcz + dz
			var key := _key(cx, cz)
			var old = queued_keys.get(key)
			if old == "build":
				continue
			var c = chunks.get(key)
			if c != null and c.mesh_built:
				continue
			want[key] = {"cx": cx, "cz": cz, "d": absi(dx) + absi(dz)}
	for b in range(band_buckets.size()):
		var arr: Array = band_buckets[b]
		for i in range(arr.size()):
			var e: Dictionary = arr[i]
			var key: String = e["key"]
			var adx := absi(int(e["cx"]) - pcx)
			var adz := absi(int(e["cz"]) - pcz)
			if adx > rr + 1 or adz > rr + 1:
				if not chunks.has(key):
					queued_keys.erase(key)
				continue
			if want.has(key):
				queued_keys.erase(key)
				continue
			new_buckets[mini(adx + adz, nbands - 1)].append(e)
	var new_n := 0
	var qs := 0
	for key in want:
		var w: Dictionary = want[key]
		queued_keys[key] = "build"
		new_buckets[mini(int(w["d"]), nbands - 1)].append({"key": key, "cx": int(w["cx"]), "cz": int(w["cz"]), "data_only": false})
		new_n += 1
	for dx in range(-(rr + 1), rr + 2):
		for dz in range(-(rr + 1), rr + 2):
			if maxi(absi(dx), absi(dz)) != rr + 1:
				continue
			var cx := pcx + dx
			var cz := pcz + dz
			var key := _key(cx, cz)
			if queued_keys.has(key):
				continue
			var c = chunks.get(key)
			if c != null and not c.data.is_empty():
				continue
			queued_keys[key] = "data"
			new_buckets[mini(absi(dx) + absi(dz), nbands - 1)].append({"key": key, "cx": cx, "cz": cz, "data_only": true})
			new_n += 1
	for b in range(nbands):
		for e2 in new_buckets[b]:
			qs += 1
	band_buckets = new_buckets
	dq_b = 0
	dq_i = 0
	mq_b = 0
	mq_i = 0
	queue_size = qs
	_rp_stub_n = new_n

func _enter_candidate(key: String, c: Node3D) -> bool:
	# AC-0080 candidacy: keep node + data + fl + edits, kill the expensive
	# parts. col_dirty forces a collision rebuild on re-entry; mesh_built
	# false makes re-enterers re-queue themselves as "build" in
	# _build_queue_for_center and skips them in the flush loops.
	c.candidate = true
	c.cand_since = 0
	var had_mesh: bool = c.mesh_built
	c.mesh_built = false
	c.col_dirty = true
	if had_mesh:
		if c.mesh_instance != null:
			c.mesh_instance.mesh = null
		if c.fluid_instance != null:
			c.fluid_instance.mesh = null
		if c.flora_instance != null:
			c.flora_instance.mesh = null
		if c.collision_body != null:
			c.collision_body.queue_free()
			c.collision_body = null
		# Pending mesh-bound work on an invisible chunk is waste; re-entry
		# marks it dirty again via the rebuild path.
		light_pending_set.erase(key)
		light_pending.erase(key)
		fluid_dirty.erase(key)
		tex_refresh.erase(key)
	return had_mesh


func _strip_candidate_builds(keys: Array) -> void:
	# Remove surviving "build" queue entries of freshly-candidated chunks so
	# the drain cannot re-mesh them while they are invisible. "data" entries
	# are left in place (data gen on the r+1 ring is unchanged behavior).
	if keys.is_empty():
		return
	var kset := {}
	for k in keys:
		kset[k] = true
	for b in range(band_buckets.size()):
		var arr: Array = band_buckets[b]
		var i := 0
		while i < arr.size():
			var e: Dictionary = arr[i]
			if not bool(e["data_only"]) and kset.has(e["key"]):
				queued_keys.erase(e["key"])
				arr.remove_at(i)
				queue_size -= 1
			else:
				i += 1


func recenter(wx: float, wz: float, mesh_now := true) -> void:
	last_pcx = int(floorf(wx / 16.0))
	last_pcz = int(floorf(wz / 16.0))
	var pcx := last_pcx
	var pcz := last_pcz
	_rp_free_ms = 0.0
	_rp_stub_ms = 0.0
	_rp_stub_n = 0
	_rp_walk_ms = 0.0
	_rp_insert_ms = 0.0
	_rp_dequeue_ms = 0.0
	_rp_deq_n = 0
	var rt0 := Time.get_ticks_usec()
	# AC-0080 two-stage hysteresis: r+1 = candidate (kill expensive parts,
	# keep node+data+edits); r+2+ for 2 recenter events = free. Jitter at
	# r+1 resets cand_since, so a chunk never flaps in and out.
	var rr := render_radius
	var to_free: Array[String] = []
	var cand_builds: Array = []
	for key in chunks:
		var c: Node3D = chunks[key]
		var cheby := maxi(absi(c.cx - pcx), absi(c.cz - pcz))
		if cheby <= rr:
			if c.candidate:
				c.candidate = false
				c.cand_since = 0
		elif cheby == rr + 1:
			if not c.candidate:
				if _enter_candidate(key, c):
					cand_builds.append(key)
			else:
				c.cand_since = 0
		else:
			if not c.candidate:
				if _enter_candidate(key, c):
					cand_builds.append(key)
			c.cand_since += 1
			if c.cand_since >= 2:
				to_free.append(key)
	var tf1 := Time.get_ticks_usec()
	_strip_candidate_builds(cand_builds)
	for key in to_free:
		var c: Node3D = chunks[key]
		chunks.erase(key)
		queued_keys.erase(key)
		light_pending_set.erase(key)
		light_pending.erase(key)
		fluid_dirty.erase(key)
		tex_refresh.erase(key)
		c.queue_free()
	_rp_free_ms += (Time.get_ticks_usec() - tf1) / 1000.0
	threadgen_poll()
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
	var tr1 := Time.get_ticks_usec()
	for dx in range(-render_radius, render_radius + 1):
		for dz in range(-render_radius, render_radius + 1):
			var cxr := pcx + dx
			var czr := pcz + dz
			if not chunks.has(_key(cxr, czr)):
				stub_chunk(cxr, czr)
				_rp_stub_n += 1
	for dx in range(-(render_radius + 1), render_radius + 2):
		for dz in range(-(render_radius + 1), render_radius + 2):
			if maxi(absi(dx), absi(dz)) != render_radius + 1:
				continue
			var cxr := pcx + dx
			var czr := pcz + dz
			if not chunks.has(_key(cxr, czr)):
				stub_chunk(cxr, czr)
				_rp_stub_n += 1
	_build_queue_for_center(pcx, pcz)
	_rp_walk_ms += (Time.get_ticks_usec() - tr1) / 1000.0
	if _recprobe:
		print("RECPROBE r=%d total_ms=%.1f free_ms=%.1f rebuild_ms=%.1f new_n=%d queue=%d chunks=%d drain_stubs_ms=%.1f drain_stubs_n=%d" % [
			render_radius,
			(Time.get_ticks_usec() - rt0) / 1000.0,
			_rp_free_ms, _rp_walk_ms, _rp_stub_n,
			queue_size, chunks.size(),
			_rp_drain_stub_ms, _rp_drain_stub_n])

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
