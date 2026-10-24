extends Node

const CHUNK := 16
# AC-0091: world height 80 -> 384. Internal 0-based y, y=0 = bedrock =
# Minecraft Y=-64, y=383 = MC Y=319. MC Y = y - 64 at coordinate surfaces.
# Sea level: internal y=126 (MC Y=62), the spec-directed level.
const HEIGHT := 384
const SEA := 126

const C_GRASS_TOP := Color(0.416, 0.667, 0.251)
const C_DIRT := Color(0.525, 0.376, 0.263)
const C_GRASS_SIDE := Color(0.545, 0.404, 0.294)
const C_STONE := Color(0.463, 0.463, 0.471)
const C_SAND := Color(0.855, 0.804, 0.62)
const C_WATER := Color(0.157, 0.431, 0.863)
const C_BEDROCK := Color(0.294, 0.294, 0.306)
const C_SNOW := Color(0.922, 0.949, 0.98)
const C_SNOW_SIDE := Color(0.732, 0.663, 0.622)
const C_COAL_ORE := Color(0.30, 0.30, 0.32)
const C_IRON_ORE := Color(0.518, 0.494, 0.467)
const C_DIAMOND_ORE := Color(0.30, 0.72, 0.70)
const C_LAVA := Color(0.976, 0.447, 0.082)
const C_OBSIDIAN := Color(0.118, 0.078, 0.165)
const C_TORCH := Color(0.98, 0.71, 0.35)
const C_GLOWSTONE := Color(0.98, 0.85, 0.60)
const C_COBBLE := Color(0.447, 0.447, 0.455)
const C_LEAVES := Color(0.235, 0.549, 0.188)
const C_ROSE := Color(0.863, 0.157, 0.157)
const C_DANDELION := Color(0.941, 0.824, 0.157)
# AC-0040: the hanging banana fruit (block 28 / item 126).
const C_BANANA := Color(0.918, 0.824, 0.243)
# AC-0292: the cave-feature block family (32-36) — colors approximate the
# Faithful pack tiles the atlas probe pastes in (the tiles win at render;
# the colors seed the face-color cache + item icons).
const C_DEEPSLATE := Color(0.38, 0.38, 0.42)
const C_DRIPSTONE := Color(0.62, 0.56, 0.47)
const C_CLAY := Color(0.55, 0.60, 0.70)
const C_SCULK := Color(0.10, 0.35, 0.35)
const C_MOSS := Color(0.36, 0.52, 0.27)

var atlas_tex: Texture2D = null
var atlas_rects := {}
var item_atlas_tex: Texture2D = null
var item_atlas_rects := {}
var fluid_anim_mats := {}
# AC-0245 follow-up 3: the INWARD (cull_front) pass of the two-pass
# camera-side fluid culling (see core/fluid_anim_bf.gdshader) - same ids,
# same uniforms as fluid_anim_mats.
var fluid_anim_bf_mats := {}
const ATLAS_PX := 1024.0
const TILE_PX := 32

const TINT_GRASS_TOP := Color(93.0 / 255.0, 178.0 / 255.0, 55.0 / 255.0)
const TINT_LEAVES := Color(60.0 / 255.0, 140.0 / 255.0, 48.0 / 255.0)
const TINT_WATER := Color(47.0 / 255.0, 107.0 / 255.0, 235.0 / 255.0)

var blocks := {}
const TOOL_BLOCKS := {
	"pick": [3, 9, 14, 15, 16, 25, 32, 33, 35, 36],
	"axe": [6, 7, 8],
	"shovel": [1, 2, 4, 12, 13, 34],
}
# AC-0040: bouncy-banana — eating restores health+hunger (stamina) and
# plays the gorilla SFX (Audio.play("gorilla"); the AC-0039 sound lane).
# AC-0141: the item table moved to res://data/items.json (same entries and
# types — the dump-diff in tasks/AC-0141/ is the proof). Loaded in _init.
var items := {}
# grid: 2 = craftable in the E-inventory 2x2 grid; grid: 3 = crafting-table 3x3 only
var shapeless := [
	{"in": {6: 1}, "grid": 2, "out": {"id": 8, "n": 4}},
	{"in": {8: 4}, "grid": 2, "out": {"id": 20, "n": 1}},
	# AC-0271: 6 planks -> 3 doors.
	{"in": {8: 6}, "grid": 3, "out": {"id": 26, "n": 3}},
	{"in": {8: 2}, "grid": 2, "out": {"id": 100, "n": 4}},
	{"in": {9: 4}, "grid": 2, "out": {"id": 17, "n": 4}},
	{"in": {105: 3, 100: 2}, "grid": 3, "out": {"id": 109, "n": 1}},
	{"in": {105: 3}, "grid": 2, "out": {"id": 139, "n": 1}},
	{"in": {8: 2, 100: 1}, "grid": 3, "out": {"id": 123, "n": 1}},
	{"in": {9: 2, 100: 1}, "grid": 3, "out": {"id": 124, "n": 1}},
	{"in": {107: 2, 100: 1}, "grid": 3, "out": {"id": 125, "n": 1}},
	{"in": {104: 5}, "grid": 3, "out": {"id": 127, "n": 1}},
	{"in": {104: 8}, "grid": 3, "out": {"id": 128, "n": 1}},
	{"in": {104: 7}, "grid": 3, "out": {"id": 129, "n": 1}},
	{"in": {104: 4}, "grid": 3, "out": {"id": 130, "n": 1}},
	{"in": {105: 5}, "grid": 3, "out": {"id": 131, "n": 1}},
	{"in": {105: 8}, "grid": 3, "out": {"id": 132, "n": 1}},
	{"in": {105: 7}, "grid": 3, "out": {"id": 133, "n": 1}},
	{"in": {105: 4}, "grid": 3, "out": {"id": 134, "n": 1}},
	{"in": {107: 5}, "grid": 3, "out": {"id": 135, "n": 1}},
	{"in": {107: 8}, "grid": 3, "out": {"id": 136, "n": 1}},
	{"in": {107: 7}, "grid": 3, "out": {"id": 137, "n": 1}},
	{"in": {107: 4}, "grid": 3, "out": {"id": 138, "n": 1}},
	{"in": {9: 1, 100: 1}, "grid": 2, "out": {"id": 143, "n": 4}},
	{"in": {106: 1, 100: 1}, "grid": 2, "out": {"id": 22, "n": 4}},
]
var shaped := [
	{"grid3": ["CCC", "C C", "CCC"], "grid": 3, "map": {"C": 9}, "out": {"id": 21, "n": 1}},
	{"grid3": ["MMM", " S ", " S "], "grid": 3, "map": {"M": 8, "S": 100}, "out": {"id": 111, "n": 1}},
	{"grid3": ["MMM", " S ", " S "], "grid": 3, "map": {"M": 9, "S": 100}, "out": {"id": 112, "n": 1}},
	{"grid3": ["MMM", " S ", " S "], "grid": 3, "map": {"M": 105, "S": 100}, "out": {"id": 113, "n": 1}},
	{"grid3": ["MMM", " S ", " S "], "grid": 3, "map": {"M": 107, "S": 100}, "out": {"id": 114, "n": 1}},
	{"grid3": ["MM ", "MS ", " S "], "grid": 3, "map": {"M": 8, "S": 100}, "out": {"id": 115, "n": 1}},
	{"grid3": ["MM ", "MS ", " S "], "grid": 3, "map": {"M": 9, "S": 100}, "out": {"id": 116, "n": 1}},
	{"grid3": ["MM ", "MS ", " S "], "grid": 3, "map": {"M": 105, "S": 100}, "out": {"id": 117, "n": 1}},
	{"grid3": ["MM ", "MS ", " S "], "grid": 3, "map": {"M": 107, "S": 100}, "out": {"id": 118, "n": 1}},
	{"grid3": ["M  ", "S  ", "S  "], "grid": 3, "map": {"M": 8, "S": 100}, "out": {"id": 119, "n": 1}},
	{"grid3": ["M  ", "S  ", "S  "], "grid": 3, "map": {"M": 9, "S": 100}, "out": {"id": 120, "n": 1}},
	{"grid3": ["M  ", "S  ", "S  "], "grid": 3, "map": {"M": 105, "S": 100}, "out": {"id": 121, "n": 1}},
	{"grid3": ["M  ", "S  ", "S  "], "grid": 3, "map": {"M": 107, "S": 100}, "out": {"id": 122, "n": 1}},
	{"grid3": ["S# ", "#S ", "S# "], "grid": 3, "map": {"S": 100, "#": 145}, "out": {"id": 142, "n": 1}},
]
var mobs := {
	"pig": {"passive": true, "hp": 10, "w": 0.8, "h": 0.9, "speed": 1.5, "drops": [{"id": 101, "n": 2, "ch": 1.0}, {"id": 104, "n": 1, "ch": 0.6}], "body": Color.html("f2a29c"), "head": Color.html("f2a29c")},
	"sheep": {"passive": true, "hp": 8, "w": 0.8, "h": 0.9, "speed": 1.4, "drops": [{"id": 103, "n": 2, "ch": 1.0}, {"id": 101, "n": 1, "ch": 0.8}], "body": Color.html("f0f0e8"), "head": Color.html("f0f0e8")},
	"cow": {"passive": true, "hp": 10, "w": 0.9, "h": 1.1, "speed": 1.3, "drops": [{"id": 101, "n": 2, "ch": 1.0}, {"id": 104, "n": 1, "ch": 0.8}], "body": Color.html("8a5a3a"), "head": Color.html("7a4e30")},
	"zombie": {"passive": false, "hp": 20, "w": 0.6, "h": 1.8, "speed": 2.2, "dmg": 3, "drops": [{"id": 101, "n": 1, "ch": 0.3}], "body": Color.html("3a7a3a"), "head": Color.html("4a9a4a")},
	"skeleton": {"passive": false, "hp": 20, "w": 0.6, "h": 1.9, "speed": 2.3, "ranged": true, "dmg": 2, "drops": [{"id": 144, "n": 2, "ch": 0.9}, {"id": 145, "n": 1, "ch": 0.3}], "body": Color.html("d6d4ce"), "head": Color.html("e6e4de")},
	"chicken": {"passive": true, "hp": 4, "w": 0.45, "h": 0.6, "speed": 1.7, "drops": [{"id": 146, "n": 1, "ch": 1.0}], "body": Color.html("f6f3ef"), "head": Color.html("f6f3ef")},
	"wolf": {"passive": true, "hp": 8, "w": 0.6, "h": 0.9, "speed": 3.0, "drops": [{"id": 104, "n": 2, "ch": 0.8}], "body": Color.html("7c7970"), "head": Color.html("6b685f")},
	"spider": {"passive": false, "hp": 16, "w": 1.3, "h": 0.95, "speed": 2.5, "dmg": 2, "drops": [{"id": 145, "n": 2, "ch": 0.8}], "body": Color.html("2b2620"), "head": Color.html("211d18")},
	# AC-0037: the cute bunny (user ask) - chicken-sized, passive, drops
	# a little leather. The rig adds the long ears (see entities/mob.gd).
	"bunny": {"passive": true, "hp": 3, "w": 0.5, "h": 0.6, "speed": 2.2, "drops": [{"id": 104, "n": 1, "ch": 0.7}], "body": Color.html("f3e3d7"), "head": Color.html("f6ead9")},
}
var tiles := {}


# AC-0141: the blocks/items tables live in res://data/{blocks,items}.json.
# The loader converts the JSON encoding back to the EXACT GDScript types the
# lookups below expect (the before/after dump-diff in tasks/AC-0141/ is the
# proof the round-trip is bit-identical). Encoding rules:
#   - top-level keys are the int ids, written as strings (JSON object keys
#     are strings) and converted back to int here;
#   - {"i": n} -> int n. Godot's JSON parser yields a FLOAT for every bare
#     number, and these tables mix int and float per value (speed is int
#     2/4/6/7 on tools but 1.5 on swords), so ints are tagged, never guessed
#     from value (hard 1.0 / 2.0 / 50.0 stay floats);
#   - {"c": [r,g,b,a]} -> Color(r,g,b,a). Floats; the source spelling was
#     transcribed verbatim and the JSON doubles were proven == the literal
#     doubles (tasks/AC-0141 probe), so the float32 channels are identical;
#   - a bare JSON number -> float (as in the source: hard 0.6 / 1.0 / 1e9);
#   - strings/bools/objects/arrays -> String/Bool/Dictionary/Array.
func _load_table(path: String):
	var f := FileAccess.open(path, FileAccess.READ)
	# Deliberately no null-guards: a missing file (null call below) or a
	# corrupt parse (null iteration) is a SCRIPT ERROR, so G0's census sees
	# a broken table instead of the game silently running on empty data.
	var j = JSON.parse_string(f.get_as_text())
	f.close()
	var out := {}
	for k in j:
		if not k.is_valid_int():
			push_error("data: %s has a non-int top-level key %s (ids are quoted ints)" % [path, k])
			# The null call below is a runtime SCRIPT ERROR on purpose —
			# the tables are mandatory and G0's census must see the break.
			var broken = null
			return broken.size()
		out[int(k)] = _decode_table_value(j[k])
	return out


func _decode_table_value(v):
	if v is Dictionary:
		if v.size() == 1 and v.has("i"):
			return int(v["i"])
		if v.size() == 1 and v.has("c"):
			var c: Array = v["c"]
			return Color(c[0], c[1], c[2], c[3])
		var d := {}
		for k in v:
			d[k] = _decode_table_value(v[k])
		return d
	if v is Array:
		var a: Array = []
		for e in v:
			a.append(_decode_table_value(e))
		return a
	return v


func _init() -> void:
	# AC-0205: "ramp" marks the GROUND materials that smooth into sloped
	# quads across a one-block step (the smooth-ground-ramps toggle —
	# default OFF; see world.gd note_ramps / the C++ ro-scan ramp branch in
	# gdext/src/mesh.cpp). ONLY dirt/grass/sand + the snowy-grass variant:
	# every other block stays a full cube (a ramp needs BOTH column tops
	# in this set). Generated terrain AND player-placed blocks of these
	# types ramp (the rule is id-based, not source-based).
	# AC-0141: the table itself moved to res://data/blocks.json (same
	# entries and types — the dump-diff in tasks/AC-0141/ is the proof).
	# The provenance notes that used to sit between the entries move here
	# with them:
	# AC-0270: player-placed leaves (the shears/Silk-Touch equivalent -
	# there are no shears yet, so ANY placed leaf writes id 30). Same
	# rendering as 7 (the block_rect alias below), but NEVER decays.
	# "drop": 30 so breaking one gives it back.
	# AC-0271: the wooden door, state by ID variant (the block grid is
	# a pure id byte - there is no per-cell state, so open/closed lives
	# in the id). 26/27 = CLOSED (solid 2-high box: mesh + collision
	# come free from the solid path); 29/31 = OPEN (cross panels at the
	# hinge - walk-through, no collision, passes light like every cross
	# block). All four drop the DOOR ITEM (26) - breaking either half
	# reclaims one door; the player.gd break path clears the PAIR. The
	# open panel is rendered symmetric (the cross X reads as a door
	# panel from every direction), so no per-door hinge side is stored
	# (see the _door_pair comment in player.gd).
	# AC-0292: the cave-feature block family (32-36). All solid,
	# drop themselves, atlas tiles at [64..192, 32] (the pack tiles
	# pasted in by this ticket's one-shot probe).
	# AC-0040: hanging banana fruit — cross (non-solid, light-passing,
	# cutout quad like the flowers); lighting.gd already pre-wires id 28
	# as a cross block (passes_light / _att[28]) and blocks_atlas.json
	# reserves its tile at [32,32]. Mined with the hand -> item 126.
	blocks = _load_table("res://data/blocks.json")
	items = _load_table("res://data/items.json")


func _ready() -> void:
	var tex := load("res://assets/blocks_atlas.png")
	if tex is Texture2D:
		atlas_tex = tex
	if FileAccess.file_exists("res://assets/blocks_atlas.json"):
		var f := FileAccess.open("res://assets/blocks_atlas.json", FileAccess.READ)
		var j = JSON.parse_string(f.get_as_text())
		f.close()
		if j is Dictionary:
			atlas_rects = j
	# AC-0128: bake the block tints into the atlas pixels BEFORE the
	# fluid_anim materials capture the atlas texture (they sample it directly).
	_bake_atlas_tints()
	_load_item_atlas()
	_make_fluid_anim_mats()


# AC-0128: the web block tints (TINT_GRASS_TOP/LEAVES/WATER) move from the
# vertex color into the atlas pixels — multiply the tile pixels once at load
# (id 1 top, id 7 x3 faces, id 5 x3 faces; block_tint is white elsewhere).
# The atlas_tex identity changes -> the merge-atlas + material caches
# (identity-keyed) rebuild automatically.
func _bake_atlas_tints() -> void:
	if atlas_tex == null or atlas_rects.is_empty():
		return
	var img: Image = atlas_tex.get_image()
	if img == null:
		return
	# AC-0138: blocks 5/7 share ONE tile across all three faces — baking per
	# face multiplied the tint 3x on the same pixels (leaves -> (1,19,0)
	# black; water -> near-black). Bake each unique rect exactly once.
	var baked := {}
	for tid in [1, 7, 5]:
		for face in ["top", "side", "bottom"]:
			var t: Color = block_tint(tid, face)
			if t == Color.WHITE:
				continue
			var rc: Vector2i = block_rect(tid, face)
			if rc.x < 0 or baked.has(rc):
				continue
			baked[rc] = true
			# AC-0151: tint every stacked anim frame of the strip — the
			# fluid_anim shader (TILE_F 1/32) scrolls uv.y through row f at
			# rc.y + f*TILE_PX, so frame 0 only tinted water grey 31/32 frames.
			# Grass/leaves have anim 1 (single tile) -> unchanged.
			for f in range(block_anim_frames(tid)):
				for py in range(TILE_PX):
					for px in range(TILE_PX):
						var x: int = rc.x + px
						var y: int = rc.y + f * TILE_PX + py
						if x < 0 or x >= img.get_width() or y < 0 or y >= img.get_height():
							continue
						var col: Color = img.get_pixel(x, y)
						img.set_pixel(x, y, Color(col.r * t.r, col.g * t.g, col.b * t.b, col.a))
	atlas_tex = ImageTexture.create_from_image(img)


func _load_item_atlas() -> void:
	var itex := load("res://assets/items_atlas.png")
	if itex is Texture2D:
		item_atlas_tex = itex
	if FileAccess.file_exists("res://assets/items_atlas.json"):
		var f := FileAccess.open("res://assets/items_atlas.json", FileAccess.READ)
		var j = JSON.parse_string(f.get_as_text())
		f.close()
		if j is Dictionary:
			item_atlas_rects = j


func apply_items_atlas(image: Image, rects: Dictionary) -> void:
	item_atlas_tex = ImageTexture.create_from_image(image)
	item_atlas_rects = rects


# Web-faithful: updateAtlasAnims flips stacked frames at 300 ms/frame (web
# default frametime; no .animation.json for water/lava in the Faithful pack).
func apply_atlas(image: Image, rects: Dictionary) -> void:
	atlas_tex = ImageTexture.create_from_image(image)
	atlas_rects = rects
	# AC-0128: texture-pack swaps go through the same tint bake (identity
	# change -> chunk material caches rebuild; re-point the fluid_anim mats
	# at the baked texture below).
	_bake_atlas_tints()
	for bid in fluid_anim_mats:
		fluid_anim_mats[bid].set_shader_parameter("atlas", atlas_tex)
		fluid_anim_mats[bid].set_shader_parameter("anim_frames", float(block_anim_frames(bid)))
	for bid in fluid_anim_bf_mats:
		fluid_anim_bf_mats[bid].set_shader_parameter("atlas", atlas_tex)
		fluid_anim_bf_mats[bid].set_shader_parameter("anim_frames", float(block_anim_frames(bid)))


func _fluid_anim_mat(bid: int, sh: Shader) -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	sm.shader = sh
	sm.set_shader_parameter("atlas", atlas_tex)
	sm.set_shader_parameter("anim_frames", float(block_anim_frames(bid)))
	sm.set_shader_parameter("frame_time", 0.3)
	sm.set_shader_parameter("phase", 0.0)
	sm.set_shader_parameter("alpha_scale", 0.62)
	return sm


func _make_fluid_anim_mats() -> void:
	for bid in [5, 24]:
		# AC-0245 follow-up 3 (user: water must stay two-sided): two passes
		# per fluid id - OUTWARD (cull_back) and INWARD (cull_front). The
		# GPU back-face cull is per-triangle and camera-relative, so
		# exactly one pass draws each boundary face per frame (the side
		# the camera is on) - two-sided water with no coincident
		# fragments, no cull_disabled z-fight.
		var sh_f = load("res://core/fluid_anim.gdshader")
		if sh_f == null:
			continue
		fluid_anim_mats[bid] = _fluid_anim_mat(bid, sh_f)
		var sh_b = load("res://core/fluid_anim_bf.gdshader")
		if sh_b != null:
			fluid_anim_bf_mats[bid] = _fluid_anim_mat(bid, sh_b)


func block_anim_frames(id: int) -> int:
	var e = atlas_rects.get(str(id))
	if e == null:
		return 1
	return maxi(1, int(e.get("anim", 1)))


func block_rect(id: int, face: String) -> Vector2i:
	# AC-0270: persistent leaves (30) render exactly like leaves (7) -
	# they share the atlas cell; only the decay rule differs.
	if id == 30:
		id = 7
	var e = atlas_rects.get(str(id))
	if e == null:
		return Vector2i(-1, -1)
	var r = e.get(face)
	if r == null:
		return Vector2i(-1, -1)
	return Vector2i(int(r[0]), int(r[1]))


func item_rect(_id: int) -> Vector2i:
	var e = item_atlas_rects.get(str(_id))
	if e == null:
		return Vector2i(-1, -1)
	return Vector2i(int(e[0]), int(e[1]))


func item_tint(_id: int) -> Color:
	var it = items.get(_id)
	if it != null and it.has("icon"):
		return Color(it["icon"])
	return Color(0.7, 0.7, 0.7, 1.0)


func block_tint(id: int, face: String) -> Color:
	if id == 1 and face == "top":
		return TINT_GRASS_TOP
	if id == 7:
		return TINT_LEAVES
	if id == 5:
		return TINT_WATER
	return Color.WHITE


func block(_id):
	return blocks.get(_id)


func item(_id):
	return items.get(_id)


func block_tool(_id: int) -> String:
	for k in TOOL_BLOCKS:
		for v in TOOL_BLOCKS[k]:
			if int(v) == int(_id):
				return k
	return ""


func block_drops(_id: int, _is_pick: bool) -> Array:
	var id := int(_id)
	match id:
		1:
			return [{"id": 2, "n": 1, "ch": 1.0}, {"id": 108, "n": 1, "ch": 0.35}]
		12:
			return [{"id": 2, "n": 1, "ch": 1.0}]
		3:
			return [{"id": 9, "n": 1, "ch": 1.0}] if _is_pick else []
		7:
			return [{"id": 108, "n": 1, "ch": 0.15}]
		# AC-0270: persistent leaves drop themselves (the player placed
		# them; they are reclaimable).
		30:
			return [{"id": 30, "n": 1, "ch": 1.0}]
		14:
			return [{"id": 106, "n": 1, "ch": 1.0}] if _is_pick else []
		15:
			return [{"id": 110, "n": 1, "ch": 1.0}] if _is_pick else []
		16:
			return [{"id": 107, "n": 1, "ch": 1.0}] if _is_pick else []
		18:
			return [{"id": 18, "n": 1, "ch": 1.0}, {"id": 108, "n": 1, "ch": 0.5}]
		19:
			return [{"id": 19, "n": 1, "ch": 1.0}, {"id": 108, "n": 1, "ch": 0.5}]
		10:
			return []
	var b = block(id)
	if b != null and b.has("drop"):
		return [{"id": int(b["drop"]), "n": 1, "ch": 1.0}]
	return []


func match_shapeless(cells: Array, grid_size: int = 3):
	var have := {}
	for c in cells:
		if c == null:
			continue
		var cid := int(c["id"])
		if cid == 0:
			continue
		have[cid] = int(have.get(cid, 0)) + int(c["n"])
	for r in shapeless:
		if int(r.get("grid", 2)) > int(grid_size):
			continue
		var ok := true
		for id in r["in"]:
			if int(have.get(id, 0)) != int(r["in"][id]):
				ok = false
				break
		if ok:
			for id in have:
				if not r["in"].has(id):
					ok = false
					break
		if ok:
			return {"id": int(r["out"]["id"]), "n": int(r["out"]["n"])}
	return null


func match_shaped(grid: Array, grid_size: int = 3):
	for r in shaped:
		if int(r.get("grid", 3)) > int(grid_size):
			continue
		var ok := true
		for i in 9:
			var ch := String(r["grid3"][i / 3])[i % 3]
			var want := 0
			if ch != " ":
				want = int(r["map"].get(ch, 0))
			var gid := 0
			if i < grid.size() and grid[i] != null:
				gid = int(grid[i]["id"])
			if gid != want:
				ok = false
				break
		if ok:
			return {"id": int(r["out"]["id"]), "n": int(r["out"]["n"])}
	return null
