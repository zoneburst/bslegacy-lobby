extends PanelContainer
class_name CardWidget
##
## One card, anywhere it appears: deck editor grid, zoom, hand, field, trash.
##
## setup(id, size)            a card face
## setup(id, size, live)      a card in play: adds level, BP, cores and
##                            exhausted state from the engine snapshot
## setup_back(size)           a face-down card (opponent's hand, deck)
##
## WHAT CHANGED IN 0.6.0
## The old widget always printed the card's name and cost over the art. The
## generated card faces already carry both, so every card showed its name twice
## and the overlay clipped the face's own text. The name overlay now appears
## ONLY when no art could be found -- the placeholder swatch -- and live state is
## drawn as compact badges that stay out of the card's printed text.
##
## Rotation for exhausted cards is not done here. A Container owns its
## children's transform, so rotating a card inside an HBox fights the layout
## (see architecture guide 11.9). The board wraps exhausted cards in a holder
## sized for the rotated card instead.
##

signal clicked(card_id: String)
signal right_clicked(card_id: String)
signal hovered(card_id: String)

const SIZE_SMALL := Vector2(96, 134)
const SIZE_MEDIUM := Vector2(124, 174)
const SIZE_LARGE := Vector2(220, 308)

var card_id: String = ""
var uid: int = -1
var live: Dictionary = {}
var face_down := false

var _frame: StyleBoxFlat
var _art: TextureRect
var _name_label: Label
var _badges: Control
var _highlight := Color(0, 0, 0, 0)
var _shade: Control = null
var unplayable := false


func setup(id: String, card_size: Vector2 = SIZE_MEDIUM, live_state: Dictionary = {}) -> void:
	card_id = id
	live = live_state
	uid = int(live_state.get("uid", -1))
	face_down = false
	_build(card_size)
	_art.texture = CardDB.get_card_texture(id)
	_refresh()


func setup_back(card_size: Vector2 = SIZE_SMALL) -> void:
	card_id = ""
	face_down = true
	_build(card_size)
	_art.texture = back_texture()
	mouse_filter = Control.MOUSE_FILTER_IGNORE


static var _back_tex: Texture2D = null

## The card back: user://assets/ui/card_back.png when present (no rebuild
## needed, as the asset guide promises -- before 0.10.0 only the res:// copy
## was ever read), otherwise the bundled one. Loaded once.
static func back_texture() -> Texture2D:
	if _back_tex != null:
		return _back_tex
	var user_path := "user://assets/ui/card_back.png"
	if FileAccess.file_exists(user_path):
		var img := Image.load_from_file(user_path)
		if img != null and not img.is_empty():
			img.generate_mipmaps()
			_back_tex = ImageTexture.create_from_image(img)
			return _back_tex
	if ResourceLoader.exists("res://assets/ui/card_back.png"):
		_back_tex = load("res://assets/ui/card_back.png")
	return _back_tex


## Coloured outline for "you can act on this" (gold), "selected" (blue),
## "attacking" (red). Transparent clears it.
func set_highlight(col: Color) -> void:
	_highlight = col
	if _frame == null:
		return
	if col.a > 0.0:
		_frame.border_color = col
		_frame.set_border_width_all(3)
		_frame.shadow_color = Color(col, 0.55)
		_frame.shadow_size = 10
	else:
		_frame.border_color = Color(1, 1, 1, 0.18)
		_frame.set_border_width_all(1)
		_frame.shadow_color = Color(0, 0, 0, 0.5)
		_frame.shadow_size = 4


## Darken a card that cannot be played right now (0.8.0): a dark veil with a
## heavier shadow at the bottom, so the playable cards stand out in the hand
## at a glance. The card still shows its preview when hovered.
func set_unplayable(on: bool) -> void:
	unplayable = on
	if _shade != null and is_instance_valid(_shade):
		_shade.queue_free()
		_shade = null
	if not on:
		return
	var veil := TextureRect.new()
	veil.texture = _veil_texture()
	veil.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	veil.stretch_mode = TextureRect.STRETCH_SCALE
	veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(veil)
	_shade = veil
	if _frame != null:
		_frame.shadow_color = Color(0, 0, 0, 0.75)
		_frame.shadow_size = 10
		_frame.shadow_offset = Vector2(0, 4)


static var _veil: Texture2D = null


## A vertical gradient: 50% black at the top to 72% at the bottom.
static func _veil_texture() -> Texture2D:
	if _veil == null:
		var g := Gradient.new()
		g.set_color(0, Color(0.02, 0.02, 0.05, 0.50))
		g.set_color(1, Color(0.0, 0.0, 0.02, 0.72))
		var gt := GradientTexture2D.new()
		gt.gradient = g
		gt.fill_from = Vector2(0, 0)
		gt.fill_to = Vector2(0, 1)
		gt.width = 4
		gt.height = 64
		_veil = gt
	return _veil


func _build(card_size: Vector2) -> void:
	for c in get_children():
		c.queue_free()
	custom_minimum_size = card_size
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	_frame = StyleBoxFlat.new()
	_frame.bg_color = Color("#0b1020")
	_frame.set_corner_radius_all(int(maxf(4.0, card_size.x * 0.05)))
	_frame.set_border_width_all(1)
	_frame.border_color = Color(1, 1, 1, 0.18)
	_frame.shadow_color = Color(0, 0, 0, 0.5)
	_frame.shadow_size = 4
	_frame.set_content_margin_all(2)
	_frame.anti_aliasing = true
	add_theme_stylebox_override("panel", _frame)

	_art = TextureRect.new()
	_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	# Card faces are 600 x 838 and are shown as small as 52 px wide; sampling
	# from mipmaps keeps them smooth instead of jagged (0.8.0).
	_art.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_art)

	_name_label = Label.new()
	_name_label.visible = false
	_name_label.add_theme_font_size_override("font_size", int(clampf(card_size.x * 0.10, 10, 16)))
	_name_label.add_theme_color_override("font_color", UITheme.TEXT)
	_name_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_name_label.add_theme_constant_override("outline_size", 4)
	_name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_name_label)

	# Badges are absolutely positioned inside a plain Control, which the
	# PanelContainer stretches over the card -- so badge placement is ours and
	# no container can rearrange it.
	_badges = Control.new()
	_badges.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_badges)
	set_highlight(_highlight)


func _refresh() -> void:
	var cd: CardData = CardDB.get_card(card_id)
	if cd == null:
		_name_label.text = card_id
		_name_label.visible = true
		return

	# Only label the card when it is showing the fallback swatch.
	if not CardDB.has_art(card_id):
		_name_label.text = "%s\n\n%d" % [cd.name, cd.cost]
		_name_label.visible = true

	if not live.is_empty():
		_build_live_badges(cd)
	if GameConfig.show_card_tooltips and live.is_empty():
		tooltip_text = "%s  (%s)" % [cd.name, cd.id]


func _build_live_badges(cd: CardData) -> void:
	var exhausted := int(live.get("orient", 0)) == BSS.Orientation.EXHAUSTED
	modulate = Color(0.72, 0.72, 0.78) if exhausted else Color.WHITE

	if cd.is_spirit():
		# BP banner across the bottom: the number that decides every battle.
		var bar := PanelContainer.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0, 0, 0, 0.78)
		sb.set_corner_radius_all(4)
		sb.content_margin_left = 4
		sb.content_margin_right = 4
		bar.add_theme_stylebox_override("panel", sb)
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bar.add_child(row)
		var lv := Label.new()
		lv.text = "LV%d" % int(live.get("level", 1))
		lv.add_theme_font_size_override("font_size", 11)
		lv.add_theme_color_override("font_color", UITheme.ACCENT)
		row.add_child(lv)
		var bp := Label.new()
		_bp_label = bp
		_lv_label = lv
		_bp_bar = bar
		bp.text = "%d" % int(live.get("bp", 0))
		bp.add_theme_font_size_override("font_size", 13)
		bp.add_theme_color_override("font_color", Color.WHITE)
		bp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bp.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		if UITheme.font("bold") != null:
			bp.add_theme_font_override("font", UITheme.font("bold"))
		row.add_child(bp)
		bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
		bar.offset_left = 3
		bar.offset_right = -3
		bar.offset_top = -24
		bar.offset_bottom = -3
		_badges.add_child(bar)

	# Cores on the card, top-left, as gems (larger since 0.22.0, so they can
	# be grabbed and dragged).
	var gems := CoreGems.new()
	gems.radius = clampf(custom_minimum_size.x * 0.095, 6.5, 10.0)
	gems.max_drawn = 5
	gems.set_counts(int(live.get("cores", 0)), int(live.get("soul", 0)))
	gems.position = Vector2(5, 5)
	_badges.add_child(gems)
	_gems = gems
	_animate_changes(cd)

	if exhausted:
		var tag := Label.new()
		tag.text = "EXHAUSTED"
		tag.add_theme_font_size_override("font_size", 10)
		tag.add_theme_color_override("font_color", Color.WHITE)
		tag.add_theme_color_override("font_outline_color", Color(0, 0, 0))
		tag.add_theme_constant_override("outline_size", 4)
		tag.set_anchors_preset(Control.PRESET_CENTER)
		tag.offset_left = -34
		tag.offset_right = 34
		tag.offset_top = -8
		tag.offset_bottom = 8
		tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_badges.add_child(tag)


var _gems: CoreGems = null
var _bp_label: Label = null
var _lv_label: Label = null
var _bp_bar: Control = null


## The gems drawn on this card (null for a card with no live state).
func core_gems() -> CoreGems:
	return _gems


## 0.22.0: when this card's numbers changed since the board last showed it
## (live["_prev"], filled in by the board), they move instead of jumping: the
## BP counts up or down with a pop -- green going up, red going down -- the
## level flashes gold when it changes, and a new core pops in.
func _animate_changes(cd: CardData) -> void:
	var prev: Dictionary = live.get("_prev", {})
	if prev.is_empty() or not cd.is_spirit():
		return
	var delay := float(live.get("_anim_delay", 0.0))
	var bp0 := int(prev.get("bp", 0))
	var bp1 := int(live.get("bp", 0))
	var lv0 := int(prev.get("level", 0))
	var lv1 := int(live.get("level", 0))
	var t := create_tween()
	t.tween_interval(delay)
	if bp0 != bp1 and _bp_label != null:
		var lab := _bp_label
		var bar := _bp_bar
		lab.text = "%d" % bp0
		var up := bp1 > bp0
		var flash := Color("#7dffa0") if up else Color("#ff7a7a")
		t.tween_callback(func() -> void:
			if is_instance_valid(bar):
				bar.pivot_offset = bar.size * 0.5
			if is_instance_valid(lab):
				lab.add_theme_color_override("font_color", flash))
		t.tween_method(func(v: float) -> void:
			if is_instance_valid(lab):
				lab.text = "%d" % int(round(v / 100.0) * 100.0),
			float(bp0), float(bp1), 0.45).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		t.parallel().tween_property(bar, "scale", Vector2(1.18, 1.18), 0.16).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		t.tween_property(bar, "scale", Vector2.ONE, 0.22)
		t.tween_interval(0.25)
		t.tween_callback(func() -> void:
			if is_instance_valid(lab):
				lab.text = "%d" % bp1
				lab.add_theme_color_override("font_color", Color.WHITE))
	if lv0 != lv1 and _lv_label != null:
		var lv := _lv_label
		lv.pivot_offset = Vector2(14, 8)
		var t2 := create_tween()
		t2.tween_interval(delay)
		t2.tween_callback(func() -> void:
			if is_instance_valid(lv):
				lv.add_theme_color_override("font_color", Color("#ffe08a")))
		t2.tween_property(lv, "scale", Vector2(1.5, 1.5), 0.14).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		t2.tween_property(lv, "scale", Vector2.ONE, 0.24)
		t2.tween_interval(0.3)
		t2.tween_callback(func() -> void:
			if is_instance_valid(lv):
				lv.add_theme_color_override("font_color", UITheme.ACCENT))


func _gui_input(event: InputEvent) -> void:
	if face_down:
		return
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			clicked.emit(card_id)
			accept_event()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			right_clicked.emit(card_id)
			accept_event()


func _notification(what: int) -> void:
	if face_down:
		return
	if what == NOTIFICATION_MOUSE_ENTER:
		hovered.emit(card_id)
		if _highlight.a == 0.0 and _frame != null:
			_frame.border_color = Color(1, 1, 1, 0.55)
	elif what == NOTIFICATION_MOUSE_EXIT:
		set_highlight(_highlight)
