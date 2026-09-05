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
var debug_check: CheckBox
var file_dialog: FileDialog
var _options_from := "main"
var _syncing := false
# visibility state machine: exactly one of the boxes may be visible;
# "ingame" = menu layer hidden entirely (except pause, via show_pause)
var _state := "main"


func _apply_state() -> void:
	if main_box != null:
		main_box.visible = _state == "main"
	if pause_box != null:
		pause_box.visible = _state == "pause"
	if options_box != null:
		options_box.visible = _state == "opt_main" or _state == "opt_pause"
	visible = _state != "ingame"


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
	print("OPTSYNC from=%s render=%d sim=%d vol=%d res=%s full=%s hunger=%s stats=%s chunk=%d" % [
		source,
		int(Settings.values["render_dist"]),
		int(Settings.values["sim_dist"]),
		int(Settings.values["volume"]),
		String(Settings.values["resolution"]),
		bool(Settings.values["fullscreen"]),
		bool(Settings.values["hunger_enabled"]),
		bool(Settings.values["debug_stats"]),
		int(Settings.values.get("chunks_per_frame", 3)),
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
	Settings.apply_render_distance()
	Settings.apply_sim_distance()


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
