extends MenuBase
class_name ProfileScreen
##
## The player profile (0.16.0): who you are on the left, what your games say
## on the right. Identity card: circular icon (card art or an uploaded
## picture), editable display name, record line, member-since, favourite
## deck. Right side: one of three pages -- the record by deck, the strengths
## and weaknesses read off the match history, and the last ten matches.
##
## Everything is read from PlayerProfile; nothing here computes a statistic.
##

const ICON_PX := 140
const LEFT_W := 332.0
const PAGE_CARDS := 16         # thumbnails per page in the icon picker
const PICK_COLS := 8

var _page := "decks"
var _page_host: ScrollContainer
var _page_buttons := {}
var _icon_holder: Control
var _name_edit: LineEdit
var _title_line: Label
var _fav_line: HBoxContainer
var _glance: VBoxContainer

# icon picker state
var _pick_query := ""
var _pick_page := 0
var _pick_grid: GridContainer
var _pick_status: Label


func screen_title() -> String: return "Profile"
func screen_subtitle() -> String: return "Player"


func build_content(parent: VBoxContainer) -> void:
	var row := UITheme.hbox(UITheme.SP_M)
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(row)

	row.add_child(_build_identity())

	var right := UITheme.vbox(UITheme.SP_S)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_child(right)

	var tabs := UITheme.hbox(UITheme.SP_S)
	var group := ButtonGroup.new()
	for entry: Array in [["decks", "Record by deck"], ["insights", "Strengths & weaknesses"],
			["recent", "Recent matches"]]:
		var key: String = entry[0]
		var chip := UITheme.chip(str(entry[1]), UITheme.GOLD)
		chip.button_group = group
		chip.custom_minimum_size = Vector2(0, 36)
		chip.add_theme_font_size_override("font_size", UITheme.FS_SMALL + 1)
		chip.pressed.connect(func(): _show_page(key))
		tabs.add_child(chip)
		_page_buttons[key] = chip
	tabs.add_child(UITheme.grow())
	var games := PlayerProfile.games()
	var count := UITheme.number("%d match%s on record" % [games, "" if games == 1 else "es"],
			UITheme.FS_SMALL, UITheme.TEXT_DIM)
	count.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tabs.add_child(count)
	right.add_child(tabs)

	var panel := UITheme.panel()
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(panel)
	_page_host = ScrollContainer.new()
	_page_host.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_page_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(_page_host)

	_show_page(_page)
	if not PlayerProfile.changed.is_connected(_on_profile_changed):
		PlayerProfile.changed.connect(_on_profile_changed)


func _exit_tree() -> void:
	if PlayerProfile.changed.is_connected(_on_profile_changed):
		PlayerProfile.changed.disconnect(_on_profile_changed)


func _on_profile_changed() -> void:
	_refresh_identity()
	_show_page(_page)


# ---------------------------------------------------------------------------
# Identity card
# ---------------------------------------------------------------------------

func _build_identity() -> Control:
	# The identity card is the one hero panel on the screen: gold frame,
	# corner brackets, the icon in a gold ring (0.16.0).
	var card := UITheme.hero_panel(Vector2(LEFT_W, 0))
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var v := UITheme.vbox(UITheme.SP_S)
	v.alignment = BoxContainer.ALIGNMENT_BEGIN
	card.add_child(v)

	_icon_holder = CenterContainer.new()
	_icon_holder.custom_minimum_size = Vector2(0, ICON_PX + 12)
	v.add_child(_icon_holder)

	var change := UITheme.ghost_button("Change icon", _open_icon_picker)
	change.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	change.custom_minimum_size = Vector2(150, 34)
	change.add_theme_font_size_override("font_size", UITheme.FS_SMALL)
	v.add_child(change)

	v.add_child(UITheme.spacer(2))
	v.add_child(UITheme.eyebrow("Display name"))
	_name_edit = UITheme.line_edit("Your name", PlayerProfile.display_name())
	_name_edit.max_length = 24
	_name_edit.text_submitted.connect(func(t: String):
		PlayerProfile.set_display_name(t)
		_name_edit.release_focus())
	_name_edit.focus_exited.connect(func(): PlayerProfile.set_display_name(_name_edit.text))
	v.add_child(_name_edit)

	_title_line = UITheme.number("", UITheme.FS_BODY, UITheme.TEXT)
	v.add_child(_title_line)

	_fav_line = UITheme.hbox(UITheme.SP_S)
	v.add_child(_fav_line)

	v.add_child(UITheme.spacer(6))
	v.add_child(UITheme.eyebrow("At a glance", UITheme.GOLD))
	v.add_child(UITheme.gold_rule(90.0))
	_glance = UITheme.vbox(UITheme.SP_XS)
	v.add_child(_glance)

	v.add_child(UITheme.grow())
	v.add_child(UITheme.rule())
	v.add_child(UITheme.body("Member since %s" % PlayerProfile.member_since(), true, UITheme.FS_SMALL))
	_refresh_identity()
	return card


func _refresh_identity() -> void:
	if _icon_holder == null:
		return
	for c in _icon_holder.get_children():
		_icon_holder.remove_child(c)
		c.queue_free()
	_icon_holder.add_child(UITheme.gold_ring(icon_widget(ICON_PX), ICON_PX, 2.5))

	if _name_edit != null and not _name_edit.has_focus():
		_name_edit.text = PlayerProfile.display_name()

	var o := PlayerProfile.stats_overall()
	var g := int(o["games"])
	if g == 0:
		_title_line.text = "No matches yet"
	else:
		_title_line.text = "%d win%s · %s win rate · %d-%d-%d" % [int(o["wins"]),
				"" if int(o["wins"]) == 1 else "s", PlayerProfile.pct(float(o["win_rate"])),
				int(o["wins"]), int(o["losses"]), int(o["draws"])]

	for c in _fav_line.get_children():
		_fav_line.remove_child(c)
		c.queue_free()
	_refresh_glance(o)
	var fav := PlayerProfile.favourite_deck()
	if fav.is_empty():
		var hint := UITheme.body("Play a match to start your record.", true, UITheme.FS_SMALL)
		_fav_line.add_child(hint)
		return
	_fav_line.add_child(UITheme.body("Favourite", true, UITheme.FS_SMALL))
	for c: Variant in fav.get("colours", []):
		_fav_line.add_child(UITheme.color_dot(int(c), 12))
	var nm := UITheme.truncating(str(fav["name"]), false, UITheme.FS_SMALL)
	_fav_line.add_child(nm)
	var streak := int(o["streak"])
	if absi(streak) >= 2:
		_fav_line.add_child(UITheme.pill("%s%d" % ["W" if streak > 0 else "L", absi(streak)],
				UITheme.SUCCESS if streak > 0 else UITheme.DANGER))


func _refresh_glance(o: Dictionary) -> void:
	for c in _glance.get_children():
		_glance.remove_child(c)
		c.queue_free()
	var g := int(o["games"])
	if g == 0:
		_glance.add_child(UITheme.paragraph("Your record, favourite deck and the habits your games "
				+ "reveal appear here once you have played.", true, UITheme.FS_SMALL))
		return
	var hist: Array = PlayerProfile.history
	var turns := 0.0
	var attacks := 0.0
	var my_turns := 0.0
	var blocks := 0.0
	var chances := 0.0
	var bp := 0
	var ai := 0
	var online := 0
	for r: Dictionary in hist:
		turns += float(r.get("turns", 0))
		attacks += float(r.get("attacks", 0))
		my_turns += float(r.get("my_turns", 0))
		blocks += float(r.get("blocks", 0))
		chances += float(r.get("blocks", 0)) + float(r.get("blocks_declined", 0))
		bp = maxi(bp, int(r.get("biggest_bp", 0)))
		if str(r.get("mode", "")) == PlayerProfile.MODE_VS_AI:
			ai += 1
		elif str(r.get("mode", "")) == PlayerProfile.MODE_ONLINE:
			online += 1
	_colour_bar()
	_glance_row("Best streak", "%d wins" % int(o["best_streak"]))
	_glance_row("Average game", "%.0f turns" % (turns / float(g)))
	_glance_row("Attacks per turn", "%.1f" % (attacks / maxf(1.0, my_turns)))
	_glance_row("Block rate", PlayerProfile.pct(blocks / chances) if chances > 0.0 else "–")
	_glance_row("Biggest spirit", ("%d BP" % bp) if bp > 0 else "–")
	_glance_row("Modes", "%d vs AI · %d online · %d hotseat" % [ai, online, g - ai - online])
	var fav_c := PlayerProfile.favourite_colour()
	if fav_c >= 0:
		var h := UITheme.hbox(UITheme.SP_S)
		var l := UITheme.body("Favourite colour", true, UITheme.FS_SMALL)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(l)
		h.add_child(UITheme.color_dot(fav_c, 12))
		h.add_child(UITheme.body(str(BSS.COLOR_NAMES[fav_c]).capitalize(), false, UITheme.FS_SMALL))
		_glance.add_child(h)


func _glance_row(label: String, value: String) -> void:
	var h := UITheme.hbox(UITheme.SP_S)
	var l := UITheme.body(label, true, UITheme.FS_SMALL)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(l)
	h.add_child(UITheme.number(value, UITheme.FS_SMALL))
	_glance.add_child(h)


## A six-colour usage bar: how much of the player's games each colour has
## seen, read off the decks in the history.
func _colour_bar() -> void:
	var tally := {}
	var total := 0
	for r: Dictionary in PlayerProfile.history:
		for c: Variant in r.get("deck_colours", []):
			tally[int(c)] = int(tally.get(int(c), 0)) + 1
			total += 1
	if total == 0:
		return
	var bar := ColourBar.new()
	bar.tally = tally
	bar.total = total
	bar.custom_minimum_size = Vector2(0, 10)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.tooltip_text = "Colours played"
	_glance.add_child(bar)
	_glance.add_child(UITheme.spacer(2))


class ColourBar extends Control:
	var tally := {}
	var total := 1

	func _draw() -> void:
		var x := 0.0
		var keys: Array = tally.keys()
		keys.sort()
		for k: Variant in keys:
			var w := size.x * float(tally[k]) / float(maxi(1, total))
			var col: Color = UITheme.COLOR_SWATCH.get(int(k), UITheme.TEXT_DIM)
			draw_rect(Rect2(x, 0, maxf(0.0, w - 1.0), size.y), col)
			x += w


## The circular icon with the player's initial over it when no picture is
## set. Shared with the main menu's name plate.
static func icon_widget(px: int) -> Control:
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(px, px)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tex := TextureRect.new()
	tex.texture = PlayerProfile.icon_texture(px)
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(tex)
	if not PlayerProfile.has_icon():
		var initial := UITheme.heading(PlayerProfile.display_name().left(1).to_upper(), int(px * 0.46))
		initial.add_theme_color_override("font_color", UITheme.ACCENT)
		initial.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		initial.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		initial.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		initial.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.add_child(initial)
	return holder


# ---------------------------------------------------------------------------
# Pages
# ---------------------------------------------------------------------------

func _show_page(key: String) -> void:
	_page = key
	for k: String in _page_buttons:
		(_page_buttons[k] as Button).button_pressed = (k == key)
	if _page_host == null:
		return
	for c in _page_host.get_children():
		_page_host.remove_child(c)
		c.queue_free()
	var v := UITheme.vbox(UITheme.SP_S)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_page_host.add_child(v)
	match key:
		"decks": _build_decks(v)
		"insights": _build_insights(v)
		"recent": _build_recent(v)
	Motion.stagger_in(v.get_children())


func _empty(v: VBoxContainer, text: String) -> void:
	v.add_child(UITheme.spacer(20))
	v.add_child(UITheme.paragraph(text, true))


const COL_GAMES := 64.0
const COL_WLD := 96.0
const COL_BAR := 150.0
const COL_PCT := 52.0
const COL_DATE := 92.0
const COL_COLOURS := 84.0


func _header_row(cols: Array) -> Control:
	var h := UITheme.hbox(UITheme.SP_S)
	for c: Array in cols:
		var l := UITheme.eyebrow(str(c[0]))
		var w := float(c[1])
		if w > 0.0:
			l.custom_minimum_size = Vector2(w, 0)
		else:
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(l)
	return h


func _build_decks(v: VBoxContainer) -> void:
	var rows := PlayerProfile.stats_by_deck()
	if rows.is_empty():
		_empty(v, "No matches recorded yet. Every game you finish against the AI, in a room or in the "
				+ "random queue is added here with the deck you played.")
		return
	v.add_child(_header_row([["Deck", 0], ["Colours", COL_COLOURS], ["Games", COL_GAMES],
			["W-L-D", COL_WLD], ["Win rate", COL_BAR + COL_PCT + UITheme.SP_S], ["Last played", COL_DATE]]))
	v.add_child(UITheme.rule())
	for r: Dictionary in rows:
		var h := UITheme.hbox(UITheme.SP_S)
		h.custom_minimum_size = Vector2(0, 34)
		var nm := UITheme.truncating(str(r["name"]))
		h.add_child(nm)
		var dots := UITheme.hbox(3)
		dots.custom_minimum_size = Vector2(COL_COLOURS, 0)
		for c: Variant in r.get("colours", []):
			dots.add_child(UITheme.color_dot(int(c), 14))
		h.add_child(dots)
		h.add_child(_cell(str(r["games"]), COL_GAMES))
		h.add_child(_cell("%d-%d-%d" % [int(r["wins"]), int(r["losses"]), int(r["draws"])], COL_WLD))
		h.add_child(_rate_bar(float(r["win_rate"])))
		h.add_child(_cell(PlayerProfile.pct(float(r["win_rate"])), COL_PCT))
		h.add_child(_cell(str(r["last_played"]).left(10), COL_DATE, true))
		v.add_child(h)


func _cell(text: String, w: float, dim: bool = false) -> Label:
	var l := UITheme.body(text, dim, UITheme.FS_SMALL + 1)
	l.custom_minimum_size = Vector2(w, 0)
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return l


func _rate_bar(rate: float) -> Control:
	var bar := RateBar.new()
	bar.rate = clampf(rate, 0.0, 1.0)
	bar.custom_minimum_size = Vector2(COL_BAR, 14)
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return bar


## A win-rate bar drawn by hand: a container would stretch a child rect to
## its full width whatever anchors it was given (11.9).
## 0.16.0: a 4 px track, a tinted fill, and a core gem at the tip.
class RateBar extends Control:
	var rate := 0.0

	func _draw() -> void:
		var y := size.y * 0.5
		var h := 4.0
		draw_rect(Rect2(0, y - h * 0.5, size.x, h), Color(1, 1, 1, 0.08))
		var tint := UITheme.OK if rate >= 0.5 else (UITheme.WARN if rate >= 0.35 else UITheme.BAD)
		if rate > 0.0:
			var w := maxf(3.0, (size.x - 6.0) * rate)
			draw_rect(Rect2(0, y - h * 0.5, w, h), tint)
			UITheme.draw_gem(self, Vector2(w, y), 5.0, tint)


func _build_insights(v: VBoxContainer) -> void:
	var ins := PlayerProfile.strengths_and_weaknesses()
	var conf := str(ins["confidence"])
	var head := UITheme.hbox(UITheme.SP_S)
	head.add_child(UITheme.eyebrow("Playstyle"))
	head.add_child(UITheme.grow())
	var conf_tint := {"none": UITheme.TEXT_DIM, "low": UITheme.CORE, "medium": UITheme.GOLD,
			"high": UITheme.OK}
	head.add_child(UITheme.pill("Confidence: %s" % conf, conf_tint.get(conf, UITheme.TEXT_DIM)))
	v.add_child(head)
	v.add_child(UITheme.paragraph(str(ins["playstyle"])))
	v.add_child(UITheme.spacer(4))

	var cols := UITheme.hbox(UITheme.SP_M)
	v.add_child(cols)
	cols.add_child(_insight_list("Strengths", ins["strengths"], UITheme.SUCCESS))
	cols.add_child(_insight_list("Weaknesses", ins["weaknesses"], UITheme.DANGER))

	var tips: Array = ins["tips"]
	if not tips.is_empty():
		v.add_child(UITheme.spacer(4))
		v.add_child(UITheme.eyebrow("Tips", UITheme.GOLD))
		for t: Variant in tips:
			v.add_child(_bullet(str(t), UITheme.ACCENT))


func _insight_list(title: String, items: Array, tint: Color) -> Control:
	var col := UITheme.vbox(UITheme.SP_XS)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_stretch_ratio = 1.0
	col.add_child(UITheme.eyebrow(title, tint))
	if items.is_empty():
		col.add_child(UITheme.paragraph("Nothing to report yet.", true, UITheme.FS_SMALL))
	for it: Variant in items:
		col.add_child(_bullet(str(it), tint))
	return col


## A coloured dot and a wrapping sentence, as one RichTextLabel: a wrapping
## label beside a dot in an HBox is the collapse trap of 11.9.
func _bullet(text: String, tint: Color) -> Control:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.add_theme_font_size_override("normal_font_size", UITheme.FS_SMALL + 1)
	r.add_theme_color_override("default_color", UITheme.TEXT)
	r.text = "[color=#%s]●[/color]  %s" % [tint.to_html(false), text.replace("[", "[lb]")]
	return r


func _build_recent(v: VBoxContainer) -> void:
	var rows := PlayerProfile.recent(10)
	if rows.is_empty():
		_empty(v, "Your last ten matches will be listed here.")
		return
	v.add_child(_header_row([["Date", COL_DATE], ["Mode", 104], ["Your deck", 0], ["Against", 0],
			["Result", 66], ["Turns", 52], ["Life", 56]]))
	v.add_child(UITheme.rule())
	for r: Dictionary in rows:
		var h := UITheme.hbox(UITheme.SP_S)
		h.custom_minimum_size = Vector2(0, 32)
		h.add_child(_cell(str(r.get("date", "")).left(10), COL_DATE, true))
		h.add_child(_cell(_mode_text(r), 104))
		var mine := UITheme.truncating(str(r.get("deck_name", "")), false, UITheme.FS_SMALL + 1)
		h.add_child(mine)
		var opp := UITheme.truncating(str(r.get("opp_deck", "")), true, UITheme.FS_SMALL + 1)
		h.add_child(opp)
		var res := str(r.get("result", ""))
		var tint := UITheme.SUCCESS if res == "win" else (UITheme.DANGER if res == "loss" else UITheme.TEXT_DIM)
		var pill := UITheme.pill(res.capitalize(), tint)
		pill.custom_minimum_size = Vector2(66, 0)
		h.add_child(pill)
		h.add_child(_cell(str(r.get("turns", 0)), 52))
		h.add_child(_cell("%d-%d" % [int(r.get("my_life", 0)), int(r.get("opp_life", 0))], 56, true))
		v.add_child(h)


func _mode_text(r: Dictionary) -> String:
	match str(r.get("mode", "")):
		PlayerProfile.MODE_VS_AI:
			var d := int(r.get("difficulty", -1))
			if d >= 0 and d < BotController.DIFFICULTY_NAMES.size():
				return "AI · %s" % str(BotController.DIFFICULTY_NAMES[d])
			return "AI"
		PlayerProfile.MODE_HOTSEAT: return "Hotseat"
		PlayerProfile.MODE_ONLINE: return "Online"
	return str(r.get("mode", ""))


# ---------------------------------------------------------------------------
# Icon picker
# ---------------------------------------------------------------------------

func _open_icon_picker() -> void:
	_pick_query = ""
	_pick_page = 0
	var m := Modal.open(self, "Choose an icon", 760.0)
	var search := UITheme.search_field("Search cards by name…")
	search.text_changed.connect(func(t: String):
		_pick_query = t
		_pick_page = 0
		_fill_picker(m))
	m.body.add_child(search)
	_pick_grid = GridContainer.new()
	_pick_grid.columns = PICK_COLS
	_pick_grid.add_theme_constant_override("h_separation", 8)
	_pick_grid.add_theme_constant_override("v_separation", 8)
	_pick_grid.custom_minimum_size = Vector2(0, 2 * 100 + 8)
	m.body.add_child(_pick_grid)
	var nav := UITheme.hbox(UITheme.SP_S)
	nav.add_child(UITheme.button("‹", func():
		_pick_page = maxi(0, _pick_page - 1)
		_fill_picker(m)))
	_pick_status = UITheme.body("", true, UITheme.FS_SMALL)
	_pick_status.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	nav.add_child(_pick_status)
	nav.add_child(UITheme.button("›", func():
		_pick_page += 1
		_fill_picker(m)))
	nav.add_child(UITheme.grow())
	nav.add_child(UITheme.body("Click a card to use its art.", true, UITheme.FS_SMALL))
	m.body.add_child(nav)

	m.buttons.add_child(UITheme.button("Upload image…", func(): _open_file_dialog(m)))
	if PlayerProfile.has_icon():
		m.buttons.add_child(UITheme.button("Use my initial", func():
			PlayerProfile.clear_icon()
			m.close()))
	m.buttons.add_child(UITheme.grow())
	m.buttons.add_child(UITheme.button("Cancel", m.close))
	_fill_picker(m)
	search.grab_focus.call_deferred()


func _picker_cards() -> Array:
	var out: Array = []
	var q := _pick_query.strip_edges().to_lower()
	for cd: CardData in CardDB.all_cards():
		if CardDB.is_hidden(cd.id):
			continue
		if q != "" and not cd.matches_search(q):
			continue
		out.append(cd)
	out.sort_custom(func(a: CardData, b: CardData) -> bool: return a.name.naturalnocasecmp_to(b.name) < 0)
	return out


func _fill_picker(m: Modal) -> void:
	if _pick_grid == null or not is_instance_valid(_pick_grid):
		return
	for c in _pick_grid.get_children():
		_pick_grid.remove_child(c)
		c.queue_free()
	var cards := _picker_cards()
	var pages := maxi(1, int(ceil(float(cards.size()) / float(PAGE_CARDS))))
	_pick_page = clampi(_pick_page, 0, pages - 1)
	var start := _pick_page * PAGE_CARDS
	for cd: CardData in cards.slice(start, start + PAGE_CARDS):
		var w := CardWidget.new()
		w.setup(cd.id, Vector2(72, 100))
		w.tooltip_text = cd.name
		var id := cd.id
		w.clicked.connect(func(_cid: String):
			PlayerProfile.set_icon_card(id)
			set_status("Icon set from %s" % cd.name)
			m.close())
		_pick_grid.add_child(w)
	_pick_status.text = "Page %d of %d · %d cards" % [_pick_page + 1, pages, cards.size()]


func _open_file_dialog(m: Modal) -> void:
	if WebFilePicker.available():
		# 0.21.1: the browser's file window; the picture stays in this browser
		WebFilePicker.pick("image/png,image/jpeg,image/webp", func(path: String, file_name: String) -> void:
			if file_name.is_empty():
				return
			if not path.is_empty() and PlayerProfile.set_icon_file(path):
				set_status("Profile picture set from %s" % file_name)
				m.close()
			else:
				set_status("Could not use %s as a picture" % file_name, true), "Choose a profile picture")
		return
	var dlg := FileDialog.new()
	dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dlg.access = FileDialog.ACCESS_FILESYSTEM
	dlg.use_native_dialog = true
	dlg.filters = PackedStringArray(["*.png, *.jpg, *.jpeg, *.webp ; Images"])
	dlg.title = "Choose a profile picture"
	dlg.file_selected.connect(func(path: String):
		if PlayerProfile.set_icon_file(path):
			set_status("Icon set from %s" % path.get_file())
			if is_instance_valid(m):
				m.close()
		else:
			set_status("Could not read %s" % path.get_file(), true)
		dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	add_child(dlg)
	dlg.popup_centered_ratio(0.6)
