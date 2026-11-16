extends RefCounted
## 0.25.0 (R-166): after one Immortal answer, ask about the next Immortal
## spirit that the same destruction activated.
static func run(engine, _pid: int, _args: Dictionary, _frame: Dictionary) -> String:
	if engine.state.pending_choice.is_empty():
		engine.keywords.offer_next_immortal()
	return ""
