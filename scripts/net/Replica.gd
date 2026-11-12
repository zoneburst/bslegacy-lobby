extends RefCounted
class_name Replica
##
## The online client's copy of the game (0.16.8).
##
## An online client has no rules engine of its own: the server's RulesEngine is
## the only one that decides anything. But the board needs an engine to READ --
## which actions are legal, what a card costs, what happened since the last
## update -- exactly as it does in a local game. So the server sends each
## player an "replica": the whole GameState, with everything that player may
## not see blanked out, and the client rebuilds it into a mirror RulesEngine
## that the board reads and never submits to. Every action still travels to
## the server and is checked there; the mirror only makes the board work.
##
## What a viewer may not see (3-1-3):
##   * every deck card (both decks; their order is hidden too: deck uids are
##     sent sorted, so a card shuffled back in cannot be followed),
##   * the other player's hand and set burst (a spectator sees neither hand),
##   * the other player's open choice (only who is choosing, and its type),
##   * the match seed, the RNG and the action log.
## A hidden card keeps its uid, zone and owner, so counts and positions on the
## board are right, but its CardData is a blank placeholder.
##
## Encoding is generic -- every script variable of GameState, PlayerState and
## CardInstance -- so a field added to the engine later is replicated without
## anyone remembering to add it here. Values equal to a fresh object's default
## are left out to keep the message small. Objects inside values are encoded
## by reference: a CardInstance as {"__ci": uid}, a CardData as {"__cd": id};
## any other object is dropped and counted in `unsupported` (the tests fail on
## it).
##

const HIDDEN_ID := "__hidden"
const SKIP_STATE := ["rng", "seed_value", "action_log", "event_log", "players", "cards"]
const MAX_EVENTS := 400

static var unsupported: int = 0
static var _hidden_data: CardData = null
## Card definitions received from the server (id -> CardData), so a card this
## client does not have -- a token made during the game, a card the other
## player imported -- is still the exact card the server plays. Cleared at the
## start of each online match.
static var defs: Dictionary = {}


## The replica of `st` for `viewer` (0, 1, or -1 for a spectator), with the
## events after serial `since`. `sent_defs` (id -> true) lists the card
## definitions this recipient already has; the full definition of every other
## visible card is included once, and added to it.
static func encode(st: GameState, viewer: int, since: int = -1, sent_defs: Dictionary = {}) -> Dictionary:
	var hidden := hidden_uids(st, viewer)
	var cards := {}
	var new_defs := {}
	var blank_ci := CardInstance.new()
	var blank_cd := CardData.new()
	for uid: int in st.cards:
		var ci: CardInstance = st.cards[uid]
		if hidden.has(uid):
			cards[uid] = {"uid": uid, "zone": ci.zone, "owner_id": ci.owner_id,
					"controller_id": ci.controller_id, "__hidden": true}
		else:
			cards[uid] = _encode_object(ci, blank_ci, [])
			for cdv: Variant in [ci.data, ci.orig_data]:
				var cd := cdv as CardData
				if cd != null and not sent_defs.has(cd.id):
					new_defs[cd.id] = _encode_object(cd, blank_cd, [])
					sent_defs[cd.id] = true
	var players: Array = []
	var blank_ps := PlayerState.new()
	for ps: PlayerState in st.players:
		var pd := _encode_object(ps, blank_ps, [])
		pd["deck"] = _sorted(ps.deck)         # order hidden; a set burst's uid is public, its card is not
		players.append(pd)
	var top := _encode_object(st, GameState.new(1), SKIP_STATE)
	var pc: Dictionary = st.pending_choice
	if not pc.is_empty() and int(pc.get("player", -1)) != viewer:
		top["pending_choice"] = {"player": int(pc.get("player", -1)), "type": str(pc.get("type", "")),
				"reason": str(pc.get("reason", ""))}
	var events: Array = []
	for e: Dictionary in st.event_log:
		if int(e.get("t", -1)) > since:
			events.append(_encode(e))
	if events.size() > MAX_EVENTS:
		events = events.slice(events.size() - MAX_EVENTS)
	return {"state": top, "players": players, "cards": cards, "events": events, "defs": new_defs,
			"viewer": viewer, "checksum": st.checksum()}


## Uids whose identity `viewer` may not know.
static func hidden_uids(st: GameState, viewer: int) -> Dictionary:
	var out := {}
	for ps: PlayerState in st.players:
		for uid in ps.deck:
			out[uid] = true
		if ps.player_id != viewer:
			for uid in ps.hand:
				out[uid] = true
			if ps.burst >= 0:
				out[ps.burst] = true
	# The cards in the viewer's own open choice are the ones they are looking at
	# (a search of their deck, say), so those are shown to them.
	var pc: Dictionary = st.pending_choice
	if not pc.is_empty() and int(pc.get("player", -1)) == viewer:
		for o: Variant in pc.get("options", []):
			if typeof(o) == TYPE_INT or typeof(o) == TYPE_FLOAT:
				out.erase(int(o))
		for r: Variant in pc.get("revealed", []):
			if r is Dictionary:
				out.erase(int((r as Dictionary).get("uid", -1)))
	return out


## Rebuild a GameState from a replica. `prior_events` is the previous mirror's
## event log, so the board can keep animating from where it was.
static func decode(rep: Dictionary, prior_events: Array = []) -> GameState:
	var raw_defs: Dictionary = rep.get("defs", {})
	for id: Variant in raw_defs:
		var cdef := CardData.new()
		_apply(cdef, raw_defs[id], null)
		defs[str(id)] = cdef
		# Register a card this client lacks, so the board can draw it too.
		if not CardDB.cards.has(str(id)):
			CardDB.cards[str(id)] = cdef
	var st := GameState.new(1)
	st.seed_value = 0
	st.cards = {}
	var raw_cards: Dictionary = rep.get("cards", {})
	for k: Variant in raw_cards:
		var cd: Dictionary = raw_cards[k]
		var uid := int(cd.get("uid", int(k)))
		var ci := CardInstance.new(null, uid, int(cd.get("owner_id", 0)))
		st.cards[uid] = ci
	for k: Variant in raw_cards:
		var cd: Dictionary = raw_cards[k]
		var ci: CardInstance = st.cards[int(cd.get("uid", int(k)))]
		if bool(cd.get("__hidden", false)):
			ci.data = hidden_data()
			ci.zone = int(cd.get("zone", 0))
			ci.controller_id = int(cd.get("controller_id", ci.owner_id))
			ci.face_up = false
			continue
		_apply(ci, cd, st)
		if ci.data == null:
			ci.data = hidden_data()
	var players: Array = rep.get("players", [])
	for i in mini(players.size(), st.players.size()):
		_apply(st.players[i], players[i], st)
	_apply(st, rep.get("state", {}), st)
	var evlog: Array = prior_events.duplicate()
	var last := int(evlog[evlog.size() - 1].get("t", -1)) if not evlog.is_empty() else -1
	for e: Variant in rep.get("events", []):
		var ev: Dictionary = _decode(e, st)
		if int(ev.get("t", -1)) > last:
			evlog.append(ev)
	if evlog.size() > MAX_EVENTS:
		evlog = evlog.slice(evlog.size() - MAX_EVENTS)
	st.event_log = evlog
	return st


static func hidden_data() -> CardData:
	if _hidden_data == null:
		_hidden_data = CardData.new()
		_hidden_data.id = HIDDEN_ID
		_hidden_data.name = "Hidden card"
	return _hidden_data


# ---------------------------------------------------------------------------
# Generic encoding
# ---------------------------------------------------------------------------

static func _script_vars(obj: Object) -> Array:
	var out: Array = []
	for p: Dictionary in obj.get_property_list():
		if int(p.get("usage", 0)) & PROPERTY_USAGE_SCRIPT_VARIABLE:
			out.append(str(p["name"]))
	return out


static func _encode_object(obj: Object, blank: Object, skip: Array) -> Dictionary:
	var out := {}
	for name: String in _script_vars(obj):
		if skip.has(name):
			continue
		var v: Variant = _encode(obj.get(name))
		if blank != null and v == _encode(blank.get(name)):
			continue
		out[name] = v
	return out


static func _encode(v: Variant) -> Variant:
	match typeof(v):
		TYPE_OBJECT:
			if v == null:
				return null
			if v is CardInstance:
				return {"__ci": (v as CardInstance).uid}
			if v is CardData:
				return {"__cd": (v as CardData).id}
			unsupported += 1
			return null
		TYPE_ARRAY:
			var a: Array = []
			for x: Variant in v:
				a.append(_encode(x))
			return a
		TYPE_DICTIONARY:
			var d := {}
			for k: Variant in v:
				d[k] = _encode(v[k])
			return d
		TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID:
			unsupported += 1
			return null
	return v


static func _decode(v: Variant, st: GameState) -> Variant:
	match typeof(v):
		TYPE_ARRAY:
			var a: Array = []
			for x: Variant in v:
				a.append(_decode(x, st))
			return a
		TYPE_DICTIONARY:
			var dv: Dictionary = v
			if dv.size() == 1 and dv.has("__ci"):
				return st.cards.get(int(dv["__ci"])) if st != null else null
			if dv.size() == 1 and dv.has("__cd"):
				return _card_data(str(dv["__cd"]))
			var d := {}
			for k: Variant in dv:
				d[k] = _decode(dv[k], st)
			return d
	return v


static func _apply(obj: Object, d: Dictionary, st: GameState) -> void:
	for name: Variant in d:
		var val: Variant = _decode(d[name], st)
		var cur: Variant = obj.get(name)
		if cur is Array and val is Array and (cur as Array).is_typed():
			(cur as Array).assign(val)
		elif cur is PackedStringArray and val is Array:
			obj.set(name, PackedStringArray(val))
		else:
			obj.set(name, val)


static func _card_data(id: String) -> CardData:
	if id == "" or id == HIDDEN_ID:
		return hidden_data()
	if defs.has(id):
		return defs[id]
	var cd: CardData = CardDB.get_card(id)
	if cd != null:
		return cd
	# The server knows a card this client does not (an imported card). Show
	# it by number rather than failing; the server still plays it correctly.
	var ph := CardData.new()
	ph.id = id
	ph.name = id
	return ph


static func _sorted(a: Array) -> Array:
	var out: Array = a.duplicate()
	out.sort()
	return out
