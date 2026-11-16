extends Control
class_name Modal
##
## An in-screen dialog: a dimmed backdrop with a centred panel.
##
## Replaces Godot's AcceptDialog / ConfirmationDialog, which open as separate
## windows with the engine's default look and sit outside the game's theme.
## Built on anchors, added as the last child of the screen so it draws on top,
## and it swallows input behind it while open.
##
##   Modal.confirm(self, "Concede?", "This ends the game.", on_yes)
##   Modal.text_input(self, "Import deck", "Paste a list…", on_ok)
##   var m := Modal.open(self, "Game over"); m.body.add_child(...)
##

var body: VBoxContainer
var buttons: HBoxContainer


static func open(host: Node, title: String, width: float = 520.0) -> Modal:
	var m := Modal.new()
	m._build(title, width)
	host.add_child(m)
	return m


static func confirm(host: Node, title: String, text: String, on_yes: Callable,
		yes_label: String = "Confirm", danger: bool = false) -> Modal:
	var m := open(host, title)
	m.body.add_child(UITheme.paragraph(text, true))
	m.buttons.add_child(UITheme.grow())
	m.buttons.add_child(UITheme.button("Cancel", m.close))
	var yes := UITheme.danger_button(yes_label) if danger else UITheme.primary_button(yes_label)
	yes.custom_minimum_size = Vector2(150, 44)
	yes.pressed.connect(func():
		m.close()
		on_yes.call())
	m.buttons.add_child(yes)
	return m


static func text_input(host: Node, title: String, placeholder: String,
		on_ok: Callable, ok_label: String = "OK") -> Modal:
	var m := open(host, title, 640.0)
	var edit := TextEdit.new()
	edit.placeholder_text = placeholder
	edit.custom_minimum_size = Vector2(0, 260)
	m.body.add_child(edit)
	m.buttons.add_child(UITheme.grow())
	m.buttons.add_child(UITheme.button("Cancel", m.close))
	var ok := UITheme.primary_button(ok_label)
	ok.custom_minimum_size = Vector2(150, 44)
	ok.pressed.connect(func():
		var t := edit.text
		m.close()
		on_ok.call(t))
	m.buttons.add_child(ok)
	# in the browser a real browser text box goes over the TextEdit, so
	# pasting works inside the itch.io page too (0.24.0, R-135)
	if WebTextOverlay.attach(edit) == null:
		edit.grab_focus.call_deferred()
	return m


func _build(title: String, width: float) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 100

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.62)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var panel := UITheme.hero_panel(Vector2(width, 0))
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -width * 0.5
	panel.offset_right = width * 0.5
	panel.offset_top = -180
	panel.offset_bottom = 180
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	# 0.25.0 (R-178): content wider than asked grows the panel on both sides,
	# never only to the right (the Ascend choice with many spirits ran off the
	# window and hid its buttons); _fit() shrinks it to the window if needed
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	add_child(panel)
	_panel = panel

	var v := UITheme.vbox(UITheme.SP_M)
	panel.add_child(v)
	v.add_child(UITheme.display_title(title, UITheme.FS_HEAD))
	v.add_child(UITheme.gold_rule(140.0))
	body = UITheme.vbox(UITheme.SP_S)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(body)
	buttons = UITheme.hbox(UITheme.SP_S)
	v.add_child(buttons)
	# Fades up over 150 ms (0.16.0); the backdrop never blocks the click that
	# would close it.
	panel.resized.connect(func(): _fit.call_deferred())
	ready.connect(func():
		_fit.call_deferred()
		if Motion.enabled():
			dim.modulate.a = 0.0
			var tw := create_tween().set_parallel()
			tw.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
			tw.tween_property(dim, "modulate:a", 1.0, 0.15)
			panel.modulate.a = 0.0
			tw.tween_property(panel, "modulate:a", 1.0, 0.15)
			tw.chain().tween_callback(_fit))


var _panel: Control


## Keeps the whole panel -- its buttons above all -- inside the window: a
## panel bigger than the window is scaled down to fit (R-178).
func _fit() -> void:
	if _panel == null or not is_instance_valid(_panel) or not is_inside_tree():
		return
	var view := get_viewport_rect().size
	var need := _panel.get_combined_minimum_size()
	need.x = maxf(need.x, _panel.size.x)
	need.y = maxf(need.y, _panel.size.y)
	var k := minf(1.0, minf((view.x - 32.0) / maxf(1.0, need.x), (view.y - 32.0) / maxf(1.0, need.y)))
	_panel.pivot_offset = _panel.size * 0.5
	_panel.scale = Vector2(k, k)
	fitted_scale = k


## The scale _fit() chose (1 = no shrinking needed); read by the tests.
var fitted_scale := 1.0


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _panel != null:
		_fit.call_deferred()


func close() -> void:
	queue_free()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
