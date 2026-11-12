extends Control
##
## The hub. Five destinations, as specified in the project brief: Battle (as
## the one dominant PLAY), Deck, Config, Patch Notes, Report Bug -- name plate
## top left, the menu down the left, version bottom right, with the active
## deck showcased on the right in a gold case and a one-click route into a
## game against the AI. 0.16.0 restyled it after the "Gilded Ink" brief:
## soul-core PLAY, staggered entrance, embers, parallax, a hover-spread fan
## and a "What's new" line.
##
## Standalone rather than a MenuBase screen: it is a full-bleed art screen with
## no title bar or back button, and it is built from plain anchored Controls so
## the one screen a player cannot get past has no container stack to collapse
## (R-011).
##

const ITEMS := [
	{"label": "DECKS",       "route": "deck_list",
		"hint": "Build, edit, import and export decks."},
	{"label": "CONFIG",      "route": "settings",
		"hint": "Audio, display, gameplay and connection options."},
	{"label": "PATCH NOTES", "route": "patch_notes",
		"hint": "What changed, and what is known to be broken."},
	{"label": "REPORT BUG",  "route": "bug_report",
		"hint": "Send a report with logs and a replayable action log."},
]
const MENU_W := 360.0

var _hint: Label
var _fan: Control
var _fan_spread := 1.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	UITheme.apply_root(self, "", UITheme.BG_MENU, 0.10)
	var deck := _active_deck()
	var colors := _deck_colors(deck)
	if not colors.is_empty():
		UITheme.tint_background(self, UITheme.COLOR_SWATCH.get(int(colors[0]), UITheme.CORE))
	if has_meta("bg_rect"):
		Motion.parallax(get_meta("bg_rect"))
	Motion.embers(self, 18)
	_build_name_plate()
	_build_menu()
	_build_showcase(deck)
	_build_corners()
	Motion.enter_screen(self)
	AudioManager.play_music("menu_theme")


## The plate is the door to the profile (0.16.0): icon in a gold ring, name
## and record. A click opens the profile screen where the name and icon are
## edited.
func _build_name_plate() -> void:
	var plate := PanelContainer.new()
	plate.set_anchors_preset(Control.PRESET_TOP_LEFT)
	plate.position = Vector2(32, 24)
	plate.custom_minimum_size = Vector2(320, 64)
	var sb := UITheme._box(Color(UITheme.SURFACE, 0.88), 32, Color(UITheme.GOLD, 0.55))
	sb.shadow_color = Color(0, 0, 0, 0.5)
	sb.shadow_size = 12
	sb.content_margin_left = 6
	sb.content_margin_right = 22
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	plate.add_theme_stylebox_override("panel", sb)
	var hov := sb.duplicate() as StyleBoxFlat
	hov.border_color = UITheme.GOLD_HI
	plate.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	plate.tooltip_text = "Open your profile"
	plate.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.is_pressed() \
				and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			AudioManager.play_sfx("ui_click")
			SceneRouter.go("profile"))
	plate.mouse_entered.connect(func():
		AudioManager.play_sfx("ui_hover")
		plate.add_theme_stylebox_override("panel", hov))
	plate.mouse_exited.connect(func(): plate.add_theme_stylebox_override("panel", sb))
	Motion.glint(plate)
	add_child(plate)

	var row := UITheme.hbox(12)
	plate.add_child(row)

	var avatar := UITheme.gold_ring(ProfileScreen.icon_widget(48), 48)
	avatar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(avatar)

	var texts := UITheme.vbox(0)
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	texts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var name_label := UITheme.truncating(GameConfig.player_name, false, UITheme.FS_HEAD)
	if UITheme.font("bold") != null:
		name_label.add_theme_font_override("font", UITheme.font("bold"))
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	texts.add_child(name_label)
	var o := PlayerProfile.stats_overall()
	var record := UITheme.truncating("No matches yet · open profile" if int(o["games"]) == 0 else
			"%d-%d-%d · %s win rate" % [int(o["wins"]), int(o["losses"]), int(o["draws"]),
			PlayerProfile.pct(float(o["win_rate"]))], true, UITheme.FS_SMALL)
	record.mouse_filter = Control.MOUSE_FILTER_IGNORE
	texts.add_child(record)
	row.add_child(texts)


## Left column: one dominant PLAY, then the four secondary destinations,
## entering with a stagger. The hint line under them explains the hovered
## item.
func _build_menu() -> void:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	col.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	col.offset_left = 48
	col.offset_right = 48 + MENU_W
	col.offset_top = 150
	col.offset_bottom = -110
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(col)

	var play := UITheme.hero_button("Play", func(): SceneRouter.go("battle_menu"), 26)
	play.custom_minimum_size = Vector2(MENU_W, 72)
	play.mouse_entered.connect(func(): _show_hint("Play the AI, find an opponent, or host a room."))
	Motion.glint(play, Color(1, 1, 1, 1))
	col.add_child(play)
	col.add_child(UITheme.spacer(6))

	for item: Dictionary in ITEMS:
		col.add_child(_menu_item(str(item["label"]), str(item["route"]), str(item["hint"])))

	col.add_child(UITheme.spacer(2))
	_hint = UITheme.body("", true, UITheme.FS_SMALL + 1)
	_hint.custom_minimum_size = Vector2(0, 24)
	col.add_child(_hint)
	Motion.stagger_in(col.get_children())


func _show_hint(text: String) -> void:
	if _hint != null:
		_hint.text = text
		_hint.add_theme_color_override("font_color", UITheme.TEXT_DIM)


## A secondary button: serif label, left-aligned, a gold rim that brightens
## on hover with a glint.
func _menu_item(label: String, route: String, hint: String) -> Control:
	var b := UITheme.button(label, func(): SceneRouter.go(route))
	b.custom_minimum_size = Vector2(MENU_W, 52)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.add_theme_font_size_override("font_size", UITheme.FS_BODY + 1)
	var f := UITheme.title_font(UITheme.FS_BODY + 1)
	if f != null:
		b.add_theme_font_override("font", f)
	var sb := UITheme._box(Color(UITheme.SURFACE, 0.82), UITheme.RADIUS, Color(UITheme.GOLD, 0.5))
	sb.content_margin_left = 22
	b.add_theme_stylebox_override("normal", sb)
	var hov := UITheme._box(Color(UITheme.SURFACE_HI, 0.95), UITheme.RADIUS, UITheme.GOLD_HI)
	hov.content_margin_left = 22
	b.add_theme_stylebox_override("hover", hov)
	b.mouse_entered.connect(func(): _show_hint(hint))
	b.focus_entered.connect(func(): _show_hint(hint))
	Motion.glint(b)
	return b


## Right side: the active deck as a fan of cards in a gold-framed case, and
## the quickest path into a game.
func _build_showcase(deck: Dictionary) -> void:
	var panel := UITheme.hero_panel()
	panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	panel.offset_left = -600
	panel.offset_right = -48
	panel.offset_top = 120
	panel.offset_bottom = -126
	add_child(panel)

	var v := UITheme.vbox(UITheme.SP_S)
	panel.add_child(v)
	var head := UITheme.hbox(UITheme.SP_S)
	var titles := UITheme.vbox(0)
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.add_child(UITheme.eyebrow("Your active deck", UITheme.GOLD))
	var name_label := UITheme.truncating(str(deck.get("name", "No deck yet")), false, UITheme.FS_TITLE - 4)
	if UITheme.font("display") != null:
		name_label.add_theme_font_override("font", UITheme.font("display"))
	titles.add_child(name_label)
	head.add_child(titles)
	var stats := UITheme.vbox(2)
	stats.alignment = BoxContainer.ALIGNMENT_END
	var colors_row := UITheme.hbox(UITheme.SP_XS)
	colors_row.alignment = BoxContainer.ALIGNMENT_END
	for c in _deck_colors(deck):
		colors_row.add_child(UITheme.color_dot(int(c), 16))
	stats.add_child(colors_row)
	var main: Array = deck.get("main", [])
	var win_text := ""
	for r: Dictionary in PlayerProfile.stats_by_deck():
		if str(r.get("name", "")) == str(deck.get("name", "")) and int(r.get("games", 0)) > 0:
			win_text = "  ·  %s wins" % PlayerProfile.pct(float(r["win_rate"]))
	var count := UITheme.number("%d cards%s" % [main.size(), win_text], UITheme.FS_SMALL, UITheme.TEXT_DIM)
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	stats.add_child(count)
	head.add_child(stats)
	v.add_child(head)

	# The fan lives in a plain Control, so each card's position and rotation
	# are ours -- no container is laying them out. Hovering it spreads the
	# fan (animation 11).
	_fan = Control.new()
	_fan.custom_minimum_size = Vector2(0, 230)
	_fan.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_fan.mouse_filter = Control.MOUSE_FILTER_PASS
	v.add_child(_fan)
	var picks := _showcase_cards(deck, 5)
	_fan.resized.connect(func(): _layout_fan(_fan))
	for id: String in picks:
		var w := CardWidget.new()
		w.setup(id, Vector2(132, 185))
		w.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_fan.add_child(w)
	if picks.is_empty():
		var empty := UITheme.paragraph("No playable deck yet. Open Decks to build one, "
				+ "or import a list.", true)
		empty.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
		empty.offset_left = -200
		empty.offset_right = 200
		empty.offset_top = 60
		empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_fan.add_child(empty)
	_fan.mouse_entered.connect(func(): _spread_fan(1.5))
	_fan.mouse_exited.connect(func(): _spread_fan(1.0))
	_layout_fan.call_deferred(_fan)

	var actions := UITheme.hbox(UITheme.SP_S)
	var quick := UITheme.primary_button("Quick Play vs AI", _quick_play)
	quick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	quick.custom_minimum_size = Vector2(0, 48)
	actions.add_child(quick)
	var edit := UITheme.button("Edit deck", func():
		SceneRouter.go("deck_editor", {"deck_id": str(deck.get("id", ""))}))
	edit.custom_minimum_size = Vector2(130, 48)
	edit.disabled = deck.is_empty()
	actions.add_child(edit)
	# 0.24.0: pick another deck here, before Quick Play, without going
	# through the Battle screen
	var change := UITheme.button("Change deck", _pick_deck)
	change.custom_minimum_size = Vector2(150, 48)
	change.disabled = DeckManager.visible_playable_decks().size() < 2 and not deck.is_empty()
	change.tooltip_text = "Choose which of your decks Quick Play uses"
	actions.add_child(change)
	v.add_child(actions)

	# "What's new": the latest release, one line, linking to the full notes.
	var latest := _latest_release()
	if not latest.is_empty():
		var news := UITheme.hbox(UITheme.SP_S)
		news.alignment = BoxContainer.ALIGNMENT_CENTER
		var dot := UITheme.Dot.new()
		dot.color = UITheme.CORE
		dot.custom_minimum_size = Vector2(10, 10)
		dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		news.add_child(dot)
		var headline := str(latest.get("codename", ""))
		if headline == "":
			var added: Array = latest.get("added", [])
			headline = str(added[0]) if not added.is_empty() else ""
		var line := UITheme.truncating("What's new in v%s%s" % [str(latest.get("version", "")),
				("  ·  " + headline) if headline != "" else ""], true, UITheme.FS_SMALL)
		line.custom_minimum_size = Vector2(200, 0)
		news.add_child(line)
		var open := UITheme.ghost_button("Patch notes ›", func(): SceneRouter.go("patch_notes"))
		open.add_theme_font_size_override("font_size", UITheme.FS_SMALL)
		open.custom_minimum_size = Vector2(0, 30)
		news.add_child(open)
		v.add_child(news)


func _spread_fan(to: float) -> void:
	if _fan == null or not Motion.enabled():
		_fan_spread = to
		_layout_fan(_fan)
		return
	var tw := create_tween()
	tw.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_method(func(v: float):
		_fan_spread = v
		_layout_fan(_fan), _fan_spread, to, 0.2)


func _layout_fan(fan: Control) -> void:
	var n := 0
	for c in fan.get_children():
		if c is CardWidget:
			n += 1
	if n == 0:
		return
	var card := Vector2(132, 185)
	var centre := Vector2(fan.size.x * 0.5, fan.size.y * 0.46)
	var i := 0
	for w in fan.get_children():
		if not (w is CardWidget):
			continue
		var t := (float(i) - float(n - 1) * 0.5)
		w.size = card
		w.pivot_offset = Vector2(card.x * 0.5, card.y)
		w.rotation = deg_to_rad(t * 7.0 * _fan_spread)
		w.position = centre - card * 0.5 + Vector2(t * 78.0 * _fan_spread,
				absf(t) * 10.0 * _fan_spread - (6.0 * (_fan_spread - 1.0) if absf(t) < 0.1 else 0.0))
		i += 1


func _latest_release() -> Dictionary:
	var f := FileAccess.open("res://data/patch_notes.json", FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var releases: Array = parsed.get("releases", [])
	return releases[0] if not releases.is_empty() else {}


func _build_corners() -> void:
	var ver := UITheme.display_title("Ver %s" %
			ProjectSettings.get_setting("application/config/version", "0.0.0"), 18, UITheme.TEXT_DIM)
	ver.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	ver.add_theme_constant_override("outline_size", 5)
	ver.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	ver.offset_left = -260
	ver.offset_top = -54
	ver.offset_right = -36
	ver.offset_bottom = -24
	ver.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(ver)

	var status := UITheme.body("%d cards  ·  %d decks  ·  %s" % [
		CardDB.count(), DeckManager.decks.size(),
		"online" if Net.connected else "offline"], true, UITheme.FS_SMALL)
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	status.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	status.offset_left = -500
	status.offset_top = -80
	status.offset_right = -36
	status.offset_bottom = -56
	add_child(status)

	var quit := UITheme.ghost_button("QUIT", func(): get_tree().quit())
	quit.visible = not GameConfig.is_web()    # a browser tab is closed, not quit (0.21.0)
	quit.add_theme_font_size_override("font_size", UITheme.FS_SMALL)
	quit.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	quit.offset_left = 40
	quit.offset_top = -66
	quit.offset_right = 130
	quit.offset_bottom = -26
	add_child(quit)

	if OS.is_debug_build():
		var dbg := Label.new()
		dbg.text = "MainMenu · %d cards · %s" % [CardDB.count(), get_viewport_rect().size]
		dbg.add_theme_font_size_override("font_size", 10)
		dbg.add_theme_color_override("font_color", Color(1, 1, 1, 0.35))
		dbg.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
		dbg.position = Vector2(4, -14)
		dbg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(dbg)


# --- Data -------------------------------------------------------------------

## The chosen deck if it can be played, otherwise the first deck that can.
## An unfinished or empty deck is never shown as "active".
func _active_deck() -> Dictionary:
	return DeckManager.active_deck()


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


## The highest-cost spirits make the best-looking fan.
func _showcase_cards(deck: Dictionary, n: int) -> Array[String]:
	var unique := {}
	for id in deck.get("main", []):
		unique[str(id)] = true
	var ids: Array = unique.keys()
	ids.sort_custom(func(a, b):
		var ca: CardData = CardDB.get_card(str(a))
		var cb: CardData = CardDB.get_card(str(b))
		var sa := (ca.cost + (10 if ca.is_spirit() else 0)) if ca != null else 0
		var sb := (cb.cost + (10 if cb.is_spirit() else 0)) if cb != null else 0
		return sa > sb)
	var out: Array[String] = []
	for id in ids.slice(0, n):
		out.append(str(id))
	return out


## The deck picker (0.24.0): every playable deck with its colours and size;
## the one chosen becomes the active deck everywhere (Quick Play, Battle).
func _pick_deck() -> void:
	var m := Modal.open(self, "Choose your active deck", 560.0)
	var current := str(_active_deck().get("id", ""))
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, 360)
	m.body.add_child(scroll)
	var list := UITheme.vbox(UITheme.SP_XS)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	var decks := DeckManager.visible_playable_decks()
	if decks.is_empty():
		list.add_child(UITheme.paragraph("No playable decks yet. Open Decks to build one, or import a list.", true))
	for d: Dictionary in decks:
		list.add_child(_deck_choice(d, str(d.get("id", "")) == current, m))
	m.buttons.add_child(UITheme.ghost_button("Deck builder ›", func():
		m.close()
		SceneRouter.go("deck_list")))
	m.buttons.add_child(UITheme.grow())
	m.buttons.add_child(UITheme.button("Cancel", m.close))


func _deck_choice(d: Dictionary, selected: bool, m: Modal) -> Control:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, 46)
	b.focus_mode = Control.FOCUS_NONE
	b.tooltip_text = str(d.get("name", "Untitled"))
	var sb := UITheme._box(Color(UITheme.SURFACE_HI, 0.98), UITheme.RADIUS, UITheme.GOLD, 2) if selected \
			else UITheme._box(Color(UITheme.SURFACE, 0.6), UITheme.RADIUS, Color(UITheme.LINE, 0.9))
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_stylebox_override("hover", UITheme._box(Color(UITheme.SURFACE_HI, 0.98), UITheme.RADIUS, UITheme.GOLD_HI, 2))
	var id := str(d.get("id", ""))
	b.pressed.connect(func():
		AudioManager.play_sfx("ui_click")
		GameConfig.default_deck_id = id
		GameConfig.save_settings()
		m.close()
		SceneRouter.go("main"))
	var row := UITheme.hbox(UITheme.SP_XS)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 12
	row.offset_right = -12
	for c in _deck_colors(d):
		var dot := UITheme.color_dot(int(c), 14)
		dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(dot)
	row.add_child(UITheme.spacer(4))
	var nm := UITheme.truncating(str(d.get("name", "Untitled")), not selected, UITheme.FS_BODY)
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nm.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(nm)
	var info := UITheme.number("%d cards%s" % [(d.get("main", []) as Array).size(),
			"  ·  active" if selected else ""], UITheme.FS_SMALL, UITheme.GOLD if selected else UITheme.TEXT_DIM)
	info.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(info)
	b.add_child(row)
	return b


## One click from the hub into a game: your active deck against a different
## starter deck at Normal difficulty.
func _quick_play() -> void:
	var deck := _active_deck()
	if deck.is_empty():
		SceneRouter.go("deck_list")
		return
	var opp := deck
	for d in DeckManager.visible_playable_decks():
		if str(d.get("id", "")) != str(deck.get("id", "")):
			opp = d
			break
	var res := MatchService.start_bot_match(deck, 2, opp, true)
	if bool(res.get("ok", false)):
		MatchService.record_results = true  # a real game: goes on the profile (0.16.0)
		SceneRouter.go("game", {"mode": "bot"})
	elif _hint != null:
		_hint.text = str(res.get("reason", "Could not start"))
		_hint.add_theme_color_override("font_color", UITheme.DANGER)
