extends CanvasLayer

const SLOT := 48
const PAD := 14
const GAP := 3
const ROW_GAP := 14
const HOT_IN := 2
const SLOT_BG := Color(0.0, 0.0, 0.0, 0.35)
const SLOT_BORDER := Color(0.333, 0.333, 0.333, 1.0)
const SEL_BORDER := Color(1.0, 1.0, 1.0, 1.0)
const STRIP_BG := Color(0.0, 0.0, 0.0, 0.4)
const STRIP_BORDER := Color(1.0, 1.0, 1.0, 0.3)
const PANEL_BG := Color(0.776, 0.776, 0.776, 1.0)
const PANEL_HI := Color(1.0, 1.0, 1.0, 1.0)
const PANEL_LO := Color(0.333, 0.333, 0.333, 1.0)
const TITLE_C := Color(0.247, 0.247, 0.247, 1.0)
const ARMOR_H := 4 * SLOT + 3 * GAP
const STORE_W := 9 * SLOT + 8 * GAP
const STORE_H := 3 * SLOT + 2 * GAP
const CRAFT_H := 3 * SLOT + 2 * GAP
const TITLE_ZONE := 28
const ROW_Y := PAD + TITLE_ZONE
const CRAFT_X := PAD
const CRAFT_Y := ROW_Y + (ARMOR_H - CRAFT_H) / 2.0
const OUT_X := PAD + CRAFT_H + ROW_GAP
const OUT_Y := ROW_Y + (ARMOR_H - SLOT) / 2.0
const ARMOR_X := OUT_X + SLOT + ROW_GAP
const STORE_X := ARMOR_X + SLOT + ROW_GAP
const STORE_Y := ROW_Y + (ARMOR_H - STORE_H) / 2.0
const PHOT_X := PAD
const PHOT_Y := ROW_Y + ARMOR_H + 10
const PANEL_W := STORE_X + STORE_W + PAD
const PANEL_H := PAD + TITLE_ZONE + ARMOR_H + 10 + SLOT + PAD
const LIST_W := 190
const REC_H := 42
const REC_TOP := 24


class FrameRect extends Control:
	var bg := Color(0.0, 0.0, 0.0, 0.4)
	var edge := 2.0
	var edge_hi := Color(1.0, 1.0, 1.0, 0.3)
	var edge_lo := Color(1.0, 1.0, 1.0, 0.3)

	func _draw() -> void:
		var s := size
		draw_rect(Rect2(Vector2.ZERO, s), bg)
		draw_rect(Rect2(Vector2.ZERO, Vector2(s.x, edge)), edge_hi, true)
		draw_rect(Rect2(Vector2(0.0, s.y - edge), Vector2(s.x, edge)), edge_lo, true)
		draw_rect(Rect2(Vector2.ZERO, Vector2(edge, s.y)), edge_hi, true)
		draw_rect(Rect2(Vector2(s.x - edge, 0.0), Vector2(edge, s.y)), edge_lo, true)


class SlotCtl extends Control:
	var region := Vector2i(-1, -1)
	var fill := Color(0.05, 0.05, 0.08, 1.0)
	var border := SLOT_BORDER
	var tex: Texture2D = null
	var cb: Callable
	var rel_pos := Vector2.ZERO

	func _draw() -> void:
		var s := size
		draw_rect(Rect2(Vector2.ZERO, s), SLOT_BG)
		draw_rect(Rect2(Vector2.ZERO, Vector2(s.x, 2.0)), border, true)
		draw_rect(Rect2(Vector2(0.0, s.y - 2.0), Vector2(s.x, 2.0)), border, true)
		draw_rect(Rect2(Vector2.ZERO, Vector2(2.0, s.y)), border, true)
		draw_rect(Rect2(Vector2(s.x - 2.0, 0.0), Vector2(2.0, s.y)), border, true)
		var r := Rect2(Vector2(4, 4), Vector2(s.x - 8.0, s.y - 8.0))
		if tex != null:
			draw_texture_rect(tex, r, false)
		elif region.x >= 0 and Data.atlas_tex != null:
			draw_texture_rect_region(Data.atlas_tex, Rect2i(region.x, region.y, Data.TILE_PX, Data.TILE_PX), r)
		else:
			draw_rect(r, fill)

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and cb.is_valid():
			var mb: InputEventMouseButton = event
			if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				return
			if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
				var p = Game.player
				if p == null or String(p.ui_mode) == "":
					return
			if not mb.pressed:
				rel_pos = position + mb.position
			var button := 0 if mb.button_index == MOUSE_BUTTON_LEFT else 2
			cb.call(button, mb.shift_pressed, mb.pressed)
			get_viewport().set_input_as_handled()


class HeldCtl extends Control:
	var region := Vector2i(-1, -1)
	var fill := Color(0.05, 0.05, 0.08, 1.0)
	var tex: Texture2D = null

	func _draw() -> void:
		if tex != null:
			draw_texture_rect(tex, Rect2(Vector2.ZERO, size), false)
		elif region.x >= 0 and Data.atlas_tex != null:
			draw_texture_rect_region(Data.atlas_tex, Rect2i(region.x, region.y, Data.TILE_PX, Data.TILE_PX), Rect2(Vector2.ZERO, size))
		else:
			draw_rect(Rect2(Vector2.ZERO, size), fill)


class RecipeRow extends Control:
	var region := Vector2i(-1, -1)
	var fill := Color(0.05, 0.05, 0.08, 1.0)
	var tex: Texture2D = null
	var out_id := 0
	var out_n := 0
	var hl := false
	var cb: Callable
	var _label: Label

	func setup_row(t: String) -> void:
		if _label == null:
			_label = Label.new()
			_label.add_theme_font_size_override("font_size", 13)
			_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.95))
			_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.9))
			_label.add_theme_constant_override("outline_size", 3)
			_label.position = Vector2(44.0, 0.0)
			_label.size = Vector2(140.0, float(REC_H))
			_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
			add_child(_label)
		_label.text = t

	func _draw() -> void:
		var s := size
		draw_rect(Rect2(Vector2.ZERO, s), Color(0.0, 0.0, 0.0, 0.62) if hl else Color(0.0, 0.0, 0.0, 0.5))
		var bc := Color(0.45, 0.9, 0.45, 0.9) if hl else Color(1.0, 1.0, 1.0, 0.25)
		draw_rect(Rect2(Vector2.ZERO, s), bc, false, 2.0)
		var r := Rect2(Vector2(5, 3), Vector2(36.0, 36.0))
		if tex != null:
			draw_texture_rect(tex, r, false)
		elif region.x >= 0 and Data.atlas_tex != null:
			draw_texture_rect_region(Data.atlas_tex, Rect2i(region.x, region.y, Data.TILE_PX, Data.TILE_PX), r)
		else:
			draw_rect(r, fill)

	func _gui_input(event: InputEvent) -> void:
		if cb.is_valid() and event is InputEventMouseButton and event.pressed:
			var mb: InputEventMouseButton = event
			if mb.button_index != MOUSE_BUTTON_LEFT:
				return
			if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
				cb.call()
				get_viewport().set_input_as_handled()


class FoodBar extends Control:
	var frac := 1.0

	func _draw() -> void:
		var s := size
		draw_rect(Rect2(Vector2.ZERO, s), Color(0.0, 0.0, 0.0, 0.55))
		draw_rect(Rect2(Vector2.ZERO, Vector2(s.x, 1.0)), Color(0.067, 0.067, 0.067, 1.0), true)
		draw_rect(Rect2(Vector2(0.0, s.y - 1.0), Vector2(s.x, 1.0)), Color(0.067, 0.067, 0.067, 1.0), true)
		draw_rect(Rect2(Vector2.ZERO, Vector2(1.0, s.y)), Color(0.067, 0.067, 0.067, 1.0), true)
		draw_rect(Rect2(Vector2(s.x - 1.0, 0.0), Vector2(1.0, s.y)), Color(0.067, 0.067, 0.067, 1.0), true)
		var fw := clampf(frac, 0.0, 1.0) * (s.x - 2.0)
		var fh := s.y - 2.0
		var top_c := Color8(232, 163, 61)
		var bot_c := Color8(176, 106, 28)
		var yy := 1
		while float(yy) < fh:
			draw_rect(Rect2(1.0, 1.0 + float(yy), fw, 1.0), top_c.lerp(bot_c, float(yy) / fh))
			yy += 1


class FlashCtl extends Control:
	var tex: Texture2D = null
	var a := 0.0

	func _draw() -> void:
		if a > 0.0 and tex != null:
			draw_texture_rect(tex, Rect2(Vector2.ZERO, size), false, Color(1.0, 1.0, 1.0, a))


class DeadBtn extends Control:
	var cb: Callable

	func _draw() -> void:
		var s := size
		draw_rect(Rect2(Vector2.ZERO, s), Color(0.435, 0.435, 0.435, 1.0))
		draw_rect(Rect2(Vector2.ZERO, Vector2(s.x, 2.0)), Color(0.659, 0.659, 0.659, 1.0), true)
		draw_rect(Rect2(Vector2(0.0, s.y - 2.0), Vector2(s.x, 2.0)), Color(0.235, 0.235, 0.235, 1.0), true)
		draw_rect(Rect2(Vector2.ZERO, Vector2(2.0, s.y)), Color(0.659, 0.659, 0.659, 1.0), true)
		draw_rect(Rect2(Vector2(s.x - 2.0, 0.0), Vector2(2.0, s.y)), Color(0.235, 0.235, 0.235, 1.0), true)

	func _gui_input(event: InputEvent) -> void:
		if cb.is_valid() and event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			cb.call()
			get_viewport().set_input_as_handled()


var _strip: FrameRect
var _held: HeldCtl
var _panel: FrameRect
var _title: Label
var _slots: Array = []
var _labels: Array = []
var _areas: Array = []
var _indices: Array = []
var _last: Array = []
var _slot_ids: Array = []
var _recipe_box: FrameRect
var _recipe_title: Label
var _recipe_rows: Array = []
var _all_recipes: Array = []
var _last_inv_key := ""
var _tooltip: Label
var _force_hover_id := 0
var _mouse := Vector2.ZERO
var _tile_tex := {}
var _hearts: Array = []
var _food: FoodBar
var _flash: FlashCtl
var _flash_tex: ImageTexture
var _flash_t := 0.0
var _damaged_node = null
var _hp_key := ""
var _hunger_key := ""
var _dead_bg: ColorRect
var _dead_title: Label
var _dead_btn: DeadBtn


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_mouse = (event as InputEventMouseMotion).position


func _ready() -> void:
	layer = 10
	_strip = FrameRect.new()
	_strip.bg = STRIP_BG
	_strip.edge = 2.0
	_strip.edge_hi = STRIP_BORDER
	_strip.edge_lo = STRIP_BORDER
	_strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_strip)
	_held = HeldCtl.new()
	_held.size = Vector2(SLOT, SLOT)
	_held.visible = false
	_held.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel = FrameRect.new()
	_panel.bg = PANEL_BG
	_panel.edge = 3.0
	_panel.edge_hi = PANEL_HI
	_panel.edge_lo = PANEL_LO
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.visible = false
	add_child(_panel)
	_title = Label.new()
	_title.text = "Inventory"
	_title.add_theme_font_size_override("font_size", 15)
	_title.add_theme_color_override("font_color", TITLE_C)
	_title.position = Vector2(PAD, PAD - 5)
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_title)
	for i in 9:
		_add_slot("hotbar_bottom", i)
	for i in 9:
		_add_slot("craft", i)
	_add_slot("output", 0)
	for i in 4:
		_add_slot("armor", i)
	for i in 27:
		_add_slot("storage", i)
	for i in 9:
		_add_slot("hotbar", i)
	_recipe_box = FrameRect.new()
	_recipe_box.bg = STRIP_BG
	_recipe_box.edge = 2.0
	_recipe_box.edge_hi = STRIP_BORDER
	_recipe_box.edge_lo = STRIP_BORDER
	_recipe_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_recipe_box.visible = false
	add_child(_recipe_box)
	_recipe_title = Label.new()
	_recipe_title.text = "Craftable"
	_recipe_title.add_theme_font_size_override("font_size", 13)
	_recipe_title.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.9))
	_recipe_title.position = Vector2(10, 5)
	_recipe_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_recipe_box.add_child(_recipe_title)
	_tooltip = Label.new()
	var tbox := StyleBoxFlat.new()
	tbox.bg_color = Color(0.04, 0.04, 0.04, 0.85)
	tbox.border_width_left = 1
	tbox.border_width_right = 1
	tbox.border_width_top = 1
	tbox.border_width_bottom = 1
	tbox.border_color = Color(0.0, 0.0, 0.0, 1.0)
	_tooltip.add_theme_stylebox_override("normal", tbox)
	_tooltip.add_theme_font_size_override("font_size", 14)
	_tooltip.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 1.0))
	_tooltip.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.9))
	_tooltip.add_theme_constant_override("outline_size", 3)
	_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip.visible = false
	add_child(_tooltip)
	_food = FoodBar.new()
	_food.size = Vector2(170, 9)
	_food.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_food)
	for i in 10:
		var h := Label.new()
		h.text = "\u2665"
		h.add_theme_font_size_override("font_size", 16)
		h.add_theme_color_override("font_color", Color(0.0, 0.0, 0.0, 1.0))
		h.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 1.0))
		h.add_theme_constant_override("outline_size", 2)
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(h)
		_hearts.append(h)
	var fimg := Image.create_empty(128, 128, false, Image.FORMAT_RGBA8)
	var fc := Vector2(64.0, 64.0)
	var fmaxd := fc.length()
	for fy in 128:
		for fx in 128:
			var fr := Vector2(float(fx), float(fy)).distance_to(fc) / fmaxd
			var fa := 0.0
			if fr >= 0.45:
				fa = minf(0.55, (fr - 0.45) / 0.55 * 0.55)
			fimg.set_pixel(fx, fy, Color(1.0, 0.0, 0.0, fa))
	_flash_tex = ImageTexture.create_from_image(fimg)
	_flash = FlashCtl.new()
	_flash.tex = _flash_tex
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_flash)
	_dead_bg = ColorRect.new()
	_dead_bg.color = Color(0.0, 0.0, 0.0, 0.72)
	_dead_bg.visible = false
	add_child(_dead_bg)
	_dead_title = Label.new()
	_dead_title.text = "You Died!"
	_dead_title.add_theme_font_size_override("font_size", 28)
	_dead_title.add_theme_color_override("font_color", Color(1.0, 0.392, 0.392, 1.0))
	_dead_title.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.9))
	_dead_title.add_theme_constant_override("outline_size", 3)
	_dead_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dead_bg.add_child(_dead_title)
	_dead_btn = DeadBtn.new()
	_dead_btn.cb = Callable(self, "_respawn_click")
	_dead_btn.size = Vector2(260, 40)
	_dead_bg.add_child(_dead_btn)
	var dl := Label.new()
	dl.text = "Respawn"
	dl.add_theme_font_size_override("font_size", 16)
	dl.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 1.0))
	dl.size = _dead_btn.size
	dl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	dl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	dl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dl.position = Vector2.ZERO
	_dead_btn.add_child(dl)
	add_child(_held)
	_build_all_recipes()


func _add_slot(area: String, idx: int) -> void:
	var c := SlotCtl.new()
	c.size = Vector2(SLOT, SLOT)
	c.cb = Callable(self, "_route_click").bind(_slots.size())
	if _slots.size() >= 9:
		c.visible = false
	add_child(c)
	_slots.append(c)
	_areas.append(area)
	_indices.append(idx)
	_last.append("")
	_slot_ids.append(0)
	var l := Label.new()
	l.add_theme_font_size_override("font_size", 14)
	l.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.95))
	l.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.9))
	l.add_theme_constant_override("outline_size", 3)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	l.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	l.position = Vector2(SLOT - 30, SLOT - 20)
	l.size = Vector2(28, 18)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.add_child(l)
	_labels.append(l)


func _route_click(button: int, shift: bool, is_press: bool, si: int) -> void:
	var p = Game.player
	if p == null:
		return
	if not is_press:
		_release_drop(p, (_slots[si] as SlotCtl).rel_pos)
		return
	var area: String = _areas[si]
	var idx: int = _indices[si]
	if area == "storage":
		p.inv_slot_click(idx, "storage", button, shift, false)
	elif area == "armor":
		p.armor_slot_click(idx, button, shift, false)
	elif area == "hotbar":
		p.inv_slot_click(idx, "hotbar", button, shift, false)
	elif area == "craft":
		p.craft_grid_click(idx, button, shift, false)
	elif area == "output":
		p.craft_output_click()
	elif button == 0 and Game.mode == "play":
		p.sel = idx


func _release_drop(p, gpos: Vector2) -> void:
	for i in _slots.size():
		var c: Control = _slots[i]
		if not c.visible:
			continue
		if not Rect2(c.position, c.size).has_point(gpos):
			continue
		var area: String = _areas[i]
		var idx: int = _indices[i]
		if area == "storage":
			p.inv_slot_click(idx, "storage", 0, false, true)
		elif area == "armor":
			p.armor_slot_click(idx, 0, false, true)
		elif area == "hotbar":
			p.inv_slot_click(idx, "hotbar", 0, false, true)
		elif area == "craft":
			p.craft_grid_click(idx, 0, false, true)
		elif area == "hotbar_bottom":
			p.sel = idx
		return


func _tile_texture(region: Vector2i) -> Texture2D:
	var key := region.x * 10000 + region.y
	var t: Texture2D = _tile_tex.get(key)
	if t != null:
		return t
	t = ImageTexture.create_from_image(Data.atlas_tex.get_image().get_region(Rect2i(region, Vector2i(Data.TILE_PX, Data.TILE_PX))))
	_tile_tex[key] = t
	return t


func _setup_icon(c: Control, id: int) -> void:
	if id == 0:
		c.region = Vector2i(-1, -1)
		c.fill = Color(0.05, 0.05, 0.08, 0.45)
		c.tex = null
		return
	var info = Data.blocks.get(id)
	if info != null:
		c.region = Data.block_rect(id, "side")
		c.fill = info["color"]["side"]
		c.tex = _tile_texture(c.region) if (c.region.x >= 0 and Data.atlas_tex != null) else null
	else:
		c.region = Vector2i(-1, -1)
		c.tex = null
		var it = Data.items.get(id)
		if it != null and it.has("icon"):
			c.fill = it["icon"]
		else:
			c.fill = Color(0.7, 0.7, 0.7, 1.0)


func _build_all_recipes() -> void:
	for r in Data.shapeless:
		_all_recipes.append({"shaped": false, "req": r["in"], "out": r["out"], "ok": false})
	for r in Data.shaped:
		var req := {}
		var g: Array = r["grid"]
		for i in 9:
			var ch := String(g[i / 3])[i % 3]
			if ch != " ":
				var id: int = int(r["map"][ch])
				req[id] = int(req.get(id, 0)) + 1
		_all_recipes.append({"shaped": true, "grid": r["grid"], "map": r["map"], "req": req, "out": r["out"], "ok": false})


func _have(id: int) -> int:
	var p = Game.player
	if p == null:
		return 0
	var c := 0
	for i in 36:
		var it: Dictionary = p._inv_get(i)
		if int(it["id"]) == id:
			c += int(it["n"])
	return c


func _refresh_recipe_ok() -> void:
	if Game.player == null:
		return
	for r in _all_recipes:
		var req: Dictionary = r["req"]
		var ok := true
		for id in req:
			if _have(int(id)) < int(req[id]):
				ok = false
				break
		r["ok"] = ok


func _rebuild_recipes() -> void:
	for ch in _recipe_rows:
		ch.queue_free()
	_recipe_rows.clear()
	var n := 0
	for r in _all_recipes:
		if not bool(r["ok"]):
			continue
		n += 1
		if n > 14:
			break
		var row := RecipeRow.new()
		row.size = Vector2(float(LIST_W) - 12.0, float(REC_H))
		row.position = Vector2(6.0, float(REC_TOP) + float(n - 1) * float(REC_H + 2))
		row.out_id = int(r["out"]["id"])
		row.out_n = int(r["out"]["n"])
		row.setup_row(_item_name(int(r["out"]["id"])))
		_setup_icon(row, int(r["out"]["id"]))
		row.cb = Callable(self, "_recipe_click").bind(r)
		_recipe_box.add_child(row)
		_recipe_rows.append(row)


func _recipe_click(r: Dictionary) -> void:
	var p = Game.player
	if p == null:
		return
	if bool(r["shaped"]):
		var g: Array = r["grid"]
		for i in 9:
			var ch := String(g[i / 3])[i % 3]
			if ch != " ":
				p.craft_grid[i] = {"id": int(r["map"][ch]), "n": 1}
			else:
				p.craft_grid[i] = {"id": 0, "n": 0}
	else:
		var cell := 0
		var req: Dictionary = r["req"]
		for id in req:
			var left := int(req[id])
			while left > 0:
				var take := mini(left, 64)
				p.craft_grid[cell] = {"id": int(id), "n": take}
				cell += 1
				left -= take
	p.recompute_craft()


func _item_name(id: int) -> String:
	var b = Data.block(id)
	if b != null:
		return String(b.get("name", "item"))
	var it = Data.items.get(id)
	if it != null:
		return String(it.get("name", "item"))
	return "item %d" % id


func _show_tooltip(c: Control, id: int) -> void:
	_tooltip.text = _item_name(id)
	var ms := _tooltip.get_combined_minimum_size()
	var vs: Vector2 = get_viewport().get_visible_rect().size
	var x := c.position.x + c.size.x * 0.5 - ms.x * 0.5
	var y := c.position.y - ms.y - 6.0
	if y < 4.0:
		y = c.position.y + c.size.y + 6.0
	x = clampf(x, 4.0, vs.x - ms.x - 4.0)
	_tooltip.position = Vector2(x, y)
	_tooltip.visible = true


func _update_tooltip(p) -> void:
	var shown := false
	if p != null:
		for si in _slots.size():
			var c: Control = _slots[si]
			if not c.visible:
				continue
			if not Rect2(c.position, c.size).has_point(_mouse):
				continue
			if int(_slot_ids[si]) != 0:
				_show_tooltip(c, int(_slot_ids[si]))
				shown = true
			break
	_tooltip.visible = shown


func _update_recipes(p, show: bool, px: float, py: float) -> void:
	if not show or p == null:
		_recipe_box.visible = false
		return
	var inv_key := ""
	for i in 36:
		var it: Dictionary = p._inv_get(i)
		inv_key += "%d:%d " % [int(it["id"]), int(it["n"])]
	if inv_key != _last_inv_key:
		_last_inv_key = inv_key
		_refresh_recipe_ok()
		_rebuild_recipes()
	var cout_id := 0
	var cout_n := 0
	if p.craft_out != {}:
		cout_id = int(p.craft_out.get("id", 0))
		cout_n = int(p.craft_out.get("n", 0))
	for i in _recipe_rows.size():
		var row: RecipeRow = _recipe_rows[i]
		var hl: bool = cout_id != 0 and row.out_id == cout_id and row.out_n == cout_n
		if hl != row.hl:
			row.hl = hl
			row.queue_redraw()
	var bh := float(REC_TOP) + 6.0 + float(_recipe_rows.size()) * float(REC_H + 2)
	var bw := float(LIST_W)
	_recipe_box.size = Vector2(bw, bh)
	var bx := px - bw - 10.0
	if bx < 6.0:
		bx = px + float(PANEL_W) + 10.0
	_recipe_box.position = Vector2(bx, py + (float(PANEL_H) - bh) * 0.5)
	_recipe_box.visible = true


func refresh_atlas() -> void:
	_tile_tex.clear()
	for si in _slots.size():
		_last[si] = ""
		(_slots[si] as Control).queue_redraw()
	for r in _recipe_rows:
		r.queue_redraw()
	_held.queue_redraw()


func hover_item(id_in: int) -> void:
	_force_hover_id = int(id_in)


func autofill_first() -> void:
	if Game.player == null:
		return
	_refresh_recipe_ok()
	for r in _all_recipes:
		if bool(r["ok"]):
			_recipe_click(r)
			return


func _on_damaged(_src: String) -> void:
	_flash_t = 0.13


func _respawn_click() -> void:
	var p = Game.player
	if p != null and p.dead:
		p.respawn()


func _update_survival(p, dt: float) -> void:
	var vs: Vector2 = get_viewport().get_visible_rect().size
	if _flash_t > 0.0:
		_flash_t = maxf(0.0, _flash_t - dt)
		_flash.a = _flash_t / 0.13 * 0.85
	elif _flash.a != 0.0:
		_flash.a = 0.0
	_flash.size = vs
	_flash.queue_redraw()
	if p == null:
		_food.visible = false
		for h in _hearts:
			(h as Label).visible = false
		_dead_bg.visible = false
		return
	if _damaged_node != p:
		if _damaged_node != null and is_instance_valid(_damaged_node) and _damaged_node.damaged.is_connected(_on_damaged):
			_damaged_node.damaged.disconnect(_on_damaged)
		_damaged_node = p
		p.damaged.connect(_on_damaged)
	var hw: Vector2 = _hearts[0].get_combined_minimum_size()
	var total_w := 10.0 * hw.x + 9.0
	var hx := (vs.x - total_w) * 0.5
	var hy := vs.y - 64.0 - hw.y
	for i in 10:
		var h: Label = _hearts[i]
		var v: float = p.hp - float(i) * 2.0
		h.visible = true
		h.modulate.a = 1.0 if v >= 2.0 else (0.45 if v >= 1.0 else 0.25)
		(h as Control).position = Vector2(hx + i * (hw.x + 1.0), hy)
	_food.visible = true
	_food.position = Vector2((vs.x - 170.0) * 0.5, vs.y - 84.0 - 9.0)
	var hk := str(roundf(float(p.hunger) * 1000.0))
	if hk != _hunger_key:
		_hunger_key = hk
		_food.frac = clampf(float(p.hunger) / 20.0, 0.0, 1.0)
		_food.queue_redraw()
	_dead_bg.visible = p.dead
	if p.dead:
		_dead_bg.size = vs
		_dead_title.size = Vector2(vs.x, 40.0)
		var bt := _dead_title.get_combined_minimum_size()
		_dead_title.position = Vector2(0.0, (vs.y - bt.y - 40.0 - 14.0) * 0.5)
		_dead_btn.position = Vector2((vs.x - 260.0) * 0.5, _dead_title.position.y + bt.y + 14.0)


func _process(dt: float) -> void:
	if _strip == null:
		return
	var vs: Vector2 = get_viewport().get_visible_rect().size
	var sw := 9 * SLOT + 8 * HOT_IN + 10.0
	var sh := SLOT + 10.0
	var sx := (vs.x - sw) * 0.5
	var sy := vs.y - 8.0 - sh
	_strip.position = Vector2(sx, sy)
	_strip.size = Vector2(sw, sh)
	var p = Game.player
	var show: bool = p != null and String(p.ui_mode) == "inv"
	_panel.visible = show
	for i in range(9, _slots.size()):
		(_slots[i] as Control).visible = show
	if show:
		_panel.size = Vector2(float(PANEL_W), float(PANEL_H))
	var px := (vs.x - float(PANEL_W)) * 0.5
	var py := (vs.y - float(PANEL_H)) * 0.5
	_panel.position = Vector2(px, py)
	for i in 9:
		(_slots[i] as Control).position = Vector2(sx + 5.0 + i * (SLOT + HOT_IN), sy + 5.0)
	if show:
		for i in 9:
			var cc: Control = _slots[9 + i]
			cc.position = Vector2(px + float(CRAFT_X) + (i % 3) * (SLOT + GAP), py + CRAFT_Y + (i / 3) * (SLOT + GAP))
		(_slots[18] as Control).position = Vector2(px + float(OUT_X), py + float(OUT_Y))
		for i in 4:
			(_slots[19 + i] as Control).position = Vector2(px + float(ARMOR_X), py + float(ROW_Y) + i * (SLOT + GAP))
		for i in 27:
			var c2: Control = _slots[23 + i]
			c2.position = Vector2(px + float(STORE_X) + (i % 9) * (SLOT + GAP), py + STORE_Y + (i / 9) * (SLOT + GAP))
		for i in 9:
			(_slots[50 + i] as Control).position = Vector2(px + float(PHOT_X) + i * (SLOT + GAP), py + float(PHOT_Y))
	for si in _slots.size():
		var id := 0
		var n := 0
		var is_sel := false
		if p != null:
			var area: String = _areas[si]
			var idx: int = _indices[si]
			if area == "storage":
				id = int(p._inv_get(27 + idx)["id"])
				n = int(p._inv_get(27 + idx)["n"])
			elif area == "armor":
				id = int(p.armor[idx])
				n = 1 if id != 0 else 0
			elif area == "craft":
				id = int(p.craft_grid[idx]["id"])
				n = int(p.craft_grid[idx]["n"])
			elif area == "output":
				id = int(p.craft_out.get("id", 0))
				n = int(p.craft_out.get("n", 0))
			else:
				id = int(p._inv_get(idx)["id"])
				n = int(p._inv_get(idx)["n"])
				if area == "hotbar_bottom":
					is_sel = int(p.sel) == idx
		var key := "%d|%d|%d" % [id, n, 1 if is_sel else 0]
		if key != _last[si]:
			_last[si] = key
			_slot_ids[si] = id
			var c: Control = _slots[si]
			_setup_icon(c, id)
			if c is SlotCtl:
				(c as SlotCtl).border = SEL_BORDER if is_sel else SLOT_BORDER
			_labels[si].text = str(n) if n > 1 else ""
			c.queue_redraw()
	if _force_hover_id != 0:
		for si in _slots.size():
			var hc: Control = _slots[si]
			if hc.visible and int(_slot_ids[si]) == _force_hover_id:
				_mouse = hc.position + hc.size * 0.5
				_force_hover_id = 0
				break
	_update_tooltip(p)
	_update_recipes(p, show, px, py)
	if p != null and p.held != {} and int(p.held.get("id", 0)) != 0:
		_held.visible = true
		_setup_icon(_held, int(p.held["id"]))
		_held.position = _mouse + Vector2(14, 14)
		_held.queue_redraw()
	else:
		_held.visible = false
	_update_survival(p, dt)
