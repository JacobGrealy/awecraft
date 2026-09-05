class_name DayNight
extends RefCounted

const DAY_LEN := 600.0


static func fog_near(render_radius: int) -> float:
	return (float(render_radius) + 1.0) * 4.0


# AC-0226: full-fog boundary, pulled in from 0.95 to 0.875 of the render
# edge. The far-edge ring pops in as the player crosses a chunk boundary:
# its near face sits at R*16 (crossing instant, worst case) .. (R+1)*16-8
# (chunk center) from the player. A chunk is invisible only at/BEYOND
# fog_depth_end (Godot depth fog: factor 0 at fog_depth_begin, 1 at
# fog_depth_end), so the boundary must land short of the pop-in face to
# hide the pop. 0.875 keeps the (R+1)*16 scaling with render_radius
# (fog_far = 238.0 @ R16, 714.0 @ R50) and puts full fog 18 m short of
# the worst-case R16 pop-in face (256) and 86 m short of R50's (800) —
# fully hidden at every radius R >= 7 (the old 0.95 only guaranteed that
# at R >= 19; @R16 the crossing-instant pop was 98.7% fogged = a flash).
static func fog_far(render_radius: int) -> float:
	return (float(render_radius) + 1.0) * 16.0 * 0.875


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
