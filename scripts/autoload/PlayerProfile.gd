extends Node
##
## The player's profile (0.16.0): icon, match history and what the history says
## about how they play.
##
## Persisted to user://profile/profile.json. The display name is NOT stored
## here -- it stays in GameConfig.player_name (settings.cfg), which the main
## menu, the settings screen and the lobby already read; this script only
## wraps it so the profile screen has one place to talk to.
##
## Recording is triggered by MatchService at the end of a match, and only when
## MatchService.record_results is true, which the screens that start a real
## game set and the test harnesses never do. Tests point this script at a
## throw-away folder with set_storage_dir() so nothing they record lands in
## the real profile.
##

const DEFAULT_DIR := "user://profile"
const MAX_HISTORY := 500
const MIN_GAMES_FOR_INSIGHTS := 5

## Mode names stored in each match record.
const MODE_VS_AI := "vs_ai"
const MODE_HOTSEAT := "hotseat"
const MODE_ONLINE := "online"

var storage_dir: String = DEFAULT_DIR
var icon: Dictionary = {"kind": "none", "card_id": "", "path": ""}
var created: String = ""
var history: Array = []            # oldest first; each entry is a Dictionary

var _icon_cache: Dictionary = {}   # "key@size" -> Texture2D
var _loaded := false

signal changed


func _ready() -> void:
	load_profile()


# ---------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------

func profile_path() -> String:
	return storage_dir.path_join("profile.json")


func icon_file_path() -> String:
	return storage_dir.path_join("icon.png")


## Tests call this with a temporary folder; it reloads from there.
func set_storage_dir(dir: String) -> void:
	storage_dir = dir
	_icon_cache.clear()
	load_profile()


func load_profile() -> void:
	DirAccess.make_dir_recursive_absolute(storage_dir)
	icon = {"kind": "none", "card_id": "", "path": ""}
	history = []
	created = ""
	var f := FileAccess.open(profile_path(), FileAccess.READ)
	if f != null:
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		if parsed is Dictionary:
			var d: Dictionary = parsed
			var ic: Variant = d.get("icon", {})
			if ic is Dictionary:
				icon = {"kind": str((ic as Dictionary).get("kind", "none")),
						"card_id": str((ic as Dictionary).get("card_id", "")),
						"path": str((ic as Dictionary).get("path", ""))}
			created = str(d.get("created", ""))
			var h: Variant = d.get("history", [])
			if h is Array:
				for e: Variant in h:
					if e is Dictionary:
						history.append(e)
	if created == "":
		created = _today()
	_bound()
	_loaded = true
	changed.emit()


func save() -> void:
	DirAccess.make_dir_recursive_absolute(storage_dir)
	_bound()
	var out := {"version": 1, "created": created, "icon": icon, "history": history}
	var f := FileAccess.open(profile_path(), FileAccess.WRITE)
	if f == null:
		Log.error("PlayerProfile: cannot write %s" % profile_path())
		return
	f.store_string(JSON.stringify(out, "\t"))
	f.close()
	changed.emit()


func _bound() -> void:
	if history.size() > MAX_HISTORY:
		history = history.slice(history.size() - MAX_HISTORY)


func _today() -> String:
	return Time.get_date_string_from_system()


# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------

func display_name() -> String:
	return GameConfig.player_name


func set_display_name(text: String) -> void:
	var clean := text.strip_edges().substr(0, 24)
	if clean.is_empty():
		clean = "Player"
	if clean == GameConfig.player_name:
		return
	GameConfig.player_name = clean
	GameConfig.save_settings()
	changed.emit()


func member_since() -> String:
	return created


# ---------------------------------------------------------------------------
# Icon
# ---------------------------------------------------------------------------

func set_icon_card(card_id: String) -> void:
	icon = {"kind": "card", "card_id": card_id, "path": ""}
	_icon_cache.clear()
	save()


## Copies an image from the player's computer into the profile folder, so the
## profile keeps working when the original moves. PNG, JPG and WebP.
func set_icon_file(src_path: String) -> bool:
	if not FileAccess.file_exists(src_path):
		Log.error("PlayerProfile: no such image %s" % src_path)
		return false
	var img := Image.new()
	var err := img.load(src_path)
	if err != OK or img.is_empty():
		Log.error("PlayerProfile: could not read image %s (error %d)" % [src_path, err])
		return false
	# Square-crop and shrink: a 4000px photo is not needed for a 140px circle.
	img = _square(img, 512)
	DirAccess.make_dir_recursive_absolute(storage_dir)
	if img.save_png(icon_file_path()) != OK:
		Log.error("PlayerProfile: could not write %s" % icon_file_path())
		return false
	icon = {"kind": "file", "card_id": "", "path": icon_file_path()}
	_icon_cache.clear()
	save()
	return true


func clear_icon() -> void:
	icon = {"kind": "none", "card_id": "", "path": ""}
	_icon_cache.clear()
	save()


func has_icon() -> bool:
	return str(icon.get("kind", "none")) != "none"


## The icon as a circle of `size` pixels, transparent outside. Cached per size.
## With no icon set, a gold initial on a navy disc, so every screen can show
## something without checking first.
func icon_texture(size: int) -> Texture2D:
	size = maxi(16, size)
	var key := "%s:%s:%s@%d" % [str(icon.get("kind", "none")), str(icon.get("card_id", "")),
			display_name().left(1), size]
	if _icon_cache.has(key):
		return _icon_cache[key]
	var src: Image = _source_image()
	var tex := ImageTexture.create_from_image(circle_crop(src, size))
	_icon_cache[key] = tex
	return tex


func _source_image() -> Image:
	var kind := str(icon.get("kind", "none"))
	if kind == "card":
		var tex: Texture2D = CardDB.get_card_texture(str(icon.get("card_id", "")))
		if tex != null:
			var img := tex.get_image()
			if img != null and not img.is_empty():
				return _card_face_crop(img)
	elif kind == "file":
		var img2 := Image.new()
		if img2.load(str(icon.get("path", icon_file_path()))) == OK and not img2.is_empty():
			return img2
	return _initial_image()


## Card art: the picture sits in the upper part of the face, above the text
## box, so the crop takes a square from just under the name bar.
func _card_face_crop(img: Image) -> Image:
	if img.is_compressed():
		img.decompress()
	var w := img.get_width()
	var h := img.get_height()
	var side := mini(w, int(float(h) * 0.44))
	var x := int((w - side) * 0.5)
	var y := int(float(h) * 0.10)
	if y + side > h:
		y = h - side
	return img.get_region(Rect2i(x, maxi(0, y), side, side))


func _square(img: Image, max_side: int) -> Image:
	if img.is_compressed():
		img.decompress()
	var w := img.get_width()
	var h := img.get_height()
	var side := mini(w, h)
	var sq := img.get_region(Rect2i(int((w - side) * 0.5), int((h - side) * 0.5), side, side))
	if side > max_side:
		sq.resize(max_side, max_side, Image.INTERPOLATE_LANCZOS)
	return sq


## No icon chosen: a navy disc with a gold rim. An Image has no text
## rasteriser, so the player's initial is drawn over it by the screen that
## shows it (see ProfileScreen.icon_widget).
func _initial_image() -> Image:
	var n := 128
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	img.fill(Color("#15203d"))
	var c := Vector2(n * 0.5, n * 0.5)
	for y in n:
		for x in n:
			var d := Vector2(x + 0.5, y + 0.5).distance_to(c)
			if d > n * 0.5 - 6.0:
				img.set_pixel(x, y, Color("#f0b84a"))
	return img


## A circular cut of `src`, `size` pixels across, anti-aliased at the edge.
func circle_crop(src: Image, size: int) -> Image:
	var img := src.duplicate() as Image
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	var side := mini(w, h)
	if side != w or side != h:
		img = img.get_region(Rect2i(int((w - side) * 0.5), int((h - side) * 0.5), side, side))
	img.resize(size, size, Image.INTERPOLATE_LANCZOS)
	var c := float(size) * 0.5
	var r := c - 0.5
	for y in size:
		for x in size:
			var d := Vector2(x + 0.5, y + 0.5).distance_to(Vector2(c, c))
			if d > r + 1.0:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
			elif d > r - 1.0:
				var p := img.get_pixel(x, y)
				p.a *= clampf((r + 1.0 - d) * 0.5, 0.0, 1.0)
				img.set_pixel(x, y, p)
	return img


# ---------------------------------------------------------------------------
# Recording
# ---------------------------------------------------------------------------

## Builds a record from a finished engine state and stores it. Returns the
## record. `deck` is the saved deck (id, name, main). For an online game with
## no local engine, pass null and a snapshot through record_snapshot().
func record_match(state: GameState, my_seat: int, deck: Dictionary, mode: String,
		difficulty: int, opponent_deck_name: String) -> Dictionary:
	var rec := extract(state, my_seat, deck, mode, difficulty, opponent_deck_name)
	record_entry(rec)
	return rec


## Stores an already-built record (what tests and the screenshot tour use).
func record_entry(rec: Dictionary) -> void:
	history.append(rec)
	save()


## What a match record holds, with the numbers read off the engine's logs.
## action_log is complete; event_log is trimmed in very long games, so the
## counts that have an action behind them come from the actions.
func extract(state: GameState, my_seat: int, deck: Dictionary, mode: String,
		difficulty: int, opponent_deck_name: String) -> Dictionary:
	var opp := 1 - my_seat
	var rec := blank_record(deck, mode, difficulty, opponent_deck_name)
	if state == null:
		return rec
	var me := state.player(my_seat)
	var them := state.player(opp)
	rec["result"] = "draw" if state.winner == 2 else ("win" if state.winner == my_seat else "loss")
	rec["turns"] = state.turn_number
	rec["my_life"] = me.life_total()
	rec["opp_life"] = them.life_total()
	rec["first"] = state.first_player == my_seat
	rec["conceded"] = me.conceded
	if opponent_deck_name == "":
		rec["opp_deck"] = them.deck_name
	for a: Variant in state.action_log:
		if not (a is Dictionary):
			continue
		var ad: Dictionary = a
		var pid := int(ad.get("pid", -1))
		var act: Variant = ad.get("action", {})
		var verb := str((act as Dictionary).get("verb", "")) if act is Dictionary else ""
		if pid == my_seat:
			match verb:
				BSS.Action.SUMMON: rec["summons"] = int(rec["summons"]) + 1
				BSS.Action.PLACE: rec["nexuses"] = int(rec["nexuses"]) + 1
				BSS.Action.USE_MAGIC: rec["magic"] = int(rec["magic"]) + 1
				BSS.Action.DECLARE_ATTACK: rec["attacks"] = int(rec["attacks"]) + 1
				BSS.Action.DECLARE_BLOCK: rec["blocks"] = int(rec["blocks"]) + 1
				BSS.Action.DECLINE_BLOCK: rec["blocks_declined"] = int(rec["blocks_declined"]) + 1
		elif pid == opp:
			match verb:
				BSS.Action.DECLARE_ATTACK: rec["opp_attacks"] = int(rec["opp_attacks"]) + 1
				BSS.Action.USE_MAGIC: rec["opp_magic"] = int(rec["opp_magic"]) + 1
				BSS.Action.DECLARE_BLOCK: rec["opp_blocks"] = int(rec["opp_blocks"]) + 1
				BSS.Action.DECLINE_BLOCK: rec["opp_blocks_declined"] = int(rec["opp_blocks_declined"]) + 1
	var my_turns := 0
	var opp_turns := 0
	for e: Variant in state.event_log:
		if not (e is Dictionary):
			continue
		var ed: Dictionary = e
		var kind := str(ed.get("kind", ""))
		var dat: Variant = ed.get("data", {})
		if not (dat is Dictionary):
			continue
		var d: Dictionary = dat
		var p := int(d.get("player", -1))
		match kind:
			"damage":
				if p == opp:
					rec["damage_dealt"] = int(rec["damage_dealt"]) + int(d.get("n", 0))
				elif p == my_seat:
					rec["damage_taken"] = int(rec["damage_taken"]) + int(d.get("n", 0))
			"draw":
				if p == my_seat:
					rec["cards_drawn"] = int(rec["cards_drawn"]) + int(d.get("n", 0))
			"turn_start":
				if p == my_seat:
					my_turns += 1
				elif p == opp:
					opp_turns += 1
			"summon", "place", "use_magic":
				if p == my_seat:
					rec["cores_spent"] = int(rec["cores_spent"]) + int(d.get("cost", 0))
					if kind == "summon":
						var ci: CardInstance = state.cards.get(int(d.get("uid", -1)))
						if ci != null and ci.data != null:
							rec["biggest_bp"] = maxi(int(rec["biggest_bp"]), ci.data.max_bp())
	# The event log is trimmed in very long games; fall back to the turn count.
	if my_turns == 0 and state.turn_number > 0:
		var mine_first := state.first_player == my_seat
		@warning_ignore("integer_division")
		my_turns = (state.turn_number + (1 if mine_first else 0)) / 2
		opp_turns = state.turn_number - my_turns
	rec["my_turns"] = my_turns
	rec["opp_turns"] = opp_turns
	return rec


## Online games have no engine: what the final snapshot can say.
func record_snapshot(snap: Dictionary, my_seat: int, deck: Dictionary, mode: String,
		result: String, opponent_deck_name: String) -> Dictionary:
	var rec := blank_record(deck, mode, -1, opponent_deck_name)
	rec["result"] = result
	rec["turns"] = int(snap.get("turn_number", 0))
	var players: Array = snap.get("players", [])
	if players.size() == 2 and my_seat >= 0:
		var me: Dictionary = players[my_seat]
		var them: Dictionary = players[1 - my_seat]
		rec["my_life"] = int(me.get("life", 0)) + int(me.get("life_soul", 0))
		rec["opp_life"] = int(them.get("life", 0)) + int(them.get("life_soul", 0))
		if opponent_deck_name == "":
			rec["opp_deck"] = str(them.get("deck_name", "Opponent's deck"))
	rec["partial"] = true
	record_entry(rec)
	return rec


func blank_record(deck: Dictionary, mode: String, difficulty: int, opponent_deck_name: String) -> Dictionary:
	var colours: Array = []
	var costs := 0
	var n := 0
	var magic_cards := 0
	var seen := {}
	for id: Variant in deck.get("main", []):
		var cd: CardData = CardDB.get_card(str(id))
		if cd == null:
			continue
		n += 1
		costs += cd.cost
		if cd.is_magic():
			magic_cards += 1
		for c: int in cd.colors:
			seen[c] = true
	colours = seen.keys()
	colours.sort()
	return {
		"date": Time.get_datetime_string_from_system(false, true),
		"mode": mode,
		"difficulty": difficulty,
		"deck_id": str(deck.get("id", "")),
		"deck_name": str(deck.get("name", "Untitled")),
		"deck_colours": colours,
		"deck_avg_cost": (float(costs) / float(n)) if n > 0 else 0.0,
		"deck_magic": magic_cards,
		"opp_deck": opponent_deck_name,
		"result": "draw",
		"turns": 0,
		"my_turns": 0,
		"opp_turns": 0,
		"my_life": 0,
		"opp_life": 0,
		"summons": 0,
		"nexuses": 0,
		"magic": 0,
		"attacks": 0,
		"blocks": 0,
		"blocks_declined": 0,
		"opp_attacks": 0,
		"opp_magic": 0,
		"opp_blocks": 0,
		"opp_blocks_declined": 0,
		"damage_dealt": 0,
		"damage_taken": 0,
		"cards_drawn": 0,
		"biggest_bp": 0,
		"cores_spent": 0,
		"first": false,
		"conceded": false,
	}


# ---------------------------------------------------------------------------
# Statistics
# ---------------------------------------------------------------------------

func games() -> int:
	return history.size()


func stats_overall() -> Dictionary:
	var out := {"games": 0, "wins": 0, "losses": 0, "draws": 0, "win_rate": 0.0,
			"streak": 0, "best_streak": 0, "worst_streak": 0, "last_played": ""}
	var cur := 0          # +n wins in a row, -n losses in a row
	for r: Dictionary in history:
		out["games"] = int(out["games"]) + 1
		var res := str(r.get("result", ""))
		if res == "win":
			out["wins"] = int(out["wins"]) + 1
			cur = cur + 1 if cur > 0 else 1
		elif res == "loss":
			out["losses"] = int(out["losses"]) + 1
			cur = cur - 1 if cur < 0 else -1
		else:
			out["draws"] = int(out["draws"]) + 1
			cur = 0
		out["best_streak"] = maxi(int(out["best_streak"]), cur)
		out["worst_streak"] = mini(int(out["worst_streak"]), cur)
		out["last_played"] = str(r.get("date", ""))
	out["streak"] = cur
	out["worst_streak"] = -int(out["worst_streak"])
	out["win_rate"] = _rate(int(out["wins"]), int(out["games"]))
	return out


## One row per deck, most played first.
func stats_by_deck() -> Array:
	var by := {}
	for r: Dictionary in history:
		var id := str(r.get("deck_id", ""))
		var key := id if id != "" else str(r.get("deck_name", ""))
		if not by.has(key):
			by[key] = {"deck_id": id, "name": str(r.get("deck_name", "Untitled")),
					"colours": r.get("deck_colours", []), "games": 0, "wins": 0, "losses": 0,
					"draws": 0, "win_rate": 0.0, "last_played": ""}
		var row: Dictionary = by[key]
		row["games"] = int(row["games"]) + 1
		var res := str(r.get("result", ""))
		if res == "win":
			row["wins"] = int(row["wins"]) + 1
		elif res == "loss":
			row["losses"] = int(row["losses"]) + 1
		else:
			row["draws"] = int(row["draws"]) + 1
		row["last_played"] = str(r.get("date", ""))
		row["name"] = str(r.get("deck_name", row["name"]))     # a renamed deck shows its new name
		row["colours"] = r.get("deck_colours", row["colours"])
	var rows: Array = by.values()
	for row: Dictionary in rows:
		row["win_rate"] = _rate(int(row["wins"]), int(row["games"]))
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["games"]) != int(b["games"]):
			return int(a["games"]) > int(b["games"])
		return str(a["last_played"]) > str(b["last_played"]))
	return rows


## The last n matches, newest first.
func recent(n: int) -> Array:
	var out: Array = history.slice(maxi(0, history.size() - n))
	out.reverse()
	return out


func favourite_deck() -> Dictionary:
	var rows := stats_by_deck()
	return rows[0] if not rows.is_empty() else {}


## The colour that appears in the most games played.
func favourite_colour() -> int:
	var count := {}
	for r: Dictionary in history:
		for c: Variant in r.get("deck_colours", []):
			count[int(c)] = int(count.get(int(c), 0)) + 1
	var best := -1
	var best_n := 0
	for c: int in count:
		if int(count[c]) > best_n:
			best_n = int(count[c])
			best = c
	return best


func _rate(part: int, whole: int) -> float:
	return (float(part) / float(whole)) if whole > 0 else 0.0


func pct(x: float) -> String:
	return "%d%%" % int(round(x * 100.0))


# ---------------------------------------------------------------------------
# Insights
# ---------------------------------------------------------------------------

## Reads the history and says what it shows. Every sentence carries the number
## behind it. With fewer than MIN_GAMES_FOR_INSIGHTS games there is nothing to
## say yet and the result says so.
func strengths_and_weaknesses() -> Dictionary:
	var out := {"strengths": [], "weaknesses": [], "tips": [], "playstyle": "", "confidence": "none"}
	var n := history.size()
	if n < MIN_GAMES_FOR_INSIGHTS:
		out["playstyle"] = "Not enough games yet: play %d more to see what your history says." % (MIN_GAMES_FOR_INSIGHTS - n)
		out["tips"].append("Finish at least %d matches for a first read; the picture sharpens after 12." % MIN_GAMES_FOR_INSIGHTS)
		return out
	out["confidence"] = "low" if n < 12 else ("medium" if n < 30 else "high")

	var strengths: Array = out["strengths"]
	var weaknesses: Array = out["weaknesses"]
	var tips: Array = out["tips"]
	var wins: Array = []
	var losses: Array = []
	for r: Dictionary in history:
		if str(r.get("result", "")) == "win":
			wins.append(r)
		elif str(r.get("result", "")) == "loss":
			losses.append(r)
	var overall := stats_overall()
	var win_rate := float(overall["win_rate"])

	# --- Aggression: my attacks per turn against the opponents' -------------
	var my_apt := _sum("attacks") / maxf(1.0, _sum("my_turns"))
	var opp_apt := _sum("opp_attacks") / maxf(1.0, _sum("opp_turns"))
	var aggression := "balanced"
	if opp_apt > 0.0 and my_apt >= opp_apt * 1.25:
		aggression = "aggressive"
		strengths.append("You attack %.1f times per turn against your opponents' %.1f: you set the pace." % [my_apt, opp_apt])
	elif opp_apt > 0.0 and my_apt <= opp_apt * 0.75:
		aggression = "passive"
		weaknesses.append("You attack %.1f times per turn against your opponents' %.1f; the pressure is coming from them." % [my_apt, opp_apt])
		tips.append("Attack with spirits that cannot be blocked profitably instead of holding them back: a spirit that never attacks is only a blocker.")

	# --- Defence: block rate and damage taken ------------------------------
	var block_chances := _sum("blocks") + _sum("blocks_declined")
	var block_rate := (_sum("blocks") / block_chances) if block_chances > 0.0 else -1.0
	var taken_in_losses := _avg(losses, "damage_taken")
	var taken_in_wins := _avg(wins, "damage_taken")
	var defence := "balanced"
	if block_rate >= 0.0 and block_chances >= 5.0:
		if block_rate <= 0.35:
			defence = "open"
			var ratio_text := ""
			if not wins.is_empty() and not losses.is_empty() and taken_in_wins > 0.0:
				ratio_text = "; the games you lost had %.1fx the damage taken" % (taken_in_losses / taken_in_wins)
			weaknesses.append("You block only %s of attacks%s." % [pct(block_rate), ratio_text])
			tips.append("Block when the trade is even or better: an exhausted attacker is already paying its cost, and a blocked hit is a life core kept.")
		elif block_rate >= 0.6:
			defence = "solid"
			strengths.append("You block %s of attacks and take %.1f damage per game; your life total is well guarded." % [pct(block_rate), _avg(history, "damage_taken")])

	# --- Tempo: expensive decks losing early --------------------------------
	var early_losses := 0
	for r: Dictionary in losses:
		if int(r.get("turns", 0)) <= 8:
			early_losses += 1
	var avg_cost := _avg(history, "deck_avg_cost")
	if losses.size() >= 3 and avg_cost >= 4.5 and float(early_losses) / float(losses.size()) >= 0.4:
		weaknesses.append("Your decks average %.1f cost and %d of your %d losses ended by turn 8: you are being run over before the expensive cards land." % [avg_cost, early_losses, losses.size()])
		tips.append("Add low-cost spirits or cheaper cards with reduction symbols so the early turns are not empty.")
	var short_games: Array = []
	for r: Dictionary in history:
		if int(r.get("turns", 0)) <= 8:
			short_games.append(r)
	if short_games.size() >= 3:
		var short_wins := 0
		for r: Dictionary in short_games:
			if str(r.get("result", "")) == "win":
				short_wins += 1
		var short_rate := _rate(short_wins, short_games.size())
		if short_rate >= 0.6:
			strengths.append("You win %s of games that end by turn 8 (%d of %d): a fast start is your edge." % [pct(short_rate), short_wins, short_games.size()])

	# --- Consistency per deck --------------------------------------------
	for row: Dictionary in stats_by_deck():
		if int(row["games"]) < 3:
			continue
		var wr := float(row["win_rate"])
		if wr >= 0.6:
			strengths.append("%s wins %s of its games (%d-%d-%d)." % [str(row["name"]), pct(wr),
					int(row["wins"]), int(row["losses"]), int(row["draws"])])
		elif wr <= 0.35:
			weaknesses.append("%s wins only %s of its games (%d-%d-%d)." % [str(row["name"]), pct(wr),
					int(row["wins"]), int(row["losses"]), int(row["draws"])])
			tips.append("Compare %s with your best deck in the Record by deck table: its cost curve or colours may not suit how you play." % str(row["name"]))

	# --- Finishing ---------------------------------------------------------
	if wins.size() >= 3:
		var clutch := 0
		for r: Dictionary in wins:
			if int(r.get("my_life", 0)) <= 2:
				clutch += 1
		if float(clutch) / float(wins.size()) >= 0.3:
			strengths.append("%d of your %d wins came with 2 or fewer life left: you close out tight games." % [clutch, wins.size()])
	if losses.size() >= 3:
		var near := 0
		for r: Dictionary in losses:
			if int(r.get("opp_life", 0)) <= 1:
				near += 1
		if float(near) / float(losses.size()) >= 0.3:
			weaknesses.append("%d of your %d losses had the opponent at 1 life or less: the last hit is not landing." % [near, losses.size()])
			tips.append("Keep one unblockable or Crush attacker back for the final turn, and count the opponent's untapped blockers before committing.")

	# --- Magic -------------------------------------------------------------
	var magic_pg := _avg(history, "magic")
	var opp_magic_pg := _avg(history, "opp_magic")
	var games_with_magic_cards := 0
	var games_no_magic_used := 0
	for r: Dictionary in history:
		if int(r.get("deck_magic", 0)) > 0:
			games_with_magic_cards += 1
			if int(r.get("magic", 0)) == 0:
				games_no_magic_used += 1
	var magic_style := "balanced"
	if opp_magic_pg > 0.0 and magic_pg >= opp_magic_pg * 1.5 and magic_pg >= 1.0:
		magic_style = "spell-heavy"
		strengths.append("You use %.1f magic cards per game against your opponents' %.1f." % [magic_pg, opp_magic_pg])
	if games_with_magic_cards >= 3 and float(games_no_magic_used) / float(games_with_magic_cards) >= 0.6:
		magic_style = "spell-shy"
		weaknesses.append("In %d of %d games with magic in your deck you never used one." % [games_no_magic_used, games_with_magic_cards])
		tips.append("Flash magic in the attack step is the cheapest way to win a BP comparison; keep cores in reserve for it.")

	# --- Difficulty --------------------------------------------------------
	var by_diff := {}
	for r: Dictionary in history:
		if str(r.get("mode", "")) != MODE_VS_AI:
			continue
		var dk := int(r.get("difficulty", -1))
		if dk < 0:
			continue
		if not by_diff.has(dk):
			by_diff[dk] = [0, 0]
		var pair: Array = by_diff[dk]
		pair[1] = int(pair[1]) + 1
		if str(r.get("result", "")) == "win":
			pair[0] = int(pair[0]) + 1
	var diffs: Array = by_diff.keys()
	diffs.sort()
	for dk: int in diffs:
		var pair: Array = by_diff[dk]
		if int(pair[1]) < 3:
			continue
		var dr := _rate(int(pair[0]), int(pair[1]))
		var dname: String = BotController.DIFFICULTY_NAMES[clampi(dk, 0, BotController.DIFFICULTY_NAMES.size() - 1)]
		if dk >= 3 and dr >= 0.6:
			strengths.append("You beat the %s AI %s of the time (%d of %d)." % [dname, pct(dr), int(pair[0]), int(pair[1])])
		elif dk >= 2 and dr < 0.3:
			weaknesses.append("You beat the %s AI only %s of the time (%d of %d)." % [dname, pct(dr), int(pair[0]), int(pair[1])])
		elif dk <= 1 and dr >= 0.8 and diffs.size() == 1:
			tips.append("You win %s against the %s AI; step up a difficulty for a harder read on your play." % [pct(dr), dname])

	# --- Going first or second ------------------------------------------
	var first_w := 0
	var first_n := 0
	var second_w := 0
	var second_n := 0
	for r: Dictionary in history:
		if bool(r.get("first", false)):
			first_n += 1
			if str(r.get("result", "")) == "win":
				first_w += 1
		else:
			second_n += 1
			if str(r.get("result", "")) == "win":
				second_w += 1
	if first_n >= 3 and second_n >= 3:
		var fr := _rate(first_w, first_n)
		var sr := _rate(second_w, second_n)
		if fr - sr >= 0.2:
			weaknesses.append("You win %s going first but %s going second (%d and %d games)." % [pct(fr), pct(sr), first_n, second_n])
			tips.append("Going second you draw first and get the first full core turn: spend it on a blocker, not on nothing.")
		elif sr - fr >= 0.2:
			strengths.append("You win %s going second against %s going first (%d and %d games)." % [pct(sr), pct(fr), second_n, first_n])

	# --- Streaks and concessions -----------------------------------------
	if int(overall["best_streak"]) >= 3:
		strengths.append("Your longest winning streak is %d games." % int(overall["best_streak"]))
	if int(overall["worst_streak"]) >= 3 and win_rate < 0.5:
		weaknesses.append("Your longest losing streak is %d games." % int(overall["worst_streak"]))
	if losses.size() >= 3:
		var conceded := 0
		for r: Dictionary in losses:
			if bool(r.get("conceded", false)):
				conceded += 1
		if float(conceded) / float(losses.size()) >= 0.3:
			tips.append("%d of your %d losses were concessions; the AI misplays often enough that playing it out wins some of those." % [conceded, losses.size()])

	# --- Overall -------------------------------------------------------
	if win_rate >= 0.6:
		strengths.append("Overall you win %s of your games (%d of %d)." % [pct(win_rate), int(overall["wins"]), n])
	elif win_rate <= 0.4:
		weaknesses.append("Overall you win %s of your games (%d of %d)." % [pct(win_rate), int(overall["wins"]), n])

	# --- Playstyle line -------------------------------------------------
	var fav := favourite_deck()
	var parts: Array[String] = []
	match aggression:
		"aggressive": parts.append("Aggressive")
		"passive": parts.append("Patient")
		_: parts.append("Balanced")
	match defence:
		"solid": parts.append("well-defended")
		"open": parts.append("all-in")
		_: parts.append("even-tempo")
	var style := " ".join(parts)
	if magic_style == "spell-heavy":
		style += ", spell-heavy"
	var fav_text := ""
	if not fav.is_empty():
		fav_text = "; favourite deck %s (%d games)" % [str(fav["name"]), int(fav["games"])]
	out["playstyle"] = "%s player: %.1f attacks per turn, %s block rate, %.1f magic per game%s." % [
			style, my_apt, (pct(block_rate) if block_rate >= 0.0 else "no"), magic_pg, fav_text]
	if strengths.is_empty():
		strengths.append("Nothing stands out yet across %d games; keep playing and the numbers will." % n)
	if weaknesses.is_empty():
		weaknesses.append("No clear weakness in %d games." % n)
	return out


func _sum(key: String) -> float:
	var t := 0.0
	for r: Dictionary in history:
		t += float(r.get(key, 0))
	return t


func _avg(rows: Array, key: String) -> float:
	if rows.is_empty():
		return 0.0
	var t := 0.0
	for r: Dictionary in rows:
		t += float(r.get(key, 0))
	return t / float(rows.size())
