extends RefCounted
class_name QuickSettings
## The settings you may want during a battle (0.24.0): sound, animations and
## a few play aids, in a window over the board -- opened with the gear
## button next to Concede. Same values as Settings, saved the same way; the
## game keeps running underneath (online games cannot pause).


static func open(host: Node) -> Modal:
	var m := Modal.open(host, "Settings", 600.0)
	m.body.add_child(UITheme.eyebrow("Audio", UITheme.GOLD))
	m.body.add_child(_slider("Music volume", GameConfig.music_volume, func(v: float):
		GameConfig.music_volume = v
		GameConfig.save_settings()))
	m.body.add_child(_slider("Sound effects", GameConfig.sfx_volume, func(v: float):
		GameConfig.sfx_volume = v
		GameConfig.save_settings()
		AudioManager.play_sfx("ui_click")))
	m.body.add_child(UITheme.toggle_row("Mute everything", GameConfig.mute, func(on: bool):
		GameConfig.mute = on
		GameConfig.save_settings()))
	m.body.add_child(UITheme.rule())
	m.body.add_child(UITheme.eyebrow("Battle", UITheme.GOLD))
	m.body.add_child(_slider("Animation speed", GameConfig.card_animation_speed, func(v: float):
		GameConfig.card_animation_speed = v
		GameConfig.save_settings(), 0.25, 2.5))
	m.body.add_child(UITheme.toggle_row("Battle animations", GameConfig.battle_animations, func(on: bool):
		GameConfig.battle_animations = on
		GameConfig.save_settings()))
	m.body.add_child(UITheme.toggle_row("Auto-pass flash windows when I have no legal response",
		GameConfig.auto_pass_empty_flash, func(on: bool):
			GameConfig.auto_pass_empty_flash = on
			GameConfig.save_settings()))
	m.body.add_child(UITheme.toggle_row("Confirm before declaring an attack", GameConfig.confirm_attacks,
		func(on: bool):
			GameConfig.confirm_attacks = on
			GameConfig.save_settings()))
	m.body.add_child(UITheme.toggle_row("Show card tooltips", GameConfig.show_card_tooltips, func(on: bool):
		GameConfig.show_card_tooltips = on
		GameConfig.save_settings()))
	m.buttons.add_child(UITheme.paragraph("Everything else is in Settings on the main menu.", true, UITheme.FS_SMALL))
	m.buttons.add_child(UITheme.grow())
	var done := UITheme.primary_button("Done", m.close)
	done.custom_minimum_size = Vector2(130, 44)
	m.buttons.add_child(done)
	return m


static func _slider(label: String, value: float, on_change: Callable, vmin: float = 0.0, vmax: float = 1.0) -> Control:
	var h := UITheme.hbox(10)
	h.custom_minimum_size = Vector2(0, 38)
	var l := UITheme.body(label)
	l.custom_minimum_size = Vector2(170, 0)
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(l)
	var s := HSlider.new()
	s.min_value = vmin
	s.max_value = vmax
	s.step = 0.05
	s.value = value
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.custom_minimum_size = Vector2(220, 24)
	var readout := UITheme.number("%d%%" % roundi(value * 100.0) if vmax <= 1.0 else "%.2f×" % value,
			UITheme.FS_BODY, UITheme.TEXT_DIM)
	readout.custom_minimum_size = Vector2(56, 0)
	readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	readout.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.value_changed.connect(func(v: float):
		readout.text = "%d%%" % roundi(v * 100.0) if vmax <= 1.0 else "%.2f×" % v
		on_change.call(v))
	h.add_child(s)
	h.add_child(readout)
	return h


## A small gear drawn in code (no picture file), white on transparent.
static var _gear: Texture2D = null

static func gear_icon() -> Texture2D:
	if _gear != null:
		return _gear
	var n := 40
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var c := Vector2(n * 0.5, n * 0.5)
	for y in n:
		for x in n:
			var cov := 0.0
			for sy in 3:                       # 3x3 supersampling for smooth edges
				for sx in 3:
					var p := Vector2(x + (sx + 0.5) / 3.0, y + (sy + 0.5) / 3.0) - c
					var r := p.length()
					var a := atan2(p.y, p.x)
					var tooth := 0.5 + 0.5 * cos(a * 8.0)
					var outer := 15.0 + 4.0 * clampf((tooth - 0.35) * 3.0, 0.0, 1.0)
					if r <= outer and r >= 5.5:
						cov += 1.0
			img.set_pixel(x, y, Color(1, 1, 1, cov / 9.0))
	_gear = ImageTexture.create_from_image(img)
	return _gear
