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

enum Kind { NONE, ONLINE, BOT, LOCAL_HOTSEAT, REPLAY }

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
## 0.24.0: the match around the games -- best of 1 or 3, rematches.
## series: {"best_of": 1|3, "wins": [a, b], "game": n, "over": bool,
##          "chooser": seat that picks the turn order next, or -1}
## series_changed fires when the other player becomes ready, asks for a
## rematch, or leaves (online), and when a local series moves on.
signal series_changed(info: Dictionary)

## 0.25.0 (R-169): replays. Every finished game is kept (ReplayStore, the
## last ten); start_replay() plays one back on the board, read-only.
signal replay_progress(index: int, total: int)
signal replay_finished
var save_replays := true            # tests turn it off (or point ReplayStore.DIR elsewhere)
var replay_id := ""
var replay_entry: Dictionary = {}
var replay_paused := false
var replay_speed := 1.0
var replay_recording := false       # an MP4 export is running: no pauses, no end dialog wait
var _replay_actions: Array = []
var _replay_index := 0
var _replay_step_once := false
var _anim_speed_before := 1.0

var series: Dictionary = {}
var game_series: Dictionary = {}     # the series as this game began (the opening banner shows it)
var series_info: Dictionary = {}    # online: the lobby's latest word on readiness / rematch
var current_main: Array = []        # the cards played this game (after sideboarding)


func _ready() -> void:
	Net.match_state.connect(_on_net_state)
	Net.match_found.connect(_on_net_found)
	Net.match_ended.connect(_on_net_ended)
	Net.lobby_message.connect(_on_net_message)
	Net.connection_changed.connect(_on_net_connection)
	_export_child.call_deferred()


## The recording copy of the game (0.25.0, ReplayExporter): started with
## --write-movie and "-- --replay-export=<id>", it plays that replay on the
## board, writes its progress for the first copy to show, and quits.
func _export_child() -> void:
	var id := ""
	var sp := 2.0
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--replay-export="):
			id = a.substr(16)
		elif a.begins_with("--replay-speed="):
			sp = float(a.substr(15))
		elif a.begins_with("--replay-dir="):
			ReplayStore.DIR = a.substr(13)
	if id.is_empty():
		return
	GameConfig.persist = false
	GameConfig.gate_open = "off"
	GameConfig.battle_animations = true
	await get_tree().process_frame
	await get_tree().process_frame
	var r := start_replay(id)
	if not bool(r.get("ok", false)):
		Log.error("Replay export: %s" % str(r.get("reason", "")))
		get_tree().quit(2)
		return
	replay_recording = true
	replay_speed = sp
	GameConfig.card_animation_speed = sp
	var progress := ReplayStore.DIR + "/export/%s.progress" % id
	replay_progress.connect(func(i: int, total: int):
		var f := FileAccess.open(progress, FileAccess.WRITE)
		if f != null:
			f.store_string("%d/%d" % [i, total]))
	SceneRouter.go("game")
	await replay_finished
	await get_tree().create_timer(2.0).timeout
	get_tree().quit(0)


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
func start_bot_match(deck: Dictionary, bot_difficulty: int, bot_deck: Dictionary = {}, wait_for_board: bool = false,
		best_of: int = 1) -> Dictionary:
	var res := _start_bot_game(deck, bot_difficulty, bot_deck, wait_for_board, (deck.get("main", deck.get("cards", [])) as Array), -1)
	if bool(res.get("ok", false)):
		series = {"best_of": 3 if best_of >= 3 else 1, "wins": [0, 0], "game": 1, "over": false, "chooser": -1}
		game_series = series.duplicate(true)
		series_info = {}
	return res


## The next game of a best of 3 against the CPU, or a rematch (`fresh`), with
## the deck as sideboarded (`main`). The loser of the last game chooses the
## turn order in a best of 3; a rematch tosses a coin again.
func next_bot_game(main: Array, fresh: bool = false) -> Dictionary:
	var deck := my_deck
	var chooser := -1 if fresh else int(series.get("chooser", -1))
	var res := _start_bot_game(deck, difficulty, _opp_deck, true, main, chooser)
	if not bool(res.get("ok", false)):
		return res
	if fresh:
		series = {"best_of": int(series.get("best_of", 1)), "wins": [0, 0], "game": 1, "over": false, "chooser": -1}
	else:
		series["game"] = int(series.get("game", 1)) + 1
	game_series = series.duplicate(true)
	record_results = true
	return res


func _start_bot_game(deck: Dictionary, bot_difficulty: int, bot_deck: Dictionary, wait_for_board: bool,
		main: Array, chooser: int) -> Dictionary:
	if bot != null:
		bot.queue_free()
		bot = null
	var st := GameState.new(randi())
	engine = RulesEngine.new(st)
	var opp_deck := bot_deck if not bot_deck.is_empty() else deck
	var res := engine.setup([{"name": str(deck.get("name", "Untitled")), "cards": main}, _engine_deck(opp_deck)],
			[GameConfig.player_name, "CPU"], -1, chooser)
	if not res["ok"]:
		return res
	current_main = main.duplicate()
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
	if kind == Kind.REPLAY:
		GameConfig.card_animation_speed = _anim_speed_before     # the replay bar's speed was for the replay
	mirror = false
	_match_token += 1
	_auto_running = false
	record_results = false
	my_deck = {}
	_opp_deck = {}
	difficulty = -1
	series = {}
	series_info = {}
	current_main = []
	if bot != null:
		bot.queue_free()
		bot = null
	engine = null
	kind = Kind.NONE
	snapshot = {}
	is_spectator = false
	replay_id = ""
	_replay_actions = []
	_replay_index = 0
	replay_recording = false


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
	_save_replay("draw" if winner == 2 else ("win" if winner == my_seat else "loss"))
	if kind == Kind.BOT:
		_series_scored(winner)
	ended.emit({"winner": winner, "you": my_seat, "series": series.duplicate(true),
		"result": ("draw" if winner == 2 else ("win" if winner == my_seat else "loss"))})


## Keep the game that just ended for the Replays screen (0.25.0, R-169).
func _save_replay(result: String) -> void:
	if kind == Kind.REPLAY or engine == null or not save_replays or not GameConfig.persist:
		return
	var k := "cpu" if kind == Kind.BOT else ("hotseat" if kind == Kind.LOCAL_HOTSEAT else "local")
	var res := result
	if kind == Kind.LOCAL_HOTSEAT:
		res = "draw" if result == "draw" else "Seat %d won" % (engine.state.winner + 1)
	var meta := {"opponent": opponent_name if kind == Kind.BOT else "Seat 2", "result": res,
			"kind": k, "seat": my_seat, "deck": str(my_deck.get("name", ""))}
	# The game ends inside submit(), before its last action is logged: save
	# once that call has returned.
	var eng := engine
	(func() -> void: ReplayStore.save(eng.replay_record(), meta)).call_deferred()


## Watch a kept game (0.25.0, R-169): the recorded game is rebuilt and its
## actions are applied one at a time, at the board's pace. The board is
## read-only (is_spectator); the replay bar pauses, steps, changes speed.
func start_replay(id: String, record: Dictionary = {}) -> Dictionary:
	var rec := record if not record.is_empty() else ReplayStore.load_record(id)
	if rec.is_empty():
		return {"ok": false, "reason": "That replay could not be read."}
	var eng := ReplayStore.engine_for(rec)
	if eng == null:
		return {"ok": false, "reason": "That replay's decks are no longer valid with these cards."}
	var keep_speed := _anim_speed_before if kind == Kind.REPLAY else GameConfig.card_animation_speed
	end_match()
	_anim_speed_before = keep_speed
	engine = eng
	kind = Kind.REPLAY
	_match_token += 1
	replay_id = id
	replay_entry = ReplayStore.entry(id)
	var seat := int(replay_entry.get("seat", 0))
	my_seat = seat if seat >= 0 else 0
	is_spectator = true
	record_results = false
	_recorded = true
	opponent_name = str(replay_entry.get("opponent", "Opponent"))
	_replay_actions = rec.get("actions", [])
	_replay_index = 0
	replay_paused = false
	_refresh_local()
	_run_replay.call_deferred(_match_token)
	return {"ok": true, "reason": ""}


func replay_total() -> int:
	return _replay_actions.size()


func replay_index() -> int:
	return _replay_index


func replay_step() -> void:
	_replay_step_once = true


## From the start again (keeps speed and pause).
func replay_restart() -> void:
	if kind != Kind.REPLAY:
		return
	var rec := ReplayStore.load_record(replay_id)
	var eng := ReplayStore.engine_for(rec) if not rec.is_empty() else null
	if eng == null:
		return
	_match_token += 1
	engine = eng
	_replay_index = 0
	_refresh_local()
	_run_replay.call_deferred(_match_token)


func _run_replay(token: int) -> void:
	while token == _match_token and kind == Kind.REPLAY and _replay_index < _replay_actions.size():
		var waited := 0
		while _presenter_busy() and waited < 3600:
			waited += 1
			await get_tree().process_frame
			if token != _match_token:
				return
		while replay_paused and not _replay_step_once and not replay_recording:
			await get_tree().process_frame
			if token != _match_token:
				return
		_replay_step_once = false
		await get_tree().create_timer(0.45 / maxf(0.25, replay_speed)).timeout
		if token != _match_token:
			return
		var e: Dictionary = _replay_actions[_replay_index]
		_replay_index += 1
		var r := engine.submit(int(e.get("pid", 0)), ReplayStore.action_of(e))
		if not bool(r.get("ok", false)):
			Log.warn("Replay: action %d was refused (%s)" % [_replay_index, str(r.get("reason", ""))])
		_refresh_local()
		replay_progress.emit(_replay_index, _replay_actions.size())
	if token == _match_token and kind == Kind.REPLAY:
		var waited2 := 0
		while _presenter_busy() and waited2 < 3600:
			waited2 += 1
			await get_tree().process_frame
		replay_finished.emit()


## A game of the series is over (local games; the lobby does this online).
## A draw counts for neither player; the next game is chosen by the loser.
func _series_scored(winner: int) -> void:
	if series.is_empty():
		return
	var wins: Array = series.get("wins", [0, 0])
	if winner == 0 or winner == 1:
		wins[winner] = int(wins[winner]) + 1
		series["chooser"] = 1 - winner
	series["wins"] = wins
	var need := 2 if int(series.get("best_of", 1)) >= 3 else 1
	series["over"] = int(wins[0]) >= need or int(wins[1]) >= need or int(series.get("best_of", 1)) < 3 \
			or int(series.get("game", 1)) >= 5


## True while a best of 3 still has games to play.
func series_continues() -> bool:
	return not series.is_empty() and int(series.get("best_of", 1)) >= 3 and not bool(series.get("over", true))


## The deck as registered for this match (deck + sideboard), for sideboarding.
func match_deck() -> Dictionary:
	return my_deck


## Online (0.24.0): ready for the next game of the best of 3 with `main`.
func ready_next_game(main: Array) -> void:
	if kind == Kind.ONLINE:
		current_main = main.duplicate()
		Net.series_ready(main)


## Online: ask for (or accept) a rematch with `main`; `cancel` withdraws it.
func request_rematch(main: Array, cancel: bool = false) -> void:
	if kind == Kind.ONLINE:
		current_main = main.duplicate()
		Net.rematch(main, cancel)


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
	series = (data.get("series", {}) as Dictionary).duplicate(true)
	game_series = series.duplicate(true)
	series_info = {}
	if current_main.is_empty() or int(series.get("game", 1)) <= 1 and not bool(data.get("rematch", false)):
		current_main = (my_deck.get("main", []) as Array).duplicate()
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
	if data.has("series"):
		series = (data["series"] as Dictionary).duplicate(true)
	_record_result(str(data.get("result", "")))
	# the server sends the whole game once it is over (0.25.0)
	if data.get("replay") is Dictionary and save_replays and GameConfig.persist:
		ReplayStore.save(data["replay"], {"opponent": opponent_name, "result": str(data.get("result", "")),
				"kind": "online", "seat": my_seat, "deck": str(my_deck.get("name", ""))})
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
	elif kind_name == "series" and kind == Kind.ONLINE:
		series_info = data.duplicate(true)
		if data.has("series"):
			series = (data["series"] as Dictionary).duplicate(true)
		series_changed.emit(series_info)


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
