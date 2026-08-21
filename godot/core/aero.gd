class_name Aero
extends RefCounted

const SKY_RADIUS := 1000.0

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


static func sky_on() -> bool:
	return OS.get_environment("AWECRAFT_AERO_SKY") != "0"


static func apply_grade(env: Environment) -> void:
	env.glow_enabled = GLOW_ENABLED
	env.glow_strength = GLOW_STRENGTH
	env.glow_bloom = GLOW_BLOOM
	env.glow_hdr_threshold = GLOW_THRESHOLD
	env.tonemap_mode = TONEMAP_MODE
	env.tonemap_exposure = EXPOSURE
	env.adjustment_enabled = true
	env.adjustment_saturation = ADJ_SATURATION
	env.adjustment_contrast = ADJ_CONTRAST


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
