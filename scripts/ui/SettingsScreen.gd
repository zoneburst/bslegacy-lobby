extends MenuBase
##
## Settings. Everything writes straight through to GameConfig and saves on
## change; there is no Apply button, because a settings screen that can be
## abandoned in a half-applied state is a bug factory.
##
## 0.16.0: a left tab rail (Profile / Audio / Display / Gameplay / Connection
## / Assets / Imports) and one card per section on the right. Every section
## is built once, up front, and the rail only shows and hides them, so the
## import button, the drop-to-import handler and the remove buttons behave
## exactly as before.
##

const SECTIONS := [["profile", "Profile"], ["audio", "Audio"], ["display", "Display"],
		["gameplay", "Gameplay"], ["connection", "Connection"], ["assets", "Assets"],
		["imports", "Imports"]]

var _sections := {}        # key -> VBoxContainer (the card's content)
var _cards := {}           # key -> PanelContainer
var _rail := {}            # key -> Button
var _current := "profile"
var _host: VBoxContainer


func screen_title() -> String: return "Settings"
func screen_subtitle() -> String: return "Config"


func build_content(parent: VBoxContainer) -> void:
	var split := UITheme.hbox(UITheme.SP_M)
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(split)

	var rail := UITheme.vbox(4)
	rail.custom_minimum_size = Vector2(200, 0)
	split.add_child(rail)
	for entry: Array in SECTIONS:
		var key: String = entry[0]
		var b := UITheme.button(str(entry[1]), func(): _show_section(key))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(0, 42)
		b.toggle_mode = true
		_rail[key] = b
		rail.add_child(b)
		# web build (0.21.0): no lobby address or user-folder overrides in a browser
		# (spreadsheet import works there since 0.21.1, through WebFilePicker)
		if GameConfig.is_web() and key in ["connection", "assets"]:
			b.visible = false
	Motion.stagger_in(rail.get_children())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	split.add_child(scroll)
	_host = UITheme.vbox(16)
	_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_host)
	var v := _host

	# --- Profile ---
	var prof := _section(v, "Profile")
	var name_row: HBoxContainer = _text_row("Display name", GameConfig.player_name, func(t: String):
		GameConfig.player_name = t.substr(0, 24)
		GameConfig.save_settings())
	# Icon, record and play history live on the profile screen (0.16.0).
	var open_profile := UITheme.button("Profile", func(): SceneRouter.go("profile"))
	open_profile.custom_minimum_size = Vector2(120, 40)
	name_row.add_child(open_profile)
	prof.add_child(name_row)

	# --- Audio ---
	var audio := _section(v, "Audio")
	audio.add_child(_slider_row("Music volume", GameConfig.music_volume, func(val: float):
		GameConfig.music_volume = val
		GameConfig.save_settings()))
	audio.add_child(_slider_row("Sound effects", GameConfig.sfx_volume, func(val: float):
		GameConfig.sfx_volume = val
		GameConfig.save_settings()))
	audio.add_child(_check_row("Mute everything", GameConfig.mute, func(on: bool):
		GameConfig.mute = on
		GameConfig.save_settings()))

	# --- Display ---
	var disp := _section(v, "Display")
	disp.add_child(_check_row("Fullscreen", GameConfig.fullscreen, func(on):
		GameConfig.fullscreen = on
		GameConfig.save_settings()))
	disp.add_child(_check_row("Battle animations", GameConfig.battle_animations, func(on):
			GameConfig.battle_animations = on
			GameConfig.save_settings(),
		"Summon, attack, block, clash and damage presentations on the board."))
	disp.add_child(_slider_row("Animation speed", GameConfig.card_animation_speed,
		func(val):
			GameConfig.card_animation_speed = val
			GameConfig.save_settings(), 0.25, 2.5))
	disp.add_child(_option_row("Gate Open opening", ["Off", "On"],
		0 if GameConfig.gate_open == "off" else 1, func(i: int):
			GameConfig.gate_open = ["off", "isekai"][i]
			GameConfig.save_settings(),
		"\"Gate Open, Kaiho!\" before the first battle of a session, in your deck's colour "
		+ "(every colour of a split deck). Any click skips it. Off when Battle animations is off or Reduce motion is on."))
	disp.add_child(_check_row("Reduce motion", GameConfig.reduce_motion, func(on):
			GameConfig.reduce_motion = on
			GameConfig.save_settings()
			set_status("Menu motion reduced: takes effect on the next screen" if on
					else "Menu motion back on"),
		"Turns off the menus' breathing buttons, embers, parallax and card fans, and makes "
		+ "every other menu animation instant. Battle animations have their own switch."))
	disp.add_child(_check_row("Show card tooltips", GameConfig.show_card_tooltips, func(on):
		GameConfig.show_card_tooltips = on
		GameConfig.save_settings()))

	# --- Gameplay ---
	var game := _section(v, "Gameplay")
	# 0.23.0: the switch turns the AI-generated cards ON (they used to be on
	# unless hidden); off by default
	game.add_child(_check_row("Show AI-generated cards and the decks that use them",
		GameConfig.show_generated_cards, _on_show_generated,
		"The cards that come with the simulator were made by us (generated art and text). They are "
		+ "off unless you turn this on: only imported cards, and decks made of them, are shown. "
		+ "While no cards have been imported at all, the AI-generated cards stay in view so the game "
		+ "can still be played. Nothing is deleted."))
	game.add_child(_check_row(
		"Auto-pass flash windows when I have no legal response",
		GameConfig.auto_pass_empty_flash, func(on):
			GameConfig.auto_pass_empty_flash = on
			GameConfig.save_settings()))
	game.add_child(_check_row("Confirm before declaring an attack",
		GameConfig.confirm_attacks, func(on):
			GameConfig.confirm_attacks = on
			GameConfig.save_settings()))

	# --- Network (0.17.0) ---
	var net := _section(v, "Connection")
	net.add_child(UITheme.paragraph(
		"Online lobby: the server Custom Room and Quick Match use, so friends anywhere can play "
		+ "with just a room code. Leave it empty to host rooms on your own computer instead. "
		+ "Running a lobby: see the Online Play Guide.", true))
	var lobby_text := (GameConfig.lobby_host if Net.is_ws_url(GameConfig.lobby_host)
			else "%s:%d" % [GameConfig.lobby_host, GameConfig.lobby_port]) if GameConfig.has_online_lobby() else ""
	net.add_child(_text_row("Online lobby (address:port, or a wss:// address)", lobby_text, func(t):
		var ap: Array = Net.parse_address(str(t), 8910)
		GameConfig.lobby_host = str(ap[0])
		GameConfig.lobby_port = int(ap[1])
		GameConfig.save_settings()))
	net.add_child(_text_row("Port for hosting on this computer", str(GameConfig.host_port), func(t):
		if str(t).strip_edges().is_valid_int():
			GameConfig.host_port = int(t)
			GameConfig.save_settings()))
	var upnp := CheckBox.new()
	upnp.text = "Ask my router to open that port automatically (UPnP)"
	upnp.button_pressed = GameConfig.auto_router
	upnp.toggled.connect(func(on: bool):
		GameConfig.auto_router = on
		GameConfig.save_settings())
	net.add_child(upnp)
	net.add_child(UITheme.button("Test the online lobby", func():
		if not GameConfig.has_online_lobby():
			set_status("No online lobby is set", true)
			return
		set_status("Connecting to %s…" % GameConfig.lobby_label())
		if not Net.connect_to_server(GameConfig.lobby_host, GameConfig.lobby_port):
			return
		var up: bool = await Net.connection_changed
		if up:
			set_status("Connected to %s" % GameConfig.lobby_label())
		else:
			set_status("No lobby answered at %s" % GameConfig.lobby_label(), true)))
	net.add_child(UITheme.paragraph(
		"An always-on lobby runs without a screen on any computer or server:\n"
		+ "    <game> --headless -- --server --port 8910", true, UITheme.FS_SMALL))

	# --- Assets ---
	var assets := _section(v, "Assets")
	assets.add_child(UITheme.paragraph(
		"Override directories are checked before the packaged assets, so "
		+ "dropping files in replaces them without a rebuild. Full instructions "
		+ "are in docs/ASSET_REPLACEMENT_GUIDE.md.", true))
	assets.add_child(_text_row("Card art directory", GameConfig.card_art_override_dir, func(t):
		GameConfig.card_art_override_dir = t
		GameConfig.save_settings()
		CardDB.clear_art_cache()))
	assets.add_child(_text_row("Music directory", GameConfig.music_override_dir, func(t):
		GameConfig.music_override_dir = t
		GameConfig.save_settings()))
	assets.add_child(UITheme.button("Open user data folder", func():
		OS.shell_open(ProjectSettings.globalize_path("user://"))))
	assets.add_child(UITheme.button("Reload card database", func():
		CardDB.clear_art_cache()
		CardDB.load_all()
		set_status("Reloaded %d cards" % CardDB.count())))

	# --- Card import (0.12.0) ---
	var imp := _section(v, "Imports", "Import cards from a spreadsheet")
	if GameConfig.is_web():
		imp.add_child(UITheme.paragraph(
			"In the browser: choose your Excel workbook (.xlsx) below. The cards and their pictures are "
			+ "saved in this browser only, on this computer -- nothing is uploaded to the website. Import "
			+ "it again on another browser or device; clearing this site's data removes them.", true))
	imp.add_child(UITheme.paragraph(
		"Pick an Excel workbook (.xlsx) with a 'Card Code' and 'Card Name' column, or drop one on this "
		+ "window. A picture placed over a row becomes that card's image; 'Starter Deck' and 'Copies in "
		+ "Deck' columns build decks. Cards are matched to the rules the game already has. An imported "
		+ "card is added next to our own version of it; ours, and its art, stay in the game. Everything is written to your own "
		+ "user folder, never into the game. Full instructions are in the Card Import Manual.", true))
	_import_report = UITheme.paragraph("", false, UITheme.FS_SMALL)
	imp.add_child(UITheme.button("Import cards from spreadsheet...", func(): _open_import_dialog()))
	imp.add_child(_import_report)
	_import_list = UITheme.vbox(6)
	imp.add_child(_import_list)
	_refresh_imports()
	if not get_window().files_dropped.is_connected(_on_files_dropped):
		get_window().files_dropped.connect(_on_files_dropped)
	_show_section(_current)


func _show_section(key: String) -> void:
	_current = key
	for k: String in _cards:
		(_cards[k] as Control).visible = (k == key)
	for k: String in _rail:
		var b := _rail[k] as Button
		b.set_pressed_no_signal(k == key)
		b.add_theme_color_override("font_color", UITheme.GOLD_HI if k == key else UITheme.TEXT_DIM)
		b.add_theme_color_override("font_pressed_color", UITheme.GOLD_HI)
		b.add_theme_color_override("font_hover_pressed_color", UITheme.GOLD_HI)
	if _cards.has(key):
		Motion.stagger_in((_sections[key] as VBoxContainer).get_children())


var _import_report: Label
var _import_list: VBoxContainer


func _exit_tree() -> void:
	if get_window() != null and get_window().files_dropped.is_connected(_on_files_dropped):
		get_window().files_dropped.disconnect(_on_files_dropped)


func _open_import_dialog() -> void:
	if WebFilePicker.available():
		# 0.21.1: the browser's own "open file" window; the workbook is saved in
		# this browser's storage (user://incoming) and imported from there
		set_status("Choose your workbook…")
		WebFilePicker.pick(".xlsx", func(path: String, file_name: String) -> void:
			if file_name.is_empty():
				set_status("Import cancelled")
				return
			if path.is_empty():
				set_status("Could not read %s" % file_name, true)
				return
			set_status("Importing %s…" % file_name)
			_run_import(path), "Import cards from a spreadsheet (.xlsx)")
		return
	var dlg := FileDialog.new()
	dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dlg.access = FileDialog.ACCESS_FILESYSTEM
	dlg.use_native_dialog = true
	dlg.filters = PackedStringArray(["*.xlsx ; Excel workbook"])
	dlg.title = "Import cards from a spreadsheet"
	dlg.file_selected.connect(func(path: String):
		_run_import(path)
		dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	add_child(dlg)
	dlg.popup_centered_ratio(0.6)


func _on_files_dropped(files: PackedStringArray) -> void:
	for f in files:
		if f.get_extension().to_lower() == "xlsx":
			_run_import(f)
			return
	set_status("Drop an Excel workbook (.xlsx) to import cards.", true)


func _run_import(path: String) -> void:
	var rep := SheetImporter.import_xlsx(path)
	_import_report.text = SheetImporter.summary(rep)
	if bool(rep.get("ok", false)):
		set_status("Imported %d cards from %s" % [int(rep["imported"]), path.get_file()])
	else:
		set_status(str(rep.get("error", "Import failed")), true)
	_refresh_imports()


func _refresh_imports() -> void:
	if _import_list == null:
		return
	for c in _import_list.get_children():
		c.queue_free()
	for m: Dictionary in SheetImporter.imports():
		var row := UITheme.hbox(8)
		var lab := UITheme.body("%s  -  %d images, %d decks" % [m.get("sheet", m["tag"]),
				(m.get("images", []) as Array).size(), (m.get("decks", []) as Array).size()], true)
		lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(lab)
		var tag := str(m["tag"])
		row.add_child(UITheme.button("Remove", func():
			SheetImporter.remove(tag)
			_import_report.text = "Removed the cards imported from %s; our versions are back." % m.get("sheet", tag)
			set_status("Removed imported cards")
			_refresh_imports()))
		_import_list.add_child(row)


## One card per section. `title` is also the rail key unless `heading` is
## given (the Imports card has a longer heading than its tab).
func _on_show_generated(on: bool) -> void:
	GameConfig.show_generated_cards = on
	GameConfig.save_settings()
	DeckManager.decks_changed.emit()
	if on:
		set_status("AI-generated cards shown, with the decks that use them")
	elif GameConfig.real_cards_present:
		set_status("AI-generated cards off: only imported cards and their decks are shown")
	else:
		set_status("AI-generated cards off -- but no cards have been imported yet, so they stay in view until you import some")


func _section(parent: VBoxContainer, title: String, heading: String = "") -> VBoxContainer:
	var p := UITheme.panel()
	parent.add_child(p)
	var v := UITheme.vbox(10)
	p.add_child(v)
	v.add_child(UITheme.display_title(heading if heading != "" else title, UITheme.FS_HEAD))
	v.add_child(UITheme.gold_rule(120.0))
	v.add_child(UITheme.spacer(2))
	var key := title.to_lower()
	_sections[key] = v
	_cards[key] = p
	p.visible = false
	return v


func _text_row(label: String, value: String, on_change: Callable) -> HBoxContainer:
	var h := UITheme.hbox(10)
	h.custom_minimum_size = Vector2(0, 44)
	var l := UITheme.body(label)
	l.custom_minimum_size = Vector2(220, 0)
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(l)
	var e := UITheme.line_edit(label, value)
	e.custom_minimum_size = Vector2(320, 40)
	e.text_changed.connect(on_change)
	h.add_child(e)
	return h


## Label, a gold-filled slider with a gem thumb, and the live value.
func _slider_row(label: String, value: float, on_change: Callable,
		vmin: float = 0.0, vmax: float = 1.0) -> Control:
	var h := UITheme.hbox(10)
	h.custom_minimum_size = Vector2(0, 40)
	var l := UITheme.body(label)
	l.custom_minimum_size = Vector2(220, 0)
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(l)
	var s := HSlider.new()
	s.min_value = vmin
	s.max_value = vmax
	s.step = 0.05
	s.value = value
	s.custom_minimum_size = Vector2(280, 24)
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var readout := UITheme.number("%.2f" % value, UITheme.FS_BODY, UITheme.TEXT_DIM)
	readout.custom_minimum_size = Vector2(48, 0)
	readout.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.value_changed.connect(func(val):
		readout.text = "%.2f" % val
		on_change.call(val))
	h.add_child(s)
	h.add_child(readout)
	return h


## A toggle row: the label, a pill switch at the right, and an optional
## one-line description under it. The switch is a CheckButton; `toggled`
## reaches `on_change` exactly as the old CheckBox's did.
## A labelled dropdown (0.18.5).
func _option_row(label: String, options: Array, selected: int, on_change: Callable, description: String = "") -> Control:
	var v := UITheme.vbox(2)
	var row := UITheme.hbox(UITheme.SP_M)
	row.add_child(UITheme.body(label))
	row.add_child(UITheme.grow())
	var ob := OptionButton.new()
	for o in options:
		ob.add_item(str(o))
	ob.selected = selected
	ob.item_selected.connect(func(i: int): on_change.call(i))
	row.add_child(ob)
	v.add_child(row)
	if description != "":
		v.add_child(UITheme.paragraph(description, true, UITheme.FS_SMALL))
	return v


func _check_row(label: String, value: bool, on_change: Callable, description: String = "") -> Control:
	return UITheme.toggle_row(label, value, on_change, description)
