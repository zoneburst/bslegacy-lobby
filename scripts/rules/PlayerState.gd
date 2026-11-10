extends RefCounted
class_name PlayerState
##
## Everything one player owns (Comprehensive Rules section 3).
##
## Zones that hold cards are arrays of uid ints, not of CardInstance objects.
## The GameState owns the single authoritative uid -> CardInstance map, so a
## card can never accidentally exist in two zones at once; moving it is a
## single erase + append and the instance itself is untouched.
##
## Cores are counted, not modelled as objects, with one exception: each player
## has exactly one soul core (4-11-3) and it needs individual tracking because
## several rules ask "is *the* soul core here".
##

var player_id: int = 0
var display_name: String = "Player"

# --- Card zones (uid lists) ------------------------------------------------
var deck: Array[int] = []      # 3-2 private, ordered, top of deck is index 0
var hand: Array[int] = []      # 3-3 private to the owner
var trash: Array[int] = []     # 3-4 public
var field: Array[int] = []     # 3-5 public
var burst: int = -1            # 3-8-3 at most one card set at a time

# --- Core pools ------------------------------------------------------------
var reserve_cores: int = 0     # 3-6 regular cores in the reserve
var reserve_soul: int = 0      # soul cores in the reserve (0 or 1)
var life_cores: int = 0        # 3-7 life; a soul core cannot be put here by an
									# effect that does not name soul cores (4-11-3)
var life_soul: int = 0
var trash_cores: int = 0       # 3-4-1 core section of the trash
var trash_soul: int = 0
var void_soul: int = 0         # 4-11-4 soul cores banished to the void

# --- Turn counters ---------------------------------------------------------
var bursts_set_this_turn: int = 0     # 6-6-1-2-2 one per turn
var has_mulliganed: bool = false
var conceded: bool = false

# --- Deck identity ---------------------------------------------------------
var deck_name: String = ""


func life_total() -> int:
	# 1-2-1-1-1 -- the loss condition counts every core in the life area.
	return life_cores + life_soul


func total_reserve() -> int:
	return reserve_cores + reserve_soul


## 2-7-3 / 10-6-5 -- count symbols currently on the field for cost reduction.
## Every symbol on every card the player controls counts, spirits and nexuses
## alike, and a double-colour symbol counts as whichever colour helps (2-8-2-2).
func count_field_symbols(game) -> Dictionary:
	var counts := {}
	for c in BSS.COLOR_NAMES.size():
		counts[c] = 0
	for uid in field:
		var ci: CardInstance = game.cards.get(uid)
		if ci == null:
			continue
		for group in ci.symbol_groups():
			for col in group:
				counts[col] = int(counts[col]) + 1
	return counts


## 2-8-2-2 -- the same symbols, but kept as individual groups instead of being
## flattened into per-colour totals. Cost reduction needs this: a double-colour
## symbol is ONE symbol that the player declares as one of its colours, so it
## can pay for a red reduction icon or a blue one, never both at once.
## `count_field_symbols` above deliberately keeps the flattened view, which is
## the right answer for "do you have a symbol of colour X" tests (11-15-3).
func field_symbol_groups(game) -> Array:
	var groups: Array = []
	for uid in field:
		var ci: CardInstance = game.cards.get(uid)
		if ci == null:
			continue
		for group in ci.symbol_groups():
			groups.append(group)
	return groups


func reset_turn_counters() -> void:
	bursts_set_this_turn = 0


func to_net(is_self: bool, game) -> Dictionary:
	var hand_out: Array = []
	for uid in hand:
		var ci: CardInstance = game.cards[uid]
		hand_out.append(ci.to_net(is_self))
	var field_out: Array = []
	for uid in field:
		field_out.append(game.cards[uid].to_net(true))
	var trash_out: Array = []
	for uid in trash:
		trash_out.append(game.cards[uid].to_net(true))
	return {
		"id": player_id,
		"name": display_name,
		"deck_count": deck.size(),
		"hand": hand_out,
		"field": field_out,
		"trash": trash_out,
		"burst_set": burst >= 0,
		"burst_card": (game.cards[burst].to_net(true) if (is_self and burst >= 0) else null),
		"reserve": reserve_cores,
		"reserve_soul": reserve_soul,
		"life": life_cores,
		"life_soul": life_soul,
		"trash_cores": trash_cores,
		"trash_soul": trash_soul,
		"deck_name": deck_name,
	}
