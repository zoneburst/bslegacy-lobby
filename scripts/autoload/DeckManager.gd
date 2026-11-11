extends Node
##
## Deck storage, validation, and import/export.
##
## Decks are plain JSON files in user://decks/. One file per deck keeps the
## format trivially diffable and lets a user hand-edit or share a deck without
## the app running. Nothing is stored server-side unless the account sync in
## Net.gd is enabled, so the offline experience is complete on its own.
##
## Deck file shape:
##   {
##     "id": "d_1712345678_4821",
##     "name": "Red Aggro",
##     "author": "Player",
##     "created": 1712345678, "modified": 1712400000,
##     "main": ["BSS01-001", "BSS01-001", ...],   # 50-60 entries, one per card
##     "side": ["BSS02-014", ...],                # optional, not used in play
##     "notes": ""
##   }
##
## The main list stores one entry per physical copy rather than
## {id: count} pairs. It is more verbose but it is exactly what the engine
## wants at setup time and it removes a whole class of "count drifted out of
## sync with the list" bugs.
##

const DECK_DIR := "user://decks"

var decks: Dictionary = {}     # id -> deck dictionary

signal decks_changed


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(DECK_DIR)
	load_all()


## Bundled decks live in res://data/starter_decks and are copied into the
## player's own deck folder the first time the game runs. Without this a fresh
## install has NO decks at all, and every battle screen refuses to start with
## "pick a deck first" and nothing to pick -- which is not a helpful thing to
## say to someone who has just installed the game.
##
## Copies are made once. After that they are the player's decks: editing or
## deleting one is permanent, and the originals are not restored on the next
## launch, because silently resurrecting a deck someone deliberately deleted
## would be worse than the empty state this solves.
const BUNDLED_DIR := "res://data/starter_decks"
const SEEDED_MARKER := "user://decks/.seeded"


## A starter deck the player has never edited (still "author": "bundled" and
## "modified": 0) is replaced whenever the shipped version changes. Until
## 0.9.0 starter decks were copied once and never again, so everyone who had
## run an earlier version kept the old all-spirit decks after the update and
## never saw the new nexus and magic cards in them (R-046). Decks the player
## has edited or saved are never touched.
func _refresh_bundled_decks() -> void:
	var refreshed := 0
	for fp: String in _bundled_files():
		var f := fp.get_file()
		var dest: String = DECK_DIR.path_join(f)
		if not FileAccess.file_exists(dest):
			continue
		var mine: Variant = JSON.parse_string(FileAccess.get_file_as_string(dest))
		var shipped_text := FileAccess.get_file_as_string(fp)
		var shipped: Variant = JSON.parse_string(shipped_text)
		if not (mine is Dictionary) or not (shipped is Dictionary):
			continue
		var m: Dictionary = mine
		if str(m.get("author", "")) != "bundled" or float(m.get("modified", 0)) != 0.0:
			continue
		if m.get("main", []) == (shipped as Dictionary).get("main", []):
			continue
		var out := FileAccess.open(dest, FileAccess.WRITE)
		if out != null:
			out.store_string(shipped_text)
			out.close()
			refreshed += 1
	if refreshed > 0:
		Log.info("DeckManager: updated %d unedited starter deck(s) to the new version" % refreshed)


## Bundled decks are copied into the user's deck folder once each. The
## marker file lists the ones already offered, so a deck added in a later
## version (the six 0.11.0 starter-deck versions) still arrives, while a deck
## the player deleted is never brought back. Before 0.11.0 the marker was a
## single "seeded" flag and new bundled decks never appeared (R-057).
const LEGACY_SEEDED := ["starter_red.json", "starter_purple.json", "starter_white.json",
		"starter_yellow.json", "starter_green.json", "starter_blue.json"]


func _seed_bundled_decks() -> void:
	_refresh_bundled_decks()
	DirAccess.make_dir_recursive_absolute(DECK_DIR)
	var seeded: Array = []
	if FileAccess.file_exists(SEEDED_MARKER):
		var text := FileAccess.get_file_as_string(SEEDED_MARKER).strip_edges()
		var parsed: Variant = JSON.parse_string(text) if text.begins_with("[") else null
		seeded = parsed if parsed is Array else LEGACY_SEEDED.duplicate()
	var copied := 0
	for f: String in _bundled_files():
		if seeded.has(f.get_file()):
			continue
		seeded.append(f.get_file())
		var dest: String = DECK_DIR.path_join(f.get_file())
		if FileAccess.file_exists(dest):
			continue
		var text := FileAccess.get_file_as_string(f)
		var out := FileAccess.open(dest, FileAccess.WRITE)
		if out != null:
			out.store_string(text)
			out.close()
			copied += 1
	var mark := FileAccess.open(SEEDED_MARKER, FileAccess.WRITE)
	if mark != null:
		mark.store_string(JSON.stringify(seeded))
		mark.close()
	if copied > 0:
		Log.info("DeckManager: added %d starter decks" % copied)


## Every deck file that ships with this copy: ours (data/starter_decks) and
## the decks of a bundled spreadsheet (data/bundle/decks, 0.23.0).
const BUNDLE_DECK_DIR := "res://data/bundle/decks"


func _bundled_files() -> Array:
	var out: Array = []
	for dir_path in [BUNDLED_DIR, BUNDLE_DECK_DIR]:
		var d := DirAccess.open(dir_path)
		if d == null:
			continue
		for f in d.get_files():
			if f.ends_with(".json"):
				out.append(dir_path.path_join(f))
	return out


## Starter decks no longer shipped (0.18.2): our versions of the six Battle
## Spirits Saga starter decks. Their cards stay in the database. A copy the
## player never edited (still "author": "bundled", "modified": 0) is removed
## from their deck folder; one they edited or saved is theirs and is kept.
const RETIRED_DECKS := ["saga_st01", "saga_st02", "saga_st03", "saga_st04", "saga_st05", "saga_st06"]
## The tests still play with those decks; they are kept here, not in the game.
const FIXTURE_DECK_DIR := "res://tests/fixtures/decks"


func _remove_retired_decks() -> void:
	var removed := 0
	for id: String in RETIRED_DECKS:
		var path: String = DECK_DIR.path_join("%s.json" % id)
		if not FileAccess.file_exists(path):
			continue
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if d is Dictionary and str((d as Dictionary).get("author", "")) == "bundled" \
				and float((d as Dictionary).get("modified", 0)) == 0.0:
			DirAccess.remove_absolute(path)
			removed += 1
	if removed > 0:
		Log.info("DeckManager: removed %d retired starter deck(s) you had not edited" % removed)


## A deck by id, or one of the tests' fixture decks (tests only).
func test_deck(id: String) -> Dictionary:
	if decks.has(id):
		return decks[id]
	var path := FIXTURE_DECK_DIR.path_join("%s.json" % id)
	if FileAccess.file_exists(path):
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if d is Dictionary:
			return d
	return {}


func load_all() -> void:
	_remove_retired_decks()
	_seed_bundled_decks()
	decks.clear()
	var dir := DirAccess.open(DECK_DIR)
	if dir == null:
		return
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if not dir.current_is_dir() and f.ends_with(".json"):
			var fa := FileAccess.open(DECK_DIR.path_join(f), FileAccess.READ)
			if fa != null:
				var d = JSON.parse_string(fa.get_as_text())
				fa.close()
				if typeof(d) == TYPE_DICTIONARY and d.has("id"):
					decks[str(d["id"])] = d
		f = dir.get_next()
	dir.list_dir_end()
	Log.info("DeckManager: %d decks loaded" % decks.size())
	# Having decks but no PLAYABLE chosen deck is the same dead end as having
	# none, so pick one that can actually start a match.
	active_deck()
	decks_changed.emit()


## The deck the player plays with: the chosen one if it can be played AND is
## shown (0.23.1: a hidden AI-generated deck is not kept as the active one
## once real cards are in the game), otherwise the first shown deck that can
## be played -- which then becomes the chosen one.
func active_deck() -> Dictionary:
	var d := get_deck(GameConfig.default_deck_id)
	if not d.is_empty() and bool(validate(d).get("ok", false)) and is_visible(d):
		return d
	var playable := visible_playable_decks()
	if playable.is_empty():
		playable = playable_decks()
	if playable.is_empty():
		return {}
	GameConfig.default_deck_id = str(playable[0]["id"])
	return playable[0]


## Returns a DRAFT deck. It is not added to `decks` and not written to disk
## until save() is called. Before 0.6.0 this saved immediately, so simply
## opening the deck editor left an empty "New Deck" behind every time -- and
## those empty decks then appeared in the Battle menu, could be picked as the
## AI's deck, and made the match fail to start (R-021).
func new_deck(deck_name: String = "New Deck") -> Dictionary:
	var id := "d_%d_%d" % [int(Time.get_unix_time_from_system()), randi() % 10000]
	return {
		"id": id, "name": deck_name, "author": GameConfig.player_name,
		"created": int(Time.get_unix_time_from_system()),
		"modified": int(Time.get_unix_time_from_system()),
		"main": [], "side": [], "notes": "",
	}


## Empty decks left behind by the pre-0.6.0 editor, which saved a blank
## "New Deck" every time it was opened (R-021). Listed, never deleted
## automatically -- the deck list offers a button so the player decides.
func empty_decks() -> Array:
	var out: Array = []
	for d in decks.values():
		if (d.get("main", []) as Array).is_empty():
			out.append(d)
	return out


## Decks that can actually be played. Battle screens list only these, so an
## unfinished deck can never be chosen for a match.
func playable_decks() -> Array:
	var out: Array = []
	for d in sorted_decks():
		if bool(validate(d).get("ok", false)):
			out.append(d)
	return out


## Decks the player sees (0.13.0): with "hide AI-generated cards" on, a deck
## that uses any of our generated cards is hidden until the setting is off.
func is_visible(d: Dictionary) -> bool:
	if not GameConfig.hide_generated_cards:
		return true
	for id: Variant in d.get("main", []):
		if CardDB.is_hidden(str(id)):
			return false
	return true


func visible_decks() -> Array:
	return sorted_decks().filter(func(d: Dictionary) -> bool: return is_visible(d))


func visible_playable_decks() -> Array:
	return playable_decks().filter(func(d: Dictionary) -> bool: return is_visible(d))


func save(d: Dictionary) -> void:
	d["modified"] = int(Time.get_unix_time_from_system())
	var path := DECK_DIR.path_join("%s.json" % str(d["id"]))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		Log.error("DeckManager: cannot write %s" % path)
		return
	f.store_string(JSON.stringify(d, "  "))
	f.close()
	decks[str(d["id"])] = d
	decks_changed.emit()


func delete(id: String) -> void:
	DirAccess.remove_absolute(DECK_DIR.path_join("%s.json" % id))
	decks.erase(id)
	decks_changed.emit()


func duplicate_deck(id: String) -> Dictionary:
	var src: Dictionary = decks.get(id, {})
	if src.is_empty():
		return {}
	var copy := src.duplicate(true)
	copy["id"] = "d_%d_%d" % [int(Time.get_unix_time_from_system()), randi() % 10000]
	copy["name"] = str(src["name"]) + " (copy)"
	save(copy)
	return copy


func get_deck(id: String) -> Dictionary:
	return decks.get(id, {})


func sorted_decks() -> Array:
	var out: Array = decks.values()
	out.sort_custom(func(a, b): return int(a.get("modified", 0)) > int(b.get("modified", 0)))
	return out


## Can this card still be added? Enforces 5-1-1-1 (60 max) and 5-1-1-1-1
## (four copies per card *name*, spanning alternate printings).
func can_add(d: Dictionary, card_id: String) -> Dictionary:
	var cd: CardData = CardDB.get_card(card_id)
	if cd == null:
		return {"ok": false, "reason": "unknown card"}
	var main: Array = d.get("main", [])
	if main.size() >= BSS.DECK_MAX:
		return {"ok": false, "reason": "deck is already at %d cards" % BSS.DECK_MAX}
	var same := 0
	for cid in main:
		var other: CardData = CardDB.get_card(cid)
		if other != null and other.deck_key() == cd.deck_key():
			same += 1
	if same >= BSS.MAX_COPIES:
		return {"ok": false, "reason": "already 4 copies of \"%s\"" % cd.name}
	return {"ok": true, "reason": ""}


## Edits the deck in memory only. Saving is the editor's decision -- before
## 0.6.0 every click wrote to disk, which made a draft impossible and meant an
## abandoned edit was silently kept.
func add_card(d: Dictionary, card_id: String) -> Dictionary:
	var chk := can_add(d, card_id)
	if not chk["ok"]:
		return chk
	if not d.has("main"):
		d["main"] = []
	d["main"].append(card_id)
	return {"ok": true, "reason": ""}


func remove_card(d: Dictionary, card_id: String) -> void:
	var main: Array = d.get("main", [])
	var idx := main.find(card_id)
	if idx >= 0:
		main.remove_at(idx)


## Legality for matchmaking. Wraps RulesEngine.validate_deck so the editor and
## the engine can never disagree about what a legal deck is.
func validate(d: Dictionary) -> Dictionary:
	return RulesEngine.validate_deck(d.get("main", []))


func stats(d: Dictionary) -> Dictionary:
	var counts := {"spirit": 0, "nexus": 0, "magic": 0}
	var curve := {}
	var colors := {}
	for cid in d.get("main", []):
		var cd: CardData = CardDB.get_card(cid)
		if cd == null: continue
		counts[BSS.CARD_TYPE_NAMES[cd.card_type]] += 1
		curve[cd.cost] = int(curve.get(cd.cost, 0)) + 1
		for c in cd.colors:
			colors[c] = int(colors.get(c, 0)) + 1
	return {"total": d.get("main", []).size(), "types": counts, "curve": curve, "colors": colors}


# ---------------------------------------------------------------------------
# Import / export
# ---------------------------------------------------------------------------

## Plain-text format, one line per stack: "4 BSS01-001 Card Name".
## This matches the text export offered by bssdb.dev closely enough to
## round-trip, which is the point -- users already have decks over there.
func to_text(d: Dictionary) -> String:
	var counts := {}
	var order: Array = []
	for cid in d.get("main", []):
		if not counts.has(cid):
			counts[cid] = 0
			order.append(cid)
		counts[cid] += 1
	var lines: Array = []
	for cid in order:
		var cd: CardData = CardDB.get_card(cid)
		lines.append("%d %s %s" % [counts[cid], cid, cd.name if cd else ""])
	return "\n".join(lines)


func from_text(text: String, deck_name: String = "Imported Deck") -> Dictionary:
	var d := new_deck(deck_name)
	var rx := RegEx.new()
	rx.compile("^\\s*(\\d+)\\s*[xX]?\\s+([A-Za-z0-9\\-]+)")
	for raw in text.split("\n"):
		var m := rx.search(raw)
		if m == null:
			continue
		var n := int(m.get_string(1))
		var cid := m.get_string(2)
		if CardDB.get_card(cid) == null:
			Log.warn("Deck import: unknown card id %s" % cid)
			continue
		for i in min(n, BSS.MAX_COPIES):
			d["main"].append(cid)
	save(d)
	return d
