class_name Atlas

const ATLAS_PX := 1024
const TILE_PX := 32
const DIR := "assets/minecraft/textures/block/"
const SUF := ".png"

const MAP := {
	"1": ["grass_block_top", "grass_block_side", "dirt"],
	"2": ["dirt", "dirt", "dirt"],
	"3": ["stone", "stone", "stone"],
	"4": ["sand", "sand", "sand"],
	"5": ["water_still", "water_still", "water_still"],
	"6": ["oak_log_top", "oak_log", "oak_log_top"],
	"7": ["oak_leaves", "oak_leaves", "oak_leaves"],
	"8": ["oak_planks", "oak_planks", "oak_planks"],
	"9": ["cobblestone", "cobblestone", "cobblestone"],
	"11": ["bedrock", "bedrock", "bedrock"],
	"12": ["snow", "grass_block_side", "dirt"],
	"14": ["coal_ore", "coal_ore", "coal_ore"],
	"15": ["iron_ore", "iron_ore", "iron_ore"],
	"16": ["diamond_ore", "diamond_ore", "diamond_ore"],
	"17": ["bricks", "bricks", "bricks"],
	"18": ["poppy", "poppy", "poppy"],
	"19": ["dandelion", "dandelion", "dandelion"],
	"20": ["crafting_table_top", "crafting_table_side", "oak_planks"],
	"21": ["furnace_top", "furnace_side", "furnace_top"],
	"22": ["torch", "torch", "torch"],
	"23": ["glowstone", "glowstone", "glowstone"],
	"24": ["lava_still", "lava_still", "lava_still"],
	"25": ["obsidian", "obsidian", "obsidian"],
	"28": ["portal", "portal", "portal"],
}


static func import_pack(pack_path: String) -> Dictionary:
	var z := ZIPReader.new()
	var err := z.open(pack_path)
	if err != OK:
		return {"ok": false, "error": "zip_open_%d" % err}
	var atlas: Image = null
	var rects := {}
	if FileAccess.file_exists("res://assets/blocks_atlas.json"):
		var jf := FileAccess.open("res://assets/blocks_atlas.json", FileAccess.READ)
		var j = JSON.parse_string(jf.get_as_text())
		jf.close()
		if j is Dictionary:
			rects = j
	var existing := false
	if rects.size() > 0:
		var bt = load("res://assets/blocks_atlas.png")
		if bt is Texture2D:
			atlas = bt.get_image().duplicate()
			existing = true
	if atlas == null:
		atlas = Image.create_empty(ATLAS_PX, ATLAS_PX, false, Image.FORMAT_RGBA8)
	var used := {}
	for id in rects:
		var faces: Dictionary = rects[id]
		for fn in faces:
			used[Vector2i(int(faces[fn][0]), int(faces[fn][1]))] = true
	var tiles_ok := 0
	var missing: Array = []
	for id in MAP:
		var bkey: String = str(id)
		if rects.has(bkey):
			continue
		var names: Array = MAP[id]
		var info = Data.block(int(id))
		var fallback := Color(0.45, 0.2, 0.75)
		if info != null and info.has("color"):
			fallback = info.color.side
		var faces := {}
		var ftile := {}
		for fi in range(3):
			var fname: String = names[fi]
			var face_name := "top" if fi == 0 else "side" if fi == 1 else "bottom"
			if ftile.has(fname):
				faces[face_name] = ftile[fname]
				continue
			var tl := _free_tile(used)
			used[tl] = true
			var region := Rect2(tl, Vector2(TILE_PX, TILE_PX))
			var img: Image = null
			var path := DIR + fname + SUF
			if z.file_exists(path):
				img = Image.new()
				var le := img.load_png_from_buffer(z.read_file(path))
				if le != OK:
					img = null
			if img == null:
				atlas.fill_rect(region, fallback)
				missing.append(fname)
			else:
				if img.get_format() != Image.FORMAT_RGBA8:
					img.convert(Image.FORMAT_RGBA8)
				if img.get_width() != TILE_PX or img.get_height() != TILE_PX:
					img.resize(TILE_PX, TILE_PX)
				atlas.blit_rect(img, Rect2i(0, 0, TILE_PX, TILE_PX), tl)
				tiles_ok += 1
			ftile[fname] = [tl.x, tl.y, TILE_PX, TILE_PX]
			faces[face_name] = [tl.x, tl.y, TILE_PX, TILE_PX]
		rects[bkey] = faces
	z.close()
	DirAccess.make_dir_recursive_absolute("res://assets")
	atlas.save_png("res://assets/blocks_atlas.png")
	var f := FileAccess.open("res://assets/blocks_atlas.json", FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(rects))
		f.close()
	return {"ok": true, "merged": existing, "tiles": tiles_ok, "missing": missing, "blocks": rects.size()}


static func _free_tile(used: Dictionary) -> Vector2i:
	var ty := 0
	while ty < ATLAS_PX / TILE_PX:
		var tx := 0
		while tx < ATLAS_PX / TILE_PX:
			var p := Vector2i(tx * TILE_PX, ty * TILE_PX)
			if not used.has(p):
				return p
			tx += 1
		ty += 1
	return Vector2i(-1, -1)
