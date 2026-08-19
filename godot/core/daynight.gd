class_name DayNight
extends RefCounted

const DAY_LEN := 600.0


static func fog_near(render_radius: int) -> float:
	return (float(render_radius) + 1.0) * 4.0


static func fog_far(render_radius: int) -> float:
	return (float(render_radius) + 1.0) * 16.0 * 0.95


static func day_rgb() -> Color:
	return Color8(135, 206, 235, 255).srgb_to_linear()


static func night_rgb() -> Color:
	return Color8(10, 14, 31, 255).srgb_to_linear()


static func dusk_rgb() -> Color:
	return Color8(240, 128, 64, 255).srgb_to_linear()


static func elevation(t: float) -> float:
	return sin((t - 0.25) * TAU)


static func day(t: float) -> float:
	return clampf((elevation(t) + 0.12) / 0.35, 0.0, 1.0)


static func is_night(t: float) -> bool:
	return elevation(t) < -0.08


static func sun_energy(t: float) -> float:
	return 0.1 + day(t) * 0.95


static func ambient_energy(t: float) -> float:
	return 0.25 + day(t) * 0.4


static func sky_color(t: float) -> Color:
	var c := night_rgb().lerp(day_rgb(), day(t))
	var dusk := clampf(1.0 - abs(elevation(t)) / 0.25, 0.0, 1.0)
	return c.lerp(dusk_rgb(), dusk * 0.45)


static func sky_display(t: float) -> Color:
	return sky_color(t).linear_to_srgb()


static func sun_direction(t: float) -> Vector3:
	var a := (t - 0.25) * TAU
	return -Vector3(cos(a), sin(a), 0.4 * sin(a)).normalized()
