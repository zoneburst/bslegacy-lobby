extends Node
##
## One interface for "I am in a game", whether that game is online or local.
##
## GameBoard.gd talks to this and nothing else. It calls `act()` and listens to
## `updated`. Whether that action travelled to a server or went straight into a
## local RulesEngine is entirely hidden, which is why the board UI has no
## networking code in it at all and why a bot match and a ranked match render
## through the same scene.
##

enum Kind { NONE, ONLINE, BOT, LOCAL_HOTSEAT }

var kind: int = Kind.NONE
var my_seat: int = 0
var is_spectator: bool = false
var snapshot: Dictionary = {}          # last state received or computed
var engine: RulesEngine = null         # local kinds: the engine; online: the read-only mirror (0.16.8)
var mirror := false                    # true when `engine` is an online mirror (never submitted to)
var desyncs := 0                       # online: mirror checksums that differed from the server's
var _auto_passed_serial := -1          # online: the event serial an empty flash window was auto-passed at
var bot: BotController = null          # non-null only for Kind.BOT
var opponent_name: String = "Opponent"
var last_reject: String = ""

## The board registers itself here while it is on screen. When it is
## presenting (animations playing), the AI waits for it -- see _run_auto().
var presenter: Node = null
var _auto_running := false
var _match_token := 0              # bumps on every start/end, cancels old loops

## Profile recording (0.16.0). False by default, so the test harnesses that
## run bot games through this service never touch the player's profile. The
## screens that start a real game (Battle, Quick Play, online) set it true
## after a successful start; it is cleared the moment a result is recorded
## or the match ends, so each finished match is recorded exactly once.
var record_results := false
var my_deck: Dictionary = {}       # the saved deck the human seat is playing
var _opp_deck: Dictionary = {}     # the other seat's deck when it is known here (bot, hotseat; 0.18.4)
var difficulty: int = -1           # AI difficulty, -1 when there is no AI
var _recorded := false

signal updated(snapshot: Dictionary)
signal ended(data: Dictionary)
signal rejected(reason: String)


func _ready() -> void:
	Net.match_state.connect(_on_net_state)
	Net.match_found.connect(_on_net_found)
	Net.match_ended.connect(_on_net_ended)
	Net.lobby_message.connect(_on_net_message)
	Net.connection_changed.connect(_on_net_connection)


# ---------------------------------------------------------------------------
# Starting a match
# ---------------------------------------------------------------------------

## Local match against the AI. No peer, no server, fully offline.
## Saved decks keep their card list under "main"; the engine's setup() wants
## "cards". Converting here, once, keeps that translation in a single place
## instead of leaving each call site to remember it.
func _engine_deck(d: Dictionary) -> Dictionary:
	return {"name": str(d.get("name", "Untitled")),
			"cards": d.get("cards", d.get("main", []))}


## `wait_for_board` (0.20.0): the CPU makes no decision (turn order,
## mulligan) until the battle screen calls board_ready(), so its choices are
## paced and shown like its other moves. Callers that open the board pass true.
func start_bot_match(deck: Dictionary, bot_difficulty: int, bot_deck: Dictionary = {}, wait_for_board: bool = false) -> Dictionary:
	var st := GameState.new(randi())
	engine = RulesEngine.new(st)
	var opp_deck := bot_deck if not bot_deck.is_empty() else deck
	var res := engine.setup([_engine_deck(deck), _engine_deck(opp_deck)],
			[GameConfig.player_name, "CPU"])
	if not res["ok"]:
		return res
	kind = Kind.BOT
	_match_token += 1
	my_seat = 0
	is_spectator = false
	record_results = false
	_recorded = false
	my_deck = deck
	_opp_deck = opp_deck
	difficulty = bot_difficulty
	opponent_name = "CPU (%s)" % BotController.DIFFICULTY_NAMES[bot_difficulty]
	bot = BotController.new(engine, 1, bot_difficulty)
	add_child(bot)
	engine.game_ended.connect(_on_local_ended)
	_refresh_local()
	if not (wait_for_board and GameConfig.battle_animations):
		_pump_bot()
	return {"ok": true, "reason": ""}


## The battle screen is up and presenting (0.20.0): let a held CPU act.
func board_ready() -> void:
	_pump_bot()


## Local two-players-one-screen match, useful for rules testing and for
## reproducing a bug report without a second machine.
func start_hotseat(deck_a: Dictionary, deck_b: Dictionary) -> Dictionary:
	var st := GameState.new(randi())
	engine = RulesEngine.new(st)
	var res := engine.setup([_engine_deck(deck_a), _engine_deck(deck_b)],
			["Seat 1", "Seat 2"])
	if not res["ok"]:
		return res
	kind = Kind.LOCAL_HOTSEAT
	_match_token += 1
	my_seat = 0
	record_results = false
	_recorded = false
	my_deck = deck_a
	_opp_deck = deck_b
	difficulty = -1
	engine.game_ended.connect(_on_local_ended)
	_refresh_local()
	return {"ok": true, "reason": ""}


func end_match() -> void:
	# Leaving an online game also leaves its room on the server, so finished
	# rooms do not pile up there (0.16.8).
	if kind == Kind.ONLINE and Net.connected:
		Net.leave_room()
	mirror = false
	_match_token += 1
	_auto_running = false
	record_results = false
	my_deck = {}
	_opp_deck = {}
	difficulty = -1
	if bot != null:
		bot.queue_free()
		bot = null
	engine = null
	kind = Kind.NONE
	snapshot = {}
	is_spectator = false


# ---------------------------------------------------------------------------
# Acting
# ---------------------------------------------------------------------------

## The single call the board UI makes. Returns immediately; results arrive via
## the `updated` signal, so the caller never blocks waiting for the network.
func act(action: Dictionary) -> void:
	if is_spectator:
		return
	match kind:
		Kind.ONLINE:
			Net.send_action(action)
		Kind.BOT:
			var res := engine.submit(my_seat, action)
			if not res["ok"]:
				last_reject = res["reason"]
				rejected.emit(res["reason"])
				return
			_refresh_local()
			_pump_bot()
		Kind.LOCAL_HOTSEAT:
			# In hotseat the acting seat is whoever the engine currently expects.
			var seat := _hotseat_seat()
			var r2 := engine.submit(seat, action)
			if not r2["ok"]:
				rejected.emit(r2["reason"])
				return
			_refresh_local()


func _hotseat_seat() -> int:
	var st := engine.state
	if not st.pending_choice.is_empty():
		return int(st.pending_choice.get("player", st.turn_player))
	if st.flash_priority >= 0:
		return st.flash_priority
	if not st.battle.is_empty() and int(st.battle.get("phase", 0)) == BSS.BattlePhase.BLOCK_DECLARATION:
		return int(st.battle["defending_player"])
	return st.turn_player


## Let the bot take every action it is entitled to, then hand control back.
##
## Two modes:
##   * PACED (a board is on screen and battle animations are on): one action
##     at a time. Before each one the loop waits for the board to finish
##     presenting the previous action, then a short "thinking" beat, so every
##     summon, attack and block the AI makes is seen. This is what makes the
##     animations readable at all -- before 0.7.0 the AI played its whole turn
##     inside a single frame (R-029).
##   * INSTANT (tests, animations off): the original synchronous loop.
##
## Both also auto-pass the HUMAN's empty flash windows when the setting
## "Auto-pass empty flash windows" is on. That setting existed since 0.1 but
## nothing read it (R-027).
func _pump_bot() -> void:
	if kind != Kind.BOT or bot == null or engine == null:
		return
	if _paced():
		if not _auto_running:
			_auto_running = true
			_run_auto(_match_token)
		return
	var guard := 0
	while guard < 400 and not engine.state.game_over:
		guard += 1
		if not _auto_step():
			break
	_refresh_local()


func _paced() -> bool:
	return presenter != null and is_instance_valid(presenter) and GameConfig.battle_animations


func _presenter_busy() -> bool:
	return _paced() and presenter.has_method("is_presenting") and bool(presenter.call("is_presenting"))


func _run_auto(token: int) -> void:
	var guard := 0
	while guard < 400:
		guard += 1
		if token != _match_token or engine == null or engine.state.game_over:
			break
		if _next_auto_actor() < 0:
			break
		# Let the board finish showing the last action before the next one.
		var waited := 0
		while _presenter_busy() and waited < 1800:
			waited += 1
			await get_tree().process_frame
			if token != _match_token:
				return
		await get_tree().create_timer(_think_delay()).timeout
		if token != _match_token or engine == null or engine.state.game_over:
			break
		if not _auto_step():
			break
	if token == _match_token:
		_auto_running = false


## Who acts automatically next: 1 for the bot, my_seat for an auto-pass, -1 for
## nobody (the human has a real decision).
func _next_auto_actor() -> int:
	if engine == null or engine.state.game_over:
		return -1
	var seat := _hotseat_seat()
	if seat == 1:
		return 1
	if seat == my_seat and _should_auto_pass(seat):
		return seat
	return -1


## The human's flash window holds nothing but "pass": no flash magic they can
## afford, no Swift spirit, no burst prompt.
func _should_auto_pass(seat: int) -> bool:
	if not GameConfig.auto_pass_empty_flash or not engine._in_flash_window(seat):
		return false
	if not engine.state.pending_choice.is_empty():
		return false
	for a: Dictionary in engine.legal_actions(seat):
		var v := str(a.get("verb", ""))
		if v != BSS.Action.FLASH_PASS and v != BSS.Action.CONCEDE:
			return false
	return true


## One automatic action. Returns false when nothing was done.
func _auto_step() -> bool:
	var actor := _next_auto_actor()
	if actor < 0:
		return false
	if actor == my_seat:
		var r := engine.submit(my_seat, {"verb": BSS.Action.FLASH_PASS})
		_refresh_local()
		return bool(r["ok"])
	var action := bot.choose_action()
	if action == null or action.is_empty():
		return false
	var res := engine.submit(1, action)
	if not res["ok"]:
		# The bot proposed something illegal. Fall back to the safest legal
		# action so a policy bug degrades into a bad move, not a hang.
		var fallback := bot.safe_fallback()
		if fallback.is_empty() or not engine.submit(1, fallback)["ok"]:
			return false
	_refresh_local()
	return true


func _think_delay() -> float:
	return 0.35 / maxf(0.25, GameConfig.card_animation_speed)


func _refresh_local() -> void:
	if engine == null:
		return
	var viewer := my_seat if kind != Kind.LOCAL_HOTSEAT else _hotseat_seat()
	snapshot = engine.state.to_net(viewer)
	snapshot["local"] = true
	BugReporter.capture_game(engine)
	updated.emit(snapshot)


func _on_local_ended(winner: int) -> void:
	_record_result()
	ended.emit({"winner": winner, "you": my_seat,
		"result": ("draw" if winner == 2 else ("win" if winner == my_seat else "loss"))})


## Writes the finished match to the player's profile, once (0.16.0). Local
## kinds read the engine's logs; an online game has only the last snapshot.
## Hotseat records for seat 0 only, flagged as such.
func _record_result(online_result: String = "") -> void:
	if not record_results or _recorded or is_spectator or my_seat < 0:
		return
	_recorded = true
	record_results = false
	match kind:
		Kind.BOT:
			PlayerProfile.record_match(engine.state, my_seat, my_deck, PlayerProfile.MODE_VS_AI,
					difficulty, "")
		Kind.LOCAL_HOTSEAT:
			PlayerProfile.record_match(engine.state, my_seat, my_deck, PlayerProfile.MODE_HOTSEAT,
					-1, "")
		Kind.ONLINE:
			if online_result in ["win", "loss", "draw"]:
				PlayerProfile.record_snapshot(snapshot, my_seat, my_deck, PlayerProfile.MODE_ONLINE,
						online_result, "")


# ---------------------------------------------------------------------------
# Online plumbing
# ---------------------------------------------------------------------------

func _on_net_found(data: Dictionary) -> void:
	kind = Kind.ONLINE
	_match_token += 1
	my_seat = int(data.get("seat", 0))
	is_spectator = my_seat < 0
	opponent_name = str(data.get("opponent", "Opponent"))
	engine = null
	mirror = false
	snapshot = {}                 # never show the previous game's board
	desyncs = 0
	Replica.defs = {}             # card definitions come fresh from this match's server
	_auto_passed_serial = -1
	_online_over = false
	bot = null
	# An online game is always a real one: record it for the player's profile
	# with the deck the Battle screen sent to the lobby (0.16.0).
	_recorded = false
	record_results = not is_spectator and not my_deck.is_empty()
	difficulty = -1
	SceneRouter.go("game", {"mode": "online"})


## Every server update rebuilds the mirror engine from its replica (0.16.8):
## the board then reads legal actions, costs and events from it exactly as in
## a local game. Actions still go to the server (act()).
func _on_net_state(snap: Dictionary) -> void:
	if kind != Kind.ONLINE:
		return
	var rep: Dictionary = snap.get("replica", {})
	var s2: Dictionary = snap.duplicate()
	s2.erase("replica")
	if not rep.is_empty():
		var prior: Array = engine.state.event_log if (engine != null and mirror) else []
		engine = RulesEngine.new(Replica.decode(rep, prior))
		mirror = true
		if engine.state.checksum() != int(rep.get("checksum", 0)):
			desyncs += 1
			Log.warn("MatchService: online mirror differs from the server (checksum), update %d" % desyncs)
	snapshot = s2
	updated.emit(s2)
	_online_auto_pass()


## "Auto-pass empty flash windows" online too (0.16.8): when the mirror says
## the only thing this player can do is pass, pass -- once per state.
func _online_auto_pass() -> void:
	if engine == null or not mirror or is_spectator or engine.state.game_over:
		return
	var serial := engine.state.event_serial
	if serial == _auto_passed_serial:
		return
	if _should_auto_pass(my_seat) and _hotseat_seat() == my_seat:
		_auto_passed_serial = serial
		Net.send_action({"verb": BSS.Action.FLASH_PASS})


var _online_over := false


func _on_net_ended(data: Dictionary) -> void:
	if kind != Kind.ONLINE or _online_over:
		return
	_online_over = true
	_record_result(str(data.get("result", "")))
	ended.emit(data)


## The connection dropped during an online game: end it on this side, so the
## board shows the end of the game rather than waiting forever (0.16.8).
func _on_net_connection(up: bool) -> void:
	if up or kind != Kind.ONLINE or _online_over or snapshot.is_empty():
		return
	_online_over = true
	record_results = false
	ended.emit({"winner": -1, "you": my_seat, "result": "disconnected",
			"reason": "The connection to the server was lost."})


func _on_net_message(kind_name: String, data: Dictionary) -> void:
	if kind_name == "reject":
		last_reject = str(data.get("reason", ""))
		rejected.emit(last_reject)


# ---------------------------------------------------------------------------
# Convenience for the UI
# ---------------------------------------------------------------------------

func legal_actions() -> Array:
	if engine != null and not is_spectator:
		return engine.legal_actions(my_seat)     # online: the mirror's, which the server also checks
	return []


func my_state() -> Dictionary:
	var players: Array = snapshot.get("players", [])
	return players[my_seat] if my_seat >= 0 and my_seat < players.size() else {}


func opponent_state() -> Dictionary:
	var players: Array = snapshot.get("players", [])
	var idx := 1 - my_seat if my_seat >= 0 else 1
	return players[idx] if idx < players.size() else {}


## The opponent's deck as far as this side knows it (0.18.4): the bot's or the
## hotseat deck locally; online, the cards of theirs in the snapshot.
func opponent_deck() -> Dictionary:
	if not _opp_deck.is_empty():
		return _opp_deck
	var ids: Array = []
	var them: Dictionary = opponent_state()
	for zone in ["field", "trash", "burst", "hand", "deck_top"]:
		for c in them.get(zone, []):
			if c is Dictionary and str((c as Dictionary).get("id", "")) != "":
				ids.append(str((c as Dictionary).get("id", "")))
	return {"main": ids}
