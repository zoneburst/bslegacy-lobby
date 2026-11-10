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
	add_child(panel)

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
	ready.connect(func():
		if Motion.enabled():
			dim.modulate.a = 0.0
			var tw := create_tween().set_parallel()
			tw.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
			tw.tween_property(dim, "modulate:a", 1.0, 0.15)
			panel.pivot_offset = Vector2(width * 0.5, 180.0)
			panel.scale = Vector2(0.97, 0.97)
			panel.modulate.a = 0.0
			tw.tween_property(panel, "scale", Vector2.ONE, 0.18)
			tw.tween_property(panel, "modulate:a", 1.0, 0.15))


func close() -> void:
	queue_free()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
