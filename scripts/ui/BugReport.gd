extends MenuBase
##
## Bug reporting.
##
## The form is short on purpose. What makes a report useful is not the prose,
## it is the attached action log: because every game is seeded and every action
## recorded, a maintainer can replay the exact sequence that produced the bug.
## The user only has to describe what looked wrong.
##

var _category := 0
var _summary: LineEdit
var _details: TextEdit
var _include_state: CheckBox
var _past: VBoxContainer

const CATEGORIES := ["rules", "network", "ui", "crash", "cards", "other"]
const CATEGORY_LABELS := [
	"Rules -- something resolved incorrectly",
	"Network -- disconnects, desync, matchmaking",
	"UI -- layout, controls, text",
	"Crash or freeze",
	"Card data -- wrong text, missing card, bad effect",
	"Something else",
]
const CATEGORY_SHORT := ["Rules", "Network", "UI", "Crash", "Card data", "Other"]


func screen_title() -> String: return "Report a Bug"
func screen_subtitle() -> String: return "Help"


func build_content(parent: VBoxContainer) -> void:
	var cols := UITheme.hbox(UITheme.SP_M)
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(cols)

	# The form, as one card (0.16.0): a segmented category row, then the
	# fields, then one primary Submit.
	var form := UITheme.panel()
	form.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(form)
	var v := UITheme.vbox(10)
	form.add_child(v)

	v.add_child(UITheme.display_title("What went wrong?", UITheme.FS_HEAD))
	v.add_child(UITheme.gold_rule(120.0))
	v.add_child(UITheme.eyebrow("Type"))
	var seg := UITheme.segmented(CATEGORY_SHORT, _category, func(i: int):
		_category = i
		_hint.text = str(CATEGORY_LABELS[i]), UITheme.GOLD, 96.0)
	v.add_child(seg)
	_hint = UITheme.body(str(CATEGORY_LABELS[_category]), true, UITheme.FS_SMALL)
	v.add_child(_hint)

	v.add_child(UITheme.spacer(2))
	v.add_child(UITheme.eyebrow("One-line summary"))
	_summary = UITheme.line_edit("e.g. Curse did not destroy the blocker")
	_summary.custom_minimum_size = Vector2(520, 40)
	v.add_child(_summary)

	v.add_child(UITheme.eyebrow("What happened, and what you expected instead"))
	_details = TextEdit.new()
	_details.custom_minimum_size = Vector2(520, 200)
	_details.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_details.placeholder_text = "Steps, the cards involved, and what you expected to happen."
	v.add_child(_details)

	_include_state = CheckBox.new()
	_include_state.text = "Attach the current game state and action log (recommended)"
	_include_state.button_pressed = true
	v.add_child(_include_state)

	v.add_child(UITheme.paragraph(
		("Your report is saved on this device first, then sent to the team through the "
		+ "online lobby. If it cannot be sent, copy it and post it on the game's page.")
		if GameConfig.has_online_lobby() else
		("Reports are saved on this device. No online lobby is set up, so they are not "
		+ "sent anywhere: copy one and post it on the game's page, or attach the file."),
		true, UITheme.FS_SMALL))

	var row := UITheme.hbox(10)
	v.add_child(row)
	var submit := UITheme.hero_button("Submit report", _submit, UITheme.FS_BODY + 1)
	submit.custom_minimum_size = Vector2(220, 50)
	row.add_child(submit)
	if not GameConfig.is_web():           # no folders to open in a browser (0.21.0)
		row.add_child(UITheme.ghost_button("Open reports folder", func():
			OS.shell_open(ProjectSettings.globalize_path("user://reports"))))
	# 0.23.0: when a report could not be sent (or there is no lobby)
	_copy_btn = UITheme.ghost_button("Copy report", func():
		DisplayServer.clipboard_set(BugReporter.last_report_text())
		set_status("Report copied: paste it on the game's page"))
	_copy_btn.visible = false
	row.add_child(_copy_btn)
	_page_btn = UITheme.ghost_button("Open the game's page", func(): OS.shell_open(GameConfig.feedback_url))
	_page_btn.visible = false
	row.add_child(_page_btn)
	v.add_child(UITheme.spacer(6))
	Motion.stagger_in(v.get_children())

	var side := UITheme.panel(Vector2(320, 0))
	cols.add_child(side)
	var sv := UITheme.vbox(8)
	side.add_child(sv)
	sv.add_child(UITheme.display_title("Previous reports", UITheme.FS_HEAD))
	sv.add_child(UITheme.gold_rule(120.0))
	_past = UITheme.vbox(4)
	sv.add_child(_past)
	_refresh_past()


var _hint: Label


func _submit() -> void:
	if _summary.text.strip_edges().length() < 6:
		set_status("Add a short summary first", true)
		return
	var path := BugReporter.submit(
		CATEGORIES[_category],
		_summary.text.strip_edges(),
		_details.text,
		_include_state.button_pressed)
	_summary.text = ""
	_details.text = ""
	_refresh_past()
	if not GameConfig.has_online_lobby():
		set_status("Saved on this device (%s). No online lobby is set up to send it." % path.get_file())
		_offer_copy()
		return
	set_status("Saved. Sending it to the team… (if the lobby was asleep, this takes up to a minute)")
	var answered := [false]
	var on_result := func(ok: bool, message: String) -> void:
		answered[0] = true
		if not is_inside_tree():
			return
		if ok:
			set_status("Report sent -- thank you! (%s)" % message)
		else:
			set_status("Could not send the report (%s). It is saved here; copy it and post it on the game's page." % message, true)
			_offer_copy()
	Net.report_result.connect(on_result, CONNECT_ONE_SHOT)
	BugReporter.send_last()
	await get_tree().create_timer(100.0).timeout
	if not answered[0]:
		if Net.report_result.is_connected(on_result):
			Net.report_result.disconnect(on_result)
		if is_inside_tree():
			set_status("No answer from the online lobby. The report is saved here; copy it and post it on the game's page.", true)
			_offer_copy()


var _copy_btn: Button
var _page_btn: Button


func _offer_copy() -> void:
	if _copy_btn != null:
		_copy_btn.visible = true
	if _page_btn != null:
		_page_btn.visible = not GameConfig.feedback_url.is_empty()


func _refresh_past() -> void:
	for c in _past.get_children():
		c.queue_free()
	var files := BugReporter.list_reports()
	if files.is_empty():
		_past.add_child(UITheme.body("None yet.", true))
		return
	for p in files.slice(maxi(0, files.size() - 12)):
		var row := UITheme.hbox(UITheme.SP_S)
		var dot := UITheme.Dot.new()
		dot.color = UITheme.CORE
		dot.custom_minimum_size = Vector2(8, 8)
		dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(dot)
		row.add_child(UITheme.truncating(p.get_file(), true, UITheme.FS_SMALL))
		_past.add_child(row)
