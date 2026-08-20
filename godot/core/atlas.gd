class_name Atlas

const ATLAS_PX := 1024
const TILE_PX := 32
const DIR := "assets/minecraft/textures/block/"
const IDIR := "assets/minecraft/textures/"
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

const IMAP := {
	100: "item/stick.png",
	101: "item/beef.png",
	102: "item/cooked_beef.png",
	103: "block/white_wool.png",
	104: "item/leather.png",
	105: "item/iron_ingot.png",
	106: "item/coal.png",
	107: "item/diamond.png",
	108: "item/wheat_seeds.png",
	109: "item/iron_sword.png",
	110: "item/raw_iron.png",
	111: "item/wooden_pickaxe.png",
	112: "item/stone_pickaxe.png",
	113: "item/iron_pickaxe.png",
	114: "item/diamond_pickaxe.png",
	115: "item/wooden_axe.png",
	116: "item/stone_axe.png",
	117: "item/iron_axe.png",
	118: "item/diamond_axe.png",
	119: "item/wooden_shovel.png",
	120: "item/stone_shovel.png",
	121: "item/iron_shovel.png",
	122: "item/diamond_shovel.png",
	123: "item/wooden_sword.png",
	124: "item/stone_sword.png",
	125: "item/diamond_sword.png",
	127: "item/leather_helmet.png",
	128: "item/leather_chestplate.png",
	129: "item/leather_leggings.png",
	130: "item/leather_boots.png",
	131: "item/iron_helmet.png",
	132: "item/iron_chestplate.png",
	133: "item/iron_leggings.png",
	134: "item/iron_boots.png",
	135: "item/diamond_helmet.png",
	136: "item/diamond_chestplate.png",
	137: "item/diamond_leggings.png",
	138: "item/diamond_boots.png",
	139: "item/bucket.png",
	140: "item/water_bucket.png",
	141: "item/lava_bucket.png",
	142: "item/bow.png",
	143: "item/arrow.png",
	144: "item/bone.png",
	145: "item/string.png",
	146: "item/chicken.png",
	147: "item/cooked_chicken.png",
}


static func import_pack(pack_path: String) -> Dictionary:
	var r := import_pack_mem(pack_path)
	if not bool(r.get("ok", false)):
		return r
	return _save_pack(r)


static func import_pack_mem(source) -> Dictionary:
	var z := ZIPReader.new()
	var err: int = -1
	if source is PackedByteArray:
		err = z.open_buffer(source)
	else:
		err = z.open(String(source))
	if err != OK:
		return {"ok": false, "error": "zip_open_%d" % err}
	return _import_core(z)


static func _save_pack(r: Dictionary) -> Dictionary:
	if not bool(r.get("ok", false)):
		return r
	var atlas: Image = r["image"]
	var rects: Dictionary = r["rects"]
	var out := {}
	for k in r:
		if k != "image":
			out[k] = r[k]
	DirAccess.make_dir_recursive_absolute("res://assets")
	atlas.save_png("res://assets/blocks_atlas.png")
	var f := FileAccess.open("res://assets/blocks_atlas.json", FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(rects))
		f.close()
	if r.has("item_image") and r["item_image"] is Image:
		(r["item_image"] as Image).save_png("res://assets/items_atlas.png")
		var ir = r.get("item_rects")
		if ir is Dictionary:
			var fi := FileAccess.open("res://assets/items_atlas.json", FileAccess.WRITE)
			if fi:
				fi.store_string(JSON.stringify(ir))
				fi.close()
	return out


static func _import_core(z: ZIPReader) -> Dictionary:
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
			var fr = faces[fn]
			if fr is Array:
				used[Vector2i(int(fr[0]), int(fr[1]))] = true
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
				if img.get_width() == TILE_PX and img.get_height() > TILE_PX and img.get_height() % TILE_PX == 0:
					# stacked animation frames (web: ANIM flip); frame 0 in the tile,
					# frames 1..N-1 in the tiles directly below it
					var nfr := int(img.get_height()) / TILE_PX
					var st := _strip_tile(used, nfr)
					if st.x >= 0:
						for fr in range(nfr):
							used[Vector2i(st.x, st.y + fr * TILE_PX)] = true
							atlas.blit_rect(img, Rect2i(0, fr * TILE_PX, TILE_PX, TILE_PX), Vector2i(st.x, st.y + fr * TILE_PX))
						tl = st
						faces["anim"] = nfr
					else:
						tl = Vector2i(-1, -1)
						missing.append(fname + "(strip)")
				else:
					if img.get_width() != TILE_PX or img.get_height() != TILE_PX:
						img.resize(TILE_PX, TILE_PX)
					atlas.blit_rect(img, Rect2i(0, 0, TILE_PX, TILE_PX), tl)
					tiles_ok += 1
			ftile[fname] = [tl.x, tl.y, TILE_PX, TILE_PX]
			faces[face_name] = [tl.x, tl.y, TILE_PX, TILE_PX]
			rects[bkey] = faces
	var ir := _import_items(z)
	z.close()
	return {
		"ok": true, "merged": existing, "tiles": tiles_ok, "missing": missing, "blocks": rects.size(), "image": atlas, "rects": rects,
		"item_tiles": ir["tiles"], "item_missing": ir["missing"], "item_count": ir["items"],
		"item_image": ir["image"], "item_rects": ir["rects"],
	}


static func _import_items(z: ZIPReader) -> Dictionary:
	var img := Image.create_empty(ATLAS_PX, ATLAS_PX, false, Image.FORMAT_RGBA8)
	var used := {}
	var rects := {}
	var tiles := 0
	var missing: Array = []
	for id in IMAP:
		var bkey: String = str(id)
		var path: String = IDIR + String(IMAP[id])
		var tl := _free_tile(used)
		if tl.x < 0:
			missing.append(bkey + "(full)")
			continue
		used[tl] = true
		var region := Rect2(tl, Vector2(TILE_PX, TILE_PX))
		var iimg: Image = null
		if z.file_exists(path):
			iimg = Image.new()
			if iimg.load_png_from_buffer(z.read_file(path)) != OK:
				iimg = null
		if iimg == null:
			var info = Data.items.get(int(id))
			var fallback := Color(0.7, 0.7, 0.7, 1.0)
			if info != null and info.has("icon"):
				fallback = Color(info["icon"])
			img.fill_rect(region, fallback)
			missing.append(bkey)
		else:
			if iimg.get_format() != Image.FORMAT_RGBA8:
				iimg.convert(Image.FORMAT_RGBA8)
			if iimg.get_width() != TILE_PX or iimg.get_height() != TILE_PX:
				iimg.resize(TILE_PX, TILE_PX)
			img.blit_rect(iimg, Rect2i(0, 0, TILE_PX, TILE_PX), tl)
			tiles += 1
		rects[bkey] = [tl.x, tl.y, TILE_PX, TILE_PX]
	return {"ok": true, "tiles": tiles, "missing": missing, "items": rects.size(), "image": img, "rects": rects}


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


static func _strip_tile(used: Dictionary, nfr: int) -> Vector2i:
	var cols := ATLAS_PX / TILE_PX
	for tx in range(cols):
		for tyi in range(cols - nfr + 1):
			var ok := true
			for i in range(nfr):
				if used.has(Vector2i(tx * TILE_PX, (tyi + i) * TILE_PX)):
					ok = false
					break
			if ok:
				return Vector2i(tx * TILE_PX, tyi * TILE_PX)
	return Vector2i(-1, -1)
