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
	# AC-0389: the ambient sound bed (AC-0039's looping wind) — OFF by
	# default: the user reported the always-on loop as a defect; the
	# toggle keeps the feature for those who want ambience. apply_audio()
	# pushes it to Audio.set_ambient (the SFX pool is never affected).
	"ambient_enabled": false,
	# AC-0205: the smooth-ground-ramps feature (one-block steps between
	# dirt/grass/sand columns render + collide as sloped quads). OFF by
	# default — the same "a feature that changes how the game looks ships
	# with a switch, defaulting to the conservative behaviour" rule as
	# ambient_enabled; the user evaluates the ramps by turning them on.
	# The switch short-circuits BEFORE geometry is emitted (the C++ ro
	# scan's ramp branch is gated on the ctx "ramps" flag), so OFF is
	# byte-identical to the pre-feature mesh — and the collider follows
	# the same flag (it is derived from the mesh), so the two can never
	# disagree. The AWECRAFT_RAMPS harness env overrides the stored value
	# at boot (world.gd) so the arms test both states without a save file.
	"smooth_ramps": false,
	# AC-0398: the modern per-vertex lighting toggle. UNLIKE smooth_ramps
	# this DEFAULTS ON — the user asked for the interpolated look in their
	# own words, and the project rule (AC-0205) says default to the
	# conservative behaviour only when the user has NOT asked for the new
	# one. Same switch discipline as every other look change: persisted on
	# the Options surface, clamped to a bool, env-overridable
	# (AWECRAFT_MODERN=0|1 at boot, world.gd), and the C++ ctx flag
	# short-circuits BEFORE any shading is emitted, so OFF is byte-identical
	# to the pre-AC-0398 mesh. POLARITY NOTE: the game default is ON but
	# the C++ key-absent default is OFF — the arms build their ctx dicts by
	# hand (no "modern" key) and the ramp arm's stored _RAMP_REF fingerprint
	# is pre-AC-0398, so a hand-built ctx must stay on the pre-feature path
	# (harness.gd is pristine). The live world always writes the key at boot
	# (note_modern), so the game path is explicit in both states.
	"modern_light": true,
	# AC-0427: the seam-lighting continuity switch. DEFAULTS ON — the
	# user asked for it ("the shading is weird along the line"; "the
	# joins between chunks should be invisible"). The modern per-corner
	# lighting at a chunk-edge corner used an inward neighbour only the
	# own chunk knows, so the two corners meeting at a seam read
	# different occluder sets — a measured 0.08-0.92 luminance step on
	# every seam (AC-0420). ON: a boundary corner evaluates the inward
	# side as the seam column itself (flat continuation), so the seam
	# pair uses only the data both chunks share and the seam's (sl,
	# oshade) are identical — the lighting is continuous across the
	# join. OFF = the pre-AC-0427 evaluation exactly (colour-only; the
	# C++ key-absent default is off, so the arms' hand-built ctx dicts
	# and their stored fingerprints stay green). Colour-only: a toggle
	# re-derives the worker ctx ("seamc") and re-meshes every resident
	# column through the tex_refresh drain — no geom_epoch bump.
	# Env-overridable (AWECRAFT_SEAM_LIGHT=0|1 at boot, world.gd).
	"seam_light": true,
	# AC-0401: the cloud deck character switch. DEFAULTS ON — the user
	# asked for the new look ("less of them but the individual clouds
	# should be bigger and they should be volumetric"), the modern_light
	# precedent: default to conservative only when the user has NOT
	# asked. The switch rides world.gd _ac0401_push (u_deck on the three
	# cloud-layer materials): 0.0 runs the exact pre-AC-0401 field and
	# windows inside cloud_layer.gdshader (short-circuit before the work,
	# byte-identical pattern), 1.0 is the re-characterised deck (1/3
	# field frequency, tighter coverage window, clearing band troughs,
	# volumetric shading). Env-overridable (AWECRAFT_CLOUDDECK=0|1 at
	# boot, world.gd).
	"cloud_deck": true,
	# AC-0401: the limb-glow altitude gate. DEFAULTS ON — the user asked
	# for it ("we do not want low lod to have the limb effect, only fog"):
	# the atmospheric rim is an ORBIT instrument, so with the gate ON it
	# rides u_space (the flight-band blend): no rim near the ground, full
	# rim from orbit. OFF (u_limb_gate 0.0) is the pre-AC-0401 glow at
	# every altitude. Rides the same _ac0401_push (u_limb_gate on the sky
	# material); env-overridable (AWECRAFT_LIMB=0|1 at boot, world.gd).
	"limb_space": true,
	# AC-0402: the sky's altitude-aware space blend. DEFAULTS ON - the
	# user story asks for it ("the sky should know where the player is:
	# bright air near the ground, thinning to space as you climb"). The
	# sky's background blend rides u_space_sky (world.gd _ac0401_push
	# pushes it per frame, stretched window BAND_WALK_MAX ..
	# BAND_FLY_MIN*1.6 read off the live player); the limb gate, stars
	# and sun glow stay on the physics band's S. OFF (u_sky_alt 0.0)
	# makes the sky's ws exactly the pre-AC-0402 expression - a
	# bit-identical sky. Env-overridable (AWECRAFT_SKYALT=0|1 at boot,
	# world.gd).
	"sky_altitude": true,
	# AC-0422: the continuous-horizon sky switch (u_horizon in
	# aero_sky_gradient.gdshader sky_on). DEFAULTS ON — the user asked
	# for it in their own words, twice ("the skybox shouldn't have a
	# horizon line"; reported again 2026-10-11 with a screenshot: a
	# flat expanse terminated by a hard straight edge at altitude).
	# The pre-fix look is the shader default (u_horizon 0.0 - the old
	# path bit-for-bit, the AC-0401 short-circuit convention) and the
	# A/B rides the harness env override. With the switch ON: the
	# below-horizon branch is the single-source air colour u_air at
	# every altitude (the AC-0384 r8 fog seam restored for w > 0 - the
	# world's fog and the satellite body's rim are exactly u_air, so
	# the fog wall and the body rim stop being hard edges), the space
	# thinning spares the horizon (the weight is * u: 0 at the local
	# horizon, w at the zenith - the sky is still space at A when
	# looking up), and the branch switch is a smooth blend instead of
	# the step at the local horizon. Env-overridable
	# (AWECRAFT_SKYHORIZON=0|1 at boot, world.gd).
	"sky_horizon": true,
	# AC-0429: the skybox-no-bottom-edge switch (u_no_floor in
	# aero_sky_gradient.gdshader sky_on). DEFAULTS ON — the user's
	# correction, in their own words, to the AC-0428 fix: "the sky box
	# can't have a bottom edge, we are in space! We can't fake the
	# horizon, the planet and satellite is the horizon." The AC-0428
	# blend removed the STEP at the local horizon but kept the box
	# (the anchor, the band, the u_air floor below it) — this removes
	# the lower boundary as a CONCEPT: below the local horizon the sky
	# is space (the same black, the same stars), the gradient's horizon
	# anchor fades to space with the floor's space weight ws
	# (smoothstep(0, 0.3, w) — 1 from ~630 m), the horizon haze band
	# dies with ws, and the planet's limb is the only boundary left.
	# The pre-ticket look (the AC-0428 floor) is the shader default
	# (u_no_floor 0.0 — the old path bit-for-bit, the AC-0401
	# short-circuit convention) and the A/B rides the harness env
	# override (AWECRAFT_NOSKYFLOOR=0|1 at boot, world.gd).
	"no_sky_floor": true,
	# AC-0405: the raymarched-volumetric-clouds switch. DEFAULTS ON —
	# the user ordered the rework in their own words ("rethink clouds...
	# forget how we currently do it"), the modern_light/cloud_deck
	# precedent: default conservative only when the user has NOT asked.
	# Rides world.gd _ac0401_push (u_vol on the three cloud-layer
	# materials + the annulus radii u_vol_r/rmin/rmax + the two inner
	# shells' visibility): 0.0 is the exact AC-0401 three-shell path
	# (short-circuit before the work, provably the old look), 1.0 is the
	# raymarched density volume in the annulus [R+275, R+400] about the
	# centre (verified geometry, the outer shell carries the march).
	# Env-overridable (AWECRAFT_CLOUDVOL=0|1 at boot, world.gd).
	"cloud_volume": true,
	# AC-0428: the planetary WEATHER GATE. AC-0435: DEFAULTS ON — the user
	# asked for it in their own words: "we need some kind of noise or
	# something around the planet that determines where groups of clouds
	# are, it should not be uniformly cloudy across the entire planet."
	# AC-0428 shipped the measured fix behind the switch defaulting OFF
	# (conservative), so the shipped look was the uniform deck the user
	# asked to remove — the OFF look IS the reported absence (the same
	# shape as AC-0426's ambient_sky, re-ruled by AC-0432; the AC-0435
	# sweep re-ruled this one). ON (u_gate 1.0) multiplies the cloud
	# cover by a low-frequency planetary field (cloud_layer.gdshader
	# vgate - a handful of broad cloud groups with clear gaps between
	# them); OFF (AWECRAFT_CLOUDGATE=0, or the saved setting) restores
	# the pre-AC-0428 uniform deck bit-for-bit (vgate returns 1.0 at
	# u_gate < 0.5). Rides world.gd _ac0401_push (u_gate on the three
	# cloud-layer materials, change-gated). Env-overridable
	# (AWECRAFT_CLOUDGATE=0|1 at boot, world.gd).
	"cloud_gate": true,
	# AC-0414: the bake-before-load switch. DEFAULTS ON — the user asked
	# ("after a recent build the level of detail was not showing at all,
	# and when they looked into it the world 'was still baking'": the
	# satellite's baked terrain was not ready when the player arrived).
	# ON: a non-canonical-seed world bakes its 12-face planet texture
	# BEFORE the player is handed the world — the bake runs multithreaded
	# (14 payload shards + 12 per-face tasks, HIGH priority), the
	# loading window holds the release (the sim taxi diamond) on the
	# body's phase with a LOUD 42 s bounded budget (main.gd's 3000-frame
	# release cap is 50 s wall), and the sky's limb term is gated on the
	# body's LOADED phase (no fake planet while it is not). OFF: the
	# pre-AC-0414 behaviour literally — the single low-priority bake
	# task, no hold, the ungated limb (the world is released first, the
	# planet may appear minutes later). Env-overridable
	# (AWECRAFT_SATPRELOAD=0|1 at boot, world.gd — the AWECRAFT_RAMPS
	# pattern).
	"sat_preload": true,
	# AC-0394: the held-item occlusion switch (the 2026-10-03 report's
	# residual H2: every viewmodel material sets no_depth_test, so the
	# hand draws OVER terrain and reads as floating at the correct
	# scale). AC-0435: DEFAULTS ON — the user REPORTED the drawn-over-
	# terrain behaviour as the defect (the 2026-10-03 screenshot: the
	# held item as a flat tan quad over the scene, read as "a sizing
	# issue"; the AC-0421 follow-up re-adjudicated it — "the screenshot
	# is the authority: the defect is that it draws at all" — and hid
	# the orbit case; the on-surface case this switch owns was left
	# behind the switch defaulting OFF, so the player still sees the
	# reported defect: the hand floating over the terrain). ON
	# re-enables the depth TEST on every viewmodel material (player.gd
	# — fist / box / cross / sprite / the tool child materials; the
	# depth WRITE stays DEPTH_DRAW_DISABLED in both states, the hand
	# still never blocks the depth of anything behind it). OFF
	# (AWECRAFT_VMOCC=0, or the saved setting) restores the
	# always-on-top behaviour for A/B. No apply step: player.gd reads
	# the live value every frame (the cloud_deck/limb_space pattern).
	# Env-overridable (AWECRAFT_VMOCC=0|1 at boot, player.gd — the
	# AWECRAFT_RAMPS pattern, written to Settings.values WITHOUT save).
	"viewmodel_occlude": true,
	# AC-0421: the height-based RELIEF on the satellite body. DEFAULTS ON —
	# the user asked for it in their own words ("alter the color of the
	# sample based on the height to make it more like baked lighting, like
	# what minecraft does with its maps"), so the modern_light/cloud_deck
	# default rule applies (default to conservative only when the user has
	# NOT asked). The effect itself is conservative: a subtle amplitude
	# (±20 % centred on the mid height) that gives the disc a baked-lit
	# read without a lighting model. The switch rides u_relief on the body's
	# 12 face materials (satellite_body.gd pushes it live from this value):
	# 0.0 short-circuits before the modulation — the exact pre-AC-0421 flat
	# sample, byte-identical. Env-overridable (AWECRAFT_RELIEF=0|1 at boot,
	# satellite_body.gd — the AWECRAFT_RAMPS pattern).
	"relief_shading": true,
	# AC-0426: the zero-light sky-ambient switch (the black-silhouette
	# tree fix). AC-0432: DEFAULTS ON — AC-0426 shipped the measured fix
	# behind the switch (conservative), and the user's ticket is that the
	# OFF look IS the defect: the faces whose BOTH direct light terms
	# reach zero (the trunk under its own crown, enclosed caves/hollows —
	# the user's persistent pure-black blob along the chunk seam) render
	# (0,0,0) on screen. AWECRAFT_AMBSKY=0 restores the OFF look per
	# process; the saved setting still lets a user flip it either way.
	# ON adds the ambient term to those faces only, tracking the sky's
	# actual day factor at that hour (u_day): 0.0 at night (the night
	# look is bit-identical even when ON — a tree at midnight stays
	# black), the measured AMB_SKY_L (world.gd) at noon. Faces with real
	# direct light are untouched at any hour. OFF is the AC-0128 formula
	# bit-identical (the shader term is 0.0 * x, x + 0.0). No apply step:
	# world.gd _ac0401_push reads the live value and pushes u_amb to the
	# four chunk_lit_* ShaderMaterials on change (the cloud_deck/limb_space
	# pattern). Env-overridable (AWECRAFT_AMBSKY=0|1 at boot, world.gd —
	# the AWECRAFT_RAMPS pattern, written WITHOUT save).
	"ambient_sky": true,
	# AC-0395: the noclip toggle (the user's own request — disable the
	# player's collision so they can fly through blocks and inspect
	# geometry). DEFAULTS OFF: the shipped state is exactly today's
	# behaviour (the same collision, the same movement), and a debug tool
	# must not be left on by accident (the indicator label + the Options
	# row make the ON state obvious — the ticket's "if it persists,
	# default OFF and make the toggle obvious"). Same switch discipline as
	# every other player-facing bool: sanitize_bool-clamped, persisted on
	# the Options surface, env-overridable (AWECRAFT_NOCLIP=0|1 preloaded
	# WITHOUT save in player.gd _ready — the AWECRAFT_VMOCC pattern; the
	# viewmodel is the player's, the noclip is the player's). No apply
	# step: player.gd _noclip_sync reads the live value every frame and
	# applies on change (the viewmodel_occlude/cloud_deck pattern) —
	# col_shape.disabled + the AC-0145 flight state (free flight: no
	# gravity, the existing flight controls) + the void-kill gate.
	"noclip": false,
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
	# AC-0145 P3: the "flight_speed" Developer slider is GONE — the live
	# flight never read it (AC-0280 replaced it with sub_cruising_speed /
	# cruising_speed; AC-0145 piece 2 re-keyed those to radial altitude).
	# A stale key in an old cfg is simply never read: load_settings only
	# pulls keys in this table (the old worlds are disposable — no
	# migration owed, the AC-0313 tier0_radius precedent).
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
	# AC-0088: the controls remap layer — a flat list of
	# "action:cls:idx" tokens (ControlsMap owns the grammar). EMPTY by
	# default = no customisations = the project.godot [input] map as
	# shipped. A corrupt or partial value can only LOSE customisations
	# (sanitize_array drops every unvalidated entry) - it can never
	# empty an action: the merge keeps the full default set for any
	# action with no saved tokens (core/controls_map.gd owns the rule).
	"controls": [],
	# AC-0089: the analog tuning layer (Options > Controls "Analog tuning"
	# group; core/analog_tune.gd owns the bounds and the math). Defaults
	# from AnalogTune.defaults(): sensitivity 1.0 = the shipped look speed;
	# 0.15 deadzones keep the shipped arms green (the gamepad arm drives
	# 0.8 / 1.0 deflections) and reject typical stick drift by default;
	# invert off = the shipped behaviour. A corrupt stored value clamps
	# into the legal band (always usable — analog_tune.gd header).
	"look_sensitivity": 1.0,
	"deadzone_left": 0.15,
	"deadzone_right": 0.15,
	"invert_y": false,
	"invert_x": false,
}

# AC-0257 (Developer submenu) slider ranges (AC-0313: the tier-0 radius
# row — and TIER0_RADIUS_MAX — is gone with the tier-0 set).
const WORKER_THREADS_MAX := 16

var values: Dictionary = {}
# AC-0088: the remap core (core/controls_map.gd) - the captured
# project.godot defaults + the merge / apply / conflict API shared by
# the Controls tab (ui/menu.gd) and the `controls` arm (harness.gd).
var controls_map: ControlsMap


func _ready() -> void:
	# AC-0088: the remap core must exist before load_settings (the
	# "controls" clamp sanitizes against the captured defaults), and
	# the capture must precede the apply - it snapshots the
	# project.godot [input] map BEFORE the custom layer touches it. A
	# pristine tree (no cfg) stores [] and the apply is a no-op, so
	# every arm sees the shipped defaults.
	controls_map = ControlsMap.new()
	controls_map.capture_defaults()
	load_settings()
	apply_controls()


func load_settings() -> Dictionary:
	values = {}
	for k in DEFAULTS:
		values[k] = DEFAULTS[k]
	values["controls"] = []  # AC-0088: copy, never share the const array
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
		# AC-0389: the ambient bed toggle (plain bool, no range).
		"ambient_enabled":
			values[k] = bool(v)
		# AC-0205: the smooth-ground-ramps toggle — sanitize_bool (not
		# bool()): a hand-edited string in the cfg must fail to false,
		# never raise and abort the whole load (the invert_y precedent).
		"smooth_ramps":
			values[k] = AnalogTune.sanitize_bool(v)
		# AC-0398: the modern-lighting toggle — sanitize_bool for the same
		# reason as smooth_ramps (a hand-edited string fails to false,
		# never raises and aborts the load).
		"modern_light":
			values[k] = AnalogTune.sanitize_bool(v)
		# AC-0427: the seam-lighting continuity toggle — sanitize_bool,
		# not bool(): a hand-edited string in the cfg must fail to false,
		# never raise and abort the whole load.
		"seam_light":
			values[k] = AnalogTune.sanitize_bool(v)
		# AC-0401: the deck character + the limb-glow gate (both look
		# changes, both default ON - the user asked; see DEFAULTS).
		# sanitize_bool, not bool(): a hand-edited string in the cfg must
		# fail to false, not raise and abort the whole load.
		"cloud_deck":
			values[k] = AnalogTune.sanitize_bool(v)
		"limb_space":
			values[k] = AnalogTune.sanitize_bool(v)
		"sky_altitude":  # AC-0402: bool (the sky's altitude-aware space blend).
			values[k] = AnalogTune.sanitize_bool(v)
		"cloud_volume":  # AC-0405: bool (the raymarched cloud volume).
			values[k] = AnalogTune.sanitize_bool(v)
		"cloud_gate":  # AC-0428: bool (the planetary weather gate).
			# sanitize_bool, not bool(): a hand-edited string in the cfg
			# must fail to the default (false), never throw.
			values[k] = AnalogTune.sanitize_bool(v)
		"no_sky_floor":  # AC-0429: bool (the skybox-no-bottom-edge switch).
			# sanitize_bool, not bool(): a hand-edited string in the cfg
			# must fail to false, never throw (the cloud_gate precedent).
			values[k] = AnalogTune.sanitize_bool(v)
		"sat_preload":  # AC-0414: bool (the bake-before-load switch).
			values[k] = AnalogTune.sanitize_bool(v)
		"viewmodel_occlude":  # AC-0394: bool (the held-item occlusion switch).
			values[k] = AnalogTune.sanitize_bool(v)
		"relief_shading":  # AC-0421: bool (the satellite body's height relief).
			values[k] = AnalogTune.sanitize_bool(v)
		"ambient_sky":  # AC-0426/AC-0432: bool (the zero-light sky-ambient
			# switch; AC-0432 defaults it ON).
			# sanitize_bool, not bool(): a hand-edited string in the cfg
			# must fail to the default (true), never throw.
			values[k] = AnalogTune.sanitize_bool(v)
		"noclip":  # AC-0395: bool (the player-collision switch). sanitize_bool
			# as viewmodel_occlude: a hand-edited string in the cfg fails to
			# false (the OFF state), never raises and aborts the load.
			values[k] = AnalogTune.sanitize_bool(v)
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
		# (AC-0145 P3: the flight_speed clamp branch is gone with the
		# setting — a stale cfg key is never read.)
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
		# AC-0088: the controls remap layer. sanitize_array is the whole
		# clamp: it drops every entry that fails validation (grammar,
		# unknown action, a class the action does not use) and resolves
		# duplicates deterministically (last per (action, class) wins).
		# A corrupt stored value lands here as [] or a reduced list -
		# never an emptied action (the merge rule, controls_map.gd).
		"controls":
			values[k] = controls_map.sanitize_array(v)
		# AC-0089: the analog tuning layer — plain bounded floats/bools
		# (AnalogTune owns the band constants; a corrupt stored value
		# clamps INTO the band, so no stored value is ever out of the
		# usable range — the bounds keep the game navigable, see
		# analog_tune.gd). No apply step: the player reads values live at
		# its two input paths (the look _process + the movement read).
		"look_sensitivity":
			values[k] = AnalogTune.clamp_sens(float(v))
		"deadzone_left":
			values[k] = AnalogTune.clamp_dz(float(v))
		"deadzone_right":
			values[k] = AnalogTune.clamp_dz(float(v))
		# (AnalogTune.sanitize_bool, not bool(): GDScript's bool() is
		# numbers only — a hand-edited string in the cfg would raise and
		# abort the whole load; the sanitizer fails garbage to false.)
		"invert_y":
			values[k] = AnalogTune.sanitize_bool(v)
		"invert_x":
			values[k] = AnalogTune.sanitize_bool(v)
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
	# AC-0205: the ramp toggle — the world re-derives the worker ctx flag
	# and re-meshes every resident column (note_ramps, the same apply-step
	# seam as yfloor). A no-op while Game.world is absent (menu / the
	# settings arm's standalone context).
	if k == "smooth_ramps":
		apply_ramps()
	# AC-0398: the modern-lighting toggle — the world re-derives the worker
	# ctx flag ("modern") and re-meshes every resident column (note_modern,
	# the same apply-step seam; colour-only, so no geom_epoch bump). A
	# no-op while Game.world is absent (menu / the settings arm's
	# standalone context).
	if k == "modern_light":
		apply_modern()
	# AC-0427: the seam-lighting continuity toggle — the world re-derives
	# the worker ctx flag ("seamc") and re-meshes every resident column
	# (note_seam_light, the same apply-step seam as modern_light;
	# colour-only, so no geom_epoch bump). A no-op while Game.world is
	# absent (menu / the settings arm's standalone context).
	if k == "seam_light":
		apply_seam_light()
	# AC-0088: the remap layer applies to the live InputMap in the same
	# apply step (the clamp chain above already sanitized the value).
	if k == "controls":
		apply_controls()
	save()


func save() -> void:
	var cf := ConfigFile.new()
	for k in values:
		cf.set_value("settings", k, values[k])
	cf.save(PATH)


func reset_defaults() -> void:
	for k in DEFAULTS:
		values[k] = DEFAULTS[k]
	values["controls"] = []  # AC-0088: copy, never share the const array
	save()


func apply_audio() -> void:
	Audio.set_volume(float(values["volume"]))
	# AC-0389: the ambient bed toggle rides the same apply step (main
	# _ready at startup + every Options audio change).
	Audio.set_ambient(bool(values["ambient_enabled"]))


# AC-0088: push the sanitized "controls" layer onto the live InputMap
# (merge over the captured project.godot defaults). Guarded on the
# capture: before it there is no default set to merge over, and
# applying an empty merge would ERASE the actions it cannot see.
func apply_controls() -> void:
	if controls_map != null and controls_map.captured:
		controls_map.apply_map(controls_map.merge(values["controls"]))


# AC-0088: the rebind operation - the ONE code path the Controls tab
# and the `controls` arm share. {ok, conflicts, unchanged?, msg}:
# a conflict with ANOTHER MANAGED action blocks (both fire in the
# game's unhandled/poll stages - the real shadowing the ticket exists
# to prevent); a conflict with a built-in ui_* action is reported but
# allowed (built-ins fire in the GUI stage only - the default map
# already co-mingles Space on jump and on ui_accept). Replace-within-
# class semantics: the captured input replaces the action's current
# binding of its class (or adds the class when the action has none).
func rebind_action(action: String, tok: String) -> Dictionary:
	var map := controls_map
	if not ControlsMap.is_managed(action):
		return {"ok": false, "conflicts": [], "msg": "unknown action: %s" % action}
	var cls := ControlsMap.token_class(tok)
	if cls == "" or not ControlsMap.valid_token(tok):
		return {"ok": false, "conflicts": [], "msg": "invalid binding: %s" % tok}
	if not map.default_classes(action).has(cls):
		return {"ok": false, "conflicts": [], "msg": "%s does not use %s inputs" % [action, cls]}
	if map.current_binding(action, cls) == tok:
		return {"ok": true, "conflicts": [], "unchanged": true}
	var confs := map.conflicts_for(tok, action)
	var managed_conf := confs.filter(func(c): return not bool(c.get("builtin", false)))
	if not managed_conf.is_empty():
		var names := ""
		for c in managed_conf:
			names += str(c["action"]) + " "
		return {"ok": false, "conflicts": confs, "msg": "conflict: already used by %s" % names.strip_edges()}
	var list: Array = []
	for s in values["controls"]:
		var a := ControlsMap.entry_action(s)
		var t := ControlsMap.entry_token(s)
		if a == action and ControlsMap.token_class(t) == cls:
			continue  # the old binding of this class is replaced
		list.append(s)
	list.append("%s:%s" % [action, tok])
	set_value("controls", list)  # clamp chain + save + apply in one step
	return {"ok": true, "conflicts": confs}


# AC-0088: reset ONE action to its project.godot defaults (its tokens
# leave the custom layer; every other action's customisations stand).
func reset_action(action: String) -> void:
	var list: Array = []
	for s in values["controls"]:
		if ControlsMap.entry_action(s) != action:
			list.append(s)
	set_value("controls", list)


# AC-0088: reset EVERYTHING to the shipped defaults ([] = no
# customisations - the full default map comes back, byte-identical).
func reset_all_controls() -> void:
	set_value("controls", [])


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
			# AC-0308: recenter takes FLAT coords — the player position is
			# global on the placed world; convert (mm-identical at the pole).
			var fp: Vector3 = Game.world.flat_of_world_pos(Game.player.position)
			Game.world.recenter(fp.x, fp.z)
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


# AC-0205: the smooth-ground-ramps toggle — the world re-derives the
# worker ctx flag ("ramps") and re-meshes every resident column through
# the tex-refresh drain (the ramp change is a geometry change, not a
# table or light change — the settled star payload is reused). The
# has_method guard keeps the _StubWorld / range arms clean (the AC-0332
# note_yfloor precedent).
func apply_ramps() -> void:
	if Game.world != null and Game.world.has_method("note_ramps"):
		Game.world.note_ramps()


# AC-0398: the modern-lighting toggle — the world re-derives the worker
# ctx flag ("modern") and re-meshes every resident column through the
# tex-refresh drain. The change is COLOUR-ONLY (per-vertex light values,
# no geometry — the collider is untouched and geom_epoch is NOT bumped,
# unlike note_ramps). The has_method guard keeps the _StubWorld / range
# arms clean (the AC-0332 note_yfloor / AC-0205 note_ramps precedent).
func apply_modern() -> void:
	if Game.world != null and Game.world.has_method("note_modern"):
		Game.world.note_modern()

# AC-0427: the seam-lighting continuity toggle — the same apply-step seam
# as apply_modern (world re-derives the worker ctx flag "seamc", colour-
# only, no geom_epoch bump; the has_method guard keeps the _StubWorld /
# range arms clean).
func apply_seam_light() -> void:
	if Game.world != null and Game.world.has_method("note_seam_light"):
		Game.world.note_seam_light()
