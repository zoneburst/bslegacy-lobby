extends Control
class_name SideboardPanel
## Sideboarding between games (0.24.0): the deck on the left, the sideboard on
## the right, the card under the pointer in the middle. Clicking a card moves
## one copy across. Only the cards of the deck as registered for the match
## (its deck + sideboard) are offered, the deck must stay 50-60 cards, and
## Reset puts back the deck as it was saved. Changes last for this match only:
## the saved deck is not touched.
##
## Like other card games' best-of-3 matches (MTG Arena, Yu-Gi-Oh! Master
## Duel), there is a time limit online: when it runs out, the deck as it
## stands (if legal, else the last deck played) is used.
##
##   SideboardPanel.open(host, registered_deck, current_main, title, seconds, on_done)
##   on_done(main: Array)  -- called once, with the chosen deck

signal done(main: Array)

var _deck: Dictionary = {}          # as registered: {"main", "side"}
var _main: Array = []
var _side: Array = []
var _start_main: Array = []         # the deck of the last game (the timer falls back to it)
var _deadline := 0.0
var _title := ""
var _finished := false

var _main_list: VBoxContainer
var _side_list: VBoxContainer
var _main_head: Label
var _side_head: Label
var _legal: Label
var _swaps: Label
var _ready_btn: Button
var _timer: Label
var _preview: CardWidget
var _preview_name: Label


static func open(host: Node, registered: Dictionary, now_main: Array, title: String,
		seconds: float, on_done: Callable) -> SideboardPanel:
	var p := SideboardPanel.new()
	p._deck = registered
	p._main = now_main.duplicate()
	p._start_main = now_main.duplicate()
	p._side = DeckManager.side_after(registered, now_main)
	p._title = title
	p._deadline = Time.get_unix_time_from_system() + seconds if seconds > 0.0 else 0.0
	p.done.connect(on_done)
	host.add_child(p)
	return p


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 110
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.07, 0.94)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var outer := MarginContainer.new()
	outer.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]:
		outer.add_theme_constant_override("margin_" + side, 40)
	outer.add_theme_constant_override("margin_top", 28)
	outer.add_theme_constant_override("margin_bottom", 24)
	add_child(outer)
	var v := UITheme.vbox(UITheme.SP_M)
	outer.add_child(v)

	# header: title, the rule in one line, the timer
	var head := UITheme.hbox(UITheme.SP_M)
	var titles := UITheme.vbox(2)
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.add_child(UITheme.eyebrow("Sideboard", UITheme.GOLD))
	titles.add_child(UITheme.display_title(_title, UITheme.FS_TITLE - 6))
	titles.add_child(UITheme.body("Click a card to move one copy across. Your deck must stay at 50 to 60 cards; "
			+ "only your own deck and sideboard can be used, and your saved deck is not changed.", true, UITheme.FS_SMALL))
	head.add_child(titles)
	_timer = UITheme.number("", UITheme.FS_HEAD, UITheme.GOLD_HI)
	_timer.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_timer)
	v.add_child(head)
	v.add_child(UITheme.gold_rule(220.0))

	var cols := UITheme.hbox(UITheme.SP_L)
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(cols)
	var left := _column("Your deck", true)
	_main_head = left[1]
	_main_list = left[2]
	cols.add_child(left[0])

	var mid := UITheme.vbox(UITheme.SP_S)
	mid.custom_minimum_size = Vector2(250, 0)
	mid.alignment = BoxContainer.ALIGNMENT_CENTER
	var holder := CenterContainer.new()
	holder.custom_minimum_size = Vector2(0, 330)
	_preview = CardWidget.new()
	_preview.setup_back(Vector2(228, 318))
	holder.add_child(_preview)
	mid.add_child(holder)
	_preview_name = UITheme.truncating("Point at a card to see it", true, UITheme.FS_BODY)
	_preview_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mid.add_child(_preview_name)
	_swaps = UITheme.body("", true, UITheme.FS_SMALL)
	_swaps.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mid.add_child(_swaps)
	cols.add_child(mid)

	var right := _column("Sideboard", false)
	_side_head = right[1]
	_side_list = right[2]
	cols.add_child(right[0])

	var foot := UITheme.hbox(UITheme.SP_S)
	_legal = UITheme.body("", false, UITheme.FS_BODY)
	_legal.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_legal.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	foot.add_child(_legal)
	var reset := UITheme.button("Reset to my saved deck", _reset)
	reset.custom_minimum_size = Vector2(0, 50)
	foot.add_child(reset)
	_ready_btn = UITheme.hero_button("Ready", _confirm)
	_ready_btn.custom_minimum_size = Vector2(220, 54)
	_ready_btn.name = "SideboardReady"
	foot.add_child(_ready_btn)
	v.add_child(foot)
	_refresh()
	Motion.enter_screen(outer)


func _column(title: String, is_main: bool) -> Array:
	var p := UITheme.panel(Vector2(0, 0))
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var v := UITheme.vbox(UITheme.SP_S)
	p.add_child(v)
	var h := UITheme.hbox(UITheme.SP_S)
	var t := UITheme.eyebrow(title, UITheme.ACCENT if is_main else UITheme.CORE)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(t)
	var count := UITheme.number("", UITheme.FS_HEAD, UITheme.TEXT)
	h.add_child(count)
	v.add_child(h)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(scroll)
	var list := UITheme.vbox(3)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	return [p, count, list]


func _process(_delta: float) -> void:
	if _deadline <= 0.0 or _finished:
		if _timer != null:
			_timer.text = ""
		return
	var left := maxf(0.0, _deadline - Time.get_unix_time_from_system())
	var secs := int(ceil(left))
	_timer.text = "%d:%02d" % [floori(secs / 60.0), secs % 60]
	_timer.add_theme_color_override("font_color", UITheme.DANGER if left < 20.0 else UITheme.GOLD_HI)
	if left <= 0.0:
		# time is up: the deck as it stands if it is legal, else the last one
		if not _is_legal():
			_main = _start_main.duplicate()
		_confirm()


func _is_legal() -> bool:
	return bool(DeckManager.check_sideboarded(_deck, _main).get("ok", false))


func _refresh() -> void:
	_fill(_main_list, _main, true)
	_fill(_side_list, _side, false)
	_main_head.text = "%d" % _main.size()
	_side_head.text = "%d" % _side.size()
	var chk := DeckManager.check_sideboarded(_deck, _main)
	var ok := bool(chk.get("ok", false))
	_legal.text = ("Deck ready: %d cards" % _main.size()) if ok else ("Not ready: %s" % str(chk.get("reason", "")))
	_legal.add_theme_color_override("font_color", UITheme.OK if ok else UITheme.BAD)
	_main_head.add_theme_color_override("font_color", UITheme.OK if ok else UITheme.BAD)
	_ready_btn.disabled = not ok
	var orig: Array = _deck.get("main", [])
	var ins := 0
	var pool := {}
	for c in orig:
		pool[c] = int(pool.get(c, 0)) + 1
	for c2 in _main:
		if int(pool.get(c2, 0)) > 0:
			pool[c2] = int(pool[c2]) - 1
		else:
			ins += 1
	var outs := orig.size() - (_main.size() - ins)
	_swaps.text = "Compared with your saved deck: %d in · %d out" % [ins, outs] if ins + outs > 0 else "Your saved deck, unchanged"


func _fill(list: VBoxContainer, ids: Array, is_main: bool) -> void:
	for c in list.get_children():
		list.remove_child(c)
		c.queue_free()
	var counts := {}
	var order: Array = []
	for id in ids:
		if not counts.has(id):
			counts[id] = 0
			order.append(id)
		counts[id] = int(counts[id]) + 1
	order.sort_custom(func(a: Variant, b: Variant) -> bool:
		var ca: CardData = CardDB.get_card(str(a))
		var cb: CardData = CardDB.get_card(str(b))
		if ca == null or cb == null:
			return str(a) < str(b)
		if ca.card_type != cb.card_type:
			return ca.card_type < cb.card_type
		if ca.cost != cb.cost:
			return ca.cost < cb.cost
		return ca.name < cb.name)
	if order.is_empty():
		list.add_child(UITheme.paragraph("Empty" if is_main else
				"No cards here. Cards you take out of your deck land here.", true, UITheme.FS_SMALL))
	for id in order:
		list.add_child(_row(str(id), int(counts[id]), is_main))


func _row(id: String, n: int, is_main: bool) -> Control:
	var cd: CardData = CardDB.get_card(id)
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, 42)
	b.focus_mode = Control.FOCUS_NONE
	b.clip_contents = true
	b.tooltip_text = ("Move one to the sideboard" if is_main else "Move one into the deck")
	var sb := UITheme._box(Color("#0b1020"), 8, UITheme.BORDER)
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_stylebox_override("hover", UITheme._box(Color("#121a30"), 8, UITheme.GOLD_HI, 2))
	b.add_theme_stylebox_override("pressed", UITheme._box(Color("#121a30"), 8, UITheme.GOLD, 2))
	var art := TextureRect.new()
	art.texture = CardDB.get_card_art_texture(id)
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	art.modulate = Color(1, 1, 1, 0.4)
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	art.set_anchors_preset(Control.PRESET_FULL_RECT)
	b.add_child(art)
	var row := UITheme.hbox(8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 10
	row.offset_right = -10
	var cost := UITheme.number(str(cd.cost) if cd != null else "?", UITheme.FS_BODY, UITheme.GOLD_HI)
	cost.custom_minimum_size = Vector2(22, 0)
	cost.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cost.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(cost)
	var nm := UITheme.truncating(cd.name if cd != null else id, false, UITheme.FS_BODY - 1)
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nm.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	nm.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	nm.add_theme_constant_override("outline_size", 4)
	nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(nm)
	var cnt := UITheme.heading("×%d" % n, UITheme.FS_HEAD - 2)
	cnt.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cnt.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	cnt.add_theme_constant_override("outline_size", 4)
	cnt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(cnt)
	var arrow := UITheme.heading("→" if is_main else "←", UITheme.FS_HEAD - 2)
	arrow.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	arrow.add_theme_color_override("font_color", UITheme.CORE if is_main else UITheme.GOLD_HI)
	arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if is_main:
		row.add_child(arrow)
	else:
		row.add_child(arrow)
		row.move_child(arrow, 0)
	b.add_child(row)
	b.mouse_entered.connect(func(): _show(id))
	b.pressed.connect(func(): _move(id, is_main))
	return b


func _show(id: String) -> void:
	if _preview == null:
		return
	_preview.setup(id, Vector2(228, 318))
	var cd: CardData = CardDB.get_card(id)
	_preview_name.text = cd.name if cd != null else id


func _move(id: String, from_main: bool) -> void:
	if _finished:
		return
	var src := _main if from_main else _side
	var i := src.find(id)
	if i < 0:
		return
	if not from_main and _main.size() >= BSS.DECK_MAX:
		AudioManager.play_sfx("error")
		_legal.text = "Your deck is already at %d cards: take one out first" % BSS.DECK_MAX
		_legal.add_theme_color_override("font_color", UITheme.WARN)
		return
	src.remove_at(i)
	(_side if from_main else _main).append(id)
	AudioManager.play_sfx("card_play")
	_refresh()


## The same as clicking a card (tests and the showcase recording use it).
func move_for_test(id: String, from_main: bool) -> void:
	_move(id, from_main)


func _reset() -> void:
	_main = (_deck.get("main", []) as Array).duplicate()
	_side = (_deck.get("side", []) as Array).duplicate()
	AudioManager.play_sfx("ui_click")
	_refresh()


func _confirm() -> void:
	if _finished or not _is_legal():
		return
	_finished = true
	AudioManager.play_sfx("ui_click")
	done.emit(_main.duplicate())
	queue_free()


func current_main() -> Array:
	return _main.duplicate()
