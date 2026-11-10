extends Node
##
## Command-line entry point.
##
## Attached to the StartScreen scene tree via an autoload-free path: the
## StartScreen itself checks for --server before building any UI, because a
## headless server has no viewport to build one in.
##
## Recognised arguments (everything after a bare `--`):
##   --server            run as the authoritative lobby server
##   --ws                (with --server) listen for WebSockets instead of ENet
##                       -- for browsers and hosts such as Render (0.23.0)
##   --port <n>          port to bind or connect to; a server with no --port
##                       uses the PORT environment variable when set (Render
##                       sets it), else the lobby port
##   --host <addr>       lobby address for a client
##   --name <string>     display name
##   --rebuild-db        reload the card database and exit (CI smoke test)
##
## Example:
##   godot --headless -- --server --port 8910
##   godot --headless -- --server --ws            (on Render: port from $PORT)
##

static func parse_args() -> Dictionary:
	var out := {"server": false, "ws": false, "port": 0, "host": "", "name": "", "rebuild_db": false}
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		match args[i]:
			"--server": out["server"] = true
			"--ws": out["ws"] = true
			"--rebuild-db": out["rebuild_db"] = true
			"--port":
				i += 1
				if i < args.size(): out["port"] = int(args[i])
			"--host":
				i += 1
				if i < args.size(): out["host"] = args[i]
			"--name":
				i += 1
				if i < args.size(): out["name"] = args[i]
		i += 1
	return out


## Returns true when the process took over as a server and the UI should not
## be built.
static func maybe_run_server(tree: SceneTree) -> bool:
	var args := parse_args()
	if not args["server"]:
		if not str(args["host"]).is_empty():
			GameConfig.lobby_host = str(args["host"])
		if int(args["port"]) > 0:
			GameConfig.lobby_port = int(args["port"])
		if not str(args["name"]).is_empty():
			GameConfig.player_name = str(args["name"])
		return false
	var port: int = int(args["port"])
	if port <= 0 and OS.get_environment("PORT").is_valid_int():
		port = int(OS.get_environment("PORT"))
	if port <= 0:
		port = GameConfig.lobby_port if GameConfig.lobby_port > 0 else 8910
	if not Net.start_server(port, 400, bool(args["ws"])):
		Log.error("Boot: server failed to start, exiting")
		tree.quit(1)
	return true
