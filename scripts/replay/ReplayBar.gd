class_name ReplayBar
extends PanelContainer
##
## The control strip on the board while a replay plays (0.25.0, R-169):
## pause / play, one action at a time, speed, back to the start, progress,
## export as MP4 and leave. Hidden while a replay is being recorded to video.
##

var _play: Button
var _progress: ProgressBar
var _count: Label
var _speed_btns: Array = []


func _ready() -> void:
	name = "ReplayBar"
	add_theme_stylebox_override("panel", UITheme._panel_box(Color(UITheme.SURFACE, 0.94)))
	var row := UITheme.hbox(UITheme.SP_S)
	add_child(row)
	var tag := UITheme.eyebrow("REPLAY", UITheme.GOLD)
	tag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(tag)
	_play = UITheme.button("Pause", _toggle)
	_play.name = "ReplayPlay"
	row.add_child(_play)
	var step := UITheme.button("Step", func(): MatchService.replay_step())
	step.tooltip_text = "Paused: apply the next action"
	row.add_child(step)
	row.add_child(UITheme.button("Restart", func(): MatchService.replay_restart()))
	for sp: float in [1.0, 2.0, 4.0]:
		var b := UITheme.button("%dx" % int(sp), _set_speed.bind(sp))
		b.toggle_mode = true
		b.button_pressed = is_equal_approx(MatchService.replay_speed, sp)
		_speed_btns.append(b)
		row.add_child(b)
	_progress = ProgressBar.new()
	_progress.custom_minimum_size = Vector2(180, 10)
	_progress.show_percentage = false
	_progress.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_progress.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_progress)
	_count = UITheme.body("", true, UITheme.FS_SMALL)
	row.add_child(_count)
	var export_btn := UITheme.button("Export MP4", func(): ReplayExporter.start(MatchService.replay_id, get_tree().current_scene))
	export_btn.name = "ReplayExport"
	export_btn.tooltip_text = "Save this replay as a video file"
	row.add_child(export_btn)
	row.add_child(UITheme.ghost_button("Leave", func():
		MatchService.end_match()
		SceneRouter.go("replays")))
	MatchService.replay_progress.connect(_on_progress)
	_on_progress(MatchService.replay_index(), MatchService.replay_total())
	visible = not MatchService.replay_recording


func _toggle() -> void:
	MatchService.replay_paused = not MatchService.replay_paused
	_play.text = "Play" if MatchService.replay_paused else "Pause"


func _set_speed(sp: float) -> void:
	MatchService.replay_speed = sp
	GameConfig.card_animation_speed = sp
	for i in _speed_btns.size():
		(_speed_btns[i] as Button).button_pressed = is_equal_approx([1.0, 2.0, 4.0][i], sp)


func _on_progress(i: int, total: int) -> void:
	if _progress == null:
		return
	_progress.max_value = maxi(1, total)
	_progress.value = i
	_count.text = "%d / %d" % [i, total]
