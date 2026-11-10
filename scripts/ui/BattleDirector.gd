extends Node
class_name BattleDirector
##
## Decides what the player SEES for each thing that happened in the game.
##
## Input: the engine events since the last presentation (GameState.event_log),
## where every card was on screen BEFORE the board re-rendered (`before`), and
## the previous snapshot. Output: a sequence of effects on BattleFX, played in
## the same order the rules resolved them.
##
## The board has already been redrawn in its NEW state when this runs; cards
## that are arriving (drawn, summoned, set as burst) are drawn invisible and
## revealed by the effect that delivers them. Cards that LEFT (destroyed,
## used magic) no longer exist on the board, so their effect plays on a ghost
## copy placed where the card used to be. This "render first, then animate the
## difference" order means the board is always correct even if an effect is
## skipped, sped up or fails -- the last step of every presentation reveals
## everything regardless.
##
## Beats (each mirrors a moment of the rules, see rules manual sections):
##   setup ............ BATTLE START banner, opening hands dealt
##   turn_start ....... YOUR TURN / OPPONENT'S TURN banner (6-1)
##   step ............. a band naming each step as it happens (6-2 .. 6-8)
##   draw ............. card flies from deck to hand, turns face up if yours
##   summon/place ..... card rises to centre stage, name and SUMMON / NEXUS,
##                      slams into its field slot with a shockwave (10-6, 10-7)
##   magic ............ card shown at centre with MAGIC, then fades (10-8)
##   cores ............ gems fly between reserve, cards, trash and life
##   attack ........... attacker turns sideways, ATTACK!, an arrow draws from
##                      it to the defender's LIFE: the attack's target (7-1-1)
##   block ............ BLOCK!, the arrow swings onto the blocking spirit (7-1-3)
##   BP clash ......... both spirits face off at centre, BP counts up, impact,
##                      the loser shatters (7-1-5-2)
##   damage ........... the hit lands on life: shake, red flash, -N LIFE, the
##                      life cores fly to the reserve (7-1-5-3)
##   destroyed ........ card blanches and breaks into shards (10-1)
##   burst ............ face-down burst flips at centre with BURST! (10-9)
##   refresh .......... exhausted spirits turn back upright (6-5)
##   game_over ........ VICTORY / DEFEAT banner
##

var board: GameBoard
var fx: BattleFX

var _before: Dictionary = {}
var _prev: Dictionary = {}
var _claimed: Dictionary = {}       # event index -> true, already shown by another beat
var _entered: Dictionary = {}       # uid -> true, arrival already shown
var _atk := -1
var _blk := -1


func _init(p_board: GameBoard = null, p_fx: BattleFX = null) -> void:
	board = p_board
	fx = p_fx


# ===========================================================================
# Entry points
# ===========================================================================

## Cards the board should draw INVISIBLE because an effect will deliver them.
static func incoming_uids(events: Array) -> Dictionary:
	var out := {}
	for e: Dictionary in events:
		var dd: Dictionary = e.get("data", {})
		match str(e.get("kind", "")):
			"move":
				var to := int(dd.get("to", -1))
				if to == BSS.Zone.HAND or to == BSS.Zone.FIELD or to == BSS.Zone.BURST:
					out[int(dd.get("uid", -1))] = true
			"token_summoned":
				out[int(dd.get("uid", -1))] = true
	return out


func play(events: Array, before: Dictionary, prev: Dictionary) -> void:
	_before = before
	_prev = prev
	_claimed = {}
	_entered = {}
	var pb: Dictionary = prev.get("battle", {})
	_atk = int(pb.get("attacker", -1))
	_blk = int(pb.get("blocker", -1))
	_claim_damage_cores(events)
	_hold_cores(events)
	# The engine logs "setup" AFTER dealing the opening hands, which played the
	# deal first and the BATTLE START banner second. The banner opens the game.
	for k in events.size():
		if str((events[k] as Dictionary).get("kind", "")) == "setup":
			_claimed[k] = true
			await _beat(events, k)
			break
	# 0.20.0: the coin toss comes before the deal, as at the table
	for k2 in events.size():
		if str((events[k2] as Dictionary).get("kind", "")) == "coin_toss":
			_claimed[k2] = true
			await _beat(events, k2)
			break
	for i in events.size():
		if _claimed.has(i):
			continue
		await _beat(events, i)
	await _level_pass()
	_release_cores()


## Online games have no local engine and so no event log. This rebuilds the
## main events from the difference between two snapshots, so a network match
## still shows draws, summons, attacks, blocks, clashes, destruction and life
## damage -- in a sensible order, if not with every core movement.
static func synthesize(prev: Dictionary, now: Dictionary, _seat: int) -> Array:
	var out: Array = []
	if prev.is_empty() or now.is_empty():
		return out
	var add := func(kind: String, data: Dictionary) -> void:
		out.append({"t": -1, "kind": kind, "data": data})
	if int(now.get("turn_number", 0)) > int(prev.get("turn_number", 0)):
		add.call("turn_start", {"player": int(now.get("turn_player", 0)), "n": int(now.get("turn_number", 0))})
	if int(now.get("step", 0)) != int(prev.get("step", 0)):
		add.call("step", {"step": int(now.get("step", 0)), "player": int(now.get("turn_player", 0))})
	var pplayers: Array = prev.get("players", [])
	var nplayers: Array = now.get("players", [])
	if pplayers.size() < 2 or nplayers.size() < 2:
		return out
	for pid in 2:
		var ph := _uids((pplayers[pid] as Dictionary).get("hand", []))
		var nh := _uids((nplayers[pid] as Dictionary).get("hand", []))
		var pf := _uids((pplayers[pid] as Dictionary).get("field", []))
		for uid: int in nh:
			if not ph.has(uid) and not pf.has(uid):
				add.call("move", {"uid": uid, "from": BSS.Zone.DECK, "to": BSS.Zone.HAND, "owner": pid})
	var pb: Dictionary = prev.get("battle", {})
	var nb: Dictionary = now.get("battle", {})
	for pid in 2:
		var pf := _uids((pplayers[pid] as Dictionary).get("field", []))
		for entry: Dictionary in (nplayers[pid] as Dictionary).get("field", []):
			var uid := int(entry.get("uid", -1))
			if pf.has(uid):
				continue
			add.call("move", {"uid": uid, "from": BSS.Zone.HAND, "to": BSS.Zone.FIELD, "owner": pid})
			var cd: CardData = CardDB.get_card(str(entry.get("card_id", "")))
			add.call("place" if cd != null and cd.is_nexus() else "summon", {"player": pid, "uid": uid})
	if int(nb.get("attacker", -1)) >= 0 and int(nb.get("attacker", -1)) != int(pb.get("attacker", -1)):
		add.call("attack_declared", {"uid": int(nb["attacker"]), "player": int(nb.get("attacking_player", 0))})
	if int(nb.get("blocker", -1)) >= 0 and int(nb.get("blocker", -1)) != int(pb.get("blocker", -1)):
		add.call("block_declared", {"uid": int(nb["blocker"])})
	if nb.is_empty() and int(pb.get("blocker", -1)) >= 0:
		var a := _bp_in(pplayers, int(pb.get("attacker", -1)))
		var b := _bp_in(pplayers, int(pb.get("blocker", -1)))
		if a >= 0 and b >= 0:
			add.call("compare_bp", {"a": a, "b": b})
	for pid in 2:
		var nf := _uids((nplayers[pid] as Dictionary).get("field", []))
		for entry: Dictionary in (pplayers[pid] as Dictionary).get("field", []):
			var uid := int(entry.get("uid", -1))
			if not nf.has(uid):
				add.call("destroyed", {"uid": uid})
		var lost := (int((pplayers[pid] as Dictionary).get("life", 0)) + int((pplayers[pid] as Dictionary).get("life_soul", 0))) \
			- (int((nplayers[pid] as Dictionary).get("life", 0)) + int((nplayers[pid] as Dictionary).get("life_soul", 0)))
		if lost > 0:
			add.call("damage", {"player": pid, "n": lost})
	if bool(now.get("game_over", false)) and not bool(prev.get("game_over", false)):
		add.call("game_over", {"winner": int(now.get("winner", -1))})
	return out


static func _uids(entries: Array) -> Dictionary:
	var d := {}
	for e: Dictionary in entries:
		d[int(e.get("uid", -1))] = true
	return d


static func _bp_in(players: Array, uid: int) -> int:
	for p: Dictionary in players:
		for e: Dictionary in p.get("field", []):
			if int(e.get("uid", -1)) == uid:
				return int(e.get("bp", 0))
	return -1


# ===========================================================================
# Dispatch
# ===========================================================================

func _beat(events: Array, i: int) -> void:
	var e: Dictionary = events[i]
	var dd: Dictionary = e.get("data", {})
	match str(e.get("kind", "")):
		"setup":
			await fx.banner("BATTLE START", "%s   VS   %s" % [GameConfig.player_name, MatchService.opponent_name],
					UITheme.ACCENT, 0.45)
		"coin_toss":
			# 0.20.0: who won the toss (and will choose the turn order)
			var won := int(dd.get("player", -1)) == board.seat()
			await fx.banner("COIN TOSS", "YOU WIN THE TOSS" if won else "%s WINS THE TOSS" % MatchService.opponent_name.to_upper(),
					UITheme.ACCENT if won else UITheme.SOUL, 0.55)
		"turn_order":
			var me_first := int(dd.get("first", -1)) == board.seat()
			await fx.banner("YOU GO FIRST" if me_first else "YOU GO SECOND",
					"%s CHOSE" % ("YOU" if int(dd.get("player", -1)) == board.seat() else MatchService.opponent_name.to_upper()),
					UITheme.ACCENT if me_first else UITheme.SOUL, 0.5)
		"turn_start":
			var mine := int(dd.get("player", -1)) == board.seat()
			AudioManager.play_sfx("turn")
			await fx.banner("YOUR TURN" if mine else "OPPONENT'S TURN", "TURN %d" % int(dd.get("n", 0)),
					UITheme.ACCENT if mine else UITheme.SOUL, 0.5)
		"step":
			await _step(dd)
		"move":
			await _move(events, i)
		"summon", "place", "token_summoned":
			var uid := int(dd.get("uid", -1))
			if not _entered.has(uid):
				await _enter(uid, str(e.get("kind", "")), int(dd.get("player", board.owner_of(uid))), -1)
		"revealed":
			await _reveal(events, i)
		"use_magic":
			await _magic(events, i)
		"cores":
			await _cores(dd)
		"attack_declared":
			await _attack(dd)
		"block_declared":
			await _block(dd)
		"compare_bp":
			await _clash(events, i)
		"destroyed":
			await _destroyed(int(dd.get("uid", -1)))
		"damage":
			await _damage(dd)
		"burst_activated":
			await _burst(dd)
		"refresh_step":
			await _refresh(int(dd.get("player", -1)))
		"battle_end":
			fx.arrow.clear()
			_atk = -1
			_blk = -1
		"game_over":
			await _game_over(dd)
		"awaken", "crush", "blessed", "luster":
			await _keyword(int(dd.get("uid", -1)), str(e.get("kind", "")).to_upper())
		"link":
			await _keyword(int(dd.get("from", -1)), "LINK")
		"ascend":
			await _keyword(int(dd.get("to", -1)), "ASCEND")
		"cores_removed":
			# purple (0.10.0): the core flight itself is the "cores" beat
			await _keyword(int(dd.get("uid", -1)), "CORE BREAK")
		"raid_refresh":
			await _keyword(int(dd.get("uid", -1)), "RAID")
		"gale":
			await fx.callout("GALE", UITheme.SUCCESS, fx.global_position + fx.centre(), 40, 0.25)
		"destruction_substituted":
			await _keyword(int(dd.get("uid", -1)), "SAVED")
		"at_field_blocked":
			await _keyword(int(dd.get("uid", -1)), "A.T. FIELD")


# ===========================================================================
# Beats
# ===========================================================================

const STEP_LABELS := ["START STEP", "CORE STEP", "DRAW STEP", "REFRESH STEP",
		"MAIN STEP", "ATTACK STEP", "END STEP"]


func _step(dd: Dictionary) -> void:
	var s := int(dd.get("step", 0))
	if s < 0 or s >= STEP_LABELS.size():
		return
	var y := board.anchor_rect(-1, "centre").get_center().y - fx.global_position.y
	if y <= 0.0:
		y = fx.size.y * 0.5
	var big := s >= BSS.Step.MAIN
	fx.pulse(board.step_pill(s), UITheme.STEP_COLORS[s], 0.5)
	await fx.step_sweep(STEP_LABELS[s], UITheme.STEP_COLORS[s], y, 0.32 if big else 0.08)


func _move(events: Array, i: int) -> void:
	var dd: Dictionary = events[i].get("data", {})
	var uid := int(dd.get("uid", -1))
	var from := int(dd.get("from", -1))
	var to := int(dd.get("to", -1))
	var who := int(dd.get("owner", board.owner_of(uid)))
	if to == BSS.Zone.HAND and from == BSS.Zone.DECK:
		await _draws(events, i, who)
	elif to == BSS.Zone.FIELD:
		await _enter(uid, _arrival_kind(events, i, uid), who, from)
	elif to == BSS.Zone.BURST:
		await _set_burst(uid, who)
	elif to == BSS.Zone.TRASH and from == BSS.Zone.DECK:
		await _mill(events, i, who)
	elif to == BSS.Zone.TRASH:
		await _to_pile(uid, who, "trash")
	elif to == BSS.Zone.DECK:
		await _to_pile(uid, who, "deck")
	elif to == BSS.Zone.HAND:
		await _to_hand(uid, who)


func _arrival_kind(events: Array, i: int, uid: int) -> String:
	for j in range(i + 1, mini(events.size(), i + 12)):
		var e: Dictionary = events[j]
		var k := str(e.get("kind", ""))
		if k in ["summon", "place", "token_summoned"] and int((e.get("data", {}) as Dictionary).get("uid", -1)) == uid:
			return k
	return "summon"


## Opening hands and draw steps: every card in a run of draws is dealt with a
## short stagger, like dealing from the top of the deck.
## "Reveal the top three cards of your deck" (0.16.1, R-079): the cards fan
## out face up from the deck, the ones the effect takes are marked, then
## they fly to where they went (hand, field, bottom of the deck or trash).
## Reveals are public, so both players see them. Private looks ("look at
## the top card") are never logged as "revealed".
func _reveal(events: Array, i: int) -> void:
	var dd: Dictionary = events[i].get("data", {})
	var who := int(dd.get("player", 0))
	var uids: Array = dd.get("uids", [])
	var ids: Array = dd.get("card_ids", [])
	var taken: Array = dd.get("taken", [])
	if uids.is_empty():
		return
	var size := Vector2(112, 157)
	var src: Rect2 = board.anchor_rect(who, "deck")
	if bool(dd.get("random_hand", false)):
		src = board.anchor_rect(who, "hand")
	elif bool(dd.get("burst", false)):
		src = board.anchor_rect(who, "burst")
	var n := uids.size()
	var gap := 18.0
	var total := n * size.x + (n - 1) * gap
	var c := fx.global_position + fx.centre()
	var ghosts: Array = []
	fx.dim(0.4, 0.2)
	AudioManager.play_sfx("draw")
	for k in n:
		var cid := str(ids[k]) if k < ids.size() else board.card_id_of(int(uids[k]))
		if cid == "":
			continue
		var g := fx.ghost(cid, Rect2(Vector2.ZERO, size), true)
		g.set_meta("reveal_id", cid)
		g.position = fx.local_rect(src).get_center() - size * 0.5
		g.scale = Vector2.ONE * 0.5
		ghosts.append(g)
		var dest := Rect2(c + Vector2(-total * 0.5 + k * (size.x + gap), -size.y * 0.5), size)
		fx.fly(g, dest, 0.28, 40.0)
		await fx.wait(0.06)
	await fx.wait(0.2)
	for g2: CardWidget in ghosts:
		if is_instance_valid(g2):
			fx.flip_to(g2, str(g2.get_meta("reveal_id", "")), 0.22)
	await fx.wait(0.28)
	fx.callout("REVEAL", UITheme.GOLD, c + Vector2(0, -size.y * 0.5 - 40.0), 44, 0.4)
	for k2 in ghosts.size():
		var g3: CardWidget = ghosts[k2]
		if is_instance_valid(g3) and taken.has(int(uids[k2])):
			g3.set_highlight(UITheme.GOLD)
			fx.ring(g3.global_position + size * 0.5, UITheme.GOLD, 20.0, 120.0, 0.4, 3.0)
	await fx.wait(1.1 if taken.is_empty() else 1.3)
	# Where each card went: the move events that follow this reveal.
	for k3 in ghosts.size():
		var g4: CardWidget = ghosts[k3]
		if not is_instance_valid(g4):
			continue
		var to_zone := _reveal_dest(events, i, int(uids[k3]))
		var dest_rect: Rect2 = board.anchor_rect(who, "deck")
		match to_zone:
			BSS.Zone.HAND: dest_rect = board.anchor_rect(who, "hand")
			BSS.Zone.TRASH: dest_rect = board.anchor_rect(who, "trash")
			BSS.Zone.FIELD: dest_rect = board.anchor_rect(who, "field")
		fx.fly(g4, dest_rect, 0.3, 30.0)
		fx.vanish(g4, 0.3, true)
	await fx.wait(0.36)
	fx.dim(0.0, 0.2)


## The zone a revealed card moved to right after the reveal, or DECK.
func _reveal_dest(events: Array, i: int, uid: int) -> int:
	for j in range(i + 1, mini(events.size(), i + 40)):
		var e: Dictionary = events[j]
		var ed: Dictionary = e.get("data", {})
		if str(e.get("kind", "")) == "move" and int(ed.get("uid", -1)) == uid:
			_claimed[j] = true
			return int(ed.get("to", BSS.Zone.DECK))
	return BSS.Zone.DECK


func _draws(events: Array, i: int, who: int) -> void:
	var batch: Array = [i]
	var j := i + 1
	while j < events.size():
		var e: Dictionary = events[j]
		var k := str(e.get("kind", ""))
		var dd: Dictionary = e.get("data", {})
		if k == "draw" or k == "shuffle":
			j += 1
			continue
		if k == "move" and int(dd.get("from", -1)) == BSS.Zone.DECK and int(dd.get("to", -1)) == BSS.Zone.HAND \
				and int(dd.get("owner", -1)) == who:
			batch.append(j)
			_claimed[j] = true
			j += 1
			continue
		break
	var deck := board.anchor_rect(who, "deck")
	for n in batch.size():
		var idx: int = batch[n]
		var uid := int((events[idx].get("data", {}) as Dictionary).get("uid", -1))
		_deal_one(uid, who, deck)
		AudioManager.play_sfx("draw")
		await fx.wait(0.11)
	await fx.wait(0.36)


func _deal_one(uid: int, who: int, deck: Rect2) -> void:
	var dst := board.rect_of(uid)
	if dst.size.x <= 0.0 or deck.size.x <= 0.0:
		board.reveal(uid)
		return
	var mine := who == board.seat()
	var g := fx.ghost("", Rect2(Vector2.ZERO, dst.size), true)
	g.position = fx.local_rect(deck).get_center() - dst.size * 0.5
	g.scale = Vector2.ONE * (deck.size.x / dst.size.x)
	if mine:
		var cid := board.card_id_of(uid)
		var t := fx.tw()
		t.tween_interval(fx.d(0.14))
		var gid := g.get_instance_id()          # an id, not the node: it may be freed first
		t.tween_callback(func() -> void:
			var gg := BattleFX.alive(gid) as CardWidget
			if gg != null:
				fx.flip_to(gg, cid, 0.2))
	await fx.fly(g, dst, 0.38, -50.0 if mine else 50.0)
	board.reveal(uid)
	if is_instance_valid(g):
		g.queue_free()


## Summon, nexus placement, token: the card is lifted to centre stage, named,
## then slammed into its slot. An opponent's card turns face up on the way.
func _enter(uid: int, kind: String, who: int, from: int) -> void:
	_entered[uid] = true
	var dst := board.rect_of(uid)
	var cid := board.card_id_of(uid)
	if dst.size.x <= 0.0 or cid == "":
		board.reveal(uid)
		return
	var mine := who == board.seat()
	var src := _origin_rect(uid, who, from)
	var col := _colour(cid)
	var face_down := not mine and (from == BSS.Zone.HAND or from == BSS.Zone.DECK)
	var g := fx.ghost(cid, Rect2(Vector2.ZERO, dst.size), face_down)
	g.position = fx.local_rect(src).get_center() - dst.size * 0.5
	g.scale = Vector2.ONE * clampf(src.size.x / dst.size.x, 0.3, 1.4)
	g.z_index = 5

	AudioManager.play_sfx("summon" if kind != "place" else "card_play")
	fx.dim(0.5, 0.2)
	var stage := Rect2(fx.global_position + fx.centre() - dst.size * 0.85, dst.size * 1.7)
	await fx.fly(g, stage, 0.30, 70.0 if mine else -70.0)
	if face_down and is_instance_valid(g):
		await fx.flip_to(g, cid, 0.22)
	var c := fx.global_position + fx.centre()
	fx.ring(c, col, 40.0, 240.0, 0.5, 7.0)
	fx.flash(Rect2(), col, 0.3, 0.18)
	var word := "SUMMON"
	match kind:
		"place": word = "NEXUS"
		"token_summoned": word = "TOKEN"
	fx.callout(word, col, c + Vector2(0, -dst.size.y * 0.85 - 34.0), 46, 0.40)
	fx.callout(board.card_name(uid), Color(0.92, 0.95, 1.0), c + Vector2(0, dst.size.y * 0.85 + 26.0), 26, 0.36)
	await fx.wait(0.55)
	fx.dim(0.0, 0.18)
	if is_instance_valid(g):
		await fx.fly(g, dst, 0.22, 0.0, 1.0, Tween.TRANS_QUART)
	board.reveal(uid)
	if is_instance_valid(g):
		g.queue_free()
	fx.ring(dst.get_center(), col, 30.0, 120.0, 0.35, 5.0)
	fx.shake(6.0, 0.2)
	await fx.wait(0.12)


func _origin_rect(uid: int, who: int, from: int) -> Rect2:
	if _before.has(uid):
		return (_before[uid] as Dictionary).get("rect", Rect2())
	if from == BSS.Zone.DECK:
		return board.anchor_rect(who, "deck")
	if from == BSS.Zone.TRASH:
		return board.anchor_rect(who, "trash")
	var h := board.anchor_rect(who, "hand")
	if h.size.x > 0.0:
		return Rect2(h.get_center() - Vector2(40, 56), Vector2(80, 112))
	return board.anchor_rect(who, "deck")


func _magic(events: Array, i: int) -> void:
	var dd: Dictionary = events[i].get("data", {})
	var uid := int(dd.get("uid", -1))
	var who := int(dd.get("player", board.owner_of(uid)))
	var cid := board.card_id_of(uid)
	if cid == "":
		return
	# The card goes to the trash once the effect resolves; this beat covers it.
	for j in range(i + 1, events.size()):
		var e: Dictionary = events[j]
		var ed: Dictionary = e.get("data", {})
		if str(e.get("kind", "")) == "move" and int(ed.get("uid", -1)) == uid and int(ed.get("to", -1)) == BSS.Zone.TRASH:
			_claimed[j] = true
			break
	var mine := who == board.seat()
	var size := Vector2(112, 157)
	var src := _origin_rect(uid, who, BSS.Zone.HAND)
	var col := _colour(cid)
	var g := fx.ghost(cid, Rect2(Vector2.ZERO, size), not mine)
	g.position = fx.local_rect(src).get_center() - size * 0.5
	g.scale = Vector2.ONE * clampf(src.size.x / size.x, 0.3, 1.4)
	AudioManager.play_sfx("magic")
	fx.dim(0.45, 0.2)
	var stage := Rect2(fx.global_position + fx.centre() - size * 0.85, size * 1.7)
	await fx.fly(g, stage, 0.30, 60.0)
	if not mine and is_instance_valid(g):
		await fx.flip_to(g, cid, 0.22)
	var c := fx.global_position + fx.centre()
	fx.ring(c, col, 30.0, 200.0, 0.45, 5.0)
	fx.ring(c, Color.WHITE, 10.0, 150.0, 0.55, 3.0)
	fx.callout("MAGIC", col, c + Vector2(0, -size.y * 0.85 - 34.0), 46, 0.4)
	await fx.wait(0.55)
	fx.dim(0.0, 0.18)
	var trash := board.anchor_rect(who, "trash")
	if trash.size.x > 0.0 and is_instance_valid(g):
		await fx.fly(g, trash, 0.28, 40.0)
	if is_instance_valid(g):
		await fx.vanish(g, 0.15, true)


## 0.22.0: cores fly one after another as real gems, and both ends count:
## the row they leave shows them going one by one, the row they reach fills
## slot by slot with a pop. A core from the void (the core step) first appears
## out of a flash of light with "+1 CORE"; cores back from the core trash (the
## refresh step) stream home in a quick arc. The board has already drawn the
## new state, so before anything plays every row a core movement touches is
## held at its old count (_hold_cores) and stepped forward here.
func _cores(dd: Dictionary) -> void:
	var from_loc: Dictionary = dd.get("from", {})
	var to_loc: Dictionary = dd.get("to", {})
	var n := int(dd.get("n", 1))
	if n <= 0:
		return
	var src := _gems_at(from_loc)
	var dst := _gems_at(to_loc)
	var a := _loc_point(from_loc)
	# 0.22.1: a core you dragged ends where you put it -- no flight, it is
	# simply in its new place, with the small "arrived" pop
	if board.has_method("is_dragged_move") and board.is_dragged_move(dd):
		if dst != null:
			dst.pop_in()
		return
	var b := _loc_point(to_loc)
	if a == Vector2.INF or b == Vector2.INF or (dst == null and a.distance_to(b) < 4.0):
		_settle_rows(src, dst, n, 0)
		return
	var shown := clampi(n, 1, 8)
	var targets: Array = dst.landing_points(shown) if dst != null else []
	var from_void := int(from_loc.get("zone", -1)) == BSS.Zone.VOID and str(from_loc.get("kind", "")) != "card"
	var refresh := int(from_loc.get("zone", -1)) == BSS.Zone.TRASH and int(to_loc.get("zone", -1)) == BSS.Zone.RESERVE
	if from_void and int(to_loc.get("zone", -1)) == BSS.Zone.RESERVE:
		fx.float_text("+%d CORE" % n, a + Vector2(0, -30), UITheme.CORE.lightened(0.3), 24)
	var sid := src.get_instance_id() if src != null else 0
	var did := dst.get_instance_id() if dst != null else 0
	var stagger := 0.09 if refresh else 0.13
	var dur := 0.42 if refresh else 0.5
	await fx.gems_seq(a, b, n, bool(dd.get("soul", false)),
		func(_i: int) -> void:
			var s := BattleFX.alive(sid) as CoreGems
			if s != null:
				s.bump(-1),
		func(_i: int) -> void:
			var t := BattleFX.alive(did) as CoreGems
			if t != null:
				t.bump(1),
		from_void, stagger, dur, targets)
	_settle_rows(BattleFX.alive(sid) as CoreGems, BattleFX.alive(did) as CoreGems, n, shown, shown)
	await fx.wait(0.1)


## Whatever of a move was not stepped one by one settles at once: `left` of
## the source's and `arrived` of the target's held cores are already shown.
func _settle_rows(src: CoreGems, dst: CoreGems, n: int, left: int, arrived: int = 0) -> void:
	if src != null and is_instance_valid(src):
		src.hold_add(-(n - left))
	if dst != null and is_instance_valid(dst):
		dst.hold_add(n - arrived)


## Before the beats play, every gem row a core movement touches goes back to
## what it showed before the update; _cores then steps each one forward.
func _hold_cores(events: Array) -> void:
	_held_rows = []
	# a core the player dragged is already in its new place (0.22.1):
	# neither of its rows is held
	var dragged_seen := false
	for k in events.size():
		var e: Dictionary = events[k]
		if _claimed.has(k) or str(e.get("kind", "")) != "cores":
			continue
		var dd: Dictionary = e.get("data", {})
		var n := int(dd.get("n", 1))
		var src := _gems_at(dd.get("from", {}))
		var dst := _gems_at(dd.get("to", {}))
		if not dragged_seen and board.has_method("is_dragged_move") and board.is_dragged_move(dd, false):
			dragged_seen = true
			continue
		if src != null:
			src.hold_add(n)
			_held_rows.append(src.get_instance_id())
		if dst != null:
			dst.hold_add(-n)
			_held_rows.append(dst.get_instance_id())


## After the beats: every row shows its real count, whatever happened.
func _release_cores() -> void:
	for id: int in _held_rows:
		var g := BattleFX.alive(id) as CoreGems
		if g != null and g.offset != 0:
			g.hold(0)
	_held_rows = []


var _held_rows: Array = []


## The gem row of a core location: a pool's CoreGems, or the gems on a card.
func _gems_at(loc: Dictionary) -> CoreGems:
	if str(loc.get("kind", "")) == "card":
		var w := board.node_of(int(loc.get("uid", -1)))
		if w is CardWidget:
			return (w as CardWidget).core_gems()
		return null
	var zname := ""
	match int(loc.get("zone", -1)):
		BSS.Zone.RESERVE: zname = "reserve"
		BSS.Zone.LIFE: zname = "life"
		BSS.Zone.TRASH: zname = "core_trash"
	if zname.is_empty():
		return null
	return board.anchor(int(loc.get("player", -1)), zname) as CoreGems


## A core location ({"kind":"pool"...} or {"kind":"card","uid":...}) as a
## point on screen. The void (where cores come from in the core step) is just
## above the reserve.
func _loc_point(loc: Dictionary) -> Vector2:
	if str(loc.get("kind", "")) == "card":
		var uid := int(loc.get("uid", -1))
		var r := board.rect_of(uid)
		if r.size.x <= 0.0 and _before.has(uid):
			r = (_before[uid] as Dictionary).get("rect", Rect2())
		return r.get_center() if r.size.x > 0.0 else Vector2.INF
	var pid := int(loc.get("player", -1))
	var zname := ""
	match int(loc.get("zone", -1)):
		BSS.Zone.RESERVE: zname = "reserve"
		BSS.Zone.LIFE: zname = "life"
		BSS.Zone.TRASH: zname = "core_trash"
		BSS.Zone.VOID: zname = "void"
	if zname == "void":
		var rr := board.anchor_rect(pid, "reserve")
		# 0.22.0: the new core appears just beside the reserve row (in the
		# open field edge), not over the life row, and glides into its slot
		return Vector2(rr.end.x + 70.0, rr.get_center().y) if rr.size.x > 0.0 else Vector2.INF
	var r2 := board.anchor_rect(pid, zname)
	return r2.get_center() if r2.size.x > 0.0 else Vector2.INF


## The attack and its TARGET. In Battle Spirits an attack is aimed at the
## opposing player; the defender then decides whether a spirit steps in. So the
## arrow first points at the defender's life, and only moves if a block comes.
func _attack(dd: Dictionary) -> void:
	var uid := int(dd.get("uid", -1))
	_atk = uid
	_blk = -1
	var attacker_pid := int(dd.get("player", board.owner_of(uid)))
	var defender := 1 - attacker_pid
	var src := board.node_of(uid)
	var life := board.anchor(defender, "life_panel")
	AudioManager.play_sfx("attack")
	board.animate_orient(uid)
	if src == null:
		return
	var r := BattleFX.visual_rect(src)
	fx.pulse(src, UITheme.SOUL, 0.5)
	fx.ring(r.get_center(), UITheme.SOUL, 20.0, 110.0, 0.4, 5.0)
	fx.callout("ATTACK!", UITheme.SOUL, r.get_center() + Vector2(0, -r.size.y * 0.5 - 20.0), 50, 0.35)
	if life != null:
		fx.arrow.point_at(src, life, UITheme.SOUL)
		fx.arrow.grow = 0.0
		var t := fx.tw()
		t.tween_property(fx.arrow, "grow", 1.0, fx.d(0.38)).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
		await t.finished
		var lr := BattleFX.visual_rect(life)
		fx.ring(lr.get_center(), UITheme.SOUL, 16.0, 70.0, 0.4, 4.0)
		fx.float_text("TARGET: %s" % ("YOUR LIFE" if defender == board.seat() else "OPPONENT'S LIFE"),
				lr.get_center() + Vector2(0, -lr.size.y * 0.5 - 6.0), UITheme.SOUL, 18)
	await fx.wait(0.35)


func _block(dd: Dictionary) -> void:
	var uid := int(dd.get("uid", -1))
	_blk = uid
	var blk := board.node_of(uid)
	var atk := board.node_of(_atk)
	AudioManager.play_sfx("block")
	board.animate_orient(uid)
	if blk == null:
		return
	var r := BattleFX.visual_rect(blk)
	fx.pulse(blk, UITheme.CORE, 0.5)
	fx.ring(r.get_center(), UITheme.CORE, 20.0, 120.0, 0.4, 6.0)
	fx.callout("BLOCK!", UITheme.CORE, r.get_center() + Vector2(0, r.size.y * 0.5 + 24.0), 50, 0.35)
	if atk != null:
		fx.arrow.point_at(atk, blk, UITheme.SOUL)
		fx.arrow.grow = 0.0
		var t := fx.tw()
		t.tween_property(fx.arrow, "grow", 1.0, fx.d(0.32)).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
		await t.finished
		fx.float_text("TARGET: %s" % board.card_name(uid), r.get_center() + Vector2(0, -r.size.y * 0.5 - 6.0),
				UITheme.CORE, 18)
	await fx.wait(0.3)


## 7-1-5-2: the two spirits face off at centre. BP counts up, they collide,
## the higher BP wins; the loser (both, on a tie) shatters on the spot.
func _clash(events: Array, i: int) -> void:
	var dd: Dictionary = events[i].get("data", {})
	var a := int(dd.get("a", 0))
	var b := int(dd.get("b", 0))
	var atk_cid := _cid(_atk)
	var blk_cid := _cid(_blk)
	if atk_cid == "" or blk_cid == "":
		return
	# The destruction that follows is shown here, as part of the clash.
	var losers: Array = []
	if a <= b: losers.append(_atk)
	if b <= a: losers.append(_blk)
	for j in range(i + 1, mini(events.size(), i + 16)):
		var e: Dictionary = events[j]
		if str(e.get("kind", "")) == "destroyed" and int((e.get("data", {}) as Dictionary).get("uid", -1)) in losers:
			_claimed[j] = true

	fx.arrow.clear()
	var size := Vector2(112, 157)
	var c := fx.global_position + fx.centre()
	var ar := _rect(_atk)
	var br := _rect(_blk)
	var ga := fx.ghost(atk_cid, Rect2(ar.get_center() - size * 0.5, size))
	var gb := fx.ghost(blk_cid, Rect2(br.get_center() - size * 0.5, size))
	ga.z_index = 6
	gb.z_index = 6
	fx.dim(0.62, 0.2)
	var left := Rect2(c + Vector2(-230, 0) - size * 0.8, size * 1.6)
	var right := Rect2(c + Vector2(230, 0) - size * 0.8, size * 1.6)
	var a_left := board.owner_of(_atk) == board.seat()
	fx.fly(ga, left if a_left else right, 0.32, 30.0)
	await fx.fly(gb, right if a_left else left, 0.32, -30.0)

	var vs := fx.word("VS", 54, UITheme.ACCENT)
	vs.position = fx.centre() - vs.size * 0.5
	var la := fx.word("0", 40, UITheme.SOUL)
	var lb := fx.word("0", 40, UITheme.CORE)
	var la_x := (left if a_left else right).get_center().x - fx.global_position.x
	var lb_x := (right if a_left else left).get_center().x - fx.global_position.x
	var label_y := fx.centre().y + size.y * 0.8 + 8.0
	la.custom_minimum_size = Vector2(160, 0)
	lb.custom_minimum_size = Vector2(160, 0)
	la.size = Vector2(160, la.size.y)
	lb.size = Vector2(160, lb.size.y)
	la.position = Vector2(la_x - 80.0, label_y)
	lb.position = Vector2(lb_x - 80.0, label_y)
	fx.count_up(la, a, 0.45)
	await fx.count_up(lb, b, 0.45)
	la.text = "%d BP" % a
	lb.text = "%d BP" % b
	await fx.wait(0.2)

	# Collide.
	var t := fx.tw()
	t.set_parallel(true)
	var dx := 150.0 if a_left else -150.0
	t.tween_property(ga, "position:x", ga.position.x + dx, fx.d(0.12)).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_IN)
	t.tween_property(gb, "position:x", gb.position.x - dx, fx.d(0.12)).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_IN)
	await t.finished
	AudioManager.play_sfx("clash")
	fx.flash(Rect2(), Color.WHITE, 0.3, 0.5)
	fx.ring(c, UITheme.ACCENT, 20.0, 300.0, 0.5, 8.0)
	fx.shake(14.0, 0.32)
	var back := fx.tw()
	back.set_parallel(true)
	back.tween_property(ga, "position:x", ga.position.x - dx * 0.6, fx.d(0.18)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	back.tween_property(gb, "position:x", gb.position.x + dx * 0.6, fx.d(0.18)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	await back.finished

	var result := "TIE — BOTH DESTROYED"
	var rcol := UITheme.ACCENT
	if a > b:
		result = "%s WINS" % board.card_name(_atk).to_upper()
		rcol = UITheme.SOUL
	elif b > a:
		result = "%s WINS" % board.card_name(_blk).to_upper()
		rcol = UITheme.CORE
	fx.callout(result, rcol, c + Vector2(0, -size.y * 0.8 - 40.0), 34, 0.55)
	await fx.wait(0.25)
	for uid: int in losers:
		var g := ga if uid == _atk else gb
		if is_instance_valid(g):
			var gr := Rect2(fx.global_position + g.position + g.size * 0.5 - g.size * g.scale * 0.5, g.size * g.scale)
			var cid := _cid(uid)
			g.queue_free()
			AudioManager.play_sfx("destroy")
			fx.shatter(gr, cid, _colour(cid))
	await fx.wait(0.5)
	for n: Variant in [vs, la, lb]:
		if is_instance_valid(n):
			fx.vanish(n as Control, 0.2)
	# Survivors return to their slots.
	for uid: int in [_atk, _blk]:
		if uid in losers:
			continue
		var g2 := ga if uid == _atk else gb
		var home := board.rect_of(uid)
		if is_instance_valid(g2) and home.size.x > 0.0:
			fx.fly(g2, home, 0.26, 0.0)
	fx.dim(0.0, 0.2)
	await fx.wait(0.3)
	# Untyped on purpose: a loser's ghost is already freed by now, and a typed
	# loop (`for g: Control in [...]`) builds a typed array that rejects a dead
	# reference outright (R-030).
	for g3: Variant in [ga, gb]:
		if is_instance_valid(g3):
			(g3 as Node).queue_free()


func _destroyed(uid: int) -> void:
	var r := _rect(uid)
	var cid := _cid(uid)
	if r.size.x <= 0.0 or cid == "":
		return
	AudioManager.play_sfx("destroy")
	fx.callout("DESTROYED", UITheme.DANGER, r.get_center() + Vector2(0, -r.size.y * 0.5 - 16.0), 30, 0.3)
	await fx.shatter(r, cid, _colour(cid))
	fx.pulse(board.anchor(board.owner_of(uid), "trash"), Color.WHITE, 0.4)


## The life cores taken by damage are shown by the damage beat itself, so the
## plain core movement just before it is skipped.
func _claim_damage_cores(events: Array) -> void:
	for i in events.size():
		if str((events[i] as Dictionary).get("kind", "")) != "damage":
			continue
		for j in range(i - 1, maxi(-1, i - 3), -1):
			var e: Dictionary = events[j]
			var from: Dictionary = (e.get("data", {}) as Dictionary).get("from", {})
			if str(e.get("kind", "")) == "cores" and int(from.get("zone", -1)) == BSS.Zone.LIFE:
				_claimed[j] = true
				break


func _damage(dd: Dictionary) -> void:
	var pid := int(dd.get("player", -1))
	var n := int(dd.get("n", 0))
	if n <= 0:
		return
	var life := board.anchor(pid, "life_panel")
	var lr := board.anchor_rect(pid, "life_panel")
	if lr.size.x <= 0.0:
		return
	var src := board.rect_of(_atk)
	fx.arrow.clear()
	if src.size.x > 0.0:
		# The strike: a fast comet from the attacker into the life panel.
		await fx.gems(src.get_center(), lr.get_center(), 1, true, 0.18)
	AudioManager.play_sfx("damage")
	fx.flash(lr, UITheme.SOUL, 0.45, 0.8)
	fx.flash(Rect2(), UITheme.SOUL, 0.35, 0.16)
	fx.shake(16.0, 0.38)
	fx.ring(lr.get_center(), UITheme.SOUL, 20.0, 160.0, 0.45, 6.0)
	fx.pulse(life, UITheme.SOUL, 0.6)
	fx.callout("-%d LIFE" % n, UITheme.SOUL, lr.get_center(), 44, 0.45)
	await fx.wait(0.3)
	var res := board.anchor_rect(pid, "reserve")
	if res.size.x > 0.0:
		await fx.gems(lr.get_center(), res.get_center(), n, false, 0.4)
	await fx.wait(0.2)


func _burst(dd: Dictionary) -> void:
	var uid := int(dd.get("uid", -1))
	var who := int(dd.get("player", board.owner_of(uid)))
	var cid := board.card_id_of(uid)
	var slot := board.anchor_rect(who, "burst")
	if cid == "" or slot.size.x <= 0.0:
		return
	var size := Vector2(112, 157)
	var g := fx.ghost("", Rect2(slot.get_center() - size * 0.5, size), true)
	g.scale = Vector2.ONE * (slot.size.x / size.x)
	AudioManager.play_sfx("burst")
	fx.dim(0.55, 0.2)
	var c := fx.global_position + fx.centre()
	await fx.fly(g, Rect2(c - size * 0.9, size * 1.8), 0.3, 40.0)
	await fx.flip_to(g, cid, 0.24)
	fx.ring(c, UITheme.ACCENT, 30.0, 260.0, 0.5, 8.0)
	fx.ring(c, Color.WHITE, 10.0, 180.0, 0.6, 3.0)
	fx.flash(Rect2(), UITheme.ACCENT, 0.3, 0.25)
	fx.callout("BURST!", UITheme.ACCENT, c + Vector2(0, -size.y * 0.9 - 36.0), 56, 0.5)
	await fx.wait(0.6)
	fx.dim(0.0, 0.18)
	await fx.vanish(g, 0.2, true)


func _set_burst(uid: int, who: int) -> void:
	var dst := board.anchor_rect(who, "burst")
	if dst.size.x <= 0.0:
		board.reveal(uid)
		return
	var mine := who == board.seat()
	var cid := board.card_id_of(uid)
	var src := _origin_rect(uid, who, BSS.Zone.HAND)
	var g := fx.ghost(cid if mine else "", Rect2(src.get_center() - dst.size * 0.5, dst.size), not mine)
	g.scale = Vector2.ONE * clampf(src.size.x / dst.size.x, 0.5, 3.0)
	AudioManager.play_sfx("card_play")
	if mine:
		var t := fx.tw()
		t.tween_interval(fx.d(0.12))
		var gid2 := g.get_instance_id()
		t.tween_callback(func() -> void:
			var gg := BattleFX.alive(gid2) as CardWidget
			if gg != null:
				gg.setup_back(dst.size)
				gg.size = dst.size)
	await fx.fly(g, dst, 0.36, 40.0)
	board.reveal(uid)
	fx.callout("BURST SET", UITheme.ACCENT, dst.get_center() + Vector2(0, -dst.size.y), 24, 0.3)
	if is_instance_valid(g):
		g.queue_free()
	await fx.wait(0.2)


## Cards milled from the top of a deck (Crush, blue's mill effects, 0.10.0):
## the whole run flips off the deck into the trash, face up, staggered. Cards
## in a deck have no place on screen, so before 0.10.0 a mill showed nothing.
func _mill(events: Array, i: int, who: int) -> void:
	var batch: Array = [i]
	var j := i + 1
	while j < events.size():
		var dd: Dictionary = (events[j] as Dictionary).get("data", {})
		if str((events[j] as Dictionary).get("kind", "")) == "move" and int(dd.get("from", -1)) == BSS.Zone.DECK \
				and int(dd.get("to", -1)) == BSS.Zone.TRASH and int(dd.get("owner", -1)) == who:
			batch.append(j)
			_claimed[j] = true
			j += 1
			continue
		break
	var deck := board.anchor_rect(who, "deck")
	var trash := board.anchor_rect(who, "trash")
	if deck.size.x <= 0.0 or trash.size.x <= 0.0:
		return
	for n in batch.size():
		var uid := int(((events[batch[n]] as Dictionary).get("data", {}) as Dictionary).get("uid", -1))
		var g := fx.ghost(board.card_id_of(uid), Rect2(Vector2.ZERO, trash.size), false)
		g.position = fx.local_rect(deck).position
		g.scale = Vector2.ONE * (deck.size.x / maxf(1.0, trash.size.x))
		var t := fx.tw()
		t.tween_property(g, "position", fx.local_rect(trash).position, fx.d(0.26)) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		t.parallel().tween_property(g, "scale", Vector2.ONE, fx.d(0.26))
		t.tween_property(g, "modulate:a", 0.0, fx.d(0.12))
		t.tween_callback(g.queue_free)
		AudioManager.play_sfx("card_play")
		await fx.wait(0.07)
	fx.callout("MILL %d" % batch.size(), Color(0.45, 0.70, 1.0), fx.local_rect(trash).get_center()
			+ fx.global_position + Vector2(0, -trash.size.y * 0.7), 30, 0.2)
	await fx.wait(0.34)


func _to_pile(uid: int, who: int, pile: String) -> void:
	var src := _rect(uid)
	var dst := board.anchor_rect(who, pile)
	var cid := _cid(uid)
	if src.size.x <= 0.0 or dst.size.x <= 0.0:
		return
	var g := fx.ghost(cid, src, cid == "" or pile == "deck")
	await fx.fly(g, dst, 0.3, 30.0)
	if is_instance_valid(g):
		await fx.vanish(g, 0.12, true)


func _to_hand(uid: int, who: int) -> void:
	var dst := board.rect_of(uid)
	var src := _rect(uid) if _before.has(uid) else board.anchor_rect(who, "trash")
	if dst.size.x <= 0.0 or src.size.x <= 0.0:
		board.reveal(uid)
		return
	var g := fx.ghost(board.card_id_of(uid), Rect2(src.get_center() - dst.size * 0.5, dst.size),
			who != board.seat())
	await fx.fly(g, dst, 0.32, 40.0)
	board.reveal(uid)
	if is_instance_valid(g):
		g.queue_free()


func _refresh(pid: int) -> void:
	var any := false
	for uid: int in board.pending_orient_uids():
		if board.owner_of(uid) == pid:
			board.animate_orient(uid)
			any = true
	if any:
		await fx.wait(0.3)


func _keyword(uid: int, word: String) -> void:
	var r := board.rect_of(uid)
	if r.size.x <= 0.0:
		r = _rect(uid)
	if r.size.x <= 0.0:
		return
	fx.ring(r.get_center(), UITheme.ACCENT, 16.0, 90.0, 0.35, 4.0)
	await fx.callout(word, UITheme.ACCENT, r.get_center(), 30, 0.25)


func _game_over(dd: Dictionary) -> void:
	var w := int(dd.get("winner", -1))
	var title := "DRAW"
	var col := UITheme.ACCENT
	if w == board.seat():
		title = "VICTORY"
	elif w == 0 or w == 1:
		title = "DEFEAT"
		col = UITheme.SOUL
	fx.arrow.clear()
	await fx.banner(title, str(dd.get("reason", "")).to_upper(), col, 0.9)


## Level changes are not events of their own; they show up as a difference
## between the previous snapshot and this one.
func _level_pass() -> void:
	var before_lv := {}
	for p: Dictionary in _prev.get("players", []):
		for e: Dictionary in p.get("field", []):
			before_lv[int(e.get("uid", -1))] = int(e.get("level", 0))
	var any := false
	for p2: Dictionary in board.snapshot().get("players", []):
		for e2: Dictionary in p2.get("field", []):
			var uid := int(e2.get("uid", -1))
			if not before_lv.has(uid):
				continue
			var lv := int(e2.get("level", 0))
			var was: int = before_lv[uid]
			if lv == was or lv <= 0:
				continue
			var r := board.rect_of(uid)
			if r.size.x <= 0.0:
				continue
			fx.float_text(("LEVEL UP  LV%d" if lv > was else "LEVEL DOWN  LV%d") % lv, r.get_center(),
					UITheme.SUCCESS if lv > was else UITheme.DANGER, 24)
			any = true
	if any:
		await fx.wait(0.4)


# ===========================================================================
# Lookups
# ===========================================================================

## Where a card is now, or where it was before this presentation.
func _rect(uid: int) -> Rect2:
	var r := board.rect_of(uid)
	if r.size.x > 0.0:
		return r
	if _before.has(uid):
		return (_before[uid] as Dictionary).get("rect", Rect2())
	return Rect2()


func _cid(uid: int) -> String:
	if uid < 0:
		return ""
	var c := board.card_id_of(uid)
	if c == "" and _before.has(uid):
		c = str((_before[uid] as Dictionary).get("card_id", ""))
	return c


func _colour(cid: String) -> Color:
	var cd: CardData = CardDB.get_card(cid)
	if cd != null and not cd.colors.is_empty():
		return UITheme.COLOR_SWATCH.get(cd.colors[0], UITheme.ACCENT)
	return UITheme.ACCENT
