extends RefCounted
class_name CardData
##
## The immutable, printed face of a card (Comprehensive Rules section 2).
##
## One CardData exists per distinct printing and is shared by every copy in
## every deck in the running program. Nothing here is ever mutated during a
## game -- runtime state lives on CardInstance instead. That split is what
## makes the engine safe to run twice in the same process (host + bot preview)
## and what lets the deck editor hold the whole database in memory cheaply.
##

var id: String = ""                  # 2-13-1-1 card number, e.g. "BSS01-001"
var name: String = ""                # 2-1-1
var additional_names: PackedStringArray = []  # 2-1-2 collab names, not part of the name
var card_type: int = BSS.CardType.SPIRIT      # 2-3
var colors: Array[int] = []          # 2-4, may hold more than one entry
var spirit_types: PackedStringArray = []      # 2-5
var cost: int = 0                    # 2-6
var reduction_symbols: Array[int] = []        # 2-7, one entry per printed icon
var symbols: Array = []              # 2-8; each entry is Array[int] of colours
									# (a double-colour symbol is [RED, BLUE])
var ex_symbols: Array[int] = []      # 0.19.1: EX symbols (Japanese Standard, 2026); spent by Inherit from the trash
var levels: Array = []               # 2-10; [{level:int, core_cost:int, bp:int}]
var effects: Array = []              # parsed EffectSpec dictionaries
var text: String = ""                # raw rules text, for display and search
var flavor: String = ""              # 2-9-2-2, no rules meaning
var set_code: String = ""
var rarity: String = ""
var block: int = 0                   # 2-12-3, no gameplay meaning
var illustrator: String = ""
var image_path: String = ""          # res:// or user:// path resolved at load
var has_burst: bool = false          # 3-8-4 only burst cards may be set
var replaces: String = ""            # 0.12.0: id of the card this one supersedes (an imported official card)
var generated: bool = false          # 0.13.0: ships with the game (made by us), set by CardDB


static func from_dict(d: Dictionary) -> CardData:
	var c := CardData.new()
	c.id = str(d.get("id", ""))
	c.name = str(d.get("name", ""))
	for n in d.get("additional_names", []):
		c.additional_names.append(str(n))
	c.card_type = BSS.card_type_from_string(str(d.get("card_type", "spirit")))
	for col in d.get("colors", []):
		var ci := BSS.color_from_string(str(col))
		if ci >= 0:
			c.colors.append(ci)
	for st in d.get("spirit_types", []):
		c.spirit_types.append(str(st))
	c.cost = int(d.get("cost", 0))
	for r in d.get("reduction_symbols", []):
		var ri := BSS.color_from_string(str(r))
		if ri >= 0:
			c.reduction_symbols.append(ri)
	# Symbols may be given as "red" or as "red|blue" for a double-colour symbol.
	for s in d.get("symbols", []):
		var parts := str(s).split("|", false)
		var group: Array[int] = []
		for p in parts:
			var pi := BSS.color_from_string(p.strip_edges())
			if pi >= 0:
				group.append(pi)
		if not group.is_empty():
			c.symbols.append(group)
	for x in d.get("ex_symbols", []):
		var xi := BSS.color_from_string(str(x))
		if xi >= 0:
			c.ex_symbols.append(xi)
	for lv in d.get("levels", []):
		c.levels.append({
			"level": int(lv.get("level", 1)),
			"core_cost": int(lv.get("core_cost", 1)),
			"bp": int(lv.get("bp", 0)),
		})
	c.levels.sort_custom(func(a, b): return a["level"] < b["level"])
	c.effects = d.get("effects", []).duplicate(true)
	# Godot's JSON parser returns every number as a float, so "levels": [1, 2]
	# arrives as [1.0, 2.0] -- and [1.0, 2.0].has(1) is FALSE in Godot 4.
	# Until 0.8.0 that silently switched off every level-gated effect in the
	# game: no When Summoned, When Attacks or When Destroyed effect and no
	# nexus effect ever fired (R-037). Normalise to ints once, here.
	for e: Dictionary in c.effects:
		if e.has("levels"):
			var ints: Array = []
			for lv: Variant in e["levels"]:
				ints.append(int(lv))
			e["levels"] = ints
	c.text = str(d.get("text", ""))
	c.flavor = str(d.get("flavor", ""))
	c.set_code = str(d.get("set_code", ""))
	c.rarity = str(d.get("rarity", ""))
	c.replaces = str(d.get("replaces", ""))
	c.block = int(d.get("block", 0))
	c.illustrator = str(d.get("illustrator", ""))
	c.image_path = str(d.get("image", ""))
	for e in c.effects:
		if str(e.get("timing", "")) == "burst":
			c.has_burst = true
	return c


## A spirit copy of this nexus: "also treated as a Golem spirit with 5000 BP"
## (0.15.0, BSS05-082). Same levels, effects and symbols; every level has `bp`.
func as_spirit(family: String, bp: int) -> CardData:
	var c := CardData.new()
	c.id = id
	c.name = name
	c.additional_names = additional_names
	c.card_type = BSS.CardType.SPIRIT
	c.colors = colors.duplicate()
	c.spirit_types = spirit_types.duplicate()
	if family != "" and not c.spirit_types.has(family):
		c.spirit_types.append(family)
	c.cost = cost
	c.reduction_symbols = reduction_symbols.duplicate()
	c.ex_symbols = ex_symbols.duplicate()
	c.symbols = symbols.duplicate(true)
	for lv: Dictionary in levels:
		c.levels.append({"level": int(lv["level"]), "core_cost": int(lv["core_cost"]), "bp": bp})
	c.effects = effects
	c.text = text
	c.set_code = set_code
	c.rarity = rarity
	c.image_path = image_path
	c.has_burst = has_burst
	c.replaces = replaces
	c.generated = generated
	return c


## 2-10-3 -- highest level whose maintenance cost is met by `core_count`.
## Returns 0 when the card cannot even sustain its lowest level, which is the
## trigger for the destruction checkpoint in section 9-3.
func level_for_cores(core_count: int) -> int:
	var best := 0
	for lv in levels:
		if core_count >= int(lv["core_cost"]):
			best = max(best, int(lv["level"]))
	return best


func min_level_cost() -> int:
	if levels.is_empty():
		return 1
	return int(levels[0]["core_cost"])


## 2-11 -- printed BP at a given level. Level 0 has no printed BP.
func base_bp(level: int) -> int:
	for lv in levels:
		if int(lv["level"]) == level:
			return int(lv["bp"])
	return 0


func max_level() -> int:
	var m := 0
	for lv in levels:
		m = max(m, int(lv["level"]))
	return m


func max_bp() -> int:
	var m := 0
	for lv in levels:
		m = max(m, int(lv["bp"]))
	return m


## 2-8-3 -- symbol count drives damage (7-1-5-3-1). A double-colour symbol is
## still a single symbol for counting purposes.
func symbol_count() -> int:
	return symbols.size()


func has_color(c: int) -> bool:
	return colors.has(c)


func is_spirit() -> bool:
	return card_type == BSS.CardType.SPIRIT


func is_nexus() -> bool:
	return card_type == BSS.CardType.NEXUS


func is_magic() -> bool:
	return card_type == BSS.CardType.MAGIC


## 5-1-1-1-1 -- deck legality groups by card *name*, not by printing, so alt
## arts and collab-named reprints share a single four-copy allowance.
func deck_key() -> String:
	return name


func matches_search(query: String) -> bool:
	if query.is_empty():
		return true
	var q := query.to_lower()
	if name.to_lower().find(q) >= 0: return true
	if id.to_lower().find(q) >= 0: return true
	if text.to_lower().find(q) >= 0: return true
	# "bss02", "set 2", "rare" (0.16.0): the set code and rarity also match
	if set_code != "" and set_code.to_lower().find(q) >= 0: return true
	if q.begins_with("set ") and set_code.to_lower() == "bss0" + q.substr(4).strip_edges(): return true
	if rarity != "" and rarity.to_lower() == q: return true
	for st in spirit_types:
		if st.to_lower().find(q) >= 0: return true
	for an in additional_names:
		if an.to_lower().find(q) >= 0: return true
	return false


## Whether the printed text grants keyword `kw` at any level (0.19.1); the
## live, level-aware check is CardInstance.has_keyword.
func has_keyword(kw: int) -> bool:
	for e in effects:
		if str(e.get("timing", "")) == "keyword" and BSS.keyword_from_string(str(e.get("keyword", ""))) == kw:
			return true
	return false
