extends Control
class_name CoreGems
##
## Draws cores as gems -- blue for regular cores, red for the soul core -- the
## way they look on the table, instead of as a number.
##
## Used for life, reserve, trash and the cores sitting on a card. Above
## `max_drawn` gems it draws a few and a count, so a reserve of 14 does not
## become a row that runs off the panel.
##
## 0.22.0: the gems are pictures (assets/ui/core_gem.png, soul_core.png, made
## by tools/make_core_gems.py) instead of drawn circles. An animation can show
## the row as it was a moment ago -- `hold(delta)` -- and then step it towards
## the real count with `bump(+1 / -1)` as each flying core lands or leaves; a
## core that arrives "pops" (grows and settles, with a ring).
##

const CORE_TEX := "res://assets/ui/core_gem.png"
const SOUL_TEX := "res://assets/ui/soul_core.png"
## The gem fills about 90% of its picture (the rest is its shadow and glow).
const TEX_SCALE := 1.0 / 0.90
## Extra room around the row that still counts as touching it, so a finger
## can pick up a small gem (0.22.1); a mouse gets a little.
const TOUCH_SLOP := 12.0
const MOUSE_SLOP := 4.0

## The number this row shows changed (an animation stepped it); a zone
## header's count follows it so the two never disagree.
signal shown_changed(n: int)

static var _core_tex: Texture2D
static var _soul_tex: Texture2D

@export var cores: int = 0:
	set(v):
		cores = maxi(0, v)
		_resize()
@export var soul: int = 0:
	set(v):
		soul = maxi(0, v)
		_resize()
@export var radius: float = 9.0:
	set(v):
		radius = v
		_resize()
@export var max_drawn: int = 8
@export var show_count: bool = true
## When > 0, draws this many empty sockets first (e.g. 5 life slots) so a loss
## of life is visible as an empty socket rather than as a shorter row.
@export var sockets: int = 0:
	set(v):
		sockets = v
		_resize()

## When > 0 (0.24.0), the row must fit in this width: the gems get smaller
## on a small card instead of running off it. Up to `max_drawn` gems are drawn
## on one row; past that the row ends with the count ("x6").
@export var fit_width: float = 0.0:
	set(v):
		fit_width = v
		_resize()

## Shown = real count + offset (an animation in progress); 0 = the real count.
var offset: int = 0
## 1 -> 0 while the newest gem pops in.
var pop: float = 0.0:
	set(v):
		pop = v
		queue_redraw()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


static func slop() -> float:
	return TOUCH_SLOP if DisplayServer.is_touchscreen_available() else MOUSE_SLOP


## A press a little outside the row still lands on it (fingers are wide).
func _has_point(point: Vector2) -> bool:
	return Rect2(Vector2.ZERO, size).grow(slop()).has_point(point)


static func core_texture(is_soul: bool) -> Texture2D:
	if _core_tex == null:
		_core_tex = load(CORE_TEX)
		_soul_tex = load(SOUL_TEX)
	return _soul_tex if is_soul else _core_tex


func set_counts(regular: int, soul_cores: int) -> void:
	cores = regular
	soul = soul_cores
	queue_redraw()


## Show the row as if it had `delta` more (or fewer) cores than it really has.
func hold(delta: int) -> void:
	offset = delta
	queue_redraw()
	shown_changed.emit(_shown())


## Add `delta` to what the row is holding back (several moves queued at once).
func hold_add(delta: int) -> void:
	offset += delta
	queue_redraw()
	shown_changed.emit(_shown())


## Where the next `k` arriving cores land, in global coordinates.
func landing_points(k: int) -> Array:
	var out: Array = []
	var start := _shown()
	var last := maxi(0, maxi(_slots(), mini(start + k, _cap())) - 1)
	for i in k:
		out.append(get_global_transform() * slot_center(mini(start + i, last)))
	return out


## The newest gem grows and settles, with a ring (a core just arrived).
func pop_in() -> void:
	pop = 1.0
	var t := create_tween()
	t.tween_property(self, "pop", 0.0, 0.32).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## Step the shown row by `step` towards the real count; an arrival pops.
func bump(step: int) -> void:
	offset += step
	if step > 0:
		pop_in()
	queue_redraw()
	shown_changed.emit(_shown())


func _total() -> int:
	return cores + soul


func _shown() -> int:
	return maxi(0, _total() + offset)


func _slots() -> int:
	return maxi(sockets, mini(maxi(_total(), _shown()), _cap()))


func _gap() -> float:
	return _r() * 0.42


## Gems drawn at most (the rest are the count).
func _cap() -> int:
	return max_drawn


## The radius the gems are drawn at: `radius`, or smaller so the row (and its
## count) fits `fit_width`.
func _r() -> float:
	if fit_width <= 0.0:
		return radius
	var n := maxi(1, _slots())
	var label := show_count and _total() > _cap()
	var units := n * 2.0 + (n - 1) * 0.42 + (3.4 if label else 0.0)
	return minf(radius, fit_width / units)


func _resize() -> void:
	var r := _r()
	var gap := r * 0.42
	var n := maxi(1, _slots())
	var w := n * r * 2.0 + (n - 1) * gap
	if show_count and _total() > _cap():
		w += r * 3.4
	custom_minimum_size = Vector2(w, r * 2.0 + 2.0)
	queue_redraw()


## Centre of gem slot `i` in this control's coordinates.
func slot_center(i: int) -> Vector2:
	var r := _r()
	return Vector2(r + i * (r * 2.0 + r * 0.42), maxf(size.y, r * 2.0 + 2.0) * 0.5)


## Where the next arriving core lands (the first empty slot), in global coordinates.
func landing_point() -> Vector2:
	var i := mini(_shown(), maxi(0, _slots() - 1))
	return get_global_transform() * slot_center(i)


## "soul" or "core" for the gem under `local_pos`, "" for none (used to pick
## which core a drag takes).
func gem_at(local_pos: Vector2) -> String:
	var drawn := mini(_shown(), _cap())
	for i in drawn:
		if slot_center(i).distance_to(local_pos) <= _r() * 1.25 + slop() * 0.5:
			return "soul" if i < soul else "core"
	if drawn > 0 and Rect2(Vector2.ZERO, size).grow(slop()).has_point(local_pos):
		return "core" if cores > 0 else "soul"
	return ""


func _draw() -> void:
	var shown := _shown()
	var drawn := mini(shown, _cap())
	var slots := _slots()
	var y := size.y * 0.5
	for i in slots:
		var c := slot_center(i)
		if i >= drawn:
			# Empty socket.
			draw_circle(c, _r(), Color(1, 1, 1, 0.05))
			draw_arc(c, _r() - 0.5, 0.0, TAU, 28, Color(1, 1, 1, 0.22), 1.2, true)
			continue
		# Soul cores are drawn first so a single red gem is always visible even
		# when the row is truncated.
		var is_soul := i < soul
		var k := 1.0
		if pop > 0.0 and i == drawn - 1 and offset >= 0:
			k = 1.0 + 0.45 * pop
			draw_arc(c, _r() * (1.2 + 0.9 * (1.0 - pop)), 0.0, TAU, 32,
					Color(UITheme.SOUL if is_soul else UITheme.CORE, 0.7 * pop), 2.0, true)
		_gem(c, is_soul, k)
	if show_count and _total() > _cap():
		var font := get_theme_default_font()
		var rr := _r()
		var x := slots * (rr * 2.0 + _gap())
		draw_string(font, Vector2(x, y + rr * 0.55), "x%d" % shown,
				HORIZONTAL_ALIGNMENT_LEFT, -1, maxi(8, int(rr * 1.5)), UITheme.TEXT)


func _gem(c: Vector2, is_soul: bool, k: float = 1.0) -> void:
	var tex := core_texture(is_soul)
	if tex == null:
		var col := UITheme.SOUL if is_soul else UITheme.CORE
		draw_circle(c, _r() * k, col)
		return
	var s := _r() * 2.0 * TEX_SCALE * k
	draw_texture_rect(tex, Rect2(c - Vector2(s, s) * 0.5, Vector2(s, s)), false)
