extends RefCounted
## Hook for 11-16 Agile: bounce the cheaper spirit, then summon the Agile card
## from hand paying its cost as normal (11-16-1).
static func run(engine, pid: int, args: Dictionary, _frame: Dictionary) -> String:
	var field_ci = engine.state.card(int(args.get("field_uid", -1)))
	var hand_ci = engine.state.card(int(args.get("hand_uid", -1)))
	if field_ci == null or hand_ci == null:
		return ""
	engine.state.move_card(field_ci.uid, BSS.Zone.HAND, field_ci.owner_id)
	engine.do_summon(pid, hand_ci, {})
	return ""
