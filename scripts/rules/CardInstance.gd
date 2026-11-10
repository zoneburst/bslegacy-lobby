extends RefCounted
class_name CardInstance
##
## One physical card inside one running game.
##
## CardData is the printing; CardInstance is the copy sitting in a zone with
## cores on it. Rule 3-1-4 ("treat it as a new card" when it changes area) is
## enforced by `on_zone_change()`, which wipes every runtime modifier. If you
## are ever tempted to preserve something across a zone change, it needs an
## explicit rule citation, because the default is amnesia.
##

var uid: int = 0                       # unique within a game, stable over the wire
var data: CardData = null
var owner_id: int = 0                  # 4-2 the player who put it in their deck
var controller_id: int = 0             # may differ from owner via effects
var zone: int = BSS.Zone.DECK
var orientation: int = BSS.Orientation.REFRESHED   # 4-4
var cores: int = 0                     # regular cores currently on the card
var soul_cores: int = 0                # 4-11-3 soul cores are tracked separately
var face_up: bool = true

# --- Runtime modifiers, all cleared on zone change (3-1-4) ------------------
var bp_add: int = 0                    # 8-8-1-3-5 category (4) adjustments
var bp_constant: int = 0               # from constant effects; rebuilt by EffectSystem.refresh_constants()
var constant_keywords: Array = []      # keywords granted by constant effects (0.11.0), rebuilt the same way
var constant_kw_values: Dictionary = {} # values of those keywords ("Armor: Red / Purple / White"), 0.14.0
var constant_level: int = -1           # "treated as LV3" from a constant effect (0.14.0)
var constant_symbols: Array = []       # extra symbol groups from constant effects (0.14.0)
var suppressed_levels: Array = []      # "all nexuses lose their LV1 effects" (0.14.0)
var constant_types: Array = []         # families added by constant effects / turn rules (0.15.0)
var constant_base_bp: Dictionary = {}  # level -> printed BP replaced by a constant effect (0.15.0)
var constant_suppressed: bool = false  # "loses all its effects" from a constant rule (0.15.0)
var granted_effects: Array = []        # effects given by another card ("gains: When This Spirit Blocks ...")
var bp_set: int = -1                   # 8-8-1-3-4 category (3) "BP becomes N"
var bp_redefine: Dictionary = {}       # 8-8-1-3-3 category (2) level->bp overrides
var level_override: int = -1           # 8-8-1-3-2 category (1) "treated as LVn"
var granted_keywords: Array = []       # [{keyword:int, value:Variant, source:int}]
var granted_symbols: Array = []        # extra symbol groups, e.g. from Link
var symbol_override: Array = []        # "treated as having two red symbols" this turn (0.15.0, BSS03-122)
var kw_cond_ok: Array = []             # keywords whose printed condition holds now (0.15.0, BSS03-070);
									   # rebuilt by EffectSystem.refresh_constants
var flags: Dictionary = {}             # ad-hoc per-turn markers, see below
var constant_cost: int = -1            # "treat this spirit as though it costs 5" (0.15.0, BSS06-054)
# "That nexus is also treated as a Golem spirit with 5000 BP this turn" (0.15.0,
# BSS05-082): `data` is a spirit copy meanwhile and this is the printed nexus.
var orig_data: CardData = null

# --- Battle bookkeeping ----------------------------------------------------
var linked_to: int = -1                # 11-18 uid of the spirit this one lends to
var linked_from: int = -1              # uid of the (first) spirit lending to this one
## The spirits lending to this one (11-18-1, 0.17.1). Their BP and symbols are
## read LIVE while they stay linked on the field, so a change to the lender's
## BP shows at once and a lender that leaves takes its bonus with it (11-18-4).
## Before 0.17.1 the BP was copied once when the link was made.
var link_lenders: Array = []
var summoned_this_turn: bool = false
var raid_uses_this_turn: int = 0       # 11-12-1 per-turn Raid budget


func _init(p_data: CardData = null, p_uid: int = 0, p_owner: int = 0) -> void:
	data = p_data
	uid = p_uid
	owner_id = p_owner
	controller_id = p_owner


func total_cores() -> int:
	return cores + soul_cores


## 2-10-3 with 8-8-1-3-2 layered on top.
func current_level() -> int:
	if level_override > 0:
		return level_override
	if constant_level > 0:
		return constant_level
	if data == null:
		return 0
	return data.level_for_cores(total_cores())


## 8-8-1-3 -- BP is resolved in four ordered categories. We evaluate them in
## the printed order (1) level, (2) redefine, (3) assign, (4) add/subtract so
## that "this spirit's BP becomes 1000" always beats "+2000 BP" applied before
## it, and always loses to "+2000 BP" applied after it.
func current_bp() -> int:
	if data == null or not data.is_spirit():
		return 0
	var lv := current_level()                          # (1)
	var bp := data.base_bp(lv)
	if constant_base_bp.has(lv):                       # (2) "their LV1 BP is 4000" (0.15.0)
		bp = int(constant_base_bp[lv])
	if bp_redefine.has(lv):                            # (2)
		bp = int(bp_redefine[lv])
	if bp_set >= 0:                                    # (3)
		bp = bp_set
	bp += bp_add + bp_constant                         # (4)
	bp += link_bp()                                    # 11-18-1
	return max(bp, 0) if bp >= 0 else bp   # 9-4-2 needs the true sign, see below


## 9-4-2 destroys a spirit whose BP is zero or less, so the checkpoint needs
## the unclamped value. current_bp() clamps for display; this does not.
func raw_bp() -> int:
	if data == null or not data.is_spirit():
		return 1
	var lv := current_level()
	var bp := data.base_bp(lv)
	if constant_base_bp.has(lv):
		bp = int(constant_base_bp[lv])
	if bp_redefine.has(lv):
		bp = int(bp_redefine[lv])
	if bp_set >= 0:
		bp = bp_set
	bp += bp_add + bp_constant
	bp += link_bp()
	return bp


## The lenders still linked to this spirit on the field (11-18-4).
func live_lenders() -> Array:
	var out: Array = []
	for l: Variant in link_lenders:
		var lc := l as CardInstance
		if lc != null and lc.zone == BSS.Zone.FIELD and lc.linked_to == uid:
			out.append(lc)
	return out


## BP lent by linked spirits: their current BP, now (11-18-1). A lender never
## receives a link itself (11-18-3), so this cannot loop.
func link_bp() -> int:
	var total := 0
	for l: CardInstance in live_lenders():
		total += l.current_bp()
	return total


## 7-1-5-3-1 -- damage equals the attacking spirit's symbol count, including
## symbols lent by a linked spirit (11-18-1).
func symbol_groups() -> Array:
	var out: Array = []
	if not symbol_override.is_empty():
		# "treated as having two red symbols" replaces its own symbols (0.15.0)
		out.append_array(symbol_override)
		out.append_array(granted_symbols)
		for l: CardInstance in live_lenders():
			out.append_array(l.symbol_groups())
		return out
	if data != null:
		out.append_array(data.symbols)
	out.append_array(granted_symbols)
	out.append_array(constant_symbols)
	for l2: CardInstance in live_lenders():              # symbols lent by Link (11-18-1)
		out.append_array(l2.symbol_groups())
	return out


## The cost every check reads (0.15.0). "While this card is in the trash, it is
## treated as costing 5" (BSS04-025): a constant cost_in_trash directive,
## read off the card itself because it works from the trash.
func effective_cost() -> int:
	if data == null:
		return 0
	if zone == BSS.Zone.FIELD and constant_cost >= 0:
		return constant_cost                           # set_cost (0.15.0, BSS06-054)
	if zone == BSS.Zone.TRASH:
		for e: Dictionary in data.effects:
			for d: Dictionary in e.get("directives", []):
				if str(d.get("op", "")) == "cost_in_trash":
					return int(d.get("cost", data.cost))
	return data.cost


func symbol_count() -> int:
	return symbol_groups().size()


## 10-13-1 -- on the field, a keyword whose level condition is unmet does not
## count. In any other zone (10-13-2) a printed keyword counts at any level.
func has_keyword(kw: int) -> bool:
	for g in granted_keywords:
		if int(g["keyword"]) == kw:
			return true
	if constant_keywords.has(kw):
		return true
	if data == null:
		return false
	if zone == BSS.Zone.FIELD and effects_suppressed():
		return false                                   # "loses its effects" (0.15.0)
	for e in data.effects:
		if not _effect_grants(e, kw):
			continue
		if zone != BSS.Zone.FIELD:
			return true                                # 10-13-2
		if _level_active(e):
			return true                                # 10-13-1
	return false


func keyword_value(kw: int) -> Variant:
	# Several keywords carry a number: Gale: N, Crush: +N, Raid: N, Link: cond.
	# 11-10-3 / 11-11-4 / 11-12-3 all say "only the largest applies", so we take
	# the maximum across printed and granted sources.
	var best: Variant = null
	for g in granted_keywords:
		if int(g["keyword"]) == kw:
			best = _max_kw(best, g.get("value", null))
	if constant_kw_values.has(kw):
		best = _max_kw(best, constant_kw_values[kw])
	if data != null:
		for e in data.effects:
			if _effect_grants(e, kw) and (zone != BSS.Zone.FIELD or _level_active(e)):
				best = _max_kw(best, e.get("keyword_value", null))
	return best


func _max_kw(a: Variant, b: Variant) -> Variant:
	if a == null: return b
	if b == null: return a
	if typeof(a) == TYPE_INT and typeof(b) == TYPE_INT:
		return max(a, b)
	# Two Armor keywords protect against the colours of both (0.15.0, BSS06-052)
	if typeof(a) == TYPE_ARRAY and typeof(b) == TYPE_ARRAY:
		var u: Array = (a as Array).duplicate()
		for x: Variant in b:
			var have := false
			for y: Variant in u:
				if str(y).to_lower() == str(x).to_lower():
					have = true
			if not have:
				u.append(x)
		return u
	return a


## True when this card has an effect at `timing` -- "a spirit with a When
## Blocks effect" (0.11.0). Printed effects only, at any level.
## A family printed on the card or added by an effect (0.15.0).
func has_family(name: String) -> bool:
	var want := name.to_lower()
	if data != null:
		for st in data.spirit_types:
			if st.to_lower() == want:
				return true
	for st2: Variant in constant_types:
		if str(st2).to_lower() == want:
			return true
	return false


func effects_suppressed() -> bool:
	return constant_suppressed or bool(flags.get("no_effects", false))


func has_timing(timing: String) -> bool:
	if data == null:
		return false
	for g: Dictionary in granted_effects:
		if str(g.get("timing", "")) == timing:
			return true
	for e: Dictionary in data.effects:
		if str(e.get("timing", "")) == timing:
			return true
	return false


func _effect_grants(e: Dictionary, kw: int) -> bool:
	var name := str(e.get("keyword", ""))
	if name.is_empty():
		return false
	if BSS.keyword_from_string(name) != kw:
		return false
	# a keyword printed with a condition ("if you control a spirit with Gale,
	# this card gains Swift in your hand") counts only while it holds (0.15.0)
	if e.has("condition") and not kw_cond_ok.has(kw):
		return false
	return true


func _level_active(e: Dictionary) -> bool:
	var lv := current_level()
	var allowed: Array = e.get("levels", [])
	if allowed.is_empty():
		return true
	for sl: Variant in suppressed_levels:
		for a0: Variant in allowed:
			if int(a0) == int(sl):
				return false                           # "lose their LV1 effects" (0.14.0)
	# Compared as ints: a float 1.0 never matches int 1 in Array.has() (R-037).
	for a: Variant in allowed:
		if int(a) == lv:
			return true
	return false


## Effects only apply at the levels printed beside them (2-10-2).
func active_effects() -> Array:
	var out: Array = []
	if data == null:
		return out
	if zone == BSS.Zone.FIELD and effects_suppressed():
		return out                                     # "loses its effects" (0.15.0)
	for e in data.effects:
		if zone == BSS.Zone.FIELD and not _level_active(e):
			continue
		out.append(e)
	if zone == BSS.Zone.FIELD:
		out.append_array(granted_effects)              # given by another card (0.15.0)
	return out


func is_refreshed() -> bool:
	return orientation == BSS.Orientation.REFRESHED


func is_exhausted() -> bool:
	return orientation == BSS.Orientation.EXHAUSTED


## 3-1-4 -- a card that changes area is a brand new object as far as effects
## are concerned. Cores are handled by the caller because where they go depends
## on why the card moved (3-5-5 vs 10-1-3-4).
func on_zone_change(new_zone: int) -> void:
	zone = new_zone
	if orig_data != null:
		data = orig_data                               # a nexus treated as a spirit (0.15.0)
		orig_data = null
	constant_cost = -1
	orientation = BSS.Orientation.REFRESHED
	bp_add = 0
	bp_constant = 0
	constant_keywords = []
	constant_kw_values = {}
	constant_level = -1
	constant_symbols = []
	suppressed_levels = []
	constant_types = []
	constant_base_bp = {}
	constant_suppressed = false
	granted_effects = []
	bp_set = -1
	bp_redefine.clear()
	level_override = -1
	granted_keywords.clear()
	granted_symbols.clear()
	symbol_override = []
	kw_cond_ok = []
	flags.clear()
	linked_to = -1
	linked_from = -1
	link_lenders = []
	summoned_this_turn = false
	raid_uses_this_turn = 0
	controller_id = owner_id
	if new_zone != BSS.Zone.FIELD:
		cores = 0
		soul_cores = 0


## Serialised form sent to clients. `reveal` is false for cards in an opponent's
## private area (3-1-3) -- the client is told a card exists and nothing else,
## which is what makes hidden information actually hidden rather than merely
## not drawn.
func to_net(reveal: bool) -> Dictionary:
	var d := {
		"uid": uid,
		"zone": zone,
		"owner": owner_id,
		"controller": controller_id,
	}
	if not reveal:
		d["hidden"] = true
		return d
	d["card_id"] = data.id if data else ""
	d["orient"] = orientation
	d["cores"] = cores
	d["soul"] = soul_cores
	d["level"] = current_level()
	d["bp"] = current_bp()
	d["symbols"] = symbol_count()
	return d
