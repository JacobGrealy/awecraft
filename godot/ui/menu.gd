class_name Menu
extends Control

const AtlasScript = preload("res://core/atlas.gd")

const SUB_C := Color(0.75, 0.75, 0.78, 1.0)
const HELP_C := Color(0.62, 0.62, 0.66, 1.0)
const RES_MODES := ["1280x720", "1600x900", "1920x1080", "2560x1440"]

var on_play: Callable
var on_new_world: Callable
var on_resume: Callable
var on_quit_to_menu: Callable
var on_continue: Callable
var on_range: Callable
var slot_labels: Array = []
var slot_conts: Array = []
var slot_clears: Array = []

var main_box: Control
var pause_box: Control
var options_box: Control
var main_status: Label
var opt_status: Label
var seed_edit: LineEdit
var version_label: Label
var render_slider: HSlider
var sim_slider: HSlider
var volume_slider: HSlider
var flight_slider: HSlider
var chunk_slider: HSlider
var render_val: Label
var sim_val: Label
var volume_val: Label
var flight_val: Label
var chunk_val: Label
var res_option: OptionButton
var full_check: CheckBox
var hunger_check: CheckBox
var debuglog_check: CheckBox
var overlay_band_check: CheckBox
var overlay_light_check: CheckBox
var overlay_collision_check: CheckBox
var debug_check: CheckBox
# AC-0232 (dither dropped in AC-0241): the fog start-distance slider
# (percent of the render edge, (render_dist + 1) * 16 blocks).
var fogstart_slider: HSlider
var fogstart_val: Label
# AC-0252: the med/low band split slider — the distance (taxi chunks)
# where the 4x4x4 LOW avg-color band starts (the 8x8x8 MED tier owns
# everything closer; the low band runs out to the render edge).
var lowstart_slider: HSlider
var lowstart_val: Label
# AC-0260: the "Developer" TAB of the options panel (tier-0 radius + the
# worker-thread caps; the per-frame instance cap row moves here from the
# Settings page). No checkbox: it is a TabContainer page.
var dev_page: VBoxContainer
var tier0_slider: HSlider
var tier0_val: Label
var gen_slider: HSlider
var gen_val: Label
var mesh_slider: HSlider
var mesh_val: Label
var file_dialog: FileDialog
var _options_from := "main"
var _focus_last: Control = null  # AC-0087: gamepad focus highlight
var _syncing := false
# visibility state machine: exactly one of the boxes may be visible;
# "ingame" = menu layer hidden entirely (except pause, via show_pause)
var _state := "main"


func _process(_dt: float) -> void:
	# AC-0087: highlight the focused control (native navigation
	# moves gui focus; we just paint it).
	if _state == "ingame":
		return
	var f := get_viewport().gui_get_focus_owner()
	if f != _focus_last:
		if _focus_last != null and is_instance_valid(_focus_last):
			_focus_last.modulate = Color.WHITE
		_focus_last = f
		if f != null:
			f.modulate = Color(1.35, 1.35, 1.35)


func _apply_state() -> void:
	if main_box != null:
		main_box.visible = _state == "main"
	if pause_box != null:
		pause_box.visible = _state == "pause"
	if options_box != null:
		options_box.visible = _state == "opt_main" or _state == "opt_pause"
	visible = _state != "ingame"
	# AC-0087: give keyboard/gamepad a starting focus per box so the
	# D-pad and stick navigate (the engine moves focus natively for the
	# built-in ui_* actions; only one box is visible, so navigation
	# stays inside it).
	if main_box != null and _state == "main":
		main_box.get_node("Center/VBox/PlayButton").grab_focus()
	elif pause_box != null and _state == "pause":
		pause_box.get_node("Center/VBox/ResumeButton").grab_focus()
	elif options_box != null and (_state == "opt_main" or _state == "opt_pause"):
		if render_slider != null:
			render_slider.grab_focus()


func _ready() -> void:
	main_box = get_node("Layer/MainBox")
	pause_box = get_node("Layer/PauseBox")
	options_box = get_node("Layer/OptionsBox")
	version_label = get_node("Layer/MainBox/Center/VBox/Version")
	main_status = get_node("Layer/MainBox/Center/VBox/MainStatus")
	opt_status = get_node("Layer/OptionsBox/Center/VBox/OptStatus")
	seed_edit = get_node("Layer/MainBox/Center/VBox/SeedRow/SeedEdit")
	render_slider = get_node("Layer/OptionsBox/Center/VBox/RenderRow/RenderSlider")
	sim_slider = get_node("Layer/OptionsBox/Center/VBox/SimRow/SimSlider")
	volume_slider = get_node("Layer/OptionsBox/Center/VBox/VolumeRow/VolumeSlider")
	flight_slider = get_node("Layer/OptionsBox/Center/VBox/FlightRow/FlightSlider")
	render_val = get_node("Layer/OptionsBox/Center/VBox/RenderRow/RenderVal")
	sim_val = get_node("Layer/OptionsBox/Center/VBox/SimRow/SimVal")
	volume_val = get_node("Layer/OptionsBox/Center/VBox/VolumeRow/VolumeVal")
	flight_val = get_node("Layer/OptionsBox/Center/VBox/FlightRow/FlightVal")
	chunk_slider = get_node("Layer/OptionsBox/Center/VBox/ChunkRow/ChunkSlider")
	chunk_val = get_node("Layer/OptionsBox/Center/VBox/ChunkRow/ChunkVal")
	res_option = get_node("Layer/OptionsBox/Center/VBox/ResRow/ResOption")
	full_check = get_node("Layer/OptionsBox/Center/VBox/FullscreenCheck")
	hunger_check = get_node("Layer/OptionsBox/Center/VBox/HungerCheck")
	fogstart_slider = get_node("Layer/OptionsBox/Center/VBox/FogStartRow/FogStartSlider")
	fogstart_val = get_node("Layer/OptionsBox/Center/VBox/FogStartRow/FogStartVal")
	lowstart_slider = get_node("Layer/OptionsBox/Center/VBox/LowStartRow/LowStartSlider")
	lowstart_val = get_node("Layer/OptionsBox/Center/VBox/LowStartRow/LowStartVal")
	var opt_vbox := get_node("Layer/OptionsBox/Center/VBox")
	debug_check = CheckBox.new()
	debug_check.name = "DebugStatsCheck"
	debug_check.text = "Show debug stats (CPU/RAM/VRAM/FPS)"
	debug_check.add_theme_font_size_override("font_size", 15)
	debug_check.toggled.connect(_on_debug_stats_toggled)
	opt_vbox.add_child(debug_check)
	var hi := -1
	for i in opt_vbox.get_child_count():
		if opt_vbox.get_child(i) == hunger_check:
			hi = i
	if hi >= 0:
		opt_vbox.move_child(debug_check, hi + 1)
	# AC-0170: debug logging toggle (same code-created pattern as above).
	debuglog_check = CheckBox.new()
	debuglog_check.name = "DebugLogCheck"
	debuglog_check.text = "Log debug output to the in-game console"
	debuglog_check.add_theme_font_size_override("font_size", 15)
	debuglog_check.toggled.connect(_on_debug_log_toggled)
	opt_vbox.add_child(debuglog_check)
	if hi + 1 < opt_vbox.get_child_count():
		opt_vbox.move_child(debuglog_check, hi + 2)
	# AC-0174: dev overlay toggles - independent, all can be on at once.
	overlay_band_check = CheckBox.new()
	overlay_band_check.name = "OverlayBandCheck"
	overlay_band_check.text = "Show band overlay (render/sim bands)"
	overlay_band_check.add_theme_font_size_override("font_size", 15)
	overlay_band_check.toggled.connect(_on_overlay_band_toggled)
	opt_vbox.add_child(overlay_band_check)
	if hi + 2 < opt_vbox.get_child_count():
		opt_vbox.move_child(overlay_band_check, hi + 3)
	overlay_light_check = CheckBox.new()
	overlay_light_check.name = "OverlayLightCheck"
	overlay_light_check.text = "Show light-level overlay"
	overlay_light_check.add_theme_font_size_override("font_size", 15)
	overlay_light_check.toggled.connect(_on_overlay_light_toggled)
	opt_vbox.add_child(overlay_light_check)
	if hi + 3 < opt_vbox.get_child_count():
		opt_vbox.move_child(overlay_light_check, hi + 4)
	overlay_collision_check = CheckBox.new()
	overlay_collision_check.name = "OverlayCollisionCheck"
	overlay_collision_check.text = "Show collision overlay"
	overlay_collision_check.add_theme_font_size_override("font_size", 15)
	overlay_collision_check.toggled.connect(_on_overlay_collision_toggled)
	opt_vbox.add_child(overlay_collision_check)
	if hi + 4 < opt_vbox.get_child_count():
		opt_vbox.move_child(overlay_collision_check, hi + 5)
	# AC-0260: the options panel is TABBED. The "Settings" page is the
	# original list restored to its tscn seat (centered again by the
	# OptionsBox CenterContainer — the AC-0257 ScrollContainer wrap that
	# broke the centering is gone, and the Developer rows no longer make
	# it too tall: they live on their own tab). The "Developer" page
	# holds the perf-knob rows. The scene's ChunkRow (the per-frame
	# instance cap) moves to the Developer page: the tscn
	# ChunkSlider->_on_chunk_changed connection survives the reparent
	# (connections hold object refs, not node paths).
	var opt_center := get_node("Layer/OptionsBox/Center")
	var chunk_row := get_node("Layer/OptionsBox/Center/VBox/ChunkRow")
	var opt_tabs := TabContainer.new()
	opt_tabs.name = "OptTabs"
	opt_tabs.add_theme_font_size_override("font_size", 15)
	opt_center.add_child(opt_tabs)
	opt_vbox.name = "Settings"
	opt_tabs.add_child(opt_vbox)  # reparent out of its tscn seat into the tab
	dev_page = VBoxContainer.new()
	dev_page.name = "Developer"
	dev_page.add_theme_constant_override("separation", 6)
	opt_vbox.remove_child(chunk_row)
	dev_page.add_child(chunk_row)
	var t0r := _mk_dev_slider_row(dev_page, "Tier0Row", "Tier-0 radius (full-high columns)", 0.0, float(Settings.TIER0_RADIUS_MAX))
	tier0_slider = t0r[0]
	tier0_val = t0r[1]
	var genr := _mk_dev_slider_row(dev_page, "GenThreadsRow", "Worker threads gen (0 = auto)", 0.0, float(Settings.WORKER_THREADS_MAX))
	gen_slider = genr[0]
	gen_val = genr[1]
	var meshr := _mk_dev_slider_row(dev_page, "MeshThreadsRow", "Worker threads mesh (0 = auto)", 0.0, float(Settings.WORKER_THREADS_MAX))
	mesh_slider = meshr[0]
	mesh_val = meshr[1]
	tier0_slider.value_changed.connect(_on_tier0_changed)
	gen_slider.value_changed.connect(_on_gen_threads_changed)
	mesh_slider.value_changed.connect(_on_mesh_threads_changed)
	opt_tabs.add_child(dev_page)
	file_dialog = get_node("Layer/PackDialog")
	slot_labels = []
	slot_conts = []
	slot_clears = []
	for i in range(3):
		var row: Node = get_node("Layer/MainBox/Center/VBox/SlotRow%d" % i)
		slot_labels.append(row.get_node("SlotLabel"))
		slot_conts.append(row.get_node("ContinueButton"))
		slot_clears.append(row.get_node("ClearButton"))
	version_label.text = "AweCraft[" + Build.ID + "]"
	seed_edit.text = str(int(Settings.values.get("seed", 44)))
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.add_filter("*.zip ; *.mcpack ; *.mcpr")
	file_dialog.file_selected.connect(_on_pack_file_selected)
	show_main()


func _unhandled_input(event) -> void:
	if _state == "ingame":
		return
	# AC-0087: A/Cross confirm + B/Circle cancel (the built-in ui_accept/
	# ui_cancel actions are keyboard-only in this project; D-pad and stick
	# navigation itself is native via the built-in ui_* actions).
	if event is InputEventJoypadButton:
		if not event.pressed:
			return
		if event.is_action_pressed("pad_cancel"):
			# mirrors the ESC branch below
			if options_box.visible:
				close_options()
			elif pause_box.visible:
				_on_resume_btn_pressed()
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("pad_accept"):
			var f := get_viewport().gui_get_focus_owner()
			if f is Button:
				f.pressed.emit()
				get_viewport().set_input_as_handled()
			elif f is CheckBox:
				f.set_pressed(not f.button_pressed)
				get_viewport().set_input_as_handled()
	if event is InputEventKey and event.pressed and not event.echo:
		var kc: int = int(event.physical_keycode)
		if kc != int(KEY_ESCAPE) and kc != int(KEY_P) and not event.is_action_pressed("ui_pause"):
			return
		if options_box.visible:
			close_options()
			get_viewport().set_input_as_handled()
		elif pause_box.visible:
			_on_resume_btn_pressed()
			get_viewport().set_input_as_handled()


func show_main() -> void:
	_state = "main"
	_apply_state()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	refresh_slots()


func show_pause() -> void:
	_state = "pause"
	_sync_controls()
	_apply_state()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func open_options(source: String) -> void:
	_options_from = source
	_state = "opt_main" if source == "main" else "opt_pause"
	_sync_controls()
	_apply_state()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	print("OPTSYNC from=%s render=%d sim=%d vol=%d res=%s full=%s hunger=%s stats=%s logdbg=%s chunk=%d fogpct=%d ovband=%s ovlight=%s ovcol=%s" % [
		source,
		int(Settings.values["render_dist"]),
		int(Settings.values["sim_dist"]),
		int(Settings.values["volume"]),
		String(Settings.values["resolution"]),
		bool(Settings.values["fullscreen"]),
		bool(Settings.values["hunger_enabled"]),
		bool(Settings.values["debug_stats"]),
		bool(Settings.values.get("debug_logging", false)),
		int(Settings.values.get("chunks_per_frame", 3)),
		int(Settings.values.get("fog_start_pct", 87)),
		bool(Settings.values.get("overlay_band", false)),
		bool(Settings.values.get("overlay_light", false)),
		bool(Settings.values.get("overlay_collision", false)),
	])


func close_options() -> void:
	if _state == "opt_main" or _state == "opt_pause":
		_state = _options_from
	_apply_state()


func play_clicked() -> void:
	_state = "ingame"
	_apply_state()
	if on_play.is_valid():
		await on_play.call()


func new_world_clicked() -> void:
	var t := seed_edit.text.strip_edges()
	var seed: int
	if t.is_valid_int():
		seed = t.to_int()
	else:
		seed = randi_range(-2147483647, 2147483646)
		seed_edit.text = str(seed)
	_state = "ingame"
	_apply_state()
	if on_new_world.is_valid():
		await on_new_world.call(seed)


func continue_clicked(slot: int) -> void:
	_state = "ingame"
	_apply_state()
	if on_continue.is_valid():
		await on_continue.call(slot)


# AC-0191: enter the isolated combat/movement range (no world, no saves)
func range_clicked() -> void:
	_state = "ingame"
	_apply_state()
	if on_range.is_valid():
		await on_range.call()


func _clear_slot(slot: int) -> void:
	Save.clear(slot)
	if Save.active_slot == slot:
		Save.active_slot = -1
	refresh_slots()
	if main_status != null:
		main_status.text = "Slot %d cleared" % (slot + 1)


func refresh_slots() -> void:
	for s in range(slot_labels.size()):
		var l: Label = slot_labels[s]
		var cont: Button = slot_conts[s]
		var clr: Button = slot_clears[s]
		if not Save.file_exists(s):
			l.text = "Slot %d — Empty" % (s + 1)
			l.add_theme_color_override("font_color", HELP_C)
			cont.disabled = true
			clr.disabled = true
			continue
		var m := Save.meta(s)
		l.text = "Slot %d · World %d · %s · %d edits" % [
			s + 1, int(m.get("seed", 0)), Save.format_time(float(m.get("time", 0.0))), int(m.get("edits", 0))
		]
		l.add_theme_color_override("font_color", SUB_C)
		cont.disabled = false
		clr.disabled = false


func hide_pause() -> void:
	_state = "ingame"
	_apply_state()


func _on_resume_btn_pressed() -> void:
	_state = "ingame"
	_apply_state()
	if on_resume.is_valid():
		on_resume.call()


func _on_quit_btn_pressed() -> void:
	if on_quit_to_menu.is_valid():
		on_quit_to_menu.call()


func _on_exit_pressed() -> void:
	get_tree().quit()


func _open_pack_dialog() -> void:
	file_dialog.popup_centered(Vector2i(720, 480))


func _on_pack_file_selected(path: String) -> void:
	var st := opt_status if opt_status != null and options_box.visible else main_status
	if st != null:
		st.text = "Importing texture pack…"
	var r := AtlasScript.import_pack(path)
	if st == null:
		return
	if not bool(r.get("ok", false)):
		st.text = "Import failed: " + str(r.get("error", "unknown"))
		return
	var img: Image = Image.load_from_file("res://assets/blocks_atlas.png")
	if img == null:
		st.text = "Import failed: atlas reload"
		return
	Data.apply_atlas(img, r["rects"])
	if FileAccess.file_exists("res://assets/items_atlas.png"):
		var iimg: Image = Image.load_from_file("res://assets/items_atlas.png")
		if iimg != null and r.has("item_rects"):
			Data.apply_items_atlas(iimg, r["item_rects"])
	if Game.world != null:
		Game.world.refresh_textures()
	if Game.hotbar != null:
		Game.hotbar.refresh_atlas()
	if Game.player != null:
		Game.player.refresh_held()
	st.text = "Texture pack applied: %d blocks, %d tiles, %d items" % [int(r.get("blocks", 0)), int(r.get("tiles", 0)), int(r.get("item_count", 0))]


# AC-0257: one code-built slider row for the Developer submenu (the tscn
# row pattern). Returns [slider, val_label].
func _mk_dev_slider_row(parent: Control, row_name: String, label_text: String, minv: float, maxv: float) -> Array:
	var row := HBoxContainer.new()
	row.name = row_name
	row.add_theme_constant_override("separation", 10)
	var lab := Label.new()
	lab.text = label_text
	lab.add_theme_font_size_override("font_size", 15)
	lab.custom_minimum_size = Vector2(250, 0)
	var sl := HSlider.new()
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.custom_minimum_size = Vector2(0, 24)
	sl.min_value = minv
	sl.max_value = maxv
	sl.step = 1.0
	var val := Label.new()
	val.add_theme_font_size_override("font_size", 15)
	val.custom_minimum_size = Vector2(44, 0)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(lab)
	row.add_child(sl)
	row.add_child(val)
	parent.add_child(row)
	return [sl, val]


func _sync_controls() -> void:
	_syncing = true
	render_slider.value = float(int(Settings.values["render_dist"]))
	sim_slider.max_value = float(int(Settings.values["render_dist"]))
	sim_slider.value = float(int(Settings.values["sim_dist"]))
	volume_slider.value = float(int(Settings.values["volume"]))
	flight_slider.value = float(int(Settings.values.get("flight_speed", 4)))
	chunk_slider.value = float(int(Settings.values.get("chunks_per_frame", 3)))
	render_val.text = str(int(render_slider.value))
	sim_val.text = str(int(sim_slider.value))
	volume_val.text = str(int(volume_slider.value))
	flight_val.text = str(int(flight_slider.value)) + "x"
	chunk_val.text = str(int(chunk_slider.value))
	res_option.clear()
	for m in RES_MODES:
		res_option.add_item(m)
	var cur := String(Settings.values["resolution"])
	if not RES_MODES.has(cur):
		res_option.add_item(cur + " (current)")
		cur = cur + " (current)"
	var wi := -1
	for i in res_option.item_count:
		if res_option.get_item_text(i) == cur:
			wi = i
			break
	if wi >= 0:
		res_option.select(wi)
	full_check.button_pressed = bool(Settings.values["fullscreen"])
	hunger_check.button_pressed = bool(Settings.values["hunger_enabled"])
	debug_check.button_pressed = bool(Settings.values["debug_stats"])
	debuglog_check.button_pressed = bool(Settings.values.get("debug_logging", false))
	overlay_band_check.button_pressed = bool(Settings.values.get("overlay_band", false))
	overlay_light_check.button_pressed = bool(Settings.values.get("overlay_light", false))
	overlay_collision_check.button_pressed = bool(Settings.values.get("overlay_collision", false))
	fogstart_slider.value = float(int(Settings.values["fog_start_pct"]))
	fogstart_val.text = str(int(fogstart_slider.value)) + "%"
	# AC-0261: the low-start slider spans the visible band [sim, render].
	_sync_lowstart_range()
	# AC-0257: the Developer submenu rows.
	tier0_slider.value = float(int(Settings.values.get("tier0_radius", 0)))
	tier0_val.text = str(int(tier0_slider.value))
	gen_slider.value = float(int(Settings.values.get("worker_gen_threads", 0)))
	gen_val.text = "auto" if int(gen_slider.value) == 0 else str(int(gen_slider.value))
	mesh_slider.value = float(int(Settings.values.get("worker_mesh_threads", 0)))
	mesh_val.text = "auto" if int(mesh_slider.value) == 0 else str(int(mesh_slider.value))
	_syncing = false


func _on_render_changed(v: float) -> void:
	if _syncing:
		return
	render_val.text = str(int(v))
	Settings.set_value("render_dist", int(v))
	_syncing = true
	sim_slider.max_value = float(int(Settings.values["render_dist"]))
	sim_slider.value = float(int(Settings.values["sim_dist"]))
	_syncing = false
	sim_val.text = str(int(sim_slider.value))
	# AC-0261: the low-start slider's range tracks the [sim, render] band.
	_sync_lowstart_range()
	Settings.apply_render_distance()
	Settings.apply_sim_distance()


# AC-0261: the low-start slider spans the visible LOD band [sim, render]:
# MED = [sim, low_start), LOW = [low_start, render]; nothing renders past
# the render distance. Re-clamp the value into the band.
func _sync_lowstart_range() -> void:
	var lr := int(Settings.values["render_dist"])
	var lo := mini(int(Settings.values["sim_dist"]), lr)
	var hi := lr
	_syncing = true
	lowstart_slider.min_value = float(lo)
	lowstart_slider.max_value = float(hi)
	lowstart_slider.value = float(clampi(int(Settings.values["low_start"]), lo, hi))
	_syncing = false
	lowstart_val.text = str(int(lowstart_slider.value))


func _on_sim_changed(v: float) -> void:
	if _syncing:
		return
	var r := int(Settings.values["render_dist"])
	var s := clampi(int(v), 1, r)
	_syncing = true
	sim_slider.max_value = float(r)
	sim_slider.value = float(s)
	_syncing = false
	sim_val.text = str(s)
	Settings.set_value("sim_dist", s)
	Settings.apply_sim_distance()
	# AC-0261: the low-start band starts at the sim distance.
	_sync_lowstart_range()


func _on_volume_changed(v: float) -> void:
	if _syncing:
		return
	volume_val.text = str(int(v))
	Settings.set_value("volume", int(v))
	Settings.apply_audio()


func _on_flight_changed(v: float) -> void:
	if _syncing:
		return
	flight_val.text = str(int(v)) + "x"
	Settings.set_value("flight_speed", int(v))


# AC-0225: the per-frame streaming chunk-mesh handoff burst (the AC-0224
# drain cap). world.gd's drain reads Settings "chunks_per_frame" every
# process frame, so saving it here is the whole apply — no extra call.
func _on_chunk_changed(v: float) -> void:
	if _syncing:
		return
	chunk_val.text = str(int(v))
	Settings.set_value("chunks_per_frame", int(v))


func _on_tier0_changed(v: float) -> void:
	if _syncing:
		return
	tier0_val.text = str(int(v))
	Settings.set_value("tier0_radius", int(v))
	Settings.apply_tier0_radius()


func _on_gen_threads_changed(v: float) -> void:
	if _syncing:
		return
	gen_val.text = "auto" if int(v) == 0 else str(int(v))
	Settings.set_value("worker_gen_threads", int(v))
	Settings.apply_worker_threads()


func _on_mesh_threads_changed(v: float) -> void:
	if _syncing:
		return
	mesh_val.text = "auto" if int(v) == 0 else str(int(v))
	Settings.set_value("worker_mesh_threads", int(v))
	Settings.apply_worker_threads()


func _on_fogstart_changed(v: float) -> void:
	if _syncing:
		return
	fogstart_val.text = str(int(v)) + "%"
	Settings.set_value("fog_start_pct", int(v))


# AC-0261: the med/low band split — the 4x4x4 LOW band's start distance
# (taxi chunks; the sim_dist slider pattern: set + apply, live update).
# The value lives in the VISIBLE band [sim, render] (MED = [sim, low_start),
# LOW = [low_start, render]); the slider range is set by
# _sync_lowstart_range, so the drag value is already in band (the clampi
# is belt-and-braces) — no slider-range rewrite here (the old far-ring
# rewrite is what made the value jump out of band on every click).
func _on_lowstart_changed(v: float) -> void:
	if _syncing:
		return
	var lo := mini(int(Settings.values["sim_dist"]), int(Settings.values["render_dist"]))
	var hi := int(Settings.values["render_dist"])
	var s := clampi(int(v), lo, hi)
	lowstart_val.text = str(s)
	Settings.set_value("low_start", s)
	Settings.apply_low_start()


func _on_res_selected(i: int) -> void:
	if _syncing:
		return
	var s: String = res_option.get_item_text(i)
	if s.ends_with(" (current)"):
		s = s.trim_suffix(" (current)")
	Settings.set_value("resolution", s)
	Settings.apply_window(get_window())


func _on_full_toggled(on: bool) -> void:
	if _syncing:
		return
	Settings.set_value("fullscreen", on)
	Settings.apply_window(get_window())


func _on_hunger_toggled(on: bool) -> void:
	if _syncing:
		return
	Settings.set_value("hunger_enabled", on)


func _on_debug_stats_toggled(on: bool) -> void:
	if _syncing:
		return
	Settings.set_value("debug_stats", on)


func _on_debug_log_toggled(on: bool) -> void:
	if _syncing:
		return
	Settings.set_value("debug_logging", on)


func _on_overlay_band_toggled(on: bool) -> void:
	if _syncing:
		return
	Settings.set_value("overlay_band", on)


func _on_overlay_light_toggled(on: bool) -> void:
	if _syncing:
		return
	Settings.set_value("overlay_light", on)


func _on_overlay_collision_toggled(on: bool) -> void:
	if _syncing:
		return
	Settings.set_value("overlay_collision", on)
