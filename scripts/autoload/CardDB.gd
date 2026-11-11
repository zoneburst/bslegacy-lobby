extends Node
##
## The card database.
##
## Loads every JSON file in res://data/cards/ (and then user://data/cards/, so
## a new set can be added without rebuilding the game), parses them into
## CardData objects, and builds the indexes the deck editor's filters need.
##
## Data provenance: run tools/scrape_bssdb.py against https://bssdb.dev to
## regenerate these files. Card text and artwork are Bandai's; the scraper
## writes text into JSON and downloads art into user:// rather than into the
## repository, so the game ships without redistributing anyone's assets. See
## docs/ASSET_REPLACEMENT_GUIDE.md, section "Card artwork and the law".
##

const RES_DIR := "res://data/cards"
const USER_DIR := "user://data/cards"
## Cards packed into this copy of the game from a spreadsheet (0.23.0,
## tools/bundle_cards.sh): everyone who opens it has them, with their art in
## BUNDLE_ART_DIR. They count as imported cards, not ours.
const BUNDLE_DIR := "res://data/bundle/cards"
const BUNDLE_ART_DIR := "res://data/bundle/art"

var cards: Dictionary = {}            # card id -> CardData
var by_name: Dictionary = {}          # card name -> Array[CardData]
var all_ids: PackedStringArray = []

# Filter facets, populated at load so the editor never rescans.
var set_codes: PackedStringArray = []
var spirit_types: PackedStringArray = []
var rarities: PackedStringArray = []
var keywords_present: PackedStringArray = []

# 0.12.0-0.18.1: an imported official card superseded one of ours
# ("replaces"): ours left the card pool and every deck got the official card.
# Since 0.18.2 nothing is replaced (R-107): an imported official card is a card
# of its own next to ours, so our cards -- and their art -- stay findable.
# replaced_by stays (empty) so resolve() and is_replaced() keep working.
var replaced_by: Dictionary = {}

var _art_cache: Dictionary = {}
var _placeholder_ids: Dictionary = {}

signal database_loaded(count: int)


func _ready() -> void:
	load_all()


func load_all() -> void:
	cards.clear()
	by_name.clear()
	all_ids = PackedStringArray()
	var loaded := 0
	loaded += _load_dir(RES_DIR)
	loaded += _load_dir(BUNDLE_DIR)
	loaded += _load_dir(USER_DIR)
	var real := false
	for id in all_ids:
		if not (cards[id] as CardData).generated:
			real = true
			break
	GameConfig.real_cards_present = real
	_build_replacements()
	_build_facets()
	Log.info("CardDB: loaded %d cards" % loaded)
	database_loaded.emit(loaded)


func _load_dir(dir_path: String) -> int:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return 0
	var n := 0
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.get_extension().to_lower() == "json":
			n += _load_file(dir_path.path_join(fname))
		fname = dir.get_next()
	dir.list_dir_end()
	return n


func _load_file(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		Log.warn("CardDB: cannot open %s" % path)
		return 0
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed == null:
		Log.error("CardDB: %s is not valid JSON" % path)
		return 0
	# Accept either a bare array of cards or {"cards":[...]} with metadata.
	var list: Array = parsed if typeof(parsed) == TYPE_ARRAY else parsed.get("cards", [])
	var n := 0
	for entry in list:
		var cd := CardData.from_dict(entry)
		if cd.id.is_empty():
			continue
		# Every card file inside the game is ours; cards you add (imported
		# or scraped) live in user:// (0.13.0).
		cd.generated = path.begins_with("res://") and not path.begins_with(BUNDLE_DIR)
		# A card loaded again under the same id (0.23.1: the bundled sheet, then
		# the player importing the same sheet) replaces the earlier one; it is
		# not listed twice, or the deck editor and AI decks counted it twice.
		if cards.has(cd.id):
			var old: CardData = cards[cd.id]
			if by_name.has(old.name):
				(by_name[old.name] as Array).erase(old)
		else:
			all_ids.append(cd.id)
		cards[cd.id] = cd
		if not by_name.has(cd.name):
			by_name[cd.name] = []
		by_name[cd.name].append(cd)
		n += 1
	return n


func _build_replacements() -> void:
	# 0.18.2 (R-107): an imported card's "replaces" (written by imports made
	# before 0.18.2) no longer takes our card out of the game.
	replaced_by.clear()


## The id a card is played as: itself, or the card that replaces it.
func resolve(id: String) -> String:
	var seen := 0
	while replaced_by.has(id) and seen < 8:
		id = str(replaced_by[id])
		seen += 1
	return id


func is_replaced(id: String) -> bool:
	return replaced_by.has(id)


## True when the "hide AI-generated cards" setting hides this card. A card we
## made that an imported official card replaces is shown as that official
## card, so it is not hidden (0.13.0).
func is_hidden(id: String) -> bool:
	if not GameConfig.hide_generated_cards:
		return false
	var cd: CardData = get_card(id)
	return cd == null or cd.generated


func _build_facets() -> void:
	var sets := {}
	var types := {}
	var rars := {}
	var kws := {}
	for id in cards:
		if replaced_by.has(id):
			continue
		var cd: CardData = cards[id]
		if not cd.set_code.is_empty(): sets[cd.set_code] = true
		if not cd.rarity.is_empty(): rars[cd.rarity] = true
		for st in cd.spirit_types: types[st] = true
		for e in cd.effects:
			var k := str(e.get("keyword", ""))
			if not k.is_empty(): kws[k] = true
	set_codes = PackedStringArray(sets.keys()); set_codes.sort()
	spirit_types = PackedStringArray(types.keys()); spirit_types.sort()
	rarities = PackedStringArray(rars.keys()); rarities.sort()
	keywords_present = PackedStringArray(kws.keys()); keywords_present.sort()


func get_card(id: String) -> CardData:
	return cards.get(resolve(id))


## Every loaded card, in load order (used by the effect tests to find cards by
## what they do rather than by id).
func all_cards() -> Array:
	var out: Array = []
	for id in all_ids:
		if not replaced_by.has(id):
			out.append(cards[id])
	return out


func count() -> int:
	return cards.size()


## The deck editor's search. `filters` keys, all optional:
##   text, colors:Array[int], card_types:Array[int], cost_min, cost_max,
##   bp_min, bp_max, spirit_type, keyword, set_code, rarity, hide_alts
func search(filters: Dictionary) -> Array:
	var out: Array = []
	var text := str(filters.get("text", ""))
	var colors: Array = filters.get("colors", [])
	var types: Array = []
	# card types may be given as ints or as names ("spirit"); the editor's
	# chips pass names (0.16.5, R-080)
	for t0: Variant in filters.get("card_types", []):
		types.append(BSS.card_type_from_string(str(t0)) if typeof(t0) == TYPE_STRING else int(t0))
	var seen_names := {}
	for id in all_ids:
		if replaced_by.has(id):
			continue                                   # superseded by an imported card
		var cd: CardData = cards[id]
		if GameConfig.hide_generated_cards and cd.generated:
			continue                                   # the "hide AI-generated cards" setting
		if not cd.matches_search(text): continue
		if not colors.is_empty():
			var hit := false
			for c in colors:
				if cd.has_color(int(c)): hit = true
			if not hit: continue
		if not types.is_empty() and not types.has(cd.card_type): continue
		if filters.has("cost_min") and cd.cost < int(filters["cost_min"]): continue
		if filters.has("cost_max") and cd.cost > int(filters["cost_max"]): continue
		if filters.has("bp_min") and cd.max_bp() < int(filters["bp_min"]): continue
		if filters.has("bp_max") and cd.max_bp() > int(filters["bp_max"]): continue
		if filters.has("spirit_type"):
			var want := str(filters["spirit_type"]).to_lower()
			var found := false
			for st in cd.spirit_types:
				if st.to_lower() == want: found = true
			if not found: continue
		if filters.has("keyword"):
			var kw := str(filters["keyword"]).to_lower()
			var kfound := false
			for e in cd.effects:
				if str(e.get("keyword", "")).to_lower() == kw: kfound = true
			if not kfound: continue
		if filters.has("set_code") and cd.set_code != str(filters["set_code"]): continue
		if filters.has("rarity") and cd.rarity != str(filters["rarity"]): continue
		# Deck editor filters (0.16.0): a trigger header ("When Summoned",
		# "When Destroyed", "When This Spirit Attacks") -- the card's printed
		# condition, matched on the header text or its timing name.
		if filters.has("timing"):
			var want_t := str(filters["timing"])
			var tfound := false
			for e2 in cd.effects:
				if timing_label(e2) == want_t or str(e2.get("timing", "")) == want_t:
					tfound = true
			if not tfound: continue
		if bool(filters.get("hide_alts", false)):
			if seen_names.has(cd.name): continue
			seen_names[cd.name] = true
		out.append(cd)
	var sort_key := str(filters.get("sort", "id"))
	match sort_key:
		"name": out.sort_custom(func(a, b): return a.name < b.name)
		"cost": out.sort_custom(func(a, b): return a.cost < b.cost or (a.cost == b.cost and a.id < b.id))
		"bp": out.sort_custom(func(a, b): return a.max_bp() > b.max_bp() or (a.max_bp() == b.max_bp() and a.id < b.id))
		# 0.16.0 sorts
		"type": out.sort_custom(func(a, b): return a.card_type < b.card_type or (a.card_type == b.card_type and a.id < b.id))
		"color": out.sort_custom(func(a, b): return _color_key(a) < _color_key(b) or (_color_key(a) == _color_key(b) and a.id < b.id))
		"rarity": out.sort_custom(func(a, b): return rarity_rank(a.rarity) > rarity_rank(b.rarity) \
				or (rarity_rank(a.rarity) == rarity_rank(b.rarity) and a.id < b.id))
		"set": out.sort_custom(func(a, b): return a.set_code < b.set_code or (a.set_code == b.set_code and a.id < b.id))
		"spirit_type": out.sort_custom(func(a, b): return _family_key(a) < _family_key(b) or (_family_key(a) == _family_key(b) and a.id < b.id))
		# 0.16.5: the editor's default -- spirits, then nexuses, then magic;
		# within a type the newest set first; within a set by card number
		"type_set": out.sort_custom(func(a, b): return _type_set_key(a) < _type_set_key(b))
		_: out.sort_custom(func(a, b): return a.id < b.id)
	return out


## Newest set first: BSS06 ... BSS01, then PR, then ST07 ... ST01, then our
## own sets. Returned so that a smaller key sorts first.
static func set_rank(code: String) -> int:
	var c := code.to_upper()
	if c.begins_with("BSS"):
		return 100 - int(c.substr(3))
	if c.begins_with("PR"):
		return 150
	if c.begins_with("ST"):
		return 200 - int(c.substr(2))
	return 300


static func _type_set_key(cd: CardData) -> Array:
	return [cd.card_type, set_rank(cd.set_code if cd.set_code != "" else cd.id.get_slice("-", 0)), cd.id]


static func _color_key(cd: CardData) -> int:
	return cd.colors[0] if not cd.colors.is_empty() else 99


static func _family_key(cd: CardData) -> String:
	return cd.spirit_types[0].to_lower() if not cd.spirit_types.is_empty() else "~"


## The condition an effect activates on, as the card prints it: "When
## Summoned", "When Destroyed", "When This Spirit Attacks"... One label per
## timing, so "During Your Attack Step: when this spirit attacks" still files
## under "When This Spirit Attacks". Keywords and magic effects have none.
const TIMING_LABELS := {
	"on_summon": "When Summoned", "on_place": "When Placed", "on_attack": "When This Spirit Attacks",
	"on_block": "When This Spirit Blocks", "when_destroyed": "When Destroyed",
	"when_destroyed_by_opponent": "When Destroyed By Opponent", "battle_end": "When Battle Ends",
	"battle_destroy": "When Destroys A Spirit In Battle", "dealt_damage": "When Reduces Life",
	"life_reduced": "When Life Is Reduced", "life_gained": "When Life Increases",
	"burst": "Burst", "start_of_step": "At The Start Of A Step", "end_of_turn": "At The End Of Turn",
	"end_of_opponent_turn": "At The End Of Opponent's Turn", "returned_to_hand": "When Returned To Hand",
	"magic_used": "When A Magic Card Is Used", "extra_draw": "When A Card Is Drawn",
	"spirit_exhausted": "When A Spirit Is Exhausted", "spirit_refreshed": "When A Spirit Is Refreshed",
	"on_link": "When This Spirit Links", "became_linked": "When Linked", "activated": "Flash (Activated)",
	"substitute_destruction": "Instead Of Being Destroyed", "blocked": "When Blocked",
	"block_declared": "When A Spirit Blocks", "cores_zeroed": "When Cores Are Removed",
	"deck_milled": "When Cards Are Discarded From Deck", "discarded_from_deck": "When Discarded From Deck",
	"card_discarded": "When A Card Is Discarded", "core_to_reserve": "When Cores Enter Reserve",
	"cores_placed": "When Cores Are Placed", "added_to_hand": "When Cards Are Added To Hand",
	"used_for_ascend": "When Used For Ascend", "bp_comparison_won": "When BP Is Compared",
}


static func timing_label(e: Dictionary) -> String:
	var t := str(e.get("timing", ""))
	if str(e.get("kind", "")) == "constant":
		return "Constant (Always)"
	if t == "" or t == "keyword" or str(e.get("kind", "")) == "magic":
		return ""
	return str(TIMING_LABELS.get(t, t.capitalize()))


## Rarity order for sorting: the rarest first. Unknown rarities sort last.
static func rarity_rank(r: String) -> int:
	var s := r.to_lower().strip_edges()
	if s.begins_with("x") or s.contains("xr"): return 5
	if s.begins_with("secret") or s.begins_with("sr"): return 6
	if s.begins_with("promo") or s.begins_with("pr"): return 4
	if s.begins_with("r"): return 3
	if s.begins_with("u"): return 2
	if s.begins_with("c"): return 1
	return 0


## Distinct values for the deck editor's dropdowns (0.16.0): every family,
## keyword, trigger header, rarity and set seen on the playable cards, sorted.
func facet(kind: String) -> Array:
	var seen := {}
	for id in all_ids:
		if replaced_by.has(id):
			continue
		var cd: CardData = cards[id]
		if GameConfig.hide_generated_cards and cd.generated:
			continue
		match kind:
			"spirit_type":
				for st in cd.spirit_types:
					if st != "": seen[st] = true
			"keyword":
				for e in cd.effects:
					var k := str(e.get("keyword", ""))
					if k != "": seen[k] = true
			"timing":
				for e2 in cd.effects:
					var h := timing_label(e2)
					if h != "": seen[h] = true
			"rarity":
				if cd.rarity != "": seen[cd.rarity] = true
			"set":
				if cd.set_code != "": seen[cd.set_code] = true
	var out: Array = seen.keys()
	if kind == "rarity":
		out.sort_custom(func(a, b): return rarity_rank(a) > rarity_rank(b))
	else:
		out.sort_custom(func(a, b): return str(a).to_lower() < str(b).to_lower())
	return out


# ---------------------------------------------------------------------------
# Artwork
# ---------------------------------------------------------------------------

## Resolve a card's texture. Search order, first hit wins:
##   1. user://assets/cards/<id>.png   (or the configured override directory)
##   2. res://assets/cards/<id>.png    (shipped, usually empty)
##   3. a generated placeholder that prints the card id
##
## Textures are cached because a deck editor page can request 60 of them at
## once and decoding a PNG per frame is visible as a stutter.
func get_card_texture(id: String) -> Texture2D:
	return _texture_for(resolve(id))


## Just the artwork of a card face, for strips and banners (0.18.0): the art
## fills the top of every face, from about 1.5% to 53% of its height, inside
## the frame (5.7% each side). Cropping the whole face instead shows the name
## banner and the text box.
const ART_REGION := Rect2(0.057, 0.015, 0.886, 0.515)


func get_card_art_texture(id: String) -> Texture2D:
	var full := get_card_texture(id)
	if full == null:
		return null
	var w := float(full.get_width())
	var h := float(full.get_height())
	var atlas := AtlasTexture.new()
	atlas.atlas = full
	atlas.region = Rect2(w * ART_REGION.position.x, h * ART_REGION.position.y,
			w * ART_REGION.size.x, h * ART_REGION.size.y)
	return atlas


func _texture_for(id: String) -> Texture2D:
	if _art_cache.has(id):
		return _art_cache[id]
	var tex: Texture2D = null
	for ext in [".png", ".jpg", ".jpeg", ".webp"]:
		var upath := "%s/%s%s" % [GameConfig.card_art_override_dir, id, ext]
		if FileAccess.file_exists(upath):
			var img := Image.new()
			if img.load(upath) == OK:
				img.generate_mipmaps()
				tex = ImageTexture.create_from_image(img)
				break
	if tex == null:
		for ext in [".png", ".jpg", ".jpeg", ".webp"]:
			var bpath := "%s/%s%s" % [BUNDLE_ART_DIR, id, ext]
			if ResourceLoader.exists(bpath):
				tex = load(bpath)
				break
	if tex == null:
		for ext in [".png", ".jpg", ".webp"]:
			var rpath := "res://assets/cards/%s%s" % [id, ext]
			if ResourceLoader.exists(rpath):
				tex = load(rpath)
				break
			# The image exists but Godot has not imported it (no .import file
			# yet). Before 0.6.0 that fell straight through to the flat colour
			# swatch -- the red "Pyre Golem / 1 cost" box (R-022). Reading the
			# raw file works in the editor and in any run from source.
			if FileAccess.file_exists(rpath):
				var raw := Image.load_from_file(rpath)
				if raw != null and not raw.is_empty():
					raw.generate_mipmaps()
					tex = ImageTexture.create_from_image(raw)
					break
	# 0.12.0-0.18.1: an imported card with no image of its own borrowed the
	# face of the card it replaced. Our card now stays in the game with that
	# face, so the official card shows a plain card with its own name (R-107).
	if tex == null:
		tex = _make_placeholder(id)
		_placeholder_ids[id] = true
	_art_cache[id] = tex
	return tex


## True when the card has real art (a file), false when it is showing the
## generated colour swatch. CardWidget only prints the card's name over the
## swatch -- a real face already carries its own name.
func has_art(id: String) -> bool:
	id = resolve(id)
	_texture_for(id)
	return not _placeholder_ids.has(id)


func clear_art_cache() -> void:
	_art_cache.clear()
	_placeholder_ids.clear()


func _make_placeholder(id: String) -> Texture2D:
	# A flat card-shaped swatch tinted by the card's first colour. Enough to
	# tell cards apart during development without any art at all.
	var cd: CardData = cards.get(id)
	var base := Color(0.18, 0.18, 0.22)
	if cd != null and not cd.colors.is_empty():
		base = [Color(0.65, 0.18, 0.18), Color(0.42, 0.20, 0.55), Color(0.85, 0.85, 0.80),
			Color(0.80, 0.70, 0.20), Color(0.20, 0.55, 0.28), Color(0.18, 0.35, 0.70)][cd.colors[0]]
	var img := Image.create(300, 420, false, Image.FORMAT_RGBA8)
	img.fill(base)
	for x in range(6, 294):
		for y in range(6, 12):
			img.set_pixel(x, y, base.lightened(0.35))
	return ImageTexture.create_from_image(img)
