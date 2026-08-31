extends Node

const SLOTS := 3
const BASE := "user://awecraft_save"
const SAVE_VERSION := 3  # AC-0155: full-chunk-save era (load validates by shape, not version)
const ChunkIO = preload("res://core/chunk_io.gd")  # AC-0155

var active_slot := -1


func _path(slot: int) -> String:
	return "%s_%d.json" % [BASE, int(slot)]


func file_exists(slot: int) -> bool:
	return FileAccess.file_exists(_path(slot))


func first_empty_slot() -> int:
	for s in range(SLOTS):
		if not file_exists(s):
			return s
	return 0


func first_occupied_slot() -> int:
	for s in range(SLOTS):
		if file_exists(s):
			return s
	return -1


func edit_count(edits: Dictionary) -> int:
	var n := 0
	for ck in edits:
		var cells = edits[ck]
		if typeof(cells) == TYPE_DICTIONARY:
			n += int(cells.size())
	return n


func meta(slot: int) -> Dictionary:
	var d := load_full(slot)
	if d.is_empty():
		return {}
	return {
		"seed": int(d.get("seed", 0)),
		"time": float(d.get("time", 0.0)),
		"edits": edit_count(d.get("edits", {})),
		"ts": int(d.get("ts", 0)),
	}


func load_full(slot: int) -> Dictionary:
	var p := _path(slot)
	if not FileAccess.file_exists(p):
		return {}
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return {}
	var txt := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed


func save_now(slot: int) -> bool:
	if Game.world == null or Game.player == null:
		return false
	var w: Node3D = Game.world
	var p = Game.player
	var data := {
		"version": SAVE_VERSION,
		"seed": int(Game.world_seed),
		# AC-0091: world height at save time; a mismatch on load means the save
		# predates the height change -> soft-fail to a fresh world (same seed),
		# never a script error. Old saves lack this key entirely.
		"height": int(Data.HEIGHT),
		"time": float(Game.time_of_day),
		"ts": int(Time.get_unix_time_from_system()),
		# AC-0143 M5 v2: edits re-keyed "0:<face>:<ccx>:<ccz>:<local>" (home
		# pair: face 0 = ccx >= 0 half, face 1 = ccx < 0 half; non-home faces
		# are data-level in P1a and never record edits).
		"edits": _edits_v2(w.edits),
		# AC-0143 M5 v2: planet list - P1a stores home only (id=0, R=4000
		# exact, orbit=null until AC-0147); load clamps R to [2000, 8000].
		"planets": [
			{"id": 0, "R": 4000, "orbit": null},
		],
		"player": {
			"pos": [float(p.position.x), float(p.position.y), float(p.position.z)],
			"yaw": float(p.get_yaw()),
			"pitch": float(p.get_pitch()),
			"sel": int(p.sel),
			"hp": float(p.hp),
			"hunger": float(p.hunger),
			"inv": p.inv,
			"armor": p.armor,
		},
	}
	var f := FileAccess.open(_path(int(slot)), FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(data))
	f.close()
	return true


func clear(slot: int) -> void:
	var p := _path(int(slot))
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	ChunkIO.clear_dir(int(slot))  # AC-0155: drop the slot's saved columns too


func format_time(t: float) -> String:
	var total := int(fmod(float(t), 1.0) * 24.0 * 60.0)
	if total < 0:
		total += 24 * 60
	var hh := int(total / 60) % 24
	var mm := int(total % 60)
	return "%02d:%02d" % [hh, mm]

# AC-0143 M5: v2 edit key form "0:<face>:<ccx>:<ccz>:<local>" (home pair
# only in P1a; the planet_id:face:cx:cz:local form addresses non-home faces
# from AC-0144+ when the player can reach them). Old runtime key
# "<ccx>,<ccz>" maps to face 0 (ccx >= 0) / face 1 (ccx < 0) - no column
# straddles the x=0 midline.
func _edits_v2(old: Dictionary) -> Dictionary:
	var v2: Dictionary = {}
	for ck in old:
		var parts: PackedStringArray = String(ck).split(",")
		if parts.size() != 2:
			continue
		var ccx: int = parts[0].to_int()
		var ccz: int = parts[1].to_int()
		var face: int = 1 if ccx < 0 else 0
		var cells = old[ck]
		if typeof(cells) != TYPE_DICTIONARY:
			continue
		for li in cells:
			v2["0:%d:%d:%d:%d" % [face, ccx, ccz, li]] = cells[li]
	return v2
