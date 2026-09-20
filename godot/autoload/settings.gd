extends Node

const PATH := "user://awecraft.cfg"

const RENDER_MIN := 4
const RENDER_MAX := 96
# AC-0313: the sim distance FLOOR is 4 (was 1). With the tier-0 set gone,
# the real band (taxi ≤ sim) is the footing guarantee: every column of the
# player's 3x3 has taxi ≤ 2, so sim ≥ 4 (strictly above 2) keeps the player's
# whole 3x3 inside the real band at every storable value — the load-screen
# gate (the 9 spawn chunks) and the (taxi, layer) build order both assume
# the 3x3 is real. A stored sim of 0/1/2/3 re-clamps to 4 on load (the
# _clamp path below is the only write site).
const SIM_MIN := 4
# AC-0225: Options "Chunk meshes per frame" slider range — the per-frame
# streaming handoff burst (the AC-0224 drain cap, world.gd stream_ho_cap).
const CHUNKS_PER_FRAME_MIN := 1
const CHUNKS_PER_FRAME_MAX := 100
# AC-0232 (dither dropped in AC-0241): the fog start-distance slider —
# percent (0-100) of the render edge ((render_dist + 1) * 16 blocks; the same
# base the AC-0226 formula scales from).
const PCT_MIN := 0
const PCT_MAX := 100
# AC-0332: the far-tier mesh floor scale (AC-0331's kernel seam) — the
# chunks-below-sea range. A plain 0..24 scale with NO sentinel: the on/off
# axis is the separate yfloor_enabled boolean, so the scale never encodes
# "disabled". 0 = the waterline (y Data.SEA = 126); each step cuts 16
# blocks deeper (y_floor = Data.SEA - n*16). 24 reaches y -258, below the
# world floor (0) — the full far column.
const YFLOOR_MAX := 24

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
	"fog_enabled": true,
	# AC-0261: the med/low band split (taxi chunks). The visible LOD
	# zones: HIGH = [0, sim_dist), MED (8x8x8) = [sim_dist, low_start),
	# LOW (4x4x4) = [low_start, render_dist); NOTHING renders past the
	# render distance (data-only ahead of it). Default = the midpoint of
	# the [sim, render] band for the default sim 4 / render 50.
	# clamp_low_start_to_render re-defaults out-of-band stored values to
	# the band midpoint.
	"low_start": 27,
	# AC-0263: where the MED LOD begins (taxi chunks) — the HIGH band's
	# outer edge. HIGH = [0, medium_start) now (per-slab builds, tier-0
	# ball = the full column); MED (8x8x8) = [medium_start, low_start);
	# LOW (4x4x4) = [low_start, render_dist]. MUST be > sim_dist (the sim
	# distance no longer controls world generation — it only gates mob /
	# fluid updates); clamp_medium_start enforces the band (sim, render].
	# Default 8 = high detail clearly past the default sim 4 (~3.5x the
	# old high-band chunk count).
	"medium_start": 8,
	# AC-0313: the "tier0_radius" default (Developer submenu) is GONE —
	# the tier-0 set was removed (the real band taxi ≤ sim is the footing
	# guarantee). A stale key in an old cfg is simply never read: load
	# settings only pulls keys in this table (the old worlds are
	# disposable — no migration owed).
	# AC-0280: altitude-based flight speed (Developer submenu).
	"sub_cruising_speed": 2,
	"cruising_altitude": 275,
	"cruising_speed": 6,
	# AC-0281: DOF (Developer submenu).
	"dof_enabled": true,
	"dof_far_distance": 82.62,
	"dof_amount": 0.08,
	# AC-0332: the far-tier mesh floor (AC-0331's kernel — the sub-waterline
	# geometry of the three far draw tiers is removed at the floor). The
	# on/off axis + the plain 0..24 chunks-below-sea scale (YFLOOR_MAX);
	# 0 = the waterline. The -1 "disabled" is an INTERNAL sentinel derived
	# only from the toggle (world.gd note_yfloor) — never storable.
	"yfloor_enabled": true,
	"yfloor_chunks_below_sea": 0,
	# AC-0257: worker-thread in-flight caps. 0 = auto (scale to all
	# available cores, never past — gen/mesh split 40/60); >0 = the
	# explicit cap for that lane.
	"worker_gen_threads": 0,
	"worker_mesh_threads": 0,
}

# AC-0257 (Developer submenu) slider ranges (AC-0313: the tier-0 radius
# row — and TIER0_RADIUS_MAX — is gone with the tier-0 set).
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
	clamp_medium_start()
	clamp_low_start_to_render()
	return values


func clamp_sim_to_render() -> void:
	if int(values["sim_dist"]) > int(values["render_dist"]):
		values["sim_dist"] = int(values["render_dist"])


# AC-0263: medium_start lives in the band (sim, render] — it MUST be
# strictly above the sim distance (high visuals extend past the sim
# distance, which no longer controls world generation) and can't outrun
# the render edge. A stored value outside the band (or a degenerate
# sim >= render world) re-defaults to 8 re-clamped into the band.
func clamp_medium_start() -> void:
	var lo := mini(int(values["sim_dist"]) + 1, int(values["render_dist"]))
	var hi := int(values["render_dist"])
	var ms := int(values["medium_start"])
	if ms < lo or ms > hi:
		values["medium_start"] = clampi(8, lo, hi)


# AC-0261 (AC-0263): low_start lives inside the visible band [medium,
# render] — MED = [medium_start, low_start), LOW = [low_start, render];
# nothing renders past the render distance (the MED floor moved from the
# sim distance to medium_start in AC-0263). A stored value outside the
# band re-defaults to the band MIDPOINT (clamping to the edge would
# silently cancel the LOW band).
func clamp_low_start_to_render() -> void:
	var lo := mini(int(values["medium_start"]), int(values["render_dist"]))
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
		# AC-0263: the high/med band split distance (taxi chunks); the
		# (sim, render] band clamp runs in clamp_medium_start.
		"medium_start":
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
		"fog_enabled":
			values[k] = bool(v)
		# AC-0257 (Developer submenu). (AC-0313: the tier0_radius clamp
		# branch is gone with the setting — a stale cfg key is never read.)
		"sub_cruising_speed":
			values[k] = clampi(int(v), 1, 20)
		"cruising_altitude":
			values[k] = clampi(int(v), 0, 384)
		"cruising_speed":
			values[k] = clampi(int(v), 1, 20)
		"dof_enabled":
			values[k] = bool(v)
		"dof_far_distance":
			values[k] = clampf(float(v), 1.0, 400.0)
		"dof_amount":
			values[k] = clampf(float(v), 0.0, 1.0)
		# AC-0332: the far-tier mesh floor (AC-0331's kernel) — the on/off
		# axis + the plain 0..24 chunks-below-sea scale (no sentinel: the
		# -1 "off" is derived only from the toggle, in world.gd).
		"yfloor_enabled":
			values[k] = bool(v)
		"yfloor_chunks_below_sea":
			values[k] = clampi(int(v), 0, YFLOOR_MAX)
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
	clamp_medium_start()  # AC-0263: the sim/render change moves its band
	clamp_low_start_to_render()
	# AC-0332: the far-tier mesh floor pair — the apply step alongside the
	# clamp chain: the world re-derives the effective floor (note_yfloor)
	# and handles the cache staleness a changed value owes. A no-op while
	# Game.world is absent (menu / the settings arm's standalone context).
	if k == "yfloor_enabled" or k == "yfloor_chunks_below_sea":
		apply_yfloor()
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
		# AC-0263: the sim distance is no longer a world-gen boundary —
		# the medium_start band (sim, render] moved, so re-clamp + re-stamp
		# the high/med edge, then the low-start floor.
		clamp_medium_start()
		apply_medium_start()
		# AC-0252: the band boundary follows the radii (the low-start
		# clamp depends on medium_start / render_radius).
		if Game.world.has_method("apply_low_start"):
			Game.world.apply_low_start()


func apply_render_distance() -> void:
	if Game.world != null:
		var prev := int(Game.world.render_radius)
		Game.world.render_radius = int(values["render_dist"])
		if Game.player != null:
			Game.world.recenter(Game.player.position.x, Game.player.position.z)
		Game.world.note_render_distance(prev)  # AC-0178: Options render_distance trigger
		# AC-0263: the render edge moved — re-clamp the medium_start band
		# and re-stamp the high/med edge, then the low-start floor.
		clamp_medium_start()
		apply_medium_start()
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
		# AC-0263: the sim distance left world generation — it only moves
		# the medium_start band's FLOOR (must stay > sim), so re-clamp +
		# re-stamp the high/med edge when the floor changed.
		clamp_medium_start()
		apply_medium_start()
		# AC-0252: the low-start floor is the medium_start now - re-clamp.
		if Game.world.has_method("apply_low_start"):
			Game.world.apply_low_start()


# AC-0252: Options "Low LOD start" slider apply — the med/low band boundary
# (taxi chunks). The world recomputes the effective boundary (clamped
# above the sim "high circle") + re-stales the tier-changed low slabs.
func apply_low_start() -> void:
	if Game.world != null:
		if Game.world.has_method("apply_low_start"):
			Game.world.apply_low_start()


# AC-0263: the "mid LOD distance" (medium_start) changed — the HIGH band's
# outer edge. The world reads it live (medium_start_r) and re-stamps the
# queue's tier/band stamps (the has_method guard keeps the _StubWorld arm
# clean). Runs after clamp_medium_start, so the value is always in band.
func apply_medium_start() -> void:
	if Game.world != null:
		if Game.world.has_method("note_medium_start"):
			Game.world.note_medium_start()


# AC-0313: apply_tier0_radius (the Developer-submenu tier-0 radius apply)
# is GONE with the tier-0 set (world.note_tier0_radius no longer exists).

# AC-0257 (Developer submenu): the worker-thread caps changed — the world
# updates its in-flight caps live (no pool restart; the caps are software
# limits on the shared engine pool).
func apply_worker_threads() -> void:
	if Game.world != null and Game.world.has_method("note_worker_threads"):
		Game.world.note_worker_threads()


# AC-0281: DOF settings changed — push to the live CameraAttributes if
# a player exists (the Camera3D's attributes resource).
func apply_dof() -> void:
	if Game.player != null:
		var cam = Game.player.get_node_or_null("Camera3D")
		if cam != null and cam.get("attributes") != null:
			var attrs = cam.attributes
			# Duplicate if shared so we don't permanently mutate the .tres on disk
			# for other instances; duplicate is cheap and keeps live tuning isolated.
			if attrs != null and attrs.resource_path != "":
				# First use: duplicate the shared .tres so live edits stay in-memory
				cam.attributes = attrs.duplicate()
				attrs = cam.attributes
			if attrs != null:
				attrs.set("dof_blur_far_enabled", bool(values.get("dof_enabled", true)))
				attrs.set("dof_blur_far_distance", float(values.get("dof_far_distance", 82.62)))
				attrs.set("dof_blur_amount", float(values.get("dof_amount", 0.08)))


# AC-0332: the far-tier mesh floor (AC-0331's kernel seam) — the world
# re-derives the effective floor from the pair (note_yfloor: -1 when the
# toggle is off, else Data.SEA - n*16) and handles the cache staleness a
# change owes (the far_eff clear + the band-A far_mat reopen, so
# materialized columns re-materialize at the new floor through the normal
# drain). Boot/dev knob: a change applies to newly built columns
# immediately; existing ones converge as they demote and re-mesh (the
# live re-floor storm is a follow-up, designed against measured churn).
# The has_method guard keeps the _StubWorld / range arms clean.
func apply_yfloor() -> void:
	if Game.world != null and Game.world.has_method("note_yfloor"):
		Game.world.note_yfloor()
