extends Node

const PATH := "user://awecraft.cfg"

const RENDER_MIN := 4
const RENDER_MAX := 96
const SIM_MIN := 1
# AC-0225: Options "Chunk meshes per frame" slider range — the per-frame
# streaming handoff burst (the AC-0224 drain cap, world.gd stream_ho_cap).
const CHUNKS_PER_FRAME_MIN := 1
const CHUNKS_PER_FRAME_MAX := 100
# AC-0232 (dither dropped in AC-0241): the fog start-distance slider —
# percent (0-100) of the render edge ((render_dist + 1) * 16 blocks; the same
# base the AC-0226 formula scales from).
const PCT_MIN := 0
const PCT_MAX := 100

const DEFAULTS := {
	"render_dist": 50,
	# AC-0152: Bedrock Realms default — Simulate 4 (taxicab diamond, 41 chunks).
	"sim_dist": 4,
	"volume": 100,
	"fullscreen": false,
	"resolution": "1280x720",
	"seed": 44,
	"hunger_enabled": true,
	"debug_stats": false,
	# AC-0170: tee Debug.log/Debug.error output into the in-game console.
	"debug_logging": false,
	"overlay_band": false,
	"overlay_light": false,
	"overlay_collision": false,
	"flight_speed": 4,
	# AC-0225: streaming chunk-mesh handoff burst per frame (the AC-0224
	# drain cap); 3 = the shipped AC-0224 default, so the default is a
	# no-behavior-change.
	"chunks_per_frame": 3,
	# AC-0232 (AC-0227's dither was dropped in AC-0241): fog_start_pct -
	# 87 ~ the shipped AC-0226 0.875 coefficient (int slider, percent of
	# the render edge (R+1)*16), kept at/under 0.875 so the full-fog
	# boundary stays ahead of the worst-case pop-in face at every R >= 7.
	"fog_start_pct": 87,
	# AC-0261: the med/low band split (taxi chunks). The visible LOD
	# zones: HIGH = [0, sim_dist), MED (8x8x8) = [sim_dist, low_start),
	# LOW (4x4x4) = [low_start, render_dist); NOTHING renders past the
	# render distance (data-only ahead of it). Default = the midpoint of
	# the [sim, render] band for the default sim 4 / render 50.
	# clamp_low_start_to_render re-defaults out-of-band stored values to
	# the band midpoint.
	"low_start": 27,
	# AC-0257 (Developer submenu): the tier-0 Chebyshev radius around the
	# player column — columns this close go FULL COLUMN straight to high
	# (default 0 = the player column only, the existing behavior).
	"tier0_radius": 0,
	# AC-0257: worker-thread in-flight caps. 0 = auto (scale to all
	# available cores, never past — gen/mesh split 40/60); >0 = the
	# explicit cap for that lane.
	"worker_gen_threads": 0,
	"worker_mesh_threads": 0,
}

# AC-0257 (Developer submenu) slider ranges.
const TIER0_RADIUS_MAX := 8
const WORKER_THREADS_MAX := 16

var values: Dictionary = {}


func _ready() -> void:
	load_settings()


func load_settings() -> Dictionary:
	values = {}
	for k in DEFAULTS:
		values[k] = DEFAULTS[k]
	if OS.get_environment("AWECRAFT_IGNORE_SETTINGS") == "1":
		return values
	if not FileAccess.file_exists(PATH):
		return values
	var cf := ConfigFile.new()
	if cf.load(PATH) != OK:
		return values
	for k in values:
		if cf.has_section_key("settings", k):
			_clamp(k, cf.get_value("settings", k))
	clamp_sim_to_render()
	clamp_low_start_to_render()
	return values


func clamp_sim_to_render() -> void:
	if int(values["sim_dist"]) > int(values["render_dist"]):
		values["sim_dist"] = int(values["render_dist"])


# AC-0261: low_start lives inside the visible band [sim, render] — MED =
# [sim, low_start), LOW = [low_start, render]; nothing renders past the
# render distance. A stored value outside the band (the old far-ring
# default 58) re-defaults to the band MIDPOINT (clamping to the edge
# would silently cancel the LOW band).
func clamp_low_start_to_render() -> void:
	var lo := mini(int(values["sim_dist"]), int(values["render_dist"]))
	var hi := int(values["render_dist"])
	var ls := int(values["low_start"])
	if ls < lo or ls > hi:
		values["low_start"] = int((lo + hi) / 2)


func _clamp(k: String, v) -> void:
	match k:
		"render_dist":
			values[k] = clampi(int(v), RENDER_MIN, RENDER_MAX)
		"sim_dist":
			values[k] = clampi(int(v), SIM_MIN, RENDER_MAX)
		# AC-0252: the med/low band split distance (taxi chunks).
		"low_start":
			values[k] = clampi(int(v), 2, RENDER_MAX)
		"volume":
			values[k] = roundi(clampf(float(v), 0.0, 100.0))
		"fullscreen":
			values[k] = bool(v)
		"hunger_enabled":
			values[k] = bool(v)
		"debug_stats":
			values[k] = bool(v)
		"debug_logging":
			values[k] = bool(v)
		"overlay_band":
			values[k] = bool(v)
		"overlay_light":
			values[k] = bool(v)
		"overlay_collision":
			values[k] = bool(v)
		"flight_speed":
			values[k] = clampi(int(v), 1, 50)
		"chunks_per_frame":
			values[k] = clampi(int(v), CHUNKS_PER_FRAME_MIN, CHUNKS_PER_FRAME_MAX)
		# AC-0232 (dither dropped in AC-0241): the fog percent slider.
		"fog_start_pct":
			values[k] = clampi(int(v), PCT_MIN, PCT_MAX)
		# AC-0257 (Developer submenu).
		"tier0_radius":
			values[k] = clampi(int(v), 0, TIER0_RADIUS_MAX)
		"worker_gen_threads":
			values[k] = clampi(int(v), 0, WORKER_THREADS_MAX)
		"worker_mesh_threads":
			values[k] = clampi(int(v), 0, WORKER_THREADS_MAX)
		"seed":
			values[k] = int(v)
		"resolution":
			var s := String(v)
			var parts := s.split("x")
			if parts.size() == 2 and parts[0].is_valid_int() and parts[1].is_valid_int():
				values[k] = s


func set_value(k: String, v) -> void:
	_clamp(k, v)
	clamp_sim_to_render()
	clamp_low_start_to_render()
	save()


func save() -> void:
	var cf := ConfigFile.new()
	for k in values:
		cf.set_value("settings", k, values[k])
	cf.save(PATH)


func reset_defaults() -> void:
	for k in DEFAULTS:
		values[k] = DEFAULTS[k]
	save()


func apply_audio() -> void:
	Audio.set_volume(float(values["volume"]))


func apply_window(win: Window) -> void:
	if bool(values["fullscreen"]):
		win.mode = Window.MODE_FULLSCREEN
	else:
		win.mode = Window.MODE_WINDOWED
		var parts := String(values["resolution"]).split("x")
		if parts.size() == 2 and parts[0].is_valid_int() and parts[1].is_valid_int():
			win.size = Vector2i(int(parts[0]), int(parts[1]))


func apply_world() -> void:
	if Game.world != null:
		Game.world.render_radius = int(values["render_dist"])
		Game.world.fluid_tick_radius = int(values["sim_dist"]) * 16
		# AC-0152: the tick diamond follows Simulate (chunks); fluid_tick_radius
		# (blocks) stays for the legacy mapping.
		Game.world.band0_r = mini(int(values["sim_dist"]), int(values["render_dist"]))
		# AC-0239: the sim radius is the streaming tier-1 boundary - re-stamp.
		if Game.world.has_method("note_sim_distance"):
			Game.world.note_sim_distance()
		# AC-0252: the band boundary follows the radii (the low-start
		# clamp depends on band0_r / render_radius).
		if Game.world.has_method("apply_low_start"):
			Game.world.apply_low_start()


func apply_render_distance() -> void:
	if Game.world != null:
		var prev := int(Game.world.render_radius)
		Game.world.render_radius = int(values["render_dist"])
		if Game.player != null:
			Game.world.recenter(Game.player.position.x, Game.player.position.z)
		Game.world.note_render_distance(prev)  # AC-0178: Options render_distance trigger
		# AC-0252: the band boundary re-clamps against the new render edge.
		if Game.world.has_method("apply_low_start"):
			Game.world.apply_low_start()


func apply_sim_distance() -> void:
	if Game.world != null:
		Game.world.fluid_tick_radius = int(values["sim_dist"]) * 16
		Game.world.band0_r = mini(int(values["sim_dist"]), int(values["render_dist"]))
		# AC-0239: the sim radius is the streaming tier-1 boundary - re-stamp
		# the tier order (the has_method guard keeps the _StubWorld arm clean).
		if Game.world.has_method("note_sim_distance"):
			Game.world.note_sim_distance()
		# AC-0252: the low-start floor is the sim radius - re-clamp the band.
		if Game.world.has_method("apply_low_start"):
			Game.world.apply_low_start()


# AC-0252: Options "Low LOD start" slider apply — the med/low band boundary
# (taxi chunks). The world recomputes the effective boundary (clamped
# above the sim "high circle") + re-stales the tier-changed low slabs.
func apply_low_start() -> void:
	if Game.world != null:
		if Game.world.has_method("apply_low_start"):
			Game.world.apply_low_start()


# AC-0257 (Developer submenu): the tier-0 radius changed — the world re-stamps
# the queue's tier-0 set (the has_method guard keeps the _StubWorld arm clean).
func apply_tier0_radius() -> void:
	if Game.world != null and Game.world.has_method("note_tier0_radius"):
		Game.world.note_tier0_radius()


# AC-0257 (Developer submenu): the worker-thread caps changed — the world
# updates its in-flight caps live (no pool restart; the caps are software
# limits on the shared engine pool).
func apply_worker_threads() -> void:
	if Game.world != null and Game.world.has_method("note_worker_threads"):
		Game.world.note_worker_threads()
