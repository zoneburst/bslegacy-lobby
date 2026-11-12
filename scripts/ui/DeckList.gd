extends MenuBase
##
## Your decks as a grid of tiles: cover art, name, colours, size and legality.
## Click a tile to edit it; the buttons on each tile set it as your battle
## deck, duplicate it, or delete it.
##

const TILE_W := 300.0

var _grid: GridContainer
var _scroll: ScrollContainer
var _cleanup_bar: Control


func screen_title() -> String: return "Decks"
func screen_subtitle() -> String: return "Deck builder"


func header_extras() -> Array:
	var imp := UITheme.button("Import list", _import)
	imp.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	imp.custom_minimum_size = Vector2(0, 44)
	var new_b := UITheme.hero_button("+  New deck", func(): SceneRouter.go("deck_editor"), UITheme.FS_BODY)
	new_b.custom_minimum_size = Vector2(170, 44)
	new_b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return [imp, new_b]


func music_track() -> String:
	return "deck_theme"


func build_content(parent: VBoxContainer) -> void:
	_cleanup_bar = UITheme.hbox(UITheme.SP_S)
	parent.add_child(_cleanup_bar)

	_scroll = ScrollContainer.new()
	# SHOW_NEVER (0.17.4, R-104): a ScrollContainer with horizontal scrolling
	# DISABLED is at least as wide as its content, so once the tiles had
	# spread for a wide window the grid could never get narrower again.
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# 0.16.5: a margin below the tiles so the grid never sits on the footer
	var holder := MarginContainer.new()
	holder.add_theme_constant_override("margin_bottom", UITheme.SP_L)
	holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	holder.add_child(_scroll)
	parent.add_child(holder)
	_grid = GridContainer.new()
	_grid.add_theme_constant_override("h_separation", UITheme.SP_M)
	_grid.add_theme_constant_override("v_separation", UITheme.SP_M)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_grid)
	_scroll.resized.connect(_reflow)

	DeckManager.decks_changed.connect(_rebuild)
	_rebuild()


## As many columns as fit, then the tiles share the width between them so
## the grid fills the screen at any size.
func _reflow() -> void:
	var usable := _scroll.size.x - 12.0
	var gap := float(UITheme.SP_M)
	var cols := maxi(1, int((usable + gap) / (TILE_W + gap)))
	_grid.columns = cols
	var w := floorf((usable - float(cols - 1) * gap) / float(cols))
	for c in _grid.get_children():
		if c is Control:
			(c as Control).custom_minimum_size.x = maxf(TILE_W, w)


func _rebuild() -> void:
	for c in _grid.get_children():
		_grid.remove_child(c)          # out of the layout now, not at frame end
		c.queue_free()
	_build_cleanup_bar()

	var decks := DeckManager.visible_decks().filter(
			func(d): return not (d.get("main", []) as Array).is_empty())
	for d in decks:
		_grid.add_child(_tile(d))
	_grid.add_child(_new_tile())
	_reflow()
	Motion.stagger_in(_grid.get_children())


## Empty decks are leftovers from the pre-0.6.0 editor, which saved a blank deck
## every time it was opened (R-021). They are hidden from the grid and offered
## for removal here -- never deleted without the player asking.
func _build_cleanup_bar() -> void:
	for c in _cleanup_bar.get_children():
		c.queue_free()
	var empties := DeckManager.empty_decks()
	_cleanup_bar.visible = not empties.is_empty()
	if empties.is_empty():
		return
	_cleanup_bar.add_child(UITheme.body(
		"%d empty deck%s left over from an earlier version." % [
			empties.size(), "" if empties.size() == 1 else "s"], true))
	_cleanup_bar.add_child(UITheme.button("Remove them", func():
		Modal.confirm(self, "Remove empty decks?",
			"This deletes %d deck%s with no cards in them. Decks with cards are not touched."
			% [empties.size(), "" if empties.size() == 1 else "s"],
			func():
				for d in DeckManager.empty_decks():
					DeckManager.delete(str(d["id"]))
				set_status("Removed empty decks"),
			"Remove", true)))


## A deck tile: cover art fading into the panel, a validity badge in the
## corner, name, colour gems, card count, and a compact action row. The
## battle deck wears a gold frame; every tile lifts on hover.
func _tile(d: Dictionary) -> Control:
	var id := str(d["id"])
	var val: Dictionary = DeckManager.validate(d)
	var legal := bool(val.get("ok", false))
	var active := id == GameConfig.default_deck_id
	var n := (d.get("main", []) as Array).size()

	var p := UITheme.hero_panel(Vector2(TILE_W, 0)) if active else UITheme.panel(Vector2(TILE_W, 0))
	var sb: StyleBoxFlat = p.get_theme_stylebox("panel").duplicate()
	sb.set_content_margin_all(0)
	p.add_theme_stylebox_override("panel", sb)
	p.clip_contents = true
	Motion.hover_lift(p, 1.03)
	Motion.glint(p)
	var v := UITheme.vbox(0)
	p.add_child(v)

	# Cover: the deck's most expensive spirit, cropped to a banner that fades
	# into the surface. A click opens the editor.
	var cover_box := Control.new()
	cover_box.custom_minimum_size = Vector2(0, 136)
	cover_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(cover_box)
	var cover := TextureRect.new()
	cover.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cover.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	cover.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	var cover_id := _cover_card(d)
	if cover_id != "":
		# The art sits in the top half of the face: the cover shows the art
		# itself (0.18.0: CardDB's art crop, as the new card layout has it),
		# scaled to cover the banner.
		var art_tex: Texture2D = CardDB.get_card_art_texture(cover_id)
		if art_tex != null:
			cover.texture = art_tex
	cover.mouse_filter = Control.MOUSE_FILTER_STOP
	cover.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	cover.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			AudioManager.play_sfx("ui_click")
			SceneRouter.go("deck_editor", {"deck_id": id}))
	cover_box.add_child(cover)
	var fade := TextureRect.new()
	fade.texture = _fade_texture()
	fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	fade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	fade.stretch_mode = TextureRect.STRETCH_SCALE
	fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cover_box.add_child(fade)
	var badge: Control
	if active:
		badge = UITheme.badge("Battle deck", UITheme.GOLD)
	elif legal:
		badge = UITheme.badge("✓ Legal", UITheme.OK)
	else:
		badge = UITheme.badge("%d/50" % n if n < 50 else "!", UITheme.WARN if n < 50 else UITheme.BAD)
		badge.tooltip_text = str(val.get("reason", "Not legal"))
		badge.mouse_filter = Control.MOUSE_FILTER_PASS
	badge.anchor_left = 1.0
	badge.anchor_right = 1.0
	badge.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	badge.offset_right = -8
	badge.offset_left = -8
	badge.offset_top = 8
	badge.offset_bottom = 8
	cover_box.add_child(badge)

	var inner := UITheme.vbox(UITheme.SP_XS)
	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 12)
	pad.add_theme_constant_override("margin_right", 12)
	pad.add_theme_constant_override("margin_top", 6)
	pad.add_theme_constant_override("margin_bottom", 10)
	pad.add_child(inner)
	v.add_child(pad)

	var name_label := UITheme.truncating(str(d.get("name", "Untitled")), false, UITheme.FS_HEAD - 2)
	if UITheme.font("display") != null:
		name_label.add_theme_font_override("font", UITheme.font("display"))
	inner.add_child(name_label)

	var row := UITheme.hbox(UITheme.SP_XS)
	for c in _deck_colors(d):
		row.add_child(UITheme.color_dot(int(c), 14))
	row.add_child(UITheme.spacer(0))
	row.add_child(UITheme.number("%d cards" % n, UITheme.FS_SMALL, UITheme.TEXT_DIM))
	row.add_child(UITheme.grow())
	var rec := _record(d)
	if rec != "":
		row.add_child(UITheme.number(rec, UITheme.FS_SMALL, UITheme.TEXT_DIM))
	inner.add_child(row)

	var actions := UITheme.hbox(UITheme.SP_XS)
	var edit := UITheme.button("Edit", func(): SceneRouter.go("deck_editor", {"deck_id": id}))
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.custom_minimum_size = Vector2(0, 34)
	edit.add_theme_font_size_override("font_size", UITheme.FS_SMALL)
	actions.add_child(edit)
	var use := UITheme.button("Use", func():
		GameConfig.default_deck_id = id
		GameConfig.save_settings()
		set_status("\"%s\" is now your battle deck" % d.get("name", ""))
		_rebuild())
	use.disabled = not legal or active
	use.tooltip_text = "Make this the deck you take into battle"
	use.custom_minimum_size = Vector2(0, 34)
	use.add_theme_font_size_override("font_size", UITheme.FS_SMALL)
	actions.add_child(use)
	var copy := UITheme.button("Copy", func():
		DeckManager.duplicate_deck(id)
		set_status("Duplicated \"%s\"" % d.get("name", "")))
	copy.custom_minimum_size = Vector2(0, 34)
	copy.add_theme_font_size_override("font_size", UITheme.FS_SMALL)
	actions.add_child(copy)
	var del := UITheme.danger_button("Delete", func():
		Modal.confirm(self, "Delete deck?",
			"\"%s\" will be deleted permanently." % d.get("name", ""),
			func(): DeckManager.delete(id), "Delete", true))
	del.custom_minimum_size = Vector2(0, 34)
	del.add_theme_font_size_override("font_size", UITheme.FS_SMALL)
	actions.add_child(del)
	inner.add_child(actions)
	return p


## "W-L" for a deck that has been played, from the profile.
func _record(d: Dictionary) -> String:
	for r: Dictionary in PlayerProfile.stats_by_deck():
		if str(r.get("name", "")) == str(d.get("name", "")) and int(r.get("games", 0)) > 0:
			return "%d-%d" % [int(r["wins"]), int(r["losses"])]
	return ""


static var _fade: Texture2D = null


## A vertical gradient, transparent to the panel surface, laid over a cover.
static func _fade_texture() -> Texture2D:
	if _fade != null:
		return _fade
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	g.colors = PackedColorArray([Color(UITheme.SURFACE, 0.0), Color(UITheme.SURFACE, 0.0),
			Color(UITheme.SURFACE, 0.96)])
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(0, 1)
	gt.width = 4
	gt.height = 64
	_fade = gt
	return _fade


func _new_tile() -> Control:
	var b := Button.new()
	b.text = "+\n\nNew deck"
	b.custom_minimum_size = Vector2(TILE_W, 240)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", UITheme.FS_HEAD)
	var f := UITheme.title_font(UITheme.FS_HEAD)
	if f != null:
		b.add_theme_font_override("font", f)
	var dashed := UITheme._box(Color(1, 1, 1, 0.025), UITheme.RADIUS, Color(UITheme.GOLD, 0.35), 1)
	b.add_theme_stylebox_override("normal", dashed)
	b.add_theme_stylebox_override("hover", UITheme._box(Color(1, 1, 1, 0.05), UITheme.RADIUS, UITheme.GOLD_HI, 1))
	b.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	b.add_theme_color_override("font_hover_color", UITheme.GOLD_HI)
	b.pressed.connect(func():
		AudioManager.play_sfx("ui_click")
		SceneRouter.go("deck_editor"))
	Motion.hover_lift(b, 1.02)
	return b


func _cover_card(d: Dictionary) -> String:
	var best := ""
	var best_cost := -1
	for id in d.get("main", []):
		var cd: CardData = CardDB.get_card(str(id))
		if cd != null and cd.is_spirit() and cd.cost > best_cost:
			best_cost = cd.cost
			best = str(id)
	if best == "" and not (d.get("main", []) as Array).is_empty():
		best = str(d["main"][0])
	return best


func _deck_colors(deck: Dictionary) -> Array:
	var seen := {}
	for id in deck.get("main", []):
		var cd: CardData = CardDB.get_card(str(id))
		if cd != null:
			for c in cd.colors:
				seen[int(c)] = true
	var out: Array = seen.keys()
	out.sort()
	return out


func _import() -> void:
	Modal.text_input(self, "Import a decklist",
		"Paste a list, one line per card, e.g.\n4 ST01-009 Dragron Trooper\n4x BSS01-001: Supernova Dragon Siegwurm Nova\n\n=== Sideboard ===\n2 BSS01-122 Deadly Balance",
		func(text: String):
			if text.strip_edges().is_empty():
				return
			var d := DeckManager.from_text(text, "Imported Deck")
			var rep: Dictionary = DeckManager.last_import
			var msg := "Imported %d cards" % int(rep.get("main", 0))
			if int(rep.get("side", 0)) > 0:
				msg += " and a %d-card sideboard" % int(rep.get("side", 0))
			var unknown: Array = rep.get("unknown", [])
			if not unknown.is_empty():
				msg += " · not found: %s%s" % [", ".join(unknown.slice(0, 4)), "…" if unknown.size() > 4 else ""]
			if int(rep.get("dropped", 0)) > 0:
				msg += " · %d over the limits left out" % int(rep.get("dropped", 0))
			set_status(msg, not unknown.is_empty())
			SceneRouter.go("deck_editor", {"deck_id": str(d["id"]), "status": msg}),
		"Import")
