extends Node
class_name LobbyServer
##
## The authoritative server: matchmaking, rooms, and one RulesEngine per match.
##
## Runs only inside a headless instance started with `--server`. It holds no
## persistent state -- no accounts, no database -- because a card lobby that
## can be restarted at will is far easier to operate than one that cannot.
## Decks arrive from the client with the join request and are validated here;
## the client's copy is treated as a suggestion, never as truth.
##
## Room codes are six characters from an alphabet with the visually ambiguous
## glyphs removed, so a code read aloud over voice chat does not become a
## support ticket.
##

const CODE_ALPHABET := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
const CODE_LENGTH := 6
const MAX_ROOMS := 500
const IDLE_ROOM_TIMEOUT := 1800.0     # seconds before an empty room is reaped
const MISS_LIMIT := 8                 # wrong room codes allowed per peer per MISS_WINDOW (I-006)
const MISS_WINDOW := 60.0
const MISS_LOCKOUT := 60.0
const BETWEEN_SECONDS := 150.0         # 0.24.0: sideboarding time between best-of-3 games

class Client:
	var peer_id: int
	var name: String = "Player"
	var version: String = ""
	var room_code: String = ""
	var role: String = ""             # "player" or "spectator"
	var seat: int = -1                # 0 or 1 within the match
	var deck: Dictionary = {}         # what this player plays in the current game
	var orig_deck: Dictionary = {}    # 0.24.0: the deck as registered, with its sideboard
	var best_of: int = 1              # 0.24.0: the format this player queued for
	var misses: Array = []            # times of wrong room codes (0.17.0, I-006)
	var locked_until := 0.0

class Room:
	var code: String
	var owner_peer: int
	var players: Array[int] = []      # peer ids, index == seat
	var spectators: Array[int] = []
	var public: bool = false
	var allow_spectators: bool = true
	var engine: RulesEngine = null
	var sent_serial: Dictionary = {}  # peer -> last event serial sent in a replica (0.16.8)
	var sent_defs: Dictionary = {}    # peer -> {card id: true}: card definitions already sent
	var created: float = 0.0
	var last_activity: float = 0.0
	var chat: Array = []
	# 0.24.0: the match around the games
	var best_of: int = 1
	var wins: Array = [0, 0]          # games won, by seat
	var game_no: int = 0
	var phase: String = "waiting"     # waiting, playing, between (best of 3), over
	var chooser: int = -1             # seat that picks the turn order next game
	var ready: Dictionary = {}        # peer -> true: sideboarded and ready for the next game
	var rematch: Dictionary = {}      # peer -> true: asked for a rematch
	var deadline: float = 0.0         # between games: when the next game starts anyway

var clients: Dictionary = {}          # peer_id -> Client
var rooms: Dictionary = {}            # code -> Room
var random_queue: Array[int] = []     # peer ids waiting for a random match

var _rng := RandomNumberGenerator.new()
var _reap_accum := 0.0


func _ready() -> void:
	_rng.randomize()
	multiplayer.peer_disconnected.connect(_on_peer_left)
	Log.info("LobbyServer: ready")


func _process(delta: float) -> void:
	_check_deadlines()
	_reap_accum += delta
	if _reap_accum < 30.0:
		return
	_reap_accum = 0.0
	_reap_idle_rooms()


## Between best-of-3 games (0.24.0): when the sideboarding time is up, a
## player who has not pressed Ready plays the deck they last played.
func _check_deadlines() -> void:
	var now := Time.get_unix_time_from_system()
	for code: String in rooms.keys():
		var room: Room = rooms[code]
		if room.phase == "between" and room.deadline > 0.0 and now >= room.deadline and room.players.size() == 2:
			Log.info("LobbyServer: room %s sideboarding time is up" % code)
			_start_match(room, room.chooser)


# ---------------------------------------------------------------------------
# Client bookkeeping
# ---------------------------------------------------------------------------

func register(peer_id: int, display_name: String, version: String) -> void:
	# Both ends must run the same rules (0.16.8): the client's board reads a
	# mirror of the server's engine, so a different version would offer
	# actions the server does not allow, or miss ones it does.
	var mine := str(ProjectSettings.get_setting("application/config/version", "0.0.0"))
	if version != mine:
		Net.push(peer_id, "lobby", {"status": "Version mismatch: the server runs %s and you run %s. Use the same version on both." % [mine, version],
				"error": true, "version_mismatch": true})
		Log.info("LobbyServer: refused peer %d (v%s, server v%s)" % [peer_id, version, mine])
		return
	var c := Client.new()
	c.peer_id = peer_id
	c.name = display_name.substr(0, 24) if not display_name.is_empty() else "Player"
	c.version = version
	clients[peer_id] = c
	Net.push(peer_id, "lobby", {"status": "Registered", "server_time": Time.get_unix_time_from_system()})
	Log.info("LobbyServer: %s joined (peer %d, v%s)" % [c.name, peer_id, version])


# ---------------------------------------------------------------------------
# Bug reports (0.23.0)
# ---------------------------------------------------------------------------
#
# A player's "Submit report" reaches here over the lobby connection (the web
# version has no other way out). The server keeps a copy in its own
# user://reports (lost when a free host restarts) and, when the environment
# variable BSL_DISCORD_WEBHOOK holds a Discord webhook address, posts it to
# that channel: a one-line summary and the full report as a .json file. The
# webhook address stays on the server; players never see it.

const REPORT_LIMIT := 4                 # reports per peer per REPORT_WINDOW
const REPORT_WINDOW := 600.0
var _report_times: Dictionary = {}      # peer id -> [unix times]


func bug_report(peer_id: int, text: String) -> void:
	var now := Time.get_unix_time_from_system()
	var times: Array = (_report_times.get(peer_id, []) as Array).filter(func(t: float) -> bool: return now - t < REPORT_WINDOW)
	if times.size() >= REPORT_LIMIT:
		Net.push(peer_id, "report", {"ok": false, "message": "too many reports in a short time; try again in a few minutes"})
		return
	times.append(now)
	_report_times[peer_id] = times
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		Net.push(peer_id, "report", {"ok": false, "message": "the report could not be read"})
		return
	var rep: Dictionary = parsed
	DirAccess.make_dir_recursive_absolute("user://reports")
	var fname := "server_%d_%d.json" % [int(now), peer_id]
	var f := FileAccess.open("user://reports".path_join(fname), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(rep, "  "))
		f.close()
	var line := "Bug report v%s [%s] %s -- %s (%s)" % [str(rep.get("version", "?")), str(rep.get("category", "?")),
		str(rep.get("summary", "")).substr(0, 200), str(rep.get("player", "?")).substr(0, 24), str(rep.get("platform", "?"))]
	Log.info("LobbyServer: " + line)
	var hook := OS.get_environment("BSL_DISCORD_WEBHOOK").strip_edges()
	if hook.is_empty():
		Net.push(peer_id, "report", {"ok": true, "message": "received by the lobby"})
		return
	_post_discord(hook, line, fname, JSON.stringify(rep, "  "), peer_id)


func _post_discord(hook: String, line: String, fname: String, body_json: String, peer_id: int) -> void:
	var boundary := "----bsl%d" % randi()
	var payload := JSON.stringify({"content": line.substr(0, 1900), "allowed_mentions": {"parse": []}})
	var body := PackedByteArray()
	body.append_array(("--%s\r\nContent-Disposition: form-data; name=\"payload_json\"\r\nContent-Type: application/json\r\n\r\n%s\r\n" % [boundary, payload]).to_utf8_buffer())
	body.append_array(("--%s\r\nContent-Disposition: form-data; name=\"files[0]\"; filename=\"%s\"\r\nContent-Type: application/json\r\n\r\n" % [boundary, fname]).to_utf8_buffer())
	body.append_array(body_json.to_utf8_buffer())
	body.append_array(("\r\n--%s--\r\n" % boundary).to_utf8_buffer())
	var http := HTTPRequest.new()
	http.timeout = 20.0
	add_child(http)
	http.request_completed.connect(func(result: int, code: int, _h: PackedStringArray, _b: PackedByteArray) -> void:
		var ok := result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300
		Log.info("LobbyServer: report forwarded to Discord: %s (HTTP %d)" % ["ok" if ok else "FAILED", code])
		Net.push(peer_id, "report", {"ok": true, "message": "sent to the team" if ok else "received by the lobby"})
		http.queue_free())
	var err := http.request_raw(hook, ["Content-Type: multipart/form-data; boundary=" + boundary],
		HTTPClient.METHOD_POST, body)
	if err != OK:
		http.queue_free()
		Net.push(peer_id, "report", {"ok": true, "message": "received by the lobby"})


func _on_peer_left(peer_id: int) -> void:
	random_queue.erase(peer_id)
	leave(peer_id)
	clients.erase(peer_id)


# ---------------------------------------------------------------------------
# Random matchmaking
# ---------------------------------------------------------------------------

## Only the card list and the name of a deck the client sends are used.
static func clean_deck(deck: Dictionary) -> Dictionary:
	var ids: Array = []
	for x: Variant in deck.get("main", deck.get("cards", [])):
		ids.append(str(x))
		if ids.size() > 200:
			break
	var side: Array = []
	for y: Variant in deck.get("side", []):
		side.append(str(y))
		if side.size() > 40:
			break
	return {"name": str(deck.get("name", "Deck")).substr(0, 40), "main": ids, "side": side}


## The deck and its sideboard are both legal (0.24.0).
static func check_deck(deck: Dictionary) -> Dictionary:
	var chk := RulesEngine.validate_deck(deck.get("main", []))
	if not bool(chk.get("ok", false)):
		return chk
	return DeckManager.validate_side(deck)


## What a client is told about the match (0.24.0).
static func series_of(room: Room) -> Dictionary:
	var need := 2 if room.best_of >= 3 else 1
	return {"best_of": room.best_of, "wins": room.wins.duplicate(), "game": room.game_no,
		"over": room.phase == "over" or int(room.wins[0]) >= need or int(room.wins[1]) >= need,
		"chooser": room.chooser}


## The deck list in a random order (0.16.8). Card uids are handed out in list
## order when the deck is dealt; without this, a hidden card's uid would tell
## a player which card of the opponent's list it is.
static func shuffled_deck(deck: Dictionary, shuffle_seed: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = shuffle_seed
	var ids: Array = (deck.get("main", deck.get("cards", [])) as Array).duplicate()
	for i in range(ids.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t: Variant = ids[i]
		ids[i] = ids[j]
		ids[j] = t
	return {"name": str(deck.get("name", "Deck")), "main": ids}


## Pairs the two longest-waiting players. Deliberately not skill-based: with a
## small population a rating queue mostly produces long waits. If a rating
## system is added later this is the only function that has to change.
func queue_random(peer_id: int, deck: Dictionary, opts: Dictionary = {}) -> void:
	var c: Client = clients.get(peer_id)
	if c == null:
		return
	deck = clean_deck(deck)
	var chk := check_deck(deck)
	if not chk["ok"]:
		Net.push(peer_id, "lobby", {"status": "Deck rejected: %s" % chk["reason"], "error": true})
		return
	c.orig_deck = deck
	c.deck = deck
	c.best_of = 3 if int(opts.get("best_of", 1)) >= 3 else 1
	leave(peer_id)                     # a player in an old room leaves it first
	if not random_queue.has(peer_id):
		random_queue.append(peer_id)
	Net.push(peer_id, "lobby", {"status": "Searching for an opponent...", "queued": random_queue.size()})
	_try_pair()


func cancel_queue(peer_id: int) -> void:
	random_queue.erase(peer_id)
	Net.push(peer_id, "lobby", {"status": "Search cancelled"})


## Pairs the two longest-waiting players who asked for the same format
## (best of 1 or best of 3, 0.24.0).
func _try_pair() -> void:
	random_queue = random_queue.filter(func(p: int) -> bool: return clients.has(p))
	var i := 0
	while i < random_queue.size():
		var a: int = random_queue[i]
		var fmt: int = (clients[a] as Client).best_of
		var j := i + 1
		while j < random_queue.size() and (clients[random_queue[j]] as Client).best_of != fmt:
			j += 1
		if j >= random_queue.size():
			i += 1
			continue
		var b: int = random_queue[j]
		random_queue.remove_at(j)
		random_queue.remove_at(i)
		var room := _make_room(a, false)
		room.public = false
		room.best_of = fmt
		_seat_player(room, b)
		_new_series(room)
		_start_match(room)


# ---------------------------------------------------------------------------
# Rooms
# ---------------------------------------------------------------------------

func create_room(peer_id: int, deck: Dictionary, opts: Dictionary) -> void:
	var c: Client = clients.get(peer_id)
	if c == null:
		return
	if rooms.size() >= MAX_ROOMS:
		Net.push(peer_id, "lobby", {"status": "Server is full, try again shortly", "error": true})
		return
	deck = clean_deck(deck)
	var chk := check_deck(deck)
	if not chk["ok"]:
		Net.push(peer_id, "lobby", {"status": "Deck rejected: %s" % chk["reason"], "error": true})
		return
	c.orig_deck = deck
	c.deck = deck
	leave(peer_id)
	var room := _make_room(peer_id, true)
	room.public = bool(opts.get("public", false))
	room.allow_spectators = bool(opts.get("allow_spectators", true))
	room.best_of = 3 if int(opts.get("best_of", 1)) >= 3 else 1
	_broadcast_room(room)


func _make_room(host_peer: int, _keep_open: bool) -> Room:
	var room := Room.new()
	room.code = _unique_code()
	room.owner_peer = host_peer
	room.created = Time.get_unix_time_from_system()
	room.last_activity = room.created
	rooms[room.code] = room
	_seat_player(room, host_peer)
	Log.info("LobbyServer: room %s created" % room.code)
	return room


func _unique_code() -> String:
	for attempt in 64:
		var s := ""
		for i in CODE_LENGTH:
			s += CODE_ALPHABET[_rng.randi_range(0, CODE_ALPHABET.length() - 1)]
		if not rooms.has(s):
			return s
	return "R%05d" % (_rng.randi() % 100000)


func _seat_player(room: Room, peer_id: int) -> void:
	var c: Client = clients.get(peer_id)
	if c == null or room.players.size() >= 2:
		return
	c.room_code = room.code
	c.role = "player"
	c.seat = room.players.size()
	room.players.append(peer_id)
	room.last_activity = Time.get_unix_time_from_system()


## Wrong room codes are limited per player (0.17.0, was I-006): on a public
## lobby, guessing codes in a loop could otherwise find someone's room.
## Returns true when this peer may try a code now.
func _may_try_code(peer_id: int) -> bool:
	var c: Client = clients.get(peer_id)
	if c == null:
		return false
	var now := Time.get_unix_time_from_system()
	if now < c.locked_until:
		Net.push(peer_id, "lobby", {"status": "Too many wrong room codes. Wait %d seconds and check the code." % int(ceil(c.locked_until - now)),
				"error": true})
		return false
	return true


func _note_miss(peer_id: int, code: String) -> void:
	var c: Client = clients.get(peer_id)
	if c == null:
		return
	var now := Time.get_unix_time_from_system()
	c.misses = c.misses.filter(func(t: float) -> bool: return now - t < MISS_WINDOW)
	c.misses.append(now)
	if c.misses.size() >= MISS_LIMIT:
		c.locked_until = now + MISS_LOCKOUT
		c.misses = []
		Log.info("LobbyServer: peer %d locked out for %d s after %d wrong codes" % [peer_id, int(MISS_LOCKOUT), MISS_LIMIT])
	Net.push(peer_id, "lobby", {"status": "No room with code %s" % code, "error": true})


func join_room(peer_id: int, code: String, deck: Dictionary) -> void:
	if not _may_try_code(peer_id):
		return
	var room: Room = rooms.get(code)
	if room == null:
		_note_miss(peer_id, code)
		return
	if room.players.size() >= 2:
		# 3-1-1 has nothing to say about spectators; the product decision is to
		# offer spectating rather than a bare rejection.
		if room.allow_spectators:
			spectate_room(peer_id, code)
		else:
			Net.push(peer_id, "lobby", {"status": "Room %s is full" % code, "error": true})
		return
	var c: Client = clients.get(peer_id)
	if c == null: return
	if room.players.has(peer_id):
		return                         # already seated here
	deck = clean_deck(deck)
	var chk := check_deck(deck)
	if not chk["ok"]:
		Net.push(peer_id, "lobby", {"status": "Deck rejected: %s" % chk["reason"], "error": true})
		return
	c.orig_deck = deck
	c.deck = deck
	leave(peer_id)
	_seat_player(room, peer_id)
	_broadcast_room(room)
	if room.players.size() == 2:
		_new_series(room)
		_start_match(room)


func spectate_room(peer_id: int, code: String) -> void:
	if not _may_try_code(peer_id):
		return
	var room: Room = rooms.get(code)
	if room == null:
		_note_miss(peer_id, code)
		return
	if not room.allow_spectators:
		Net.push(peer_id, "lobby", {"status": "This room has spectating disabled", "error": true})
		return
	var c: Client = clients.get(peer_id)
	if c == null: return
	if c.room_code != code:
		leave(peer_id)
	c.room_code = code
	c.role = "spectator"
	c.seat = -1
	if not room.spectators.has(peer_id):
		room.spectators.append(peer_id)
	_broadcast_room(room)
	if room.engine != null:
		# A spectator joining mid-game gets the current board immediately, with
		# both hands hidden (3-1-3), rather than waiting for the next action.
		Net.push(peer_id, "match_found", {"code": room.code, "seat": -1})
		room.sent_serial.erase(peer_id)
		room.sent_defs.erase(peer_id)
		_push_state(room, peer_id, -1)


func leave(peer_id: int) -> void:
	var c: Client = clients.get(peer_id)
	if c == null or c.room_code.is_empty():
		return
	var room: Room = rooms.get(c.room_code)
	c.room_code = ""
	if room == null:
		return
	room.spectators.erase(peer_id)
	room.sent_serial.erase(peer_id)
	room.sent_defs.erase(peer_id)
	if room.players.has(peer_id):
		# 1-2-4: leaving mid-game is a concession. Conceded while the player is
		# still seated, so every remaining player keeps their own seat's view
		# (before 0.16.8 the list shifted first, and the player left behind
		# could be sent the leaver's view, hand included).
		if room.engine != null and not room.engine.state.game_over:
			room.engine.submit(c.seat, {"verb": BSS.Action.CONCEDE})
			_broadcast_state(room, peer_id)
			_finish_match(room, "opponent disconnected", peer_id)
		elif room.phase == "between" or room.phase == "over":
			# 0.24.0: no next game and no rematch without them
			room.phase = "over"
			for other: int in room.players:
				if other != peer_id:
					Net.push(other, "series", {"opponent_left": true, "series": series_of(room)})
		room.players.erase(peer_id)
		room.ready.erase(peer_id)
		room.rematch.erase(peer_id)
	if room.players.is_empty() and room.spectators.is_empty():
		rooms.erase(room.code)
		Log.info("LobbyServer: room %s closed" % room.code)
	else:
		_broadcast_room(room)


func _reap_idle_rooms() -> void:
	var now := Time.get_unix_time_from_system()
	for code in rooms.keys():
		var room: Room = rooms[code]
		if (room.players.is_empty() or room.engine == null) and now - room.last_activity > IDLE_ROOM_TIMEOUT:
			rooms.erase(code)


func chat(peer_id: int, text: String) -> void:
	var c: Client = clients.get(peer_id)
	if c == null or c.room_code.is_empty():
		return
	var room: Room = rooms.get(c.room_code)
	if room == null: return
	var entry := {"from": c.name, "text": text, "t": Time.get_unix_time_from_system()}
	room.chat.append(entry)
	if room.chat.size() > 200:
		room.chat = room.chat.slice(100)
	for p in room.players + room.spectators:
		Net.push(p, "chat", entry)


# ---------------------------------------------------------------------------
# Match lifecycle
# ---------------------------------------------------------------------------

## A fresh match for two seated players: no games won yet (0.24.0).
func _new_series(room: Room) -> void:
	room.wins = [0, 0]
	room.game_no = 0
	room.chooser = -1
	room.ready = {}
	room.rematch = {}
	room.deadline = 0.0
	for pid in room.players:
		var c: Client = clients.get(pid)
		if c != null and not c.orig_deck.is_empty():
			c.deck = c.orig_deck


## Starts the next game in the room. `chooser` (0.24.0): the seat that lost
## the last game of a best of 3 and picks the turn order; -1 tosses a coin.
func _start_match(room: Room, chooser: int = -1, is_rematch: bool = false) -> void:
	# Not `seed`: that is a global function, and shadowing it is a warning.
	var match_seed := _rng.randi()
	var st := GameState.new(match_seed)
	room.engine = RulesEngine.new(st)
	var decks: Array = []
	var names: Array = []
	for pid in room.players:
		var c: Client = clients[pid]
		decks.append(shuffled_deck(c.deck, _rng.randi()))
		names.append(c.name)
	var res := room.engine.setup(decks, names, -1, chooser)
	if not res["ok"]:
		for p in room.players:
			Net.push(p, "lobby", {"status": res["reason"], "error": true})
		room.engine = null
		return
	# The end of a game is handled after each action (handle_action), not on
	# game_ended: that signal fires inside submit(), and finishing there left
	# the room without an engine before the final state was sent (0.16.8).
	room.sent_serial = {}
	room.sent_defs = {}
	room.game_no += 1
	room.phase = "playing"
	room.ready = {}
	room.rematch = {}
	room.deadline = 0.0
	room.chooser = chooser
	var info := series_of(room)
	for i in room.players.size():
		var ci: Client = clients[room.players[i]]
		ci.seat = i
		# (Before 0.16.8 this also sent "seed": the global function `seed`, not
		# the match seed -- it arrived as null. Nothing used it; it is gone, as
		# the seed would only help a client predict the shuffles.)
		Net.push(room.players[i], "match_found", {
			"code": room.code, "seat": i, "opponent": names[1 - i], "series": info, "rematch": is_rematch,
		})
	for s in room.spectators:
		Net.push(s, "match_found", {"code": room.code, "seat": -1, "series": info})
	_broadcast_state(room)
	Log.info("LobbyServer: match started in room %s" % room.code)


## The choke point for every player action in an online game.
##
## Three checks, in order: is this peer in a match, is it holding the seat it
## claims, and does the engine accept the action. A client that sends garbage
## gets a rejection message and nothing else happens, so a hacked client can
## only ever fail to act -- never act illegally.
func handle_action(peer_id: int, action: Dictionary) -> void:
	var c: Client = clients.get(peer_id)
	if c == null or c.room_code.is_empty() or c.role != "player":
		return
	var room: Room = rooms.get(c.room_code)
	if room == null or room.engine == null:
		return
	room.last_activity = Time.get_unix_time_from_system()
	var res := room.engine.submit(c.seat, action)
	if not res["ok"]:
		Net.push(peer_id, "reject", {"reason": res["reason"], "action": action})
		return
	_broadcast_state(room)
	if room.engine.state.game_over:
		var conceded: bool = str(action.get("verb", "")) == BSS.Action.CONCEDE
		_finish_match(room, "concession" if conceded else "victory")


## Each recipient receives their own redaction of the state (3-1-3). This is
## the only place a hidden zone could leak, which is why the redaction lives in
## GameState.to_net() rather than being reimplemented per message.
##
## Since 0.16.8 each state also carries a replica (scripts/net/Replica.gd): the
## recipient's redacted copy of the whole game, with the events they have not
## been sent yet, which the client's board reads like a local engine.
func _broadcast_state(room: Room, except_peer: int = -1) -> void:
	if room.engine == null:
		return
	for p in room.players:
		if p != except_peer:
			_push_state(room, p, (clients[p] as Client).seat if clients.has(p) else -1)
	for s in room.spectators:
		if s != except_peer:
			_push_state(room, s, -1)


func _push_state(room: Room, peer_id: int, viewer: int) -> void:
	var st := room.engine.state
	var snap := st.to_net(viewer)
	if not room.sent_defs.has(peer_id):
		room.sent_defs[peer_id] = {}
	snap["replica"] = Replica.encode(st, viewer, int(room.sent_serial.get(peer_id, -1)), room.sent_defs[peer_id])
	room.sent_serial[peer_id] = st.event_serial - 1
	Net.push(peer_id, "state", snap)


func _broadcast_room(room: Room) -> void:
	var members: Array = []
	for p in room.players:
		var c: Client = clients.get(p)
		members.append({"name": c.name if c else "?", "role": "player"})
	for s in room.spectators:
		var c2: Client = clients.get(s)
		members.append({"name": c2.name if c2 else "?", "role": "spectator"})
	var payload := {
		"code": room.code, "members": members,
		"allow_spectators": room.allow_spectators,
		"in_progress": room.engine != null,
		"best_of": room.best_of,
	}
	for p in room.players + room.spectators:
		Net.push(p, "room", payload)


func _finish_match(room: Room, reason: String, except_peer: int = -1) -> void:
	if room.engine == null:
		return
	var winner := room.engine.state.winner
	# 0.24.0: the score of the match; the loser picks the order next game
	if winner == 0 or winner == 1:
		room.wins[winner] = int(room.wins[winner]) + 1
		room.chooser = 1 - winner
	var need := 2 if room.best_of >= 3 else 1
	var decided := int(room.wins[0]) >= need or int(room.wins[1]) >= need or room.game_no >= 5
	if reason == "opponent disconnected" or decided or room.best_of < 3:
		room.phase = "over"
		room.deadline = 0.0
	else:
		room.phase = "between"
		room.deadline = Time.get_unix_time_from_system() + BETWEEN_SECONDS
	var info := series_of(room)
	for p in room.players:
		if p == except_peer or not clients.has(p):
			continue
		var seat: int = (clients[p] as Client).seat
		Net.push(p, "ended", {
			"winner": winner, "you": seat, "reason": reason, "series": info,
			"between_seconds": BETWEEN_SECONDS if room.phase == "between" else 0.0,
			"result": ("draw" if winner == 2 else ("win" if winner == seat else "loss")),
		})
	for s in room.spectators:
		Net.push(s, "ended", {"winner": winner, "reason": reason, "result": "spectated", "series": info})
	room.engine = null
	room.last_activity = Time.get_unix_time_from_system()


# ---------------------------------------------------------------------------
# Between games: sideboarding and rematches (0.24.0)
# ---------------------------------------------------------------------------

## The deck a player sends between games must be made of their registered
## deck and sideboard only, and be legal.
func _sideboarded(c: Client, main: Array) -> Dictionary:
	var ids: Array = []
	for x: Variant in main:
		ids.append(str(x))
		if ids.size() > 200:
			break
	var chk := DeckManager.check_sideboarded(c.orig_deck, ids)
	if not bool(chk.get("ok", false)):
		return chk
	return {"ok": true, "deck": {"name": str(c.orig_deck.get("name", "Deck")), "main": ids}}


func series_ready(peer_id: int, main: Array) -> void:
	var c: Client = clients.get(peer_id)
	if c == null or c.room_code.is_empty() or c.role != "player":
		return
	var room: Room = rooms.get(c.room_code)
	if room == null or room.phase != "between":
		return
	var res := _sideboarded(c, main)
	if not bool(res.get("ok", false)):
		Net.push(peer_id, "lobby", {"status": "Deck not accepted: %s" % str(res.get("reason", "")), "error": true})
		return
	c.deck = res["deck"]
	room.ready[peer_id] = true
	room.last_activity = Time.get_unix_time_from_system()
	_push_series(room)
	if room.players.size() == 2 and room.ready.size() >= 2:
		_start_match(room, room.chooser)


func rematch(peer_id: int, main: Array, cancel: bool) -> void:
	var c: Client = clients.get(peer_id)
	if c == null or c.room_code.is_empty() or c.role != "player":
		return
	var room: Room = rooms.get(c.room_code)
	if room == null or room.phase != "over" or room.players.size() != 2:
		return
	if cancel:
		room.rematch.erase(peer_id)
		_push_series(room)
		return
	var res := _sideboarded(c, main)
	if not bool(res.get("ok", false)):
		Net.push(peer_id, "lobby", {"status": "Deck not accepted: %s" % str(res.get("reason", "")), "error": true})
		return
	c.deck = res["deck"]
	room.rematch[peer_id] = true
	room.last_activity = Time.get_unix_time_from_system()
	_push_series(room)
	if room.rematch.size() >= 2:
		room.wins = [0, 0]
		room.game_no = 0
		_start_match(room, -1, true)


## Who is ready / wants a rematch, by seat, to both players.
func _push_series(room: Room) -> void:
	var rdy: Array = []
	var again: Array = []
	for pid in room.players:
		rdy.append(room.ready.has(pid))
		again.append(room.rematch.has(pid))
	var left := maxf(0.0, room.deadline - Time.get_unix_time_from_system()) if room.phase == "between" else 0.0
	for pid in room.players:
		Net.push(pid, "series", {"ready": rdy, "rematch": again, "seconds_left": left,
			"series": series_of(room)})
