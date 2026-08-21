extends CanvasLayer

const AtlasScript = preload("res://core/atlas.gd")

const OVERLAY_BG := Color(0.0, 0.0, 0.0, 0.72)
const MENU_BG := Color(0.055, 0.055, 0.078, 1.0)
const TITLE_C := Color(1.0, 1.0, 1.0, 1.0)
const SUB_C := Color(0.75, 0.75, 0.78, 1.0)
const HELP_C := Color(0.62, 0.62, 0.66, 1.0)
const RES_MODES := ["1280x720", "1600x900", "1920x1080", "2560x1440"]

var on_play: Callable
var on_new_world: Callable
var on_resume: Callable
var on_quit_to_menu: Callable

var main_box: Control
var pause_box: Control
var options_box: Control
var main_status: Label
var opt_status: Label
var seed_edit: LineEdit
var render_slider: HSlider
var sim_slider: HSlider
var volume_slider: HSlider
var render_val: Label
var sim_val: Label
var volume_val: Label
var res_option: OptionButton
var full_check: CheckBox
var file_dialog: FileDialog
var _options_from := "main"
var _is_web := false
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
	_is_web = OS.has_feature("web")
	layer = 20
	_build_main()
	_build_pause()
	_build_options()
	add_child(main_box)
	add_child(pause_box)
	add_child(options_box)
	file_dialog = FileDialog.new()
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	if not _is_web:
		file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.add_filter("*.zip ; *.mcpack ; *.mcpr")
	file_dialog.file_selected.connect(_on_pack_file_selected)
	add_child(file_dialog)
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
	print("OPTSYNC from=%s render=%d sim=%d vol=%d res=%s full=%s" % [
		source,
		int(Settings.values["render_dist"]),
		int(Settings.values["sim_dist"]),
		int(Settings.values["volume"]),
		String(Settings.values["resolution"]),
		bool(Settings.values["fullscreen"]),
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


func _open_pack_dialog() -> void:
	if _is_web:
		return
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
	sim_slider.value = float(int(Settings.values["sim_dist"]))
	volume_slider.value = float(int(Settings.values["volume"]))
	render_val.text = str(int(render_slider.value))
	sim_val.text = str(int(sim_slider.value))
	volume_val.text = str(int(volume_slider.value))
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
	_syncing = false


func _on_render_changed(v: float) -> void:
	if _syncing:
		return
	render_val.text = str(int(v))
	Settings.set_value("render_dist", int(v))
	Settings.apply_render_distance()


func _on_sim_changed(v: float) -> void:
	if _syncing:
		return
	sim_val.text = str(int(v))
	Settings.set_value("sim_dist", int(v))
	Settings.apply_sim_distance()


func _on_volume_changed(v: float) -> void:
	if _syncing:
		return
	volume_val.text = str(int(v))
	Settings.set_value("volume", int(v))
	Settings.apply_audio()


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


func _mk_btn(text: String, cb: Callable, w: float = -1.0) -> Button:
	var b := Button.new()
	b.text = text
	if w >= 0.0:
		b.custom_minimum_size = Vector2(w, 40.0)
		b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	else:
		b.custom_minimum_size = Vector2(0, 40.0)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_font_size_override("font_size", 17)
	if cb.is_valid():
		b.pressed.connect(cb)
	return b


func _full_box() -> Control:
	var c := Control.new()
	c.size = get_viewport().get_visible_rect().size
	var cb := func() -> void: c.size = get_viewport().get_visible_rect().size
	get_viewport().size_changed.connect(cb)
	return c


func _mk_full_bg(color: Color) -> ColorRect:
	var c := ColorRect.new()
	c.color = color
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	return c


func _build_main() -> void:
	main_box = _full_box()
	main_box.add_child(_mk_full_bg(MENU_BG))
	main_status = Label.new()
	main_status.add_theme_font_size_override("font_size", 13)
	main_status.add_theme_color_override("font_color", SUB_C)
	main_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# centered fixed-width column (MC-menu-like); holds at any resolution
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var vb := VBoxContainer.new()
	vb.custom_minimum_size = Vector2(720.0, 0)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 10)
	center.add_child(vb)
	main_box.add_child(center)
	var title := Label.new()
	title.text = "AweCraft"
	title.add_theme_font_size_override("font_size", 52)
	title.add_theme_color_override("font_color", TITLE_C)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)
	var sub := Label.new()
	sub.text = "a minecraft-ish voxel sandbox"
	sub.add_theme_font_size_override("font_size", 15)
	sub.add_theme_color_override("font_color", SUB_C)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(sub)
	var ver := Label.new()
	ver.text = "AweCraft[" + Build.ID + "]"
	ver.add_theme_font_size_override("font_size", 13)
	ver.add_theme_color_override("font_color", HELP_C)
	ver.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(ver)
	vb.add_child(Control.new())
	vb.add_child(_mk_btn("Play", play_clicked))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	seed_edit = LineEdit.new()
	seed_edit.placeholder_text = "world seed (optional)"
	seed_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	seed_edit.custom_minimum_size = Vector2(0, 34.0)
	seed_edit.text = str(int(Settings.values.get("seed", 44)))
	row.add_child(seed_edit)
	row.add_child(_mk_btn("New World", new_world_clicked, 130.0))
	vb.add_child(row)
	vb.add_child(_mk_btn("Options", func(): open_options("main")))
	var packb := _mk_btn("Load Texture Pack (.mcpack / .zip)", _open_pack_dialog)
	if _is_web:
		packb.disabled = true
		packb.tooltip_text = "Unavailable in the web build"
	vb.add_child(packb)
	vb.add_child(main_status)
	# help line: centered bottom strip, allowed to run wider than the column
	var help := Label.new()
	help.text = "WASD move · Space jump/swim · F fly · G day/night · P pause · Left click mine/attack · Right click place/use · E inventory · 1-9/scroll select"
	help.add_theme_font_size_override("font_size", 12)
	help.add_theme_color_override("font_color", HELP_C)
	help.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	help.anchor_left = 0.0
	help.anchor_top = 1.0
	help.anchor_right = 1.0
	help.anchor_bottom = 1.0
	help.offset_top = -36.0
	help.offset_bottom = 0.0
	main_box.add_child(help)


func _build_pause() -> void:
	pause_box = _full_box()
	pause_box.visible = false
	pause_box.add_child(_mk_full_bg(OVERLAY_BG))
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var vb := VBoxContainer.new()
	vb.custom_minimum_size = Vector2(480.0, 0)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 12)
	center.add_child(vb)
	pause_box.add_child(center)
	var t := Label.new()
	t.text = "Game Paused"
	t.add_theme_font_size_override("font_size", 34)
	t.add_theme_color_override("font_color", TITLE_C)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(t)
	vb.add_child(_mk_btn("Back to Game", _on_resume_btn_pressed))
	vb.add_child(_mk_btn("Options", func(): open_options("pause")))
	vb.add_child(_mk_btn("Quit to Menu", _on_quit_btn_pressed))
	var hint := Label.new()
	hint.text = "P or Esc resumes"
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", HELP_C)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(hint)


func _options_row(vb: VBoxContainer, label_text: String, slider: HSlider, val: Label) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var l := Label.new()
	l.text = label_text
	l.add_theme_font_size_override("font_size", 15)
	l.custom_minimum_size = Vector2(170.0, 0)
	row.add_child(l)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.step = 1.0
	slider.custom_minimum_size = Vector2(0, 24.0)
	row.add_child(slider)
	val = _val_label(val)
	val.custom_minimum_size = Vector2(44.0, 0)
	row.add_child(val)
	vb.add_child(row)


func _val_label(val: Label) -> Label:
	val.add_theme_font_size_override("font_size", 15)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	return val


func _build_options() -> void:
	options_box = _full_box()
	options_box.visible = false
	options_box.add_child(_mk_full_bg(OVERLAY_BG))
	var center := Control.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var vb := VBoxContainer.new()
	vb.size = Vector2(560, 0)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 12)
	var c := CenterContainer.new()
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.add_child(vb)
	center.add_child(c)
	options_box.add_child(center)
	var t := Label.new()
	t.text = "Options"
	t.add_theme_font_size_override("font_size", 26)
	t.add_theme_color_override("font_color", TITLE_C)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(t)
	render_slider = HSlider.new()
	render_slider.min_value = 1.0
	render_slider.max_value = 8.0
	render_slider.value_changed.connect(_on_render_changed)
	render_val = Label.new()
	_options_row(vb, "Render distance (chunks)", render_slider, render_val)
	sim_slider = HSlider.new()
	sim_slider.min_value = 1.0
	sim_slider.max_value = 8.0
	sim_slider.value_changed.connect(_on_sim_changed)
	sim_val = Label.new()
	_options_row(vb, "Simulation distance (chunks)", sim_slider, sim_val)
	volume_slider = HSlider.new()
	volume_slider.min_value = 0.0
	volume_slider.max_value = 100.0
	volume_slider.value_changed.connect(_on_volume_changed)
	volume_val = Label.new()
	_options_row(vb, "Sound volume (%)", volume_slider, volume_val)
	var rrow := HBoxContainer.new()
	rrow.add_theme_constant_override("separation", 10)
	var rl := Label.new()
	rl.text = "Resolution"
	rl.add_theme_font_size_override("font_size", 15)
	rl.custom_minimum_size = Vector2(170.0, 0)
	rrow.add_child(rl)
	res_option = OptionButton.new()
	res_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	res_option.item_selected.connect(_on_res_selected)
	rrow.add_child(res_option)
	vb.add_child(rrow)
	full_check = CheckBox.new()
	full_check.text = "Fullscreen"
	full_check.add_theme_font_size_override("font_size", 15)
	full_check.toggled.connect(_on_full_toggled)
	vb.add_child(full_check)
	var packb := _mk_btn("Load Texture Pack (.mcpack / .zip)", _open_pack_dialog, 560.0)
	if _is_web:
		packb.disabled = true
		packb.tooltip_text = "Unavailable in the web build (web packs need an in-memory swap that this build does not do yet)"
	vb.add_child(packb)
	opt_status = Label.new()
	opt_status.add_theme_font_size_override("font_size", 13)
	opt_status.add_theme_color_override("font_color", SUB_C)
	opt_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(opt_status)
	vb.add_child(_mk_btn("Back", close_options, 200.0))
