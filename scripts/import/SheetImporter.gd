extends RefCounted
class_name SheetImporter
##
## Import official cards from a spreadsheet (0.12.0).
##
## Reads an Excel workbook (.xlsx) straight from disk -- no Excel, no Python --
## and turns each row into a playable card in your own user folder:
##
##   user://data/cards/imported_<sheet>.json   the cards
##   <card art folder>/<code>.<jpg|png>        the card image from that row
##   user://decks/imp_<deck>.json              one deck per "Starter Deck" value
##   user://imports/<sheet>.json               what was written, for removal
##
## Nothing is written inside the game folder, so a shared copy of the game
## never contains the imported cards.
##
## WHAT A ROW NEEDS
## Columns are found by their header (case does not matter):
##   card code / code / card number     required, e.g. ST01-001
##   card name / name                   required
##   card type / type                   optional, checked against the rules
##   rarity                             optional (X Rare, Rare, Uncommon, Common)
##   copies in deck / copies / qty      optional, builds the decks
##   starter deck / deck                optional, builds the decks
## A picture placed over a row (Insert > Picture > Place in/over cell) is that
## card's image.
##
## WHERE THE RULES COME FROM
## A spreadsheet lists cards; it does not say what they do. Each code is
## matched to rules the game already has:
##   * a card in data/cards/*.json whose "based_on" is that code -- our own
##     version of it. The imported card takes its rules from ours and is a
##     card of its own; ours stays in the game, with its art (0.18.2, R-107:
##     until then the official card replaced ours everywhere). The link is
##     kept as "our_version".
##   * otherwise data/import/rules_*.json (mechanics written for sets we have
##     no version of, e.g. ST07).
## A code with no rules is skipped and reported, never imported half-working.

const CARD_DIR := "user://data/cards"
const DECK_DIR := "user://decks"
const MANIFEST_DIR := "user://imports"
const RULES_DIR := "res://data/import"
const OURS_DIR := "res://data/cards"
## A card code: letters (and set digits), a dash, a number (0.15.0).
static var _CODE_RE := RegEx.create_from_string("^[A-Za-z]{1,6}[0-9]{0,3}-[0-9]{1,4}[A-Za-z0-9_]*$")

const RARITY := {"x rare": "X", "x": "X", "rare": "R", "r": "R", "uncommon": "U", "uc": "U", "u": "U",
		"common": "C", "c": "C"}


## Import `path`. Returns a report:
## {ok, sheet, imported, ours, decks:Array, images, skipped:Array, warnings:Array, error}
static func import_xlsx(path: String) -> Dictionary:
	var report := {"ok": false, "sheet": path.get_file().get_basename(), "imported": 0, "ours": 0,
			"decks": [], "images": 0, "skipped": [], "warnings": [], "error": ""}
	var zip := ZIPReader.new()
	if zip.open(path) != OK:
		report["error"] = "Could not open %s as an Excel workbook (.xlsx)." % path.get_file()
		return report
	# 0.14.0: every sheet with a card-code column is read (a workbook can
	# hold the starter decks and each booster set on its own sheet).
	var books := _read_book(zip)
	zip.close()
	if books.is_empty():
		report["error"] = "No sheet in %s has a 'Card Code' column." % path.get_file()
		return report
	var entries: Array = []
	for book: Dictionary in books:
		for row: Dictionary in book["rows"]:
			entries.append({"row": row, "cols": book["cols"], "images": book["images"]})
	report["skipped_by_set"] = {}

	var ours := _rules_from_our_cards()                # code -> card dict (ours)
	var extra := _rules_from_import_files()            # code -> rules dict

	var tag := _slug(str(report["sheet"]))
	var out_cards: Array = []
	var written_images: Array = []
	var decks := {}                                    # deck label -> Array[String] ids
	var art_dir := GameConfig.card_art_override_dir
	DirAccess.make_dir_recursive_absolute(art_dir)
	for ent: Dictionary in entries:
		var row: Dictionary = ent["row"]
		var cols: Dictionary = ent["cols"]
		var images: Dictionary = ent["images"]         # sheet row number -> {bytes, ext}
		var code := str(row.get(cols["code"], "")).strip_edges()
		if code.is_empty():
			continue
		# Notes, totals and source lines under a card list are not cards
		# (0.15.0): only "ST01-001", "BSS06-116", "PR-068"-style codes are read.
		if not _CODE_RE.search(code):
			continue
		var name := str(row.get(cols.get("name", ""), "")).strip_edges()
		var base: Dictionary = {}
		var our_version := ""
		if ours.has(code):
			base = (ours[code] as Dictionary).duplicate(true)
			our_version = str(base.get("id", ""))
		elif extra.has(code):
			base = (extra[code] as Dictionary).duplicate(true)
		else:
			(report["skipped"] as Array).append("%s %s: the game has no rules for this card yet" % [code, name])
			var sbs: Dictionary = report["skipped_by_set"]
			var set_code := code.get_slice("-", 0)
			sbs[set_code] = int(sbs.get(set_code, 0)) + 1
			continue
		var c: Dictionary = base
		c["id"] = code
		c["name"] = name if not name.is_empty() else str(base.get("name", code))
		c["set_code"] = code.get_slice("-", 0)
		c["based_on"] = code
		c["source"] = "imported"
		c.erase("replaces")
		c["our_version"] = our_version                 # informational only (0.18.2)
		if cols.has("rarity"):
			var r := str(row.get(cols["rarity"], "")).strip_edges().to_lower()
			if RARITY.has(r):
				c["rarity"] = RARITY[r]
		if cols.has("type"):
			var t := str(row.get(cols["type"], "")).strip_edges().to_lower()
			if not t.is_empty() and t != str(c.get("card_type", "")):
				(report["warnings"] as Array).append("%s: the sheet says %s, the rules say %s; the rules were used"
						% [code, t, c.get("card_type", "")])
		out_cards.append(c)
		report["imported"] = int(report["imported"]) + 1
		if not our_version.is_empty():
			report["ours"] = int(report["ours"]) + 1
		# the image placed over this row
		var rn := int(row.get("_row", -1))
		if images.has(rn):
			var img: Dictionary = images[rn]
			for old_ext in ["png", "jpg", "jpeg", "webp"]:
				var old := art_dir.path_join("%s.%s" % [code, old_ext])
				if FileAccess.file_exists(old):
					DirAccess.remove_absolute(old)
			var ipath := art_dir.path_join("%s.%s" % [code, img["ext"]])
			var f := FileAccess.open(ipath, FileAccess.WRITE)
			if f != null:
				f.store_buffer(img["bytes"])
				f.close()
				written_images.append(ipath)
				report["images"] = int(report["images"]) + 1
		else:
			(report["warnings"] as Array).append("%s: no picture over this row; it shows a plain card" % code)
		# decks
		if cols.has("deck"):
			var deck := str(row.get(cols["deck"], "")).strip_edges()
			var copies := 1
			if cols.has("copies"):
				copies = maxi(0, int(str(row.get(cols["copies"], "1")).to_float()))
			if not deck.is_empty() and copies > 0:
				if not decks.has(deck):
					decks[deck] = []
				for i in copies:
					(decks[deck] as Array).append(code)

	if out_cards.is_empty():
		report["error"] = "No row in the sheet matched a card the game has rules for."
		return report

	# cards
	DirAccess.make_dir_recursive_absolute(CARD_DIR)
	var card_path := CARD_DIR.path_join("imported_%s.json" % tag)
	var cf := FileAccess.open(card_path, FileAccess.WRITE)
	if cf == null:
		report["error"] = "Could not write %s." % card_path
		return report
	cf.store_string(JSON.stringify({"set": "imported", "source_sheet": path.get_file(),
			"count": out_cards.size(), "cards": out_cards}, " "))
	cf.close()
	CardDB.clear_art_cache()
	CardDB.load_all()

	# decks: one per "Starter Deck" value; re-importing replaces them
	var deck_ids: Array = []
	for label: String in decks:
		var did := "imp_%s" % _slug(label)
		var d := DeckManager.new_deck("%s (official)" % label)
		d["id"] = did
		d["main"] = decks[label]
		d["notes"] = "Imported from %s." % path.get_file()
		DeckManager.save(d)
		deck_ids.append(did)
		var v: Dictionary = DeckManager.validate(d)
		(report["decks"] as Array).append({"id": did, "name": d["name"], "cards": (decks[label] as Array).size(),
				"ok": bool(v.get("ok", false)), "reason": str(v.get("reason", ""))})

	# manifest, so the import can be removed again
	DirAccess.make_dir_recursive_absolute(MANIFEST_DIR)
	var mf := FileAccess.open(MANIFEST_DIR.path_join("%s.json" % tag), FileAccess.WRITE)
	if mf != null:
		mf.store_string(JSON.stringify({"sheet": path.get_file(), "cards": card_path, "images": written_images,
				"decks": deck_ids, "time": int(Time.get_unix_time_from_system())}, " "))
		mf.close()
	report["ok"] = true
	return report


## Every import done so far: [{tag, sheet, cards (count), time}].
static func imports() -> Array:
	var out: Array = []
	var dir := DirAccess.open(MANIFEST_DIR)
	if dir == null:
		return out
	for fname in dir.get_files():
		if fname.get_extension() != "json":
			continue
		var m: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_DIR.path_join(fname)))
		if typeof(m) == TYPE_DICTIONARY:
			var md: Dictionary = m
			md["tag"] = fname.get_basename()
			out.append(md)
	return out


## Undo an import: its cards, images and decks are deleted and our versions
## come back.
static func remove(tag: String) -> bool:
	var mpath := MANIFEST_DIR.path_join("%s.json" % tag)
	var m: Variant = JSON.parse_string(FileAccess.get_file_as_string(mpath))
	if typeof(m) != TYPE_DICTIONARY:
		return false
	var md: Dictionary = m
	DirAccess.remove_absolute(str(md.get("cards", "")))
	# A picture another import also wrote stays (R-070: removing one sheet
	# deleted the pictures of the same cards imported from another).
	var shared := {}
	for other: Dictionary in imports():
		if str(other.get("tag", "")) == tag:
			continue
		for op: Variant in other.get("images", []):
			shared[str(op)] = true
	for p: Variant in md.get("images", []):
		if not shared.has(str(p)):
			DirAccess.remove_absolute(str(p))
	for did: Variant in md.get("decks", []):
		if not DeckManager.get_deck(str(did)).is_empty():
			DeckManager.delete(str(did))
	DirAccess.remove_absolute(mpath)
	CardDB.clear_art_cache()
	CardDB.load_all()
	return true


## A short human summary of a report.
static func summary(rep: Dictionary) -> String:
	if not bool(rep.get("ok", false)):
		return "Import failed: %s" % rep.get("error", "")
	var lines: Array = ["Imported %d cards from %s (%d card images). %d of them also have our own version, which stays in the game." % [
			int(rep["imported"]), rep["sheet"], int(rep["images"]), int(rep.get("ours", 0))]]
	for d: Dictionary in rep.get("decks", []):
		lines.append("Deck: %s, %d cards%s" % [d["name"], d["cards"], "" if d["ok"] else " (not playable: %s)" % d["reason"]])
	var skipped: Array = rep.get("skipped", [])
	if not skipped.is_empty():
		var by_set: Dictionary = rep.get("skipped_by_set", {})
		var parts: Array = []
		for k: String in by_set:
			parts.append("%s %d" % [k, by_set[k]])
		lines.append("Skipped %d with no rules in the game yet (%s): %s" % [skipped.size(), ", ".join(parts),
				"; ".join(skipped.slice(0, 3))])
	var warns: Array = rep.get("warnings", [])
	if not warns.is_empty():
		lines.append("Notes (%d): %s" % [warns.size(), "; ".join(warns.slice(0, 5))])
	return "\n".join(lines)


# --------------------------------------------------------------- rules -----

static func _rules_from_our_cards() -> Dictionary:
	var out := {}
	var dir := DirAccess.open(OURS_DIR)
	if dir == null:
		return out
	for fname in dir.get_files():
		if fname.get_extension() != "json":
			continue
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(OURS_DIR.path_join(fname)))
		var list: Array = []
		if typeof(parsed) == TYPE_DICTIONARY:
			list = (parsed as Dictionary).get("cards", [])
		elif typeof(parsed) == TYPE_ARRAY:
			list = parsed
		for c: Variant in list:
			if typeof(c) == TYPE_DICTIONARY and str((c as Dictionary).get("based_on", "")) != "":
				out[str((c as Dictionary)["based_on"])] = c
	return out


static func _rules_from_import_files() -> Dictionary:
	var out := {}
	var dir := DirAccess.open(RULES_DIR)
	if dir == null:
		return out
	for fname in dir.get_files():
		if not fname.begins_with("rules_") or fname.get_extension() != "json":
			continue
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(RULES_DIR.path_join(fname)))
		if typeof(parsed) == TYPE_DICTIONARY:
			var rules: Dictionary = (parsed as Dictionary).get("rules", {})
			for code: String in rules:
				out[code] = rules[code]
	return out


# ---------------------------------------------------------------- xlsx -----

## [{cols, rows, images}] for every worksheet with a code column.
static func _read_book(zip: ZIPReader) -> Array:
	var files := zip.get_files()
	var shared := _shared_strings(zip, files)
	var sheets: Array = []
	for f: String in files:
		if f.begins_with("xl/worksheets/") and f.ends_with(".xml") and not f.contains("/_rels/"):
			sheets.append(f)
	sheets.sort_custom(func(a: String, b: String) -> bool: return a.naturalnocasecmp_to(b) < 0)
	var out: Array = []
	for sheet: String in sheets:
		var rows := _sheet_rows(zip.read_file(sheet), shared)
		if rows.is_empty():
			continue
		var cols := _columns(rows[0])
		if not cols.has("code"):
			continue
		out.append({"cols": cols, "rows": rows.slice(1), "images": _row_images(zip, files, sheet)})
	return out


static func _shared_strings(zip: ZIPReader, files: PackedStringArray) -> Array:
	var out: Array = []
	if not files.has("xl/sharedStrings.xml"):
		return out
	var p := XMLParser.new()
	p.open_buffer(zip.read_file("xl/sharedStrings.xml"))
	var cur := ""
	var in_si := false
	var in_t := false
	while p.read() == OK:
		match p.get_node_type():
			XMLParser.NODE_ELEMENT:
				if p.get_node_name() == "si":
					in_si = true
					cur = ""
				elif p.get_node_name() == "t":
					in_t = not p.is_empty()
			XMLParser.NODE_ELEMENT_END:
				if p.get_node_name() == "si":
					out.append(cur)
					in_si = false
				elif p.get_node_name() == "t":
					in_t = false
			XMLParser.NODE_TEXT, XMLParser.NODE_CDATA:
				if in_si and in_t:
					cur += p.get_node_data()
	return out


## Rows as dictionaries: column letter -> text, plus "_row" (1-based row number).
static func _sheet_rows(buf: PackedByteArray, shared: Array) -> Array:
	var rows: Array = []
	var p := XMLParser.new()
	p.open_buffer(buf)
	var row := {}
	var col := ""
	var ctype := ""
	var val := ""
	var in_v := false
	while p.read() == OK:
		match p.get_node_type():
			XMLParser.NODE_ELEMENT:
				match p.get_node_name():
					"row":
						row = {"_row": int(p.get_named_attribute_value_safe("r"))}
					"c":
						var ref := p.get_named_attribute_value_safe("r")
						col = ""
						for ch in ref:
							if ch >= "A" and ch <= "Z":
								col += ch
						ctype = p.get_named_attribute_value_safe("t")
						val = ""
					"v", "t":
						in_v = not p.is_empty()
			XMLParser.NODE_ELEMENT_END:
				match p.get_node_name():
					"v", "t":
						in_v = false
					"c":
						if ctype == "s" and val.is_valid_int() and int(val) < shared.size():
							val = str(shared[int(val)])
						row[col] = val
					"row":
						rows.append(row)
			XMLParser.NODE_TEXT, XMLParser.NODE_CDATA:
				if in_v:
					val += p.get_node_data()
	return rows


static func _columns(header: Dictionary) -> Dictionary:
	var cols := {}
	for col: String in header:
		if col == "_row":
			continue
		var h := str(header[col]).strip_edges().to_lower()
		if h.is_empty():
			continue
		if h.contains("copies") or h in ["qty", "quantity", "count"]:
			cols["copies"] = col
		elif h.contains("code") or h.contains("number") or h == "id":
			if not cols.has("code"): cols["code"] = col
		elif h.contains("name"):
			if not cols.has("name"): cols["name"] = col
		elif h.contains("type"):
			cols["type"] = col
		elif h.contains("rarity"):
			cols["rarity"] = col
		elif h.contains("colour") or h.contains("color") or h.contains("image") or h.contains("link"):
			pass                                       # "Deck Colour" is not the deck
		elif h.contains("deck"):
			cols["deck"] = col
	return cols


## Pictures placed over cells: sheet row number -> {bytes, ext}.
static func _row_images(zip: ZIPReader, files: PackedStringArray, sheet: String) -> Dictionary:
	var out := {}
	var rels_path := sheet.get_base_dir().path_join("_rels").path_join(sheet.get_file() + ".rels")
	if not files.has(rels_path):
		return out
	var drawing := ""
	for rel: Dictionary in _rels(zip.read_file(rels_path)):
		if str(rel["type"]).ends_with("/drawing"):
			drawing = _join(sheet.get_base_dir(), str(rel["target"]))
	if drawing.is_empty() or not files.has(drawing):
		return out
	var drels_path := drawing.get_base_dir().path_join("_rels").path_join(drawing.get_file() + ".rels")
	var media := {}
	if files.has(drels_path):
		for rel: Dictionary in _rels(zip.read_file(drels_path)):
			media[str(rel["id"])] = _join(drawing.get_base_dir(), str(rel["target"]))
	var p := XMLParser.new()
	p.open_buffer(zip.read_file(drawing))
	var in_from := false
	var in_row := false
	var anchor_row := -1
	var txt := ""
	# Excel writes "xdr:from", other tools plain "from": compare local names.
	while p.read() == OK:
		match p.get_node_type():
			XMLParser.NODE_ELEMENT:
				var n := _local(p.get_node_name())
				if n.ends_with("Anchor"):
					anchor_row = -1
				elif n == "from":
					in_from = true
				elif n == "row" and in_from:
					in_row = not p.is_empty()
					txt = ""
				elif n == "blip":
					var rid := ""
					for i in p.get_attribute_count():
						if _local(p.get_attribute_name(i)) == "embed":
							rid = p.get_attribute_value(i)
					if media.has(rid) and anchor_row >= 0 and files.has(str(media[rid])):
						var mp := str(media[rid])
						var ext := mp.get_extension().to_lower()
						out[anchor_row + 1] = {"bytes": zip.read_file(mp), "ext": "jpg" if ext == "jpeg" else ext}
			XMLParser.NODE_ELEMENT_END:
				var n2 := _local(p.get_node_name())
				if n2 == "from":
					in_from = false
				elif n2 == "row" and in_row:
					in_row = false
					anchor_row = int(txt)
			XMLParser.NODE_TEXT:
				if in_row:
					txt += p.get_node_data()
	return out


static func _local(qname: String) -> String:
	var i := qname.rfind(":")
	return qname if i < 0 else qname.substr(i + 1)


static func _rels(buf: PackedByteArray) -> Array:
	var out: Array = []
	var p := XMLParser.new()
	p.open_buffer(buf)
	while p.read() == OK:
		if p.get_node_type() == XMLParser.NODE_ELEMENT and p.get_node_name() == "Relationship":
			out.append({"id": p.get_named_attribute_value_safe("Id"),
					"type": p.get_named_attribute_value_safe("Type"),
					"target": p.get_named_attribute_value_safe("Target")})
	return out


## Resolve "../media/image1.jpeg" against "xl/drawings".
static func _join(base: String, target: String) -> String:
	if target.begins_with("/"):
		return target.substr(1)
	var parts: Array = base.split("/", false)
	for seg: String in target.split("/", false):
		if seg == "..":
			if not parts.is_empty():
				parts.pop_back()
		elif seg != ".":
			parts.append(seg)
	return "/".join(parts)


static func _slug(s: String) -> String:
	var out := ""
	for ch in s.to_lower():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"):
			out += ch
		elif not out.ends_with("_"):
			out += "_"
	return out.strip_edges().trim_suffix("_").trim_prefix("_")
