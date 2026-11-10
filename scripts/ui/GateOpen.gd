extends CanvasLayer
class_name GateOpen
## "Gate Open, Kaiho!" -- the battle-start animation (0.18.4, proposals).
##
## An overlay drawn above the board by the game itself: shaders for the gate,
## the tunnel and the field, particles for sparks and embers, the real board
## underneath. Three variants, picked by name:
##   "isekai"  A, the anime moment: ignite, gate, tunnel, arrival, the board rises
##   "core"    B, the arena builds itself: face-off, cores, hex field, tilt down
##   "burst"   C, fast: the key card slams, cracks, the dark shatters
##
##   var g := GateOpen.start(board, "isekai", "red", "blue", "SS1-001")
##   var g := GateOpen.start(board, "isekai", ["red", "blue"], "blue", "SS1-001")   # a split deck (0.19.0)
##   await g.finished
##
## Colours (0.19.0): the opening is drawn in the player's deck's dominant
## colour. When the deck is split -- two or more colours within reach of the
## leader, see deck_colours() -- every one of them is shown: one symbol per
## colour side by side at the ignition, and the gate, tunnel, word, line and
## afterglow drawn as a spectrum across those colours.
##
## Any click, key or tap skips to the end. Nothing here touches the match:
## online, both players see their own copy and the game does not wait.

signal finished

const DUR := {"isekai": 6.6, "core": 5.6, "burst": 2.6}
const RGB := {"red": Color8(226, 70, 70), "purple": Color8(176, 104, 226), "white": Color8(236, 240, 248),
		"yellow": Color8(250, 214, 74), "green": Color8(96, 206, 120), "blue": Color8(88, 160, 248)}
const ORDER := ["red", "purple", "white", "yellow", "green", "blue"]
const WARM := Color8(255, 240, 200)

## Set when an opening has played this run of the game (once per session).
static var shown_this_session := false

var variant := "isekai"
var me := "red"                      # the leading colour
var mine: Array = ["red"]            # every dominant colour, in ORDER (one entry unless the deck is split)
var opp := "blue"
var key_id := ""
var board: Control
var _root: Control
var _done := false
var _tweens: Array[Tween] = []
var _board_pos := Vector2.ZERO


## `my_colour` is a colour name or, for a split deck, an Array of them.
static func start(host: Control, which: String, my_colour: Variant, opp_colour: String, key_card: String) -> GateOpen:
	var g := GateOpen.new()
	g.variant = which if DUR.has(which) else "isekai"
	var list: Array = []
	for c in (my_colour if my_colour is Array else [my_colour]):
		if RGB.has(str(c)) and not list.has(str(c)):
			list.append(str(c))
	if list.is_empty():
		list = ["red"]
	list.sort_custom(func(a, b): return ORDER.find(a) < ORDER.find(b))
	g.mine = list
	g.me = str(list[0])
	g.opp = opp_colour if RGB.has(opp_colour) else "blue"
	g.key_id = key_card
	g.board = host
	g.layer = 60
	host.get_tree().root.add_child(g)
	return g


## The deck's leading colour and its cover card (its costliest spirit).
static func deck_colour_and_key(deck: Dictionary) -> Array:
	var cols := deck_colours(deck)
	var best := ""
	var best_cost := -1
	for id in deck.get("main", []):
		var cd: CardData = CardDB.get_card(str(id))
		if cd != null and cd.is_spirit() and cd.cost > best_cost:
			best_cost = cd.cost
			best = str(id)
	return [cols[0], best]


## How close to the leader a colour must be to count as co-dominant: within
## this share of the deck (5 cards of 50)...
const SPLIT_WITHIN := 0.10
## ...and holding at least this share of the deck on its own.
const SPLIT_MIN_SHARE := 0.30


## The deck's dominant colours (0.19.0), in ORDER. Every colour of a card
## counts for that colour. One entry for a normal deck; two or more when the
## deck is split: a colour counts as co-dominant when it is within
## SPLIT_WITHIN of the leader's count and holds at least SPLIT_MIN_SHARE of
## the deck. So 25/25 and 26/24 are splits; 30/20 is not.
static func deck_colours(deck: Dictionary) -> Array:
	var count := {}
	var n := 0
	for id in deck.get("main", []):
		var cd: CardData = CardDB.get_card(str(id))
		if cd == null:
			continue
		n += 1
		for c in cd.colors:
			var cname := str(BSS.COLOR_NAMES[int(c)]) if int(c) >= 0 and int(c) < BSS.COLOR_NAMES.size() else "red"
			count[cname] = int(count.get(cname, 0)) + 1
	if count.is_empty() or n == 0:
		return ["red"]
	var most := 0
	for k in count:
		most = maxi(most, int(count[k]))
	var out: Array = []
	for k in ORDER:
		var v := int(count.get(k, 0))
		if v == most or (v >= most - SPLIT_WITHIN * n and v >= SPLIT_MIN_SHARE * n):
			out.append(k)
	return out


func _ready() -> void:
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	_board_pos = board.position
	shown_this_session = true
	AudioManager.play_sfx("gate_" + ("burst" if variant == "burst" else variant))
	match variant:
		"core":
			_play_core()
		"burst":
			_play_burst()
		_:
			_play_isekai()


func _input(event: InputEvent) -> void:
	if _done:
		return
	if (event is InputEventMouseButton and event.pressed) or (event is InputEventKey and event.pressed) \
			or (event is InputEventScreenTouch and event.pressed):
		_finish()


func _finish() -> void:
	if _done:
		return
	_done = true
	for t in _tweens:
		if t != null and t.is_valid():
			t.kill()
	if is_instance_valid(board):
		board.position = _board_pos
		board.scale = Vector2.ONE
		board.modulate = Color.WHITE
	finished.emit()
	queue_free()


func _tween() -> Tween:
	var t := create_tween()
	_tweens.append(t)
	return t


func _colour(cname: String) -> Color:
	return RGB.get(cname, RGB["red"])


# ============================================================================
# Building blocks
# ============================================================================

func _size() -> Vector2:
	return _root.get_viewport_rect().size


func _centre() -> Vector2:
	return _size() / 2.0


func _rect(color: Color) -> ColorRect:
	var r := ColorRect.new()
	r.color = color
	r.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(r)
	return r


static func _additive() -> CanvasItemMaterial:
	var m := CanvasItemMaterial.new()
	m.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	return m


static var _glow_tex: GradientTexture2D


## A soft radial glow sprite (additive), centred on `pos`.
func _glow(pos: Vector2, radius: float, color: Color, alpha: float = 1.0) -> Sprite2D:
	if _glow_tex == null:
		var g := Gradient.new()
		g.set_color(0, Color(1, 1, 1, 1))
		g.set_color(1, Color(1, 1, 1, 0))
		g.add_point(0.35, Color(1, 1, 1, 0.45))
		_glow_tex = GradientTexture2D.new()
		_glow_tex.gradient = g
		_glow_tex.fill = GradientTexture2D.FILL_RADIAL
		_glow_tex.fill_from = Vector2(0.5, 0.5)
		_glow_tex.fill_to = Vector2(0.5, 0.0)
		_glow_tex.width = 256
		_glow_tex.height = 256
	var s := Sprite2D.new()
	s.texture = _glow_tex
	s.material = _additive()
	s.position = pos
	s.scale = Vector2.ONE * (radius * 2.0 / 256.0)
	s.modulate = Color(color.r, color.g, color.b, alpha)
	_root.add_child(s)
	return s


## A colour symbol (the game's own picture) centred on `pos`.
func _symbol(cname: String, pos: Vector2, px: float) -> TextureRect:
	var t := TextureRect.new()
	t.texture = UITheme.symbol_texture(_colour_index(cname), int(px))
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	t.size = Vector2(px, px)
	t.pivot_offset = t.size / 2.0
	t.position = pos - t.size / 2.0
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(t)
	return t


static func _colour_index(cname: String) -> int:
	return maxi(0, ORDER.find(cname))


## The deck's colours as the shader wants them: six entries, ncol used.
func _cols_param() -> PackedColorArray:
	var out := PackedColorArray()
	for i in 6:
		out.append(_colour(str(mine[mini(i, mine.size() - 1)])))
	return out


func _spectrum_material(x0: float, x1: float, textured: bool) -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = SPECTRUM_TINT
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("cols", _cols_param())
	m.set_shader_parameter("ncol", mine.size())
	m.set_shader_parameter("x0", x0)
	m.set_shader_parameter("x1", x1)
	m.set_shader_parameter("textured", textured)
	return m


## Big word in the display font with an outline and a soft glow behind it.
## `spectrum` draws the glow through every dominant colour instead of `color`.
func _word(text: String, y: float, px: int, color: Color, spectrum: bool = false) -> Control:
	var holder := Control.new()
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(holder)
	holder.position = Vector2(0, y)
	holder.size = Vector2(_size().x, px * 1.3)
	holder.pivot_offset = holder.size / 2.0
	for pass_i in 3:
		var l := Label.new()
		l.text = text
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var ls := LabelSettings.new()
		ls.font = load("res://assets/fonts/InterDisplay-Black.otf")
		ls.font_size = px
		if pass_i < 2:
			# glow passes: the word in the colour, additive, with a wide soft outline
			var gc := Color.WHITE if spectrum and mine.size() > 1 else color
			ls.font_color = Color(gc.r, gc.g, gc.b, 0.55 if pass_i == 0 else 0.3)
			ls.outline_size = int(px * (0.2 if pass_i == 0 else 0.42))
			ls.outline_color = Color(gc.r, gc.g, gc.b, 0.45 if pass_i == 0 else 0.18)
			if spectrum and mine.size() > 1:
				var w: float = ls.font.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1, px).x
				var sw := _size().x
				l.material = _spectrum_material((sw - w) * 0.5 / sw, (sw + w) * 0.5 / sw, true)
			else:
				l.material = _additive()
		else:
			ls.font_color = Color(1, 0.98, 0.94)
			ls.outline_size = int(px * 0.07)
			ls.outline_color = Color(0.05, 0.03, 0.05)
			ls.shadow_color = Color(0, 0, 0, 0.6)
			ls.shadow_offset = Vector2(0, px * 0.06)
		l.label_settings = ls
		holder.add_child(l)
		l.position = Vector2.ZERO
		l.size = holder.size
	return holder


func _particles(pos: Vector2, color: Color, amount: int, speed: float, life: float, spread: float = 180.0,
		dir: Vector2 = Vector2.UP, size: float = 4.0) -> CPUParticles2D:
	var p := CPUParticles2D.new()
	p.position = pos
	p.amount = amount
	p.lifetime = life
	p.explosiveness = 0.0
	p.direction = dir
	p.spread = spread
	p.initial_velocity_min = speed * 0.4
	p.initial_velocity_max = speed
	p.gravity = Vector2.ZERO
	p.damping_min = speed * 0.2
	p.damping_max = speed * 0.5
	p.scale_amount_min = size * 0.4
	p.scale_amount_max = size
	p.color = color
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1, 1, 1, 0))
	ramp.add_point(0.15, Color(1, 1, 1, 1))
	ramp.set_color(ramp.get_point_count() - 1, Color(1, 1, 1, 0))
	p.color_ramp = ramp
	p.material = _additive()
	_root.add_child(p)
	return p


## A full-screen shader quad.
func _shader_rect(code: String) -> ColorRect:
	var r := _rect(Color.WHITE)
	var sh := Shader.new()
	sh.code = code
	var m := ShaderMaterial.new()
	m.shader = sh
	r.material = m
	return r


func _param(r: ColorRect, k: String, v: Variant) -> void:
	(r.material as ShaderMaterial).set_shader_parameter(k, v)


func _tween_param(tw: Tween, r: ColorRect, k: String, from: float, to: float, dur: float, ease_kind := Tween.EASE_IN_OUT,
		trans := Tween.TRANS_SINE) -> void:
	_param(r, k, from)
	tw.tween_method(func(v: float): _param(r, k, v), from, to, dur).set_ease(ease_kind).set_trans(trans)


# ============================================================================
# Shaders
# ============================================================================

## The gate seen from the front and the tunnel beyond it: concentric rings of
## light racing inward, streaks on the walls, a warm core where the world is.
const TUNNEL := """
shader_type canvas_item;
uniform float t = 0.0;
uniform float open = 0.0;        // radius of the opening, 0..1.3
uniform float travel = 0.0;      // 0 = looking at the gate, 1 = deep in the tunnel
uniform float fade = 1.0;
uniform vec4 col : source_color = vec4(0.9, 0.3, 0.3, 1.0);
uniform vec4 cols[6];            // the deck's colours (0.19.0); ncol of them are used
uniform int ncol = 1;
uniform vec2 aspect = vec2(1.777, 1.0);
float hash(float n) { return fract(sin(n) * 43758.5453); }
float hash2(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
// the colour at a point of the ring, u in 0..1 around it: one colour, or a
// spectrum running through every dominant colour and back (a split deck)
vec3 spectrum(float u) {
	if (ncol <= 1) return cols[0].rgb;
	float x = fract(u) * float(ncol);
	int i = int(floor(x));
	int j = (i + 1) % ncol;
	float f = smoothstep(0.15, 0.85, fract(x));
	return mix(cols[i].rgb, cols[j].rgb, f);
}
void fragment() {
	vec2 uv = (UV - 0.5) * aspect;
	float r = length(uv);
	float a = atan(uv.y, uv.x);
	float depth = 0.16 / max(r, 0.004) + t * (1.5 + 7.0 * travel);
	// streaks on the walls: many thin lines of random length, brightness and width
	float an = a / 6.2832 + 0.5;
	vec3 ccol = spectrum(an);     // this point's colour: the leading colour sits at the left
	float s_total = 0.0;
	for (int k = 0; k < 3; k++) {
		float n = 60.0 + 40.0 * float(k);
		float lane = floor(an * n);
		float within = fract(an * n);
		float seed = lane + float(k) * 97.0;
		float speed = 0.6 + hash(seed) * 1.4;
		float d = depth * speed + hash(seed + 1.0) * 10.0;
		float len = 0.25 + hash(seed + 2.0) * 0.5;
		float along = smoothstep(0.0, 0.15, fract(d)) * smoothstep(len, len - 0.2, fract(d));
		float width = 0.08 + hash(seed + 3.0) * 0.25;
		float across = smoothstep(width, 0.0, abs(within - 0.5));
		s_total += along * across * (0.35 + 0.65 * hash(seed + 4.0));
	}
	// faint rings racing past, fading with distance
	float ringv = smoothstep(0.9, 1.0, fract(depth * 0.5)) * 0.35;
	float core = exp(-r * (5.5 - 3.5 * travel));
	float fog = smoothstep(0.0, 0.5, r);               // the walls dim toward the camera's edges
	vec3 warm = vec3(1.0, 0.95, 0.85);
	vec3 wall = ccol * (s_total * (0.5 + travel) + ringv) * mix(1.0, 0.75, fog);
	vec3 c = wall + warm * core * (0.5 + 0.9 * travel) + ccol * core * 0.6;
	float inside = smoothstep(open, open - 0.05, r);
	float rim = smoothstep(0.035, 0.0, abs(r - open)) * (1.0 - travel);
	float rimglow = smoothstep(0.16, 0.0, abs(r - open)) * (1.0 - travel) * 0.5;
	vec3 outc = c * inside + (warm * 1.5 + ccol) * rim + ccol * rimglow;
	float alpha = clamp(inside * (0.4 + 0.6 * travel) + rim + rimglow, 0.0, 1.0) * fade;
	COLOR = vec4(outc, alpha);
}
"""

## A tint that runs left to right through the deck's colours (0.19.0): on the
## glow passes of a word (additive, over the font texture) and on the line the
## board rises behind. x0..x1 are the span in screen UV; one colour is flat.
const SPECTRUM_TINT := """
shader_type canvas_item;
render_mode blend_add;
uniform vec4 cols[6];
uniform int ncol = 1;
uniform float x0 = 0.0;
uniform float x1 = 1.0;
uniform bool textured = true;
vec3 across(float u) {
	if (ncol <= 1) return cols[0].rgb;
	float x = clamp(u, 0.0, 1.0) * float(ncol - 1);
	int i = int(floor(min(x, float(ncol - 1) - 0.001)));
	float f = smoothstep(0.2, 0.8, x - float(i));
	return mix(cols[i].rgb, cols[i + 1].rgb, f);
}
void fragment() {
	vec4 c = textured ? texture(TEXTURE, UV) * COLOR : COLOR;
	float u = (SCREEN_UV.x - x0) / max(x1 - x0, 0.001);
	COLOR = vec4(c.rgb * across(u), c.a);
}
"""


## A hexagonal field on a ground plane in perspective, lit from the centre
## out; the near half in one colour, the far half in the other.
const HEXFIELD := """
shader_type canvas_item;
uniform float reveal = 0.0;      // 0..1.4, how far from the centre the panels exist
uniform float fade = 1.0;
uniform float horizon = 0.42;
uniform vec4 near_col : source_color = vec4(0.9, 0.3, 0.3, 1.0);
uniform vec4 far_col : source_color = vec4(0.3, 0.6, 1.0, 1.0);
uniform vec2 aspect = vec2(1.777, 1.0);
vec4 hexcell(vec2 p) {
	// axial hex grid; returns cell centre (xy) and distance to the edge (z)
	vec2 s = vec2(1.0, 1.7320508);
	vec4 hc = floor(vec4(p, p - vec2(0.5, 1.0)) / s.xyxy) + 0.5;
	vec4 h = vec4(p - hc.xy * s, p - (hc.zw + 0.5) * s);
	vec2 cell = dot(h.xy, h.xy) < dot(h.zw, h.zw) ? hc.xy * s : (hc.zw + 0.5) * s;
	vec2 d = p - cell;
	float e = max(abs(d.y), abs(d.x) * 0.866 + abs(d.y) * 0.5) / 0.5;
	return vec4(cell, e, 0.0);
}
void fragment() {
	vec2 uv = UV;
	float below = uv.y - horizon;
	if (below <= 0.002) { COLOR = vec4(0.0); }
	else {
		float z = 0.35 / below;                      // depth along the ground
		float x = (uv.x - 0.5) * aspect.x * z * 2.2;
		vec2 p = vec2(x, z * 1.15) * 0.9;
		vec4 hc = hexcell(p);
		vec2 cc = hc.xy;
		float dist = length(vec2(cc.x, (cc.y - 1.9) * 1.1));   // from the field's centre
		float born = dist / 4.2;
		float a = smoothstep(born - 0.08, born + 0.08, reveal);
		float mid = 1.9;
		vec3 base = cc.y < mid ? near_col.rgb : far_col.rgb;
		float edge = smoothstep(0.80, 0.97, hc.z);
		float seam = smoothstep(0.08, 0.0, abs(cc.y - mid));
		vec3 c = base * (0.10 + 0.08 * (1.0 - hc.z)) + base * edge * 1.2 + vec3(1.0, 0.98, 0.9) * seam * 0.4;
		// haze with distance, light bloom near the centre as it is revealed
		float haze = smoothstep(14.0, 2.0, z);
		float bloom = smoothstep(1.2, 0.0, dist) * smoothstep(0.0, 0.3, reveal) * 0.4;
		c += base * bloom;
		float alpha = a * haze * fade;
		COLOR = vec4(c, alpha);
	}
}
"""

# ============================================================================
# A -- "Isekai Gate"
# ============================================================================

func _play_isekai() -> void:
	var c := _centre()
	var sz := _size()
	var col := _colour(me)
	var black := _rect(Color8(5, 4, 9))
	var tunnel := _shader_rect(TUNNEL)
	_param(tunnel, "col", col)
	_param(tunnel, "cols", _cols_param())
	_param(tunnel, "ncol", mine.size())
	_param(tunnel, "aspect", Vector2(sz.x / sz.y, 1.0))
	_param(tunnel, "open", 0.0)
	# the ignition: one symbol per dominant colour, side by side, each with its
	# own glow and sparks (one of each for a normal deck)
	var n := mine.size()
	var sym_px := 150.0 if n == 1 else (130.0 if n == 2 else 110.0)
	var gap := sym_px * 1.25
	var glows: Array[Sprite2D] = []
	var syms: Array[TextureRect] = []
	var sparks_all: Array[CPUParticles2D] = []
	for i in n:
		var cn := str(mine[i])
		var ci := _colour(cn)
		var pos := c + Vector2((i - (n - 1) * 0.5) * gap, 0)
		glows.append(_glow(pos, 220.0 if n == 1 else 170.0, ci, 0.0))
		var sy := _symbol(cn, pos, sym_px)
		sy.modulate = Color(1, 1, 1, 0)
		syms.append(sy)
		var sp := _particles(pos, Color(ci.r, ci.g, ci.b, 1), int(90.0 / n), 420, 1.1, 180, Vector2.UP, 5)
		sp.emitting = false
		sparks_all.append(sp)
	var sym := syms[0]
	# embers drawn into the gate as it opens, then streaming past during the travel
	var embers := _particles(c, Color(1.0, 0.92, 0.8, 1), 140, 900, 0.9, 180, Vector2.UP, 3)
	embers.emitting = false
	var gate_word := _word("GATE OPEN", sz.y * 0.04, int(sz.y * 0.12), WARM)
	gate_word.modulate.a = 0
	var kaiho := _word("KAIHO!", sz.y * 0.80, int(sz.y * 0.14), col, true)
	kaiho.modulate.a = 0
	kaiho.scale = Vector2(1.6, 1.6)
	# the light at the end of the tunnel, and the afterglow the board rises
	# through: one glow per dominant colour, spread across the screen
	var light := _glow(c, 420, Color(1.0, 0.97, 0.9), 0.0)
	var afters: Array[Sprite2D] = []
	for i in n:
		var ax := c.x + (i - (n - 1) * 0.5) * sz.x * (0.0 if n == 1 else 0.5 / (n - 1) * 1.2)
		afters.append(_glow(Vector2(ax, sz.y * 0.35), 900.0 if n == 1 else 760.0, _colour(str(mine[i])), 0.0))
	var flash := _rect(Color(1, 0.98, 0.93, 0))
	var clock := _tween().set_loops()
	clock.tween_method(func(v: float): _param(tunnel, "t", v), 0.0, 1000.0, 1000.0)

	var tw := _tween()
	# 1. ignite
	tw.tween_property(sym, "modulate:a", 1.0, 0.7).set_ease(Tween.EASE_OUT)
	for i in n:
		if i > 0:
			tw.parallel().tween_property(syms[i], "modulate:a", 1.0, 0.7).set_ease(Tween.EASE_OUT)
		tw.parallel().tween_property(glows[i], "modulate:a", 0.8, 0.9)
		tw.parallel().tween_property(glows[i], "scale", glows[i].scale * 2.4, 1.1).set_ease(Tween.EASE_OUT)
		tw.parallel().tween_property(syms[i], "scale", Vector2(1.25, 1.25), 1.1).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(gate_word, "modulate:a", 1.0, 0.5).set_delay(0.4)
	tw.tween_callback(func():
		for sp in sparks_all:
			sp.emitting = true)
	# 2. the gate blooms
	var open_dur := 1.1
	_tween_param(tw, tunnel, "open", 0.0, 0.34 if n == 1 else 0.34 + 0.05 * (n - 1), open_dur, Tween.EASE_OUT, Tween.TRANS_CUBIC)
	for i in n:
		tw.parallel().tween_property(syms[i], "scale", Vector2(0.6, 0.6), open_dur)
		tw.parallel().tween_property(syms[i], "modulate:a", 0.0, open_dur * 0.8)
	tw.parallel().tween_property(kaiho, "modulate:a", 1.0, 0.25).set_delay(0.55)
	tw.parallel().tween_property(kaiho, "scale", Vector2.ONE, 0.3).set_delay(0.55).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	tw.tween_callback(func(): embers.emitting = true)
	tw.tween_interval(0.35)
	# 3. through the gate: the opening swallows the screen, the walls stream past, light grows ahead
	var go := 2.0
	_tween_param(tw, tunnel, "open", 0.34 if n == 1 else 0.34 + 0.05 * (n - 1), 1.3, go * 0.6, Tween.EASE_IN, Tween.TRANS_QUAD)
	tw.parallel().tween_method(func(v: float): _param(tunnel, "travel", v), 0.0, 1.0, go)
	tw.parallel().tween_property(gate_word, "modulate:a", 0.0, 0.5)
	tw.parallel().tween_property(kaiho, "modulate:a", 0.0, 0.5)
	for g in glows:
		tw.parallel().tween_property(g, "modulate:a", 0.0, 0.6)
	tw.parallel().tween_property(light, "modulate:a", 1.0, go).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_CUBIC)
	tw.parallel().tween_property(light, "scale", light.scale * 2.6, go).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_CUBIC)
	tw.parallel().tween_property(embers, "initial_velocity_max", 2200.0, go)
	# 4. arrival flash; the tunnel fades
	tw.tween_property(flash, "color:a", 1.0, 0.18)
	tw.parallel().tween_method(func(v: float): _param(tunnel, "fade", v), 1.0, 0.0, 0.3)
	tw.tween_callback(func():
		for sp in sparks_all:
			sp.emitting = false
		embers.emitting = false
		light.visible = false
		for a in afters:
			a.modulate.a = 0.55 if n == 1 else 0.45
		board.position = _board_pos + Vector2(0, sz.y * 0.95))
	tw.tween_property(flash, "color:a", 0.0, 0.5)
	# 5. the board rises through the afterglow; a line of the deck's colour(s) at its top edge
	var line := ColorRect.new()
	line.color = Color(col.r, col.g, col.b, 0) if n == 1 else Color(1, 1, 1, 0)
	if n > 1:
		line.material = _spectrum_material(0.0, 1.0, false)
	line.size = Vector2(sz.x, 5)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(line)
	tw.parallel().tween_property(line, "color:a", 1.0, 0.2)
	tw.parallel().tween_property(board, "position", _board_pos, 1.1).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tw.parallel().tween_method(func(v: float): line.position.y = _board_pos.y + sz.y * 0.95 * (1.0 - v) - 2.0, 0.0, 1.0, 1.1).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tw.parallel().tween_property(black, "color:a", 0.0, 0.9).set_delay(0.2)
	for a in afters:
		tw.parallel().tween_property(a, "modulate:a", 0.0, 1.0).set_delay(0.3)
	tw.parallel().tween_property(line, "color:a", 0.0, 0.3).set_delay(0.9)
	tw.tween_callback(_finish)


# ============================================================================
# B -- "Core Gate"
# ============================================================================

func _play_core() -> void:
	var c := _centre()
	var sz := _size()
	var col := _colour(me)
	var ocol := _colour(opp)
	var black := _rect(Color8(5, 7, 14))
	var field := _shader_rect(HEXFIELD)
	_param(field, "near_col", col)
	_param(field, "far_col", ocol)
	_param(field, "aspect", Vector2(sz.x / sz.y, 1.0))
	_param(field, "reveal", 0.0)
	var mid := Vector2(c.x, sz.y * 0.56)
	var gl := _glow(Vector2(-200, mid.y), 150, col, 0.6)
	var gr := _glow(Vector2(sz.x + 200, mid.y), 150, ocol, 0.6)
	var sl := _symbol(me, Vector2(-200, mid.y), 120)
	var sr := _symbol(opp, Vector2(sz.x + 200, mid.y), 120)
	var gate_word := _word("GATE OPEN", sz.y * 0.12, int(sz.y * 0.12), WARM)
	gate_word.modulate.a = 0
	var kaiho := _word("KAIHO!", sz.y * 0.78, int(sz.y * 0.14), col)
	kaiho.modulate.a = 0
	kaiho.scale = Vector2(1.6, 1.6)
	# cores: small glowing orbs that orbit in from both symbols
	var cores: Array[Sprite2D] = []
	var core_col := Color8(150, 205, 255)
	for i in 24:
		var s := _glow(mid, 16, core_col, 0.0)
		var dot := _glow(mid, 6, Color.WHITE, 0.0)
		cores.append(s)
		cores.append(dot)
	var ring_line := Line2D.new()
	ring_line.width = 2.0
	ring_line.default_color = Color(core_col.r, core_col.g, core_col.b, 0.0)
	ring_line.material = _additive()
	for i in 97:
		var ang := i * TAU / 96.0
		ring_line.add_point(mid + Vector2(cos(ang) * 240.0, sin(ang) * 100.0))
	_root.add_child(ring_line)
	var flash := _rect(Color(0.8, 0.9, 1.0, 0))

	var xl := sz.x * 0.5 - 330.0
	var xr := sz.x * 0.5 + 330.0
	var tw := _tween()
	# 1. face off
	tw.tween_property(sl, "position", Vector2(xl, mid.y) - sl.size / 2.0, 0.9).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tw.parallel().tween_property(sr, "position", Vector2(xr, mid.y) - sr.size / 2.0, 0.9).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tw.parallel().tween_property(gl, "position", Vector2(xl, mid.y), 0.9).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tw.parallel().tween_property(gr, "position", Vector2(xr, mid.y), 0.9).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tw.parallel().tween_property(gate_word, "modulate:a", 1.0, 0.5).set_delay(0.4)
	# 2. cores stream out and settle into a ring
	var orbit := 1.5
	tw.tween_method(func(v: float):
		for i in 24:
			var from_left := i % 2 == 0
			var origin := Vector2(xl if from_left else xr, mid.y)
			var ang := i * TAU / 24.0 + v * 2.2
			var target := mid + Vector2(cos(ang) * 240.0, sin(ang) * 100.0)
			var k := clampf(v * 1.3 - (i % 6) * 0.05, 0.0, 1.0)
			k = k * k * (3.0 - 2.0 * k)
			var p := origin.lerp(target, k)
			cores[i * 2].position = p
			cores[i * 2 + 1].position = p
			cores[i * 2].modulate.a = minf(1.0, v * 3.0) * 0.9
			cores[i * 2 + 1].modulate.a = minf(1.0, v * 3.0)
		ring_line.default_color.a = clampf(v * 1.5 - 0.4, 0.0, 0.8)
		, 0.0, 1.0, orbit)
	tw.parallel().tween_property(gl, "scale", gl.scale * 1.4, orbit)
	tw.parallel().tween_property(gr, "scale", gr.scale * 1.4, orbit)
	# 3. the field assembles outward from the ring
	var build := 1.9
	_tween_param(tw, field, "reveal", 0.0, 1.4, build, Tween.EASE_OUT, Tween.TRANS_QUAD)
	tw.parallel().tween_property(kaiho, "modulate:a", 1.0, 0.25).set_delay(0.3)
	tw.parallel().tween_property(kaiho, "scale", Vector2.ONE, 0.3).set_delay(0.3).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	tw.parallel().tween_method(func(v: float):
		for i in 24:
			var ang := i * TAU / 24.0 + (orbit + v * build) * 2.2
			var p := mid + Vector2(cos(ang) * 240.0, sin(ang) * 100.0)
			cores[i * 2].position = p
			cores[i * 2 + 1].position = p
		, 0.0, 1.0, build)
	# 4. tilt down onto the board: the board starts larger (closer) and settles
	tw.tween_callback(func():
		board.pivot_offset = board.size / 2.0
		board.scale = Vector2(1.22, 1.22)
		board.modulate = Color(1, 1, 1, 0))
	var settle := 1.1
	tw.tween_property(flash, "color:a", 0.75, 0.15)
	tw.parallel().tween_property(board, "modulate:a", 1.0, settle * 0.5)
	tw.parallel().tween_property(board, "scale", Vector2.ONE, settle).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tw.parallel().tween_method(func(v: float): _param(field, "fade", v), 1.0, 0.0, settle * 0.7)
	tw.parallel().tween_property(black, "color:a", 0.0, settle * 0.5)
	tw.parallel().tween_property(gate_word, "modulate:a", 0.0, 0.4)
	tw.parallel().tween_property(kaiho, "modulate:a", 0.0, 0.4)
	tw.parallel().tween_property(ring_line, "default_color:a", 0.0, 0.4)
	tw.parallel().tween_property(sl, "modulate:a", 0.0, 0.4)
	tw.parallel().tween_property(sr, "modulate:a", 0.0, 0.4)
	tw.parallel().tween_property(gl, "modulate:a", 0.0, 0.4)
	tw.parallel().tween_property(gr, "modulate:a", 0.0, 0.4)
	for s in cores:
		tw.parallel().tween_property(s, "modulate:a", 0.0, 0.4)
	tw.tween_property(flash, "color:a", 0.0, 0.5)
	tw.tween_callback(_finish)


# ============================================================================
# C -- "Burst Through"
# ============================================================================

func _play_burst() -> void:
	var c := _centre()
	var sz := _size()
	var col := _colour(me)
	# the dark cover that will shatter: built from triangles so it can break.
	# A solid backdrop sits behind the pieces until then, so their seams never show.
	var backdrop := _rect(Color8(6, 5, 10))
	var cover := Control.new()
	cover.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cover.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(cover)
	var shards := _make_shards(cover, sz, col)
	var glow := _glow(c, 320, col, 0.0)
	var cracks := _lightning(c, sz, col)                # [{line, glow, points}], grown over time
	var card := TextureRect.new()
	card.texture = load("res://assets/ui/card_back.png")   # the deck, face down, as a battler holds it
	card.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	card.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var ch := sz.y * 0.52
	card.size = Vector2(ch * 600.0 / 838.0, ch)
	card.pivot_offset = card.size / 2.0
	card.position = c - card.size / 2.0 - Vector2(0, sz.y * 0.5)
	card.scale = Vector2(2.0, 2.0)
	card.modulate = Color(1, 1, 1, 0)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(card)
	var sparks := _particles(c, Color(col.r, col.g, col.b, 1), 160, 900, 0.7, 180, Vector2.UP, 6)
	sparks.explosiveness = 0.9
	sparks.one_shot = true
	sparks.emitting = false
	var gate_word := _word("GATE OPEN", sz.y * 0.1, int(sz.y * 0.12), WARM)
	gate_word.modulate.a = 0
	var kaiho := _word("KAIHO!", sz.y * 0.76, int(sz.y * 0.16), col)
	kaiho.modulate.a = 0
	kaiho.scale = Vector2(1.8, 1.8)
	var flash := _rect(Color(1, 0.98, 0.93, 0))

	var tw := _tween()
	# 1. the key card drops and slams
	tw.tween_property(card, "modulate:a", 1.0, 0.1)
	tw.parallel().tween_property(card, "position", c - card.size / 2.0, 0.5).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUART)
	tw.parallel().tween_property(card, "scale", Vector2.ONE, 0.5).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUART)
	tw.tween_callback(func():
		sparks.restart()
		sparks.emitting = true
		_shake(cover, 14.0, 0.35)
		_shake(card, 10.0, 0.35))
	tw.tween_property(glow, "modulate:a", 1.0, 0.12)
	tw.parallel().tween_property(glow, "scale", glow.scale * 1.8, 0.4).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(gate_word, "modulate:a", 1.0, 0.15)
	# 2. cracks of light spread
	tw.tween_method(func(v: float): _grow_lightning(cracks, v), 0.0, 1.0, 0.7).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tw.parallel().tween_property(kaiho, "modulate:a", 1.0, 0.2).set_delay(0.15)
	tw.parallel().tween_property(kaiho, "scale", Vector2.ONE, 0.25).set_delay(0.15).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	tw.tween_interval(0.15)
	# 3. shatter: the dark flies apart; the board is behind, a touch closer, settling
	tw.tween_callback(func():
		board.pivot_offset = board.size / 2.0
		board.scale = Vector2(1.12, 1.12)
		backdrop.visible = false
		for ck in cracks:
			(ck["line"] as Line2D).visible = false
			(ck["glow"] as Line2D).visible = false
		for s in shards:
			var poly: Polygon2D = s["poly"]
			var dir: Vector2 = s["dir"]
			var st := _tween()
			st.tween_property(poly, "position", dir * (sz.x * 0.9 + randf() * sz.x * 0.6), 0.75).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
			st.parallel().tween_property(poly, "rotation", randf_range(-2.5, 2.5), 0.75)
			st.parallel().tween_property(poly, "modulate:a", 0.0, 0.6).set_delay(0.15))
	tw.tween_property(flash, "color:a", 0.9, 0.08)
	tw.parallel().tween_property(card, "modulate:a", 0.0, 0.2)
	tw.parallel().tween_property(glow, "modulate:a", 0.0, 0.3)
	tw.parallel().tween_property(gate_word, "modulate:a", 0.0, 0.3)
	tw.parallel().tween_property(kaiho, "modulate:a", 0.0, 0.3)
	tw.tween_property(flash, "color:a", 0.0, 0.45)
	tw.parallel().tween_property(board, "scale", Vector2.ONE, 0.8).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tw.tween_callback(_finish)


## The dark cover cut into triangles that radiate from the centre, each with
## a thin rim in the deck's colour so the breaking edges catch the light.
func _make_shards(parent: Control, sz: Vector2, col: Color) -> Array:
	var c := sz / 2.0
	var pts := PackedVector2Array()
	var rnd := RandomNumberGenerator.new()
	rnd.seed = 11
	pts.append(Vector2(0, 0))
	pts.append(Vector2(sz.x, 0))
	pts.append(Vector2(sz.x, sz.y))
	pts.append(Vector2(0, sz.y))
	for i in 10:                                       # edge points
		pts.append(Vector2(sz.x * (i + 0.5) / 10.0, 0))
		pts.append(Vector2(sz.x * (i + 0.5) / 10.0, sz.y))
	for i in 6:
		pts.append(Vector2(0, sz.y * (i + 0.5) / 6.0))
		pts.append(Vector2(sz.x, sz.y * (i + 0.5) / 6.0))
	for i in 46:                                       # inner points, denser near the centre
		var ang := rnd.randf() * TAU
		var r := pow(rnd.randf(), 0.7) * sz.x * 0.55
		pts.append((c + Vector2(cos(ang), sin(ang) * 0.75) * r).clamp(Vector2.ZERO, sz))
	var tris := Geometry2D.triangulate_delaunay(pts)
	var out: Array = []
	for i in range(0, tris.size(), 3):
		var tri := PackedVector2Array([pts[tris[i]], pts[tris[i + 1]], pts[tris[i + 2]]])
		var poly := Polygon2D.new()
		poly.polygon = tri
		poly.color = Color8(6, 5, 10)
		parent.add_child(poly)
		var rim := Line2D.new()
		rim.points = PackedVector2Array([tri[0], tri[1], tri[2], tri[0]])
		rim.width = 1.5
		rim.default_color = Color(col.r, col.g, col.b, 0.0)
		rim.material = _additive()
		poly.add_child(rim)
		var centroid: Vector2 = (tri[0] + tri[1] + tri[2]) / 3.0
		out.append({"poly": poly, "dir": (centroid - c).normalized() if centroid != c else Vector2.UP})
	# the rims light up as the cracks spread
	var tw := _tween().set_parallel(true)
	for s in out:
		tw.tween_property(s["poly"].get_child(0), "default_color:a", 0.9, 0.2).set_delay(1.05)
	return out


## Jagged bolts from the centre, with a few branches: each is a Line2D and a
## wider, fainter twin for the glow. Grown point by point by _grow_lightning.
func _lightning(c: Vector2, sz: Vector2, col: Color) -> Array:
	var rnd := RandomNumberGenerator.new()
	rnd.seed = 23
	var out: Array = []
	var bolts := 14
	for i in bolts:
		var ang := i * TAU / bolts + rnd.randf_range(-0.18, 0.18)
		var pts := PackedVector2Array([c])
		var p := c
		var reach := sz.x * rnd.randf_range(0.45, 0.8)
		var step := reach / 18.0
		for k in 18:
			ang += rnd.randf_range(-0.55, 0.55)
			p += Vector2(cos(ang), sin(ang)) * step * rnd.randf_range(0.6, 1.4)
			pts.append(p)
			if k == 7 or k == 12:                     # a branch
				var bang := ang + rnd.randf_range(-1.2, 1.2) * (1 if rnd.randf() > 0.5 else -1)
				var bp := p
				var bpts := PackedVector2Array([p])
				for j in 7:
					bang += rnd.randf_range(-0.5, 0.5)
					bp += Vector2(cos(bang), sin(bang)) * step * 0.7
					bpts.append(bp)
				out.append(_bolt(bpts, col, 2.0, 0.5 + float(k) / 18.0))
		out.append(_bolt(pts, col, 3.5, 0.0))
	return out


func _bolt(pts: PackedVector2Array, col: Color, width: float, begin_at: float) -> Dictionary:
	var glow := Line2D.new()
	glow.width = width * 5.0
	glow.default_color = Color(col.r, col.g, col.b, 0.35)
	glow.material = _additive()
	glow.joint_mode = Line2D.LINE_JOINT_ROUND
	glow.begin_cap_mode = Line2D.LINE_CAP_ROUND
	glow.end_cap_mode = Line2D.LINE_CAP_ROUND
	_root.add_child(glow)
	var line := Line2D.new()
	line.width = width
	line.default_color = Color(1.0, 0.97, 0.9, 1.0)
	line.material = _additive()
	line.joint_mode = Line2D.LINE_JOINT_ROUND
	_root.add_child(line)
	return {"line": line, "glow": glow, "points": pts, "start": begin_at}


func _grow_lightning(bolts: Array, v: float) -> void:
	for b in bolts:
		var pts: PackedVector2Array = b["points"]
		var local := clampf((v - float(b["start"]) * 0.6) / 0.6, 0.0, 1.0)
		var n := int(round(local * pts.size()))
		var shown := pts.slice(0, maxi(0, n))
		(b["line"] as Line2D).points = shown
		(b["glow"] as Line2D).points = shown
		# flicker
		(b["line"] as Line2D).modulate.a = 0.75 + 0.25 * sin(v * 60.0 + float(b["start"]) * 9.0)


func _shake(node: Control, strength: float, dur: float) -> void:
	var origin := node.position
	var tw := _tween()
	var steps := int(dur * 30.0)
	for i in steps:
		var k := 1.0 - float(i) / steps
		tw.tween_property(node, "position", origin + Vector2(randf_range(-1, 1), randf_range(-1, 1)) * strength * k, dur / steps)
	tw.tween_property(node, "position", origin, dur / steps)
