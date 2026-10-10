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
var chunk_slider: HSlider
var render_val: Label
var sim_val: Label
var volume_val: Label
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
var fog_enabled_check: CheckBox
# AC-0389: the ambient sound bed toggle (default OFF) — Settings-page
# row, the code-created checkbox pattern (fog_enabled above).
var ambient_check: CheckBox
# AC-0205: the smooth-ground-ramps toggle (Settings page).
var ramp_check: CheckBox
# AC-0398: the modern per-vertex lighting toggle (Settings page, default ON).
var modern_check: CheckBox
# AC-0401: the cloud deck character toggle (Settings page, default ON -
# the user asked for the fewer/bigger/volumetric look).
var cloud_deck_check: CheckBox
# AC-0401: the limb-glow altitude gate (Settings page, default ON - the
# user asked for the fog-only near field).
var limb_gate_check: CheckBox
# AC-0402: the sky's altitude-aware space blend (Settings page, default
# ON - the user story asks for the sky to thin with the climb).
var sky_alt_check: CheckBox
# AC-0405: the raymarched-volumetric-clouds toggle (Settings page,
# default ON - the user ordered the rework).
var cloud_vol_check: CheckBox
# AC-0394: the held-item occlusion toggle (Settings page, default OFF -
# conservative: the user reported the SIZE, not the occlusion).
var vm_occ_check: CheckBox
# AC-0395: the noclip toggle (Settings page, default OFF - the shipped
# state is exactly today's behaviour; the indicator + this row make an
# ON state obvious, a debug tool must not be left on by accident).
var noclip_check: CheckBox
# AC-0252: the med/low band split slider — the distance (taxi chunks)
# where the 4x4x4 LOW avg-color band starts (the 8x8x8 MED tier owns
# everything closer; the low band runs out to the render edge).
var lowstart_slider: HSlider
var lowstart_val: Label
# AC-0263: the "mid LOD distance" slider — the distance (taxi chunks)
# where the MED avg-color band BEGINS, i.e. the HIGH band's outer edge.
# The high band [0, medium_start) builds full-res per-slab (the tier-0
# ball's columns first); the value must stay > the sim distance (which
# no longer controls world generation).
var midstart_slider: HSlider
var midstart_val: Label
# AC-0260: the "Developer" TAB of the options panel (tier-0 radius + the
# worker-thread caps; the per-frame instance cap row moves here from the
# Settings page). No checkbox: it is a TabContainer page.
var dev_page: VBoxContainer
# AC-0260 fix: the perf knobs are SpinBoxes (typeable — the user wanted to
# enter a number, not fight a slider; the HSlider rows also misbehaved in
# the broken tab layout). (AC-0313: the tier-0 radius row is gone with the
# tier-0 set — see the "Tier0Row" removal below.)
var gen_spin: SpinBox
var gen_val: Label
var mesh_spin: SpinBox
var mesh_val: Label
var subcruise_spin: SpinBox
var subcruise_val: Label
var cruisealt_spin: SpinBox
var cruisealt_val: Label
var cruise_spin: SpinBox
var cruise_val: Label
# AC-0281: DOF developer controls
var dof_enabled_check: CheckBox
var dof_far_spin: SpinBox
var dof_far_val: Label
var dof_amount_spin: SpinBox
var dof_amount_val: Label
# AC-0332: the far-tier mesh floor (AC-0331's kernel) — the on/off
# toggle + the chunks-below-sea SpinBox (0..Settings.YFLOOR_MAX).
# SpinBox rather than HSlider follows the recorded AC-0260 fix: the
# Developer page's earlier HSlider rows were replaced because the tab
# layout squashed them and an exact small integer such as 0 was not
# reliably reachable by dragging.
var yfloor_enabled_check: CheckBox
var yfloor_spin: SpinBox
var yfloor_val: Label
# AC-0088: the Controls tab (the third OptTabs page, code-built like
# the Developer page) - per-action press-to-capture rebind rows, the
# conflict status line, the per-action and global resets. The remap
# LOGIC lives in core/controls_map.gd + settings.gd (the `controls`
# arm drives the same API).
var controls_page: VBoxContainer
var ctl_status: Label
var _ctl_rebinds: Dictionary = {}  # action -> {cls -> Button}
var _ctl_resets: Dictionary = {}   # action -> Button
var _capturing: Dictionary = {}    # {action, cls} while a capture is open
# AC-0089: the Controls-tab "Analog tuning" group (code-built like the
# remap rows above it). The LOGIC + bounds live in core/analog_tune.gd;
# the settings round-trip in settings.gd (the `analog` + `settings`
# arms drive the same API/rows). SpinBoxes, not HSliders: the AC-0260
# fix (the HSlider rows misbehaved in the tabbed options).
# (each *_spin row holds the _mk_analog_spin_row result: [SpinBox, Label])
var analog_sens_spin: Array
var analog_sens_val: Label
var analog_dz_left_spin: Array
var analog_dz_left_val: Label
var analog_dz_right_spin: Array
var analog_dz_right_val: Label
var analog_invert_y_check: CheckBox
var analog_invert_x_check: CheckBox
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
	render_val = get_node("Layer/OptionsBox/Center/VBox/RenderRow/RenderVal")
	sim_val = get_node("Layer/OptionsBox/Center/VBox/SimRow/SimVal")
	volume_val = get_node("Layer/OptionsBox/Center/VBox/VolumeRow/VolumeVal")
	chunk_slider = get_node("Layer/OptionsBox/Center/VBox/ChunkRow/ChunkSlider")
	chunk_val = get_node("Layer/OptionsBox/Center/VBox/ChunkRow/ChunkVal")
	res_option = get_node("Layer/OptionsBox/Center/VBox/ResRow/ResOption")
	full_check = get_node("Layer/OptionsBox/Center/VBox/FullscreenCheck")
	hunger_check = get_node("Layer/OptionsBox/Center/VBox/HungerCheck")
	fogstart_slider = get_node("Layer/OptionsBox/Center/VBox/FogStartRow/FogStartSlider")
	fogstart_val = get_node("Layer/OptionsBox/Center/VBox/FogStartRow/FogStartVal")
	lowstart_slider = get_node("Layer/OptionsBox/Center/VBox/LowStartRow/LowStartSlider")
	lowstart_val = get_node("Layer/OptionsBox/Center/VBox/LowStartRow/LowStartVal")
	midstart_slider = get_node("Layer/OptionsBox/Center/VBox/MidStartRow/MidStartSlider")
	midstart_val = get_node("Layer/OptionsBox/Center/VBox/MidStartRow/MidStartVal")
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
	fog_enabled_check = CheckBox.new()
	fog_enabled_check.name = "FogEnabledCheck"
	fog_enabled_check.text = "Enable fog"
	fog_enabled_check.add_theme_font_size_override("font_size", 15)
	fog_enabled_check.toggled.connect(_on_fog_enabled_toggled)
	opt_vbox.add_child(fog_enabled_check)
	if hi + 5 < opt_vbox.get_child_count():
		opt_vbox.move_child(fog_enabled_check, hi + 6)
	# AC-0389: the ambient sound bed (AC-0039's looping wind) — user-facing
	# audio setting on the Settings page (next to the other toggles),
	# persisted like every other setting (Settings "ambient_enabled",
	# default OFF).
	ambient_check = CheckBox.new()
	ambient_check.name = "AmbientCheck"
	ambient_check.text = "Ambient sound (background wind bed)"
	ambient_check.add_theme_font_size_override("font_size", 15)
	ambient_check.toggled.connect(_on_ambient_toggled)
	opt_vbox.add_child(ambient_check)
	if hi + 6 < opt_vbox.get_child_count():
		opt_vbox.move_child(ambient_check, hi + 7)
	# AC-0205: the smooth-ground-ramps toggle — user-facing visual setting
	# on the Settings page (next to the ambient bed), persisted like every
	# other setting (Settings "smooth_ramps", default OFF). The apply step
	# rides Settings.set_value -> world.note_ramps (the ctx flag + the
	# full re-mesh through the tex-refresh drain).
	ramp_check = CheckBox.new()
	ramp_check.name = "RampCheck"
	ramp_check.text = "Smooth ground ramps (dirt / grass / sand steps)"
	ramp_check.add_theme_font_size_override("font_size", 15)
	ramp_check.toggled.connect(_on_ramp_toggled)
	opt_vbox.add_child(ramp_check)
	if hi + 7 < opt_vbox.get_child_count():
		opt_vbox.move_child(ramp_check, hi + 8)
	# AC-0398: the modern per-vertex lighting toggle — user-facing visual
	# setting on the Settings page (next to the ramps toggle), persisted
	# like every other setting (Settings "modern_light", default ON — the
	# user asked for the interpolated look). The apply step rides
	# Settings.set_value -> world.note_modern (the ctx flag + the full
	# re-mesh through the tex-refresh drain; colour-only, the collider is
	# untouched).
	modern_check = CheckBox.new()
	modern_check.name = "ModernCheck"
	modern_check.text = "Modern vertex lighting (smooth light gradients)"
	modern_check.add_theme_font_size_override("font_size", 15)
	modern_check.toggled.connect(_on_modern_toggled)
	opt_vbox.add_child(modern_check)
	if hi + 8 < opt_vbox.get_child_count():
		opt_vbox.move_child(modern_check, hi + 9)
	# AC-0401: the cloud deck character toggle — user-facing visual
	# setting on the Settings page (next to the modern lighting),
	# persisted like every other setting (Settings "cloud_deck", default
	# ON - the user asked for the new look). No apply step is owed:
	# world.gd _ac0401_push reads the live value every frame and pushes
	# u_deck to the three cloud-layer materials (0.0 = the pre-AC-0401
	# field and windows, 1.0 = the re-characterised deck).
	cloud_deck_check = CheckBox.new()
	cloud_deck_check.name = "CloudDeckCheck"
	cloud_deck_check.text = "Clouds: fewer, bigger, volumetric masses"
	cloud_deck_check.add_theme_font_size_override("font_size", 15)
	cloud_deck_check.toggled.connect(_on_cloud_deck_toggled)
	opt_vbox.add_child(cloud_deck_check)
	if hi + 9 < opt_vbox.get_child_count():
		opt_vbox.move_child(cloud_deck_check, hi + 10)
	# AC-0401: the limb-glow altitude gate — the atmospheric rim is an
	# orbit instrument; ON (default, the user asked) gates it on the
	# flight-band blend (no rim near the ground, full rim from orbit),
	# OFF is the pre-AC-0401 glow at every altitude. Same _ac0401_push
	# seam (u_limb_gate on the sky material).
	limb_gate_check = CheckBox.new()
	limb_gate_check.name = "LimbGateCheck"
	limb_gate_check.text = "Planet limb glow: orbit only"
	limb_gate_check.add_theme_font_size_override("font_size", 15)
	limb_gate_check.toggled.connect(_on_limb_gate_toggled)
	opt_vbox.add_child(limb_gate_check)
	if hi + 10 < opt_vbox.get_child_count():
		opt_vbox.move_child(limb_gate_check, hi + 11)
	# AC-0402: the sky's altitude-aware space blend toggle — "bright air
	# near the ground, thinning to space as you climb" (default ON, the
	# user story). Same seam: world.gd _ac0401_push reads the live value
	# and pushes u_sky_alt + u_space_sky to the sky material (OFF = the
	# exact pre-AC-0402 sky, the short-circuit is the shader side).
	sky_alt_check = CheckBox.new()
	sky_alt_check.name = "SkyAltCheck"
	sky_alt_check.text = "Sky thins to space as you climb"
	sky_alt_check.add_theme_font_size_override("font_size", 15)
	sky_alt_check.toggled.connect(_on_sky_alt_toggled)
	opt_vbox.add_child(sky_alt_check)
	if hi + 11 < opt_vbox.get_child_count():
		opt_vbox.move_child(sky_alt_check, hi + 12)
	# AC-0405: the raymarched-volumetric-clouds toggle — the user's own
	# words ("the clouds should look like real clouds... forget how we
	# currently do it"), default ON (the rework was ordered). Same seam
	# as cloud_deck: no apply step is owed — world.gd _ac0401_push reads
	# the live value every frame and pushes u_vol + the annulus radii
	# (0.0 = the exact AC-0401 three-shell deck, 1.0 = the raymarched
	# density volume in the verified [R+275, R+400] annulus).
	cloud_vol_check = CheckBox.new()
	cloud_vol_check.name = "CloudVolCheck"
	cloud_vol_check.text = "Clouds: raymarched volume (real depth)"
	cloud_vol_check.add_theme_font_size_override("font_size", 15)
	cloud_vol_check.toggled.connect(_on_cloud_vol_toggled)
	opt_vbox.add_child(cloud_vol_check)
	if hi + 12 < opt_vbox.get_child_count():
		opt_vbox.move_child(cloud_vol_check, hi + 13)
	# AC-0394: the held-item occlusion toggle — the viewmodel's
	# no_depth_test made the hand draw OVER terrain (the 2026-10-03
	# report's residual H2), so ON re-enables the depth test (the hand is
	# occluded by terrain; sky never occludes). DEFAULTS OFF —
	# conservative: the user reported the SIZE, not the occlusion, so the
	# look change the user has NOT asked for defaults to the pre-change
	# look (the AC-0205/AC-0398 rule). No apply step is owed: player.gd
	# reads the live value every frame and re-applies the material flag on
	# change (the cloud_deck/limb_space pattern).
	vm_occ_check = CheckBox.new()
	vm_occ_check.name = "VmOccCheck"
	vm_occ_check.text = "Held item: occluded by terrain"
	vm_occ_check.add_theme_font_size_override("font_size", 15)
	vm_occ_check.toggled.connect(_on_vm_occ_toggled)
	opt_vbox.add_child(vm_occ_check)
	if hi + 13 < opt_vbox.get_child_count():
		opt_vbox.move_child(vm_occ_check, hi + 14)
	# AC-0395: the noclip toggle (the user's own request — a switch that
	# disables the player's collision so they can fly through blocks and
	# inspect geometry). Same seam as every other player-facing switch:
	# persisted like every other setting (Settings "noclip", default OFF —
	# the shipped state is exactly today's behaviour, and a debug tool
	# must not be left on by accident), the row re-syncs from
	# _sync_controls, no apply step owed (player.gd reads the live value
	# and applies on change — the viewmodel_occlude pattern).
	noclip_check = CheckBox.new()
	noclip_check.name = "NoclipCheck"
	noclip_check.text = "Noclip — fly through blocks"
	noclip_check.add_theme_font_size_override("font_size", 15)
	noclip_check.toggled.connect(_on_noclip_toggled)
	opt_vbox.add_child(noclip_check)
	if hi + 14 < opt_vbox.get_child_count():
		opt_vbox.move_child(noclip_check, hi + 15)
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
	# AC-0260 fix (the broken-tabs bug): opt_vbox is still seated in its
	# tscn parent (opt_center) — add_child into the tab WITHOUT removing it
	# first is a runtime error (logged, non-fatal) that silently left the
	# Settings page out of the TabContainer. Remove from the old parent
	# first, then reparent.
	opt_center.remove_child(opt_vbox)
	opt_tabs.add_child(opt_vbox)
	dev_page = VBoxContainer.new()
	dev_page.name = "Developer"
	dev_page.add_theme_constant_override("separation", 6)
	opt_vbox.remove_child(chunk_row)
	dev_page.add_child(chunk_row)
	# AC-0313: the "Tier0Row" Developer spinbox is GONE with the tier-0 set
	# (the real band taxi ≤ sim is the footing guarantee; the sim floor is
	# 4 in Settings.SIM_MIN).
	var genr := _mk_dev_spin_row(dev_page, "GenThreadsRow", "Worker threads gen (0 = auto)", 0.0, float(Settings.WORKER_THREADS_MAX))
	gen_spin = genr[0]
	gen_val = genr[1]
	var meshr := _mk_dev_spin_row(dev_page, "MeshThreadsRow", "Worker threads mesh (0 = auto)", 0.0, float(Settings.WORKER_THREADS_MAX))
	mesh_spin = meshr[0]
	mesh_val = meshr[1]
	var scr := _mk_dev_spin_row(dev_page, "SubCruiseRow", "Sub-cruising speed (x walk)", 1.0, 20.0)
	subcruise_spin = scr[0]
	subcruise_val = scr[1]
	var car := _mk_dev_spin_row(dev_page, "CruiseAltRow", "Cruising altitude", 0.0, 384.0)
	cruisealt_spin = car[0]
	cruisealt_val = car[1]
	var cr := _mk_dev_spin_row(dev_page, "CruiseRow", "Cruising speed (x walk)", 1.0, 20.0)
	cruise_spin = cr[0]
	cruise_val = cr[1]
	# AC-0281: DOF developer controls
	dof_enabled_check = CheckBox.new()
	dof_enabled_check.name = "DOFEnabledCheck"
	dof_enabled_check.text = "DOF enabled"
	dof_enabled_check.add_theme_font_size_override("font_size", 15)
	dof_enabled_check.toggled.connect(_on_dof_enabled_toggled)
	dev_page.add_child(dof_enabled_check)
	var doff := _mk_dev_spin_row(dev_page, "DOFFarRow", "DOF far distance", 1.0, 400.0)
	dof_far_spin = doff[0]
	dof_far_val = doff[1]
	dof_far_spin.step = 1.0
	var dofa := _mk_dev_spin_row(dev_page, "DOFAmountRow", "DOF strength", 0.0, 1.0)
	dof_amount_spin = dofa[0]
	dof_amount_val = dofa[1]
	dof_amount_spin.step = 0.01
	# AC-0332: the far-tier mesh floor (AC-0331's kernel) — the on/off
	# toggle + the chunks-below-sea row. The DOF precedent
	# (dof_enabled_check + dof_far_distance) for the dependent-control
	# wiring: the SpinBox dims + disables while the toggle is off.
	yfloor_enabled_check = CheckBox.new()
	yfloor_enabled_check.name = "YFloorCheck"
	yfloor_enabled_check.text = "Far-tier mesh floor"
	yfloor_enabled_check.add_theme_font_size_override("font_size", 15)
	yfloor_enabled_check.toggled.connect(_on_yfloor_enabled_toggled)
	dev_page.add_child(yfloor_enabled_check)
	var yfr := _mk_dev_spin_row(dev_page, "YFloorRow", "Far floor chunks below sea", 0.0, float(Settings.YFLOOR_MAX))
	yfloor_spin = yfr[0]
	yfloor_val = yfr[1]
	yfloor_spin.step = 1.0
	yfloor_spin.value_changed.connect(_on_yfloor_chunks_changed)
	gen_spin.value_changed.connect(_on_gen_threads_changed)
	mesh_spin.value_changed.connect(_on_mesh_threads_changed)
	subcruise_spin.value_changed.connect(_on_subcruise_changed)
	cruisealt_spin.value_changed.connect(_on_cruisealt_changed)
	cruise_spin.value_changed.connect(_on_cruise_changed)
	dof_far_spin.value_changed.connect(_on_dof_far_changed)
	dof_amount_spin.value_changed.connect(_on_dof_amount_changed)
	opt_tabs.add_child(dev_page)
	# AC-0088: the "Controls" page - the AC-0260 tabbed-options
	# precedent (code-built, like the Developer page). Every managed
	# action gets a row: one rebind Button per input CLASS the action
	# actually uses (key / mouse / pad - the stick motions are
	# protected and never offered), plus a per-action Reset.
	controls_page = VBoxContainer.new()
	controls_page.name = "Controls"
	controls_page.add_theme_constant_override("separation", 5)
	var ctl_all_reset := Button.new()
	ctl_all_reset.name = "ControlsResetAll"
	ctl_all_reset.text = "Reset ALL bindings to defaults"
	ctl_all_reset.add_theme_font_size_override("font_size", 15)
	ctl_all_reset.pressed.connect(_on_controls_reset_all)
	controls_page.add_child(ctl_all_reset)
	ctl_status = Label.new()
	ctl_status.name = "ControlsStatus"
	ctl_status.add_theme_font_size_override("font_size", 14)
	ctl_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ctl_status.text = "Click a binding to rebind it - press the key, mouse button, or pad button you want. Conflicts are reported, never silently shadowed."
	controls_page.add_child(ctl_status)
	for g in ControlsMap.MANAGED_GROUPS:
		var gh := Label.new()
		gh.name = "CtrlGroup_" + str(g[0]).replace(" ", "_").replace("&", "")
		gh.text = g[0]
		gh.add_theme_font_size_override("font_size", 14)
		gh.modulate = Color(0.88, 0.88, 0.94, 1.0)
		controls_page.add_child(gh)
		for a in g[1]:
			controls_page.add_child(_mk_ctl_row(a))
	# AC-0089: the "Analog tuning" group — stick tuning for the two input
	# paths (the right-stick look: deadzone + invert X/Y + sensitivity;
	# the left-stick movement: its own deadzone). Same row pattern as the
	# remap rows (named rows, value label), same persist path (Settings.
	# set_value on change — clamp + save in one step; the player applies
	# the values live at its input paths, no apply step needed).
	var agh := Label.new()
	agh.name = "AnalogGroup"
	agh.text = "Analog tuning (sticks)"
	agh.add_theme_font_size_override("font_size", 14)
	agh.modulate = Color(0.88, 0.88, 0.94, 1.0)
	controls_page.add_child(agh)
	analog_sens_spin = _mk_analog_spin_row(controls_page, "AnalogSensRow", "Look sensitivity (right stick)", float(AnalogTune.SENS_MIN), float(AnalogTune.SENS_MAX), 0.05)
	analog_sens_spin[0].value_changed.connect(_on_analog_sens_changed)
	analog_sens_val = analog_sens_spin[1]
	analog_dz_left_spin = _mk_analog_spin_row(controls_page, "AnalogDzLeftRow", "Deadzone — left stick (movement)", float(AnalogTune.DZ_MIN), float(AnalogTune.DZ_MAX), 0.01)
	analog_dz_left_spin[0].value_changed.connect(_on_analog_dz_left_changed)
	analog_dz_left_val = analog_dz_left_spin[1]
	analog_dz_right_spin = _mk_analog_spin_row(controls_page, "AnalogDzRightRow", "Deadzone — right stick (look)", float(AnalogTune.DZ_MIN), float(AnalogTune.DZ_MAX), 0.01)
	analog_dz_right_spin[0].value_changed.connect(_on_analog_dz_right_changed)
	analog_dz_right_val = analog_dz_right_spin[1]
	var ainv := HBoxContainer.new()
	ainv.name = "AnalogInvertRow"
	ainv.add_theme_constant_override("separation", 10)
	var ainv_lab := Label.new()
	ainv_lab.text = "Invert (look)"
	ainv_lab.add_theme_font_size_override("font_size", 15)
	ainv_lab.custom_minimum_size = Vector2(250, 0)
	analog_invert_y_check = CheckBox.new()
	analog_invert_y_check.name = "AnalogInvertYCheck"
	analog_invert_y_check.text = "Y (up / down)"
	analog_invert_y_check.toggled.connect(_on_analog_invert_y_toggled)
	analog_invert_x_check = CheckBox.new()
	analog_invert_x_check.name = "AnalogInvertXCheck"
	analog_invert_x_check.text = "X (left / right)"
	analog_invert_x_check.toggled.connect(_on_analog_invert_x_toggled)
	var ainv_reset := Button.new()
	ainv_reset.name = "AnalogReset"
	ainv_reset.text = "Reset analog to defaults"
	ainv_reset.pressed.connect(_on_analog_reset_pressed)
	ainv.add_child(ainv_lab)
	ainv.add_child(analog_invert_y_check)
	ainv.add_child(analog_invert_x_check)
	ainv.add_child(ainv_reset)
	controls_page.add_child(ainv)
	opt_tabs.add_child(controls_page)
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
	Game.set_cursor(Input.MOUSE_MODE_VISIBLE)
	refresh_slots()


func show_pause() -> void:
	_state = "pause"
	_sync_controls()
	_apply_state()
	Game.set_cursor(Input.MOUSE_MODE_VISIBLE)


func open_options(source: String) -> void:
	_options_from = source
	_state = "opt_main" if source == "main" else "opt_pause"
	_sync_controls()
	_apply_state()
	Game.set_cursor(Input.MOUSE_MODE_VISIBLE)
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
# AC-0260 fix: the Developer-page perf-knob row — a SpinBox (TYPEABLE:
# click the field and type a number, or use the arrows; min/max clamp on
# commit). The earlier HSlider rows were replaced after the user could not
# drive them (the broken tab layout squashed the rows, and 0/auto was not
# reliably reachable by dragging).
func _mk_dev_spin_row(parent: Control, row_name: String, label_text: String, minv: float, maxv: float) -> Array:
	var row := HBoxContainer.new()
	row.name = row_name
	row.add_theme_constant_override("separation", 10)
	var lab := Label.new()
	lab.text = label_text
	lab.add_theme_font_size_override("font_size", 15)
	lab.custom_minimum_size = Vector2(250, 0)
	var sp := SpinBox.new()
	sp.custom_minimum_size = Vector2(90, 0)
	sp.min_value = minv
	sp.max_value = maxv
	sp.step = 1.0
	sp.value = minv
	var val := Label.new()
	val.add_theme_font_size_override("font_size", 15)
	val.custom_minimum_size = Vector2(44, 0)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(lab)
	row.add_child(sp)
	row.add_child(val)
	parent.add_child(row)
	return [sp, val]


# AC-0089: the analog tuning rows (float SpinBoxes with a STEP parameter
# — _mk_dev_spin_row is the int-step developer pattern and stays as is).
func _mk_analog_spin_row(parent: Control, row_name: String, label_text: String, minv: float, maxv: float, step: float) -> Array:
	var row := HBoxContainer.new()
	row.name = row_name
	row.add_theme_constant_override("separation", 10)
	var lab := Label.new()
	lab.text = label_text
	lab.add_theme_font_size_override("font_size", 15)
	lab.custom_minimum_size = Vector2(250, 0)
	var sp := SpinBox.new()
	sp.custom_minimum_size = Vector2(90, 0)
	sp.min_value = minv
	sp.max_value = maxv
	sp.step = step
	sp.value = minv
	var val := Label.new()
	val.add_theme_font_size_override("font_size", 15)
	val.custom_minimum_size = Vector2(44, 0)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(lab)
	row.add_child(sp)
	row.add_child(val)
	parent.add_child(row)
	return [sp, val]


func _sync_controls() -> void:
	_syncing = true
	render_slider.value = float(int(Settings.values["render_dist"]))
	sim_slider.max_value = float(int(Settings.values["render_dist"]))
	sim_slider.value = float(int(Settings.values["sim_dist"]))
	volume_slider.value = float(int(Settings.values["volume"]))
	chunk_slider.value = float(int(Settings.values.get("chunks_per_frame", 3)))
	render_val.text = str(int(render_slider.value))
	sim_val.text = str(int(sim_slider.value))
	volume_val.text = str(int(volume_slider.value))
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
	fog_enabled_check.button_pressed = bool(Settings.values.get("fog_enabled", true))
	# AC-0389: the ambient bed toggle (default OFF).
	ambient_check.button_pressed = bool(Settings.values.get("ambient_enabled", false))
	# AC-0205: the smooth-ground-ramps toggle (default OFF).
	ramp_check.button_pressed = bool(Settings.values.get("smooth_ramps", false))
	# AC-0398: the modern vertex lighting toggle (default ON).
	modern_check.button_pressed = bool(Settings.values.get("modern_light", true))
	# AC-0401: the deck character + the limb gate (both default ON).
	cloud_deck_check.button_pressed = bool(Settings.values.get("cloud_deck", true))
	limb_gate_check.button_pressed = bool(Settings.values.get("limb_space", true))
	# AC-0402: the sky's altitude-aware space blend (default ON).
	sky_alt_check.button_pressed = bool(Settings.values.get("sky_altitude", true))
	# AC-0405: the raymarched-volumetric-clouds toggle (default ON).
	cloud_vol_check.button_pressed = bool(Settings.values.get("cloud_volume", true))
	# AC-0394: the held-item occlusion toggle (default OFF).
	vm_occ_check.button_pressed = bool(Settings.values.get("viewmodel_occlude", false))
	# AC-0395: the noclip toggle (default OFF).
	noclip_check.button_pressed = bool(Settings.values.get("noclip", false))
	fogstart_slider.value = float(int(Settings.values["fog_start_pct"]))
	fogstart_slider.editable = bool(Settings.values.get("fog_enabled", true))
	fogstart_slider.modulate.a = 1.0 if bool(Settings.values.get("fog_enabled", true)) else 0.45
	fogstart_val.text = str(int(fogstart_slider.value)) + "%"
	# AC-0261: the low-start slider spans the visible band [sim, render].
	_sync_lowstart_range()
	# AC-0257: the Developer tab rows (AC-0260 fix: SpinBoxes).
	# (AC-0313: the tier0_spin/tier0_val refresh is gone with the row.)
	gen_spin.value = float(int(Settings.values.get("worker_gen_threads", 0)))
	gen_val.text = "auto" if int(gen_spin.value) == 0 else str(int(gen_spin.value))
	mesh_spin.value = float(int(Settings.values.get("worker_mesh_threads", 0)))
	mesh_val.text = "auto" if int(mesh_spin.value) == 0 else str(int(mesh_spin.value))
	subcruise_spin.value = float(int(Settings.values.get("sub_cruising_speed", 2)))
	subcruise_val.text = str(int(subcruise_spin.value)) + "x"
	cruisealt_spin.value = float(int(Settings.values.get("cruising_altitude", 275)))
	cruisealt_val.text = str(int(cruisealt_spin.value))
	cruise_spin.value = float(int(Settings.values.get("cruising_speed", 6)))
	cruise_val.text = str(int(cruise_spin.value)) + "x"
	# AC-0281: DOF developer controls
	dof_enabled_check.button_pressed = bool(Settings.values.get("dof_enabled", true))
	dof_far_spin.value = float(Settings.values.get("dof_far_distance", 82.62))
	dof_far_val.text = "%.1f" % float(dof_far_spin.value)
	dof_amount_spin.value = float(Settings.values.get("dof_amount", 0.08))
	dof_amount_val.text = "%.2f" % float(dof_amount_spin.value)
	dof_far_spin.editable = bool(Settings.values.get("dof_enabled", true))
	dof_far_spin.modulate.a = 1.0 if bool(Settings.values.get("dof_enabled", true)) else 0.45
	dof_amount_spin.editable = bool(Settings.values.get("dof_enabled", true))
	dof_amount_spin.modulate.a = 1.0 if bool(Settings.values.get("dof_enabled", true)) else 0.45
	# AC-0332: the far-tier mesh floor (Developer tab).
	yfloor_enabled_check.button_pressed = bool(Settings.values.get("yfloor_enabled", true))
	yfloor_spin.value = float(int(Settings.values.get("yfloor_chunks_below_sea", 0)))
	yfloor_val.text = str(int(yfloor_spin.value))
	yfloor_spin.editable = bool(Settings.values.get("yfloor_enabled", true))
	yfloor_spin.modulate.a = 1.0 if bool(Settings.values.get("yfloor_enabled", true)) else 0.45
	# AC-0088: the Controls tab rows (the current binding per class,
	# the same _sync_controls refresh the AC-0332 rows get). Skipped
	# mid-capture - the open capture owns its button's text.
	if controls_page != null and _capturing.is_empty():
		for a in _ctl_rebinds:
			for cls in _ctl_rebinds[a]:
				_ctl_rebinds[a][cls].text = _ctl_binding_label(a, cls)
	# AC-0089: the analog tuning rows (the same _sync_controls refresh the
	# AC-0332/AC-0088 rows get — the state the game guarantees whenever
	# the panel opens or a value changes elsewhere).
	if analog_sens_spin != null:
		analog_sens_spin[0].value = float(Settings.values.get("look_sensitivity", 1.0))
		analog_sens_val.text = "%.2fx" % float(analog_sens_spin[0].value)
		analog_dz_left_spin[0].value = float(Settings.values.get("deadzone_left", 0.15))
		analog_dz_left_val.text = "%.2f" % float(analog_dz_left_spin[0].value)
		analog_dz_right_spin[0].value = float(Settings.values.get("deadzone_right", 0.15))
		analog_dz_right_val.text = "%.2f" % float(analog_dz_right_spin[0].value)
		analog_invert_y_check.button_pressed = bool(Settings.values.get("invert_y", false))
		analog_invert_x_check.button_pressed = bool(Settings.values.get("invert_x", false))
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


# AC-0261 (AC-0263): the band sliders span the visible LOD bands —
# HIGH = [0, medium_start), MED = [medium_start, low_start), LOW =
# [low_start, render]; nothing renders past the render distance. The
# mid-start band is (sim, render] (high extends past the sim distance,
# which no longer controls world generation); the low-start band is
# [medium_start, render]. Re-clamp the values into the bands.
func _sync_lowstart_range() -> void:
	var lr := int(Settings.values["render_dist"])
	var mlo := mini(int(Settings.values["sim_dist"]) + 1, lr)
	var mhi := lr
	var lo := mini(int(Settings.values["medium_start"]), lr)
	var hi := lr
	_syncing = true
	midstart_slider.min_value = float(mlo)
	midstart_slider.max_value = float(mhi)
	midstart_slider.value = float(clampi(int(Settings.values["medium_start"]), mlo, mhi))
	lowstart_slider.min_value = float(lo)
	lowstart_slider.max_value = float(hi)
	lowstart_slider.value = float(clampi(int(Settings.values["low_start"]), lo, hi))
	_syncing = false
	midstart_val.text = str(int(midstart_slider.value))
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
	# AC-0263: the sim change moves the mid-start band floor (must stay
	# > sim) — re-clamp + re-stamp via the apply, then sync both sliders.
	Settings.clamp_medium_start()
	Settings.apply_medium_start()
	_sync_lowstart_range()


func _on_volume_changed(v: float) -> void:
	if _syncing:
		return
	volume_val.text = str(int(v))
	Settings.set_value("volume", int(v))
	Settings.apply_audio()


# AC-0145 P3: the flight-speed slider (and its _on_flight_changed) is gone
# — the live flight never read flight_speed (AC-0280 replaced it with
# sub_cruising_speed / cruising_speed, re-keyed to radial altitude in
# AC-0145 piece 2). The FlightRow node is removed from scenes/menu.tscn.

# AC-0225: the per-frame streaming chunk-mesh handoff burst (the AC-0224
# drain cap). world.gd's drain reads Settings "chunks_per_frame" every
# process frame, so saving it here is the whole apply — no extra call.
func _on_chunk_changed(v: float) -> void:
	if _syncing:
		return
	chunk_val.text = str(int(v))
	Settings.set_value("chunks_per_frame", int(v))


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


func _on_subcruise_changed(v: float) -> void:
	if _syncing:
		return
	subcruise_val.text = str(int(v)) + "x"
	Settings.set_value("sub_cruising_speed", int(v))


func _on_cruisealt_changed(v: float) -> void:
	if _syncing:
		return
	cruisealt_val.text = str(int(v))
	Settings.set_value("cruising_altitude", int(v))


func _on_cruise_changed(v: float) -> void:
	if _syncing:
		return
	cruise_val.text = str(int(v)) + "x"
	Settings.set_value("cruising_speed", int(v))


func _on_dof_enabled_toggled(on: bool) -> void:
	if _syncing:
		return
	Settings.set_value("dof_enabled", on)
	dof_far_spin.editable = on
	dof_far_spin.modulate.a = 1.0 if on else 0.45
	dof_amount_spin.editable = on
	dof_amount_spin.modulate.a = 1.0 if on else 0.45
	Settings.apply_dof()


func _on_dof_far_changed(v: float) -> void:
	if _syncing:
		return
	dof_far_val.text = "%.1f" % float(v)
	Settings.set_value("dof_far_distance", float(v))
	Settings.apply_dof()


func _on_dof_amount_changed(v: float) -> void:
	if _syncing:
		return
	dof_amount_val.text = "%.2f" % float(v)
	Settings.set_value("dof_amount", float(v))
	Settings.apply_dof()


# AC-0332: the far-tier mesh floor (AC-0331's kernel). The apply step
# rides set_value (Settings.apply_yfloor -> world.note_yfloor: the
# re-derive + the cache staleness), so the handlers only wire the
# dependent-control state (the DOF precedent).
func _on_yfloor_enabled_toggled(on: bool) -> void:
	if _syncing:
		return
	Settings.set_value("yfloor_enabled", on)
	yfloor_spin.editable = on
	yfloor_spin.modulate.a = 1.0 if on else 0.45


func _on_yfloor_chunks_changed(v: float) -> void:
	if _syncing:
		return
	yfloor_val.text = str(int(v))
	Settings.set_value("yfloor_chunks_below_sea", int(v))


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
# AC-0263: the "mid LOD distance" — the HIGH band's outer edge (taxi
# chunks). Band (sim, render]: high visuals extend past the sim distance
# (which only gates mob/fluid updates now). set_value re-clamps both the
# mid-start band and the low-start floor; the world re-stamps the queue.
func _on_midstart_changed(v: float) -> void:
	if _syncing:
		return
	var lo := mini(int(Settings.values["sim_dist"]) + 1, int(Settings.values["render_dist"]))
	var hi := int(Settings.values["render_dist"])
	var s := clampi(int(v), lo, hi)
	midstart_val.text = str(s)
	Settings.set_value("medium_start", s)
	Settings.apply_medium_start()
	# the low-start floor moved with the mid-start — re-sync its range.
	_sync_lowstart_range()


func _on_lowstart_changed(v: float) -> void:
	if _syncing:
		return
	var lo := mini(int(Settings.values["medium_start"]), int(Settings.values["render_dist"]))
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


func _on_fog_enabled_toggled(on: bool) -> void:
	if _syncing:
		return
	Settings.set_value("fog_enabled", on)
	fogstart_slider.editable = on
	fogstart_slider.modulate.a = 1.0 if on else 0.45


# AC-0389: the ambient sound bed toggle (default OFF). set_value persists
# to the cfg like every other setting; apply_audio pushes the volume AND
# the toggle to Audio in one step (the SFX pool is never touched by it).
func _on_ambient_toggled(on: bool) -> void:
	if _syncing:
		return
	Settings.set_value("ambient_enabled", on)
	Settings.apply_audio()


# AC-0205: the smooth-ground-ramps toggle — set_value does the clamp
# chain + the save + the apply step (world.note_ramps re-derives the
# worker ctx flag and re-meshes every resident column through the
# tex-refresh drain; the collider follows by construction).
func _on_ramp_toggled(on: bool) -> void:
	if _syncing:
		return
	Settings.set_value("smooth_ramps", on)


# AC-0398: the modern vertex lighting toggle — set_value does the clamp
# chain + the save + the apply step (world.note_modern re-derives the
# worker ctx flag and re-meshes every resident column through the
# tex-refresh drain; the change is colour-only, so the collider is
# untouched and geom_epoch is not bumped).
func _on_modern_toggled(on: bool) -> void:
	if _syncing:
		return
	Settings.set_value("modern_light", on)


# AC-0401: the cloud deck character toggle (default ON - the user asked;
# the modern_light precedent). set_value does the clamp chain + the save;
# no apply step is owed: world.gd _ac0401_push reads the live value every
# frame and pushes u_deck to the three cloud-layer materials (0.0 = the
# exact pre-AC-0401 field and windows, 1.0 = the re-characterised deck).
func _on_cloud_deck_toggled(on: bool) -> void:
	if _syncing:
		return
	Settings.set_value("cloud_deck", on)


# AC-0401: the limb-glow altitude gate (default ON - the user asked for
# the fog-only near field). Same seam: _ac0401_push pushes u_limb_gate to
# the sky material (0.0 = the pre-AC-0401 glow at every altitude, 1.0 =
# the glow rides u_space, the flight-band blend).
func _on_limb_gate_toggled(on: bool) -> void:
	if _syncing:
		return
	Settings.set_value("limb_space", on)


# AC-0402: the sky's altitude-aware space blend toggle (default ON - the
# user story asks for the sky to thin with the climb). set_value does the
# clamp chain + the save; no apply step is owed: world.gd _ac0401_push
# reads the live value and pushes u_sky_alt / u_space_sky (OFF = the
# exact pre-AC-0402 sky).
func _on_sky_alt_toggled(on: bool) -> void:
	if _syncing:
		return
	Settings.set_value("sky_altitude", on)


# AC-0405: the raymarched-volumetric-clouds toggle (default ON - the
# user ordered the rework). set_value does the clamp chain + the save;
# no apply step is owed: world.gd _ac0401_push reads the live value and
# pushes u_vol + the annulus radii (OFF = the exact AC-0401 three-shell
# deck - the short-circuit is the shader side).
func _on_cloud_vol_toggled(on: bool) -> void:
	if _syncing:
		return
	Settings.set_value("cloud_volume", on)


# AC-0394: the held-item occlusion toggle (default OFF - conservative:
# the user reported the SIZE, not the occlusion). set_value does the
# clamp chain + the save; no apply step is owed: player.gd reads the
# live value every frame and re-applies the viewmodel materials'
# no_depth_test on change (the cloud_deck/limb_space pattern).
func _on_vm_occ_toggled(on: bool) -> void:
	if _syncing:
		return
	Settings.set_value("viewmodel_occlude", on)


# AC-0395: the noclip toggle — persisted like every other setting.
# Player-side apply is owed (player.gd _noclip_sync reads the live value
# every frame and applies on change — the shape disable + the free
# flight + the indicator; no Settings apply step).
func _on_noclip_toggled(on: bool) -> void:
	if _syncing:
		return
	Settings.set_value("noclip", on)


# ------------------------------------------------- AC-0088 Controls tab

func _mk_ctl_row(a: String) -> Control:
	var row := HBoxContainer.new()
	row.name = "CtlRow_" + a
	row.add_theme_constant_override("separation", 8)
	var lab := Label.new()
	lab.text = ControlsMap.action_label(a)
	lab.add_theme_font_size_override("font_size", 15)
	lab.custom_minimum_size = Vector2(200, 0)
	row.add_child(lab)
	for cls in Settings.controls_map.default_classes(a):
		# "motion" is protected (the analog sticks) - never offered.
		if cls == "motion":
			continue
		var b := Button.new()
		b.name = "Rebind_" + cls
		b.add_theme_font_size_override("font_size", 14)
		b.custom_minimum_size = Vector2(150, 0)
		b.pressed.connect(_on_rebind_pressed.bind(a, cls))
		row.add_child(b)
		if not _ctl_rebinds.has(a):
			_ctl_rebinds[a] = {}
		_ctl_rebinds[a][cls] = b
	var rs := Button.new()
	rs.name = "Reset"
	rs.text = "Reset"
	rs.add_theme_font_size_override("font_size", 14)
	rs.custom_minimum_size = Vector2(64, 0)
	rs.pressed.connect(_on_ctl_reset_pressed.bind(a))
	row.add_child(rs)
	_ctl_resets[a] = rs
	return row


func _ctl_binding_label(a: String, cls: String) -> String:
	var t := Settings.controls_map.current_binding(a, cls)
	if t == "":
		return "(none)"
	return ControlsMap.label_for_token(t)


func _capture_prompt(cls: String) -> String:
	match cls:
		"key": return "Press a key..."
		"mouse": return "Click a mouse button..."
		"pad": return "Press a pad button..."
	return "..."


func _class_words(a: String) -> String:
	var cs: Array = []
	for c in Settings.controls_map.default_classes(a):
		if c == "motion":
			continue
		match c:
			"key": cs.append("keys")
			"mouse": cs.append("mouse buttons")
			"pad": cs.append("pad buttons")
	return " / ".join(cs)


func _on_rebind_pressed(a: String, cls: String) -> void:
	_capturing = {"action": a, "cls": cls}
	_ctl_rebinds[a][cls].text = _capture_prompt(cls)
	ctl_status.modulate = Color.WHITE
	ctl_status.text = "Capture for %s - %s (Esc cancels)." % [ControlsMap.action_label(a), _capture_prompt(cls).to_lower().strip_edges()]


func _cancel_capture(msg: String) -> void:
	_capturing = {}
	ctl_status.modulate = Color.WHITE if msg.begins_with("Set ") else Color(1.0, 0.55, 0.45)
	ctl_status.text = msg
	_sync_controls()


# AC-0088: the capture intercept. Runs in the _input stage - BEFORE the
# GUI would hand the event to the focused rebind Button (Space/Enter/A
# would otherwise re-fire it) and before the menu's own pad_accept
# branch. While a capture is open, every candidate press is consumed
# here: accepted (class allowed + no managed conflict) or reported.
func _input(event: InputEvent) -> void:
	if _capturing.is_empty():
		return
	var act: String = _capturing["action"]
	var cls: String = _capturing["cls"]
	if event is InputEventKey:
		var k: InputEventKey = event
		if k.pressed and not k.echo and k.is_action_pressed("ui_cancel"):
			get_viewport().set_input_as_handled()
			_cancel_capture("Capture cancelled.")
			return
		if not k.pressed or k.echo:
			return
		var kc := int(k.physical_keycode)
		if kc == 0:
			kc = int(k.keycode)
		if kc == 0:
			return
		if ControlsMap.MODIFIER_KEYS.has(kc):
			get_viewport().set_input_as_handled()
			_cancel_capture("Modifier keys (Shift/Ctrl/Alt/Meta) cannot be a binding - press a plain key.")
			return
		_finish_capture(act, cls, "key:%d" % kc, k)
	elif event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if not mb.pressed:
			return
		_finish_capture(act, cls, "mouse:%d" % int(mb.button_index), mb)
	elif event is InputEventJoypadButton:
		var jb: InputEventJoypadButton = event
		if not jb.pressed:
			return
		_finish_capture(act, cls, "pad:%d" % int(jb.button_index), jb)
	# anything else (motion, releases, text input) passes through


func _finish_capture(act: String, cls: String, tok: String, ev) -> void:
	get_viewport().set_input_as_handled()
	if ControlsMap.event_class(ev) != cls:
		_cancel_capture("%s takes %s only - that was a %s input. Click the row again to try another." % [
			ControlsMap.action_label(act), _class_words(act), ControlsMap.label_for_token(tok)])
		return
	var r: Dictionary = Settings.rebind_action(act, tok)
	if bool(r.get("ok", false)):
		var note := ""
		for c in r.get("conflicts", []):
			if bool(c.get("builtin", false)):
				note += " (note: %s also uses it - menus only)" % str(c["action"])
		_cancel_capture("Set %s = %s.%s" % [ControlsMap.action_label(act), ControlsMap.label_for_token(tok), note])
	else:
		var names := ""
		for c in r.get("conflicts", []):
			names += str(c["action"]) + " "
		_cancel_capture("%s %s" % [str(r.get("msg", "conflict")), names.strip_edges()])


func _on_ctl_reset_pressed(a: String) -> void:
	Settings.reset_action(a)
	ctl_status.modulate = Color.WHITE
	ctl_status.text = "%s reset to defaults." % ControlsMap.action_label(a)
	_sync_controls()


func _on_controls_reset_all() -> void:
	Settings.reset_all_controls()
	ctl_status.modulate = Color.WHITE
	ctl_status.text = "All bindings reset to defaults."
	_sync_controls()


# AC-0089: the analog tuning handlers — the AC-0088 persist pattern
# (Settings.set_value = clamp + save in one step; the player reads the
# values live at its input paths, so the change applies the next frame —
# no apply step, no world callback).
func _on_analog_sens_changed(v: float) -> void:
	if _syncing:
		return
	analog_sens_val.text = "%.2fx" % v
	Settings.set_value("look_sensitivity", v)


func _on_analog_dz_left_changed(v: float) -> void:
	if _syncing:
		return
	analog_dz_left_val.text = "%.2f" % v
	Settings.set_value("deadzone_left", v)


func _on_analog_dz_right_changed(v: float) -> void:
	if _syncing:
		return
	analog_dz_right_val.text = "%.2f" % v
	Settings.set_value("deadzone_right", v)


func _on_analog_invert_y_toggled(v: bool) -> void:
	if _syncing:
		return
	Settings.set_value("invert_y", v)


func _on_analog_invert_x_toggled(v: bool) -> void:
	if _syncing:
		return
	Settings.set_value("invert_x", v)


func _on_analog_reset_pressed() -> void:
	var d := AnalogTune.defaults()
	Settings.set_value("look_sensitivity", float(d["look_sensitivity"]))
	Settings.set_value("deadzone_left", float(d["deadzone_left"]))
	Settings.set_value("deadzone_right", float(d["deadzone_right"]))
	Settings.set_value("invert_y", bool(d["invert_y"]))
	Settings.set_value("invert_x", bool(d["invert_x"]))
	ctl_status.modulate = Color.WHITE
	ctl_status.text = "Analog tuning reset to defaults."
	_sync_controls()
