extends RefCounted
class_name Motion
##
## The menu animation language (0.16.0): a dozen small, eased, non-blocking
## effects that every screen shares, so nothing is hand-rolled twice.
##
##   hover_lift(control)         scale 1 -> 1.04 on hover, 120 ms out, 100 ms back
##   press_feedback(button)      0.97 on press, back out with a little overshoot
##   stagger_in(children)        fade in a list of controls, 30 ms apart
##   glint(control)              a gold band sweeps along the control once per hover
##   pulse(control)              alpha 0.4 <-> 1 loop, 2.4 s ("click to start")
##   breathe(control)            alpha 0.35 <-> 0.55 loop, 3 s (soul-core glow)
##   count_up(label, from, to)   number tick, 400 ms, tween_method
##   enter_screen(root)          alpha 0 -> 1 over 250 ms when a screen opens
##   parallax(bg)                mouse parallax on the background shader
##   embers(parent)              drifting gold particles (title and home only)
##
## RULES
## - Nothing here blocks input, and every duration is 60-300 ms except the
##   slow idle loops, which never loop faster than 2.4 s.
## - "Reduce motion" (GameConfig.reduce_motion) turns the idle loops, embers
##   and parallax off and makes everything else instant: enabled() says so.
## - Everything is safe headless and in tests: every helper checks the node
##   is inside the tree before creating a Tween on it, and a helper that is
##   skipped leaves the control in its resting state (alpha 1, scale 1).
## - Containers own their children's position and size (architecture guide
##   11.9), so these helpers animate scale, modulate and draw state only --
##   never position.
##

const LIFT := 1.04
const T_IN := 0.12
const T_OUT := 0.10
const T_PRESS := 0.06
const T_RELEASE := 0.14
const T_ENTER := 0.22
const T_STAGGER := 0.03
const T_STAGGER_CAP := 0.30
const T_SCREEN := 0.25
const T_COUNT := 0.40
const T_GLINT := 0.45
const LOOP_PULSE := 2.4
const LOOP_BREATHE := 3.0


static func enabled() -> bool:
	return not GameConfig.reduce_motion


static func _live(c: CanvasItem) -> bool:
	return c != null and is_instance_valid(c) and c.is_inside_tree()


## Kills the tween a helper stored on `c` under `key`, so a hover-out never
## fights a hover-in still running.
static func _kill(c: Node, key: String) -> void:
	if c.has_meta(key):
		var old: Tween = c.get_meta(key)
		if old != null and old.is_valid():
			old.kill()
		c.remove_meta(key)


static func _scale_to(c: Control, s: float, dur: float, trans: int = Tween.TRANS_CUBIC,
		ease_kind: int = Tween.EASE_OUT) -> void:
	if not _live(c):
		return
	c.pivot_offset = c.size * 0.5
	_kill(c, "_m_scale")
	if not enabled():
		c.scale = Vector2.ONE
		return
	var tw := c.create_tween()
	tw.set_trans(trans).set_ease(ease_kind)
	tw.tween_property(c, "scale", Vector2(s, s), dur)
	c.set_meta("_m_scale", tw)


## 1. Hover lift. Scale only: the y nudge in the brief would be undone by any
## container the control sits in.
static func hover_lift(c: Control, amount: float = LIFT) -> void:
	if c == null:
		return
	c.mouse_entered.connect(func(): _scale_to(c, amount, T_IN))
	c.mouse_exited.connect(func(): _scale_to(c, 1.0, T_OUT))


## 2. Press: squash on button_down, overshoot back on release.
static func press_feedback(b: BaseButton) -> void:
	if b == null:
		return
	b.button_down.connect(func(): _scale_to(b, 0.97, T_PRESS, Tween.TRANS_QUAD))
	b.button_up.connect(func():
		var rest := LIFT if b.is_hovered() else 1.0
		_scale_to(b, rest, T_RELEASE, Tween.TRANS_BACK))


## 4. Staggered entrance: alpha 0 -> 1, 30 ms apart, the whole run capped at
## 300 ms so a long list never keeps the player waiting.
static func stagger_in(nodes: Array, step: float = T_STAGGER, dur: float = T_ENTER) -> void:
	if not enabled():
		return
	var i := 0
	for n: Variant in nodes:
		var c := n as CanvasItem
		if c == null or not _live(c):
			continue
		c.modulate.a = 0.0
		var tw := c.create_tween()
		tw.set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
		tw.tween_interval(minf(float(i) * step, T_STAGGER_CAP))
		tw.tween_property(c, "modulate:a", 1.0, dur)
		i += 1


## 5. Screen change, the "in" half: the whole screen fades up over 250 ms.
## (The "out" half would have to delay the scene change, which the brief
## forbids -- a click must never wait on an animation.)
static func enter_screen(root: CanvasItem) -> void:
	if not enabled() or not _live(root):
		return
	root.modulate.a = 0.0
	var tw := root.create_tween()
	tw.set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	tw.tween_property(root, "modulate:a", 1.0, T_SCREEN)


## 3. Gold glint: a translucent band sweeps across the control on hover.
static func glint(c: Control, tint: Color = UITheme.GOLD_HI) -> void:
	if c == null:
		return
	var ov := Glint.new()
	ov.tint = tint
	c.add_child(ov)
	c.mouse_entered.connect(func():
		if not enabled() or not _live(ov):
			return
		_kill(ov, "_m_glint")
		ov.sweep = -0.3
		var tw := ov.create_tween()
		tw.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		tw.tween_property(ov, "sweep", 1.3, T_GLINT)
		ov.set_meta("_m_glint", tw))


## The band itself: a child that fills its parent, ignores the mouse, and
## redraws only while a sweep is running.
class Glint extends Control:
	var tint := Color(0.94, 0.82, 0.48)
	var sweep := 2.0:
		set(v):
			sweep = v
			queue_redraw()

	func _ready() -> void:
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		clip_contents = true

	func _draw() -> void:
		if sweep < -0.29 or sweep > 1.29:
			return
		var w := size.x
		var h := size.y
		var x := sweep * (w + h) - h
		var band := maxf(28.0, w * 0.12)
		var pts := PackedVector2Array([
			Vector2(x, 0), Vector2(x + band, 0),
			Vector2(x + band - h * 0.6, h), Vector2(x - h * 0.6, h)])
		var cols := PackedColorArray([
			Color(tint, 0.0), Color(tint, 0.22), Color(tint, 0.22), Color(tint, 0.0)])
		draw_polygon(pts, cols)


## Idle loop: alpha lo <-> hi, `period` seconds for a full cycle.
static func _loop_alpha(c: CanvasItem, lo: float, hi: float, period: float) -> void:
	if not _live(c):
		return
	_kill(c, "_m_loop")
	if not enabled():
		c.modulate.a = hi
		return
	c.modulate.a = hi
	var tw := c.create_tween().set_loops()
	tw.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(c, "modulate:a", lo, period * 0.5)
	tw.tween_property(c, "modulate:a", hi, period * 0.5)
	c.set_meta("_m_loop", tw)


## "Click anywhere to start".
static func pulse(c: CanvasItem) -> void:
	_loop_alpha(c, 0.4, 1.0, LOOP_PULSE)


## 8. Soul breathe: the glow behind the one primary button on a screen.
static func breathe(c: CanvasItem) -> void:
	_loop_alpha(c, 0.35, 0.55, LOOP_BREATHE)


## 12. Number tick: counts a label from one value to another. `fmt` receives
## the integer. The colour flips to ok/bad when the value crosses `limit`.
static func count_up(label: Label, from: int, to: int, fmt: String = "%d",
		limit: int = -1, dur: float = T_COUNT) -> void:
	if label == null:
		return
	var paint := func(v: int) -> void:
		label.text = fmt % v
		if limit >= 0:
			label.add_theme_color_override("font_color",
					UITheme.OK if v >= limit else UITheme.TEXT)
	if not enabled() or not _live(label) or from == to:
		paint.call(to)
		return
	_kill(label, "_m_count")
	var tw := label.create_tween()
	tw.set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	tw.tween_method(paint, from, to, dur)
	label.set_meta("_m_count", tw)


## 7. Core pip pop: scale 0.6 -> 1 with a small overshoot.
static func pop(c: Control) -> void:
	if not enabled() or not _live(c):
		return
	c.pivot_offset = c.size * 0.5
	c.scale = Vector2(0.6, 0.6)
	_kill(c, "_m_scale")
	var tw := c.create_tween()
	tw.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(c, "scale", Vector2.ONE, 0.18)
	c.set_meta("_m_scale", tw)


## 10. Mouse parallax on the background shader: offset = (mouse - centre) *
## 0.008, smoothed. One shader parameter per frame, nothing else.
static func parallax(bg: ColorRect) -> void:
	if not enabled() or bg == null or not (bg.material is ShaderMaterial):
		return
	var p := Parallax.new()
	p.target = bg
	bg.add_child(p)


class Parallax extends Node:
	var target: ColorRect
	var _cur := Vector2.ZERO

	func _process(_delta: float) -> void:
		if target == null or not is_instance_valid(target):
			set_process(false)
			return
		var vp := target.get_viewport_rect().size
		if vp.x <= 0.0 or vp.y <= 0.0:
			return
		var m := target.get_viewport().get_mouse_position()
		var want := (m - vp * 0.5) / vp * 0.008
		_cur = _cur.lerp(want, 0.08)
		(target.material as ShaderMaterial).set_shader_parameter("offset", _cur)


## 9. Ember drift: about two dozen gold motes rising slowly. Additive, tiny,
## and only on the title and home screens.
static func embers(parent: Control, amount: int = 24) -> CPUParticles2D:
	if not enabled():
		return null
	var p := CPUParticles2D.new()
	p.amount = amount
	p.lifetime = 7.5
	p.preprocess = 6.0
	p.explosiveness = 0.0
	p.randomness = 0.6
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.direction = Vector2(0, -1)
	p.spread = 12.0
	p.gravity = Vector2.ZERO
	p.initial_velocity_min = 8.0
	p.initial_velocity_max = 14.0
	p.scale_amount_min = 0.3
	p.scale_amount_max = 0.7
	p.texture = _dot_texture()
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.25, 1.0])
	g.colors = PackedColorArray([Color(UITheme.GOLD_HI, 0.0), Color(UITheme.GOLD_HI, 0.8),
			Color(UITheme.GOLD_HI, 0.0)])
	p.color_ramp = g
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	p.material = mat
	parent.add_child(p)
	var fit := func():
		var s := parent.size
		p.position = s * 0.5
		p.emission_rect_extents = s * 0.5
	parent.resized.connect(fit)
	fit.call()
	return p


static var _dot: Texture2D = null


static func _dot_texture() -> Texture2D:
	if _dot != null:
		return _dot
	var n := 8
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var d := Vector2(x + 0.5, y + 0.5).distance_to(Vector2(n * 0.5, n * 0.5)) / (n * 0.5)
			img.set_pixel(x, y, Color(1, 1, 1, clampf(1.0 - d * d, 0.0, 1.0)))
	_dot = ImageTexture.create_from_image(img)
	return _dot
