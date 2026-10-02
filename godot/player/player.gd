extends CharacterBody3D

const EYE := 1.62
const P_H := 1.8
const PLAYER_LIGHT_LEVEL := 5.0
const PLAYER_LIGHT_RADIUS := 5.0
const P_HALF := 0.3
const GRAV := 26.0
const JUMP := 8.4
const WALK := 4.3
const SPRINT := 5.6
const SWIM := 3.2
const LAVA_SPEED := 1.1
const FLY_VS := 0.85
const MOUSE_SENS := 0.0022
# AC-0087: full-stick right-stick look speed (rad/s) - a full turn
# in ~2.4 s, MC-like.
const PAD_LOOK_SPEED := 2.5
const PITCH_LIMIT := 1.55
const REACH := 6.0
# AC-0309 C5: the auto-step on the FACE world (6 m cell resolution —
# terrain steps up to ~2-3 m): 1.0 m auto-stepped, the jump (1.35 m)
# covers the rest. The home step stays 0.5 m (the folded-net seam lip).
const FACE_STEP := 1.0
# AC-0039: step cadence — one "step" SFX per this much ground distance.
const STEP_DIST := 2.3
# AC-0145 P1: core sphere motion. The basis is an ACCUMULATED continuous
# frame: local Y slews toward up = the EXACT radial underfoot (C = (0,-R,0)
# global — the planet frame shifted by (0,-R,0)), the look yaw is applied as
# a delta around that local Y, and the per-column step (0.23 deg at R = 4000)
# is a continuous slew, never a re-snap. SPHERE_SNAP: a misalignment above
# ~20 deg is a teleport-class position set, not a motion — it snaps.
const SPHERE_SLEW := 12.0
const SPHERE_SNAP := 0.35
# AC-0145 P2: the altitude band window, in RADIAL altitude (m above the
# surface, |pos - C| - R — the same number on every face). band = 0 at/
# below BAND_WALK_MAX (surface walk + step, full up-alignment + gravity),
# band = 1 at/above BAND_FLY_MIN (6-DOF: free basis, no up-alignment /
# auto-level, no gravity — thrust only), smoothstep between. BAND_FLY_MIN
# sits above the atmosphere's visible (depth-fog) boundary (full fog
# 714 m at the R50 render edge 800 m — the sky/fog is distance-driven) and
# at R = 4000 the horizon reads as a curve in space: the planet-epic
# window (design of record, docs/planet-epic.html §09 T6).
const BAND_WALK_MAX := 500.0
const BAND_FLY_MIN := 2000.0
const INV_SIZE := 36
const STACK_MAX := 64
const ARMOR_SIZE := 4
const CRAFT_GRID_SIZE := 9
const EGRID_CELLS := 4
const TABLE_ID := 20
# AC-0271: door state by ID variant (the block grid is a pure id byte -
# no per-cell state exists, so open/closed lives in the id pair).
# The HINGE side is deliberately NOT stored: the open panel renders as
# the symmetric cross-X (a door panel reads correctly from every
# direction), so a stored hinge would be dead state. "Hinge handling"
# here = the door is a PAIR (bottom half at y, top half at y+1):
# placement demands 2-high air, toggling/breaking always acts on both
# halves, and the pair is re-validated against the grid on every touch.
const DOOR_LO := 26   # closed, bottom half (also the DOOR ITEM id)
const DOOR_HI := 27   # closed, top half
const DOOR_LO_OPEN := 29
const DOOR_HI_OPEN := 31
# AC-0267: crouch (B toggle). The eye lerps EYE -> CROUCH_EYE, the capsule
# shrinks CAP_H -> CAP_H_CROUCH (feet stay at the origin), ground speed
# scales by CROUCH_SPEED, and the edge guard keeps the feet on solid
# ground (a crouched player cannot walk off a block).
const CROUCH_EYE := 1.1
const CAP_H := 1.8
const CAP_H_CROUCH := 1.2
const CROUCH_SPEED := 0.3
const STORAGE_OFF := 9
const ARMOR_SLOTS := ["head", "chest", "legs", "boots"]

@onready var camera: Camera3D = $Camera3D
@onready var col_shape: CollisionShape3D = $CollisionShape3D  # AC-0267

var flying := false
# AC-0276: LATCHED sprint (Minecraft-style, user request): a sprint that
# was STARTED while moving forward keeps going after the key is released;
# it ends when the player stops moving or moves backwards. Flight L3
# stays a HELD speed key (no latch in flight). The camera FOV kicks up
# 10% while effectively sprinting (lerped ~0.15 s) and reverts after.
var sprint_latched := false
var _base_fov := -1.0
var _last_jump_t := -1  # AC-0243: double-tap fly toggle (Bedrock jump-double-tap)
var _yaw := 0.0
var _pitch := 0.0
# AC-0145 P1: the accumulated continuous frame (see SPHERE_SLEW). _up is the
# exact radial underfoot (or +Y in flat mode / before the first align);
# _applied_yaw is the yaw already baked into the basis (look events apply
# only their delta, _sphere_align owns the radial alignment).
var _up: Vector3 = Vector3.UP
var _applied_yaw := 0.0
var _chunk_x := 0
var _chunk_z := 0
var _chunk_y := 0  # AC-0234: the tracked 16-block Y slab (a crossing re-centers)
var _anchor: Dictionary = {}  # AC-0309 C5: the sim anchor (World.player_anchor)
var _debug_layer: CanvasLayer = null
var _debug_label: Label = null
var inv: Array = []
var sel := 0
var armor: Array = []
var hp := 20.0
var hunger := 20.0
var dead := false
var air := 10.0
var lava_t := 0.0
var drown_t := 0.0
var _step_acc := 0.0        # AC-0039: step-SFX distance accumulator
var in_water_now := false   # AC-0191: test-readable fluid state (range arm)
var in_lava_now := false    # AC-0191
var fall_start := -1.0
var _regen_t := 0.0
var _starve_t := 0.0
signal damaged(src: String)
var held: Dictionary = {}
var drag_held := false
var craft_grid: Array = []
# Shared table grid (documented simplification vs MC's per-block table state:
# one 3x3 grid for the ui_mode "table" view, returned to inventory on close).
var table_grid: Array = []
var craft_out: Dictionary = {}
var ui_mode := ""
var highlight: MeshInstance3D = null
var hand_root: Node3D = null
var sway_root: Node3D = null
var _sway_phase := 0.0
var _sway_bobs := 0.0
var _sway_speed := 0.0
var held_box: MeshInstance3D = null
var held_sprite: Sprite3D = null
var held_fist: MeshInstance3D = null
var held_tool: Node3D = null
var held_tool_type := ""
var _tool_voxel_count := 0
var _tool_diag := 0.0
var _held_texs := {}
var _held_item_texs := {}
var _tool_mats := {}
var _held_key := ""
const HAND_BASE_POS := Vector3(0.45, -0.62, -0.7)
const TOOL_TARGET_DIAG := {"pick": 1.224, "axe": 1.10, "shovel": 1.10, "sword": 0.796}
# AC-0097 (user 2026-09-11): held block is 0.33 scale (was 0.70).
const HELD_ITEM_SCALE := 0.33
const HANDLE_C := Color(0.47, 0.33, 0.18)
const SWORD_HANDLE_C := Color(0.52, 0.36, 0.22)
const SWING_DURATION := 0.2
const SWING_ITEM := 0
const SWING_PUNCH := 1
const SWAY_PHASE_K := 0.93
const SWAY_AMP_Y := 0.015
const SWAY_AMP_X := 0.006
const SWAY_SMOOTH := 10.0
var _swing_active := false
var _swing_held := false
var _swing_t := 0.0
var _swing_frac := 0.0
var _swing_kind := SWING_ITEM
var _swing_loop := false
var _lmb_down := false
var crouched := false  # AC-0267: B (pad_cancel) toggle, ground play
var _mining := false
var _pad_look := Vector2.ZERO  # AC-0087: right-stick value (applied per frame in _process)
var _pad_mining := false  # AC-0087: RT hold-to-mine edge state
var _pad_lt_down := false  # AC-0087: LT tap edge state
var _dragging := false
var _mine_cell := Vector3i(0, 0, 0)
var _mine_id := -1
var _mine_prog := 0.0
var _vm_mats: Array = []
var _vm_box_mats := {}
var _vm_sprite_mat: StandardMaterial3D = null
var _vm_eye_cell := Vector3i(-1, -1, -1)
var _vm_light_ms := 0
var _vm_sky := 0.0
var _vm_blk := 0.0
var _vm_L := 1.0


func _ready() -> void:
	Game.player = self
	_ac0383_player_init()  # AC-0383: read the env once (zero per-frame cost when off)
	if Game.world != null:
		# AC-0307: spawn_point() is flat; the placed world needs the
		# sphere conversion (mm-level near the spawn, exact by contract).
		var sp: Vector3 = Game.world.spawn_point()
		position = Game.world.world_pos_of_flat(sp.x, sp.y, sp.z)
		# AC-0308: track the player's column in FLAT coords (the recenter
		# contract and the column frame both key on flat).
		_chunk_x = int(floorf(sp.x / 16.0))
		_chunk_z = int(floorf(sp.z / 16.0))
		_chunk_y = int(floorf(sp.y / 16.0))  # AC-0234
	_init_inv()
	_build_highlight()
	_build_held()
	_build_debug()
	camera.current = true
	# AC-0145 P1: seed the ACCUMULATED frame from the sim anchor (the column
	# frame on home, the face frame past the patch edge) so the first
	# _sphere_align has a sane heading to preserve; _applied_yaw starts at the
	# current look so the first look event is a zero delta.
	basis = _anchor_frame().orthonormalized()
	_applied_yaw = _yaw
	_apply_rotation()
	_update_debug_label()
	# AC-0281: apply DOF settings to the live CameraAttributes
	if camera != null and camera.get("attributes") != null:
		Settings.apply_dof()


func _process(dt: float) -> void:
	# AC-0087: right-stick look - the stick sends VALUE events (not deltas),
	# so the stored value is applied once per frame.
	if Game.mode == "play" and ui_mode == "" and not Game.console_open and _pad_look != Vector2.ZERO:
		_yaw -= _pad_look.x * PAD_LOOK_SPEED * dt
		_pitch = clampf(_pitch - _pad_look.y * PAD_LOOK_SPEED * dt, -PITCH_LIMIT, PITCH_LIMIT)
		_apply_rotation()
	if camera == null or hand_root == null or held_box == null or held_sprite == null:
		return
	var it: Dictionary = inv_selected()
	var key := "%d:%d:%d:%s" % [sel, int(it["id"]), int(it["n"]), ui_mode]
	if key != _held_key:
		_held_key = key
		_update_held(int(it["id"]), int(it["n"]))
	_update_swing_loop()
	_update_swing(dt)
	_update_sway(dt)
	vm_refresh(false)


func _input(event: InputEvent) -> void:
	# AC-0121: backtick/tilde (or F3) toggles the debug console. This runs in
	# the _input stage - BEFORE the focused LineEdit would swallow the key -
	# so the toggle works with the console open (closing) and closed
	# (opening); marking the event handled keeps a stray backtick out of the
	# command line.
	if event is InputEventKey and event.pressed and not event.echo:
		var kc: int = int(event.physical_keycode)
		if kc == int(KEY_QUOTELEFT) or kc == int(KEY_F3):
			if Game.console != null and Game.mode == "play":
				Game.console.toggle()
			get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and (Game.cursor_state == int(Input.MOUSE_MODE_CAPTURED) or _dragging):
		var mm: InputEventMouseMotion = event
		apply_look(mm)
	if event is InputEventMouseButton:
		var lmb: InputEventMouseButton = event
		if lmb.button_index == MOUSE_BUTTON_LEFT and not Game.console_open:
			_lmb_down = lmb.pressed
	# AC-0272: any controller input hides a visible cursor — a pad button
	# press or a stick/trigger deflection (above the noise floor, so idle
	# stick wobble can't flap it). The mouse brings it back: motion while
	# hidden re-shows it, a click re-captures through the existing branch
	# below. Works in every mode (the cursor is global; the menu keeps its
	# native GUI focus, so a hidden cursor there is fine).
	elif event is InputEventJoypadButton and event.pressed \
			and Game.cursor_state != int(Input.MOUSE_MODE_CAPTURED):
		Game.set_cursor(Input.MOUSE_MODE_HIDDEN)
	elif event is InputEventJoypadMotion and Game.cursor_state != int(Input.MOUSE_MODE_CAPTURED):
		if absf(event.axis_value) > 0.05:
			Game.set_cursor(Input.MOUSE_MODE_HIDDEN)
	elif event is InputEventMouseMotion and Game.cursor_state == int(Input.MOUSE_MODE_HIDDEN):
		Game.set_cursor(Input.MOUSE_MODE_VISIBLE)
	if Game.mode != "play":
		return
	# AC-0121: console open - the keyboard keys are swallowed by the focused
	# TextEdit (GUI stage), but mouse clicks outside the panel and pad
	# buttons still arrive here; game actions must not fire.
	if Game.console_open:
		return
	# AC-0243: double-tap the jump action (Space / A / Cross) within
	# 0.3 s toggles fly (Bedrock parity). The second tap toggles
	# instead of jumping; holding it after the toggle climbs.
	if event.is_action_pressed("jump") and ui_mode == "" and not dead:
		var now := Time.get_ticks_msec()
		if OS.get_environment("AWECRAFT_PADTRACE") == "1":
			print("JUMPTAP now=%d last=%d delta=%d flying=%s dead=%s" % [now, _last_jump_t, now - _last_jump_t if _last_jump_t >= 0 else -1, flying, dead])
		if _last_jump_t >= 0 and now - _last_jump_t < 300:
			flying = not flying
			Game.message("Flying" if flying else "Landed")
			_last_jump_t = -1
			return
		_last_jump_t = now
	if event is InputEventMouseButton:
		if ui_mode != "":
			return
		var mb: InputEventMouseButton = event
		var was_captured := Game.cursor_state == int(Input.MOUSE_MODE_CAPTURED)
		var is_wheel := mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN
		if mb.pressed and not was_captured and not is_wheel:
			if Game.cursor_state == int(Input.MOUSE_MODE_HIDDEN):
				# AC-0272 (follow-up, user request): a click while the cursor
				# is HIDDEN (controller play) only makes the cursor visible
				# again - it does not capture (the next, visible-mode click
				# captures as before) and does not start a drag.
				Game.set_cursor(Input.MOUSE_MODE_VISIBLE)
				return
			Game.set_cursor(Input.MOUSE_MODE_CAPTURED)
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if was_captured:
					start_mine()
				else:
					_dragging = true
			else:
				_dragging = false
				if _mining:
					release_mine()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			if was_captured:
				use_selected()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			sel = clampi(sel - 1, 0, 8)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			sel = clampi(sel + 1, 0, 8)
	elif event is InputEventKey and event.pressed and not event.echo:
		var kc: int = int(event.physical_keycode)
		if kc == int(KEY_E):
			if ui_mode == "":
				open_inventory("inv")
				Game.set_cursor(Input.MOUSE_MODE_VISIBLE)
			else:
				close_inventory()
		# AC-0122: the old V/H/J/K debug keys moved into the console as the
		# seedinv / swing / holdswing / clearswing commands (no more accidental
		# triggers during play).
		# AC-0172: F8 = one-click bug capture (zip in user://bugs).
		elif kc == int(KEY_F8):
			Debug.bug_report()
		# AC-0185: ui_pause now carries P + Esc (project.godot). Esc must be
		# checked BEFORE the ui_pause branch - with ui_mode open it must
		# close the UI (below) and never fall into the pause branch.
		elif kc == int(KEY_ESCAPE) and ui_mode != "":
			close_inventory()
		elif kc == int(KEY_P) or event.is_action_pressed("ui_pause"):
			if ui_mode == "" and not dead:
				Game.pause()
		elif ui_mode == "" and kc >= int(KEY_1) and kc <= int(KEY_9):
			sel = int(kc - int(KEY_1))

	# AC-0087: Bedrock controller (minecraft.wiki Controls#Controller) -
	# left stick rides the move_* InputMap actions (analog); the right stick
	# stores its value (applied per frame in _process); the buttons below.
	if event is InputEventJoypadMotion:
		var jm: InputEventJoypadMotion = event
		if OS.get_environment("AWECRAFT_PADTRACE") == "1" and (jm.axis == JOY_AXIS_TRIGGER_LEFT or jm.axis == JOY_AXIS_TRIGGER_RIGHT):
			print("AXISTRACE axis=%d val=%.2f mode=%s ui=%s lt_down=%s mining=%s" % [jm.axis, jm.axis_value, Game.mode, ui_mode, _pad_lt_down, _mining])
		if jm.device == 0 and Game.mode == "play" and ui_mode == "":
			if jm.axis == JOY_AXIS_RIGHT_X:
				_pad_look.x = jm.axis_value
			elif jm.axis == JOY_AXIS_RIGHT_Y:
				_pad_look.y = jm.axis_value
			# AC-0087: the triggers are ANALOG axes in Godot 4.7 (SDL layout:
			# TRIGGER_LEFT = 4, TRIGGER_RIGHT = 5, value 0.0..1.0) - RT is
			# hold-to-attack (mine), LT is a tap = use/place.
			elif jm.axis == JOY_AXIS_TRIGGER_RIGHT:
				if jm.axis_value > 0.5:
					if not _pad_mining:
						_pad_mining = true
						start_mine()
				elif jm.axis_value < 0.35 and _pad_mining:  # AC-0243: hysteresis (0.5 press / 0.35 release) - a jittering trigger must not release mid-hold
					_pad_mining = false
					if _mining:
						release_mine()
			elif jm.axis == JOY_AXIS_TRIGGER_LEFT:
				if jm.axis_value > 0.5 and not _pad_lt_down:
					_pad_lt_down = true
					use_selected()
				elif jm.axis_value <= 0.5:
					_pad_lt_down = false
	if event is InputEventJoypadButton:
		var jb: InputEventJoypadButton = event
		if OS.get_environment("AWECRAFT_PADTRACE") == "1":
			print("PADTRACE btn=%d pressed=%s mode=%s ui=%s sel=%d flying=%s" % [jb.button_index, jb.pressed, Game.mode, ui_mode, sel, flying])
		if jb.device != 0:
			return
		if jb.pressed:
			# Y/Triangle toggles the inventory (the craft grid lives in it;
			# X/Square = crafting opens the same screen - the 3x3 grid is
			# used via a placed crafting table, as in MC).
			if OS.get_environment("AWECRAFT_PADTRACE") == "1":
				print("PADTRACE  branch inv_or_craft inv=%s craft=%s" % [str(event.is_action_pressed("pad_inventory")).to_lower(), str(event.is_action_pressed("pad_craft")).to_lower()])
			if event.is_action_pressed("pad_inventory") or event.is_action_pressed("pad_craft"):
				if ui_mode == "":
					open_inventory("inv")
					Game.set_cursor(Input.MOUSE_MODE_VISIBLE)
				else:
					close_inventory()
				return
			if ui_mode != "":
				# B/Circle closes the inventory (mirrors the ESC key branch).
				if event.is_action_pressed("pad_cancel"):
					close_inventory()
				return
			# LB/RB cycle the hotbar (9/10 in the 4.7 SDL layout), Menu/START
			# (6) pause. A/Cross = jump rides the jump action; B/Circle =
			# sneak has no crouch in this game (no-op). RT/L2 = attack/use are
			# the analog triggers, handled in the motion branch above.
			if OS.get_environment("AWECRAFT_PADTRACE") == "1":
				print("PADTRACE  branch hotbar prev=%s next=%s" % [str(event.is_action_pressed("pad_hotbar_prev")).to_lower(), str(event.is_action_pressed("pad_hotbar_next")).to_lower()])
			if event.is_action_pressed("pad_hotbar_prev"):
				sel = clampi(sel - 1, 0, 8)
			elif event.is_action_pressed("pad_hotbar_next"):
				sel = clampi(sel + 1, 0, 8)
			elif event.is_action_pressed("pad_cancel"):
				# AC-0267: B/Circle toggles CROUCH in ground play (the old
				# comment "B = sneak no-op" is retired). While flying, B
				# stays the held down key (AC-0264) - no double trigger.
				if not flying and not dead:
					crouched = not crouched
					Game.message("Crouching" if crouched else "Standing")
				if OS.get_environment("AWECRAFT_PADTRACE") == "1":
					print("PADTRACE  sel now %d" % sel)
			elif event.is_action_pressed("pad_pause"):
				if not dead:
					Game.pause()


func _physics_process(dt: float) -> void:
	if OS.get_environment("AWECRAFT_CBLOG") == "1":
		print("CBP in t=%d" % Time.get_ticks_msec())
	if ac0383_on:
		# AC-0383: bracket the movement-model step (the 6-DOF flight path +
		# the surface-walk blend — ONE model, AC-0145 P2). It runs in
		# _physics_process, OUTSIDE the wprof frame window, so the partition
		# could never see it. Instrument-only.
		var _p0 := Time.get_ticks_usec()
		_physics_process_impl(dt)
		_ac0383_player_add(Time.get_ticks_usec() - _p0)
	elif ac0383_guard:
		# the blind negative test: the code runs, the bracket is disabled —
		# the guard must trip visibly (the AC-0310/AC-0379 pattern).
		_ac0383_blind_n += 1
		if not _ac0383_guard_tripped and _ac0383_blind_n >= 60:
			_ac0383_guard_tripped = true
			print("AC0383_GUARD FAIL player_phys: %d physics frames ran with the bracket blind" % _ac0383_blind_n)
		_physics_process_impl(dt)
	else:
		_physics_process_impl(dt)
	if OS.get_environment("AWECRAFT_CBLOG") == "1":
		print("CBP out t=%d" % Time.get_ticks_msec())


func _physics_process_impl(dt: float) -> void:
	if Game.mode != "play":
		return
	if dead:
		return
	# AC-0307: the placed world — the global Y is no longer the player's
	# height (the ground curves down from the spawn); the altitude
	# semantics (cruise altitude, fall distance, the void test) key on the
	# FLAT height: the height above the local surface along the local radial.
	# AC-0309 C5: the sim anchor — home patch: the identity frame (the
	# flat height, as before); past a patch edge: the player's face chunk's
	# UNIT-vector frame (orthonormal metres; the chunk node's basis is the
	# same axes scaled by the cell widths). All movement physics below run
	# in the anchor frame unchanged (gravity along local -Y, jump, step).
	var flat_h: float = Game.world.sim_height(position) if Game.world != null else position.y
	if Game.world != null:
		_anchor = Game.world.player_anchor(position)
	# AC-0145 P2: the RADIAL altitude above the surface = |pos - C| - R
	# (C = (0,-R,0) global) — the same number on every face (a flat-Y
	# altitude breaks the moment the player flies over a fold). It drives
	# the band blend: band = 0 at/ below BAND_WALK_MAX (surface walk +
	# step, full up-alignment + gravity), band = 1 at/ above BAND_FLY_MIN
	# (6-DOF: free basis, no up-alignment / auto-level, no gravity),
	# smoothstep between. Flat mode (no world / R <= 0): no bands.
	var R_b: float = Game.planet_R if Game.world != null else 0.0
	var alt_rad: float = position.y
	var band: float = 0.0
	if R_b > 0.0:
		alt_rad = (position + Vector3(0.0, R_b, 0.0)).length() - R_b
		band = smoothstep(BAND_WALK_MAX, BAND_FLY_MIN, alt_rad)
	# AC-0145 P1: the continuous radial alignment of the basis, BEFORE the
	# velocity math — the movement frame below IS the accumulated basis.
	# AC-0145 P2: the alignment scales with (1 - band) — full at the
	# surface (up_dot 1.0, piece 1), zero above the atmosphere (the 6-DOF
	# band is a FREE basis: no up-alignment, no auto-level).
	_sphere_align(dt, 1.0 - band)
	# AC-0121: while the debug console is open, ignore every polled game
	# action - typing "w"/space/shift must not steer, jump, sprint or toggle
	# flight. Physics (gravity, falls, swimming buoyancy) keeps running.
	var cg := Game.console_open
	if cg:
		_lmb_down = false
	if not cg and Input.is_action_just_pressed("fly"):
		flying = not flying
		# AC-0267: B is the flight DOWN key while flying (AC-0264) - the
		# crouch toggle must not live under it, so flight un-crouches.
		crouched = false
		Game.message("Flying" if flying else "Landed")
	if not cg and Input.is_action_just_pressed("time"):
		_cycle_time()
	if not cg and Input.is_action_just_pressed("debug"):
		_debug_label.visible = not _debug_label.visible
	var in_water := _block_at(position.x, position.y + 0.5, position.z) == 5
	var in_lava := _block_at(position.x, position.y + 0.5, position.z) == 24
	in_water_now = in_water
	in_lava_now = in_lava
	var swim_up := in_water or _block_at(position.x, position.y, position.z) == 5
	var ix := 0.0
	var iz := 0.0
	if not cg and Input.is_action_pressed("move_forward"):
		iz += 1.0
	if not cg and Input.is_action_pressed("move_back"):
		iz -= 1.0
	if not cg and Input.is_action_pressed("move_left"):
		ix -= 1.0
	if not cg and Input.is_action_pressed("move_right"):
		ix += 1.0
	var ln := Vector2(ix, iz).length()
	if ln > 0.0:
		ix /= ln
		iz /= ln
	# AC-0264: sprint = keyboard Shift (unchanged) OR L3 (pad_sprint).
	# In flight, L3 scales the flight speed by the ground ratio
	# (SPRINT/WALK ~1.30) and does NOT also act as the down key (that
	# stays Shift / B-pad_cancel — a double trigger the task forbids).
	var sprint_kbd := not cg and Input.is_key_pressed(KEY_SHIFT)
	var sprint_pad := not cg and Input.is_action_pressed("pad_sprint")
	var sprint := sprint_kbd or sprint_pad
	var fly_sprint := sprint_pad
	# AC-0276: latch the sprint on a forward-moving start; release it on
	# stop or backwards (ground only - flight L3 is a held speed key).
	if flying:
		sprint_latched = false
	else:
		if sprint and iz > 0.0:
			sprint_latched = true
		elif iz < 0.0 or ln == 0.0:
			sprint_latched = false
	var sprint_eff := sprint or sprint_latched
	var speed: float
	if flying:
		# AC-0280: altitude-based flight speed — below cruising_altitude use
		# sub_cruising_speed (default 2x WALK), at/above use cruising_speed (6x).
		# AC-0145 P2: the gate is the RADIAL altitude (alt_rad = |pos-C|-R),
		# not the flat-Y (flat_h) — the speed step tracks the height above
		# the surface, the same on every face.
		var cruise_alt := float(int(Settings.values.get("cruising_altitude", 275)))
		var fly_mult := float(int(Settings.values.get("sub_cruising_speed", 2))) if alt_rad < cruise_alt else float(int(Settings.values.get("cruising_speed", 6)))
		speed = WALK * fly_mult
		if fly_sprint:
			speed *= SPRINT / WALK
	elif swim_up:
		speed = SWIM
	elif in_lava:
		speed = LAVA_SPEED
	elif sprint_eff:
		speed = SPRINT
	else:
		speed = WALK
	# AC-0267: crouch is a ~0.3x speed (the "reverse sprint") - it wins
	# over a latched sprint so holding shift into a crouch does not keep
	# sprint speed. Flight/swim-up keep their own speeds.
	if crouched and not flying and not swim_up:
		speed = WALK * CROUCH_SPEED
	# AC-0308 -> AC-0145 P1: the player lives in the ACCUMULATED continuous
	# frame (the basis, see _sphere_align): local +Y = up = the EXACT radial
	# underfoot, the look yaw is baked in. The WASD target in this frame is
	# (ix, -iz) * speed (forward = local -Z, strafe = local +X) — the old
	# (tx, tz) formula pre-rotated the input by -yaw into the COLUMN frame;
	# mapping it through the rendered frame would apply the yaw TWICE (the
	# AC-0308 double-rotation trap), so the formula is replaced by the frame
	# choice. CharacterBody3D velocity is global space, so lerp in local and
	# map back. The per-column facet normal is no longer the movement up —
	# the tangent-plane projection below uses the exact up.
	var tx := ix * speed
	var tz := -iz * speed
	var k: float
	if flying:
		k = 10.0
	elif swim_up:
		k = 4.0
	else:
		k = 12.0
	var b: Basis = basis  # AC-0145 P1: the continuous up-aligned frame (was _anchor_basis())
	# orthonormal basis: the inverse rotation is the transpose
	var vloc: Vector3 = b.transposed() * velocity
	vloc.x = lerpf(vloc.x, tx, minf(1.0, k * dt))
	vloc.z = lerpf(vloc.z, tz, minf(1.0, k * dt))
	if not flying and is_on_floor():
		# AC-0145 P1: walking stays tangent-flat — while on the ground the
		# velocity is projected onto the tangent plane (the two basis vectors
		# perpendicular to up): in the up-aligned orthonormal frame that is
		# the horizontal part. Done BEFORE the jump so a takeoff keeps its
		# vertical kick; flight/air keep the full 3-DOF lerp (the flight
		# reconciliation is a later AC-0145 piece).
		vloc.y = 0.0
	if flying:
		var vy := 0.0
		if not cg and Input.is_action_pressed("jump"):
			vy += 1.0  # A held = up (AC-0243: the double-tap hold climbs)
		# AC-0264: down stays SHIFT / B (pad_cancel). L3 (sprint_pad) is a
		# SPEED key in flight, not a down key — using `sprint` here would
		# make L3 double-trigger (descend AND speed up).
		if (sprint_kbd or (not cg and Input.is_action_pressed("pad_cancel"))):
			vy -= 1.0  # SHIFT or B (pad_cancel) = down (AC-0243)
		# AC-0145 P2: radial altitude gate (alt_rad), same as the speed gate above.
		var cruise_alt_vs := float(int(Settings.values.get("cruising_altitude", 275)))
		var fly_mult_vs := float(int(Settings.values.get("sub_cruising_speed", 2))) if alt_rad < cruise_alt_vs else float(int(Settings.values.get("cruising_speed", 6)))
		var fly_vs := WALK * fly_mult_vs * FLY_VS
		if fly_sprint:
			fly_vs *= SPRINT / WALK
		vloc.y = lerpf(vloc.y, vy * fly_vs, minf(1.0, 10.0 * dt))
	elif in_water:
		vloc.y = lerpf(vloc.y, -3.5, minf(1.0, 4.0 * dt))
		if not cg and Input.is_action_pressed("jump"):
			vloc.y = lerpf(vloc.y, 4.5, minf(1.0, 8.0 * dt))
	elif in_lava:
		vloc.y = lerpf(vloc.y, -0.7, minf(1.0, 3.0 * dt))
		if not cg and Input.is_action_pressed("jump"):
			vloc.y = lerpf(vloc.y, 1.4, minf(1.0, 6.0 * dt))
	elif swim_up and (not cg and Input.is_action_pressed("jump")):
		vloc.y = lerpf(vloc.y, 4.5, minf(1.0, 8.0 * dt))
	else:
		# AC-0145 P1: gravity = -up * GRAV (the same 26.0 constant, the felt
		# strength is unchanged): the world-space gravity mapped into the
		# frame — local -Y within the slew residual, exact in a converged
		# frame (was: the column facet's local -Y).
		# AC-0145 P2: scaled by (1 - band) — full gravity at the surface,
		# zero above the atmosphere (the 6-DOF band is thrust, not weight).
		# band = 0 at the surface, so the felt strength is unchanged on foot.
		var gs: float = 1.0 - band
		if gs > 1e-6:
			vloc += b.transposed() * (-_up * GRAV * gs * dt)
		if not cg and Input.is_action_pressed("jump") and is_on_floor():
			vloc.y = JUMP
			fall_start = -1.0
	velocity = b * vloc
	# AC-0267: EDGE GUARD - crouched on the ground: if the block under the
	# forward edge (0.45 ahead of the center along the INTENDED direction,
	# at foot level) is air, strip the velocity's component along that
	# direction. The player stops at the edge (the clamp is on the velocity
	# itself, not the target - no drift into the void); backing up and
	# sliding along the edge keep their components.
	if crouched and not flying and is_on_floor() and (absf(tx) > 0.001 or absf(tz) > 0.001):
		var f := Vector2(tx, tz)
		var fl := f.length()
		if fl > 0.001:
			f = f / fl
			# AC-0308: probe the forward edge in the player's LOCAL frame
			# (tangent-plane horizontal) and read the block in FLAT coords
			# (the grid is the flat net — the global read stopped agreeing
			# a few hundred metres from the pole).
			var probe: Vector3 = position + b * Vector3(f.x * 0.45, -0.1, f.y * 0.45)
			# AC-0309 C5: sim-routed (the face world's grid is the face
			# cell frame; the probe cell is resolved in that frame).
			var ep: Vector3i = _sim_probe_cell(probe.x, probe.y, probe.z)
			var edge_open: bool = Game.world == null or _sim_get_block(ep.x, ep.y, ep.z) == 0
			if edge_open:
				var comp := Vector2(vloc.x, vloc.z).dot(f)
				if comp > 0.0:
					vloc.x -= f.x * comp
					vloc.z -= f.y * comp
					velocity = b * vloc
	var was_ground := is_on_floor()
	if flying:
		fall_start = -1.0
	elif not was_ground and velocity.y < 0.0 and fall_start < 0.0:
		fall_start = flat_h  # AC-0307: flat height (the local surface curves)
	# AC-0308: auto-step over the seam micro-step. The per-column rigid
	# placement (AC-0307) leaves an irreducible folded-net residual of up
	# to 5.4 cm between adjacent columns' top faces along the shared edge
	# (in-band, the +/-320 m window); CharacterBody3D has no step offset,
	# so a walker is stopped dead at every seam. Nudge the capsule onto a
	# forward step of at most AUTO_STEP — measured in GLOBAL y (the exact
	# physical rise); a real 1 m terrain step stays a wall (jumped, as
	# before). The nudge lands the feet ~2 cm above the step top; gravity
	# settles them.
	if not flying and is_on_floor() and Game.world != null and (absf(tx) > 0.001 or absf(tz) > 0.001):
		var ff := Vector2(tx, tz)
		var fl := ff.length()
		if fl > 0.001:
			ff = ff / fl
			var fpos: Vector3 = position + b * Vector3(ff.x * 0.6, 0.0, ff.y * 0.6)
			if int(_anchor.get("face", 0)) > 1:
				# AC-0309 C5: the face world — the forward CELL (the anchor's
				# cell frame; the in-plane axes per cell width, y unscaled
				# metres). The face grid's 6 m resolution means terrain steps
				# up to ~2-3 m: the step threshold is FACE_STEP (1.0 m, vs
				# the home 0.5 m seam lip) and the jump (1.35 m) covers the
				# rest.
				var p: Vector3 = fpos - _anchor["origin"]
				var bx: Vector3 = _anchor["basis"].x
				var bn: Vector3 = _anchor["basis"].y
				var bz: Vector3 = _anchor["basis"].z
				var sc: Vector2 = _anchor["scale"]
				var pc: Vector3 = Vector3(p.dot(bx) / sc.x, p.dot(bn), p.dot(bz) / sc.y)
				var fx2 := int(floorf(pc.x))
				var fz2 := int(floorf(pc.z))
				var ftop: int = Game.world.surface_top_key(int(_anchor["face"]), fx2, fz2)
				var step_h: float = float(ftop) - pc.y
				if step_h > 0.001 and step_h <= FACE_STEP:
					var head_cell: int = Game.world.get_block_key(int(_anchor["face"]), fx2, fz2, ftop + 2)
					var head_solid := head_cell != 0 and Data.block(head_cell) != null and bool(Data.block(head_cell).solid)
					if not head_solid:
						position += b * Vector3(0.0, step_h + 0.02, 0.0)
			else:
				var fp2: Vector3 = Game.world.flat_of_world_pos(fpos)
				var fx2 := int(floorf(fp2.x))
				var fz2 := int(floorf(fp2.z))
				var ftop: int = Game.world.surface_top(fx2, fz2)
				# the forward ground top EXACTLY ahead (flat→world is an exact
				# inverse, 0.17 mm) — the physical rise the capsule will meet
				var fwd_g: Vector3 = Game.world.world_pos_of_flat(fp2.x, float(ftop) + 1.0, fp2.z)
				var step_h := fwd_g.y - position.y
				# the residual varies continuously along the fold (down to sub-mm);
				# ANY positive step under 0.5 m is stepped (sub-mm false positives
				# from the conversion noise are harmless — the nudge just settles)
				if step_h > 0.001 and step_h <= 0.5:
					# head clearance above the step (capsule ~1.8 m)
					var head_cell: int = Game.world.get_block(fx2, ftop + 2, fz2)
					var head_solid := head_cell != 0 and Data.block(head_cell) != null and bool(Data.block(head_cell).solid)
					if not head_solid:
						position += b * Vector3(0.0, step_h + 0.02, 0.0)
	move_and_slide()
	# AC-0039: step SFX — distance cadence: one "step" per STEP_DIST metres
	# of TANGENT-plane travel. vloc is the local (radial-up) frame, so no
	# world axis is assumed — sphere-safe by construction.
	if is_on_floor() and not flying and not in_water and not in_lava:
		_step_acc += Vector2(vloc.x, vloc.z).length() * dt
		if _step_acc >= STEP_DIST:
			_step_acc = 0.0
			Audio.play("step")
	else:
		_step_acc = 0.0
	# AC-0276: the sprint FOV kick (+10% while effectively sprinting on
	# the ground OR while flying - the air sprint cue, lerp ~0.15 s;
	# reverts when the sprint ends / on landing).
	if camera != null:
		if _base_fov < 0.0:
			_base_fov = camera.fov
		var fov_t: float = _base_fov * 1.10 if (sprint_eff or flying) else _base_fov
		camera.fov = lerpf(camera.fov, fov_t, minf(1.0, dt / 0.15))
	# AC-0267: lerp the eye height (camera) and the capsule (feet stay at
	# the origin - the shape node rides height/2). ~0.1 s both ways.
	if camera != null:
		camera.position.y = lerpf(camera.position.y, CROUCH_EYE if crouched else EYE, minf(1.0, 10.0 * dt))
	if col_shape != null and col_shape.shape is CapsuleShape3D:
		var cap_h_t: float = CAP_H_CROUCH if crouched else CAP_H
		var cap: CapsuleShape3D = col_shape.shape
		if absf(cap.height - cap_h_t) > 0.005:
			cap.height = cap_h_t
			col_shape.position.y = cap_h_t / 2.0
	if not flying and is_on_floor() and not was_ground and fall_start >= 0.0:
		var fall := fall_start - flat_h  # AC-0307: flat heights both ends
		if fall > 3.5:
			damage_player(floorf(fall - 3.0), "fall")
		fall_start = -1.0
	_recenter()
	_update_interaction(dt)
	if flat_h < -12.0:  # AC-0307: the void is below the LOCAL surface
		damage_player(100.0, "void")
	if in_lava:
		lava_t += dt
		if lava_t > 0.5:
			lava_t = 0.0
			damage_player(4.0, "lava")
	else:
		lava_t = 0.0
	# AC-0145 P3: the head offset is along the LOCAL up (the continuous
	# basis), not world +Y — the two agree on the home face and diverge
	# as the radial tilts (a +Y offset reads a cell off the head).
	var _head_w: Vector3 = position + basis.y * (camera.position.y if camera != null else EYE)
	var head_in_water := _block_at(_head_w.x, _head_w.y, _head_w.z) == 5
	if head_in_water and not flying:
		air = maxf(0.0, air - dt)
		if air <= 0.0:
			drown_t += dt
			if drown_t > 2.0:
				drown_t = 0.0
				damage_player(2.0, "drown")
		else:
			drown_t = 0.0
	else:
		air = minf(10.0, air + dt * 2.0)
		drown_t = 0.0
	var hungry := bool(Settings.values["hunger_enabled"])
	if hungry:
		if not flying and is_on_floor() and not cg and Input.is_key_pressed(KEY_SHIFT):
			hunger = maxf(0.0, hunger - dt * 0.06)
	else:
		hunger = 20.0
		_starve_t = 0.0
	if hunger > 18.0 and hp < 20.0:
		_regen_t += dt
		if _regen_t >= 2.0:
			_regen_t = 0.0
			hp = minf(20.0, hp + 1.0)
	else:
		_regen_t = 0.0
	if hungry and hunger <= 0.0:
		_starve_t += dt
		if _starve_t >= 4.0:
			_starve_t = 0.0
			damage_player(1.0, "starve")
	else:
		_starve_t = 0.0
	# AC-0383: the per-step census (which model ran this physics step — the
	# band blend value + the flying flag; the guard/bracket read these).
	if ac0383_guard:
		_ac0383_play_n += 1
		if flying:
			_ac0383_fly_n += 1
		_ac0383_band_now = band
		if band > 0.001:
			_ac0383_band_n += 1
	if _debug_label.visible:
		_update_debug_label()


# --- AC-0383: the movement-model (6-DOF flight path) per-step bracket ---
# Env-gated (AWECRAFT_AC0383, the world's _ac0383_init is the same value —
# the player reads it itself because _ready order is not guaranteed):
# unset = off (zero cost, pristine behavior); "1" = on; "blind" = guard
# armed, bracket disabled (the negative test — must trip visibly).
var ac0383_on := false
var ac0383_guard := false
var _ac0383_n := 0
var _ac0383_play_n := 0
var _ac0383_fly_n := 0
var _ac0383_band_n := 0
var _ac0383_band_now := 0.0
var _ac0383_us_total := 0
var _ac0383_us_max := 0
var _ac0383_ring: Array = []   # AC0383_RING entries [t_ms, us] (pre-allocated)
var _ac0383_head := 0
var _ac0383_worst: Array = []  # worst-20 [t_ms, us, fly, band01] (pre-allocated)
var _ac0383_blind_n := 0
var _ac0383_guard_tripped := false
const AC0383_RING := 8192
const AC0383_WORST_N := 20

func _ac0383_player_init() -> void:
	var e := OS.get_environment("AWECRAFT_AC0383")
	ac0383_on = e == "1"
	ac0383_guard = ac0383_on or e == "blind"
	_ac0383_ring.clear()
	for i in range(AC0383_RING):
		_ac0383_ring.append([0, 0])
	_ac0383_worst.clear()
	for i in range(AC0383_WORST_N):
		_ac0383_worst.append([0, 0, 0, 0])

func _ac0383_player_add(us: int) -> void:
	_ac0383_n += 1
	_ac0383_us_total += us
	if us > _ac0383_us_max:
		_ac0383_us_max = us
	var t := Time.get_ticks_msec()
	_ac0383_ring[_ac0383_head][0] = t
	_ac0383_ring[_ac0383_head][1] = us
	_ac0383_head = (_ac0383_head + 1) % AC0383_RING
	if _ac0383_worst.size() < AC0383_WORST_N:
		_ac0383_worst.append([t, us, int(flying), int(_ac0383_band_now > 0.001)])
	else:
		var mi := 0
		for i in range(1, AC0383_WORST_N):
			if int(_ac0383_worst[i][1]) < int(_ac0383_worst[mi][1]):
				mi = i
		if us > int(_ac0383_worst[mi][1]):
			_ac0383_worst[mi][0] = t
			_ac0383_worst[mi][1] = us
			_ac0383_worst[mi][2] = int(flying)
			_ac0383_worst[mi][3] = int(_ac0383_band_now > 0.001)

func _ac0383_pct(sorted_us: Array, p: float) -> float:
	if sorted_us.is_empty():
		return 0.0
	var i := int(floorf(p * float(sorted_us.size())))
	if i >= sorted_us.size():
		i = sorted_us.size() - 1
	return float(sorted_us[i])

# AC-0383: the stats snapshot (read once at run end by the boundary arm's
# RESULT, with the worst-20 arm-side frame windows for the per-window sums).
func ac0383_stats(windows: Array) -> Dictionary:
	var seen := mini(_ac0383_n, AC0383_RING)
	var us_vals: Array = []
	for i in range(seen):
		us_vals.append(float(_ac0383_ring[(_ac0383_head - seen + i + AC0383_RING) % AC0383_RING][1]))
	us_vals.sort()
	var pwin: Dictionary = {}
	for w in windows:
		var t0: int = int(w[0])
		var t1: int = t0 + int(w[1])
		var s := 0
		var k := 0
		for i in range(seen):
			var e: Array = _ac0383_ring[(_ac0383_head - seen + i + AC0383_RING) % AC0383_RING]
			if int(e[0]) >= t0 and int(e[0]) < t1:
				s += int(e[1])
				k += 1
		pwin[t0] = [int(s), int(k)]
	var worst: Array = []
	for e in _ac0383_worst:
		worst.append({"t_ms": int(e[0]), "us_ms": roundf(float(e[1]) / 1000.0 * 100.0) / 100.0,
			"fly": int(e[2]), "band": int(e[3])})
	return {
		"n": int(_ac0383_n),
		"play_n": int(_ac0383_play_n),
		"fly_n": int(_ac0383_fly_n),
		"band_n": int(_ac0383_band_n),
		"sum_ms": roundf(float(_ac0383_us_total) / 1000.0 * 10.0) / 10.0,
		"p50_ms": roundf(_ac0383_pct(us_vals, 0.50) / 1000.0 * 100.0) / 100.0,
		"p95_ms": roundf(_ac0383_pct(us_vals, 0.95) / 1000.0 * 100.0) / 100.0,
		"max_ms": roundf(float(_ac0383_us_max) / 1000.0 * 100.0) / 100.0,
		"per_window_us": pwin,
		"blind_guard": {"blind_frames": int(_ac0383_blind_n), "tripped": bool(_ac0383_guard_tripped)},
		"worst": worst,
	}

func _init_inv() -> void:
	inv.clear()
	for i in INV_SIZE:
		inv.append({"id": 0, "n": 0})
	armor.clear()
	for i in ARMOR_SIZE:
		armor.append(0)
	craft_grid.clear()
	for i in CRAFT_GRID_SIZE:
		craft_grid.append({"id": 0, "n": 0})
	table_grid.clear()
	for i in CRAFT_GRID_SIZE:
		table_grid.append({"id": 0, "n": 0})
	held = {}
	craft_out = {}
	ui_mode = ""


# AC-0309: the highlight is a child of Game.world (see _build_highlight).
# The save round-trip / slot-continue path frees the world and spawns a
# fresh one while a player node can still be alive (queue_free is
# deferred; the continue path creates the new world in the same frame),
# so the stored reference can dangle and every aim frame hits
# "previously freed". Rebuilding is cheap (one 1-box MeshInstance3D) and
# re-attaches to the CURRENT world; never touch a freed node.
func _ensure_highlight() -> MeshInstance3D:
	if is_instance_valid(highlight):
		return highlight
	_build_highlight()
	return highlight


func _build_highlight() -> void:
	highlight = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(1.02, 1.02, 1.02)
	highlight.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.0, 0.0, 0.0, 0.28)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	highlight.material_override = mat
	highlight.visible = false
	if Game.world != null:
		Game.world.add_child(highlight)
	else:
		add_child(highlight)


func _build_held() -> void:
	if camera == null:
		return
	sway_root = Node3D.new()
	sway_root.position = HAND_BASE_POS
	camera.add_child(sway_root)
	hand_root = Node3D.new()
	sway_root.add_child(hand_root)
	var mesh := BoxMesh.new()
	held_box = MeshInstance3D.new()
	held_box.mesh = mesh
	var hbmat := StandardMaterial3D.new()
	hbmat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	# AC-0097: depth_draw_mode only stops the depth WRITE; no_depth_test is
	# what skips the depth TEST (AC-0067 set only the former, so the viewmodel
	# was still occluded by the world).
	hbmat.no_depth_test = true
	held_box.material_override = hbmat
	held_box.scale = Vector3.ONE * HELD_ITEM_SCALE
	held_box.position = Vector3.ZERO
	held_box.visible = false
	hand_root.add_child(held_box)
	held_sprite = Sprite3D.new()
	held_sprite.scale = Vector3.ONE * HELD_ITEM_SCALE  # AC-0097: matches the held block (0.33)
	held_sprite.billboard = 1
	held_sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	held_sprite.no_depth_test = true
	held_sprite.visible = false
	hand_root.add_child(held_sprite)
	var fm := BoxMesh.new()
	fm.size = Vector3(0.18, 0.3, 0.24)
	held_fist = MeshInstance3D.new()
	held_fist.mesh = fm
	var fmat := StandardMaterial3D.new()
	fmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fmat.albedo_color = Color(0.87, 0.73, 0.57)
	fmat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	fmat.no_depth_test = true # AC-0097: see the hbmat note above
	held_fist.material_override = fmat
	_vm_mats.append([fmat, fmat.albedo_color])
	held_fist.position = Vector3(0.0, -0.05, 0.0)
	held_fist.visible = false
	hand_root.add_child(held_fist)
	held_tool = Node3D.new()
	held_tool.visible = false
	hand_root.add_child(held_tool)


func _update_held(id: int, n: int) -> void:
	var show_fist := ui_mode == "" and (id == 0 or n <= 0)
	if held_fist != null:
		held_fist.visible = show_fist
	if held_box != null:
		held_box.visible = false
	if held_sprite != null:
		held_sprite.visible = false
	if held_tool != null:
		held_tool.visible = false
	if id == 0 or n <= 0:
		return
	var binfo = Data.block(id)
	if binfo != null:
		if bool(binfo.get("cross", false)) and not bool(binfo.get("thin", false)):
			held_box.mesh = HeldMeshes.cross_mesh(id)
			held_box.material_override = _vm_kind_mat("cross", HeldMeshes.cross_material())
		else:
			held_box.mesh = HeldMeshes.box_mesh(id)
			held_box.material_override = _vm_kind_mat("box", HeldMeshes.box_material())
		held_box.position = Vector3(0.0, 0.0, -0.18)
		held_box.visible = true
		return
	var it = Data.items.get(id)
	var tool_type := ""
	if it != null and it.has("tool"):
		tool_type = String(it["tool"])
	if tool_type in ["pick", "axe", "shovel", "sword"]:
		_setup_held_tool(id, tool_type)
	elif it != null:
		var irect := Data.item_rect(id)
		if irect != Vector2i(-1, -1) and Data.item_atlas_tex != null and Data.item_atlas_tex.get_image() != null:
			held_sprite.texture = _item_atlas_tex(id)
		else:
			held_sprite.texture = _tint_tex(Data.item_tint(id))
		if _vm_sprite_mat == null:
			_vm_sprite_mat = StandardMaterial3D.new()
			_vm_sprite_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			# AC-0097: the Sprite3D node's no_depth_test does NOT stop the
			# depth test in this build (wallshot arm: the diamond sprite was
			# fully occluded by the wall while the box/fist materials with
			# material-level no_depth_test rendered on top) - the test has
			# to be disabled on the MATERIAL, same as the box/fist/tool.
			# DEPTH_DRAW_DISABLED stops the depth WRITE (AC-0067).
			_vm_sprite_mat.no_depth_test = true
			_vm_sprite_mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
			_vm_mats.append([_vm_sprite_mat, Color.WHITE])
		# AC-0097: a material_override DISCARDS the Sprite3D's internal
		# texture binding (the held diamond rendered as a flat WHITE quad -
		# wallshot arm). The override material must carry the tile itself.
		_vm_sprite_mat.albedo_texture = held_sprite.texture
		held_sprite.material_override = _vm_sprite_mat
		held_sprite.visible = true


func _vm_kind_mat(kind: String, src: Material) -> StandardMaterial3D:
	var m = _vm_box_mats.get(kind)
	if m == null:
		m = (src as StandardMaterial3D).duplicate()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		# AC-0035: the held-box source material (HeldMeshes._base_mat) uses
		# vertex_color_use_as_albedo, which in 4.7.1 darkens the textured box
		# to near-invisibility (VMFORCE A/B: textured+vertex avg 10 vs 25). The
		# viewmodel modulates albedo_color per-frame for light (R3), so use the
		# plain albedo_color x texture path (proven visible, L-modulated).
		m.vertex_color_use_as_albedo = false
		_vm_box_mats[kind] = m
		_vm_mats.append([m, (m as StandardMaterial3D).albedo_color])
	return m


func _vm_register_mat(m: Material, base: Color) -> void:
	if m is StandardMaterial3D:
		for ent in _vm_mats:
			if ent[0] == m:
				return
		_vm_mats.append([m, base])


func vm_refresh(force: bool = false) -> void:
	if _vm_mats.is_empty():
		return
	var day := DayNight.day(Game.time_of_day)
	# AC-0308: the light grid is FLAT (per-column local space) — convert
	# the eye's world position before sampling.
	# AC-0145 P3: the eye offset is along the LOCAL up (the continuous
	# basis), not world +Y (the hand sample follows the head on every face).
	var _eye_w: Vector3 = position + basis.y * (camera.position.y if camera != null else EYE)
	var _eye_f: Vector3 = Game.world.flat_of_world_pos(_eye_w) if Game.world != null else _eye_w
	var eye := Vector3i(int(floorf(_eye_f.x)), int(floorf(_eye_f.y)), int(floorf(_eye_f.z)))
	var now := Time.get_ticks_msec()
	if force or eye != _vm_eye_cell or now - _vm_light_ms >= 500:
		var w = Game.world
		# AC-0309 C5 (v1): the light_at pull is home-grid; on the face
		# world the viewmodel rides its floor (the lvm formula below keeps
		# it lit by the player light) — the face MESH light is the real
		# pull (build_mesh_face), so the terrain around the hand is
		# correctly lit even though the hand sample is the floor.
		if w != null and int(_anchor.get("face", 0)) <= 1:
			var l: Dictionary = w.light_at(eye.x, eye.y, eye.z)
			_vm_sky = float(l.sky)
			_vm_blk = float(l.block)
		else:
			_vm_sky = 0.0
			_vm_blk = 0.0
		_vm_eye_cell = eye
		_vm_light_ms = now
	var lvm := 0.20 + 0.80 * maxf(day * _vm_sky / 15.0, _vm_blk / 15.0)
	lvm = maxf(lvm, 0.12 + 0.88 * minf(PLAYER_LIGHT_LEVEL, 15.0) / 15.0)
	_vm_L = lvm
	for ent in _vm_mats:
		# Color * scalar would also scale alpha (GDScript) — RGB only, keep opaque.
		var bc := ent[1] as Color
		(ent[0] as StandardMaterial3D).albedo_color = Color(bc.r * lvm, bc.g * lvm, bc.b * lvm, 1.0)


func _item_atlas_tex(id: int) -> ImageTexture:
	var t = _held_item_texs.get(id)
	if t != null:
		return t
	var r := Data.item_rect(id)
	var img := Data.item_atlas_tex.get_image().get_region(Rect2i(r, Vector2i(Data.TILE_PX, Data.TILE_PX)))
	t = ImageTexture.create_from_image(img)
	_held_item_texs[id] = t
	return t


func _tint_tex(col: Color) -> ImageTexture:
	var k := col.to_html()
	var t = _held_texs.get(k)
	if t != null:
		return t
	var img := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(col)
	t = ImageTexture.create_from_image(img)
	_held_texs[k] = t
	return t


const TOOL_POSE_ROT := Vector3(0.632, 2.639, -0.2)
const TOOL_POSE_POS := Vector3(0.2, -0.3, 0.0)


const TOOL_GRIDS := {
	"pick": [
		"................................",
		"................................",
		"................................",
		"................................",
		"................................",
		"...........#########............",
		"..........#############.........",
		"...........#############hh......",
		".............###########hhh.....",
		"...................######hh.....",
		".....................hh####.....",
		"....................hhhh####....",
		"...................hhhhh####....",
		"..................hhhhh.####....",
		".................hhhhh..#####...",
		"................hhhhh....####...",
		"...............hhhhh.....####...",
		"..............hhhhh......####...",
		".............hhhhh.......####...",
		"............hhhhh........####...",
		"...........hhhhh.........####...",
		"..........hhhhh...........###...",
		".........hhhhh............###...",
		"........hhhhh..............#....",
		".......hhhhh....................",
		"......hhhhh.....................",
		".....hhhhh......................",
		"....hhhhh.......................",
		"....hhhh........................",
		".....hh.........................",
		"................................",
		"................................"
	],
	"axe": [
		"................................",
		"................................",
		"................................",
		"...................###..........",
		"..................#####.........",
		".................######.........",
		"................#######.........",
		"...............########.........",
		"..............#########.........",
		".............#########hh........",
		".............###########h.......",
		".............###########h#......",
		"..............#####h#######.....",
		"..................hh#######.....",
		".................hhhhh#####.....",
		"................hhhhh#####......",
		"...............hhhhh..###.......",
		"..............hhhhh.............",
		".............hhhhh..............",
		"............hhhhh...............",
		"...........hhhhh................",
		"..........hhhhh.................",
		".........hhhhh..................",
		"........hhhhh...................",
		".......hhhhh....................",
		"......hhhhh.....................",
		".....hhhhh......................",
		"....hhhhh.......................",
		"....hhhh........................",
		".....hh.........................",
		"................................",
		"................................"
	],
	"shovel": [
		"................................",
		"................................",
		"................................",
		"................................",
		".......................#####....",
		"......................#######...",
		".....................#########..",
		"....................##########..",
		"...................###########..",
		"..................############..",
		".................#############..",
		"..................###########...",
		"...................h########....",
		"..................hhh######.....",
		".................hhhhh####......",
		"................hhhhh.###.......",
		"...............hhhhh...#........",
		"..............hhhhh.............",
		".............hhhhh..............",
		"............hhhhh...............",
		"...........hhhhh................",
		"..........hhhhh.................",
		".........hhhhh..................",
		"........hhhhh...................",
		".......hhhhh....................",
		"....hhhhhhh.....................",
		"....hhhhhh......................",
		"....hhhhh.......................",
		".....hhhh.......................",
		"......hhh.......................",
		"................................",
		"................................"
	],
	"sword": [
		"............................####",
		"...........................#####",
		"..........................######",
		".........................#######",
		"........................#######.",
		".......................#######..",
		"......................#######...",
		".....................#######....",
		"....................#######.....",
		"...................#######......",
		"..................#######.......",
		".................#######........",
		"................#######.........",
		"...............#######..........",
		"....###.......#######...........",
		"....####.....#######............",
		"....#####...#######.............",
		".....#####.#######..............",
		"......###########...............",
		"......##########................",
		"......#########.................",
		".......#######..................",
		".......h#######.................",
		"......hhh#######................",
		".....hhhhh#######...............",
		"....hhhhh..#######..............",
		"...hhhhh......####..............",
		".##hhhh........###..............",
		"####hh..........................",
		"#####...........................",
		"#####...........................",
		".###............................"
	],
}


func _tool_part_mesh(centers: Array, s: Vector3) -> Mesh:
	var v := PackedVector3Array()
	var idx := PackedInt32Array()
	var faces := [
		[0, 3, 2, 0, 2, 1],
		[4, 5, 6, 4, 6, 7],
		[1, 2, 6, 1, 6, 5],
		[0, 4, 7, 0, 7, 3],
		[3, 7, 6, 3, 6, 2],
		[0, 1, 5, 0, 5, 4],
	]
	for ctr in centers:
		var c: Vector3 = ctr
		var cs := [
			c + Vector3(-s.x, -s.y, -s.z),
			c + Vector3(s.x, -s.y, -s.z),
			c + Vector3(s.x, s.y, -s.z),
			c + Vector3(-s.x, s.y, -s.z),
			c + Vector3(-s.x, -s.y, s.z),
			c + Vector3(s.x, -s.y, s.z),
			c + Vector3(s.x, s.y, s.z),
			c + Vector3(-s.x, s.y, s.z),
		]
		var base := v.size()
		for fv in cs:
			v.append(fv)
		for f in faces:
			for k in 6:
				idx.append(base + int(f[k]))
	var arrs: Array = []
	arrs.resize(Mesh.ARRAY_MAX)
	arrs[Mesh.ARRAY_VERTEX] = v
	arrs[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrs)
	return m


func _voxel_mat(color: Color) -> StandardMaterial3D:
	var k := color.to_html()
	var m = _tool_mats.get(k)
	if m != null:
		return m
	m = StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = color
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	m.no_depth_test = true # AC-0097: tool voxels always on top (see _build_held)
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	_tool_mats[k] = m
	return m


func _setup_held_tool(id: int, type: String) -> void:
	var tcolor := Data.item_tint(id)
	for c in held_tool.get_children():
		held_tool.remove_child(c)
		c.queue_free()
	var grid: Array = TOOL_GRIDS[type]
	var min_i := 32
	var max_i := -1
	var min_j := 32
	var max_j := -1
	for j in 32:
		var row: String = grid[j]
		for i in 32:
			if row[i] != ".":
				min_i = mini(min_i, i)
				max_i = maxi(max_i, i)
				min_j = mini(min_j, j)
				max_j = maxi(max_j, j)
	var bw := max_i - min_i + 1
	var bh := max_j - min_j + 1
	var center_i := (float(min_i) + float(max_i) + 1.0) * 0.5
	var center_j := (float(min_j) + float(max_j) + 1.0) * 0.5
	var target: float = TOOL_TARGET_DIAG[type]
	var diag_cells: float = (float(bw) * float(bw) + float(bh) * float(bh) + 1.0) ** 0.5
	var vox := target / diag_cells
	var half := Vector3(vox * 0.5, vox * 0.5, vox * 0.5)
	var head_cells: Array = []
	var handle_cells: Array = []
	for j in 32:
		var row: String = grid[j]
		for i in 32:
			var ch: String = row[i]
			if ch == ".":
				continue
			var ctr := Vector3((float(i) - center_i) * vox, (center_j - float(j)) * vox, 0.0)
			if ch == "#":
				head_cells.append(ctr)
			else:
				handle_cells.append(ctr)
	var head_mi := MeshInstance3D.new()
	head_mi.name = "head"
	head_mi.mesh = _tool_part_mesh(head_cells, half)
	head_mi.material_override = _voxel_mat(tcolor)
	held_tool.add_child(head_mi)
	var handle_mi := MeshInstance3D.new()
	handle_mi.name = "handle"
	handle_mi.mesh = _tool_part_mesh(handle_cells, half)
	handle_mi.material_override = _voxel_mat(HANDLE_C)
	held_tool.add_child(handle_mi)
	_vm_register_mat(head_mi.material_override, tcolor)
	_vm_register_mat(handle_mi.material_override, HANDLE_C)
	_tool_voxel_count = head_cells.size() + handle_cells.size()
	_tool_diag = target
	held_tool_type = type
	held_tool.position = TOOL_POSE_POS
	held_tool.rotation = TOOL_POSE_ROT
	held_tool.visible = true


func held_tool_voxel_count() -> int:
	return _tool_voxel_count


func held_tool_diag() -> float:
	return _tool_diag


func held_head_color() -> Color:
	if held_tool == null:
		return Color()
	for c in held_tool.get_children():
		if c is MeshInstance3D and c.name == "head":
			var m = (c as MeshInstance3D).material_override
			if m is StandardMaterial3D:
				return (m as StandardMaterial3D).albedo_color
	return Color()


func swing(kind: int) -> void:
	_swing_active = true
	_swing_held = false
	_swing_t = 0.0
	_swing_kind = int(kind)


func swing_kind_for_selected() -> int:
	var it: Dictionary = inv_selected()
	if int(it["id"]) == 0 or int(it["n"]) <= 0:
		return SWING_PUNCH
	return SWING_ITEM


func start_swing() -> void:
	swing(swing_kind_for_selected())


func hold_swing(frac: float, kind: int = -1) -> void:
	_swing_active = true
	_swing_held = true
	_swing_frac = clampf(float(frac), 0.0, 1.0)
	_swing_kind = int(kind) if kind >= 0 else swing_kind_for_selected()


func clear_swing() -> void:
	_swing_active = false
	_swing_held = false
	_swing_loop = false
	_swing_t = 0.0
	_swing_frac = 0.0
	if hand_root != null:
		_reset_hand_pose()


func swing_frac() -> float:
	if not _swing_active:
		return 0.0
	return _swing_frac if _swing_held else minf(_swing_t / SWING_DURATION, 1.0)


func swing_active() -> bool:
	return _swing_active


func _update_swing_loop() -> void:
	# AC-0266: a HELD right trigger loops the swing exactly like a held
	# LMB (_pad_mining is the RT hold state, hysteresis 0.5/0.35) - the
	# hit trace keeps running either way (mining ticks per frame in the
	# _mining state; mob/bow hits are one-per-press, as with the mouse).
	var want_loop := Game.mode == "play" and ui_mode == "" and not dead \
		and (_lmb_down or _pad_mining) and not _swing_held
	if want_loop:
		if not _swing_active:
			_swing_active = true
			_swing_t = 0.0
			_swing_kind = swing_kind_for_selected()
		_swing_loop = true
	elif _swing_loop:
		clear_swing()


func _update_swing(dt: float) -> void:
	if not _swing_active:
		return
	var frac: float
	if _swing_held:
		frac = _swing_frac
	else:
		_swing_t += dt
		frac = _swing_t / SWING_DURATION
	if frac >= 1.0:
		if _swing_loop:
			_swing_t = fmod(_swing_t, SWING_DURATION)
		else:
			_swing_active = false
			_swing_t = 0.0
			_reset_hand_pose()
			return
	_apply_swing(clampf(frac, 0.0, 1.0))


func _apply_swing(frac: float) -> void:
	var a := sin(frac * PI)
	if frac <= 0.0:
		_reset_hand_pose()
		return
	if _swing_kind == SWING_PUNCH:
		hand_root.position = Vector3.ZERO
		hand_root.rotation = Vector3(-0.45 * a, 0.0, 0.0)
	else:
		hand_root.position = Vector3.ZERO
		hand_root.rotation = Vector3(-0.85 * a, 0.0, -0.12 * a)


func _reset_hand_pose() -> void:
	if hand_root == null:
		return
	hand_root.position = Vector3.ZERO
	hand_root.rotation = Vector3.ZERO


func hand_pose_offset() -> Vector3:
	if sway_root == null or hand_root == null:
		return Vector3.ZERO
	return sway_root.position + hand_root.position - HAND_BASE_POS


func hand_pose_rot() -> Vector3:
	if hand_root == null:
		return Vector3.ZERO
	return hand_root.rotation


func sway_bobs() -> float:
	return _sway_bobs


func _update_sway(dt: float) -> void:
	if sway_root == null or hand_root == null:
		return
	var hspeed := Vector2(velocity.x, velocity.z).length()
	_sway_speed = lerpf(_sway_speed, hspeed, minf(1.0, SWAY_SMOOTH * dt))
	if hspeed > 0.05:
		var step := hspeed * dt * SWAY_PHASE_K
		_sway_phase = fmod(_sway_phase + step, 1.0)
		_sway_bobs += step
	var amp := clampf(_sway_speed / WALK, 0.0, 1.0)
	var off := Vector3(SWAY_AMP_X * amp * sin(_sway_bobs * PI), SWAY_AMP_Y * amp * sin(_sway_phase * TAU), 0.0)
	sway_root.position = HAND_BASE_POS + off


func aim_dir() -> Vector3:
	# AC-0145 P1: the camera's WORLD direction — the live basis (the
	# accumulated continuous frame: the radial alignment + the baked look
	# yaw) times the camera pitch, applied to the aim axis. Computed from
	# the stored yaw/pitch + the basis (no transform-lag frame — the basis
	# is updated in _sphere_align on the physics frame, the same source the
	# camera rides).
	return (basis * (Basis.from_euler(Vector3(_pitch, 0.0, 0.0)) * Vector3(0.0, 0.0, -1.0))).normalized()


func aim_hit() -> Dictionary:
	if Game.world == null:
		return {"hit": false, "cell": Vector3i.ZERO, "id": 0, "normal": Vector3i.ZERO, "t": 0.0}
	# AC-0307: the DDA queries the FLAT block API; the camera sits in the
	# placed global frame — the ray runs in the local flat frame.
	# AC-0309 C5: past the patch edge the ray runs in the face chunk's
	# CELL frame (the in-plane axes per cell width) against the face block
	# API — the same DDA (core/math.gd is resolution-agnostic).
	var fr: Dictionary = _flat_ray()
	if int(_anchor.get("face", 0)) > 1:
		var face: int = int(_anchor["face"])
		var cb := func(x: int, y: int, z: int) -> int: return Game.world.get_block_key(face, x, z, y)
		return VoxelMath.raycast_blocks(fr["o"], fr["d"], fr["reach"], cb)
	return VoxelMath.raycast_blocks(fr["o"], fr["d"], REACH, Game.world.get_block)


# AC-0307: the interaction rays (aim_hit, use_bucket) query the FLAT block
# API, but the camera is in the placed global frame. Convert the ray's
# origin + direction into the player's column flat frame (the rigid
# placement transform; the basis transposed maps directions).
# AC-0309 C5: past the patch edge the ray converts into the face chunk's
# CELL frame (metres / cell width per in-plane axis; y unscaled metres)
# with the reach rescaled to cell units (a reach of 6 m = ~0.97 face
# cells — the 6 m resolution of the face world).
func _flat_ray() -> Dictionary:
	if Game.world == null:
		return {"o": camera.global_position, "d": aim_dir(), "reach": REACH}
	if int(_anchor.get("face", 0)) > 1:
		var o: Vector3 = camera.global_position - _anchor["origin"]
		var bx: Vector3 = _anchor["basis"].x
		var bn: Vector3 = _anchor["basis"].y
		var bz: Vector3 = _anchor["basis"].z
		var sc: Vector2 = _anchor["scale"]
		var ad: Vector3 = aim_dir()
		var dcells: Vector3 = Vector3(ad.dot(bx) / sc.x, ad.dot(bn), ad.dot(bz) / sc.y)
		return {
			"o": Vector3(o.dot(bx) / sc.x, o.dot(bn), o.dot(bz) / sc.y),
			"d": dcells.normalized(),
			"reach": REACH / dcells.length(),
		}
	var o: Vector3 = Game.world.flat_of_world_pos(camera.global_position)
	var cx := int(floorf(o.x / 16.0))
	var cz := int(floorf(o.z / 16.0))
	var tb: Basis = Game.world._col_sphere_transform(cx, cz).basis
	return {"o": o, "d": (tb.transposed() * aim_dir()).normalized(), "reach": REACH}


func start_mine() -> void:
	if _mining:
		return  # AC-0243: a re-press while mining (trigger jitter) must not reset progress
	var held = Data.items.get(int(inv_selected()["id"]))
	if held != null and str(held.get("tool", "")) == "bow":
		_fire_bow()
		start_swing()
		return
	var mob := aim_mob()
	if mob != null:
		attack_mob(mob)
		start_swing()
		return
	start_swing()
	_mining = true
	_mine_id = -1
	_mine_prog = 0.0


# AC-0191: placeholder bow - a hitscan (no projectile, no arrow
# consumption) over the same Game.entities scan the sword uses, at a 60 m
# bow range. The procedural gun picker is a follow-up once the weapon
# system exists.
func _fire_bow() -> void:
	# AC-0039: the string draw fires on every release (hit or not).
	Audio.play("bow")
	var held = Data.items.get(int(inv_selected()["id"]))
	var dmg := 1.0
	if held != null and float(held.get("dmg", 0)) > 0.0:
		dmg = float(held["dmg"])
	if Game.entities == null:
		return
	var o := camera.global_position
	var d := aim_dir()
	var best: Node3D = null
	var bt := 60.0
	for c in Game.entities.get_children():
		if not (c is Node3D) or not c.has_method("center"):
			continue
		var cc: Vector3 = c.center()
		var t := (cc - o).dot(d)
		if t < 0.0 or t > bt:
			continue
		if (o + d * t - cc).length() < 0.8 and t < bt:
			bt = t
			best = c
	if best != null and best.has_method("hurt"):
		best.hurt(dmg, position)
		Audio.play("hit")


# AC-0271: resolve the door PAIR containing `cell`. Returns
# {"ok": bool, "lo": Vector3i, "hi": Vector3i, "open": bool}; "ok" is
# false when the cell is not a door half or the pair is inconsistent
# (e.g. half torn out by a future editor tool) - callers must treat
# "ok": false as "not a door".
func _door_pair(cell: Vector3i) -> Dictionary:
	# AC-0309 C5: sim-routed (doors on the face world read the face grid).
	var id = int(_sim_get_block(int(cell.x), int(cell.y), int(cell.z)))
	var open: bool = id == DOOR_LO_OPEN or id == DOOR_HI_OPEN
	if id != DOOR_LO and id != DOOR_HI and not open:
		return {"ok": false, "lo": cell, "hi": cell, "open": false}
	var lo := cell
	if id == DOOR_HI or id == DOOR_HI_OPEN:
		lo = cell - Vector3i(0, 1, 0)
	var hi := lo + Vector3i(0, 1, 0)
	if open:
		return {"ok": _sim_get_block(lo.x, lo.y, lo.z) == DOOR_LO_OPEN \
			and _sim_get_block(hi.x, hi.y, hi.z) == DOOR_HI_OPEN, "lo": lo, "hi": hi, "open": true}
	return {"ok": _sim_get_block(lo.x, lo.y, lo.z) == DOOR_LO \
		and _sim_get_block(hi.x, hi.y, hi.z) == DOOR_HI, "lo": lo, "hi": hi, "open": false}


# AC-0271: toggle the door pair at `cell` (either half).
# AC-0309 C5: sim-routed (the face world's doors toggle in the face grid).
func _toggle_door(cell: Vector3i) -> void:
	var pr := _door_pair(cell)
	if not bool(pr["ok"]):
		return
	if bool(pr["open"]):
		_sim_set_block(int(pr["lo"].x), int(pr["lo"].y), int(pr["lo"].z), DOOR_LO)
		_sim_set_block(int(pr["hi"].x), int(pr["hi"].y), int(pr["hi"].z), DOOR_HI)
	else:
		_sim_set_block(int(pr["lo"].x), int(pr["lo"].y), int(pr["lo"].z), DOOR_LO_OPEN)
		_sim_set_block(int(pr["hi"].x), int(pr["hi"].y), int(pr["hi"].z), DOOR_HI_OPEN)
	Audio.play("door")


func aim_mob() -> Node3D:
	if Game.entities == null:
		return null
	if aim_hit().hit:
		return null
	var o := camera.global_position
	var d := aim_dir()
	var best: Node3D = null
	var bt := INF
	for c in Game.entities.get_children():
		if not (c is Node3D) or not c.has_method("center"):
			continue
		var cc: Vector3 = c.center()
		var t := (cc - o).dot(d)
		if t < 0.0 or t > REACH:
			continue
		if (o + d * t - cc).length() < 0.7 and t < bt:
			bt = t
			best = c
	return best


func attack_mob(mob: Node3D) -> void:
	var item = Data.items.get(int(inv_selected()["id"]))
	var dmg := 1.0
	if item != null and float(item.get("dmg", 0)) > 0.0:
		dmg = float(item["dmg"])
	mob.hurt(dmg, position)
	if bool(Settings.values["hunger_enabled"]):
		hunger = maxf(0.0, hunger - 0.5)
	Audio.play("hit")
	if mob.hp <= 0.0:
		mob.try_kill()


func release_mine() -> void:
	_mining = false
	_mine_id = -1
	_mine_prog = 0.0


func use_selected() -> void:
	var _ut := OS.get_environment("AWECRAFT_PADTRACE") == "1"
	if _ut:
		print("USETRACE in sel=%s item=%s" % [str(sel), str(inv_selected())])
	if Game.mode != "play" or Game.world == null:
		if _ut:
			print("USETRACE reject: mode/world")
		return
	var hit := aim_hit()
	if hit.hit and int(hit.id) == TABLE_ID:
		if _ut:
			print("USETRACE table")
		open_inventory("table")
		Game.set_cursor(Input.MOUSE_MODE_VISIBLE)
		return
	# AC-0271: interact with a door (either half, bare hand or holding
	# anything) = toggle open/closed. Checked before the no-item guard so
	# a bare hand works.
	if int(hit.id) == DOOR_LO or int(hit.id) == DOOR_HI \
			or int(hit.id) == DOOR_LO_OPEN or int(hit.id) == DOOR_HI_OPEN:
		_toggle_door(hit.cell)
		return
	var item: Dictionary = inv_selected()
	var sid := int(item["id"])
	if sid == 0 or int(item["n"]) <= 0:
		if _ut:
			print("USETRACE reject: no item sid=%s" % str(sid))
		return
	# AC-0037: use a BONE on a wolf = tame it (MC semantics: the tamed
	# wolf follows and no longer flees).
	if sid == 144:
		var mob = aim_mob()
		if mob != null and str(mob.key) == "wolf" and not mob.tamed:
			mob.tamed = true
			item["n"] = int(item["n"]) - 1
			Game.message("Wolf tamed")
			return
	var info = Data.items.get(sid)
	if info != null and info.has("food"):
		if _ut:
			print("USETRACE eating")
		eat_selected(info)
		return
	if info != null and info.has("bucket"):
		if _ut:
			print("USETRACE bucket")
		use_bucket(info)
		return
	if _ut:
		print("USETRACE -> place_item hit=%s" % str(hit))
	place_item(item)


func eat_selected(info: Dictionary) -> void:
	var hit := aim_hit()
	if not hit.hit:
		return
	if hp < 20.0 or hunger < 19.9:
		hp = minf(20.0, hp + float(info["food"]))
		hunger = minf(20.0, hunger + float(info["food"]))
		inv_consume_selected()
		# AC-0040: the sfx field (banana = "gorilla", via the AC-0039 sound
		# lane) defaults to the standard eat sound.
		Audio.play(str(info.get("sfx", "eat")))
	else:
		Game.message("Too full")


func place() -> void:
	if Game.mode != "play" or Game.world == null:
		return
	place_item(inv_selected())


func place_item(item: Dictionary) -> void:
	var _pt := OS.get_environment("AWECRAFT_PADTRACE") == "1"
	if _pt:
		print("PLACETRACE in id=%s sel=%s" % [str(item), str(inv_selected())])
	if int(item["id"]) == 0:
		return
	if Data.block(int(item["id"])) == null:
		if _pt:
			print("PLACETRACE reject: Data.block null")
		return
	var hit := aim_hit()
	if not hit.hit:
		if _pt:
			print("PLACETRACE reject: no hit")
		return
	var target: Vector3i = hit.cell + hit.normal
	if Game.world.get_block(target.x, target.y, target.z) != 0:
		if _pt:
			print("PLACETRACE reject: target not air %s" % str(Game.world.get_block(target.x, target.y, target.z)))
		return
	if _box_intersects_player(target):
		if _pt:
			print("PLACETRACE reject: box intersects player pos=%s target=%s" % [str(position), str(target)])
		return
	if _pt:
		print("PLACETRACE PLACING at %s" % str(target))
	# AC-0270: a placed leaf is a PERSISTENT leaf (id 30) - the
	# shears/Silk-Touch equivalent (AweCraft has no shears yet, so every
	# placed leaf carries the flag). Natural worldgen leaves (7) decay
	# when orphaned; these never do.
	var bid := int(item["id"])
	if bid == 7:
		bid = 30
	# AC-0271: a door is a PAIR - the bottom half on the target cell, the
	# top half one above. Minecraft parity: placement lands ON the aimed
	# block's face (target = hit cell + normal), so aiming at the ground
	# puts the door's feet on the ground; both cells must be air (2-high
	# air check) and neither may swallow the player.
	if bid == DOOR_LO:
		var above := target + Vector3i(0, 1, 0)
		if _sim_get_block(above.x, above.y, above.z) != 0:  # AC-0309 C5: sim-routed
			if _pt:
				print("PLACETRACE door reject: cell above not air %s" % str(above))
			return
		if _box_intersects_player(above):
			if _pt:
				print("PLACETRACE door reject: top cell intersects player")
			return
		_sim_set_block(target.x, target.y, target.z, DOOR_LO)  # AC-0309 C5: sim-routed
		_sim_set_block(above.x, above.y, above.z, DOOR_HI)
		inv_consume_selected()
		Audio.play("place")
		return
	_sim_set_block(target.x, target.y, target.z, bid)  # AC-0309 C5: sim-routed
	inv_consume_selected()
	Audio.play("place")


func use_bucket(info: Dictionary) -> void:
	# AC-0309 C5 (v1): the fluid sim is home-grid only — the bucket is a
	# no-op on the face world (the generated face fluids still render and
	# displace; placing/scooping there is the fluids ticket's scope).
	if Game.world != null and int(_anchor.get("face", 0)) > 1:
		return
	# AC-0307: the flat-frame ray (see _flat_ray) — get_block is flat.
	var frb: Dictionary = _flat_ray()
	var hit := VoxelMath.raycast_cell(frb["o"], frb["d"], REACH, Game.world.get_block, true)
	if not hit.hit:
		return
	var cell: Vector3i = hit.cell
	var hid := int(hit.id)
	var bid := int(info.get("bucket"))
	if bid == 0:
		if hid != 5 and hid != 24:
			return
		if _box_intersects_player(cell):
			return
		Game.world.set_fluid(cell.x, cell.y, cell.z, 0, 0)
		inv_consume_selected()
		inv_add(140 if hid == 5 else 141, 1)
		Audio.play("splash")
		return
	var target := cell + Vector3i(hit.normal)
	var cur: int = Game.world.get_block(target.x, target.y, target.z)
	if cur == bid:
		return
	var cinfo = Data.block(cur)
	var replaceable := cur == 0 or (cinfo != null and bool(cinfo.get("cross", false)) and not bool(cinfo.solid) and cur != 5 and cur != 24)
	if not replaceable:
		return
	if _box_intersects_player(target):
		return
	Game.world.set_fluid(target.x, target.y, target.z, bid, 8, true)
	inv_consume_selected()
	inv_add(139, 1)
	Audio.play("splash")


func _box_intersects_player(cell: Vector3i) -> bool:
	# AC-0307: the cell is FLAT; the player box must be too.
	var pp: Vector3 = Game.world.flat_of_world_pos(position) if Game.world != null else position
	var pmin := Vector3(pp.x - P_HALF, pp.y, pp.z - P_HALF)
	var pmax := Vector3(pp.x + P_HALF, pp.y + P_H, pp.z + P_HALF)
	var bmin := Vector3(float(cell.x), float(cell.y), float(cell.z))
	var bmax := bmin + Vector3.ONE
	return pmin.x < bmax.x and pmax.x > bmin.x and pmin.y < bmax.y and pmax.y > bmin.y and pmin.z < bmax.z and pmax.z > bmin.z


func _update_interaction(dt: float) -> void:
	var hl := _ensure_highlight()  # AC-0309: survives the world free/recreate
	if ui_mode != "":
		hl.visible = false
		return
	var hit := aim_hit()
	if hit.hit:
		hl.visible = true
		# AC-0307: the aimed cell is FLAT; the highlight node lives in the
		# placed global frame.
		if Game.world != null:
			hl.global_position = Game.world.world_pos_of_flat(float(hit.cell.x) + 0.5, float(hit.cell.y) + 0.5, float(hit.cell.z) + 0.5)
		else:
			hl.global_position = Vector3(float(hit.cell.x) + 0.5, float(hit.cell.y) + 0.5, float(hit.cell.z) + 0.5)
	else:
		hl.visible = false
		if _mining:
			_mine_id = -1
			_mine_prog = 0.0
	if not _mining or not hit.hit:
		return
	var info = Data.block(int(hit.id))
	if info == null or float(info.get("hard", 1e9)) >= 1e8:
		return
	if hit.cell != _mine_cell or int(hit.id) != _mine_id:
		_mine_cell = hit.cell
		_mine_id = int(hit.id)
		_mine_prog = 0.0
	var held_item = Data.items.get(int(inv_selected()["id"]))
	var mult := 1.0
	if held_item != null and str(held_item.get("tool", "")) != "" and float(held_item.get("speed", 1.0)) > 1.0 and str(held_item["tool"]) == Data.block_tool(int(hit.id)):
		mult = float(held_item["speed"])
	_mine_prog += dt * mult / maxf(0.15, float(info["hard"]))
	if _mine_prog >= 1.0:
		# AC-0271: breaking either half of a door reclaims the WHOLE
		# door - clear both halves (the drop below is the single door
		# item from the broken cell's drop field).
		if int(_mine_id) == DOOR_LO or int(_mine_id) == DOOR_HI \
				or int(_mine_id) == DOOR_LO_OPEN or int(_mine_id) == DOOR_HI_OPEN:
			var pr := _door_pair(_mine_cell)
			if pr["ok"]:
				_sim_set_block(int(pr["lo"].x), int(pr["lo"].y), int(pr["lo"].z), 0)  # AC-0309 C5: sim-routed
				_sim_set_block(int(pr["hi"].x), int(pr["hi"].y), int(pr["hi"].z), 0)
			else:
				_sim_set_block(_mine_cell.x, _mine_cell.y, _mine_cell.z, 0)
		else:
			_sim_set_block(_mine_cell.x, _mine_cell.y, _mine_cell.z, 0)  # AC-0309 C5: sim-routed
		if bool(Settings.values["hunger_enabled"]):
			hunger = maxf(0.0, hunger - 0.1)
		var is_pick := held_item != null and str(held_item.get("tool", "")) == "pick"
		# AC-0308: the drop spawns in the PLACED world (spawn_drop takes a
		# world position) — the mined cell is FLAT, convert.
		# AC-0309 C5: sim-routed (home: flat->world; face: the chunk
		# transform on the local cell centre).
		var center: Vector3 = _sim_cell_center(_mine_cell.x, _mine_cell.y, _mine_cell.z)
		for d in Data.block_drops(_mine_id, is_pick):
			if randf() < float(d["ch"]):
				Game.world.spawn_drop(int(d["id"]), center)
		Audio.play("break")
		# AC-0038: break debris (the pooled ring; block colour, radial fall).
		if Game.particles != null:
			var bcol := Color(0.7, 0.7, 0.7)
			if info != null and info.has("color") and info["color"].has("side"):
				bcol = info["color"]["side"]
			Game.particles.burst_break(center, bcol)
		_mine_id = -1
		_mine_prog = 0.0


func _cycle_time() -> void:
	if sin((Game.time_of_day - 0.25) * TAU) < -0.08:
		Game.time_of_day = 0.5
		Game.message("Noon")
	else:
		Game.time_of_day = 0.0
		Game.message("Midnight")


func _block_at(wx: float, wy: float, wz: float) -> int:
	# AC-0308: world position -> FLAT before the grid read (the block grid
	# is the flat net; the global-read leftovers AC-0307 documented —
	# in-water / in-lava / head-in-water — are closed by this).
	# AC-0309 C5: past the patch edge the read goes through the face block
	# API (the anchor's cell frame; the far side is a live voxel world,
	# not air — fluids/terrain behave on both sides of the seam).
	if Game.world == null:
		return 0
	if int(_anchor.get("face", 0)) > 1:
		var p: Vector3 = Vector3(wx, wy, wz) - _anchor["origin"]
		var bx: Vector3 = _anchor["basis"].x
		var bn: Vector3 = _anchor["basis"].y
		var bz: Vector3 = _anchor["basis"].z
		var sc: Vector2 = _anchor["scale"]
		var pc: Vector3 = Vector3(p.dot(bx) / sc.x, p.dot(bn), p.dot(bz) / sc.y)
		return Game.world.get_block_key(int(_anchor["face"]), int(floorf(pc.x)), int(floorf(pc.y)), int(floorf(pc.z)))
	var f: Vector3 = Game.world.flat_of_world_pos(Vector3(wx, wy, wz))
	return Game.world.get_block(int(floorf(f.x)), int(floorf(f.y)), int(floorf(f.z)))


# AC-0309 C5: the sim cell accessors — the grid cell (the DDA's frame:
# flat 1 m on home, the face cell frame past the patch edge) to the
# world API. Mine/place/doors all route through these so the far side
# is a live voxel world (C6: edits key planet_id:face:ccx:ccz:local).
func _sim_get_block(x: int, y: int, z: int) -> int:
	if Game.world == null:
		return 0
	if int(_anchor.get("face", 0)) > 1:
		return Game.world.get_block_key(int(_anchor["face"]), x, z, y)
	return Game.world.get_block(x, y, z)


func _sim_set_block(x: int, y: int, z: int, id: int) -> bool:
	if Game.world == null:
		return false
	if int(_anchor.get("face", 0)) > 1:
		return Game.world.set_block_key(int(_anchor["face"]), x, z, y, id)
	return Game.world.set_block(x, y, z, id)


func _sim_cell_center(x: int, y: int, z: int) -> Vector3:
	# AC-0309 C5: the cell centre in the global frame (drops spawn here) —
	# home: flat->world; face: the anchor chunk transform applied to the
	# local cell centre (the mirror layout is the data convention — the
	# transform runs on the chunk's local slots).
	if Game.world == null:
		return Vector3.ZERO
	if int(_anchor.get("face", 0)) > 1:
		var face: int = int(_anchor["face"])
		var ccx: int = int(_anchor["ccx"])
		var ccz: int = int(_anchor["ccz"])
		var lx: int = SphereMath.face_local_x(face, x, ccx)
		return SphereMath.face_chunk_transform(face, ccx, ccz, Game.planet_R) * Vector3(float(lx) + 0.5, float(y) + 0.5, float(z) + 0.5)
	return Game.world.world_pos_of_flat(float(x) + 0.5, float(y) + 0.5, float(z) + 0.5)


func _sim_probe_cell(wx: float, wy: float, wz: float) -> Vector3i:
	# AC-0309 C5: a world position to its sim grid cell (the probe the
	# crouch edge check uses).
	if Game.world == null:
		return Vector3i(int(wx), int(wy), int(wz))
	if int(_anchor.get("face", 0)) > 1:
		var p: Vector3 = Vector3(wx, wy, wz) - _anchor["origin"]
		var bx: Vector3 = _anchor["basis"].x
		var bn: Vector3 = _anchor["basis"].y
		var bz: Vector3 = _anchor["basis"].z
		var sc: Vector2 = _anchor["scale"]
		var pc: Vector3 = Vector3(p.dot(bx) / sc.x, p.dot(bn), p.dot(bz) / sc.y)
		return Vector3i(int(floorf(pc.x)), int(floorf(pc.y)), int(floorf(pc.z)))
	var f: Vector3 = Game.world.flat_of_world_pos(Vector3(wx, wy, wz))
	return Vector3i(int(floorf(f.x)), int(floorf(f.y)), int(floorf(f.z)))


func _recenter() -> void:
	# AC-0213: camera-only moves never requeue — recenter (and with it the
	# ahead-ring queue rebuild) fires ONLY on a positional chunk change;
	# look changes touch nothing here.
	# AC-0234: a 16-block Y crossing ALSO re-centers (a FULL recenter —
	# the user-confirmed trigger: same walk + tiered rewrite as an X/Z
	# cross) so the vertical window's player band moves with the
	# altitude; the wy arg carries the Y to the window recompute.
	# AC-0307: the player position is global; the flat world (and with it
	# the recenter contract) needs the sphere conversion — global x/z stop
	# being flat coordinates a few hundred metres from the spawn.
	var fp: Vector3 = Game.world.flat_of_world_pos(position) if Game.world != null else position
	var pcx := int(floorf(fp.x / 16.0))
	var pcz := int(floorf(fp.z / 16.0))
	var pcy := int(floorf(fp.y / 16.0))
	if pcx != _chunk_x or pcz != _chunk_z or pcy != _chunk_y:
		_chunk_x = pcx
		_chunk_z = pcz
		_chunk_y = pcy
		# AC-0308 -> AC-0145 P1: the basis no longer re-snaps to the column
		# frame on a seam crossing — _sphere_align slews local Y to the exact
		# radial (continuous across the seam). The call flushes a pending
		# look-yaw delta and the camera pitch (a look that landed on this
		# frame must not wait for the next input event).
		_apply_rotation()
		if Game.world != null:
			Game.world.recenter(fp.x, fp.z, true, fp.y)


func _apply_rotation() -> void:
	# AC-0145 P1: the basis is ACCUMULATED, not re-derived from the anchor —
	# _sphere_align (per physics frame) slews local Y toward the EXACT radial
	# underfoot, and look events must only apply their YAW DELTA around that
	# local Y (instant, as before). Re-snapping to _anchor_frame() here would
	# reintroduce the per-column 0.23 deg basis snap this piece removes.
	# The camera pitch is unchanged (local X).
	var dyaw := _yaw - _applied_yaw
	if absf(dyaw) > 1e-9:
		basis = (basis * Basis.from_euler(Vector3(0.0, dyaw, 0.0))).orthonormalized()
		_applied_yaw = _yaw
	camera.rotation.x = _pitch


func _sphere_align(dt: float, align_amount: float = 1.0) -> void:
	# AC-0145 P1: local Y tracks up = normalize(pos - C) — the EXACT radial
	# (C = (0,-R,0) global: the planet frame shifted by (0,-R,0); the first
	# step is the same as world_to_flat / player_anchor). Slerp, never snap:
	# up is a continuous function of position (0.23 deg per 16 m column at
	# R = 4000), so the basis follows it smoothly at SPHERE_SLEW rad/s; a
	# teleport-class misalignment (>= SPHERE_SNAP ~20 deg) snaps, because a
	# position discontinuity is not a motion. Flat mode (no world / R <= 0):
	# the identity frame, up = +Y.
	# AC-0145 P2: align_amount = 1 - band scales the slew — full at the
	# surface (band 0), zero above the atmosphere (band 1 = the 6-DOF band,
	# a FREE basis: no up-alignment, no auto-level). The degenerate-basis
	# rebuild below is a safety net and stays unconditional.
	if Game.world == null or Game.planet_R <= 0.0:
		_up = Vector3.UP
		return
	_up = (position + Vector3(0.0, Game.planet_R, 0.0)).normalized()
	var cur: Vector3 = basis.y
	if cur.length() < 0.5 or not cur.is_finite():
		# degenerate basis — rebuild an up-aligned frame (heading from the
		# old basis if it survives, else an axis not parallel to up)
		var f: Vector3 = -basis.z
		if f.length() < 0.5 or absf(f.normalized().dot(_up)) > 0.95:
			f = Vector3.UP if absf(_up.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
		f = (f - _up * f.dot(_up)).normalized()
		basis = Basis(_up.cross(f).normalized(), _up, f)
		return
	# AC-0145 P2: above the atmosphere the basis is free — no slew to the
	# radial (align_amount ~ 0). Return BEFORE touching the basis.
	if align_amount <= 1e-6:
		return
	var q: Quaternion = Quaternion(cur.normalized(), _up)
	# the minimal-rotation angle = the angle between the two vectors
	# (Quaternion has no angle() in this engine build)
	var ang: float = 2.0 * acos(clampf(cur.normalized().dot(_up), -1.0, 1.0))
	if ang < 1e-6:
		return
	# t = the fraction of the alignment to apply this frame (1.0 = full
	# snap for teleport-class misalignments). q is the FULL alignment, so
	# slerp back toward IDENTITY by (1 - t): t=1 keeps q, t=0 drops it.
	# AC-0145 P2: the slew RATE scales with (1 - band) in the blend.
	var t: float = 1.0 if ang >= SPHERE_SNAP else minf(1.0, SPHERE_SLEW * dt / ang)
	t *= align_amount
	if t <= 1e-6:
		return
	basis = (Basis(q.slerp(Quaternion.IDENTITY, 1.0 - t)) * basis).orthonormalized()


func _col_basis() -> Basis:
	# AC-0308: the pure column frame (no yaw) — the containing column's
	# rigid placement (the _chunk_x/_chunk_z the recenter tracks in FLAT
	# coords). AC-0145 P1: the movement code no longer lerps its velocity
	# in this frame (it lives in the ACCUMULATED basis, up = the exact
	# radial, see _sphere_align); this is now the frame seed at _ready and
	# the aim/step reference the test arms use. Crossing a seam the frame
	# changes by the facet dihedral (<=0.23 deg at R = 4000) — the basis
	# slerp absorbs that as a continuous slew, never a snap.
	if Game.world == null:
		return Basis.IDENTITY
	return Game.world._col_sphere_transform(_chunk_x, _chunk_z).basis


func _col_frame() -> Basis:
	# AC-0308: the player's RENDERED frame = the column frame spun by the
	# look yaw around the local radial. The camera looks down its -Z, so
	# the basis and the aim ray both ride this frame; the velocity lives
	# in _col_basis() (see there for the double-rotation trap).
	return _col_basis() * Basis.from_euler(Vector3(0.0, _yaw, 0.0))


func _anchor_basis() -> Basis:
	# AC-0309 C5: the player's ANCHOR frame — inside the home patch the
	# column basis; past a patch edge the player's face chunk's UNIT-vector
	# frame (orthonormal metres — the chunk node's basis is the same axes
	# scaled by the cell widths, face_cell_scale). AC-0145 P1: this is no
	# longer the movement frame (that is the accumulated basis, up = the
	# exact radial); it remains the cell-frame reference for the face-world
	# reads (auto-step, the DDA) and the arms' jump-kick direction.
	if Game.world == null or int(_anchor.get("face", 0)) <= 1:
		return _col_basis()
	return _anchor["basis"]


func _anchor_frame() -> Basis:
	return _anchor_basis() * Basis.from_euler(Vector3(0.0, _yaw, 0.0))


func _build_debug() -> void:
	_debug_layer = CanvasLayer.new()
	_debug_layer.layer = 100
	add_child(_debug_layer)
	_debug_label = Label.new()
	_debug_label.position = Vector2(8, 8)
	_debug_label.visible = false
	_debug_layer.add_child(_debug_label)


func _update_debug_label() -> void:
	if _debug_label == null:
		return
	var fly_txt := "  FLY" if flying else ""
	_debug_label.text = "FPS %d  pos (%.1f, %.1f, %.1f)  time %.2f%s" % [Engine.get_frames_per_second(), position.x, position.y, position.z, Game.time_of_day, fly_txt]


func look(yaw: float, pitch: float) -> void:
	_yaw = yaw
	_pitch = clampf(pitch, -PITCH_LIMIT, PITCH_LIMIT)
	_apply_rotation()


func apply_look(mm: InputEventMouseMotion) -> void:
	_yaw -= mm.relative.x * MOUSE_SENS
	_pitch = clampf(_pitch - mm.relative.y * MOUSE_SENS, -PITCH_LIMIT, PITCH_LIMIT)
	_apply_rotation()


func get_yaw() -> float:
	return _yaw


func get_pitch() -> float:
	return _pitch


func is_mining() -> bool:
	return _mining


func is_dragging() -> bool:
	return _dragging


func set_fly(enabled: bool) -> void:
	flying = enabled
	Game.message("Flying" if enabled else "Landed")


func start() -> void:
	camera.current = true
	Game.set_cursor(Input.MOUSE_MODE_CAPTURED)


func _stack_max(id: int) -> int:
	var info = Data.items.get(id)
	if info != null and info.has("stack"):
		return int(info["stack"])
	return STACK_MAX


func _inv_order() -> Array:
	var order: Array = []
	for i in range(0, mini(STORAGE_OFF, inv.size())):
		order.append(i)
	for i in range(STORAGE_OFF, mini(INV_SIZE, inv.size())):
		order.append(i)
	return order


func inv_add(id: int, n: int) -> bool:
	var max_n := _stack_max(id)
	var order := _inv_order()
	for i in order:
		var it: Dictionary = inv[i]
		if int(it["id"]) == id and int(it["n"]) < max_n:
			var take := mini(n, max_n - int(it["n"]))
			it["n"] = int(it["n"]) + take
			n -= take
			if n <= 0:
				return true
	for i in order:
		var it: Dictionary = inv[i]
		if int(it["id"]) == 0 and n > 0:
			var take := mini(n, max_n)
			it["id"] = id
			it["n"] = take
			n -= take
			if n <= 0:
				return true
	return false


func count_item(id: int) -> int:
	var c := 0
	for it in inv:
		if int(it["id"]) == id:
			c += int(it["n"])
	return c


func find_slot(id: int) -> int:
	for i in mini(INV_SIZE, inv.size()):
		if int(inv[i]["id"]) == id:
			return i
	return -1


func remove_item(id: int, n: int) -> bool:
	for i in range(INV_SIZE - 1, -1, -1):
		if i >= inv.size():
			continue
		var it: Dictionary = inv[i]
		if int(it["id"]) == id:
			var take := mini(n, int(it["n"]))
			it["n"] = int(it["n"]) - take
			n -= take
			if int(it["n"]) <= 0:
				it["id"] = 0
				it["n"] = 0
			if n <= 0:
				return true
	return false


func armor_points() -> int:
	var s := 0
	for a in armor:
		if int(a) != 0:
			var it = Data.items.get(int(a))
			if it != null and it.has("dr"):
				s += int(it["dr"])
	return s


func damage_player(n: float, src: String) -> void:
	if dead:
		return
	var ap := armor_points()
	if ap > 0:
		var reduce := minf(0.8, float(ap) * 0.04)
		n = maxf(1.0, roundf(n * (1.0 - reduce)))
	hp -= n
	Audio.play("hurt")
	damaged.emit(src)
	# AC-0038: hit sparks on the chest (the AC-0145 P3 / AC-0377 local-up
	# offset; no attacker direction here, so the spread is isotropic).
	if Game.particles != null:
		Game.particles.burst_hit(position + basis.y * 1.0)
	if hp <= 0.0:
		hp = 0.0
		dead = true
		drag_held = false
		release_mine()
		_return_table_grid()
		if held != {}:
			_return_held_to_inv()
		Game.set_cursor(Input.MOUSE_MODE_VISIBLE)


func _return_held_to_inv() -> void:
	if int(held.get("id", 0)) != 0:
		inv_add(int(held["id"]), int(held["n"]))
	held = {}


func respawn() -> void:
	dead = false
	_lmb_down = false
	hp = 20.0
	hunger = 20.0
	air = 10.0
	lava_t = 0.0
	drown_t = 0.0
	fall_start = -1.0
	sprint_latched = false
	crouched = false
	_regen_t = 0.0
	_starve_t = 0.0
	flying = false
	armor.clear()
	for i in ARMOR_SIZE:
		armor.append(0)
	velocity = Vector3.ZERO
	if Game.world == null:
		return
	# AC-0145 P3: the respawn column + placement run in the SIM frame. The
	# old code took the player's GLOBAL x/z as flat column coords and built
	# the flat (sx, sy, sz) straight into a global position — the frames
	# agree only near the home centre (at d from it the surface sits d²/2R
	# lower in global y, so a respawn far from home floated in the air and
	# fell back onto the ground). The scan reads the death column through
	# the sim accessors (the flat net on the home pair, the anchor's face
	# cell frame past it); the placement converts the landed cell back to
	# the GLOBAL frame (world_pos_of_flat on home, the anchor chunk
	# transform on a face — the same cell->world path as _sim_cell_center).
	var sc: Vector3i = _sim_probe_cell(position.x, position.y, position.z)
	var sy := Data.HEIGHT - 2
	while sy > 1 and _sim_get_block(sc.x, sy, sc.z) == 0:
		sy -= 1
	if int(_anchor.get("face", 0)) > 1:
		var T: Transform3D = SphereMath.face_chunk_transform(int(_anchor["face"]), int(_anchor["ccx"]), int(_anchor["ccz"]), Game.planet_R)
		var lx: int = SphereMath.face_local_x(int(_anchor["face"]), sc.x, int(_anchor["ccx"]))
		position = T * Vector3(float(lx) + 0.5, float(sy) + 1.01, float(sc.z) + 0.5)
	else:
		position = Game.world.world_pos_of_flat(float(sc.x) + 0.5, float(sy) + 1.01, float(sc.z) + 0.5)


func _inv_get(i: int) -> Dictionary:
	if i >= 0 and i < inv.size():
		return inv[i]
	return {"id": 0, "n": 0}


func _inv_set(i: int, v: Dictionary) -> void:
	while inv.size() <= i:
		inv.append({"id": 0, "n": 0})
	inv[i] = v


func refresh_held() -> void:
	_held_key = ""
	_held_item_texs.clear()


func open_inventory(mode: String) -> void:
	ui_mode = mode
	release_mine()
	recompute_craft()
	Game.set_cursor(Input.MOUSE_MODE_VISIBLE)


func close_inventory() -> void:
	ui_mode = ""
	drag_held = false
	release_mine()
	if held != {} and int(held.get("id", 0)) != 0:
		inv_add(int(held["id"]), int(held["n"]))
		held = {}
	for i in CRAFT_GRID_SIZE:
		craft_grid[i] = {"id": 0, "n": 0}
	_return_table_grid()
	craft_out = {}


func _return_table_grid() -> void:
	for c in table_grid:
		var cid := int(c["id"])
		var n := int(c["n"])
		if cid == 0 or n <= 0:
			continue
		var before := count_item(cid)
		inv_add(cid, n)
		var left := n - (count_item(cid) - before)
		if left > 0:
			for k in left:
				if Game.world != null:
					Game.world.spawn_drop(cid, Vector3(position.x + 0.5, position.y + 1.0, position.z + 0.5))
	for i in range(table_grid.size()):
		table_grid[i] = {"id": 0, "n": 0}


func _current_craft_cells() -> Array:
	if ui_mode == "table":
		return table_grid
	var cells: Array = []
	for i in mini(EGRID_CELLS, craft_grid.size()):
		cells.append(craft_grid[i])
	return cells


func recompute_craft() -> void:
	var cells: Array = _current_craft_cells()
	var gs := 3 if ui_mode == "table" else 2
	var m = Data.match_shaped(cells, gs)
	if m == null:
		m = Data.match_shapeless(cells, gs)
	craft_out = {} if m == null else {"id": int(m["id"]), "n": int(m["n"])}


func _slot_click(s: Dictionary, set_slot: Callable, area: String, button: int, shift: bool, release: bool = false) -> void:
	var has_s := int(s["id"]) != 0
	var had_held := held != {} and int(held.get("id", 0)) != 0
	if release:
		if had_held and drag_held:
			if not has_s:
				set_slot.call({"id": int(held["id"]), "n": int(held["n"])})
				held = {}
			elif int(s["id"]) == int(held["id"]):
				var rmax := _stack_max(int(s["id"]))
				var rt := mini(int(held["n"]), rmax - int(s["n"]))
				s["n"] = int(s["n"]) + rt
				held["n"] = int(held["n"]) - rt
				if int(held["n"]) <= 0:
					held = {}
			else:
				set_slot.call({"id": int(held["id"]), "n": int(held["n"])})
				held = {"id": int(s["id"]), "n": int(s["n"])}
		drag_held = false
		return
	if shift:
		if has_s and (area == "storage" or area == "hotbar"):
			var off := 0 if area == "storage" else STORAGE_OFF
			var cnt := 9 if area == "storage" else 27
			for i in cnt:
				var t: Dictionary = _inv_get(i + off)
				if int(t["id"]) != 0 and int(t["id"]) == int(s["id"]) and int(t["n"]) < _stack_max(int(t["id"])):
					var m := mini(int(s["n"]), _stack_max(int(t["id"])) - int(t["n"]))
					t["n"] = int(t["n"]) + m
					s["n"] = int(s["n"]) - m
					if int(s["n"]) <= 0:
						break
			for i in cnt:
				if int(s["n"]) <= 0:
					break
				if int(_inv_get(i + off)["id"]) == 0:
					var m2 := mini(int(s["n"]), _stack_max(int(s["id"])))
					_inv_set(i + off, {"id": int(s["id"]), "n": m2})
					s["n"] = int(s["n"]) - m2
			set_slot.call(s if int(s["n"]) > 0 else {"id": 0, "n": 0})
		drag_held = false
		return
	if button == 2:
		if held != {} and int(held.get("id", 0)) != 0:
			if not has_s:
				set_slot.call({"id": int(held["id"]), "n": 1})
				held["n"] = int(held["n"]) - 1
			elif int(s["id"]) == int(held["id"]) and int(s["n"]) < _stack_max(int(s["id"])):
				s["n"] = int(s["n"]) + 1
				held["n"] = int(held["n"]) - 1
			if int(held["n"]) <= 0:
				held = {}
		elif has_s:
			held = {"id": int(s["id"]), "n": 1}
			if int(s["n"]) <= 1:
				set_slot.call({"id": 0, "n": 0})
			else:
				s["n"] = int(s["n"]) - 1
		drag_held = not had_held and int(held.get("id", 0)) != 0
		return
	if held != {} and int(held.get("id", 0)) != 0:
		if not has_s:
			set_slot.call({"id": int(held["id"]), "n": int(held["n"])})
			held = {}
		elif int(s["id"]) == int(held["id"]):
			var max_n := _stack_max(int(s["id"]))
			var t := mini(int(held["n"]), max_n - int(s["n"]))
			s["n"] = int(s["n"]) + t
			held["n"] = int(held["n"]) - t
			if int(held["n"]) <= 0:
				held = {}
		else:
			set_slot.call({"id": int(held["id"]), "n": int(held["n"])})
			held = {"id": int(s["id"]), "n": int(s["n"])}
		drag_held = int(held.get("id", 0)) != 0
	elif has_s:
		held = {"id": int(s["id"]), "n": int(s["n"])}
		set_slot.call({"id": 0, "n": 0})
		drag_held = true
	else:
		drag_held = false


func _cg_set(_i: int, v: Dictionary) -> void:
	craft_grid[_i] = v


func inv_slot_click(index: int, area: String, button: int, shift: bool, release: bool = false) -> void:
	var i: int = index + STORAGE_OFF if area == "storage" else index
	_slot_click(_inv_get(i), func(v: Dictionary) -> void: _inv_set(i, v), area, button, shift, release)


func craft_grid_click(index: int, button: int, shift: bool, release: bool = false) -> void:
	if index < 0 or index >= EGRID_CELLS:
		return
	if index >= craft_grid.size():
		return
	if shift and not release:
		return
	_slot_click(craft_grid[index], func(v: Dictionary) -> void: craft_grid[index] = v, "craft", button, false, release)
	recompute_craft()


func table_grid_click(index: int, button: int, shift: bool, release: bool = false) -> void:
	if index < 0 or index >= table_grid.size():
		return
	if shift and not release:
		return
	_slot_click(table_grid[index], func(v: Dictionary) -> void: table_grid[index] = v, "craft", button, false, release)
	recompute_craft()


func craft_output_click() -> void:
	if craft_out == {} or int(craft_out.get("id", 0)) == 0:
		return
	var ok := inv_add(int(craft_out["id"]), int(craft_out["n"]))
	if ok:
		for c in _current_craft_cells():
			if int(c["id"]) != 0:
				c["n"] = int(c["n"]) - int(craft_out["n"])
				if int(c["n"]) <= 0:
					c["id"] = 0
					c["n"] = 0
		recompute_craft()
		Audio.play("pickup")


func armor_slot_click(index: int, button: int, shift: bool, release: bool = false) -> void:
	if index < 0 or index >= armor.size():
		return
	var kind: String = ARMOR_SLOTS[index]
	var had_held := held != {} and int(held.get("id", 0)) != 0
	if release:
		if had_held and drag_held:
			var it3 = Data.items.get(int(held["id"]))
			if it3 != null and str(it3.get("armor", "")) == kind and int(armor[index]) == 0:
				armor[index] = int(held["id"])
				held = {}
		drag_held = false
		return
	if button == 2:
		if had_held:
			var it = Data.items.get(int(held["id"]))
			if it != null and str(it.get("armor", "")) == kind:
				if int(held["n"]) > 1:
					armor[index] = int(held["id"])
					held["n"] = int(held["n"]) - 1
				elif int(armor[index]) == 0:
					armor[index] = int(held["id"])
					held = {}
		drag_held = false
		return
	if shift:
		drag_held = false
		return
	if had_held:
		var it2 = Data.items.get(int(held["id"]))
		if it2 != null and str(it2.get("armor", "")) == kind:
			if int(armor[index]) == 0:
				armor[index] = int(held["id"])
				held = {}
			elif int(armor[index]) != int(held["id"]):
				var old := int(armor[index])
				armor[index] = int(held["id"])
				held = {"id": old, "n": 1}
	elif int(armor[index]) != 0:
		held = {"id": int(armor[index]), "n": 1}
		armor[index] = 0
	drag_held = not had_held and int(held.get("id", 0)) != 0


func inv_selected() -> Dictionary:
	if sel >= 0 and sel < inv.size():
		return inv[sel]
	return {"id": 0, "n": 0}


func inv_consume_selected() -> void:
	var it: Dictionary = inv[sel]
	it["n"] = int(it["n"]) - 1
	if int(it["n"]) <= 0:
		it["id"] = 0
		it["n"] = 0
