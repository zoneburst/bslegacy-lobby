extends Node
##
## Networking front door.
##
## Topology: one authoritative lobby server per game group. Clients never
## simulate the opponent's turn and never see hidden zones -- the server owns
## the one true RulesEngine per match and pushes each client a redacted
## snapshot (with a replica the board reads, 0.16.8).
##
## Three ways to be online (0.16.9):
##   * HOST   -- "Host on this computer" on the Battle screen. This game runs
##               the lobby server inside itself AND plays in it as peer 1. The
##               friend joins with this computer's address. Nothing else to
##               install or run. (Before 0.16.9 a game could only ever be a
##               client, so without a separately started server no room code
##               could ever appear.)
##   * CLIENT -- joining someone's address (a HOST or a dedicated server).
##   * SERVER -- a dedicated headless lobby, for a group that wants one always
##               on:   godot --headless -- --server --port 8910
##               (Boot.gd hands control to LobbyServer instead of the menu.)
##
## Two transports (0.23.0):
##   * ENet (UDP) -- the desktop game, hosting on your own computer, and a
##     lobby addressed as "host:port".
##   * WebSocket -- a lobby addressed as a ws:// or wss:// URL, e.g. one on
##     Render ("wss://bslegacy-lobby.onrender.com"). Browsers (the web build,
##     itch.io) can only use this one; the desktop game can use either. A
##     server started with `--server --ws` listens for WebSockets instead of
##     ENet. The same RPCs run over both.
##
## In HOST mode the local player's calls go straight into LobbyServer with
## peer id 1, and the server's pushes to peer 1 are delivered locally, in
## order (call_deferred). Remote players use the same RPCs as with a
## dedicated server, so both paths run the same server code.
##
## Bot matches bypass all of this: MatchService runs a local engine with no
## peer at all, so the game is fully playable offline.
##

enum Mode { OFFLINE, CLIENT, SERVER, HOST }

const CONNECT_TIMEOUT := 8.0          # seconds before "no answer" (ENet alone waits ~30 s)
## A WebSocket lobby on a free host (Render) sleeps after 15 minutes without
## traffic and takes about a minute to wake: wait that long before giving up.
const WAKE_TIMEOUT := 90.0
## While connected over WebSocket, a small message this often keeps a free
## host from putting the lobby to sleep mid-game (Render counts inbound
## WebSocket messages as activity).
const KEEPALIVE_EVERY := 240.0
## Big enough for a full game state or a bug report with its action log.
const WS_BUFFER := 1 << 22

var mode: int = Mode.OFFLINE
var peer: MultiplayerPeer = null
var transport := "enet"                 # "enet" or "ws" (0.23.0)
var _keepalive := 0.0
var my_id: int = 0
var connected: bool = false
var server_script: LobbyServer = null   # non-null when this process runs the lobby (SERVER, HOST)
var host_port: int = 0                  # the port being hosted on (HOST, SERVER)
var target := ""                        # "address:port" of the last connection attempt

# Populated from server pushes so the UI can render without asking.
var lobby_status: String = ""
var current_room_code: String = ""
var room_members: Array = []

var _connect_token := 0

# Automatic router setup when hosting (UPnP, 0.17.0). See _router_job().
#   router_state: "off" (not tried), "working", "open" (the port is open to
#   the internet at public_address), "failed" (no router answered, or it
#   refused), "shared" (the internet address is shared by the provider --
#   CGNAT -- so nobody outside can reach this computer at all).
var router_state := "off"
var public_address := ""
var lan_address := ""                   # this computer's address as the router sees it
var router_note := ""
var _router_thread: Thread = null
var _upnp: UPNP = null
var _upnp_port := 0

signal connection_changed(connected: bool)
signal connection_failed(reason: String)
signal lobby_message(kind: String, data: Dictionary)
signal match_found(data: Dictionary)
signal match_state(snapshot: Dictionary)
signal match_ended(data: Dictionary)
signal room_updated(data: Dictionary)
signal hosting_changed(hosting: bool)
signal router_changed(state: String)


func _ready() -> void:
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_failed)
	multiplayer.server_disconnected.connect(_on_disconnected)


func is_hosting() -> bool:
	return mode == Mode.HOST


func _is_server() -> bool:
	return mode == Mode.SERVER or mode == Mode.HOST


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

## Returns "" on success, or a sentence saying what went wrong.
func _listen(port: int, max_clients: int, ws: bool = false) -> String:
	var err := OK
	if ws:
		var wp := WebSocketMultiplayerPeer.new()
		_size_ws(wp)
		err = wp.create_server(port, "*")
		peer = wp
		transport = "ws"
	else:
		var ep := ENetMultiplayerPeer.new()
		err = ep.create_server(port, max_clients)
		peer = ep
		transport = "enet"
	if err != OK:
		peer = null
		if err == ERR_ALREADY_IN_USE or err == ERR_CANT_CREATE:
			return "Port %d is already in use on this computer (another copy of the game, or a server, is using it). Close it or pick another port in Settings." % port
		return "Could not open port %d (error %d)." % [port, err]
	multiplayer.multiplayer_peer = peer
	# Clients never talk to each other, so the server does not relay peer
	# joins and leaves between them (0.16.8). Relaying also sent notices to
	# peers that were themselves dropping ("Unable to send packet").
	var sm := multiplayer as SceneMultiplayer
	if sm != null:
		sm.server_relay = false
	host_port = port
	my_id = 1
	server_script = LobbyServer.new()
	add_child(server_script)
	return ""


## A dedicated server (no local player). `ws` = WebSockets (0.23.0, for
## browsers and hosts such as Render) instead of ENet.
func start_server(port: int, max_clients: int = 400, ws: bool = false) -> bool:
	var why := _listen(port, max_clients, ws)
	if why != "":
		Log.error("Net: " + why)
		return false
	mode = Mode.SERVER
	Log.info("Net: server listening on %d (%s)" % [port, "WebSocket" if ws else "ENet"])
	return true


func _size_ws(wp: WebSocketMultiplayerPeer) -> void:
	wp.inbound_buffer_size = WS_BUFFER
	wp.outbound_buffer_size = WS_BUFFER
	wp.max_queued_packets = 4096


## True for a WebSocket lobby address ("ws://..." or "wss://...").
func is_ws_url(s: String) -> bool:
	var t := s.strip_edges().to_lower()
	return t.begins_with("ws://") or t.begins_with("wss://")


## Host on this computer (0.16.9): run the lobby here and play in it.
## Returns "" on success, or why it failed.
func host(port: int) -> String:
	if mode == Mode.HOST:
		return ""
	if mode != Mode.OFFLINE:
		disconnect_from_server()
	var why := _listen(port, 16)
	if why != "":
		Log.warn("Net: hosting failed: " + why)
		return why
	mode = Mode.HOST
	connected = true
	target = "this computer:%d" % port
	_start_router(port)
	lobby_status = "Hosting on port %d" % port
	server_script.register(1, GameConfig.player_name,
			str(ProjectSettings.get_setting("application/config/version", "0.0.0")))
	Log.info("Net: hosting on port %d" % port)
	connection_changed.emit(true)
	hosting_changed.emit(true)
	return ""


## The addresses another computer can use to reach this one (IPv4, not
## loopback or link-local), private-network ones first.
func local_addresses() -> Array:
	# The address the router itself sees us at is the right one, when known.
	var first: Array = [lan_address] if lan_address != "" else []
	var ranked: Array = []
	for itf: Dictionary in IP.get_local_interfaces():
		var nm := (str(itf.get("name", "")) + " " + str(itf.get("friendly", ""))).to_lower()
		for a: String in itf.get("addresses", []):
			if a.contains(":") or a.begins_with("127.") or a.begins_with("169.254.") or first.has(a):
				continue
			ranked.append([_adapter_rank(nm, a), a])
	if ranked.is_empty():
		for a2: String in IP.get_local_addresses():
			if not (a2.contains(":") or a2.begins_with("127.") or a2.begins_with("169.254.")):
				ranked.append([_adapter_rank("", a2), a2])
	ranked.sort_custom(func(x: Array, y: Array) -> bool: return int(x[0]) < int(y[0]))
	var out: Array = first.duplicate()
	for r: Array in ranked:
		if not out.has(r[1]):
			out.append(r[1])
	return out


## Lower is better: a real network card before the virtual adapters that
## Docker, VirtualBox, VMware, Hyper-V and WSL add (their addresses lead
## nowhere for a friend), private addresses before others (0.17.0).
static func _adapter_rank(nm: String, a: String) -> int:
	var rank := 10
	for v: String in ["docker", "br-", "veth", "virbr", "vbox", "virtualbox", "vmnet", "vmware", "vethernet",
			"hyper-v", "wsl", "default switch", "podman", "lxc", "lxd", "utun", "awdl", "llw"]:
		if nm.contains(v):
			rank += 50
	for good: String in ["eth", "en", "wl", "wi-fi", "wifi", "wlan", "ethernet", "local area connection"]:
		if nm.begins_with(good) or nm.contains(" " + good):
			rank -= 5
	if a.begins_with("172.17.") or a.begins_with("192.168.56."):   # Docker's and VirtualBox's defaults
		rank += 20
	var p := a.split(".")
	var is_private := a.begins_with("10.") or a.begins_with("192.168.") or \
			(a.begins_with("172.") and p.size() > 1 and int(p[1]) >= 16 and int(p[1]) <= 31)
	return rank + (0 if is_private else 3)


## "192.168.1.20" or "192.168.1.20:8910" -> [address, port]. A WebSocket
## URL is kept whole, with port 0 (the URL says everything, 0.23.0).
func parse_address(text: String, default_port: int) -> Array:
	var t := text.strip_edges()
	if is_ws_url(t):
		return [t, 0]
	var port := default_port
	if t.count(":") == 1:
		var parts := t.split(":")
		t = parts[0].strip_edges()
		if parts[1].strip_edges().is_valid_int():
			port = int(parts[1])
	return [t, port]


func connect_to_server(host_addr: String, port: int, timeout: float = CONNECT_TIMEOUT) -> bool:
	if mode == Mode.HOST:
		stop_hosting()
	elif mode == Mode.CLIENT:
		disconnect_from_server()
	if host_addr.strip_edges().is_empty():
		connection_failed.emit("no address entered")
		connection_changed.emit(false)
		return false
	target = "%s:%d" % [host_addr, port]
	var err := OK
	if is_ws_url(host_addr):
		var wp := WebSocketMultiplayerPeer.new()
		_size_ws(wp)
		err = wp.create_client(host_addr.strip_edges())
		peer = wp
		transport = "ws"
		timeout = maxf(timeout, WAKE_TIMEOUT)
		_ws_url = host_addr.strip_edges()
		_ws_deadline = Time.get_ticks_msec() / 1000.0 + timeout - 4.0
		# (a new WebSocket connection itself wakes a sleeping Render service;
		# the first tries may fail while it starts, see _on_failed)
	elif GameConfig.is_web():
		# a browser cannot use ENet (UDP): only a ws:// or wss:// lobby works
		connection_changed.emit(false)
		connection_failed.emit("the web version needs a WebSocket lobby (wss://...), not %s" % target)
		return false
	else:
		var ep := ENetMultiplayerPeer.new()
		err = ep.create_client(host_addr, port)
		peer = ep
		transport = "enet"
	if err != OK:
		peer = null
		connection_changed.emit(false)
		connection_failed.emit("could not create a connection to %s" % target)
		return false
	multiplayer.multiplayer_peer = peer
	mode = Mode.CLIENT
	lobby_status = "Connecting to %s…" % target
	if transport == "ws":
		lobby_status = "Connecting to the online lobby… (if it was asleep, this takes up to a minute)"
	# ENet alone gives up after about 30 seconds of silence; a player needs
	# to know sooner that nobody is answering (0.16.9).
	_connect_token += 1
	var tok := _connect_token
	get_tree().create_timer(timeout).timeout.connect(func():
		if tok == _connect_token and mode == Mode.CLIENT and not connected:
			_give_up("no answer from %s after %d seconds" % [target, int(timeout)]))
	return true


func _give_up(reason: String) -> void:
	_connect_token += 1
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	peer = null
	mode = Mode.OFFLINE
	connected = false
	lobby_status = "Connection failed"
	connection_changed.emit(false)
	connection_failed.emit(reason)


func stop_hosting() -> void:
	if mode != Mode.HOST:
		return
	disconnect_from_server()


func disconnect_from_server() -> void:
	var was_hosting := mode == Mode.HOST or mode == Mode.SERVER
	_close_router()
	_connect_token += 1
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	peer = null
	if server_script != null:
		server_script.queue_free()
		server_script = null
	mode = Mode.OFFLINE
	connected = false
	host_port = 0
	current_room_code = ""
	connection_changed.emit(false)
	if was_hosting:
		hosting_changed.emit(false)


func _on_connected() -> void:
	_connect_token += 1
	connected = true
	my_id = multiplayer.get_unique_id()
	lobby_status = "Connected"
	Log.info("Net: connected as peer %d" % my_id)
	rpc_id(1, "s_register", GameConfig.player_name, ProjectSettings.get_setting(
			"application/config/version", "0.0.0"))
	connection_changed.emit(true)


func _on_failed() -> void:
	if mode != Mode.CLIENT:
		return
	# A sleeping lobby answers the first tries with a "starting up" page
	# instead of a WebSocket: keep trying until the wake-up time is over.
	if transport == "ws" and Time.get_ticks_msec() / 1000.0 < _ws_deadline:
		var tok := _connect_token
		get_tree().create_timer(3.0).timeout.connect(func():
			if tok != _connect_token or mode != Mode.CLIENT or connected:
				return
			var wp := WebSocketMultiplayerPeer.new()
			_size_ws(wp)
			if wp.create_client(_ws_url) == OK:
				peer = wp
				multiplayer.multiplayer_peer = wp)
		return
	_give_up("could not reach %s" % target)


var _ws_url := ""
var _ws_deadline := 0.0



func _on_disconnected() -> void:
	connected = false
	lobby_status = "Disconnected"
	current_room_code = ""
	multiplayer.multiplayer_peer = null
	peer = null
	mode = Mode.OFFLINE
	connection_changed.emit(false)


# ---------------------------------------------------------------------------
# Automatic router setup (UPnP, 0.17.0)
# ---------------------------------------------------------------------------
#
# A home router hides the computers behind it: a friend outside can reach the
# host only if the router forwards the port. Most home routers let a program
# ask for that itself (UPnP). When hosting, the game asks -- on a thread,
# since finding the router takes about two seconds -- and puts the router's
# internet address in the invite. If no router answers, or it refuses, or
# the provider shares one internet address among customers (CGNAT, common on
# mobile and some broadband), the invite says so and the online lobby is the
# way to play outside the home network.

func _start_router(port: int) -> void:
	public_address = ""
	router_note = ""
	if not GameConfig.auto_router:
		router_state = "off"
		router_changed.emit(router_state)
		return
	if _router_thread != null:
		return
	router_state = "working"
	router_changed.emit(router_state)
	_router_thread = Thread.new()
	_router_thread.start(_router_job.bind(port))


## Runs on the thread. Touches nothing outside its own UPNP object; hands the
## result back with call_deferred.
func _router_job(port: int) -> void:
	var u := UPNP.new()
	var res := {"state": "failed", "public": "", "note": ""}
	var err := u.discover(2000, 2, "InternetGatewayDevice")
	if err != UPNP.UPNP_RESULT_SUCCESS or u.get_device_count() == 0:
		res["note"] = "No router answered the request to open the port (its UPnP setting may be off)."
	else:
		var gw := u.get_gateway()
		if gw == null or not gw.is_valid_gateway():
			var ext := u.get_device(0).query_external_address() if u.get_device_count() > 0 else ""
			if is_shared_address(ext):
				res["state"] = "shared"
				res["note"] = "Your internet provider shares one internet address among many customers (CGNAT), so friends outside your network cannot reach this computer directly."
			else:
				res["note"] = "Your router answered but would not open a port."
		else:
			var m := u.add_port_mapping(port, port, "Battle Spirits Saga Simulator", "UDP", 0)
			if m != UPNP.UPNP_RESULT_SUCCESS:
				res["note"] = "Your router refused to open the port (UPnP port mapping is off or limited)."
			else:
				var ext2 := u.query_external_address()
				if ext2 == "" or is_shared_address(ext2):
					u.delete_port_mapping(port, "UDP")
					res["state"] = "shared"
					res["note"] = "Your internet provider shares one internet address among many customers (CGNAT), so friends outside your network cannot reach this computer directly."
				else:
					res["state"] = "open"
					res["public"] = ext2
					res["lan"] = str(gw.igd_our_addr)
	_router_done.call_deferred(res, u, port)


func _router_done(res: Dictionary, u: UPNP, port: int) -> void:
	if _router_thread != null:
		_router_thread.wait_to_finish()
		_router_thread = null
	if mode != Mode.HOST or host_port != port:
		# Hosting stopped while the router was being asked: undo it.
		if str(res["state"]) == "open":
			u.delete_port_mapping(port, "UDP")
		return
	router_state = str(res["state"])
	public_address = str(res["public"])
	lan_address = str(res.get("lan", ""))
	router_note = str(res["note"])
	if router_state == "open":
		_upnp = u
		_upnp_port = port
	Log.info("Net: router %s %s %s" % [router_state, public_address, router_note])
	router_changed.emit(router_state)


## Close the port the router opened for us (when hosting stops or the game
## quits), so it is not left open.
func _close_router() -> void:
	if _upnp != null and _upnp_port > 0:
		_upnp.delete_port_mapping(_upnp_port, "UDP")
		Log.info("Net: router port %d closed" % _upnp_port)
	_upnp = null
	_upnp_port = 0
	lan_address = ""
	if router_state != "off":
		router_state = "off"
		public_address = ""
		router_note = ""
		router_changed.emit(router_state)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		if _router_thread != null:
			_router_thread.wait_to_finish()
			_router_thread = null
		_close_router()


## An address that cannot be reached from the internet: private, CGNAT
## (100.64.0.0/10), loopback or link-local.
static func is_shared_address(a: String) -> bool:
	if a == "" or not a.is_valid_ip_address() or a.contains(":"):
		return a == ""
	var p := a.split(".")
	var o0 := int(p[0])
	var o1 := int(p[1])
	return o0 == 10 or o0 == 127 or (o0 == 100 and o1 >= 64 and o1 <= 127) or (o0 == 172 and o1 >= 16 and o1 <= 31) \
			or (o0 == 192 and o1 == 168) or (o0 == 169 and o1 == 254)


# ---------------------------------------------------------------------------
# Invites (0.17.0)
# ---------------------------------------------------------------------------

## What a friend needs, as one line to paste: the code, and the address(es)
## when the room is on this computer rather than on the online lobby.
func invite_text() -> String:
	var code := current_room_code if current_room_code != "" else "------"
	if mode != Mode.HOST:
		return "Battle Spirits Saga Sim room %s" % code
	var lan: Array = local_addresses()
	var lan_a := ("%s:%d" % [lan[0], host_port]) if not lan.is_empty() else ""
	if router_state == "open" and public_address != "":
		return "Battle Spirits Saga Sim room %s at %s:%d (same network: %s)" % [code, public_address, host_port, lan_a]
	return "Battle Spirits Saga Sim room %s at %s (same network only)" % [code, lan_a]


## Reads an invite, or anything a player might paste or type: returns
## {"code": "ABC123" or "", "addresses": [[host, port], ...]} in the order to
## try. A bare code has no addresses (it is on the online lobby).
func parse_invite(text: String, default_port: int) -> Dictionary:
	var t := text.strip_edges()
	var out := {"code": "", "addresses": []}
	var addrs: Array = []
	var rx_addr := RegEx.new()
	# IPv4 or a host name with a dot, optionally :port
	rx_addr.compile("(?<![\\w.-])((?:\\d{1,3}\\.){3}\\d{1,3}|(?:[A-Za-z0-9-]+\\.)+[A-Za-z]{2,})(?::(\\d{1,5}))?(?![\\w.-])")
	var spans: Array = []
	for m: RegExMatch in rx_addr.search_all(t):
		var hostname := m.get_string(1)
		var port := int(m.get_string(2)) if m.get_string(2) != "" else default_port
		addrs.append([hostname, port])
		spans.append([m.get_start(), m.get_end()])
	var rx_code := RegEx.new()
	rx_code.compile("(?<![A-Za-z0-9])([A-Za-z0-9]{6})(?![A-Za-z0-9])")
	for m2: RegExMatch in rx_code.search_all(t):
		var inside := false
		for sp: Array in spans:
			if m2.get_start() >= int(sp[0]) and m2.get_end() <= int(sp[1]):
				inside = true
		var raw := m2.get_string(1)
		var c := raw.to_upper()
		# In a longer message only a token written in capitals counts as the
		# code (so "Battle" is never one); a lone entry may be lower case.
		if inside or not _is_code(c) or (raw != c and t.length() != 6):
			continue
		out["code"] = c
		break
	# Try an address on this computer's own network first (the friend is at
	# home with the host), then the rest in the order given.
	var mine: Array = []
	for a: String in local_addresses():
		mine.append(a.substr(0, a.rfind(".")))
	var near: Array = []
	var far: Array = []
	for ap: Array in addrs:
		var h := str(ap[0])
		var pre := h.substr(0, h.rfind(".")) if h.is_valid_ip_address() else ""
		if pre != "" and mine.has(pre): near.append(ap)
		else: far.append(ap)
	out["addresses"] = near + far
	return out


## A room code: six characters from the lobby's alphabet.
func _is_code(c: String) -> bool:
	if c.length() != 6:
		return false
	for ch in c:
		if not LobbyServer.CODE_ALPHABET.contains(ch):
			return false
	return true


# ---------------------------------------------------------------------------
# Client -> server calls. Each is a thin wrapper so UI code never writes an
# rpc_id by hand and the server's API surface stays visible in one place.
# When hosting, the call goes straight into the local LobbyServer as peer 1.
# ---------------------------------------------------------------------------

## True when a call to the server can be sent. Calls made without a
## connection are dropped quietly instead of raising an engine error.
func _can_send() -> bool:
	if mode == Mode.HOST:
		return server_script != null
	return mode == Mode.CLIENT and connected and multiplayer.multiplayer_peer != null


func _call(method: String, args: Array) -> void:
	if not _can_send():
		return
	if mode == Mode.HOST:
		# Deferred, like a network round trip, so a reply never arrives in the
		# middle of the caller's own code.
		server_script.callv.call_deferred(method, [1] + args)
	else:
		callv("rpc_id", [1, "s_" + method] + args)


func queue_random(deck: Dictionary, opts: Dictionary = {}) -> void:
	_call("queue_random", [deck, opts])

func cancel_queue() -> void:
	_call("cancel_queue", [])

func create_room(deck: Dictionary, opts: Dictionary) -> void:
	_call("create_room", [deck, opts])

func join_room(code: String, deck: Dictionary) -> void:
	_call("join_room", [code.strip_edges().to_upper(), deck])

func spectate_room(code: String) -> void:
	_call("spectate_room", [code.strip_edges().to_upper()])

func leave_room() -> void:
	_call("leave", [])

func send_action(action: Dictionary) -> void:
	_call("handle_action", [action])

func send_chat(text: String) -> void:
	_call("chat", [text.substr(0, 300)])

## 0.24.0: ready for the next game of a best of 3, with this deck
func series_ready(main: Array) -> void:
	_call("series_ready", [main])

## 0.24.0: ask for (or withdraw) a rematch, with this deck
func rematch(main: Array, cancel: bool = false) -> void:
	_call("rematch", [main, cancel])


# ---------------------------------------------------------------------------
# Bug reports through the lobby (0.23.0)
# ---------------------------------------------------------------------------

signal report_result(ok: bool, message: String)

## Send a bug report to the online lobby, which forwards it to the team (a
## Discord channel, see the Online guide). Connects first when needed and
## disconnects again afterwards if it was not connected before. The answer
## arrives as report_result(ok, message).
func send_bug_report(report: Dictionary) -> void:
	var text := JSON.stringify(report)
	if text.length() > 900_000:
		# the game's action log is what makes it large: keep the newest part
		var r2 := report.duplicate(true)
		var game: Dictionary = r2.get("game", {})
		var acts: Array = game.get("actions", [])
		if acts.size() > 400:
			game["actions"] = acts.slice(acts.size() - 400)
			game["actions_trimmed"] = true
		text = JSON.stringify(r2).substr(0, 900_000)
	if mode == Mode.HOST and server_script != null:
		server_script.bug_report.call_deferred(1, text)
		return
	if mode == Mode.CLIENT and connected:
		rpc_id(1, "s_bug_report", text)
		return
	if not GameConfig.has_online_lobby():
		report_result.emit(false, "no online lobby is set up")
		return
	if not connect_to_server(GameConfig.lobby_host, GameConfig.lobby_port):
		report_result.emit(false, "could not connect to the online lobby")
		return
	var up: bool = await connection_changed
	if not up:
		report_result.emit(false, "the online lobby did not answer")
		return
	_close_after_report = true
	rpc_id(1, "s_bug_report", text)


var _close_after_report := false


func _process(delta: float) -> void:
	if mode != Mode.CLIENT or not connected or transport != "ws":
		_keepalive = 0.0
		return
	_keepalive += delta
	if _keepalive >= KEEPALIVE_EVERY:
		_keepalive = 0.0
		rpc_id(1, "s_ping")


# ---------------------------------------------------------------------------
# Server-side RPC entry points. These only ever run on the lobby (peer 1); the
# guard makes a spoofed call from a client a no-op rather than a vulnerability.
# ---------------------------------------------------------------------------

@rpc("any_peer", "call_remote", "reliable")
func s_ping() -> void:
	pass                                  # traffic only: keeps a free host awake

@rpc("any_peer", "call_remote", "reliable")
func s_bug_report(text: String) -> void:
	if not _is_server(): return
	server_script.bug_report(multiplayer.get_remote_sender_id(), text)

@rpc("any_peer", "call_remote", "reliable")
func s_register(display_name: String, version: String) -> void:
	if not _is_server(): return
	server_script.register(multiplayer.get_remote_sender_id(), display_name, version)

@rpc("any_peer", "call_remote", "reliable")
func s_queue_random(deck: Dictionary, opts: Dictionary) -> void:
	if not _is_server(): return
	server_script.queue_random(multiplayer.get_remote_sender_id(), deck, opts)

@rpc("any_peer", "call_remote", "reliable")
func s_series_ready(main: Array) -> void:
	if not _is_server(): return
	server_script.series_ready(multiplayer.get_remote_sender_id(), main)

@rpc("any_peer", "call_remote", "reliable")
func s_rematch(main: Array, cancel: bool) -> void:
	if not _is_server(): return
	server_script.rematch(multiplayer.get_remote_sender_id(), main, cancel)

@rpc("any_peer", "call_remote", "reliable")
func s_cancel_queue() -> void:
	if not _is_server(): return
	server_script.cancel_queue(multiplayer.get_remote_sender_id())

@rpc("any_peer", "call_remote", "reliable")
func s_create_room(deck: Dictionary, opts: Dictionary) -> void:
	if not _is_server(): return
	server_script.create_room(multiplayer.get_remote_sender_id(), deck, opts)

@rpc("any_peer", "call_remote", "reliable")
func s_join_room(code: String, deck: Dictionary) -> void:
	if not _is_server(): return
	server_script.join_room(multiplayer.get_remote_sender_id(), code, deck)

@rpc("any_peer", "call_remote", "reliable")
func s_spectate_room(code: String) -> void:
	if not _is_server(): return
	server_script.spectate_room(multiplayer.get_remote_sender_id(), code)

@rpc("any_peer", "call_remote", "reliable")
func s_leave() -> void:
	if not _is_server(): return
	server_script.leave(multiplayer.get_remote_sender_id())

@rpc("any_peer", "call_remote", "reliable")
func s_handle_action(action: Dictionary) -> void:
	if not _is_server(): return
	server_script.handle_action(multiplayer.get_remote_sender_id(), action)

@rpc("any_peer", "call_remote", "reliable")
func s_chat(text: String) -> void:
	if not _is_server(): return
	server_script.chat(multiplayer.get_remote_sender_id(), text.substr(0, 300))


# ---------------------------------------------------------------------------
# Server -> client pushes.
# ---------------------------------------------------------------------------

func push(peer_id: int, kind: String, data: Dictionary) -> void:
	# The host's own player is peer 1 in this process: deliver it here, in
	# order, as a copy (as if it had crossed the network).
	if mode == Mode.HOST and peer_id == 1:
		c_message.call_deferred(kind, data.duplicate(true))
		return
	# A peer that has just dropped may not have been removed yet; sending to
	# it is an ENet error, and there is nobody to read the message (0.16.8).
	if multiplayer.multiplayer_peer == null or not multiplayer.get_peers().has(peer_id):
		return
	if peer is ENetMultiplayerPeer and _is_server():
		var pp := (peer as ENetMultiplayerPeer).get_peer(peer_id)
		if pp == null or pp.get_state() != ENetPacketPeer.STATE_CONNECTED:
			return
	rpc_id(peer_id, "c_message", kind, data)


@rpc("authority", "call_remote", "reliable")
func c_message(kind: String, data: Dictionary) -> void:
	match kind:
		"lobby":
			lobby_status = str(data.get("status", ""))
		"match_found":
			match_found.emit(data)
		"state":
			match_state.emit(data)
		"room":
			current_room_code = str(data.get("code", current_room_code))
			room_members = data.get("members", [])
			room_updated.emit(data)
		"ended":
			match_ended.emit(data)
		"report":
			report_result.emit(bool(data.get("ok", false)), str(data.get("message", "")))
			if _close_after_report:
				_close_after_report = false
				disconnect_from_server.call_deferred()
	lobby_message.emit(kind, data)
