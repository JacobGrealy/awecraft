class_name Mob
extends CharacterBody3D
# AC-0037: a mob is a rigged box puppet (body + head + 4 hip/shoulder
# pivoted limbs) over a CharacterBody3D. AI: passives wander (wolves
# flee, tamed wolves follow), hostiles chase + melee within range,
# the spider is hostile at NIGHT ONLY. Bone-use on a wolf tames it.
# Spawning/despawning (the day/night tables) lives in world._mob_tick.

const GRAV := 26.0
const CHASE_R := 16.0
const ATTACK_R := 1.6
const FLEE_R := 6.0
const FOLLOW_NEAR := 2.0
const FOLLOW_FAR := 5.0
const BONE_ID := 144
const ArrowScript = preload("res://entities/arrow.gd")  # AC-0037 skeleton arrows

var key: String = ""
var hp := 0.0
var tamed := false
var vel := Vector3.ZERO  # kept for parity with the web port (unused; velocity is the physics one)
var flee_t := 0.0
var last_hit := -1.0

var _h := 1.0
var _w := 0.8
var _speed := 1.5
var _passive := true
var _dmg := 0.0
var _ranged := false

# the rig
var _root: Node3D = null
var _leg_l: Node3D = null
var _leg_r: Node3D = null
var _arm_l: Node3D = null
var _arm_r: Node3D = null

# AI state
var _wander_dir := Vector2.ZERO
var _wander_t := 0.0
var _atk_cd := 0.0
var _anim_t := 0.0
var _anim_mix := 0.0
var _face_yaw := 0.0
var _shoot_cd := 0.0


func _ready() -> void:
	var t = Data.mobs.get(key)
	if t == null:
		return
	hp = float(t["hp"])
	_h = float(t["h"])
	_w = float(t["w"])
	_speed = float(t["speed"])
	_passive = bool(t.get("passive", true))
	_dmg = float(t.get("dmg", 0.0))
	_ranged = bool(t.get("ranged", false))
	# collision: a box the type's w x h, feet at the origin.
	var col := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(_w, _h, _w)
	col.shape = bs
	col.position = Vector3(0.0, _h / 2.0, 0.0)
	add_child(col)
	_build_rig(t)
	_face_yaw = randf() * TAU
	rotation.y = _face_yaw


# The rigged body: Root -> Body/Head mesh boxes + 4 limb PIVOT nodes
# (legs at the hips, arms at the shoulders) whose children hang below
# the pivot so rotating the pivot swings the limb.
func _build_rig(t: Dictionary) -> void:
	var body_c: Color = Color(t.get("body", Color.WHITE))
	var head_c: Color = Color(t.get("head", Color.WHITE))
	_root = Node3D.new()
	_root.name = "Root"
	add_child(_root)
	var leg_h: float = _h * 0.34
	var body_h: float = _h * 0.46
	var head_s: float = _w * 0.95
	var body_w := _w
	# body
	var body := _box(body_c, Vector3(body_w, body_h, body_w * 0.75))
	body.position = Vector3(0.0, leg_h + body_h / 2.0, 0.0)
	body.name = "Body"
	_root.add_child(body)
	# head
	var head := _box(head_c, Vector3(head_s, head_s, head_s))
	head.position = Vector3(0.0, leg_h + body_h + head_s / 2.0, 0.0)
	head.name = "Head"
	_root.add_child(head)
	if key == "bunny":
		# cute: two long pink-ish ears on top of the head
		var ear_h := head_s * 0.9
		for sgn in [-1.0, 1.0]:
			var ear := _box(Color(0.98, 0.8, 0.82), Vector3(head_s * 0.22, ear_h, head_s * 0.16))
			ear.position = Vector3(sgn * head_s * 0.22, leg_h + body_h + head_s + ear_h / 2.0 - 0.02, 0.0)
			_root.add_child(ear)
	# limbs: pivot at the joint, mesh hangs below the joint.
	var limb_w := body_w * 0.28
	_leg_l = _lim(body_c, Vector3(-body_w * 0.25, leg_h, 0.0), Vector3(limb_w, leg_h, limb_w * 1.4), "LegL")
	_leg_r = _lim(body_c, Vector3(body_w * 0.25, leg_h, 0.0), Vector3(limb_w, leg_h, limb_w * 1.4), "LegR")
	var arm_h := body_h * 0.85
	# small critters get stubby arms
	_arm_l = _lim(body_c, Vector3(-body_w * 0.55 - limb_w * 0.5, leg_h + body_h * 0.85, 0.0), Vector3(limb_w * 0.8, arm_h, limb_w * 1.2), "ArmL")
	_arm_r = _lim(body_c, Vector3(body_w * 0.55 + limb_w * 0.5, leg_h + body_h * 0.85, 0.0), Vector3(limb_w * 0.8, arm_h, limb_w * 1.2), "ArmR")


func _lim(c: Color, pivot_pos: Vector3, mesh_size: Vector3, nm: String) -> Node3D:
	var piv := Node3D.new()
	piv.name = nm
	piv.position = pivot_pos
	_root.add_child(piv)
	var mi := _box(c, mesh_size)
	mi.position = Vector3(0.0, -mesh_size.y / 2.0, 0.0)
	piv.add_child(mi)
	return piv


func _box(c: Color, size: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = c
	mat.roughness = 0.9
	bm.material = mat
	mi.mesh = bm
	return mi


func center() -> Vector3:
	return position + Vector3(0.0, _h * 0.55, 0.0)


func hurt(n: float, from: Vector3) -> void:
	hp -= n
	last_hit = Time.get_ticks_msec()
	var dx := position.x - from.x
	var dz := position.z - from.z
	var d := sqrt(dx * dx + dz * dz)
	if d <= 0.0001:
		d = 1.0
	velocity.x += dx / d * 5.0
	velocity.z += dz / d * 5.0
	velocity.y += 3.0


func try_kill() -> bool:
	if hp > 0.0:
		return false
	var t = Data.mobs.get(key)
	if t != null and not tamed and Game.world != null:
		var drops: Array = t.get("drops", [])
		var at := position + Vector3(0.5, 0.5, 0.5)
		for d in drops:
			if randf() < float(d["ch"]):
				Game.world.spawn_drop(int(d["id"]), at)
	queue_free()
	return true


func _physics_process(dt: float) -> void:
	var t = Data.mobs.get(key)
	if t == null:
		return
	var p = Game.player
	var night: bool = DayNight.is_night(Game.time_of_day)
	var pdist := -1.0
	if p != null and not p.dead:
		pdist = position.distance_to(p.position)
	# ---- choose the move intent (a Vector2 in world xz, zero = stop)
	var intent := Vector2.ZERO
	var face_t: float = _face_yaw
	if _passive:
		if key == "wolf" and not tamed and pdist >= 0.0 and pdist < FLEE_R:
			# flee straight away from the player
			var away := Vector2(position.x - p.position.x, position.z - p.position.z)
			if away.length() > 0.001:
				intent = away.normalized() * _speed
		elif key == "wolf" and tamed and pdist >= 0.0:
			# follow: close in when far, hold near
			var to := Vector2(p.position.x - position.x, p.position.z - position.z)
			if pdist > FOLLOW_FAR:
				intent = to.normalized() * _speed
		else:
			# wander: a new random heading every couple of seconds
			_wander_t -= dt
			if _wander_t <= 0.0:
				_wander_t = randf_range(2.0, 4.0)
				var a := randf() * TAU
				_wander_dir = Vector2(cos(a), sin(a))
			intent = _wander_dir * _speed * 0.6
	else:
		# hostiles: the spider wakes at night; the others always.
		var active: bool = not (key == "spider" and not night)
		if active and pdist >= 0.0 and pdist < CHASE_R:
			if _ranged and pdist > 4.0:
				# AC-0037: the skeleton HOLDS the 4-14 m band and volleys
				# (the arrow code below); it only melee-chases when close.
				face_t = atan2(-(p.position.x - position.x), -(p.position.z - position.z))
			else:
				var to := Vector2(p.position.x - position.x, p.position.z - position.z)
				if to.length() > 0.001:
					intent = to.normalized() * _speed
				face_t = atan2(-to.x, -to.y)
		elif active and p != null:
			# out of range: drift toward the player's column, slowly
			var to2 := Vector2(p.position.x - position.x, p.position.z - position.z)
			if to2.length() > 1.0:
				intent = to2.normalized() * _speed * 0.5
				face_t = atan2(-to2.x, -to2.y)
	# skeleton volley: one arrow every 2.5 s at the player's chest while
	# inside the band (AC-0037: bow/arrows).
	if _ranged and pdist >= 0.0 and pdist < 14.0 and pdist > 4.0:
		_shoot_cd -= dt
		if _shoot_cd <= 0.0 and p != null and not p.dead:
			_shoot_cd = 2.5
			var a: Node3D = ArrowScript.new()
			a.dmg = _dmg
			Game.entities.add_child(a)
			a.position = center() + Vector3(0.0, 0.2, 0.0)
			var eye_t := Vector3(p.position.x, p.position.y + 1.2, p.position.z)
			a.vel = (eye_t - a.position).normalized() * 12.0
	# attack (hostile, in melee range, cooldown elapsed)
	_atk_cd -= dt
	if not _passive and pdist >= 0.0 and pdist < ATTACK_R and _atk_cd <= 0.0:
		var night2: bool = DayNight.is_night(Game.time_of_day)
		var active2: bool = not (key == "spider" and not night2)
		if active2:
			_atk_cd = 1.0
			if p != null and not p.dead:
				p.damage_player(_dmg, "mob:" + key)
	# ---- physics: walk the intent, gravity, slide.
	velocity.x = lerpf(velocity.x, intent.x, minf(1.0, 8.0 * dt))
	velocity.z = lerpf(velocity.z, intent.y, minf(1.0, 8.0 * dt))
	if not is_on_floor():
		velocity.y -= GRAV * dt
	else:
		velocity.y = 0.0
	move_and_slide()
	# ---- facing: lerp toward the move direction (hostiles keep the
	# player in view when standing).
	var hv := Vector2(velocity.x, velocity.z)
	if hv.length() > 0.2:
		face_t = atan2(-hv.x, -hv.y)
	elif pdist >= 0.0 and not _passive:
		var to3 := Vector2(p.position.x - position.x, p.position.z - position.z)
		if to3.length() > 0.001:
			face_t = atan2(-to3.x, -to3.y)
	_face_yaw = lerp_angle(_face_yaw, face_t, minf(1.0, 8.0 * dt))
	rotation.y = _face_yaw
	# ---- walk-cycle animation: the limbs swing while the body moves.
	var moving: float = clampf(hv.length() / maxf(_speed, 0.01), 0.0, 1.0)
	_anim_mix = lerpf(_anim_mix, moving, minf(1.0, 6.0 * dt))
	_anim_t += dt * (3.0 + 6.0 * moving)
	var sw := sin(_anim_t * 3.2) * 0.55 * _anim_mix
	var sw2 := sin(_anim_t * 3.2 + PI) * 0.55 * _anim_mix
	if _leg_l != null:
		_leg_l.rotation.x = sw
		_leg_r.rotation.x = sw2
	if _arm_l != null:
		# hostiles hold their arms out when chasing (MC zombie pose)
		if not _passive and _anim_mix > 0.3:
			_arm_l.rotation.x = -1.2
			_arm_r.rotation.x = -1.2
		else:
			_arm_l.rotation.x = sw2 * 0.6
			_arm_r.rotation.x = sw * 0.6
