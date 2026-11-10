extends Control
##
## Title screen: logo, a pulsing "click to start", and the card database
## warming up in the background.
##
## 0.16.0: the shared ink background with drifting embers and a gentle mouse
## parallax, the wordmark in the serif title face over a gold rule, and the
## prompt pulsing through Motion (reduce motion: everything still).
##
## Built on anchors only (no nested containers), and the UI is created before
## anything that can fail at runtime -- audio last -- so a fault elsewhere can
## never leave this, the first screen, blank (R-010).
##

var _prompt: Label
var _ready_to_go := false


func _ready() -> void:
	# A headless server instance has no UI at all; Boot takes over the process.
	var boot := load("res://scripts/Boot.gd")
	if boot != null and boot.maybe_run_server(get_tree()):
		queue_free()
		return
	UITheme.apply_root(self, "", UITheme.BG_MENU, 0.15)
	if has_meta("bg_rect"):
		var bg: ColorRect = get_meta("bg_rect")
		if bg.material is ShaderMaterial:
			(bg.material as ShaderMaterial).set_shader_parameter("lattice", 0.03)
		Motion.parallax(bg)
	Motion.embers(self)

	# A fan of three card backs behind the logo, tinted in three of the six
	# colours: quiet, and it says "cards" before the logo does.
	var fan := Control.new()
	fan.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fan.set_anchors_preset(Control.PRESET_CENTER)
	fan.offset_left = -200
	fan.offset_right = 200
	fan.offset_top = -300
	fan.offset_bottom = 60
	add_child(fan)
	var tints := [BSS.CardColor.RED, BSS.CardColor.BLUE, BSS.CardColor.GREEN]
	for i in 3:
		var w := CardWidget.new()
		w.setup_back(Vector2(150, 210))
		w.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var t := float(i) - 1.0
		w.pivot_offset = Vector2(75, 210)
		w.position = Vector2(200 - 75 + t * 26.0, 70.0 + absf(t) * 6.0)
		w.rotation = deg_to_rad(t * 14.0)
		var tint: Color = UITheme.COLOR_SWATCH[tints[i]]
		w.modulate = Color(tint.lerp(Color.WHITE, 0.5), 0.28)
		fan.add_child(w)

	# Logo, centred, slightly above the middle.
	var logo := TextureRect.new()
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	logo.set_anchors_preset(Control.PRESET_CENTER)
	logo.offset_left = -300
	logo.offset_right = 300
	logo.offset_top = -250
	logo.offset_bottom = 10
	if ResourceLoader.exists("res://assets/ui/logo.png"):
		logo.texture = load("res://assets/ui/logo.png")
	add_child(logo)

	var title := UITheme.display_title("Battle Spirits Saga", 46)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	title.add_theme_constant_override("outline_size", 8)
	title.set_anchors_preset(Control.PRESET_CENTER)
	title.offset_left = -500
	title.offset_right = 500
	title.offset_top = 20
	title.offset_bottom = 80
	add_child(title)

	var rule := UITheme.gold_rule(360.0)
	rule.set_anchors_preset(Control.PRESET_CENTER)
	rule.offset_left = -180
	rule.offset_right = 180
	rule.offset_top = 88
	rule.offset_bottom = 90
	add_child(rule)

	var sub := UITheme.eyebrow("S I M U L A T O R", UITheme.TEXT_DIM)
	sub.add_theme_font_size_override("font_size", 14)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.set_anchors_preset(Control.PRESET_CENTER)
	sub.offset_left = -300
	sub.offset_right = 300
	sub.offset_top = 98
	sub.offset_bottom = 122
	add_child(sub)

	_prompt = UITheme.display_title("Loading card database…", UITheme.FS_BODY + 1, UITheme.TEXT)
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_prompt.add_theme_constant_override("outline_size", 6)
	_prompt.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_prompt.offset_left = -400
	_prompt.offset_right = 400
	_prompt.offset_top = -170
	_prompt.offset_bottom = -136
	add_child(_prompt)

	var quit := UITheme.ghost_button("QUIT", func(): get_tree().quit())
	quit.visible = not GameConfig.is_web()    # a browser tab is closed, not quit (0.21.0)
	quit.add_theme_font_size_override("font_size", UITheme.FS_SMALL)
	quit.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	quit.offset_left = 24
	quit.offset_right = 112
	quit.offset_top = -62
	quit.offset_bottom = -24
	add_child(quit)

	var version := UITheme.body("v%s  ·  unofficial fan simulator" %
			ProjectSettings.get_setting("application/config/version", "0.0.0"),
			true, UITheme.FS_SMALL)
	version.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	version.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	version.offset_left = -420
	version.offset_right = -28
	version.offset_top = -50
	version.offset_bottom = -26
	add_child(version)
	Motion.enter_screen(self)

	# Audio last, deliberately.
	AudioManager.play_music("title_theme")

	if CardDB.count() > 0:
		_on_db_loaded(CardDB.count())
	else:
		CardDB.database_loaded.connect(_on_db_loaded)


func _on_db_loaded(count: int) -> void:
	_ready_to_go = true
	if count == 0:
		_prompt.text = "No cards found. See README.md, then restart."
		_prompt.add_theme_color_override("font_color", UITheme.DANGER)
	else:
		_prompt.text = "Click anywhere to start"
		Motion.pulse(_prompt)


func _gui_input(event: InputEvent) -> void:
	if _ready_to_go and event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		_enter_game()


func _unhandled_input(event: InputEvent) -> void:
	if not _ready_to_go:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode in [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]:
			_enter_game()


func _enter_game() -> void:
	_ready_to_go = false
	SceneRouter.go("main")
