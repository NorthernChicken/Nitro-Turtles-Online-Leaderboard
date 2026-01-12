"""
Leaderboard HTTP Service
Provides an HTTP server interface for fetching Steam leaderboard data
Integrates with Steam manager to access leaderboard information
"""
extends Node
class_name LeaderboardHTTPService

# HTTP Server
var http_server: TCPServer
var server_running: bool = false
var server_port: int = 8000

# Steam leaderboard state
var leaderboard_data: Dictionary = {} # Cache for leaderboard data
var leaderboard_handles: Dictionary = {} # Maps leaderboard names to Steam handles
var pending_leaderboards: Dictionary = {} # Maps leaderboard names to pending requests
var current_request_info: Dictionary = {} # Tracks current leaderboard being fetched

# Configuration
var active_connections: Array = []

func _ready() -> void:
	print("LeaderboardHTTPService._ready() called")

	# Initialize Steamworks
	var init_result = Steam.steamInit()
	if typeof(init_result) == TYPE_DICTIONARY:
		if init_result.get("status", 0) != 1:
			printerr("Steam initialization failed: ", init_result.get("verbal", "Unknown error"))
			return
		else:
			print("Steam initialized successfully: ", init_result.get("verbal", "OK"))
	elif typeof(init_result) == TYPE_BOOL:
		if not init_result:
			printerr("Steam initialization failed (boolean false)")
			return
		else:
			print("Steam initialized successfully")
	else:
		printerr("Unexpected Steam init return type")
		return

	# Connect Steam signals (disconnect first to avoid duplicates)
	if Steam.leaderboard_find_result.is_connected(_on_leaderboard_find_result):
		Steam.leaderboard_find_result.disconnect(_on_leaderboard_find_result)
	Steam.leaderboard_find_result.connect(_on_leaderboard_find_result)

	if Steam.leaderboard_scores_downloaded.is_connected(_on_leaderboard_scores_downloaded):
		Steam.leaderboard_scores_downloaded.disconnect(_on_leaderboard_scores_downloaded)
	Steam.leaderboard_scores_downloaded.connect(_on_leaderboard_scores_downloaded)

	# Start HTTP server
	start_server()

func _process(_delta: float) -> void:
	Steam.run_callbacks()

	# Handle incoming connections
	if server_running and http_server and http_server.is_connection_available():
		var connection = http_server.take_connection()
		if connection:
			active_connections.append(connection)

	# Process active connections
	var i = 0
	while i < active_connections.size():
		var conn = active_connections[i]

		if not conn:
			active_connections.remove_at(i)
			continue

		if conn.get_available_bytes() > 0:
			_handle_connection(conn)
			active_connections.remove_at(i)
			continue

		# if conn.get_status() == StreamPeerTCP.STATUS_DISCONNECTED or conn.get_status() == StreamPeerTCP.STATUS_NONE:
		#     active_connections.remove_at(i)
		#     continue

		i += 1

func start_server() -> void:
	print("Starting LeaderboardHTTPService on port %d" % server_port)
	http_server = TCPServer.new()
	var error = http_server.listen(server_port)
	if error != OK:
		print("ERROR: Failed to start HTTP server on port %d (error code: %d)" % [server_port, error])
		return
	server_running = true
	print("SUCCESS: Leaderboard HTTP Service listening on port %d (all interfaces)" % server_port)

func _handle_connection(connection: StreamPeerTCP) -> void:
	print("_handle_connection: Got incoming connection")
	if not connection or connection.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		print("_handle_connection: Connection not valid")
		return

	var bytes_available = connection.get_available_bytes()
	if bytes_available <= 0:
		print("_handle_connection: No bytes available")
		connection.disconnect_from_host()
		return

	print("_handle_connection: Reading %d bytes" % bytes_available)
	var request_data = connection.get_utf8_string(bytes_available)
	if request_data.is_empty():
		print("_handle_connection: Request data is empty")
		connection.disconnect_from_host()
		return

	print("_handle_connection: Got request:\n%s" % request_data)

	var lines = request_data.split("\r\n")
	if lines.size() == 0:
		_send_response(connection, 400, "Bad Request")
		return
	var request_line = lines[0]
	var parts = request_line.split(" ")
	if parts.size() < 2:
		_send_response(connection, 400, "Bad Request")
		return

	var path = parts[1]
	print("_handle_connection: Path = %s" % path)

	var response_body = ""
	var status_code = 404

	if path == "/health":
		response_body = '{"status":"healthy"}'
		status_code = 200
	elif path == "/":
		response_body = '{"service":"leaderboard","endpoints":["GET /health","GET /leaderboard/<name>"]}'
		status_code = 200
	elif path.begins_with("/leaderboard/"):
		var leaderboard_name = path.substr(13)
		leaderboard_name = leaderboard_name.uri_decode()
		print("_handle_connection: Leaderboard request for %s" % leaderboard_name)
		response_body = _handle_leaderboard_request(leaderboard_name)
		status_code = 200 if response_body != "" else 503
	else:
		_send_response(connection, 404, "Not Found")
		return

	_send_response(connection, status_code, response_body)

func _send_response(connection: StreamPeerTCP, status_code: int, body: String) -> void:
	print("_send_response: status=%d, body_len=%d" % [status_code, body.length()])
	var status_text = "OK" if status_code == 200 else "Error"
	var headers = "HTTP/1.1 %d %s\r\n" % [status_code, status_text]
	headers += "Content-Type: application/json\r\n"
	headers += "Content-Length: %d\r\n" % body.length()
	headers += "Connection: close\r\n"
	headers += "Access-Control-Allow-Origin: *\r\n"
	headers += "\r\n"
	var full_response = headers + body

	print("_send_response: Sending %d bytes total" % full_response.length())
	var err = connection.put_data(full_response.to_utf8_buffer())
	if err != OK:
		print("_send_response: put_data error: %d" % err)
	else:
		print("_send_response: Successfully wrote response")

	connection.disconnect_from_host()
	print("_send_response: Disconnected")

func _handle_leaderboard_request(leaderboard_name: String) -> String:
	print("_handle_leaderboard_request: %s" % leaderboard_name)

	if leaderboard_data.has(leaderboard_name):
		print("_handle_leaderboard_request: Returning cached data for %s" % leaderboard_name)
		return JSON.stringify(leaderboard_data[leaderboard_name])

	if leaderboard_handles.has(leaderboard_name):
		print("_handle_leaderboard_request: Have handle for %s, downloading entries" % leaderboard_name)
		var handle = leaderboard_handles[leaderboard_name]
		current_request_info = {"leaderboard": leaderboard_name, "handle": handle}
		Steam.downloadLeaderboardEntries(1, 100, Steam.LEADERBOARD_DATA_REQUEST_GLOBAL, handle)
		return JSON.stringify({"status": "loading", "leaderboard": leaderboard_name})

	print("_handle_leaderboard_request: No handle for %s, finding leaderboard" % leaderboard_name)
	pending_leaderboards[leaderboard_name] = true
	current_request_info = {"leaderboard": leaderboard_name}
	Steam.findLeaderboard(leaderboard_name)

	return JSON.stringify({"status": "loading", "leaderboard": leaderboard_name})

func _on_leaderboard_find_result(handle: int, found: int) -> void:
	print("_on_leaderboard_find_result: handle=%d, found=%d" % [handle, found])
	if found and current_request_info.has("leaderboard"):
		var leaderboard_name = current_request_info["leaderboard"]
		print("_on_leaderboard_find_result: Storing handle %d for leaderboard %s" % [handle, leaderboard_name])
		leaderboard_handles[leaderboard_name] = handle
		current_request_info["handle"] = handle
		print("_on_leaderboard_find_result: Downloading entries for %s" % leaderboard_name)
		Steam.downloadLeaderboardEntries(1, 100, Steam.LEADERBOARD_DATA_REQUEST_GLOBAL, handle)

func _on_leaderboard_scores_downloaded(message: String, leaderboard_handle: int, leaderboard_entries: Array) -> void:
	print("_on_leaderboard_scores_downloaded: %s (handle=%d, entries=%d)" % [message, leaderboard_handle, leaderboard_entries.size()])
	if not current_request_info.has("leaderboard"):
		print("_on_leaderboard_scores_downloaded: ERROR - no leaderboard in current_request_info")
		return

	var leaderboard_name = current_request_info["leaderboard"]

	var entries = []
	for entry in leaderboard_entries:
		entries.append({
			"rank": entry.get("global_rank", 0),
			"steam_id": entry.get("steam_id", ""),
			"name": entry.get("name", "Unknown"),
			"score": entry.get("score", 0)
		})

	leaderboard_data[leaderboard_name] = {
		"leaderboard": leaderboard_name,
		"entries": entries,
		"total": entries.size()
	}
	print("_on_leaderboard_scores_downloaded: Cached %d entries for %s" % [entries.size(), leaderboard_name])

func stop_server() -> void:
	print("stop_server: Stopping server")
	server_running = false
	if http_server:
		http_server.stop()
	active_connections.clear()

func _exit_tree() -> void:
	stop_server()
	Steam.steamShutdown()

func register_leaderboard(name: String, handle: int) -> void:
	leaderboard_handles[name] = handle
	print("register_leaderboard: %s -> %d" % [name, handle])
