extends Node

var server: TCPServer
var port: int = 8080

var active_clients: Dictionary = {}

var handle_to_client: Dictionary = {}

var find_queue: Array = []

var AVAILABLE_MAPS = [
	"beach", "bay", "volcano", "pits", "reef", "tide", "ruins", "cliffs", "craters"
]

func _ready():
	server = TCPServer.new()
	var err = server.listen(port)
	if err != OK:
		print("Failed to start server on port %d: %d" % [port, err])
		return
	print("API Server listening on port %d" % port)
	
	Steam.leaderboard_find_result.connect(_on_leaderboard_find_result)
	Steam.leaderboard_scores_downloaded.connect(_on_leaderboard_scores_downloaded)

func _process(_delta):
	if server.is_listening():
		while server.is_connection_available():
			var client = server.take_connection()
			var client_id = str(randi())
			active_clients[client_id] = {
				"client": client,
				"buffer": ""
			}
			print("New client connected: ", client_id)

	var to_remove = []
	for client_id in active_clients:
		var data = active_clients[client_id]
		var client = data["client"]
		
		if client.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			to_remove.append(client_id)
			continue
			
		var available = client.get_available_bytes()
		if available > 0:
			var bytes = client.get_data(available)
			if bytes[0] == OK:
				data["buffer"] += bytes[1].get_string_from_utf8()
				
				if "\r\n\r\n" in data["buffer"] or "\n\n" in data["buffer"]:
					_process_request(client_id)
	
	for client_id in to_remove:
		active_clients.erase(client_id)

func _process_request(client_id: String):
	var data = active_clients[client_id]
	var buffer = data["buffer"]
	var lines = buffer.split("\n")
	if lines.size() == 0: return
	
	var first_line = lines[0].split(" ")
	if first_line.size() < 2: return
	
	var path = first_line[1]
	print("Request: ", path)
	
	if path.begins_with("/leaderboard/"):
		var parts = path.split("/")
		if parts.size() == 3 or (parts.size() == 4 and parts[3] == ""):
			var map_name = parts[2]
			if map_name in AVAILABLE_MAPS:
				var types = ["lap", "total"]
				if map_name == "volcano":
					types = ["total"]
				
				_send_json(client_id, {
					"map": map_name,
					"available_types": types,
					"usage": "/leaderboard/" + map_name + "/<" + "|".join(types) + ">"
				})
			else:
				_send_error(client_id, 404, "Unknown map: " + map_name + ". Available values: " + ", ".join(AVAILABLE_MAPS))
			return
			
		if parts.size() >= 4:
			var map_name = parts[2]
			var type = parts[3]
			
			if not map_name in AVAILABLE_MAPS:
				_send_error(client_id, 404, "Unknown map: " + map_name)
				return
				
			if type == "lap" and map_name == "volcano":
				_send_error(client_id, 400, "Scorched Shell Volcano does not have laps.")
				return
				
			if type != "lap" and type != "total":
				_send_error(client_id, 400, "Invalid type: " + type + ". Use 'lap' or 'total'.")
				return
				
			var leaderboard_id = map_name
			# craters on steam is crater
			if map_name == "craters":
				leaderboard_id = "crater"
				
			if type == "lap":
				leaderboard_id += "lap"
			
			_fetch_leaderboard(leaderboard_id, client_id)
		else:
			_send_error(client_id, 400, "Invalid path. Use /leaderboard/<map>/<lap|total>")
	else:
		_send_error(client_id, 404, "Not found. Try /leaderboard")

func _fetch_leaderboard(id: String, client_id: String):
	find_queue.append({"id": id, "client_id": client_id})
	Steam.findLeaderboard(id)

func _on_leaderboard_find_result(handle: int, found: int):
	if find_queue.is_empty(): return
	var req = find_queue.pop_front()
	var client_id = req["client_id"]
	
	if found:
		handle_to_client[handle] = client_id
		Steam.downloadLeaderboardEntries(1, 100, Steam.LEADERBOARD_DATA_REQUEST_GLOBAL, handle)
	else:
		_send_error(client_id, 404, "Leaderboard not found: " + req["id"])

func _on_leaderboard_scores_downloaded(message: String, handle: int, entries: Array):
	var client_id = handle_to_client.get(handle)
	if not client_id: return
	
	var result = {"entries": []}
	for e in entries:
		result["entries"].append({
			"place": e["global_rank"],
			"steam_id": str(e["steam_id"]),
			"time": e["score"]
		})
	
	_send_json(client_id, result)
	handle_to_client.erase(handle)

func _send_json(client_id: String, data: Dictionary):
	if not active_clients.has(client_id): return
	var client = active_clients[client_id]["client"]
	
	var json = JSON.stringify(data)
	var response = "HTTP/1.1 200 OK\r\n"
	response += "Content-Type: application/json\r\n"
	response += "Content-Length: " + str(json.to_utf8_buffer().size()) + "\r\n"
	response += "Access-Control-Allow-Origin: *\r\n"
	response += "Connection: close\r\n"
	response += "\r\n"
	response += json
	
	client.put_data(response.to_utf8_buffer())
	active_clients.erase(client_id)

func _send_error(client_id: String, code: int, message: String):
	if not active_clients.has(client_id): return
	var client = active_clients[client_id]["client"]
	
	var response = "HTTP/1.1 " + str(code) + " Error\r\n"
	response += "Content-Type: text/plain\r\n"
	response += "Connection: close\r\n"
	response += "\r\n"
	response += message
	client.put_data(response.to_utf8_buffer())
	active_clients.erase(client_id)
