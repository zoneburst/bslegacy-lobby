extends Control
class_name CardZoom
##
## Full-screen card inspector: large art on the left, printed detail on the
## right, add/remove controls, and previous/next through whatever list opened
## it.
##
## Built entirely on anchors rather than nested containers. This overlay sits
## above a live screen, so it must have a real rect from its first frame
## regardless of what the screen underneath is doing with its layout -- the
## lesson from R-012.
##

signal add_requested(card_id: String)
signal remove_requested(card_id: String)
signal closed()

var _ids: Array = []
var _index: int = 0
var _count_source: Callable

var _art: TextureRect
var _title: Label
var _subtitle: Label
var _count_label: Label
var _detail: VBoxContainer


func open(ids: Array, start_index: int, count_source: Callable) -> void:
	_ids = ids
	_index = clampi(start_index, 0, maxi(0, ids.size() - 1))
	_count_source = count_source
	visible = true
	_refresh()


func _ready() -> void:
	# set_anchors_AND_OFFSETS_preset, not set_anchors_preset. This node is
	# already in the tree when _ready runs, and set_anchors_preset keeps the
	# node's current rectangle -- which was 0x0 -- by compensating the offsets
	# to -1600/-900. The overlay was zero-sized: no dimmed backdrop, and the
	# panel shrank to its minimum (R-026, found by the 0.6.0 screen tour).
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.72)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	# Opaque and sized to its content, centred. The shared panel colour is
	# slightly translucent, which let the card grid ghost through the text.
	var panel := UITheme.hero_panel()
	var sb := UITheme._panel_box(Color("#141828"), Color(UITheme.GOLD, 0.85))
	sb.set_content_margin_all(UITheme.SP_L)
	panel.add_theme_stylebox_override("panel", sb)
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -560
	panel.offset_right = 560
	panel.offset_top = -330
	panel.offset_bottom = 330
	add_child(panel)

	var row := UITheme.hbox(UITheme.SP_L)
	panel.add_child(row)

	_art = TextureRect.new()
	_art.custom_minimum_size = Vector2(430, 602)
	_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	row.add_child(_art)

	var right := UITheme.vbox(UITheme.SP_S)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(right)

	var head := UITheme.hbox(UITheme.SP_S)
	right.add_child(head)
	_title = UITheme.heading("", UITheme.FS_TITLE - 2)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title)
	head.add_child(UITheme.ghost_button("Close  ✕", _close))

	_subtitle = UITheme.body("", true, UITheme.FS_SMALL)
	right.add_child(_subtitle)
	right.add_child(UITheme.rule())

	var controls := UITheme.hbox(UITheme.SP_S)
	right.add_child(controls)
	var minus := UITheme.button("-  Remove", _on_remove)
	minus.custom_minimum_size = Vector2(120, 38)
	controls.add_child(minus)
	_count_label = UITheme.number("0 / 4", UITheme.FS_HEAD)
	_count_label.custom_minimum_size = Vector2(90, 0)
	_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	controls.add_child(_count_label)
	var plus := UITheme.button("+  Add", _on_add)
	plus.custom_minimum_size = Vector2(120, 38)
	controls.add_child(plus)
	controls.add_child(UITheme.grow())
	controls.add_child(UITheme.button("< Prev", func(): step(-1)))
	controls.add_child(UITheme.button("Next >", func(): step(1)))

	right.add_child(UITheme.rule())
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(scroll)
	_detail = UITheme.vbox(UITheme.SP_S)
	_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_detail)


func _close() -> void:
	visible = false
	closed.emit()


func _on_add() -> void:
	add_requested.emit(current_id())
	_refresh()


func _on_remove() -> void:
	remove_requested.emit(current_id())
	_refresh()


func current_id() -> String:
	return str(_ids[_index]) if _index >= 0 and _index < _ids.size() else ""


func step(by: int) -> void:
	if _ids.is_empty():
		return
	_index = wrapi(_index + by, 0, _ids.size())
	AudioManager.play_sfx("ui_click")
	_refresh()


func refresh_count() -> void:
	if visible:
		_refresh()


func _refresh() -> void:
	var id := current_id()
	var cd: CardData = CardDB.get_card(id)
	if cd == null:
		return
	_art.texture = CardDB.get_card_texture(id)
	_title.text = cd.name
	var type_name: String = str(BSS.CARD_TYPE_NAMES[cd.card_type]).capitalize()
	var sub_types: String = "-"
	if not cd.spirit_types.is_empty():
		sub_types = ", ".join(cd.spirit_types)
	_subtitle.text = "%s   ·   %s   ·   %s" % [id, type_name, sub_types]
	if _count_source.is_valid():
		_count_label.text = "%d / %d" % [int(_count_source.call(id)), BSS.MAX_COPIES]

	for c in _detail.get_children():
		c.queue_free()

	var rarity: String = cd.rarity
	if rarity == "":
		rarity = "-"
	_detail.add_child(_stat_row("Cost", str(cd.cost)))
	_detail.add_child(_stat_row("Reduction", str(cd.reduction_symbols.size())))
	_detail.add_child(_stat_row("Symbols", str(cd.symbols.size())))
	_detail.add_child(_stat_row("Rarity", rarity))

	if not cd.levels.is_empty():
		_detail.add_child(UITheme.rule())
		_detail.add_child(UITheme.body("Levels", true, UITheme.FS_SMALL))
		for lv: Dictionary in cd.levels:
			var bp: int = int(lv.get("bp", 0))
			var level_no: int = int(lv.get("level", 0))
			var core_cost: int = int(lv.get("core_cost", 0))
			var plural: String = "" if core_cost == 1 else "s"
			var left: String = "LV %d  (%d core%s)" % [level_no, core_cost, plural]
			var right: String = "-"
			if bp > 0:
				right = "BP %d" % bp
			_detail.add_child(_stat_row(left, right))

	if cd.text != "":
		_detail.add_child(UITheme.rule())
		_detail.add_child(UITheme.body("Effects", true, UITheme.FS_SMALL))
		_detail.add_child(UITheme.card_text(cd.text))


func _stat_row(label: String, value: String) -> Control:
	var r := UITheme.hbox(UITheme.SP_S)
	var l := UITheme.body(label, true)
	l.custom_minimum_size = Vector2(180, 0)
	r.add_child(l)
	var v := UITheme.body(value)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.add_child(v)
	return r


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel"):
		_close()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_right"):
		step(1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_left"):
		step(-1)
		get_viewport().set_input_as_handled()
