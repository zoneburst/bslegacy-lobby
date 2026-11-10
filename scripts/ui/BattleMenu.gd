extends MenuBase
##
## The Battle hub: choose your deck on the left, a mode on the right, start.
##
## Until 0.6.0 this was four screens (Battle, Bot Match, Random Match, Room
## Match), each with its own deck picker and back button. It is now one, after
## the pattern the reference simulators use: your deck, then a mode, then start.
## The old route names "bot", "random" and "room" still work -- they open this
## screen on the matching tab.
##
## Only legal decks are offered. An unfinished deck can never be picked, which
## is the other half of the fix for R-021.
##

const MODES := [
	{"key": "ai",     "label": "VS AI",        "route": "bot",
		"blurb": "Offline, instant. Learn the game or test a deck."},
	{"key": "random", "label": "Quick Match",  "route": "random",
		"blurb": "The next player waiting on the online lobby."},
	{"key": "room",   "label": "Custom Room",  "route": "room",
		"blurb": "Play a friend: create a room, send the invite."},
]
const DIFFICULTY_BLURBS := [
	"Learning the game. Plays loosely and often misses the best move.",
	"Casual. Makes clear mistakes, never responds during flash windows.",
	"A fair game. Occasional misplays, responds to flash, keeps a blocker back.",
	"Rarely misplays. Plays the board carefully.",
	"Always takes the move it rates highest.",
]

var _deck_ids: Array[String] = []
var _deck_list: VBoxContainer
var _deck_detail: VBoxContainer
var _mode := "ai"
var _tab_buttons := {}
var _mode_body: VBoxContainer

# VS AI
var _difficulty := 2
var _diff_blurb: Label
var _opp_choice := 0       # 0 = random starter, 1 = mirror, 2+ = deck index
var _opp_option: OptionButton

# Quick match
var _searching := false
var _elapsed := 0.0
var _search_status: Label
var _search_button: Button

# Custom room
var _code_field: LineEdit
var _room_code: Label
var _members: VBoxContainer
var _spectator_check: CheckBox
var _local_check: CheckBox
var _route_label: Label
var _invite_label: Label
var _host_button: Button
var _stop_button: Button


func screen_title() -> String: return "Battle"
func screen_subtitle() -> String: return "Play"


func music_track() -> String:
	return "menu_theme"


func build_content(parent: VBoxContainer) -> void:
	_mode = _mode_from_route(SceneRouter.current())

	var split := UITheme.hbox(UITheme.SP_L)
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(split)

	split.add_child(_build_deck_column())
	split.add_child(_build_mode_column())

	Net.connection_changed.connect(_on_conn)
	Net.connection_failed.connect(func(r: String): _set_mode_status(
			"Could not connect: %s. Check the address, that your friend is hosting, that you both run version %s, and their firewall / router (UDP port)." % [
			r, str(ProjectSettings.get_setting("application/config/version", ""))], true))
	Net.lobby_message.connect(_on_lobby)
	Net.room_updated.connect(_on_room)
	Net.hosting_changed.connect(func(_h: bool): _refresh_host_ui())
	Net.router_changed.connect(func(_s: String): _refresh_host_ui())
	_refresh_decks()
	_show_mode(_mode)


func _mode_from_route(route: String) -> String:
	for m: Dictionary in MODES:
		if str(m["route"]) == route:
			return str(m["key"])
	return "ai"


# ============================================================================
# Left: your deck
# ============================================================================

func _build_deck_column() -> Control:
	var p := UITheme.panel(Vector2(420, 0))
	p.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var v := UITheme.vbox(UITheme.SP_M)
	p.add_child(v)

	var head := UITheme.hbox(UITheme.SP_S)
	var t := UITheme.vbox(0)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.add_child(UITheme.eyebrow("Step 1", UITheme.GOLD))
	t.add_child(UITheme.display_title("Your deck", UITheme.FS_HEAD))
	head.add_child(t)
	var edit := UITheme.ghost_button("Deck builder ›", func(): SceneRouter.go("deck_list"))
	edit.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(edit)
	v.add_child(head)

	_deck_detail = UITheme.vbox(UITheme.SP_S)
	v.add_child(_deck_detail)
	v.add_child(UITheme.rule())
	v.add_child(UITheme.eyebrow("Choose a deck"))

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(scroll)
	_deck_list = UITheme.vbox(UITheme.SP_XS)
	_deck_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_deck_list)
	return p


func _refresh_decks() -> void:
	for c in _deck_list.get_children():
		c.queue_free()
	_deck_ids.clear()
	var playable := DeckManager.visible_playable_decks()
	if playable.is_empty():
		_deck_list.add_child(UITheme.paragraph(
			"No playable decks yet. Open the deck builder to make one.", true))
	var current := _current_deck()
	for d in playable:
		var id := str(d["id"])
		_deck_ids.append(id)
		_deck_list.add_child(_deck_row(d, id == str(current.get("id", ""))))
	_show_deck_detail(current)
	if _opp_option != null:
		_fill_opponents()


## A deck in the picker: its colour gems, its name, and a gold frame when it
## is the deck you will take into battle.
func _deck_row(d: Dictionary, selected: bool) -> Control:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, 42)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	var colors := _deck_colors(d)
	b.text = ""
	b.tooltip_text = str(d.get("name", "Untitled"))
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", UITheme.FS_BODY - 1)
	if selected:
		var sb := UITheme._box(Color(UITheme.SURFACE_HI, 0.98), UITheme.RADIUS, UITheme.GOLD, 2)
		b.add_theme_stylebox_override("normal", sb)
		b.add_theme_stylebox_override("hover", sb)
	else:
		b.add_theme_stylebox_override("normal",
				UITheme._box(Color(UITheme.SURFACE, 0.6), UITheme.RADIUS, Color(UITheme.LINE, 0.9)))
		b.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	var id := str(d["id"])
	b.pressed.connect(func():
		AudioManager.play_sfx("ui_click")
		GameConfig.default_deck_id = id
		GameConfig.save_settings()
		_refresh_decks())
	Motion.press_feedback(b)
	# 0.16.6 (R-081): the colour gems and the name share one row laid out by
	# a container, so any number of colours pushes the name along. Before,
	# the name was padded with spaces and three gems ran into it.
	var inner := UITheme.hbox(UITheme.SP_XS)
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	inner.offset_left = 12
	inner.offset_right = -10
	for c in colors:
		var dot := UITheme.color_dot(int(c), 14)
		dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		inner.add_child(dot)
	if not colors.is_empty():
		inner.add_child(UITheme.spacer(2))
	var name_label := UITheme.truncating(str(d.get("name", "Untitled")), not selected, UITheme.FS_BODY - 1)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(name_label)
	b.add_child(inner)
	return b


func _show_deck_detail(d: Dictionary) -> void:
	for c in _deck_detail.get_children():
		c.queue_free()
	if d.is_empty():
		_deck_detail.add_child(UITheme.body("No deck selected", true))
		return
	var name_label := UITheme.truncating(str(d.get("name", "")), false, UITheme.FS_TITLE - 6)
	if UITheme.font("display") != null:
		name_label.add_theme_font_override("font", UITheme.font("display"))
	_deck_detail.add_child(name_label)
	var st: Dictionary = DeckManager.stats(d)
	var types: Dictionary = st.get("types", {})
	var row := UITheme.hbox(UITheme.SP_XS)
	for c in _deck_colors(d):
		row.add_child(UITheme.color_dot(int(c), 14))
	row.add_child(UITheme.spacer(0))
	row.add_child(UITheme.number("%d cards  ·  %d spirits  ·  %d nexus  ·  %d magic" % [
		(d.get("main", []) as Array).size(), int(types.get("spirit", 0)),
		int(types.get("nexus", 0)), int(types.get("magic", 0))], UITheme.FS_SMALL, UITheme.TEXT_DIM))
	_deck_detail.add_child(row)

	# A strip of the deck's top cards, so you can see what you are bringing.
	var strip := UITheme.hbox(6)
	strip.custom_minimum_size = Vector2(0, 112)
	var unique := {}
	for id in d.get("main", []):
		unique[str(id)] = true
	var ids: Array = unique.keys()
	ids.sort_custom(func(a, b):
		var ca: CardData = CardDB.get_card(str(a))
		var cb: CardData = CardDB.get_card(str(b))
		return (ca.cost if ca else 0) > (cb.cost if cb else 0))
	for id in ids.slice(0, 5):
		var w := CardWidget.new()
		w.setup(str(id), Vector2(72, 101))
		strip.add_child(w)
	_deck_detail.add_child(strip)


func _current_deck() -> Dictionary:
	var d := DeckManager.get_deck(GameConfig.default_deck_id)
	if not d.is_empty() and bool(DeckManager.validate(d).get("ok", false)):
		return d
	var playable := DeckManager.visible_playable_decks()
	if not playable.is_empty():
		GameConfig.default_deck_id = str(playable[0]["id"])
		return playable[0]
	return {}


func _deck_colors(deck: Dictionary) -> Array:
	var seen := {}
	for id in deck.get("main", []):
		var cd: CardData = CardDB.get_card(str(id))
		if cd != null:
			for c in cd.colors:
				seen[int(c)] = true
	var out: Array = seen.keys()
	out.sort()
	return out


# ============================================================================
# Right: mode
# ============================================================================

func _build_mode_column() -> Control:
	var p := UITheme.panel()
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var v := UITheme.vbox(UITheme.SP_M)
	p.add_child(v)

	v.add_child(UITheme.eyebrow("Step 2  ·  Mode", UITheme.GOLD))
	var tabs := UITheme.hbox(UITheme.SP_S)
	for m: Dictionary in MODES:
		var key := str(m["key"])
		var card := _mode_card(key, str(m["label"]), str(m["blurb"]))
		_tab_buttons[key] = card
		tabs.add_child(card)
	v.add_child(tabs)
	Motion.stagger_in(tabs.get_children())
	v.add_child(UITheme.rule())

	_mode_body = UITheme.vbox(UITheme.SP_M)
	_mode_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(_mode_body)
	return p


## A mode card: the name in the serif, a one-line blurb, a gold frame when
## it is the chosen mode.
func _mode_card(key: String, label: String, blurb: String) -> Control:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(0, 76)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	card.set_meta("off", UITheme._box(Color(UITheme.SURFACE, 0.75), UITheme.RADIUS, Color(UITheme.LINE, 1.0)))
	var on := UITheme._box(Color(UITheme.SURFACE_HI, 0.98), UITheme.RADIUS, UITheme.GOLD, 2)
	on.shadow_color = Color(UITheme.GOLD, 0.16)
	on.shadow_size = 12
	card.set_meta("on", on)
	card.set_meta("hover", UITheme._box(Color(UITheme.SURFACE_HI, 0.9), UITheme.RADIUS, Color(UITheme.GOLD, 0.6)))
	card.add_theme_stylebox_override("panel", card.get_meta("off"))
	var v := UITheme.vbox(2)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var t := UITheme.display_title(label, UITheme.FS_BODY + 1)
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(t)
	var b := UITheme.truncating(blurb, true, UITheme.FS_SMALL - 1)
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(b)
	card.add_child(v)
	card.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.is_pressed() \
				and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			AudioManager.play_sfx("ui_click")
			_show_mode(key))
	card.mouse_entered.connect(func():
		AudioManager.play_sfx("ui_hover")
		if _mode != key:
			card.add_theme_stylebox_override("panel", card.get_meta("hover")))
	card.mouse_exited.connect(func():
		if _mode != key:
			card.add_theme_stylebox_override("panel", card.get_meta("off")))
	Motion.hover_lift(card, 1.02)
	Motion.glint(card)
	return card


func _show_mode(key: String) -> void:
	_mode = key
	for k in _tab_buttons:
		var card: PanelContainer = _tab_buttons[k]
		card.add_theme_stylebox_override("panel", card.get_meta("on" if k == key else "off"))
	for c in _mode_body.get_children():
		c.queue_free()
	_opp_option = null
	_search_status = null
	if GameConfig.is_web() and key != "ai" and not GameConfig.has_online_lobby():
		_build_web_online_notice(_mode_body, key)   # a web build with no WebSocket lobby set (0.21.0)
		return
	match key:
		"ai": _build_ai(_mode_body)
		"random": _build_random(_mode_body)
		"room": _build_room(_mode_body)


## Web build with no WebSocket lobby in data/online_lobby.json: Quick Match
## and Custom Room need one (0.21.0; since 0.23.0 a lobby on Render works).
func _build_web_online_notice(v: VBoxContainer, key: String) -> void:
	v.add_child(UITheme.display_title("Quick Match" if key == "random" else "Custom Room", UITheme.FS_HEAD))
	v.add_child(UITheme.paragraph(
		"Online play is coming to the web version soon. For now, play VS AI here, "
		+ "or use the desktop version to play friends online.", true))
	v.add_child(UITheme.primary_button("Play VS AI", func(): _show_mode("ai")))


func _set_mode_status(text: String, error: bool = false) -> void:
	set_status(text, error)


# --- VS AI --------------------------------------------------------------------

func _build_ai(v: VBoxContainer) -> void:
	v.add_child(UITheme.display_title("Play against the AI", UITheme.FS_HEAD))
	v.add_child(UITheme.paragraph(
		"Offline, instant, and the best way to learn the game or test a deck.", true))

	v.add_child(UITheme.eyebrow("Difficulty"))
	var names: Array = []
	for n: Variant in BotController.DIFFICULTY_NAMES:
		names.append(str(n))
	var row := UITheme.segmented(names, _difficulty, func(idx: int):
		_difficulty = idx
		_diff_blurb.text = DIFFICULTY_BLURBS[idx], UITheme.CORE, 104.0)
	v.add_child(row)
	_diff_blurb = UITheme.paragraph(DIFFICULTY_BLURBS[_difficulty], true, UITheme.FS_SMALL)
	v.add_child(_diff_blurb)

	v.add_child(UITheme.spacer(4))
	v.add_child(UITheme.eyebrow("Opponent deck"))
	_opp_option = OptionButton.new()
	_opp_option.custom_minimum_size = Vector2(0, 42)
	_opp_option.item_selected.connect(func(i: int): _opp_choice = i)
	v.add_child(_opp_option)
	_fill_opponents()

	v.add_child(UITheme.grow())
	var start := UITheme.hero_button("Start match", _start_ai)
	start.custom_minimum_size = Vector2(0, 60)
	start.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(start)
	Motion.stagger_in(v.get_children())


func _fill_opponents() -> void:
	if _opp_option == null:
		return
	_opp_option.clear()
	_opp_option.add_item("Random starter deck")
	_opp_option.add_item("Mirror match (a copy of your deck)")
	for d in DeckManager.visible_playable_decks():
		_opp_option.add_item(str(d.get("name", "Untitled")))
	_opp_option.select(clampi(_opp_choice, 0, _opp_option.item_count - 1))


func _start_ai() -> void:
	var deck := _current_deck()
	if deck.is_empty():
		set_status("No legal deck. Build one in the deck builder first.", true)
		return
	var playable := DeckManager.visible_playable_decks()
	var opp := deck
	if _opp_choice == 0:
		var others := playable.filter(func(d): return str(d["id"]) != str(deck["id"]))
		if not others.is_empty():
			opp = others[randi() % others.size()]
	elif _opp_choice >= 2 and _opp_choice - 2 < playable.size():
		opp = playable[_opp_choice - 2]
	var res := MatchService.start_bot_match(deck, _difficulty, opp, true)
	if not bool(res.get("ok", false)):
		set_status(str(res.get("reason", "Could not start the match")), true)
		return
	MatchService.record_results = true      # a real game: goes on the profile (0.16.0)
	SceneRouter.go("game", {"mode": "bot"})


# --- Quick match --------------------------------------------------------------

func _build_random(v: VBoxContainer) -> void:
	v.add_child(UITheme.display_title("Quick Match", UITheme.FS_HEAD))
	v.add_child(UITheme.paragraph(
		"You will be paired with the next player waiting on the online lobby. To play a "
		+ "particular friend, use Custom Room instead.", true))
	v.add_child(UITheme.body(("Online lobby: %s" % GameConfig.lobby_label())
			if GameConfig.has_online_lobby() else "No online lobby is set up yet (Settings → Connection).",
			true, UITheme.FS_SMALL))
	_search_status = UITheme.body("Not searching", true)
	v.add_child(_search_status)
	v.add_child(UITheme.grow())
	var row := UITheme.hbox(UITheme.SP_S)
	_search_button = UITheme.hero_button("Find a match", _toggle_queue)
	_search_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search_button.custom_minimum_size = Vector2(0, 60)
	row.add_child(_search_button)
	var cfg := UITheme.button("Server settings", func(): SceneRouter.go("settings"))
	cfg.custom_minimum_size = Vector2(170, 60)
	cfg.visible = not GameConfig.is_web()        # no Connection settings in a browser (0.23.0)
	row.add_child(cfg)
	v.add_child(row)
	Motion.stagger_in(v.get_children())
	set_process(true)


func _process(delta: float) -> void:
	if not _searching or _search_status == null:
		return
	_elapsed += delta
	# floori(x / 60.0), not int(x) / 60: integer division is what Godot's
	# INTEGER_DIVISION warning flags, even where dropping the remainder is the
	# point (R-035).
	var secs := int(_elapsed)
	_search_status.text = "Searching…  %d:%02d" % [floori(secs / 60.0), secs % 60]


func _toggle_queue() -> void:
	if _searching:
		Net.cancel_queue()
		_searching = false
		_search_button.text = "Find a match"
		_search_status.text = "Search cancelled"
		return
	var deck := _current_deck()
	if deck.is_empty():
		set_status("No legal deck. Build one in the deck builder first.", true)
		return
	_searching = true
	_elapsed = 0.0
	_search_button.text = "Cancel search"
	if not Net.connected:
		if not GameConfig.has_online_lobby():
			_searching = false
			_search_button.text = "Find a match"
			_search_status.text = "Quick Match needs an online lobby (Settings → Connection)."
			return
		_search_status.text = "Connecting to %s… (a sleeping lobby takes up to a minute to wake)" % GameConfig.lobby_label()
		Net.connect_to_server(GameConfig.lobby_host, GameConfig.lobby_port)
		return   # the queue request is sent from _on_conn once connected
	MatchService.my_deck = deck             # recorded on the profile when it ends (0.16.0)
	Net.queue_random(deck)


# --- Custom room --------------------------------------------------------------

func _build_room(v: VBoxContainer) -> void:
	v.add_child(UITheme.display_title("Custom Room", UITheme.FS_HEAD))
	var online := GameConfig.has_online_lobby()
	v.add_child(UITheme.paragraph(
		("Create a room and send your friend the code. Rooms are made on the online lobby, "
		+ "so it works from any network.") if online else
		("Create a room and send your friend the invite. Your game hosts the room and asks your "
		+ "router to let your friend in (automatic on most home routers)."), true, UITheme.FS_SMALL))

	# --- 1 · Create ---
	var host := UITheme.panel(Vector2.ZERO, true)
	var hv := UITheme.vbox(UITheme.SP_S)
	host.add_child(hv)
	hv.add_child(UITheme.eyebrow("1 · Create a room"))
	var opts := UITheme.hbox(UITheme.SP_M)
	_spectator_check = CheckBox.new()
	_spectator_check.text = "Allow spectators"
	_spectator_check.button_pressed = true
	opts.add_child(_spectator_check)
	_local_check = CheckBox.new()
	_local_check.text = "Host on this computer"
	_local_check.tooltip_text = "Host the room here instead of on the online lobby (for a game on your home network)."
	_local_check.visible = online and not GameConfig.is_web()   # a browser cannot host (0.23.0)
	opts.add_child(_local_check)
	opts.add_child(UITheme.grow())
	_host_button = UITheme.primary_button("Create room", _create)
	opts.add_child(_host_button)
	_stop_button = UITheme.button("Close room", _stop_hosting)
	opts.add_child(_stop_button)
	hv.add_child(opts)
	var code_row := UITheme.hbox(UITheme.SP_S)
	code_row.add_child(UITheme.body("Room code:", true))
	_room_code = UITheme.number("------", UITheme.FS_HEAD, UITheme.GOLD_HI)
	code_row.add_child(_room_code)
	code_row.add_child(UITheme.grow())
	code_row.add_child(UITheme.button("Copy invite", _copy_invite))
	hv.add_child(code_row)
	_invite_label = UITheme.paragraph("", true, UITheme.FS_SMALL)
	hv.add_child(_invite_label)
	_route_label = UITheme.paragraph("", true, UITheme.FS_SMALL)
	hv.add_child(_route_label)
	v.add_child(host)

	# --- 2 · Join ---
	var join := UITheme.panel(Vector2.ZERO, true)
	var jv := UITheme.vbox(UITheme.SP_S)
	join.add_child(jv)
	jv.add_child(UITheme.eyebrow("2 · Join a friend's room"))
	var jrow := UITheme.hbox(UITheme.SP_S)
	_code_field = UITheme.line_edit("Paste the invite, or type the room code" if online
			else "Paste your friend's invite")
	_code_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_code_field.text_submitted.connect(func(_t: String): _join())
	jrow.add_child(_code_field)
	jrow.add_child(UITheme.primary_button("Join", _join))
	jrow.add_child(UITheme.button("Watch", _spectate))
	jv.add_child(jrow)
	v.add_child(join)

	_members = UITheme.vbox(2)
	v.add_child(_members)
	_refresh_host_ui()
	Motion.stagger_in(v.get_children())


## True when the room is on this computer rather than the online lobby.
func _hosting_here() -> bool:
	if GameConfig.is_web():
		return false                        # a browser cannot host a room (0.23.0)
	return not GameConfig.has_online_lobby() or (_local_check != null and _local_check.button_pressed)


func _refresh_host_ui() -> void:
	if _invite_label == null or not is_instance_valid(_invite_label):
		return
	var in_room := not Net.current_room_code.is_empty() and Net.connected
	_stop_button.visible = in_room or Net.is_hosting()
	_host_button.text = "New room" if in_room else "Create room"
	if not in_room:
		_room_code.text = "------"
		_invite_label.text = ""
		if Net.is_hosting():
			_route_label.text = "Starting the room…"
		elif GameConfig.has_online_lobby() and not _hosting_here():
			_route_label.text = "The room is made on the online lobby (%s). Your friend needs only the code." % GameConfig.lobby_label()
		else:
			_route_label.text = "Your game hosts the room on UDP port %d and asks your router to open it. The first time, allow the game through your firewall if asked." % GameConfig.host_port
		return
	_room_code.text = Net.current_room_code
	_invite_label.text = "Invite:  " + Net.invite_text()
	if not Net.is_hosting():
		_route_label.text = "✓ On the online lobby: your friend pastes the invite, or just types the code."
		return
	match Net.router_state:
		"working":
			_route_label.text = "Asking your router to open port %d…  Friends on your home network can already join." % Net.host_port
		"open":
			_route_label.text = "✓ Your router opened port %d: friends anywhere can join with the invite." % Net.host_port
		"shared":
			_route_label.text = "✗ %s Friends on your home network can still join.%s" % [Net.router_note,
					"" if GameConfig.has_online_lobby() else " To play anyone else, use an online lobby (see the Online guide)."]
		"failed":
			_route_label.text = "✗ %s Friends on your home network can still join. For others: turn on UPnP on the router, or see the Online guide." % Net.router_note
		_:
			_route_label.text = "Automatic router setup is off (Settings → Connection): friends on your home network can join."


func _copy_invite() -> void:
	if Net.current_room_code.is_empty():
		set_status("Create a room first", true)
		return
	DisplayServer.clipboard_set(Net.invite_text())
	set_status("Invite copied — paste it to your friend")


func _create() -> void:
	var deck := _current_deck()
	if deck.is_empty():
		set_status("No legal deck. Build one in the deck builder first.", true)
		return
	if _hosting_here():
		if not Net.is_hosting():
			var why := Net.host(GameConfig.host_port)
			if why != "":
				set_status("Could not create the room: " + why, true)
				_refresh_host_ui()
				return
	else:
		if not await _connect_to_lobby():
			return
	MatchService.my_deck = deck
	Net.create_room(deck, {"public": false, "allow_spectators": _spectator_check.button_pressed})
	_refresh_host_ui()


func _stop_hosting() -> void:
	if Net.is_hosting():
		Net.stop_hosting()
	else:
		Net.leave_room()
		Net.current_room_code = ""
	set_status("Room closed")
	_refresh_host_ui()


## Connect to the online lobby (once). Returns true when connected.
func _connect_to_lobby() -> bool:
	if not GameConfig.has_online_lobby():
		set_status("No online lobby is set up (Settings → Connection, or see the Online guide).", true)
		return false
	return await _connect_to([GameConfig.lobby_host, GameConfig.lobby_port], 8.0)   # Net waits longer for a wss:// lobby


## Connect to [host, port] unless already connected there.
func _connect_to(ap: Array, timeout: float) -> bool:
	var want := "%s:%d" % [ap[0], int(ap[1])]
	if Net.mode == Net.Mode.CLIENT and Net.connected and Net.target == want:
		return true
	set_status(("Connecting to the online lobby… (if it was asleep, this takes up to a minute)")
			if Net.is_ws_url(str(ap[0])) else "Connecting to %s…" % want)
	if not Net.connect_to_server(str(ap[0]), int(ap[1]), timeout):
		return false
	var up: bool = await Net.connection_changed
	return up and Net.connected


## Read the Join box: an invite (code + addresses) or a bare code.
## Connects, and returns the code, or "" (with the reason on the status line).
func _connect_for(text: String) -> String:
	var inv: Dictionary = Net.parse_invite(text, GameConfig.host_port)
	var code := str(inv["code"])
	var addrs: Array = inv["addresses"]
	if code == "":
		set_status("Paste the invite, or type the six-character room code", true)
		return ""
	if addrs.is_empty():
		if not GameConfig.has_online_lobby():
			set_status("That code needs the host's address: paste the whole invite (no online lobby is set up).", true)
			return ""
		return code if await _connect_to_lobby() else ""
	# An invite can hold two addresses (internet, and same network): try each.
	for i in addrs.size():
		var t := 4.0 if i < addrs.size() - 1 else 8.0
		if await _connect_to(addrs[i], t):
			return code
	return ""


func _join() -> void:
	var deck := _current_deck()
	if deck.is_empty():
		set_status("No legal deck. Build one in the deck builder first.", true)
		return
	var code := await _connect_for(_code_field.text)
	if code == "":
		return
	MatchService.my_deck = deck
	Net.join_room(code, deck)


func _spectate() -> void:
	var code := await _connect_for(_code_field.text)
	if code == "":
		return
	Net.spectate_room(code)


# --- Network callbacks ----------------------------------------------------------

func _on_conn(ok: bool) -> void:
	if ok and _searching:
		MatchService.my_deck = _current_deck()
		Net.queue_random(MatchService.my_deck)
	if not ok and _searching:
		_searching = false
		if _search_button != null:
			_search_button.text = "Find a match"
	if ok:
		set_status("Hosting on this computer" if Net.is_hosting() else "Connected to %s" % Net.target)
	elif Net.lobby_status == "Disconnected":
		set_status("Disconnected from %s" % Net.target, true)
	_refresh_host_ui()


func _on_lobby(kind_name: String, data: Dictionary) -> void:
	if kind_name != "lobby":
		return
	var err := bool(data.get("error", false))
	set_status(str(data.get("status", "")), err)
	if err and _searching:
		_searching = false
		if _search_button != null:
			_search_button.text = "Find a match"


func _on_room(data: Dictionary) -> void:
	if _room_code != null and is_instance_valid(_room_code):
		_room_code.text = str(data.get("code", "------"))
	_refresh_host_ui()
	if _members == null:
		return
	for c in _members.get_children():
		c.queue_free()
	_members.add_child(UITheme.eyebrow("In this room"))
	for m in data.get("members", []):
		_members.add_child(UITheme.body("%s  ·  %s" % [m.get("name", "?"), m.get("role", "?")]))
	if bool(data.get("in_progress", false)):
		set_status("Room %s · game in progress" % data.get("code", ""))
	elif (data.get("members", []) as Array).filter(func(m): return str(m.get("role", "")) == "player").size() >= 2:
		set_status("Room %s · both players are here" % data.get("code", ""))
	else:
		set_status("Room %s · waiting for an opponent" % data.get("code", ""))
