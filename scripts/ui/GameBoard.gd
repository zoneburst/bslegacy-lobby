extends Control
class_name GameBoard
##
## The play surface, laid out after the official Battle Spirits Saga playsheet.
##
## Each player's half mirrors the physical mat: LIFE, BURST and RESERVE down
## one side, the FIELD across the middle, DECK and TRASH on the other side. The
## opponent's half is the same mat turned to face you, so their life column sits
## on your right and their deck on your left -- exactly as across a table.
##
##   +-------------------------------------------------------+-------------+
##   |  opponent name · hand (face down)                      |             |
##   |  [deck][trash]       OPPONENT FIELD       [life][burst][reserve] |  CARD       |
##   |  ---- step tracker · turn · prompt · actions --------- |  PREVIEW    |
##   |  [life][burst][reserve]      YOUR FIELD       [deck][trash] |             |
##   |                  YOUR HAND (fanned)                    |  GAME LOG   |
##   +-------------------------------------------------------+-------------+
##
## This scene contains no rules logic. It renders a snapshot and sends actions
## through MatchService. In local games it asks the engine which actions are
## LEGAL (RulesEngine.legal_actions) and only offers those, so a click never
## produces a "rejected" message for something the UI suggested.
##
## Presentation (0.7.0): updates no longer just redraw. Each update is
## PRESENTED -- the board redraws in the new state, then BattleDirector plays
## the engine events in between (draw, summon, attack, block, clash, damage...)
## on the BattleFX overlay. While that runs, is_presenting() is true, the AI
## waits (MatchService._run_auto) and clicks speed the animation up instead of
## acting. See "Presentation" below and the architecture guide, section 13.
##
## Layout: the root regions are anchored; inside them, rows and columns have
## explicit minimum sizes; the hand fan and exhausted-card rotation live in
## plain Controls whose children are positioned by this script, never by a
## container (architecture guide 11.9).
##

const SIDE_W := 330.0
const ZONE_COL_W := 172.0
const FIELD_CARD := Vector2(112, 157)
const HAND_CARD := Vector2(124, 174)
const MINI_CARD := Vector2(60, 84)
const SLOT_CARD := Vector2(52, 73)
const PINCH_LIFE := 2

var _snap: Dictionary = {}
var _legal: Array = []
var _selected_options := {}       # uid -> true, for multi-select prompts

# regions
var _opp_bar: HBoxContainer
var _opp_hand: Control
var _opp_left: VBoxContainer
var _opp_right: VBoxContainer
var _opp_field: HBoxContainer
var _opp_nexus: HBoxContainer       # 0.16.2: nexuses on their own row
var _my_left: VBoxContainer
var _my_right: VBoxContainer
var _my_field: HBoxContainer
var _my_nexus: HBoxContainer
var _hand: Control
var _steps: HBoxContainer
var _turn_label: Label
var _prompt: Label
var _prompt_extra: HBoxContainer
var _actions: HBoxContainer
var _toast: Label
var _preview_card: CardWidget
var _preview_name: Label
var _preview_meta: Label
var _preview_text: RichTextLabel
var _preview_reason: Label
var _log_box: VBoxContainer
var _log_scroll: ScrollContainer
var _menu: PopupMenu
var _menu_actions: Array = []
var _ended := false
var _render_queued := false

# presentation (0.7.0)
var _play_area: Control
var _centre_panel: Control
var _fx: BattleFX
var _director: BattleDirector
var _widgets: Dictionary = {}       # uid -> CardWidget on screen right now
var _vis: Dictionary = {}           # uid -> the node to fade in (holder or widget)
var _anchors: Dictionary = {}       # "pid:zone" -> Control
var _step_pills: Array = []
var _hidden: Dictionary = {}        # uid -> true: drawn invisible, an effect will reveal it
var _pending_orient: Dictionary = {} # uid -> exhausted(bool) still to animate
var _shown_snap: Dictionary = {}    # the snapshot currently on screen
var _last_serial := -1              # last engine event already presented
var _presenting := false
var _dirty := false
var _pending_end: Dictionary = {}


func _ready() -> void:
	UITheme.apply_root(self, "", UITheme.BG_BOARD, 0.0)
	_build()
	_fx = BattleFX.new()
	add_child(_fx)
	_fx.shake_target = _play_area
	_director = BattleDirector.new(self, _fx)
	add_child(_director)
	MatchService.presenter = self
	MatchService.updated.connect(_on_update)
	MatchService.ended.connect(_on_ended)
	MatchService.rejected.connect(_on_rejected)
	if _gate_open_wanted():
		# "Gate Open, Kaiho!" (0.18.4): the opening plays over the board before
		# the first deal. Updates that arrive meanwhile are kept, not shown.
		# The music waits for it (0.18.7), so the opening's sound stands alone.
		_intro = true
		var mine: Array = GateOpen.deck_colour_and_key(MatchService.my_deck)
		var theirs: Array = GateOpen.deck_colour_and_key(MatchService.opponent_deck())
		var g := GateOpen.start(self, GameConfig.gate_open, GateOpen.deck_colours(MatchService.my_deck), theirs[0], mine[1])
		await g.finished
		if not is_inside_tree():
			return
		_intro = false
	AudioManager.play_music("battle_theme")
	if not MatchService.snapshot.is_empty():
		_on_update(MatchService.snapshot)
		MatchService.board_ready()    # a CPU held for the board acts now, paced (0.20.0)
	elif MatchService.kind == MatchService.Kind.NONE:
		# No match at all (R-083): never leave the player on an empty board.
		_prompt.text = "There is no match in progress."
		SceneRouter.go.call_deferred("main")
	else:
		_prompt.text = "Waiting for the match to start…"


func _exit_tree() -> void:
	if MatchService.presenter == self:
		MatchService.presenter = null


# ============================================================================
# Layout
# ============================================================================

func _build() -> void:
	var board := Control.new()
	board.set_anchors_preset(Control.PRESET_FULL_RECT)
	board.offset_right = -SIDE_W - 12
	board.offset_left = 12
	board.offset_top = 8
	board.offset_bottom = -8
	add_child(board)
	_play_area = board

	var col := UITheme.vbox(6)
	col.set_anchors_preset(Control.PRESET_FULL_RECT)
	board.add_child(col)

	# --- Opponent bar + face-down hand ---
	_opp_bar = UITheme.hbox(UITheme.SP_M)
	_opp_bar.custom_minimum_size = Vector2(0, 30)
	col.add_child(_opp_bar)
	_opp_hand = Control.new()
	_opp_hand.custom_minimum_size = Vector2(0, 52)
	_opp_hand.clip_contents = true
	_opp_hand.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_opp_hand.resized.connect(_layout_opp_hand)
	col.add_child(_opp_hand)

	# --- Opponent mat (mirrored: deck/trash left, life/burst/reserve right) ---
	var opp_row := UITheme.hbox(UITheme.SP_S)
	opp_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(opp_row)
	_opp_left = _zone_column()
	opp_row.add_child(_wrap_zone(_opp_left))
	opp_row.add_child(_field_panel(true))
	_opp_right = _zone_column()
	opp_row.add_child(_wrap_zone(_opp_right))

	# --- Centre strip ---
	col.add_child(_build_centre())

	# --- Your mat (life/burst/reserve left, deck/trash right) ---
	var my_row := UITheme.hbox(UITheme.SP_S)
	my_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(my_row)
	_my_left = _zone_column()
	my_row.add_child(_wrap_zone(_my_left))
	my_row.add_child(_field_panel(false))
	_my_right = _zone_column()
	my_row.add_child(_wrap_zone(_my_right))

	# --- Hand ---
	_hand = Control.new()
	_hand.custom_minimum_size = Vector2(0, HAND_CARD.y * 0.86)
	_hand.mouse_filter = Control.MOUSE_FILTER_PASS
	_hand.resized.connect(_layout_hand)
	col.add_child(_hand)

	_build_side()

	_menu = PopupMenu.new()
	_menu.id_pressed.connect(_on_menu)
	add_child(_menu)


func _zone_column() -> VBoxContainer:
	var v := UITheme.vbox(UITheme.SP_S)
	v.custom_minimum_size = Vector2(ZONE_COL_W - 28, 0)
	return v


func _wrap_zone(inner: Control) -> Control:
	var p := UITheme.panel(Vector2(ZONE_COL_W, 0))
	var sb := UITheme._panel_box(Color(0.04, 0.06, 0.13, 0.78))
	sb.set_content_margin_all(10)
	p.add_theme_stylebox_override("panel", sb)
	p.add_child(inner)
	return p


func _field_panel(opponent: bool) -> Control:
	var p := PanelContainer.new()
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.05, 0.12, 0.45)
	sb.set_corner_radius_all(14)
	sb.set_border_width_all(1)
	sb.border_color = Color(UITheme.SOUL if opponent else UITheme.CORE, 0.35)
	sb.set_content_margin_all(8)
	p.add_theme_stylebox_override("panel", sb)

	var label := UITheme.eyebrow("Opponent field" if opponent else "Your field",
			Color(1, 1, 1, 0.22))
	label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(label)

	# 0.9.0 (R-041): the row of cards lives inside a PLAIN Control. A
	# container's minimum width is the sum of its children's, so with enough
	# spirits out the field row used to widen the whole board until it slid
	# under the card-preview column. A plain Control does not take its size
	# from its children: the board stays put, and _field_card_size() shrinks
	# the cards to fit the area instead. clip_contents is the backstop.
	var whole := Control.new()
	whole.mouse_filter = Control.MOUSE_FILTER_PASS
	whole.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	whole.size_flags_vertical = Control.SIZE_EXPAND_FILL
	p.add_child(whole)
	# 0.16.2: spirits and nexuses on separate rows. Spirits take the front of
	# the field (the half nearer the opponent), nexuses the back: for you the
	# top and the bottom, for the opponent the bottom and the top. Each row is
	# a plain clipped Control of a fixed share of the height, so the layout
	# never changes when the first nexus arrives.
	var sp_area := _field_area(whole, 0.0 if not opponent else 1.0 - SPIRIT_SHARE,
			SPIRIT_SHARE if not opponent else 1.0)
	var nx_area := _field_area(whole, SPIRIT_SHARE if not opponent else 0.0,
			1.0 if not opponent else 1.0 - SPIRIT_SHARE)
	var row := UITheme.hbox(UITheme.SP_S)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sp_area.add_child(row)
	var nrow := UITheme.hbox(UITheme.SP_S)
	nrow.alignment = BoxContainer.ALIGNMENT_CENTER
	nrow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	nx_area.add_child(nrow)
	var nl := UITheme.eyebrow("Nexuses", Color(1, 1, 1, 0.16))
	nl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	nl.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	nl.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	nl.position = Vector2(-nl.size.x - 4, 0)
	nx_area.add_child(nl)
	if opponent:
		_opp_field = row
		_opp_nexus = nrow
	else:
		_my_field = row
		_my_nexus = nrow
	return p


const SPIRIT_SHARE := 0.62      # of the field's height; nexuses get the rest


func _field_area(parent: Control, top: float, bottom: float) -> Control:
	var area := Control.new()
	area.clip_contents = true
	area.mouse_filter = Control.MOUSE_FILTER_PASS
	area.anchor_left = 0.0
	area.anchor_right = 1.0
	area.anchor_top = top
	area.anchor_bottom = bottom
	area.offset_left = 0
	area.offset_right = 0
	area.offset_top = 0
	area.offset_bottom = 0
	area.resized.connect(_on_field_area_resized)
	parent.add_child(area)
	return area


func _build_centre() -> Control:
	var p := PanelContainer.new()
	var sb := UITheme._panel_box(Color(0.05, 0.08, 0.17, 0.92), UITheme.BORDER_HI)
	sb.set_content_margin_all(10)
	p.add_theme_stylebox_override("panel", sb)
	p.custom_minimum_size = Vector2(0, 96)
	_centre_panel = p

	var row := UITheme.hbox(UITheme.SP_M)
	p.add_child(row)

	var left := UITheme.vbox(6)
	left.custom_minimum_size = Vector2(520, 0)
	row.add_child(left)
	var top := UITheme.hbox(UITheme.SP_M)
	left.add_child(top)
	_turn_label = UITheme.heading("", UITheme.FS_HEAD - 2)
	top.add_child(_turn_label)
	_steps = UITheme.hbox(4)
	top.add_child(_steps)
	_prompt = UITheme.paragraph("", false, UITheme.FS_BODY)
	left.add_child(_prompt)

	var mid := UITheme.vbox(4)
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(mid)
	_prompt_extra = UITheme.hbox(UITheme.SP_XS)
	mid.add_child(_prompt_extra)
	_toast = UITheme.paragraph("", false, UITheme.FS_SMALL)
	_toast.add_theme_color_override("font_color", UITheme.DANGER)
	mid.add_child(_toast)

	_actions = UITheme.hbox(UITheme.SP_S)
	_actions.alignment = BoxContainer.ALIGNMENT_END
	_actions.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_actions)
	return p


func _build_side() -> void:
	var side := UITheme.panel()
	side.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	side.offset_left = -SIDE_W
	side.offset_right = -8
	side.offset_top = 8
	side.offset_bottom = -8
	add_child(side)
	var v := UITheme.vbox(UITheme.SP_S)
	side.add_child(v)

	var head := UITheme.hbox(UITheme.SP_S)
	var title := UITheme.eyebrow("Card", UITheme.ACCENT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	head.add_child(UITheme.danger_button("Concede", _confirm_concede))
	v.add_child(head)

	var holder := CenterContainer.new()
	holder.custom_minimum_size = Vector2(0, 300)
	v.add_child(holder)
	_preview_card = CardWidget.new()
	_preview_card.setup_back(Vector2(206, 288))
	holder.add_child(_preview_card)
	_preview_name = UITheme.truncating("Hover a card to see it here", false, UITheme.FS_HEAD - 2)
	if UITheme.font("bold") != null:
		_preview_name.add_theme_font_override("font", UITheme.font("bold"))
	v.add_child(_preview_name)
	_preview_meta = UITheme.body("", true, UITheme.FS_SMALL)
	v.add_child(_preview_meta)
	_preview_reason = UITheme.paragraph("", false, UITheme.FS_SMALL)
	_preview_reason.add_theme_color_override("font_color", UITheme.DANGER)
	v.add_child(_preview_reason)
	_preview_text = UITheme.card_text("", UITheme.FS_SMALL)
	v.add_child(_preview_text)

	v.add_child(UITheme.rule())
	v.add_child(UITheme.eyebrow("Game log"))
	_log_scroll = ScrollContainer.new()
	_log_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_log_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(_log_scroll)
	_log_box = UITheme.vbox(2)
	_log_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_log_scroll.add_child(_log_box)


# ============================================================================
# Rendering
# ============================================================================

## Updates are COALESCED: the snapshot is stored and the board redraws once,
## at the end of the frame, however many updates arrived.
##
## During the AI's turn MatchService used to emit an update after every AI
## action -- ten or twenty in a single frame. Rebuilding the whole board for
## each one queued thousands of node frees and redraws inside one frame, until
## Godot's message queue overflowed and the game crashed (R-025). With
## animations on, the AI is now paced, but coalescing stays: an update that
## arrives mid-presentation only marks the board dirty, and the next
## presentation picks up every event since the last one.
func _on_update(snap: Dictionary) -> void:
	_snap = snap
	if not _drop_move.is_empty():
		_drop_pending = _drop_move        # this update carries the dragged core's move
	if _intro:
		return                      # shown when the opening has finished
	if _presenting:
		_dirty = true
		return
	if _anims_on() and _has_new_events():
		_presenting = true          # the AI must wait from this moment on
	if _render_queued:
		return
	_render_queued = true
	_present.call_deferred()


func _anims_on() -> bool:
	return GameConfig.battle_animations


var _intro := false


## The opening plays once per board, for a match at its start, with battle
## animations on and reduce motion off, when a variant is chosen in Settings.
func _gate_open_wanted() -> bool:
	if GameConfig.gate_open == "off" or not GameConfig.battle_animations or GameConfig.reduce_motion:
		return false
	if GateOpen.shown_this_session:
		return false                 # once per session
	if MatchService.kind == MatchService.Kind.NONE:
		return false
	var snap := MatchService.snapshot
	return snap.is_empty() or int(snap.get("turn_number", 1)) <= 1


func is_presenting() -> bool:
	# The opening counts (0.18.8): the CPU waits for it like any animation,
	# so its first turn is not played out of sight and shown in a rush after.
	return _presenting or _render_queued or _intro


func _has_new_events() -> bool:
	if MatchService.engine != null:
		return MatchService.engine.state.event_serial - 1 > _last_serial
	return not _shown_snap.is_empty()


## Engine events since the last presentation; for online games (no engine)
## they are rebuilt from the snapshot difference.
func _collect_events() -> Array:
	if MatchService.engine != null:
		var st := MatchService.engine.state
		var out: Array = []
		for e: Dictionary in st.event_log:
			if int(e.get("t", -1)) > _last_serial:
				out.append(e)
		_last_serial = st.event_serial - 1
		return out
	return BattleDirector.synthesize(_shown_snap, _snap, MatchService.my_seat)


func _present() -> void:
	_render_queued = false
	if not is_inside_tree():
		return
	var events: Array = _collect_events()
	# A board that opens on a game already under way (spectating, coming back
	# to the scene) shows the current state, not a replay of every turn so far.
	# Only the opening deal is presented on a first look.
	if _shown_snap.is_empty():
		for e: Dictionary in events:
			if str(e.get("kind", "")) == "turn_start" and int((e.get("data", {}) as Dictionary).get("n", 0)) > 1:
				events = []
				break
	if not _anims_on() or events.is_empty():
		_drop_pending = {}
		_hidden.clear()
		_pending_orient.clear()
		_render()
		_shown_snap = _snap
		_presenting = false
		_after_present()
		return
	_presenting = true
	var before := _capture_rects()
	var prev := _shown_snap
	_hidden = BattleDirector.incoming_uids(events)
	_render()
	_shown_snap = _snap
	_fx.begin()
	await _fx.wait(0.0)           # let containers lay the new board out
	await _director.play(events, before, prev)
	_finish_presentation()


func _finish_presentation() -> void:
	_drop_pending = {}
	for uid: int in _hidden.keys():
		reveal(uid)
	_hidden.clear()
	for uid: int in _pending_orient.keys():
		animate_orient(uid)
	_fx.dim(0.0, 0.1)
	_fx.end()
	_presenting = false
	_sync_arrow()
	if _dirty:
		_dirty = false
		_on_update(_snap)
		return
	_after_present()


func _after_present() -> void:
	if not _pending_end.is_empty() and not _ended:
		_show_end(_pending_end)


## Where every card is before the board is rebuilt, so a card that is about
## to disappear (destroyed, used) can be shown leaving from where it was.
func _capture_rects() -> Dictionary:
	var out := {}
	for uid: int in _widgets.keys():
		var w: CardWidget = _widgets[uid]
		if is_instance_valid(w) and w.is_inside_tree():
			out[uid] = {"rect": BattleFX.visual_rect(w), "card_id": w.card_id}
	return out


func _render() -> void:
	_render_queued = false
	if not is_inside_tree():
		return
	_widgets.clear()
	_vis.clear()
	_anchors.clear()
	_legal = []
	if MatchService.engine != null and not MatchService.is_spectator:
		_legal = MatchService.engine.legal_actions(MatchService.my_seat)
	var me: Dictionary = MatchService.my_state()
	var opp: Dictionary = MatchService.opponent_state()
	if me.is_empty():
		return
	var opp_seat := 1 - MatchService.my_seat if MatchService.my_seat >= 0 else 1
	var my_seat := MatchService.my_seat if MatchService.my_seat >= 0 else 0
	_anchors["%d:hand" % my_seat] = _hand
	_anchors["%d:hand" % opp_seat] = _opp_hand
	_anchors["%d:field" % my_seat] = _my_field
	_anchors["%d:field" % opp_seat] = _opp_field
	_anchors["%d:field_nexus" % my_seat] = _my_nexus
	_anchors["%d:field_nexus" % opp_seat] = _opp_nexus
	_anchors["-1:centre"] = _centre_panel

	_render_opp_bar(opp)
	_render_opp_hand(opp)
	_render_zone(_opp_right, opp, true, false)
	_render_zone(_opp_left, opp, false, false)
	_render_zone(_my_left, me, true, true)
	_render_zone(_my_right, me, false, true)
	_render_field(_opp_field, _only(opp.get("field", []), false), false)
	_render_field(_opp_nexus, _only(opp.get("field", []), true), false, true)
	_render_field(_my_field, _only(me.get("field", []), false), true)
	_render_field(_my_nexus, _only(me.get("field", []), true), true, true)
	_render_hand(me.get("hand", []))
	_render_centre()
	_render_log()
	_sync_arrow()
	_update_music()


## Battle music follows the game (0.7.1): the battle theme, crossfading to the
## faster pinch theme once either player is down to 2 life or less -- the
## point where one more hit can decide the game.
func _update_music() -> void:
	if _ended or bool(_snap.get("game_over", false)):
		return
	var pinch := false
	for p: Dictionary in _snap.get("players", []):
		if int(p.get("life", 0)) + int(p.get("life_soul", 0)) <= PINCH_LIFE:
			pinch = true
	AudioManager.play_music("battle_pinch" if pinch else "battle_theme", true, 1.6)


# --- Presentation API (used by BattleDirector) --------------------------------

func seat() -> int:
	return MatchService.my_seat if MatchService.my_seat >= 0 else 0


func snapshot() -> Dictionary:
	return _snap


func node_of(uid: int) -> Control:
	var w: Variant = _widgets.get(uid)
	if w is Control and is_instance_valid(w):
		return w
	return null


func rect_of(uid: int) -> Rect2:
	var n := node_of(uid)
	return BattleFX.visual_rect(n) if n != null and n.is_inside_tree() else Rect2()


func anchor(pid: int, zone: String) -> Control:
	var n: Variant = _anchors.get("%d:%s" % [pid, zone])
	if n is Control and is_instance_valid(n):
		return n
	return null


func anchor_rect(pid: int, zone: String) -> Rect2:
	var n := anchor(pid, zone)
	return BattleFX.visual_rect(n) if n != null and n.is_inside_tree() else Rect2()


func step_pill(i: int) -> Control:
	if i >= 0 and i < _step_pills.size() and is_instance_valid(_step_pills[i]):
		return _step_pills[i]
	return null


func card_id_of(uid: int) -> String:
	return _card_id_of(uid)


func card_name(uid: int) -> String:
	return _card_name(uid)


func owner_of(uid: int) -> int:
	if MatchService.engine != null:
		var ci: CardInstance = MatchService.engine.state.cards.get(uid)
		if ci != null:
			return ci.owner_id
	for p: Dictionary in _snap.get("players", []):
		for zone in ["hand", "field", "trash"]:
			for e: Dictionary in p.get(zone, []):
				if int(e.get("uid", -1)) == uid:
					return int(p.get("id", 0))
	return 0


## Fade in a card that was drawn invisible because an effect delivers it.
func reveal(uid: int) -> void:
	_hidden.erase(uid)
	var n: Variant = _vis.get(uid)
	if n is Control and is_instance_valid(n):
		(n as Control).modulate.a = 1.0


func pending_orient_uids() -> Array:
	return _pending_orient.keys()


## Turn a field card to its new orientation (exhausted = sideways).
func animate_orient(uid: int) -> void:
	if not _pending_orient.has(uid):
		return
	var exh: bool = _pending_orient[uid]
	_pending_orient.erase(uid)
	var card := node_of(uid)
	if card == null:
		return
	var holder := card.get_parent() as Control
	var sz := card.size
	var t := _fx.tw()
	t.set_parallel(true)
	t.tween_property(holder, "custom_minimum_size", Vector2(sz.y, sz.x) if exh else sz, _fx.d(0.24))
	t.tween_property(card, "rotation", PI * 0.5 if exh else 0.0, _fx.d(0.24)).set_trans(Tween.TRANS_BACK)
	t.tween_property(card, "position", (Vector2(sz.y, sz.x) - sz) * 0.5 if exh else Vector2.ZERO, _fx.d(0.24))


func _register(uid: int, w: CardWidget, vis: Control) -> void:
	if uid < 0:
		return
	_widgets[uid] = w
	_vis[uid] = vis
	if _hidden.has(uid):
		vis.modulate.a = 0.0


func _anchor_set(side: Dictionary, zone: String, n: Control) -> void:
	_anchors["%d:%s" % [int(side.get("id", 0)), zone]] = n


## The attack arrow always reflects the snapshot: attacker -> blocker, or
## attacker -> the defender's life while no block has been declared.
func _sync_arrow() -> void:
	if _fx == null:
		return
	var battle: Dictionary = _snap.get("battle", {})
	if battle.is_empty() or not _anims_on():
		_fx.arrow.clear()
		return
	var src := node_of(int(battle.get("attacker", -1)))
	var blk := node_of(int(battle.get("blocker", -1)))
	var dst: Control = blk if blk != null else anchor(int(battle.get("defending_player", 1)), "life_panel")
	if src == null or dst == null:
		_fx.arrow.clear()
		return
	_fx.arrow.point_at(src, dst, UITheme.SOUL)
	_fx.arrow.grow = 1.0


func _render_opp_bar(opp: Dictionary) -> void:
	_clear(_opp_bar)
	var opp_name := UITheme.heading(MatchService.opponent_name, UITheme.FS_HEAD - 2)
	_opp_bar.add_child(opp_name)
	_opp_bar.add_child(UITheme.body(str(opp.get("deck_name", "")), true, UITheme.FS_SMALL))
	_opp_bar.add_child(UITheme.grow())
	_opp_bar.add_child(UITheme.body("Hand %d" % (opp.get("hand", []) as Array).size(),
			true, UITheme.FS_SMALL))


func _render_opp_hand(opp: Dictionary) -> void:
	_clear(_opp_hand)
	for entry: Dictionary in opp.get("hand", []):
		var back := CardWidget.new()
		back.setup_back(MINI_CARD)
		_opp_hand.add_child(back)
		_register(int(entry.get("uid", -1)), back, back)
	_layout_opp_hand()


## Positions are computed from the strip's width, so this runs again whenever
## the strip is resized -- the first render happens before layout, at width 0,
## which piled every card into the top-left corner.
func _layout_opp_hand() -> void:
	var n := _opp_hand.get_child_count()
	if n == 0:
		return
	var w := MINI_CARD.x * 0.62
	var start := (_opp_hand.size.x - (w * (n - 1) + MINI_CARD.x)) * 0.5
	for i in n:
		var back: Control = _opp_hand.get_child(i)
		back.size = MINI_CARD
		back.position = Vector2(start + i * w, -MINI_CARD.y * 0.36)


## One side column of a mat. `life_side` is the LIFE/BURST/RESERVE column;
## otherwise it is the DECK/TRASH column.
##
## Kept deliberately short. In the first 0.6.0 layout, Deck, Trash and Core
## Trash were stacked vertically, the two mat rows needed more height than the
## window had, and the hand -- the last row -- was pushed off the bottom so only
## a sliver of each card showed. Deck and trash now sit side by side.
func _render_zone(col: VBoxContainer, side: Dictionary, life_side: bool, mine: bool) -> void:
	_clear(col)
	if life_side:
		col.add_child(_zone_header("Life", int(side.get("life", 0)) + int(side.get("life_soul", 0)),
				UITheme.SOUL))
		var life := CoreGems.new()
		life.radius = 11.0
		life.sockets = BSS.STARTING_LIFE
		life.max_drawn = 7
		life.set_counts(int(side.get("life", 0)), int(side.get("life_soul", 0)))
		col.add_child(life)
		_follow_count(col.get_child(col.get_child_count() - 2), life)
		_anchor_set(side, "life", life)
		_anchor_set(side, "life_panel", life)

		var res_head := _zone_header("Reserve",
				int(side.get("reserve", 0)) + int(side.get("reserve_soul", 0)), UITheme.CORE)
		col.add_child(res_head)
		var res := CoreGems.new()
		res.radius = 10.0
		res.max_drawn = 6
		res.set_counts(int(side.get("reserve", 0)), int(side.get("reserve_soul", 0)))
		col.add_child(res)
		_anchor_set(side, "reserve", res)
		_follow_count(res_head, res)
		if mine:
			# 0.22.0: drag a core from the reserve onto a spirit, or drop one
			# back here (the header row counts as the reserve too).
			var rloc := GameState.pool(MatchService.my_seat, BSS.Zone.RESERVE)
			_core_source(res, rloc)
			_core_target(res_head, rloc)

		var burst_row := UITheme.hbox(UITheme.SP_S)
		var bl := UITheme.eyebrow("Burst", UITheme.ACCENT)
		bl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		burst_row.add_child(bl)
		if bool(side.get("burst_set", false)):
			var bc: Variant = side.get("burst_card")
			var w := CardWidget.new()
			if mine and bc is Dictionary:
				w.setup(str((bc as Dictionary).get("card_id", "")), SLOT_CARD)
				w.hovered.connect(_preview)
			else:
				w.setup_back(SLOT_CARD)
			burst_row.add_child(w)
			_anchor_set(side, "burst", w)
			var bu: Variant = side.get("burst_card")
			if bu is Dictionary:
				_register(int((bu as Dictionary).get("uid", -1)), w, w)
		else:
			var es := _empty_slot("none")
			burst_row.add_child(es)
			_anchor_set(side, "burst", es)
		col.add_child(burst_row)
	else:
		var piles := UITheme.hbox(UITheme.SP_S)
		var deck_col := UITheme.vbox(2)
		deck_col.add_child(_zone_header("Deck", int(side.get("deck_count", 0)), UITheme.TEXT_DIM))
		var back := CardWidget.new()
		back.setup_back(SLOT_CARD)
		deck_col.add_child(back)
		_anchor_set(side, "deck", back)
		piles.add_child(deck_col)

		var trash: Array = side.get("trash", [])
		var trash_col := UITheme.vbox(2)
		trash_col.add_child(_zone_header("Trash", trash.size(), UITheme.TEXT_DIM))
		# Either trash is public: click the pile to look through it (0.16.1, R-078).
		var open_trash := func(): _open_trash(side, mine)
		if trash.is_empty():
			var es2 := _empty_slot("empty")
			es2.tooltip_text = "Trash is empty"
			trash_col.add_child(es2)
			_anchor_set(side, "trash", es2)
		else:
			var top: Dictionary = trash[trash.size() - 1]
			var tw := CardWidget.new()
			tw.setup(str(top.get("card_id", "")), SLOT_CARD)
			tw.hovered.connect(_preview)
			tw.clicked.connect(func(_id: String): open_trash.call())
			tw.tooltip_text = "%d card%s in the trash. Click to look through it" % [trash.size(), "" if trash.size() == 1 else "s"]
			trash_col.add_child(tw)
			_anchor_set(side, "trash", tw)
		trash_col.mouse_filter = Control.MOUSE_FILTER_STOP
		trash_col.gui_input.connect(func(ev: InputEvent):
			if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
				open_trash.call())
		piles.add_child(trash_col)
		col.add_child(piles)

		var cores_trash := int(side.get("trash_cores", 0)) + int(side.get("trash_soul", 0))
		col.add_child(_zone_header("Core trash", cores_trash, UITheme.TEXT_DIM))
		var ct := CoreGems.new()
		ct.radius = 7.0
		ct.max_drawn = 6
		ct.set_counts(int(side.get("trash_cores", 0)), int(side.get("trash_soul", 0)))
		col.add_child(ct)
		_follow_count(col.get_child(col.get_child_count() - 2), ct)
		_anchor_set(side, "core_trash", ct)


## "Look through the trash" (0.16.1): every card in a player's trash, newest
## first, in a scrollable grid. Hover previews a card in the inspector, click
## zooms it. Either player's trash can be opened; both are public (3-6-3).
var _trash_modal: Modal = null


func _open_trash(side: Dictionary, mine: bool) -> void:
	if _trash_modal != null and is_instance_valid(_trash_modal):
		_trash_modal.close()
	var trash: Array = side.get("trash", [])
	var who := "Your trash" if mine else "Opponent's trash"
	var m := Modal.open(self, "%s · %d card%s" % [who, trash.size(), "" if trash.size() == 1 else "s"], 760.0)
	_trash_modal = m
	if trash.is_empty():
		m.body.add_child(UITheme.paragraph("Nothing here yet. Destroyed spirits, used magic cards and discards go to the trash, newest on top.", true))
	else:
		m.body.add_child(UITheme.body("Newest first. Hover a card to read it; click to zoom.", true, UITheme.FS_SMALL))
		var scroll := ScrollContainer.new()
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		scroll.custom_minimum_size = Vector2(700, 330)
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		m.body.add_child(scroll)
		var grid := GridContainer.new()
		grid.columns = 6
		grid.add_theme_constant_override("h_separation", UITheme.SP_S)
		grid.add_theme_constant_override("v_separation", UITheme.SP_S)
		grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.add_child(grid)
		for i in range(trash.size() - 1, -1, -1):
			var entry: Dictionary = trash[i]
			var cid := str(entry.get("card_id", ""))
			var w := CardWidget.new()
			w.setup(cid, Vector2(104, 146))
			w.hovered.connect(_preview)
			w.clicked.connect(func(id: String): _zoom_card(id))
			grid.add_child(w)
		Motion.stagger_in(grid.get_children(), 0.02)
	var close := UITheme.button("Close", m.close)
	m.buttons.add_child(UITheme.grow())
	m.buttons.add_child(close)


## Full-size card from the trash viewer (0.16.1).
func _zoom_card(card_id: String) -> void:
	var z := CardZoom.new()
	add_child(z)
	z.z_index = 120
	z.open([card_id], 0, Callable())


func _zone_header(title: String, count: int, tint: Color) -> Control:
	var row := UITheme.hbox(UITheme.SP_XS)
	var t := UITheme.eyebrow(title, tint)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(t)
	if count >= 0:
		var n := UITheme.body(str(count), false, UITheme.FS_SMALL)
		if UITheme.font("bold") != null:
			n.add_theme_font_override("font", UITheme.font("bold"))
		row.add_child(n)
	return row


func _empty_slot(text: String) -> Control:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.03)
	sb.set_corner_radius_all(6)
	sb.set_border_width_all(1)
	sb.border_color = Color(1, 1, 1, 0.14)
	p.add_theme_stylebox_override("panel", sb)
	p.custom_minimum_size = SLOT_CARD
	var l := UITheme.body(text, true, UITheme.FS_TINY)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	p.add_child(l)
	return p


## The field entries that are nexuses (or that are not). 0.16.2
func _only(cards: Array, nexus: bool) -> Array:
	var out: Array = []
	for e: Dictionary in cards:
		var cd: CardData = CardDB.get_card(str(e.get("card_id", "")))
		if (cd != null and cd.is_nexus()) == nexus:
			out.append(e)
	return out


func _render_field(row: HBoxContainer, cards: Array, mine: bool, nexus_row: bool = false) -> void:
	_clear(row)
	if cards.is_empty():
		if nexus_row:
			return
		var l := UITheme.body("No spirits", true, UITheme.FS_SMALL)
		l.modulate.a = 0.5
		row.add_child(l)
		return
	var attacker := int(_snap.get("battle", {}).get("attacker", -1))
	var blocker := int(_snap.get("battle", {}).get("blocker", -1))
	var prev_orient := {}
	if _presenting:
		for p: Dictionary in _shown_snap.get("players", []):
			for pe: Dictionary in p.get("field", []):
				prev_orient[int(pe.get("uid", -1))] = int(pe.get("orient", 0)) == BSS.Orientation.EXHAUSTED
	# 0.22.0: what each card showed before this update, so its BP, level and
	# cores can move to the new numbers instead of jumping (CardWidget).
	var prev_nums := {}
	if _presenting:
		for p: Dictionary in _shown_snap.get("players", []):
			for pe: Dictionary in p.get("field", []):
				prev_nums[int(pe.get("uid", -1))] = {"bp": int(pe.get("bp", 0)),
					"level": int(pe.get("level", 0)), "cores": int(pe.get("cores", 0)) + int(pe.get("soul", 0))}
	var card_size := _field_card_size(row, cards)
	for entry0: Dictionary in cards:
		var entry := entry0
		var uid := int(entry.get("uid", -1))
		if prev_nums.has(uid):
			var pn: Dictionary = prev_nums[uid]
			if int(pn["bp"]) != int(entry.get("bp", 0)) or int(pn["level"]) != int(entry.get("level", 0)):
				entry = entry0.duplicate()
				entry["_prev"] = pn
				# the numbers change as the flying core lands, not before
				var core_moved := int(pn["cores"]) != int(entry.get("cores", 0)) + int(entry.get("soul", 0))
				# a dragged core is already in place, so its numbers move at once
				entry["_anim_delay"] = 0.05 if not _drop_pending.is_empty() else (0.45 if core_moved else 0.15)
		var w := CardWidget.new()
		w.setup(str(entry.get("card_id", "")), card_size, entry)
		w.hovered.connect(func(id: String): _preview(id, entry))
		w.clicked.connect(func(_id: String): _on_field_clicked(uid, mine))
		if uid == attacker:
			w.set_highlight(UITheme.SOUL)
		elif uid == blocker:
			w.set_highlight(UITheme.CORE)
		elif _selected_options.has(uid):
			w.set_highlight(UITheme.CORE)
		elif _is_option(uid) or (mine and _field_actions(uid).size() > 0):
			w.set_highlight(UITheme.ACCENT)
		var exhausted := int(entry.get("orient", 0)) == BSS.Orientation.EXHAUSTED
		# Drawn in its OLD orientation when it changed; the attack, block or
		# refresh beat then turns it (animate_orient).
		var shown := exhausted
		if prev_orient.has(uid) and bool(prev_orient[uid]) != exhausted:
			shown = not exhausted
			_pending_orient[uid] = exhausted
		var holder := _slot(w, shown, card_size)
		row.add_child(holder)
		_register(uid, w, holder)
		if mine and not nexus_row:
			var cloc := GameState.on_card(uid)
			_core_target(w, cloc)
			if w.core_gems() != null:
				_core_source(w.core_gems(), cloc, func() -> void: _on_field_clicked(uid, mine))


## Empty a row NOW. queue_free() alone leaves the old children attached until
## the end of the frame, and a second redraw in the same frame (a resize, an
## update arriving with it) then laid out old and new children together: the
## step tracker became 14, 21, 28 pills wide, the board grew to fit, the
## resize redrew it again -- a loop that ran Godot out of memory (R-044, found
## by the FieldFit test). remove_child() first takes them out of the layout.
func _clear(node: Node) -> void:
	for c in node.get_children():
		node.remove_child(c)
		c.queue_free()


## The largest card size (up to FIELD_CARD) at which every card on this side
## fits its field area -- exhausted cards count sideways. Never below 40%.
func _field_card_size(row: Control, cards: Array) -> Vector2:
	var area := row.get_parent() as Control
	if area == null or area.size.x <= 1.0:
		return FIELD_CARD
	var gap := float(UITheme.SP_S)
	var n := cards.size()
	var widths := 0.0
	for e: Dictionary in cards:
		var ex := int(e.get("orient", 0)) == BSS.Orientation.EXHAUSTED
		widths += FIELD_CARD.y if ex else FIELD_CARD.x
	var room := area.size.x - 12.0 - gap * maxf(0.0, n - 1)
	var sc := 1.0
	if widths > room:
		sc = room / widths
	if area.size.y > 1.0 and FIELD_CARD.y > area.size.y - 4.0:
		sc = minf(sc, (area.size.y - 4.0) / FIELD_CARD.y)
	return (FIELD_CARD * clampf(sc, 0.4, 1.0)).floor()


## The window (or a panel) changed size: redraw so the field cards are re-fit.
## Only for a real change in the field area, never in answer to our own redraw.
var _field_area_size := Vector2.ZERO


func _on_field_area_resized() -> void:
	if _snap.is_empty() or _my_field == null:
		return
	var now := (_my_field.get_parent() as Control).size
	if now.distance_to(_field_area_size) < 2.0:
		return
	_field_area_size = now
	if _presenting:
		_dirty = true
		return
	if not _render_queued:
		_render_queued = true
		_present.call_deferred()


## Wraps a card so an exhausted one can be turned sideways. The holder is a
## plain Control sized for the ROTATED card; the card inside is positioned and
## rotated by this code, so no container fights the transform.
func _slot(card: CardWidget, exhausted: bool, sz: Vector2 = FIELD_CARD) -> Control:
	var holder := Control.new()
	holder.mouse_filter = Control.MOUSE_FILTER_PASS
	holder.custom_minimum_size = Vector2(sz.y, sz.x) if exhausted else sz
	holder.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	holder.add_child(card)
	card.size = sz
	card.pivot_offset = sz * 0.5
	if exhausted:
		card.rotation = PI * 0.5
		card.position = (Vector2(sz.y, sz.x) - sz) * 0.5
	return holder


func _render_hand(cards: Array) -> void:
	_clear(_hand)
	for entry: Dictionary in cards:
		if bool(entry.get("hidden", false)):
			continue
		var uid := int(entry.get("uid", -1))
		var w := CardWidget.new()
		w.setup(str(entry.get("card_id", "")), HAND_CARD)
		w.set_meta("uid", uid)
		w.hovered.connect(func(id: String):
			_preview(id)
			_preview_reason.text = _unplayable_reason(uid) if w.unplayable else ""
			_raise(w, true))
		w.mouse_exited.connect(func(): _raise(w, false))
		w.clicked.connect(func(_id: String): _on_hand_clicked(uid))
		if _selected_options.has(uid):
			w.set_highlight(UITheme.CORE)
		elif _is_option(uid) or _hand_actions(uid).size() > 0:
			w.set_highlight(UITheme.ACCENT)
		elif MatchService.engine != null and not MatchService.is_spectator:
			# Nothing can be done with this card right now: darken it (0.8.0).
			w.set_unplayable(true)
		_hand.add_child(w)
		_register(uid, w, w)
	_layout_hand()


## Overlapping fan, centred. Positions are set here, not by a container, so a
## hovered card can lift without the layout snapping it back.
func _layout_hand() -> void:
	var n := _hand.get_child_count()
	if n == 0:
		return
	var avail := _hand.size.x
	var step := minf(HAND_CARD.x + 8.0, (avail - HAND_CARD.x) / maxf(1.0, n - 1))
	var total := step * (n - 1) + HAND_CARD.x
	var x0 := (avail - total) * 0.5
	for i in n:
		var w: Control = _hand.get_child(i)
		w.size = HAND_CARD
		w.position = Vector2(x0 + i * step, 8.0)
		w.z_index = i
		w.set_meta("base_y", 8.0)


func _raise(w: Control, up: bool) -> void:
	if not is_instance_valid(w):
		return
	w.position.y = float(w.get_meta("base_y", 8.0)) - (40.0 if up else 0.0)
	w.z_index = 100 if up else w.get_index()


# --- Centre strip -------------------------------------------------------------

func _render_centre() -> void:
	var mine := int(_snap.get("turn_player", 0)) == MatchService.my_seat
	var tn := int(_snap.get("turn_number", 0))
	if tn == 0:
		_turn_label.text = "Setup"
	else:
		_turn_label.text = "Turn %d · %s" % [tn, "YOUR TURN" if mine else "OPPONENT"]
	_turn_label.add_theme_color_override("font_color", UITheme.ACCENT if mine else UITheme.TEXT_DIM)

	_clear(_steps)
	_step_pills.clear()
	var step := int(_snap.get("step", 0))
	for i in UITheme.STEP_NAMES.size():
		var pill := _step_pill(i, i == step)
		_steps.add_child(pill)
		_step_pills.append(pill)

	_clear(_actions)
	_clear(_prompt_extra)

	if MatchService.is_spectator:
		_prompt.text = "Spectating. Both hands are hidden."
		return
	if bool(_snap.get("game_over", false)):
		_prompt.text = "The game is over."
		return

	var pc: Dictionary = _snap.get("pending_choice", {})
	if not pc.is_empty() and int(pc.get("player", -1)) == MatchService.my_seat:
		_render_choice(pc)
		return
	if not pc.is_empty():
		if str(pc.get("type", "")) == "turn_order":
			_prompt.text = "Your opponent won the coin toss and is choosing whether to go first or second…"
		else:
			_prompt.text = "Waiting for your opponent to decide…"
		return

	var battle: Dictionary = _snap.get("battle", {})
	if not battle.is_empty():
		_render_battle(battle)
		return

	if not mine:
		_prompt.text = "Your opponent is taking their turn."
		return

	match step:
		BSS.Step.MAIN:
			_prompt.text = "Main step: play cards from your hand (gold outline = playable), " \
				+ "or click a spirit to move cores. Then go to the attack step."
			_add_action("End main step  →", BSS.Action.END_MAIN, true)
		BSS.Step.ATTACK:
			_prompt.text = "Attack step: click a refreshed spirit to attack with it, " \
				+ "or end your turn."
			_add_action("End turn", BSS.Action.END_ATTACK, true)
		_:
			_prompt.text = "…"


func _step_pill(i: int, active: bool) -> Control:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	var col: Color = UITheme.STEP_COLORS[i]
	sb.bg_color = col if active else Color(col, 0.12)
	sb.set_corner_radius_all(10)
	sb.set_border_width_all(1)
	sb.border_color = Color(col, 0.9 if active else 0.4)
	sb.content_margin_left = 9
	sb.content_margin_right = 9
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	p.add_theme_stylebox_override("panel", sb)
	var l := UITheme.body(UITheme.STEP_NAMES[i], not active, UITheme.FS_TINY + 1)
	if active:
		l.add_theme_color_override("font_color", Color.WHITE)
		if UITheme.font("bold") != null:
			l.add_theme_font_override("font", UITheme.font("bold"))
	p.add_child(l)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return p


func _render_battle(battle: Dictionary) -> void:
	var phase := int(battle.get("phase", 0))
	var atk_name := _card_name(int(battle.get("attacker", -1)))
	var defending := int(battle.get("defending_player", -1)) == MatchService.my_seat
	if phase == BSS.BattlePhase.BLOCK_DECLARATION and defending:
		_prompt.text = "%s is attacking you. Click one of your refreshed spirits to block, " % atk_name \
			+ "or take the damage to your life."
		_add_action("Take the damage", BSS.Action.DECLINE_BLOCK, true)
		return
	if int(_snap.get("flash_priority", -1)) == MatchService.my_seat:
		_prompt.text = "Flash timing during the battle with %s. Use a flash effect, or pass." % atk_name
		for la: Dictionary in _legal:
			if str(la.get("verb", "")) == BSS.Action.ACTIVATE:
				_prompt.text += "  Gold-outlined spirits can use Awaken or a Flash effect: click one."
				break
		_add_action("Pass", BSS.Action.FLASH_PASS, true)
		return
	_prompt.text = "Battle: %s attacks. Waiting for your opponent…" % atk_name


## Every engine prompt type has a branch here: mulligan, option (also used by
## bursts), select_cards and discard.
func _render_choice(pc: Dictionary) -> void:
	_prompt.text = str(pc.get("prompt", "Choose"))
	match str(pc.get("type", "")):
		"turn_order":
			_prompt.text = "You won the coin toss! Look at your hand, then choose: go first, " \
				+ "or go second (the player going first does not draw on their first turn)."
			_actions.add_child(UITheme.button("Go second", func():
				_act({"verb": BSS.Action.CHOOSE_ORDER, "first": false})))
			_actions.add_child(UITheme.primary_button("Go first", func():
				_act({"verb": BSS.Action.CHOOSE_ORDER, "first": true})))
		"mulligan":
			_prompt.text = "Keep this opening hand and draw one extra card, or mulligan " \
				+ "for a fresh four?"
			_actions.add_child(UITheme.button("Mulligan", func():
				_act({"verb": BSS.Action.MULLIGAN})))
			_actions.add_child(UITheme.primary_button("Keep hand", func():
				_act({"verb": BSS.Action.KEEP_HAND})))
		"option":
			_render_revealed(pc, false)
			var labels: Array = pc.get("labels", ["Yes", "No"])
			for i in labels.size():
				var idx := i
				var b := UITheme.primary_button(str(labels[i])) if i == 0 \
						else UITheme.button(str(labels[i]))
				b.pressed.connect(func():
					_act({"verb": BSS.Action.RESOLVE_CHOICE, "choice": idx}))
				_actions.add_child(b)
		"select_cards", "discard":
			var want := int(pc.get("count", 1))
			var up_to := bool(pc.get("up_to", false))
			_prompt.text = "%s  —  click %s%d card%s (highlighted), then confirm." % [
				str(pc.get("prompt", "Choose")), "up to " if up_to else "", want,
				"" if want == 1 else "s"]
			if up_to and want == int((pc.get("revealed", []) as Array).size()) and pc.has("revealed"):
				_prompt.text = "%s  —  click any, then confirm." % str(pc.get("prompt", "Choose"))
			var revealed_ok := _render_revealed(pc, true)
			for uid in ([] if revealed_ok else pc.get("options", [])):
				var u := int(uid)
				var cid := _card_id_of(u)
				if cid == "":
					continue
				var w := CardWidget.new()
				w.setup(cid, Vector2(48, 67))
				w.hovered.connect(_preview)
				w.clicked.connect(func(_id: String): _toggle_option(u))
				if _selected_options.has(u):
					w.set_highlight(UITheme.CORE)
				_prompt_extra.add_child(w)
			var n := _selected_options.size()
			var budget := int(pc.get("cost_budget", -1))
			var confirm := UITheme.primary_button("Confirm (%d/%d)" % [n, want])
			confirm.disabled = n == 0 if up_to else n != want
			if up_to and n == 0:
				confirm.disabled = false
			if budget >= 0:
				# combined-cost selection (0.11.2): show the running total
				var spent := 0
				for su: Variant in _selected_options.keys():
					var scd: CardData = CardDB.get_card(_card_id_of(int(su)))
					if scd != null: spent += scd.cost
				confirm.text = "Confirm (cost %d of %d)" % [spent, budget]
				confirm.disabled = spent > budget
			confirm.pressed.connect(func():
				var picked: Array = _selected_options.keys()
				_selected_options.clear()
				_act({"verb": BSS.Action.RESOLVE_CHOICE, "choice": picked}))
			_actions.add_child(confirm)


## A reveal choice (0.16.1, R-079): every revealed card is shown at a
## readable size; the legal ones (gold rim) can be picked, the others are
## dimmed. Returns false when the choice carries no reveal.
func _render_revealed(pc: Dictionary, selectable: bool) -> bool:
	var rev: Array = pc.get("revealed", [])
	if rev.is_empty():
		return false
	for entry: Dictionary in rev:
		var u := int(entry.get("uid", -1))
		var cid := str(entry.get("card_id", ""))
		if cid == "":
			continue
		var legal := bool(entry.get("legal", false)) and selectable
		var w := CardWidget.new()
		w.setup(cid, Vector2(84, 118))
		w.hovered.connect(_preview)
		if legal:
			w.clicked.connect(func(_id: String): _toggle_option(u))
			w.set_highlight(UITheme.CORE if _selected_options.has(u) else UITheme.GOLD)
			w.tooltip_text = "Click to choose"
		else:
			w.modulate = Color(1, 1, 1, 0.45 if selectable else 1.0)
			w.tooltip_text = "Not a legal pick for this effect" if selectable else ""
		_prompt_extra.add_child(w)
	return true


func _add_action(label: String, verb: String, primary: bool) -> void:
	var b := UITheme.primary_button(label) if primary else UITheme.button(label)
	b.custom_minimum_size = Vector2(190, 50)
	b.pressed.connect(func(): _act({"verb": verb}))
	_actions.add_child(b)


# --- Preview and log ------------------------------------------------------------

func _preview(card_id: String, live: Dictionary = {}) -> void:
	var cd: CardData = CardDB.get_card(card_id)
	if cd == null:
		return
	if _preview_reason != null:
		_preview_reason.text = ""
	_preview_card.setup(card_id, Vector2(206, 288))
	_preview_name.text = cd.name
	var meta := "%s · cost %d" % [str(BSS.CARD_TYPE_NAMES[cd.card_type]).capitalize(), cd.cost]
	if not live.is_empty() and cd.is_spirit():
		meta += " · LV%d · BP %d · %d core%s" % [int(live.get("level", 1)), int(live.get("bp", 0)),
			int(live.get("cores", 0)) + int(live.get("soul", 0)),
			"" if int(live.get("cores", 0)) + int(live.get("soul", 0)) == 1 else "s"]
	elif not cd.levels.is_empty():
		var bits: Array = []
		for lv: Dictionary in cd.levels:
			if int(lv.get("bp", 0)) > 0:
				bits.append("LV%d %d" % [int(lv.get("level", 0)), int(lv.get("bp", 0))])
		if not bits.is_empty():
			meta += " · " + "  ".join(bits)
	_preview_meta.text = meta
	UITheme.set_card_text(_preview_text, cd.text if cd.text != "" else "No effect text.")


func _render_log() -> void:
	if MatchService.engine == null:
		return
	_clear(_log_box)
	var events: Array = MatchService.engine.state.event_log
	for e in events.slice(maxi(0, events.size() - 60)):
		var line := _describe(e)
		if line == "":
			continue
		var l := UITheme.paragraph(line, false, UITheme.FS_SMALL)
		var who := int((e.get("data", {}) as Dictionary).get("player", -1))
		if who == MatchService.my_seat:
			l.add_theme_color_override("font_color", Color("#cfe4ff"))
		elif who >= 0:
			l.add_theme_color_override("font_color", Color("#ffd2d6"))
		else:
			l.add_theme_color_override("font_color", UITheme.TEXT_DIM)
		_log_box.add_child(l)
	_scroll_log_down.call_deferred()


func _scroll_log_down() -> void:
	_log_scroll.scroll_vertical = int(_log_scroll.get_v_scroll_bar().max_value)


## Turns engine events into sentences. Events with no useful wording are
## skipped rather than printed as raw keys.
func _describe(e: Dictionary) -> String:
	var d: Dictionary = e.get("data", {})
	var pid := int(d.get("player", -1))
	var who := _who(pid)
	var you := pid == MatchService.my_seat
	match str(e.get("kind", "")):
		"turn_start": return "— Turn %d: %s —" % [int(d.get("n", 0)), _who(int(d.get("player", -1)))]
		"draw": return "%s drew %d card%s." % [who, int(d.get("n", 1)), "" if int(d.get("n", 1)) == 1 else "s"]
		"summon": return "%s summoned %s (cost %d)." % [who, _card_name(int(d.get("uid", -1))), int(d.get("cost", 0))]
		"place": return "%s placed %s." % [who, _card_name(int(d.get("uid", -1)))]
		"use_magic": return "%s used %s." % [who, _card_name(int(d.get("uid", -1)))]
		"revealed":
			# 0.16.1: the revealed cards by name, and which were taken
			var names: Array = []
			var taken_names: Array = []
			var ids: Array = d.get("card_ids", [])
			var uids: Array = d.get("uids", [])
			for k in uids.size():
				var cd: CardData = CardDB.get_card(str(ids[k])) if k < ids.size() else null
				var nm := cd.name if cd != null else _card_name(int(uids[k]))
				names.append(nm)
				if (d.get("taken", []) as Array).has(uids[k]):
					taken_names.append(nm)
			var line := "%s revealed %s." % [who, ", ".join(names)]
			if not taken_names.is_empty():
				line += " Taken: %s." % ", ".join(taken_names)
			return line
		"attack_declared": return "%s %s with %s!" % [who, "attack" if you else "attacks",
				_card_name(int(d.get("uid", -1)))]
		"block_declared": return "%s blocks." % _card_name(int(d.get("uid", -1)))
		"compare_bp": return "Battle: %d BP against %d BP." % [int(d.get("a", 0)), int(d.get("b", 0))]
		"damage": return "%s took %d damage to life." % [_who(int(d.get("player", -1))), int(d.get("n", 0))]
		"destroyed": return "%s was destroyed." % _card_name(int(d.get("uid", -1)))
		"link": return "%s linked to %s." % [_card_name(int(d.get("from", -1))), _card_name(int(d.get("to", -1)))]
		"unlinked": return "%s left the field: its link ended (11-18-4)." % _card_name(int(d.get("uid", -1)))
		"game_over": return "Game over: %s." % str(d.get("reason", ""))
		"setup": return "The game begins."
		"coin_toss": return "%s won the coin toss." % _who(int(d.get("player", -1)))
		"turn_order":
			var f := int(d.get("first", -1))
			return "%s %s first." % [_who(f), "go" if f == MatchService.my_seat else "goes"]
	return ""


func _who(pid: int) -> String:
	if pid < 0:
		return "Someone"
	return "You" if pid == MatchService.my_seat else MatchService.opponent_name


func _card_name(uid: int) -> String:
	if MatchService.engine == null or uid < 0:
		return "a spirit"
	var ci: CardInstance = MatchService.engine.state.cards.get(uid)
	return ci.data.name if ci != null and ci.data != null else "a card"


func _card_id_of(uid: int) -> String:
	if MatchService.engine != null:
		var ci: CardInstance = MatchService.engine.state.cards.get(uid)
		if ci != null and ci.data != null:
			return ci.data.id
	for side in [MatchService.my_state(), MatchService.opponent_state()]:
		for zone in ["hand", "field", "trash"]:
			for e: Dictionary in side.get(zone, []):
				if int(e.get("uid", -1)) == uid:
					return str(e.get("card_id", ""))
	return ""


# ============================================================================
# Input
# ============================================================================

# --- Dragging cores (0.22.0) ------------------------------------------------------
#
# In your own main step you can pick up a core -- from a spirit's gems or from
# the reserve -- and drop it on another of your spirits or back on the reserve.
# The drop is the same MOVE_CORE action the right-click menu sends, so the
# engine checks it as before. Taking the last core a spirit needs asks first,
# because the spirit would be destroyed. While a core is held, every place it
# can go is outlined in blue.

var _drag_targets: Array = []        # CardWidgets outlined while a core is held
var _drag_src: CoreGems = null


## True when a core may be picked up now.
func core_drag_ok() -> bool:
	return core_drag_mode() != ""


## When cores may be dragged, and how (0.22.1). Under the Saga rules you move
## cores freely only in your own main step (6-6-1-2); in any other step --
## the opponent's turn included -- a core moves between your cards only as
## an effect lets it. The one such move you choose at flash timing is
## Awaken (11-1-1: cores from your other cards onto the Awaken spirit), so:
##   "main"   your main step: reserve <-> cards, card <-> card, the soul core;
##   "awaken" a flash window where you have priority and a spirit can
##            Awaken: a core from one of your cards onto that spirit;
##   ""       no dragging now.
func core_drag_mode() -> String:
	if MatchService.is_spectator or _ended or _presenting or _intro:
		return ""
	if not (_snap.get("pending_choice", {}) as Dictionary).is_empty():
		return ""
	var eng := MatchService.engine
	if eng != null:
		if eng._main_ok(MatchService.my_seat):
			return "main"
		if eng._in_flash_window(MatchService.my_seat) and not _awaken_targets().is_empty():
			return "awaken"
		return ""
	# online (no local engine): the snapshot says whose main step it is
	if int(_snap.get("step", 0)) == BSS.Step.MAIN and int(_snap.get("turn_player", -1)) == MatchService.my_seat \
			and (_snap.get("battle", {}) as Dictionary).is_empty():
		return "main"
	return ""


## The uids of my spirits that may Awaken right now (from the legal actions).
func _awaken_targets() -> Array:
	var out: Array = []
	for a: Dictionary in _legal:
		if str(a.get("verb", "")) == BSS.Action.ACTIVATE and str(a.get("keyword", "")) == "awaken":
			out.append(int(a.get("uid", -1)))
	return out


func _loc_key(loc: Dictionary) -> String:
	return "%s:%d:%d:%d" % [str(loc.get("kind", "")), int(loc.get("player", -1)),
		int(loc.get("zone", -1)), int(loc.get("uid", -1))]


## A gem row you can pick cores up from. `click` keeps a plain click on the
## gems doing what a click on the card does.
func _core_source(gems: CoreGems, loc: Dictionary, click: Callable = Callable()) -> void:
	gems.mouse_filter = Control.MOUSE_FILTER_STOP
	gems.mouse_default_cursor_shape = Control.CURSOR_DRAG if core_drag_ok() else Control.CURSOR_POINTING_HAND
	gems.set_drag_forwarding(
		func(at: Vector2) -> Variant: return _core_drag(gems, loc, at),
		func(_at: Vector2, data: Variant) -> bool: return _core_can_drop(loc, data),
		func(_at: Vector2, data: Variant) -> void: _core_drop(loc, data))
	if click.is_valid():
		gems.gui_input.connect(func(e: InputEvent) -> void:
			if e is InputEventMouseButton and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT \
					and not (e as InputEventMouseButton).pressed and not get_viewport().gui_is_dragging():
				click.call())


## A place you can drop a core (a spirit, the reserve header).
func _core_target(node: Control, loc: Dictionary) -> void:
	node.set_drag_forwarding(Callable(),
		func(_at: Vector2, data: Variant) -> bool: return _core_can_drop(loc, data),
		func(_at: Vector2, data: Variant) -> void: _core_drop(loc, data))


func _core_drag(gems: CoreGems, loc: Dictionary, at: Vector2) -> Variant:
	var mode := core_drag_mode()
	if mode.is_empty():
		return null
	var kind := gems.gem_at(at)
	if kind.is_empty():
		return null
	var soul := kind == "soul"
	if mode == "awaken":
		# Awaken takes regular cores from your cards, never from the reserve
		if str(loc.get("kind", "")) != "card":
			return null
		if soul:
			if gems.cores <= 0:
				return null
			soul = false
	# the picked gem follows the pointer
	var holder := Control.new()
	var t := TextureRect.new()
	t.texture = CoreGems.core_texture(soul)
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.size = Vector2(30, 30)
	t.position = Vector2(-15, -15)
	holder.add_child(t)
	gems.set_drag_preview(holder)
	gems.hold(-1)
	_drag_src = gems
	_outline_targets(loc)
	AudioManager.play_sfx("ui_hover")
	return {"bss_core": true, "from": loc, "soul": soul}


func _outline_targets(from_loc: Dictionary) -> void:
	_drag_targets.clear()
	for uid: int in _widgets.keys():
		var w: CardWidget = _widgets[uid]
		if not is_instance_valid(w) or w.live.is_empty():
			continue
		var loc := GameState.on_card(uid)
		if _loc_key(loc) == _loc_key(from_loc) or not _core_can_drop(loc, {"bss_core": true, "from": from_loc}):
			continue
		w.set_highlight(UITheme.CORE)
		_drag_targets.append(w)


func _core_can_drop(to_loc: Dictionary, data: Variant) -> bool:
	if not (data is Dictionary) or not bool((data as Dictionary).get("bss_core", false)):
		return false
	var from_loc: Dictionary = (data as Dictionary).get("from", {})
	if _loc_key(from_loc) == _loc_key(to_loc):
		return false
	if core_drag_mode() == "awaken":
		return str(from_loc.get("kind", "")) == "card" and str(to_loc.get("kind", "")) == "card" \
			and int(to_loc.get("uid", -1)) in _awaken_targets() and not bool((data as Dictionary).get("soul", false))
	if str(to_loc.get("kind", "")) == "card":
		var uid := int(to_loc.get("uid", -1))
		if not _widgets.has(uid):
			return false
		for e: Dictionary in MatchService.my_state().get("field", []):
			if int(e.get("uid", -1)) == uid:
				var cd: CardData = CardDB.get_card(str(e.get("card_id", "")))
				return cd != null and (cd.is_spirit() or cd.is_nexus())
		return false
	return int(to_loc.get("zone", -1)) == BSS.Zone.RESERVE


func _core_drop(to_loc: Dictionary, data: Variant) -> void:
	if not _core_can_drop(to_loc, data):
		return
	var d: Dictionary = data
	var from_loc: Dictionary = d.get("from", {})
	var a := {"verb": BSS.Action.MOVE_CORE, "from": from_loc, "to": to_loc, "n": 1, "soul": bool(d.get("soul", false))}
	if core_drag_mode() == "awaken":
		# the drop IS the Awaken: one core from that card onto this spirit
		a = {"verb": BSS.Action.ACTIVATE, "uid": int(to_loc.get("uid", -1)), "keyword": "awaken",
			"sources": [{"uid": int(from_loc.get("uid", -1)), "n": 1}]}
	_end_core_drag()
	if str(from_loc.get("kind", "")) == "card":
		var uid := int(from_loc.get("uid", -1))
		for e: Dictionary in MatchService.my_state().get("field", []):
			if int(e.get("uid", -1)) != uid:
				continue
			var cd: CardData = CardDB.get_card(str(e.get("card_id", "")))
			var left := int(e.get("cores", 0)) + int(e.get("soul", 0)) - 1
			if cd != null and cd.is_spirit() and left < cd.min_level_cost():
				Modal.confirm(self, "Remove this core?",
					"%s needs %d core%s to stay on the field. Taking this one destroys it." % [
						cd.name, cd.min_level_cost(), "" if cd.min_level_cost() == 1 else "s"],
					func() -> void:
						_drop_move = {"from": _loc_key(from_loc), "to": _loc_key(to_loc)}
						_act(a)
						_drop_move = {},
					"Remove core", true)
				return
	AudioManager.play_sfx("ui_click")
	_drop_move = {"from": _loc_key(from_loc), "to": _loc_key(to_loc)}
	_act(a)
	_drop_move = {}


## The core move the player just made by dragging ({from, to} location
## keys). That core is already where it was dropped, so the director shows it
## there (a pop) instead of flying it (0.22.1).
var _drop_move := {}
var _drop_pending := {}


## True (once) for the core event that is the player's own drag.
func is_dragged_move(dd: Dictionary, consume: bool = true) -> bool:
	if _drop_pending.is_empty():
		return false
	if _loc_key(dd.get("from", {})) != str(_drop_pending.get("from", "")) \
			or _loc_key(dd.get("to", {})) != str(_drop_pending.get("to", "")):
		return false
	if consume:
		_drop_pending = {}
	return true


func _end_core_drag() -> void:
	for w in _drag_targets:
		if is_instance_valid(w):
			(w as CardWidget).set_highlight(Color(0, 0, 0, 0))
	_drag_targets.clear()
	if _drag_src != null and is_instance_valid(_drag_src):
		_drag_src.hold(0)
	_drag_src = null


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END and _drag_src != null:
		_end_core_drag()
		# put back the outlines the board normally shows (playable, attacker...)
		if not _presenting and not _render_queued:
			_render()


## A zone header's count follows its gem row while an animation steps it.
func _follow_count(header: Control, gems: CoreGems) -> void:
	if header == null or header.get_child_count() < 2:
		return
	var lab := header.get_child(header.get_child_count() - 1) as Label
	if lab == null:
		return
	gems.shown_changed.connect(func(n: int) -> void:
		if is_instance_valid(lab):
			lab.text = str(n))


func _act(action: Dictionary) -> void:
	_toast.text = ""
	MatchService.act(action)


func _is_option(uid: int) -> bool:
	var pc: Dictionary = _snap.get("pending_choice", {})
	if pc.is_empty() or int(pc.get("player", -1)) != MatchService.my_seat:
		return false
	return uid in pc.get("options", [])


func _toggle_option(uid: int) -> void:
	if _selected_options.has(uid):
		_selected_options.erase(uid)
	else:
		_selected_options[uid] = true
	_on_update(_snap)


## Legal actions for one hand card, from the engine. Online games have no local
## engine, so they fall back to the card's type and let the server decide.
func _hand_actions(uid: int) -> Array:
	var out: Array = []
	if MatchService.engine == null:
		return out
	for a: Dictionary in _legal:
		if int(a.get("uid", -2)) == uid:
			out.append(a)
	return out


func _field_actions(uid: int) -> Array:
	var out: Array = []
	for a: Dictionary in _legal:
		var v := str(a.get("verb", ""))
		# 0.16.6 (R-082): Awaken and a card's activated effects ("Flash: ...")
		# are offered when you click the card, in the main step and at flash
		# timing. Before, the board only ever offered attack and block.
		if int(a.get("uid", -2)) == uid and v in [BSS.Action.DECLARE_ATTACK, BSS.Action.DECLARE_BLOCK,
				BSS.Action.ACTIVATE]:
			out.append(a)
	return out


func _on_hand_clicked(uid: int) -> void:
	if _is_option(uid):
		_toggle_option(uid)
		return
	var acts := _hand_actions(uid)
	if MatchService.engine == null:
		acts = _guess_hand_actions(uid)
	if acts.is_empty():
		_toast.text = "That card cannot be played right now."
		AudioManager.play_sfx("error")
		return
	_open_menu(acts)


func _on_field_clicked(uid: int, mine: bool) -> void:
	if _is_option(uid):
		_toggle_option(uid)
		return
	if not mine:
		return
	var acts := _field_actions(uid)
	# Core moves are always available in your own main step.
	if int(_snap.get("step", 0)) == BSS.Step.MAIN \
			and int(_snap.get("turn_player", 0)) == MatchService.my_seat \
			and (_snap.get("battle", {}) as Dictionary).is_empty():
		acts.append({"verb": BSS.Action.MOVE_CORE, "uid": uid, "dir": "on"})
		acts.append({"verb": BSS.Action.MOVE_CORE, "uid": uid, "dir": "off"})
		# The soul core itself (0.13.0): where it sits matters to some
		# effects, so it can be placed and taken back on purpose.
		if int(MatchService.my_state().get("reserve_soul", 0)) > 0:
			acts.append({"verb": BSS.Action.MOVE_CORE, "uid": uid, "dir": "soul_on"})
		if _soul_on_card(uid) > 0:
			acts.append({"verb": BSS.Action.MOVE_CORE, "uid": uid, "dir": "soul_off"})
	if acts.is_empty():
		return
	# A single obvious action (attack, block) happens on click; a menu only
	# appears when there is a real choice.
	if acts.size() == 1 and str(acts[0].get("verb", "")) != BSS.Action.ACTIVATE:
		_do(acts[0])
		return
	_open_menu(acts)


## Soul cores on one of my field cards, from the engine or the snapshot.
func _soul_on_card(uid: int) -> int:
	if MatchService.engine != null:
		var ci: CardInstance = MatchService.engine.state.cards.get(uid)
		return ci.soul_cores if ci != null else 0
	for e: Dictionary in MatchService.my_state().get("field", []):
		if int(e.get("uid", -1)) == uid:
			return int(e.get("soul", 0))
	return 0


func _guess_hand_actions(uid: int) -> Array:
	var cid := _card_id_of(uid)
	var cd: CardData = CardDB.get_card(cid)
	if cd == null:
		return []
	if cd.is_nexus():
		return [{"verb": BSS.Action.PLACE, "uid": uid}]
	if cd.is_magic():
		return [{"verb": BSS.Action.USE_MAGIC, "uid": uid, "effect": 0}]
	return [{"verb": BSS.Action.SUMMON, "uid": uid}]


func _open_menu(acts: Array) -> void:
	_menu.clear()
	_menu_actions = acts
	for i in acts.size():
		_menu.add_item(_label_for(acts[i]), i)
	_menu.reset_size()
	_menu.position = Vector2i(get_global_mouse_position()) + Vector2i(8, -_menu.size.y - 8)
	_menu.popup()


func _on_menu(id: int) -> void:
	if id >= 0 and id < _menu_actions.size():
		_do(_menu_actions[id])


func _do(a: Dictionary) -> void:
	var verb := str(a.get("verb", ""))
	if verb == BSS.Action.MOVE_CORE and a.has("from") and a.has("to"):
		_act(a)                       # a fully specified move (the AI's, 0.11.0)
		return
	if verb == BSS.Action.MOVE_CORE:
		var uid := int(a.get("uid", -1))
		var on_card := GameState.on_card(uid)
		var reserve := GameState.pool(MatchService.my_seat, BSS.Zone.RESERVE)
		match str(a.get("dir", "")):
			"on": _act({"verb": verb, "from": reserve, "to": on_card, "n": 1})
			"soul_on": _act({"verb": verb, "from": reserve, "to": on_card, "n": 1, "soul": true})
			"soul_off": _act({"verb": verb, "from": on_card, "to": reserve, "n": 1, "soul": true})
			_: _act({"verb": verb, "from": on_card, "to": reserve, "n": 1})
		return
	if verb in [BSS.Action.SUMMON, BSS.Action.PLACE, BSS.Action.USE_MAGIC] and _reserve_short(a) > 0:
		_open_payment(a)              # pay from your field's cores (0.16.6)
		return
	if verb == BSS.Action.DECLARE_ATTACK and GameConfig.confirm_attacks:
		Modal.confirm(self, "Attack?", "Attack with %s?" % _card_name(int(a.get("uid", -1))),
			func(): _act(a), "Attack")
		return
	_act(a)


# --- Paying with field cores (0.16.6) ------------------------------------------

## Cores the play needs: the cost, plus a spirit's LV1 cores (they go on it
## when it arrives).
func _cores_needed(a: Dictionary) -> int:
	var eng := MatchService.engine
	if eng == null:
		return 0
	var ci: CardInstance = eng.state.cards.get(int(a.get("uid", -1)))
	if ci == null or ci.data == null:
		return 0
	var n := eng.compute_cost(MatchService.my_seat, ci.data)
	if str(a.get("verb", "")) != BSS.Action.USE_MAGIC:
		n += ci.data.min_level_cost()
	return n


## How many cores the reserve is short for this play (0 = the reserve covers
## it, or the field cannot make up the difference either, or the play may only
## use the reserve -- Swift in a battle).
func _reserve_short(a: Dictionary) -> int:
	var eng := MatchService.engine
	if eng == null:
		return 0
	var p := eng.state.player(MatchService.my_seat)
	var need := _cores_needed(a)
	var short := need - (p.reserve_cores + p.reserve_soul)
	if short <= 0:
		return 0
	if str(a.get("verb", "")) == BSS.Action.SUMMON and not eng.state.battle.is_empty():
		return 0                      # 11-9-1 Swift pays from the reserve only
	var field := 0
	for uid in p.field:
		field += (eng.state.cards[uid] as CardInstance).total_cores()
	return short if field >= short else 0


var _pay_rows: Array = []          # [{loc, max, n, label, value, warn, ci}]
var _pay_modal: Modal = null


func _open_payment(a: Dictionary) -> void:
	var eng := MatchService.engine
	var my := MatchService.my_seat
	var p := eng.state.player(my)
	var need := _cores_needed(a)
	var ci: CardInstance = eng.state.cards.get(int(a.get("uid", -1)))
	_pay_rows = []
	var reserve_n := p.reserve_cores + p.reserve_soul
	_pay_rows.append({"loc": GameState.pool(my, BSS.Zone.RESERVE), "max": reserve_n, "n": reserve_n,
			"name": "Reserve", "ci": null})
	var left := need - reserve_n
	var cards: Array = []
	for uid in p.field:
		cards.append(eng.state.cards[uid])
	for c: CardInstance in cards:
		var spare := maxi(0, c.total_cores() - c.data.min_level_cost())
		var take := mini(spare, maxi(0, left))
		left -= take
		_pay_rows.append({"loc": GameState.on_card(c.uid), "max": c.total_cores(), "n": take,
				"name": c.data.name, "ci": c})
	var m := Modal.open(self, "Pay with cores from your field", 640.0)
	_pay_modal = m
	var what := "%s needs %d core%s" % [ci.data.name if ci != null else "This card", need, "" if need == 1 else "s"]
	if str(a.get("verb", "")) == BSS.Action.SUMMON and ci != null:
		what += " (cost %d + %d for LV1)" % [need - ci.data.min_level_cost(), ci.data.min_level_cost()]
	m.body.add_child(UITheme.paragraph("%s, and your reserve has %d. Choose which of your cards the other cores come from." % [what, reserve_n], true))
	var list := UITheme.vbox(UITheme.SP_XS)
	m.body.add_child(list)
	var total_label := UITheme.body("", false)
	var confirm := UITheme.primary_button("Confirm")
	var refresh := func() -> void:
		var sum := 0
		for r: Dictionary in _pay_rows:
			sum += int(r["n"])
			(r["value"] as Label).text = "%d / %d" % [int(r["n"]), int(r["max"])]
			var rc: CardInstance = r["ci"]
			var w: Label = r["warn"]
			w.text = ""
			if rc != null and int(r["n"]) > 0:
				var after := rc.total_cores() - int(r["n"])
				if after < rc.data.min_level_cost():
					w.text = "will be destroyed"
					w.add_theme_color_override("font_color", UITheme.BAD)
				elif rc.data.level_for_cores(after) < rc.current_level():
					w.text = "drops to LV%d" % rc.data.level_for_cores(after)
					w.add_theme_color_override("font_color", UITheme.WARN)
		total_label.text = "Chosen %d of %d" % [sum, need]
		confirm.disabled = sum != need
	for r: Dictionary in _pay_rows:
		var row := UITheme.hbox(UITheme.SP_S)
		var nm := UITheme.truncating(str(r["name"]), false)
		nm.custom_minimum_size = Vector2(230, 0)
		row.add_child(nm)
		var warn := UITheme.body("", true, UITheme.FS_SMALL)
		warn.custom_minimum_size = Vector2(140, 0)
		r["warn"] = warn
		var minus := UITheme.button("−")
		minus.custom_minimum_size = Vector2(40, 34)
		var val := UITheme.body("", false)
		val.custom_minimum_size = Vector2(70, 0)
		val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		r["value"] = val
		var plus := UITheme.button("+")
		plus.custom_minimum_size = Vector2(40, 34)
		var rr: Dictionary = r
		minus.pressed.connect(func():
			rr["n"] = maxi(0, int(rr["n"]) - 1)
			refresh.call())
		plus.pressed.connect(func():
			rr["n"] = mini(int(rr["max"]), int(rr["n"]) + 1)
			refresh.call())
		row.add_child(minus)
		row.add_child(val)
		row.add_child(plus)
		row.add_child(warn)
		list.add_child(row)
	m.body.add_child(total_label)
	var cancel := UITheme.button("Cancel", m.close)
	confirm.pressed.connect(func():
		var act := _with_payment(a, need)
		m.close()
		_act(act))
	m.buttons.add_child(total_label.duplicate() if false else UITheme.grow())
	m.buttons.add_child(cancel)
	m.buttons.add_child(confirm)
	refresh.call()


## The play with the chosen cores: the first `cost` pay the cost, the rest go
## onto the new spirit as its LV1 cores ("lv1_from").
func _with_payment(a: Dictionary, need: int) -> Dictionary:
	var act := a.duplicate(true)
	var ci: CardInstance = MatchService.engine.state.cards.get(int(a.get("uid", -1)))
	var lv1 := ci.data.min_level_cost() if ci != null and str(a.get("verb", "")) != BSS.Action.USE_MAGIC else 0
	var cost_left := need - lv1
	var pay: Array = []
	var lv1_from: Array = []
	for r: Dictionary in _pay_rows:
		var n := int(r["n"])
		if n <= 0:
			continue
		var to_cost := mini(n, cost_left)
		if to_cost > 0:
			var l1: Dictionary = (r["loc"] as Dictionary).duplicate()
			l1["n"] = to_cost
			pay.append(l1)
			cost_left -= to_cost
		if n - to_cost > 0:
			var l2: Dictionary = (r["loc"] as Dictionary).duplicate()
			l2["n"] = n - to_cost
			lv1_from.append(l2)
	act["payment"] = pay
	if not lv1_from.is_empty():
		act["lv1_from"] = lv1_from
	return act


func _label_for(a: Dictionary) -> String:
	var uid := int(a.get("uid", -1))
	var cost := -1
	if MatchService.engine != null and uid >= 0:
		var ci: CardInstance = MatchService.engine.state.cards.get(uid)
		if ci != null:
			cost = MatchService.engine.compute_cost(MatchService.my_seat, ci.data)
	var cost_txt := (" (cost %d)" % cost) if cost >= 0 else ""
	match str(a.get("verb", "")):
		BSS.Action.SUMMON:
			if _summon_would_die(uid, cost):
				return "Summon%s — no core left for it, it would be destroyed" % cost_txt
			return "Summon%s" % cost_txt
		BSS.Action.PLACE: return "Place nexus%s" % cost_txt
		BSS.Action.USE_MAGIC:
			# Two-effect magic offers each effect separately (0.9.0): say which.
			var eff_txt := ""
			if MatchService.engine != null and uid >= 0:
				var mc: CardInstance = MatchService.engine.state.cards.get(uid)
				var idx := int(a.get("effect", 0))
				if mc != null and mc.data != null and idx < mc.data.effects.size():
					var e: Dictionary = mc.data.effects[idx]
					var t := str(e.get("text", ""))
					eff_txt = " \u2014 %s: %s" % [str(e.get("header", "Use")),
							t if t.length() <= 60 else t.left(58) + "\u2026"]
			return "Use magic%s%s" % [cost_txt, eff_txt]
		BSS.Action.SET_BURST: return "Set as burst"
		BSS.Action.DECLARE_ATTACK: return "Attack"
		BSS.Action.DECLARE_BLOCK: return "Block"
		BSS.Action.MOVE_CORE:
			match str(a.get("dir", "")):
				"on": return "Add a core from reserve"
				"soul_on": return "Move the soul core here"
				"soul_off": return "Return the soul core to reserve"
			return "Return a core to reserve"
		BSS.Action.ACTIVATE:
			if a.has("effect") and not a.has("keyword"):
				# an activated effect of a card on the field (0.15.0)
				var ac: CardInstance = MatchService.engine.state.card(int(a.get("uid", -1))) if MatchService.engine else null
				if ac != null:
					var sp: Array = ac.active_effects()
					var ei := int(a.get("effect", 0))
					if ei < sp.size():
						var at := str((sp[ei] as Dictionary).get("text", "its effect"))
						return "Use: %s" % (at if at.length() <= 60 else at.left(58) + "\u2026")
				return "Use its effect"
			if str(a.get("keyword", "")) == "awaken":
				var n := 0
				for src: Dictionary in a.get("sources", []):
					n += int(src.get("n", 0))
				return "Awaken (+%d core%s from your other spirits)" % [n, "" if n == 1 else "s"]
	return str(a.get("verb", "?")).capitalize()


## Why a darkened hand card cannot be played, in one line for the preview.
func _unplayable_reason(uid: int) -> String:
	var eng := MatchService.engine
	if eng == null:
		return ""
	var st := eng.state
	var me := MatchService.my_seat
	var ci: CardInstance = st.cards.get(uid)
	if ci == null or ci.data == null:
		return ""
	if not st.pending_choice.is_empty():
		return "Can't play now: a choice has to be made first."
	var in_flash := eng._in_flash_window(me)
	if st.turn_player != me and not in_flash:
		return "Can't play now: it's your opponent's turn."
	if in_flash:
		return "Can't play now: only flash effects can be used during a battle."
	if st.step != BSS.Step.MAIN:
		return "Can't play now: cards are played in your main step."
	var cost := eng.compute_cost(me, ci.data)
	var p := st.player(me)
	var avail := p.reserve_cores + p.reserve_soul
	for f in p.field:
		avail += (st.cards[f] as CardInstance).cores
	if avail < cost:
		return "Can't play now: costs %d after reductions, you have %d core%s." % [
			cost, avail, "" if avail == 1 else "s"]
	if ci.data.is_magic():
		return "Can't play now: this magic can only be used at flash timing."
	return "Can't be played right now."


## A spirit needs at least its LV1 core cost on it the moment it arrives, or the
## rules destroy it immediately. Summoning it anyway is legal, so the option is
## still offered -- but labelled, because nobody does it on purpose.
func _summon_would_die(uid: int, cost: int) -> bool:
	if MatchService.engine == null or uid < 0 or cost < 0:
		return false
	var ci: CardInstance = MatchService.engine.state.cards.get(uid)
	if ci == null or ci.data == null:
		return false
	var p := MatchService.engine.state.player(MatchService.my_seat)
	return p.reserve_cores + p.reserve_soul - cost < ci.data.min_level_cost()


func _on_rejected(reason: String) -> void:
	AudioManager.play_sfx("error")
	_toast.text = "Not allowed: %s" % reason


## The engine reports the end of the game during the action that ended it --
## before the board has even received that update. The dialog waits until the
## final presentation (the last hit, VICTORY/DEFEAT) has played.
func _on_ended(data: Dictionary) -> void:
	if _ended:
		return
	_pending_end = data
	_maybe_show_end.call_deferred()


func _maybe_show_end() -> void:
	if _presenting or _render_queued or _ended:
		return
	_show_end(_pending_end)


func _show_end(data: Dictionary) -> void:
	if _ended:
		return
	_ended = true
	_pending_end = {}
	var result := str(data.get("result", ""))
	AudioManager.play_music("victory" if result == "win" else "defeat", false, 0.4)
	var title := "Victory" if result == "win" else ("Defeat" if result == "loss" else "Draw")
	var line := "You won the game." if result == "win" else (
		"Your opponent won the game." if result == "loss" else "The game ended in a draw.")
	# Online results that are neither a win nor a loss (0.16.8).
	var reason := str(data.get("reason", ""))
	if result == "disconnected":
		title = "Disconnected"
		line = reason if reason != "" else "The connection to the server was lost."
	elif result == "spectated":
		var w := int(data.get("winner", -1))
		var names: Array = []
		for p: Dictionary in MatchService.snapshot.get("players", []):
			names.append(str(p.get("name", "Player")))
		title = "Game over"
		line = ("%s won the game." % names[w]) if w >= 0 and w < names.size() else "The game ended in a draw."
	elif result == "win" and reason == "opponent disconnected":
		line = "Your opponent left the game, so you win."
	elif result == "win" and reason == "concession":
		line = "Your opponent conceded."
	var m := Modal.open(self, title, 520.0)
	m.body.add_child(UITheme.paragraph(line, true))
	if MatchService.engine != null:
		var st := MatchService.engine.state
		m.body.add_child(UITheme.body("Turns played: %d" % st.turn_number, true, UITheme.FS_SMALL))
	m.buttons.add_child(UITheme.grow())
	m.buttons.add_child(UITheme.button("Main menu", func():
		MatchService.end_match()
		SceneRouter.go("main")))
	var again := UITheme.primary_button("Back to Battle", func():
		MatchService.end_match()
		SceneRouter.go("battle_menu"))
	m.buttons.add_child(again)


func _confirm_concede() -> void:
	Modal.confirm(self, "Concede?", "This ends the game as a loss.", func():
		MatchService.act({"verb": BSS.Action.CONCEDE}), "Concede", true)
