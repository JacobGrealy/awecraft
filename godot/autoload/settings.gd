extends Node

const PATH := "user://awecraft.cfg"

const RENDER_MIN := 4
const RENDER_MAX := 96
const SIM_MIN := 1

const DEFAULTS := {
	"render_dist": 50,
	# AC-0152: Bedrock Realms default — Simulate 4 (taxicab diamond, 41 chunks).
	"sim_dist": 4,
	"volume": 100,
	"fullscreen": false,
	"resolution": "1280x720",
	"seed": 44,
	"hunger_enabled": true,
}

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
	return values


func clamp_sim_to_render() -> void:
	if int(values["sim_dist"]) > int(values["render_dist"]):
		values["sim_dist"] = int(values["render_dist"])


func _clamp(k: String, v) -> void:
	match k:
		"render_dist":
			values[k] = clampi(int(v), RENDER_MIN, RENDER_MAX)
		"sim_dist":
			values[k] = clampi(int(v), SIM_MIN, RENDER_MAX)
		"volume":
			values[k] = roundi(clampf(float(v), 0.0, 100.0))
		"fullscreen":
			values[k] = bool(v)
		"hunger_enabled":
			values[k] = bool(v)
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


func apply_render_distance() -> void:
	if Game.world != null:
		var prev := int(Game.world.render_radius)
		Game.world.render_radius = int(values["render_dist"])
		if Game.player != null:
			Game.world.recenter(Game.player.position.x, Game.player.position.z)
		Game.world.note_render_distance(prev)  # AC-0178: Options render_distance trigger


func apply_sim_distance() -> void:
	if Game.world != null:
		Game.world.fluid_tick_radius = int(values["sim_dist"]) * 16
		Game.world.band0_r = mini(int(values["sim_dist"]), int(values["render_dist"]))
