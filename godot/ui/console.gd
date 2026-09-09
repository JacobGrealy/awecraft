# AC-0121: the in-game debug console - backtick/tilde (or F3) toggles the
# overlay (log + command line); commands dispatch to the Debug autoload and
# player state. The player gates its input while Game.console_open so typing
# never steers the game; the focused LineEdit swallows the keys anyway.
extends CanvasLayer

const COMMANDS := {
	"give": "give <id> [n] - add items to the inventory",
	"tp": "tp <x> <y> <z> - teleport the player",
	"time": "time [0.0-1.0] - show or set the time of day",
	"fly": "fly [on|off] - toggle fly mode",
	"setblock": "setblock <x> <y> <z> <id> - set a block",
	"block": "block <x> <y> <z> - read a block",
	"spawn": "spawn <mob> [x y z] - spawn a mob (default: at the player)",
	"seedinv": "seedinv - reset the inventory (old V key)",
	"swing": "swing - one swing with the selected item (old H key)",
	"holdswing": "holdswing [frac] - hold a swing, frac of an arm (old J key)",
	"clearswing": "clearswing - stop the swing, reset the hand (old K key)",
	"help": "help - list commands",
	"quit": "quit - exit the game",
}

var panel: Panel
var log_view: RichTextLabel
var input_line: LineEdit

func _ready() -> void:
	layer = 30
	visible = false
	panel = Panel.new()
	panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	panel.offset_top = -340.0
	panel.offset_bottom = 0.0
	add_child(panel)
	log_view = RichTextLabel.new()
	log_view.set_anchors_preset(Control.PRESET_TOP_LEFT)
	log_view.offset_left = 8.0
	log_view.offset_top = 8.0
	log_view.offset_right = -8.0
	log_view.offset_bottom = -40.0
	log_view.scroll_active = true
	log_view.scroll_following = true
	# plain text - command output may contain brackets (bbcode would eat them)
	log_view.bbcode_enabled = false
	log_view.add_theme_color_override("default_color", Color(0.55, 0.95, 0.6, 1.0))
	log_view.add_theme_font_size_override("normal_font_size", 14)
	panel.add_child(log_view)
	# AC-0121: LineEdit, not TextEdit - in Godot 4.7 the TextEdit class no
	# longer exposes the text_submitted signal (LineEdit does).
	input_line = LineEdit.new()
	# without this the edit "finishes" after the first ENTER and silently
	# stops accepting keys for every later command (verified in a probe:
	# second submit never fires until this is set).
	input_line.keep_editing_on_text_submit = true
	input_line.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	input_line.offset_top = -32.0
	input_line.offset_bottom = 0.0
	input_line.offset_left = 8.0
	input_line.offset_right = -8.0
	input_line.placeholder_text = "type a command - 'help' lists them"
	input_line.text_submitted.connect(_on_submit)
	panel.add_child(input_line)
	add_log("[console ready]")

func _process(_dt: float) -> void:
	# AC-0121: the quit-to-menu flow frees the game nodes - close the console
	# whenever the game is no longer running (covers every menu path).
	if visible and Game.mode == "menu":
		close_console()

func toggle() -> void:
	if visible:
		close_console()
	else:
		open_console()

func open_console() -> void:
	if visible:
		return
	visible = true
	Game.console_open = true
	if Game.mode == "play":
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	add_log("[console open]")
	call_deferred("_focus_input")

func _focus_input() -> void:
	if visible:
		input_line.grab_focus()

func close_console() -> void:
	if not visible:
		return
	visible = false
	Game.console_open = false
	if input_line.has_focus():
		input_line.release_focus()
	if Game.mode == "play":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func add_log(s: String) -> void:
	log_view.append_text(s + "\n")

func log_lines() -> int:
	return log_view.get_line_count()

func log_scrolled() -> bool:
	# content overflows the visible viewport = the log has scrolled (4.7 has
	# no get_scroll() on RichTextLabel; scroll_following pins the view).
	return log_view.get_line_count() > maxi(1, log_view.get_visible_line_count())

func _on_submit(line: String) -> void:
	var s := line.strip_edges()
	if s == "":
		return
	dispatch(s)
	input_line.clear()

func dispatch(s: String) -> void:
	var tok: PackedStringArray = s.split(" ", false)
	var cmd := tok[0].to_lower()
	var p: Array = []
	for i in range(1, tok.size()):
		p.append(tok[i])
	match cmd:
		"give":
			if p.size() < 1 or not p[0].is_valid_int():
				add_log("usage: give <id> [n]")
				return
			var n := 1 if p.size() < 2 else int(p[1])
			Debug.give_item(int(p[0]), n)
			add_log("gave %d x%d" % [int(p[0]), n])
		"tp":
			if p.size() < 3:
				add_log("usage: tp <x> <y> <z>")
				return
			Debug.teleport(float(p[0]), float(p[1]), float(p[2]))
			add_log("teleported to (%s, %s, %s)" % [p[0], p[1], p[2]])
		"time":
			if p.size() < 1:
				add_log("time = %.2f" % float(Game.time_of_day))
				return
			Debug.set_time(clampf(float(p[0]), 0.0, 1.0))
			add_log("time set to %.2f" % float(p[0]))
		"fly":
			var on: bool = p.size() == 0 or str(p[0]) == "on" or str(p[0]) == "1"
			Debug.fly(on)
			add_log("fly %s" % ("on" if on else "off"))
		"setblock":
			if p.size() < 4:
				add_log("usage: setblock <x> <y> <z> <id>")
				return
			Debug.set_block(int(p[0]), int(p[1]), int(p[2]), int(p[3]))
			add_log("block set")
		"block":
			if p.size() < 3:
				add_log("usage: block <x> <y> <z>")
				return
			add_log("block = %s" % str(Debug.block_at(int(p[0]), int(p[1]), int(p[2]))))
		"spawn":
			if p.size() < 1:
				add_log("usage: spawn <mob> [x y z]")
				return
			var at: Vector3 = Vector3.ZERO if Game.player == null else Game.player.position
			var x: float = at.x if p.size() < 4 else float(p[1])
			var y: float = at.y if p.size() < 4 else float(p[2])
			var z: float = at.z if p.size() < 4 else float(p[3])
			var m := Debug.spawn_mob(p[0], x, y, z)
			add_log("spawned %s (%s)" % [p[0], "ok" if m != null else "failed"])
		"seedinv":
			Debug.seed_inv()
			add_log("inventory seeded")
		"swing":
			if Game.player == null:
				add_log("no player")
				return
			Game.player.start_swing()
			add_log("swing")
		"holdswing":
			if Game.player == null:
				add_log("no player")
				return
			var hfrac := 0.5 if p.size() < 1 else clampf(float(p[0]), 0.0, 1.0)
			Game.player.hold_swing(hfrac)
			add_log("holding swing at %.2f" % hfrac)
		"clearswing":
			if Game.player == null:
				add_log("no player")
				return
			Game.player.clear_swing()
			add_log("swing cleared")
		"quit":
			add_log("[quitting...]")
			get_tree().quit()
			return
		"help":
			for k in COMMANDS:
				add_log(COMMANDS[k])
			return
		_:
			add_log("unknown command: %s (try 'help')" % cmd)
