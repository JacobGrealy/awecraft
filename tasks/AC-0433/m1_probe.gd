# AC-0433 M1 — migration blast radius (plan.html §3). MEASUREMENT, no
# behaviour change. Standalone SceneTree probe: at identical chart coords
# (u,v) and heights, the distance between the canonical placement
#   P_c = (R+h)*normalize(SM.uv_to_world(face,u,v,R)) - (0,R,0)
# and the shipped legacy placement (plan §3.1: home pair = column_transform
# on the flat mapping; non-home = face_chunk_transform with the mirror-aware
# local slot face_local_x and the 16-cell chunking).
# ONE RESULT {…} JSON line; a large displacement is a RESULT, not a failure.
extends SceneTree

const GRID := preload("res://core/planet_grid.gd")
const SM := preload("res://core/sphere_math.gd")

const H := [0.0, 140.0]
const CELL := 1024.0  # legacy face-chart resolution

var _R := 4000.0
var _r_src := "default-4000"
var _fails: Array = []
var _skipped := 0
var _groups: Dictionary = {}
var _overall_max := 0.0
var _overall_worst: Dictionary = {}


func _initialize() -> void:
	# R = Game.planet_R if the autoload is present without the game tree,
	# else 4000 (game.gd pins 4000.0; state the source in the RESULT).
	var g := root.get_node_or_null("Game")
	if g != null and g.get("planet_R") != null:
		_R = float(g.get("planet_R"))
		_r_src = "Game.planet_R"
	_group("G1", _sites_g1())
	_group("G2", _sites_g2())
	_group("G3", _sites_g3())
	_group("G4", _sites_g4())
	print("RESULT " + JSON.stringify({
		"ok": _fails.is_empty(),
		"R": _R,
		"r_source": _r_src,
		"h_values": H,
		"groups": _groups,
		"overall_max_m": _r6(_overall_max),
		"overall_worst": _overall_worst,
		"skipped": _skipped,
		"fails": _fails,
	}))
	quit()


# G1 interior non-home charts: faces 4-11, the three cell centres along
# each axis (cells 256/512/768), interior chunks only.
func _sites_g1() -> Array:
	var s: Array = []
	for face in range(4, 12):
		for iu in [256, 512, 768]:
			for iv in [256, 512, 768]:
				s.append({"face": face, "u": (float(iu) + 0.5) / CELL, "v": (float(iv) + 0.5) / CELL})
	return s


# G2 home/face seam: faces 4-11, the last cell next to the home edge
# (u=1 for 4-7, v=1 for 8-11), three positions along the edge.
func _sites_g2() -> Array:
	var s: Array = []
	for face in range(4, 12):
		for t in [256, 512, 768]:
			if face <= 7:
				s.append({"face": face, "u": (1023.0 + 0.5) / CELL, "v": (float(t) + 0.5) / CELL})
			else:
				s.append({"face": face, "u": (float(t) + 0.5) / CELL, "v": (1023.0 + 0.5) / CELL})
	return s


# G3 home pair interior: flat points near spawn and ~500 m out, both faces.
func _sites_g3() -> Array:
	var s: Array = []
	for p in [Vector2(8.0, 8.0), Vector2(-8.0, 8.0), Vector2(500.0, 500.0), Vector2(-500.0, -500.0)]:
		var r: Dictionary = SM.home_uv(p.x, p.y, _R)
		s.append({"face": int(r["face"]), "u": float(r["u"]), "v": float(r["v"])})
	return s


# G4 the documented corner site: face 4, the home-edge column at the
# harness arm's corner row (iv = 1000), same construction as G2.
func _sites_g4() -> Array:
	return [{"face": 4, "u": (1023.0 + 0.5) / CELL, "v": (1000.0 + 0.5) / CELL}]


func _legacy(face: int, u: float, v: float, h: float) -> Vector3:
	if face <= 1:
		# home pair: flat mapping of (u,v) (plan §3.1), column_transform.
		var hw: float = SM.face_width(_R) * 0.5
		var x: float = (u - (0.0 if face == 0 else 1.0)) * hw
		var z: float = hw * (2.0 * v - 1.0)
		var cx: int = int(floorf(x / 16.0))
		var cz: int = int(floorf(z / 16.0))
		return SM.column_transform(cx, cz, _R) * Vector3(x - float(cx) * 16.0, h, z - float(cz) * 16.0)
	var iu: int = int(floorf(u * CELL))
	var iv: int = int(floorf(v * CELL))
	if iu < 0 or iu >= int(CELL) or iv < 0 or iv >= int(CELL):
		return Vector3(INF, INF, INF)  # out of the legacy grid: a skip
	var ccx: int = iu >> 4
	var ccz: int = iv >> 4
	var lx: float = float(SM.face_local_x(face, iu, ccx)) + 0.5  # mirror-aware slot
	var lz: float = float(iv & 15) + 0.5
	return SM.face_chunk_transform(face, ccx, ccz, _R) * Vector3(lx, h, lz)


func _group(name: String, sites: Array) -> void:
	var n := 0
	var mx := 0.0
	var sum := 0.0
	var worst: Dictionary = {}
	for h in H:
		for s in sites:
			var pc: Vector3 = (_R + h) * SM.uv_to_world(int(s["face"]), float(s["u"]), float(s["v"]), _R).normalized() - Vector3(0.0, _R, 0.0)
			var pl: Vector3 = _legacy(int(s["face"]), float(s["u"]), float(s["v"]), h)
			if not pc.is_finite():
				_fails.append("non-finite canonical at face %d u=%s v=%s h=%s" % [s["face"], _r6(float(s["u"])), _r6(float(s["v"])), h])
				continue
			if is_inf(pl.x):
				_skipped += 1  # legacy transform not buildable here (plan §3.4)
				continue
			var d: float = (pc - pl).length()
			n += 1
			sum += d
			if d > mx:
				mx = d
				worst = {"face": int(s["face"]), "u": _r6(float(s["u"])), "v": _r6(float(s["v"])), "h": h}
	_groups[name] = {"n": n, "max_m": _r6(mx), "mean_m": _r6(sum / n) if n > 0 else 0.0, "worst": worst}
	if mx > _overall_max:
		_overall_max = mx
		_overall_worst = worst


func _r6(x: float) -> float:
	return round(x * 1.0e6) / 1.0e6
