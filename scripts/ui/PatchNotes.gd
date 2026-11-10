extends MenuBase
##
## Patch notes, rendered from data/patch_notes.json.
##
## Keeping the notes as data rather than as a hard-coded string means the same
## file feeds this screen, the docs, and any website you put up later. The
## build pipeline can append to it; nothing here needs to change when it does.
##
## 0.16.0: a version list on the left (newest first, the latest wearing a
## NEW badge) and a reader on the right with ADDED / CHANGED / FIXED / KNOWN
## tags, each group under a gold rule.
##

const GROUPS := [["added", "Added", "ADDED"], ["changed", "Changed", "CHANGED"],
		["fixed", "Fixed", "FIXED"], ["known_issues", "Known issues", "KNOWN"]]

var _entries: Array = []
var _reader: VBoxContainer
var _reader_scroll: ScrollContainer
var _rows := {}
var _selected := 0


func screen_title() -> String: return "Patch Notes"
func screen_subtitle() -> String: return "What's new"


func build_content(parent: VBoxContainer) -> void:
	_entries = _load()
	if _entries.is_empty():
		parent.add_child(UITheme.body("No patch notes found (data/patch_notes.json).", true))
		return
	if status_label != null:
		status_label.text = "%d release(s)" % _entries.size()

	var split := UITheme.hbox(UITheme.SP_M)
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(split)

	# Left: the version list.
	var list_panel := UITheme.panel(Vector2(300, 0))
	list_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(list_panel)
	var lv := UITheme.vbox(UITheme.SP_S)
	list_panel.add_child(lv)
	lv.add_child(UITheme.eyebrow("Releases", UITheme.GOLD))
	var list_scroll := ScrollContainer.new()
	list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	list_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	lv.add_child(list_scroll)
	var list := UITheme.vbox(4)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_scroll.add_child(list)
	for i in _entries.size():
		list.add_child(_version_row(i))
	Motion.stagger_in(list.get_children())

	# Right: the reader.
	var reader_panel := UITheme.panel()
	reader_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reader_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(reader_panel)
	_reader_scroll = ScrollContainer.new()
	_reader_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_reader_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	reader_panel.add_child(_reader_scroll)
	_reader = UITheme.vbox(UITheme.SP_S)
	_reader.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_reader_scroll.add_child(_reader)
	_show(0)


## One release in the list: version in the number face, date, headline, and
## a NEW badge on the latest.
func _version_row(i: int) -> Control:
	var e: Dictionary = _entries[i]
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, 56)
	b.focus_mode = Control.FOCUS_NONE
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.text = ""
	b.pressed.connect(func():
		AudioManager.play_sfx("ui_click")
		_show(i))
	b.mouse_entered.connect(func(): AudioManager.play_sfx("ui_hover"))
	Motion.press_feedback(b)
	var row := UITheme.hbox(UITheme.SP_S)
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 12
	row.offset_right = -10
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(row)
	var texts := UITheme.vbox(0)
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	texts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ver := UITheme.number("v%s" % str(e.get("version", "?")), UITheme.FS_HEAD)
	ver.mouse_filter = Control.MOUSE_FILTER_IGNORE
	texts.add_child(ver)
	var headline := str(e.get("codename", ""))
	var sub := UITheme.truncating("%s%s" % [str(e.get("date", "")),
			("  ·  " + headline) if headline != "" else ""], true, UITheme.FS_SMALL - 1)
	sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
	texts.add_child(sub)
	row.add_child(texts)
	if i == 0:
		var badge := UITheme.badge("New", UITheme.CORE)
		row.add_child(badge)
	_rows[i] = b
	return b


func _show(i: int) -> void:
	_selected = i
	for k: int in _rows:
		var b := _rows[k] as Button
		if k == i:
			b.add_theme_stylebox_override("normal",
					UITheme._box(Color(UITheme.SURFACE_HI, 0.98), UITheme.RADIUS, UITheme.GOLD, 1))
			b.add_theme_stylebox_override("hover",
					UITheme._box(Color(UITheme.SURFACE_HI, 0.98), UITheme.RADIUS, UITheme.GOLD_HI, 1))
		else:
			b.add_theme_stylebox_override("normal",
					UITheme._box(Color(UITheme.SURFACE, 0.5), UITheme.RADIUS, Color(UITheme.LINE, 0.8)))
			b.add_theme_stylebox_override("hover",
					UITheme._box(Color(UITheme.SURFACE_HI, 0.8), UITheme.RADIUS, Color(UITheme.GOLD, 0.6)))
	for c in _reader.get_children():
		c.queue_free()
	var e: Dictionary = _entries[i]
	var head := UITheme.hbox(UITheme.SP_M)
	var title := UITheme.display_title("Version %s" % str(e.get("version", "?")), UITheme.FS_TITLE - 4)
	head.add_child(title)
	if i == 0:
		head.add_child(UITheme.badge("New", UITheme.CORE))
	head.add_child(UITheme.grow())
	var date := UITheme.body(str(e.get("date", "")), true, UITheme.FS_SMALL)
	date.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(date)
	_reader.add_child(head)
	if not str(e.get("codename", "")).is_empty():
		_reader.add_child(UITheme.body("\"%s\"" % e["codename"], true))
	_reader.add_child(UITheme.gold_rule())

	for g: Array in GROUPS:
		var items: Array = e.get(str(g[0]), [])
		if items.is_empty():
			continue
		_reader.add_child(UITheme.spacer(6))
		var gh := UITheme.hbox(UITheme.SP_S)
		gh.add_child(UITheme.badge(str(g[2]), _group_tint(str(g[0]))))
		var gl := UITheme.display_title(str(g[1]), UITheme.FS_BODY + 1)
		gl.add_theme_color_override("font_color",
				UITheme.BAD if g[0] == "known_issues" else UITheme.TEXT)
		gh.add_child(gl)
		_reader.add_child(gh)
		_reader.add_child(UITheme.rule())
		for item in items:
			_reader.add_child(_bullet(str(item), _group_tint(str(g[0]))))
	Motion.stagger_in(_reader.get_children())
	if _reader_scroll != null:
		_reader_scroll.scroll_vertical = 0


func _group_tint(group: String) -> Color:
	match group:
		"added": return UITheme.OK
		"changed": return UITheme.GOLD
		"fixed": return UITheme.CORE
	return UITheme.BAD


## A tinted dot and a wrapping line, as one RichTextLabel (a wrapping label
## beside a dot in an HBox is the collapse trap of 11.9).
func _bullet(text: String, tint: Color) -> Control:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.add_theme_font_size_override("normal_font_size", UITheme.FS_BODY - 1)
	r.add_theme_color_override("default_color", UITheme.TEXT)
	r.text = "[color=#%s]◆[/color]  %s" % [tint.to_html(false), text.replace("[", "[lb]")]
	return r


func _load() -> Array:
	var f := FileAccess.open("res://data/patch_notes.json", FileAccess.READ)
	if f == null:
		return []
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return []
	return parsed.get("releases", [])
