extends RefCounted
## Hook for 11-4 Immortal: summon the keyword holder out of the trash.
## The normal summoning sequence runs, so the cost is still paid and
## "when summoned" effects still fire.
static func run(engine, pid: int, args: Dictionary, _frame: Dictionary) -> String:
	var ci = engine.state.card(int(args.get("uid", -1)))
	if ci == null or ci.zone != BSS.Zone.TRASH:
		return ""
	# A payment that loses nothing (0.16.6, I-026); none -> no summon.
	var sp: Variant = engine.effects.safe_summon_payment(pid, ci.data)
	if sp == null:
		engine.state.log_event("immortal_unpaid", {"uid": ci.uid})
		return ""
	# at the level the player chose (0.25.0): extra cores from the reserve
	engine.do_summon(pid, ci, {"via": "effect", "payment": sp, "extra_cores": int(args.get("extra", 0))})
	return ""
