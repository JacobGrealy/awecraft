# AC-0418: the satellite bake's worker-side work, DETACHED from the
# SatelliteBody node.
#
# Why this file exists: the AC-0414 run measured the mid-bake exit crash -
# the pool worker callables were methods OF THE NODE (_mt_shard_task /
# _mt_face_task / _bake_worker), so a worker thread executing one of them
# was inside the node's script instance; when the process exits, the
# scene-tree teardown frees the node (and its script instance) while the
# worker is still inside the call - a use-after-free (reproduced: a
# segfault on a pool thread in the worker's frame; the exit status is the
# signal, the log stays clean). The shipped mitigation (the file-scope
# SatelliteBody._mt_exit_aborted flag) only shrinks the window to the
# function epilogue - the worker is still inside the instance until it
# returns.
#
# The close: every worker task is now a STATIC function of this plain
# script, and every value it touches travels in `st` - a plain
# Dictionary (RefCounted) the node fills on the main thread before
# enqueue and passes as a BOUND ARGUMENT. A Callable to a static function
# holds no object, and the state Dict is kept alive by the task's own
# bound argument, so it outlives the node's teardown: at process exit
# the node is freed, this state is not, and the worker has nothing of
# the node's left in its frame. The worker's references are: the state
# (its own), the AweGen C++ handle (a C++ singleton, alive for the
# process), SphereMath (a class_name static), and engine singletons.
# The shipped mitigation stays and is exercised: every task reads
# SatelliteBody._mt_exit_aborted FIRST (readable without touching
# anything that gets freed) and stands down at the next boundary.
#
# Byte-identity: every expression below is copied VERBATIM from
# satellite_body.gd - only the source of the values changes (instance
# reads -> st reads; the consts travel in st, their single home stays
# satellite_body.gd). Same values, same operation order -> same bytes.
class_name SatelliteBakeWorker

# The per-bake state (keys, filled by the node in _bake_state()):
#   g            Variant   the AweGen C++ reference (WorldGen.gen_cpp())
#   R/SEA/HMAX   float/int the bake parameters (configure values)
#   seed         int       the world seed
#   mesh_step    float     the live grid step (the _ready env override)
#   pay_total    int       HOME_CHUNKS + 10 * FACE_CHUNKS
#   cache_dir    String    user://satellite/... (the node's _cache_dir())
#   npix/face_grid/face_cells/home_n/home_half/home_chunks/face_chunks/shard_len
#                          the node's consts, carried as values
#   fcc/lx/ly/lz the node's consts, carried as values
#   pay          PackedByteArray  merged payload (the face tasks' read-only input)
#   shard_bufs/shard_err/shard_ms 98 per-shard worker channels
#   face_img/face_guard/face_geom/face_err/face_ms/face_png_ms/face_load_ms
#                            12 per-face worker channels
#   guard/worker_images/geom   the single-task (OFF path) results
#   gen_ms/color_ms/png_ms/load_ms/worker_ms  the single-task stats
#   result       Dictionary  {"ok": bool, "why": String, "ship": String}
#   abort        bool        the probe arm's clean-quit handle (main writes)
#   done         bool        the single-task completion flag (worker writes LAST)


# --- the task entry points -------------------------------------------------

# One payload shard (records [s*shard_len, ...+shard_len) in the global
# bake order - the gen_one mapping, untouched). The worker writes only
# its own buffer.
static func shard_task(st: Dictionary, g: Variant, s: int) -> void:
	if g == null:
		st["shard_err"][s] = "no AweGen (WorldGen.gen_cpp() null)"
		return
	var t0 := Time.get_ticks_msec()
	var b: PackedByteArray = st["shard_bufs"][s]
	var i0: int = int(s) * int(st["shard_len"])
	var i1: int = mini(i0 + int(st["shard_len"]), int(st["pay_total"]))
	for i in range(i0, i1):
		# static FIRST: it is readable without touching the instance, so
		# at process exit the check itself cannot UAF - and the branch
		# RETURNS WITHOUT WRITING STATE (the main thread is exiting too;
		# nothing reads it).
		if SatelliteBody._mt_exit_aborted:
			return
		if bool(st["abort"]):
			st["shard_err"][s] = "aborted"
			return
		var rec: PackedByteArray = gen_one(g, st, i)
		if rec.size() != 1024:
			st["shard_err"][s] = "generate_far payload %d bytes at record %d (want 1024)" % [rec.size(), i]
			return
		b.append_array(rec)  # records land in generation order
	st["shard_ms"][s] = float(Time.get_ticks_msec() - t0)


# One face's whole pipeline on one pool worker: colour rows (the
# step_face machine - arithmetic untouched, per-face state in a
# task-owned Dictionary), the PNG write, the read-back + variance guard,
# the geometry. The worker writes only its own face-index slots and its
# own PNG file; face_img is set LAST, so the main thread sees a face as
# done only when all of it is. The 5000 ms slice budget is the
# resumable row machine.
static func face_task(st: Dictionary, f: int) -> void:
	# static FIRST: readable without touching the instance; the branch
	# returns before ANY state is read or written (at process exit the
	# node is being torn down under us - see _mt_exit_aborted).
	if SatelliteBody._mt_exit_aborted:
		return
	var t0 := Time.get_ticks_msec()
	var fstate: Dictionary = start_face(st, f)
	var errl := ""
	if SatelliteBody._mt_exit_aborted:
		return
	if bool(st["abort"]):
		errl = "aborted"
	if errl == "":
		var t_slice := Time.get_ticks_usec()
		while not step_face(st, f, fstate, t_slice, 5000.0):
			if SatelliteBody._mt_exit_aborted:
				return  # exit - the epilogue's state writes are skipped too
			if bool(st["abort"]):
				errl = "aborted"
				break
			t_slice = Time.get_ticks_usec()
	if errl == "":
		var t_r := Time.get_ticks_usec()
		var img: Image = load_png(face_path(st, f))
		if img == null:
			errl = "cannot read %s" % face_path(st, f)
		else:
			var gd := guard_check(img)
			if not bool(gd["ok"]):
				errl = "variance guard failed on face %d: %s" % [f, str(gd)]
			else:
				st["face_geom"][f] = geom_for_face_local(st, f, fstate["hgrid"])
				st["face_guard"][f] = gd
				st["face_load_ms"][f] = float(Time.get_ticks_usec() - t_r) / 1000.0
				st["face_img"][f] = img  # LAST: the done marker
	if errl != "":
		st["face_err"][f] = errl
	st["face_png_ms"][f] = float(fstate["png_ms"])
	st["face_ms"][f] = float(Time.get_ticks_msec() - t0)


# The single-task bake (Settings "sat_preload" OFF - the pre-AC-0414
# path, now reference-free too: the same race class lived in this
# worker - the user closing the game during the ~13 min bake). One pool
# worker runs the whole pipeline: generate_far x pay_total -> pay, the
# piece-1 colour per face (the row machine, budget INF), the PNG write
# as each face completes, the read-back + variance guard, the geometry.
# Writes only its own state slots; result/done are set last.
static func single_task(st: Dictionary, g: Variant) -> void:
	var err := ""
	var ship_msg := ""  # the AWECRAFT_SATELLITE_SHIP report
	var w0 := Time.get_ticks_msec()
	if g == null:
		err = "no AweGen (WorldGen.gen_cpp() null)"
	if err == "":
		var t0 := Time.get_ticks_msec()
		var p: PackedByteArray = st["pay"]
		for i in int(st["pay_total"]):
			# static FIRST (the exit stand-down), then the probe arm's
			# clean-quit handle (the game never aborts - it stays false
			# and the check is inert).
			if SatelliteBody._mt_exit_aborted:
				st["result"] = {"ok": false, "why": "exit aborted", "ship": ""}
				st["worker_ms"] = int(Time.get_ticks_msec() - w0)
				st["done"] = true
				return
			if i % 8192 == 0 and bool(st["abort"]):
				err = "aborted"
				break
			var rec: PackedByteArray = gen_one(g, st, i)
			if rec.size() != 1024:
				err = "generate_far payload %d bytes at record %d" % [rec.size(), i]
				break
			p.append_array(rec)  # records land in generation order
		st["gen_ms"] = float(Time.get_ticks_msec() - t0)  # ms (the fields are ms)
	if err == "" and int(pay_size(st)) != int(st["pay_total"]) * 1024:
		err = "payload %d bytes (want %d)" % [pay_size(st), int(st["pay_total"]) * 1024]
	var geoms := []
	if err == "":
		var t_face := Time.get_ticks_msec()
		var png_sum := 0.0
		for f in 12:
			# static FIRST (the exit stand-down), then the probe arm's
			# clean-quit handle (the game never aborts).
			if SatelliteBody._mt_exit_aborted:
				st["result"] = {"ok": false, "why": "exit aborted", "ship": ""}
				st["worker_ms"] = int(Time.get_ticks_msec() - w0)
				st["done"] = true
				return
			if bool(st["abort"]):
				err = "aborted"
				break
			var fstate: Dictionary = start_face(st, f)
			while not step_face(st, f, fstate, Time.get_ticks_usec(), 1e9):
				pass
			# the geometry RIGHT AFTER the colour - the face's H grid is
			# live; the row machine's per-face state carries it (the
			# pre-r2 second-geometry-loop bug the node twin documents).
			geoms.append(geom_for_face_local(st, f, fstate["hgrid"]))
			png_sum += float(fstate["png_ms"])
		# colour time = the face-pipeline wall minus the PNG writes (the
		# old main-thread slice's field semantics: colour and png
		# separate; step_face accrues the png time per face).
		st["color_ms"] = float(Time.get_ticks_msec() - t_face) - png_sum
		st["png_ms"] = png_sum
		st["pay"] = PackedByteArray()  # 1.74 GB no longer needed (the faces are coloured + on disk)
		st["geom"] = geoms
		ship_msg = ship_faces(st)
	if err == "":
		var t2 := Time.get_ticks_msec()
		var gds := []
		var imgs := []
		for f in 12:
			var img: Image = load_png(face_path(st, f))
			if img == null:
				err = "cannot read %s" % face_path(st, f)
				break
			var gd := guard_check(img)
			gds.append(gd)
			if not bool(gd["ok"]):
				err = "variance guard failed on face %d: %s" % [f, str(gd)]
				break
			imgs.append(img)
		st["load_ms"] = float(Time.get_ticks_msec() - t2)  # ms
		st["guard"] = gds
		st["worker_images"] = imgs
	st["result"] = {"ok": err == "", "why": err, "ship": ship_msg}
	st["worker_ms"] = int(Time.get_ticks_msec() - w0)
	st["done"] = true


# --- the payload ------------------------------------------------------------

# AC-0311 piece 3 (the same flat-frame class the port retired from
# generation): the piece-1 keying's per-face seed salt is DROPPED - in
# the sphere domain the field is ONE pure f(world, seed), so the bake
# and the streamed face chunks read the SAME terrain. The (face, R)
# thread reaches the C++ (d, δ) domain on both lanes (R explicit).
static func gen_one(g: Variant, st: Dictionary, idx: int) -> PackedByteArray:
	if idx < int(st["home_chunks"]):
		var cx: int = idx % int(st["home_n"]) - int(st["home_half"])
		var cz: int = idx / int(st["home_n"]) - int(st["home_half"])
		return g.generate_far(cx, cz, int(st["seed"]), int(st["HMAX"]), int(st["SEA"]), 0, float(st["R"]))
	var kf: int = idx - int(st["home_chunks"])
	var f: int = 2 + kf / int(st["face_chunks"])
	var kk: int = kf % int(st["face_chunks"])
	var ccx: int = kk % int(st["face_grid"])
	var ccz: int = kk / int(st["face_grid"])
	return g.generate_far(f * int(st["face_grid"]) + ccx, f * int(st["face_grid"]) + ccz, int(st["seed"]), int(st["HMAX"]), int(st["SEA"]), f, float(st["R"]))


static func record_offset(st: Dictionary, f: int, ccx: int, ccz: int) -> int:
	return (int(st["home_chunks"]) + (f - 2) * int(st["face_chunks"]) + ccz * int(st["face_grid"]) + ccx) * 1024


static func home_rec_offset(st: Dictionary, cx: int, cz: int) -> int:
	return ((cz + int(st["home_half"])) * int(st["home_n"]) + (cx + int(st["home_half"]))) * 1024


static func pay_size(st: Dictionary) -> int:
	return st["pay"].size()


# --- the per-face row machine ----------------------------------------------
# The st-dict twin of the old instance-field machine: the arithmetic
# (row/uv mapping, chunk cache, the pixel call, the PNG bytes) is the
# same, so the sharded bake and the single-task bake are both
# byte-identical to the pre-detached output.

# The per-face state (the task owns it; the instance fields are gone).
static func start_face(st: Dictionary, f: int) -> Dictionary:
	var fs: Dictionary = {}
	var npix: int = int(st["npix"])
	fs["row"] = 0
	fs["out"] = PackedByteArray()
	fs["out"].resize(npix * npix * 3)
	fs["hgrid"] = PackedInt32Array()
	fs["hgrid"].resize(npix * npix)
	fs["png_ms"] = 0.0
	if f > 1:
		# AC-0469 stage D: H2/T2 live in the chart's CELL space - the
		# chunk-space span face_grid*16 = 6,288 cells per axis (2.6
		# texels/chunk against the npix texture), not the old 1:1
		# texel:cell grid.
		var fcells: int = int(st["face_cells"])
		fs["h2"] = PackedInt32Array()
		fs["h2"].resize(fcells * fcells)
		fs["t2"] = PackedByteArray()
		fs["t2"].resize(fcells * fcells)
		fs["bld_row"] = 0
	else:
		fs["ch_cx"] = -999
		fs["ch_cz"] = -999
	return fs


# The home-pair chunk load (reads pay - merged and stable by the time
# any face runs; never writes it).
static func home_chunk_load(st: Dictionary, fs: Dictionary, cx: int, cz: int) -> void:
	fs["ch_cx"] = cx
	fs["ch_cz"] = cz
	var o := home_rec_offset(st, cx, cz)
	var h16 := PackedInt32Array()
	h16.resize(256)
	var t16 := PackedByteArray()
	t16.resize(256)
	var pay: PackedByteArray = st["pay"]
	for slot in 256:
		h16[slot] = int(pay[o + 2 * slot]) | (int(pay[o + 2 * slot + 1]) << 8)
		t16[slot] = int(pay[o + 768 + slot])
	# clamped central differences (the piece-1 home recipe: the gradient
	# is computed PER CHUNK - clamped at the chunk edges), 1 m spacing.
	var gx16 := PackedFloat32Array()
	gx16.resize(256)
	var gz16 := PackedFloat32Array()
	gz16.resize(256)
	for lz in 16:
		for lx in 16:
			var s := lz * 16 + lx
			gx16[s] = float(h16[lz * 16 + mini(lx + 1, 15)] - h16[lz * 16 + maxi(lx - 1, 0)]) / 2.0
			gz16[s] = float(h16[mini(lz + 1, 15) * 16 + lx] - h16[maxi(lz - 1, 0) * 16 + lx]) / 2.0
	fs["h16"] = h16
	fs["t16"] = t16
	fs["gx16"] = gx16
	fs["gz16"] = gz16


# One 16-row H2/T2 block (rows 16b..16b+15) from the payload. The
# mirror class stores cell (iu, iv) in local slot (15 - (iu&15), iv&15)
# (SphereMath.face_mirror_x, machine-diffed in piece 1).
static func face_build_block(st: Dictionary, f: int, fs: Dictionary, b: int) -> void:
	var mirrored: bool = SphereMath.face_mirror_x(f)
	var h2: PackedInt32Array = fs["h2"]
	var t2: PackedByteArray = fs["t2"]
	var pay: PackedByteArray = st["pay"]
	var fcells: int = int(st["face_cells"])  # AC-0469 stage D: the H2/T2 cell-space width
	for lz in 16:
		var iv: int = b * 16 + lz
		for ccx in int(st["face_grid"]):
			var o := record_offset(st, f, ccx, b)
			for lx in 16:
				var slot := lz * 16 + lx
				var iu: int = ccx * 16 + (15 - lx if mirrored else lx)
				var pidx: int = iv * fcells + iu
				h2[pidx] = int(pay[o + 2 * slot]) | (int(pay[o + 2 * slot + 1]) << 8)
				t2[pidx] = int(pay[o + 768 + slot])


# AC-0469 stage D: pixel row/column k's CENTRE CELL on an axis of
# cells_axis chart cells spread over the npix-pixel texture (2.6
# texels/chunk). Texel centres sit at (k+0.5)/npix - the same lattice the
# hgrid_sample + PNG texels use. The axis count is the chart's OWN (the
# chunk-space span carries 5 padding cells past it), so the centre cell
# always lands in the chart.
static func _sat_cell_of(k: int, cells_axis: int, npix: int) -> int:
	return int(floorf((float(k) + 0.5) * float(cells_axis) / float(npix)))


# The row machine on the per-face state. Returns true when the face's
# rows are done AND its PNG is written.
static func step_face(st: Dictionary, f: int, fs: Dictionary, t0: int, budget_ms: float) -> bool:
	var npix: int = int(st["npix"])
	var R: float = float(st["R"])
	# AC-0469 stage D: per-axis chart counts + the per-axis cell metres
	# (the gradient denominators, the AC-0471 grid: the halved axis is
	# 3,141 cells of 1.00019 m - the old 0.5 m factor is gone).
	var cells_u_f: int = SphereMath.cells_u(f)
	var cells_v_f: int = SphereMath.cells_v(f)
	var du_m: float = SphereMath.face_axis_span(f, R, true) / float(cells_u_f)
	var dv_m: float = SphereMath.face_axis_span(f, R, false) / float(cells_v_f)
	var fcells: int = int(st["face_cells"])  # the H2/T2 cell-space width
	var hw: float = SphereMath.face_width(R) * 0.5
	var hgrid: PackedInt32Array = fs["hgrid"]
	while int(fs["row"]) < npix:
		var j: int = int(fs["row"])
		if f > 1:
			# AC-0469 stage D: build every H2 block row j can touch (row j
			# reads its centre cell + the j+1 row's gradient neighbour one
			# cell on; blocks are built in order).
			var cv_hi: int = mini(cells_v_f - 1, _sat_cell_of(j + 1, cells_v_f, npix) + 1)
			var need_hi: int = mini(int(st["face_grid"]) - 1, cv_hi / 16)
			while int(fs["bld_row"]) <= need_hi:
				face_build_block(st, f, fs, int(fs["bld_row"]))
				fs["bld_row"] = int(fs["bld_row"]) + 1
				if (Time.get_ticks_usec() - t0) / 1000.0 >= budget_ms:
					return false
		var cz := 0
		var lz := 0
		if f <= 1:
			var z: int = int(floorf(hw * (2.0 * (float(j) + 0.5) / npix - 1.0)))
			cz = int(floorf(float(z) / 16.0))
			lz = int(z - cz * 16.0)
		for i in npix:
			var hv: int
			var tv: int
			var gx: float
			var gz: float
			if f <= 1:
				var x: int = int(floorf(hw * ((float(i) + 0.5) / npix if f == 0 else (float(i) + 0.5) / npix - 1.0)))
				var cx: int = int(floorf(float(x) / 16.0))
				var lx: int = int(x - cx * 16.0)
				if cx != int(fs["ch_cx"]) or cz != int(fs["ch_cz"]):
					home_chunk_load(st, fs, cx, cz)
				var h16: PackedInt32Array = fs["h16"]
				var t16: PackedByteArray = fs["t16"]
				var gx16: PackedFloat32Array = fs["gx16"]
				var gz16: PackedFloat32Array = fs["gz16"]
				var slot: int = lz * 16 + lx
				hv = h16[slot]
				tv = int(t16[slot])
				gx = gx16[slot]
				gz = gz16[slot]
			else:
				# AC-0469 stage D: the pixel's CENTRE CELL in chart cell
				# space (2.6 texels/chunk; the lattice the hgrid_sample +
				# PNG texels use, texel centres at (k+0.5)/npix). The
				# gradient is the clamped central difference AT the sample
				# cell, in cell metres.
				var h2: PackedInt32Array = fs["h2"]
				var t2: PackedByteArray = fs["t2"]
				var cu: int = _sat_cell_of(i, cells_u_f, npix)
				var cv: int = _sat_cell_of(j, cells_v_f, npix)
				hv = h2[cv * fcells + cu]
				tv = int(t2[cv * fcells + cu])
				gx = (float(h2[cv * fcells + mini(cu + 1, cells_u_f - 1)]) - float(h2[cv * fcells + maxi(cu - 1, 0)])) / (2.0 * du_m)
				gz = (float(h2[mini(cv + 1, cells_v_f - 1) * fcells + cu]) - float(h2[maxi(cv - 1, 0) * fcells + cu])) / (2.0 * dv_m)
			hgrid[j * npix + i] = hv  # the height channel (the geometry + PNG alpha source)
			pixel_write(st, fs, (j * npix + i) * 3, hv, tv, gx, gz)
		fs["row"] = j + 1
		if (Time.get_ticks_usec() - t0) / 1000.0 >= budget_ms:
			return false
	# face complete - the PNG (the deflate spike lands on the calling
	# thread - the pool worker). RGBA8: the alpha channel carries the
	# height (A = round(H * 255 / HMAX)); the RGB bytes are exactly the
	# pixel output (untouched: the colour stays canonical).
	var t_png := Time.get_ticks_usec()
	var out: PackedByteArray = fs["out"]
	var out4 := PackedByteArray()
	out4.resize(npix * npix * 4)
	for k in npix * npix:
		out4[k * 4] = out[k * 3]
		out4[k * 4 + 1] = out[k * 3 + 1]
		out4[k * 4 + 2] = out[k * 3 + 2]
		out4[k * 4 + 3] = clampi(int(roundf(float(hgrid[k]) * 255.0 / float(st["HMAX"]))), 0, 255)
	var img := Image.create_from_data(npix, npix, false, Image.FORMAT_RGBA8, out4)
	img.save_png(face_path(st, f))
	fs["png_ms"] = float(fs["png_ms"]) + float(Time.get_ticks_usec() - t_png) / 1000.0
	fs["out"] = PackedByteArray()  # release the 3 MB RGB (the face is on disk)
	return true


# The piece-1 colour per pixel (arithmetic untouched).
static func pixel_write(st: Dictionary, fs: Dictionary, o: int, hv: int, tv: int, gx: float, gz: float) -> void:
	var ocean: bool = hv < int(st["SEA"])
	var col: Vector3
	if ocean:
		col = st["fcc"][5]
	else:
		match tv:
			1:
				col = st["fcc"][1]
			4:
				col = st["fcc"][4]
			12:
				col = st["fcc"][12]
			32:
				col = st["fcc"][32]
			_:
				col = st["fcc"][5]  # the piece-1 default (an unknown top reads as water)
	var b: float = 0.45 + 0.55 * clampf((-float(st["lx"]) * gx + float(st["ly"]) - float(st["lz"]) * gz) / sqrt(gx * gx + gz * gz + 1.0), 0.0, 1.0)
	if ocean:
		b = 1.0
	var out: PackedByteArray = fs["out"]
	out[o] = byte_val(byte_srgb(col.x * b))
	out[o + 1] = byte_val(byte_srgb(col.y * b))
	out[o + 2] = byte_val(byte_srgb(col.z * b))


# sRGB companding (the standard piecewise; the inverse of the
# srgb_to_linear the fcc probe applied) - the piece-1 formula,
# byte-for-byte.
static func byte_srgb(v: float) -> float:
	if v <= 0.0031308:
		return v * 12.92
	return 1.055 * pow(v, 1.0 / 2.4) - 0.045


# np.round is round-half-to-even; match it so the bake reproduces the
# shipped seed-44 PNG where the float paths agree.
static func byte_val(v: float) -> int:
	var x := v * 255.0
	var fl := int(floorf(x))
	var fr := x - float(fl)
	var r: int
	if fr > 0.5:
		r = fl + 1
	elif fr < 0.5:
		r = fl
	else:
		r = fl + 1 if fl % 2 == 1 else fl
	return clampi(r, 0, 255)


# --- the load-side helpers (main thread + worker share them) ----------------

# The runtime twin of the piece-1 on-disk variance guard (the smear
# repair): the image must vary along BOTH axes.
static func guard_check(img: Image) -> Dictionary:
	var rows := 1
	var cols := 1
	var minc := [255, 255, 255]
	var maxc := [0, 0, 0]
	var first_line: PackedByteArray = PackedByteArray()
	for k in 16:
		var j := k * 64
		var line := PackedByteArray()
		for i in 16:
			var px := img.get_pixel(i * 64, j)
			line.append(px.r8)
			line.append(px.g8)
			line.append(px.b8)
			minc[0] = mini(minc[0], px.r8)
			minc[1] = mini(minc[1], px.g8)
			minc[2] = mini(minc[2], px.b8)
			maxc[0] = maxi(maxc[0], px.r8)
			maxc[1] = maxi(maxc[1], px.g8)
			maxc[2] = maxi(maxc[2], px.b8)
		if first_line.is_empty():
			first_line = line
		elif line != first_line:
			rows += 1
	var first_col: PackedByteArray = PackedByteArray()
	for k in 16:
		var i := k * 64
		var col := PackedByteArray()
		for j in 16:
			var px := img.get_pixel(i, j * 64)
			col.append(px.r8)
			col.append(px.g8)
			col.append(px.b8)
		if first_col.is_empty():
			first_col = col
		elif col != first_col:
			cols += 1
	var spread: int = mini(mini(maxc[0] - minc[0], maxc[1] - minc[1]), maxc[2] - minc[2])
	return {
		"rows": rows,
		"cols": cols,
		"spread": spread,
		"ok": rows >= 4 and cols >= 4 and spread >= 8,
	}


static func load_png(pth: String) -> Image:
	var f := FileAccess.open(pth, FileAccess.READ)
	if f == null:
		return null
	var b := f.get_buffer(f.get_length())
	f.close()
	var img := Image.new()
	if img.load_png_from_buffer(b) != OK:
		return null
	return img


static func face_path(st: Dictionary, f: int) -> String:
	return st["cache_dir"] + "/satellite_face%02d.png" % f


# --- the geometry (pure SphereMath - thread-safe) ---------------------------

# (u subdivisions, v subdivisions) of the displaced grid for face f.
# The home pair is the half-width face: u spans W/2 (196 steps at
# R = 4000), v spans W (393). Faces 2-11 span W x W (393 x 393).
static func mesh_grid(R: float, mesh_step: float, f: int) -> Vector2i:
	var W: float = SphereMath.face_width(R)
	if f <= 1:
		return Vector2i(int(roundf(W / 2.0 / mesh_step)), int(roundf(W / mesh_step)))
	return Vector2i(int(roundf(W / mesh_step)), int(roundf(W / mesh_step)))


# Bilinear over the 1024^2 per-texel H grid. Texel centres sit at
# (k + 0.5) / NPIX in (u, v) - the same lattice the PNG texels and
# step_face's H reads use.
static func hgrid_sample(hgrid: PackedInt32Array, u: float, v: float, npix: int) -> float:
	var fx: float = clampf(u * float(npix) - 0.5, 0.0, float(npix) - 1.0)
	var fy: float = clampf(v * float(npix) - 0.5, 0.0, float(npix) - 1.0)
	var x0: int = int(fx)
	var y0: int = int(fy)
	var x1: int = mini(x0 + 1, npix - 1)
	var y1: int = mini(y0 + 1, npix - 1)
	var tx: float = fx - float(x0)
	var ty: float = fy - float(y0)
	var h00: float = float(hgrid[y0 * npix + x0])
	var h10: float = float(hgrid[y0 * npix + x1])
	var h01: float = float(hgrid[y1 * npix + x0])
	var h11: float = float(hgrid[y1 * npix + x1])
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), ty)


# The face geometry (the single implementation - the worker's face tasks
# call it on their own H grids; the main-thread cache wrapper
# SatelliteBody._geom_for_face calls it for the LOAD phase).
static func geom_for_face_local(st: Dictionary, f: int, hgrid: PackedInt32Array) -> Dictionary:
	var R: float = float(st["R"])
	var nu_nv: Vector2i = mesh_grid(R, float(st["mesh_step"]), f)
	var nu: int = nu_nv.x
	var nv: int = nu_nv.y
	var npix: int = int(st["npix"])
	var has_h: bool = hgrid.size() == npix * npix
	var RB: float = R + float(st["SEA"])  # the winding-test radius (any radial scale works)
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var nrm := PackedVector3Array()
	var idx := PackedInt32Array()
	for j in nv + 1:
		for i in nu + 1:
			var u: float = float(i) / float(nu)
			var v: float = float(j) / float(nv)
			var rr: float = RB
			if has_h:
				rr = R + hgrid_sample(hgrid, u, v, npix)
			var p: Vector3 = SphereMath.uv_to_world(f, u, v, rr)
			verts.append(p)  # body origin = the sphere centre: local == radial
			uvs.append(Vector2(u, v))
			nrm.append(p / rr)
	# winding per face: the chart axes differ per face; the corner test
	# picks the per-face index order (the AC-0411 inversion - see
	# SatelliteBody._geom_for_face for the full note; copied verbatim).
	var p00: Vector3 = SphereMath.uv_to_world(f, 0.0, 0.0, RB)
	var p10: Vector3 = SphereMath.uv_to_world(f, 1.0, 0.0, RB)
	var p01: Vector3 = SphereMath.uv_to_world(f, 0.0, 1.0, RB)
	var outward: bool = (p01 - p00).cross(p10 - p00).dot(p00) < 0.0
	for j in nv:
		for i in nu:
			var a: int = j * (nu + 1) + i
			var b: int = a + 1
			var c: int = a + (nu + 1)
			var d: int = c + 1
			if outward:
				idx.append_array([a, c, b, b, c, d])
			else:
				idx.append_array([a, b, c, b, d, c])
	return {"v": verts, "u": uvs, "n": nrm, "i": idx}


# The AWECRAFT_SATELLITE_SHIP step (harness-only env; unset = no-op).
# Main-thread edition on the state (the sharded path runs it at
# assembly; the single task runs it in its own slot).
static func ship_faces(st: Dictionary) -> String:
	var ship_dir := OS.get_environment("AWECRAFT_SATELLITE_SHIP")
	if ship_dir == "":
		return ""
	var err := ""
	for f in 12:
		var rf := FileAccess.open(face_path(st, f), FileAccess.READ)
		if rf == null:
			err = "ship: cannot read %s" % face_path(st, f)
			break
		var wb := rf.get_buffer(rf.get_length())
		rf.close()
		var wf := FileAccess.open(ship_dir + "/satellite_face%02d.png" % f, FileAccess.WRITE)
		if wf == null:
			err = "ship: cannot write %s" % (ship_dir + "/satellite_face%02d.png" % f)
			break
		wf.store_buffer(wb)
		wf.close()
	return "shipped 12 height-channel faces to %s" % ship_dir if err == "" else err
