extends RefCounted
class_name UITheme
##
## The design system: palette, type, spacing, a global Godot Theme, and a small
## set of widget factories.
##
## TWO LAYERS, ON PURPOSE
##
## 1. build_theme() returns a Theme that SceneRouter assigns to the root window
##    at startup. Every Control in the game inherits it, which is what styles
##    the controls nobody builds through a helper: OptionButton dropdowns and
##    their popups, SpinBoxes, CheckBoxes, scrollbars, sliders, tooltips. Before
##    0.6.0 those used Godot's default grey skin, and the mix of styled and
##    unstyled controls is most of why the old UI looked broken.
##
## 2. The static helpers (panel, button, heading...) handle the cases a theme
##    cannot express cleanly: variants such as primary/danger buttons, display
##    headings in a second font, and the click sound every button makes.
##
## Nothing here is referenced by the rules engine, so it is safe to restyle.
## Change a colour below and the whole game follows.
##

# --- Palette ----------------------------------------------------------------
# "Gilded Ink" (0.16.0): a dark ink-blue space with thin gold frames. The six
# card colours appear only as meaning (filters, deck identity, stats), cores
# are the pip language, and the soul-core gradient is reserved for the one
# primary action on a screen. Gold is never body text.
const BG_0       := Color("#0B0D14")     # background gradient edge
const BG_1       := Color("#121624")     # background gradient centre
const SURFACE    := Color("#181C2C")     # panels
const SURFACE_HI := Color("#22283D")     # hover rows, inputs, secondary buttons
const LINE       := Color("#2E3550")     # dividers, inactive borders
const GOLD       := Color("#C9A24A")     # frames, focus
const GOLD_HI    := Color("#F0D27A")     # hover rim, glint
const GOLD_LO    := Color("#7A5E24")     # pressed, bevel
const TEXT       := Color("#EDE6D3")
const TEXT_DIM   := Color("#9C98A8")
const TEXT_OFF   := Color("#5E5B6B")
const OK         := Color("#4CC38A")
const WARN       := Color("#E3A33B")
const BAD        := Color("#E0534A")
const CORE       := Color("#4FC9E0")     # core gems, pips, unread dots
const SOUL       := Color("#FF5A78")     # the soul core gem on the board
const SOUL_A     := Color("#FF7AB8")     # iridescent gradient: primary button
const SOUL_B     := Color("#9B7BFF")
const SOUL_C     := Color("#5FE3D0")

# Names the board and older screens still use. Same colours, older words.
const BG         := BG_0
const BG_DEEP    := Color("#07090F")
const PANEL      := Color(0.094, 0.110, 0.173, 0.92)   # SURFACE at 92%
const PANEL_ALT  := Color(0.133, 0.157, 0.239, 0.94)   # SURFACE_HI
const PANEL_HI   := Color(0.165, 0.192, 0.290, 0.96)
const BORDER     := LINE
const BORDER_HI  := Color(0.788, 0.635, 0.290, 0.55)   # GOLD at 55%
const ACCENT     := GOLD
const ACCENT_DIM := GOLD_LO
const ACCENT_2   := CORE
const DANGER     := BAD
const SUCCESS    := OK

## Step colours, as printed in the official rule manual: the four setup steps
## share blue, Main is green, Attack is red, End is purple.
const STEP_COLORS := [
	Color("#3a78e0"), Color("#3a78e0"), Color("#3a78e0"), Color("#3a78e0"),
	Color("#2fb35a"), Color("#e04848"), Color("#8a5ad6"),
]
const STEP_NAMES := ["Start", "Core", "Draw", "Refresh", "Main", "Attack", "End"]

const COLOR_SWATCH := {
	BSS.CardColor.RED:    Color("#D8443A"),
	BSS.CardColor.PURPLE: Color("#8F5AD8"),
	BSS.CardColor.WHITE:  Color("#DCE3EC"),
	BSS.CardColor.YELLOW: Color("#E6B82E"),
	BSS.CardColor.GREEN:  Color("#3FA55C"),
	BSS.CardColor.BLUE:   Color("#3A7FD8"),
}
## White gets a cool outline so it reads on a cream-on-ink screen.
const WHITE_OUTLINE := Color("#9FB2C8")
## One-letter glyph beside each colour, for colour-blind players and because
## yellow sits close to gold.
const COLOR_GLYPHS := ["R", "P", "W", "Y", "G", "B"]

# --- Type -------------------------------------------------------------------
const FS_HERO    := 64
const FS_DISPLAY := 44
const FS_TITLE   := 30
const FS_HEAD    := 20
const FS_BODY    := 16
const FS_SMALL   := 13
const FS_TINY    := 11

# --- Spacing ----------------------------------------------------------------
const SP_XS := 4
const SP_S  := 8
const SP_M  := 14
const SP_L  := 22
const SP_XL := 34

const RADIUS := 6

const BG_MENU  := "res://assets/ui/menu_bg.png"
const BG_BOARD := "res://assets/ui/board_bg.png"

const FONT_PATHS := {
	"body":     "res://assets/fonts/Inter-Regular.otf",
	"medium":   "res://assets/fonts/Inter-Medium.otf",
	"semibold": "res://assets/fonts/Inter-SemiBold.otf",
	"bold":     "res://assets/fonts/Inter-Bold.otf",
	"display":  "res://assets/fonts/InterDisplay-ExtraBold.otf",
	"black":    "res://assets/fonts/InterDisplay-Black.otf",
	# TeX Gyre Pagella (GUST Font License): the serif for the wordmark, screen
	# titles and the primary button (0.16.0). Cinzel is not bundled.
	"title":    "res://assets/fonts/texgyrepagella-bold.otf",
	"title_rg": "res://assets/fonts/texgyrepagella-regular.otf",
}
const BG_SHADER := "res://assets/ui/menu_bg.gdshader"

static var _fonts := {}


## Returns a font by role, or null when the file is missing -- in which case
## Godot's built-in font is used and nothing breaks.
static func font(role: String) -> Font:
	if _fonts.has(role):
		return _fonts[role]
	var f: Font = null
	var path: String = FONT_PATHS.get(role, "")
	if path != "" and ResourceLoader.exists(path):
		f = load(path)
	_fonts[role] = f
	return f


# ============================================================================
# Global theme
# ============================================================================

static func build_theme() -> Theme:
	var t := Theme.new()
	var body_font := font("body")
	if body_font != null:
		t.default_font = body_font
	t.default_font_size = FS_BODY

	t.set_color("font_color", "Label", TEXT)

	# Buttons -- every Button-derived control (OptionButton, CheckBox, MenuButton)
	# falls back to these unless it has its own entry. Secondary button: a
	# raised surface with a thin gold rim that brightens on hover.
	for type: String in ["Button", "OptionButton", "MenuButton"]:
		t.set_stylebox("normal", type, _box(SURFACE_HI, RADIUS, Color(GOLD, 0.55)))
		t.set_stylebox("hover", type, _box(SURFACE_HI.lightened(0.06), RADIUS, GOLD_HI))
		t.set_stylebox("pressed", type, _box(SURFACE_HI.darkened(0.08), RADIUS, GOLD_LO))
		t.set_stylebox("focus", type, _box(Color(0, 0, 0, 0), RADIUS, GOLD, 1))
		t.set_stylebox("disabled", type, _box(Color(SURFACE, 0.6), RADIUS, Color(LINE, 0.8)))
		t.set_color("font_color", type, TEXT)
		t.set_color("font_hover_color", type, TEXT)
		t.set_color("font_pressed_color", type, TEXT)
		t.set_color("font_focus_color", type, TEXT)
		t.set_color("font_disabled_color", type, TEXT_OFF)
		t.set_font_size("font_size", type, FS_BODY - 1)
		if font("semibold") != null:
			t.set_font("font", type, font("semibold"))
	t.set_icon("arrow", "OptionButton", _arrow_icon())
	t.set_constant("arrow_margin", "OptionButton", 8)

	# Check boxes are text with an indicator, not panels.
	for type2: String in ["CheckBox", "CheckButton"]:
		var empty := StyleBoxEmpty.new()
		for state: String in ["normal", "hover", "pressed", "focus", "disabled",
				"hover_pressed"]:
			t.set_stylebox(state, type2, empty)
		t.set_color("font_color", type2, TEXT)
		t.set_color("font_hover_color", type2, TEXT)
		t.set_color("font_pressed_color", type2, TEXT)
		t.set_color("font_hover_pressed_color", type2, TEXT)
		t.set_color("font_focus_color", type2, TEXT)
		if font("body") != null:
			t.set_font("font", type2, font("body"))
		t.set_font_size("font_size", type2, FS_BODY)
	# Godot's default unchecked box is dark grey, invisible on these panels --
	# "Mute everything" rendered as bare text with no box at all. Drawn here so
	# both states are unmistakable.
	t.set_icon("unchecked", "CheckBox", _check_icon(false))
	t.set_icon("checked", "CheckBox", _check_icon(true))
	t.set_icon("unchecked_disabled", "CheckBox", _check_icon(false, true))
	t.set_icon("checked_disabled", "CheckBox", _check_icon(true, true))
	t.set_icon("radio_unchecked", "CheckBox", _check_icon(false))
	t.set_icon("radio_checked", "CheckBox", _check_icon(true))
	t.set_constant("h_separation", "CheckBox", 10)
	# CheckButton draws as a 44x24 pill (0.16.0).
	t.set_icon("unchecked", "CheckButton", _switch_icon(false))
	t.set_icon("checked", "CheckButton", _switch_icon(true))
	t.set_icon("unchecked_disabled", "CheckButton", _switch_icon(false, true))
	t.set_icon("checked_disabled", "CheckButton", _switch_icon(true, true))
	t.set_constant("h_separation", "CheckButton", 12)

	# Text entry.
	var le := _box(BG_DEEP, RADIUS, LINE)
	le.content_margin_left = 12
	le.content_margin_right = 12
	var le_focus := _box(BG_DEEP, RADIUS, GOLD, 1)
	le_focus.content_margin_left = 12
	le_focus.content_margin_right = 12
	for type3: String in ["LineEdit", "TextEdit"]:
		t.set_stylebox("normal", type3, le)
		t.set_stylebox("focus", type3, le_focus)
		t.set_stylebox("read_only", type3, le)
		t.set_color("font_color", type3, TEXT)
		t.set_color("font_placeholder_color", type3, TEXT_OFF)
		t.set_color("caret_color", type3, GOLD_HI)
		t.set_color("selection_color", type3, Color(CORE, 0.35))

	# Panels.
	t.set_stylebox("panel", "PanelContainer", _panel_box(PANEL))
	t.set_stylebox("panel", "Panel", _panel_box(PANEL))

	# Popups and dropdown lists.
	var pop := _box(Color("#141828"), RADIUS, Color(GOLD, 0.7))
	pop.content_margin_left = 6
	pop.content_margin_right = 6
	pop.content_margin_top = 6
	pop.content_margin_bottom = 6
	pop.shadow_color = Color(0, 0, 0, 0.5)
	pop.shadow_size = 12
	t.set_stylebox("panel", "PopupMenu", pop)
	t.set_stylebox("hover", "PopupMenu", _box(SURFACE_HI, 4, Color(GOLD, 0.6)))
	t.set_color("font_color", "PopupMenu", TEXT)
	t.set_color("font_hover_color", "PopupMenu", TEXT)
	t.set_color("font_disabled_color", "PopupMenu", TEXT_OFF)
	t.set_stylebox("panel", "PopupPanel", pop)
	t.set_stylebox("panel", "TooltipPanel", pop)
	t.set_color("font_color", "TooltipLabel", TEXT)
	t.set_font_size("font_size", "TooltipLabel", FS_SMALL)

	# Scrollbars: thin, rounded, only visible as a grabber.
	# A scrollbar's thickness IS its style box's content margins, so these must
	# be set explicitly -- _box()'s 14px padding made a 28px-wide bar.
	for type4: String in ["VScrollBar", "HScrollBar"]:
		var track := _thin(Color(1, 1, 1, 0.04))
		t.set_stylebox("scroll", type4, track)
		t.set_stylebox("scroll_focus", type4, track)
		t.set_stylebox("grabber", type4, _thin(Color(GOLD, 0.30)))
		t.set_stylebox("grabber_highlight", type4, _thin(Color(GOLD, 0.6)))
		t.set_stylebox("grabber_pressed", type4, _thin(GOLD))

	# Sliders: a 4 px track, gold fill, a gem for a thumb.
	var slider_track := _box(Color(1, 1, 1, 0.10), 2, Color(0, 0, 0, 0), 0)
	slider_track.content_margin_top = 2
	slider_track.content_margin_bottom = 2
	t.set_stylebox("slider", "HSlider", slider_track)
	var fill := _box(GOLD, 2, Color(0, 0, 0, 0), 0)
	fill.content_margin_top = 2
	fill.content_margin_bottom = 2
	t.set_stylebox("grabber_area", "HSlider", fill)
	t.set_stylebox("grabber_area_highlight", "HSlider", fill)
	t.set_icon("grabber", "HSlider", gem_texture(GOLD, 16))
	t.set_icon("grabber_highlight", "HSlider", gem_texture(GOLD_HI, 16))
	t.set_icon("grabber_disabled", "HSlider", gem_texture(TEXT_OFF, 16))

	# Spin boxes: the up/down arrows are drawn by the theme's LineEdit.
	t.set_icon("updown", "SpinBox", _updown_icon())

	# Tabs.
	t.set_stylebox("tab_selected", "TabBar", _box(SURFACE_HI, RADIUS, GOLD))
	t.set_stylebox("tab_unselected", "TabBar", _box(PANEL, RADIUS, LINE))
	t.set_stylebox("tab_hovered", "TabBar", _box(PANEL_ALT, RADIUS, Color(GOLD, 0.55)))
	t.set_color("font_selected_color", "TabBar", TEXT)
	t.set_color("font_unselected_color", "TabBar", TEXT_DIM)
	t.set_color("font_hovered_color", "TabBar", TEXT)
	return t


# ============================================================================
# Backgrounds
# ============================================================================

## Fills `node` edge to edge and puts the shared background behind everything
## else: the ink-blue shader (gradient, smoke, lattice, vignette) with the
## nebula art sunk into it. `scrim` is kept for the callers: a higher scrim
## means less art showing through. The ColorRect carrying the shader is
## stored on the node as meta "bg_rect" so a screen can add parallax or tint
## it with the active deck's colour. Falls back to a flat colour when the
## shader is absent, so a stripped assets/ folder degrades to plain rather
## than to broken.
static func apply_root(node: Control, title: String = "", bg_path: String = BG_MENU,
		scrim: float = 0.35) -> void:
	node.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var flat := ColorRect.new()
	flat.name = "Background"
	flat.color = BG_0
	flat.set_anchors_preset(Control.PRESET_FULL_RECT)
	flat.mouse_filter = Control.MOUSE_FILTER_IGNORE
	node.add_child(flat)
	node.move_child(flat, 0)
	if ResourceLoader.exists(BG_SHADER):
		var mat := ShaderMaterial.new()
		mat.shader = load(BG_SHADER)
		var art_mix := clampf(0.75 - scrim, 0.0, 1.0) * 0.8
		if bg_path != "" and ResourceLoader.exists(bg_path):
			var tex: Texture2D = load(bg_path)
			mat.set_shader_parameter("art", tex)
			mat.set_shader_parameter("art_aspect",
					float(tex.get_width()) / maxf(1.0, float(tex.get_height())))
			mat.set_shader_parameter("art_mix", art_mix)
		mat.set_shader_parameter("speed", 1.0 if Motion.enabled() else 0.0)
		flat.material = mat
	elif bg_path != "" and ResourceLoader.exists(bg_path):
		var tex2 := TextureRect.new()
		tex2.texture = load(bg_path)
		tex2.set_anchors_preset(Control.PRESET_FULL_RECT)
		tex2.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex2.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		tex2.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tex2.modulate.a = 1.0 - scrim
		node.add_child(tex2)
		node.move_child(tex2, 1)
	node.set_meta("bg_rect", flat)
	if not title.is_empty():
		node.name = title


## Tints the shared background towards a colour (the active deck's) at a few
## percent. Safe to call on a screen without a shader background.
static func tint_background(node: Control, col: Color) -> void:
	if not node.has_meta("bg_rect"):
		return
	var rect: ColorRect = node.get_meta("bg_rect")
	if rect != null and rect.material is ShaderMaterial:
		(rect.material as ShaderMaterial).set_shader_parameter("tint", Color(col, 1.0))


# ============================================================================
# Style boxes
# ============================================================================

static func _box(bg: Color, radius: int = RADIUS, border: Color = BORDER,
		border_w: int = 1) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	if border_w > 0:
		sb.set_border_width_all(border_w)
		sb.border_color = border
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	sb.anti_aliasing = true
	return sb


## An 20px checkbox drawn into an image: a thin outline when off, a gold
## filled box with a dark tick when on.
static func _check_icon(on: bool, disabled: bool = false) -> Texture2D:
	var n := 20
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var edge := Color(TEXT_DIM, 0.9) if not disabled else Color(TEXT_OFF, 0.6)
	var fill := GOLD if not disabled else Color(0.45, 0.42, 0.35)
	for y in n:
		for x in n:
			var inside := x >= 1 and y >= 1 and x <= n - 2 and y <= n - 2
			var corner := (x <= 2 or x >= n - 3) and (y <= 2 or y >= n - 3) \
					and (Vector2(x, y).distance_to(Vector2(clampi(x, 4, n - 5), clampi(y, 4, n - 5))) > 3.2)
			if not inside or corner:
				continue
			var border := x <= 2 or y <= 2 or x >= n - 3 or y >= n - 3
			if on:
				img.set_pixel(x, y, fill)
			elif border:
				img.set_pixel(x, y, edge)
			else:
				img.set_pixel(x, y, Color(1, 1, 1, 0.04))
	if on:
		var tick := Color("#1a1204")
		var pts := [Vector2(5, 10), Vector2(8, 13), Vector2(15, 6)]
		for i in 2:
			var a: Vector2 = pts[i]
			var b: Vector2 = pts[i + 1]
			for k in 24:
				var q := a.lerp(b, k / 23.0)
				for dy: int in [-1, 0, 1]:
					for dx: int in [-1, 0]:
						var px: int = int(q.x) + dx
						var py: int = int(q.y) + dy
						if px >= 0 and py >= 0 and px < n and py < n:
							img.set_pixel(px, py, tick)
	return ImageTexture.create_from_image(img)


## A 44x24 toggle pill: the thumb sits left on a `line` track when off, right
## on a gold track when on.
static func _switch_icon(on: bool, disabled: bool = false) -> Texture2D:
	var w := 44
	var h := 24
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var track := (GOLD if on else Color(LINE, 1.0)) if not disabled else Color(TEXT_OFF, 0.5)
	var rim := (GOLD_HI if on else Color(TEXT_DIM, 0.5)) if not disabled else Color(TEXT_OFF, 0.6)
	var r := h * 0.5
	var thumb_c := Vector2(w - r, r) if on else Vector2(r, r)
	for y in h:
		for x in w:
			var p := Vector2(x + 0.5, y + 0.5)
			# capsule distance
			var cx := clampf(p.x, r, w - r)
			var d := p.distance_to(Vector2(cx, r))
			if d > r:
				continue
			var col := track if d < r - 1.2 else rim
			var td := p.distance_to(thumb_c)
			if td < r - 3.5:
				col = Color("#1a1204") if on else TEXT_DIM
				if td < r - 5.5:
					col = TEXT if not on else Color("#2a2010")
			img.set_pixel(x, y, col)
	return ImageTexture.create_from_image(img)


## The small chevron on dropdowns.
static func _arrow_icon() -> Texture2D:
	var n := 12
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for y in range(3, 9):
		var half := y - 3
		for x in range(half, n - half):
			if x == half or x == n - half - 1 or x == half + 1 or x == n - half - 2:
				img.set_pixel(x, y, TEXT_DIM)
	return ImageTexture.create_from_image(img)


static func _updown_icon() -> Texture2D:
	var n := 14
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for i in 3:
		for x in range(6 - i, 8 + i):
			img.set_pixel(x, 2 + i, TEXT_DIM)
			img.set_pixel(x, n - 3 - i, TEXT_DIM)
	return ImageTexture.create_from_image(img)


static func _thin(bg: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(3)
	sb.set_content_margin_all(3)
	return sb


## The panel: surface at 92%, radius 6, a 1 px gold border at 55%, and a
## soft 12 px shadow.
static func _panel_box(bg: Color, border: Color = BORDER_HI) -> StyleBoxFlat:
	var sb := _box(bg, RADIUS, border)
	sb.content_margin_left = SP_M
	sb.content_margin_right = SP_M
	sb.content_margin_top = SP_M
	sb.content_margin_bottom = SP_M
	sb.shadow_color = Color(0, 0, 0, 0.5)
	sb.shadow_size = 12
	sb.shadow_offset = Vector2(0, 4)
	return sb


# ============================================================================
# Widgets
# ============================================================================

static func panel(min_size: Vector2 = Vector2.ZERO, alt: bool = false) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _panel_box(PANEL_ALT if alt else PANEL))
	p.custom_minimum_size = min_size
	return p


## A panel with a full gold frame and procedural corner brackets: for hero
## content only (the profile card, the active deck, a selected mode).
static func hero_panel(min_size: Vector2 = Vector2.ZERO, tint: Color = GOLD) -> PanelContainer:
	var p := HeroPanel.new()
	p.tint = tint
	var sb := _panel_box(PANEL, Color(tint, 0.85))
	sb.shadow_color = Color(tint, 0.18)
	sb.shadow_size = 16
	sb.set_content_margin_all(SP_L)
	p.add_theme_stylebox_override("panel", sb)
	p.custom_minimum_size = min_size
	return p


## The brackets are drawn by the panel itself, in the margin outside its
## content: a PanelContainer lays out every child as content, so an overlay
## child would land inside the margin and over the text.
class HeroPanel extends PanelContainer:
	var tint := Color("#C9A24A")
	var arm := 16.0

	func _draw() -> void:
		var w := size.x
		var h := size.y
		var o := 5.0
		var c := Color(tint, 0.95)
		var hi := Color(tint.lightened(0.3), 0.9)
		for corner: Array in [[Vector2(o, o), Vector2(1, 1)], [Vector2(w - o, o), Vector2(-1, 1)],
				[Vector2(o, h - o), Vector2(1, -1)], [Vector2(w - o, h - o), Vector2(-1, -1)]]:
			var at: Vector2 = corner[0]
			var d: Vector2 = corner[1]
			draw_line(at, at + Vector2(arm * d.x, 0), c, 2.0, true)
			draw_line(at, at + Vector2(0, arm * d.y), c, 2.0, true)
			draw_circle(at + Vector2(arm * d.x, 0), 1.6, hi)
			draw_circle(at + Vector2(0, arm * d.y), 1.6, hi)


## A panel with a coloured top edge, used for cards of content that belong to a
## category -- the mode tabs, the step tracker, deck tiles.
static func accent_panel(tint: Color, min_size: Vector2 = Vector2.ZERO) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := _panel_box(PANEL)
	sb.set_border_width_all(0)
	sb.border_width_top = 3
	sb.border_color = tint
	p.add_theme_stylebox_override("panel", sb)
	p.custom_minimum_size = min_size
	return p


## Display headings use the heavier display cut of the font.
static func heading(text: String, size: int = FS_TITLE) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", TEXT)
	var f := font("display") if size >= FS_HEAD else font("bold")
	if f != null:
		l.add_theme_font_override("font", f)
	return l


static var _title_fonts := {}


## The title face: Pagella Bold, letter-spaced by 6% of the size. Cached per
## size because a FontVariation is a resource.
static func title_font(size: int) -> Font:
	if _title_fonts.has(size):
		return _title_fonts[size]
	var base := font("title")
	if base == null:
		return null
	var fv := FontVariation.new()
	fv.base_font = base
	fv.set_spacing(TextServer.SPACING_GLYPH, int(round(size * 0.06)))
	_title_fonts[size] = fv
	return fv


## Screen titles, the wordmark and section heads: uppercase serif, tracked.
static func display_title(text: String, size: int = FS_TITLE, tint: Color = TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.uppercase = true
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", tint)
	var f := title_font(size)
	if f != null:
		l.add_theme_font_override("font", f)
	l.autowrap_mode = TextServer.AUTOWRAP_OFF
	l.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	return l


## Numbers: cost, BP, 38/40, percentages. The display cut of Inter.
static func number(text: String, size: int = FS_BODY, tint: Color = TEXT) -> Label:
	var l := body(text, false, size)
	l.add_theme_color_override("font_color", tint)
	if font("display") != null:
		l.add_theme_font_override("font", font("display"))
	return l


## A thin gold rule with a brighter centre, for under titles.
static func gold_rule(width: float = 0.0) -> Control:
	var r := GoldRule.new()
	r.custom_minimum_size = Vector2(width, 2)
	if width <= 0.0:
		r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


class GoldRule extends Control:
	func _draw() -> void:
		var y := size.y * 0.5
		var pts := PackedVector2Array([Vector2(0, y), Vector2(size.x * 0.5, y), Vector2(size.x, y)])
		var cols := PackedColorArray([Color(UITheme.GOLD, 0.0), UITheme.GOLD_HI, Color(UITheme.GOLD, 0.0)])
		draw_polyline_colors(pts, cols, 1.5, true)


## Small uppercase label for section names ("YOUR DECK", "OPPONENT").
static func eyebrow(text: String, tint: Color = TEXT_DIM) -> Label:
	var l := Label.new()
	l.text = text.to_upper()
	l.add_theme_font_size_override("font_size", FS_TINY + 1)
	l.add_theme_color_override("font_color", tint)
	if font("semibold") != null:
		l.add_theme_font_override("font", font("semibold"))
	return l


## Single-line text. Wrapping is OFF here on purpose.
##
## A Label with autowrap has a minimum width of ONE CHARACTER, because it can
## always wrap harder. Inside an HBoxContainer -- which hands each child its
## minimum width -- such a label collapses into a vertical strip one glyph wide
## (R-016). Long text that genuinely needs to flow goes through paragraph().
##
## Truncation is OFF too. A label allowed to ellipsise has a minimum width of
## ZERO, so inside a row it is handed zero width and disappears entirely --
## the mirror image of the wrapping bug, found in 0.6.0 only because the
## screens were finally rendered (R-023). A body label is exactly as wide as
## its text. Use truncating() where a label must shrink to fit.
static func body(text: String, dim: bool = false, size: int = FS_BODY) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", TEXT_DIM if dim else TEXT)
	l.autowrap_mode = TextServer.AUTOWRAP_OFF
	l.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	return l


## A single-line label that shrinks with an ellipsis. Because its minimum width
## is zero it MUST be given width explicitly: expand-fill in a row, or a
## custom_minimum_size. Otherwise it vanishes.
static func truncating(text: String, dim: bool = false, size: int = FS_BODY) -> Label:
	var l := body(text, dim, size)
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l


## Multi-line prose. Wraps, and expands horizontally so wrapping has room.
## Use in vertical layouts only -- never directly inside an HBox.
static func paragraph(text: String, dim: bool = false, size: int = FS_BODY) -> Label:
	var l := body(text, dim, size)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l


## Card effect text with the printed card's formatting (0.11.3): keywords as
## white-on-black tags, a Burst condition on a black bar, reminder text in
## parentheses and italics, level chips in bold. Used beside the board and in
## the card zoom so the text reads the way the card face does.
const KEYWORD_PATTERN := "(?<![\\w])(Crush(?: \\+\\d+)?|Raid(?: \\d+)?|Gale(?: \\d+)?|Armor(?:: [A-Z][a-z]+(?: / [A-Z][a-z]+)*(?: Colours)?)?|A\\.T\\. Field|Confront|Curse|Awaken|Immortal|Luster|Blessed|Ascend|Swift|Astral|Chain|Agile|Feast|Link)(?![\\w])"
# non-breaking padding: a tag never parts from the punctuation after it
const TAG_OPEN := "[bgcolor=#101010][color=#ffffff][b]\u00a0"
const TAG_CLOSE := "\u00a0[/b][/color][/bgcolor]"
static var _italic_font: FontVariation = null


static func card_text_bbcode(text: String) -> String:
	var chips := RegEx.create_from_string("\\[lb\\]LV(\\d)\\]")
	var burst := RegEx.create_from_string("^(Burst: [^:]+):")
	var window := RegEx.create_from_string("^(Main / Flash|Main|Flash):")
	var paren := RegEx.create_from_string("\\(([^()]*)\\)")
	var kw := RegEx.create_from_string(KEYWORD_PATTERN)
	var out: PackedStringArray = []
	for line: String in text.split("\n"):
		var t := line.replace("[", "[lb]")
		t = chips.sub(t, "[b]LV$1[/b] ", true)
		t = burst.sub(t, TAG_OPEN + "$1" + TAG_CLOSE + "\n")
		t = window.sub(t, "[b]$1:[/b]")
		t = kw.sub(t, TAG_OPEN + "$1" + TAG_CLOSE, true)
		t = paren.sub(t, "[i]($1)[/i]", true)
		out.append(t)
	return "\n".join(out)


static func card_text(text: String, size: int = FS_BODY) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# A parchment box like the card's own text box, so the black keyword tags
	# read as they do on the card (on the dark panel they disappeared).
	var box := StyleBoxFlat.new()
	box.bg_color = Color("#ddd0b8")
	box.set_corner_radius_all(6)
	box.border_color = Color("#6b4a2e")
	box.set_border_width_all(1)
	box.content_margin_left = 10
	box.content_margin_right = 10
	box.content_margin_top = 8
	box.content_margin_bottom = 8
	r.add_theme_stylebox_override("normal", box)
	# the tag's own non-breaking spaces pad it; the default highlight padding
	# reached over the full stop after "Raid 1"
	r.add_theme_constant_override("text_highlight_h_padding", 0)
	r.add_theme_constant_override("text_highlight_v_padding", 1)
	r.add_theme_color_override("default_color", Color("#1c1612"))
	for k in ["normal_font_size", "bold_font_size", "italics_font_size", "bold_italics_font_size"]:
		r.add_theme_font_size_override(k, size)
	if _italic_font == null:
		# Inter has no italic file here: slant the regular face instead.
		_italic_font = FontVariation.new()
		_italic_font.base_font = load("res://assets/fonts/Inter-Regular.otf")
		_italic_font.variation_transform = Transform2D(Vector2(1, 0), Vector2(0.22, 1), Vector2.ZERO)
	r.add_theme_font_override("italics_font", _italic_font)
	r.add_theme_font_override("bold_font", load("res://assets/fonts/Inter-Bold.otf"))
	set_card_text(r, text)
	return r


static func set_card_text(r: RichTextLabel, text: String) -> void:
	r.text = card_text_bbcode(text)
	# fit_content measures before the new text is wrapped to the panel's
	# width, which could leave the last wrapped line outside the box: measure
	# again once it has been laid out.
	r.update_minimum_size.call_deferred()


## Every button clicks. Wiring the sound here rather than at every call site is
## the whole point of having a factory.
static func _wire(b: BaseButton, on_press: Callable) -> void:
	b.mouse_entered.connect(func(): AudioManager.play_sfx("ui_hover"))
	b.pressed.connect(func(): AudioManager.play_sfx("ui_click"))
	if on_press.is_valid():
		b.pressed.connect(on_press)
	# Every factory button lifts on hover and squashes on press (0.16.0).
	Motion.hover_lift(b)
	Motion.press_feedback(b)


static func button(text: String, on_press: Callable = Callable(), wide: bool = false) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 40)
	b.focus_mode = Control.FOCUS_NONE
	if wide:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_wire(b, on_press)
	return b


## Gold, dark text: a confirming action -- the board's choices, a modal's
## Yes, the secondary confirms of a screen. The ONE main action of a menu
## screen is hero_button() instead.
static func primary_button(text: String, on_press: Callable = Callable()) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(180, 48)
	b.focus_mode = Control.FOCUS_NONE
	var normal := _box(GOLD, RADIUS, GOLD_HI)
	var hover := _box(GOLD_HI, RADIUS, Color("#FFF2C0"))
	var press := _box(GOLD_LO.lightened(0.15), RADIUS, GOLD)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", press)
	b.add_theme_stylebox_override("disabled", _box(Color(SURFACE, 0.6), RADIUS, Color(LINE, 0.8)))
	var dark := Color("#1a1204")
	for k: String in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(k, dark)
	b.add_theme_color_override("font_disabled_color", TEXT_OFF)
	b.add_theme_font_size_override("font_size", FS_HEAD - 2)
	if font("bold") != null:
		b.add_theme_font_override("font", font("bold"))
	_wire(b, on_press)
	return b


## The soul-core button (0.16.0): a deep violet fill, a 2 px iridescent rim
## that slowly drifts through pink, violet and teal, a breathing glow, and a
## serif label. Use ONE per screen: PLAY, START, SAVE.
static func hero_button(text: String, on_press: Callable = Callable(),
		size: int = FS_HEAD + 2) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(220, 60)
	b.focus_mode = Control.FOCUS_NONE
	var normal := _box(Color("#241D3A"), RADIUS + 2, Color(0, 0, 0, 0), 0)
	normal.shadow_color = Color(SOUL_B, 0.45)
	normal.shadow_size = 18
	normal.shadow_offset = Vector2(0, 2)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color("#2E2549")
	hover.shadow_color = Color(SOUL_B, 0.65)
	var press := normal.duplicate() as StyleBoxFlat
	press.bg_color = Color("#1A1630")
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", press)
	b.add_theme_stylebox_override("disabled", _box(Color(SURFACE, 0.6), RADIUS + 2, Color(LINE, 0.8)))
	for k: String in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(k, Color("#FFF6E0"))
	b.add_theme_color_override("font_disabled_color", TEXT_OFF)
	b.add_theme_font_size_override("font_size", size)
	var f := title_font(size)
	if f != null:
		b.add_theme_font_override("font", f)
	b.text = text.to_upper()
	var rim := SoulRim.new()
	b.add_child(rim)
	# The glow breathes 0.35 <-> 0.55 (the shadow is the glow): a resource
	# property tween, started once the button is in the tree.
	b.ready.connect(func():
		if Motion.enabled() and not b.disabled:
			var tw := b.create_tween().set_loops()
			tw.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
			tw.tween_property(normal, "shadow_color:a", 0.65, Motion.LOOP_BREATHE * 0.5)
			tw.tween_property(normal, "shadow_color:a", 0.35, Motion.LOOP_BREATHE * 0.5))
	_wire(b, on_press)
	return b


## The iridescent 2 px rim of a hero button. The hue drifts a full cycle in
## 6 s (reduce motion: a fixed gradient).
class SoulRim extends Control:
	var phase := 0.0

	func _ready() -> void:
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		if Motion.enabled():
			var tw := create_tween().set_loops()
			tw.tween_method(func(v: float):
				phase = v
				queue_redraw(), 0.0, 1.0, 6.0)

	func _draw() -> void:
		var parent_btn := get_parent() as Button
		if parent_btn != null and parent_btn.disabled:
			return
		var r := Rect2(Vector2(1, 1), size - Vector2(2, 2))
		var rad := 7.0
		var pts := PackedVector2Array()
		var cols := PackedColorArray()
		# Corners get their own samples, so a wide button keeps round corners
		# rather than chamfered ones.
		var w := r.size.x
		var h := r.size.y
		var o := r.position
		var corners := [[Vector2(w - rad, rad), -PI * 0.5], [Vector2(w - rad, h - rad), 0.0],
				[Vector2(rad, h - rad), PI * 0.5], [Vector2(rad, rad), PI]]
		for c: Array in corners:
			for k in 7:
				var a: float = c[1] + float(k) / 6.0 * PI * 0.5
				pts.append(o + (c[0] as Vector2) + Vector2(cos(a), sin(a)) * rad)
		pts.append(pts[0])
		var total := 2.0 * (w + h)
		var walked := 0.0
		for i in pts.size():
			if i > 0:
				walked += pts[i].distance_to(pts[i - 1])
			cols.append(_soul(walked / maxf(1.0, total) * 2.0 + phase))
		draw_polyline_colors(pts, cols, 2.5, true)

	static func _soul(t: float) -> Color:
		var k := fposmod(t, 1.0) * 3.0
		var i := int(k)
		var f := k - float(i)
		var stops := [UITheme.SOUL_A, UITheme.SOUL_B, UITheme.SOUL_C, UITheme.SOUL_A]
		return (stops[i] as Color).lerp(stops[i + 1], f)


static func danger_button(text: String, on_press: Callable = Callable()) -> Button:
	var b := button(text, on_press)
	b.add_theme_color_override("font_color", BAD)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_stylebox_override("normal", _box(SURFACE_HI, RADIUS, Color(BAD, 0.45)))
	b.add_theme_stylebox_override("hover", _box(BAD.darkened(0.45), RADIUS, BAD))
	return b


## No fill, dim text that turns gold on hover: for utilities in corners
## (Quit, Open folder, a link to the patch notes).
static func ghost_button(text: String, on_press: Callable = Callable()) -> Button:
	var b := button(text, on_press)
	for st: String in ["normal", "hover", "pressed", "focus"]:
		b.add_theme_stylebox_override(st, _box(Color(0, 0, 0, 0), RADIUS, Color(0, 0, 0, 0), 0))
	b.add_theme_stylebox_override("hover", _box(Color(1, 1, 1, 0.04), RADIUS, Color(GOLD, 0.4)))
	b.add_theme_color_override("font_color", TEXT_DIM)
	b.add_theme_color_override("font_hover_color", GOLD_HI)
	b.add_theme_color_override("font_pressed_color", GOLD)
	return b


## A toggle styled as a chip: 28-34 px tall, fully rounded. Off: a `line`
## border. On: the tint at 15% with a coloured border. `icon` (a gem, say)
## sits before the text so colour is never the only signal.
static func chip(text: String, tint: Color = ACCENT_2, icon: Texture2D = null) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 32)
	var off := _box(Color(SURFACE, 0.8), 16, LINE)
	off.content_margin_left = 12
	off.content_margin_right = 12
	off.content_margin_top = 3
	off.content_margin_bottom = 3
	var on := _box(Color(tint, 0.18), 16, tint, 1)
	on.content_margin_left = 12
	on.content_margin_right = 12
	on.content_margin_top = 3
	on.content_margin_bottom = 3
	var hov := _box(SURFACE_HI, 16, Color(tint, 0.7))
	hov.content_margin_left = 12
	hov.content_margin_right = 12
	hov.content_margin_top = 3
	hov.content_margin_bottom = 3
	b.add_theme_stylebox_override("normal", off)
	b.add_theme_stylebox_override("hover", hov)
	b.add_theme_stylebox_override("pressed", on)
	b.add_theme_stylebox_override("hover_pressed", on)
	b.add_theme_stylebox_override("focus", _box(Color(0, 0, 0, 0), 16, Color(0, 0, 0, 0), 0))
	b.add_theme_font_size_override("font_size", FS_SMALL)
	if font("semibold") != null:
		b.add_theme_font_override("font", font("semibold"))
	b.add_theme_color_override("font_color", TEXT_DIM)
	b.add_theme_color_override("font_pressed_color", TEXT)
	b.add_theme_color_override("font_hover_color", TEXT)
	b.add_theme_color_override("font_hover_pressed_color", TEXT)
	if icon != null:
		b.icon = icon
		b.add_theme_constant_override("h_separation", 6)
	b.mouse_entered.connect(func(): AudioManager.play_sfx("ui_hover"))
	b.pressed.connect(func(): AudioManager.play_sfx("ui_click"))
	Motion.press_feedback(b)
	return b


## A chip for one of the six colours: its gem plus its initial, in its tint.
static func color_chip(color_index: int, text: String = "") -> Button:
	var tint: Color = COLOR_SWATCH.get(color_index, TEXT_DIM)
	var label := text if text != "" else str(COLOR_GLYPHS[color_index])
	# 0.16.3: the colour's symbol picture (assets/ui/symbols); the drawn gem
	# only when the picture is missing
	var icon := symbol_texture(color_index, 20)
	var b := chip(label, tint, icon if icon != null else gem_texture(tint, 14))
	b.tooltip_text = str(BSS.COLOR_NAMES[color_index]).capitalize()
	return b


## Segmented control: a row of exclusive chips that share one ButtonGroup.
## Returns the HBox; `on_pick(index)` fires on a change.
static func segmented(labels: Array, selected: int, on_pick: Callable,
		tint: Color = GOLD, min_w: float = 0.0) -> HBoxContainer:
	var row := hbox(4)
	var group := ButtonGroup.new()
	for i in labels.size():
		var idx := i
		var b := chip(str(labels[i]), tint)
		b.button_group = group
		b.custom_minimum_size = Vector2(min_w, 34)
		b.add_theme_font_size_override("font_size", FS_SMALL + 1)
		b.button_pressed = i == selected
		b.pressed.connect(func(): on_pick.call(idx))
		row.add_child(b)
	return row


static func line_edit(placeholder: String, text: String = "") -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.text = text
	e.custom_minimum_size = Vector2(0, 40)
	return e


## Search is the primary way people find a card, so it is the largest field.
static func search_field(placeholder: String = "Search cards...") -> LineEdit:
	var e := line_edit(placeholder)
	e.custom_minimum_size = Vector2(0, 44)
	e.add_theme_font_size_override("font_size", FS_BODY + 1)
	e.clear_button_enabled = true
	return e


static func spacer(h: float = 12.0) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


static func grow() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


static func rule() -> Control:
	var r := ColorRect.new()
	r.color = LINE
	r.custom_minimum_size = Vector2(0, 1)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


static func vbox(sep: int = SP_S) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	return v


static func hbox(sep: int = SP_S) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	return h


## A colour as a small faceted gem (0.16.0). Same call as before; it used to
## be a round swatch.
static func color_dot(color_index: int, size: float = 18.0) -> Control:
	var d := Dot.new()
	d.color = COLOR_SWATCH.get(color_index, TEXT_DIM)
	d.symbol = symbol_texture(color_index, int(maxf(size, 12.0) * 2.0))
	d.custom_minimum_size = Vector2(size, size)
	d.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	d.mouse_filter = Control.MOUSE_FILTER_IGNORE
	d.tooltip_text = str(BSS.COLOR_NAMES[color_index]).capitalize() if color_index >= 0 \
			and color_index < BSS.COLOR_NAMES.size() else ""
	return d


## Draws a faceted gem of `col` into `canvas` at centre `c`, radius `r`.
static func draw_gem(canvas: CanvasItem, c: Vector2, r: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 6:
		var a := -PI * 0.5 + float(i) * PI / 3.0
		pts.append(c + Vector2(cos(a), sin(a)) * r)
	canvas.draw_colored_polygon(pts, col.darkened(0.45))
	var inner := PackedVector2Array()
	for i in 6:
		var a := -PI * 0.5 + float(i) * PI / 3.0
		inner.append(c + Vector2(cos(a), sin(a)) * r * 0.78)
	canvas.draw_colored_polygon(inner, col)
	# top-left facet catches the light, bottom-right falls into shade
	canvas.draw_colored_polygon(PackedVector2Array([inner[0], inner[5], c]), col.lightened(0.35))
	canvas.draw_colored_polygon(PackedVector2Array([inner[4], inner[5], c]), col.lightened(0.15))
	canvas.draw_colored_polygon(PackedVector2Array([inner[2], inner[3], c]), col.darkened(0.25))
	canvas.draw_circle(c + Vector2(-r * 0.22, -r * 0.30), r * 0.16, Color(1, 1, 1, 0.75))
	var outline := col.lightened(0.5) if col != COLOR_SWATCH[BSS.CardColor.WHITE] else WHITE_OUTLINE
	pts.append(pts[0])
	canvas.draw_polyline(pts, Color(outline, 0.9), 1.0, true)


## A gem swatch. A ColorRect is a square, which reads as a checkbox.
class Dot extends Control:
	var color := Color.WHITE
	var symbol: Texture2D = null     # the colour's symbol picture (0.16.3)

	func _draw() -> void:
		if symbol != null:
			var s := minf(size.x, size.y)
			draw_texture_rect(symbol, Rect2((size - Vector2(s, s)) * 0.5, Vector2(s, s)), false)
			return
		var r := minf(size.x, size.y) * 0.5
		UITheme.draw_gem(self, size * 0.5, r, color)


static var _symbol_textures := {}


## The colour's symbol picture (0.16.3), fitted into a px x px square, or null
## when there is none. user://assets/ui/symbols/<colour>.png wins over the
## bundled res:// one, like every other asset.
static func symbol_texture(color_index: int, px: int = 20) -> Texture2D:
	if color_index < 0 or color_index >= BSS.COLOR_NAMES.size():
		return null
	var key := "%d:%d" % [color_index, px]
	if _symbol_textures.has(key):
		return _symbol_textures[key]
	var cname := str(BSS.COLOR_NAMES[color_index])
	var img: Image = null
	var upath := "user://assets/ui/symbols/%s.png" % cname
	if FileAccess.file_exists(upath):
		img = Image.load_from_file(ProjectSettings.globalize_path(upath))
	if img == null:
		var rpath := "res://assets/ui/symbols/%s.png" % cname
		if ResourceLoader.exists(rpath):
			var t: Texture2D = load(rpath)
			if t != null:
				img = t.get_image()
	if img == null or img.is_empty():
		_symbol_textures[key] = null
		return null
	img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	var sc := float(px) / maxf(img.get_width(), img.get_height())
	img.resize(maxi(1, int(round(img.get_width() * sc))), maxi(1, int(round(img.get_height() * sc))),
			Image.INTERPOLATE_LANCZOS)
	var canvas := Image.create(px, px, false, Image.FORMAT_RGBA8)
	canvas.fill(Color(0, 0, 0, 0))
	canvas.blit_rect(img, Rect2i(Vector2i.ZERO, img.get_size()),
			Vector2i(int((px - img.get_width()) * 0.5), int((px - img.get_height()) * 0.5)))
	var tex := ImageTexture.create_from_image(canvas)
	_symbol_textures[key] = tex
	return tex


static var _gem_textures := {}


## The same gem as a texture, for button icons and slider thumbs.
static func gem_texture(col: Color, px: int = 16) -> Texture2D:
	var key := "%s:%d" % [col.to_html(), px]
	if _gem_textures.has(key):
		return _gem_textures[key]
	var img := Image.create(px, px, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var c := Vector2(px * 0.5, px * 0.5)
	var r := px * 0.5 - 0.5
	var white_gem := col.is_equal_approx(COLOR_SWATCH[BSS.CardColor.WHITE])
	for y in px:
		for x in px:
			var p := Vector2(x + 0.5, y + 0.5) - c
			# pointy-top hexagon test
			var q := Vector2(absf(p.x), absf(p.y))
			var inside := q.y <= r and (q.x * 0.866 + q.y * 0.5) <= r * 0.866
			if not inside:
				continue
			var edge := q.y > r - 1.3 or (q.x * 0.866 + q.y * 0.5) > r * 0.866 - 1.2
			var px_col := col
			if edge:
				px_col = WHITE_OUTLINE if white_gem else col.lightened(0.45)
			elif p.x < 0.0 and p.y < 0.0 and -p.y > p.x * 0.3:
				px_col = col.lightened(0.3)
			elif p.x > 0.0 and p.y > 0.0:
				px_col = col.darkened(0.22)
			elif p.y > 0.0:
				px_col = col.darkened(0.08)
			if p.distance_to(Vector2(-r * 0.25, -r * 0.3)) < r * 0.17:
				px_col = Color(1, 1, 1, 0.9)
			img.set_pixel(x, y, px_col)
	var tex := ImageTexture.create_from_image(img)
	_gem_textures[key] = tex
	return tex


## Copy pips: `limit` sockets, `n` of them lit as core gems (gold when the
## limit is reached). The deck editor draws these under every card.
static func pips(n: int, limit: int, px: float = 10.0) -> Control:
	var p := Pips.new()
	p.n = n
	p.limit = limit
	p.px = px
	p.custom_minimum_size = Vector2(limit * (px + 3.0) - 3.0, px)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.tooltip_text = "%d of %d copies in the deck" % [n, limit]
	return p


class Pips extends Control:
	var n := 0
	var limit := 4
	var px := 10.0

	func _draw() -> void:
		var r := px * 0.5
		var full := n >= limit
		for i in limit:
			var c := Vector2(r + i * (px + 3.0), size.y * 0.5)
			if i < n:
				UITheme.draw_gem(self, c, r, UITheme.GOLD if full else UITheme.CORE)
			else:
				draw_circle(c, r * 0.75, Color(1, 1, 1, 0.05))
				draw_arc(c, r * 0.75, 0.0, TAU, 20, Color(UITheme.TEXT_OFF, 0.7), 1.0, true)


## A labelled toggle row: label on the left, a pill switch on the right, an
## optional one-line description beneath. The switch is a CheckButton, so
## `button_pressed` and `toggled` behave as they always did.
static func toggle_row(label: String, value: bool, on_change: Callable,
		description: String = "") -> Control:
	var v := vbox(2)
	var h := hbox(SP_S)
	h.custom_minimum_size = Vector2(0, 36)
	var l := body(label)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(l)
	var cb := CheckButton.new()
	cb.button_pressed = value
	cb.focus_mode = Control.FOCUS_NONE
	cb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	cb.toggled.connect(func(on: bool):
		AudioManager.play_sfx("ui_click")
		on_change.call(on))
	h.add_child(cb)
	v.add_child(h)
	if description != "":
		var d := paragraph(description, true, FS_SMALL - 1)
		d.add_theme_color_override("font_color", TEXT_DIM)
		v.add_child(d)
	v.set_meta("switch", cb)
	return v


## A small tag: NEW / CHANGED / FIXED, a validity badge, a rarity. Solid tint
## with dark text, so it reads at 11 px.
static func badge(text: String, tint: Color = GOLD) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := _box(tint, 4, Color(0, 0, 0, 0), 0)
	sb.content_margin_left = 7
	sb.content_margin_right = 7
	sb.content_margin_top = 1
	sb.content_margin_bottom = 1
	p.add_theme_stylebox_override("panel", sb)
	var l := body(text.to_upper(), false, FS_TINY)
	l.add_theme_color_override("font_color", Color("#141208"))
	if font("bold") != null:
		l.add_theme_font_override("font", font("bold"))
	p.add_child(l)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p


## A circular avatar frame: a gold ring with a soft glow around `inner`.
static func gold_ring(inner: Control, px: int, width: float = 2.0) -> Control:
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(px + 8, px + 8)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ring := Ring.new()
	ring.width = width
	ring.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(ring)
	inner.position = Vector2(4, 4)
	inner.size = Vector2(px, px)
	holder.add_child(inner)
	return holder


class Ring extends Control:
	var width := 2.0

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5 - width
		draw_arc(c, r + width * 1.5, 0.0, TAU, 64, Color(UITheme.GOLD, 0.18), width * 3.0, true)
		draw_arc(c, r, 0.0, TAU, 64, UITheme.GOLD, width, true)
		draw_arc(c, r, -PI * 0.75, -PI * 0.25, 24, UITheme.GOLD_HI, width, true)


## Small rounded label used for costs, counts and legality states.
static func pill(text: String, tint: Color = ACCENT_2) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := _box(Color(tint, 0.15), 11, Color(tint, 0.8), 1)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	p.add_theme_stylebox_override("panel", sb)
	var l := body(text, false, FS_SMALL)
	l.add_theme_color_override("font_color", tint.lightened(0.3))
	if font("semibold") != null:
		l.add_theme_font_override("font", font("semibold"))
	p.add_child(l)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p


## Scales chrome with the window so a 1280-wide window is not left with padding
## it cannot spare.
static func margin_for(viewport_width: float) -> int:
	if viewport_width < 900:
		return SP_M
	if viewport_width < 1400:
		return SP_L
	return SP_XL
