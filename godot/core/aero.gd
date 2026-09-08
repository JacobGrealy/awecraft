class_name Aero
extends RefCounted

# AC-0235: the sky dome is gone (sky pass now); the cloud layer
# plane hovers at this height (surface tops ~128-145; 400 puts the
# layer ~260 above the ground - distant, MC-like; 160 read as
# clouds hovering over the field, user retest 19:40).
const CLOUD_H := 400.0

const GLOW_ENABLED := true
const GLOW_STRENGTH := 0.35
const GLOW_BLOOM := 0.15
const GLOW_THRESHOLD := 0.9
const TONEMAP_MODE := Environment.TONE_MAPPER_ACES
const EXPOSURE := 0.85
const SUN_BOOST := 1.0
const SUN_TINT := Color8(255, 246, 226)
const AMBIENT_BOOST := 1.0
const AMBIENT_TINT := Color8(232, 233, 226)
const ADJ_SATURATION := 1.25
const ADJ_CONTRAST := 1.1

const WASH_AMOUNT := 0.03
const WASH_COLOR := Color8(168, 238, 255)
const WASH_TOP_GLOW := 0.5

const DAY_ZENITH := Color8(46, 134, 216)
const DAY_MID := Color8(95, 198, 234)
const DAY_HORIZON := Color8(223, 246, 251)
const NIGHT_ZENITH := Color8(11, 30, 58)
const NIGHT_MID := Color8(14, 46, 78)
const NIGHT_HORIZON := Color8(14, 63, 74)
const DUSK_ZENITH := Color8(255, 128, 92)
const DUSK_MID := Color8(255, 179, 110)
const DUSK_HORIZON := Color8(122, 214, 235)
const SUN_CORE := Color8(255, 255, 255)
const SUN_HALO := Color8(255, 246, 222)
const MOON_CORE := Color8(230, 242, 255)
const MOON_HALO := Color8(148, 196, 255)
const CLOUD := Color8(255, 255, 255)
const HAZE := Color8(186, 233, 250)

const CLOUD_AMOUNT_DAY := 0.75
const CLOUD_AMOUNT_NIGHT := 0.3
const HAZE_AMOUNT_DAY := 0.4
const HAZE_AMOUNT_NIGHT := 0.2

const GLOW_AMOUNT_DAY := 1.0
const GLOW_AMOUNT_NIGHT := 0.18


static func enabled() -> bool:
	return OS.get_environment("AWECRAFT_AERO") != "0"


static func grade_on() -> bool:
	return OS.get_environment("AWECRAFT_AERO_GLOW") != "0"


static func wash_on() -> bool:
	return OS.get_environment("AWECRAFT_AERO_WASH") != "0"


# AC-0235: the cloud layer (the dome's AWECRAFT_AERO_SKY flag is
# gone with the sphere).
static func clouds_on() -> bool:
	return OS.get_environment("AWECRAFT_CLOUDS") != "0"


# AC-0241 follow-up: env A/B overrides for the grade (Forward+ executes
# the same parameters differently than gl_compatibility - glow especially);
# each AWECRAFT_GRADE_* var replaces its constant for one launch.
static func _envf(key: String, d: float) -> float:
	var v := OS.get_environment(key)
	return d if v == "" else v.to_float()

# AC-0242: the gl_compatibility LDR path displays unshaded material output
# WITHOUT a final sRGB encode (measured: the compat frame is the sRGB-decoded
# image of the Forward+ frame; atlas grass bytes 120-134 show as ~50 under
# compat, ~130 under Forward+). Forward+ therefore renders the same material
# one sRGB curve brighter than the old build - the "washed out" report.
# srgb_pre() = 1.0 makes Forward+ shaders pre-decode their final unshaded
# color (pow 2.2) so the pipeline encode round-trips to the old display;
# 0.0 on compatibility keeps it the identity.
static func srgb_pre() -> float:
	return 1.0 if RenderingServer.get_current_rendering_method() != "gl_compatibility" else 0.0


static func glow_strength() -> float:
	return _envf("AWECRAFT_GRADE_GLOW", GLOW_STRENGTH)


static func glow_bloom() -> float:
	return _envf("AWECRAFT_GRADE_BLOOM", GLOW_BLOOM)


static func glow_threshold() -> float:
	return _envf("AWECRAFT_GRADE_GLOWTHRESH", GLOW_THRESHOLD)


static func tone_exposure() -> float:
	return _envf("AWECRAFT_GRADE_EXPOSURE", EXPOSURE)


static func adj_saturation() -> float:
	return _envf("AWECRAFT_GRADE_SAT", ADJ_SATURATION)


static func adj_contrast() -> float:
	return _envf("AWECRAFT_GRADE_CONTRAST", ADJ_CONTRAST)


static func apply_grade(env: Environment) -> void:
	env.glow_enabled = GLOW_ENABLED
	env.glow_strength = glow_strength()
	env.glow_bloom = glow_bloom()
	env.glow_hdr_threshold = glow_threshold()
	env.tonemap_mode = TONEMAP_MODE
	env.tonemap_exposure = tone_exposure()
	env.adjustment_enabled = true
	env.adjustment_saturation = adj_saturation()
	env.adjustment_contrast = adj_contrast()


static func sky_uniforms(t: float) -> Dictionary:
	var day := DayNight.day(t)
	var elev := DayNight.elevation(t)
	var dusk := clampf(1.0 - absf(elev) / 0.25, 0.0, 1.0)
	var duskw := dusk * 0.5
	var zenith := NIGHT_ZENITH.lerp(DAY_ZENITH, day).lerp(DUSK_ZENITH, duskw * 0.7)
	var mid := NIGHT_MID.lerp(DAY_MID, day).lerp(DUSK_MID, duskw * 0.7)
	var horizon := NIGHT_HORIZON.lerp(DAY_HORIZON, day).lerp(DUSK_HORIZON, duskw * 0.8)
	var light_dir := DayNight.sun_direction(t)
	var body := -light_dir
	var core := SUN_CORE
	var halo := SUN_HALO
	var amount := GLOW_AMOUNT_NIGHT + (GLOW_AMOUNT_DAY - GLOW_AMOUNT_NIGHT) * day
	if body.y < -0.10:
		body = -body
		core = MOON_CORE
		halo = MOON_HALO
		amount = 0.3
	else:
		halo = halo.lerp(DUSK_ZENITH, duskw * 0.6)
	return {
		"zenith_color": zenith,
		"mid_color": mid,
		"horizon_color": horizon,
		"sun_dir": body.normalized(),
		"sun_core": core,
		"sun_halo": halo,
		"sun_amount": amount,
		"cloud_color": CLOUD,
		"cloud_amount": CLOUD_AMOUNT_NIGHT + (CLOUD_AMOUNT_DAY - CLOUD_AMOUNT_NIGHT) * day,
		"haze_color": HAZE,
		"haze_amount": HAZE_AMOUNT_NIGHT + (HAZE_AMOUNT_DAY - HAZE_AMOUNT_NIGHT) * day,
	}
