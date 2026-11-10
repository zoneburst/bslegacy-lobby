extends Node
##
## Tiny logging façade. Everything else in the project logs through here so
## that a single switch controls verbosity, and so that log lines can be piped
## into the in-game bug reporter (BugReporter attaches the tail of this buffer
## to every report, which is the difference between a useful bug report and
## "it crashed").
##

enum Level { DEBUG, INFO, WARN, ERROR }

## Indexed by Level. Declared as a typed constant rather than written inline at
## the point of use: indexing an inline array literal yields Variant, and
## assigning that with := is a parse error under Godot's default warning levels.
const LEVEL_TAGS: Array[String] = ["DBG", "INF", "WRN", "ERR"]

var min_level: int = Level.INFO
var buffer: Array[String] = []
const BUFFER_MAX := 400

signal line_written(text: String)


func _write(level: int, text: String) -> void:
	if level < min_level:
		return
	var stamp := Time.get_time_string_from_system()
	var tag: String = LEVEL_TAGS[level]
	var line := "[%s] %s %s" % [stamp, tag, text]
	buffer.append(line)
	if buffer.size() > BUFFER_MAX:
		buffer = buffer.slice(buffer.size() - BUFFER_MAX)
	print(line)
	line_written.emit(line)


func debug(t: String) -> void: _write(Level.DEBUG, t)
func info(t: String) -> void: _write(Level.INFO, t)
func warn(t: String) -> void: _write(Level.WARN, t)
func error(t: String) -> void: _write(Level.ERROR, t)


func tail(n: int = 80) -> String:
	var start := maxi(0, buffer.size() - n)
	return "\n".join(buffer.slice(start))
