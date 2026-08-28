extends Node

const CHUNK := 16
const HEIGHT := 80
const SEA := 30

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

var atlas_tex: Texture2D = null
var atlas_rects := {}
var item_atlas_tex: Texture2D = null
var item_atlas_rects := {}
var fluid_anim_mats := {}
const ATLAS_PX := 1024.0
const TILE_PX := 32

const TINT_GRASS_TOP := Color(93.0 / 255.0, 178.0 / 255.0, 55.0 / 255.0)
const TINT_LEAVES := Color(60.0 / 255.0, 140.0 / 255.0, 48.0 / 255.0)
const TINT_WATER := Color(47.0 / 255.0, 107.0 / 255.0, 235.0 / 255.0)

var blocks := {}
const TOOL_BLOCKS := {
	"pick": [3, 9, 14, 15, 16, 25],
	"axe": [6, 7, 8],
	"shovel": [1, 2, 4, 12, 13],
}
var items := {
	100: {"name": "Stick", "icon": Color(0.72, 0.55, 0.35), "stack": 64},
	101: {"name": "Raw Meat", "icon": Color(0.8, 0.47, 0.43), "stack": 64, "food": 2},
	102: {"name": "Cooked Meat", "icon": Color(0.55, 0.35, 0.2), "stack": 64, "food": 5},
	103: {"name": "Wool", "icon": Color(0.94, 0.94, 0.91), "stack": 64},
	104: {"name": "Leather", "icon": Color(0.72, 0.5, 0.33), "stack": 64},
	105: {"name": "Iron Ingot", "icon": Color(0.75, 0.75, 0.78), "stack": 64},
	106: {"name": "Coal", "icon": Color(0.15, 0.15, 0.16), "stack": 64},
	107: {"name": "Diamond", "icon": Color(0.3, 0.72, 0.7), "stack": 64},
	108: {"name": "Seeds", "icon": Color(0.7, 0.6, 0.25), "stack": 64},
	109: {"name": "Iron Sword", "icon": Color(0.75, 0.75, 0.78), "stack": 1, "dmg": 4, "tool": "sword", "tier": 3, "speed": 1.5},
	110: {"name": "Raw Iron", "icon": Color(0.75, 0.75, 0.78), "stack": 64},
	111: {"name": "Wooden Pickaxe", "icon": Color(0.55, 0.38, 0.2), "stack": 1, "dmg": 1, "tool": "pick", "tier": 1, "speed": 2},
	112: {"name": "Stone Pickaxe", "icon": Color(0.46, 0.46, 0.47), "stack": 1, "dmg": 1, "tool": "pick", "tier": 2, "speed": 4},
	113: {"name": "Iron Pickaxe", "icon": Color(0.75, 0.75, 0.78), "stack": 1, "dmg": 2, "tool": "pick", "tier": 3, "speed": 6},
	114: {"name": "Diamond Pickaxe", "icon": Color(0.3, 0.72, 0.7), "stack": 1, "dmg": 3, "tool": "pick", "tier": 4, "speed": 7},
	115: {"name": "Wooden Axe", "icon": Color(0.55, 0.38, 0.2), "stack": 1, "dmg": 3, "tool": "axe", "tier": 1, "speed": 2},
	116: {"name": "Stone Axe", "icon": Color(0.46, 0.46, 0.47), "stack": 1, "dmg": 4, "tool": "axe", "tier": 2, "speed": 4},
	117: {"name": "Iron Axe", "icon": Color(0.75, 0.75, 0.78), "stack": 1, "dmg": 5, "tool": "axe", "tier": 3, "speed": 6},
	118: {"name": "Diamond Axe", "icon": Color(0.3, 0.72, 0.7), "stack": 1, "dmg": 6, "tool": "axe", "tier": 4, "speed": 7},
	119: {"name": "Wooden Shovel", "icon": Color(0.55, 0.38, 0.2), "stack": 1, "dmg": 2, "tool": "shovel", "tier": 1, "speed": 2},
	120: {"name": "Stone Shovel", "icon": Color(0.46, 0.46, 0.47), "stack": 1, "dmg": 2, "tool": "shovel", "tier": 2, "speed": 4},
	121: {"name": "Iron Shovel", "icon": Color(0.75, 0.75, 0.78), "stack": 1, "dmg": 3, "tool": "shovel", "tier": 3, "speed": 6},
	122: {"name": "Diamond Shovel", "icon": Color(0.3, 0.72, 0.7), "stack": 1, "dmg": 3, "tool": "shovel", "tier": 4, "speed": 7},
	123: {"name": "Wooden Sword", "icon": Color(0.55, 0.38, 0.2), "stack": 1, "dmg": 3, "tool": "sword", "tier": 1, "speed": 1.5},
	124: {"name": "Stone Sword", "icon": Color(0.46, 0.46, 0.47), "stack": 1, "dmg": 4, "tool": "sword", "tier": 2, "speed": 1.5},
	125: {"name": "Diamond Sword", "icon": Color(0.3, 0.72, 0.7), "stack": 1, "dmg": 6, "tool": "sword", "tier": 4, "speed": 1.5},
	127: {"name": "Leather Helmet", "icon": Color(0.72, 0.5, 0.33), "stack": 1, "armor": "head", "dr": 1, "mat": "leather"},
	128: {"name": "Leather Chestplate", "icon": Color(0.72, 0.5, 0.33), "stack": 1, "armor": "chest", "dr": 3, "mat": "leather"},
	129: {"name": "Leather Leggings", "icon": Color(0.72, 0.5, 0.33), "stack": 1, "armor": "legs", "dr": 2, "mat": "leather"},
	130: {"name": "Leather Boots", "icon": Color(0.72, 0.5, 0.33), "stack": 1, "armor": "boots", "dr": 1, "mat": "leather"},
	131: {"name": "Iron Helmet", "icon": Color(0.75, 0.75, 0.78), "stack": 1, "armor": "head", "dr": 2, "mat": "iron"},
	132: {"name": "Iron Chestplate", "icon": Color(0.75, 0.75, 0.78), "stack": 1, "armor": "chest", "dr": 6, "mat": "iron"},
	133: {"name": "Iron Leggings", "icon": Color(0.75, 0.75, 0.78), "stack": 1, "armor": "legs", "dr": 5, "mat": "iron"},
	134: {"name": "Iron Boots", "icon": Color(0.75, 0.75, 0.78), "stack": 1, "armor": "boots", "dr": 2, "mat": "iron"},
	135: {"name": "Diamond Helmet", "icon": Color(0.3, 0.72, 0.7), "stack": 1, "armor": "head", "dr": 3, "mat": "diamond"},
	136: {"name": "Diamond Chestplate", "icon": Color(0.3, 0.72, 0.7), "stack": 1, "armor": "chest", "dr": 8, "mat": "diamond"},
	137: {"name": "Diamond Leggings", "icon": Color(0.3, 0.72, 0.7), "stack": 1, "armor": "legs", "dr": 6, "mat": "diamond"},
	138: {"name": "Diamond Boots", "icon": Color(0.3, 0.72, 0.7), "stack": 1, "armor": "boots", "dr": 3, "mat": "diamond"},
	139: {"name": "Bucket", "icon": Color(0.204, 0.204, 0.227), "stack": 1, "bucket": 0},
	140: {"name": "Water Bucket", "icon": Color(0.157, 0.431, 0.863), "stack": 1, "bucket": 5},
	141: {"name": "Lava Bucket", "icon": Color(0.976, 0.431, 0.118), "stack": 1, "bucket": 24},
	142: {"name": "Bow", "icon": Color(0.55, 0.4, 0.25), "stack": 1, "dmg": 1},
	143: {"name": "Arrow", "icon": Color(0.55, 0.4, 0.25), "stack": 64},
	144: {"name": "Bone", "icon": Color(0.93, 0.93, 0.88), "stack": 64},
	145: {"name": "String", "icon": Color(0.85, 0.82, 0.75), "stack": 64},
	146: {"name": "Raw Chicken", "icon": Color(0.98, 0.78, 0.65), "stack": 64, "food": 2},
	147: {"name": "Cooked Chicken", "icon": Color(0.72, 0.45, 0.25), "stack": 64, "food": 5},
}
# grid: 2 = craftable in the E-inventory 2x2 grid; grid: 3 = crafting-table 3x3 only
var shapeless := [
	{"in": {6: 1}, "grid": 2, "out": {"id": 8, "n": 4}},
	{"in": {8: 4}, "grid": 2, "out": {"id": 20, "n": 1}},
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
}
var tiles := {}


func _init() -> void:
	blocks = {
		1: {"name": "Grass", "solid": true, "cross": false, "hard": 0.6, "light": 0, "drop": 2, "color": {"top": C_GRASS_TOP, "side": C_GRASS_SIDE, "bottom": C_DIRT}},
		2: {"name": "Dirt", "solid": true, "cross": false, "hard": 0.6, "light": 0, "drop": 2, "color": {"top": C_DIRT, "side": C_DIRT, "bottom": C_DIRT}},
		3: {"name": "Stone", "solid": true, "cross": false, "hard": 1.5, "light": 0, "drop": 9, "color": {"top": C_STONE, "side": C_STONE, "bottom": C_STONE}},
		4: {"name": "Sand", "solid": true, "cross": false, "hard": 0.6, "light": 0, "drop": 4, "color": {"top": C_SAND, "side": C_SAND, "bottom": C_SAND}},
		5: {"name": "Water", "solid": false, "cross": true, "hard": 1e9, "light": 0, "color": {"top": C_WATER, "side": C_WATER, "bottom": C_WATER}},
		6: {"name": "Oak Log", "solid": true, "cross": false, "hard": 1.0, "light": 0, "drop": 6, "color": {"top": Color(0.55, 0.42, 0.24), "side": Color(0.42, 0.3, 0.18), "bottom": Color(0.55, 0.42, 0.24)}},
		7: {"name": "Leaves", "solid": false, "cross": false, "cutout": true, "hard": 0.2, "light": 0, "color": {"top": C_LEAVES, "side": C_LEAVES, "bottom": C_LEAVES}},
		8: {"name": "Planks", "solid": true, "cross": false, "hard": 1.0, "light": 0, "drop": 8, "color": {"top": Color(0.72, 0.56, 0.34), "side": Color(0.72, 0.56, 0.34), "bottom": Color(0.72, 0.56, 0.34)}},
		9: {"name": "Cobblestone", "solid": true, "cross": false, "hard": 2.0, "light": 0, "drop": 9, "color": {"top": C_COBBLE, "side": C_COBBLE, "bottom": C_COBBLE}},
		17: {"name": "Bricks", "solid": true, "cross": false, "hard": 2.0, "light": 0, "drop": 17, "color": {"top": Color(0.6, 0.3, 0.25), "side": Color(0.6, 0.3, 0.25), "bottom": Color(0.6, 0.3, 0.25)}},
		18: {"name": "Rose", "solid": false, "cross": true, "hard": 0.1, "light": 0, "drop": 18, "color": {"top": C_ROSE, "side": C_ROSE, "bottom": C_ROSE}},
		19: {"name": "Dandelion", "solid": false, "cross": true, "hard": 0.1, "light": 0, "drop": 19, "color": {"top": C_DANDELION, "side": C_DANDELION, "bottom": C_DANDELION}},
		20: {"name": "Crafting Table", "solid": true, "cross": false, "hard": 1.0, "light": 0, "drop": 20, "color": {"top": Color(0.62, 0.47, 0.26), "side": Color(0.55, 0.4, 0.22), "bottom": Color(0.72, 0.56, 0.34)}},
		21: {"name": "Furnace", "solid": true, "cross": false, "hard": 2.0, "light": 0, "drop": 21, "color": {"top": Color(0.5, 0.46, 0.46), "side": Color(0.45, 0.4, 0.4), "bottom": Color(0.5, 0.46, 0.46)}},
		11: {"name": "Bedrock", "solid": true, "cross": false, "hard": 1e9, "light": 0, "color": {"top": C_BEDROCK, "side": C_BEDROCK, "bottom": C_BEDROCK}},
		12: {"name": "Snowy Grass", "solid": true, "cross": false, "hard": 0.6, "light": 0, "drop": 2, "color": {"top": C_SNOW, "side": C_SNOW_SIDE, "bottom": C_DIRT}},
		14: {"name": "Coal Ore", "solid": true, "cross": false, "hard": 2.0, "light": 0, "color": {"top": C_COAL_ORE, "side": C_COAL_ORE, "bottom": C_COAL_ORE}},
		15: {"name": "Iron Ore", "solid": true, "cross": false, "hard": 2.5, "light": 0, "color": {"top": C_IRON_ORE, "side": C_IRON_ORE, "bottom": C_IRON_ORE}},
		16: {"name": "Diamond Ore", "solid": true, "cross": false, "hard": 3.0, "light": 0, "color": {"top": C_DIAMOND_ORE, "side": C_DIAMOND_ORE, "bottom": C_DIAMOND_ORE}},
		22: {"name": "Torch", "solid": false, "cross": true, "thin": true, "hard": 0.1, "light": 14, "drop": 22, "color": {"top": C_TORCH, "side": C_TORCH, "bottom": C_TORCH}},
		23: {"name": "Glowstone", "solid": true, "cross": false, "hard": 0.3, "light": 12, "drop": 23, "color": {"top": C_GLOWSTONE, "side": C_GLOWSTONE, "bottom": C_GLOWSTONE}},
		24: {"name": "Lava", "solid": false, "cross": true, "hard": 1e9, "light": 15, "color": {"top": C_LAVA, "side": C_LAVA, "bottom": C_LAVA}},
		25: {"name": "Obsidian", "solid": true, "cross": false, "hard": 50.0, "light": 0, "drop": 25, "color": {"top": C_OBSIDIAN, "side": C_OBSIDIAN, "bottom": C_OBSIDIAN}},
	}


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
	for tid in [1, 7, 5]:
		for face in ["top", "side", "bottom"]:
			var t: Color = block_tint(tid, face)
			if t == Color.WHITE:
				continue
			var rc: Vector2i = block_rect(tid, face)
			if rc.x < 0:
				continue
			for py in range(TILE_PX):
				for px in range(TILE_PX):
					var x: int = rc.x + px
					var y: int = rc.y + py
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


func _make_fluid_anim_mats() -> void:
	for bid in [5, 24]:
		var sm := ShaderMaterial.new()
		var sh = load("res://core/fluid_anim.gdshader")
		if sh == null:
			sm.queue_free()
			continue
		sm.shader = sh
		sm.set_shader_parameter("atlas", atlas_tex)
		sm.set_shader_parameter("anim_frames", float(block_anim_frames(bid)))
		sm.set_shader_parameter("frame_time", 0.3)
		sm.set_shader_parameter("phase", 0.0)
		sm.set_shader_parameter("alpha_scale", 0.62)
		fluid_anim_mats[bid] = sm


func block_anim_frames(id: int) -> int:
	var e = atlas_rects.get(str(id))
	if e == null:
		return 1
	return maxi(1, int(e.get("anim", 1)))


func block_rect(id: int, face: String) -> Vector2i:
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
