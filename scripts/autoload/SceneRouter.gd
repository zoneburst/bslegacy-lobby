extends Node
##
## Scene navigation with a back stack, plus the one place the global UI theme
## is installed.
##
## Every menu calls SceneRouter.go("battle_menu") rather than
## get_tree().change_scene_to_file(). Centralising it buys a working Back button
## everywhere, a single place for transition sounds, and one list of route
## names that documents the whole UI flow.
##
## "bot", "random" and "room" all open the Battle hub on the matching tab. They
## were separate screens until 0.6.0; keeping the route names means nothing
## that already navigates to them has to change.
##

const ROUTES := {
	"start":       "res://scenes/menu/StartScreen.tscn",
	"main":        "res://scenes/menu/MainMenu.tscn",
	"battle_menu": "res://scenes/menu/BattleMenu.tscn",
	"bot":         "res://scenes/menu/BattleMenu.tscn",
	"random":      "res://scenes/menu/BattleMenu.tscn",
	"room":        "res://scenes/menu/BattleMenu.tscn",
	"deck_list":   "res://scenes/deck/DeckList.tscn",
	"deck_editor": "res://scenes/deck/DeckEditor.tscn",
	"settings":    "res://scenes/menu/SettingsScreen.tscn",
	"profile":     "res://scenes/menu/ProfileScreen.tscn",
	"patch_notes": "res://scenes/menu/PatchNotes.tscn",
	"bug_report":  "res://scenes/menu/BugReport.tscn",
	"game":        "res://scenes/battle/GameBoard.tscn",
}

## How long a scene change may take before it is reported as failed. Generous,
## because a heavy screen on a slow machine can take several frames; the 0.5.1
## check waited ONE frame and reported working screens as broken (R-020).
const LOAD_TIMEOUT_SEC := 3.0

var _stack: Array[String] = []
var payload: Dictionary = {}     # data handed to the next scene
var _pending_route := ""
var _pending_path := ""
var _pending_since := 0.0

signal route_changed(route: String)


func _ready() -> void:
	# One theme for the whole game, set on the root window so every Control --
	# including the ones nobody builds through UITheme -- inherits it.
	get_tree().root.theme = UITheme.build_theme()
	get_tree().scene_changed.connect(_on_scene_changed)
	set_process(false)


func go(route: String, data: Dictionary = {}) -> void:
	if not ROUTES.has(route):
		Log.error("SceneRouter: unknown route '%s'" % route)
		return
	payload = data
	# The main menu is the root: going there forgets the trail, so Back can
	# never walk into a finished game (0.16.6, R-083).
	if route == "main":
		_stack.clear()
	_stack.append(route)
	var path: String = ROUTES[route]
	var err := get_tree().change_scene_to_file(path)
	if err != OK:
		_show_load_failure(route, path, "change_scene_to_file returned error %d" % err)
		return
	# Verified by the engine's own scene_changed signal rather than by counting
	# frames. If the signal does not arrive within LOAD_TIMEOUT_SEC, the scene
	# genuinely failed -- almost always because its script did not compile.
	_pending_route = route
	_pending_path = path
	_pending_since = 0.0
	set_process(true)
	route_changed.emit(route)


func _on_scene_changed() -> void:
	_pending_route = ""
	set_process(false)


func _process(delta: float) -> void:
	if _pending_route == "":
		set_process(false)
		return
	_pending_since += delta
	if _pending_since < LOAD_TIMEOUT_SEC:
		return
	var route := _pending_route
	_pending_route = ""
	set_process(false)
	if get_tree().current_scene == null:
		_show_load_failure(route, _pending_path,
				"the scene did not appear within %.0f seconds, which almost always "
				% LOAD_TIMEOUT_SEC + "means its script failed to compile")


## Builds a failure screen in code -- deliberately, because it must not depend
## on any scene file or on MenuBase. If the reason the game is broken is that a
## screen will not compile, the screen that says so cannot be one of them.
func _show_load_failure(route: String, path: String, reason: String) -> void:
	push_error("SceneRouter: could not open '%s' (%s): %s" % [route, path, reason])
	Log.error("SceneRouter: could not open '%s': %s" % [route, reason])

	var screen := Control.new()
	screen.set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.color = Color("#140d12")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	screen.add_child(bg)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 60
	box.offset_right = -60
	box.offset_top = 60
	box.offset_bottom = -60
	box.add_theme_constant_override("separation", 14)
	screen.add_child(box)

	var title := Label.new()
	title.text = "Could not open: %s" % route
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color("#ff5a62"))
	box.add_child(title)

	var detail := Label.new()
	detail.text = "%s\n\n%s\n\nOpen the Output panel and read the FIRST error; everything after it is usually a knock-on effect." % [path, reason]
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(detail)

	var back_btn := Button.new()
	back_btn.text = "Back to the main menu"
	back_btn.custom_minimum_size = Vector2(260, 44)
	back_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	back_btn.pressed.connect(func(): go("main"))
	box.add_child(back_btn)

	var tree := get_tree()
	if tree.current_scene != null:
		tree.current_scene.queue_free()
	tree.root.add_child(screen)
	tree.current_scene = screen


## Routes Back never returns to: a game is over once you have left it, and
## the title screen is not a menu (0.16.6, R-083).
const NO_RETURN := ["game", "start"]


func back() -> void:
	if not _stack.is_empty():
		_stack.pop_back()                # the screen we are leaving
	while not _stack.is_empty() and NO_RETURN.has(_stack[-1]):
		_stack.pop_back()
	if _stack.is_empty():
		go("main")
		return
	var prev: String = _stack.pop_back()
	go(prev)


func current() -> String:
	return _stack[-1] if not _stack.is_empty() else ""
