static func world_to_face(pos: Vector3, R: float) -> Dictionary:
	# Invert the affine cube map: C = d rescaled so the dominant component
	# is exactly +-1 by |dom| (dividing by the signed dominant would flip
	# the sign of the other components on negative-axis faces); (u,v) =
	# C's coords in the face frame.
	var len: float = pos.length()
	if len <= 0.0:
		return { "face": 0, "u": 0.5, "v": 0.5 }
	var d: Vector3 = pos / len
	var face: int = face_for_dir(d)
	var dom: float = maxf(maxf(absf(d.x), absf(d.y)), absf(d.z))
	var C: Vector3 = d / dom
	var u: float
	var v: float
	match face:
		0, 2, 8, 10:
			u = C.x
		1, 3, 9, 11:
			u = C.x + 1.0
		4, 5, 6, 7:
			u = (C.y + 1.0) * 0.5
	match face:
		0, 1, 2, 3:
			v = (C.z + 1.0) * 0.5
		4, 6:
			v = C.z
		5, 7:
			v = C.z + 1.0
		8, 9, 10, 11:
			v = (C.y + 1.0) * 0.5
	return { "face": face, "u": u, "v": v }
