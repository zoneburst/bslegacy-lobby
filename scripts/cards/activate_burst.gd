extends RefCounted
## Hook used by the burst prompt in KeywordEngine.offer_bursts().
static func run(engine, pid: int, args: Dictionary, _frame: Dictionary) -> String:
	engine.keywords.activate_burst(pid, int(args.get("uid", -1)))
	return ""
