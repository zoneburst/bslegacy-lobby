class_name ReplayStore
extends RefCounted
##
## The last ten matches, kept for watching again and exporting as video
## (0.25.0, R-169).
##
## A replay is tiny: the engine is deterministic, so the match seed, what
## setup() was given and the accepted actions in order rebuild the whole game
## (RulesEngine.replay_record()). Local games record it themselves; an
## online game's record comes from the server with the "ended" message, once
## nothing in it is hidden any more.
##
##   user://replays/index.json   [{id, date, title, opponent, result, kind,
##                                 seat, turns, names}], newest first
##   user://replays/<id>.json.gz the record, gzip-compressed
##

## The folder; tests point it elsewhere so they never touch the player's own.
static var DIR := "user://replays"
const KEEP := 10


static func _ensure_dir() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)


static func list() -> Array:
	var f := FileAccess.open(DIR + "/index.json", FileAccess.READ)
	if f == null:
		return []
	var v: Variant = JSON.parse_string(f.get_as_text())
	return (v as Array) if typeof(v) == TYPE_ARRAY else []


static func _write_index(entries: Array) -> void:
	_ensure_dir()
	var f := FileAccess.open(DIR + "/index.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(entries, " "))


## Keep a finished game. `meta`: opponent, result ("win"/"loss"/"draw"/
## "spectated"), kind ("cpu"/"online"/"hotseat"), seat (whose view). Returns
## the new entry's id, or "" when the record is unusable. The eleventh
## replay pushes out the oldest.
static func save(record: Dictionary, meta: Dictionary) -> String:
	if (record.get("actions", []) as Array).is_empty() or (record.get("setup", {}) as Dictionary).is_empty():
		return ""
	_ensure_dir()
	var now := Time.get_datetime_dict_from_system()
	var id := "%04d%02d%02d-%02d%02d%02d-%d" % [now.year, now.month, now.day, now.hour, now.minute, now.second,
			randi() % 1000]
	var f := FileAccess.open_compressed(DIR + "/%s.json.gz" % id, FileAccess.WRITE, FileAccess.COMPRESSION_GZIP)
	if f == null:
		return ""
	f.store_string(JSON.stringify(record))
	f.close()
	var names: Array = (record.get("setup", {}) as Dictionary).get("names", [])
	var row := {
		"id": id,
		"date": Time.get_datetime_string_from_system(false, true),
		"opponent": str(meta.get("opponent", "Opponent")),
		"result": str(meta.get("result", "")),
		"kind": str(meta.get("kind", "cpu")),
		"seat": int(meta.get("seat", 0)),
		"turns": int(record.get("turns", 0)),
		"names": names,
		"deck": str(meta.get("deck", "")),
	}
	var entries := list()
	entries.push_front(row)
	while entries.size() > KEEP:
		var old: Dictionary = entries.pop_back()
		DirAccess.remove_absolute(DIR + "/%s.json.gz" % str(old.get("id", "")))
	_write_index(entries)
	return id


static func load_record(id: String) -> Dictionary:
	var f := FileAccess.open_compressed(DIR + "/%s.json.gz" % id, FileAccess.READ, FileAccess.COMPRESSION_GZIP)
	if f == null:
		return {}
	var v: Variant = JSON.parse_string(f.get_as_text())
	return (v as Dictionary) if typeof(v) == TYPE_DICTIONARY else {}


static func entry(id: String) -> Dictionary:
	for e: Dictionary in list():
		if str(e.get("id", "")) == id:
			return e
	return {}


static func delete(id: String) -> void:
	var entries := list().filter(func(e: Dictionary) -> bool: return str(e.get("id", "")) != id)
	DirAccess.remove_absolute(DIR + "/%s.json.gz" % id)
	_write_index(entries)


## Rebuild a recorded game's engine at its start (no action applied). JSON
## turns every number into a float; the engine's dictionaries take them as
## they come, the setup lists are converted back to what setup() expects.
static func engine_for(record: Dictionary) -> RulesEngine:
	var su: Dictionary = record.get("setup", {})
	var eng := RulesEngine.new(GameState.new(int(record.get("seed", 1))))
	var decks: Array = []
	for d: Variant in su.get("decks", []):
		var dd: Dictionary = (d as Dictionary).duplicate(true)
		for k: String in ["cards", "main"]:
			if dd.has(k):
				var ids: Array = []
				for c: Variant in dd[k]:
					ids.append(str(c))
				dd[k] = ids
		decks.append(dd)
	var names: Array = []
	for n: Variant in su.get("names", ["Player 1", "Player 2"]):
		names.append(str(n))
	var res := eng.setup(decks, names, int(su.get("first", -1)), int(su.get("chooser", -1)))
	return eng if bool(res.get("ok", false)) else null


## An action read back from JSON: numbers that are ids become ints again.
static func action_of(entry_: Dictionary) -> Dictionary:
	return _ints(entry_.get("action", {})) as Dictionary


static func _ints(v: Variant) -> Variant:
	match typeof(v):
		TYPE_FLOAT:
			return int(v) if is_equal_approx(v, roundf(v)) else v
		TYPE_DICTIONARY:
			var out := {}
			for k: Variant in v:
				out[k] = _ints(v[k])
			return out
		TYPE_ARRAY:
			var arr: Array = []
			for x: Variant in v:
				arr.append(_ints(x))
			return arr
	return v
