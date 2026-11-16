class_name ReplayExporter
extends Node
##
## Export a replay as a video (0.25.0, R-169).
##
## Desktop: a second copy of the game is started with Godot's Movie Maker
## (--write-movie, 30 frames a second, 1280x720) and plays the replay; it
## writes an AVI (MJPEG + sound) and quits. FFmpeg then makes the MP4:
##   * Windows: the FFmpeg that ships with the game (ffmpeg/ffmpeg.exe next to
##     the game, or tools/ffmpeg/win64/ffmpeg.exe in the project) -- a small
##     LGPL build that encodes H.264 with Windows' own encoder (Media
##     Foundation), or MPEG-4 if that encoder is missing;
##   * macOS / Linux: the system's ffmpeg if installed (H.264 via libx264,
##     else MPEG-4). Without one the AVI is kept and the player is told.
## The MP4 goes to the Videos folder, under BSLegacy/.
##
## Web: the browser records the game's canvas (MediaRecorder) while the
## replay plays in the page, then downloads it: MP4 in Chrome, Edge and
## Safari, WebM in Firefox (which cannot record MP4). No sound on the web.
##
## BSL_FFMPEG (environment): use this ffmpeg instead (tests).
##

const FPS := 30
const SIZE := "1280x720"

var _id := ""
var _speed := 2.0
var _host: Node = null
var _modal: Modal = null
var _status: Label = null
var _bar: ProgressBar = null
var _pid := -1
var _avi := ""
var _thread: Thread = null
var _result: Dictionary = {}


## Open the export dialog for replay `id` over `host`.
static func start(id: String, host: Node) -> void:
	if id.is_empty() or host == null:
		return
	var ex := ReplayExporter.new()
	ex._id = id
	ex._host = host
	host.get_tree().root.add_child(ex)
	ex._ask()


func _ask() -> void:
	var m := Modal.open(_host, "Export as MP4", 560.0)
	m.name = "ExportDialog"
	var web := OS.has_feature("web")
	m.body.add_child(UITheme.paragraph(
			"The replay plays from the start while it is recorded. " + (
			"Your browser saves the video when it ends (MP4 in Chrome, Edge and Safari; WebM in Firefox). Keep this tab open." if web else
			"A second game window opens and plays it; leave it running until it closes. The MP4 is saved in your Videos folder."), true))
	m.body.add_child(UITheme.eyebrow("Speed", UITheme.GOLD))
	var speeds := [1.0, 2.0, 4.0]
	var seg := UITheme.segmented(["1x (real time)", "2x", "4x"], 1, func(i: int): _speed = speeds[i])
	m.body.add_child(seg)
	m.buttons.add_child(UITheme.button("Cancel", func():
		m.close()
		queue_free()))
	m.buttons.add_child(UITheme.grow())
	m.buttons.add_child(UITheme.primary_button("Record", func():
		m.close()
		if web:
			_web_record()
		else:
			_desktop_record()))


# --------------------------------------------------------------- desktop ----

func _progress_modal(title: String, line: String) -> void:
	_modal = Modal.open(_host, title, 560.0)
	_modal.name = "ExportProgress"
	_status = UITheme.paragraph(line, true)
	_modal.body.add_child(_status)
	_bar = ProgressBar.new()
	_bar.custom_minimum_size = Vector2(480, 12)
	_bar.show_percentage = false
	_modal.body.add_child(_bar)


static func export_dir() -> String:
	var v := OS.get_system_dir(OS.SYSTEM_DIR_MOVIES)
	if v.is_empty() or not DirAccess.dir_exists_absolute(v):
		return ProjectSettings.globalize_path(ReplayStore.DIR + "/videos")
	return v.path_join("BSLegacy")


## The arguments of the recording copy of the game.
static func child_args(id: String, avi: String, speed: float) -> PackedStringArray:
	var args := PackedStringArray()
	if not OS.has_feature("template"):
		args.append_array(["--path", ProjectSettings.globalize_path("res://")])
	# the same renderer as this copy (OpenGL under a virtual display, 0.25.0 tests)
	args.append_array(["--rendering-driver", RenderingServer.get_current_rendering_driver_name()])
	args.append_array(["--write-movie", avi, "--fixed-fps", str(FPS), "--resolution", SIZE,
			"--", "--replay-export=" + id, "--replay-speed=" + str(speed),
			"--replay-dir=" + ProjectSettings.globalize_path(ReplayStore.DIR)])
	return args


func _desktop_record() -> void:
	var work := ProjectSettings.globalize_path(ReplayStore.DIR + "/export")
	DirAccess.make_dir_recursive_absolute(work)
	_avi = work.path_join(_id + ".avi")
	DirAccess.remove_absolute(_avi)
	DirAccess.remove_absolute(work.path_join(_id + ".progress"))
	_pid = OS.create_process(OS.get_executable_path(), child_args(_id, _avi, _speed))
	if _pid <= 0:
		_done("The recording window could not be started.", "")
		return
	_progress_modal("Recording the replay", "The replay is playing in a second window. Leave it running; it closes by itself.")
	_poll_child.call_deferred(work.path_join(_id + ".progress"))


func _poll_child(progress_file: String) -> void:
	while OS.is_process_running(_pid):
		await get_tree().create_timer(0.5).timeout
		var f := FileAccess.open(progress_file, FileAccess.READ)
		if f != null and _bar != null:
			var parts := f.get_as_text().strip_edges().split("/")
			if parts.size() == 2 and int(parts[1]) > 0:
				_bar.max_value = int(parts[1])
				_bar.value = int(parts[0])
	if not FileAccess.file_exists(_avi):
		_done("The recording did not produce a video. Try again, or send a bug report.", "")
		return
	_status.text = "Making the MP4…"
	_bar.value = _bar.max_value
	_thread = Thread.new()
	_thread.start(_convert.bind(_avi, _mp4_path()))
	while _thread.is_alive():
		await get_tree().create_timer(0.25).timeout
	_thread.wait_to_finish()
	_thread = null
	var r := _result
	if bool(r.get("ok", false)):
		DirAccess.remove_absolute(_avi)
		_done("Saved: %s" % str(r["path"]), str(r["path"]))
	elif str(r.get("ffmpeg", "")) == "":
		var keep := _mp4_path().get_basename() + ".avi"
		DirAccess.make_dir_recursive_absolute(keep.get_base_dir())
		DirAccess.rename_absolute(_avi, keep)
		_done("FFmpeg was not found, so the video was kept as an AVI file:\n%s\n\nInstall FFmpeg (for example with Homebrew on macOS or your package manager on Linux) to get MP4s." % keep, keep)
	else:
		_done("FFmpeg could not convert the video (%s). The AVI was kept: %s" % [str(r.get("error", "")), _avi], _avi)


func _mp4_path() -> String:
	var e := ReplayStore.entry(_id)
	var who := str(e.get("opponent", "replay")).validate_filename().replace(" ", "_")
	return export_dir().path_join("BSLegacy_%s_vs_%s.mp4" % [_id, who])


## The ffmpeg to use: BSL_FFMPEG, the one shipped with the game (Windows),
## or the system's. "" when there is none.
static func find_ffmpeg() -> String:
	var env := OS.get_environment("BSL_FFMPEG")
	if not env.is_empty() and FileAccess.file_exists(env):
		return env
	var cands: Array = []
	if OS.get_name() == "Windows":
		cands.append(OS.get_executable_path().get_base_dir().path_join("ffmpeg/ffmpeg.exe"))
		cands.append(ProjectSettings.globalize_path("res://tools/ffmpeg/win64/ffmpeg.exe"))
	else:
		cands.append_array(["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"])
	for c: String in cands:
		if FileAccess.file_exists(c):
			return c
	if OS.get_name() != "Windows" and OS.execute("ffmpeg", ["-version"]) == 0:
		return "ffmpeg"
	return ""


## The encoders to try, best first: Media Foundation H.264 for our Windows
## build, libx264 for a full system ffmpeg, MPEG-4 Part 2 everywhere.
static func encoder_args(ffmpeg: String) -> Array:
	var out: Array = []
	var shipped := ffmpeg.ends_with("ffmpeg.exe") and ffmpeg.contains("ffmpeg")
	if shipped:
		out.append(["-c:v", "h264_mf", "-b:v", "6M", "-pix_fmt", "nv12"])
	else:
		out.append(["-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p"])
	out.append(["-c:v", "mpeg4", "-q:v", "3", "-pix_fmt", "yuv420p"])
	return out


## AVI -> MP4 (runs in a thread). Fills _result.
func _convert(avi: String, mp4: String) -> void:
	_result = convert_file(avi, mp4)


static func convert_file(avi: String, mp4: String) -> Dictionary:
	var ff := find_ffmpeg()
	if ff.is_empty():
		return {"ok": false, "ffmpeg": ""}
	DirAccess.make_dir_recursive_absolute(mp4.get_base_dir())
	var last := ""
	for enc: Array in encoder_args(ff):
		var args: Array = ["-y", "-loglevel", "error", "-i", avi]
		args.append_array(enc)
		args.append_array(["-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart", mp4])
		var out: Array = []
		var code := OS.execute(ff, PackedStringArray(args), out, true)
		if code == 0 and FileAccess.file_exists(mp4):
			return {"ok": true, "path": mp4, "ffmpeg": ff, "encoder": enc[1]}
		last = "".join(out).strip_edges().substr(0, 200)
	return {"ok": false, "ffmpeg": ff, "error": last}


func _done(text: String, path: String) -> void:
	if _modal != null and is_instance_valid(_modal):
		_modal.close()
	var m := Modal.open(_host, "Export", 600.0)
	m.name = "ExportDone"
	m.body.add_child(UITheme.paragraph(text, true))
	if not path.is_empty():
		m.buttons.add_child(UITheme.button("Show in folder", func(): OS.shell_show_in_file_manager(path)))
	m.buttons.add_child(UITheme.grow())
	m.buttons.add_child(UITheme.primary_button("OK", func():
		m.close()
		queue_free()))


# ------------------------------------------------------------------- web ----

const JS_START := """
(function(){
  var c = document.querySelector('canvas');
  if (!c || !c.captureStream || typeof MediaRecorder === 'undefined') { return 'unsupported'; }
  var types = ['video/mp4;codecs=avc1.42E01E', 'video/mp4', 'video/webm;codecs=vp9', 'video/webm;codecs=vp8', 'video/webm'];
  var t = '';
  for (var i = 0; i < types.length; i++) { if (MediaRecorder.isTypeSupported(types[i])) { t = types[i]; break; } }
  var r = new MediaRecorder(c.captureStream(30), t ? {mimeType: t, videoBitsPerSecond: 6000000} : {});
  var chunks = [];
  window.bslRecDone = false;
  r.ondataavailable = function(e){ if (e.data && e.data.size) chunks.push(e.data); };
  r.onstop = function(){
    var type = t || 'video/webm';
    var blob = new Blob(chunks, {type: type});
    var a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = (window.bslRecName || 'BSLegacy_replay') + (type.indexOf('mp4') >= 0 ? '.mp4' : '.webm');
    document.body.appendChild(a); a.click();
    setTimeout(function(){ URL.revokeObjectURL(a.href); a.remove(); }, 5000);
    window.bslRecDone = true;
  };
  r.start(1000);
  window.bslRec = r;
  return t || 'video/webm';
})()
"""


func _web_record() -> void:
	JavaScriptBridge.eval("window.bslRecName = %s;" % JSON.stringify("BSLegacy_" + _id), true)
	var r := MatchService.start_replay(_id)
	if not bool(r.get("ok", false)):
		_done(str(r.get("reason", "")), "")
		return
	MatchService.replay_recording = true
	MatchService.replay_speed = _speed
	GameConfig.card_animation_speed = _speed
	SceneRouter.go("game")
	await get_tree().create_timer(1.0).timeout
	var t: Variant = JavaScriptBridge.eval(JS_START, true)
	if str(t) == "unsupported":
		MatchService.replay_recording = false
		_host = get_tree().current_scene
		_done("This browser cannot record the game. Try Chrome, Edge, Safari or Firefox.", "")
		return
	await MatchService.replay_finished
	await get_tree().create_timer(1.5).timeout
	JavaScriptBridge.eval("if (window.bslRec) window.bslRec.stop();", true)
	MatchService.replay_recording = false
	_host = get_tree().current_scene
	_done("Your browser is saving the video (%s)." % ("MP4" if str(t).contains("mp4") else "WebM"), "")
