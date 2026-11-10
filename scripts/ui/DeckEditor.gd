extends MenuBase
##
## Deck editor, laid out after the reference deck builder:
##
##   toolbar      search · reset · hide alts · sort · card size
##   filter row   colour chips · card type chips · cost range
##   filter row 2 set · rarity · spirit type · keyword · condition · BP range (0.16.0)
##   left         pager, then a grid of card art, each with  −  n/4  +
##   right        the decklist as card-art strips, grouped by type
##   zoom         click any card, in either place, for a full inspector
##
## The editor works on a DRAFT. Nothing is written until Save is pressed, so
## opening the editor and leaving no longer leaves an empty deck behind (R-021).
## Leaving with unsaved changes asks first.
##
## Layout rules observed (architecture guide 11.9): no wrapping labels in rows,
## no truncating labels without a width, no ScrollContainer inside another,
## explicit minimum sizes on every pane.
##

const DECK_W := 380.0
const PER_PAGE := 30        # 0.16.5: full rows of 5, 6 or 10
const TILE_STEPS := [Vector2(112, 157), Vector2(136, 190), Vector2(168, 235)]

var _deck: Dictionary = {}
var _saved_snapshot := ""
var _results: Array = []
var _page := 0
var _tile_step := 1

var _search: LineEdit
var _grid: GridContainer
var _grid_scroll: ScrollContainer
var _pager: HBoxContainer
var _deck_name: LineEdit
var _deck_list: VBoxContainer
var _deck_summary: Label
var _legality_slot: HBoxContainer
var _curve_box: HBoxContainer
var _split: HBoxContainer
var _type_chips := {}
var _color_chips := {}
var _zoom: CardZoom

var _colors: Array = []
var _types: Array = []
var _cost_min := 0
var _cost_max := 20
var _sort := "type_set"
var _hide_alts := true
# 0.16.0 filters: "" = any
var _set := ""
var _rarity := ""
var _family := ""
var _keyword := ""
var _timing := ""
var _bp_min := 0
var _bp_max := 99999
var _facet_opts := {}          # kind -> OptionButton
var _spin_boxes: Array = []     # every range SpinBox, for Reset all
var _last_count := 0            # for the card-count tick (0.16.0)
const SORTS := [["Sort: Type · Set", "type_set"], ["Sort: Cost", "cost"], ["Sort: Name", "name"], ["Sort: BP", "bp"], ["Sort: Number", "id"],
		["Sort: Type", "type"], ["Sort: Colour", "color"], ["Sort: Rarity", "rarity"], ["Sort: Set", "set"],
		["Sort: Spirit type", "spirit_type"]]


func screen_title() -> String:
	return "Deck Editor"


func screen_subtitle() -> String:
	return "Deck builder"


func show_back_button() -> bool:
	return false   # replaced by a Back that checks for unsaved changes


func header_extras() -> Array:
	var save := UITheme.hero_button("Save deck", _save, UITheme.FS_BODY)
	save.custom_minimum_size = Vector2(160, 44)
	save.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return [save]


func music_track() -> String:
	return "deck_theme"


func build_content(parent: VBoxContainer) -> void:
	var deck_id := str(SceneRouter.payload.get("deck_id", ""))
	_deck = DeckManager.get_deck(deck_id).duplicate(true) if deck_id != "" else {}
	if _deck.is_empty():
		_deck = DeckManager.new_deck()
	_saved_snapshot = JSON.stringify(_deck.get("main", [])) + str(_deck.get("name", ""))
	if deck_id == "":
		_saved_snapshot = ""   # a brand-new deck counts as unsaved once it has cards

	_add_back_button()
	parent.add_child(_build_toolbar())
	parent.add_child(_build_filter_row())
	parent.add_child(_build_filter_row2())

	_split = UITheme.hbox(UITheme.SP_M)
	_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(_split)
	_split.add_child(_build_results())
	_split.add_child(_build_deck_pane())

	# The inspector is a child of the screen, not of a pane, so it covers
	# everything and is not clipped by whichever panel opened it.
	_zoom = CardZoom.new()
	add_child(_zoom)
	_zoom.add_requested.connect(func(id: String):
		_add(id)
		_zoom.refresh_count())
	_zoom.remove_requested.connect(func(id: String):
		_remove(id)
		_zoom.refresh_count())

	_run_search()
	_refresh_deck()


## Back, but it asks before throwing away unsaved work.
func _add_back_button() -> void:
	var back := UITheme.ghost_button("‹  BACK", _leave)
	back.custom_minimum_size = Vector2(96, 40)
	back.add_theme_font_size_override("font_size", UITheme.FS_SMALL)
	back.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_header.add_child(back)
	_header.move_child(back, 0)


func _dirty() -> bool:
	var now := JSON.stringify(_deck.get("main", [])) + str(_deck.get("name", ""))
	if _saved_snapshot == "":
		return not (_deck.get("main", []) as Array).is_empty()
	return now != _saved_snapshot


func _leave() -> void:
	if not _dirty():
		SceneRouter.back()
		return
	Modal.confirm(self, "Leave without saving?",
		"This deck has changes that have not been saved.",
		func(): SceneRouter.back(), "Discard changes", true)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if _zoom != null and _zoom.visible:
			return
		_leave()
		get_viewport().set_input_as_handled()


# ---------------------------------------------------------------- toolbar --
func _build_toolbar() -> Control:
	var bar := UITheme.hbox(UITheme.SP_S)
	_search = UITheme.search_field("Search name, effect text or card number")
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_changed.connect(func(_t: String):
		_page = 0
		_run_search())
	bar.add_child(_search)
	var reset := UITheme.ghost_button("↺  Reset all", _reset_filters)
	reset.tooltip_text = "Clear the search and every filter"
	bar.add_child(reset)

	var alts := UITheme.chip("Hide alts", UITheme.CORE)
	alts.button_pressed = true
	alts.custom_minimum_size = Vector2(0, 44)
	alts.toggled.connect(func(on: bool):
		_hide_alts = on
		_run_search())
	bar.add_child(alts)

	var sort_opt := OptionButton.new()
	sort_opt.custom_minimum_size = Vector2(170, 44)
	for pair: Array in SORTS:
		sort_opt.add_item(str(pair[0]))
	sort_opt.item_selected.connect(func(i: int):
		_sort = str(SORTS[i][1])
		_run_search())
	bar.add_child(sort_opt)

	var smaller := UITheme.button("−", func(): _zoom_grid(-1))
	smaller.custom_minimum_size = Vector2(44, 44)
	smaller.tooltip_text = "Smaller cards"
	bar.add_child(smaller)
	var bigger := UITheme.button("+", func(): _zoom_grid(1))
	bigger.custom_minimum_size = Vector2(44, 44)
	bigger.tooltip_text = "Larger cards"
	bar.add_child(bigger)
	return bar


func _zoom_grid(by: int) -> void:
	_tile_step = clampi(_tile_step + by, 0, TILE_STEPS.size() - 1)
	_show_page()


# ------------------------------------------------------------- filter row --
func _build_filter_row() -> Control:
	var row := UITheme.hbox(UITheme.SP_XS)

	row.add_child(UITheme.eyebrow("Colour"))
	for i in BSS.COLOR_NAMES.size():
		var idx := i
		var chip := UITheme.color_chip(i, str(BSS.COLOR_NAMES[i]).capitalize())
		chip.toggled.connect(func(on: bool):
			if on:
				_colors.append(idx)
			else:
				_colors.erase(idx)
			_page = 0
			_run_search())
		_color_chips[idx] = chip
		row.add_child(chip)

	row.add_child(UITheme.spacer(0))
	var sep := ColorRect.new()
	sep.color = UITheme.BORDER
	sep.custom_minimum_size = Vector2(1, 26)
	sep.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(sep)
	row.add_child(UITheme.eyebrow("Type"))

	for t: String in ["spirit", "nexus", "magic"]:
		var tt: String = t
		var chip2 := UITheme.chip(t.capitalize(), UITheme.GOLD)
		chip2.toggled.connect(func(on: bool):
			if on:
				_types.append(tt)
			else:
				_types.erase(tt)
			_page = 0
			_run_search())
		_type_chips[tt] = chip2
		row.add_child(chip2)

	row.add_child(UITheme.grow())
	_range(row, "Cost", 0, 20, 1, func(v: int): _cost_min = v, func(v: int): _cost_max = v)
	return row


## "Cost 0 to 20" / "BP 0 to 30000": two spin boxes and their labels.
func _range(row: HBoxContainer, label: String, lo_v: int, hi_v: int, step: int, set_lo: Callable, set_hi: Callable) -> void:
	row.add_child(UITheme.body(label, true, UITheme.FS_SMALL))
	var lo := SpinBox.new()
	lo.min_value = lo_v
	lo.max_value = hi_v
	lo.step = step
	lo.custom_minimum_size = Vector2(84 if hi_v <= 99 else 104, 34)
	lo.value_changed.connect(func(val: float):
		set_lo.call(int(val))
		_page = 0
		_run_search())
	row.add_child(lo)
	row.add_child(UITheme.body("to", true, UITheme.FS_SMALL))
	var hi := SpinBox.new()
	hi.min_value = lo_v
	hi.max_value = hi_v
	hi.step = step
	hi.value = hi_v
	hi.custom_minimum_size = lo.custom_minimum_size
	hi.value_changed.connect(func(val: float):
		set_hi.call(int(val))
		_page = 0
		_run_search())
	row.add_child(hi)
	_spin_boxes.append_array([lo, hi])


## Set, rarity, spirit type, keyword and condition dropdowns, and a BP range
## (0.16.0). Each list is built from the cards that are actually playable, so
## an imported set appears the moment it is imported.
func _build_filter_row2() -> Control:
	var row := UITheme.hbox(UITheme.SP_XS)
	_facet(row, "set", "Set", 118, func(v: String): _set = v)
	_facet(row, "rarity", "Rarity", 128, func(v: String): _rarity = v)
	_facet(row, "spirit_type", "Spirit type", 178, func(v: String): _family = v)
	_facet(row, "keyword", "Keyword", 140, func(v: String): _keyword = v)
	_facet(row, "timing", "Condition", 230, func(v: String): _timing = v)
	row.add_child(UITheme.grow())
	_range(row, "BP", 0, 30000, 1000, func(v: int): _bp_min = v, func(v: int): _bp_max = v)
	return row


func _facet(row: HBoxContainer, kind: String, label: String, width: int, setter: Callable) -> void:
	var opt := OptionButton.new()
	opt.custom_minimum_size = Vector2(width, 34)
	opt.fit_to_longest_item = false
	opt.add_item("%s: any" % label)
	var values: Array = CardDB.facet(kind)
	for v: Variant in values:
		opt.add_item(_facet_text(kind, str(v)))
	opt.item_selected.connect(func(i: int):
		setter.call("" if i == 0 else str(values[i - 1]))
		_page = 0
		_run_search())
	_facet_opts[kind] = opt
	row.add_child(opt)


func _facet_text(kind: String, v: String) -> String:
	if kind == "set":
		return "%s %s" % [v, SET_NAMES.get(v, "")] if SET_NAMES.has(v) else v
	return v


const SET_NAMES := {"BSS01": "Dawn of History", "BSS02": "False Gods", "BSS03": "Aquatic Invaders",
		"BSS04": "Savior of Chaos", "BSS05": "Strangers in the Sky", "BSS06": "Generational Link",
		"ST01": "Dragon Onslaught", "ST02": "Call of the Curse", "ST03": "Aegis of the Machine",
		"ST04": "Forbidden Magic", "ST05": "Verdant Wings", "ST06": "Bodies of Steel", "ST07": "Destined Assault",
		"PR": "Promo"}


func _reset_filters() -> void:
	_colors.clear()
	_types.clear()
	_page = 0
	_search.text = ""
	_set = ""
	_rarity = ""
	_family = ""
	_keyword = ""
	_timing = ""
	_cost_min = 0
	_cost_max = 20
	_bp_min = 0
	_bp_max = 99999
	for k in _facet_opts:
		(_facet_opts[k] as OptionButton).select(0)
	for i in _spin_boxes.size():
		var sb: SpinBox = _spin_boxes[i]
		sb.set_value_no_signal(sb.min_value if i % 2 == 0 else sb.max_value)
	for k in _color_chips:
		(_color_chips[k] as Button).set_pressed_no_signal(false)
	for k in _type_chips:
		(_type_chips[k] as Button).set_pressed_no_signal(false)
	_run_search()


# ---------------------------------------------------------------- results --
func _build_results() -> Control:
	var p := UITheme.panel()
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.size_flags_vertical = Control.SIZE_EXPAND_FILL
	p.clip_contents = true
	var v := UITheme.vbox(UITheme.SP_S)
	p.add_child(v)

	_pager = UITheme.hbox(UITheme.SP_XS)
	_pager.custom_minimum_size = Vector2(0, 34)
	v.add_child(_pager)

	_grid_scroll = ScrollContainer.new()
	# SHOW_NEVER, not DISABLED (0.17.4, R-104): with horizontal scrolling
	# disabled, a ScrollContainer is at least as wide as its content, so a
	# grid that once got wider (more columns) held the panel wide for good and
	# pushed the deck list off the screen. Now the panel's width comes from the
	# screen, and the columns follow it.
	_grid_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_grid_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_grid_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid_scroll.resized.connect(_reflow)
	v.add_child(_grid_scroll)

	_grid = GridContainer.new()
	_grid.add_theme_constant_override("h_separation", UITheme.SP_S)
	_grid.add_theme_constant_override("v_separation", UITheme.SP_M)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid_scroll.add_child(_grid)
	return p


func _run_search() -> void:
	var query := {
		"text": _search.text if _search != null else "",
		"colors": _colors,
		"card_types": _types,
		"sort": _sort,
		"hide_alts": _hide_alts,
	}
	# 0.16.0 filters (CardDB.search applies every key present)
	if _set != "": query["set_code"] = _set
	if _rarity != "": query["rarity"] = _rarity
	if _family != "": query["spirit_type"] = _family
	if _keyword != "": query["keyword"] = _keyword
	if _timing != "": query["timing"] = _timing
	if _bp_min > 0: query["bp_min"] = _bp_min
	if _bp_max < 99999: query["bp_max"] = _bp_max
	_results = []
	for cd: CardData in CardDB.search(query):
		if cd.cost >= _cost_min and cd.cost <= _cost_max:
			_results.append(cd)
	_page = clampi(_page, 0, maxi(0, _pages() - 1))
	_show_page()


func _pages() -> int:
	return maxi(1, int(ceil(float(_results.size()) / float(PER_PAGE))))


func _show_page() -> void:
	if _grid == null:
		return
	for c in _grid.get_children():
		_grid.remove_child(c)       # out of the layout now, not at frame end (R-044)
		c.queue_free()
	var start := _page * PER_PAGE
	_grid.columns = _columns()
	for i in range(start, mini(start + PER_PAGE, _results.size())):
		var cd: CardData = _results[i]
		_grid.add_child(_grid_tile(cd, i))
	_build_pager()


## The card plus a "− n/4 +" strip beneath it, as in the reference: the count
## is visible without opening anything, and adding never leaves the grid.
func _grid_tile(cd: CardData, index: int) -> Control:
	var tile_size: Vector2 = _eff_tile()
	var box := UITheme.vbox(4)
	box.custom_minimum_size = Vector2(tile_size.x, tile_size.y + 32)

	var card := CardWidget.new()
	card.setup(cd.id, tile_size)
	card.clicked.connect(func(_id: String): _open_zoom(index))
	card.right_clicked.connect(func(id: String): _remove(id))
	var n := _count_of(cd.id)
	if n > 0:
		card.set_highlight(UITheme.GOLD if n >= BSS.MAX_COPIES else UITheme.CORE)
	Motion.hover_lift(card, 1.04)
	box.add_child(card)

	# Copies in the deck as core gems (0.16.0): lit for each copy, gold when
	# the limit is reached, with "-" and "+" either side.
	var row := UITheme.hbox(2)
	row.custom_minimum_size = Vector2(0, 28)
	var minus := _count_button("−", func(): _remove(cd.id))
	minus.disabled = n == 0
	row.add_child(minus)
	var centre := CenterContainer.new()
	centre.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	centre.add_child(UITheme.pips(n, BSS.MAX_COPIES, 9.0 if tile_size.x < 130 else 10.0))
	row.add_child(centre)
	var plus := _count_button("+", func(): _add(cd.id))
	plus.disabled = n >= BSS.MAX_COPIES
	row.add_child(plus)
	box.add_child(row)
	return box


func _count_button(text: String, on_press: Callable) -> Button:
	var b := UITheme.button(text, on_press)
	b.custom_minimum_size = Vector2(30, 26)
	b.add_theme_font_size_override("font_size", UITheme.FS_BODY)
	var sb := UITheme._box(Color(UITheme.SURFACE_HI, 0.9), 4, Color(UITheme.LINE, 1.0))
	sb.set_content_margin_all(0)
	b.add_theme_stylebox_override("normal", sb)
	var hov := UITheme._box(UITheme.SURFACE_HI.lightened(0.08), 4, UITheme.GOLD_HI)
	hov.set_content_margin_all(0)
	b.add_theme_stylebox_override("hover", hov)
	var dis := UITheme._box(Color(UITheme.SURFACE, 0.5), 4, Color(UITheme.LINE, 0.5))
	dis.set_content_margin_all(0)
	b.add_theme_stylebox_override("disabled", dis)
	return b


func _build_pager() -> void:
	# Taken out of the row at once, not at the end of the frame (0.17.4,
	# R-104): rebuilt twice in one frame -- a right-click rebuilds the page --
	# the row held two or three headers side by side, and its width started
	# the layout growing.
	for c in _pager.get_children():
		_pager.remove_child(c)
		c.queue_free()
	_pager.add_child(UITheme.body("%d cards" % _results.size(), true, UITheme.FS_SMALL))
	_pager.add_child(UITheme.grow())
	var hint := UITheme.truncating("Click a card to inspect it · right-click to remove", true, UITheme.FS_SMALL)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pager.add_child(hint)
	_pager.add_child(UITheme.grow())
	var total := _pages()
	var prev := UITheme.button("‹", func(): _goto(_page - 1))
	prev.custom_minimum_size = Vector2(34, 30)
	prev.disabled = _page == 0
	_pager.add_child(prev)
	var label := UITheme.body("Page %d / %d" % [_page + 1, total], false, UITheme.FS_SMALL)
	label.custom_minimum_size = Vector2(90, 0)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pager.add_child(label)
	var nxt := UITheme.button("›", func(): _goto(_page + 1))
	nxt.custom_minimum_size = Vector2(34, 30)
	nxt.disabled = _page >= total - 1
	_pager.add_child(nxt)


func _goto(page: int) -> void:
	_page = clampi(page, 0, _pages() - 1)
	_show_page()
	_grid_scroll.scroll_vertical = 0


func _reflow() -> void:
	if _grid == null or _grid_scroll == null:
		return
	var cols := _columns()
	if _grid.columns != cols or (_grid.get_child_count() > 0 and \
			not (_grid.get_child(0) as Control).custom_minimum_size.x == _eff_tile().x):
		_grid.columns = cols
		if _grid.get_child_count() > 0:
			_show_page.call_deferred()      # tiles are sized for the new width


## 0.16.5: a page is 30 cards in complete rows, so the column count is the
## largest divisor of 30 that fits at the base tile size (10, 6, 5, 3, 2, 1).
func _columns() -> int:
	var tile: Vector2 = TILE_STEPS[_tile_step]
	var usable: float = maxf(tile.x, _grid_scroll.size.x - 14.0) if _grid_scroll != null else tile.x
	var fit := maxi(1, int((usable + UITheme.SP_S) / (tile.x + UITheme.SP_S)))
	for c in [10, 6, 5, 3, 2]:
		if fit >= c:
			return c
	return 1


## The tile size that fills the row: the base size grown (up to 40 %) so the
## chosen columns span the width.
func _eff_tile() -> Vector2:
	var tile: Vector2 = TILE_STEPS[_tile_step]
	if _grid_scroll == null or _grid_scroll.size.x < tile.x:
		return tile
	var cols := _columns()
	var usable: float = _grid_scroll.size.x - 14.0
	var w: float = floorf((usable - float(cols - 1) * UITheme.SP_S) / float(cols))
	w = clampf(w, tile.x, tile.x * 1.4)
	return Vector2(w, floorf(w * tile.y / tile.x))


func _open_zoom(index: int) -> void:
	var ids: Array = []
	for cd: CardData in _results:
		ids.append(cd.id)
	_zoom.open(ids, index, Callable(self, "_count_of"))


# ------------------------------------------------------------------- deck --
func _build_deck_pane() -> Control:
	var p := UITheme.panel(Vector2(DECK_W, 0))
	p.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var v := UITheme.vbox(UITheme.SP_S)
	p.add_child(v)

	v.add_child(UITheme.eyebrow("Deck", UITheme.GOLD))
	_deck_name = UITheme.line_edit("Deck name", str(_deck.get("name", "New Deck")))
	_deck_name.add_theme_font_size_override("font_size", UITheme.FS_HEAD)
	if UITheme.font("display") != null:
		_deck_name.add_theme_font_override("font", UITheme.font("display"))
	_deck_name.custom_minimum_size = Vector2(0, 46)
	_deck_name.text_changed.connect(func(t: String): _deck["name"] = t)
	v.add_child(_deck_name)

	_legality_slot = UITheme.hbox(UITheme.SP_S)
	v.add_child(_legality_slot)
	_deck_summary = UITheme.number("", UITheme.FS_SMALL, UITheme.TEXT_DIM)
	v.add_child(_deck_summary)

	v.add_child(UITheme.eyebrow("Cost curve"))
	_curve_box = UITheme.hbox(3)
	_curve_box.custom_minimum_size = Vector2(0, 58)
	v.add_child(_curve_box)
	v.add_child(UITheme.rule())

	var list_scroll := ScrollContainer.new()
	list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	list_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(list_scroll)
	_deck_list = UITheme.vbox(3)
	_deck_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_scroll.add_child(_deck_list)

	v.add_child(UITheme.rule())
	var actions := UITheme.hbox(UITheme.SP_S)
	var copy := UITheme.button("Copy list", _copy_text)
	copy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(copy)
	var clear := UITheme.danger_button("Clear", func():
		Modal.confirm(self, "Clear this deck?", "Removes every card from the list.",
			func():
				_deck["main"] = []
				_refresh_deck()
				_show_page(), "Clear", true))
	actions.add_child(clear)
	v.add_child(actions)
	return p


func _count_of(card_id: String) -> int:
	var n := 0
	for id in _deck.get("main", []):
		if str(id) == card_id:
			n += 1
	return n


func _add(card_id: String) -> void:
	var res: Dictionary = DeckManager.add_card(_deck, card_id)
	if not bool(res.get("ok", false)):
		AudioManager.play_sfx("error")
		set_status(str(res.get("reason", "Cannot add that card")), true)
	else:
		AudioManager.play_sfx("card_play")
		set_status("")
	_refresh_deck()
	_show_page()


func _remove(card_id: String) -> void:
	DeckManager.remove_card(_deck, card_id)
	_refresh_deck()
	_show_page()


## Grouped by card type with a header per group, as the reference does.
func _refresh_deck() -> void:
	for c in _deck_list.get_children():
		c.queue_free()

	var main: Array = _deck.get("main", [])
	var counts := {}
	for id in main:
		counts[id] = int(counts.get(id, 0)) + 1

	var groups := {"spirit": [], "nexus": [], "magic": []}
	for id in counts.keys():
		var cd: CardData = CardDB.get_card(str(id))
		if cd != null:
			groups[BSS.CARD_TYPE_NAMES[cd.card_type]].append(id)

	if main.is_empty():
		_deck_list.add_child(UITheme.paragraph(
			"Your deck is empty. Click + under any card on the left to add it, "
			+ "or click a card to inspect it first. A deck needs 50 to 60 cards, "
			+ "at most 4 of each.", true, UITheme.FS_SMALL))

	for type_name: String in ["spirit", "nexus", "magic"]:
		var ids: Array = groups[type_name]
		if ids.is_empty():
			continue
		ids.sort_custom(func(a, b):
			var ca: CardData = CardDB.get_card(str(a))
			var cb: CardData = CardDB.get_card(str(b))
			if ca == null or cb == null:
				return str(a) < str(b)
			if ca.cost != cb.cost:
				return ca.cost < cb.cost
			return ca.name < cb.name)
		var total := 0
		for id in ids:
			total += int(counts[id])
		var header := UITheme.hbox(UITheme.SP_S)
		header.custom_minimum_size = Vector2(0, 26)
		var h := UITheme.eyebrow(type_name, UITheme.ACCENT)
		h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		header.add_child(h)
		header.add_child(UITheme.body(str(total), false, UITheme.FS_SMALL))
		_deck_list.add_child(header)
		for id in ids:
			_deck_list.add_child(_deck_row(str(id), int(counts[id])))

	for c in _legality_slot.get_children():
		c.queue_free()
	var val: Dictionary = DeckManager.validate(_deck)
	var ok := bool(val.get("ok", false))
	var counter := UITheme.number("%d / 50" % main.size(), UITheme.FS_HEAD,
			UITheme.OK if ok else (UITheme.WARN if main.size() < 50 else UITheme.BAD))
	counter.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_legality_slot.add_child(counter)
	_legality_slot.add_child(UITheme.grow())
	_legality_slot.add_child(UITheme.pill(
		"Legal · ready to play" if ok else _short_reason(str(val.get("reason", "Not legal"))),
		UITheme.OK if ok else (UITheme.WARN if main.size() < 50 else UITheme.BAD)))
	Motion.count_up(counter, _last_count, main.size(), "%d / 50")
	_last_count = main.size()

	var st: Dictionary = DeckManager.stats(_deck)
	var types: Dictionary = st.get("types", {})
	_deck_summary.text = "%d spirit  ·  %d nexus  ·  %d magic" % [
		int(types.get("spirit", 0)), int(types.get("nexus", 0)), int(types.get("magic", 0))]
	_draw_curve(st.get("curve", {}))


func _short_reason(r: String) -> String:
	if r.begins_with("deck must contain"):
		return "Needs 50–60 cards"
	return r.capitalize() if r.length() < 30 else r.left(29) + "…"


## A decklist row as a card-art strip, like the reference: the art cropped to a
## banner, the cost on the left, name, copies, and add/remove.
func _deck_row(id: String, n: int) -> Control:
	var cd: CardData = CardDB.get_card(id)
	var strip := PanelContainer.new()
	strip.custom_minimum_size = Vector2(0, 44)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("#0b1020")
	sb.set_corner_radius_all(8)
	sb.set_border_width_all(1)
	sb.border_color = UITheme.BORDER
	sb.set_content_margin_all(0)
	strip.add_theme_stylebox_override("panel", sb)

	var art := TextureRect.new()
	art.texture = CardDB.get_card_art_texture(id)      # the art, not the middle of the face (0.18.0)
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	art.modulate = Color(1, 1, 1, 0.45)
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	strip.add_child(art)

	var row := UITheme.hbox(UITheme.SP_S)
	row.add_theme_constant_override("separation", 6)
	strip.add_child(row)
	row.add_child(UITheme.spacer(0))

	var cost := _cost_badge(cd.cost if cd != null else 0,
			UITheme.COLOR_SWATCH.get(int(cd.colors[0]), UITheme.TEXT_DIM) if cd != null and not cd.colors.is_empty() else UITheme.TEXT_DIM)
	row.add_child(cost)

	var name_btn := Button.new()
	name_btn.text = cd.name if cd != null else id
	name_btn.flat = true
	name_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	name_btn.clip_text = true
	name_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_btn.focus_mode = Control.FOCUS_NONE
	name_btn.add_theme_font_size_override("font_size", UITheme.FS_BODY - 1)
	if UITheme.font("semibold") != null:
		name_btn.add_theme_font_override("font", UITheme.font("semibold"))
	name_btn.add_theme_color_override("font_color", Color.WHITE)
	name_btn.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	name_btn.add_theme_constant_override("outline_size", 4)
	name_btn.tooltip_text = "%s · click to inspect" % id
	name_btn.pressed.connect(func(): _zoom_deck_card(id))
	row.add_child(name_btn)

	var count := UITheme.heading("×%d" % n, UITheme.FS_HEAD)
	count.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	count.add_theme_constant_override("outline_size", 4)
	count.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(count)

	var btns := UITheme.vbox(0)
	btns.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var plus := _tiny_button("+", UITheme.SUCCESS, func(): _add(id))
	plus.disabled = n >= BSS.MAX_COPIES
	btns.add_child(plus)
	btns.add_child(_tiny_button("−", UITheme.DANGER, func(): _remove(id)))
	row.add_child(btns)
	row.add_child(UITheme.spacer(0))
	return strip


func _cost_badge(cost: int, tint: Color) -> Control:
	var c := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.75)
	sb.set_corner_radius_all(15)
	sb.set_border_width_all(2)
	sb.border_color = tint
	sb.set_content_margin_all(0)
	c.add_theme_stylebox_override("panel", sb)
	c.custom_minimum_size = Vector2(30, 30)
	c.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var l := UITheme.body(str(cost), false, UITheme.FS_BODY)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if UITheme.font("bold") != null:
		l.add_theme_font_override("font", UITheme.font("bold"))
	c.add_child(l)
	return c


func _tiny_button(text: String, tint: Color, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(24, 19)
	var sb := StyleBoxFlat.new()
	sb.bg_color = tint.darkened(0.35)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(0)
	b.add_theme_stylebox_override("normal", sb)
	var hov := sb.duplicate() as StyleBoxFlat
	hov.bg_color = tint
	b.add_theme_stylebox_override("hover", hov)
	b.add_theme_stylebox_override("pressed", hov)
	var dis := sb.duplicate() as StyleBoxFlat
	dis.bg_color = Color(0.2, 0.2, 0.25, 0.6)
	b.add_theme_stylebox_override("disabled", dis)
	b.add_theme_font_size_override("font_size", 14)
	b.add_theme_color_override("font_color", Color.WHITE)
	b.pressed.connect(func():
		AudioManager.play_sfx("ui_click")
		on_press.call())
	return b


## The inspector pages through the deck's own cards when opened from the list.
func _zoom_deck_card(card_id: String) -> void:
	var ids: Array = []
	var seen := {}
	for id in _deck.get("main", []):
		if not seen.has(id):
			seen[id] = true
			ids.append(str(id))
	_zoom.open(ids, maxi(0, ids.find(card_id)), Callable(self, "_count_of"))


func _draw_curve(curve: Dictionary) -> void:
	for c in _curve_box.get_children():
		c.queue_free()
	var peak := 1
	for k in curve:
		peak = maxi(peak, int(curve[k]))
	for cost in range(0, 9):
		var n := 0
		if cost == 8:
			for k in curve:
				if int(k) >= 8:
					n += int(curve[k])
		else:
			n = int(curve.get(cost, curve.get(str(cost), 0)))
		var col := UITheme.vbox(2)
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.alignment = BoxContainer.ALIGNMENT_END
		if n > 0:
			var num := UITheme.body(str(n), true, UITheme.FS_TINY)
			num.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			col.add_child(num)
		var bar := PanelContainer.new()
		var tint := _dominant_colour_at_cost(cost)
		var sb := UITheme._box(Color(tint, 0.75) if n > 0 else Color(UITheme.LINE, 0.6), 2,
				tint.lightened(0.3) if n > 0 else Color(0, 0, 0, 0), 1 if n > 0 else 0)
		sb.set_content_margin_all(0)
		bar.add_theme_stylebox_override("panel", sb)
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bar.custom_minimum_size = Vector2(0, maxf(2.0, 30.0 * float(n) / float(peak)))
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.add_child(bar)
		var lbl := UITheme.body(("%d+" % cost) if cost == 8 else str(cost), true, UITheme.FS_TINY)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		col.add_child(lbl)
		_curve_box.add_child(col)


## The colour most of the deck's cards at this cost share (8 = 8 and up).
func _dominant_colour_at_cost(cost: int) -> Color:
	var tally := {}
	for id in _deck.get("main", []):
		var cd: CardData = CardDB.get_card(str(id))
		if cd == null or cd.colors.is_empty():
			continue
		if (cost == 8 and cd.cost >= 8) or cd.cost == cost:
			var c := int(cd.colors[0])
			tally[c] = int(tally.get(c, 0)) + 1
	var best := -1
	var best_n := 0
	for c in tally:
		if int(tally[c]) > best_n:
			best_n = int(tally[c])
			best = int(c)
	return UITheme.COLOR_SWATCH.get(best, UITheme.CORE) if best >= 0 else UITheme.CORE


func _save() -> void:
	_deck["name"] = _deck_name.text.strip_edges()
	if _deck["name"] == "":
		_deck["name"] = "New Deck"
	if (_deck.get("main", []) as Array).is_empty():
		set_status("Add some cards before saving.", true)
		return
	DeckManager.save(_deck)
	_saved_snapshot = JSON.stringify(_deck.get("main", [])) + str(_deck.get("name", ""))
	var legal := bool(DeckManager.validate(_deck).get("ok", false))
	set_status("Saved \"%s\"%s" % [_deck["name"],
			"" if legal else " · not legal yet, so it will not appear in Battle"])


func _copy_text() -> void:
	DisplayServer.clipboard_set(DeckManager.to_text(_deck))
	set_status("Decklist copied to clipboard")
