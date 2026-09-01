# AC-0178: loading screen (first spawn / render-distance change). Code-built
# CanvasLayer so the World node owns it without a scene file; matches the
# menu palette (0.055 bg, white primary, 0.62 gray). Headless-safe: plain
# node creation, never awaited. Preloaded by world.gd (global class cache
# is not refreshed on headless runs).
extends CanvasLayer

var _bg: ColorRect
var _title: Label
var _bar: ProgressBar
var _stats: Label

func _ready() -> void:
	layer = 90
	_bg = ColorRect.new()
	_bg.color = Color(0.055, 0.055, 0.078, 1)
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_bg)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(box)
	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	_title.add_theme_font_size_override("font_size", 28)
	box.add_child(_title)
	_bar = ProgressBar.new()
	_bar.min_value = 0.0
	_bar.max_value = 100.0
	_bar.value = 0.0
	_bar.show_percentage = false
	_bar.custom_minimum_size = Vector2(480, 18)
	_bar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	box.add_child(_bar)
	_stats = Label.new()
	_stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_stats.add_theme_color_override("font_color", Color(0.62, 0.62, 0.66, 1))
	_stats.add_theme_font_size_override("font_size", 15)
	box.add_child(_stats)
	visible = false

func show_loading(total: int, title: String) -> void:
	_title.text = title
	_bar.max_value = float(maxi(total, 1))
	_bar.value = 0.0
	_stats.text = "%d / %d cols" % [0, maxi(total, 1)]
	visible = true

func update_progress(meshed: int, total: int, disk: int, gen: int) -> void:
	if not visible:
		return
	_bar.max_value = float(maxi(total, 1))
	_bar.value = float(mini(meshed, maxi(total, 1)))
	_stats.text = "%d%%  —  %d / %d cols   (disk %d · gen %d)" % [int(100.0 * mini(float(meshed), float(maxi(total, 1))) / float(maxi(total, 1))), meshed, maxi(total, 1), disk, gen]

func hide_screen() -> void:
	visible = false
