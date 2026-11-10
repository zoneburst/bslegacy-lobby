extends RefCounted
class_name KeywordEngine
##
## The eighteen keyword effects of Comprehensive Rules section 11.
##
## Keywords get their own file rather than being expressed in the effect DSL
## because most of them hook into the battle sequence at points the DSL has no
## vocabulary for -- "at the end of the battle, but before while-attacking
## expires" is a real requirement for Curse and Luster and it is much clearer
## as code. Each method below names the paragraph it implements.
##

var engine: RulesEngine
var state: GameState


func _init(p_engine: RulesEngine) -> void:
	engine = p_engine
	state = p_engine.state


# --- 11-1 Awaken -----------------------------------------------------------
## An activated effect usable whenever the spirit could use a flash effect.
## Cores come from *other* cards you control; a card emptied this way is not
## considered destroyed for trigger purposes.
func awaken(pid: int, ci: CardInstance, action: Dictionary) -> Dictionary:
	if not ci.has_keyword(BSS.Keyword.AWAKEN):
		return {"ok": false, "reason": "that spirit has no Awaken"}
	if ci.zone != BSS.Zone.FIELD:
		return {"ok": false, "reason": "Awaken works only on the field"}
	var sources: Array = action.get("sources", [])
	if sources.is_empty():
		return {"ok": false, "reason": "choose which cards to take cores from"}
	var moved := 0
	for s in sources:
		var src: CardInstance = state.card(int(s.get("uid", -1)))
		if src == null or src.controller_id != pid or src.uid == ci.uid:
			continue
		moved += state.move_cores(GameState.on_card(src.uid), GameState.on_card(ci.uid),
				int(s.get("n", 1)), false, false)
		# 11-1-1: emptying a card this way suppresses its destruction triggers.
		if src.total_cores() < src.data.min_level_cost():
			engine._destroy_raw(src, true)
	if moved == 0:
		return {"ok": false, "reason": "no cores were moved"}
	state.log_event("awaken", {"uid": ci.uid, "n": moved})
	return {"ok": true, "reason": ""}


# --- 11-3 Curse ------------------------------------------------------------
## Triggers during battle resolution when the Curse spirit is blocked; the
## blocker dies at the end of the battle. Only one Curse ever applies (11-3-2).
func on_block(attacker: CardInstance, _blocker: CardInstance) -> void:
	if attacker != null and attacker.has_keyword(BSS.Keyword.CURSE):
		state.battle["curse"] = true
	# 11-10 Gale: when a spirit with Gale is blocked, the blocking player
	# exhausts N refreshed spirits they control.
	if attacker != null and attacker.has_keyword(BSS.Keyword.GALE):
		var n: Variant = attacker.keyword_value(BSS.Keyword.GALE)
		var count := int(n) if n != null else 1
		var defender := int(state.battle.get("defending_player", 0))
		var gp := attacker.controller_id
		var refreshed: Array = []
		for ci in state.field_spirits(defender):
			# Gale is the attacker's effect: "cannot be exhausted by your
			# opponent's effects" spirits are not offered (0.15.0, BSS04-106)
			if ci.is_refreshed() and not engine.effects.rule_applies(ci, "no_exhaust_by_opponent"):
				refreshed.append(ci.uid)
		if refreshed.size() <= count:
			for uid in refreshed:
				engine.effects.effect_exhaust(gp, state.cards[uid])
		else:
			# "This turn, you choose which spirits are exhausted by your Gale
			# effects" (0.15.0, BSS03-133)
			var chooser := gp if state.turn_flag(gp, "gale_you_choose") else defender
			state.pending_choice = {
				"type": "select_cards", "player": chooser, "options": refreshed,
				"count": count, "up_to": false, "prompt": "Gale: exhaust %d spirit(s)" % count,
				"resume": {"frame_index": -1, "op": {"op": "exhaust", "by_player": gp}},
			}
		state.log_event("gale", {"n": count})


# --- 11-11 Crush, 11-12 Raid, 11-18 Link, 11-14 Astral ---------------------
func on_attack(ci: CardInstance) -> void:
	# 11-11-1 / 11-11-3: mill level + modifier from the opponent's deck.
	if ci.has_keyword(BSS.Keyword.CRUSH):
		do_crush(ci)

	# 11-12-1: exhaust one of your nexuses to refresh the attacker, up to N
	# times per turn. Offered as a choice so the player keeps the option.
	# A Raid granted by a condition ("if your opponent has ten or more cards in
	# their trash", 0.11.2) must see the cards Crush just milled.
	engine.effects.refresh_constants()
	if ci.has_keyword(BSS.Keyword.RAID):
		var limit: Variant = ci.keyword_value(BSS.Keyword.RAID)
		var max_uses := int(limit) if limit != null else 1
		if ci.raid_uses_this_turn < max_uses:
			var has_nexus := false
			for nx in state.field_nexuses(ci.controller_id):
				if nx.is_refreshed(): has_nexus = true
			if has_nexus:
				state.pending_choice = {
					"type": "option", "player": ci.controller_id,
					"prompt": "Raid: exhaust a nexus to refresh %s?" % ci.data.name,
					"keyword_prompt": true,
					"labels": ["Yes", "No"],
					"branches": [
						{"directives": [{"op": "exhaust_nexus"}, {"op": "script",
							"name": "raid_refresh", "args": {"uid": ci.uid}}]},
						{"directives": []},
					],
				}

	# 11-18-1: another spirit with Link may exhaust itself to lend BP+symbols.
	_offer_links(ci)


## 11-11 Crush: discard the spirit's level + modifier from the top of the
## opponent's deck. Also "activate its Crush effect" (0.15.0, BSS03-088). The
## mill is an effect of the spirit's controller (EffectSystem.effect_mill).
func do_crush(ci: CardInstance) -> void:
	if ci == null or ci.zone != BSS.Zone.FIELD or not ci.has_keyword(BSS.Keyword.CRUSH):
		return
	var mod: Variant = ci.keyword_value(BSS.Keyword.CRUSH)
	var amount := ci.current_level() + (int(mod) if mod != null else 0)
	var opp := state.opponent_of(ci.controller_id)
	var milled_cards := engine.effects.effect_mill(ci.controller_id, opp, amount)
	state.log_event("crush", {"uid": ci.uid, "n": milled_cards.size()})
	# "When a spirit card is discarded by your Crush effect" (0.11.0);
	# "spirits": how many (0.15.0, BSS03-085 "+1000 BP for each")
	var spirits := 0
	for m in milled_cards:
		var mc: CardInstance = state.card(int(m))
		if mc != null and mc.data != null and mc.data.is_spirit():
			spirits += 1
	if spirits > 0:
		engine.effects.trigger("crush_milled_spirit", {"player": ci.controller_id, "uid": ci.uid, "spirits": spirits})


## 11-18 Link. The linking spirit exhausts; the attacker gains its BP and
## symbols for the battle. 11-18-3: links can't stack -- a spirit lends to one
## spirit and receives from one, unless a multi_link rule says more (BSS06-002).
##
## 0.15.0: "you MAY exhaust this spirit to link it" -- the attacker's controller
## is offered each eligible Link spirit (best BP first) or no link. The offer
## waits until the attack's other prompts and effects are done (Raid, When
## Attacks choices): offer_pending_links() runs after every accepted action.
func _offer_links(attacker: CardInstance) -> void:
	if state.battle.is_empty():
		return
	state.battle["link_offer"] = attacker.uid
	offer_pending_links()


## Make the waiting Link offer (state.battle.link_offer) once nothing else is pending.
func offer_pending_links() -> void:
	if state.battle.is_empty() or state.game_over or not state.pending_choice.is_empty() \
			or not state.effect_stack.is_empty():
		return
	var to_uid := int(state.battle.get("link_offer", -1))
	if to_uid < 0:
		return
	state.battle.erase("link_offer")
	var to: CardInstance = state.card(to_uid)
	if to == null or to.zone != BSS.Zone.FIELD:
		return
	var lenders := link_candidates(to)
	if lenders.is_empty():
		return
	lenders.sort_custom(func(a: CardInstance, b: CardInstance) -> bool: return a.current_bp() > b.current_bp())
	var labels: Array = []
	var branches: Array = []
	for l: CardInstance in lenders:
		labels.append("Link %s (+%d BP)" % [l.data.name, l.current_bp()])
		branches.append({"directives": [{"op": "do_link", "lender": l.uid, "to": to.uid}]})
	labels.append("Don't link")
	branches.append({"directives": []})
	state.pending_choice = {"type": "option", "player": to.controller_id, "keyword_prompt": true,
			"prompt": "Link: exhaust one of your spirits with Link to link it to %s?" % to.data.name,
			"labels": labels, "branches": branches, "source_uid": to.uid}


## Spirits that may link to `to` now: refreshed, with Link, not in a link,
## meeting their Link condition -- or allowed to ignore it (link_ignore_condition,
## BSS06-045; flag link_any on `to`, BSS06-060 / -091).
func link_candidates(to: CardInstance) -> Array:
	var out: Array = []
	if to == null or to.zone != BSS.Zone.FIELD or to.data == null or not to.data.is_spirit():
		return out
	var max_links := 1
	for r: Dictionary in engine.effects.active_rules(to.controller_id, "multi_link"):
		var fr := {"source": (r["source"] as CardInstance).uid, "controller": to.controller_id}
		if engine.effects.collect_targets(to.controller_id, (r["d"] as Dictionary).get("target", {}), fr).has(to):
			max_links = maxi(max_links, int((r["d"] as Dictionary).get("max", 1)))
	var have := 0
	for s in state.field_spirits(to.controller_id):
		if s.linked_to == to.uid:
			have += 1
	if have >= max_links or to.linked_to >= 0:
		return out
	var any_ok := bool(to.flags.get("link_any", false)) and not bool(to.flags.get("link_any_used", false))
	for ci in state.field_spirits(to.controller_id):
		if ci.uid == to.uid or not ci.is_refreshed() or not ci.has_keyword(BSS.Keyword.LINK):
			continue
		if ci.linked_to >= 0 or ci.linked_from >= 0:
			continue
		if _link_condition_met(to, ci.keyword_value(BSS.Keyword.LINK)) or any_ok \
				or engine.effects.rule_applies(ci, "link_ignore_condition"):
			out.append(ci)
	return out


## Link `lender` to `to`: it exhausts, `to` gains its BP and symbols until the
## battle ends. Fires on_link on the lender ("When This Spirit Links") and
## became_linked on both ("when this spirit is linked") -- 0.15.0.
func do_link(lender: CardInstance, to: CardInstance) -> void:
	if lender == null or to == null or lender.zone != BSS.Zone.FIELD or to.zone != BSS.Zone.FIELD:
		return
	if not link_candidates(to).has(lender):
		return
	if not _link_condition_met(to, lender.keyword_value(BSS.Keyword.LINK)) \
			and not engine.effects.rule_applies(lender, "link_ignore_condition"):
		to.flags["link_any_used"] = true               # BSS06-060: one spirit only
	lender.orientation = BSS.Orientation.EXHAUSTED
	lender.linked_to = to.uid
	if to.linked_from < 0:
		to.linked_from = lender.uid
	# The lender's BP and symbols are read live from here on (0.17.1): see
	# CardInstance.link_bp() / symbol_groups().
	to.link_lenders.append(lender)
	state.log_event("link", {"from": lender.uid, "to": to.uid})
	var pid := to.controller_id
	engine.effects.trigger("on_link", {"uid": lender.uid, "partner": to.uid, "player": pid})
	engine.effects.trigger("became_linked", {"uid": to.uid, "partner": lender.uid, "player": pid})
	engine.effects.trigger("became_linked", {"uid": lender.uid, "partner": to.uid, "player": pid})
	if not state.battle.is_empty() and not link_candidates(to).is_empty():
		state.battle["link_offer"] = to.uid                # another lender (multi_link)


func _link_condition_met(attacker: CardInstance, cond: Variant) -> bool:
	if cond == null:
		return true
	if typeof(cond) == TYPE_DICTIONARY:
		var c: Dictionary = cond
		# the cost every rule reads ("treat it as though it costs 5", BSS06-054)
		if c.has("cost_min") and attacker.effective_cost() < int(c["cost_min"]): return false
		if c.has("cost_max") and attacker.effective_cost() > int(c["cost_max"]): return false
		if c.has("color"):
			if not attacker.data.has_color(BSS.color_from_string(str(c["color"]))): return false
		# "Link: No Effects Listed" (0.15.0, BSS06-019)
		if c.has("vanilla") and attacker.data.effects.is_empty() != bool(c["vanilla"]): return false
	return true


## Links end when the battle ends (11-18-1 "during that battle"). A spirit
## leaving the field ends its links at once: GameState.unlink() (11-18-4).
## Only the link is removed: symbols granted by other effects stay (before
## 0.17.1 this cleared every granted symbol of a linked spirit).
func break_links(_battle: Dictionary) -> void:
	for pid in 2:
		for ci in state.field_spirits(pid):
			if ci.linked_from >= 0 or ci.linked_to >= 0 or not ci.link_lenders.is_empty():
				ci.flags.erase("link_any_used")
				ci.link_lenders = []
				ci.linked_from = -1
				ci.linked_to = -1


# --- 11-14 Astral ----------------------------------------------------------
## Constant. 11-14-2: when no timing is printed the effect is always live.
## 11-14-4: an "during opponent's turn" Astral is off while its spirit attacks.
func astral_active(ci: CardInstance) -> bool:
	if not ci.has_keyword(BSS.Keyword.ASTRAL):
		return false
	var timing: Variant = ci.keyword_value(BSS.Keyword.ASTRAL)
	if timing == null:
		return true
	match str(timing):
		"opponent_turn": return state.turn_player != ci.controller_id
		"your_turn": return state.turn_player == ci.controller_id
	return true


# --- 11-13 A.T. Field ------------------------------------------------------
## Constant. Prevents destruction by an opposing *spirit's* destruction effect
## while a soul core sits on the protected spirit. Note this is prevention, not
## substitution, so 8-9-3 does not consume the player's one substitution.
func at_field_protects(ci: CardInstance, source_uid: int) -> bool:
	if not ci.has_keyword(BSS.Keyword.AT_FIELD):
		return false
	if ci.soul_cores <= 0:
		return false
	var src: CardInstance = state.card(source_uid)
	if src == null or src.data == null:
		return false
	return src.data.is_spirit() and src.controller_id != ci.controller_id


# --- 11-7 Blessed ----------------------------------------------------------
## Triggers only when the attack actually reduced life (11-7-1), and once even
## with multiple copies (11-7-2).
func on_damage_dealt(attacker: CardInstance) -> void:
	if attacker == null or not attacker.has_keyword(BSS.Keyword.BLESSED):
		return
	state.move_cores(GameState.pool(attacker.controller_id, BSS.Zone.VOID),
			GameState.pool(attacker.controller_id, BSS.Zone.LIFE), 1)
	state.log_event("blessed", {"uid": attacker.uid})


# --- 11-3 Curse + 11-6 Luster resolution ----------------------------------
func on_battle_end(attacker: CardInstance, blocker: CardInstance) -> void:
	# 11-3-1: the blocker is destroyed at the end of the battle.
	if bool(state.battle.get("curse", false)) and blocker != null and blocker.zone == BSS.Zone.FIELD:
		engine.destroy(blocker, attacker.uid if attacker else -1)

	# 11-6-1: return every magic card the attacker's owner used this battle.
	if attacker != null and attacker.has_keyword(BSS.Keyword.LUSTER):
		for uid in state.battle.get("magic_used", []):
			var ci: CardInstance = state.card(int(uid))
			# 11-6-2: only cards still sitting in the trash come back.
			if ci != null and ci.zone == BSS.Zone.TRASH and ci.owner_id == attacker.controller_id:
				state.move_card(ci.uid, BSS.Zone.HAND, ci.owner_id)
		state.log_event("luster", {"uid": attacker.uid})


# --- 11-4 Immortal ---------------------------------------------------------
## Triggered from the trash when another spirit you control is destroyed.
func check_immortal(owner: int, destroyed_uid: int) -> void:
	var destroyed: CardInstance = state.card(destroyed_uid)
	for uid in state.player(owner).trash.duplicate():
		var ci: CardInstance = state.cards[uid]
		if ci.data == null or not ci.data.is_spirit():
			continue
		if not ci.has_keyword(BSS.Keyword.IMMORTAL):
			continue
		var cond: Variant = ci.keyword_value(BSS.Keyword.IMMORTAL)
		if not _immortal_condition_met(destroyed, cond):
			continue
		# Only offer it when it can be paid without losing a card (0.16.6)
		if engine.effects.safe_summon_payment(owner, ci.data) == null:
			continue
		# "During either attack step, ..." printed on the keyword (0.15.0, BSS03-030 / BSS04-032)
		var ks := keyword_spec(ci, BSS.Keyword.IMMORTAL)
		if ks.has("during") and not engine.effects.during_ok(str(ks["during"]), owner):
			continue
		# ... or in the keyword's value (0.15.0, BSS05-014 / -027 / -031 / -032, BSS06-024)
		if typeof(cond) == TYPE_DICTIONARY and (cond as Dictionary).has("during") \
				and not engine.effects.during_ok(str((cond as Dictionary)["during"]), owner):
			continue
		state.pending_choice = {
			"type": "option", "player": owner,
			"prompt": "Immortal: summon %s from your trash?" % ci.data.name,
			"keyword_prompt": true,
			"labels": ["Summon", "Decline"],
			"branches": [
				{"directives": [{"op": "script", "name": "immortal_summon", "args": {"uid": ci.uid}}]},
				{"directives": []},
			],
		}
		return


## The printed effect that gives `ci` keyword `kw` ({} if none) -- for what a
## keyword line says beside its value, e.g. its "during" (0.15.0).
func keyword_spec(ci: CardInstance, kw: int) -> Dictionary:
	if ci == null or ci.data == null:
		return {}
	for e: Dictionary in ci.data.effects:
		if str(e.get("keyword", "")) != "" and BSS.keyword_from_string(str(e["keyword"])) == kw:
			return e
	return {}


func _immortal_condition_met(destroyed: CardInstance, cond: Variant) -> bool:
	if destroyed == null or destroyed.data == null:
		return false
	if cond == null:
		return true
	if typeof(cond) == TYPE_DICTIONARY:
		var c: Dictionary = cond
		var dcost := destroyed.effective_cost()                   # set_cost (0.15.0, BSS06-054)
		if c.has("cost_min") and dcost < int(c["cost_min"]): return false
		if c.has("cost_max") and dcost > int(c["cost_max"]): return false
		if c.has("cost_in") and not (c["cost_in"] as Array).has(dcost) \
				and not (c["cost_in"] as Array).has(float(dcost)): return false     # 0.15.0
		if c.has("color") and not destroyed.data.has_color(BSS.color_from_string(str(c["color"]))): return false
		if c.has("spirit_type"):
			var want := str(c["spirit_type"]).to_lower()
			var hit := false
			for st in destroyed.data.spirit_types:
				if st.to_lower() == want: hit = true
			if not hit: return false
	return true


# --- 11-8 Ascend -----------------------------------------------------------
## An additional summoning cost: strip every core off a qualifying spirit you
## control and put those cores in your reserve.
##
## 0.15.0 (Set 4):
##   * "Ascend: Shadow or Nightling" -- keyword value spirit_types (any of them);
##   * "when you use this spirit to perform Ascend, treat it as though it costs
##     6" -- the stripped spirit's constant ascend_cost_as (ascend_cost());
##     that cost is also what "performed Ascend using a spirit that costs 6 or
##     more" reads (returned as from_cost);
##   * spirits that are made to be stripped (ascend_cost_as, or a
##     used_for_ascend effect) are taken first unless action.ascend_uid names one;
##   * "you may exhaust this nexus to summon it without paying its additional
##     Ascend summoning cost" (BSS04-114, waive_ascend): taken whenever such a
##     nexus is refreshed, unless action.ascend_uid names a spirit to strip or
##     action.waive_ascend is false. Nothing is stripped, so "performed Ascend
##     using ..." conditions are false.
func pay_ascend(pid: int, ci: CardInstance, action: Dictionary) -> Dictionary:
	var want := int(action.get("ascend_uid", -1))
	var waiver := _ascend_waiver(pid)
	if waiver != null and want < 0 and bool(action.get("waive_ascend", true)):
		engine.effects.effect_exhaust(pid, waiver)
		state.log_event("ascend_waived", {"by": waiver.uid, "to": ci.uid})
		return {"ok": true, "reason": "", "from_name": "", "from_uid": -1, "from_cost": -1}
	var candidates := _ascend_candidates(pid, ci)
	var need := _ascend_count(ci)
	if candidates.size() < need:
		return {"ok": false, "reason": "no spirit qualifies for Ascend"}
	var chosen: CardInstance = candidates[0]
	for c: CardInstance in candidates:
		if c.uid == want: chosen = c
	var from_cost := ascend_cost(chosen)
	# "Ascend: Skybinder x2" (0.15.0, BSS06-001): strip two of them
	var strip: Array = [chosen]
	for c2: CardInstance in candidates:
		if strip.size() >= need:
			break
		if not strip.has(c2):
			strip.append(c2)
	for s: CardInstance in strip:
		state.move_cores(GameState.on_card(s.uid), GameState.pool(pid, BSS.Zone.RESERVE),
				s.total_cores(), false, true)
		state.log_event("ascend", {"from": s.uid, "to": ci.uid})
	return {"ok": true, "reason": "", "from_name": chosen.data.name, "from_uid": chosen.uid, "from_cost": from_cost}


## How many spirits Ascend strips ("Ascend: Skybinder x2" -> 2; 0.15.0).
func _ascend_count(ci: CardInstance) -> int:
	var cond: Variant = ci.keyword_value(BSS.Keyword.ASCEND)
	if typeof(cond) == TYPE_DICTIONARY:
		return maxi(1, int((cond as Dictionary).get("count", 1)))
	return 1


func _ascend_candidates(pid: int, ci: CardInstance) -> Array:
	var cond: Variant = ci.keyword_value(BSS.Keyword.ASCEND)
	var fodder: Array = []
	var others: Array = []
	for s in state.field_spirits(pid):
		if s.uid == ci.uid or not _ascend_qualifies(s, cond):
			continue
		if s.has_timing("used_for_ascend") or ascend_cost(s) != s.data.cost:
			fodder.append(s)
		else:
			others.append(s)
	return fodder + others


## A refreshed nexus of `pid` whose waive_ascend rule is active now, or null.
func _ascend_waiver(pid: int) -> CardInstance:
	for r: Dictionary in engine.effects.active_rules(pid, "waive_ascend"):
		var src: CardInstance = r["source"]
		if src != null and src.zone == BSS.Zone.FIELD and src.is_refreshed():
			return src
	return null


## The cost a spirit counts as when it is used for Ascend (0.15.0): its own,
## or what its ascend_cost_as constant says ("treat it as though it costs 6").
func ascend_cost(s: CardInstance) -> int:
	for r: Dictionary in engine.effects.active_rules(s.controller_id, "ascend_cost_as"):
		var src: CardInstance = r["source"]
		var fr := {"source": src.uid, "controller": s.controller_id}
		for t in engine.effects.collect_targets(s.controller_id, (r["d"] as Dictionary).get("target", {"zone": "self"}), fr):
			if t.uid == s.uid:
				return int((r["d"] as Dictionary).get("cost", s.data.cost))
	return s.data.cost


## Is there a spirit Ascend could strip? (legal_actions, 0.14.0)
func can_ascend(pid: int, ci: CardInstance) -> bool:
	if _ascend_waiver(pid) != null:
		return true                                     # BSS04-114 (0.15.0)
	var cond: Variant = ci.keyword_value(BSS.Keyword.ASCEND)
	var n := 0
	for s in state.field_spirits(pid):
		if s.uid != ci.uid and _ascend_qualifies(s, cond):
			n += 1
	return n >= _ascend_count(ci)


func _ascend_qualifies(s: CardInstance, cond: Variant) -> bool:
	if cond == null:
		return true
	if typeof(cond) == TYPE_DICTIONARY:
		var c: Dictionary = cond
		if c.has("cost_min") and ascend_cost(s) < int(c["cost_min"]): return false
		# "Ascend: Shadow or Nightling" (0.15.0, BSS04-018 / -035 / -052)
		if c.has("spirit_types"):
			var any_t := false
			for t0: Variant in c["spirit_types"]:
				if s.has_family(str(t0)): any_t = true
			if not any_t: return false
		if c.has("color") and not s.data.has_color(BSS.color_from_string(str(c["color"]))): return false
		# "Ascend: Token" (0.15.0, BSS05-064)
		if c.has("is_token") and bool(s.flags.get("is_token", false)) != bool(c["is_token"]): return false
		if c.has("spirit_type"):
			var want := str(c["spirit_type"]).to_lower()
			for st in s.data.spirit_types:
				if st.to_lower() == want: return true
			return false
	return true


# --- 11-16 Agile -----------------------------------------------------------
## Triggers from the *hand* when a battle involving one of your cheaper spirits
## ends: bounce that spirit and summon the Agile card, paying its cost normally.
func check_agile(battle: Dictionary) -> void:
	for pid in 2:
		for uid in state.player(pid).hand:
			var ci: CardInstance = state.cards[uid]
			if ci.data == null or not ci.data.is_spirit():
				continue
			if not ci.has_keyword(BSS.Keyword.AGILE):
				continue
			var mine: Array = []
			for key in ["attacker", "blocker"]:
				var b: CardInstance = state.card(int(battle.get(key, -1)))
				if b != null and b.zone == BSS.Zone.FIELD and b.controller_id == pid \
						and b.data.cost < ci.data.cost:
					mine.append(b.uid)
			if mine.is_empty():
				continue
			state.pending_choice = {
				"type": "option", "player": pid,
				"prompt": "Agile: return your spirit and summon %s?" % ci.data.name,
				"labels": ["Yes", "No"],
				"branches": [
					{"directives": [{"op": "script", "name": "agile_swap",
						"args": {"hand_uid": ci.uid, "field_uid": mine[0]}}]},
					{"directives": []},
				],
			}
			return


# --- 11-17 Feast -----------------------------------------------------------
## Escalating Supsprite tokens. Small -> Medium -> Large, each upgrade paying
## for itself by stripping the cores off the token being replaced.
const SUPSPRITE_SIZES := ["Small", "Medium", "Large"]
const SUPSPRITE_BP := {"Small": 1000, "Medium": 3000, "Large": 6000}

func feast(pid: int) -> void:
	var smalls: Array = []
	var mediums: Array = []
	for ci in state.field_spirits(pid):
		if not ci.flags.get("is_token", false):
			continue
		match str(ci.flags.get("token_size", "")):
			"Small": smalls.append(ci)
			"Medium": mediums.append(ci)
	if not mediums.is_empty():
		_upgrade_supsprite(pid, mediums[0], "Large")
	elif not smalls.is_empty():
		_upgrade_supsprite(pid, smalls[0], "Medium")
	else:
		summon_token(pid, _supsprite_token("Small"))


func _upgrade_supsprite(pid: int, token: CardInstance, size: String) -> void:
	state.move_cores(GameState.on_card(token.uid), GameState.pool(pid, BSS.Zone.RESERVE),
			token.total_cores(), false, true)
	summon_token(pid, _supsprite_token(size))


func _supsprite_token(size: String) -> Dictionary:
	var bp: int = SUPSPRITE_BP.get(size, 1000)
	return {
		"name": "%s Supsprite Token" % size, "card_type": "spirit", "colors": ["green"],
		"cost": 0, "spirit_types": ["Supsprite"], "symbols": ["green"],
		"levels": [{"level": 1, "core_cost": 1, "bp": bp}], "size": size,
	}


## 4-12 -- tokens. A token is a full CardData built on the fly from the
## annotation in the creating effect, flagged so that 4-12-3 (removal from the
## game the instant it leaves the field) can find it.
func summon_token(pid: int, token_def: Dictionary, cores_from_void: bool = false) -> CardInstance:
	if token_def.is_empty():
		return null
	var cd := CardData.from_dict(token_def)
	cd.id = "TOKEN:" + cd.name
	var ci := spawn_token(pid, cd, str(token_def.get("size", "")), "void" if cores_from_void else "field_or_reserve")
	engine.effects.trigger("on_summon", {"uid": ci.uid, "player": pid})
	return ci


## A token on the field with its LV1 cores (0.15.0). Where the cores come from:
##   "field_or_reserve" -- the token reminder says "from either your field or
##     your reserve": the reserve first, then cores a card of yours does not need
##     for its current level (so nothing levels down or dies);
##   "void" -- "putting a core from the void on each of them" (BSS05-064);
##   "trash_first" -- "a core (not the soul core) from your reserve or trash"
##     (BSS05-111): the trash first, then the reserve, never the soul core.
## Does not fire on_summon (the caller does).
func spawn_token(pid: int, cd: CardData, size: String = "", from: String = "field_or_reserve",
		no_soul: bool = false) -> CardInstance:
	var ci := state.spawn_card(cd, pid, BSS.Zone.FIELD)
	ci.flags["is_token"] = true
	if size != "":
		ci.flags["token_size"] = size
	var need := cd.min_level_cost()
	var dest := GameState.on_card(ci.uid)
	match from:
		"void":
			need -= state.move_cores(GameState.pool(pid, BSS.Zone.VOID), dest, need)
		"trash_first":
			need -= state.move_cores(GameState.pool(pid, BSS.Zone.TRASH), dest, need, false, not no_soul)
			need -= state.move_cores(GameState.pool(pid, BSS.Zone.RESERVE), dest, need, false, not no_soul)
		_:
			need -= state.move_cores(GameState.pool(pid, BSS.Zone.RESERVE), dest, need, false, true)
			for uid in state.player(pid).field:
				if need <= 0:
					break
				var c: CardInstance = state.cards[uid]
				if c.uid == ci.uid:
					continue
				var spare := c.cores - engine._level_floor(c)
				if spare > 0:
					need -= state.move_cores(GameState.on_card(c.uid), dest, mini(spare, need))
	state.log_event("token_summoned", {"uid": ci.uid, "name": cd.name})
	return ci


# --- 10-9 Bursts -----------------------------------------------------------
## A burst is a triggered effect sitting face down. 10-9-3 makes activation
## optional, so the engine offers rather than forces.
func offer_bursts(pid: int, event: String = "life_decreased") -> void:
	# 0.11.0: a burst is offered only when ITS condition happens. Before, every
	# set burst was offered at every flash window whatever it said (I-010).
	var uid := state.player(pid).burst
	if uid < 0 or state.game_over:
		return
	if not state.pending_choice.is_empty():
		# 0.16.7 (R-086): another prompt is open (the opponent's own burst in
		# a tie, a "may" of a When Destroyed effect, Immortal...). Before,
		# the burst was simply not offered. Now it waits and is offered when
		# the prompt is answered -- once per event: the same player's open
		# burst offer for the same event already covers it.
		var pc := state.pending_choice
		if bool(pc.get("burst_offer", false)) and int(pc.get("player", -1)) == pid \
				and str(pc.get("burst_event", "")) == event:
			return
		for q: Dictionary in state.pending_bursts:
			if int(q["player"]) == pid and str(q["event"]) == event:
				return
		state.pending_bursts.append({"player": pid, "event": event})
		return
	var ci: CardInstance = state.cards[uid]
	for spec in ci.data.effects:
		if str(spec.get("timing", "")) != "burst":
			continue
		if not _burst_condition_met(pid, spec, event):
			continue
		state.pending_choice = {
			"type": "option", "player": pid,
			"prompt": "Activate your burst %s?" % ci.data.name,
			"labels": ["Activate", "Keep set"],
			"keyword_prompt": true,
			"burst_offer": true, "burst_event": event,
			"branches": [
				{"directives": [{"op": "script", "name": "activate_burst", "args": {"uid": uid}}]},
				{"directives": []},
			],
		}
		return


## Offer the bursts that had to wait for another prompt (0.16.7, R-086).
## Called whenever the engine is between prompts.
func flush_pending_bursts() -> void:
	var guard := 0
	while not state.pending_bursts.is_empty() and state.pending_choice.is_empty() and not state.game_over \
			and state.effect_stack.is_empty() and guard < 8:
		guard += 1
		var q: Dictionary = state.pending_bursts.pop_front()
		offer_bursts(int(q["player"]), str(q["event"]))


## Called after life loss, the most common burst condition.
func check_life_bursts(pid: int) -> void:
	offer_bursts(pid, "life_decreased")


## Burst conditions (10-9). Older data names map onto the same three events.
const BURST_EVENTS := {
	"life_decreased": "life_decreased",
	"spirit_destroyed": "spirit_destroyed",
	"opponent_destroys_spirit": "spirit_destroyed",
	"opponent_summons": "opponent_summon_effect",
	"opponent_summon_effect": "opponent_summon_effect",
}


func _burst_condition_met(_pid: int, spec: Dictionary, event: String) -> bool:
	var want := str(BURST_EVENTS.get(str(spec.get("burst_condition", "life_decreased")), ""))
	return want == event


func activate_burst(pid: int, uid: int) -> Dictionary:
	var ci: CardInstance = state.card(uid)
	if ci == null or state.player(pid).burst != uid:
		return {"ok": false, "reason": "no such burst"}
	ci.face_up = true
	for spec in ci.data.effects:
		if str(spec.get("timing", "")) == "burst":
			state.log_event("burst_activated", {"player": pid, "uid": uid})
			# 10-9-2: no cost is paid to activate a burst.
			state.player(pid).burst = -1
			ci.zone = BSS.Zone.TRASH   # limbo until resolution finishes
			state.player(pid).trash.append(uid)
			# The "then pay to use its flash effect" offer waits until the
			# burst effect has finished resolving (EffectSystem._finish_frame).
			# "Use this card's main effect without paying its cost" bursts
			# have no paid follow-up (0.15.0).
			var meta := {"burst": false} if bool(spec.get("no_followup", false)) \
					else {"burst": false, "burst_followup": uid}
			engine.effects.push(ci, spec, pid, meta)
			engine.effects.resolve_top()
			return {"ok": true, "reason": ""}
	return {"ok": false, "reason": "card has no burst effect"}


## "You may then pay this card's cost to activate its flash (or main)
## effect." (0.11.0) Offered after the burst resolves, if the reserve can pay.
func offer_burst_followup(pid: int, ci: CardInstance) -> void:
	if not state.pending_choice.is_empty() or state.game_over:
		return
	var follow: Dictionary = {}
	for spec in ci.data.effects:
		if str(spec.get("timing", "")) == "magic":
			follow = spec
			break
	if follow.is_empty():
		return
	var cost := engine.compute_cost(pid, ci.data)
	if state.player(pid).total_reserve() < cost:
		return
	var dirs: Array = [{"op": "pay_cores", "amount": cost}]
	for d: Dictionary in follow.get("directives", []):
		dirs.append(d)
	state.pending_choice = {
		"type": "option", "player": pid,
		"prompt": "Pay %d to also use: %s" % [cost, str(follow.get("text", "its effect"))],
		"labels": ["Pay %d" % cost, "No"],
		"keyword_prompt": true,
		"source_uid": ci.uid,
		"branches": [{"directives": dirs}, {"directives": []}],
	}
