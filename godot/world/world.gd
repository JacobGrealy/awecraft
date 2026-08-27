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
const REC_SLICE_BUDGET_MS := 8
const REC_UNITS_PER_FRAME := 2048

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
var perf_read_sync_gen := 0
var perf_read_sync_gen_ms := 0.0
var perf_create_sync_gen := 0
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
var _rec_pending := false
var _rec_pcx := 0
var _rec_pcz := 0
var _rec_phase := 0            # 0 WANT, 1 STUB, 2 MERGE_OLD, 3 MERGE_WANT, 4 MERGE_RING
var _rec_cursor := 0           # position in the current phase's domain
var _rec_i := 0
var _rec_want: Dictionary = {}
var _rec_want_keys: Array = []
var _rec_new_buckets: Array = []
var _rec_slice_total_ms := 0.0
var _rec_slice_max_ms := 0.0
var _rec_slice_frames := 0
var _rec_new_n := 0
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
var _fluidprobe := false
var _fp_writes := 0
var fluid_wet := {}
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
# AC-0107 threaded mesh+light (desktop): shared WorkerThreadPool, dedup by
# chunk key, in-flight cap, stale drop (node gone / data+fl changed).
var threadmesh := false
var threadmesh_max := 3
var threadmesh_pool = null
var threadmesh_inflight: Array = []
var _tm_slots = {}
var _tm_inflight_keys: Dictionary = {}
var _tm_ctx: Dictionary = {}
var _tm_ms_full: Dictionary = {"tex": null, "rects": {}}
var _tm_debug := false
var _tm_enq := 0
var _tm_dedup := 0
var _tm_capdrop := 0
var _tm_stale := 0
var _tm_datadrop := 0
var _tm_handoff := 0
var perf_build_worker_ms := 0
var col_stage_enabled := true
var _col_pending: Array = []
var _col_pending_set: Dictionary = {}
var perf_collision_ms := 0
var perf_collision_n := 0
var perf_collision_max_ms := 0
var perf_staged_drained := 0
var perf_staged_dropped := 0
var _eff_cache: Dictionary = {}
var _eff_cache_order: Array = []
const EFF_CACHE_CAP := 128
var _bl_want: Dictionary = {}
var perf_light_self_computes := 0
var perf_light_batch_calls := 0
var perf_light_batch_chunks := 0
var perf_light_cache_hits := 0
var _look_yaw := 0.0
var _look_dir := Vector2(1, 0)
const PICK_POOL_CAP := 512
const PICK_LOOK_REFRESH_DEG := 10.0
# AC-0079 v3 pick-order probe: a bounded log of every mesh-build DISPATCH
# (any _mesh_dispatch that actually dispatches — sync fallbacks included,
# dedup re-picks excluded). The boundary harness reads it to count, per
# crossing, how many of the FIRST 10 dispatches are forward (dx > 0) chunks.
var build_dispatch_total := 0
var build_dispatch_log: Array = []
const BUILD_DISPATCH_LOG_CAP := 16384

func _bd_log(cx: int, cz: int) -> void:
	build_dispatch_total += 1
	build_dispatch_log.append(Vector2i(cx, cz))
	if build_dispatch_log.size() > BUILD_DISPATCH_LOG_CAP:
		build_dispatch_log.pop_front()

func _ready() -> void:
	timing = OS.get_environment("AWECRAFT_TIMING") == "1"
	var nenv := OS.get_environment("AWECRAFT_THREADGEN_N")
	# AC-0079 v3 C3: default threadgen = mini(cores, 6). The r4 cold wall is the
	# 36-chunk crossing-1 core fill: 36 x ~220 ms of gen paced by the pool size
	# (3 -> 2.64 s vs 6 -> 1.32 s). Env override above stays; final cap below.
	threadgen_max = mini(OS.get_processor_count(), 6)
	if nenv != "":
		threadgen_max = maxi(1, nenv.to_int())
	threadgen_max = mini(threadgen_max, 6)
	threadgen_pool = Engine.get_singleton("WorkerThreadPool")
	threadgen = true
	_tg_debug = OS.get_environment("AWECRAFT_TGDEBUG") == "1"
	print("THREADGEN on threadgen=true pool=%d" % threadgen_max)
	var menv := OS.get_environment("AWECRAFT_THREADMESH_N")
	# AC-0079 v3 C2 (pool-saturation mitigation, plan risk (c)): contained light
	# now runs on the mesh workers (64 ms/chunk instead of 44), so TM3 + TG6 +
	# main = 10 threads on 6 cores oversubscribes the cold phase (measured:
	# X1 wall 4256-4325 ms with TM3 vs 3342 ms with TM2; walk p95 61 either way,
	# max 121 vs 111). TM2 keeps build capacity (15.6 chunks/s) above the
	# steady r4 demand (9-14/s). Env override above stays; cap below stays.
	threadmesh_max = maxi(1, mini(OS.get_processor_count() - 2, 2))
	if menv != "":
		threadmesh_max = maxi(1, menv.to_int())
	threadmesh_max = mini(threadmesh_max, 6)
	threadmesh_pool = Engine.get_singleton("WorkerThreadPool")
	# Pre-warm everything the worker path touches so a worker thread
	# never dereferences Data/Game: tables, block-table snapshot, and the
	# merge atlas (static cache keyed by atlas identity).
	Lighting._tables()
	_tm_ctx = ChunkScript.make_ctx()
	_tm_ms_full = ChunkScript._merge_atlas()
	threadmesh = true
	_tm_debug = OS.get_environment("AWECRAFT_TMDEBUG") == "1"
	print("THREADMESH on threadmesh=true pool=%d" % threadmesh_max)
	_recprobe = OS.get_environment("AWECRAFT_RECPROBE") == "1"
	var dr := OS.get_environment("AWECRAFT_DRAIN_MS")
	if dr != "" and dr.to_int() > 0:
		drain_budget_ms = dr.to_int()
	col_stage_enabled = OS.get_environment("AWECRAFT_COLSTAGE") != "0"
	var gb := OS.get_environment("AWECRAFT_GEN_BUDGET")
	if gb != "" and gb.to_int() >= 0:
		gen_budget_ms = gb.to_int()
	fluid_sleep = OS.get_environment("AWECRAFT_FLUID_SLEEP") != "0"
	tick_time = OS.get_environment("AWECRAFT_TICKTIME") == "1"
	_fluidprobe = OS.get_environment("AWECRAFT_FLUIDPROBE") == "1"
	Game.world = self
	fluid_timer = Timer.new()
	fluid_timer.wait_time = FLUID_TICK_INTERVAL
	fluid_timer.autostart = true
	fluid_timer.timeout.connect(_on_fluid_tick)
	add_child(fluid_timer)

func _exit_tree() -> void:
	threadgen = false
	threadmesh = false
	# AC-0107 (G5 flake fix): drain in-flight worker tasks BEFORE the engine
	# unloads scripts. A worker still executing a GDScript static call during
	# cleanup deadlocks (observed: post-RESULT exit hang, ~40% of ON-arm runs,
	# OFF arm clean). Bounded wait — if the pool ever wedges, continue the
	# shutdown after the cap instead of hanging the exit.
	if threadgen_pool != null:
		var waited := 0
		while waited < 1000 and (not threadgen_inflight.is_empty() or not threadmesh_inflight.is_empty()):
			var any_pending := false
			for e in threadgen_inflight:
				if not threadgen_pool.is_task_completed(int(e["tid"])):
					any_pending = true
			for e in threadmesh_inflight:
				if not threadgen_pool.is_task_completed(int(e["tid"])):
					any_pending = true
			if not any_pending:
				break
			OS.delay_msec(1)
			waited += 1
	threadgen_inflight.clear()
	threadmesh_inflight.clear()
	_tg_slots.clear()
	_tm_slots.clear()

func _on_fluid_tick() -> void:
	if fluid_sim_enabled and (Game.mode == "play" or Game.mode == "pause"):
		tick_fluids()

func _process(_delta: float) -> void:
	# threadmesh_inflight keeps this running while mesh tasks are in flight
	# even when every bookkeeping list is drained (else the poll never runs).
	if light_dirty.is_empty() and fluid_dirty.is_empty() and queue_size == 0 and light_pending.is_empty() and tex_refresh.is_empty() and threadmesh_inflight.is_empty() and not _rec_pending and _bl_want.is_empty() and _col_pending.is_empty():
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
			_mesh_dispatch(c2, int(c2.cx), int(c2.cz), eff, eff.is_empty())
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
			_mesh_dispatch(cc, int(cc.cx), int(cc.cz), cc.last_eff, false)
		else:
			fluid_dirty[_key(int(cc.cx), int(cc.cz))] = true
	threadgen_poll()
	threadmesh_poll()
	_recenter_slice()
	_drain_build_queue()
	_drain_tex_refresh()

func refresh_textures() -> void:
	tex_refresh = chunks.keys().duplicate()
	# Texture swap is the only table-changing event: rebuild the worker ctx
	# and the merge-atlas cache on the main thread. In-flight tasks keep their
	# own copies and land with the old atlas; the tex_refresh drain re-pushes
	# deduped keys so every chunk is rebuilt once with the new tables.
	if threadmesh:
		_tm_ctx = ChunkScript.make_ctx()
		_tm_ms_full = ChunkScript._merge_atlas()

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
		# false = a task for this chunk is still in flight (dispatch dedup):
		# re-queue so the chunk is rebuilt once that task has landed.
		if not _mesh_dispatch(c, int(c.cx), int(c.cz), c.last_eff, false):
			tex_refresh.push_back(key)
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


# --- AC-0107 threaded mesh+light (desktop) -------------------------------

func _threadmesh_worker() -> void:
	# Worker body: pure-static pipeline (ChunkScript.build_accs) on fresh
	# copies. Reads only its own entry (written before add_task) and writes
	# entry["result"] — the AC-0082 handoff pattern, proven in this codebase.
	var tid = threadmesh_pool.get_caller_task_id()
	var entry = _tm_slots.get(tid)
	if entry == null:
		return
	entry["result"] = ChunkScript.build_accs(entry["data"], entry["fl"], int(entry["cx"]), int(entry["cz"]), entry["nbs"], entry["ctx"], entry["ms"], entry["eff"])

func threadmesh_poll() -> void:
	if threadmesh_inflight.is_empty():
		return
	var i := 0
	while i < threadmesh_inflight.size():
		var e: Dictionary = threadmesh_inflight[i]
		var tid = int(e["tid"])
		if threadmesh_pool.is_task_completed(tid):
			threadmesh_inflight.remove_at(i)
			_tm_inflight_keys.erase(e["key"])
			_tm_slots.erase(tid)
			threadmesh_handoff(e, e.get("result", null))
			continue
		i += 1

func _tm_retrigger(key: String, c: Node3D, e: Dictionary) -> void:
	# A dropped result can't be applied: rebuild from current state.
	# Meshed chunks re-enter the light-flush queue (fresh bulk eff);
	# not-yet-meshed chunks re-enter the build band queue.
	if bool(c.mesh_built):
		if not light_pending_set.has(key):
			light_pending.append(key)
			light_pending_set[key] = true
		flush_active = true
	else:
		_enqueue_build(int(e["cx"]), int(e["cz"]))

func threadmesh_handoff(e: Dictionary, res) -> void:
	var key: String = e["key"]
	var c = chunks.get(key)
	if c == null:
		_tm_stale += 1
		if _tm_debug:
			print("TMESH STALE %d,%d (chunk gone)" % [int(e["cx"]), int(e["cz"])])
		return
	if int(c.get_instance_id()) != int(e["inst"]):
		_tm_stale += 1
		if _tm_debug:
			print("TMESH STALE %d,%d (inst mismatch)" % [int(e["cx"]), int(e["cz"])])
		return
	if res == null:
		_tm_datadrop += 1
		if _tm_debug:
			print("TMESH DATADROP %d,%d (no result)" % [int(e["cx"]), int(e["cz"])])
		_tm_retrigger(key, c, e)
		return
	if c.data != e["data"] or c.fl != e["fl"]:
		_tm_datadrop += 1
		if _tm_debug:
			print("TMESH DATADROP %d,%d (data/fl changed mid-build)" % [int(e["cx"]), int(e["cz"])])
		_tm_retrigger(key, c, e)
		return
	var ta := Time.get_ticks_msec()
	c.apply_accs(res, _tm_ms_full)
	perf_build_ms += Time.get_ticks_msec() - ta
	perf_build_worker_ms += int(res.get("wms", 0))
	_count_collision_build(c)
	_stage_check(c, key)
	if bool(e.get("eff_trust", true)):
		_eff_cache_put(key, c.data, res.get("light", {}))
	_tm_handoff += 1
	if timing or _tm_debug:
		print("BUILDCHUNK_T %d,%d build_ms=%d" % [int(e["cx"]), int(e["cz"]), int(res.get("wms", 0))])

func _mesh_dispatch(c: Node3D, cx: int, cz: int, eff: Dictionary, eff_trust := true) -> bool:
	# true = covered (sync-built now, or an in-flight task will apply);
	# false = deduped behind an in-flight task (caller may want to retry).
	# Sync fallbacks (spawn chunk, no own data, missing neighbor, cap-drop)
	# run the legacy build_mesh path unchanged. eff_trust marks effs whose
	# light values came from the contained per-chunk kernel (cache/empty);
	# bulk flush effs are untrusted and must not enter the eff cache.
	c.col_immediate = _col_immediate_for(cx, cz)
	var key := _key(cx, cz)
	if (cx == 0 and cz == 0) or c.data.is_empty():
		c.build_mesh(get_block, eff)
		_count_collision_build(c)
		_stage_check(c, key)
		_bd_log(cx, cz)
		return true
	var nbs: Dictionary = {}
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			if (dx == 0) == (dz == 0):
				continue
			var nc = chunks.get(_key(cx + dx, cz + dz))
			if nc == null or nc.data.is_empty():
				# Workers can't on-demand-generate; the sync _build_snap can.
				c.build_mesh(get_block, eff)
				_count_collision_build(c)
				_stage_check(c, key)
				_bd_log(cx, cz)
				return true
			nbs["%d,%d" % [dx, dz]] = {"d": nc.data.duplicate(), "f": nc.fl.duplicate()}
	if _tm_inflight_keys.has(key):
		_tm_dedup += 1
		if _tm_debug:
			print("TMESH DEDUP %d,%d" % [cx, cz])
		return false
	if threadmesh_inflight.size() >= threadmesh_max:
		_tm_capdrop += 1
		if _tm_debug:
			print("TMESH CAPDROP %d,%d inflight=%d" % [cx, cz, threadmesh_inflight.size()])
		c.build_mesh(get_block, eff)
		_count_collision_build(c)
		_stage_check(c, key)
		_bd_log(cx, cz)
		return true
	var ms_w: Dictionary
	if not _tm_ms_full.rects.is_empty():
		ms_w = {"rects": _tm_ms_full.rects.duplicate(), "h": float(_tm_ms_full.get("h", 0.0))}
	else:
		ms_w = {"rects": {}}
	var entry := {
		"key": key, "cx": cx, "cz": cz, "inst": c.get_instance_id(),
		"data": c.data.duplicate(), "fl": c.fl.duplicate(),
		"nbs": nbs, "eff": eff, "eff_trust": eff_trust, "ctx": _tm_ctx, "ms": ms_w,
	}
	var tid = threadmesh_pool.add_task(_threadmesh_worker)
	entry["tid"] = tid
	_tm_slots[tid] = entry
	_tm_inflight_keys[key] = tid
	threadmesh_inflight.append(entry)
	_tm_enq += 1
	_bd_log(cx, cz)
	if _tm_debug:
		print("TMESH ENQ %d,%d inflight=%d" % [cx, cz, threadmesh_inflight.size()])
	return true

func _build_unit(c: Node3D, cx: int, cz: int) -> int:
	var tb := Time.get_ticks_msec()
	# AC-0107: threaded dispatch when eligible; sync fallbacks inside keep the
	# legacy path. dt is the MAIN-thread cost (dispatch/apply), the worker-side
	# total is reported via perf_build_worker_ms / BUILDCHUNK_T.
	# AC-0079 v3 C2 (the AC-0077 follow-up): contained light is OFF the main
	# thread — cached eff when it matches the chunk data (the cache is now fed
	# by worker handoffs via _eff_cache_put), otherwise an empty eff and the
	# worker self-lights its own fresh copy through the byte-identical
	# contained kernel (ChunkScript.build_accs / Lighting.compute_light_flat_chunk).
	var eff := _eff_for(c, cx, cz)
	if eff.is_empty():
		perf_light_self_computes += 1
	_mesh_dispatch(c, cx, cz, eff)
	var dt := Time.get_ticks_msec() - tb
	last_build_us = dt * 1000
	if timing:
		print("BUILDCHUNK %d,%d gen_ms=0 build_ms=%d" % [cx, cz, dt])
	perf_build_ms += dt
	return dt

func _refresh_look_dir() -> void:
	var p = Game.player
	if p == null:
		return
	var dy := float(p._yaw) - _look_yaw
	dy = fposmod(dy + PI, TAU)
	if dy > PI:
		dy = TAU - dy
	if dy * 180.0 / PI < PICK_LOOK_REFRESH_DEG:
		return
	# AC-0079 fix: match player.gd aim_dir() = Basis.from_euler(pitch,yaw,0)*(0,0,-1)
	# = (-sin(yaw), -cos(yaw)) in (x,z). Old (cos,sin) pointed sideways at yaw=-PI/2.
	var d := Vector2(-sin(float(p._yaw)), -cos(float(p._yaw)))
	var l := d.length()
	_look_dir = d / l if l > 1e-6 else Vector2(1, 0)
	_look_yaw = float(p._yaw)

func _entry_score(e: Dictionary, pcx: int, pcz: int, px: float, pz: float) -> float:
	var cx := int(e["cx"])
	var cz := int(e["cz"])
	var d := absi(cx - pcx) + absi(cz - pcz)
	var to_cx := float(cx * 16 + 8) - px
	var to_cz := float(cz * 16 + 8) - pz
	var l := Vector2(to_cx, to_cz).length()
	var dot := _look_dir.x * to_cx + _look_dir.y * to_cz
	var a := dot / l if l > 1e-6 else 0.0
	a = clampf(a, 0.0, 1.0)
	var cheby := maxi(absi(cx - pcx), absi(cz - pcz))
	var boost := 2.0 if cheby <= 1 else 0.0
	return float(d) + (1.0 - a) * 0.75 * float(d) - boost

func _collect_pool(build: bool, include_fb := false) -> Array:
	# AC-0079 round 3: the pick is score-driven (spec: generate the LOWEST score
	# among no-data entries), so the pool must not be clipped by the sticky FIFO
	# cursors — a stale dq_b/mq_b (entries consumed out of band order, cursor
	# parked past the last band) would empty the pool and starve the drain
	# forever. Cursors are bookkeeping only (cursor-advance on consume, exact
	# queue_size); the pool scans every band with the same cap as before.
	# AC-0079 v3 C1: include_fb additionally admits the forward lead column's
	# data_only entries (cx == last_pcx + r, |cz - last_pcz| <= r) — the drain's
	# second pass can pre-build a ready lead chunk before the general scored
	# sweep reaches it. Bounded: the band is exactly 2r+1 entries. Admitted
	# entries carry no data guarantee; the drain applies the full gate
	# (data + mesh_built + _build_ready) to every candidate.
	var out: Array = []
	for b in range(band_buckets.size()):
		var arr: Array = band_buckets[b]
		for i in range(arr.size()):
			if out.size() >= PICK_POOL_CAP:
				return out
			var e: Dictionary = arr[i]
			var c = chunks.get(e["key"])
			if build:
				if bool(e["data_only"]):
					if include_fb and int(e["cx"]) == last_pcx + render_radius \
							and absi(int(e["cz"]) - last_pcz) <= render_radius:
						out.append(e)
					continue
				if c == null or c.data.is_empty() or c.mesh_built:
					continue
				out.append(e)
			else:
				if c == null or not c.data.is_empty():
					continue
				out.append(e)
	return out

func _drain_build_queue() -> void:
	if queue_size == 0:
		if _bl_want.is_empty() and _col_pending.is_empty():
			return
		_col_drain_step()
		return
	var t0 := Time.get_ticks_usec()
	var budget := 3 if _startup_pending() else (2 if last_build_us < BUILD_FAST_US else 1)
	var budget_us := int(drain_budget_ms * 1000)
	var gen_used_ms := 0
	var units := 0
	var px: float = Game.player.position.x if Game.player != null else 0.0
	var pz: float = Game.player.position.z if Game.player != null else 0.0
	while budget > 0:
		if Time.get_ticks_usec() - t0 > budget_us:
			break
		var u := 0
		_refresh_look_dir()
		var bp: Array = _collect_pool(true)
		var best_e: Dictionary = {}
		var best_c: Node3D = null
		var best_s := 1e30
		for e in bp:
			var c = chunks.get(e["key"])
			if c == null or c.data.is_empty() or c.mesh_built:
				continue
			if not _build_ready(int(e["cx"]), int(e["cz"])):
				continue
			var s := _entry_score(e, last_pcx, last_pcz, px, pz)
			if s < best_s:
				best_s = s
				best_e = e
				best_c = c
		if best_c == null:
			# AC-0079 v3 C1: lead-column pre-build, second pass. The in-radius
			# READY pool is empty — pick the lowest-score READY candidate from
			# _collect_pool(true, true) (identical _build_ready gate, identical
			# _build_unit/_remove_entry). In-radius READY ALWAYS wins (this pass
			# only runs when the first pass found nothing); the forward band is
			# exactly 2r+1 entries, so the pass is bounded.
			var fp: Array = _collect_pool(true, true)
			for e in fp:
				var c = chunks.get(e["key"])
				if c == null or c.data.is_empty() or c.mesh_built:
					continue
				if not _build_ready(int(e["cx"]), int(e["cz"])):
					continue
				var s := _entry_score(e, last_pcx, last_pcz, px, pz)
				if s < best_s:
					best_s = s
					best_e = e
					best_c = c
		if best_c != null:
			_build_unit(best_c, int(best_e["cx"]), int(best_e["cz"]))
			_remove_entry(best_e)
			u = 1
		if u == 0 and (gen_budget_ms < 0 or gen_used_ms < gen_budget_ms):
			# AC-0079 round 3: scored DATA pick. The spec requires the lowest-score
			# no-data entry (not FIFO), else forward leading-edge data only arrives
			# after all nearer-band data drains and _build_ready stalls the forward
			# mesh. Pool = _collect_pool(false) (band scan from the dq cursor,
			# capped at PICK_POOL_CAP, same as before); each candidate is scored
			# with _entry_score and the lowest wins. Per-consumption FIFO cursor
			# bookkeeping (dq_b/dq_i advance past the consumed entry) is kept so
			# entries are never re-picked and queue_size stays exact.
			var dp: Array = _collect_pool(false)
			var dp_e: Dictionary = {}
			var dp_s := 1e30
			for e in dp:
				# AC-0077: skip chunks whose gen is already in flight. The
				# scored pick used to keep re-picking the same in-flight
				# no-data entry (dedup no-op) every iteration, burning the
				# frame budget and starving the next chunk's enqueue (~1 real
				# enqueue / 5-6 frames), which left want-set stragglers
				# unbuilt by the batch pass and forced self light computes.
				if _tg_inflight_keys.has(e["key"]):
					continue
				var s := _entry_score(e, last_pcx, last_pcz, px, pz)
				if s < dp_s:
					dp_s = s
					dp_e = e
			if not dp_e.is_empty():
				_advance_dq_past(int(dp_e["cx"]), int(dp_e["cz"]))
				var cx: int = int(dp_e["cx"])
				var cz: int = int(dp_e["cz"])
				var c = chunks.get(dp_e["key"])
				if c == null:
					if absi(cx - last_pcx) > render_radius + 1 or absi(cz - last_pcz) > render_radius + 1:
						# Out-of-radius stale pool candidate (possible after a
						# recenter mid-frame): skip this pick, leave the entry
						# queued for the next recenter rebuild to drop it.
						pass
					else:
						var s0 := Time.get_ticks_usec() if _recprobe else 0
						stub_chunk(cx, cz)
						if _recprobe:
							_rp_drain_stub_ms += (Time.get_ticks_usec() - s0) / 1000.0
							_rp_drain_stub_n += 1
						c = chunks.get(dp_e["key"])
				if c != null and c.data.is_empty():
					var dg := _gen_unit(c, cx, cz)
					u = 1
					gen_used_ms += dg
			if u == 0 and dp.is_empty():
				# Pool exhausted this frame (all entries consumed): park the
				# cursor past the scanned region, same as the old FIFO scan.
				var db := dq_b
				var di := dq_i
				while db < band_buckets.size() and di < band_buckets[db].size():
					db += 1
					di = 0
				dq_b = db
				dq_i = di
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
	_col_drain_step()

func _advance_dq_past(cx: int, cz: int) -> void:
	# AC-0079 round 3: advance the sticky data cursor (dq_b/dq_i) past the entry
	# at (cx,cz), keeping the cursor consistent with the scored pool pick the
	# way the old FIFO scan did (entries at/below the cursor are considered
	# consumed). Fallback-only bookkeeping: the pick itself is score-driven.
	for b in range(dq_b, band_buckets.size()):
		var arr: Array = band_buckets[b]
		for i in range(dq_i if b == dq_b else 0, arr.size()):
			if int(arr[i]["cx"]) == cx and int(arr[i]["cz"]) == cz:
				dq_b = b
				dq_i = i + 1
				while dq_b < band_buckets.size() and dq_i >= band_buckets[dq_b].size():
					dq_b += 1
					dq_i = 0
				return

func _remove_entry(e: Dictionary) -> void:
	for b in range(band_buckets.size()):
		var arr: Array = band_buckets[b]
		for i in range(arr.size()):
			if arr[i]["key"] == e["key"]:
				arr.remove_at(i)
				queue_size -= 1
				return

# --- AC-0077: crossing-batched per-chunk light (P1.3) ----------------------

func _eff_cache_put(key: String, data: PackedByteArray, eff: Dictionary) -> void:
	if eff.is_empty():
		return
	_eff_cache[key] = {"data": data.duplicate(), "eff": eff}
	if not _eff_cache_order.has(key):
		_eff_cache_order.append(key)
		while _eff_cache_order.size() > EFF_CACHE_CAP:
			_eff_cache.erase(_eff_cache_order.pop_front())

func _eff_cache_evict(key: String) -> void:
	_eff_cache.erase(key)
	if _eff_cache_order.has(key):
		_eff_cache_order.erase(key)

func _eff_for(c: Node3D, cx: int, cz: int) -> Dictionary:
	var key := _key(cx, cz)
	var cached = _eff_cache.get(key)
	if cached != null and c.data == cached.data:
		perf_light_cache_hits += 1
		return cached.eff
	return {}

# AC-0079 v3 C2: _bl_batch_step (the AC-0077 main-thread batch light) is
# DELETED — contained light now runs off the main thread: workers self-light
# their fresh copies (ChunkScript.build_accs) and the handoff feeds the eff
# cache below. _bl_want bookkeeping stays (recenter WANT fills it, release
# erases it); its early-return check in _drain_build_queue stays behavior-
# neutral. No light math changed (byte-identity: compute_light_flat_batch and
# compute_light_flat_chunk both route through _chunk_light_into).

# --- AC-0077: staged collision bodies (P1.4) --------------------------------

func _col_immediate_for(cx: int, cz: int) -> bool:
	if not col_stage_enabled:
		return true
	if cx == 0 and cz == 0:
		return true
	return maxi(absi(cx - last_pcx), absi(cz - last_pcz)) <= 1

func _stage_check(c: Node3D, key: String) -> void:
	if c == null or not col_stage_enabled:
		return
	if not c.collision_enabled or not c.col_dirty:
		return
	if c.collision_body != null:
		return
	var ccx := int(c.cx)
	var ccz := int(c.cz)
	if (ccx == 0 and ccz == 0) or maxi(absi(ccx - last_pcx), absi(ccz - last_pcz)) <= 1:
		return
	if not _col_pending_set.has(key):
		_col_pending.append(key)
		_col_pending_set[key] = true

func _col_dist(key: String) -> int:
	var c = chunks.get(key)
	if c == null:
		return 1000000
	return maxi(absi(int(c.cx) - last_pcx), absi(int(c.cz) - last_pcz))

func _col_drain_step() -> void:
	# <=2 staged bodies per frame, nearest-first, behind the build queue.
	# Validity: chunk present + mesh_built + no body yet (dup guard) +
	# collision_enabled + col_dirty + in radius; anything else drops (a
	# rebuilt or out-of-radius chunk is cancelled, never double-bodied).
	if _col_pending.is_empty():
		return
	_col_pending.sort_custom(func(a, b): return _col_dist(a) < _col_dist(b))
	var done := 0
	var i := 0
	while done < 2 and i < _col_pending.size():
		var key: String = _col_pending[i]
		var c = chunks.get(key)
		var ok: bool = c != null and c.mesh_built and c.collision_body == null and c.collision_enabled and c.col_dirty and maxi(absi(int(c.cx) - last_pcx), absi(int(c.cz) - last_pcz)) <= render_radius
		_col_pending.remove_at(i)
		_col_pending_set.erase(key)
		if not ok:
			perf_staged_dropped += 1
			continue
		c._build_collision()
		if c.collision_body != null:
			c.col_dirty = false
			_count_collision_build(c)
			perf_staged_drained += 1
		else:
			perf_staged_dropped += 1
		done += 1

func _count_collision_build(c: Node3D) -> void:
	var dt := int(c.last_collision_build_ms)
	if dt > 0:
		perf_collision_ms += dt
		perf_collision_n += 1
		if dt > perf_collision_max_ms:
			perf_collision_max_ms = dt

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
	perf_create_sync_gen += 1
	var c: Node3D = _make_chunk_node(cx, cz)
	c.data = WorldGen.generate(cx, cz, Game.world_seed)
	c.init_fl()
	_apply_edits_to_chunk(c)
	if mesh_now:
		c.build_mesh(get_block)
	return c

func stub_chunk(cx: int, cz: int) -> Node3D:
	return _make_chunk_node(cx, cz)

# AC-0119: pure lookup — a read NEVER generates. Missing chunk = null,
# stub = empty data; both read as air at the call sites (web world.block
# parity). All data generation lives in the drain/threadgen path.
func _chunk_data(cx: int, cz: int) -> Node3D:
	return chunks.get(_key(cx, cz))

func _enter_candidate(key: String, c: Node3D) -> bool:
	# AC-0080 candidacy: keep node + data + fl + edits, kill the expensive
	# parts. col_dirty forces a collision rebuild on re-entry; mesh_built
	# false makes re-enterers re-queue themselves as "build" in the
	# recenter WANT pass and skips them in the flush loops.
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
		# marks it dirty again via the rebuild path. The staged-body entry is
		# stale too (body freed above); the eff cache stays — data is kept,
		# so the cached light is still valid on re-entry.
		light_pending_set.erase(key)
		light_pending.erase(key)
		fluid_dirty.erase(key)
		tex_refresh.erase(key)
		_col_pending_set.erase(key)
		_col_pending.erase(key)
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
		_eff_cache_evict(key)
		_bl_want.erase(key)
		_col_pending_set.erase(key)
		_col_pending.erase(key)
		c.queue_free()
	_rp_free_ms += (Time.get_ticks_usec() - tf1) / 1000.0
	threadgen_poll()
	threadmesh_poll()
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
	_rec_pending = true
	_rec_pcx = pcx
	_rec_pcz = pcz
	_rec_phase = 0
	_rec_cursor = 0
	_rec_i = 0
	_rec_want = {}
	_rec_want_keys = []
	_rec_new_buckets = []
	for i in range(2 * rr + 3):
		_rec_new_buckets.append([])
	_rec_slice_total_ms = 0.0
	_rec_slice_max_ms = 0.0
	_rec_slice_frames = 0
	_rec_new_n = 0
	_rp_walk_ms += (Time.get_ticks_usec() - tr1) / 1000.0
	if _recprobe:
		print("RECPROBE r=%d total_ms=%.1f free_ms=%.1f rebuild_ms=%.1f new_n=%d queue=%d chunks=%d drain_stubs_ms=%.1f drain_stubs_n=%d" % [
			render_radius,
			(Time.get_ticks_usec() - rt0) / 1000.0,
			_rp_free_ms, _rp_walk_ms, _rp_stub_n,
			queue_size, chunks.size(),
			_rp_drain_stub_ms, _rp_drain_stub_n])

func _recenter_slice() -> void:
	if not _rec_pending:
		return
	var t0 := Time.get_ticks_msec()
	var units := 0
	while _rec_pending and units < REC_UNITS_PER_FRAME and Time.get_ticks_msec() - t0 < REC_SLICE_BUDGET_MS:
		if _rec_phase == 0:
			_rec_want_step()
		elif _rec_phase == 1:
			_rec_stub_step()
		elif _rec_phase == 2:
			_rec_merge_old_step()
		elif _rec_phase == 3:
			_rec_merge_want_step()
		else:
			_rec_merge_ring_step()
		units += 1
	var fm := float(Time.get_ticks_msec() - t0)
	_rec_slice_total_ms += fm
	_rec_slice_frames += 1
	if fm > _rec_slice_max_ms:
		_rec_slice_max_ms = fm
	if not _rec_pending:
		if _recprobe:
			print("RECSLICE r=%d total_ms=%.1f max_ms=%.1f frames=%d new_n=%d stubs=%d queue=%d" % [
				render_radius, _rec_slice_total_ms, _rec_slice_max_ms,
				_rec_slice_frames, _rec_new_n, _rp_stub_n, queue_size])
		_rp_stub_n = _rec_new_n

func _rec_want_step() -> void:
	var rr := render_radius
	var side := 2 * rr + 1
	if _rec_cursor >= side * side:
		_rec_phase = 1
		_rec_cursor = 0
		_bl_want = {}
		for k in _rec_want:
			_bl_want[k] = true
		return
	var dx := _rec_cursor / side - rr
	var dz := _rec_cursor % side - rr
	var cx := _rec_pcx + dx
	var cz := _rec_pcz + dz
	var key := _key(cx, cz)
	var old = queued_keys.get(key)
	if old != "build":
		var c = chunks.get(key)
		if c == null or not c.mesh_built:
			_rec_want[key] = {"cx": cx, "cz": cz, "d": absi(dx) + absi(dz)}
			_rec_want_keys.append(key)
	_rec_cursor += 1

func _rec_stub_step() -> void:
	var rr := render_radius
	var side_a := 2 * rr + 1
	var side_b := 2 * rr + 3
	if _rec_cursor >= side_a * side_a + side_b * side_b:
		_rec_phase = 2
		_rec_cursor = 0
		_rec_i = 0
		return
	var dx := 0
	var dz := 0
	if _rec_cursor < side_a * side_a:
		dx = _rec_cursor / side_a - rr
		dz = _rec_cursor % side_a - rr
	else:
		var j := _rec_cursor - side_a * side_a
		dx = j / side_b - rr - 1
		dz = j % side_b - rr - 1
		if maxi(absi(dx), absi(dz)) != rr + 1:
			_rec_cursor += 1
			return
	var cx := _rec_pcx + dx
	var cz := _rec_pcz + dz
	if not chunks.has(_key(cx, cz)):
		stub_chunk(cx, cz)
		_rp_stub_n += 1
	_rec_cursor += 1

func _rec_merge_old_step() -> void:
	var rr := render_radius
	var b := _rec_cursor
	if b >= band_buckets.size():
		_rec_phase = 3
		_rec_cursor = 0
		return
	var arr: Array = band_buckets[b]
	if _rec_i >= arr.size():
		_rec_cursor = b + 1
		_rec_i = 0
		return
	var e: Dictionary = arr[_rec_i]
	_rec_i += 1
	var key: String = e["key"]
	var adx := absi(int(e["cx"]) - _rec_pcx)
	var adz := absi(int(e["cz"]) - _rec_pcz)
	if adx > rr + 1 or adz > rr + 1:
		if not chunks.has(key):
			queued_keys.erase(key)
		return
	if _rec_want.has(key):
		queued_keys.erase(key)
		return
	_rec_new_buckets[mini(adx + adz, 2 * rr + 2)].append(e)

func _rec_merge_want_step() -> void:
	var rr := render_radius
	if _rec_cursor >= _rec_want_keys.size():
		_rec_phase = 4
		_rec_cursor = 0
		return
	var key: String = _rec_want_keys[_rec_cursor]
	_rec_cursor += 1
	var c = chunks.get(key)
	if c != null and c.mesh_built:
		return
	var w: Dictionary = _rec_want[key]
	queued_keys[key] = "build"
	_rec_new_buckets[mini(int(w["d"]), 2 * rr + 2)].append({"key": key, "cx": int(w["cx"]), "cz": int(w["cz"]), "data_only": false})
	_rec_new_n += 1

func _rec_merge_ring_step() -> void:
	var rr := render_radius
	var side := 2 * rr + 3
	if _rec_cursor >= side * side:
		var qs := 0
		for b in range(_rec_new_buckets.size()):
			for e2 in _rec_new_buckets[b]:
				qs += 1
		band_buckets = _rec_new_buckets
		dq_b = 0
		dq_i = 0
		mq_b = 0
		mq_i = 0
		queue_size = qs
		_rec_pending = false
		_rec_want = {}
		_rec_want_keys = []
		_rec_new_buckets = []
		_rec_cursor = 0
		_rec_i = 0
		return
	var dx := _rec_cursor / side - rr - 1
	var dz := _rec_cursor % side - rr - 1
	_rec_cursor += 1
	if maxi(absi(dx), absi(dz)) != rr + 1:
		return
	var cx := _rec_pcx + dx
	var cz := _rec_pcz + dz
	var key := _key(cx, cz)
	if queued_keys.has(key):
		return
	var c = chunks.get(key)
	if c != null and not c.data.is_empty():
		return
	queued_keys[key] = "data"
	_rec_new_buckets[mini(absi(dx) + absi(dz), 2 * rr + 2)].append({"key": key, "cx": cx, "cz": cz, "data_only": true})
	_rec_new_n += 1

func get_block(x: int, y: int, z: int) -> int:
	if y < 0 or y >= Data.HEIGHT:
		return 0
	var c := _chunk_data(int(floorf(float(x) / 16.0)), int(floorf(float(z) / 16.0)))
	if c == null or c.data.is_empty():
		return 0
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
	if c == null or c.data.is_empty():
		return
	var lx := x & 15
	var lz := z & 15
	c.set_local(lx, y, lz, id)
	if _fluidprobe:
		_fp_writes += 1
	var fi := (y << 8) | (lz << 4) | lx
	if is_fluid_id(id):
		if c.fl[fi] == 0:
			c.fl[fi] = 7
		fluid_wet[_key(cx, cz)] = true
	else:
		c.fl[fi] = 0
	c.col_dirty = true
	_eff_cache_evict(_key(cx, cz))
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
		if int(e.get("f", 0)) > 0:
			fluid_wet[_key(c.cx, c.cz)] = true
	c.col_dirty = true
	_eff_cache_evict(key)
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

# AC-0119: the one legitimate boot-time sync gen, made explicit (port rule:
# the spawn chunk is generated synchronously at boot, NOT on read). Idempotent.
func _ensure_spawn_chunk() -> void:
	var scx := int(floorf(float(WorldGen.SPAWN_X) / 16.0))
	var scz := int(floorf(float(WorldGen.SPAWN_Z) / 16.0))
	var c = chunks.get(_key(scx, scz))
	if c == null or c.data.is_empty():
		create_chunk(scx, scz, false)

func spawn_point() -> Vector3:
	_ensure_spawn_chunk()
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
	if c == null or c.data.is_empty():
		return
	var lx := x & 15
	var lz := z & 15
	var i := (y << 8) | (lz << 4) | lx
	if c.get_local(lx, y, lz) == id and c.fl[i] == lvl:
		return
	c.set_local(lx, y, lz, id)
	c.fl[i] = lvl
	_fluid_write = true
	if _fluidprobe:
		_fp_writes += 1
	_mark_fluid_around(cx, cz)
	_record_edit(cx, cz, i, id, lvl)
	if lvl > 0:
		fluid_wet[_key(cx, cz)] = true

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
	return 0

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
		sig = "%d:%d" % [cl.size(), int(floorf(float(cl[0].x) / 2.0)) * 4096 + int(floorf(float(cl[0].y) / 2.0))]
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
		if _fluidprobe:
			print("FLUIDPROBE slept=1 tick_ms=%.3f window=%d wet_cells=0 writes=%d stable=%d sig=%s" % [
				(Time.get_ticks_usec() - t0) / 1000.0, cl.size(), _fp_writes, _fluid_stable, sig])
		fluid_tick_samples.append((Time.get_ticks_usec() - t0) / 1000.0)
		return
	var hmax := Data.HEIGHT - 1
	var fp_wet := 0
	var fp_chunks := 0
	var fp_writes0 := _fp_writes
	for pos in cl:
		var c: Node3D = chunks.get(_key(pos.x, pos.y))
		if c == null or c.data.is_empty():
			continue
		var ck := _key(int(c.cx), int(c.cz))
		if not fluid_wet.has(ck):
			continue
		var wet_cells := 0
		var data: PackedByteArray = c.data
		var fl: PackedByteArray = c.fl
		var cx: int = int(c.cx)
		var cz: int = int(c.cz)
		if _fluidprobe:
			fp_chunks += 1
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
						wet_cells += 1
						if _fluidprobe:
							fp_wet += 1
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
		if wet_cells == 0:
			fluid_wet.erase(ck)
	if tick_time:
		print("TICKMS ", (Time.get_ticks_usec() - t0) / 1000.0)
	if _fluidprobe:
		print("FLUIDPROBE slept=0 tick_ms=%.3f window=%d chunks=%d wet_cells=%d writes=%d stable=%d sig=%s" % [
			(Time.get_ticks_usec() - t0) / 1000.0, cl.size(), fp_chunks, fp_wet, _fp_writes - fp_writes0, _fluid_stable, sig])
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
