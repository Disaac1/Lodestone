extends Control

@onready var name_input: LineEdit = %NameInput
@onready var server_input: LineEdit = %ServerInput
@onready var code_input: LineEdit = %CodeInput
@onready var create_btn: Button = %CreateBtn
@onready var join_btn: Button = %JoinBtn
@onready var error_label: Label = %ErrorLabel
@onready var recent_lobbies_container: VBoxContainer = %RecentLobbiesContainer

@onready var rom_status_badge: Label = %RomStatusBadge
@onready var rom_url_input: LineEdit = %RomUrlInput
@onready var rom_download_btn: Button = %RomDownloadBtn
@onready var rom_load_file_btn: Button = %RomLoadFileBtn
@onready var rom_manage_btn: Button = %RomManageBtn
@onready var rom_folder_btn: Button = %RomFolderBtn
@onready var rom_catalog_modal: Control = %RomCatalogModal
@onready var rom_file_dialog: FileDialog = %RomFileDialog
@onready var update_overlay: Control = %UpdateOverlay
@onready var tools_btn: Button = get_node_or_null("%ToolsBtn")
@onready var tools_manager_modal: Control = get_node_or_null("%ToolsManagerModal")
var launcher: GameLauncher = GameLauncher.new()
@onready var subtitle_label: Label = get_node("CenterContainer/HBox/CardPanel/Margin/VBox/Subtitle")

const SETTINGS_PATH = "user://settings.json"
const Updater = preload("res://scripts/core/updater.gd")
const RomCatalogManager = preload("res://scripts/core/rom_catalog_manager.gd")
const UpdateOverlayScene = preload("res://scenes/modals/update_overlay.tscn")

var pending_action: String = "" # "create" or "join"
var pending_user_id: String = ""
var recent_lobbies: Array = []
var _cached_server_rooms_map: Dictionary = {}
var update_banner_btn: Button = null

func _ready() -> void:
	subtitle_label.text = "Archipelago Lobby System  •  v" + Updater.active_version
	Updater.log_message("UPDATER", "Main menu ready: updater_base=" + Updater.BASE_VERSION + " active=" + Updater.active_version + " bridge=" + str(Updater.is_bridge_version()))
	# Clear error label
	if ResourceLoader.exists("res://icon.png"):
		var icon_tex = load("res://icon.png") as Texture2D
		if icon_tex:
			var img: Image = icon_tex.get_image()
			if img and not img.is_empty():
				DisplayServer.set_icon(img)
	error_label.text = ""
	launcher.load_launcher_config()
	DiagnosticsManager.register_launcher(launcher)
	if is_instance_valid(tools_btn):
		tools_btn.pressed.connect(func():
			if is_instance_valid(tools_manager_modal):
				tools_manager_modal.open(launcher)
		)
	
	# Connect local button signals
	create_btn.pressed.connect(_on_create_pressed)
	join_btn.pressed.connect(_on_join_pressed)
	name_input.text_changed.connect(_on_name_text_changed)
	server_input.text_changed.connect(func(_t: String):
		_save_all_settings()
		NetworkManager.server_url = server_input.text.strip_edges()
		if rom_url_input.text.strip_edges() == "" or rom_url_input.text.strip_edges() == RomCatalogManager.DEFAULT_FALLBACK_URL:
			rom_url_input.text = RomCatalogManager.get_default_catalog_url(server_input.text)
	)
	rom_download_btn.pressed.connect(_on_rom_download_pressed)
	rom_load_file_btn.pressed.connect(func(): rom_file_dialog.popup_centered(Vector2(650, 450)))
	rom_file_dialog.file_selected.connect(_on_rom_file_selected)
	rom_manage_btn.pressed.connect(func(): rom_catalog_modal.open(launcher))
	rom_folder_btn.pressed.connect(func(): OS.shell_open(ProjectSettings.globalize_path("user://")))
	rom_catalog_modal.catalog_updated.connect(func(_info): _refresh_rom_catalog_status())
	rom_url_input.text_changed.connect(func(_t: String): _save_all_settings())
	code_input.text_changed.connect(func(t: String):
		var upper = t.to_upper()
		if code_input.text != upper:
			var cur = code_input.caret_column
			code_input.text = upper
			code_input.caret_column = cur
	)
	
	# Connect NetworkManager signals
	NetworkManager.connected_to_server.connect(_on_connected_to_server)
	NetworkManager.connection_closed.connect(_on_connection_closed)
	NetworkManager.room_created.connect(_on_room_created)
	NetworkManager.room_joined.connect(_on_room_joined)
	NetworkManager.error_received.connect(_on_error_received)
	
	# Load settings & fetch active server rooms
	_load_local_settings()
	if server_input.text.strip_edges() != "":
		NetworkManager.server_url = server_input.text.strip_edges()
	_fetch_server_rooms_and_update_ui()
	_refresh_rom_catalog_status()
	_check_for_updates()

func _check_for_updates() -> void:
	Updater.log_message("UPDATER", "Main menu starting update check.")
	Updater.check_for_update(self, func(has_update: bool, update_info: Dictionary):
		var bridge_requires_finalization := Updater.is_bridge_version()
		Updater.log_message("UPDATER", "Main menu update callback: has_update=" + str(has_update) + " bridge=" + str(bridge_requires_finalization) + " info=" + str(update_info))
		var manual_update_required: bool = update_info.get("update_mode", "") == "manual"
		if (has_update or bridge_requires_finalization or manual_update_required) and is_instance_valid(error_label):
			var remote_ver = update_info.get("version", "")
			var update_mode = update_info.get("update_mode", "normal")
			if update_mode == "manual":
				_start_manual_update(update_info)
				return
			var update_label = "Repair required" if update_mode == "bridge" else "Update available"
			var force_update = bridge_requires_finalization or update_mode in ["bridge", "finalize"]
			if force_update:
				Updater.log_message("UPDATER", "Entering forced update: mode=" + str(update_mode) + " target=" + str(update_info.get("version", "")))
				if not update_info.has("version") or str(update_info.get("version", "")).is_empty():
					_start_forced_update_failure("The update server did not provide a target version.")
					return
				_start_forced_update(update_info)
				return
			if update_banner_btn == null:
				update_banner_btn = Button.new()
				update_banner_btn.text = "⚡ " + update_label + " (v" + remote_ver + ") - Click to Install"
				update_banner_btn.add_theme_color_override("font_color", Color(0.2, 0.9, 0.5))
				update_banner_btn.custom_minimum_size = Vector2(0, 32)
				var parent_vbox = error_label.get_parent()
				if parent_vbox:
					parent_vbox.add_child(update_banner_btn)
					parent_vbox.move_child(update_banner_btn, error_label.get_index())
				
				update_banner_btn.pressed.connect(func():
					update_banner_btn.disabled = true
					update_banner_btn.text = "Downloading update..."
					Updater.apply_update(self, update_info, Callable(), func(success: bool, msg: String):
						if success:
							update_banner_btn.text = "✅ Update installed. Restarting..."
							if not Updater.restart_application(self):
								update_banner_btn.disabled = false
								update_banner_btn.text = "Update installed. Please restart the application."
						else:
							update_banner_btn.disabled = false
							update_banner_btn.text = "Update Failed: " + msg
					)
				)
	)

func _get_update_overlay() -> Control:
	if is_instance_valid(update_overlay):
		return update_overlay
	var existing = get_node_or_null("%UpdateOverlay")
	if is_instance_valid(existing):
		update_overlay = existing
		return update_overlay
	existing = get_node_or_null("UpdateOverlay")
	if is_instance_valid(existing):
		update_overlay = existing
		return update_overlay
	var instance = UpdateOverlayScene.instantiate()
	instance.name = "UpdateOverlay"
	add_child(instance)
	update_overlay = instance
	return update_overlay

func _start_manual_update(update_info: Dictionary) -> void:
	_get_update_overlay().start_manual_update(update_info)

func _start_forced_update_failure(message: String) -> void:
	_get_update_overlay().start_forced_update_failure(message)

func _start_forced_update(update_info: Dictionary) -> void:
	_get_update_overlay().start_forced_update(update_info)

func _on_name_text_changed(new_text: String) -> void:
	_update_recent_lobbies_ui(recent_lobbies, _cached_server_rooms_map)
	_save_all_settings()
	_debounced_fetch_server_rooms()

func _debounced_fetch_server_rooms() -> void:
	var cur_name = name_input.text.strip_edges()
	await get_tree().create_timer(0.3).timeout
	if is_instance_valid(name_input) and name_input.text.strip_edges() == cur_name:
		_fetch_server_rooms_and_update_ui()

func _fetch_server_rooms_and_update_ui() -> void:
	var current_player: String = name_input.text.strip_edges()
	if current_player == "":
		_cached_server_rooms_map.clear()
		_update_recent_lobbies_ui(recent_lobbies, _cached_server_rooms_map)
		return

	var endpoint: String = "/api/rooms?playerName=" + current_player.uri_encode()
	var response: Dictionary = await NetworkManager.fetch_http(endpoint)
	_cached_server_rooms_map.clear()
	if not response.has("error"):
		var server_rooms_list: Array = response.get("data", {}).get("rooms", [])
		for r in server_rooms_list:
			_cached_server_rooms_map[r.get("code", "")] = r

		# Purge any local recent lobbies that no longer exist on the server
		var cleaned_recent_lobbies: Array = []
		for lobby in recent_lobbies:
			var code: String = lobby.get("room_code", "")
			var p_name: String = str(lobby.get("player_name", "")).strip_edges()
			if p_name.to_lower() == current_player.to_lower():
				if _cached_server_rooms_map.has(code):
					cleaned_recent_lobbies.append(lobby)
			else:
				cleaned_recent_lobbies.append(lobby)

		if cleaned_recent_lobbies.size() != recent_lobbies.size():
			recent_lobbies = cleaned_recent_lobbies
			_save_all_settings()

	_update_recent_lobbies_ui(recent_lobbies, _cached_server_rooms_map)

func _on_create_pressed() -> void:
	if not _validate_name():
		return
	
	pending_user_id = "" # Fresh creation
	pending_action = "create"
	error_label.text = "Connecting..."
	_connect_network()

func _on_join_pressed() -> void:
	if not _validate_name():
		return
		
	var code = code_input.text.strip_edges().to_upper()
	if code.length() != 6:
		error_label.text = "Room code must be exactly 6 characters"
		return
		
	# Check if we have a saved user_id for this room code and player name to enable resume takeover
	pending_user_id = ""
	var current_player_lower: String = name_input.text.strip_edges().to_lower()
	for lobby in recent_lobbies:
		if lobby.get("room_code", "") == code and lobby.get("player_name", "").strip_edges().to_lower() == current_player_lower:
			pending_user_id = lobby.get("user_id", "")
			break
			
	pending_action = "join"
	error_label.text = "Connecting..."
	_connect_network()

func _validate_name() -> bool:
	var name_text = name_input.text.strip_edges()
	if name_text == "":
		error_label.text = "Player name cannot be empty"
		return false
	return true

func _connect_network() -> void:
	var url = server_input.text.strip_edges()
	if not url.begins_with("ws://") and not url.begins_with("wss://"):
		if url.begins_with("http://"):
			url = "ws://" + url.substr(7)
		elif url.begins_with("https://"):
			url = "wss://" + url.substr(8)
		elif url.begins_with("localhost") or url.begins_with("127.0.0.1"):
			url = "ws://" + url
		elif url != "":
			url = "wss://" + url
		server_input.text = url
		_save_all_settings()
		
	var err = NetworkManager.connect_to_server(url)
	if err != OK:
		error_label.text = "Failed to connect to server. Error code: " + str(err)

func _on_connected_to_server() -> void:
	var name_text = name_input.text.strip_edges()
	if pending_action == "create":
		error_label.text = "Creating room..."
		NetworkManager.create_room(name_text)
	elif pending_action == "join":
		var code = code_input.text.strip_edges().to_upper()
		if pending_user_id != "":
			error_label.text = "Reconnecting as " + name_text + "..."
			NetworkManager.reconnect_session(pending_user_id, code, name_text)
		else:
			error_label.text = "Joining room " + code + "..."
			NetworkManager.join_room(code, name_text)

func _on_connection_closed() -> void:
	error_label.text = "Connection closed by server"
	pending_action = ""

func _on_room_created(room_code: String, user_id: String) -> void:
	_save_recent_lobby(room_code, name_input.text.strip_edges(), user_id)
	_go_to_lobby()

func _on_room_joined(room_code: String, user_id: String, _players: Array) -> void:
	_save_recent_lobby(room_code, name_input.text.strip_edges(), user_id)
	_go_to_lobby()

func _on_error_received(message: String) -> void:
	error_label.text = "Error: " + message
	NetworkManager.disconnect_from_server()
	pending_action = ""

func _go_to_lobby() -> void:
	# Disconnect local signals first to avoid leaks
	NetworkManager.connected_to_server.disconnect(_on_connected_to_server)
	NetworkManager.connection_closed.disconnect(_on_connection_closed)
	NetworkManager.room_created.disconnect(_on_room_created)
	NetworkManager.room_joined.disconnect(_on_room_joined)
	NetworkManager.error_received.disconnect(_on_error_received)
	
	# Transition scene
	get_tree().change_scene_to_file("res://scenes/lobby.tscn")

# --- Local Settings Saving / Loading ---

func _load_local_settings() -> void:
	if not FileAccess.file_exists(SETTINGS_PATH):
		return
		
	var file = FileAccess.open(SETTINGS_PATH, FileAccess.READ)
	var json_text = file.get_as_text()
	file.close()
	
	var json = JSON.new()
	if json.parse(json_text) == OK:
		var data = json.get_data()
		if data.has("player_name"):
			name_input.text = data.get("player_name", "")
		if data.has("server_url"):
			var saved_url = str(data.get("server_url", "")).strip_edges()
			if saved_url != "":
				server_input.text = saved_url
		if data.has("rom_catalog_url"):
			rom_url_input.text = str(data.get("rom_catalog_url", "")).strip_edges()
		if data.has("recent_lobbies"):
			recent_lobbies = data.get("recent_lobbies", [])
	if rom_url_input.text.strip_edges() == "":
		rom_url_input.text = RomCatalogManager.get_default_catalog_url(server_input.text)

func _save_recent_lobby(room_code: String, player_name: String, user_id: String) -> void:
	var list = recent_lobbies.duplicate()
	var new_list = []
	for lobby in list:
		# Keep entries that differ in either room_code or player_name
		if lobby.get("room_code", "") == room_code and str(lobby.get("player_name", "")).strip_edges().to_lower() == player_name.strip_edges().to_lower():
			continue
		new_list.append(lobby)
			
	new_list.insert(0, {
		"room_code": room_code,
		"player_name": player_name,
		"user_id": user_id,
		"timestamp": Time.get_unix_time_from_system()
	})
	
	if new_list.size() > 10:
		new_list.resize(10)
		
	recent_lobbies = new_list
	_save_all_settings()

func _save_all_settings() -> void:
	var data = {
		"player_name": name_input.text.strip_edges(),
		"server_url": server_input.text.strip_edges(),
		"rom_catalog_url": rom_url_input.text.strip_edges(),
		"recent_lobbies": recent_lobbies
	}
	var file = FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	file.store_string(JSON.stringify(data))
	file.close()

func _update_recent_lobbies_ui(lobbies: Array, server_rooms_map: Dictionary) -> void:
	for child in recent_lobbies_container.get_children():
		recent_lobbies_container.remove_child(child)
		child.queue_free()
		
	var current_player: String = name_input.text.strip_edges()
	var current_player_lower: String = current_player.to_lower()
	
	if current_player_lower == "":
		var prompt_lbl = Label.new()
		prompt_lbl.text = "Enter your player name above to see your lobbies"
		prompt_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		prompt_lbl.add_theme_color_override("font_color", Color(0.5, 0.55, 0.6))
		prompt_lbl.add_theme_font_size_override("font_size", 12)
		recent_lobbies_container.add_child(prompt_lbl)
		return

	var displayed_codes: Dictionary = {}
	var items_to_render: Array = []

	# 1. Add local recent lobbies matching this player's name
	for lobby in lobbies:
		var code: String = lobby.get("room_code", "")
		var p_name: String = str(lobby.get("player_name", "")).strip_edges()
		if code != "" and not displayed_codes.has(code):
			if p_name.to_lower() == current_player_lower:
				displayed_codes[code] = true
				items_to_render.append({
					"code": code,
					"player_name": p_name,
					"user_id": lobby.get("user_id", ""),
					"server_info": server_rooms_map.get(code, {}),
					"is_recent": true
				})

	# 2. Add active server rooms where this player is registered (or is host), not already in local history
	for code in server_rooms_map.keys():
		if not displayed_codes.has(code):
			var s_info: Dictionary = server_rooms_map[code]
			var host_name: String = str(s_info.get("hostName", "")).strip_edges()
			var p_names: Array = s_info.get("playerNames", [])
			var matches_player: bool = (host_name.to_lower() == current_player_lower)
			if not matches_player:
				for pn in p_names:
					if str(pn).strip_edges().to_lower() == current_player_lower:
						matches_player = true
						break
			if matches_player:
				displayed_codes[code] = true
				items_to_render.append({
					"code": code,
					"player_name": current_player,
					"user_id": "",
					"server_info": s_info,
					"is_recent": false
				})

	if items_to_render.size() == 0:
		var lbl = Label.new()
		lbl.text = "No recent lobbies found for \"" + current_player + "\""
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.add_theme_color_override("font_color", Color(0.5, 0.55, 0.6))
		lbl.add_theme_font_size_override("font_size", 12)
		recent_lobbies_container.add_child(lbl)
		return
		
	for item in items_to_render:
		var row: HBoxContainer = _create_lobby_row(item)
		recent_lobbies_container.add_child(row)

func _create_lobby_row(item: Dictionary) -> HBoxContainer:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	var code: String = item.get("code", "")
	var name_val: String = item.get("player_name", "")
	var uid: String = item.get("user_id", "")
	var s_info: Dictionary = item.get("server_info", {})

	var host_name: String = s_info.get("hostName", name_val)
	var count: int = s_info.get("playerCount", 1)
	var seed_status: String = s_info.get("seedStatus", "idle")

	var btn: Button = Button.new()
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.add_theme_font_size_override("font_size", 12)

	var status_text: String = " 🟢" if seed_status == "done" else " 🟣"
	var is_host: bool = host_name.strip_edges().to_lower() == name_val.strip_edges().to_lower()
	var role_text: String = " (Host)" if is_host else " (Host: " + host_name + ")"
	btn.text = status_text + " " + code + role_text

	btn.pressed.connect(func():
		code_input.text = code
		if name_val != "":
			name_input.text = name_val
		pending_user_id = uid
		_on_join_pressed()
	)
	row.add_child(btn)

	if item.get("is_recent", false):
		var del_btn: Button = Button.new()
		del_btn.text = "✕"
		del_btn.tooltip_text = "Remove from recent history"
		del_btn.custom_minimum_size = Vector2(28, 0)
		del_btn.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		del_btn.pressed.connect(func():
			_on_remove_recent_pressed(code)
		)
		row.add_child(del_btn)

	return row

func _on_remove_recent_pressed(room_code: String) -> void:
	print("[Main Menu] Removing room from recent history: ", room_code)
	var current_player_lower: String = name_input.text.strip_edges().to_lower()
	var new_recent: Array = []
	for l in recent_lobbies:
		var match_code = (l.get("room_code", "") == room_code)
		var match_name = (current_player_lower == "" or str(l.get("player_name", "")).strip_edges().to_lower() == current_player_lower)
		if match_code and match_name:
			continue
		new_recent.append(l)
	recent_lobbies = new_recent
	_save_all_settings()
	_update_recent_lobbies_ui(recent_lobbies, _cached_server_rooms_map)
	_fetch_server_rooms_and_update_ui()



func _refresh_rom_catalog_status() -> void:
	var info: Dictionary = RomCatalogManager.get_catalog_info()
	var exists: bool = info.get("exists", false)
	var configured: int = info.get("configured_count", 0)
	var total: int = info.get("total_count", 0)
	
	if configured > 0:
		rom_status_badge.text = "🟢 %d ROMs" % configured
		rom_status_badge.add_theme_color_override("font_color", Color(0.3, 0.9, 0.5))
		rom_status_badge.tooltip_text = "%d of %d ROMs have download links in rom.json" % [configured, total]
	elif exists and total > 0:
		rom_status_badge.text = "🟡 %d entries" % total
		rom_status_badge.add_theme_color_override("font_color", Color(0.9, 0.8, 0.3))
		rom_status_badge.tooltip_text = "ROM catalog exists but has no download URLs configured"
	else:
		rom_status_badge.text = "⚪ Not loaded"
		rom_status_badge.add_theme_color_override("font_color", Color(0.5, 0.55, 0.6))
		rom_status_badge.tooltip_text = "No rom.json found in AppData folder"

func _on_rom_download_pressed() -> void:
	var url: String = rom_url_input.text.strip_edges()
	if url == "":
		error_label.text = "Please enter a valid URL to download rom.json"
		error_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
		return
		
	rom_download_btn.disabled = true
	rom_download_btn.text = "Downloading..."
	rom_status_badge.text = "⏳ Fetching..."
	rom_status_badge.add_theme_color_override("font_color", Color(0.4, 0.7, 1.0))
	error_label.text = "Downloading rom.json..."
	error_label.remove_theme_color_override("font_color")
	
	RomCatalogManager.download_catalog_from_url(self, url, func(success: bool, msg: String, count: int, _data: Dictionary):
		rom_download_btn.disabled = false
		rom_download_btn.text = "Download"
		_refresh_rom_catalog_status()
		
		if success:
			_save_all_settings()
			error_label.text = "✅ rom.json loaded! (" + str(count) + " ROMs available)"
			error_label.add_theme_color_override("font_color", Color(0.3, 0.9, 0.5))
		else:
			error_label.text = "❌ " + msg
			error_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
	)

func _on_rom_file_selected(path: String) -> void:
	var res: Dictionary = RomCatalogManager.load_from_local_file(path)
	_refresh_rom_catalog_status()
	if res.get("success", false):
		var count: int = res.get("configured_count", 0)
		error_label.text = "✅ Loaded rom.json from %s (%d configured)" % [path.get_file(), count]
		error_label.add_theme_color_override("font_color", Color(0.3, 0.9, 0.5))
	else:
		error_label.text = "❌ " + res.get("error", "Failed to load file")
		error_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
