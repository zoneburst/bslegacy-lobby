extends RefCounted
class_name GameState
##
## The authoritative snapshot of one game in progress.
##
## Design contract: GameState holds data and the small number of *primitive*
## mutations that every rule is built from (move a card, move cores, draw).
## It deliberately contains no decision-making. Anything that reads like a
## rule -- "may", "if", "then" -- belongs in RulesEngine, EffectSystem or
## Keywords, which call into here. Keeping that line clean is what makes the
## engine testable without a scene tree and identical on host and bot.
##
## Determinism: every random operation goes through `rng`, seeded once at game
## creation and shared over the network. Two machines fed the same seed and the
## same action log reach byte-identical states, which is how desync detection
## in Net.gd works.
##

var players: Array[PlayerState] = []
var cards: Dictionary = {}             # uid -> CardInstance
var _next_uid: int = 1

var turn_player: int = 0               # 4-3-1
var turn_number: int = 0
var step: int = BSS.Step.START
var first_player: int = 0
var toss_winner: int = -1           # 0.20.0: who won the coin toss and chose the turn order (-1: order given by the caller)

var rng := RandomNumberGenerator.new()
var seed_value: int = 0

# --- Resolution machinery --------------------------------------------------
var effect_stack: Array = []           # 8-5-2-4 LIFO of pending effects
var pending_choice: Dictionary = {}    # a choice a player must answer
var checkpoint_queue: Array = []       # 4-7 gameplay-management work items
var battle: Dictionary = {}            # active battle record, see RulesEngine
## Per-turn flags on a PLAYER, keyed "<pid>:<name>" (0.11.0): "lost_life",
## "attack_tax". Cleared in the end step.
var turn_flags: Dictionary = {}
var flash_passes: int = 0              # 7-1-2-1 two in a row closes the window
var flash_priority: int = -1           # whose turn it is to act in a flash window

# --- Lifecycle -------------------------------------------------------------
var game_over: bool = false
var winner: int = -1                   # -1 none, 2 = draw (1-2-3)
var setup_complete: bool = false

# --- Observability ---------------------------------------------------------
var event_log: Array = []              # replayable, also what the UI animates
## Monotonic id for the next event. The log is trimmed when it grows past 4000
## entries, so a list INDEX is not a stable bookmark; the board remembers the
## last serial it animated instead (0.7.0, R-028).
var event_serial: int = 0
var action_log: Array = []             # every accepted player action, for replays


func _init(p_seed: int = 0) -> void:
	seed_value = p_seed if p_seed != 0 else int(Time.get_unix_time_from_system() * 1000)
	rng.seed = seed_value
	for i in 2:
		var ps := PlayerState.new()
		ps.player_id = i
		players.append(ps)


func opponent_of(pid: int) -> int:
	return 1 - pid


func player(pid: int) -> PlayerState:
	return players[pid]


func card(uid: int) -> CardInstance:
	return cards.get(uid)


# ---------------------------------------------------------------------------
# Card creation
# ---------------------------------------------------------------------------

func spawn_card(data: CardData, owner_id: int, zone: int) -> CardInstance:
	var ci := CardInstance.new(data, _next_uid, owner_id)
	_next_uid += 1
	ci.zone = zone
	cards[ci.uid] = ci
	_zone_array(owner_id, zone).append(ci.uid)
	return ci


## End every link `ci` is part of (11-18-4): its partner stops receiving
## its BP and symbols, and a lender whose partner left is free again. The
## lender stays exhausted (linking exhausted it; nothing refreshes it).
func unlink(ci: CardInstance) -> void:
	if ci.linked_to < 0 and ci.linked_from < 0 and ci.link_lenders.is_empty():
		return
	for uid2: int in cards:
		var c: CardInstance = cards[uid2]
		if c == ci:
			continue
		if c.linked_to == ci.uid:
			c.linked_to = -1
		if c.link_lenders.has(ci):
			c.link_lenders.erase(ci)
			c.linked_from = (c.link_lenders[0] as CardInstance).uid if not c.link_lenders.is_empty() else -1
	if ci.linked_to >= 0 or ci.linked_from >= 0 or not ci.link_lenders.is_empty():
		log_event("unlinked", {"uid": ci.uid})
	ci.linked_to = -1
	ci.linked_from = -1
	ci.link_lenders = []


func _zone_array(pid: int, zone: int) -> Array[int]:
	var p := players[pid]
	match zone:
		BSS.Zone.DECK: return p.deck
		BSS.Zone.HAND: return p.hand
		BSS.Zone.TRASH: return p.trash
		BSS.Zone.FIELD: return p.field
		_: return []


# ---------------------------------------------------------------------------
# Zone movement -- the single choke point for rule 3-1-4
# ---------------------------------------------------------------------------

## Move a card between areas.
##
## `to_top` matters only for the deck (3-2). `cores_to` decides where cores
## sitting on the card go: the default is the controller's reserve, which
## covers both 3-5-5 (generic field exit) and 10-1-3-4 (destruction). Effects
## that send cores elsewhere pass an explicit destination.
func move_card(uid: int, to_zone: int, to_owner: int = -1, to_top: bool = true,
		cores_to: int = BSS.Zone.RESERVE) -> void:
	var ci: CardInstance = cards.get(uid)
	if ci == null:
		return
	var from_zone := ci.zone

	# 1-3-2-2: moving a piece from an area to that same area does not happen.
	var dest_owner := to_owner if to_owner >= 0 else ci.owner_id
	if from_zone == to_zone and dest_owner == ci.controller_id and to_zone != BSS.Zone.DECK:
		return

	# Detach from the old zone.
	if from_zone == BSS.Zone.BURST:
		players[ci.owner_id].burst = -1
	else:
		var src := _zone_array(ci.controller_id, from_zone)
		src.erase(uid)
		if src.is_empty() and ci.controller_id != ci.owner_id:
			_zone_array(ci.owner_id, from_zone).erase(uid)
		else:
			_zone_array(ci.owner_id, from_zone).erase(uid)

	# 11-18-4: a linked spirit leaving the field ends its links at once, for
	# its partner too (0.17.1).
	if from_zone == BSS.Zone.FIELD:
		unlink(ci)
		# 7-1-5-2-1 (0.24.0, R-151): remember that a battling spirit left the
		# field -- the block still stands, and a card that comes back is a new
		# card, not the spirit in this battle.
		if not battle.is_empty():
			if uid == int(battle.get("blocker", -1)):
				battle["blocker_left"] = true
			if uid == int(battle.get("attacker", -1)):
				battle["attacker_left"] = true

	# Cores riding on the card are released before the card lands.
	if from_zone == BSS.Zone.FIELD and ci.total_cores() > 0:
		_release_cores(ci, cores_to)

	# 4-12-3: a token that leaves the field ceases to exist immediately.
	if from_zone == BSS.Zone.FIELD and ci.data != null and ci.flags.get("is_token", false):
		ci.on_zone_change(BSS.Zone.REMOVED)
		cards.erase(uid)
		log_event("token_removed", {"uid": uid})
		return

	ci.on_zone_change(to_zone)
	ci.owner_id = ci.owner_id  # ownership never transfers (4-2-2)
	ci.controller_id = dest_owner

	if to_zone == BSS.Zone.BURST:
		# 3-8-3: setting a second burst discards the first.
		var existing := players[dest_owner].burst
		if existing >= 0:
			move_card(existing, BSS.Zone.TRASH)
		players[dest_owner].burst = uid
		ci.face_up = false
	elif to_zone == BSS.Zone.DECK:
		if to_top:
			players[dest_owner].deck.insert(0, uid)
		else:
			players[dest_owner].deck.append(uid)
	else:
		_zone_array(dest_owner, to_zone).append(uid)
	if to_zone == BSS.Zone.TRASH and ci.data != null and ci.data.is_spirit() and trash_events.size() < 64:
		trash_events.append({"uid": uid, "player": dest_owner})

	log_event("move", {"uid": uid, "from": from_zone, "to": to_zone, "owner": dest_owner})


func _release_cores(ci: CardInstance, dest: int) -> void:
	var p := players[ci.controller_id]
	match dest:
		BSS.Zone.RESERVE:
			p.reserve_cores += ci.cores
			p.reserve_soul += ci.soul_cores
		BSS.Zone.TRASH:
			p.trash_cores += ci.cores
			p.trash_soul += ci.soul_cores
		BSS.Zone.LIFE:
			p.life_cores += ci.cores
			p.life_soul += ci.soul_cores
		BSS.Zone.VOID:
			p.void_soul += ci.soul_cores   # 4-11-3 regular cores just vanish
	ci.cores = 0
	ci.soul_cores = 0


# ---------------------------------------------------------------------------
# Core movement
# ---------------------------------------------------------------------------

## Move `count` cores between two core locations.
##
## A location is either {"kind":"pool","player":pid,"zone":Zone} or
## {"kind":"card","uid":uid}. `soul` requests soul cores specifically; when it
## is false the mover prefers regular cores and only dips into soul cores if
## nothing else is available and `allow_soul` is set (8-5-6 leaves the choice
## to the controller, and the UI passes that choice down).
## "Cores that would be placed into either player's life are placed on this
## spirit instead" (0.14.0): set by EffectSystem.refresh_constants.
var life_redirect_uid := -1
# 0.15.0 (Sets 2-6)
var turn_rules: Array = []      # [{pid, source, d}]: "this turn, ..." constant rules from resolved effects
var delayed: Array = []         # [{pid, source, spec, target, once, duration}]: "this turn, when ..." triggers
var pending_bursts: Array = []  # [{player, event}]: bursts waiting for an open prompt (0.16.7)
var pending_followups: Array = []  # [{player, uid}]: "then pay to use its other effect" offers waiting for an open prompt (0.24.0)
var core_events: Array = []     # core moves since the last checkpoint: {kind: reserve|placed, player|uid}
var turn_start_life: Array = [0, 0]   # each player's life when this turn began (0.15.0, BSS03-058 / BSS04-052)
var trash_events: Array = []    # spirit cards put into a trash since the last checkpoint: {uid, player} (0.15.0, BSS05-016)


func move_cores(from_loc: Dictionary, to_loc: Dictionary, count: int,
		soul: bool = false, allow_soul: bool = false) -> int:
	if count <= 0:
		return 0                                   # 1-3-2-3
	if life_redirect_uid >= 0 and str(to_loc.get("kind", "")) == "pool" \
			and int(to_loc.get("zone", -1)) == BSS.Zone.LIFE:
		var rc: CardInstance = cards.get(life_redirect_uid)
		if rc != null and rc.zone == BSS.Zone.FIELD:
			to_loc = on_card(life_redirect_uid)
	var moved := 0
	for i in count:
		var kind := _take_core(from_loc, soul, allow_soul)
		if kind == "":
			break
		# 4-11-3: a soul core may not enter life or void unless specifically named.
		if kind == "soul" and not soul:
			var tz := int(to_loc.get("zone", -1))
			if to_loc.get("kind", "") == "pool" and (tz == BSS.Zone.LIFE or tz == BSS.Zone.VOID):
				_give_core(from_loc, kind)          # put it back, cannot go there
				break
		_give_core(to_loc, kind)
		moved += 1
	if moved > 0:
		log_event("cores", {"from": from_loc, "to": to_loc, "n": moved, "soul": soul})
		# "When cores are put into your reserve" / "when cores are placed on
		# this spirit" (0.15.0): fired by the engine at the next checkpoint.
		if core_events.size() < 64:
			if str(to_loc.get("kind", "")) == "pool" and int(to_loc.get("zone", -1)) == BSS.Zone.RESERVE \
					and not (str(from_loc.get("kind", "")) == "pool" and int(from_loc.get("zone", -1)) == BSS.Zone.RESERVE):
				core_events.append({"kind": "reserve", "player": int(to_loc.get("player", 0))})
			elif str(to_loc.get("kind", "")) == "card":
				core_events.append({"kind": "placed", "uid": int(to_loc.get("uid", -1))})
	return moved


func _take_core(loc: Dictionary, soul: bool, allow_soul: bool) -> String:
	if loc.get("kind", "") == "card":
		var ci: CardInstance = cards.get(int(loc["uid"]))
		if ci == null: return ""
		if soul:
			if ci.soul_cores > 0: ci.soul_cores -= 1; return "soul"
			return ""
		if ci.cores > 0: ci.cores -= 1; return "regular"
		if allow_soul and ci.soul_cores > 0: ci.soul_cores -= 1; return "soul"
		return ""
	var p := players[int(loc.get("player", 0))]
	match int(loc.get("zone", BSS.Zone.RESERVE)):
		BSS.Zone.RESERVE:
			if soul:
				if p.reserve_soul > 0: p.reserve_soul -= 1; return "soul"
				return ""
			if p.reserve_cores > 0: p.reserve_cores -= 1; return "regular"
			if allow_soul and p.reserve_soul > 0: p.reserve_soul -= 1; return "soul"
		BSS.Zone.LIFE:
			if p.life_cores > 0: p.life_cores -= 1; return "regular"
			if p.life_soul > 0: p.life_soul -= 1; return "soul"
		BSS.Zone.TRASH:
			if soul:
				if p.trash_soul > 0: p.trash_soul -= 1; return "soul"
				return ""
			if p.trash_cores > 0: p.trash_cores -= 1; return "regular"
			if allow_soul and p.trash_soul > 0: p.trash_soul -= 1; return "soul"
		BSS.Zone.VOID:
			# 3-9-2: the void is inexhaustible.
			if soul:
				if p.void_soul > 0: p.void_soul -= 1; return "soul"
				return ""
			return "regular"
	return ""


func _give_core(loc: Dictionary, kind: String) -> void:
	if loc.get("kind", "") == "card":
		var ci: CardInstance = cards.get(int(loc["uid"]))
		if ci == null: return
		if kind == "soul": ci.soul_cores += 1
		else: ci.cores += 1
		return
	var p := players[int(loc.get("player", 0))]
	var is_soul := kind == "soul"
	match int(loc.get("zone", BSS.Zone.RESERVE)):
		BSS.Zone.RESERVE:
			if is_soul: p.reserve_soul += 1
			else: p.reserve_cores += 1
		BSS.Zone.LIFE:
			if is_soul: p.life_soul += 1
			else: p.life_cores += 1
		BSS.Zone.TRASH:
			if is_soul: p.trash_soul += 1
			else: p.trash_cores += 1
		BSS.Zone.VOID:
			if is_soul: p.void_soul += 1
			# regular cores returning to the void simply leave play


static func pool(pid: int, zone: int) -> Dictionary:
	return {"kind": "pool", "player": pid, "zone": zone}


static func on_card(uid: int) -> Dictionary:
	return {"kind": "card", "uid": uid}


# ---------------------------------------------------------------------------
# Deck operations
# ---------------------------------------------------------------------------

## 4-5-2 -- draw one card, top of deck to hand, unrevealed.
func draw(pid: int, n: int = 1) -> int:
	var drawn := 0
	for i in n:
		var p := players[pid]
		if p.deck.is_empty():
			break                          # 1-3-2, deck-out is checked at 6-2-2
		var uid := p.deck[0]
		move_card(uid, BSS.Zone.HAND, pid)
		drawn += 1
	if drawn > 0:
		log_event("draw", {"player": pid, "n": drawn})
	return drawn


## 3-2-4 -- randomise deck order. Physical shuffling etiquette (owner first,
## then opponent cuts) has no digital analogue; what matters is that the result
## is uniformly random and derived from the shared seed.
func shuffle_deck(pid: int) -> void:
	var d := players[pid].deck
	for i in range(d.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp := d[i]
		d[i] = d[j]
		d[j] = tmp
	log_event("shuffle", {"player": pid})


## 11-11 Crush and similar effects discard from the top of a deck (10-2-1).
func mill(pid: int, n: int) -> int:
	return mill_cards(pid, n).size()


## The milled cards' uids, top first (0.11.0: "when a spirit card is milled").
func mill_cards(pid: int, n: int) -> Array:
	var out: Array = []
	for i in n:
		var p := players[pid]
		if p.deck.is_empty():
			break
		var uid := p.deck[0]
		move_card(uid, BSS.Zone.TRASH, pid)
		out.append(uid)
	return out


func turn_flag(pid: int, name: String) -> bool:
	return bool(turn_flags.get("%d:%s" % [pid, name], false))


func set_turn_flag(pid: int, name: String, on: bool = true) -> void:
	turn_flags["%d:%s" % [pid, name]] = on


# ---------------------------------------------------------------------------
# Queries used all over the engine
# ---------------------------------------------------------------------------

func field_spirits(pid: int) -> Array:
	var out: Array = []
	for uid in players[pid].field:
		var ci: CardInstance = cards[uid]
		if ci.data != null and ci.data.is_spirit():
			out.append(ci)
	return out


func field_nexuses(pid: int) -> Array:
	var out: Array = []
	for uid in players[pid].field:
		var ci: CardInstance = cards[uid]
		# a nexus treated as a spirit is still one of your nexuses (0.15.0, BSS05-082)
		if ci.data != null and (ci.data.is_nexus() or (ci.orig_data != null and ci.orig_data.is_nexus())):
			out.append(ci)
	return out


func all_field_cards() -> Array:
	var out: Array = []
	for pid in 2:
		for uid in players[pid].field:
			out.append(cards[uid])
	return out


func log_event(kind: String, payload: Dictionary = {}) -> void:
	event_log.append({"t": event_serial, "kind": kind, "data": payload})
	event_serial += 1
	if event_log.size() > 4000:
		event_log = event_log.slice(event_log.size() - 2000)


# ---------------------------------------------------------------------------
# Networking snapshot
# ---------------------------------------------------------------------------

## Build the view of the game that `viewer` is allowed to see (3-1-3).
## `viewer` of -1 means a spectator, who sees neither hand.
func to_net(viewer: int) -> Dictionary:
	return {
		"turn_player": turn_player,
		"turn_number": turn_number,
		"step": step,
		"battle": battle.duplicate(true),
		"stack": effect_stack.size(),
		"pending_choice": pending_choice.duplicate(true) if int(pending_choice.get("player", -1)) == viewer else ({"player": pending_choice.get("player", -1), "type": str(pending_choice.get("type", "")), "reason": str(pending_choice.get("reason", ""))} if not pending_choice.is_empty() else {}),
		"flash_priority": flash_priority,
		"game_over": game_over,
		"winner": winner,
		"players": [
			players[0].to_net(viewer == 0, self),
			players[1].to_net(viewer == 1, self),
		],
		"event_cursor": event_serial,
	}


## Cheap fingerprint used to detect desync between host and client.
func checksum() -> int:
	var h := 0
	h = hash([turn_number, step, turn_player, winner])
	for pid in 2:
		var p := players[pid]
		h = hash([h, p.deck.size(), p.hand.size(), p.trash.size(), p.field.size(),
			p.reserve_cores, p.reserve_soul, p.life_cores, p.life_soul])
		for uid in p.field:
			var ci: CardInstance = cards[uid]
			h = hash([h, uid, ci.cores, ci.soul_cores, ci.orientation, ci.raw_bp()])
	return h
