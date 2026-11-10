extends RefCounted
class_name RulesEngine
##
## The referee. Owns turn flow (section 6), battles (section 7), and gameplay
## management (section 9), and is the only thing allowed to accept a player
## action.
##
## The engine is a pure state machine: `submit(pid, action)` either rejects the
## action with a reason or mutates the GameState and returns the list of events
## produced. It never touches the scene tree, never awaits, and never asks the
## UI anything. When a rule needs a decision from a human it parks a
## `pending_choice` on the state and returns; the UI or the bot answers with a
## RESOLVE_CHOICE action later. That is what lets the same code run on a
## dedicated headless server, inside the host client, and inside the bot's
## look-ahead search.
##

var state: GameState
var effects: EffectSystem
var keywords: KeywordEngine

signal state_changed
signal game_ended(winner: int)


func _init(p_state: GameState = null) -> void:
	state = p_state if p_state != null else GameState.new()
	effects = EffectSystem.new(self)
	keywords = KeywordEngine.new(self)


# ===========================================================================
# SECTION 5 -- Preparing to play
# ===========================================================================

## 5-2 -- build both decks, set up cores and opening hands.
##
## `decks` is [{name: String, cards: Array[String]}, ...] of card ids.
##
## Saved decks from DeckManager store their card list under "main" instead,
## because that is the on-disk deck format. Both keys are accepted here: the
## mismatch silently produced an empty deck and the baffling error "deck must
## contain 50-60 cards (has 0)" for a deck the editor had just called legal.
## Callers should still pass "cards"; "main" is tolerated so that a deck
## dictionary can be handed over directly without a conversion step.
func setup(decks: Array, names: Array = ["Player 1", "Player 2"], p_first: int = -1) -> Dictionary:
	for pid in 2:
		var entry: Dictionary = decks[pid]
		var ids: Array = entry.get("cards", entry.get("main", []))
		if ids.is_empty():
			return {"ok": false, "reason":
				"Player %d deck has no cards. A deck dictionary needs a \"cards\" or \"main\" list." % (pid + 1)}
		var legality := validate_deck(ids)
		if not legality["ok"]:
			return {"ok": false, "reason": "Player %d deck illegal: %s" % [pid + 1, legality["reason"]]}
		var ps := state.player(pid)
		ps.display_name = str(names[pid])
		ps.deck_name = str(entry.get("name", "Untitled"))
		for cid in ids:
			var cd: CardData = CardDB.get_card(cid)
			if cd == null:
				return {"ok": false, "reason": "Unknown card id %s" % cid}
			state.spawn_card(cd, pid, BSS.Zone.DECK)
		state.shuffle_deck(pid)                       # 5-2-2
		ps.life_cores = BSS.STARTING_LIFE             # 5-2-3
		ps.reserve_cores = BSS.STARTING_RESERVE       # 5-2-4
		ps.reserve_soul = 1
		state.draw(pid, BSS.OPENING_HAND)             # 5-2-5

	state.turn_number = 0
	# 5-2-6 -- who goes first. A caller that fixes the order (tests, replays)
	# passes p_first and the game goes straight to the mulligans.
	if p_first >= 0:
		state.first_player = p_first
		state.turn_player = p_first
		_open_mulligans()
		state.log_event("setup", {"first": state.first_player})
		return {"ok": true}
	# 0.20.0 -- the coin toss. The seeded RNG tosses, so every machine agrees.
	# The winner has drawn their opening hand above and looks at it while
	# deciding whether to go first or second (CHOOSE_ORDER); the mulligans
	# follow the decision.
	state.toss_winner = state.rng.randi_range(0, 1)
	state.first_player = state.toss_winner          # until they decide
	state.turn_player = state.toss_winner
	state.log_event("setup", {"toss": state.toss_winner})
	state.log_event("coin_toss", {"player": state.toss_winner})
	state.pending_choice = {
		"type": "turn_order",
		"player": state.toss_winner,
		"prompt": "You won the coin toss. Look at your hand, then choose: go first or go second?",
	}
	return {"ok": true}


## 5-2-7 -- mulligan decisions, the first player first.
func _open_mulligans() -> void:
	state.pending_choice = {
		"type": "mulligan",
		"player": state.first_player,
		"prompt": "Mulligan? (returns your hand to the bottom of the deck and redraws 4)",
	}


## 0.20.0 -- the coin-toss winner decides the turn order after seeing their hand.
func _act_choose_order(pid: int, action: Dictionary) -> Dictionary:
	if str(state.pending_choice.get("type", "")) != "turn_order":
		return _err("not the turn-order decision")
	if int(state.pending_choice.get("player", -1)) != pid:
		return _err("not your decision: your opponent won the coin toss")
	var go_first := bool(action.get("first", true))
	state.first_player = pid if go_first else state.opponent_of(pid)
	state.turn_player = state.first_player
	state.pending_choice = {}
	state.log_event("turn_order", {"player": pid, "first": state.first_player})
	_open_mulligans()
	return _ok()


## 5-1-1-1 -- 50 to 60 cards, at most four sharing a card name (5-1-1-1-1
## folds alternate printings and collab names into the same allowance).
static func validate_deck(ids: Array) -> Dictionary:
	if ids.size() < BSS.DECK_MIN or ids.size() > BSS.DECK_MAX:
		return {"ok": false, "reason": "deck must contain %d-%d cards (has %d)" % [BSS.DECK_MIN, BSS.DECK_MAX, ids.size()]}
	var by_name := {}
	for cid in ids:
		var cd: CardData = CardDB.get_card(cid)
		if cd == null:
			return {"ok": false, "reason": "unknown card %s" % cid}
		var k := cd.deck_key()
		by_name[k] = int(by_name.get(k, 0)) + 1
		if by_name[k] > BSS.MAX_COPIES:
			return {"ok": false, "reason": "more than %d copies of \"%s\"" % [BSS.MAX_COPIES, k]}
	return {"ok": true, "reason": ""}


func _finish_mulligans(pid: int, do_mull: bool) -> void:
	var ps := state.player(pid)
	if do_mull:
		# 5-2-7: hand to the bottom, draw four, then shuffle.
		for uid in ps.hand.duplicate():
			state.move_card(uid, BSS.Zone.DECK, pid, false)
		state.draw(pid, BSS.OPENING_HAND)
		state.shuffle_deck(pid)
	else:
		state.draw(pid, BSS.NO_MULLIGAN_BONUS)
	ps.has_mulliganed = true
	state.pending_choice = {}

	var other := state.opponent_of(pid)
	if not state.player(other).has_mulliganed:
		state.pending_choice = {"type": "mulligan", "player": other, "prompt": "Mulligan?"}
		return
	state.setup_complete = true
	_begin_turn()


# ===========================================================================
# SECTION 6 -- Turn flow
# ===========================================================================

func _begin_turn() -> void:
	state.turn_number += 1
	# "... the same as or higher than it was at the start of the turn" (0.15.0)
	state.turn_start_life = [state.player(0).life_total(), state.player(1).life_total()]
	state.player(state.turn_player).reset_turn_counters()
	for ci in state.all_field_cards():
		ci.summoned_this_turn = false
		ci.raid_uses_this_turn = 0
	state.log_event("turn_start", {"player": state.turn_player, "n": state.turn_number})
	_set_step(BSS.Step.START)
	_run_step()


## Every step change goes through here so the board can show it: steps 1-4 run
## without stopping, and without an event the presentation could not tell that
## a core step or refresh step happened at all.
func _set_step(s: int) -> void:
	state.step = s
	state.log_event("step", {"step": s, "player": state.turn_player})
	effects.refresh_constants()          # "during your attack step" effects (0.9.0)


## 0.9.0 (R-042): steps 1-4 and the end step run by themselves. If an effect
## in one of them stops for a choice -- "draw a card, then discard one" -- the
## step loop returned and nothing ever restarted it: the turn stalled at the
## draw step for good. `_steps_parked` remembers that the loop stopped
## part-way; `_resume_steps()`, run after every accepted action, carries on
## once the choice is answered.
var _steps_parked := false
var _end_triggers_done := false


func _resume_steps() -> void:
	if not _steps_parked or state.game_over:
		return
	if not state.pending_choice.is_empty() or not state.effect_stack.is_empty():
		return
	_steps_parked = false
	_run_step()


## Steps 1-4 are pure gameplay management and run without stopping for input.
## The engine walks them in a loop and only halts at MAIN or ATTACK, or when a
## triggered effect parks a choice.
func _run_step() -> void:
	while not state.game_over:
		match state.step:
			BSS.Step.START:
				effects.trigger("start_of_step", {"step": BSS.Step.START})
				# 6-2-2 / 1-2-1-1-2: deck-out is checked here and nowhere else.
				if state.player(state.turn_player).deck.is_empty():
					_declare_winner(state.opponent_of(state.turn_player), "deck out")
					return
				_set_step(BSS.Step.CORE)
			BSS.Step.CORE:
				# 6-3-3: player one skips the core step on turn one -- and a
				# skipped step has no "during your core step" effects either.
				if not (state.turn_number == 1 and state.turn_player == state.first_player):
					effects.trigger("start_of_step", {"step": BSS.Step.CORE})
					state.move_cores(
						GameState.pool(state.turn_player, BSS.Zone.VOID),
						GameState.pool(state.turn_player, BSS.Zone.RESERVE), 1)
				_set_step(BSS.Step.DRAW)
			BSS.Step.DRAW:
				effects.trigger("start_of_step", {"step": BSS.Step.DRAW})
				state.draw(state.turn_player, 1)      # 6-4-2
				# "During your draw step: draw one additional card. After your
				# draw, discard a card" -- effects that act after the draw.
				effects.trigger("after_draw", {"player": state.turn_player})
				_set_step(BSS.Step.REFRESH)
			BSS.Step.REFRESH:
				effects.trigger("start_of_step", {"step": BSS.Step.REFRESH})
				_refresh_step()
				_set_step(BSS.Step.MAIN)
			BSS.Step.MAIN:
				effects.trigger("start_of_step", {"step": BSS.Step.MAIN})
				run_checkpoints()
				return                                 # wait for player actions
			BSS.Step.ATTACK:
				effects.trigger("start_of_step", {"step": BSS.Step.ATTACK})
				# 6-7-2: player one has no attack step on turn one.
				if state.turn_number == 1 and state.turn_player == state.first_player:
					_set_step(BSS.Step.END)
					continue
				run_checkpoints()
				return
			BSS.Step.END:
				_end_step()
				return
		run_checkpoints()
		if not state.pending_choice.is_empty() or not state.effect_stack.is_empty():
			_steps_parked = true                       # resumed by _resume_steps()
			return                                     # something needs answering


## 6-5-2 -- refresh everything you control and sweep the core trash.
func _refresh_step() -> void:
	var pid := state.turn_player
	for uid in state.player(pid).field:
		var c: CardInstance = state.cards[uid]
		# "That spirit will not refresh during their next refresh step" (0.11.1)
		if bool(c.flags.get("skip_refresh", false)):
			c.flags.erase("skip_refresh")
			continue
		c.orientation = BSS.Orientation.REFRESHED
	var p := state.player(pid)
	state.move_cores(GameState.pool(pid, BSS.Zone.TRASH),
			GameState.pool(pid, BSS.Zone.RESERVE), p.trash_cores, false, false)
	state.move_cores(GameState.pool(pid, BSS.Zone.TRASH),
			GameState.pool(pid, BSS.Zone.RESERVE), p.trash_soul, true, false)
	state.log_event("refresh_step", {"player": pid})


## 6-8 -- end step, then hand the turn over.
func _end_step() -> void:
	# On a resume the end-of-turn triggers have already fired; firing them
	# again would double every "at end of turn" effect.
	if not _end_triggers_done:
		_end_triggers_done = true
		# "At the start of your end step" (0.11.0) -- the end step had no
		# start-of-step trigger, unlike every other step.
		effects.trigger("start_of_step", {"step": BSS.Step.END})
		effects.trigger("end_of_turn", {"player": state.turn_player})
		effects.trigger("end_of_opponent_turn", {"player": state.opponent_of(state.turn_player)})
		run_checkpoints()
		if not state.pending_choice.is_empty() or not state.effect_stack.is_empty():
			_steps_parked = true
			return
	_end_triggers_done = false
	# "At the end of this turn, if it is refreshed, return it to its owner's
	# hand" (0.15.0, BSS03-131) -- before the turn's flags expire.
	for eb in state.all_field_cards():
		if bool(eb.flags.get("end_bounce_if_refreshed", false)) and eb.is_refreshed():
			effects._return_to_hand(eb)
	# 6-8-1-2: "during this turn" effects switch off now.
	effects.expire_duration("turn")
	effects.expire_through_turn(state.turn_number)    # "until the end of your opponent's next turn" (0.15.0)
	state.turn_flags.clear()                          # per-turn player flags (0.11.0)
	# "this turn" rules and triggers from resolved effects end (0.15.0)
	state.turn_rules.clear()
	state.delayed = state.delayed.filter(func(e: Dictionary) -> bool: return str(e.get("duration", "turn")) != "turn")
	run_checkpoints()
	state.turn_player = state.opponent_of(state.turn_player)
	if not state.game_over:
		_begin_turn()


# ===========================================================================
# Action entry point
# ===========================================================================

## The one door into the engine. Returns {ok:bool, reason:String}.
func submit(pid: int, action: Dictionary) -> Dictionary:
	if state.game_over:
		return _err("the game is over")
	var verb := str(action.get("verb", ""))

	# Conceding is unconditional and unstoppable (1-2-4, 1-2-5).
	if verb == BSS.Action.CONCEDE:
		state.player(pid).conceded = true
		_declare_winner(state.opponent_of(pid), "concession")
		return _ok()

	# A parked choice blocks everything else from the player who owes an answer.
	if not state.pending_choice.is_empty():
		if verb != BSS.Action.RESOLVE_CHOICE and verb != BSS.Action.MULLIGAN \
				and verb != BSS.Action.KEEP_HAND and verb != BSS.Action.CHOOSE_ORDER \
				and verb != BSS.Action.ACTIVATE_BURST \
				and verb != BSS.Action.DECLINE_BURST:
			return _err("resolve the pending choice first")

	var result: Dictionary
	match verb:
		BSS.Action.CHOOSE_ORDER:
			result = _act_choose_order(pid, action)
		BSS.Action.MULLIGAN, BSS.Action.KEEP_HAND:
			result = _act_mulligan(pid, verb == BSS.Action.MULLIGAN)
		BSS.Action.RESOLVE_CHOICE:
			result = _act_resolve_choice(pid, action)
		BSS.Action.SUMMON:
			result = _act_summon(pid, action)
		BSS.Action.PLACE:
			result = _act_place(pid, action)
		BSS.Action.USE_MAGIC:
			result = _act_use_magic(pid, action)
		BSS.Action.SET_BURST:
			result = _act_set_burst(pid, action)
		BSS.Action.MOVE_CORE:
			result = _act_move_core(pid, action)
		BSS.Action.ACTIVATE:
			result = _act_activate(pid, action)
		BSS.Action.END_MAIN:
			result = _act_end_main(pid)
		BSS.Action.DECLARE_ATTACK:
			result = _act_declare_attack(pid, action)
		BSS.Action.DECLARE_BLOCK:
			result = _act_declare_block(pid, action)
		BSS.Action.DECLINE_BLOCK:
			result = _act_decline_block(pid)
		BSS.Action.FLASH_PASS:
			result = _act_flash_pass(pid)
		BSS.Action.END_ATTACK:
			result = _act_end_attack(pid)
		BSS.Action.ACTIVATE_BURST:
			result = keywords.activate_burst(pid, int(action.get("uid", -1)))
		BSS.Action.DECLINE_BURST:
			state.pending_choice = {}
			result = _ok()
		_:
			result = _err("unknown action '%s'" % verb)

	if result.get("ok", false):
		state.action_log.append({"pid": pid, "action": action})
		run_checkpoints()
		keywords.flush_pending_bursts()                # bursts that waited for a prompt (0.16.7)
		_resume_steps()
		keywords.offer_pending_links()                 # 11-18 Link, once nothing else waits (0.15.0)
		state_changed.emit()
	return result


func _ok() -> Dictionary: return {"ok": true, "reason": ""}
func _err(msg: String) -> Dictionary: return {"ok": false, "reason": msg}


func _act_mulligan(pid: int, do_mull: bool) -> Dictionary:
	if str(state.pending_choice.get("type", "")) != "mulligan":
		return _err("not a mulligan window")
	if int(state.pending_choice.get("player", -1)) != pid:
		return _err("not your decision")
	_finish_mulligans(pid, do_mull)
	return _ok()


func _act_resolve_choice(pid: int, action: Dictionary) -> Dictionary:
	if state.pending_choice.is_empty():
		return _err("nothing to choose")
	if int(state.pending_choice.get("player", -1)) != pid:
		return _err("not your choice")
	var choice = action.get("choice", null)
	var pc := state.pending_choice
	state.pending_choice = {}
	return effects.deliver_choice(pid, pc, choice)


# ---------------------------------------------------------------------------
# 6-6 Main step actions
# ---------------------------------------------------------------------------

func _main_ok(pid: int) -> bool:
	return state.step == BSS.Step.MAIN and pid == state.turn_player \
		and state.effect_stack.is_empty()


## 2-7-3 / 10-6-5 -- cost after reduction. Each printed reduction symbol can be
## satisfied at most once, and only by a matching colour actually on the field.
## Each printed reduction icon must be matched to a DISTINCT symbol on the
## field, and a double-colour symbol may be declared as either of its colours
## but only once (2-8-2-2). Greedily walking the icons left to right gets this
## wrong: with icons [RED, BLUE] and a field holding one RED|BLUE symbol and one
## plain BLUE, a greedy pass spends the double symbol on RED, then finds BLUE
## still available and claims a reduction of 2 -- correct here, but reverse the
## icon order and the same pass spends the plain BLUE first and still claims 2
## while a single RED|BLUE symbol alone would also claim 2. The reliable answer
## is a maximum bipartite matching between icons and field symbols, which is
## small enough (icons cap at ~5) that Kuhn's algorithm is instant.
func compute_cost(pid: int, cd: CardData) -> int:
	# "You may use magic cards from your hand without paying their cost"
	if cd.is_magic() and not effects.active_rules(pid, "free_magic").is_empty():
		return 0
	var groups := _cost_symbol_groups(pid, cd)
	var base := cd.cost
	# "This card costs 4 in your hand if you control a nexus" (0.11.0)
	for e: Dictionary in cd.effects:
		if str(e.get("timing", "")) != "cost":
			continue
		if e.has("condition") and not effects.check_condition(pid, e["condition"], {"source": -1, "controller": pid}):
			continue
		base = mini(base, int(e.get("cost", base)))
		# "reduce its cost by 2 for each card in your trash with Astral" (0.15.0, BSS06-016)
		if e.has("cost_minus_per"):
			var cmp: Dictionary = e["cost_minus_per"]
			base -= int(cmp.get("amount", 1)) * effects.collect_targets(pid, cmp.get("per", {}),
					{"source": -1, "controller": pid}).size()
		# "This card costs 4 in your hand when you use it during your main
		# step" (0.15.0, BSS04-124)
		if e.has("set_cost") and (not e.has("during") or effects.during_ok(str(e["during"]), pid)):
			base = mini(base, int(e["set_cost"]))
	# "When you summon a Star Dragon card, count each symbol on this spirit
	# as two symbols" (0.11.0): that card's symbols are counted again.
	for r: Dictionary in effects.active_rules(pid, "double_symbols"):
		var d: Dictionary = r["d"]
		var f: Dictionary = d.get("for", {})
		# 0.14.0: "for" may name a card type or a minimum cost; "from" names
		# whose symbols count double; "extra" how many more times they count.
		if f.has("card_type") and BSS.card_type_from_string(str(f["card_type"])) != cd.card_type:
			continue
		if f.has("cost_min") and cd.cost < int(f["cost_min"]):
			continue
		if d.has("from"):
			var fw := str((d["from"] as Dictionary).get("spirit_type", "")).to_lower()
			for fu2 in state.player(pid).field:
				var fc2: CardInstance = state.cards.get(fu2)
				if fc2 == null:
					continue
				for st7 in fc2.data.spirit_types:
					if st7.to_lower() == fw:
						for g7 in fc2.symbol_groups(): groups.append(g7)
			continue
		if f.has("spirit_type"):
			var want := str(f["spirit_type"]).to_lower()
			var ok := false
			for st in cd.spirit_types:
				if st.to_lower() == want: ok = true
			if not ok:
				continue
		# "When you summon a Terrasaur or Dragonoid spirit" (0.15.0, BSS03-012)
		if f.has("spirit_types"):
			var ok2 := false
			for want2: Variant in f["spirit_types"]:
				for st2 in cd.spirit_types:
					if st2.to_lower() == str(want2).to_lower(): ok2 = true
			if not ok2:
				continue
		for _x in int(d.get("extra", 1)):
			for g in (r["source"] as CardInstance).symbol_groups():
				groups.append(g)
	var icons: Array = []
	for ic in cd.reduction_symbols:
		icons.append(ic)
	# ---- 0.14.0 (Set 1) cost rules ----
	var me := state.player(pid)
	if cd.is_spirit() and state.turn_flag(pid, "star_dragon_cost_life"):
		for st0 in cd.spirit_types:
			if st0.to_lower() == "star dragon":
				base = me.life_total()                 # "costs equal to your life total"
	# "The next red spirit card with Ascend you summon this turn will have a
	# cost equal to your life total" (0.15.0, BSS04-005; used up by do_summon)
	if _next_red_ascend(pid, cd):
		base = me.life_total()
	for e2: Dictionary in cd.effects:
		if str(e2.get("timing", "")) != "cost":
			continue
		# "count each symbol on your Terrasaur or Emperor Beast spirits as two"
		if e2.has("double_symbols_of"):
			var types: Array = (e2["double_symbols_of"] as Dictionary).get("spirit_types", [])
			for fu in me.field:
				var fc: CardInstance = state.cards.get(fu)
				if fc == null or not fc.data.is_spirit():
					continue
				var hitt := false
				for t5: Variant in types:
					for st5 in fc.data.spirit_types:
						if st5.to_lower() == str(t5).to_lower(): hitt = true
				if hitt:
					for g5 in fc.symbol_groups(): groups.append(g5)
		# "the symbols of spirit cards that cost 2 in your trash"
		if e2.has("trash_symbols"):
			var ts: Dictionary = e2["trash_symbols"]
			for tu in me.trash:
				var tc: CardInstance = state.cards.get(tu)
				if tc != null and tc.data.is_spirit() and tc.data.cost >= int(ts.get("cost_min", 0)) \
						and tc.data.cost <= int(ts.get("cost_max", 99)):
					for g6 in tc.data.symbols: groups.append(g6)
	if cd.is_magic():
		for r6: Dictionary in effects.active_rules(pid, "extra_reduction"):
			icons.append(BSS.color_from_string(str((r6["d"] as Dictionary).get("color", "yellow"))))
		if not state.turn_flag(pid, "magic_used"):
			for r7: Dictionary in effects.active_rules(pid, "magic_discount"):
				base -= int((r7["d"] as Dictionary).get("amount", 1))
		# "the next yellow magic card you use from your hand costs 1 less" (0.15.0, BSS03-036)
		var nmd := _next_magic_discount(pid, cd)
		if nmd >= 0:
			base -= int(((state.turn_flags.get("%d:next_magic_discount" % pid, []) as Array)[nmd] as Dictionary)["amount"])
	var reduction := _match_icons(icons, groups)
	# 継召 / Inherit (0.19.1): EX symbols on cards in your trash may pay the
	# icons the field leaves unpaid; those cards leave the game when the
	# summon is paid (do_summon). See _inherit_plan.
	if reduction < icons.size():
		for iu in _inherit_plan(pid, cd, icons, groups):
			var ic2: CardInstance = state.cards.get(iu)
			if ic2 != null:
				for xc in ic2.data.ex_symbols:
					groups.append([xc])
		reduction = _match_icons(icons, groups)
	# "If you have 3 or fewer life, you may treat all of this card's reduction
	# symbols as fulfilled" (0.15.0, BSS04-002)
	for e3: Dictionary in cd.effects:
		if str(e3.get("timing", "")) == "cost" and bool(e3.get("full_reduction", false)) and \
				(not e3.has("condition") or effects.check_condition(pid, e3["condition"], {"source": -1, "controller": pid})):
			reduction = maxi(reduction, cd.reduction_symbols.size())
	return max(base - reduction, 0)


## The symbols on `pid`'s field that may pay `cd`'s reduction icons, one group
## per symbol (a split two-colour symbol is one group of both colours). Rules
## that widen or replace symbols for this card are applied here:
##   * symbol_also (0.12.0): the source's symbol also counts as more colours;
##     "also_from" widens your other matching cards too (0.15.0, BSS06-091);
##   * count_symbols_as (0.15.0, BSS06-090): "treat this nexus as having two
##     white symbols" when summoning a matching card;
##   * the card's own cost keys (0.15.0): only_symbols_of (BSS06-043: only your
##     Wanderfae / Supsprite spirits' symbols count) and symbols_as (BSS06-053 /
##     -076: your Link spirits' symbols also count as white or purple).
func _cost_symbol_groups(pid: int, cd: CardData) -> Array:
	var widen := {}                                     # uid -> extra colours
	var replace := {}                                   # uid -> replacement groups
	if not cd.is_magic():
		for r: Dictionary in effects.active_rules(pid, "symbol_also"):
			var dd: Dictionary = r["d"]
			var ff: Dictionary = dd.get("for", {})
			if ff.has("spirit_type"):
				var fits := false
				for t: String in cd.spirit_types:
					if t.to_lower() == str(ff["spirit_type"]).to_lower():
						fits = true
				if not fits:
					continue
			var extra: Array = []
			for c: Variant in dd.get("colors", []):
				extra.append(BSS.color_from_string(str(c)))
			var su := (r["source"] as CardInstance).uid
			widen[su] = (widen.get(su, []) as Array) + extra
			if dd.has("also_from"):
				var af: Dictionary = dd["also_from"]
				for fc0 in state.all_field_cards():
					if fc0.controller_id == pid and effects._passes_filter(pid, fc0, {"filters": af.get("filters", {}),
							"card_type": af.get("card_type", ""), "count": 0}, {"source": su, "controller": pid}):
						widen[fc0.uid] = (widen.get(fc0.uid, []) as Array) + extra
	for r2: Dictionary in effects.active_rules(pid, "count_symbols_as"):
		var d2: Dictionary = r2["d"]
		var f2: Dictionary = d2.get("for", {})
		if f2.has("card_type") and BSS.card_type_from_string(str(f2["card_type"])) != cd.card_type:
			continue
		var gl: Array = []
		for g0: Variant in d2.get("groups", []):
			var gg: Array = []
			for c0: Variant in (g0 as Array if typeof(g0) == TYPE_ARRAY else [g0]):
				gg.append(BSS.color_from_string(str(c0)))
			gl.append(gg)
		for t2 in effects.collect_targets(pid, d2.get("target", {"zone": "self"}),
				{"source": (r2["source"] as CardInstance).uid, "controller": pid}):
			replace[t2.uid] = gl
	var only_types: Array = []
	var as_cols: Array = []
	var as_from: Array = []
	for e: Dictionary in cd.effects:
		if str(e.get("timing", "")) != "cost":
			continue
		if e.has("only_symbols_of"):
			only_types = (e["only_symbols_of"] as Dictionary).get("spirit_types", [])
		if e.has("symbols_as"):
			var sa: Dictionary = e["symbols_as"]
			for c3: Variant in sa.get("colors", []):
				as_cols.append(BSS.color_from_string(str(c3)))
			as_from = sa.get("from", [])
	var groups: Array = []
	for uid in state.player(pid).field:
		var fc: CardInstance = state.cards.get(uid)
		if fc == null:
			continue
		if not only_types.is_empty():
			var fam_ok := false
			for ot: Variant in only_types:
				if fc.data != null and fc.data.is_spirit() and fc.has_family(str(ot)):
					fam_ok = true
			if not fam_ok:
				continue
		var extra2: Array = widen.get(uid, [])
		if not as_from.is_empty():
			for af2: Variant in as_from:
				var afd: Dictionary = af2
				if effects._passes_filter(pid, fc, {"filters": afd.get("filters", {}), "card_type": afd.get("card_type", ""),
						"count": 0}, {"source": -1, "controller": pid}):
					extra2 = extra2 + as_cols
					break
		for g in (replace[uid] if replace.has(uid) else fc.symbol_groups()):
			var g2: Array = (g as Array).duplicate()
			for c2: Variant in extra2:
				if not g2.has(c2):
					g2.append(c2)
			groups.append(g2)
	return groups


## "This turn, when your opponent uses a magic card from their hand, they must
## pay three cores as an additional cost" (0.15.0, BSS05-100).
func magic_core_tax(pid: int) -> int:
	var n := 0
	for r: Dictionary in effects.active_rules(state.opponent_of(pid), "magic_core_tax"):
		n += int((r["d"] as Dictionary).get("amount", 1))
	return n


## "This turn, spirits with 2000 BP or less cannot attack" (0.15.0, BSS05-127): either player's rule.
func attack_banned(ci: CardInstance) -> bool:
	for p in 2:
		for r: Dictionary in effects.active_rules(p, "attack_ban"):
			if ci.current_bp() <= int((r["d"] as Dictionary).get("bp_max", 0)):
				return true
	return false


## BSS04-005's "next red spirit card with Ascend" discount applies to `cd` (0.15.0).
func _next_red_ascend(pid: int, cd: CardData) -> bool:
	if cd == null or not cd.is_spirit() or not cd.has_color(BSS.CardColor.RED) \
			or not state.turn_flag(pid, "next_red_ascend_cost_life"):
		return false
	for e: Dictionary in cd.effects:
		if BSS.keyword_from_string(str(e.get("keyword", ""))) == BSS.Keyword.ASCEND:
			return true
	return false


## Kuhn's augmenting-path step: try to seat reduction icon `icon_idx` on some
## field symbol. If every symbol it could use is taken, an already-seated icon
## is asked to move aside; it does so only when it can find another symbol of
## its own colour, so a seat is never stolen in a way that loses a reduction.
## The card's printed reduction icons as a plain Array (for _inherit_plan).
func _cost_icons(cd: CardData) -> Array:
	var icons: Array = []
	for ic in cd.reduction_symbols:
		icons.append(ic)
	return icons


## How many of `icons` the symbol `groups` can pay (a maximum matching).
func _match_icons(icons: Array, groups: Array) -> int:
	var match_for_group := {}          # group index -> icon index
	var reduction := 0
	for i in icons.size():
		var seen := {}
		if _augment(icons, i, groups, match_for_group, seen):
			reduction += 1
	return reduction


## 継召 / Inherit (0.19.1, Japanese Standard 2026). Rules manual (Standard),
## "特殊な効果": when paying the card's cost you may remove from the game
## cards with EX symbols in your trash; their symbols count toward the
## card's reduction like symbols on your field, no more cards than the card
## has reduction icons, and never a card whose EX symbol's colour matches no
## icon. Our simplification: the removal is automatic and minimal -- only as
## many cards as pay icons the field's symbols leave unpaid (the player never
## loses a trash card for nothing). Returns the trash uids that will be
## removed, oldest first, deterministic for the same state (compute_cost and
## do_summon must agree).
func _inherit_plan(pid: int, cd: CardData, icons: Array, field_groups: Array) -> Array:
	var out: Array = []
	if not cd.has_keyword(BSS.Keyword.INHERIT) or icons.is_empty():
		return out
	var groups := field_groups.duplicate()
	var have := _match_icons(icons, groups)
	if have >= icons.size():
		return out
	for tu in state.player(pid).trash:
		if out.size() >= icons.size() or have >= icons.size():
			break
		var tc: CardInstance = state.cards.get(tu)
		if tc == null or tc.data == null or tc.data.ex_symbols.is_empty():
			continue
		var useful := false
		for xc in tc.data.ex_symbols:
			if xc in icons:
				useful = true
		if not useful:
			continue
		var trial := groups.duplicate()
		for xc in tc.data.ex_symbols:
			trial.append([xc])
		var now := _match_icons(icons, trial)
		if now > have:
			groups = trial
			have = now
			out.append(tu)
	return out


func _augment(icons: Array, icon_idx: int, groups: Array,
		match_for_group: Dictionary, seen: Dictionary) -> bool:
	var col := int(icons[icon_idx])
	for g in groups.size():
		if seen.has(g) or not (col in groups[g]):
			continue
		seen[g] = true
		if not match_for_group.has(g) \
				or _augment(icons, int(match_for_group[g]), groups, match_for_group, seen):
			match_for_group[g] = icon_idx
			return true
	return false


## 10-6-6 -- pay by sending cores to the trash from the field or the reserve.
## `payment` is a list of {"kind":..., ...} locations; when empty the engine
## auto-pays from the reserve, which is what the bot and quick-play use.
## A core location the player may pay from: their reserve or one of their
## own cards on the field (0.16.6).
func _own_loc(pid: int, loc: Variant) -> bool:
	if typeof(loc) != TYPE_DICTIONARY:
		return false
	var l: Dictionary = loc
	if str(l.get("kind", "")) == "card":
		var c: CardInstance = state.card(int(l.get("uid", -1)))
		return c != null and c.zone == BSS.Zone.FIELD and c.controller_id == pid
	return int(l.get("player", -1)) == pid and int(l.get("zone", -1)) == BSS.Zone.RESERVE


func _pay_cost(pid: int, amount: int, payment: Array) -> bool:
	if amount <= 0:
		return true
	var p := state.player(pid)
	var available := p.reserve_cores + p.reserve_soul
	for uid in p.field:
		available += state.cards[uid].cores
	if available < amount:
		return false
	var remaining := amount
	if payment.is_empty():
		# Automatic payment, in the order a player would choose:
		#   1. regular cores in the reserve
		#   2. the soul core in the reserve
		#   3. SPARE cores on the field -- ones above what each card needs to
		#      stay at level 1, so paying never quietly destroys a spirit
		#   4. only then, cores a card needs
		#
		# Before 0.6.0 step 2 was missing. The affordability check counted the
		# soul core but payment never took it, so with three cores and the soul
		# core in reserve, a cost of 4 moved three cores to the trash, ran short,
		# and rejected the summon -- having already spent the three cores
		# (R-024). Found by the BoardPlay test, which plays through the UI.
		var trash := GameState.pool(pid, BSS.Zone.TRASH)
		var reserve := GameState.pool(pid, BSS.Zone.RESERVE)
		remaining -= state.move_cores(reserve, trash, remaining)
		if remaining > 0 and p.reserve_soul > 0:
			remaining -= state.move_cores(reserve, trash, mini(remaining, p.reserve_soul), true, true)
		for uid in p.field.duplicate():
			if remaining <= 0:
				break
			var ci: CardInstance = state.cards[uid]
			var spare := ci.cores - (ci.data.min_level_cost() if ci.data != null else 0)
			if spare > 0:
				remaining -= state.move_cores(GameState.on_card(uid), trash, mini(spare, remaining))
		for uid in p.field.duplicate():
			if remaining <= 0:
				break
			remaining -= state.move_cores(GameState.on_card(uid), trash, remaining)
	else:
		# Check the chosen cores cover the cost BEFORE moving any (0.16.6):
		# a short payment used to spend what it had and then fail.
		var offered := 0
		for loc0 in payment:
			if not _own_loc(pid, loc0):
				continue
			var have := 0
			if str(loc0.get("kind", "")) == "card":
				var c0: CardInstance = state.card(int(loc0.get("uid", -1)))
				have = c0.total_cores()
			else:
				have = p.reserve_cores + p.reserve_soul
			offered += mini(int(loc0.get("n", 1)), have)
		if offered < amount:
			return false
		for loc in payment:
			if remaining <= 0: break
			if not _own_loc(pid, loc):
				continue                     # only your own reserve and cards (0.16.6)
			var n := int(loc.get("n", 1))
			remaining -= state.move_cores(loc, GameState.pool(pid, BSS.Zone.TRASH),
					min(n, remaining), bool(loc.get("soul", false)), true)
	return remaining <= 0


func _act_summon(pid: int, action: Dictionary) -> Dictionary:
	var uid := int(action.get("uid", -1))
	var ci: CardInstance = state.card(uid)
	if ci == null or ci.data == null or not ci.data.is_spirit():
		return _err("not a spirit card")
	if ci.controller_id != pid:
		return _err("not your card")
	if ci.zone != BSS.Zone.HAND:
		return _err("card is not in your hand")         # (0.15.0) a field card was accepted

	var is_flash := _in_flash_window(pid)
	if not _main_ok(pid):
		# 11-9 Swift is the only way to summon outside your own main step.
		if not (is_flash and ci.has_keyword(BSS.Keyword.SWIFT)):
			return _err("cannot summon right now")
	return do_summon(pid, ci, action, is_flash)


## 10-6 -- the summoning sequence, shared by hand summons, Swift, Immortal and
## any effect that summons a card from anywhere.
func do_summon(pid: int, ci: CardInstance, action: Dictionary = {}, swift: bool = false) -> Dictionary:
	var cost := compute_cost(pid, ci.data)             # 10-6-4, 10-6-5
	# "Your opponent cannot summon more than one spirit that costs 4 or less
	# each turn" (0.15.0, BSS03-103)
	if summon_blocked(pid, ci.data):
		return _err("you cannot summon another spirit like that this turn")
	# "As an additional summoning cost, you must destroy one of your blue
	# nexuses" (0.15.0, BSS03-097): checked first, paid with the cost.
	if not summon_cost_payable(pid, ci):
		return _err("cannot pay the additional summoning cost")

	# 11-8 Ascend adds a non-core cost that must be payable up front (8-4-2-3).
	var ascended_from := ""
	var asc: Dictionary = {}
	var red_ascend := _next_red_ascend(pid, ci.data)
	if ci.has_keyword(BSS.Keyword.ASCEND):
		asc = keywords.pay_ascend(pid, ci, action)
		if not asc["ok"]:
			return asc
		ascended_from = str(asc.get("from_name", ""))
	var souls_before := _soul_count(pid)
	var from_zone := ci.zone

	# 11-9-1 Swift restricts payment to reserve cores only.
	var payment: Array = action.get("payment", [])
	if swift and payment.is_empty():
		if state.player(pid).reserve_cores + state.player(pid).reserve_soul < cost:
			return _err("Swift may only spend cores from the reserve")
	# Inherit (0.19.1): decide which trash cards pay before anything moves
	var inherit_uids := _inherit_plan(pid, ci.data, _cost_icons(ci.data), _cost_symbol_groups(pid, ci.data))
	if not _pay_cost(pid, cost, payment):
		return _err("cannot pay the summoning cost (%d)" % cost)
	_pay_summon_cost(pid, ci, action)
	for iu in inherit_uids:
		state.move_card(int(iu), BSS.Zone.REMOVED, pid)
		state.log_event("inherit", {"uid": int(iu), "player": pid, "for": ci.uid})
	note_summon(pid, ci.data)

	state.move_card(ci.uid, BSS.Zone.FIELD, pid)       # 10-6-7
	# "If you spend a soul core as part of this spirit's summoning cost" and
	# "when this spirit performs Ascend using a 'Siegwurm'" (0.14.0)
	if _soul_count(pid) < souls_before:
		ci.flags["soul_paid"] = true
	if ascended_from != "":
		ci.flags["ascended_from"] = ascended_from
		ci.flags["ascended_cost"] = int(asc.get("from_cost", -1))     # (0.15.0, BSS04-001)
	if red_ascend:
		state.set_turn_flag(pid, "next_red_ascend_cost_life", false)  # used up (0.15.0, BSS04-005)
	# "If this spirit was summoned from the trash" (BSS04-020) / "summoned
	# with Swift" (BSS04-078) -- 0.15.0
	ci.flags["summoned_from"] = ["deck", "hand", "trash"][from_zone] if from_zone <= BSS.Zone.TRASH else ""
	if swift and ci.has_keyword(BSS.Keyword.SWIFT) and str(action.get("via", "")) != "effect":
		ci.flags["summoned_with"] = "Swift"

	# Place at least enough cores for the lowest level.
	var need := ci.data.min_level_cost()
	var extra := int(action.get("extra_cores", 0))
	var src := GameState.pool(pid, BSS.Zone.RESERVE)
	# "lv1_from" (0.16.6): the player chose which cards the new spirit's
	# level cores come from (when the reserve is short); the rest come from
	# the reserve as before.
	var still := need + extra
	for loc: Dictionary in action.get("lv1_from", []):
		if still <= 0:
			break
		if (str(loc.get("kind", "")) == "card" and int(loc.get("uid", -1)) == ci.uid) or not _own_loc(pid, loc):
			continue
		still -= state.move_cores(loc, GameState.on_card(ci.uid), mini(int(loc.get("n", 1)), still),
				bool(loc.get("soul", false)), true)
	state.move_cores(src, GameState.on_card(ci.uid), still, false, true)
	ci.summoned_this_turn = true
	state.log_event("summon", {"player": pid, "uid": ci.uid, "cost": cost})

	# "When you use this spirit to perform Ascend" (0.15.0, BSS04-039 / -053 /
	# -088): the stripped spirit is still on the field, with no cores, until
	# the next checkpoint destroys it.
	if int(asc.get("from_uid", -1)) >= 0:
		effects.trigger("used_for_ascend", {"uid": int(asc["from_uid"]), "player": pid, "ascender": ci.uid})
		# the stripped spirit is gone (9-3) before any When Summoned effect
		# resolves -- "destroy all spirits with one symbol" must not count it
		if effects._depth == 0:
			run_checkpoints()
	effects.trigger("on_summon", {"uid": ci.uid, "player": pid})
	# "[Burst: When Opponent Resolves a Spirit's When Summoned Effect]" (0.11.0)
	if ci.has_timing("on_summon") and state.pending_choice.is_empty():
		keywords.offer_bursts(state.opponent_of(pid), "opponent_summon_effect")
	return _ok()


func _act_place(pid: int, action: Dictionary) -> Dictionary:
	if not _main_ok(pid):
		return _err("nexuses may only be placed during your main step")
	var ci: CardInstance = state.card(int(action.get("uid", -1)))
	if ci == null or ci.data == null or not ci.data.is_nexus():
		return _err("not a nexus card")
	if ci.zone != BSS.Zone.HAND or ci.controller_id != pid:
		return _err("card is not in your hand")
	var cost := compute_cost(pid, ci.data)             # 10-7-5
	if not _pay_cost(pid, cost, action.get("payment", [])):
		return _err("cannot pay the placing cost (%d)" % cost)
	state.move_card(ci.uid, BSS.Zone.FIELD, pid)
	state.move_cores(GameState.pool(pid, BSS.Zone.RESERVE), GameState.on_card(ci.uid),
			ci.data.min_level_cost() + int(action.get("extra_cores", 0)), false, true)
	state.log_event("place", {"player": pid, "uid": ci.uid, "cost": cost})
	effects.trigger("on_place", {"uid": ci.uid, "player": pid})
	return _ok()


func _act_use_magic(pid: int, action: Dictionary) -> Dictionary:
	var ci: CardInstance = state.card(int(action.get("uid", -1)))
	if ci == null or ci.data == null or not ci.data.is_magic():
		return _err("not a magic card")
	if ci.zone != BSS.Zone.HAND or ci.controller_id != pid:
		return _err("card is not in your hand")
	var eff_idx := int(action.get("effect", 0))        # 10-8-3 pick one usable effect
	var spec: Dictionary = ci.data.effects[eff_idx] if eff_idx < ci.data.effects.size() else {}
	var window := str(spec.get("window", "main"))
	var is_flash := _in_flash_window(pid)
	if is_flash:
		if window != "flash" and window != "both":
			return _err("that magic effect is not a flash effect")
	elif not _main_ok(pid):
		return _err("cannot use magic right now")
	elif window != "main" and window != "both":
		return _err("that magic effect is flash-only")

	var cost := compute_cost(pid, ci.data)             # 10-8-5
	# "Your opponent cannot use magic cards from their hand that do not share a
	# colour with any symbol on their field" (0.15.0, BSS03-117)
	if magic_locked(pid, ci.data):
		return _err("that magic card shares no colour with a symbol on your field")
	# "When your opponent uses a magic card from their hand, they must discard
	# a card as an additional cost" (0.15.0)
	var tax := magic_discard_tax(pid)
	if tax > 0 and state.player(pid).hand.size() - 1 < tax:
		return _err("you must discard %d card(s) to use magic" % tax)
	var souls_before := _soul_count(pid)
	cost += magic_core_tax(pid)                        # BSS05-100 (0.15.0)
	if not _pay_cost(pid, cost, action.get("payment", [])):
		return _err("cannot pay the use cost (%d)" % cost)
	var soul_spent := _soul_count(pid) < souls_before
	if tax > 0:
		_pay_discard_tax(pid, ci.uid, tax, action.get("discard", []))
	# the "next magic card costs 1 less" discount is used up (0.15.0, BSS03-036)
	var nmd := _next_magic_discount(pid, ci.data)
	if nmd >= 0:
		(state.turn_flags["%d:next_magic_discount" % pid] as Array).remove_at(nmd)

	# 10-8-7: the card waits in limbo -- still nominally in the hand, but not
	# counted there and invisible to other effects until resolution finishes.
	ci.flags["resolving"] = true
	if soul_spent:
		ci.flags["soul_paid"] = true                  # "if you spent a soul core on this card's cost"
	state.set_turn_flag(pid, "magic_used")            # "the first magic card you use each turn" (0.14.0)
	var mck := "%d:magic_count" % pid                 # how many this turn (0.15.0, BSS04-043)
	state.turn_flags[mck] = int(state.turn_flags.get(mck, 0)) + 1
	state.log_event("use_magic", {"player": pid, "uid": ci.uid, "cost": cost})
	# "When you spend a soul core as part of a magic card's cost" / "when you
	# use a magic card from your hand, ... after its effect resolves": fired by
	# EffectSystem._finish_frame once the magic has resolved (0.15.0; before,
	# they fired here even while the magic waited on a choice).
	effects.push(ci, spec, pid, {"magic": true, "from_hand": true, "soul_spent": soul_spent})
	if is_flash:
		state.flash_passes = 0                         # 7-1-2-1 an action resets the pass count
		state.flash_priority = state.opponent_of(pid)
	effects.resolve_top()
	return _ok()


## Cards `pid` must discard to use a magic card, from the opponent's
## magic_discard_tax rules (0.15.0).
func magic_discard_tax(pid: int) -> int:
	return effects.active_rules(state.opponent_of(pid), "magic_discard_tax").size()


## Discards the chosen cards, or else the cheapest other cards in hand.
func _pay_discard_tax(pid: int, magic_uid: int, n: int, chosen: Array) -> void:
	var hand: Array = state.player(pid).hand.filter(func(u: int) -> bool: return u != magic_uid)
	var picks: Array = []
	for u: Variant in chosen:
		if hand.has(int(u)) and picks.size() < n:
			picks.append(int(u))
	hand.sort_custom(func(a: int, b: int) -> bool: return state.cards[a].data.cost < state.cards[b].data.cost)
	for u2: int in hand:
		if picks.size() >= n:
			break
		if not picks.has(u2):
			picks.append(u2)
	for u3: int in picks:
		state.move_card(u3, BSS.Zone.TRASH, pid)
	state.log_event("discard", {"player": pid, "uids": picks, "reason": "magic tax"})
	effects.note_discarded(picks, pid, pid)            # (0.15.0)


func _soul_count(pid: int) -> int:
	var n := state.player(pid).reserve_soul
	for uid in state.player(pid).field:
		n += state.cards[uid].soul_cores
	return n


func _act_set_burst(pid: int, action: Dictionary) -> Dictionary:
	if not _main_ok(pid):
		return _err("bursts may only be set during your main step")
	var ps := state.player(pid)
	if ps.bursts_set_this_turn >= BSS.MAX_BURST_SET_PER_TURN:
		return _err("you have already set a burst this turn")   # 6-6-1-2-2
	var ci: CardInstance = state.card(int(action.get("uid", -1)))
	if ci == null or ci.zone != BSS.Zone.HAND or ci.controller_id != pid:
		return _err("card is not in your hand")
	if not ci.data.has_burst:
		return _err("that card has no burst effect")            # 3-8-4
	state.move_card(ci.uid, BSS.Zone.BURST, pid)
	ps.bursts_set_this_turn += 1
	return _ok()


## 6-6-1-2-3 -- free core rearrangement during your own main step.
func _act_move_core(pid: int, action: Dictionary) -> Dictionary:
	if not _main_ok(pid):
		return _err("cores may only be rearranged during your main step")
	var from_loc: Dictionary = action.get("from", {})
	var to_loc: Dictionary = action.get("to", {})
	if not _core_loc_belongs(pid, from_loc) or not _core_loc_belongs(pid, to_loc):
		return _err("you may only move your own cores on your own field/reserve")
	state.move_cores(from_loc, to_loc, int(action.get("n", 1)),
			bool(action.get("soul", false)), true)
	return _ok()


func _core_loc_belongs(pid: int, loc: Dictionary) -> bool:
	if loc.get("kind", "") == "card":
		var ci: CardInstance = state.card(int(loc.get("uid", -1)))
		return ci != null and ci.zone == BSS.Zone.FIELD and ci.controller_id == pid
	return int(loc.get("player", -1)) == pid and int(loc.get("zone", -1)) == BSS.Zone.RESERVE


## 8-1-3 -- activated effects, including the Awaken keyword.
func _act_activate(pid: int, action: Dictionary) -> Dictionary:
	var ci: CardInstance = state.card(int(action.get("uid", -1)))
	if ci == null or ci.controller_id != pid:
		return _err("not your card")
	var idx := int(action.get("effect", 0))
	if str(action.get("keyword", "")) == "awaken":
		# 11-1 Awaken is used in your main step or in a flash window; a use
		# in a flash window is an action, so priority passes (7-1-2-1). 0.16.6
		var in_flash := _in_flash_window(pid)
		if not in_flash and not _main_ok(pid):
			return _err("Awaken can be used in your main step or at flash timing")
		var ar := keywords.awaken(pid, ci, action)
		if ar["ok"] and in_flash:
			state.flash_passes = 0
			state.flash_priority = state.opponent_of(pid)
		if ar["ok"]:
			run_checkpoints()
		return ar
	var specs := ci.active_effects()
	if idx >= specs.size():
		return _err("no such effect")
	var spec: Dictionary = specs[idx]
	var window := str(spec.get("window", "main"))
	var is_flash := _in_flash_window(pid)
	if spec.has("during") and not effects.during_ok(str(spec["during"]), pid):
		return _err("not usable right now")             # 0.15.0
	if is_flash and window != "flash" and window != "both":
		return _err("not a flash effect")
	if not is_flash and not _main_ok(pid):
		return _err("cannot activate right now")
	if not effects.pay_effect_cost(pid, ci, spec, action):
		return _err("cannot pay the effect cost")      # 8-4-2-4
	effects.push(ci, spec, pid, {})
	if is_flash:
		state.flash_passes = 0
		state.flash_priority = state.opponent_of(pid)
	effects.resolve_top()
	return _ok()


func _act_end_main(pid: int) -> Dictionary:
	if not _main_ok(pid):
		return _err("not your main step")
	_set_step(BSS.Step.ATTACK)
	_run_step()
	return _ok()


# ===========================================================================
# SECTION 7 -- Attacking and battles
# ===========================================================================

func _act_declare_attack(pid: int, action: Dictionary) -> Dictionary:
	if state.step != BSS.Step.ATTACK or pid != state.turn_player:
		return _err("not your attack step")
	if not state.battle.is_empty():
		return _err("a battle is already in progress")
	if not state.effect_stack.is_empty():
		return _err("resolve pending effects first")
	var ci: CardInstance = state.card(int(action.get("uid", -1)))
	if ci == null or ci.zone != BSS.Zone.FIELD or ci.controller_id != pid:
		return _err("not a spirit you control")
	if not ci.data.is_spirit():
		return _err("only spirits attack")
	if not ci.is_refreshed():
		return _err("that spirit is exhausted")        # 7-1-1-1
	if bool(ci.flags.get("no_attack", false)):
		return _err("that spirit cannot attack this turn")
	if effects.rule_applies(ci, "cannot_attack"):
		return _err("that spirit cannot attack")      # "This spirit cannot attack." (0.12.0)
	if attack_banned(ci):
		return _err("spirits with that little BP cannot attack this turn")    # BSS05-127 (0.15.0)
	if state.turn_flag(pid, "attack_step_closed"):
		return _err("the attack step has ended")
	# "Your opponent's spirits that cost 3 or less cannot attack unless their
	# controller pays one core" (0.15.0, BSS03-084 / BSS03-118)
	var acost := attack_cost(ci)
	if acost > 0:
		if not effects._pay_cores_any(pid, acost):
			return _err("attacking with that spirit costs %d core(s)" % acost)
		state.log_event("attack_cost", {"uid": ci.uid, "n": acost})
		run_checkpoints()
		if ci.zone != BSS.Zone.FIELD:
			return _ok()                               # it paid with its last core
	# "Your opponent cannot attack with a spirit unless they remove a core
	# from it and place it into their reserve" (0.11.0)
	if state.turn_flag(pid, "attack_tax"):
		if ci.total_cores() < 1:
			return _err("attacking costs a core from the spirit this turn")
		state.move_cores(GameState.on_card(ci.uid), GameState.pool(pid, BSS.Zone.RESERVE), 1, false, true)
		state.log_event("attack_tax", {"uid": ci.uid})
		run_checkpoints()
		if ci.zone != BSS.Zone.FIELD:
			return _ok()                               # it paid with its last core

	ci.orientation = BSS.Orientation.EXHAUSTED
	state.battle = {
		"attacker": ci.uid,
		"blocker": -1,
		"attacking_player": pid,
		"defending_player": state.opponent_of(pid),
		"phase": BSS.BattlePhase.ATTACK_DECLARED,
		"magic_used": [],                              # 11-6 Luster bookkeeping
		"curse": false,                                # 11-3
		"forced_block": false,                         # 11-2
	}
	state.log_event("attack_declared", {"uid": ci.uid, "player": pid})
	state.turn_flags["%d:attacks" % pid] = int(state.turn_flags.get("%d:attacks" % pid, 0)) + 1

	# 7-1-1-2 -- "when attacking" triggers, then "while attacking" turns on.
	effects.set_active_window("while_attacking", ci.uid, true)
	effects.trigger("on_attack", {"uid": ci.uid, "player": pid})
	# "All of your spirits' When This Spirit Blocks effects also activate when
	# attacking" (0.11.0)
	# ... or "this turn" (turn flag, 0.15.0, BSS04-053)
	if (not effects.active_rules(pid, "blocks_on_attack").is_empty() or state.turn_flag(pid, "blocks_on_attack")) \
			and ci.has_timing("on_block"):
		effects.set_active_window("while_blocking", ci.uid, true)
		effects.trigger("on_block", {"uid": ci.uid, "player": pid})
	keywords.on_attack(ci)
	# "This turn, your spirits with Curse gain: When Attacks, you may attack
	# one of your opponent's exhausted spirits" (Poison Mist, 0.14.0)
	if state.turn_flag(pid, "curse_attacks_exhausted") and ci.has_keyword(BSS.Keyword.CURSE):
		effects.push(ci, {"kind": "triggered", "timing": "on_attack", "directives": [{"op": "attack_spirit",
				"optional": true, "target": {"controller": "opponent", "zone": "field", "card_type": "spirit",
				"count": 1, "filters": {"exhausted": true}}}]}, pid, {})

	# 11-2 Confront is a constant effect evaluated at block declaration.
	state.battle["forced_block"] = ci.has_keyword(BSS.Keyword.CONFRONT)

	_open_flash_window(BSS.BattlePhase.FLASH_BEFORE_BLOCK, state.battle["defending_player"])
	return _ok()


## 7-1-2 / 7-1-4 -- flash windows. The named player acts first; the window ends
## after two consecutive passes.
func _open_flash_window(phase: int, first: int) -> void:
	state.battle["phase"] = phase
	state.flash_passes = 0
	state.flash_priority = first
	state.log_event("flash_open", {"phase": phase, "priority": first})
	# Bursts are offered at the moment their condition happens (0.11.0);
	# before, any set burst was offered at every flash window (I-010).


func _in_flash_window(pid: int) -> bool:
	if state.battle.is_empty():
		return false
	var ph := int(state.battle.get("phase", BSS.BattlePhase.NONE))
	if ph != BSS.BattlePhase.FLASH_BEFORE_BLOCK and ph != BSS.BattlePhase.FLASH_AFTER_BLOCK:
		return false
	return state.flash_priority == pid


func _act_flash_pass(pid: int) -> Dictionary:
	if not _in_flash_window(pid):
		return _err("not your flash priority")
	state.flash_passes += 1
	state.flash_priority = state.opponent_of(pid)
	if state.flash_passes >= 2:                        # 7-1-2-1
		_close_flash_window()
	return _ok()


func _close_flash_window() -> void:
	var ph := int(state.battle.get("phase", BSS.BattlePhase.NONE))
	state.flash_priority = -1
	if ph == BSS.BattlePhase.FLASH_BEFORE_BLOCK:
		# "You may attack that spirit" (0.14.0): it battles as if blocking.
		var ft: CardInstance = state.card(int(state.battle.get("forced_target", -1)))
		if ft != null and ft.zone == BSS.Zone.FIELD:
			state.battle["blocker"] = ft.uid
			state.log_event("attacked_spirit", {"uid": ft.uid})
			_open_flash_window(BSS.BattlePhase.FLASH_AFTER_BLOCK, int(state.battle["defending_player"]))
			return
		state.battle["phase"] = BSS.BattlePhase.BLOCK_DECLARATION
		var defender := int(state.battle["defending_player"])
		if _legal_blockers(defender).is_empty():
			_battle_resolution()                       # 7-1-3-1 no block possible
		else:
			state.log_event("block_window", {"player": defender})
	else:
		_battle_resolution()


## 7-1-3-1 with 11-14 Astral layered on: a spirit without Astral cannot block
## an attacker whose Astral is currently active.
func _legal_blockers(defender: int) -> Array:
	var out: Array = []
	var atk: CardInstance = state.card(int(state.battle.get("attacker", -1)))
	var astral_active := atk != null and keywords.astral_active(atk)
	if atk != null and bool(atk.flags.get("unblockable", false)):
		return out                                     # "cannot be blocked this turn" (0.14.0)
	for ci in state.field_spirits(defender):
		if not ci.is_refreshed() and not _may_block_exhausted(ci, atk):
			continue
		if effects.rule_applies(ci, "cannot_block"):
			continue                                   # "This spirit cannot block" (0.14.0)
		if astral_active and not ci.has_keyword(BSS.Keyword.ASTRAL):
			continue
		# "...cannot block this turn" (red, 0.10.0) is a turn-long flag.
		if bool(ci.flags.get("no_block", false)):
			continue
		# "Your yellow spirits cannot be blocked by spirits with When This
		# Spirit Blocks effects" (0.11.0)
		if atk != null and _block_forbidden(atk, ci):
			continue
		out.append(ci)
	return out


## "can block while exhausted" (Suppression), "can block your opponent's
## spirits with two or fewer cores even if exhausted" (Pegacyone) -- 0.14.0.
func _may_block_exhausted(ci: CardInstance, atk: CardInstance) -> bool:
	if bool(ci.flags.get("block_exhausted", false)):
		return true
	for r: Dictionary in effects.active_rules(ci.controller_id, "block_while_exhausted"):
		var d: Dictionary = r["d"]
		var who: Array = effects.collect_targets(ci.controller_id, d.get("target", {"zone": "self"}),
				{"source": (r["source"] as CardInstance).uid, "controller": ci.controller_id})
		if not who.has(ci) or atk == null:
			continue
		if effects._passes_filter(ci.controller_id, atk, {"filters": d.get("attacker", {})}, {}):
			return true
	return false


func _block_forbidden(atk: CardInstance, blocker: CardInstance) -> bool:
	# "cannot be blocked by spirits with any effects" (0.14.0)
	var ub: Variant = atk.flags.get("unblockable_by", null)
	if typeof(ub) == TYPE_DICTIONARY and effects._passes_filter(atk.controller_id, blocker, {"filters": ub, "count": 0}, {}):
		return true
	# "your spirits that cost 2 cannot be blocked by spirits at LV2 or higher"
	if state.turn_flag(atk.controller_id, "cost2_unblockable_lv2") and atk.data.cost == 2 \
			and blocker.current_level() >= 2:
		return true
	# "This turn, your spirits that cost 2 cannot be blocked by your opponent's
	# spirits with one core" (0.15.0, BSS05-123)
	if state.turn_flag(atk.controller_id, "cost2_unblockable_one_core") and atk.effective_cost() == 2 \
			and blocker.total_cores() == 1:
		return true
	# "... cannot be blocked by spirits of the colours named in any Armor they
	# have" (0.15.0, BSS04-062)
	if effects.rule_applies(atk, "unblockable_by_armor_colors"):
		var av: Variant = atk.keyword_value(BSS.Keyword.ARMOR)
		if typeof(av) == TYPE_ARRAY:
			for ac: Variant in av:
				if blocker.data.has_color(BSS.color_from_string(str(ac))):
					return true
	for r: Dictionary in effects.active_rules(atk.controller_id, "unblockable_by"):
		var d: Dictionary = r["d"]
		var frame := {"source": (r["source"] as CardInstance).uid, "controller": atk.controller_id}
		if not effects._passes_filter(atk.controller_id, atk, {"filters": d.get("attacker", {})}, frame):
			continue
		# "count": 0 -- a description of the blocker, not a selection: Armor
		# and "cannot be selected" do not apply (0.15.0)
		if effects._passes_filter(atk.controller_id, blocker, {"filters": d.get("blocker", {}), "count": 0}, frame):
			return true
	return false


func _act_declare_block(pid: int, action: Dictionary) -> Dictionary:
	if state.battle.is_empty() or int(state.battle["phase"]) != BSS.BattlePhase.BLOCK_DECLARATION:
		return _err("not the block declaration")
	if pid != int(state.battle["defending_player"]):
		return _err("you are not the defending player")
	var ci: CardInstance = state.card(int(action.get("uid", -1)))
	var legal := _legal_blockers(pid)
	var found := false
	for l in legal:
		if l.uid == ci.uid if ci != null else false:
			found = true
	if not found:
		return _err("that spirit cannot block")
	ci.orientation = BSS.Orientation.EXHAUSTED
	state.battle["blocker"] = ci.uid
	state.log_event("block_declared", {"uid": ci.uid})

	effects.set_active_window("while_blocking", ci.uid, true)   # 7-1-3-2
	# '"When This Spirit Blocks" effects of your opponent's spirits blocking
	# your Ancient Dragon spirits are not triggered' (0.15.0, BSS04-004)
	if not _block_triggers_suppressed(state.card(int(state.battle.get("attacker", -1)))):
		effects.trigger("on_block", {"uid": ci.uid, "player": pid})
	effects.trigger("block_declared", {"uid": ci.uid, "player": pid})   # "when one of your spirits blocks" (0.14.0)
	# "When one of your spirits is blocked" (0.11.1) -- ctx is the attacker
	var atk_b: CardInstance = state.card(int(state.battle.get("attacker", -1)))
	if atk_b != null:
		effects.trigger("blocked", {"uid": atk_b.uid, "player": atk_b.controller_id, "blocker": ci.uid})
	keywords.on_block(state.card(int(state.battle["attacker"])), ci)

	_open_flash_window(BSS.BattlePhase.FLASH_AFTER_BLOCK, pid)  # 7-1-4-1
	# "Your spirits can be linked with a spirit with Link when blocking" (0.15.0, BSS06-054)
	if ci.zone == BSS.Zone.FIELD and effects.rule_applies(ci, "link_on_block"):
		state.battle["link_offer"] = ci.uid
		keywords.offer_pending_links()
	return _ok()


func _act_decline_block(pid: int) -> Dictionary:
	if state.battle.is_empty() or int(state.battle["phase"]) != BSS.BattlePhase.BLOCK_DECLARATION:
		return _err("not the block declaration")
	if pid != int(state.battle["defending_player"]):
		return _err("you are not the defending player")
	# 11-2-1 -- Confront removes the option to decline while a blocker exists.
	if bool(state.battle.get("forced_block", false)) and not _legal_blockers(pid).is_empty():
		return _err("Confront forces you to block")
	_battle_resolution()
	return _ok()


## 7-1-5 -- battle resolution.
func _battle_resolution() -> void:
	state.battle["phase"] = BSS.BattlePhase.RESOLUTION
	effects.refresh_constants()                        # "while attacking" constants (0.14.0)
	var atk: CardInstance = state.card(int(state.battle.get("attacker", -1)))
	var blk: CardInstance = state.card(int(state.battle.get("blocker", -1)))
	var blocked := blk != null and blk.zone == BSS.Zone.FIELD

	if blocked:
		# 7-1-5-2-1 compare BP; ties destroy both.
		if atk == null or atk.zone != BSS.Zone.FIELD:
			pass                                       # attacker already gone
		else:
			effects.refresh_constants()
			var a := atk.current_bp()
			var b := blk.current_bp()
			state.log_event("compare_bp", {"a": a, "b": b})
			# "When BP is compared, if this spirit has higher BP" (0.15.0, BSS04-078 / -113):
			# fires whether or not the loser then leaves the field.
			if a != b:
				var won: CardInstance = atk if a > b else blk
				var lost0: CardInstance = blk if a > b else atk
				effects.trigger("bp_comparison_won", {"uid": won.uid, "loser": lost0.uid, "player": won.controller_id})
			if bool(state.battle.get("no_battle_destroy", false)):
				# "During this battle, neither player's spirits can be destroyed
				# by battle" (0.15.0, BSS03-050)
				state.log_event("battle_destroy_prevented", {})
			elif a > b:
				destroy(blk, atk.uid, true)
				_after_bp_kill(atk, blk, b)
			elif b > a:
				destroy(atk, blk.uid, true)
				_after_bp_kill(blk, atk, a)
			else:
				destroy(atk, blk.uid, true)
				destroy(blk, atk.uid, true)
			# "When one of your spirits is destroyed in battle / via comparing
			# BP" (0.11.1): the losing side, ties included.
			for lost: CardInstance in [atk, blk]:
				if lost.zone != BSS.Zone.FIELD:
					effects.trigger("lost_battle", {"uid": lost.uid, "player": lost.owner_id})
	else:
		# 7-1-5-3-1 apply damage equal to the attacker's symbol count.
		if atk != null and atk.zone == BSS.Zone.FIELD:
			var defender := int(state.battle["defending_player"])
			var n := atk.symbol_count()
			# "Neither player's life can be reduced by an attack from a spirit
			# with 2000 or fewer BP" (0.14.0)
			for pz in 2:
				for r: Dictionary in effects.active_rules(pz, "no_life_damage"):
					var nd: Dictionary = r["d"]
					if bool(nd.get("bp_lt_source", false)):
						# "your opponent's spirits with less BP than this spirit
						# cannot reduce your life" -- only its controller's
						# life (0.15.0, BSS03-014)
						var nsrc: CardInstance = r["source"]
						if pz == defender and atk.current_bp() < nsrc.current_bp():
							n = 0
					elif nd.has("bp_max") and atk.current_bp() <= int(nd["bp_max"]):
						n = 0
			# "...reduces your opponent's life, the lost cores go to the void"
			# "attacks from your opponent's non-token spirits that cost 4 or less
			# cannot reduce your life to 0" (0.15.0, BSS04-128)
			# "This turn, its attacks cannot reduce your life" (0.15.0, BSS05-128)
			if bool(atk.flags.get("no_life_damage", false)):
				n = 0
			# "This turn, attacks by your opponent's spirits with 3000 BP or less
			# cannot reduce your life" (0.15.0, BSS05-062)
			for r3: Dictionary in effects.active_rules(defender, "life_shield"):
				if atk.current_bp() <= int((r3["d"] as Dictionary).get("bp_max", 0)):
					n = 0
			# "Each time an attack by one of your opponent's spirits deals you
			# damage, your life can only be reduced by 1" (0.15.0, BSS05-035)
			for r4: Dictionary in effects.active_rules(defender, "life_damage_cap"):
				n = mini(n, int((r4["d"] as Dictionary).get("amount", 1)))
			for r2: Dictionary in effects.active_rules(defender, "no_lethal_damage"):
				if effects._passes_filter(defender, atk, {"filters": (r2["d"] as Dictionary).get("attacker", {}), "count": 0}, {}):
					n = mini(n, maxi(0, state.player(defender).life_total() - 1))
			var to_zone := BSS.Zone.RESERVE
			if (atk.has_keyword(BSS.Keyword.CURSE) or atk.has_keyword(BSS.Keyword.BLOODCURSE)) \
					and not effects.active_rules(atk.controller_id, "life_to_void").is_empty():
				to_zone = BSS.Zone.VOID
			var moved := state.move_cores(GameState.pool(defender, BSS.Zone.LIFE),
					GameState.pool(defender, to_zone), n)
			state.log_event("damage", {"player": defender, "n": moved})
			if moved > 0:
				keywords.on_damage_dealt(atk)          # 11-7 Blessed
				effects.trigger("dealt_damage", {"uid": atk.uid, "player": atk.controller_id})
				on_life_lost(defender)                 # bursts, "when life is reduced"
	_end_battle()


## 7-1-6 -- end of battle.
func _end_battle() -> void:
	state.battle["phase"] = BSS.BattlePhase.BATTLE_END
	var atk: CardInstance = state.card(int(state.battle.get("attacker", -1)))
	var blk: CardInstance = state.card(int(state.battle.get("blocker", -1)))

	# "destroy your opponent's blocking spirit when the battle ends" (0.14.0)
	if blk != null and blk.zone == BSS.Zone.FIELD and bool(blk.flags.get("doomed", false)):
		destroy(blk, atk.uid if atk != null else -1)
	# "Destroy it when the battle ends" on the attacking spirit (0.15.0, BSS03-124)
	if atk != null and atk.zone == BSS.Zone.FIELD and bool(atk.flags.get("doomed", false)):
		destroy(atk, int(atk.flags.get("doomed_by", blk.uid if blk != null else -1)))
	keywords.on_battle_end(atk, blk)                   # 11-3 Curse, 11-6 Luster
	# "When this battle ends, end the attack step" (0.14.0)
	if state.turn_flag(state.turn_player, "end_attack_after_battle"):
		state.set_turn_flag(state.turn_player, "end_attack_after_battle", false)
		state.set_turn_flag(state.turn_player, "attack_step_closed")
		# "When an effect of your opponent ends your attack step" (0.15.0, BSS05-072)
		var eab := int(state.turn_flags.get("%d:end_attack_after_battle:by" % state.turn_player, -1))
		if eab >= 0 and eab != state.turn_player:
			effects.trigger("attack_step_ended_by_opponent", {"player": state.turn_player, "by_player": eab})
	# uid/player name the attacker, so "when a battle with one of your NERV
	# spirits ends" can filter on it (0.12.0)
	effects.trigger("battle_end", {"battle": state.battle.duplicate(true),
			"uid": atk.uid if atk != null else -1, "player": atk.controller_id if atk != null else -1})
	keywords.check_agile(state.battle)                 # 11-16

	# 7-1-6-2 -- "while attacking"/"while blocking" switch off.
	effects.set_active_window("while_attacking", -1, false)
	effects.set_active_window("while_blocking", -1, false)
	keywords.break_links(state.battle)                 # 11-18-4

	# "During this battle, ..." player flags end with it (0.15.0, BSS03-134)
	for pf: Variant in state.battle.get("player_flags", []):
		state.set_turn_flag(int((pf as Array)[0]), str((pf as Array)[1]), false)
	state.battle = {}
	state.flash_priority = -1
	run_checkpoints()
	state.log_event("battle_end", {})


## "When this spirit destroys one of your opponent's spirits via comparing
## BP" (0.11.0). Fires only if the loser really left the field.
func _after_bp_kill(winner: CardInstance, loser: CardInstance, loser_bp: int = 0) -> void:
	if winner == null or loser == null or loser.zone == BSS.Zone.FIELD:
		return
	# "battle": scope battle_attacker ("while this spirit attacks", BSS01-021)
	# needs the battle; before 0.15.0 it had none and never fired.
	effects.trigger("battle_destroy", {"uid": winner.uid, "loser": loser.uid,
			"player": winner.controller_id, "loser_bp": loser_bp, "battle": state.battle.duplicate(true)})
	# "During this battle, when one of your Bladebeast spirits destroys one of
	# your opponent's spirits by comparing BP, refresh it" (0.15.0, BSS03-134)
	if winner.zone == BSS.Zone.FIELD and winner.has_family("Bladebeast") \
			and state.turn_flag(winner.controller_id, "bladebeast_bp_win_refresh"):
		winner.orientation = BSS.Orientation.REFRESHED


## Everything that follows a player losing life (0.11.0): remember it for the
## turn ("if you did not lose life this turn"), fire "when your life is
## reduced" effects, then offer a life-loss burst.
func on_life_lost(pid: int) -> void:
	state.set_turn_flag(pid, "lost_life")
	effects.trigger("life_reduced", {"player": pid})
	keywords.offer_bursts(pid, "life_decreased")


func _act_end_attack(pid: int) -> Dictionary:
	if state.step != BSS.Step.ATTACK or pid != state.turn_player:
		return _err("not your attack step")
	if not state.battle.is_empty():
		return _err("finish the current battle first")
	var must := must_attack_pending(pid)
	if must != null:
		return _err("%s must attack if able" % must.data.name)
	effects.trigger("end_of_attack_step", {"player": pid})   # "after your attack step" (0.14.0)
	effects.resolve_top()
	_set_step(BSS.Step.END)
	_run_step()
	return _ok()


# ===========================================================================
# SECTION 9 -- Gameplay management
# ===========================================================================

## 4-7-2 -- run every checkpoint rule until the state stops changing. Because
## resolving one checkpoint can create the conditions for another, this loops
## rather than running once, with a hard cap so a pathological board cannot
## hang the server.
## 0.14.0: "when your life increases" and "when one of your opponent's
## spirits is exhausted" are noticed here, whatever caused them.
var _last_life: Array = []
var _exhausted_seen: Dictionary = {}


func _detect_changes() -> void:
	# Record the new state BEFORE firing: a triggered effect can resolve and
	# reach this checkpoint again, and must not see the same change twice.
	var gained: Array = []
	if _last_life.size() == 2:
		for pid in 2:
			if state.player(pid).life_total() > int(_last_life[pid]):
				gained.append(pid)
	_last_life = [state.player(0).life_total(), state.player(1).life_total()]
	var now := {}
	var newly: Array = []
	var refreshed: Array = []
	var nexus_newly: Array = []
	for ci in state.all_field_cards():
		if ci.data != null and ci.data.is_spirit() and ci.is_exhausted():
			now[ci.uid] = true
			if not _exhausted_seen.has(ci.uid):
				newly.append(ci)
		elif ci.data != null and ci.data.is_spirit() and _exhausted_seen.has(ci.uid):
			refreshed.append(ci)               # exhausted -> refreshed (0.15.0)
		elif ci.data != null and ci.data.is_nexus() and ci.is_exhausted():
			# "When one of your nexuses is exhausted" -- by anything, not only
			# exhaust_nexus, which fires it itself (0.15.0, BSS03-087)
			now[ci.uid] = true
			if not _exhausted_seen.has(ci.uid) and not effects.nexus_exhaust_fired.has(ci.uid):
				nexus_newly.append(ci)
	_exhausted_seen = now
	effects.nexus_exhaust_fired.clear()
	# "The first time each turn a spirit card is put into your trash" (0.15.0,
	# BSS05-016): every spirit card that reached a trash since the last checkpoint
	var to_trash: Array = state.trash_events.duplicate()
	state.trash_events.clear()
	for te: Dictionary in to_trash:
		var tc: CardInstance = state.card(int(te["uid"]))
		if tc != null and tc.zone == BSS.Zone.TRASH:
			effects.trigger("spirit_card_to_trash", {"uid": tc.uid, "player": int(te["player"])})
	# whose effect exhausted each spirit (0.15.0, BSS03-114); -1: an attack, a block or a cost
	var exh_by: Dictionary = effects.exhausted_by.duplicate()
	effects.exhausted_by.clear()
	for pid2: int in gained:
		effects.trigger("life_gained", {"player": pid2})
	for ci2: CardInstance in newly:
		effects.trigger("spirit_exhausted", {"uid": ci2.uid, "player": ci2.controller_id,
				"by_player": int(exh_by.get(ci2.uid, -1))})
	for nx: CardInstance in nexus_newly:
		if nx.zone == BSS.Zone.FIELD:
			effects.trigger("nexus_exhausted", {"uid": nx.uid, "player": nx.controller_id})
	for ci3: CardInstance in refreshed:
		if ci3.zone == BSS.Zone.FIELD:
			effects.trigger("spirit_refreshed", {"uid": ci3.uid, "player": ci3.controller_id})
	# Core moves since the last checkpoint (0.15.0): "when cores are put into
	# your reserve" once per player, "when cores are placed on it" once per card.
	if not state.core_events.is_empty():
		var evs: Array = state.core_events.duplicate()
		state.core_events.clear()
		var seen := {}
		for ev: Dictionary in evs:
			var key := "%s:%d" % [ev["kind"], int(ev.get("player", ev.get("uid", -1)))]
			if seen.has(key):
				continue
			seen[key] = true
			if str(ev["kind"]) == "reserve":
				effects.trigger("core_to_reserve", {"player": int(ev["player"])})
			else:
				var pc: CardInstance = state.card(int(ev["uid"]))
				if pc != null and pc.zone == BSS.Zone.FIELD:
					effects.trigger("cores_placed", {"uid": pc.uid, "player": pc.controller_id})


func run_checkpoints() -> void:
	effects.expire_orphans()             # "... while you control this spirit" (0.15.0)
	effects.refresh_constants()          # constant effects first: BP can change (R-040)
	_detect_changes()
	var guard := 0
	while guard < 64:
		guard += 1
		var changed := false

		# 9-2 establishing a winner is interrupting management.
		for pid in 2:
			if state.player(pid).life_total() <= 0 and not state.game_over:
				_declare_winner(state.opponent_of(pid), "life reduced to zero")
				return

		# 9-3 insufficient cores for LV1, and 9-4 BP zero or less.
		for ci in state.all_field_cards():
			if ci.zone != BSS.Zone.FIELD or bool(ci.flags.get("being_destroyed", false)):
				continue
			if ci.total_cores() < ci.data.min_level_cost():
				# 9-3-2 self-destruction: no "when destroyed" effects fire.
				# But "when one of your effects destroys a spirit by reducing
				# its cores to zero" (0.11.1) does: the remover is recorded.
				var stripper := int(ci.flags.get("stripped_by", -1))
				var zero_uid: int = ci.uid
				if stripper >= 0 and stripper != ci.controller_id:
					# 0.16.7 (R-085): cores removed by the OPPONENT's effect --
					# destroyed by that effect, so "When Destroyed" effects and
					# "when your opponent destroys your spirit" bursts apply.
					# Losing cores to your own payments or moves stays a quiet
					# self-destruction (9-3-2).
					if ci.current_level() <= 0:
						ci.level_override = int(ci.flags.get("last_level", 1))   # last known level
					_destroy_raw(ci, false, int(ci.flags.get("stripped_src", -1)), false, stripper)
				else:
					_destroy_raw(ci, true)
				if stripper >= 0:
					effects.trigger("cores_zeroed", {"uid": zero_uid, "player": stripper})
				changed = true
			elif ci.data.is_spirit() and ci.raw_bp() <= 0:
				ci.flags["zero_bp"] = true                 # BSS05-043 (0.15.0)
				# an opponent's -BP: destroyed by that card (0.16.7, R-085)
				_destroy_raw(ci, bool(ci.flags.get("self_caused", false)), int(ci.flags.get("bp_down_src", -1)))
				changed = true

		if not changed:
			break
		effects.refresh_constants()       # a card left: its constant effects end
	# "stripped_by" only means something until the checkpoint that follows the
	# removal; a spirit that survived it keeps no mark (0.11.1).
	for c2 in state.all_field_cards():
		c2.flags.erase("stripped_by")
		c2.flags.erase("stripped_src")


## A refreshed spirit that may declare an attack right now.
func _can_attack_now(ci: CardInstance) -> bool:
	return ci.is_refreshed() and not bool(ci.flags.get("no_attack", false)) \
			and not effects.rule_applies(ci, "cannot_attack") and not attack_banned(ci) \
			and not (state.turn_flag(ci.controller_id, "attack_tax") and ci.total_cores() < 1) \
			and (attack_cost(ci) == 0 or _affordable(ci.controller_id, attack_cost(ci)))


# ---- 0.15.0 (Set 3) --------------------------------------------------------

## BSS04-004: the attacker's controller has a suppress_block_triggers rule
## whose attacker filter it passes (0.15.0).
func _block_triggers_suppressed(atk: CardInstance) -> bool:
	if atk == null:
		return false
	for r: Dictionary in effects.active_rules(atk.controller_id, "suppress_block_triggers"):
		if effects._passes_filter(atk.controller_id, atk, {"filters": (r["d"] as Dictionary).get("attacker", {}), "count": 0}, {}):
			return true
	return false


## Cores the opponent's opponent_attack_cost rules charge to attack with `ci`
## ("cannot attack unless their controller pays one core", BSS03-084 / -118).
func attack_cost(ci: CardInstance) -> int:
	var n := 0
	for r: Dictionary in effects.active_rules(state.opponent_of(ci.controller_id), "opponent_attack_cost"):
		var d: Dictionary = r["d"]
		if effects._passes_filter(ci.controller_id, ci, {"filters": d.get("attacker", {}), "count": 0}, {}):
			n += int(d.get("amount", 1))
	return n


## "Your opponent cannot summon more than one spirit that costs 4 or less each
## turn" (BSS03-103): every summon of a spirit card is counted by note_summon.
func summon_blocked(pid: int, cd: CardData) -> bool:
	if cd == null or not cd.is_spirit():
		return false
	var done: Array = state.turn_flags.get("%d:summoned_costs" % pid, [])
	for r: Dictionary in effects.active_rules(state.opponent_of(pid), "summon_limit"):
		var d: Dictionary = r["d"]
		var cmax := int(d.get("cost_max", 99))
		if cd.cost > cmax:
			continue
		var n := 0
		for c: Variant in done:
			if int(c) <= cmax: n += 1
		if n >= int(d.get("per_turn", 1)):
			return true
	return false


func note_summon(pid: int, cd: CardData) -> void:
	var k := "%d:summoned_costs" % pid
	var done: Array = state.turn_flags.get(k, [])
	done.append(cd.cost)
	state.turn_flags[k] = done


## "As an additional summoning cost, you must destroy one of your blue
## nexuses" (BSS03-097): a cost-timing effect with "summon_cost" directives.
## Each directive needs a target to be payable.
func summon_cost_payable(pid: int, ci: CardInstance) -> bool:
	for e: Dictionary in ci.data.effects:
		for sd: Dictionary in e.get("summon_cost", []):
			if sd.has("target") and effects.collect_targets(pid, sd["target"], {"source": ci.uid, "controller": pid}).is_empty():
				return false
	return true


## Pays it: the target named by action.summon_cost_uid, else the cheapest one.
func _pay_summon_cost(pid: int, ci: CardInstance, action: Dictionary) -> void:
	for e: Dictionary in ci.data.effects:
		for sd: Dictionary in e.get("summon_cost", []):
			var fr := {"source": ci.uid, "controller": pid}
			if not sd.has("target"):
				effects.execute(pid, sd, fr)
				continue
			var pool: Array = effects.collect_targets(pid, sd["target"], fr)
			if pool.is_empty():
				continue
			pool.sort_custom(func(a: CardInstance, b: CardInstance) -> bool: return a.data.cost < b.data.cost)
			var pick: CardInstance = pool[0]
			for p0: CardInstance in pool:
				if p0.uid == int(action.get("summon_cost_uid", -1)):
					pick = p0
			match str(sd.get("op", "")):
				"destroy": destroy(pick, ci.uid)
				"exhaust": pick.orientation = BSS.Orientation.EXHAUSTED
				"return_to_hand": effects._return_to_hand(pick)


## "Cannot use magic cards from their hand that do not share a colour with any
## symbol on their field" (BSS03-117), from the opponent's magic_color_lock.
func magic_locked(pid: int, cd: CardData) -> bool:
	if cd == null or not cd.is_magic() or effects.active_rules(state.opponent_of(pid), "magic_color_lock").is_empty():
		return false
	for g: Variant in state.player(pid).field_symbol_groups(state):
		for col: Variant in g:
			if cd.has_color(int(col)):
				return false
	return true


## The index of the "next magic card costs N less" discount this card uses, or -1 (BSS03-036).
func _next_magic_discount(pid: int, cd: CardData) -> int:
	if cd == null or not cd.is_magic():
		return -1
	var lst: Array = state.turn_flags.get("%d:next_magic_discount" % pid, [])
	for i in lst.size():
		var f: Dictionary = (lst[i] as Dictionary).get("filters", {})
		if f.has("color") and not cd.has_color(BSS.color_from_string(str(f["color"]))):
			continue
		if f.has("cost_max") and cd.cost > int(f["cost_max"]):
			continue
		return i
	return -1


## Place a nexus without paying its cost, from wherever it is (Sets 3-4: "place
## it without paying its cost", a nexus burst placing itself). Its When Placed
## effects activate.
func place_free(pid: int, ci: CardInstance) -> void:
	if ci == null or ci.data == null or not ci.data.is_nexus() or ci.zone == BSS.Zone.FIELD:
		return
	state.move_card(ci.uid, BSS.Zone.FIELD, pid)
	ci.face_up = true
	state.move_cores(GameState.pool(pid, BSS.Zone.RESERVE), GameState.on_card(ci.uid),
			ci.data.min_level_cost(), false, true)
	state.log_event("place", {"player": pid, "uid": ci.uid, "cost": 0, "free": true})
	effects.trigger("on_place", {"uid": ci.uid, "player": pid})


## The first spirit that must attack and still can, or null (0.12.0).
func must_attack_pending(pid: int) -> CardInstance:
	if state.step != BSS.Step.ATTACK or pid != state.turn_player:
		return null
	if state.turn_flag(pid, "attack_step_closed"):
		return null
	for ci in state.field_spirits(pid):
		if _can_attack_now(ci) and (effects.rule_applies(ci, "must_attack") or bool(ci.flags.get("must_attack", false))):
			return ci
	return null


## 10-1 -- destroy a card. `source_uid` records what did it, for effects that
## care about "destroyed by the opponent".
## `by_battle` (0.13.0): destroyed by comparing BP, not by an effect.
func destroy(ci: CardInstance, source_uid: int = -1, by_battle: bool = false) -> void:
	if ci == null or ci.zone != BSS.Zone.FIELD:
		return
	# 10-1-3-2 -- substitution effects get first refusal.
	if effects.try_substitute_destruction(ci, source_uid, by_battle):
		state.log_event("destruction_substituted", {"uid": ci.uid})
		return
	# "This turn, this spirit cannot be destroyed by your opponent's
	# destruction effects or as the result of battle" (0.11.0)
	if bool(ci.flags.get("indestructible", false)):
		var src: CardInstance = state.card(source_uid)
		if src == null or src.controller_id != ci.controller_id:
			state.log_event("destruction_prevented", {"uid": ci.uid})
			return
	var src_card: CardInstance = state.card(source_uid)
	var by_opponent := src_card != null and src_card.controller_id != ci.controller_id
	# "Your white nexuses cannot be destroyed by the effects of your
	# opponent's red spirits or magic" (0.14.0)
	if ci.data.is_nexus() and by_opponent and not by_battle:
		for r: Dictionary in effects.active_rules(ci.controller_id, "nexus_protect"):
			var dn: Dictionary = r["d"]
			var fcol := str((dn.get("for", {}) as Dictionary).get("color", ""))
			if fcol != "" and not ci.data.has_color(BSS.color_from_string(fcol)):
				continue
			for c3: Variant in dn.get("colors", []):
				if src_card.data != null and src_card.data.has_color(BSS.color_from_string(str(c3))):
					state.log_event("destruction_prevented", {"uid": ci.uid})
					return
	# Bloodcurse (0.14.0): when the opponent would destroy it, one core from
	# their life and one from this spirit go to their owners' trashes and it
	# stays, refreshed. Taken whenever it leaves the spirit with a core.
	if by_opponent and ci.has_keyword(BSS.Keyword.BLOODCURSE) and ci.total_cores() >= 2 \
			and state.player(src_card.controller_id).life_total() >= 1:
		var foe := src_card.controller_id
		state.move_cores(GameState.pool(foe, BSS.Zone.LIFE), GameState.pool(foe, BSS.Zone.TRASH), 1)
		state.move_cores(GameState.on_card(ci.uid), GameState.pool(ci.owner_id, BSS.Zone.TRASH), 1, false, true)
		ci.orientation = BSS.Orientation.REFRESHED
		state.log_event("bloodcurse", {"uid": ci.uid})
		on_life_lost(foe)
		return
	# 11-13 A.T. Field is a flat prevention, not a substitution. It stops the
	# DESTRUCTION EFFECTS of opposing spirits; losing a battle is not an
	# effect (R-068: before 0.13.0 the battle's winner counted as one).
	if not by_battle and keywords.at_field_protects(ci, source_uid):
		state.log_event("at_field_blocked", {"uid": ci.uid})
		return
	# "Your Lightguider spirits cannot be destroyed by the destruction effects
	# of your opponent's spirits" (0.15.0, BSS05-052 / -063)
	if by_opponent and not by_battle and src_card.data != null and src_card.data.is_spirit() \
			and effects.rule_applies(ci, "indestructible_by"):
		state.log_event("destruction_prevented", {"uid": ci.uid})
		return
	# "If this spirit has a soul core on it, it cannot be destroyed by your
	# opponent's effects" (0.15.0, BSS04-053)
	if by_opponent and not by_battle and effects.rule_applies(ci, "no_destroy_by_effect"):
		state.log_event("destruction_prevented", {"uid": ci.uid})
		return
	# "Cannot be destroyed by your opponent's destruction effects" -- a lost
	# battle still destroys it (0.15.0)
	if bool(ci.flags.get("effect_indestructible", false)) and by_opponent and not by_battle:
		state.log_event("destruction_prevented", {"uid": ci.uid})
		return
	_destroy_raw(ci, false, source_uid, by_battle)


func _destroy_raw(ci: CardInstance, self_destroy: bool, source_uid: int = -1, by_battle: bool = false,
		by_player: int = -1) -> void:
	if ci == null or ci.zone != BSS.Zone.FIELD:
		return
	# (0.15.0) Its When Destroyed triggers resolve while it is still on the
	# field; a checkpoint inside that resolution found the same spirit (BP 0)
	# and destroyed it again, without end -- a stack overflow in AI games.
	if bool(ci.flags.get("being_destroyed", false)):
		return
	ci.flags["being_destroyed"] = true
	var uid := ci.uid
	var owner := ci.owner_id
	state.log_event("destroyed", {"uid": uid, "self": self_destroy, "by": source_uid})
	# "If one of your spirits has been destroyed this turn" (0.15.0)
	if ci.data != null and ci.data.is_spirit():
		state.set_turn_flag(ci.controller_id, "spirit_destroyed")
	if not self_destroy:
		# 10-1-3-3 -- triggers fire before the card physically moves so that
		# "when destroyed" effects can still read its last state (8-10-1).
		# "Your opponent's When Destroyed effects do not activate" (0.15.0)
		var silenced := ci.data != null and ci.data.is_spirit() and \
				not effects.active_rules(state.opponent_of(ci.controller_id), "suppress_when_destroyed").is_empty()
		if not effects.suppress_when_destroyed and not silenced:
			effects.trigger("when_destroyed", {"uid": uid, "player": owner, "by": source_uid,
					"cores": ci.cores, "soul": ci.soul_cores, "bp": ci.current_bp(), "by_battle": by_battle,
					"zero_bp": bool(ci.flags.get("zero_bp", false))})
		var destroyer := by_player
		var src: CardInstance = state.card(source_uid)
		if src != null:
			destroyer = src.controller_id
		if destroyer >= 0 and destroyer != owner:
			if not silenced:
				effects.trigger("when_destroyed_by_opponent", {"uid": uid, "player": owner})
			if ci.data != null and ci.data.is_spirit():
				keywords.offer_bursts(owner, "spirit_destroyed")    # 0.11.0
		keywords.check_immortal(owner, uid)            # 11-4
	# 10-1-3-4 -- card to the owner's trash, cores to the owner's reserve.
	# (Unless one of its triggers already moved it -- 0.15.0.)
	if ci.zone == BSS.Zone.FIELD:
		state.move_card(uid, BSS.Zone.TRASH, owner, true, BSS.Zone.RESERVE)


func _declare_winner(pid: int, reason: String) -> void:
	if state.game_over:
		return
	state.game_over = true
	state.winner = pid
	state.log_event("game_over", {"winner": pid, "reason": reason})
	game_ended.emit(pid)


func declare_draw(reason: String) -> void:
	state.game_over = true
	state.winner = 2                                   # 1-2-3
	state.log_event("game_over", {"winner": 2, "reason": reason})
	game_ended.emit(2)


# ===========================================================================
# Legal-move enumeration -- used by the bot and by the UI to grey out buttons
# ===========================================================================

func legal_actions(pid: int) -> Array:
	var out: Array = []
	if state.game_over:
		return out
	if not state.pending_choice.is_empty():
		if int(state.pending_choice.get("player", -1)) == pid:
			out.append({"verb": BSS.Action.RESOLVE_CHOICE})
		return out
	if _main_ok(pid):
		for uid in state.player(pid).hand:
			var ci: CardInstance = state.cards[uid]
			var cost := compute_cost(pid, ci.data) + (magic_core_tax(pid) if ci.data.is_magic() else 0)
			var affordable := _affordable(pid, cost)
			# Ascend needs a qualifying spirit to strip (0.14.0)
			if ci.data.is_spirit() and affordable and ci.has_keyword(BSS.Keyword.ASCEND) \
					and not keywords.can_ascend(pid, ci):
				affordable = false
			# 0.15.0 (Set 3): summon limits, extra summoning costs, the magic colour lock
			if ci.data.is_spirit() and affordable and (summon_blocked(pid, ci.data) or not summon_cost_payable(pid, ci)):
				affordable = false
			if ci.data.is_magic() and affordable and magic_locked(pid, ci.data):
				affordable = false
			if ci.data.is_spirit() and affordable:
				out.append({"verb": BSS.Action.SUMMON, "uid": uid})
			elif ci.data.is_nexus() and affordable:
				out.append({"verb": BSS.Action.PLACE, "uid": uid})
			elif ci.data.is_magic() and affordable and state.player(pid).hand.size() - 1 >= magic_discard_tax(pid):
				# 10-8-3: a magic card with several effects uses ONE of them;
				# every effect usable in the main step is offered (0.9.0 --
				# before, only the first was, R-043).
				for i in ci.data.effects.size():
					var win := str(ci.data.effects[i].get("window", "main"))
					if win == "main" or win == "both":
						out.append({"verb": BSS.Action.USE_MAGIC, "uid": uid, "effect": i})
			if ci.data.has_burst and state.player(pid).bursts_set_this_turn == 0:
				out.append({"verb": BSS.Action.SET_BURST, "uid": uid})
		_offer_awaken(pid, out)
		_offer_activated(pid, out, false)
		out.append({"verb": BSS.Action.END_MAIN})
	if state.step == BSS.Step.ATTACK and pid == state.turn_player and state.battle.is_empty():
		for ci in state.field_spirits(pid):
			if _can_attack_now(ci) and not state.turn_flag(pid, "attack_step_closed"):
				out.append({"verb": BSS.Action.DECLARE_ATTACK, "uid": ci.uid})
		# "This spirit must attack if able" (0.12.0): no ending the attack
		# step while such a spirit could still attack.
		if must_attack_pending(pid) == null:
			out.append({"verb": BSS.Action.END_ATTACK})
	if not state.battle.is_empty():
		var ph := int(state.battle["phase"])
		if ph == BSS.BattlePhase.BLOCK_DECLARATION and pid == int(state.battle["defending_player"]):
			for ci in _legal_blockers(pid):
				out.append({"verb": BSS.Action.DECLARE_BLOCK, "uid": ci.uid})
			if not bool(state.battle.get("forced_block", false)) or _legal_blockers(pid).is_empty():
				out.append({"verb": BSS.Action.DECLINE_BLOCK})
		elif _in_flash_window(pid):
			out.append({"verb": BSS.Action.FLASH_PASS})
			_offer_awaken(pid, out)
			_offer_activated(pid, out, true)
			for uid in state.player(pid).hand:
				var ci: CardInstance = state.cards[uid]
				if ci.data.is_magic():
					for i in ci.data.effects.size():
						var w := str(ci.data.effects[i].get("window", "main"))
						if (w == "flash" or w == "both") and _affordable(pid, compute_cost(pid, ci.data) + magic_core_tax(pid)) \
							and state.player(pid).hand.size() - 1 >= magic_discard_tax(pid) \
							and not magic_locked(pid, ci.data):
							out.append({"verb": BSS.Action.USE_MAGIC, "uid": uid, "effect": i})
				elif ci.data.is_spirit() and ci.has_keyword(BSS.Keyword.SWIFT):
					if state.player(pid).reserve_cores >= compute_cost(pid, ci.data) \
							and not summon_blocked(pid, ci.data) and summon_cost_payable(pid, ci):
						out.append({"verb": BSS.Action.SUMMON, "uid": uid})
	out.append({"verb": BSS.Action.CONCEDE})
	return out


## 11-1 Awaken (offered since 0.11.0; before, nothing ever offered it): move
## cores from your other spirits onto this one. The offer takes only cores
## those spirits do not need for their current level, so it never empties or
## levels down another spirit.
func _offer_awaken(pid: int, out: Array) -> void:
	for ci in state.field_spirits(pid):
		if not ci.has_keyword(BSS.Keyword.AWAKEN):
			continue
		var sources: Array = []
		for other: CardInstance in state.field_spirits(pid):
			if other.uid == ci.uid:
				continue
			var spare: int = other.cores - _level_floor(other)
			if spare > 0:
				sources.append({"uid": other.uid, "n": spare})
		if not sources.is_empty():
			out.append({"verb": BSS.Action.ACTIVATE, "uid": ci.uid, "keyword": "awaken", "sources": sources})


## Activated effects of cards on the field ("Flash: you may destroy this
## nexus to draw two cards", 0.15.0), when their window, step and cost allow.
func _offer_activated(pid: int, out: Array, flash: bool) -> void:
	for ci in state.all_field_cards():
		if ci.controller_id != pid or ci.data == null:
			continue
		var specs: Array = ci.active_effects()
		for i in specs.size():
			var spec: Dictionary = specs[i]
			if str(spec.get("kind", "")) != "activated" or str(spec.get("timing", "")) != "activated":
				continue
			var w := str(spec.get("window", "main"))
			if flash and w != "flash" and w != "both":
				continue
			if not flash and w != "main" and w != "both":
				continue
			if spec.has("during") and not effects.during_ok(str(spec["during"]), pid):
				continue
			var payable := true
			for c: Dictionary in spec.get("cost", []):
				if not effects._can_pay_one(pid, ci, c):
					payable = false
			if payable and _activated_useful(pid, ci, spec):
				out.append({"verb": BSS.Action.ACTIVATE, "uid": ci.uid, "effect": i})


## An activated effect is offered only when it would do something now (0.15.0):
## its condition holds, its first selection has a target, and a summon from
## the hand can be paid for. Spirit effects such as "Flash: summon one spirit
## card with Agile from your hand" (BSS06-067) or "Flash: put all cores from
## one of your other Star Dragon spirits onto this spirit" (BSS05-004) would
## otherwise be offered -- and taken -- over and over while doing nothing.
func _activated_useful(pid: int, ci: CardInstance, spec: Dictionary) -> bool:
	var fr := {"source": ci.uid, "controller": pid}
	if spec.has("condition") and typeof(spec["condition"]) == TYPE_DICTIONARY \
			and not effects.check_condition(pid, spec["condition"], fr):
		return false
	var dirs: Array = spec.get("directives", [])
	if dirs.is_empty():
		return false
	var d: Dictionary = dirs[0]
	if not d.has("target"):
		return true
	var t: Dictionary = d["target"]
	if str(t.get("zone", "field")) in ["self", "last_target", "trigger", "trigger_any", "linked_partner"]:
		return true
	var pool := effects.collect_targets(pid, t, fr)
	if str(d.get("op", "")) == "summon_from" and str(t.get("zone", "")) == "hand" and not bool(d.get("free", false)):
		var budget := state.player(pid).total_reserve() + \
				(effects._spare_field_cores(pid) if str(d.get("pay", "")) == "normal" else 0)
		pool = pool.filter(func(c: CardInstance) -> bool:
			return compute_cost(pid, c.data) + c.data.min_level_cost() <= budget and not summon_blocked(pid, c.data))
	return not pool.is_empty()


func _level_floor(ci: CardInstance) -> int:
	var lv := ci.current_level()
	for l: Dictionary in ci.data.levels:
		if int(l["level"]) == lv:
			return int(l["core_cost"])
	return ci.data.min_level_cost()


func _affordable(pid: int, cost: int) -> bool:
	var avail := state.player(pid).reserve_cores + state.player(pid).reserve_soul
	for uid in state.player(pid).field:
		avail += state.cards[uid].cores
	return avail >= cost
