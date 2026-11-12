extends Control
class_name BattleFX
##
## The battle presentation layer: every animation on the game board is built
## from the primitives in this file.
##
## It is a transparent overlay on top of the board. Nothing here knows the
## rules; BattleDirector.gd decides WHAT to show for each engine event and
## calls these to show it. Keeping the two apart means a new effect (a burst
## flourish, a keyword callout) is one director function using existing
## primitives, and restyling an effect never touches game logic.
##
## Timing: every duration passed in is a duration at speed 1.0. `d()` divides
## by the "Animation speed" setting. Clicking anywhere while something is
## playing RUSHES it: every live tween is sped up 6x until the queue drains.
##
## Lifetime: every tween is created by this node, so when the board is freed
## (scene change, concede) all of them die with it and no coroutine resumes on
## a freed object. That is why waits are tweens, never SceneTree timers.
##
## Primitives
##   ghost(card_id, rect, face_down)      a free-floating card copy
##   fly(node, to_rect, dur, arc, scale)  move a node along an arc
##   flip_to(card, card_id, dur)          turn a card face up mid-air
##   callout(text, colour, at)            punchy word ("ATTACK!", "BLOCK!")
##   float_text(text, at, colour)         small rising number ("-2 LIFE")
##   banner(title, subtitle, colour)      full-width sweeping band (turns)
##   step_sweep(text, colour, y)          narrow band across the centre strip
##   ring(at, colour, r0, r1, dur)        expanding shockwave
##   flash(rect, colour, dur)             a quick light flash over a rect
##   shatter(rect, card_id, colour)       a card breaking into shards
##   gems(from, to, n, soul)              cores flying between zones
##   shake(strength, dur)                 shake the play area
##   dim(alpha, dur)                      darken the board behind a focus
##   arrow                                persistent attack-target arrow
##

const RUSH := 6.0

var speed := 1.0
var shake_target: Control = null

var _rush := 1.0
## Untyped on purpose: when the board is freed its tweens die with it, and a
## TYPED array refuses to even hold the dead references long enough to be
## pruned ("Attempted to assign an invalid object into a TypedArray", R-030).
var _tweens: Array = []
var _blocker: Control
var _hint: Label
var _dimmer: ColorRect
var arrow: AttackArrow


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 40

	_dimmer = ColorRect.new()
	_dimmer.color = Color(0.0, 0.01, 0.04, 0.0)
	_dimmer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dimmer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_dimmer)

	arrow = AttackArrow.new()
	add_child(arrow)

	# While a presentation plays, this swallows clicks (so nothing is acted on
	# against a board that is still moving) and turns them into "hurry up".
	_blocker = Control.new()
	_blocker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	_blocker.visible = false
	_blocker.gui_input.connect(_on_blocker_input)
	add_child(_blocker)

	_hint = UITheme.body("Click to speed up", true, UITheme.FS_TINY + 1)
	_hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_hint.position = Vector2(18, -26)
	_hint.modulate.a = 0.0
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hint)


# ---------------------------------------------------------------------------
# Session control
# ---------------------------------------------------------------------------

func begin() -> void:
	speed = maxf(0.25, GameConfig.card_animation_speed)
	_rush = 1.0
	_blocker.visible = true
	_hint.position = Vector2(18, size.y - 26)
	var t := tw()
	t.tween_property(_hint, "modulate:a", 0.55, d(0.6)).set_delay(d(1.2))


func end() -> void:
	_blocker.visible = false
	_rush = 1.0
	_hint.modulate.a = 0.0
	_prune()


func rush() -> void:
	_rush = RUSH
	_prune()
	for t: Variant in _tweens:
		(t as Tween).set_speed_scale(_rush)


func _on_blocker_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed:
		rush()
		_blocker.accept_event()


## Seconds at the current speed.
func d(t: float) -> float:
	return t / speed


## Every tween goes through here so rush() can reach it.
func tw() -> Tween:
	var t := create_tween()
	t.set_speed_scale(_rush)
	_tweens.append(t)
	if _tweens.size() > 64:
		_prune()
	return t


func _prune() -> void:
	var keep: Array = []
	for t: Variant in _tweens:
		if is_instance_valid(t) and (t as Tween).is_valid() and (t as Tween).is_running():
			keep.append(t)
	_tweens = keep


## A pause that dies with this node.
func wait(t: float) -> Signal:
	var x := tw()
	x.tween_interval(maxf(0.01, d(t)))
	return x.finished


## Where a control really is on screen (0.17.3): centred on its drawn centre,
## with its own size. get_global_rect() ignores rotation, and an exhausted
## card is turned 90 degrees about its middle, so for it that rectangle sat
## beside the card: the attack arrow, the rings and the ATTACK!/BLOCK! words
## started off to one side of the card (R-103).
static func visual_rect(c: Control) -> Rect2:
	if c == null or not c.is_inside_tree():
		return Rect2()
	var xf := c.get_global_transform()
	var mid := xf * (c.size * 0.5)
	var sz := (c.size * xf.get_scale()).abs()
	return Rect2(mid - sz * 0.5, sz)


func local_rect(global_rect: Rect2) -> Rect2:
	return Rect2(global_rect.position - global_position, global_rect.size)


func local_point(global_point: Vector2) -> Vector2:
	return global_point - global_position


func centre() -> Vector2:
	return size * 0.5


## Keep a word fully on screen: text aimed at your own life panel, which sits
## against the left edge, was being cut in half.
func _inside(p: Vector2, sz: Vector2) -> Vector2:
	var m := 10.0
	return Vector2(clampf(p.x, m, maxf(m, size.x - sz.x - m)),
			clampf(p.y, m, maxf(m, size.y - sz.y - m)))


# ---------------------------------------------------------------------------
# Cards in flight
# ---------------------------------------------------------------------------

## A card that belongs to no layout: positioned freely in the overlay.
func ghost(card_id: String, global_rect: Rect2, face_down: bool = false) -> CardWidget:
	var w := CardWidget.new()
	var sz := global_rect.size if global_rect.size.x > 4.0 else Vector2(112, 157)
	if face_down or card_id == "":
		w.setup_back(sz)
	else:
		w.setup(card_id, sz)
	w.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(w)
	w.size = sz
	w.pivot_offset = sz * 0.5
	var r := local_rect(global_rect)
	w.position = r.position
	return w


## Move `node` so it ends centred on `to_rect` (global), along an arc that
## bulges `arc` pixels sideways. The node's own size never changes; `to_scale`
## scales it about its centre. Returns the finished signal.
func fly(node: Control, to_rect: Rect2, dur: float, arc: float = 0.0,
		to_scale: float = -1.0, trans: int = Tween.TRANS_CUBIC) -> Signal:
	var r := local_rect(to_rect)
	var target_scale := to_scale
	if target_scale < 0.0:
		target_scale = (r.size.x / node.size.x) if node.size.x > 0.0 and r.size.x > 0.0 else 1.0
	var p0 := node.position
	var p1 := r.get_center() - node.size * 0.5
	var mid := (p0 + p1) * 0.5
	var dir := (p1 - p0)
	var normal := Vector2(-dir.y, dir.x).normalized() if dir.length() > 1.0 else Vector2.ZERO
	var ctrl := mid + normal * arc
	var t := tw()
	t.set_parallel(true)
	t.tween_method(func(k: float) -> void:
		if is_instance_valid(node):
			node.position = p0.lerp(ctrl, k).lerp(ctrl.lerp(p1, k), k),
		0.0, 1.0, d(dur)).set_trans(trans).set_ease(Tween.EASE_IN_OUT)
	t.tween_property(node, "scale", Vector2.ONE * target_scale, d(dur)) \
		.set_trans(trans).set_ease(Tween.EASE_IN_OUT)
	return t.finished


## The object with this instance id, or null once it has been freed (0.16.8).
## Tween callbacks hold ids rather than nodes: a lambda that captured a node
## freed before the tween ended makes Godot log "Lambda capture ... was freed".
static func alive(id: int) -> Object:
	return instance_from_id(id) if is_instance_id_valid(id) else null


## Turn a card over: squash to nothing on X, swap the face, open up again.
func flip_to(card: CardWidget, card_id: String, dur: float = 0.24) -> Signal:
	var t := tw()
	var sx := card.scale.x
	var sz := card.size
	t.tween_property(card, "scale:x", 0.0, d(dur * 0.5)).set_trans(Tween.TRANS_SINE)
	var cid_inst := card.get_instance_id()
	t.tween_callback(func() -> void:
		var c := alive(cid_inst) as CardWidget
		if c != null and card_id != "":
			c.setup(card_id, sz)
			c.size = sz
			c.mouse_filter = Control.MOUSE_FILTER_IGNORE)
	t.tween_property(card, "scale:x", sx, d(dur * 0.5)).set_trans(Tween.TRANS_SINE)
	return t.finished


## Remove a ghost with a fade (optionally shrinking into a point).
func vanish(node: Control, dur: float = 0.25, shrink: bool = false) -> Signal:
	var t := tw()
	t.set_parallel(true)
	t.tween_property(node, "modulate:a", 0.0, d(dur))
	if shrink:
		t.tween_property(node, "scale", node.scale * 0.3, d(dur))
	t.chain().tween_callback(node.queue_free)
	return t.finished


# ---------------------------------------------------------------------------
# Words
# ---------------------------------------------------------------------------

func _word(text: String, font_size: int, col: Color, outline: int = 10) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", col.lightened(0.35))
	l.add_theme_color_override("font_outline_color", Color(col.darkened(0.75), 0.95))
	l.add_theme_constant_override("outline_size", outline)
	l.add_theme_color_override("font_shadow_color", Color(col, 0.6))
	l.add_theme_constant_override("shadow_offset_x", 0)
	l.add_theme_constant_override("shadow_offset_y", 4)
	if UITheme.font("display") != null:
		l.add_theme_font_override("font", UITheme.font("display"))
	elif UITheme.font("bold") != null:
		l.add_theme_font_override("font", UITheme.font("bold"))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(l)
	l.size = l.get_minimum_size()
	l.pivot_offset = l.size * 0.5
	return l


## A word that slams in, holds, and lifts away. `at` is global.
func callout(text: String, col: Color, at: Vector2, font_size: int = 52,
		hold: float = 0.45) -> Signal:
	var l := _word(text, font_size, col)
	l.position = _inside(local_point(at) - l.size * 0.5, l.size)
	l.scale = Vector2.ONE * 2.2
	l.modulate.a = 0.0
	var t := tw()
	t.set_parallel(true)
	t.tween_property(l, "scale", Vector2.ONE, d(0.18)).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.tween_property(l, "modulate:a", 1.0, d(0.10))
	t.chain().tween_interval(d(hold))
	t.chain().tween_property(l, "position:y", l.position.y - 26.0, d(0.25))
	t.parallel().tween_property(l, "modulate:a", 0.0, d(0.25))
	t.chain().tween_callback(l.queue_free)
	return t.finished


func float_text(text: String, at: Vector2, col: Color, font_size: int = 26) -> Signal:
	var l := _word(text, font_size, col, 6)
	l.position = _inside(local_point(at) - l.size * 0.5, l.size)
	var t := tw()
	t.set_parallel(true)
	t.tween_property(l, "position:y", l.position.y - 46.0, d(0.9)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	t.tween_property(l, "modulate:a", 0.0, d(0.35)).set_delay(d(0.55))
	t.chain().tween_callback(l.queue_free)
	return t.finished


## The turn banner: a slanted band sweeps across the middle of the board with
## a big title, holds, and sweeps out the far side.
func banner(title: String, subtitle: String, col: Color, hold: float = 0.6) -> Signal:
	var h := 132.0
	var band := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(col.darkened(0.55), 0.92)
	sb.border_color = col
	sb.border_width_top = 3
	sb.border_width_bottom = 3
	sb.skew = Vector2(0.25, 0)
	sb.shadow_color = Color(col, 0.35)
	sb.shadow_size = 24
	band.add_theme_stylebox_override("panel", sb)
	band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(band)
	band.size = Vector2(size.x + 240.0, h)
	band.position = Vector2(-band.size.x, size.y * 0.5 - h * 0.5)

	var big := _word(title, 64, col)
	var small := _word(subtitle, 20, Color(0.85, 0.9, 1.0), 4)
	var y := size.y * 0.5
	big.position = Vector2(size.x + 40.0, y - big.size.y * 0.5 + 8.0)
	small.position = Vector2(-small.size.x - 40.0, y - h * 0.5 + 10.0)
	var bx := size.x * 0.5 - big.size.x * 0.5
	var sx := size.x * 0.5 - small.size.x * 0.5

	var t := tw()
	t.set_parallel(true)
	t.tween_property(band, "position:x", -120.0, d(0.28)).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	t.tween_property(big, "position:x", bx, d(0.34)).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT).set_delay(d(0.06))
	t.tween_property(small, "position:x", sx, d(0.34)).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT).set_delay(d(0.10))
	t.chain().tween_interval(d(hold))
	t.chain().tween_property(band, "position:x", size.x + 120.0, d(0.26)).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_IN)
	t.parallel().tween_property(big, "position:x", -big.size.x - 60.0, d(0.26)).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_IN)
	t.parallel().tween_property(small, "position:x", size.x + 60.0, d(0.26)).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_IN)
	var ids := [band.get_instance_id(), big.get_instance_id(), small.get_instance_id()]
	t.chain().tween_callback(func() -> void:
		for i: int in ids:
			var n := alive(i) as Node
			if n != null:
				n.queue_free())
	return t.finished


## A thin band with a step name that crosses the centre strip at height `y`.
func step_sweep(text: String, col: Color, y: float, hold: float = 0.25) -> Signal:
	var band := ColorRect.new()
	band.color = Color(col, 0.0)
	band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(band)
	band.size = Vector2(size.x, 46.0)
	band.position = Vector2(0, y - 23.0)
	var l := _word(text, 30, col, 6)
	l.position = Vector2(size.x * 0.5 - l.size.x * 0.5 + 80.0, y - l.size.y * 0.5)
	l.modulate.a = 0.0
	var t := tw()
	t.set_parallel(true)
	t.tween_property(band, "color:a", 0.32, d(0.12))
	t.tween_property(l, "modulate:a", 1.0, d(0.12))
	t.tween_property(l, "position:x", size.x * 0.5 - l.size.x * 0.5, d(0.18)).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	t.chain().tween_interval(d(hold))
	t.chain().tween_property(band, "color:a", 0.0, d(0.14))
	t.parallel().tween_property(l, "modulate:a", 0.0, d(0.14))
	t.parallel().tween_property(l, "position:x", size.x * 0.5 - l.size.x * 0.5 - 80.0, d(0.14))
	var ids := [band.get_instance_id(), l.get_instance_id()]
	t.chain().tween_callback(func() -> void:
		for i: int in ids:
			var n := alive(i) as Node
			if n != null:
				n.queue_free())
	return t.finished


# ---------------------------------------------------------------------------
# Light, impact, debris
# ---------------------------------------------------------------------------

func ring(at: Vector2, col: Color, r0: float = 20.0, r1: float = 140.0,
		dur: float = 0.45, width: float = 6.0) -> Signal:
	var r := Ring.new()
	r.colour = col
	r.width = width
	r.radius = r0
	r.position = local_point(at)
	add_child(r)
	var t := tw()
	t.set_parallel(true)
	t.tween_property(r, "radius", r1, d(dur)).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	t.tween_property(r, "alpha", 0.0, d(dur)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	t.chain().tween_callback(r.queue_free)
	return t.finished


func flash(global_rect: Rect2, col: Color, dur: float = 0.3, peak: float = 0.75) -> Signal:
	var f := ColorRect.new()
	f.color = Color(col, peak)
	f.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(f)
	var r := local_rect(global_rect) if global_rect.size.x > 0.0 else Rect2(Vector2.ZERO, size)
	f.position = r.position
	f.size = r.size
	var t := tw()
	t.tween_property(f, "color:a", 0.0, d(dur)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	t.tween_callback(f.queue_free)
	return t.finished


## The card blanches, then bursts into shards that fly apart and fade.
func shatter(global_rect: Rect2, card_id: String, col: Color) -> Signal:
	var g := ghost(card_id, global_rect)
	var r := local_rect(global_rect)
	var t := tw()
	t.tween_property(g, "modulate", Color(2.4, 2.4, 2.4, 1.0), d(0.10))
	t.tween_property(g, "scale", Vector2.ONE * 1.06, d(0.06))
	var gid := g.get_instance_id()
	t.tween_callback(func() -> void:
		var gg := alive(gid) as Node
		if gg == null:
			return
		gg.queue_free()
		var rng := RandomNumberGenerator.new()
		rng.seed = hash(card_id) ^ int(r.position.x)
		for i in 14:
			var shard := Polygon2D.new()
			var s := rng.randf_range(10.0, 26.0)
			shard.polygon = PackedVector2Array([Vector2(0, -s), Vector2(s * 0.7, s * 0.5), Vector2(-s * 0.6, s * 0.4)])
			shard.color = col.lerp(Color.WHITE, rng.randf_range(0.0, 0.6))
			shard.position = r.position + Vector2(rng.randf() * r.size.x, rng.randf() * r.size.y)
			add_child(shard)
			var away := (shard.position - r.get_center()).normalized() * rng.randf_range(60.0, 170.0)
			var st := tw()
			st.set_parallel(true)
			st.tween_property(shard, "position", shard.position + away + Vector2(0, 40), d(0.55)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
			st.tween_property(shard, "rotation", rng.randf_range(-4.0, 4.0), d(0.55))
			st.tween_property(shard, "modulate:a", 0.0, d(0.55)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
			st.chain().tween_callback(shard.queue_free))
	t.tween_interval(d(0.45))
	ring(global_rect.get_center(), col, 10.0, 120.0, 0.4, 5.0)
	return t.finished


## `n` cores fly from one point to another, a few at a time. Soul cores red.
## Only up to 6 are drawn; a move of 9 still shows as a stream, not a swarm.
func gems(from_g: Vector2, to_g: Vector2, n: int, soul: bool = false,
		dur: float = 0.42) -> Signal:
	var shown := clampi(n, 1, 6)
	var last: Signal = wait(0.01)
	var p0 := local_point(from_g)
	var p1 := local_point(to_g)
	for i in shown:
		var g := CoreGems.new()
		g.radius = 8.0
		g.show_count = false
		g.set_counts(0 if soul and i == 0 else 1, 1 if soul and i == 0 else 0)
		add_child(g)
		g.size = g.custom_minimum_size
		g.position = p0 - g.size * 0.5
		g.modulate.a = 0.0
		var dir := p1 - p0
		var normal := Vector2(-dir.y, dir.x).normalized() if dir.length() > 1.0 else Vector2.UP
		var ctrl := (p0 + p1) * 0.5 + normal * (40.0 + 12.0 * i)
		var t := tw()
		t.tween_interval(d(0.06 * i))
		t.tween_property(g, "modulate:a", 1.0, d(0.06))
		t.tween_method(func(k: float) -> void:
			if is_instance_valid(g):
				g.position = p0.lerp(ctrl, k).lerp(ctrl.lerp(p1, k), k) - g.size * 0.5,
			0.0, 1.0, d(dur)).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		t.tween_property(g, "modulate:a", 0.0, d(0.08))
		t.tween_callback(g.queue_free)
		last = t.finished
	return last


## 0.24.0 -- Link: a beam of light grows from the lending spirit to the
## attacker and sparks of its power stream along it; returns when the last
## spark has arrived.
func link_beam(from_g: Vector2, to_g: Vector2, col: Color, sparks: int = 9, dur: float = 0.9) -> Signal:
	var p0 := local_point(from_g)
	var p1 := local_point(to_g)
	var line := Line2D.new()
	line.width = 10.0
	line.default_color = Color(col, 0.0)
	line.begin_cap_mode = Line2D.LINE_CAP_ROUND
	line.end_cap_mode = Line2D.LINE_CAP_ROUND
	line.points = PackedVector2Array([p0, p0])
	var glow := Line2D.new()
	glow.width = 26.0
	glow.default_color = Color(col, 0.0)
	glow.begin_cap_mode = Line2D.LINE_CAP_ROUND
	glow.end_cap_mode = Line2D.LINE_CAP_ROUND
	glow.points = line.points
	add_child(glow)
	add_child(line)
	var t := tw()
	t.set_parallel(true)
	t.tween_method(func(k: float) -> void:
		if is_instance_valid(line):
			var pts := PackedVector2Array([p0, p0.lerp(p1, k)])
			line.points = pts
			glow.points = pts, 0.0, 1.0, d(0.28)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	t.tween_property(line, "default_color:a", 0.95, d(0.12))
	t.tween_property(glow, "default_color:a", 0.35, d(0.12))
	var last: Signal = t.finished
	for i in sparks:
		var sp := Ring.new()
		sp.colour = Color(1, 1, 1)
		sp.width = 5.0
		sp.radius = 5.0
		sp.position = p0
		sp.alpha = 0.0
		add_child(sp)
		var ts := tw()
		ts.tween_interval(d(0.22 + 0.07 * i))
		ts.tween_property(sp, "alpha", 1.0, d(0.04))
		ts.tween_property(sp, "position", p1, d(0.34)).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
		ts.tween_property(sp, "alpha", 0.0, d(0.05))
		ts.tween_callback(sp.queue_free)
		last = ts.finished
	var tf := tw()
	tf.tween_interval(d(dur))
	tf.set_parallel(true)
	tf.tween_property(line, "default_color:a", 0.0, d(0.3))
	tf.tween_property(glow, "default_color:a", 0.0, d(0.3))
	tf.chain().tween_callback(line.queue_free)
	tf.chain().tween_callback(glow.queue_free)
	return last


## 0.22.0 -- cores flying one after another, each a real gem picture on an
## arc, a little larger mid-flight. `on_launch(i)` runs as gem i leaves and
## `on_land(i)` as it arrives (the board steps the source and target rows
## with them). `spawn`: the gems first appear out of a flash of light at
## `from_g` (a new core from the void in the core step).
func gems_seq(from_g: Vector2, to_g: Vector2, n: int, soul: bool, on_launch: Callable,
		on_land: Callable, spawn: bool = false, stagger: float = 0.13, dur: float = 0.5,
		to_list: Array = []) -> Signal:
	var shown := clampi(n, 1, 8)
	var last: Signal = wait(0.01)
	var p0 := local_point(from_g)
	for i in shown:
		# each gem can aim at its own slot (to_list), so a row fills left to right
		var p1 := local_point(to_list[mini(i, to_list.size() - 1)] if not to_list.is_empty() else to_g)
		var is_soul := soul and i == 0
		var g := TextureRect.new()
		g.texture = CoreGems.core_texture(is_soul)
		g.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		g.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		g.mouse_filter = Control.MOUSE_FILTER_IGNORE
		g.size = Vector2(26, 26)
		g.pivot_offset = g.size * 0.5
		add_child(g)
		g.position = p0 - g.size * 0.5
		g.modulate.a = 0.0
		var dir := p1 - p0
		var normal := Vector2(-dir.y, dir.x).normalized() if dir.length() > 1.0 else Vector2.UP
		var lift := clampf(dir.length() * 0.28, 30.0, 120.0)
		var ctrl := (p0 + p1) * 0.5 + normal * (lift + 8.0 * i) * (1.0 if normal.y <= 0.0 else -1.0)
		var idx: int = i
		var gid := g.get_instance_id()
		var t := tw()
		t.tween_interval(d(stagger * i))
		if spawn:
			t.tween_callback(func() -> void:
				ring(from_g, UITheme.CORE.lightened(0.4) if not is_soul else UITheme.SOUL, 4.0, 46.0, 0.35, 3.0))
			t.tween_property(g, "scale", Vector2(0.2, 0.2), 0.0)
			t.tween_property(g, "modulate:a", 1.0, d(0.12))
			t.parallel().tween_property(g, "scale", Vector2(1.5, 1.5), d(0.22)).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
			t.tween_interval(d(0.12))
		else:
			t.tween_property(g, "modulate:a", 1.0, d(0.07))
		t.tween_callback(func() -> void:
			if on_launch.is_valid():
				on_launch.call(idx)
			AudioManager.play_sfx("ui_hover"))
		t.tween_method(func(k: float) -> void:
			var gg := alive(gid) as Control
			if gg != null:
				var q := p0.lerp(ctrl, k).lerp(ctrl.lerp(p1, k), k)
				gg.position = q - gg.size * 0.5
				var sc := (1.5 if spawn else 1.0) * (1.0 - k) + 1.0 * k
				gg.scale = Vector2.ONE * sc * (1.0 + 0.3 * sin(k * PI))
				gg.rotation = (1.0 - k) * 0.9,
			0.0, 1.0, d(dur)).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		t.tween_callback(func() -> void:
			if on_land.is_valid():
				on_land.call(idx)
			AudioManager.play_sfx("ui_click"))
		t.tween_property(g, "modulate:a", 0.0, d(0.06))
		t.tween_callback(g.queue_free)
		last = t.finished
	return last


func shake(strength: float = 10.0, dur: float = 0.3) -> Signal:
	if shake_target == null or not is_instance_valid(shake_target):
		return wait(dur)
	var target := shake_target
	var origin := target.position
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var t := tw()
	var tid := target.get_instance_id()
	t.tween_method(func(k: float) -> void:
		var tg := alive(tid) as Control
		if tg != null:
			var s := strength * (1.0 - k)
			tg.position = origin + Vector2(rng.randf_range(-s, s), rng.randf_range(-s, s)),
		0.0, 1.0, d(dur))
	t.tween_callback(func() -> void:
		var tg := alive(tid) as Control
		if tg != null:
			tg.position = origin)
	return t.finished


func dim(alpha: float, dur: float = 0.18) -> Signal:
	var t := tw()
	t.tween_property(_dimmer, "color:a", alpha, d(dur))
	return t.finished


## Holds a colour pulse on a live board control (e.g. the life panel).
func pulse(node: Control, col: Color, dur: float = 0.5) -> Signal:
	if node == null or not is_instance_valid(node):
		return wait(dur)
	var t := tw()
	var base := node.modulate
	t.tween_property(node, "modulate", Color(col.r * 1.6, col.g * 1.6, col.b * 1.6, base.a), d(dur * 0.3))
	t.tween_property(node, "modulate", base, d(dur * 0.7))
	return t.finished


## A counter that rolls from 0 to `value` in a label (BP in the clash).
func count_up(label: Label, value: int, dur: float = 0.4) -> Signal:
	var t := tw()
	t.tween_method(func(v: float) -> void:
		if is_instance_valid(label):
			label.text = "%d" % int(v),
		0.0, float(value), d(dur)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	return t.finished


func word(text: String, font_size: int, col: Color) -> Label:
	return _word(text, font_size, col)


# ---------------------------------------------------------------------------
# Drawn helpers
# ---------------------------------------------------------------------------

class Ring extends Node2D:
	var colour := Color.WHITE
	var width := 6.0
	var radius := 20.0:
		set(v):
			radius = v
			queue_redraw()
	var alpha := 1.0:
		set(v):
			alpha = v
			queue_redraw()

	func _draw() -> void:
		draw_arc(Vector2.ZERO, radius, 0.0, TAU, 64, Color(colour, alpha * 0.35), width * 3.0, true)
		draw_arc(Vector2.ZERO, radius, 0.0, TAU, 64, Color(colour.lightened(0.4), alpha), width, true)


## The attack-target arrow. It points from the attacking spirit to whatever it
## is hitting: the defending player's LIFE while no block is declared, then the
## BLOCKER once one is. It follows its two end controls every frame, so a
## re-render or a card turning sideways never leaves it pointing at nothing.
class AttackArrow extends Control:
	var source: Control = null
	var target: Control = null
	var colour := Color("#ff4d5e")
	var grow := 0.0             # 0..1, how much of the path is drawn
	var _phase := 0.0
	var _p0 := Vector2.ZERO
	var _p1 := Vector2.ZERO

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		visible = false

	func point_at(src: Control, dst: Control, col: Color) -> void:
		source = src
		target = dst
		colour = col
		visible = src != null and dst != null
		set_process(visible)

	func clear() -> void:
		source = null
		target = null
		grow = 0.0
		visible = false
		set_process(false)

	func _process(delta: float) -> void:
		if source == null or target == null or not is_instance_valid(source) \
				or not is_instance_valid(target) or not source.is_visible_in_tree():
			visible = false
			return
		visible = true
		_phase = fmod(_phase + delta * 1.6, 1.0)
		_p0 = BattleFX.visual_rect(source).get_center() - global_position
		_p1 = BattleFX.visual_rect(target).get_center() - global_position
		queue_redraw()

	func _bez(t: float, c: Vector2) -> Vector2:
		return _p0.lerp(c, t).lerp(c.lerp(_p1, t), t)

	func _draw() -> void:
		if grow <= 0.0:
			return
		var dir := _p1 - _p0
		if dir.length() < 8.0:
			return
		var normal := Vector2(-dir.y, dir.x).normalized()
		var ctrl := (_p0 + _p1) * 0.5 + normal * clampf(dir.length() * 0.18, 30.0, 120.0)
		var pts := PackedVector2Array()
		var steps := 40
		for i in steps + 1:
			var t := float(i) / steps * grow
			pts.append(_bez(t, ctrl))
		# Glow, then core line.
		draw_polyline(pts, Color(colour, 0.22), 18.0, true)
		draw_polyline(pts, Color(colour, 0.9), 6.0, true)
		# Chevrons travelling along the path, towards the target.
		for k in 4:
			var t := fmod(_phase + k * 0.25, 1.0) * grow
			var p := _bez(t, ctrl)
			var ahead := _bez(minf(1.0, t + 0.02), ctrl)
			var fwd := (ahead - p).normalized()
			var side := Vector2(-fwd.y, fwd.x)
			draw_polyline(PackedVector2Array([p - fwd * 8.0 + side * 7.0, p, p - fwd * 8.0 - side * 7.0]),
					Color(1, 1, 1, 0.75), 3.0, true)
		# Head.
		var tip := _bez(grow, ctrl)
		var before := _bez(maxf(0.0, grow - 0.04), ctrl)
		var f := (tip - before).normalized()
		var s := Vector2(-f.y, f.x)
		draw_colored_polygon(PackedVector2Array([tip + f * 10.0, tip - f * 22.0 + s * 16.0,
				tip - f * 22.0 - s * 16.0]), colour.lightened(0.2))
		if grow >= 1.0:
			draw_arc(_p1, 34.0 + 4.0 * sin(_phase * TAU), 0.0, TAU, 48, Color(colour, 0.85), 3.0, true)
