extends SceneTree

const ATLAS := "res://assets/blocks_atlas.png"
const JSONF := "res://assets/blocks_atlas.json"
const PACK := "/home/angrygiant/github_projects/AweCraft/Faithful-32x-1.21.11.mcpack"


func _initialize() -> void:
	var rects := {}
	if FileAccess.file_exists(JSONF):
		var jf := FileAccess.open(JSONF, FileAccess.READ)
		var j = JSON.parse_string(jf.get_as_text())
		jf.close()
		if j is Dictionary:
			rects = j
	var atlas := Image.new()
	var le := atlas.load(ATLAS)
	print("atlas load err " + str(le))
	if le == OK:
		print("atlas fmt " + str(atlas.get_format()) + " size " + str(atlas.get_size()))
		print("atlas total alpha<0.5: " + str(_count_tr(atlas)))
		for id in ["17", "18", "19", "7"]:
			var faces: Variant = rects.get(id)
			if faces == null:
				print("id " + id + " not in rects")
				continue
			var r: Array = faces["side"]
			var px := atlas.get_pixelv(Vector2i(int(r[0]) + 16, int(r[1]) + 16))
			# scan whole tile
			var tr := 0
			var w := int(r[2])
			var h := int(r[3])
			for x in range(w):
				for y in range(h):
					if atlas.get_pixelv(Vector2i(int(r[0]) + x, int(r[1]) + y)).a < 0.5:
						tr += 1
			print("tile id=" + id + " rect=" + str(r) + " alpha<0.5=" + str(tr) + " center=" + px.to_html())
	# raw source tiles from the mcpack
	var z := ZIPReader.new()
	var ze := z.open(PACK)
	print("zip err " + str(ze))
	if ze == OK:
		for name in ["assets/minecraft/textures/block/oak_leaves.png",
				"assets/minecraft/textures/block/poppy.png",
				"assets/minecraft/textures/block/dandelion.png"]:
			if not z.file_exists(name):
				print("missing in pack: " + name)
				continue
			var img := Image.new()
			var e2 := img.load_png_from_buffer(z.read_file(name))
			var parts: PackedStringArray = name.split("/")
			print("src " + parts[parts.size() - 1] + " fmt " + str(img.get_format())
					+ " size " + str(img.get_size()) + " alpha<0.5 " + str(_count_tr(img)))
		z.close()
	quit()


func _count_tr(im: Image) -> int:
	var n := 0
	var w := im.get_width()
	var h := im.get_height()
	for x in w:
		for y in h:
			if im.get_pixelv(Vector2i(x, y)).a < 0.5:
				n += 1
	return n
