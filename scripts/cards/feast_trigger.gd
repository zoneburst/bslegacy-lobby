extends RefCounted
## Hook for 11-17 Feast. Kept as a script rather than a DSL op because the
## escalation rule inspects the board for existing Supsprite tokens.
static func run(engine, pid: int, _args: Dictionary, _frame: Dictionary) -> String:
	engine.keywords.feast(pid)
	return ""
