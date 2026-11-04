extends Node

const RoomSessionState = preload("res://scripts/core/room_session_state.gd")
const ServerUrlHelper = preload("res://scripts/core/server_url_helper.gd")
const Updater = preload("res://scripts/core/updater.gd")

signal connected_to_server
signal connection_closed
signal room_created(room_code: String, user_id: String)
signal room_joined(room_code: String, user_id: String, players: Array)
signal room_state_updated(players: Array)
signal error_received(message: String)
signal generation_log_received(line: String)
signal kicked_from_room(message: String)
signal room_closed(message: String)
signal checks_updated(checks_data: Dictionary)
signal server_log_received(line: String)

var socket: WebSocketPeer = WebSocketPeer.new()
var is_connected: bool = false
var _ping_timer: float = 0.0
const PING_INTERVAL: float = 20.0
var is_reconnecting: bool = false

var server_url: String = "wss://lodestone.disaac1.com"

# Typed room session state
var session: RoomSessionState = RoomSessionState.new()

# Backward-compatibility property forwarders to typed session object
var player_name: String:
	get: return session.player_name
	set(v): session.player_name = v
var room_code: String:
	get: return session.room_code
	set(v): session.room_code = v
var user_id: String:
	get: return session.user_id
	set(v): session.user_id = v
var players: Array:
	get: return session.players
	set(v): session.players = v
var seed_status: String:
	get: return session.seed_status
	set(v): session.seed_status = v
var seed_zip_name: String:
	get: return session.seed_zip_name
	set(v): session.seed_zip_name = v
var seed_spoiler_name: String:
	get: return session.seed_spoiler_name
	set(v): session.seed_spoiler_name = v
var tunnel_url: String:
	get: return session.tunnel_url
	set(v): session.tunnel_url = v
var locked_by: String:
	get: return session.locked_by
	set(v): session.locked_by = v
var checks: Dictionary:
	get: return session.checks
	set(v): session.checks = v
var hosting_mode: String:
	get: return session.hosting_mode
	set(v): session.hosting_mode = v
var hosting_status: String:
	get: return session.hosting_status
	set(v): session.hosting_status = v
var hosting_room_url: String:
	get: return session.hosting_room_url
	set(v): session.hosting_room_url = v
var hosting_server_url: String:
	get: return session.hosting_server_url
	set(v): session.hosting_server_url = v

func _enter_tree() -> void:
	# Mount verified self-updating patches before the root scene loads
	Updater.bootstrap_early_updates()

func _ready() -> void:
	# Disable processing until we actively initiate a connection
	set_process(false)

func connect_to_server(url: String = server_url) -> Error:
	if socket.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		socket.close()
	server_url = url
	socket = WebSocketPeer.new() # Instantiate a new peer
	var connect_url = url
	if "://localhost" in connect_url:
		connect_url = connect_url.replace("://localhost", "://127.0.0.1")
	var err = socket.connect_to_url(connect_url)
	if err == OK:
		is_connected = false
		set_process(true)
		print("Connecting to WebSocket server: ", url)
	else:
		print("Failed to start connection attempt to: ", url)
	return err

func disconnect_from_server() -> void:
	if socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		socket.close(1000, "Leaving room")
	is_connected = false
	set_process(false)
	print("Disconnected from server.")

func _process(delta: float) -> void:
	socket.poll()
	var state = socket.get_ready_state()
	
	if state == WebSocketPeer.STATE_OPEN:
		if not is_connected:
			is_connected = true
			_ping_timer = 0.0
			connected_to_server.emit()
			print("WebSocket connection fully established.")
			
		_ping_timer += delta
		if _ping_timer >= PING_INTERVAL:
			_ping_timer = 0.0
			send_message({ "type": "ping" })

		while socket.get_available_packet_count() > 0:
			var packet = socket.get_packet()
			var text = packet.get_string_from_utf8()
			_handle_raw_message(text)
			
	elif state == WebSocketPeer.STATE_CLOSED:
		if is_connected:
			is_connected = false
			print("WebSocket connection closed by remote peer.")
			if room_code != "" and user_id != "":
				_attempt_auto_reconnect()
			else:
				connection_closed.emit()
				set_process(false)
		elif not is_reconnecting:
			# A failed initial connection also reaches CLOSED, but never
			# transitions through STATE_OPEN to set is_connected.
			connection_closed.emit()
			set_process(false)
			
	elif state == WebSocketPeer.STATE_CONNECTING:
		pass
	else:
		# Error or state is none
		pass

func _attempt_auto_reconnect() -> void:
	if is_reconnecting:
		return
	is_reconnecting = true
	print("[NetworkManager] Connection dropped unexpectedly. Attempting automatic session recovery in 2 seconds...")
	await get_tree().create_timer(2.0).timeout
	if room_code == "" or user_id == "":
		is_reconnecting = false
		return
	
	var err = connect_to_server(server_url)
	if err == OK:
		var connected_ok = false
		for i in range(50):
			await get_tree().create_timer(0.1).timeout
			if socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
				connected_ok = true
				break
			elif socket.get_ready_state() == WebSocketPeer.STATE_CLOSED:
				break
		if connected_ok:
			print("[NetworkManager] Re-established connection! Resuming room session ", room_code)
			reconnect_session(user_id, room_code, player_name)
			is_reconnecting = false
			return

	print("[NetworkManager] Auto-reconnect failed. Notifying listeners.")
	is_reconnecting = false
	connection_closed.emit()
	set_process(false)

func _handle_raw_message(text: String) -> void:
	var json = JSON.new()
	var err = json.parse(text)
	if err != OK:
		print("JSON Parse Error: ", json.get_error_message(), " at ", text)
		return
		
	var data = json.data
	if typeof(data) != TYPE_DICTIONARY:
		print("Received non-dictionary message: ", data)
		return
		
	var type: String = data.get("type", "")
	if type != "ping" and type != "pong":
		print("NetworkManager received: ", _sanitize_for_log(data))
	_handle_message(data)

func _sanitize_for_log(val: Variant) -> Variant:
	if typeof(val) == TYPE_DICTIONARY:
		var sanitized: Dictionary = {}
		for k in val:
			if k == "yaml" and typeof(val[k]) == TYPE_STRING:
				sanitized[k] = "<yaml: %d chars>" % val[k].length()
			elif k == "players" and typeof(val[k]) == TYPE_ARRAY:
				var sanitized_players: Array = []
				for p in val[k]:
					if typeof(p) == TYPE_DICTIONARY:
						var sp: Dictionary = p.duplicate()
						if sp.has("yaml") and typeof(sp["yaml"]) == TYPE_STRING:
							sp["yaml"] = "<yaml: %d chars>" % sp["yaml"].length()
						sanitized_players.append(sp)
					else:
						sanitized_players.append(p)
				sanitized["players"] = sanitized_players
			elif typeof(val[k]) == TYPE_DICTIONARY or typeof(val[k]) == TYPE_ARRAY:
				sanitized[k] = _sanitize_for_log(val[k])
			else:
				sanitized[k] = val[k]
		return sanitized
	elif typeof(val) == TYPE_ARRAY:
		var sanitized_arr: Array = []
		for item in val:
			sanitized_arr.append(_sanitize_for_log(item))
		return sanitized_arr
	return val

func _handle_message(data: Dictionary) -> void:
	var type = data.get("type", "")
	match type:
		"ping", "pong":
			return
		"room_created":
			session.room_code = data.get("roomCode", "")
			session.user_id = data.get("userId", "")
			room_created.emit(room_code, user_id)
			
		"room_joined":
			session.apply_room_joined(data)
			room_joined.emit(session.room_code, session.user_id, session.players)
			
		"room_state":
			session.apply_room_state(data)
			if data.get("checks") is Dictionary:
				checks_updated.emit(session.checks)
			room_state_updated.emit(session.players)

		"checks_updated":
			var ch3 = data.get("checks")
			if ch3 is Dictionary:
				session.apply_checks(ch3)
				checks_updated.emit(session.checks)
			
		"error":
			var message = data.get("message", "Unknown error")
			error_received.emit(message)
			
		"generation_log":
			var line = data.get("line", "")
			generation_log_received.emit(line)

		"kicked":
			var kicked_msg = data.get("message", "You have been kicked from the room.")
			kicked_from_room.emit(kicked_msg)

		"room_deleted":
			var closed_msg = data.get("message", "The room has been closed.")
			room_closed.emit(closed_msg)

		"server_log":
			var s_line = data.get("line", "")
			if s_line != "":
				server_log_received.emit(s_line)

func send_message(data: Dictionary) -> void:
	if socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		var text = JSON.stringify(data)
		socket.send_text(text)
	else:
		print("Failed to send message: WebSocket is closed. State: ", socket.get_ready_state())

func create_room(name: String) -> void:
	player_name = name
	send_message({
		"type": "create_room",
		"playerName": name
	})

func join_room(code: String, name: String) -> void:
	player_name = name
	room_code = code.to_upper()
	send_message({
		"type": "join_room",
		"roomCode": room_code,
		"playerName": name
	})

func reconnect_session(id: String, code: String, name: String) -> void:
	user_id = id
	player_name = name
	room_code = code.to_upper()
	send_message({
		"type": "reconnect",
		"userId": id,
		"roomCode": room_code
	})

func generate_seed() -> void:
	send_message({
		"type": "generate_seed"
	})

func update_player_state(games: Array, is_ready: bool, yaml_str: String = "") -> void:
	send_message({
		"type": "update_state",
		"games": games,
		"isReady": is_ready,
		"yaml": yaml_str if yaml_str != "" else null
	})

func kick_player(target_user_id: String) -> void:
	send_message({
		"type": "kick_player",
		"targetUserId": target_user_id
	})

func leave_room() -> void:
	print("[NetworkManager] Leaving room: ", room_code)
	if socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		send_message({
			"type": "leave_room",
			"roomCode": room_code,
			"userId": user_id
		})
	disconnect_from_server()
	session.reset()

func close_room() -> void:
	print("[NetworkManager] Closing room: ", room_code)
	if room_code != "" and user_id != "":
		delete_room(room_code, user_id)
	leave_room()

func get_http_url() -> String:
	var url: String = ServerUrlHelper.ws_to_http(server_url)
	if "://localhost" in url:
		return url.replace("://localhost", "://127.0.0.1")
	return url

func get_ap_server_url() -> String:
	return ServerUrlHelper.resolve_ap_server_url(session.tunnel_url, server_url, session.hosting_server_url)

func fetch_http(endpoint: String) -> Dictionary:
	var http = HTTPRequest.new()
	http.timeout = 30.0
	add_child(http)
	var url = get_http_url() + endpoint
	var req_url = url.replace("://localhost", "://127.0.0.1") if "://localhost" in url else url
	print("[HTTP GET] Requesting: ", url)
	var err = http.request(req_url)
	if err != OK:
		http.queue_free()
		return {"error": "Failed to initiate HTTP request"}
		
	var result = await http.request_completed
	# result = [result, response_code, headers, body]
	var res_code = result[1]
	var body = result[3]
	http.queue_free()
	
	if res_code != 200:
		return {"error": "HTTP Server returned status: " + str(res_code)}
		
	var json = JSON.new()
	var parse_err = json.parse(body.get_string_from_utf8())
	if parse_err != OK:
		return {"error": "Failed to parse response as JSON"}
		
	if typeof(json.data) == TYPE_DICTIONARY:
		return {"data": json.data}
	elif typeof(json.data) == TYPE_ARRAY:
		return {"data": {"list": json.data}}
	return {"data": {}}

func set_hosting_mode(mode: String) -> Dictionary:
	if room_code == "" or user_id == "":
		return {"error": "Not connected to a room"}
	var http = HTTPRequest.new()
	add_child(http)
	var url = get_http_url() + "/api/rooms/" + room_code.uri_encode() + "/hosting/mode"
	var headers = ["Content-Type: application/json"]
	var body = JSON.stringify({"userId": user_id, "hostingMode": mode})
	var err = http.request(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		http.queue_free()
		return {"error": "Failed to initiate hosting mode request"}
	var result = await http.request_completed
	http.queue_free()
	var response_body = result[3].get_string_from_utf8()
	var parsed = JSON.parse_string(response_body)
	if result[1] < 200 or result[1] >= 300:
		if parsed is Dictionary and parsed.has("error"):
			return {"error": str(parsed.error)}
		return {"error": "Hosting mode request failed with HTTP " + str(result[1])}
	return parsed if parsed is Dictionary else {"success": true}

func cleanup_test_room(code: String) -> Dictionary:
	var http = HTTPRequest.new()
	add_child(http)
	var url = get_http_url() + "/api/test/cleanup"
	var headers = ["Content-Type: application/json"]
	var body = JSON.stringify({"roomCode": code})
	print("[HTTP POST] Cleanup Requesting: ", url)
	var err = http.request(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		http.queue_free()
		return {"error": "Failed to initiate HTTP cleanup request"}
		
	var result = await http.request_completed
	var res_code = result[1]
	http.queue_free()
	
	if res_code != 200:
		return {"error": "Cleanup failed with code " + str(res_code)}
	return {"success": true}

func delete_room(code: String, u_id: String = "") -> Dictionary:
	var target_uid: String = u_id if u_id != "" else user_id
	var http = HTTPRequest.new()
	add_child(http)
	var url = get_http_url() + "/api/rooms/" + code.uri_encode() + "/delete?userId=" + target_uid.uri_encode()
	var headers = ["Content-Type: application/json"]
	print("[HTTP POST] Delete Room Requesting: ", url)
	var err = http.request(url, headers, HTTPClient.METHOD_POST, "")
	if err != OK:
		http.queue_free()
		return {"error": "Failed to initiate HTTP delete request"}
		
	var result = await http.request_completed
	var res_code = result[1]
	http.queue_free()
	
	if res_code != 200:
		return {"error": "Delete failed with code " + str(res_code)}
	return {"success": true}

func send_server_command(command: String) -> Dictionary:
	if room_code == "" or user_id == "":
		return {"error": "Not connected to a room"}
	var payload = JSON.stringify({
		"userId": user_id,
		"command": command
	})
	var http = HTTPRequest.new()
	add_child(http)
	var url = get_http_url() + "/api/rooms/" + room_code.uri_encode() + "/command"
	var headers = ["Content-Type: application/json"]
	print("[HTTP POST] Server Command Requesting: ", url, " -> ", command)
	var err = http.request(url, headers, HTTPClient.METHOD_POST, payload)
	if err != OK:
		http.queue_free()
		return {"error": "Failed to initiate command request"}
	var response = await http.request_completed
	http.queue_free()
	var res_code = response[1]
	var body = response[3].get_string_from_utf8()
	var json = JSON.parse_string(body)
	if json is Dictionary:
		return json
	return {"statusCode": res_code}

func fetch_seed_data() -> Dictionary:
	if room_code == "":
		return {"error": "No active room"}
	return await fetch_http("/api/rooms/" + room_code.uri_encode() + "/seed-data")
