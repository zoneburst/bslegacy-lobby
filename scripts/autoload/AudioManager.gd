extends Node
##
## Music and SFX playback with a user-overridable asset root.
##
## Lookup order for every clip: user override directory first, then the
## packaged res:// asset. That ordering is the whole mechanism behind
## "drop a file in and it replaces the built-in one" -- no reimport, no
## rebuild. See docs/ASSET_REPLACEMENT_GUIDE.md.
##

var _music := AudioStreamPlayer.new()      # the track playing now
var _music_out := AudioStreamPlayer.new()  # the previous track, fading out
var _fade: Tween = null
var _sfx_pool: Array[AudioStreamPlayer] = []
var _current_track := ""

const SFX_VOICES := 6


func _ready() -> void:
	add_child(_music)
	add_child(_music_out)
	_music.bus = "Master"
	_music_out.bus = "Master"
	for i in SFX_VOICES:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_sfx_pool.append(p)
	GameConfig.settings_changed.connect(_apply_volumes)
	_apply_volumes()


func _music_level() -> float:
	return 0.0 if GameConfig.mute else GameConfig.music_volume


func _set_level(x: float, player: AudioStreamPlayer) -> void:
	player.volume_db = linear_to_db(maxf(_music_level() * x, 0.0001))


func _apply_volumes() -> void:
	if _fade == null or not _fade.is_running():
		_set_level(1.0, _music)
	var s := 0.0 if GameConfig.mute else GameConfig.sfx_volume
	for p in _sfx_pool:
		p.volume_db = linear_to_db(max(s, 0.0001))


## `name` is a bare filename without extension, e.g. "menu_theme".
## A new track CROSSFADES with the old one over `fade` seconds (0.7.1): the
## battle theme blends into the pinch theme instead of cutting. `loop = false`
## is for jingles (victory, defeat).
func play_music(track: String, loop: bool = true, fade: float = 0.8) -> void:
	if _current_track == track and _music.playing:
		return
	var stream := _load_audio(GameConfig.music_override_dir, "res://assets/music", track)
	if stream == null:
		return
	if stream is AudioStreamOggVorbis:
		stream.loop = loop
	elif stream is AudioStreamMP3:
		stream.loop = loop
	elif stream is AudioStreamWAV:
		# WAV exposes a loop range rather than a bool, and the importer leaves
		# it disabled by default, so a looping track has to be set up here.
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD if loop else AudioStreamWAV.LOOP_DISABLED
		# loop_end is in FRAMES: bytes / (bytes per sample * channels). Until
		# 0.7.1 this ignored the channel count, so a stereo WAV dropped in as
		# a music override got a loop point past its end (R-036).
		var wav := stream as AudioStreamWAV
		var bytes_per_frame := (2 if wav.format == AudioStreamWAV.FORMAT_16_BITS else 1) \
				* (2 if wav.stereo else 1)
		wav.loop_begin = 0
		wav.loop_end = floori(wav.data.size() / float(bytes_per_frame))
	if _fade != null and _fade.is_valid():
		_fade.kill()
	_music_out.stop()
	var old := _music
	_music = _music_out
	_music_out = old
	_music.stream = stream
	_current_track = track
	if fade <= 0.0 or not _music_out.playing:
		_music_out.stop()
		_set_level(1.0, _music)
		_music.play()
		return
	_set_level(0.0, _music)
	_music.play()
	_fade = create_tween()
	_fade.set_parallel(true)
	_fade.tween_method(_set_level.bind(_music), 0.0, 1.0, fade)
	_fade.tween_method(_set_level.bind(_music_out), 1.0, 0.0, fade)
	_fade.chain().tween_callback(_music_out.stop)


func current_track() -> String:
	return _current_track


func stop_music() -> void:
	if _fade != null and _fade.is_valid():
		_fade.kill()
	_music.stop()
	_music_out.stop()
	_current_track = ""


func play_sfx(track: String) -> void:
	var stream := _load_audio("user://assets/sfx", "res://assets/sfx", track)
	if stream == null:
		return
	for p in _sfx_pool:
		if not p.playing:
			p.stream = stream
			p.play()
			return
	_sfx_pool[0].stream = stream
	_sfx_pool[0].play()


func _load_audio(user_dir: String, res_dir: String, stem: String) -> AudioStream:
	for ext in [".ogg", ".mp3", ".wav"]:
		var upath := "%s/%s%s" % [user_dir, stem, ext]
		if FileAccess.file_exists(upath):
			return _load_external(upath)
	for ext in [".ogg", ".mp3", ".wav"]:
		var rpath := "%s/%s%s" % [res_dir, stem, ext]
		if ResourceLoader.exists(rpath):
			return load(rpath)
	return null


## Files under user:// are not imported resources, so they must be decoded by
## hand rather than via load().
func _load_external(path: String) -> AudioStream:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var bytes := f.get_buffer(f.get_length())
	f.close()
	if path.ends_with(".ogg"):
		return AudioStreamOggVorbis.load_from_buffer(bytes)
	if path.ends_with(".mp3"):
		var mp3 := AudioStreamMP3.new()
		mp3.data = bytes
		return mp3
	if path.ends_with(".wav"):
		return AudioStreamWAV.load_from_buffer(bytes, {})
	return null
