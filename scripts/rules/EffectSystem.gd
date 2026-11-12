extends RefCounted
class_name EffectSystem
##
## Interpreter for card text (Comprehensive Rules section 8).
##
## Card effects are data, not code. Each card carries a list of EffectSpec
## dictionaries and this class executes them. That choice is deliberate: with
## roughly a thousand printed cards and a new set every few months, hand-writing
## a GDScript file per card does not scale, and a data format can be produced by
## the scraper and hot-reloaded without a rebuild.
##
## EffectSpec shape (see docs/CODE_ARCHITECTURE.md for the full reference):
##
##   {
##     "kind":    "triggered" | "activated" | "constant" | "magic",
##     "timing":  "on_summon" | "on_attack" | "when_destroyed" | "burst" | ...,
##     "window":  "main" | "flash" | "both",        # activated/magic only
##     "levels":  [1, 2, 3],                        # 2-10-2 level gating
##     "condition": { ... },                        # optional gate
##     "cost":    [ {directive}, ... ],             # 8-4 effect cost
##     "directives": [ {op, ...}, ... ],
##     "keyword": "Crush", "keyword_value": 1       # keyword-granting effects
##   }
##
## Anything the interpreter cannot express falls back to a named GDScript hook
## in scripts/cards/ via the "script" op -- the escape hatch for the handful of
## genuinely weird cards every TCG has.
##

var engine: RulesEngine
var state: GameState

# Continuous effect directives currently applied, so they can be revoked at the
# right time (8-2-2-2, 6-8-1-2).
var continuous: Array = []      # [{duration, uid, undo:Callable-ish Dictionary}]
# Windows like "while attacking" that gate constant effects (7-1-6-2).
var active_windows: Dictionary = {}

# 8-5: an effect that triggers WHILE another effect is resolving waits until
# that one has finished. Before 0.8.0 the new trigger called resolve_top()
# from inside the running effect, which re-ran the unfinished effect: a magic
# card that destroyed a spirit destroyed it again, and again, until the stack
# overflowed (R-038). `_depth` counts directives being executed right now;
# frames pushed meanwhile wait in `_deferred`.
var _depth := 0
var suppress_when_destroyed := false   # "their When Destroyed effects are not triggered" (0.14.0)
var _deferred: Array = []


var _rule_by_uid := -1      # the card whose effect is removing cores right now (0.15.0)
# "When one of your effects exhausts one of your opponent's spirits" (0.15.0, BSS03-114):
# uid -> the player whose effect exhausted it, read by RulesEngine._detect_changes.
var exhausted_by: Dictionary = {}
# nexuses whose nexus_exhausted exhaust_nexus already fired; _detect_changes skips them (0.15.0)
var nexus_exhaust_fired: Dictionary = {}


func _init(p_engine: RulesEngine) -> void:
	engine = p_engine
	state = p_engine.state


# ===========================================================================
# 8-5 Activation and resolution
# ===========================================================================

## 8-5-2-3 -- push an activated effect; it now waits to resolve.
func push(source: CardInstance, spec: Dictionary, controller: int, meta: Dictionary = {}) -> void:
	var frame := {
		"source": source.uid if source != null else -1,
		"spec": spec,
		"controller": controller,
		"meta": meta,
		"dir_index": 0,
	}
	if _depth > 0:
		_deferred.append(frame)         # waits for the running effect (R-038)
	else:
		state.effect_stack.append(frame)
	# "ops" (0.10.0) lets tests and tools see what the effect does without
	# re-deriving it from the card.
	var ops: Array = []
	for d: Dictionary in spec.get("directives", []):
		ops.append(str(d.get("op", "")))
	state.log_event("effect_pushed", {"source": source.uid if source else -1, "ops": ops})


## Frames that triggered during a resolution join the stack once it is done.
## Pushed in trigger order, so the newest resolves first (8-5-2-4).
func _flush_deferred() -> void:
	if _depth > 0 or _deferred.is_empty():
		return
	for f: Dictionary in _deferred:
		state.effect_stack.append(f)
	_deferred.clear()


## Run directives with the re-entrancy guard held.
func _guarded(fn: Callable) -> Variant:
	_depth += 1
	var r: Variant = fn.call()
	_depth -= 1
	return r


## 8-5-2-4 -- resolve the most recently activated effect first.
func resolve_top() -> void:
	if _depth > 0:
		return                           # the running loop picks it up (R-038)
	_flush_deferred()
	var guard := 0
	while not state.effect_stack.is_empty() and state.pending_choice.is_empty() and guard < 128:
		guard += 1
		var frame: Dictionary = state.effect_stack[state.effect_stack.size() - 1]
		var done: bool = _guarded(func() -> bool: return _run_frame(frame))
		if not done:
			return                       # parked on a choice; resume later
		state.effect_stack.pop_back()
		_finish_frame(frame)
		_flush_deferred()
		engine.run_checkpoints()
		_flush_deferred()


func _finish_frame(frame: Dictionary) -> void:
	var meta: Dictionary = frame.get("meta", {})
	# "Burst: When Opponent Resolves a When Summoned" (0.24.0, R-158): a
	# spirit's own When Summoned effect has resolved -- offer the opponent's
	# burst now. Not when the effect did not apply: its "if ..." condition
	# was not met (Absolute Divinity Amaterasu Dragon with fewer than ten
	# symbols).
	var fspec: Dictionary = frame.get("spec", {})
	if str(fspec.get("timing", "")) == "on_summon" and str(fspec.get("scope", "self")) == "self" \
			and not bool((frame.get("flags", {}) as Dictionary).get("_cond_failed", false)):
		var summoner := int(frame.get("controller", -1))
		if summoner >= 0:
			state.log_event("when_summoned_resolved", {"uid": int(frame.get("source", -1)), "player": summoner})
			engine.keywords.offer_bursts(state.opponent_of(summoner), "opponent_summon_effect")
	if meta.has("burst_followup"):
		var bc: CardInstance = state.card(int(meta["burst_followup"]))
		if bc != null:
			engine.keywords.offer_burst_followup(int(frame["controller"]), bc)
	if bool(meta.get("magic", false)):
		# 10-8-8 -- the magic card goes to the trash after resolution.
		var ci: CardInstance = state.card(int(frame["source"]))
		if ci != null:
			ci.flags.erase("resolving")
			if not state.battle.is_empty():
				state.battle["magic_used"].append(ci.uid)    # 11-6 Luster
			# "If ..., return this card to your hand" (0.15.0, BSS05-121): op magic_to_hand
			if bool((frame.get("flags", {}) as Dictionary).get("magic_to_hand", false)):
				state.move_card(ci.uid, BSS.Zone.HAND, ci.owner_id)
			else:
				state.move_card(ci.uid, BSS.Zone.TRASH, ci.owner_id)
	# "When you use a magic card from your hand, ... after its effect resolves"
	# (0.15.0, BSS05-036 / -047 / -114, BSS06-092): fired once the magic -- its
	# Chains included -- is done, and only for magic used from the hand. Before,
	# they fired as soon as the magic parked on a choice and resolved BEFORE it.
	var after: Array = meta.get("after_triggers", [])
	if bool(meta.get("from_hand", false)):
		var mpid := int(frame["controller"])
		if bool(meta.get("soul_spent", false)):
			after = after + [["soul_spent_on_magic", {"player": mpid}]]
		after = after + [["magic_used", {"player": mpid, "uid": int(frame["source"])}]]
	if bool(meta.get("burst", false)):
		# 10-9-4 -- a resolved burst goes to the trash.
		var ci2: CardInstance = state.card(int(frame["source"]))
		if ci2 != null:
			state.move_card(ci2.uid, BSS.Zone.TRASH, ci2.owner_id)
	# 11-15 Chain -- an effect that continues into another if a colour condition
	# is met. It is evaluated only after the parent effect finishes.
	var spec: Dictionary = frame["spec"]
	# (0.15.0) "chain" may be a list -- several "Chain: <colour>" on one effect
	# (BSS06-010, -020 ...), each checked on its own, in printed order. A chain
	# frame sees its parent's frame flags and trigger context, so "that nexus"
	# (last_target, BSS05-082) and "if you do" carry over. No chain when the
	# parent's own condition was unmet (8-3-3).
	var live: Array = []
	if spec.has("chain") and not bool((frame.get("flags", {}) as Dictionary).get("_cond_failed", false)):
		var chains: Array = spec["chain"] if typeof(spec["chain"]) == TYPE_ARRAY else [spec["chain"]]
		for ch: Variant in chains:
			if typeof(ch) == TYPE_DICTIONARY and _chain_condition_met(int(frame["controller"]), ch):
				live.append(ch)
	if live.is_empty():
		for a: Array in after:
			trigger(str(a[0]), a[1])
		return
	# pushed last-first, so the first printed Chain resolves first and a Chain
	# waiting on a choice keeps the later ones waiting under it; the "after it
	# resolves" triggers ride on the last one
	var csrc: CardInstance = state.card(int(frame["source"]))
	for i in range(live.size() - 1, -1, -1):
		var cmeta: Dictionary = {"ctx": (frame.get("meta", {}) as Dictionary).get("ctx", {}), "chain": true}
		if i == live.size() - 1 and not after.is_empty():
			cmeta["after_triggers"] = after
		state.effect_stack.append({"source": csrc.uid if csrc != null else -1, "spec": live[i],
				"controller": int(frame["controller"]), "meta": cmeta, "dir_index": 0,
				"flags": (frame.get("flags", {}) as Dictionary).duplicate()})
	resolve_top()


func _chain_condition_met(pid: int, chain: Dictionary) -> bool:
	# 11-15-3 -- Chain is live if you have a symbol of the named colour. A
	# split two-colour symbol counts for both of its colours (count_field_symbols).
	var col := BSS.color_from_string(str(chain.get("condition", "")))
	if col < 0:
		return true
	return int(state.player(pid).count_field_symbols(state).get(col, 0)) > 0


func _run_frame(frame: Dictionary) -> bool:
	var spec: Dictionary = frame["spec"]
	var ctrl := int(frame["controller"])
	# A chain's "condition" is its colour (checked in _finish_frame), not a
	# condition dictionary (0.15.0): only dictionaries are conditions.
	if spec.has("condition") and typeof(spec["condition"]) == TYPE_DICTIONARY \
			and not check_condition(ctrl, spec["condition"], frame):
		_frame_flag(frame, "_cond_failed")
		return true                                   # 8-3-3 condition unmet
	var dirs: Array = spec.get("directives", [])
	while int(frame["dir_index"]) < dirs.size():
		var d: Dictionary = dirs[int(frame["dir_index"])]
		# "Then, if you control a Shinji nexus, ..." (0.12.0): a directive
		# can carry its own condition, checked when it is reached.
		if d.has("if") and not check_condition(ctrl, d["if"], frame):
			frame["dir_index"] = int(frame["dir_index"]) + 1
			continue
		var res := execute(ctrl, d, frame)
		if res == "await":
			return false                              # parked on a choice
		frame["dir_index"] = int(frame["dir_index"]) + 1
	return true


# ===========================================================================
# 8-6 Triggered effects
# ===========================================================================

## 8-6-2 / 8-6-3 -- a trigger fires once per event even when its condition is
## satisfied several times at the same instant.
func trigger(timing: String, ctx: Dictionary = {}) -> void:
	var fired := {}
	var queued: Array = []
	var candidates: Array = []
	for ci in state.all_field_cards():
		candidates.append(ci)
	# Cards in the trash can carry Immortal; hand cards can carry Agile.
	for pid in 2:
		for uid in state.player(pid).trash:
			candidates.append(state.cards[uid])

	for ci in candidates:
		if ci.data == null:
			continue
		var in_trash: bool = ci.zone == BSS.Zone.TRASH
		var effs: Array = ci.active_effects()
		for ei in effs.size():
			var spec: Dictionary = effs[ei]
			if str(spec.get("timing", "")) != timing:
				continue
			# "At the start of the step, you may summon this spirit card from
			# your trash" (0.15.0, BSS05-012 / -043): from_trash effects work
			# only while the card is in its owner's trash, whatever their scope.
			var from_trash := bool(spec.get("from_trash", false))
			if from_trash != in_trash and (from_trash or str(spec.get("scope", "self")) != "self"):
				if from_trash or not (bool(spec.get("include_self", false)) and int(ctx.get("uid", -1)) == ci.uid):
					continue
			# "Once per turn" (0.10.0): green's refresh-on-attack and white's
			# refresh-on-block would otherwise loop forever.
			if bool(spec.get("once_per_turn", false)):
				var key := "opt:%s:%d" % [timing, ci.data.effects.find(spec)]
				if int(ci.flags.get(key, -1)) == state.turn_number:
					continue
				if _trigger_matches(ci, spec, ctx):
					ci.flags[key] = state.turn_number
			# (0.15.0) once per EFFECT per event: a card with two effects on
			# the same timing fires both (BSS06-011, BSS06-083, BSS01-028 ...).
			# Before, it was keyed by card and only the first one fired.
			if fired.has([ci.uid, timing, ei]):
				continue
			if not _trigger_matches(ci, spec, ctx):
				continue
			fired[[ci.uid, timing, ei]] = true
			queued.append([ci, spec])
	# 0.24.0 (R-147): the same draw/discard effect from several copies of a
	# card (two Volcanic Canyons: "Draw one more card, then discard a card")
	# resolves once with the amounts added -- draw 2, then discard 2 -- not
	# draw 1, discard 1, draw 1, discard 1.
	for q: Array in _merge_same(queued):
		push(q[0], q[1], (q[0] as CardInstance).controller_id, {"ctx": ctx})
	# "This turn, when ..." (0.15.0): temporary triggers from resolved effects
	for e: Dictionary in state.delayed.duplicate():
		var dsp: Dictionary = e["spec"]
		var tms: Array = dsp.get("timings", [])
		if str(dsp.get("timing", "")) != timing and not tms.has(timing):
			continue
		if int(e.get("target", -1)) >= 0 and int(ctx.get("uid", -2)) != int(e["target"]):
			continue
		var dsrc: CardInstance = state.card(int(e["source"]))
		if dsrc == null:
			continue
		var saved := dsrc.controller_id
		dsrc.controller_id = int(e["pid"])
		var ok_d := _trigger_matches(dsrc, dsp, ctx)
		dsrc.controller_id = saved
		if not ok_d:
			continue
		if bool(e.get("once", false)):
			state.delayed.erase(e)
		push(dsrc, dsp, int(e["pid"]), {"ctx": ctx})
	if not state.effect_stack.is_empty():
		# 8-5-2-4 -- when several activate at once, the turn player orders them.
		resolve_top()


## Triggered effects that are the same card's same effect for the same
## player, and only draw / discard, become one with the amounts added
## (0.24.0, R-147). Anything else is left as it is, in order.
const MERGEABLE_OPS := ["draw", "discard"]


func _merge_same(queued: Array) -> Array:
	var out: Array = []
	var by_key := {}
	for q: Array in queued:
		var ci: CardInstance = q[0]
		var spec: Dictionary = q[1]
		var dirs: Array = spec.get("directives", [])
		var ok := not dirs.is_empty() and spec.get("choice", null) == null and not bool(spec.get("optional", false))
		for d: Variant in dirs:
			if not (d is Dictionary) or not str((d as Dictionary).get("op", "")) in MERGEABLE_OPS \
					or (d as Dictionary).has("if") or (d as Dictionary).has("condition"):
				ok = false
		if not ok or ci.data == null:
			out.append(q)
			continue
		var key := "%d|%s|%s" % [ci.controller_id, ci.data.name, JSON.stringify(dirs)]
		if not by_key.has(key):
			by_key[key] = out.size()
			out.append([ci, spec.duplicate(true), 1])
			continue
		var merged: Array = out[int(by_key[key])]
		merged[2] = int(merged[2]) + 1
		var mspec: Dictionary = merged[1]
		var mdirs: Array = mspec.get("directives", [])
		for i in mdirs.size():
			var md: Dictionary = mdirs[i]
			md["amount"] = int(md.get("amount", 1)) + int((dirs[i] as Dictionary).get("amount", 1))
		mspec["merged_copies"] = int(merged[2])
	return out


const STEP_NAMES := {"start": 0, "core": 1, "draw": 2, "refresh": 3, "main": 4, "attack": 5, "end": 6}


## "During your attack step" and friends, for triggered and constant effects.
func during_ok(during: String, controller: int) -> bool:
	var mine := state.turn_player == controller
	var attack := state.step == BSS.Step.ATTACK
	match during:
		"your_attack_step": return mine and attack
		"opponent_attack_step": return not mine and attack
		"either_attack_step": return attack
		"your_turn": return mine
		"opponent_turn": return not mine
		"your_end_step": return mine and state.step == BSS.Step.END
		"your_main_step": return mine and state.step == BSS.Step.MAIN
		"either_main_step": return state.step == BSS.Step.MAIN
		"opponent_main_step": return not mine and state.step == BSS.Step.MAIN
	return true


func _trigger_matches(ci: CardInstance, spec: Dictionary, ctx: Dictionary) -> bool:
	# "During your core step ..." -- a start_of_step trigger can name its step
	# (0.9.0). Without this, a core-step effect fired at the start of every step.
	if spec.has("step"):
		if int(ctx.get("step", -1)) != int(STEP_NAMES.get(str(spec["step"]), -2)):
			return false
	# "During your attack step, when ..." (0.11.0)
	if spec.has("during") and not during_ok(str(spec["during"]), ci.controller_id):
		return false
	# "When your opponent's effect discards ..." / "when one of your effects
	# exhausts ..." (0.15.0, Set 3): who controlled the effect is ctx.by_player
	# (-1 for an attack, a block or a cost). "min_amount": at least N cards.
	if spec.has("by"):
		var byp := int(ctx.get("by_player", -1))
		match str(spec["by"]):
			"opponent":
				if byp < 0 or byp == ci.controller_id:
					return false
			"your_effect":
				if byp != ci.controller_id:
					return false
	if spec.has("min_amount") and int(ctx.get("amount", 0)) < int(spec["min_amount"]):
		return false
	# "When one of your Swift spirits ...", "a spirit with a When Blocks
	# effect": filters on the card that set the trigger off (0.11.0).
	if spec.has("trigger_filter"):
		var who: CardInstance = state.card(int(ctx.get("uid", -1)))
		if who == null or not _passes_filter(ci.controller_id, who,
				{"filters": spec["trigger_filter"], "card_type": str(spec.get("trigger_type", ""))},
				{"source": ci.uid}):
			return false
	var scope := str(spec.get("scope", "self"))
	# "When one of your yellow nexuses -- this one included -- ..." (0.15.0)
	if bool(spec.get("include_self", false)) and int(ctx.get("uid", -1)) == ci.uid:
		return true
	match scope:
		"you_lost_life":
			return int(ctx.get("player", -1)) == ci.controller_id
		"opponent_lost_life", "opponent_drew":
			return int(ctx.get("player", -1)) != ci.controller_id and int(ctx.get("player", -1)) >= 0
		"you":
			return int(ctx.get("player", -1)) == ci.controller_id
		"opponent":
			return int(ctx.get("player", -1)) != ci.controller_id and int(ctx.get("player", -1)) >= 0
		"self_or_keyword":
			# "When this spirit or one of your spirits with [Swift] ..."
			if int(ctx.get("uid", -1)) == ci.uid:
				return true
			var o: CardInstance = state.card(int(ctx.get("uid", -1)))
			var kwv := BSS.keyword_from_string(str(spec.get("scope_keyword", "")))
			return o != null and o.controller_id == ci.controller_id and kwv >= 0 and o.has_keyword(kwv)
		"battle_attacker":
			# battle_end: "while this spirit attacks ... when the battle ends"
			var b: Dictionary = ctx.get("battle", {})
			return int(b.get("attacker", -1)) == ci.uid
		"self":
			return int(ctx.get("uid", -1)) == ci.uid
		"your_spirits":
			var t: CardInstance = state.card(int(ctx.get("uid", -1)))
			return t != null and t.controller_id == ci.controller_id
		"opponent_spirits":
			var t2: CardInstance = state.card(int(ctx.get("uid", -1)))
			return t2 != null and t2.controller_id != ci.controller_id
		"any":
			return true
		"your_turn":
			return state.turn_player == ci.controller_id
		"opponent_turn":
			return state.turn_player != ci.controller_id
	return true


# ===========================================================================
# 8-4 Effect costs
# ===========================================================================

## 8-4-2-3 -- an effect cost is payable only if every part of it is payable, so
## we simulate first and commit second. Half-paying is never legal.
func pay_effect_cost(pid: int, source: CardInstance, spec: Dictionary, _action: Dictionary) -> bool:
	var cost: Array = spec.get("cost", [])
	if cost.is_empty():
		return true
	for c in cost:
		if not _can_pay_one(pid, source, c):
			return false                              # 8-4-2-4
	for c in cost:
		execute(pid, c, {"source": source.uid if source else -1, "controller": pid,
			"spec": spec, "dir_index": 0, "is_cost": true})
	return true


func _can_pay_one(pid: int, source: CardInstance, c: Dictionary) -> bool:
	match str(c.get("op", "")):
		"pay_cores":
			var n := int(c.get("amount", 0))
			var avail := state.player(pid).reserve_cores + state.player(pid).reserve_soul
			for uid in state.player(pid).field:
				avail += state.cards[uid].cores
			return avail >= n
		"discard":
			return state.player(pid).hand.size() >= int(c.get("amount", 1))
		"exhaust_self":
			return source != null and source.is_refreshed()
		"exhaust_nexus":
			for ci in state.field_nexuses(pid):
				if ci.is_refreshed(): return true
			return false
		"remove_cores_self":
			return source != null and source.total_cores() >= int(c.get("amount", 1))
		"destroy_self":
			return source != null and source.zone == BSS.Zone.FIELD
	return true


# ===========================================================================
# Directive interpreter
# ===========================================================================

## Executes one directive. Returns "" on success or "await" when the directive
## needs an answer from a player, in which case a pending_choice has been set
## and the caller must return control to the network layer.
func execute(pid: int, d: Dictionary, frame: Dictionary) -> String:
	var op := str(d.get("op", ""))
	match op:
		# --- 8-2-2-1 immediately resolving directives -----------------------
		"draw":
			var drawer := _who(pid, d)
			var want_n := int(d.get("amount", 1))
			# "Draw cards until you have four cards in your hand" (0.15.0, BSS06-012)
			if d.has("until_hand"):
				want_n = int(d["until_hand"]) - state.player(drawer).hand.size()
			# "Draw the same number of cards as your opponent has in their hand" (0.15.0, BSS06-065)
			if str(d.get("amount_of", "")) == "opponent_hand":
				want_n = state.player(state.opponent_of(pid)).hand.size()
			# "Your opponent draws two cards for each symbol on the destroyed spirit"
			# (0.15.0, BSS06-077): read from the card's printed symbols, wherever it is
			if str(d.get("per_symbols_of", "")) == "last_target":
				var pst: CardInstance = state.card(int((frame.get("flags", {}) as Dictionary).get("last_target", -1)))
				want_n *= pst.data.symbol_count() if pst != null and pst.data != null else 0
			# "Draw one card for each spirit destroyed by this effect" (0.15.0, BSS04-001)
			if d.has("per_flag"):
				want_n *= int((frame.get("flags", {}) as Dictionary).get(str(d["per_flag"]), 0))
			# "Neither player can draw cards with magic effects" (0.15.0, BSS03-103)
			if want_n <= 0 or _magic_draw_blocked(frame):
				return ""
			var got := 0
			# "Each time a player draws outside their draw step, they pay one
			# core per card" (0.15.0): a card that cannot be paid for is not drawn.
			var dtax := 0
			if not bool(frame.get("is_cost", false)):
				for p0 in 2:
					for r: Dictionary in active_rules(p0, "extra_draw_tax"):
						dtax += int((r["d"] as Dictionary).get("amount", 1))
			if dtax > 0:
				for i in want_n:
					if not _pay_cores_any(drawer, dtax):
						break
					got += state.draw(drawer, 1)
			else:
				got = state.draw(drawer, want_n)
			if got > 0 and not bool(frame.get("is_cost", false)):
				# "If your opponent drew a card with an effect they control this
				# turn" (0.15.0, BSS03-056)
				if drawer == pid:
					state.set_turn_flag(drawer, "drew_by_effect")
				# "When your opponent draws outside their draw step" (0.11.0):
				# a draw made by an effect is always outside the draw step.
				# by_player: whose effect it was (0.15.0, BSS03-073 / BSS04-110).
				trigger("extra_draw", {"player": drawer, "by_player": pid})
				trigger("added_to_hand", {"player": drawer})
		"mill":
			var mn := int(d.get("amount", 1))
			# "three cards for each nexus you control (twelve at most)" (0.15.0, BSS03-081)
			if d.has("per"):
				mn *= collect_targets(pid, d["per"], frame).size()
			# "cards equal to that spirit's cost" (0.15.0, BSS04-086)
			if str(d.get("amount_from", "")) == "last_target_cost":
				var mlt: CardInstance = state.card(int((frame.get("flags", {}) as Dictionary).get("last_target", -1)))
				mn = mlt.data.cost if mlt != null and mlt.data != null else 0
			# "... equal to the number of cores on this spirit" (0.15.0, BSS05-089)
			if bool(d.get("amount_self_cores", false)):
				var msc: CardInstance = state.card(int(frame.get("source", -1)))
				mn = msc.total_cores() if msc != null else 0
			# "the top card for each spirit destroyed this way" (0.15.0, BSS05-092)
			if bool(d.get("per_destroyed", false)):
				mn = int((frame.get("flags", {}) as Dictionary).get("destroyed_n", 0))
			# "... equal to the number of cards in their trash" (0.15.0, BSS06-076)
			if str(d.get("amount_of", "")) == "opponent_trash":
				mn = state.player(_who(pid, d)).trash.size()
			if d.has("max"):
				mn = mini(mn, int(d["max"]))
			# "... among the discarded cards" (0.15.0, BSS06-031): target zone "milled"
			_frame_flag(frame, "milled_uids", effect_mill(pid, _who(pid, d), mn))
		"discard":
			return _op_discard(pid, d, frame)
		"destroy":
			return _op_targeted(pid, d, frame, func(t: CardInstance):
				_destroy_by_effect(d, t, frame))
		"return_to_hand":
			return _op_targeted(pid, d, frame, func(t: CardInstance):
				if not _bounce_blocked(pid, t):
					_return_to_hand(t))
		"exhaust":
			return _op_targeted(pid, d, frame, func(t: CardInstance):
				_exhaust_or_instead(pid, d, t))
		"refresh":
			return _op_targeted(pid, d, frame, func(t: CardInstance):
				t.orientation = BSS.Orientation.REFRESHED
				_flag_also(d, t))
		"pay_soul":
			# "you may pay a soul core": from the reserve, else from your cards
			_pay_soul(pid, frame)
		"exhaust_self":
			var s: CardInstance = state.card(int(frame.get("source", -1)))
			if s: s.orientation = BSS.Orientation.EXHAUSTED
		"exhaust_nexus":
			# "Exhaust one of your nexuses" (0.15.0, BSS05-081 / -086): the player
			# picks which when there is a choice; as an effect cost it is the first.
			if bool(frame.get("is_cost", false)):
				for ci in state.field_nexuses(pid):
					if ci.is_refreshed():
						_exhaust_nexus(pid, ci)
						break
				return ""
			return _op_targeted(pid, {"op": "exhaust_nexus", "prompt": "Exhaust which nexus?",
					"target": {"controller": "self", "zone": "field", "card_type": "nexus", "count": 1,
					"filters": {"exhausted": false}}}, frame, func(t: CardInstance):
				_exhaust_nexus(pid, t))
		"pay_cores":
			var n := int(d.get("amount", 0))
			var paid := state.move_cores(GameState.pool(pid, BSS.Zone.RESERVE),
					GameState.pool(pid, BSS.Zone.TRASH), n, false, true)
			# 0.24.0 (R-157): a cost is paid from the reserve AND the field
			# (10-6-6). The rest comes from cards' spare cores (above their
			# LV1), the card with the most spare first.
			var left := n - paid
			while left > 0:
				var best: CardInstance = null
				var best_spare := 0
				for fu in state.player(pid).field:
					var fc: CardInstance = state.cards[fu]
					var spare := fc.cores - (fc.data.min_level_cost() if fc.data != null else 0)
					if spare > best_spare:
						best = fc
						best_spare = spare
				if best == null:
					break
				left -= state.move_cores(GameState.on_card(best.uid), GameState.pool(pid, BSS.Zone.TRASH),
						mini(left, best_spare))
		"remove_cores":
			# Purple (0.10.0): "Send N cores from one of your opponent's
			# spirits to the void." A spirit left below its LV1 cost is
			# destroyed at the next checkpoint (9-3) -- the colour's removal.
			var rd := d
			# "one of its cores for each spirit you control" (0.15.0, BSS05-030)
			if d.has("amount_per"):
				rd = d.duplicate()
				rd["amount"] = int(d.get("amount", 1)) * collect_targets(pid, d["amount_per"], frame).size()
				rd.erase("amount_per")
				if int(rd["amount"]) <= 0:
					return ""
			if bool(d.get("amount_per_trigger_symbol", false)):
				# "one core ... for each symbol on your blocked spirit" (0.15.0, BSS04-025)
				var rtc: CardInstance = state.card(int(((frame.get("meta", {}) as Dictionary).get("ctx", {}) as Dictionary).get("uid", -1)))
				rd = d.duplicate()
				rd["amount"] = int(d.get("amount", 1)) * (rtc.symbol_count() if rtc != null else 0)
				if int(rd["amount"]) <= 0:
					return ""
			return _op_targeted(pid, rd, frame, func(t: CardInstance):
				_remove_cores_from(pid, rd, t, frame))
		# ---- 0.14.0 (Set 1) ----------------------------------------------
		"soul_to_void":
			if _move_soul(pid, GameState.pool(pid, BSS.Zone.VOID), false, frame):
				_frame_flag(frame, "paid")
		"soul_to_trash":
			if _move_soul(pid, GameState.pool(pid, BSS.Zone.TRASH), bool(d.get("from_self", false)), frame):
				_frame_flag(frame, "paid")
		"life_fill":
			var lp := state.player(pid)
			var need := int(d.get("amount", 5)) - lp.life_total()
			if need > 0:
				state.move_cores(GameState.pool(pid, BSS.Zone.VOID), GameState.pool(pid, BSS.Zone.LIFE), need)
		"reveal_top_take":
			_op_reveal_top_take(pid, d, frame)
		"attack_spirit":
			# "You may attack that spirit": the battle is fought against it as
			# though it had blocked (Dark Knight Palomides, Poison Mist).
			return _op_targeted(pid, d, frame, func(t: CardInstance):
				engine.attack_spirit_now(t))
		"to_deck_bottom", "to_deck_top":
			var top := op == "to_deck_top"
			return _op_targeted(pid, d, frame, func(t: CardInstance):
				if not _bounce_blocked(pid, t):
					_return_to_deck(t, top))
		"refresh_step":
			engine._refresh_step()
		"trash_core_to_reserve":
			var tp := state.player(pid)
			if bool(d.get("prefer_soul", false)) and tp.trash_soul > 0:
				state.move_cores(GameState.pool(pid, BSS.Zone.TRASH), GameState.pool(pid, BSS.Zone.RESERVE), 1, true, true)
				_frame_flag(frame, "soul_moved")
			elif tp.trash_cores > 0:
				state.move_cores(GameState.pool(pid, BSS.Zone.TRASH), GameState.pool(pid, BSS.Zone.RESERVE), 1)
		"mill_check":
			# "player": "opponent" -- the top card of your opponent's deck (0.15.0, BSS04-051)
			var mcm: Array = effect_mill(pid, _who(pid, d), 1)
			if not mcm.is_empty():
				var top_c: CardInstance = state.card(int(mcm[0]))
				var hit := top_c != null and top_c.data != null and \
						BSS.card_type_from_string(str(d.get("card_type", "spirit"))) == top_c.data.card_type
				if not hit:
					_frame_flag(frame, "milled_other")
		"discard_for_cores":
			return _op_targeted(pid, d, frame, func(t: CardInstance):
				_offer_discard_for_cores(pid, t))
		# ---- 0.15.0 (Sets 2-6) -------------------------------------------
		"mill_count":
			# "Discard the top three cards of your deck. For each spirit card
			# discarded ..." -- the count is kept as frame flag milled_hits.
			var mw := _who(pid, d)
			var mtop: Array = effect_mill(pid, mw, int(d.get("amount", 1)))
			var hits := 0
			for muid in mtop:
				var mc: CardInstance = state.card(int(muid))
				if mc != null and mc.data != null and (str(d.get("card_type", "")) == "" or \
						BSS.card_type_from_string(str(d.get("card_type", ""))) == mc.data.card_type):
					# "If a white card is among the discarded cards" (0.15.0, BSS06-021)
					if d.has("filters") and not _passes_filter(pid, mc, {"filters": d["filters"], "count": 0}, frame):
						continue
					hits += 1
			_frame_flag(frame, "milled_hits", hits)
			_frame_flag(frame, "milled_uids", mtop)
		"absorb_cores":
			# "Put all of the cores on one of your tokens onto this spirit."
			var me_a: CardInstance = state.card(int(frame.get("source", -1)))
			if me_a == null:
				return ""
			return _op_targeted(pid, d, frame, func(t: CardInstance):
				if t.uid != me_a.uid:
					state.move_cores(GameState.on_card(t.uid), GameState.on_card(me_a.uid), t.total_cores(), false, true)
					_frame_flag(frame, "absorbed"))
		"add_cores_from_trash":
			# "Place two cores from your trash that are not a soul core onto
			# one of your NERV spirits" (0.12.0)
			var ad := d
			if d.has("per"):
				# "two cores ... for every Ruby Sanctuary you control" (0.15.0,
				# BSS03-001); "one ... for each of your spirits with Luster" (BSS04-043)
				ad = d.duplicate()
				ad["amount"] = int(d.get("amount", 1)) * collect_targets(pid, d["per"], frame).size()
				ad.erase("per")
				if int(ad["amount"]) <= 0:
					return ""
			return _op_targeted(pid, ad, frame, func(t: CardInstance):
				_cores_from_trash(pid, ad, t))
		"remove_cores_self":
			var s2: CardInstance = state.card(int(frame.get("source", -1)))
			if s2:
				s2.flags["self_caused"] = true
				state.move_cores(GameState.on_card(s2.uid),
						GameState.pool(pid, BSS.Zone.RESERVE), int(d.get("amount", 1)), false, true)
		"add_core_from_void":
			if bool(d.get("per_zeroed", false)):
				# "a core from the void onto this spirit for each spirit
				# destroyed by this effect" (0.14.0)
				var zn := int((frame.get("flags", {}) as Dictionary).get("zeroed_n", 0))
				if zn > 0:
					if state.move_cores(GameState.pool(pid, BSS.Zone.VOID), _core_dest(pid, d, frame), zn) > 0:
						_note_void_core(pid, "reserve")
				return ""
			# "on this spirit" / "on one of your spirits" name a card target;
			# before 0.8.0 the target was ignored and the core went to the
			# reserve (R-039).
			if d.has("target") and not d.has("to"):
				var amt := int(d.get("amount", 1))
				return _op_targeted(pid, d, frame, func(t: CardInstance):
					_void_cores_onto(pid, d, t, amt))
			if state.move_cores(GameState.pool(_who(pid, d), BSS.Zone.VOID),
					_core_dest(pid, d, frame), int(d.get("amount", 1))) > 0:
				_note_void_core(pid, "reserve")
		"move_cores":
			# "you may move any number of cores" (0.15.0, BSS05-104): the player picks how many
			if str(d.get("amount", "")) == "any":
				return _offer_move_any(pid, d, frame)
			# "a core (not the soul core)" (0.15.0, BSS05-001 / -035): no_soul
			state.move_cores(_core_src(pid, d, frame), _core_dest(pid, d, frame),
					int(d.get("amount", 1)), bool(d.get("soul", false)), not bool(d.get("no_soul", false)))
		"life_gain":
			state.move_cores(GameState.pool(_who(pid, d), BSS.Zone.VOID),
					GameState.pool(_who(pid, d), BSS.Zone.LIFE), int(d.get("amount", 1)))
		"life_loss":
			var v := _who(pid, d)
			var to_zone := BSS.Zone.TRASH if str(d.get("to", "reserve")) == "trash" else BSS.Zone.RESERVE
			var lost := state.move_cores(GameState.pool(v, BSS.Zone.LIFE),
					GameState.pool(v, to_zone), int(d.get("amount", 1)))
			if lost > 0:
				engine.on_life_lost(v)
		"summon_from":
			return _op_summon_from(pid, d, frame)
		"search_top":
			return _op_search_top(pid, d, frame)
		"scry":
			return _op_scry(pid, d, frame)
		"reveal_match_cost":
			_op_reveal_match_cost(pid, frame, int(d.get("cost", -1)))
		"regather_cores":
			# "Place all of the destroyed spirit's cores onto one of your
			# spirits" (0.11.1): the destroyed card's cores went to its owner's
			# reserve; the same number (soul core included) moves from there.
			var meta2: Dictionary = frame.get("meta", {})
			var cx: Dictionary = meta2.get("ctx", {})
			var amount := int(cx.get("cores", 0)) + int(cx.get("soul", 0))
			if amount > 0:
				return _op_targeted(pid, d, frame, func(t: CardInstance):
					state.move_cores(GameState.pool(pid, BSS.Zone.RESERVE), GameState.on_card(t.uid),
							amount, false, true))
		"set_player_flag":
			var spw := _who(pid, d)
			state.set_turn_flag(spw, str(d.get("flag", "x")))
			# whose effect set it -- "when an effect of your opponent ends your
			# attack step" (0.15.0, BSS05-072)
			state.turn_flags["%d:%s:by" % [spw, str(d.get("flag", "x"))]] = pid
			# "When this battle ends, the attack step ends" used after that
			# battle has already finished ending -- the follow-up of an
			# Absolute Ice Shield burst, answered after the damage: the
			# battle it names is over, so the attack step ends now
			# (0.24.0, R-157). Before, it waited for the NEXT battle.
			if str(d.get("flag", "")) == "end_attack_after_battle" and state.battle.is_empty() \
					and state.step == BSS.Step.ATTACK:
				engine.end_attack_step_by_flag()
			# "During this battle, ..." (0.15.0, BSS03-134): cleared when the battle ends
			if str(d.get("duration", "")) == "battle" and not state.battle.is_empty():
				if not state.battle.has("player_flags"):
					state.battle["player_flags"] = []
				(state.battle["player_flags"] as Array).append([spw, str(d.get("flag", "x"))])
		"summon_token":
			# "putting a core from the void on each of them" (0.15.0, BSS05-064)
			var tk: CardInstance = engine.keywords.summon_token(pid, d.get("token", {}),
					bool(d.get("cores_from_void", false)))
			if tk != null and bool(d.get("exhausted", false)):
				tk.orientation = BSS.Orientation.EXHAUSTED
		"win_game":
			# 1-2-6 -- effects that simply win the game bypass checkpoints.
			engine._declare_winner(_who(pid, d), "card effect")
		"lose_game":
			engine._declare_winner(state.opponent_of(_who(pid, d)), "card effect")

		# --- 8-2-2-2 continuous directives ---------------------------------
		"add_bp":
			# "+1000 BP for each green spirit you control" (0.11.0): "per"
			# names what to count.
			var amt := int(d.get("amount", 0))
			if d.has("per"):
				amt *= collect_targets(pid, d["per"], frame).size()
			# "+1000 BP for each spirit card discarded by its Crush" (0.15.0, BSS03-085)
			if d.has("per_ctx"):
				var pctx: Dictionary = (frame.get("meta", {}) as Dictionary).get("ctx", {})
				amt *= int(pctx.get(str(d["per_ctx"]), 0))
			# the counted amount travels with the directive, so a target picked
			# later (_apply_chosen) gets it too (0.15.0, BSS03-116)
			var bd := d
			if d.has("per") or d.has("per_ctx"):
				bd = d.duplicate()
				bd["amount"] = amt
				bd.erase("per")
				bd.erase("per_ctx")
			return _op_targeted(pid, bd, frame, func(t: CardInstance):
				t.bp_add += amt
				_register_continuous(bd, t.uid, "bp_add", amt)
				_note_bp_zeroed(frame, t, amt))
		"set_bp":
			return _op_targeted(pid, d, frame, func(t: CardInstance):
				var prev := t.bp_set
				t.bp_set = int(d.get("amount", 0))
				_register_continuous(d, t.uid, "bp_set", prev))
		"treat_as_level":
			return _op_targeted(pid, d, frame, func(t: CardInstance):
				_treat_as_level(pid, d, t, frame))
		"grant_keyword":
			return _op_targeted(pid, d, frame, func(t: CardInstance):
				var kw := BSS.keyword_from_string(str(d.get("keyword", "")))
				if kw >= 0:
					t.granted_keywords.append({"keyword": kw, "value": d.get("value", null),
						"source": int(frame.get("source", -1))})
					_register_continuous(d, t.uid, "keyword", kw))
		"set_flag":
			return _op_targeted(pid, d, frame, func(t: CardInstance):
				t.flags[str(d.get("flag", "x"))] = d.get("value", true)
				_register_continuous(d, t.uid, "flag", str(d.get("flag", "x"))))

		# ---- 0.15.0 (Set 2) ------------------------------------------------
		"destroy_self":
			# an effect cost: "you may destroy this nexus to ..."
			var ds: CardInstance = state.card(int(frame.get("source", -1)))
			if ds != null and ds.zone == BSS.Zone.FIELD:
				engine.destroy(ds, ds.uid)
		"select_target":
			# only selects ("select one of your spirits"); later directives
			# read it as last_target
			return _op_targeted(pid, d, frame, func(_t: CardInstance): pass)
		"delayed_effect":
			# "At the end of this turn, ..."
			state.delayed.append({"pid": pid, "source": int(frame.get("source", -1)), "target": -1,
					"once": true, "duration": "turn",
					"spec": {"timing": str(d.get("when", "end_of_turn")), "scope": "any", "kind": "triggered",
							"directives": d.get("directives", [])}})
		"delayed_trigger":
			# "This turn, when ..." -- a temporary triggered effect
			var dspec := {"kind": "triggered", "timing": str(d.get("timing", "")), "timings": d.get("timings", []),
					"scope": str(d.get("scope", "any")), "directives": d.get("directives", [])}
			for k: String in ["trigger_filter", "trigger_type", "during", "condition"]:
				if d.has(k):
					dspec[k] = d[k]
			var entry := {"pid": pid, "source": int(frame.get("source", -1)), "target": -1,
					"once": bool(d.get("once", false)), "duration": str(d.get("duration", "turn")), "spec": dspec}
			if d.has("target"):
				return _op_targeted(pid, d, frame, func(t: CardInstance):
					var e2: Dictionary = entry.duplicate(true)
					e2["target"] = t.uid
					state.delayed.append(e2))
			state.delayed.append(entry)
		"turn_rule":
			# "This turn, your spirits ..." -- a constant rule until the turn ends
			state.turn_rules.append({"pid": pid, "source": int(frame.get("source", -1)), "d": d.get("rule", {})})
			engine.run_checkpoints()
		"copy_effect":
			# "Use one of its When Summoned effects as if it were this spirit's"
			var me_c: CardInstance = state.card(int(frame.get("source", -1)))
			var want_t := str(d.get("timing", "on_summon"))
			return _op_targeted(pid, d, frame, func(t: CardInstance):
				for e: Dictionary in t.active_effects():
					if str(e.get("timing", "")) == want_t:
						push(me_c if me_c != null else t, e, pid, {"ctx": {"uid": me_c.uid if me_c else t.uid, "player": pid}})
						break)
		"grant_effect":
			var ge: Dictionary = d.get("effect", {})
			return _op_targeted(pid, d, frame, func(t: CardInstance):
				if not ge.is_empty():
					t.granted_effects.append(ge))
		"suppress_effects":
			# "... lose their effects and cannot regain them this turn"
			return _op_targeted(pid, d, frame, func(t: CardInstance):
				t.flags["no_effects"] = true
				_register_continuous(d, t.uid, "flag", "no_effects"))
		"magic_selection_steal":
			state.turn_flags["%d:steal_select" % pid] = int(d.get("uses", 1))
		"distribute_reserve_cores":
			# "Put any number of cores from your reserve on up to two of your
			# spirits": each, in turn, is raised toward its highest level.
			return _op_targeted(pid, d, frame, func(t: CardInstance):
				var need := 0
				for l: Dictionary in t.data.levels:
					need = maxi(need, int(l["core_cost"]))
				var add := maxi(0, need - t.total_cores())
				if add > 0:
					state.move_cores(GameState.pool(pid, BSS.Zone.RESERVE), GameState.on_card(t.uid), add, false, true))
		"extra_draw_tax", "set_base_bp", "add_spirit_type", "suppress_when_destroyed":
			pass        # constant rules, read by refresh_constants / active_rules
		# ---- 0.15.0 (Set 3) -----------------------------------------------
		"draw_until":
			# "Draw cards until you have three cards in your hand" (BSS03-006);
			# "... as many cards as your opponent has" (BSS04-069)
			var duw := _who(pid, d)
			var goal := int(d.get("amount", 0))
			if str(d.get("amount_from", "")) == "opponent_hand":
				goal = state.player(state.opponent_of(duw)).hand.size()
			var dn := goal - state.player(duw).hand.size()
			if dn > 0:
				return execute(pid, {"op": "draw", "amount": dn, "player": str(d.get("player", "self"))}, frame)
		"retrigger_on_summon":
			# "Activate one of that spirit's When Summoned effects a second time" (BSS03-033)
			var rr := _op_targeted(pid, d, frame, func(t: CardInstance):
				_retrigger_on_summon(pid, t))
			return "await" if rr == "" and not state.pending_choice.is_empty() else rr
		"push_effect_of":
			# internal: the branch of _retrigger_on_summon's choice
			var pe: CardInstance = state.card(int(d.get("uid", -1)))
			if pe != null:
				var pes := pe.active_effects()
				var pei := int(d.get("index", -1))
				if pei >= 0 and pei < pes.size():
					push(pe, pes[pei], pid, {"ctx": {"uid": pe.uid, "player": pe.controller_id}})
		"next_magic_discount":
			# "This turn, the next yellow magic card you use from your hand costs
			# 1 less" (BSS03-036): read by RulesEngine.compute_cost, used up by
			# _act_use_magic.
			var nmk := "%d:next_magic_discount" % pid
			var nml: Array = state.turn_flags.get(nmk, [])
			nml.append({"amount": int(d.get("amount", 1)), "filters": d.get("filters", {})})
			state.turn_flags[nmk] = nml
		"no_battle_destroy":
			# "During this battle, neither player's spirits can be destroyed by battle" (BSS03-050)
			if not state.battle.is_empty():
				state.battle["no_battle_destroy"] = true
		"activate_crush":
			# "Then activate its Crush effect" (BSS03-088)
			return _op_targeted(pid, d, frame, func(t: CardInstance):
				engine.keywords.do_crush(t))
		"place_from":
			# "Place a nexus card from your hand / trash without paying its cost"
			# (BSS03-092, BSS03-097, BSS04-088, BSS04-095)
			return _op_targeted(pid, d, frame, func(t: CardInstance):
				engine.place_free(pid, t))
		"place_self":
			# a nexus burst: "Place this card without paying its cost" (BSS03-116).
			# The burst card waits in the trash while it resolves; it goes to the
			# field instead of staying there.
			var psc: CardInstance = state.card(int(frame.get("source", -1)))
			if psc != null and psc.data != null and psc.data.is_nexus() and psc.zone != BSS.Zone.FIELD:
				engine.place_free(pid, psc)
		"reveal_random_hand":
			# "Select a card from your opponent's hand at random and reveal it" (BSS03-110)
			var rhw := _who(pid, d)
			var rh := state.player(rhw).hand
			if not rh.is_empty():
				var ru: int = rh[state.rng.randi_range(0, rh.size() - 1)]
				_log_reveal(rhw, [ru], [], {"random_hand": true})
		"look_top":
			# "Look at the top card of your deck, then put it back" (BSS03-111):
			# information only, so it is just logged.
			var lkd := state.player(pid).deck
			var lk_top: Array = lkd.slice(0, mini(int(d.get("amount", 1)), lkd.size()))
			state.log_event("looked", {"player": pid, "uids": lk_top})
			if not lk_top.is_empty():
				# The player sees the card(s) and acknowledges (0.16.1, R-079)
				state.pending_choice = {"type": "option", "player": pid, "prompt": "Top of your deck",
						"labels": ["OK"], "branches": [{"directives": []}], "revealed": _reveal_list(lk_top, []),
						"private": true}
				return "await"
		"set_symbols":
			# "This turn it is treated as having two red symbols" (BSS03-122)
			return _op_targeted(pid, d, frame, func(t: CardInstance):
				_set_symbols(d, t))
		"add_unblockable_rule":
			# "This turn, your spirits that cost 2 or less cannot be blocked by
			# your opponent's spirits that cost 5 or more" (BSS03-128): a turn
			# rule with the shape of the constant unblockable_by.
			state.turn_rules.append({"pid": pid, "source": int(frame.get("source", -1)),
					"d": {"op": "unblockable_by", "attacker": d.get("attacker", {}), "blocker": d.get("blocker", {})}})
		"refresh_or_exhaust":
			# "If it is green, refresh it; if not, exhaust it" (BSS03-132)
			return _op_targeted(pid, d, frame, func(t: CardInstance):
				_refresh_or_exhaust(pid, d, t))
		"soul_only_selectable", "opponent_attack_cost", "no_magic_draw", "summon_limit", "magic_color_lock":
			pass        # constant rules (Set 3), read where they matter (active_rules)
		# ---- 0.15.0 (Set 4) -----------------------------------------------
		"reveal_summon":
			# "Reveal the top four cards of your deck. Summon a spirit card that
			# costs 2 from among them and discard the rest" (BSS04-043, -102)
			return _op_reveal_summon(pid, d, frame)
		"discard_hand":
			# "You may discard your entire hand. If a Preybird card is discarded
			# this way, ..." (BSS04-069): frame flag discarded_match
			var dh: Array = state.player(pid).hand.filter(func(u1: int) -> bool:
				return not bool(state.cards[u1].flags.get("resolving", false)))
			var mark: Dictionary = d.get("mark", {})
			for du: Variant in dh:
				var dc: CardInstance = state.card(int(du))
				if not mark.is_empty() and _passes_filter(pid, dc, {"filters": mark}, frame):
					_frame_flag(frame, "discarded_match")
				state.move_card(int(du), BSS.Zone.TRASH, pid)
			if not dh.is_empty():
				_frame_flag(frame, "discarded")
				state.log_event("discard", {"player": pid, "uids": dh, "reason": "whole hand"})
				note_discarded(dh, pid, pid, frame)
		"no_lethal_damage":
			# "This turn, attacks from your opponent's non-token spirits that cost
			# 4 or less cannot reduce your life to 0" (BSS04-128): a turn rule of
			# its user, read in battle resolution.
			state.turn_rules.append({"pid": pid, "source": int(frame.get("source", -1)), "d": d})
		"suppress_block_triggers", "ascend_cost_as", "cost_in_trash", "no_destroy_by_effect", "no_exhaust_by_opponent", \
				"unblockable_by_armor_colors", "waive_ascend":
			pass        # constant rules (Set 4), read where they matter (active_rules / CardInstance)
		# ---- 0.15.0 (Set 5) -----------------------------------------------
		"summon_self_from_trash":
			# "You may summon this spirit card from your trash" (BSS05-012 paying
			# its cost as Immortal does, BSS05-043 free and exhausted). Frame flag
			# "summoned" when it arrived.
			var sst: CardInstance = state.card(int(frame.get("source", -1)))
			if sst == null or sst.data == null or not sst.data.is_spirit() or sst.zone != BSS.Zone.TRASH:
				return ""
			if bool(d.get("free", false)):
				_summon_free(sst.owner_id, sst, d)
			else:
				engine.do_summon(sst.owner_id, sst, {"via": "effect"})
			if sst.zone == BSS.Zone.FIELD:
				_frame_flag(frame, "summoned")
		"life_shield":
			# "This turn, attacks by your opponent's spirits with 3000 BP or less
			# cannot reduce your life" (BSS05-062): a turn rule of its user.
			state.turn_rules.append({"pid": pid, "source": int(frame.get("source", -1)), "d": d})
		"magic_core_tax":
			# "This turn, when your opponent uses a magic card from their hand,
			# they must pay three cores as an additional cost" (BSS05-100)
			state.turn_rules.append({"pid": pid, "source": int(frame.get("source", -1)), "d": d})
		"attack_ban":
			# "This turn, spirits with 2000 BP or less cannot attack" (BSS05-127): both players
			state.turn_rules.append({"pid": pid, "source": int(frame.get("source", -1)), "d": d})
		"magic_to_hand":
			# "... return this card to your hand" (BSS05-121): read by _finish_frame
			_frame_flag(frame, "magic_to_hand")
		"copy_token":
			# "Summon one more copy of that token, exhausted, putting a core (not
			# the soul core) from your reserve or trash on it" (BSS05-111); "source" names the token
			var ctd := d.duplicate()
			ctd["target"] = d.get("source", {"zone": "trigger"})
			return _op_targeted(pid, ctd, frame, func(t: CardInstance):
				_apply_new(pid, ctd, t, frame))
		"reveal_burst_mill":
			# "Reveal your opponent's set burst card. Discard cards from the top of
			# your opponent's deck equal to its cost; it stays set" (BSS05-136)
			var rfoe := state.opponent_of(pid)
			var rb: CardInstance = state.card(state.player(rfoe).burst)
			if rb != null and rb.data != null:
				_log_reveal(rfoe, [rb.uid], [], {"burst": true})
				_frame_flag(frame, "milled_uids", effect_mill(pid, rfoe, rb.data.cost))
		"to_deck_top_or_bottom":
			# "Your opponent puts it on the top or the bottom of their deck" (BSS05-130):
			# select it, then the chooser picks top or bottom.
			_push_sub(pid, frame, [{"op": "select_target", "target": d.get("target", {})},
					{"op": "choice", "player": "opponent" if str(d.get("position_chooser", "opponent")) == "opponent" else "self",
					"prompt": "Put that card on the top or the bottom of its owner's deck?", "labels": ["Top", "Bottom"],
					"if": {"type": "frame_flag", "flag": "last_target"},
					"branches": [{"directives": [{"op": "to_deck_top", "target": {"zone": "last_target"}}]},
							{"directives": [{"op": "to_deck_bottom", "target": {"zone": "last_target"}}]}]}])
		"add_symbols":
			# "this spirit gains one additional green symbol during this battle"
			# (BSS05-066): a one-shot version of the constant
			return _op_targeted(pid, d, frame, func(t: CardInstance):
				_apply_new(pid, d, t, frame))
		"bounce_same_cost", "nexus_as_spirit", "move_soul_to", "place_from_trash":
			# BSS05-052 / -082 / -083 / -089 / -099 / -113 / -115 (see _apply_new)
			return _op_targeted(pid, d, frame, func(t: CardInstance):
				_apply_new(pid, d, t, frame))
		"life_damage_cap", "indestructible_by", "discard_protect":
			pass        # constant rules (Set 5), read where they matter (active_rules)
		# ---- 0.15.0 (Set 6) -----------------------------------------------
		"feast":
			# "Activate Feast" -- once, "two times" (times), or "once for each
			# spirit your opponent controls" (times_per, counted now) -- BSS06
			var ftimes := int(d.get("times", 1))
			if d.has("times_per"):
				ftimes = collect_targets(pid, d["times_per"], frame).size()
			for _fi in ftimes:
				engine.keywords.feast(pid)
		"summon_supsprite":
			# "summon two Small Supsprite Tokens" (BSS06-116): no upgrading
			for _si in int(d.get("count", 1)):
				engine.keywords.summon_token(pid, engine.keywords._supsprite_token(str(d.get("size", "Small"))))
		"core_to_void":
			# "Place a core (not the soul core) from your field or your reserve
			# into the void" (BSS06-102)
			_core_to_void(pid)
		"discard_any":
			# "Discard any number of cards" (BSS06-104): frame flag discarded_n
			return _op_discard_any(pid, d, frame)
		"use_magic_from":
			# "Use one magic card ... among the discarded cards without paying its
			# cost" (BSS06-031)
			return _op_targeted(pid, d, frame, func(t: CardInstance):
				_apply_new(pid, d, t, frame))
		"do_link":
			# internal: the branch of the Link offer (KeywordEngine.offer_links)
			engine.keywords.do_link(state.card(int(d.get("lender", -1))), state.card(int(d.get("to", -1))))
		"count_symbols_as", "set_cost", "multi_link", "link_ignore_condition", "link_on_block":
			pass        # constant rules (Set 6), read where they matter
		# --- Escape hatch ---------------------------------------------------
		"script":
			return _op_script(pid, d, frame)
		"choice":
			return _op_choice(pid, d, frame)
		"noop", "":
			pass
		"double_symbols", "blocks_on_attack", "unblockable_by", "magic_discard_tax":
			pass        # rules constants, read where they matter (active_rules)
		_:
			Log.warn("EffectSystem: unimplemented op '%s'" % op)
	return ""


# ---- 0.15.0 (Sets 5-6) helpers ---------------------------------------------

## "If you destroy one of your opponent's spirits via reducing its BP to 0
## with this effect" (BSS06-030 / -032): frame flag bp_zeroed when a -BP brings
## a spirit to 0 (the checkpoint then destroys it).
func _note_bp_zeroed(frame: Dictionary, t: CardInstance, amt: int) -> void:
	# 0.16.7 (R-085): an opponent's -BP that leaves a spirit at 0 destroys it
	# "by the opponent's effect" -- remember whose card it was for the checkpoint.
	var bsrc: CardInstance = state.card(int(frame.get("source", -1)))
	if amt < 0 and t.data != null and t.zone == BSS.Zone.FIELD and bsrc != null and bsrc.controller_id != t.controller_id:
		t.flags["bp_down_src"] = bsrc.uid
	if amt < 0 and t.data != null and t.data.is_spirit() and t.zone == BSS.Zone.FIELD and t.raw_bp() <= 0:
		_frame_flag(frame, "bp_zeroed")


## "Select one of your opponent's spirits and exhaust it. If it has Astral,
## return it to their hand instead" (BSS05-132): exhaust's instead_if.
func _exhaust_or_instead(pid: int, d: Dictionary, t: CardInstance) -> void:
	var ii: Dictionary = d.get("instead_if", {})
	if not ii.is_empty() and _passes_filter(pid, t, {"filters": ii.get("filters", {}), "count": 0}, {}):
		match str(ii.get("op", "")):
			"return_to_hand":
				if not _bounce_blocked(pid, t):
					_return_to_hand(t)
			"destroy":
				engine.destroy(t, -1)
		return
	effect_exhaust(int(d.get("by_player", pid)), t)


## Exhaust one nexus, firing nexus_exhausted once (the checkpoint skips it).
func _exhaust_nexus(pid: int, ci: CardInstance) -> void:
	if ci == null or ci.zone != BSS.Zone.FIELD or not ci.is_refreshed():
		return
	ci.orientation = BSS.Orientation.EXHAUSTED
	nexus_exhaust_fired[ci.uid] = true
	state.log_event("nexus_exhausted", {"uid": ci.uid, "player": pid})
	trigger("nexus_exhausted", {"uid": ci.uid, "player": ci.controller_id})


## "You may move any number of cores from this nexus onto the blocked spirit"
## (BSS05-104): one option per amount, the most first.
func _offer_move_any(pid: int, d: Dictionary, frame: Dictionary) -> String:
	var src := _core_src(pid, d, frame)
	var have := 0
	if str(src.get("kind", "")) == "card":
		var sc: CardInstance = state.card(int(src.get("uid", -1)))
		have = sc.total_cores() if sc != null else 0
	else:
		var sp := state.player(int(src.get("player", pid)))
		match int(src.get("zone", BSS.Zone.RESERVE)):
			BSS.Zone.RESERVE: have = sp.total_reserve()
			BSS.Zone.TRASH: have = sp.trash_cores + sp.trash_soul
	if have <= 0:
		return ""
	var labels: Array = []
	var branches: Array = []
	for n in range(have, -1, -1):
		labels.append("Move %d" % n)
		var md := d.duplicate()
		md["amount"] = n
		branches.append({"directives": [md] if n > 0 else []})
	state.pending_choice = {"type": "option", "player": pid, "prompt": "Move how many cores?",
			"labels": labels, "branches": branches}
	return "await"


## Run `dirs` as a follow-up effect of the same card (its trigger context and
## "if you do" flags, not its last selection), after the running one.
func _push_sub(pid: int, frame: Dictionary, dirs: Array) -> void:
	var fl: Dictionary = (frame.get("flags", {}) as Dictionary).duplicate()
	fl.erase("last_target")
	var f := {"source": int(frame.get("source", -1)), "spec": {"directives": dirs}, "controller": pid,
			"meta": {"ctx": (frame.get("meta", {}) as Dictionary).get("ctx", {}), "branch": true},
			"dir_index": 0, "flags": fl}
	if _depth > 0:
		_deferred.append(f)
	else:
		state.effect_stack.append(f)


## The targeted ops added for Sets 5-6, for a target taken on the spot or one
## picked by a player (_apply_chosen).
func _apply_new(pid: int, d: Dictionary, t: CardInstance, frame: Dictionary) -> void:
	match str(d.get("op", "")):
		"exhaust_nexus":
			_exhaust_nexus(pid, t)
		"bounce_same_cost":
			# "Return it and every spirit that costs the same as it to their
			# owners' hands" (BSS05-052)
			var c := t.effective_cost()
			var all_c: Array = [t]
			for o in state.all_field_cards():
				if o.uid != t.uid and o.data != null and o.data.is_spirit() and o.effective_cost() == c:
					all_c.append(o)
			for o2: CardInstance in all_c:
				if o2.zone == BSS.Zone.FIELD and not _bounce_blocked(pid, o2):
					_return_to_hand(o2)
		"nexus_as_spirit":
			# "That nexus is also treated as a Golem spirit with 5000 BP this
			# turn" (BSS05-082 / -083 / -113): its CardData is swapped for a
			# spirit copy (still a nexus for filters and field_nexuses); the
			# original comes back when the duration ends or the card moves.
			if t.data == null or not t.data.is_nexus() or t.orig_data != null:
				return
			t.orig_data = t.data
			t.data = t.data.as_spirit(str(d.get("spirit_type", "")), int(d.get("bp", 0)))
			_register_continuous(d, t.uid, "as_spirit", null)
			state.log_event("nexus_as_spirit", {"uid": t.uid})
		"move_soul_to":
			# "Move the soul core from that spirit onto one of your other
			# spirits" (BSS05-089)
			var msrc := _core_loc(pid, d.get("from", {}), frame)
			state.move_cores(msrc, GameState.on_card(t.uid), 1, true, true)
		"place_from_trash":
			# "Place them without paying their costs" (BSS05-099 / -115, BSS06-081)
			if t.data != null and t.data.is_nexus() and t.zone != BSS.Zone.FIELD:
				engine.place_free(pid, t)
				if bool(d.get("exhausted", false)) and t.zone == BSS.Zone.FIELD:
					t.orientation = BSS.Orientation.EXHAUSTED
		"copy_token":
			if not bool(t.flags.get("is_token", false)) or t.data == null:
				return
			var nt: CardInstance = engine.keywords.spawn_token(pid, t.data, str(t.flags.get("token_size", "")),
					"trash_first", true)
			if nt != null and bool(d.get("exhausted", false)):
				nt.orientation = BSS.Orientation.EXHAUSTED
			if nt != null:
				trigger("on_summon", {"uid": nt.uid, "player": pid})
		"add_symbols":
			var grp: Array = []
			for c0: Variant in d.get("colors", []):
				grp.append(BSS.color_from_string(str(c0)))
			t.granted_symbols.append(grp)
			_register_continuous(d, t.uid, "granted_symbol", grp)
		"use_magic_from":
			_use_magic_free(pid, t)


## "Use one magic card ... without paying its cost" (BSS06-031): its Main
## effect in your main step, its Flash effect in a battle (the first that
## fits); it goes to the trash when it has resolved.
func _use_magic_free(pid: int, t: CardInstance) -> void:
	if t.data == null or not t.data.is_magic():
		return
	var main_ok := state.battle.is_empty()
	for e: Dictionary in t.data.effects:
		if str(e.get("kind", "")) != "magic":
			continue
		var w := str(e.get("window", "main"))
		if (main_ok and (w == "main" or w == "both")) or (not main_ok and (w == "flash" or w == "both")):
			t.flags["resolving"] = true
			state.log_event("use_magic", {"player": pid, "uid": t.uid, "cost": 0, "free": true})
			push(t, e, pid, {"magic": true})
			return


## BSS06-102: a non-soul core from the reserve, else a spare one on a card,
## else one from the card with the most cores (the player's choice, made for them).
func _core_to_void(pid: int) -> void:
	var p := state.player(pid)
	var void_loc := GameState.pool(pid, BSS.Zone.VOID)
	if p.reserve_cores > 0:
		state.move_cores(GameState.pool(pid, BSS.Zone.RESERVE), void_loc, 1)
		return
	var best: CardInstance = null
	for uid in p.field:
		var c: CardInstance = state.cards[uid]
		if c.cores <= 0:
			continue
		if best == null or (c.cores - engine._level_floor(c)) > (best.cores - engine._level_floor(best)):
			best = c
	if best != null:
		state.move_cores(GameState.on_card(best.uid), void_loc, 1)


## "Discard any number of cards" (BSS06-104): the player picks 0..all.
func _op_discard_any(pid: int, d: Dictionary, frame: Dictionary) -> String:
	var hand: Array = state.player(pid).hand.filter(func(u0: int) -> bool:
		return not bool(state.cards[u0].flags.get("resolving", false)))
	_frame_flag(frame, "discarded_n", 0)
	if hand.is_empty():
		return ""
	# how many are worth discarding (the AI reads it): one per opposing spirit
	var useful := state.field_spirits(state.opponent_of(pid)).size()
	state.pending_choice = {"type": "discard", "player": pid, "count": hand.size(), "any": true, "up_to": true,
			"max_useful": useful, "options": hand.duplicate(), "mark_frame": true,
			"prompt": str(d.get("prompt", "Discard any number of cards"))}
	return "await"


## Cards discarded from a hand (0.15.0): "when this card is discarded from your
## hand" (BSS05-100, answers from the trash), "when you discard a card"
## (BSS05-115); frame flag discarded_cost (BSS06-115).
func note_discarded(uids: Array, player: int, by_player: int, frame: Dictionary = {}) -> void:
	for u: Variant in uids:
		var dc: CardInstance = state.card(int(u))
		if dc != null and dc.data != null:
			_frame_flag(frame, "discarded_cost", dc.data.cost)
	for u2: Variant in uids:
		trigger("card_discarded", {"uid": int(u2), "player": player, "by_player": by_player})


## "Refresh them. Spirits refreshed by this effect cannot attack this turn."
func _flag_also(d: Dictionary, t: CardInstance) -> void:
	if d.has("flag"):
		t.flags[str(d["flag"])] = true
		_register_continuous({"duration": str(d.get("flag_duration", "turn"))}, t.uid, "flag", str(d["flag"]))


# ---- 0.15.0 (Set 3) helpers ---------------------------------------------------

## Every "discard the top N cards of a deck" done by an effect (mill, mill_count,
## mill_check, Crush) goes through here (0.15.0, Set 3), so that
##   * "this turn, when your opponent's effect discards cards from your deck, no
##     more than one card is discarded" (BSS03-130, turn flag mill_cap_one) caps it,
##   * deck_milled fires once (ctx player, by_player, amount -- BSS03-059),
##   * discarded_from_deck fires for each card, which answers from the trash
##     (BSS03-126),
##   * milled_by_opponent fires once when it was the opponent's effect (BSS04-108).
## `by_pid` is the player whose effect it is. Returns the milled uids, top first.
func effect_mill(by_pid: int, victim: int, n: int) -> Array:
	if n <= 0:
		return []
	if by_pid >= 0 and by_pid != victim and state.turn_flag(victim, "mill_cap_one"):
		n = mini(n, 1)
	var milled: Array = state.mill_cards(victim, n)
	if milled.is_empty():
		return milled
	trigger("deck_milled", {"player": victim, "by_player": by_pid, "amount": milled.size()})
	for mu: Variant in milled:
		trigger("discarded_from_deck", {"uid": int(mu), "player": victim, "by_player": by_pid})
	if by_pid >= 0 and by_pid != victim:
		trigger("milled_by_opponent", {"player": victim, "by_player": by_pid, "amount": milled.size()})
	return milled


## An effect exhausts a card (0.15.0, Sets 3-4). Remembers whose effect did it
## ("when one of your effects exhausts one of your opponent's spirits",
## BSS03-114) and honours "your Shadow spirits cannot be exhausted by your
## opponent's effects" (BSS04-106, rule no_exhaust_by_opponent).
func effect_exhaust(by_pid: int, t: CardInstance) -> void:
	if t == null or t.zone != BSS.Zone.FIELD or t.is_exhausted():
		return
	if by_pid >= 0 and by_pid != t.controller_id and rule_applies(t, "no_exhaust_by_opponent"):
		state.log_event("exhaust_prevented", {"uid": t.uid})
		return
	t.orientation = BSS.Orientation.EXHAUSTED
	if by_pid >= 0:
		exhausted_by[t.uid] = by_pid


## destroy, for both a target taken on the spot and one picked by a player.
## Sets frame flags "destroyed" / "destroyed_n" for "if you destroy a spirit with
## this effect" (BSS03-094) and "for each spirit destroyed by this effect"
## (BSS04-001, BSS04-136) -- only for cards that really left the field.
func _destroy_by_effect(d: Dictionary, t: CardInstance, frame: Dictionary) -> void:
	suppress_when_destroyed = bool(d.get("no_when_destroyed", false))
	engine.destroy(t, int(frame.get("source", -1)))
	suppress_when_destroyed = false
	if t.zone != BSS.Zone.FIELD:
		_frame_flag(frame, "destroyed")
		_frame_flag(frame, "destroyed_n", int((frame.get("flags", {}) as Dictionary).get("destroyed_n", 0)) + 1)


## "Neither player can draw cards with magic effects" (BSS03-103): a draw done
## by a magic card's effect, while either player has the rule.
func _magic_draw_blocked(frame: Dictionary) -> bool:
	if bool(frame.get("is_cost", false)):
		return false
	var src: CardInstance = state.card(int(frame.get("source", -1)))
	if src == null or src.data == null or not src.data.is_magic():
		return false
	for p in 2:
		if not active_rules(p, "no_magic_draw").is_empty():
			return true
	return false


## Cores from the void onto a selected card. "amount_keyword": "Gale" -- as many
## as its Gale number (BSS03-115). A core put on a spirit this way is noted for
## core_from_void (BSS04-106).
func _void_cores_onto(pid: int, d: Dictionary, t: CardInstance, amt: int) -> void:
	var n := amt
	if d.has("amount_keyword"):
		var kv: Variant = t.keyword_value(BSS.keyword_from_string(str(d["amount_keyword"])))
		n = int(kv) if kv != null else 0
	if state.move_cores(GameState.pool(_who(pid, d), BSS.Zone.VOID), GameState.on_card(t.uid), n) > 0 \
			and t.data != null and t.data.is_spirit():
		_note_void_core(pid, "spirit")


## "When your opponent uses one of their effects to put a core from the void on
## a spirit or into their reserve" (0.15.0, BSS04-106). Not for life or nexuses.
func _note_void_core(pid: int, to: String) -> void:
	trigger("core_from_void", {"player": pid, "by_player": pid, "to": to})


## treat_as_level, for a target taken on the spot or picked by a player.
## "exhaust": exhaust each selected card first; "while_source": the level ends
## when the effect's card leaves the field (0.15.0, BSS03-092 -- see expire_orphans).
func _treat_as_level(pid: int, d: Dictionary, t: CardInstance, frame: Dictionary) -> void:
	if bool(d.get("exhaust", false)):
		effect_exhaust(pid, t)
	var prev := t.level_override
	t.level_override = _level_for(d, t)
	var n0 := continuous.size()
	_register_continuous(d, t.uid, "level_override", prev)
	if bool(d.get("while_source", false)) and continuous.size() > n0:
		continuous[continuous.size() - 1]["while_source"] = int(frame.get("source", -1))


## "... while you control this spirit" (0.15.0, BSS03-092): a continuous effect
## registered with while_source ends as soon as that card is off the field.
## Called from every checkpoint.
func expire_orphans() -> void:
	for i in range(continuous.size() - 1, -1, -1):
		var c: Dictionary = continuous[i]
		if not c.has("while_source"):
			continue
		var src: CardInstance = state.card(int(c["while_source"]))
		if src != null and src.zone == BSS.Zone.FIELD:
			continue
		var ci: CardInstance = state.card(int(c["uid"]))
		if ci != null and str(c["kind"]) == "level_override":
			ci.level_override = int(c["payload"])
		continuous.remove_at(i)


## "Treated as having two red symbols" (BSS03-122): the card's symbols are
## replaced for the duration (cost reduction and life damage both read them).
func _set_symbols(d: Dictionary, t: CardInstance) -> void:
	var groups: Array = []
	for g: Variant in d.get("colors", []):
		var grp: Array = []
		for c: Variant in (g as Array if typeof(g) == TYPE_ARRAY else [g]):
			grp.append(BSS.color_from_string(str(c)))
		groups.append(grp)
	var prev: Array = t.symbol_override.duplicate()
	t.symbol_override = groups
	_register_continuous(d, t.uid, "symbols", prev)


func _refresh_or_exhaust(pid: int, d: Dictionary, t: CardInstance) -> void:
	if t.data != null and t.data.has_color(BSS.color_from_string(str(d.get("if_color", "")))):
		t.orientation = BSS.Orientation.REFRESHED
	else:
		effect_exhaust(pid, t)


## "Activate one of that spirit's When Summoned effects a second time"
## (BSS03-033): one of its own When Summoned effects (scope self, at its current
## level) is pushed again; with several, its controller chooses which.
func _retrigger_on_summon(pid: int, t: CardInstance) -> void:
	var effs := t.active_effects()
	var idx: Array = []
	for i in effs.size():
		var e: Dictionary = effs[i]
		if str(e.get("timing", "")) == "on_summon" and str(e.get("kind", "")) == "triggered" \
				and str(e.get("scope", "self")) == "self":
			idx.append(i)
	if idx.is_empty():
		return
	if idx.size() == 1:
		push(t, effs[int(idx[0])], pid, {"ctx": {"uid": t.uid, "player": t.controller_id}})
		return
	var labels: Array = []
	var branches: Array = []
	for i2: Variant in idx:
		labels.append(str((effs[int(i2)] as Dictionary).get("text", "When Summoned")).left(70))
		branches.append({"directives": [{"op": "push_effect_of", "uid": t.uid, "index": int(i2)}]})
	state.pending_choice = {"type": "option", "player": pid, "prompt": "Activate which When Summoned effect again?",
			"labels": labels, "branches": branches}


func _pay_soul(pid: int, frame: Dictionary) -> bool:
	var p := state.player(pid)
	if p.reserve_soul > 0:
		return state.move_cores(GameState.pool(pid, BSS.Zone.RESERVE), GameState.pool(pid, BSS.Zone.TRASH), 1, true, true) > 0
	var me: CardInstance = state.card(int(frame.get("source", -1)))
	var order: Array = []
	if me != null and me.zone == BSS.Zone.FIELD:
		order.append(me)
	for c in state.all_field_cards():
		if c.controller_id == pid and not order.has(c):
			order.append(c)
	for c: CardInstance in order:
		if c.soul_cores > 0:
			return state.move_cores(GameState.on_card(c.uid), GameState.pool(pid, BSS.Zone.TRASH), 1, true, true) > 0
	return false


func _remove_cores_from(pid: int, d: Dictionary, t: CardInstance, frame: Dictionary = {}) -> void:
	_rule_by_uid = int(frame.get("source", -1))
	_remove_cores_inner(pid, d, t)
	_rule_by_uid = -1
	# "When you destroy a spirit with this effect" (0.12.0): a spirit left
	# with no cores is destroyed at the next checkpoint; note it on the frame.
	if t.zone == BSS.Zone.FIELD and t.data != null and t.data.is_spirit() and t.total_cores() == 0 \
			and not frame.is_empty():
		if not frame.has("flags"):
			frame["flags"] = {}
		frame["flags"]["zeroed"] = true
		frame["flags"]["zeroed_n"] = int(frame["flags"].get("zeroed_n", 0)) + 1


func _remove_cores_inner(pid: int, d: Dictionary, t: CardInstance) -> void:
	# "...cannot have its cores removed by your opponent's effects" (0.11.0)
	if (bool(t.flags.get("core_lock", false)) or rule_applies_vs(t, "core_lock", state.card(_rule_by_uid))) \
			and t.controller_id != pid:
		state.log_event("cores_protected", {"uid": t.uid})
		return
	if d.has("leave"):
		# "Remove all but one core from it" (0.11.0)
		var keep := int(d.get("leave", 1))
		var n2 := maxi(0, t.total_cores() - keep)
		var dest2 := GameState.pool(t.owner_id, BSS.Zone.RESERVE)
		var moved2 := state.move_cores(GameState.on_card(t.uid), dest2, n2, false, true)
		if moved2 > 0 and t.controller_id != pid:
			t.flags["stripped_by"] = pid
			t.flags["stripped_src"] = _rule_by_uid          # the card whose effect did it (0.16.7)
		if moved2 > 0:
			state.log_event("cores_removed", {"uid": t.uid, "n": moved2, "by": pid})
		return
	if str(d.get("to", "reserve")) == "trash":
		var moved3 := state.move_cores(GameState.on_card(t.uid), GameState.pool(t.owner_id, BSS.Zone.TRASH),
				int(d.get("amount", 1)), false, true)
		if moved3 > 0 and t.controller_id != pid:
			t.flags["stripped_by"] = pid
			t.flags["stripped_src"] = _rule_by_uid          # the card whose effect did it (0.16.7)
		if moved3 > 0:
			state.log_event("cores_removed", {"uid": t.uid, "n": moved3, "by": pid})
		return
	# Purple's standard wording is "...to your opponent's reserve": the soul
	# core may go there, so a spirit holding only the soul core is not immune.
	# "to": "void" is the harsher variant; 4-11-3 keeps the soul core out of
	# the void, so that one only takes regular cores.
	var to_void := str(d.get("to", "reserve")) == "void"
	var dest := GameState.pool(t.owner_id, BSS.Zone.VOID if to_void else BSS.Zone.RESERVE)
	var n := state.move_cores(GameState.on_card(t.uid), dest, int(d.get("amount", 1)), false, not to_void)
	if n > 0 and t.controller_id != pid:
		t.flags["stripped_by"] = pid
		t.flags["stripped_src"] = _rule_by_uid          # the card whose effect did it (0.16.7)
	if n > 0:
		state.log_event("cores_removed", {"uid": t.uid, "n": n, "by": pid})


func _cores_from_trash(pid: int, d: Dictionary, t: CardInstance) -> void:
	# "that are not a soul core" (ST07) keeps the soul core back; "two cores
	# from your trash" (Set 1, allow_soul) may include it.
	var n := int(d.get("amount", 1))
	var moved := state.move_cores(GameState.pool(pid, BSS.Zone.TRASH), GameState.on_card(t.uid), n, false, false)
	if moved < n and bool(d.get("allow_soul", false)):
		state.move_cores(GameState.pool(pid, BSS.Zone.TRASH), GameState.on_card(t.uid), n - moved, true, true)


# ---- 0.14.0 helpers ---------------------------------------------------------

func _frame_flag(frame: Dictionary, flag: String, value: Variant = true) -> void:
	if frame.is_empty():
		return
	if not frame.has("flags"):
		frame["flags"] = {}
	frame["flags"][flag] = value


## Move your soul core: from the effect's own card (from_self), else from the
## reserve, else from whichever of your cards holds it.
func _move_soul(pid: int, dest: Dictionary, from_self: bool, frame: Dictionary) -> bool:
	if from_self:
		var me: CardInstance = state.card(int(frame.get("source", -1)))
		return me != null and state.move_cores(GameState.on_card(me.uid), dest, 1, true, true) > 0
	if state.player(pid).reserve_soul > 0:
		return state.move_cores(GameState.pool(pid, BSS.Zone.RESERVE), dest, 1, true, true) > 0
	for c in state.all_field_cards():
		if c.controller_id == pid and c.soul_cores > 0:
			return state.move_cores(GameState.on_card(c.uid), dest, 1, true, true) > 0
	return false


## "Your opponent's effects cannot return your spirits to your hand or deck."
func _bounce_blocked(pid: int, t: CardInstance) -> bool:
	if t.zone != BSS.Zone.FIELD or t.controller_id == pid:
		return false
	for r: Dictionary in active_rules(t.controller_id, "no_bounce"):
		# "Your exhausted spirits cannot be returned ..." -- "for" limits which
		# spirits it protects (0.15.0, BSS04-007); without it, all of them
		var rf: Dictionary = (r["d"] as Dictionary).get("for", {})
		if rf.is_empty() or _passes_filter(t.controller_id, t, {"filters": rf, "count": 0}, {}):
			return true
	return false


## Field card -> top or bottom of its owner's deck, telling anyone who cares
## ("when one of your opponent's spirits is returned to their deck", 0.15.0, BSS04-055).
func _return_to_deck(t: CardInstance, top: bool) -> void:
	var from_field := t.zone == BSS.Zone.FIELD
	var owner := t.owner_id
	state.move_card(t.uid, BSS.Zone.DECK, owner, top)
	if from_field:
		trigger("returned_to_deck", {"uid": t.uid, "player": owner})


## "Reveal the top card. If it is a Terrasaur spirit card, add it to your
## hand; if not, return it to the top / discard it."
func _op_reveal_top_take(pid: int, d: Dictionary, frame: Dictionary) -> void:
	var deck := state.player(pid).deck
	if deck.is_empty():
		return
	var top: CardInstance = state.card(int(deck[0]))
	var ok := _passes_filter(pid, top, {"filters": d.get("filters", {}), "card_type": d.get("card_type", "")}, frame)
	_log_reveal(pid, [top.uid], [top.uid] if ok else [])
	if ok and bool(d.get("summon", false)):
		# "... summon it without paying its cost" (0.15.0)
		state.move_card(top.uid, BSS.Zone.FIELD, pid)
		state.move_cores(GameState.pool(pid, BSS.Zone.RESERVE), GameState.on_card(top.uid),
				top.data.min_level_cost(), false, true)
		top.summoned_this_turn = true
		state.log_event("summon", {"player": pid, "uid": top.uid, "cost": 0, "from": "deck"})
		trigger("on_summon", {"uid": top.uid, "player": pid})
	elif ok:
		state.move_card(top.uid, BSS.Zone.HAND, pid)
		trigger("added_to_hand", {"player": pid})
	elif str(d.get("rest", "top")) == "trash":
		state.move_card(top.uid, BSS.Zone.TRASH, pid)


## "Then discard any number of cards and send one core from that spirit to
## its owner's trash for each card discarded" (Core Theft).
func _offer_discard_for_cores(pid: int, t: CardInstance) -> void:
	var k := mini(state.player(pid).hand.size(), t.total_cores())
	if k <= 0:
		return
	var labels: Array = []
	var branches: Array = []
	for n in range(k, -1, -1):
		labels.append("Discard %d" % n)
		var dirs: Array = []
		if n > 0:
			dirs = [{"op": "discard", "amount": n},
					{"op": "remove_cores", "amount": n, "to": "trash", "target": {"zone": "uid", "uid": t.uid}}]
		branches.append({"directives": dirs})
	state.pending_choice = {"type": "option", "player": pid, "prompt": "Discard how many cards?",
			"labels": labels, "branches": branches}


func _who(pid: int, d: Dictionary) -> int:
	match str(d.get("player", "self")):
		"opponent": return state.opponent_of(pid)
		"turn_player": return state.turn_player
		_: return pid


func _core_src(pid: int, d: Dictionary, frame: Dictionary) -> Dictionary:
	return _core_loc(pid, d.get("from", {"zone": "reserve"}), frame)


func _core_dest(pid: int, d: Dictionary, frame: Dictionary) -> Dictionary:
	return _core_loc(pid, d.get("to", {"zone": "reserve"}), frame)


func _core_loc(pid: int, spec: Variant, frame: Dictionary) -> Dictionary:
	if typeof(spec) != TYPE_DICTIONARY:
		return GameState.pool(pid, BSS.Zone.RESERVE)
	var s: Dictionary = spec
	if str(s.get("zone", "")) == "self":
		return GameState.on_card(int(frame.get("source", -1)))
	if str(s.get("zone", "")) == "trigger":
		var meta: Dictionary = frame.get("meta", {})
		return GameState.on_card(int((meta.get("ctx", {}) as Dictionary).get("uid", -1)))
	if s.has("uid"):
		return GameState.on_card(int(s["uid"]))
	var owner := _who(pid, s)
	match str(s.get("zone", "reserve")):
		"reserve": return GameState.pool(owner, BSS.Zone.RESERVE)
		"trash": return GameState.pool(owner, BSS.Zone.TRASH)
		"life": return GameState.pool(owner, BSS.Zone.LIFE)
		"void": return GameState.pool(owner, BSS.Zone.VOID)
	return GameState.pool(owner, BSS.Zone.RESERVE)


# ---------------------------------------------------------------------------
# 8-5-3 Targeting
# ---------------------------------------------------------------------------

## Collect every card that satisfies a target spec.
##
##   {"controller":"self"|"opponent"|"any", "zone":"field", "card_type":"spirit",
##    "count":1 | "up_to":2 | "all":true, "filters":{...}}
func collect_targets(pid: int, tspec: Dictionary, frame: Dictionary) -> Array:
	var out: Array = []
	var zone_name := str(tspec.get("zone", "field"))
	# {"zone": "self"} is the effect's own card: "this spirit gains...",
	# "put a core on this spirit" (R-039). Never a choice.
	if zone_name == "self":
		var me: CardInstance = state.card(int(frame.get("source", -1)))
		if me != null and me.zone == BSS.Zone.FIELD:
			out.append(me)
		return out
	# {"zone": "trigger"} is the card that set the trigger off: "when one of
	# your spirits blocks, IT gets +1000 BP" on a nexus (0.10.0).
	if zone_name == "trigger":
		var meta: Dictionary = frame.get("meta", {})
		var ctx: Dictionary = meta.get("ctx", {})
		var who: CardInstance = state.card(int(ctx.get("uid", -1)))
		if who != null and who.zone == BSS.Zone.FIELD:
			out.append(who)
		return out
	# 0.14.0: a card named by uid (a follow-up directive), the target of the
	# previous directive ("that spirit"), the trigger card wherever it is now.
	if zone_name == "uid":
		var u: CardInstance = state.card(int(tspec.get("uid", -1)))
		if u != null and u.zone == BSS.Zone.FIELD:
			out.append(u)
		return out
	# "The linked spirit" (0.15.0, Set 6): the other side of the source's link
	if zone_name == "linked_partner":
		var lsrc: CardInstance = state.card(int(frame.get("source", -1)))
		if lsrc != null and lsrc.zone == BSS.Zone.FIELD:
			var lp: CardInstance = state.card(lsrc.linked_to if lsrc.linked_to >= 0 else lsrc.linked_from)
			if lp != null and lp.zone == BSS.Zone.FIELD:
				out.append(lp)
		return out
	# "among the discarded cards" (0.15.0, BSS06-031): the previous mill's cards
	if zone_name == "milled":
		for mu: Variant in (frame.get("flags", {}) as Dictionary).get("milled_uids", []):
			var mci: CardInstance = state.card(int(mu))
			if mci != null and mci.zone == BSS.Zone.TRASH and _passes_filter(pid, mci, tspec, frame):
				out.append(mci)
		return out
	if zone_name == "last_target":
		var lt: CardInstance = state.card(int((frame.get("flags", {}) as Dictionary).get("last_target", -1)))
		if lt != null and lt.zone == BSS.Zone.FIELD:
			out.append(lt)
		return out
	if zone_name == "trigger_any":
		var tm0: Dictionary = frame.get("meta", {})
		var ta: CardInstance = state.card(int((tm0.get("ctx", {}) as Dictionary).get("uid", -1)))
		if ta != null:
			out.append(ta)
		return out
	# {"zone": "blocker"} is the spirit blocking in the battle that set the
	# trigger off: "remove a core from your opponent's blocking spirit" (0.12.0)
	if zone_name == "blocker":
		var bmeta: Dictionary = frame.get("meta", {})
		var bctx: Dictionary = bmeta.get("ctx", {})
		var blk: CardInstance = state.card(int(bctx.get("blocker", -1)))
		# "blocked by one of your opponent's spirits that costs 7 or less" -- a
		# description, not a selection (0.15.0, BSS04-056)
		if blk != null and blk.zone == BSS.Zone.FIELD and (not tspec.has("filters") or \
				_passes_filter(pid, blk, {"filters": tspec["filters"], "count": 0}, frame)):
			out.append(blk)
		return out
	# "one of your opponent's spirits that is being blocked by ..." -- the
	# attacking spirit of the current battle (0.15.0, BSS03-124). Still a
	# selection, so Armor and "cannot be selected" apply.
	if zone_name == "battle_attacker":
		if not state.battle.is_empty():
			var ba: CardInstance = state.card(int(state.battle.get("attacker", -1)))
			if ba != null and ba.zone == BSS.Zone.FIELD and _passes_filter(pid, ba, tspec, frame):
				out.append(ba)
		return out
	var owners: Array = []
	match str(tspec.get("controller", "any")):
		"self": owners = [pid]
		"opponent": owners = [state.opponent_of(pid)]
		_: owners = [0, 1]

	for o in owners:
		var uids: Array = []
		match zone_name:
			"field": uids = state.player(o).field.duplicate()
			"hand": uids = state.player(o).hand.duplicate()
			"trash": uids = state.player(o).trash.duplicate()
			"deck": uids = state.player(o).deck.duplicate()
		for uid in uids:
			var ci: CardInstance = state.cards[uid]
			if ci.flags.get("resolving", false):
				continue                              # 10-8-7 invisible while resolving
			if _passes_filter(pid, ci, tspec, frame):
				out.append(ci)
	return out


func _passes_filter(pid: int, ci: CardInstance, tspec: Dictionary, frame: Dictionary) -> bool:
	if ci.data == null:
		return false
	var f: Dictionary = tspec.get("filters", {})
	var ctv: Variant = tspec.get("card_type", "")
	if typeof(ctv) == TYPE_ARRAY:
		# "one of their spirits with 3000 or fewer BP, or one of their
		# nexuses" (0.11.0): any of several card types
		var any_type := false
		for t: Variant in ctv:
			if BSS.card_type_from_string(str(t)) == ci.data.card_type or \
					(ci.orig_data != null and BSS.card_type_from_string(str(t)) == ci.orig_data.card_type):
				any_type = true
		if not any_type:
			return false
	elif str(ctv) != "" and BSS.card_type_from_string(str(ctv)) != ci.data.card_type and \
			not (ci.orig_data != null and BSS.card_type_from_string(str(ctv)) == ci.orig_data.card_type):
		return false       # a nexus treated as a spirit is still a nexus (0.15.0, BSS05-082)
	if f.has("color"):
		var col := BSS.color_from_string(str(f["color"]))
		if not ci.data.has_color(col): return false
	if f.has("spirit_type") and not ci.has_family(str(f["spirit_type"])):
		return false
	if f.has("not_spirit_type") and ci.has_family(str(f["not_spirit_type"])):
		return false
	# effective_cost: "while this card is in the trash, it is treated as costing 5" (0.15.0, BSS04-025)
	if f.has("cost_max") and ci.effective_cost() > int(f["cost_max"]): return false
	if f.has("cost_min") and ci.effective_cost() < int(f["cost_min"]): return false
	if f.has("bp_max") and ci.data.is_spirit() and ci.current_bp() > int(f["bp_max"]): return false
	if f.has("bp_min") and ci.current_bp() < int(f["bp_min"]): return false
	if f.has("level_max") and ci.current_level() > int(f["level_max"]): return false
	if f.has("exhausted") and ci.is_exhausted() != bool(f["exhausted"]): return false
	# 0.11.0 filters
	if f.has("cores_min") and ci.total_cores() < int(f["cores_min"]): return false
	if f.has("has_soul") and (ci.soul_cores > 0) != bool(f["has_soul"]): return false
	if f.has("has_timing") and not ci.has_timing(str(f["has_timing"])): return false
	if f.has("spirit_types"):
		var hit2 := false
		for want2: Variant in f["spirit_types"]:
			if ci.has_family(str(want2)): hit2 = true
		if not hit2: return false
	if f.has("not_self_uid") and ci.uid == int(frame.get("source", -1)): return false
	# 0.11.1 filters
	if f.has("cores_max") and ci.total_cores() > int(f["cores_max"]): return false
	if f.has("is_source") and (ci.uid == int(frame.get("source", -1))) != bool(f["is_source"]): return false
	if f.has("vanilla") and ci.data.effects.is_empty() != bool(f["vanilla"]): return false
	if f.has("not_trigger"):
		var tm: Dictionary = frame.get("meta", {})
		if ci.uid == int((tm.get("ctx", {}) as Dictionary).get("uid", -2)): return false
	# 0.14.0 filters (Set 1)
	if f.has("keyword_any"):
		var any_kw := false
		for kn: Variant in f["keyword_any"]:
			var kwi := BSS.keyword_from_string(str(kn))
			if kwi >= 0 and ci.has_keyword(kwi): any_kw = true
		if not any_kw: return false
	if f.has("not_keyword"):
		var nk := BSS.keyword_from_string(str(f["not_keyword"]))
		if nk >= 0 and ci.has_keyword(nk): return false
	if f.has("not_attacking") and not state.battle.is_empty() and ci.uid == int(state.battle.get("attacker", -1)):
		return false
	var fctx: Dictionary = (frame.get("meta", {}) as Dictionary).get("ctx", {})
	if f.has("bp_max_ctx") and ci.current_bp() > int(fctx.get("bp", 0)): return false
	if f.has("bp_eq_ctx") and ci.current_bp() != int(fctx.get(str(f["bp_eq_ctx"]), -1)): return false
	if f.has("cost_lt_ctx"):
		var cc: CardInstance = state.card(int(fctx.get("uid", -1)))
		if cc == null or cc.data == null or ci.data.cost >= cc.data.cost: return false
	# 0.12.0 filters
	if f.has("not_same_name"):
		# "a NERV card other than Rei Ayanami": not a card named like this one
		var me2: CardInstance = state.card(int(frame.get("source", -1)))
		if me2 != null and me2.data != null and ci.data.name == me2.data.name:
			return false
	if f.has("keyword"):
		var kw := BSS.keyword_from_string(str(f["keyword"]))
		if kw >= 0 and not ci.has_keyword(kw): return false   # 10-13
	if bool(f.get("exclude_self", false)) and ci.uid == int(frame.get("source", -1)):
		return false
	# 0.15.0 filters (Sets 2-6)
	if f.has("cost_in") and not (f["cost_in"] as Array).has(ci.effective_cost()) and \
			not (f["cost_in"] as Array).has(float(ci.effective_cost())):
		return false
	if f.has("is_token") and bool(ci.flags.get("is_token", false)) != bool(f["is_token"]): return false
	if f.has("mecha_or_nexus") and not (ci.data.is_nexus() or ci.has_family("Mecha")):
		return false
	if f.has("level_min") and ci.current_level() < int(f["level_min"]): return false
	if f.has("not_has_timing") and ci.has_timing(str(f["not_has_timing"])): return false
	if f.has("attacking") and (not state.battle.is_empty() and ci.uid == int(state.battle.get("attacker", -1))) \
			!= bool(f["attacking"]):
		return false
	if f.has("bp_lt_attacker"):
		var atk0: CardInstance = state.card(int(state.battle.get("attacker", -1))) if not state.battle.is_empty() else null
		if atk0 == null or ci.current_bp() >= atk0.current_bp(): return false
	if f.has("cost_eq_last_target"):
		var lt0: CardInstance = state.card(int((frame.get("flags", {}) as Dictionary).get("last_target", -1)))
		if lt0 == null or lt0.data == null or lt0.data.cost != ci.data.cost: return false
	if f.has("cost_matches_my_spirit"):
		var cm := false
		for sp0 in state.field_spirits(pid):
			if sp0.uid != ci.uid and sp0.data.cost == ci.data.cost: cm = true
		if not cm: return false
	if f.has("bp_gt_opponent_max"):
		for sp1 in state.field_spirits(state.opponent_of(pid)):
			if sp1.current_bp() >= ci.current_bp(): return false
	# 0.15.0 filters (Set 3)
	# "a Ruby Sanctuary": the card name contains the text (BSS03-001 ...)
	if f.has("name_has") and not ci.data.name.containsn(str(f["name_has"])): return false
	# "spirits whose BP equals this spirit's BP" (BSS03-003)
	if f.has("bp_eq_source"):
		var bsrc: CardInstance = state.card(int(frame.get("source", -1)))
		if bsrc == null or bsrc.current_bp() != ci.current_bp(): return false
	# "if it has the same cost as any of your spirits" -- for a card off the field (BSS03-034)
	if f.has("cost_matches_mine"):
		var cm2 := false
		for sp2 in state.field_spirits(pid):
			if sp2.uid != ci.uid and sp2.data.cost == ci.data.cost: cm2 = true
		if not cm2: return false
	# "a spirit that spent a soul core on its summoning cost" (BSS03-066)
	if f.has("soul_paid") and bool(ci.flags.get("soul_paid", false)) != bool(f["soul_paid"]): return false
	# "your attacking spirits" (BSS03-119)
	if f.has("is_attacking") and (not state.battle.is_empty() and ci.uid == int(state.battle.get("attacker", -1))) \
			!= bool(f["is_attacking"]):
		return false
	# "it and all of your spirits that share a family with it" -- the others (BSS03-120)
	if f.has("shares_family_with_last"):
		var lt1: CardInstance = state.card(int((frame.get("flags", {}) as Dictionary).get("last_target", -1)))
		if lt1 == null or lt1.data == null or lt1.uid == ci.uid: return false
		var share := false
		for fam: String in lt1.data.spirit_types:
			if ci.has_family(fam): share = true
		for fam2: Variant in lt1.constant_types:
			if ci.has_family(str(fam2)): share = true
		if not share: return false
	# 0.15.0 filters (Set 4)
	# "spirits with one symbol" (BSS04-001, -055, -120, -128, -132)
	if f.has("symbols_exactly") and ci.symbol_count() != int(f["symbols_exactly"]): return false
	# "your attacking or blocking spirits" (BSS04-137)
	if f.has("in_battle"):
		var inb := not state.battle.is_empty() and (ci.uid == int(state.battle.get("attacker", -1)) \
				or ci.uid == int(state.battle.get("blocker", -1)))
		if inb != bool(f["in_battle"]): return false
	# "spirits that cost the same as your life total" (BSS04-035)
	if f.has("cost_eq_life") and (ci.effective_cost() == state.player(ci.controller_id).life_total()) \
			!= bool(f["cost_eq_life"]):
		return false
	# "one of your other Leaf Kindred spirits or one of your nexuses that costs
	# 3 or less" (BSS04-076): passes if any sub-spec passes
	if f.has("any_of"):
		var any_ok := false
		for sub: Variant in f["any_of"]:
			if _passes_filter(pid, ci, {"filters": (sub as Dictionary).get("filters", {}),
					"card_type": (sub as Dictionary).get("card_type", ""), "count": 0}, frame):
				any_ok = true
		if not any_ok: return false
	# "one of your spirits is summoned with Swift" (BSS04-078)
	if f.has("summoned_with") and str(ci.flags.get("summoned_with", "")) != str(f["summoned_with"]): return false
	# "their spirit with the highest cost" -- ties: any of them (BSS03-093)
	if f.has("cost_is_max"):
		var t2: Dictionary = tspec.duplicate(true)
		(t2["filters"] as Dictionary).erase("cost_is_max")
		var top_cost := -1
		for o2: CardInstance in collect_targets(pid, t2, frame):
			top_cost = maxi(top_cost, o2.effective_cost())
		if ci.effective_cost() < top_cost: return false
	# 0.15.0 filters (Sets 5-6)
	# "a spirit with only one color" / "two or more colors" (BSS05-022 / -048 / -100, BSS06-016)
	if f.has("single_color") and (ci.data.colors.size() == 1) != bool(f["single_color"]): return false
	if f.has("multicolor") and (ci.data.colors.size() >= 2) != bool(f["multicolor"]): return false
	# "your white or green spirits" (BSS05-065 / -109); "is not red" (BSS05-116)
	if f.has("color_any"):
		var ca := false
		for cn: Variant in f["color_any"]:
			if ci.data.has_color(BSS.color_from_string(str(cn))): ca = true
		if not ca: return false
	if f.has("not_color") and ci.data.has_color(BSS.color_from_string(str(f["not_color"]))): return false
	# 'a card with "Cooking" in its card name' (BSS06-031 / -040)
	if f.has("name_contains") and not ci.data.name.containsn(str(f["name_contains"])): return false
	var lt5: CardInstance = state.card(int((frame.get("flags", {}) as Dictionary).get("last_target", -1)))
	# "BP equal to or fewer than the selected token spirit" (BSS06-040)
	if f.has("bp_max_last_target") and (lt5 == null or ci.current_bp() > lt5.current_bp()): return false
	# "costs the same as or less than the spirit you returned" (BSS06-053)
	if f.has("cost_max_last_target") and (lt5 == null or lt5.data == null or ci.effective_cost() > lt5.effective_cost()):
		return false
	# "costs more than the card discarded by this effect" (BSS06-115)
	if f.has("cost_gt_flag"):
		var fv: Variant = (frame.get("flags", {}) as Dictionary).get(str(f["cost_gt_flag"]), null)
		if fv == null or ci.effective_cost() <= int(fv): return false
	# "your linked spirits" (BSS06-046 / -087 / -109)
	if f.has("linked") and (ci.linked_to >= 0 or ci.linked_from >= 0) != bool(f["linked"]): return false
	# "your opponent's spirit with the lowest cost" -- ties: any of them (BSS05-110 / -139)
	if f.has("lowest_cost"):
		var t3: Dictionary = tspec.duplicate(true)
		(t3["filters"] as Dictionary).erase("lowest_cost")
		t3["count"] = 0
		var low := 9999
		for o3: CardInstance in collect_targets(pid, t3, frame):
			low = mini(low, o3.effective_cost())
		if ci.effective_cost() > low: return false
	# "cannot be selected by the effects of your opponent's spirits" (BSS05-039) /
	# "... of your opponent's magic" (BSS06-062): selection only
	if ci.controller_id != pid and not bool(tspec.get("all", false)) and int(tspec.get("count", 1)) != 0:
		var usrc: CardInstance = state.card(int(frame.get("source", -1)))
		if bool(ci.flags.get("untargetable_by_spirits", false)) and usrc != null and usrc.data != null \
				and usrc.data.is_spirit():
			return false
		var ub: Variant = ci.flags.get("untargetable_by", null)
		if typeof(ub) == TYPE_DICTIONARY and usrc != null and usrc.data != null and \
				_passes_filter(usrc.controller_id, usrc, {"filters": (ub as Dictionary).get("filters", {}),
				"card_type": (ub as Dictionary).get("card_type", ""), "count": 0}, {}):
			return false

	# "Your EVA-01 spirits cannot be selected by your opponent's effects"
	# (0.12.0): a constant rule from another card. Only selection is
	# blocked -- an effect on "all" spirits still applies.
	if ci.controller_id != pid and not bool(tspec.get("all", false)) and int(tspec.get("count", 1)) != 0 \
			and rule_applies_vs(ci, "untargetable", state.card(int(frame.get("source", -1)))):
		return false
	# "Your opponent's effects can only select your spirits that have a soul
	# core on them" (0.15.0, BSS03-061)
	if ci.controller_id != pid and not bool(tspec.get("all", false)) and int(tspec.get("count", 1)) != 0 \
			and ci.data.is_spirit() and ci.soul_cores == 0 \
			and rule_applies_vs(ci, "soul_only_selectable", state.card(int(frame.get("source", -1)))):
		return false
	# 11-5 Armor -- a spirit with Armor cannot be *selected* by an opposing
	# effect of a listed colour. This is the single place that check lives.
	if ci.controller_id != pid and ci.has_keyword(BSS.Keyword.ARMOR) and int(tspec.get("count", 1)) != 0:
		var src: CardInstance = state.card(int(frame.get("source", -1)))
		if src != null and src.data != null:
			var protected: Variant = ci.keyword_value(BSS.Keyword.ARMOR)
			var colors: Array = protected if typeof(protected) == TYPE_ARRAY else []
			for c in colors:
				if ci.data != null and src.data.has_color(BSS.color_from_string(str(c))):
					return false
	return true


## 8-5-3-1 through 8-5-3-4 -- resolve a target list into the actual selection,
## asking the controller when a genuine choice exists.
func _op_targeted(pid: int, d: Dictionary, frame: Dictionary, action: Callable) -> String:
	var tspec: Dictionary = d.get("target", {"controller": "any", "zone": "field"})
	var pool := collect_targets(pid, tspec, frame)
	if pool.is_empty():
		return ""                                     # 8-5-3-4 ignore silently
	var act := func(t: CardInstance) -> void:
		_frame_flag(frame, "last_target", t.uid)
		action.call(t)
	if bool(tspec.get("all", false)):
		for t in pool: act.call(t)
		return ""
	var want := int(tspec.get("count", 1))
	var up_to := tspec.has("up_to") or bool(d.get("optional", false))
	if tspec.has("up_to"): want = int(tspec["up_to"])
	if tspec.has("count_flag"):
		# "one for each spirit card discarded" (0.15.0): a count set
		# earlier in the same effect.
		want = int((frame.get("flags", {}) as Dictionary).get(str(tspec["count_flag"]), 0))
		if want <= 0:
			return ""
	if tspec.has("count_per"):
		# "select one for each Fabled Beast you control" (0.14.0)
		want = collect_targets(pid, tspec["count_per"], frame).size()
		if want <= 0:
			return ""
	if tspec.has("up_to_symbols"):
		# "up to as many of your opponent's spirits as you have yellow symbols" (0.15.0, BSS04-035)
		want = int(state.player(pid).count_field_symbols(state).get(BSS.color_from_string(str(tspec["up_to_symbols"])), 0))
		up_to = true
		if want <= 0:
			return ""
	if bool(tspec.get("count_self_level", false)):
		# "one ... for each level this spirit has" (0.15.0, BSS03-083)
		var lvs: CardInstance = state.card(int(frame.get("source", -1)))
		want = lvs.current_level() if lvs != null else 0
		if want <= 0:
			return ""
	# "Your opponent selects one of their spirits" (0.14.0)
	var chooser := state.opponent_of(pid) if str(d.get("chooser", "")) == "opponent" else pid
	# "The next time your opponent would select while using a magic card, you
	# select instead" (0.15.0)
	var steal_key := "%d:steal_select" % state.opponent_of(chooser)
	var stealing := bool((frame.get("meta", {}) as Dictionary).get("magic", false)) and chooser == pid \
			and int(state.turn_flags.get(steal_key, 0)) > 0
	var budget := int(tspec.get("cost_budget", -1))
	var budget_kind := "cost"
	if tspec.has("bp_budget"):
		budget = int(tspec["bp_budget"])
		budget_kind = "bp"
	if budget >= 0:
		# "any number with a combined cost of N or less" (0.11.2): if every
		# target fits, take them all; otherwise the player picks a set.
		var total := 0
		for t in pool: total += (t.current_bp() if budget_kind == "bp" else t.data.cost)
		if total <= budget:
			for t in pool: act.call(t)
			return ""
		want = pool.size()
		up_to = true
	if pool.size() <= want and not up_to:
		# 8-5-3-1 / 8-5-3-3 -- fewer targets than required means take them all.
		for t in pool: act.call(t)
		return ""
	# A real decision: park it.
	if stealing:
		state.turn_flags[steal_key] = int(state.turn_flags[steal_key]) - 1
		chooser = state.opponent_of(chooser)
	var uids: Array = []
	for t in pool: uids.append(t.uid)
	state.pending_choice = {
		"type": "select_cards",
		"player": chooser,
		"options": uids,
		"count": want,
		"up_to": up_to,
		"cost_budget": budget,
		"budget_kind": budget_kind,
		"prompt": str(d.get("prompt", "Select target(s)")) if budget < 0 \
				else "Select spirits with a combined cost of %d or less" % budget,
		"resume": {"frame_index": _frame_index(frame), "op": d},
	}
	return "await"


## "Treat it as LVn" -- or, since 0.11.2, "as its highest level" ("level": "max").
func _level_for(d: Dictionary, t: CardInstance) -> int:
	if str(d.get("level", "")) == "max" and t.data != null:
		return maxi(1, t.data.max_level())
	return int(d.get("level", 1))


## "Select any number of spirits with a combined cost of N or less" (0.11.2):
## keep picks in the order given, skipping any that would break the budget.
func _within_budget(picks: Array, budget: int, kind: String = "cost") -> Array:
	var out: Array = []
	var spent := 0
	for uid: Variant in picks:
		var ci: CardInstance = state.card(int(uid))
		if ci == null or ci.data == null:
			continue
		var v := ci.current_bp() if kind == "bp" else ci.data.cost
		if spent + v > budget:
			continue
		spent += v
		out.append(uid)
	return out


## Where `frame` sits on the effect stack, or -1 if it is not on it.
func _frame_index(frame: Dictionary) -> int:
	for i in range(state.effect_stack.size() - 1, -1, -1):
		if is_same(state.effect_stack[i], frame):
			return i
	return -1


func deliver_choice(pid: int, pc: Dictionary, choice: Variant) -> Dictionary:
	match str(pc.get("type", "")):
		"select_cards":
			var chosen: Array = choice if typeof(choice) == TYPE_ARRAY else [choice]
			if int(pc.get("cost_budget", -1)) >= 0:
				chosen = _within_budget(chosen, int(pc["cost_budget"]), str(pc.get("budget_kind", "cost")))
			var d: Dictionary = pc["resume"]["op"]
			var fi0 := int((pc.get("resume", {}) as Dictionary).get("frame_index", -1))
			var pframe: Dictionary = state.effect_stack[fi0] if fi0 >= 0 and fi0 < state.effect_stack.size() else {}
			_depth += 1
			if d.has("_reveal"):
				# a reveal choice (search_top / reveal_summon / scry), 0.16.1
				_resume_reveal(pid, d, chosen, pframe)
				chosen = []
			for uid in chosen:
				var ci: CardInstance = state.card(int(uid))
				if ci == null or not pc["options"].has(int(uid)):
					continue
				_frame_flag(pframe, "last_target", ci.uid)
				_apply_chosen(int(pframe.get("controller", pid)) if not pframe.is_empty() else pid, d, ci, pframe)
			_depth -= 1
			# Advance past the directive we parked on -- in the frame that
			# parked, not whatever is on top now (R-058: a trigger that joined
			# the stack meanwhile had its own directive skipped). A choice
			# asked outside any effect (Gale) has frame_index -1: nothing to
			# advance.
			var fi := int((pc.get("resume", {}) as Dictionary).get("frame_index", -1))
			if fi >= 0 and fi < state.effect_stack.size():
				var frame: Dictionary = state.effect_stack[fi]
				frame["dir_index"] = int(frame["dir_index"]) + 1
			_flush_deferred()
			resolve_top()
			return {"ok": true, "reason": ""}
		"option":
			var idx := int(choice)
			var branches: Array = pc.get("branches", [])
			if idx >= 0 and idx < branches.size():
				# The chosen branch runs as an effect of its own on top of the
				# stack (R-058, 0.11.0), so a branch directive that needs a
				# target picked parks and resumes like any other. Before, the
				# branch ran inline and anything after such a directive was lost.
				# Keyword prompts (Raid, Immortal, bursts) are asked with no
				# effect on the stack (R-049); their branch frame has no parent.
				var on_stack := not state.effect_stack.is_empty() and not bool(pc.get("keyword_prompt", false))
				var parent: Dictionary = state.effect_stack[state.effect_stack.size() - 1] if on_stack else {}
				if on_stack:
					parent["dir_index"] = int(parent["dir_index"]) + 1
				var sub: Array = branches[idx].get("directives", [])
				if not sub.is_empty():
					var pmeta: Dictionary = parent.get("meta", {})
					# (0.15.0) the branch sees the parent's frame flags ("that
					# spirit", "if you do"), e.g. BSS05-130's top-or-bottom choice
					state.effect_stack.append({
						"source": int(parent.get("source", pc.get("source_uid", -1))),
						"spec": {"directives": sub},
						"controller": pid,
						"meta": {"ctx": pmeta.get("ctx", {}), "branch": true},
						"dir_index": 0,
						"flags": (parent.get("flags", {}) as Dictionary).duplicate(),
					})
			_flush_deferred()
			resolve_top()
			return {"ok": true, "reason": ""}
		"discard":
			var picks: Array = choice if typeof(choice) == TYPE_ARRAY else [choice]
			if typeof(choice) == TYPE_NIL:
				picks = []
			var discarded_any := false
			var gone: Array = []
			for uid in picks:
				var ci2: CardInstance = state.card(int(uid))
				if ci2 != null and ci2.zone == BSS.Zone.HAND and ci2.controller_id == pid:
					if not (pc.get("options", []) as Array).has(ci2.uid):
						continue                         # only the offered cards (0.15.0)
					if gone.size() >= int(pc.get("count", 1)):
						break
					if bool(pc.get("to_bottom", false)):
						state.move_card(ci2.uid, BSS.Zone.DECK, ci2.owner_id, false)
					else:
						state.move_card(ci2.uid, BSS.Zone.TRASH, ci2.owner_id)
					discarded_any = true
					gone.append(ci2.uid)
			var f3: Dictionary = {}
			if not state.effect_stack.is_empty():
				f3 = state.effect_stack[state.effect_stack.size() - 1]
				f3["dir_index"] = int(f3["dir_index"]) + 1
				if discarded_any:
					_frame_flag(f3, "discarded")         # "If you do, ..." (0.15.0)
				_frame_flag(f3, "discarded_n", gone.size())      # BSS06-104 (0.15.0)
			if not bool(pc.get("to_bottom", false)) and not gone.is_empty():
				# "when ... discarded" effects wait until the discarding effect
				# has finished: they go in under it (8-5)
				_depth += 1
				note_discarded(gone, pid, int(f3.get("controller", pid)) if not f3.is_empty() else pid, f3)
				_depth -= 1
				var at := state.effect_stack.size() - 1 if not f3.is_empty() else state.effect_stack.size()
				for df: Dictionary in _deferred:
					state.effect_stack.insert(at, df)
					at += 1
				_deferred.clear()
			resolve_top()
			return {"ok": true, "reason": ""}
		"mulligan":
			engine._finish_mulligans(pid, bool(choice))
			return {"ok": true, "reason": ""}
	return {"ok": false, "reason": "unhandled choice type"}


func _apply_chosen(_pid: int, d: Dictionary, ci: CardInstance, frame: Dictionary = {}) -> void:
	match str(d.get("op", "")):
		"add_core_from_void":
			_void_cores_onto(_pid, d, ci, int(d.get("amount", 1)))
		# R-066: a chosen target is destroyed BY the effect's card, as an
		# unchosen one always was -- "when your opponent destroys your
		# spirit" bursts and A.T. Field depend on knowing who did it.
		"destroy":
			_destroy_by_effect(d, ci, frame)
		# ---- 0.15.0 (Set 3) ----
		"place_from": engine.place_free(_pid, ci)
		"set_symbols": _set_symbols(d, ci)
		"refresh_or_exhaust": _refresh_or_exhaust(_pid, d, ci)
		"activate_crush": engine.keywords.do_crush(ci)
		"attack_spirit":
			engine.attack_spirit_now(ci)
		"to_deck_bottom", "to_deck_top":
			if not _bounce_blocked(_pid, ci):
				_return_to_deck(ci, str(d.get("op", "")) == "to_deck_top")
		"discard_for_cores":
			_offer_discard_for_cores(_pid, ci)
		"remove_cores": _remove_cores_from(_pid, d, ci, frame)
		"add_cores_from_trash": _cores_from_trash(_pid, d, ci)
		"set_flag":
			ci.flags[str(d.get("flag", "x"))] = d.get("value", true)
			_register_continuous(d, ci.uid, "flag", str(d.get("flag", "x")))
		"return_to_hand":
			if not _bounce_blocked(_pid, ci):
				_return_to_hand(ci)
		# by_player: whose effect it is -- Gale's choice is made by the
		# defender but is the attacker's effect (0.15.0)
		"exhaust": _exhaust_or_instead(_pid, d, ci)        # instead_if (0.15.0, BSS05-132)
		"refresh":
			ci.orientation = BSS.Orientation.REFRESHED
			_flag_also(d, ci)
		"add_bp":
			ci.bp_add += int(d.get("amount", 0))
			_register_continuous(d, ci.uid, "bp_add", int(d.get("amount", 0)))
			_note_bp_zeroed(frame, ci, int(d.get("amount", 0)))
		"set_bp":
			ci.bp_set = int(d.get("amount", 0))
			_register_continuous(d, ci.uid, "bp_set", -1)
		"treat_as_level":
			_treat_as_level(_pid, d, ci, frame)
		"grant_keyword":
			var kw := BSS.keyword_from_string(str(d.get("keyword", "")))
			if kw >= 0:
				ci.granted_keywords.append({"keyword": kw, "value": d.get("value", null), "source": -1})
				_register_continuous(d, ci.uid, "keyword", kw)
		_:
			_apply_new(_pid, d, ci, frame)          # Sets 5-6 (0.15.0)


func _op_discard(pid: int, d: Dictionary, frame: Dictionary) -> String:
	var target := _who(pid, d)
	var n := int(d.get("amount", 1))
	# "Your opponent's effects cannot discard cards from your hand" (0.15.0, BSS05-110)
	if target != pid and not active_rules(target, "discard_protect").is_empty():
		state.log_event("discard_prevented", {"player": target})
		return ""
	# a magic card that is resolving is not in the hand any more (10-8-7, 0.15.0)
	var hand: Array = state.player(target).hand.filter(func(u0: int) -> bool:
		return not bool(state.cards[u0].flags.get("resolving", false)))
	# "Discard a red card" / "a spirit card with Crush" (0.15.0, Sets 3-4): only
	# cards passing card_type / filters may go; none -> nothing happens. Frame
	# flag "discarded" is set when at least one card went, for a following "if".
	if d.has("filters") or str(d.get("card_type", "")) != "":
		var ft := {"filters": d.get("filters", {}), "card_type": d.get("card_type", "")}
		hand = hand.filter(func(u: Variant) -> bool:
			var hc: CardInstance = state.card(int(u))
			return hc != null and not bool(hc.flags.get("resolving", false)) and _passes_filter(target, hc, ft, frame))
	if not hand.is_empty() and not bool(d.get("auto", false)) and hand.size() <= n:
		_frame_flag(frame, "discarded")
	var to_bottom := str(d.get("to", "")) == "deck_bottom"   # "return two cards to the bottom of your deck"
	if bool(d.get("auto", false)) and not hand.is_empty():
		# a discard inside a substitution is decided on the spot (0.14.0):
		# the cheapest card goes
		var cheap: Array = hand.duplicate()
		cheap.sort_custom(func(a: Variant, b: Variant) -> bool:
			return state.cards[int(a)].data.cost < state.cards[int(b)].data.cost)
		var gone: Array = []
		for i in mini(n, cheap.size()):
			state.move_card(int(cheap[i]), BSS.Zone.TRASH, target)
			gone.append(int(cheap[i]))
		note_discarded(gone, target, pid, frame)
		return ""
	if hand.size() <= n:
		# 1-3-2 -- perform as much as is possible.
		var gone2: Array = hand.duplicate()
		for uid in gone2:
			if to_bottom:
				state.move_card(uid, BSS.Zone.DECK, target, false)
			else:
				state.move_card(uid, BSS.Zone.TRASH, target)
		if not to_bottom:
			note_discarded(gone2, target, pid, frame)
		return ""
	state.pending_choice = {
		"type": "discard", "player": target, "count": n, "to_bottom": to_bottom,
		"options": hand.duplicate(), "mark_frame": true,
		"prompt": ("Put %d card(s) on the bottom of your deck" if to_bottom else "Discard %d card(s)") % n,
	}
	return "await"


func _op_choice(pid: int, d: Dictionary, _frame: Dictionary) -> String:
	state.pending_choice = {
		"type": "option", "player": _who(pid, d),
		"prompt": str(d.get("prompt", "Choose one")),
		"labels": d.get("labels", []),
		"branches": d.get("branches", []),
	}
	return "await"


func _op_summon_from(pid: int, d: Dictionary, frame: Dictionary) -> String:
	var tspec: Dictionary = d.get("target", {"controller": "self", "zone": "trash", "card_type": "spirit"})
	var pool := collect_targets(pid, tspec, frame)
	if pool.is_empty():
		return ""
	# Revive the strongest qualifying spirit (purple, 0.10.0). Before 0.10.0
	# this took whichever card happened to be first in the trash.
	pool.sort_custom(func(a: CardInstance, b: CardInstance) -> bool:
		return a.data.cost > b.data.cost)
	if str(tspec.get("zone", "")) == "hand" and not bool(d.get("free", false)):
		# "You may summon a green card from your hand by using cores from your
		# reserve" (0.11.0): the best one the reserve can pay for AND keep
		# alive -- never one that would die on arrival.
		# "pay": "normal" -- "you may summon a spirit card from your hand",
		# paying as usual: spare cores on your cards may pay too (0.15.0,
		# BSS04-077 / -112).
		var normal := str(d.get("pay", "")) == "normal"
		var res := state.player(pid).total_reserve() + (_spare_field_cores(pid) if normal else 0)
		pool = pool.filter(func(c: CardInstance) -> bool:
			return engine.compute_cost(pid, c.data) + c.data.min_level_cost() <= res)
		if pool.is_empty():
			return ""
		var pc0: CardInstance = pool[0]
		var act := {"via": "effect"}
		if normal:
			act["payment"] = _spare_first_payment(pid, engine.compute_cost(pid, pc0.data))
		engine.do_summon(pid, pc0, act, not normal)
		return ""
	# "Select up to two spirit cards ... and summon them" (0.15.0, BSS05-123,
	# BSS06-036): the target's up_to / count, best first
	var sn := int(tspec.get("up_to", tspec.get("count", 1)))
	for si in mini(maxi(1, sn), pool.size()):
		var ci: CardInstance = pool[si]
		if bool(d.get("free", false)):
			_summon_free(pid, ci, d)
		else:
			var sp: Variant = safe_summon_payment(pid, ci.data)
			if sp == null:
				continue                      # cannot be paid without a loss (0.16.6)
			engine.do_summon(pid, ci, {"via": "effect", "payment": sp})
		if ci.zone == BSS.Zone.FIELD:
			_frame_flag(frame, "summoned")       # "if you summon a spirit with this effect" (PR-068)
	return ""


## "Summon it without paying its cost" (0.10.0-0.15.0): from the trash, the
## hand or a revealed deck card. LV1 cores from the reserve, or from the void
## with cores_from_void; "exhausted"; "no_on_summon". Remembers where it came
## from ("if this spirit was summoned from the trash", BSS04-020).
func _summon_free(pid: int, ci: CardInstance, d: Dictionary) -> void:
	if ci == null or ci.data == null or not ci.data.is_spirit() or ci.zone == BSS.Zone.FIELD:
		return
	if engine.summon_blocked(pid, ci.data):
		return                                     # BSS03-103 (0.15.0)
	engine.note_summon(pid, ci.data)
	var from_zone := ci.zone
	state.move_card(ci.uid, BSS.Zone.FIELD, pid)
	ci.flags["summoned_from"] = ["deck", "hand", "trash"][from_zone] if from_zone <= BSS.Zone.TRASH else ""
	if bool(d.get("exhausted", false)):
		ci.orientation = BSS.Orientation.EXHAUSTED		  # "summon it exhausted" (0.15.0)
	# "...summon it without paying its cost, putting its LV1 cores on it
	# from the void" -- so a revive never strips your reserve.
	var src := GameState.pool(pid, BSS.Zone.VOID) if bool(d.get("cores_from_void", false)) \
			else GameState.pool(pid, BSS.Zone.RESERVE)
	state.move_cores(src, GameState.on_card(ci.uid), ci.data.min_level_cost(), false, true)
	ci.summoned_this_turn = true
	state.log_event("summon", {"player": pid, "uid": ci.uid, "cost": 0, "from": str(ci.flags["summoned_from"])})
	# "Its When Summoned effects do not activate" (0.15.0)
	if not bool(d.get("no_on_summon", false)):
		engine.effects.trigger("on_summon", {"uid": ci.uid, "player": pid})


## Cores on your cards above what they need for their current level (0.15.0).
func _spare_field_cores(pid: int) -> int:
	var n := 0
	for uid in state.player(pid).field:
		var c: CardInstance = state.cards[uid]
		n += maxi(0, c.cores - engine._level_floor(c))
	return n


## A payment for an effect's paid summon (Immortal, "summon it from your
## trash paying its cost") that loses nothing: spare cores first, then the
## reserve, leaving the new spirit's LV1 cores in the reserve. null when no
## such payment exists (0.16.6, I-026: before, these summons paid
## automatically, could strip a spirit below LV1 and left the new spirit
## with no cores, so both were destroyed at once).
func safe_summon_payment(pid: int, cd: CardData) -> Variant:
	var cost := engine.compute_cost(pid, cd)
	var spare := _spare_field_cores(pid)
	var reserve := state.player(pid).total_reserve()
	var from_reserve := maxi(0, cost - spare) + cd.min_level_cost()
	if from_reserve > reserve:
		return null
	return _spare_first_payment(pid, cost)


## A payment that spends those spare cores first, then the reserve -- so the
## reserve keeps the new spirit's LV1 cores (0.15.0).
func _spare_first_payment(pid: int, cost: int) -> Array:
	var plan: Array = []
	var left := cost
	for uid in state.player(pid).field:
		if left <= 0:
			break
		var c: CardInstance = state.cards[uid]
		var spare := mini(maxi(0, c.cores - engine._level_floor(c)), left)
		if spare > 0:
			var loc := GameState.on_card(c.uid)
			loc["n"] = spare
			plan.append(loc)
			left -= spare
	if left > 0:
		var r := GameState.pool(pid, BSS.Zone.RESERVE)
		r["n"] = left
		plan.append(r)
	return plan


## "Reveal the top N cards of your deck. Summon / place a <filter> card from
## among them without paying its cost and discard the rest" (0.15.0, BSS04-043,
## BSS04-102). The best match (highest cost) is taken; take = how many.
func _op_reveal_summon(pid: int, d: Dictionary, frame: Dictionary) -> String:
	var deck := state.player(pid).deck
	var top: Array = deck.slice(0, mini(int(d.get("amount", 1)), deck.size()))
	var tspec := {"filters": d.get("filters", {}), "card_type": d.get("card_type", "")}
	var matches: Array = []
	for uid in top:
		var c: CardInstance = state.cards[uid]
		if _passes_filter(pid, c, tspec, frame) and not (c.data.is_spirit() and engine.summon_blocked(pid, c.data)):
			matches.append(uid)
	matches.sort_custom(func(a: Variant, b: Variant) -> bool:
		return state.cards[int(a)].data.cost > state.cards[int(b)].data.cost)
	# "up_to": "summon up to three spirit cards with Agile" (0.15.0, BSS06-069)
	var want_n := maxi(0, int(d.get("take", d.get("up_to", 1))))
	# More legal cards than the effect takes: the player chooses, seeing every
	# revealed card (0.16.1, R-079). The choice resumes in _finish_reveal.
	if want_n > 0 and matches.size() > want_n:
		return _park_reveal(pid, d, frame, top, matches, want_n, d.has("up_to"),
				"Reveal: choose %s%d to summon" % ["up to " if d.has("up_to") else "", want_n])
	var taken: Array = matches.slice(0, want_n)
	_finish_reveal_summon(pid, d, top, taken)
	return ""


func _finish_reveal_summon(pid: int, d: Dictionary, top: Array, taken: Array) -> void:
	_log_reveal(pid, top, taken)
	for uid2 in top:
		if not taken.has(uid2):
			if str(d.get("rest", "trash")) == "trash":
				state.move_card(int(uid2), BSS.Zone.TRASH, pid)
			else:
				state.move_card(int(uid2), BSS.Zone.DECK, pid, false)
	for uid3 in taken:
		var tc: CardInstance = state.card(int(uid3))
		if tc.data.is_nexus():
			engine.place_free(pid, tc)
		else:
			_summon_free(pid, tc, d)


func _op_script(pid: int, d: Dictionary, frame: Dictionary) -> String:
	# Named GDScript hooks live in scripts/cards/<name>.gd and expose
	#   static func run(engine, pid, args, frame) -> String
	var name := str(d.get("name", ""))
	var path := "res://scripts/cards/%s.gd" % name
	if not ResourceLoader.exists(path):
		Log.warn("EffectSystem: missing card script %s" % path)
		return ""
	var scr = load(path)
	if scr == null or not scr.has_method("run"):
		return ""
	return str(scr.run(engine, pid, d.get("args", {}), frame))


# ---------------------------------------------------------------------------
# 8-8 Continuous directives and their lifetimes
# ---------------------------------------------------------------------------

func _register_continuous(d: Dictionary, uid: int, kind: String, payload: Variant) -> void:
	var dur := str(d.get("duration", "permanent"))
	if dur == "permanent":
		return
	var entry := {"duration": dur, "uid": uid, "kind": kind, "payload": payload}
	if dur == "opponent_next_turn":
		# the turn it lasts through: the next one if it is its controller's turn now
		var rc: CardInstance = state.card(uid)
		var mine := rc == null or state.turn_player == rc.controller_id
		entry["until_turn"] = state.turn_number + (1 if mine else 2)
	continuous.append(entry)


## 8-2-2-2 / 2-10-2 -- CONSTANT effects ("All of your red spirits gain 1000
## BP") apply for as long as their source is on the field at a printed level.
## They are recomputed from scratch, never accumulated: every call resets each
## card's constant layer and re-applies what is active now, so a nexus that
## levels down or leaves the field simply stops contributing. Called from
## every checkpoint and before BP is compared. Before 0.8.0 nothing applied
## constant effects at all (R-040).
func refresh_constants() -> void:
	var field := state.all_field_cards()
	state.life_redirect_uid = -1
	for lk in field:
		# last known level (0.16.7): a spirit stripped to 0 cores is destroyed
		# at the level it had, so its "When Destroyed" effects still apply
		if lk.data != null and lk.total_cores() >= lk.data.min_level_cost() and lk.total_cores() > 0:
			lk.flags["last_level"] = lk.current_level()
	for ci in field:
		ci.bp_constant = 0
		ci.constant_keywords = []
		ci.constant_kw_values = {}
		ci.constant_level = -1
		ci.constant_symbols = []
		ci.suppressed_levels = []
		ci.constant_types = []
		ci.constant_base_bp = {}
		ci.constant_suppressed = false
		ci.constant_cost = -1
	# "Swift for the spirit cards in your hand" (0.15.0): hand cards can hold
	# constant keywords too.
	for hp in 2:
		for hu in state.player(hp).hand:
			var hc: CardInstance = state.cards[hu]
			hc.constant_keywords = []
			hc.constant_kw_values = {}
			_keyword_conditions(hc)
	# "If you control a spirit with Gale, this card gains Swift in your hand"
	# (0.15.0, BSS03-070): a keyword printed with a condition counts only
	# while the condition holds.
	for kc in field:
		_keyword_conditions(kc)
	# "All nexuses lose their LV1 effects" (0.14.0) / "all LV1 nexuses lose
	# their effects" (0.15.0) apply before nexuses' own constant effects are read.
	for pid0 in 2:
		for r: Dictionary in active_rules(pid0, "suppress_nexus_lv1"):
			var at_lv1 := bool((r["d"] as Dictionary).get("nexus_at_lv1", false))
			for nx in field:
				if nx.data != null and nx.data.is_nexus():
					if not at_lv1:
						nx.suppressed_levels = [1]
					elif nx.current_level() == 1:
						nx.constant_suppressed = true
	var entries := _constant_entries()
	# Families first (0.15.0): "your yellow spirits are also Otherlanders"
	# changes what the other constant effects count.
	for en: Dictionary in entries:
		var d0: Dictionary = en["d"]
		if str(d0.get("op", "")) == "add_spirit_type":
			for t0 in collect_targets(int(en["ctrl"]), d0.get("target", {}), en["frame"]):
				if not t0.constant_types.has(str(d0.get("spirit_type", ""))):
					t0.constant_types.append(str(d0.get("spirit_type", "")))
	for en2: Dictionary in entries:
		var d: Dictionary = en2["d"]
		var ctrl := int(en2["ctrl"])
		var frame: Dictionary = en2["frame"]
		match str(d.get("op", "")):
			"add_bp":
				var amt := int(d.get("amount", 0))
				if d.has("per"):
					amt *= collect_targets(ctrl, d["per"], frame).size()
				for t in collect_targets(ctrl, d.get("target", {}), frame):
					# "+1000 BP for each core on it" (0.15.0)
					if bool(d.get("per_core_on_target", false)):
						t.bp_constant += amt * t.total_cores()
					elif bool(d.get("per_symbol", false)):
						t.bp_constant += amt * t.symbol_count()    # "for each symbol they have" (0.15.0, BSS04-104)
					else:
						t.bp_constant += amt
			"grant_keyword":
				# "All of your spirits with Awaken gain Confront" (0.11.0)
				var kw := BSS.keyword_from_string(str(d.get("keyword", "")))
				if kw >= 0:
					for t2 in collect_targets(ctrl, d.get("target", {}), frame):
						if not t2.constant_keywords.has(kw):
							t2.constant_keywords.append(kw)
						if d.has("value"):
							# two Armor grants protect against both lists (0.15.0)
							t2.constant_kw_values[kw] = t2._max_kw(t2.constant_kw_values.get(kw, null), d["value"])
			# 0.14.0 (Set 1)
			"set_level":
				for t3 in collect_targets(ctrl, d.get("target", {}), frame):
					t3.constant_level = _level_for(d, t3)
			"add_symbols":
				var grp: Array = []
				for c0: Variant in d.get("colors", []):
					grp.append(BSS.color_from_string(str(c0)))
				for t4 in collect_targets(ctrl, d.get("target", {}), frame):
					t4.constant_symbols.append(grp)
			"life_redirect":
				state.life_redirect_uid = int(frame.get("source", -1))
			# 0.15.0 (Set 2)
			"set_base_bp":
				for t5 in collect_targets(ctrl, d.get("target", {}), frame):
					t5.constant_base_bp[int(d.get("level", 1))] = int(d.get("bp", 0))
			# 0.15.0 (Set 6): "Treat this spirit as though it costs 5" (BSS06-054)
			"set_cost":
				for t6 in collect_targets(ctrl, d.get("target", {}), frame):
					t6.constant_cost = int(d.get("amount", t6.data.cost))


func _keyword_conditions(ci: CardInstance) -> void:
	ci.kw_cond_ok = []
	if ci.data == null:
		return
	for e: Dictionary in ci.data.effects:
		if str(e.get("timing", "")) == "keyword" and e.has("condition") and \
				check_condition(ci.controller_id, e["condition"], {"source": ci.uid, "controller": ci.controller_id}):
			ci.kw_cond_ok.append(BSS.keyword_from_string(str(e.get("keyword", ""))))


## Every constant directive in force now: printed constant effects of cards
## on the field, then "this turn" rules from resolved effects (0.15.0).
## [{ctrl, frame, d}]
func _constant_entries() -> Array:
	var out: Array = []
	for src in state.all_field_cards():
		if src.data == null:
			continue
		for spec in src.active_effects():
			if str(spec.get("kind", "")) != "constant":
				continue
			# "During your attack step: all of your spirits gain 1000 BP."
			if spec.has("during") and not during_ok(str(spec["during"]), src.controller_id):
				continue
			var frame := {"source": src.uid, "controller": src.controller_id}
			if spec.has("condition") and not check_condition(src.controller_id, spec["condition"], frame):
				continue
			for d: Dictionary in spec.get("directives", []):
				out.append({"ctrl": src.controller_id, "frame": frame, "d": d})
	for trl: Dictionary in state.turn_rules:
		out.append({"ctrl": int(trl["pid"]), "frame": {"source": int(trl["source"]), "controller": int(trl["pid"])},
				"d": trl["d"]})
	return out


## 6-8-1-2 -- "during this turn" effects stop applying in the end step.
func expire_duration(dur: String) -> void:
	var keep: Array = []
	for c in continuous:
		if str(c["duration"]) != dur:
			keep.append(c)
			continue
		var ci: CardInstance = state.card(int(c["uid"]))
		if ci == null:
			continue
		match str(c["kind"]):
			"bp_add": ci.bp_add -= int(c["payload"])
			"bp_set": ci.bp_set = int(c["payload"])
			"level_override": ci.level_override = int(c["payload"])
			"keyword":
				for i in range(ci.granted_keywords.size() - 1, -1, -1):
					if int(ci.granted_keywords[i]["keyword"]) == int(c["payload"]):
						ci.granted_keywords.remove_at(i)
						break
			"flag": ci.flags.erase(str(c["payload"]))
			"symbols": ci.symbol_override = c["payload"]      # 0.15.0 (BSS03-122)
			"granted_symbol":                                # 0.15.0 (BSS05-066)
				var gi := ci.granted_symbols.find(c["payload"])
				if gi >= 0:
					ci.granted_symbols.remove_at(gi)
			"as_spirit":                                     # 0.15.0 (BSS05-082)
				if ci.orig_data != null:
					ci.data = ci.orig_data
					ci.orig_data = null
	continuous = keep


## "until the end of your opponent's next turn" (0.15.0, BSS05-039): continuous
## effects registered with duration "opponent_next_turn" carry the turn number
## they last through; called at each end step.
func expire_through_turn(turn: int) -> void:
	for c in continuous:
		if str(c["duration"]) == "opponent_next_turn" and int(c.get("until_turn", 0)) <= turn:
			c["duration"] = "_expire_now"
	expire_duration("_expire_now")


## 7-1-6-2 -- battle-scoped windows.
func set_active_window(name: String, uid: int, on: bool) -> void:
	if on:
		active_windows[name] = uid
	else:
		active_windows.erase(name)
		expire_duration(name)


func window_uid(name: String) -> int:
	return int(active_windows.get(name, -1))


# ---------------------------------------------------------------------------
# 8-9 Substitution effects
# ---------------------------------------------------------------------------

## 10-1-3-2 -- give substitution effects the chance to replace a destruction.
## 8-9-3 caps this at one substitution per event, so the first match wins and
## the loop stops.
## 0.14.0: "by": "opponent_effect" -- only when an effect of the opponent's
## destroys it (not a lost battle); once_per_turn; include_self.
func _sub_allowed(spec: Dictionary, holder: CardInstance, ci: CardInstance, source_uid: int, by_battle: bool) -> bool:
	if str(spec.get("by", "")) == "opponent_effect":
		var src0: CardInstance = state.card(source_uid)
		if by_battle or src0 == null or src0.controller_id == ci.controller_id:
			return false
	if bool(spec.get("once_per_turn", false)):
		var key := "opt:sub:%d" % holder.data.effects.find(spec)
		if int(holder.flags.get(key, -1)) == state.turn_number:
			return false
	return true


func _sub_used(spec: Dictionary, holder: CardInstance) -> void:
	if bool(spec.get("once_per_turn", false)):
		holder.flags["opt:sub:%d" % holder.data.effects.find(spec)] = state.turn_number


func try_substitute_destruction(ci: CardInstance, _source_uid: int, by_battle: bool = false) -> bool:
	# "When one of your yellow spirits would be destroyed, you may exhaust
	# this nexus to return the spirit card to your hand instead" (0.11.1):
	# substitutions printed on OTHER cards you control, scope your_spirits.
	# A "may" here is taken whenever it can be paid -- a substitution has to
	# be decided on the spot.
	for src in state.all_field_cards():
		if src.controller_id != ci.controller_id or src.data == null:
			continue
		for spec2 in src.active_effects():
			if str(spec2.get("timing", "")) != "substitute_destruction" or str(spec2.get("scope", "")) != "your_spirits":
				continue
			if src.uid == ci.uid and not bool(spec2.get("include_self", false)):
				continue
			if not _sub_allowed(spec2, src, ci, _source_uid, by_battle):
				continue
			if spec2.has("during") and not during_ok(str(spec2["during"]), src.controller_id):
				continue
			if spec2.has("trigger_filter") and not _passes_filter(src.controller_id, ci,
					{"filters": spec2["trigger_filter"], "card_type": "spirit"}, {"source": src.uid}):
				continue
			var fr := {"source": src.uid, "controller": src.controller_id, "spec": spec2, "dir_index": 0,
					"meta": {"ctx": {"uid": ci.uid, "player": ci.controller_id}}}
			if spec2.has("condition") and not check_condition(src.controller_id, spec2["condition"], fr):
				continue
			_sub_used(spec2, src)
			for d2 in spec2.get("directives", []):
				execute(src.controller_id, d2, fr)
			return true
	for spec in ci.active_effects():
		if str(spec.get("timing", "")) != "substitute_destruction" or str(spec.get("scope", "self")) != "self":
			continue
		if spec.has("during") and not during_ok(str(spec["during"]), ci.controller_id):
			continue
		if not _sub_allowed(spec, ci, ci, _source_uid, by_battle):
			continue
		if spec.has("condition") and not check_condition(ci.controller_id, spec["condition"],
				{"source": ci.uid, "controller": ci.controller_id}):
			continue
		_sub_used(spec, ci)
		var frame := {"source": ci.uid, "controller": ci.controller_id, "spec": spec, "dir_index": 0}
		for d in spec.get("directives", []):
			execute(ci.controller_id, d, frame)
		return true
	return false


# ---------------------------------------------------------------------------
# Conditions
# ---------------------------------------------------------------------------

## Condition dictionaries are small boolean expressions over the board.
func check_condition(pid: int, cond: Dictionary, frame: Dictionary) -> bool:
	if cond.has("all"):
		for c in cond["all"]:
			if not check_condition(pid, c, frame): return false
		return true
	if cond.has("any"):
		for c in cond["any"]:
			if check_condition(pid, c, frame): return true
		return false
	if cond.has("not"):
		return not check_condition(pid, cond["not"], frame)

	match str(cond.get("type", "")):
		"life_at_most":
			return state.player(_who(pid, cond)).life_total() <= int(cond.get("amount", 0))
		"life_at_least":
			return state.player(_who(pid, cond)).life_total() >= int(cond.get("amount", 0))
		"symbol_count":
			var col := BSS.color_from_string(str(cond.get("color", "red")))
			return int(state.player(_who(pid, cond)).count_field_symbols(state).get(col, 0)) \
				>= int(cond.get("amount", 1))
		"controls":
			var pool := collect_targets(pid, cond.get("target", {}), frame)
			return pool.size() >= int(cond.get("amount", 1))
		"trash_count":
			return state.player(_who(pid, cond)).trash.size() >= int(cond.get("amount", 1))
		"hand_count":
			return state.player(_who(pid, cond)).hand.size() >= int(cond.get("amount", 1))
		"is_your_turn":
			return state.turn_player == pid
		"self_refreshed":
			var sr: CardInstance = state.card(int(frame.get("source", -1)))
			return sr != null and sr.is_refreshed()
		"soul_on_self":
			var me: CardInstance = state.card(int(frame.get("source", -1)))
			return me != null and me.soul_cores > 0
		"has_soul_core":
			var pl := state.player(_who(pid, cond))
			if pl.reserve_soul > 0:
				return true
			for c in state.all_field_cards():
				if c.controller_id == _who(pid, cond) and c.soul_cores > 0:
					return true
			return false
		"turn_flag":
			return state.turn_flag(_who(pid, cond), str(cond.get("flag", "")))
		"frame_flag":
			# set earlier in the same effect, e.g. "zeroed" by remove_cores
			return bool((frame.get("flags", {}) as Dictionary).get(str(cond.get("flag", "")), false))
		# ---- 0.14.0 (Set 1) ----
		"soul_paid":
			# the soul core was spent on this card's own cost
			var sp: CardInstance = state.card(int(frame.get("source", -1)))
			return sp != null and bool(sp.flags.get("soul_paid", false))
		"ascended_with":
			# "If this spirit performed Ascend using a 'Siegwurm'" / "... using a
			# spirit that costs 6 or more" (0.15.0, BSS04-001): the stripped
			# spirit's cost as it counted for Ascend (ascend_cost_as).
			var asc: CardInstance = state.card(int(frame.get("source", -1)))
			if asc == null or str(asc.flags.get("ascended_from", "")) == "":
				return false
			if cond.has("name") and not str(asc.flags["ascended_from"]).contains(str(cond["name"])):
				return false
			return not cond.has("cost_min") or int(asc.flags.get("ascended_cost", -1)) >= int(cond["cost_min"])
		"self_attacking":
			return not state.battle.is_empty() and int(state.battle.get("attacker", -1)) == int(frame.get("source", -1))
		"self_has_cores":
			var sh: CardInstance = state.card(int(frame.get("source", -1)))
			return sh != null and sh.total_cores() >= int(cond.get("amount", 1))
		"can_pay_cores":
			var avail := state.player(pid).total_reserve()
			for c2 in state.all_field_cards():
				if c2.controller_id == pid: avail += c2.total_cores()
			return avail >= int(cond.get("amount", 1))
		"burst_set":
			return state.player(_who(pid, cond)).burst >= 0
		"first_attack":
			return int(state.turn_flags.get("%d:attacks" % pid, 0)) <= 1
		"only_spirit_types", "only_spirit_colors", "same_cost":
			var mine0 := state.field_spirits(pid)
			if mine0.is_empty():
				return false
			var cost0: int = (mine0[0] as CardInstance).data.cost
			for sc: CardInstance in mine0:
				match str(cond["type"]):
					"only_spirit_types":
						var okt := false
						for want3: Variant in cond.get("spirit_types", []):
							for st3 in sc.data.spirit_types:
								if st3.to_lower() == str(want3).to_lower(): okt = true
						if not okt: return false
					"only_spirit_colors":
						var okc := false
						for col3: Variant in cond.get("colors", []):
							if sc.data.has_color(BSS.color_from_string(str(col3))): okc = true
						if not okc: return false
					"same_cost":
						if sc.data.cost != cost0: return false
			return true
		"level_at_least":
			var s: CardInstance = state.card(int(frame.get("source", -1)))
			return s != null and s.current_level() >= int(cond.get("amount", 1))
		# ---- 0.15.0 (Sets 2-6) ----
		"trash_has":
			# "If a spirit card with X in its name is in your trash"
			for tu in state.player(_who(pid, cond)).trash:
				var tc: CardInstance = state.card(int(tu))
				if tc == null or tc.data == null:
					continue
				if cond.has("name") and not tc.data.name.containsn(str(cond["name"])):
					continue
				if str(cond.get("card_type", "")) != "" and \
						BSS.card_type_from_string(str(cond["card_type"])) != tc.data.card_type:
					continue
				if cond.has("filters") and not _passes_filter(pid, tc, {"filters": cond["filters"]}, frame):
					continue
				return true
			return false
		"destroyer":
			# when_destroyed: what destroyed the card ("by" in the trigger
			# context) -- this spirit, or one of yours that costs N or more.
			var dctx: Dictionary = (frame.get("meta", {}) as Dictionary).get("ctx", {})
			var by: CardInstance = state.card(int(dctx.get("by", -1)))
			if by == null or by.data == null:
				return false
			if bool(cond.get("is_self", false)) and by.uid != int(frame.get("source", -1)):
				return false
			if str(cond.get("controller", "self")) == "self" and by.controller_id != pid:
				return false
			if cond.has("cost_min") and by.data.cost < int(cond["cost_min"]):
				return false
			if str(cond.get("controller", "self")) == "opponent" and by.controller_id == pid:
				return false                              # 0.15.0 (BSS04-108)
			# "an effect of one of your spirits" (0.15.0, BSS03-106)
			if str(cond.get("card_type", "")) != "" and \
					BSS.card_type_from_string(str(cond["card_type"])) != by.data.card_type:
				return false
			if bool(cond.get("by_effect", false)) and bool(dctx.get("by_battle", false)):
				return false
			if cond.has("filters") and not _passes_filter(pid, by, {"filters": cond["filters"]}, frame):
				return false
			return true
		"fewer_than_opponent":
			var foe0 := state.opponent_of(pid)
			if str(cond.get("what", "hand")) == "life":
				return state.player(pid).life_total() < state.player(foe0).life_total()
			return state.player(pid).hand.size() < state.player(foe0).hand.size()
		"during":
			return during_ok(str(cond.get("during", "")), pid)
		# ---- 0.15.0 (Set 3) ----
		"hand_has":
			# "You may discard a red card" -- only offered with one in hand (BSS03-007)
			var ht := {"filters": cond.get("filters", {}), "card_type": cond.get("card_type", "")}
			for hu in state.player(_who(pid, cond)).hand:
				var hc: CardInstance = state.card(int(hu))
				if hc != null and not bool(hc.flags.get("resolving", false)) and _passes_filter(pid, hc, ht, frame):
					return true
			return false
		"life_not_below_turn_start", "life_at_least_turn_start":
			# "If your life is the same as or higher than it was at the start of
			# the turn" (BSS03-058, BSS04-052)
			var lw := _who(pid, cond)
			return state.player(lw).life_total() >= int(state.turn_start_life[lw])
		# ---- 0.15.0 (Set 4) ----
		"summoned_from":
			# "If this spirit was summoned from the trash" (BSS04-020)
			var sfc: CardInstance = state.card(int(frame.get("source", -1)))
			return sfc != null and str(sfc.flags.get("summoned_from", "")) == str(cond.get("zone", "trash"))
		"first_magic_this_turn":
			# "The first time you use a magic card each turn" (BSS04-043)
			return int(state.turn_flags.get("%d:magic_count" % pid, 0)) == 1
		"bp_lead_over_blocker":
			# "if its BP is 5000 or more higher than the blocking spirit's" (BSS04-104)
			var lctx: Dictionary = (frame.get("meta", {}) as Dictionary).get("ctx", {})
			var la: CardInstance = state.card(int(lctx.get("uid", -1)))
			var lb: CardInstance = state.card(int(lctx.get("blocker", -1)))
			return la != null and lb != null and la.current_bp() - lb.current_bp() >= int(cond.get("amount", 0))
		"frame_flag_at_least":
			# "If two or more spirits are destroyed by this effect" (BSS04-136)
			return int((frame.get("flags", {}) as Dictionary).get(str(cond.get("flag", "")), 0)) >= int(cond.get("amount", 1))
		"blocked_by_mine":
			# "being blocked by one of your spirits with Curse" (BSS03-124)
			if state.battle.is_empty():
				return false
			var bm: CardInstance = state.card(int(state.battle.get("blocker", -1)))
			return bm != null and bm.zone == BSS.Zone.FIELD and bm.controller_id == pid \
					and _passes_filter(pid, bm, {"filters": cond.get("filters", {})}, frame)
		"spirit_count_vs_opponent":
			var mine_n := state.field_spirits(pid).size()
			var theirs_n := state.field_spirits(state.opponent_of(pid)).size()
			if bool(cond.get("at_most", false)):
				return mine_n <= theirs_n
			if bool(cond.get("fewer", false)):
				return mine_n < theirs_n
			if bool(cond.get("more", false)):
				return mine_n > theirs_n
			return mine_n >= theirs_n
		# ---- 0.15.0 (Set 5) ----
		"self_bp_gt_blocker":
			# "if it has higher BP than the blocking spirit" (BSS05-012)
			var gctx: Dictionary = (frame.get("meta", {}) as Dictionary).get("ctx", {})
			var gme: CardInstance = state.card(int(frame.get("source", -1)))
			var gb: CardInstance = state.card(int(gctx.get("blocker", state.battle.get("blocker", -1))))
			return gme != null and gb != null and gme.current_bp() > gb.current_bp()
		"destroyed_by_zero_bp":
			# "destroyed by having its BP reduced to 0" (BSS05-043): when_destroyed ctx
			return bool(((frame.get("meta", {}) as Dictionary).get("ctx", {}) as Dictionary).get("zero_bp", false))
		# ---- 0.15.0 (Set 6) ----
		"symbol_total":
			# "If you have ten or more symbols" (BSS06-001): a split symbol is one
			return state.player(_who(pid, cond)).field_symbol_groups(state).size() >= int(cond.get("amount", 1))
		"ref_matches":
			# "If it has 6000 or fewer BP" / "If it is a Surveyor spirit" (BSS06-011 / -091 / -105 / -109):
			# the card named by last_target or by the trigger, wherever it is now
			var rctx: Dictionary = (frame.get("meta", {}) as Dictionary).get("ctx", {})
			var ruid := int(rctx.get("uid", -1)) if str(cond.get("ref", "last_target")) == "trigger" \
					else int((frame.get("flags", {}) as Dictionary).get("last_target", -1))
			var rc: CardInstance = state.card(ruid)
			return rc != null and _passes_filter(pid, rc, {"filters": cond.get("filters", {}), "count": 0}, frame)
		"ctx_had_soul":
			# "one of your Supsprite spirits with a soul core on it is destroyed" (BSS06-041)
			return int(((frame.get("meta", {}) as Dictionary).get("ctx", {}) as Dictionary).get("soul", 0)) > 0
		"destroyed_by_effect":
			# "is destroyed by an effect" (BSS06-089): not by a lost battle
			var dbe: Dictionary = (frame.get("meta", {}) as Dictionary).get("ctx", {})
			return dbe.has("by_battle") and not bool(dbe["by_battle"])
		"trigger_is_attacker":
			# "When one of your attacking spirits is destroyed" (BSS06-096)
			var tia: Dictionary = (frame.get("meta", {}) as Dictionary).get("ctx", {})
			return not state.battle.is_empty() and int(tia.get("uid", -1)) == int(state.battle.get("attacker", -2))
		"reserve_at_least":
			# "you may pay one core from your reserve" (BSS06-059)
			return state.player(_who(pid, cond)).total_reserve() >= int(cond.get("amount", 1))
		"self_linked":
			# "While this spirit is linked" (Set 6): either side of a link
			var sl: CardInstance = state.card(int(frame.get("source", -1)))
			return sl != null and sl.zone == BSS.Zone.FIELD and (sl.linked_to >= 0 or sl.linked_from >= 0)
		"": return true
	return true


# ===========================================================================
# 0.11.0 -- effects needed by the starter-deck cards
# ===========================================================================

## Constant rules effects of player `pid` that are active right now and carry
## a directive with `op` -- cost changes, block restrictions and the like,
## which are asked for at the moment they matter rather than applied as BP.
## Returns [{"source": CardInstance, "d": directive}].
func active_rules(pid: int, op: String) -> Array:
	var out: Array = []
	for src in state.all_field_cards():
		if src.data == null or src.controller_id != pid:
			continue
		for spec in src.active_effects():
			if str(spec.get("kind", "")) != "constant":
				continue
			if spec.has("during") and not during_ok(str(spec["during"]), src.controller_id):
				continue
			var frame := {"source": src.uid, "controller": src.controller_id}
			if spec.has("condition") and not check_condition(src.controller_id, spec["condition"], frame):
				continue
			for d: Dictionary in spec.get("directives", []):
				if str(d.get("op", "")) == op:
					out.append({"source": src, "d": d})
	# "This turn, ..." rules from resolved effects (0.15.0)
	for trl: Dictionary in state.turn_rules:
		if int(trl["pid"]) == pid and str((trl["d"] as Dictionary).get("op", "")) == op:
			var tsrc: CardInstance = state.card(int(trl["source"]))
			if tsrc != null:
				out.append({"source": tsrc, "d": trl["d"], "turn_rule": true, "pid": pid})
	return out


## rule_applies, for protections that name what they protect against
## ("cannot be selected by your opponent's spirits' effects", 0.15.0).
func rule_applies_vs(ci: CardInstance, op: String, by: CardInstance) -> bool:
	if ci == null or ci.zone != BSS.Zone.FIELD:
		return false
	for r: Dictionary in active_rules(ci.controller_id, op):
		var rd: Dictionary = r["d"]
		if rd.has("by_card_type") and (by == null or by.data == null or \
				BSS.card_type_from_string(str(rd["by_card_type"])) != by.data.card_type):
			continue
		# "cannot be selected by your opponent's magic effects" (0.15.0, BSS03-091 / -112)
		if str(rd.get("by", "")) == "magic" and (by == null or by.data == null or not by.data.is_magic()):
			continue
		if rd.has("by_filter") and (by == null or by.data == null or \
				not _passes_filter(by.controller_id, by, {"filters": rd["by_filter"]}, {})):
			continue
		var src: CardInstance = r["source"]
		var fr := {"source": src.uid, "controller": ci.controller_id}
		for t in collect_targets(ci.controller_id, rd.get("target", {"zone": "self"}), fr):
			if t.uid == ci.uid:
				return true
	return false


## Pay N cores from wherever the player has them (reserve first, then the
## cards with the most cores to spare), to the trash. False if they cannot.
func _pay_cores_any(pid: int, n: int) -> bool:
	var p := state.player(pid)
	var avail := p.reserve_cores + p.reserve_soul
	for uid in p.field:
		avail += state.cards[uid].total_cores()
	if avail < n:
		return false
	var left := n - state.move_cores(GameState.pool(pid, BSS.Zone.RESERVE), GameState.pool(pid, BSS.Zone.TRASH), n,
			false, true)
	var cards: Array = []
	for uid2 in p.field:
		cards.append(state.cards[uid2])
	cards.sort_custom(func(a: CardInstance, b: CardInstance) -> bool:
		return a.total_cores() - a.data.min_level_cost() > b.total_cores() - b.data.min_level_cost())
	for c: CardInstance in cards:
		if left <= 0:
			break
		left -= state.move_cores(GameState.on_card(c.uid), GameState.pool(pid, BSS.Zone.TRASH), left, false, true)
	return true


## True when a constant rule `op` of its controller's cards names `ci`
## ("this spirit cannot attack", "must attack", "cannot be selected").
func rule_applies(ci: CardInstance, op: String) -> bool:
	if ci == null or ci.zone != BSS.Zone.FIELD:
		return false
	for r: Dictionary in active_rules(ci.controller_id, op):
		var src: CardInstance = r["source"]
		var frame := {"source": src.uid, "controller": src.controller_id}
		for t in collect_targets(src.controller_id, (r["d"] as Dictionary).get("target", {"zone": "self"}), frame):
			if t.uid == ci.uid:
				return true
	return false


## Field card -> hand, telling anyone who cares ("when one of your
## opponent's spirits returns to their hand").
func _return_to_hand(t: CardInstance) -> void:
	var from_field := t.zone == BSS.Zone.FIELD
	var owner := t.owner_id
	state.move_card(t.uid, BSS.Zone.HAND, owner)
	if from_field:
		trigger("returned_to_hand", {"uid": t.uid, "player": owner})
	else:
		trigger("added_to_hand", {"player": owner})


## "Reveal the top N cards of your deck. Add one <filter> card to your hand.
## Return the rest to the bottom." `take` = how many (0 = every match);
## `rest` = "bottom" or "trash". The best match (highest cost) is taken.
func _op_search_top(pid: int, d: Dictionary, frame: Dictionary) -> String:
	var who := _who(pid, d)
	var deck := state.player(who).deck
	var amount := int(d.get("amount", 3))
	if d.has("amount_per"):
		# "one card for each yellow spirit and nexus you control" (0.14.0)
		amount = collect_targets(pid, d["amount_per"], frame).size()
	if d.has("amount_if") and check_condition(pid, (d["amount_if"] as Dictionary).get("condition", {}), frame):
		amount = int((d["amount_if"] as Dictionary).get("amount", amount))
	var top: Array = deck.slice(0, mini(amount, deck.size()))
	var tspec := {"filters": d.get("filters", {}), "card_type": d.get("card_type", "")}
	var matches: Array = []
	for uid in top:
		if _passes_filter(pid, state.cards[uid], tspec, frame):
			matches.append(uid)
	matches.sort_custom(func(a: Variant, b: Variant) -> bool:
		return state.cards[int(a)].data.cost > state.cards[int(b)].data.cost)
	var take := int(d.get("take", 1))
	# A real choice -- more matching cards than the effect takes -- is the
	# player's, made while looking at every revealed card (0.16.1, R-079).
	# Before, the highest-cost match was taken silently.
	if take > 0 and matches.size() > take:
		return _park_reveal(who, d, frame, top, matches, take, false,
				"Reveal: choose %d to add to your hand" % take)
	var taken: Array = matches if take <= 0 else matches.slice(0, take)
	_finish_search_top(who, d, frame, top, taken)
	return ""


## Everything search_top does once the taken cards are known.
func _finish_search_top(who: int, d: Dictionary, frame: Dictionary, top: Array, taken: Array) -> void:
	_log_reveal(who, top, taken)
	# "to": "field" -- place a nexus taken this way without paying its cost
	# (0.15.0, BSS03-038 / BSS03-055); "to": "deck_top" -- put it back on top
	# of the deck instead of into the hand (BSS03-096). The rest go first, so
	# a card left on top stays there.
	var dest := str(d.get("to", "hand"))
	if dest == "hand":
		for uid in taken:
			state.move_card(int(uid), BSS.Zone.HAND, who)
		if not taken.is_empty():
			trigger("added_to_hand", {"player": who})
			if bool(d.get("flag_taken", false)):
				_frame_flag(frame, "taken")          # "If you added a card this way" (0.15.0, BSS05-088)
	for uid in top:
		if taken.has(uid):
			continue
		if str(d.get("rest", "bottom")) == "trash":
			state.move_card(int(uid), BSS.Zone.TRASH, who)
		else:
			state.move_card(int(uid), BSS.Zone.DECK, who, false)     # to the bottom
	if dest == "field":
		for uid2 in taken:
			engine.place_free(who, state.card(int(uid2)))
	elif dest == "deck_top":
		for uid3 in taken:
			state.move_card(int(uid3), BSS.Zone.DECK, who, true)


## "Look at the top N cards of your deck; put any number of them on the
## bottom." Kept: cards you could pay for with what you have now. The choice
## is made for you (I-024).
func _op_scry(pid: int, d: Dictionary, frame: Dictionary) -> String:
	var deck := state.player(pid).deck
	var top: Array = deck.slice(0, mini(int(d.get("amount", 2)), deck.size()))
	if top.is_empty():
		return ""
	# The player looks at the cards and picks any number to put on the bottom
	# (or discard, "to": "trash"); the rest stay on top (0.16.1, R-079 -- the
	# choice used to be made for them, I-024). Private: only they see them.
	var to_trash := str(d.get("to", "bottom")) == "trash"
	return _park_reveal(pid, d, frame, top, top, top.size(), true,
			"Look at the top %d: choose any to %s; the rest stay on top" % [top.size(), "discard" if to_trash else "put on the bottom"],
			true)


func _finish_scry(pid: int, d: Dictionary, top: Array, chosen: Array) -> void:
	var to_trash := str(d.get("to", "bottom")) == "trash"
	var moved := 0
	for uid in chosen:
		if not top.has(int(uid)):
			continue
		if to_trash:
			state.move_card(int(uid), BSS.Zone.TRASH, pid)
		else:
			state.move_card(int(uid), BSS.Zone.DECK, pid, false)
		moved += 1
	state.log_event("scry", {"player": pid, "looked": top.size(), "bottomed": moved})


## [{uid, card_id, legal}] for a reveal: what the player (and, when public,
## the opponent) sees. 0.16.1
func _reveal_list(uids: Array, legal: Array) -> Array:
	var out: Array = []
	for u: Variant in uids:
		var c: CardInstance = state.card(int(u))
		out.append({"uid": int(u), "card_id": c.data.id if c != null and c.data != null else "",
				"legal": legal.has(int(u))})
	return out


## A public "revealed" event, with card ids so the board can show the cards
## even though deck cards are hidden in snapshots (0.16.1, R-079).
func _log_reveal(who: int, uids: Array, taken: Array, extra: Dictionary = {}) -> void:
	var ids: Array = []
	for u: Variant in uids:
		var c: CardInstance = state.card(int(u))
		ids.append(c.data.id if c != null and c.data != null else "")
	var ev := {"player": who, "uids": uids.duplicate(), "taken": taken.duplicate(), "card_ids": ids}
	ev.merge(extra)
	state.log_event("revealed", ev)


## Park a reveal choice: the player sees `top`, may pick from `legal`.
## Resumes in deliver_choice via the op's "_reveal" record.
func _park_reveal(who: int, d: Dictionary, frame: Dictionary, top: Array, legal: Array, want: int,
		up_to: bool, prompt: String, private: bool = false) -> String:
	var rd: Dictionary = d.duplicate(true)
	rd["_reveal"] = {"who": who, "top": top.duplicate()}
	state.pending_choice = {
		"type": "select_cards", "player": who, "options": legal.duplicate(), "count": want, "up_to": up_to,
		"prompt": prompt, "revealed": _reveal_list(top, legal), "private": private,
		"resume": {"frame_index": _frame_index(frame), "op": rd},
	}
	return "await"


## The reveal choice came back: finish the op it belongs to. 0.16.1
func _resume_reveal(pid: int, d: Dictionary, chosen: Array, frame: Dictionary) -> void:
	var rv: Dictionary = d["_reveal"]
	var who := int(rv.get("who", pid))
	var top: Array = rv.get("top", [])
	var picks: Array = []
	for u: Variant in chosen:
		if top.has(int(u)) and not picks.has(int(u)):
			picks.append(int(u))
	match str(d.get("op", "")):
		"search_top": _finish_search_top(who, d, frame, top, picks)
		"reveal_summon": _finish_reveal_summon(who, d, top, picks)
		"scry": _finish_scry(who, d, top, picks)


## "Reveal the top card of your deck. If it costs the same as the destroyed
## spirit, add it to your hand; if not, discard it."
func _op_reveal_match_cost(pid: int, frame: Dictionary, fixed_cost: int = -1) -> void:
	# "If it costs the same as the destroyed spirit" -- or, with fixed_cost,
	# "if it costs 2" (0.11.1).
	var meta: Dictionary = frame.get("meta", {})
	var gone: CardInstance = state.card(int((meta.get("ctx", {}) as Dictionary).get("uid", -1)))
	var deck := state.player(pid).deck
	if deck.is_empty() or (gone == null and fixed_cost < 0):
		return
	var top: CardInstance = state.cards[deck[0]]
	var want := fixed_cost if fixed_cost >= 0 else gone.data.cost
	var hit := top.data.cost == want
	state.log_event("revealed", {"player": pid, "uids": [top.uid], "taken": [top.uid] if hit else []})
	state.move_card(top.uid, BSS.Zone.HAND if hit else BSS.Zone.TRASH, pid)
