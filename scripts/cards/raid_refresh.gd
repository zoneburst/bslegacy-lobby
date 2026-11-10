extends RefCounted
## Hook for 11-12 Raid: refresh the attacking spirit after a nexus was exhausted.
## Registered as {"op":"script","name":"raid_refresh","args":{"uid":<attacker>}}.
static func run(engine, _pid: int, args: Dictionary, _frame: Dictionary) -> String:
	var ci = engine.state.card(int(args.get("uid", -1)))
	if ci == null or ci.zone != BSS.Zone.FIELD:
		return ""
	ci.orientation = BSS.Orientation.REFRESHED
	ci.raid_uses_this_turn += 1
	engine.state.log_event("raid_refresh", {"uid": ci.uid})
	return ""
