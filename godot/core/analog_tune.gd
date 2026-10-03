class_name AnalogTune
extends RefCounted
# AC-0089: the analog tuning core (pure logic, no node dependencies) — the
# same convention as core/controls_map.gd: one home for the logic, shared by
# the Options > Controls tab (ui/menu.gd), the live input paths (player.gd)
# and the `analog` arm (harness.gd), so the UI, the game and the instrument
# cannot drift apart.
#
# Bounds (stated, asserted by the arm):
# - SENS 0.25..2.0 — a LINEAR multiplier on the look delta. The floor keeps a
#   full stick deflection at >= 0.25 * PAD_LOOK_SPEED (0.625 rad/s: a 90 deg
#   turn in ~1.4 s) so no legal value makes look unusable; the ceiling is a
#   fast-but-controllable 5 rad/s. 1.0 = the shipped behaviour.
# - DZ 0.0..0.9 — per-axis deadzone with renormalize: |v| <= dz -> 0, above
#   it (|v| - dz) / (1 - dz) so a FULL deflection is ALWAYS exactly full
#   output at any legal dz ((1 - dz)/(1 - dz) = 1). 1.0 is excluded: at
#   dz = 1 the renormalize divides by zero and every deflection (including a
#   full one) would die — the game would be unnavigable, which is a bug, not
#   a player choice. 0.0 is legal and is the identity (no filter): a drifting
#   stick at dz 0 reads as input — the player's reversible choice, and the
#   math stays finite (no division by zero).
#
# Scope decisions (stated):
# - INVERT applies to LOOK only (the right stick). The left stick also drives
#   the native GUI focus navigation (engine ui_focus_* bindings, untouched)
#   and the sprint latch keys off forward sign — inverting movement would
#   break both. Mirrors Minecraft's "Invert Y" being a look setting.
# - SENSITIVITY scales the look delta LINEARLY (a multiplier, not a curve):
#   one number the player can calibrate against the base PAD_LOOK_SPEED; a
#   curve would change low-deflection response in a way a single value
#   cannot predict. Look only — movement speed is the game's, not a knob.
# - The movement path carries the user DEADZONE only (no invert, no sens).

const SENS_MIN := 0.25
const SENS_MAX := 2.0
const DZ_MIN := 0.0
const DZ_MAX := 0.9

# the shipped defaults (declared in Settings.DEFAULTS; this is the one home
# for the values — Settings and the UI reset button both read it).
static func defaults() -> Dictionary:
	return {
		"look_sensitivity": 1.0,
		"deadzone_left": 0.15,
		"deadzone_right": 0.15,
		"invert_y": false,
		"invert_x": false,
	}


# The corrupt-value sanitizer for the invert flags (the Settings _clamp
# path). GDScript's bool() conversion is NUMBERS ONLY — a hand-edited
# string in the cfg would raise "Nonexistent 'bool' constructor" and abort
# the whole load. A stored value is truthy only when it says so: real
# bools pass, 0/1-style numbers convert, "true"/"1" strings convert,
# everything else (garbage) fails safe to false.
static func sanitize_bool(v) -> bool:
	if v is bool:
		return v
	if v is int or v is float:
		return v != 0
	if v is String:
		return v == "true" or v == "1"
	return false


static func clamp_sens(v: float) -> float:
	return clampf(v, SENS_MIN, SENS_MAX)


static func clamp_dz(v: float) -> float:
	return clampf(v, DZ_MIN, DZ_MAX)


# The per-axis deadzone + renormalize + optional invert.
# |v| <= dz -> 0 (the filter); above it the range (dz, 1] is remapped onto
# (0, 1] so full deflection stays full output at every legal dz. Inverting
# flips the sign only — the magnitude is the deadzoned magnitude.
static func apply_axis(v: float, dz: float, invert := false) -> float:
	var d := clampf(dz, DZ_MIN, DZ_MAX)
	var a := absf(v)
	if a <= d:
		return 0.0
	var out := (a - d) / (1.0 - d)
	if v < 0.0:
		out = -out
	if invert:
		out = -out
	return out


# The right-stick LOOK path: per-axis deadzone, invert, then the LINEAR
# sensitivity multiplier. `values` is the Settings.values table (the live
# settings; the player calls this per frame with _pad_look).
static func look_stick(stick: Vector2, values: Dictionary) -> Vector2:
	var out := Vector2(
		apply_axis(stick.x, float(values["deadzone_right"]), bool(values["invert_x"])),
		apply_axis(stick.y, float(values["deadzone_right"]), bool(values["invert_y"])))
	return out * clamp_sens(float(values["look_sensitivity"]))


# The left-stick MOVEMENT path: the engine has already rescaled the stick by
# the binding deadzone (0.5 in project.godot [input]) before it reaches
# Input.get_action_strength, so the user deadzone applies on top of that.
# No invert / no sensitivity here (look-only, see the file header).
static func move_stick(stick: Vector2, dz: float) -> Vector2:
	return Vector2(apply_axis(stick.x, dz), apply_axis(stick.y, dz))
