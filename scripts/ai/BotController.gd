extends Node
class_name BotController
##
## The AI opponent.
##
## Design: a scored greedy policy, not a search. It enumerates legal actions
## from RulesEngine.legal_actions(), scores each with a heuristic, and picks
## with a difficulty-dependent amount of noise and deliberate error. That is
## enough to be a useful practice partner and it cannot desync, because it
## drives the same `submit()` door a human does.
##
## Why not a tree search: the engine parks on pending choices and resolves
## effects eagerly, so cloning a mid-resolution state is not free. A search
## would need a snapshot/restore layer on GameState first. That is a reasonable
## future upgrade and the scoring function below would survive it unchanged --
## see docs/CHANGELOG_AND_ISSUES.md, "Planned: bot lookahead".
##

enum Difficulty { BEGINNER, EASY, NORMAL, HARD, EXPERT }

const DIFFICULTY_NAMES := ["Beginner", "Easy", "Normal", "Hard", "Expert"]

## How the five levels differ, in one table:
##   blunder_rate  -- chance of ignoring the best action and picking at random
##   noise         -- random jitter added to every score, in score units
##   lookahead     -- reserved for the future search; unused by the greedy path
##   uses_flash    -- whether the bot bothers to respond during flash windows
##   holds_blocker -- whether it keeps a spirit back to block
const PROFILES := {
	Difficulty.BEGINNER: {"blunder_rate": 0.45, "noise": 40.0, "lookahead": 0, "uses_flash": false, "holds_blocker": false},
	Difficulty.EASY:     {"blunder_rate": 0.25, "noise": 25.0, "lookahead": 0, "uses_flash": false, "holds_blocker": false},
	Difficulty.NORMAL:   {"blunder_rate": 0.10, "noise": 12.0, "lookahead": 1, "uses_flash": true,  "holds_blocker": true},
	Difficulty.HARD:     {"blunder_rate": 0.03, "noise": 5.0,  "lookahead": 1, "uses_flash": true,  "holds_blocker": true},
	Difficulty.EXPERT:   {"blunder_rate": 0.0,  "noise": 0.0,  "lookahead": 2, "uses_flash": true,  "holds_blocker": true},
}

var engine: RulesEngine
var seat: int = 1
var difficulty: int = Difficulty.NORMAL
var profile: Dictionary = {}
var rng := RandomNumberGenerator.new()


func _init(p_engine: RulesEngine = null, p_seat: int = 1, p_difficulty: int = Difficulty.NORMAL) -> void:
	engine = p_engine
	seat = p_seat
	difficulty = clampi(p_difficulty, 0, PROFILES.size() - 1)
	profile = PROFILES[difficulty]
	rng.randomize()


# ---------------------------------------------------------------------------
# Policy
# ---------------------------------------------------------------------------

func choose_action() -> Dictionary:
	if engine == null or engine.state.game_over:
		return {}
	var st := engine.state

	# Pending choices come first: the engine is blocked until they are answered.
	if not st.pending_choice.is_empty() and int(st.pending_choice.get("player", -1)) == seat:
		return _answer_choice(st.pending_choice)

	var options := engine.legal_actions(seat)
	options = options.filter(func(a: Dictionary) -> bool:
		return str(a.get("verb", "")) != BSS.Action.CONCEDE)
	# 0.11.0: never consider a play that throws a card away -- a spirit that
	# would arrive without the cores to stay alive, or a cost that could only
	# be paid by emptying spirits already on the field. These are legal, but
	# no player would choose them. Before this, the -200 score kept them out
	# of the best pick but not out of the random "blunder" pick, which on
	# Normal is one decision in ten.
	options = options.filter(func(a: Dictionary) -> bool: return not _throws_away(a))
	# (0.15.0) an activated effect is used at most twice a turn: a free Flash
	# effect on a spirit (BSS05-004, BSS06-067) can never be repeated forever
	options = options.filter(func(a: Dictionary) -> bool:
		return not (str(a.get("verb", "")) == BSS.Action.ACTIVATE and a.has("effect") \
				and int(_activations.get(_act_key(a), 0)) >= 2))
	if options.is_empty():
		return {}

	# Beginner and Easy do not interact on the opponent's turn at all.
	if not bool(profile["uses_flash"]) and engine._in_flash_window(seat):
		return {"verb": BSS.Action.FLASH_PASS}

	if rng.randf() < float(profile["blunder_rate"]):
		return _with_payment(options[rng.randi_range(0, options.size() - 1)])

	var best: Dictionary = options[0]
	var best_score := -INF
	for a in options:
		var s := _score(a) + rng.randfn(0.0, float(profile["noise"]))
		if s > best_score:
			best_score = s
			best = a
	# Before ending the main step, put spare cores where they raise a spirit's
	# level (0.11.0). The AI never did this, so its spirits stayed at LV1 and
	# most LV2/LV3 effects never switched on.
	if str(best.get("verb", "")) == BSS.Action.END_MAIN:
		var up := _level_up_move()
		if not up.is_empty():
			return up
	if str(best.get("verb", "")) == BSS.Action.ACTIVATE and best.has("effect"):
		_activations[_act_key(best)] = int(_activations.get(_act_key(best), 0)) + 1
	return _with_payment(best)


var _activations: Dictionary = {}       # "turn:uid:effect" -> times used (0.15.0)


func _act_key(a: Dictionary) -> String:
	return "%d:%d:%d" % [engine.state.turn_number, int(a.get("uid", -1)), int(a.get("effect", 0))]


# ---------------------------------------------------------------------------
# Paying for cards (0.11.0)
# ---------------------------------------------------------------------------

## True for a summon, magic or nexus that cannot be paid for without losing
## a card: the new spirit would die on arrival, or the payment would have to
## strip spirits below their LV1 cost.
func _throws_away(a: Dictionary) -> bool:
	var verb := str(a.get("verb", ""))
	if verb != BSS.Action.SUMMON and verb != BSS.Action.USE_MAGIC and verb != BSS.Action.PLACE:
		return false
	return _payment_for(a) == null


## The payment the AI will use for `a`, or null if there is none that keeps
## every card alive. Summons keep the new spirit's LV1 cores in the reserve
## (they are placed from there after the cost is paid).
func _payment_for(a: Dictionary) -> Variant:
	var ci: CardInstance = engine.state.card(int(a.get("uid", -1)))
	if ci == null or ci.data == null:
		return null
	var cost := engine.compute_cost(seat, ci.data)
	if str(a.get("verb", "")) == BSS.Action.USE_MAGIC:
		cost += engine.magic_core_tax(seat)        # BSS05-100 (0.15.0)
	var keep := 0
	if str(a.get("verb", "")) == BSS.Action.SUMMON:
		keep = ci.data.min_level_cost() + int(a.get("extra_cores", 0))
	# Swift summons and anything in a flash window pay from the reserve only.
	return plan_payment(cost, keep, engine._in_flash_window(seat))


func _with_payment(a: Dictionary) -> Dictionary:
	var verb := str(a.get("verb", ""))
	if verb != BSS.Action.SUMMON and verb != BSS.Action.USE_MAGIC and verb != BSS.Action.PLACE:
		return a
	var plan: Variant = _payment_for(a)
	if plan == null or (plan as Array).is_empty():
		return a
	var out := a.duplicate()
	out["payment"] = plan
	return out


## How to pay `cost` and still have `keep` cores left in the reserve.
## Order: cores on spirits that are above what their CURRENT level needs
## (idle -- spending them changes nothing), then reserve cores, then the
## reserve soul core. Never a core a spirit needs for its level. Returns the
## payment list RulesEngine accepts, or null when it cannot be done.
func plan_payment(cost: int, keep: int, reserve_only: bool = false) -> Variant:
	var p := engine.state.player(seat)
	var remaining := cost
	var plan: Array = []
	if not reserve_only:
		for ci: CardInstance in engine.state.field_spirits(seat) + engine.state.field_nexuses(seat):
			if remaining <= 0:
				break
			var idle := ci.cores - _level_floor(ci)
			if idle > 0:
				var take := mini(idle, remaining)
				var loc := GameState.on_card(ci.uid)
				loc["n"] = take
				plan.append(loc)
				remaining -= take
	var in_reserve := p.reserve_cores + p.reserve_soul
	if remaining > in_reserve - keep:
		return null
	var from_regular := mini(remaining, p.reserve_cores)
	if from_regular > 0:
		var r := GameState.pool(seat, BSS.Zone.RESERVE)
		r["n"] = from_regular
		plan.append(r)
		remaining -= from_regular
	if remaining > 0:
		var s := GameState.pool(seat, BSS.Zone.RESERVE)
		s["n"] = remaining
		s["soul"] = true
		plan.append(s)
	return plan


## Cores a card needs to stay at the level it is at now.
func _level_floor(ci: CardInstance) -> int:
	if ci.data == null:
		return 0
	var lv := ci.current_level()
	for l: Dictionary in ci.data.levels:
		if int(l["level"]) == lv:
			return int(l["core_cost"])
	return ci.data.min_level_cost()


## One core move that levels up a spirit, or {} if none is worth it. Keeps
## enough in the reserve for the cheapest flash magic in hand.
func _level_up_move() -> Dictionary:
	var st := engine.state
	if st.turn_player != seat or st.step != BSS.Step.MAIN or not st.battle.is_empty() \
			or not st.pending_choice.is_empty():
		return {}
	var p := st.player(seat)
	var spare := p.reserve_cores - _flash_reserve()
	if spare <= 0:
		return {}
	var best_uid := -1
	var best_n := 0
	var best_value := 0.0
	for ci: CardInstance in st.field_spirits(seat):
		var lv := ci.current_level()
		for l: Dictionary in ci.data.levels:
			var to := int(l["level"])
			if to <= lv:
				continue
			var need := int(l["core_cost"]) - ci.total_cores()
			if need <= 0 or need > spare:
				continue
			var value := (ci.data.base_bp(to) - ci.data.base_bp(lv)) / 100.0
			for e: Dictionary in ci.data.effects:
				var lvls: Array = e.get("levels", [])
				if lvls.has(to) and not lvls.has(lv):
					value += 25.0              # an effect switches on
			# A spirit that can still attack this turn gains the most.
			if ci.is_refreshed():
				value *= 1.3
			value /= float(need)
			if value > best_value:
				best_value = value
				best_uid = ci.uid
				best_n = need
	if best_uid < 0 or best_value < 5.0:
		return {}
	return {"verb": BSS.Action.MOVE_CORE, "from": GameState.pool(seat, BSS.Zone.RESERVE),
			"to": GameState.on_card(best_uid), "n": best_n}


## Reserve cores to hold back for the cheapest flash magic in hand.
func _flash_reserve() -> int:
	var cheapest := 0
	for uid in engine.state.player(seat).hand:
		var ci: CardInstance = engine.state.cards[uid]
		if ci.data == null or not ci.data.is_magic():
			continue
		for e: Dictionary in ci.data.effects:
			if str(e.get("window", "")) in ["flash", "both"]:
				var c := engine.compute_cost(seat, ci.data)
				if cheapest == 0 or c < cheapest:
					cheapest = c
	return cheapest


## Scores are in arbitrary units; only their ordering matters. The weights are
## tuned so that: winning beats everything, board development beats card
## advantage, and ending a step is always the last resort.
func _score(action: Dictionary) -> float:
	var st := engine.state
	var verb := str(action.get("verb", ""))
	match verb:
		BSS.Action.SUMMON:
			var ci: CardInstance = st.card(int(action.get("uid", -1)))
			if ci == null: return 0.0
			# Prefer spending most of the reserve, and prefer bigger bodies.
			var cost := engine.compute_cost(seat, ci.data)
			# A spirit arrives with its LV1 core cost taken from the reserve.
			# If paying the cost leaves too few, it is destroyed on arrival --
			# legal, and a pure waste of a card. The bot was doing exactly this
			# (seen in the 0.6.0 screen tour: "summoned Halo Warden (cost 0).
			# Halo Warden was destroyed.").
			if _payment_for(action) == null:
				return -1000.0                 # it would die on arrival (0.11.0)
			var bp := ci.data.max_bp()
			var symbols := ci.data.symbol_count()
			return 100.0 + bp / 1000.0 + symbols * 8.0 - abs(_reserve() - cost) * 2.0 \
					+ _summon_effect_value(ci)
		BSS.Action.PLACE:
			# Nexuses pay off over time, so they are worth most early and while
			# the board is healthy. Before 0.9.0 this scored below every summon,
			# the bot spent its cores on spirits first, and it never placed a
			# single nexus (R-045).
			var nx: CardInstance = st.card(int(action.get("uid", -1)))
			var have := st.field_nexuses(seat).size()
			var early := 30.0 if st.turn_number <= 6 else 0.0
			var dup := 0.0
			for n in st.field_nexuses(seat):
				if nx != null and n.data != null and n.data.id == nx.data.id:
					dup = 40.0
			return 95.0 + early - have * 15.0 - dup + _life(seat) * 2.0
		BSS.Action.USE_MAGIC:
			return _score_magic(action)
		BSS.Action.ACTIVATE:
			if action.has("effect") and not action.has("keyword"):
				return _score_activated(action)
			return _score_awaken(action)
		BSS.Action.SET_BURST:
			return 45.0 if st.player(seat).burst < 0 else -10.0
		BSS.Action.DECLARE_ATTACK:
			return _score_attack(int(action.get("uid", -1)))
		BSS.Action.DECLARE_BLOCK:
			return _score_block(int(action.get("uid", -1)))
		BSS.Action.DECLINE_BLOCK:
			# Taking damage is fine while life is healthy; awful at 1 life.
			var incoming := _incoming_damage()
			return 30.0 - incoming * 25.0 if _life(seat) > incoming else -500.0
		BSS.Action.END_MAIN:
			return 10.0
		BSS.Action.END_ATTACK:
			return 5.0
		BSS.Action.FLASH_PASS:
			return 20.0
	return 0.0


## What a magic effect would actually do right now (0.9.0, R-045): a destroy
## with nothing to hit is worthless; one that removes a big spirit is worth
## more than a summon; a BP boost matters in a battle it would swing.
func _score_magic(action: Dictionary) -> float:
	var st := engine.state
	var ci: CardInstance = st.card(int(action.get("uid", -1)))
	if ci == null or ci.data == null:
		return 0.0
	var idx := int(action.get("effect", 0))
	if idx >= ci.data.effects.size():
		return 0.0
	var spec: Dictionary = ci.data.effects[idx]
	var frame := {"source": ci.uid, "controller": seat}
	# "If it is your opponent's turn, ..." (0.11.1): a condition that is not
	# met means the card would do nothing.
	if spec.has("condition") and not engine.effects.check_condition(seat, spec["condition"], frame):
		return -60.0
	var score := 0.0
	for d: Dictionary in spec.get("directives", []):
		var op := str(d.get("op", ""))
		match op:
			"destroy":
				var pool := engine.effects.collect_targets(seat, d.get("target", {}), frame)
				if pool.is_empty():
					return -50.0                   # nothing to hit: keep the card
				var tsp: Dictionary = d.get("target", {})
				var hit: Array = pool.slice(0, mini(pool.size(), int(tsp.get("count", 1))))
				if tsp.has("cost_budget"):
					# combined-cost removal (0.11.2): the biggest set that fits
					var big := pool.duplicate()
					big.sort_custom(func(a: CardInstance, b: CardInstance) -> bool:
						return a.current_bp() > b.current_bp())
					var uids: Array = []
					for t0: CardInstance in big: uids.append(t0.uid)
					hit = []
					for u: Variant in engine.effects._within_budget(uids, int(tsp["cost_budget"])):
						hit.append(st.card(int(u)))
					if hit.is_empty():
						return -50.0
				for t in hit:
					score += 60.0 + (t as CardInstance).current_bp() / 200.0
			"exhaust":
				var pool2 := engine.effects.collect_targets(seat, d.get("target", {}), frame)
				var refreshed := pool2.filter(func(t: CardInstance) -> bool: return t.is_refreshed())
				if refreshed.is_empty():
					return -40.0
				score += 70.0 if not st.battle.is_empty() else 45.0
			"draw":
				score += 35.0 + 15.0 * int(d.get("amount", 1))
			"add_core_from_void":
				score += 20.0 + 8.0 * int(d.get("amount", 1))
			"remove_cores":
				# Purple: worth most when it empties a spirit outright.
				var pool3 := engine.effects.collect_targets(seat, d.get("target", {}), frame)
				if pool3.is_empty():
					return -45.0
				var kills := 0
				for t: CardInstance in pool3:
					if t.total_cores() - int(d.get("amount", 1)) < t.data.min_level_cost():
						kills += 1
				var hits := pool3.size() if bool((d.get("target", {}) as Dictionary).get("all", false)) else 1
				score += 25.0 * hits + 55.0 * mini(kills, hits)
			"return_to_hand":
				var pool4 := engine.effects.collect_targets(seat, d.get("target", {}), frame)
				if pool4.is_empty():
					return -40.0
				score += 50.0
			"refresh":
				var pool5 := engine.effects.collect_targets(seat, d.get("target", {}), frame)
				var tired := pool5.filter(func(t: CardInstance) -> bool: return t.is_exhausted())
				if tired.is_empty():
					return -35.0
				# A fresh blocker in the opponent's attack is the point of it.
				score += 80.0 if not st.battle.is_empty() and int(st.battle.get("defending_player", -1)) == seat \
						else 30.0 * tired.size()
			"life_gain":
				score += 30.0 + (40.0 if _life(seat) <= 2 else 0.0)
			"mill":
				score += 6.0 * int(d.get("amount", 1)) \
						+ (60.0 if st.player(st.opponent_of(seat)).deck.size() <= int(d.get("amount", 1)) else 0.0)
			"summon_from":
				var pool6 := engine.effects.collect_targets(seat, d.get("target", {}), frame)
				if pool6.is_empty():
					return -45.0
				score += 70.0
			"set_flag", "set_bp":
				var pool7 := engine.effects.collect_targets(seat, d.get("target", {}), frame)
				if pool7.is_empty() or st.turn_player != seat:
					return -30.0
				score += 20.0 * pool7.size()
			"add_bp":
				var battle: Dictionary = st.battle
				if battle.is_empty():
					score += 10.0                  # a main-step boost rarely matters
				else:
					var mine := int(battle.get("attacker", -1))
					if int(battle.get("defending_player", -1)) == seat:
						mine = int(battle.get("blocker", -1))
					var me: CardInstance = st.card(mine)
					var foe: CardInstance = st.card(int(battle.get("blocker", -1)) if mine == int(battle.get("attacker", -1)) else int(battle.get("attacker", -1)))
					if me != null and foe != null and me.current_bp() <= foe.current_bp() \
							and me.current_bp() + int(d.get("amount", 0)) > foe.current_bp():
						score += 150.0             # this flips the battle
					else:
						score += 5.0
			_:
				score += 15.0
	return score


## Awaken (0.11.0): pull idle cores onto this spirit. Worth a lot when it
## turns the battle this spirit is in; worth something when it raises the
## spirit's level in the main step; otherwise not worth doing.
## An activated effect such as "destroy this nexus to draw two" (0.15.0):
## worth it late in the game or when it answers an attacker; otherwise the
## card is worth more left where it is.
func _score_activated(action: Dictionary) -> float:
	var st := engine.state
	var ci: CardInstance = st.card(int(action.get("uid", -1)))
	if ci == null or ci.data == null:
		return 0.0
	var sp: Array = ci.active_effects()
	var i := int(action.get("effect", 0))
	if i >= sp.size():
		return 0.0
	var spec: Dictionary = sp[i]
	# "Put all cores from one of your other Star Dragon spirits onto this spirit
	# to refresh it" (BSS05-004): only worth it to attack again (0.15.0)
	for d0: Dictionary in spec.get("directives", []):
		if str(d0.get("op", "")) == "absorb_cores":
			return 40.0 if ci.is_exhausted() else -20.0      # stands up to attack or block again
	var costly := false
	for c: Dictionary in spec.get("cost", []):
		if str(c.get("op", "")) == "destroy_self":
			costly = true
	var score := 12.0
	if not st.battle.is_empty() and int(st.battle.get("defending_player", -1)) == seat:
		score += 25.0                      # something to do while defending
	if _life(seat) <= 2:
		score += 20.0
	return score - (15.0 if costly and st.turn_number < 8 else 0.0)


func _score_awaken(action: Dictionary) -> float:
	var st := engine.state
	var ci: CardInstance = st.card(int(action.get("uid", -1)))
	if ci == null or ci.data == null:
		return 0.0
	var extra := 0
	for src: Dictionary in action.get("sources", []):
		extra += int(src.get("n", 0))
	var now_lv := ci.current_level()
	var new_lv := ci.data.level_for_cores(ci.total_cores() + extra)
	var gain := ci.data.base_bp(new_lv) - ci.data.base_bp(now_lv)
	if not st.battle.is_empty():
		var atk := int(st.battle.get("attacker", -1))
		var blk := int(st.battle.get("blocker", -1))
		if ci.uid != atk and ci.uid != blk:
			return -10.0
		var foe: CardInstance = st.card(blk if ci.uid == atk else atk)
		if foe != null and ci.current_bp() <= foe.current_bp() and ci.current_bp() + gain > foe.current_bp():
			return 160.0                       # this wins the battle
		return -10.0
	if new_lv > now_lv:
		return 12.0 + gain / 1000.0 * 3.0
	return -10.0


## What a spirit's own When Summoned effects are worth right now (0.10.0):
## a removal effect with a target is worth a lot, one without is worth nothing.
func _summon_effect_value(ci: CardInstance) -> float:
	var v := 0.0
	var frame := {"source": ci.uid, "controller": seat}
	for e: Dictionary in ci.data.effects:
		var timing := str(e.get("timing", ""))
		if timing == "keyword":
			v += 6.0
			continue
		if timing != "on_summon":
			v += 4.0
			continue
		for d: Dictionary in e.get("directives", []):
			match str(d.get("op", "")):
				"destroy", "remove_cores", "return_to_hand", "summon_from", "exhaust":
					var t: Dictionary = d.get("target", {})
					if str(t.get("zone", "field")) == "self":
						v += 8.0
					elif not engine.effects.collect_targets(seat, t, frame).is_empty():
						v += 30.0
				"draw", "add_core_from_void", "life_gain", "mill":
					v += 12.0
				_:
					v += 6.0
	return v


func _score_attack(uid: int) -> float:
	var st := engine.state
	var ci: CardInstance = st.card(uid)
	if ci == null: return 0.0
	var opp := st.opponent_of(seat)
	var my_bp := ci.current_bp()
	var symbols := ci.symbol_count()

	# Lethal check dominates everything else (1-2-1-1-1).
	if _best_blocker_bp(opp) <= 0 and st.player(opp).life_total() <= symbols:
		return 10000.0

	var score := 80.0 + symbols * 20.0
	var blocker_bp := _best_blocker_bp(opp)
	if blocker_bp > my_bp:
		score -= 60.0                  # walking into a losing trade
	elif blocker_bp > 0 and blocker_bp < my_bp:
		score += 30.0                  # favourable trade on offer
	# 11-2 Confront makes an attack much stronger: the defender must block.
	if ci.has_keyword(BSS.Keyword.CONFRONT):
		score += 25.0
	# 11-14 Astral often means the attack simply cannot be stopped.
	if engine.keywords.astral_active(ci):
		score += 45.0
	# Keeping a blocker home matters once life is low.
	if bool(profile["holds_blocker"]) and _life(seat) <= 2 and _refreshed_spirits(seat) <= 1:
		score -= 70.0
	# 0.10.0: a spirit built to defend stays home to defend. An attack exhausts
	# it until our next refresh step, so attacking with it means it cannot
	# block. Before this the AI attacked with everything and white -- the
	# colour that wins by blocking -- never blocked (ColourMatrix, I-020).
	if bool(profile["holds_blocker"]):
		score -= _defender_value(ci)
	return score


## How much this spirit is worth kept at home as a blocker next turn.
func _defender_value(ci: CardInstance) -> float:
	var opp := engine.state.opponent_of(seat)
	var foes := engine.state.field_spirits(opp)
	if foes.is_empty():
		return 0.0
	var biggest := 0
	for f in foes:
		biggest = maxi(biggest, f.current_bp())
	var guard := ci.current_bp() + _block_bonus(ci) + _opponent_turn_bonus(ci)
	var v := 0.0
	if _block_bonus(ci) > 0 or _refreshes_on_block(ci):
		v += 45.0                       # a card made for blocking
	if _opponent_turn_bonus(ci) > 0:
		v += 30.0
	if guard > biggest:
		v += 40.0                       # it would win the block outright
	if _life(seat) <= 3:
		v += 25.0
	return v


func _block_bonus(ci: CardInstance) -> int:
	var n := 0
	for e: Dictionary in ci.active_effects():
		if str(e.get("timing", "")) != "on_block":
			continue
		for d: Dictionary in e.get("directives", []):
			if str(d.get("op", "")) == "add_bp":
				n += int(d.get("amount", 0))
	return n


func _refreshes_on_block(ci: CardInstance) -> bool:
	for e: Dictionary in ci.active_effects():
		if str(e.get("timing", "")) == "on_block":
			for d: Dictionary in e.get("directives", []):
				if str(d.get("op", "")) == "refresh":
					return true
	return false


func _opponent_turn_bonus(ci: CardInstance) -> int:
	var n := 0
	for e: Dictionary in ci.active_effects():
		if str(e.get("kind", "")) == "constant" and str(e.get("during", "")) == "opponent_turn":
			for d: Dictionary in e.get("directives", []):
				if str(d.get("op", "")) == "add_bp":
					n += int(d.get("amount", 0))
	return n


func _score_block(uid: int) -> float:
	var st := engine.state
	var blocker: CardInstance = st.card(uid)
	var attacker: CardInstance = st.card(int(st.battle.get("attacker", -1)))
	if blocker == null or attacker == null:
		return 0.0
	# "When Blocks: +3000 BP" counts towards the clash (0.10.0).
	var mine := blocker.current_bp() + _block_bonus(blocker)
	var theirs := attacker.current_bp()
	var incoming := attacker.symbol_count()
	var score := 0.0
	if _refreshes_on_block(blocker):
		score += 25.0                  # it will stand up again
	if mine > theirs:
		score += 120.0                 # free kill
	elif mine == theirs:
		score += 20.0                  # even trade
	else:
		score -= 40.0                  # chump block
	# Chumping is correct when the alternative is losing.
	if _life(seat) <= incoming:
		score += 900.0
	# 11-3 Curse kills the blocker regardless of BP, so blocking is much worse.
	if attacker.has_keyword(BSS.Keyword.CURSE):
		score -= 80.0
	return score


func _answer_choice(pc: Dictionary) -> Dictionary:
	match str(pc.get("type", "")):
		"turn_order":
			# 0.20.0: won the coin toss. With two or more cheap cards the hand can
			# build a field at once, so go first; a slow hand takes the extra draw.
			var cheap0 := 0
			for uid in engine.state.player(seat).hand:
				var c0: CardInstance = engine.state.cards[uid]
				if c0.data.cost <= 3: cheap0 += 1
			return {"verb": BSS.Action.CHOOSE_ORDER, "first": cheap0 >= 2}
		"mulligan":
			# Keep a hand with two or three playable cheap cards.
			var cheap := 0
			for uid in engine.state.player(seat).hand:
				var ci: CardInstance = engine.state.cards[uid]
				if ci.data.cost <= 3: cheap += 1
			return {"verb": (BSS.Action.KEEP_HAND if cheap >= 2 else BSS.Action.MULLIGAN)}
		"select_cards":
			var opts: Array = pc.get("options", [])
			var n := int(pc.get("count", 1))
			var op := str(((pc.get("resume", {}) as Dictionary).get("op", {}) as Dictionary).get("op", ""))
			var rop: Dictionary = (pc.get("resume", {}) as Dictionary).get("op", {})
			if rop.has("_reveal"):
				# Reveal choices (0.16.1): scry bottoms what we cannot afford
				# soon; a search takes the most expensive legal card.
				if op == "scry":
					var budget0 := engine.state.player(seat).total_reserve() + 2
					var bottom: Array = []
					for su0: Variant in opts:
						var sc0: CardInstance = engine.state.card(int(su0))
						if sc0 != null and engine.compute_cost(seat, sc0.data) > budget0:
							bottom.append(int(su0))
					return {"verb": BSS.Action.RESOLVE_CHOICE, "choice": bottom}
				var by_cost: Array = opts.duplicate()
				by_cost.sort_custom(func(a: Variant, b: Variant) -> bool:
					var ca0: CardInstance = engine.state.card(int(a))
					var cb0: CardInstance = engine.state.card(int(b))
					return (ca0.data.cost if ca0 else 0) > (cb0.data.cost if cb0 else 0))
				return {"verb": BSS.Action.RESOLVE_CHOICE, "choice": by_cost.slice(0, n)}
			if op == "remove_cores":
				# Purple: strip the spirit closest to empty, so it dies.
				var thin: Array = opts.duplicate()
				thin.sort_custom(func(a: Variant, b: Variant) -> bool:
					var ca: CardInstance = engine.state.card(int(a))
					var cb: CardInstance = engine.state.card(int(b))
					var sa := (ca.total_cores() - ca.data.min_level_cost()) if ca else 99
					var sb := (cb.total_cores() - cb.data.min_level_cost()) if cb else 99
					# "select one spirit" may offer our own (0.11.1): theirs first
					if ca != null and ca.controller_id == seat: sa += 100
					if cb != null and cb.controller_id == seat: sb += 100
					return sa < sb)
				return {"verb": BSS.Action.RESOLVE_CHOICE, "choice": thin.slice(0, n)}
			if op == "bounce_same_cost":
				# "Return it and every spirit with the same cost" (BSS05-052, 0.15.0):
				# the cost that sends back more of theirs than of ours, or none
				var best_u := -1
				var best_gain := 0
				for u0: Variant in opts:
					var c0: CardInstance = engine.state.card(int(u0))
					if c0 == null:
						continue
					var gain := 0
					for o0 in engine.state.all_field_cards():
						if o0.data != null and o0.data.is_spirit() and o0.effective_cost() == c0.effective_cost():
							gain += 1 if o0.controller_id != seat else -1
					if gain > best_gain:
						best_gain = gain
						best_u = int(u0)
				return {"verb": BSS.Action.RESOLVE_CHOICE, "choice": [best_u] if best_u >= 0 else []}
			# Pick the biggest spirits first. "Select one spirit" may offer
			# both sides (0.11.2): a boost goes on ours, anything else on theirs.
			var od: Dictionary = (pc.get("resume", {}) as Dictionary).get("op", {})
			var helps := op in ["refresh", "treat_as_level", "add_core_from_void", "grant_keyword"] \
					or (op == "add_bp" and int(od.get("amount", 0)) > 0)
			var sorted: Array = opts.duplicate()
			sorted.sort_custom(func(a: Variant, b: Variant) -> bool:
				var ca: CardInstance = engine.state.card(int(a))
				var cb: CardInstance = engine.state.card(int(b))
				return _pick_value(ca, helps) > _pick_value(cb, helps))
			var budget := int(pc.get("cost_budget", -1))
			if budget >= 0:
				return {"verb": BSS.Action.RESOLVE_CHOICE,
						"choice": engine.effects._within_budget(sorted, budget)}
			return {"verb": BSS.Action.RESOLVE_CHOICE, "choice": sorted.slice(0, n)}
		"option":
			# Branch 0 is by convention the "do the thing" branch.
			var take := difficulty >= Difficulty.NORMAL
			return {"verb": BSS.Action.RESOLVE_CHOICE, "choice": (0 if take else 1)}
		"discard":
			var hand: Array = pc.get("options", [])
			var n2 := int(pc.get("count", 1))
			if bool(pc.get("any", false)):
				# "Discard any number of cards" (BSS06-104, 0.15.0): as many as are
				# useful, the cheapest first
				var cheap: Array = hand.duplicate()
				cheap.sort_custom(func(a: Variant, b: Variant) -> bool:
					var ca0: CardInstance = engine.state.card(int(a))
					var cb0: CardInstance = engine.state.card(int(b))
					return (ca0.data.cost if ca0 else 0) < (cb0.data.cost if cb0 else 0))
				return {"verb": BSS.Action.RESOLVE_CHOICE,
						"choice": cheap.slice(0, mini(int(pc.get("max_useful", 0)), cheap.size()))}
			var by_cost: Array = hand.duplicate()
			by_cost.sort_custom(func(a: Variant, b: Variant) -> bool:
				var ca: CardInstance = engine.state.card(int(a))
				var cb: CardInstance = engine.state.card(int(b))
				return (ca.data.cost if ca else 0) > (cb.data.cost if cb else 0))
			return {"verb": BSS.Action.RESOLVE_CHOICE, "choice": by_cost.slice(0, n2)}
	return {"verb": BSS.Action.RESOLVE_CHOICE, "choice": 0}


## How much the AI wants to pick this card for an effect (0.14.0). Good
## for us (a boost on ours, removal on theirs): the biggest first. Bad for us
## (we must destroy one of our own, Deadly Balance): the smallest first.
func _pick_value(ci: CardInstance, helps: bool) -> float:
	if ci == null:
		return -1e9
	var bp := float(ci.current_bp())
	if (ci.controller_id == seat) == helps:
		return 100000.0 + bp
	return -bp


## The action taken when the chosen one turned out to be illegal. Always legal
## by construction, so the pump loop in MatchService can always make progress.
func safe_fallback() -> Dictionary:
	var st := engine.state
	if not st.pending_choice.is_empty() and int(st.pending_choice.get("player", -1)) == seat:
		return {"verb": BSS.Action.RESOLVE_CHOICE, "choice": 0}
	if engine._in_flash_window(seat):
		return {"verb": BSS.Action.FLASH_PASS}
	if not st.battle.is_empty() and int(st.battle.get("phase", 0)) == BSS.BattlePhase.BLOCK_DECLARATION:
		return {"verb": BSS.Action.DECLINE_BLOCK}
	if st.turn_player == seat:
		if st.step == BSS.Step.MAIN: return {"verb": BSS.Action.END_MAIN}
		if st.step == BSS.Step.ATTACK:
			# a spirit that "must attack if able" has to go first (0.12.0)
			var must := engine.must_attack_pending(seat)
			if must != null:
				return {"verb": BSS.Action.DECLARE_ATTACK, "uid": must.uid}
			return {"verb": BSS.Action.END_ATTACK}
	return {}


# --- Small board queries ---------------------------------------------------

func _life(pid: int) -> int:
	return engine.state.player(pid).life_total()

func _reserve() -> int:
	return engine.state.player(seat).total_reserve()

func _refreshed_spirits(pid: int) -> int:
	var n := 0
	for ci in engine.state.field_spirits(pid):
		if ci.is_refreshed(): n += 1
	return n

func _best_blocker_bp(pid: int) -> int:
	var best := 0
	for ci in engine.state.field_spirits(pid):
		if ci.is_refreshed():
			best = max(best, ci.current_bp())
	return best

func _incoming_damage() -> int:
	var atk: CardInstance = engine.state.card(int(engine.state.battle.get("attacker", -1)))
	return atk.symbol_count() if atk != null else 1
