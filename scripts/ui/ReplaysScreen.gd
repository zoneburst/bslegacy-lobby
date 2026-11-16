extends MenuBase
##
## Replays (0.25.0, R-169): your last ten matches -- against the CPU, two
## players on one screen, or online. Watch one on the board, export it as an
## MP4, or delete it. The eleventh match pushes out the oldest.
##

var _list: VBoxContainer


func screen_title() -> String: return "Replays"
func screen_subtitle() -> String: return "Your last %d matches" % ReplayStore.KEEP


func build_content(parent: VBoxContainer) -> void:
	var intro := UITheme.paragraph("Every finished match is kept here, newest first. Watch it again move by move, "
			+ "or export it as an MP4 video to share.", true)
	parent.add_child(intro)
	var panel := UITheme.panel()
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(panel)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)
	_list = UITheme.vbox(UITheme.SP_S)
	_list.name = "ReplayList"
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)
	_fill()


func _fill() -> void:
	for c in _list.get_children():
		c.queue_free()
	var entries := ReplayStore.list()
	if status_label != null:
		status_label.text = "%d of %d kept" % [entries.size(), ReplayStore.KEEP]
	if entries.is_empty():
		_list.add_child(UITheme.body("No replays yet. Finish a match and it appears here.", true))
		return
	for e: Dictionary in entries:
		_list.add_child(_row(e))


func _row(e: Dictionary) -> Control:
	var row := UITheme.hbox(UITheme.SP_M)
	row.name = "Replay_%s" % str(e.get("id", ""))
	var res := str(e.get("result", ""))
	var tint := UITheme.OK if res == "win" else (UITheme.BAD if res == "loss" else UITheme.TEXT_DIM)
	var badge_text: String = str({"win": "WIN", "loss": "LOSS", "draw": "DRAW", "spectated": "WATCHED"}.get(res, res.to_upper()))
	var badge := UITheme.eyebrow(badge_text, tint)
	badge.custom_minimum_size = Vector2(90, 0)
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(badge)
	var col := UITheme.vbox(2)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var k := str(e.get("kind", ""))
	var line := "vs %s" % str(e.get("opponent", "?"))
	if k == "online":
		line = "Online  ·  " + line
	elif k == "hotseat":
		line = "Two players, one screen"
	col.add_child(UITheme.body(line))
	var deck := str(e.get("deck", ""))
	col.add_child(UITheme.body("%s  ·  %d turns%s" % [str(e.get("date", "")).replace("T", " "), int(e.get("turns", 0)),
			("  ·  deck: " + deck) if deck != "" else ""], true, UITheme.FS_SMALL))
	row.add_child(col)
	var id := str(e.get("id", ""))
	var watch := UITheme.primary_button("Watch", func(): _watch(id))
	watch.name = "Watch"
	row.add_child(watch)
	var ex := UITheme.button("Export MP4", func(): ReplayExporter.start(id, self))
	ex.name = "Export"
	row.add_child(ex)
	row.add_child(UITheme.ghost_button("Delete", func():
		Modal.confirm(self, "Delete this replay?", "It cannot be watched or exported afterwards.", func():
			ReplayStore.delete(id)
			_fill(), "Delete", true)))
	return row


func _watch(id: String) -> void:
	var r := MatchService.start_replay(id)
	if not bool(r.get("ok", false)):
		set_status(str(r.get("reason", "")), true)
		return
	SceneRouter.go("game")
