extends Control
class_name MenuBase
##
## Shared chrome for every menu screen: background, a header with Back and the
## screen title, a message banner, a content area, and a footer.
##
## Subclasses override screen_title() and build_content(parent). They never
## touch anchors or the escape key.
##
## BUILT ON ANCHORS, NOT NESTED CONTAINERS (R-012)
## Header, content and footer are anchored to the edges of the screen with
## explicit offsets, so each has a real rect from the first frame. A child
## marked expand-fill therefore has real space to expand into, and a screen
## that wants scrolling adds its own ScrollContainer inside a content area
## that already has a height. Wrapping content in a ScrollContainer here is
## what blanked every screen in 0.2.x -- do not reintroduce it.
##

const HEADER_H := 64.0
const FOOTER_H := 24.0

var content: VBoxContainer
var status_label: Label

var _header: HBoxContainer
var _footer: HBoxContainer
var _banner: PanelContainer
var _banner_label: Label


func _ready() -> void:
	UITheme.apply_root(self, "", background_path(), background_scrim())
	if music_track() != "":
		AudioManager.play_music(music_track())

	_header = _build_header()
	add_child(_header)

	content = UITheme.vbox(UITheme.SP_M)
	add_child(content)

	# Full-width message strip. The header status is short and ellipsises, so
	# anything that needs reading -- an error especially -- also lands here
	# (R-018).
	_banner = UITheme.panel()
	_banner.visible = false
	_banner_label = UITheme.paragraph("")
	_banner.add_child(_banner_label)
	content.add_child(_banner)

	if show_footer():
		_footer = _build_footer()
		add_child(_footer)

	_layout()
	get_viewport().size_changed.connect(_layout)

	if OS.is_debug_build():
		_add_debug_readout()

	build_content(content)
	_verify_built()
	# The screen fades up (0.16.0); the content's first-level children enter
	# with a short stagger. Neither blocks input, both are instant under
	# "Reduce motion".
	Motion.enter_screen(self)
	Motion.stagger_in(content.get_children())


func _layout() -> void:
	var m := float(UITheme.margin_for(get_viewport_rect().size.x))
	var top := m * 0.55

	_header.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_header.offset_left = m
	_header.offset_right = -m
	_header.offset_top = top
	_header.offset_bottom = top + HEADER_H

	content.set_anchors_preset(Control.PRESET_FULL_RECT)
	content.offset_left = m
	content.offset_right = -m
	content.offset_top = top + HEADER_H + UITheme.SP_M
	content.offset_bottom = -(m * 0.5 + (FOOTER_H + UITheme.SP_S if show_footer() else 0.0))

	if _footer != null:
		_footer.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
		_footer.offset_left = m
		_footer.offset_right = -m
		_footer.offset_top = -(m * 0.5 + FOOTER_H)
		_footer.offset_bottom = -(m * 0.5)


func _build_header() -> HBoxContainer:
	var bar := UITheme.hbox(UITheme.SP_M)

	if show_back_button():
		var back := UITheme.ghost_button("‹  BACK", func(): SceneRouter.back())
		back.custom_minimum_size = Vector2(96, 40)
		back.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		back.add_theme_font_size_override("font_size", UITheme.FS_SMALL)
		bar.add_child(back)

	if ResourceLoader.exists("res://assets/ui/logo.png"):
		var mark := TextureRect.new()
		mark.texture = load("res://assets/ui/logo.png")
		mark.custom_minimum_size = Vector2(74, 36)
		mark.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		mark.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		mark.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bar.add_child(mark)

	var titles := UITheme.vbox(0)
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var sub := screen_subtitle()
	if sub != "":
		titles.add_child(UITheme.eyebrow(sub, UITheme.GOLD))
	# Serif, uppercase, tracked (0.16.0), with a short gold rule beneath.
	var title := UITheme.display_title(screen_title(), UITheme.FS_TITLE - 2)
	title.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
	title.add_theme_constant_override("outline_size", 4)
	titles.add_child(title)
	var rule_row := UITheme.hbox(0)
	rule_row.add_child(UITheme.gold_rule(160.0))
	rule_row.add_child(UITheme.grow())
	titles.add_child(rule_row)
	bar.add_child(titles)

	status_label = UITheme.body("", true, UITheme.FS_SMALL)
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	status_label.custom_minimum_size = Vector2(240, 0)
	status_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.add_child(status_label)

	for extra in header_extras():
		bar.add_child(extra)
	return bar


func _build_footer() -> HBoxContainer:
	var bar := UITheme.hbox(UITheme.SP_M)
	bar.add_child(UITheme.body("Battle Spirits Saga Simulator  ·  v%s" %
			ProjectSettings.get_setting("application/config/version", "0.0.0"),
			true, UITheme.FS_TINY + 1))
	bar.add_child(UITheme.grow())
	var legal := UITheme.body(
		"Unofficial fan project · Battle Spirits Saga is a trademark of Bandai",
		true, UITheme.FS_TINY + 1)
	legal.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	legal.custom_minimum_size = Vector2(420, 0)
	bar.add_child(legal)
	return bar


## If a screen ends up with no content, say so on the screen instead of showing
## an empty window.
func _verify_built() -> void:
	var real_children := 0
	for c in (content.get_children() if content != null else []):
		if c != _banner:
			real_children += 1
	if content == null or real_children > 0:
		return
	var warn := UITheme.panel()
	var v := UITheme.vbox(UITheme.SP_S)
	warn.add_child(v)
	var h := UITheme.heading("This screen built no content", UITheme.FS_HEAD)
	h.add_theme_color_override("font_color", UITheme.DANGER)
	v.add_child(h)
	v.add_child(UITheme.paragraph(
		"%s ran but added nothing. Check the Output panel for the first error."
		% get_script().resource_path.get_file()))
	content.add_child(warn)


## Debug builds only: screen name, card count and window size in the corner.
## Present-but-blank means the scene loaded and its content failed; absent
## means the scene never loaded at all.
func _add_debug_readout() -> void:
	var l := Label.new()
	l.name = "DebugReadout"
	l.add_theme_font_size_override("font_size", 10)
	l.add_theme_color_override("font_color", Color(1, 1, 1, 0.35))
	l.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	l.position = Vector2(4, -14)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.text = "%s · %d cards · %s" % [screen_title(), CardDB.count(), get_viewport_rect().size]
	add_child(l)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and show_back_button():
		SceneRouter.back()
		get_viewport().set_input_as_handled()


# --- Overridables -----------------------------------------------------------

func screen_title() -> String:
	return "Screen"


## Small gold line above the title, e.g. "PLAY" above "Battle". Empty for none.
func screen_subtitle() -> String:
	return ""


## Controls appended to the right end of the header.
func header_extras() -> Array:
	return []


func show_back_button() -> bool:
	return true


func show_footer() -> bool:
	return true


func background_path() -> String:
	return UITheme.BG_MENU


func background_scrim() -> float:
	return 0.45


## The track this screen plays. "" keeps whatever is already playing, so
## Settings or Patch Notes opened from the main menu do not restart its music.
func music_track() -> String:
	return ""


func build_content(_parent: VBoxContainer) -> void:
	pass


func set_status(text: String, error: bool = false) -> void:
	if status_label != null:
		status_label.text = text if text.length() <= 34 else text.left(33) + "…"
		status_label.add_theme_color_override("font_color",
				UITheme.DANGER if error else UITheme.TEXT_DIM)
	if _banner == null:
		return
	_banner.visible = not text.is_empty()
	_banner_label.text = text
	_banner_label.add_theme_color_override("font_color",
			UITheme.DANGER if error else UITheme.TEXT)
