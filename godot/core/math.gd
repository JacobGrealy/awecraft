class_name VoxelMath

const FACES := [
	{"n": Vector3i(-1, 0, 0), "c": [Vector3(0, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 1), Vector3(0, 1, 0)], "sh": 0.8},
	{"n": Vector3i(1, 0, 0), "c": [Vector3(1, 0, 1), Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(1, 1, 1)], "sh": 0.8},
	{"n": Vector3i(0, 1, 0), "c": [Vector3(0, 1, 1), Vector3(1, 1, 1), Vector3(1, 1, 0), Vector3(0, 1, 0)], "sh": 1.0},
	{"n": Vector3i(0, -1, 0), "c": [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1)], "sh": 0.5},
	{"n": Vector3i(0, 0, -1), "c": [Vector3(1, 0, 0), Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(1, 1, 0)], "sh": 0.8},
	{"n": Vector3i(0, 0, 1), "c": [Vector3(0, 0, 1), Vector3(1, 0, 1), Vector3(1, 1, 1), Vector3(0, 1, 1)], "sh": 0.8},
]


static func face_normal(i: int) -> Vector3i:
	return FACES[i].n


static func raycast_blocks(origin: Vector3, dir: Vector3, max_dist: float, get_block: Callable, fluid := false) -> Dictionary:
	var x := int(floorf(origin.x))
	var y := int(floorf(origin.y))
	var z := int(floorf(origin.z))
	var sx := 1 if dir.x > 0.0 else -1
	var sy := 1 if dir.y > 0.0 else -1
	var sz := 1 if dir.z > 0.0 else -1
	var tdx: float = INF if dir.x == 0.0 else absf(1.0 / dir.x)
	var tdy: float = INF if dir.y == 0.0 else absf(1.0 / dir.y)
	var tdz: float = INF if dir.z == 0.0 else absf(1.0 / dir.z)
	var tmx: float = INF if dir.x == 0.0 else (absf(x + 1.0 - origin.x) if dir.x > 0.0 else absf(origin.x - float(x))) * tdx
	var tmy: float = INF if dir.y == 0.0 else (absf(y + 1.0 - origin.y) if dir.y > 0.0 else absf(origin.y - float(y))) * tdy
	var tmz: float = INF if dir.z == 0.0 else (absf(z + 1.0 - origin.z) if dir.z > 0.0 else absf(origin.z - float(z))) * tdz
	var normal := Vector3i.ZERO
	var t := 0.0
	for i in 256:
		var b = get_block.call(x, y, z)
		if int(b) != 0 and (fluid or int(b) != 5):
			return {"hit": true, "cell": Vector3i(x, y, z), "id": int(b), "normal": normal, "t": t}
		if tmx < tmy and tmx < tmz:
			x += sx
			t = tmx
			tmx += tdx
			normal = Vector3i(-sx, 0, 0)
		elif tmy < tmz:
			y += sy
			t = tmy
			tmy += tdy
			normal = Vector3i(0, -sy, 0)
		else:
			z += sz
			t = tmz
			tmz += tdz
			normal = Vector3i(0, 0, -sz)
		if t > max_dist:
			break
	return {"hit": false, "cell": Vector3i.ZERO, "id": 0, "normal": Vector3i.ZERO, "t": 0.0}


static func raycast_cell(origin: Vector3, dir: Vector3, max_dist: float, get_block: Callable, fluid: bool) -> Dictionary:
	var x := int(floorf(origin.x))
	var y := int(floorf(origin.y))
	var z := int(floorf(origin.z))
	var sx := 1 if dir.x > 0.0 else -1
	var sy := 1 if dir.y > 0.0 else -1
	var sz := 1 if dir.z > 0.0 else -1
	var tdx: float = INF if dir.x == 0.0 else absf(1.0 / dir.x)
	var tdy: float = INF if dir.y == 0.0 else absf(1.0 / dir.y)
	var tdz: float = INF if dir.z == 0.0 else absf(1.0 / dir.z)
	var tmx: float = INF if dir.x == 0.0 else (absf(x + 1.0 - origin.x) if dir.x > 0.0 else absf(origin.x - float(x))) * tdx
	var tmy: float = INF if dir.y == 0.0 else (absf(y + 1.0 - origin.y) if dir.y > 0.0 else absf(origin.y - float(y))) * tdy
	var tmz: float = INF if dir.z == 0.0 else (absf(z + 1.0 - origin.z) if dir.z > 0.0 else absf(origin.z - float(z))) * tdz
	var normal := Vector3i.ZERO
	var t := 0.0
	for i in 256:
		var b = get_block.call(x, y, z)
		if int(b) != 0 and (fluid or int(b) != 5):
			return {"hit": true, "cell": Vector3i(x, y, z), "id": int(b), "normal": normal, "t": t}
		if tmx < tmy and tmx < tmz:
			x += sx
			t = tmx
			tmx += tdx
			normal = Vector3i(-sx, 0, 0)
		elif tmy < tmz:
			y += sy
			t = tmy
			tmy += tdy
			normal = Vector3i(0, -sy, 0)
		else:
			z += sz
			t = tmz
			tmz += tdz
			normal = Vector3i(0, 0, -sz)
		if t > max_dist:
			break
	return {"hit": false, "cell": Vector3i.ZERO, "id": 0, "normal": Vector3i.ZERO, "t": 0.0}
