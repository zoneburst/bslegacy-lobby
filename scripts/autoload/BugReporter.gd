extends Node
##
## In-game bug reporting.
##
## Reports are always written to user://reports/ as JSON first and only then
## attempted over the network. Since 0.23.0 "over the network" is the online
## lobby: the report travels on the lobby connection (the only way out of a
## browser) and the lobby forwards it to the team's Discord channel. A report that reaches the disk is never lost to
## a flaky connection, and the same file is what a user attaches to a forum
## post when they are offline entirely.
##
## Each report automatically carries: build version, OS, the last 80 log lines,
## the current route, and -- if a game is running -- the full action log, which
## is enough to replay the exact bug deterministically because the engine is
## seeded (see GameState.seed_value).
##

const REPORT_DIR := "user://reports"

var endpoint: String = ""     # optional HTTPS collector; blank disables upload
var last_game_snapshot: Dictionary = {}

signal report_saved(path: String)
signal report_uploaded(ok: bool, message: String)


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(REPORT_DIR)


## `category` is one of: rules, network, ui, crash, cards, other.
func submit(category: String, summary: String, details: String,
		include_game_state: bool = true) -> String:
	var report := {
		"version": ProjectSettings.get_setting("application/config/version", "0.0.0"),
		"time": Time.get_datetime_string_from_system(true),
		"category": category,
		"summary": summary,
		"details": details,
		"platform": OS.get_name(),
		"model": OS.get_model_name(),
		"godot": Engine.get_version_info(),
		"route": SceneRouter.current(),
		"player": GameConfig.player_name,
		"log_tail": Log.tail(80),
	}
	if include_game_state and not last_game_snapshot.is_empty():
		report["game"] = last_game_snapshot

	var fname := "report_%d.json" % int(Time.get_unix_time_from_system())
	var path := REPORT_DIR.path_join(fname)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(report, "  "))
		f.close()
		report_saved.emit(path)
		Log.info("BugReporter: wrote %s" % path)
	if not endpoint.is_empty():
		_upload(report)
	last_report = report
	return path


## The last report submitted (0.23.0), for "Copy report" when it could not be
## sent.
var last_report: Dictionary = {}


## Send the last report through the online lobby (0.23.0). Answers with
## Net.report_result(ok, message).
func send_last() -> void:
	Net.send_bug_report(last_report)


## The last report as text a player can paste (itch.io comments, e-mail).
func last_report_text() -> String:
	var r := last_report.duplicate(true)
	r.erase("game")                         # the action log is too long to paste
	return "Battle Spirits Saga Sim bug report\n" + JSON.stringify(r, "  ")


func _upload(report: Dictionary) -> void:
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(result: int, code: int,
			_headers: PackedStringArray, _body: PackedByteArray):
		var ok: bool = result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300
		report_uploaded.emit(ok, "HTTP %d" % code)
		http.queue_free())
	var err := http.request(endpoint, ["Content-Type: application/json"],
			HTTPClient.METHOD_POST, JSON.stringify(report))
	if err != OK:
		report_uploaded.emit(false, "request failed to start")
		http.queue_free()


## Called by GameBoard each turn so a crash mid-match still has context.
func capture_game(engine) -> void:
	if engine == null:
		last_game_snapshot = {}
		return
	last_game_snapshot = {
		"seed": engine.state.seed_value,
		"turn": engine.state.turn_number,
		"step": engine.state.step,
		"checksum": engine.state.checksum(),
		"actions": engine.state.action_log.duplicate(true),
	}


func list_reports() -> Array:
	var out: Array = []
	var dir := DirAccess.open(REPORT_DIR)
	if dir == null: return out
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if f.ends_with(".json"):
			out.append(REPORT_DIR.path_join(f))
		f = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out
