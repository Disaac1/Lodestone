extends Control

# --- DEPENDENCIES ---
const UITheme = preload("res://scripts/ui/ui_theme.gd")
const YamlBuilder = preload("res://scripts/core/yaml_builder.gd")
const SaveManager = preload("res://scripts/core/save_manager.gd")
const GameLauncher = preload("res://scripts/core/game_launcher.gd")
const GuidedSetupRegistry = preload("res://scripts/guided_setup/guided_setup_registry.gd")
const GameOptionsService = preload("res://scripts/core/game_options_service.gd")
const ServerUrlHelper = preload("res://scripts/core/server_url_helper.gd")

# --- CONSTANTS ---
const VIEW_MODE_SETUP: String = "setup"
const VIEW_MODE_PLAY: String = "play"

# Color Palette (Centralized in UITheme)
const COLOR_PRIMARY_BLUE: Color = UITheme.COLOR_PRIMARY_BLUE
const COLOR_HOST_PURPLE: Color = UITheme.COLOR_HOST_PURPLE
const COLOR_STATUS_READY: Color = UITheme.COLOR_STATUS_READY
const COLOR_STATUS_NOT_READY: Color = UITheme.COLOR_STATUS_NOT_READY
const COLOR_STATUS_OFFLINE: Color = UITheme.COLOR_STATUS_OFFLINE
const COLOR_SERVER_ACTIVE: Color = UITheme.COLOR_SERVER_ACTIVE
const COLOR_SERVER_INITIALIZING: Color = UITheme.COLOR_SERVER_INITIALIZING
const COLOR_ERROR_RED: Color = UITheme.COLOR_ERROR_RED
const COLOR_MUTED_TEXT: Color = UITheme.COLOR_MUTED_TEXT
const COLOR_GUIDED_GREEN: Color = UITheme.COLOR_GUIDED_GREEN

# --- CORE HEADER & VIEW NODES ---
@onready var room_label: Label = %RoomLabel
@onready var status_label: Label = %StatusLabel
@onready var server_label: Label = %ServerLabel
@onready var lock_status_label: Label = %LockStatusLabel
@onready var active_seed_badge: PanelContainer = %ActiveSeedBadge
@onready var badge_label: Label = %BadgeLabel
@onready var view_switcher_hbox: HBoxContainer = %ViewSwitcherHBox
@onready var play_view_btn: Button = %PlayViewBtn
@onready var setup_view_btn: Button = %SetupViewBtn

@onready var connection_badge: PanelContainer = %ConnectionBadge
@onready var connection_dot: Label = %ConnectionDot
@onready var server_port_value: Label = %ServerPortValue
@onready var copy_server_address_btn: Button = %CopyServerAddressBtn

# --- VIEW REFERENCES ---
@onready var lobby_setup_view: Control = %LobbySetupView
@onready var play_dashboard_view: Control = %PlayDashboardView

# --- FOOTER BUTTONS ---
@onready var leave_btn: Button = %LeaveBtn
@onready var close_room_btn: Button = %CloseRoomBtn
@onready var refresh_btn: Button = get_node_or_null("%RefreshBtn")
@onready var start_game_btn: Button = %StartGameBtn
@onready var hosting_mode_option: OptionButton = %HostingModeOption
@onready var download_seed_btn: Button = %DownloadSeedBtn
@onready var view_spoiler_btn: Button = %ViewSpoilerBtn
@onready var checkout_save_btn: Button = %CheckoutSaveBtn
@onready var checkin_save_btn: Button = %CheckinSaveBtn
@onready var force_unlock_btn: Button = %ForceUnlockBtn

# --- MODAL SUB-SCENES ---
@onready var add_game_modal: Control = %AddGameModal
@onready var config_modal: Control = %ConfigModal
@onready var item_browser_modal: Control = %ItemBrowserModal
@onready var generating_overlay: Control = %GeneratingOverlay
@onready var launch_overlay: Control = %LaunchOverlay
@onready var host_tools_modal: Control = %HostToolsModal
@onready var host_tools_btn: Button = get_node_or_null("%HostToolsBtn")

# Backward compatibility aliases for tests and external callers
var add_game_overlay: Control:
	get:
		return add_game_modal
var config_overlay: Control:
	get:
		return config_modal
var item_browser_overlay: Control:
	get:
		return item_browser_modal

var player_list: VBoxContainer:
	get:
		if is_instance_valid(lobby_setup_view) and "player_list" in lobby_setup_view:
			return lobby_setup_view.player_list
		return get_node_or_null("%PlayerList")

var games_grid_container: HFlowContainer:
	get:
		if is_instance_valid(play_dashboard_view) and "games_grid_container" in play_dashboard_view:
			return play_dashboard_view.games_grid_container
		return get_node_or_null("%GamesGridContainer")

var checks_stats_label: Label:
	get:
		if is_instance_valid(play_dashboard_view) and "checks_stats_label" in play_dashboard_view:
			return play_dashboard_view.checks_stats_label
		return get_node_or_null("%ChecksStatsLabel")

var checks_progress_bar: ProgressBar:
	get:
		if is_instance_valid(play_dashboard_view) and "checks_progress_bar" in play_dashboard_view:
			return play_dashboard_view.checks_progress_bar
		return get_node_or_null("%ChecksProgressBar")

var server_status_value: Label:
	get:
		if is_instance_valid(play_dashboard_view) and "server_status_value" in play_dashboard_view:
			return play_dashboard_view.server_status_value
		return get_node_or_null("%ServerStatusValue")

var filter_my_games_btn: Button:
	get:
		if is_instance_valid(play_dashboard_view) and "filter_my_games_btn" in play_dashboard_view:
			return play_dashboard_view.filter_my_games_btn
		return get_node_or_null("%FilterMyGamesBtn")

var games_count_label: Label:
	get:
		if is_instance_valid(play_dashboard_view) and "games_count_label" in play_dashboard_view:
			return play_dashboard_view.games_count_label
		return get_node_or_null("%GamesCountLabel")

var all_games: Array:
	get:
		return options_service.all_games
	set(val):
		options_service.all_games = val

var options_cache: Dictionary:
	get:
		return options_service.options_cache
	set(val):
		options_service.options_cache = val

var config_states: Dictionary:
	get:
		return options_service.config_states
	set(val):
		options_service.config_states = val

var use_guided_setup_mode: Dictionary:
	get:
		return options_service.use_guided_setup_mode
	set(val):
		options_service.use_guided_setup_mode = val

var active_config_game: String:
	get:
		return options_service.active_config_game
	set(val):
		options_service.active_config_game = val

func _get_preset_packages(preset_config: Dictionary) -> Array:
	return launcher._get_preset_packages(preset_config)

# --- STATE VARIABLES ---
var local_selected_games: Array = []
var current_view_mode: String = VIEW_MODE_SETUP
var _auto_switched_to_play: bool = false

# Dedicated Service Modules
var options_service: GameOptionsService = GameOptionsService.new()
var launcher: GameLauncher = GameLauncher.new()

var _active_launch_game: String = ""
var _active_launch_preset: Dictionary = {}
var _active_prompt_callback: Callable = Callable()
var _tracker_operation_active: bool = false

# =====================================================================
#                      INITIALIZATION & SIGNALS
# =====================================================================

func _ready() -> void:
	print("[Lobby] Initializing Lobby scene for Room: '%s' (User: %s)" % [NetworkManager.room_code, NetworkManager.user_id])
	_connect_ui_signals()
	DiagnosticsManager.register_launcher(launcher)
	_load_launcher_catalogs()
	_connect_network_signals()
	hosting_mode_option.item_selected.connect(_on_hosting_mode_selected)
	_load_hosting_mode()
	_update_hosting_mode_ui()
	_sync_needed_custom_worlds()
	_load_cached_games_list()

	_update_room_header()
	_update_players_ui()

func _sync_needed_custom_worlds() -> void:
	var needed_games: Array = []
	for p in NetworkManager.players:
		for g in p.get("games", []):
			if not needed_games.has(g):
				needed_games.append(g)
	for g in local_selected_games:
		if not needed_games.has(g):
			needed_games.append(g)
	if not needed_games.is_empty():
		launcher.sync_custom_worlds_from_server(self, needed_games)

func _update_room_header() -> void:
	room_label.text = "ROOM: " + NetworkManager.room_code

func _connect_ui_signals() -> void:
	leave_btn.pressed.connect(_on_leave_pressed)
	if is_instance_valid(close_room_btn):
		close_room_btn.pressed.connect(_on_close_room_pressed)
	if is_instance_valid(refresh_btn):
		refresh_btn.pressed.connect(_on_refresh_pressed)
	
	# Modal sub-scene connections
	add_game_modal.game_selected.connect(_on_game_card_selected)
	config_modal.saved.connect(_on_config_modal_saved)
	config_modal.removed.connect(_on_config_modal_removed)
	config_modal.browse_items_requested.connect(func(t, te, is_loc, pool):
		item_browser_modal.open(t, te, is_loc, pool)
	)
	
	# Launch overlay modal signals
	launch_overlay.closed.connect(func(): _render_play_dashboard())
	launch_overlay.cancellation_requested.connect(_on_launch_overlay_cancellation_requested)
	launch_overlay.confirmed.connect(_on_launch_overlay_confirmed)
	launch_overlay.download_auto_pressed.connect(_on_launch_download_pressed)
	launch_overlay.game_selected.connect(_select_game_from_list)
	if launch_overlay.has_signal("steam_btn_pressed"):
		launch_overlay.steam_btn_pressed.connect(_on_launch_steam_pressed)
	if launch_overlay.has_signal("recheck_btn_pressed"):
		launch_overlay.recheck_btn_pressed.connect(_on_launch_recheck_pressed)
	
	# Seed actions
	start_game_btn.pressed.connect(_on_start_game_pressed)
	download_seed_btn.pressed.connect(_on_download_seed_pressed)
	view_spoiler_btn.pressed.connect(_on_view_spoiler_pressed)
	checkout_save_btn.pressed.connect(_on_checkout_save_pressed)
	checkin_save_btn.pressed.connect(_on_checkin_save_pressed)
	force_unlock_btn.pressed.connect(_on_force_unlock_pressed)
	
	# View switcher
	play_view_btn.pressed.connect(func(): _switch_view_mode(VIEW_MODE_PLAY))
	setup_view_btn.pressed.connect(func(): _switch_view_mode(VIEW_MODE_SETUP))
	if is_instance_valid(copy_server_address_btn):
		copy_server_address_btn.pressed.connect(_on_copy_server_address_pressed)
	if is_instance_valid(host_tools_btn):
		host_tools_btn.pressed.connect(_on_host_tools_pressed)

	# Dedicated view signals
	if is_instance_valid(lobby_setup_view):
		if lobby_setup_view.has_signal("game_clicked"):
			lobby_setup_view.game_clicked.connect(func(g_name: String):
				if NetworkManager.seed_status == "done":
					return
				_open_config_popup(g_name)
			)
		if lobby_setup_view.has_signal("add_game_clicked"):
			lobby_setup_view.add_game_clicked.connect(_on_plus_pressed)
		if lobby_setup_view.has_signal("kick_player_requested"):
			lobby_setup_view.kick_player_requested.connect(_show_kick_confirm_dialog)
		if lobby_setup_view.has_signal("download_seed_requested"):
			lobby_setup_view.download_seed_requested.connect(_on_download_seed_pressed)
		if lobby_setup_view.has_signal("view_spoiler_requested"):
			lobby_setup_view.view_spoiler_requested.connect(_on_view_spoiler_pressed)

	if is_instance_valid(play_dashboard_view):
		if play_dashboard_view.has_signal("launch_game_requested"):
			play_dashboard_view.launch_game_requested.connect(_check_and_launch_game)
		if play_dashboard_view.has_signal("change_path_requested"):
			play_dashboard_view.change_path_requested.connect(_show_launch_overlay_direct)
		if play_dashboard_view.has_signal("tracker_requested"):
			play_dashboard_view.tracker_requested.connect(_on_poptracker_pressed)
		if play_dashboard_view.has_signal("download_seed_requested"):
			play_dashboard_view.download_seed_requested.connect(_on_download_seed_pressed)
		if play_dashboard_view.has_signal("view_spoiler_requested"):
			play_dashboard_view.view_spoiler_requested.connect(_on_view_spoiler_pressed)
	
	# GameLauncher module signals
	launcher.launch_status_updated.connect(_on_launcher_status_updated)
	launcher.prompt_file_selection.connect(_on_launcher_prompt_file_selection)
	launcher.prompt_tool_installation.connect(_on_launcher_prompt_tool_installation)
	launcher.launch_completed.connect(_on_launcher_completed)
	launcher.launch_failed.connect(_on_launcher_failed)
	launcher.config_loaded.connect(_on_launcher_config_loaded)
	launcher.download_progress_updated.connect(_on_launcher_download_progress_updated)
	launcher.modding_status_updated.connect(_on_launcher_modding_status_updated)
	launcher.overlay_dismiss_requested.connect(_on_launcher_overlay_dismiss_requested)
	launcher.game_process_updated.connect(_on_launcher_game_process_updated)
	launcher.game_process_crashed.connect(_on_launcher_game_process_crashed)

func _on_launcher_config_loaded() -> void:
	print("[Lobby] Launcher config updated from backend. Refreshing game statuses...")
	if is_instance_valid(play_dashboard_view) and play_dashboard_view.has_method("refresh_launcher_statuses"):
		play_dashboard_view.refresh_launcher_statuses(launcher)

func _on_launcher_game_process_updated(_game_name: String, _is_running: bool) -> void:
	if is_instance_valid(play_dashboard_view) and play_dashboard_view.has_method("refresh_launcher_statuses"):
		play_dashboard_view.refresh_launcher_statuses(launcher)

func _on_launcher_game_process_crashed(game_name: String, exit_code: int, reason: String) -> void:
	print("[Lobby Error] Game process crashed for ", game_name, " (code: ", exit_code, "): ", reason)
	_on_launcher_failed(game_name, reason)

func _on_launch_overlay_cancellation_requested() -> void:
	if not _tracker_operation_active:
		launcher.cancel_tool_installation()

func _load_launcher_catalogs() -> void:
	launcher.load_paths_config()
	launcher.load_roms_catalog()
	launcher.load_launcher_config()
	launcher.sync_custom_worlds_from_server(self, [], func(success: bool):
		if success:
			print("[Lobby] Custom Archipelago worlds synchronized from backend.")
		else:
			print("[Lobby] Custom Archipelago world synchronization failed; continuing with local worlds.")
	)

func _connect_network_signals() -> void:
	NetworkManager.room_state_updated.connect(_update_players_ui)
	NetworkManager.checks_updated.connect(_on_checks_updated)
	NetworkManager.generation_log_received.connect(_on_generation_log_received)
	NetworkManager.kicked_from_room.connect(_on_kicked_from_room)
	NetworkManager.room_closed.connect(_on_room_closed)
	NetworkManager.connection_closed.connect(_on_connection_lost)

func _on_leave_pressed() -> void:
	NetworkManager.leave_room()
	_go_to_main_menu()

func _on_close_room_pressed() -> void:
	var confirm_dialog: ConfirmationDialog = ConfirmationDialog.new()
	confirm_dialog.title = "Close Room"
	confirm_dialog.dialog_text = "Are you sure you want to completely close and delete room " + NetworkManager.room_code + "? All players will be disconnected."
	confirm_dialog.ok_button_text = "Close Room"
	confirm_dialog.cancel_button_text = "Cancel"
	add_child(confirm_dialog)
	confirm_dialog.popup_centered()
	
	confirm_dialog.confirmed.connect(func():
		NetworkManager.close_room()
		confirm_dialog.queue_free()
	)
	confirm_dialog.canceled.connect(func():
		confirm_dialog.queue_free()
	)

func _on_kicked_from_room(message: String) -> void:
	var info_dialog: AcceptDialog = AcceptDialog.new()
	info_dialog.title = "Kicked from Room"
	info_dialog.dialog_text = message
	add_child(info_dialog)
	info_dialog.popup_centered()
	info_dialog.confirmed.connect(func():
		info_dialog.queue_free()
		_go_to_main_menu()
	)

func _on_room_closed(message: String) -> void:
	var info_dialog: AcceptDialog = AcceptDialog.new()
	info_dialog.title = "Room Closed"
	info_dialog.dialog_text = message
	add_child(info_dialog)
	info_dialog.popup_centered()
	info_dialog.confirmed.connect(func():
		info_dialog.queue_free()
		_go_to_main_menu()
	)

func _is_local_player_host() -> bool:
	for player_info in NetworkManager.players:
		if player_info.get("userId") == NetworkManager.user_id:
			return player_info.get("isHost", false)
	return false

func _show_kick_confirm_dialog(target_id: String, target_name: String) -> void:
	var confirm_dialog: ConfirmationDialog = ConfirmationDialog.new()
	confirm_dialog.title = "Kick Player"
	confirm_dialog.dialog_text = "Are you sure you want to kick " + target_name + " from the room?"
	confirm_dialog.ok_button_text = "Kick"
	confirm_dialog.cancel_button_text = "Cancel"
	add_child(confirm_dialog)
	confirm_dialog.popup_centered()
	
	confirm_dialog.confirmed.connect(func():
		NetworkManager.kick_player(target_id)
		confirm_dialog.queue_free()
	)
	confirm_dialog.canceled.connect(func():
		confirm_dialog.queue_free()
	)

func _on_refresh_pressed() -> void:
	options_service.clear_games_cache()
	options_service.clear_options_cache()
	_fetch_games_list()

func _load_cached_games_list() -> void:
	options_service.load_cached_games_list()
	_fetch_games_list()

func _fetch_games_list() -> void:
	if is_instance_valid(add_game_modal):
		add_game_modal.set_loading(true)
	var games: Array = await options_service.fetch_games_list()
	if is_instance_valid(add_game_modal):
		add_game_modal.set_loading(false)
		add_game_modal.update_games(games, _is_game_supported)

# =====================================================================
#                      VIEW SWITCHING & DASHBOARD
# =====================================================================

func _switch_view_mode(mode: String) -> void:
	print("[Lobby] View mode switched to: '%s'" % mode)
	current_view_mode = mode
	if mode == VIEW_MODE_PLAY:
		play_view_btn.button_pressed = true
		setup_view_btn.button_pressed = false
		play_dashboard_view.visible = true
		lobby_setup_view.visible = false
		download_seed_btn.visible = false
		view_spoiler_btn.visible = false
		_render_play_dashboard()
		if NetworkManager.checks.is_empty() and NetworkManager.seed_status == "done" and NetworkManager.room_code != "":
			_fetch_initial_checks()
	else:
		play_view_btn.button_pressed = false
		setup_view_btn.button_pressed = true
		play_dashboard_view.visible = false
		lobby_setup_view.visible = true
		if NetworkManager.seed_status == "done":
			var has_seed: bool = (NetworkManager.seed_zip_name != "")
			var has_spoiler: bool = (NetworkManager.seed_spoiler_name != "")
			download_seed_btn.visible = has_seed
			view_spoiler_btn.visible = has_spoiler

func _render_play_dashboard() -> void:
	if is_instance_valid(play_dashboard_view) and play_dashboard_view.has_method("render_play_dashboard"):
		play_dashboard_view.render_play_dashboard(launcher, local_selected_games)
	_update_dashboard_server_status()

func _get_formatted_ap_address() -> String:
	return ServerUrlHelper.format_ap_address(NetworkManager.get_ap_server_url())

func _update_dashboard_server_status() -> void:
	var archipelago_server_url: String = NetworkManager.get_ap_server_url()
	if archipelago_server_url != "":
		var clean_address: String = _get_formatted_ap_address()
		server_port_value.text = ServerUrlHelper.strip_protocol(clean_address)
		server_port_value.tooltip_text = clean_address
		if is_instance_valid(connection_dot):
			connection_dot.text = "●"
			connection_dot.add_theme_color_override("font_color", COLOR_SERVER_ACTIVE)
		if is_instance_valid(connection_badge):
			connection_badge.visible = true
		if is_instance_valid(copy_server_address_btn):
			copy_server_address_btn.visible = true
	else:
		server_port_value.text = "Connecting..."
		if is_instance_valid(connection_dot):
			connection_dot.text = "○"
			connection_dot.add_theme_color_override("font_color", COLOR_SERVER_INITIALIZING)
		if is_instance_valid(copy_server_address_btn):
			copy_server_address_btn.visible = false

func _on_copy_server_address_pressed() -> void:
	var clean_address: String = _get_formatted_ap_address()
	if clean_address == "":
		clean_address = server_port_value.text
	if clean_address != "":
		DisplayServer.clipboard_set(clean_address)
		copy_server_address_btn.text = "Copied!"
		var tree = get_tree()
		if tree:
			await tree.create_timer(1.2).timeout
			if is_instance_valid(copy_server_address_btn):
				copy_server_address_btn.text = "Copy"

func _fetch_initial_checks() -> void:
	if NetworkManager.seed_status == "done" and NetworkManager.room_code != "":
		var res: Dictionary = await NetworkManager.fetch_http("/api/checks/" + NetworkManager.room_code)
		if not res.has("error") and res.get("data") is Dictionary:
			NetworkManager.checks = res.data
			_on_checks_updated(NetworkManager.checks)

func _on_checks_updated(checks_data: Dictionary) -> void:
	if is_instance_valid(play_dashboard_view) and play_dashboard_view.has_method("update_checks"):
		play_dashboard_view.update_checks(checks_data)

# =====================================================================
#                      PLAYERS UI ORCHESTRATION
# =====================================================================

func _update_players_ui(players: Array = []) -> void:
	if players.is_empty():
		players = NetworkManager.players
		
	var sorted_players: Array = _get_sorted_players(players)
	_sync_local_player_selected_games(sorted_players)
	
	if is_instance_valid(lobby_setup_view) and lobby_setup_view.has_method("update_players_ui"):
		lobby_setup_view.update_players_ui(sorted_players, NetworkManager.user_id, _is_local_player_host())
		
	_update_seed_actions_ui(players)
	_update_server_address_display()
	_update_lock_status_display(players)
	_update_hosting_mode_ui()
	_sync_needed_custom_worlds()
	
	if NetworkManager.seed_status == "done":
		if is_instance_valid(status_label):
			status_label.visible = false
		if is_instance_valid(active_seed_badge):
			active_seed_badge.visible = false
		view_switcher_hbox.visible = true
		if not _auto_switched_to_play:
			_auto_switched_to_play = true
			_switch_view_mode(VIEW_MODE_PLAY)
	else:
		if is_instance_valid(status_label):
			status_label.visible = true
		active_seed_badge.visible = false
		view_switcher_hbox.visible = false
		_auto_switched_to_play = false

func _update_server_address_display() -> void:
	var archipelago_server_url: String = NetworkManager.get_ap_server_url()
	if archipelago_server_url != "":
		server_label.text = "Server: " + archipelago_server_url
		server_label.add_theme_color_override("font_color", COLOR_SERVER_ACTIVE)
	elif NetworkManager.seed_status == "done":
		server_label.text = "Server: Initializing..."
		server_label.add_theme_color_override("font_color", COLOR_SERVER_INITIALIZING)
	else:
		server_label.text = ""

func _update_lock_status_display(players: Array) -> void:
	var is_room_host: bool = false
	for p in players:
		if p.get("userId") == NetworkManager.user_id:
			is_room_host = p.get("isHost", false)
			break
			
	if NetworkManager.locked_by != "":
		lock_status_label.text = "Session active: Locked by " + NetworkManager.locked_by
		lock_status_label.visible = true
		force_unlock_btn.visible = is_room_host
		if is_instance_valid(close_room_btn):
			close_room_btn.visible = false
	else:
		lock_status_label.visible = false
		force_unlock_btn.visible = false
		if is_instance_valid(close_room_btn):
			close_room_btn.visible = is_room_host

	if is_instance_valid(host_tools_btn):
		host_tools_btn.visible = is_room_host and NetworkManager.seed_status == "done"

func _on_host_tools_pressed() -> void:
	host_tools_modal.open()

func _update_hosting_mode_ui() -> void:
	if not is_instance_valid(hosting_mode_option):
		return
	var is_host := _is_local_player_host()
	hosting_mode_option.visible = is_host and NetworkManager.seed_status != "done"
	hosting_mode_option.disabled = not is_host or NetworkManager.seed_status != "idle"
	if NetworkManager.hosting_mode == "archipelago_gg":
		hosting_mode_option.select(1)
	else:
		hosting_mode_option.select(0)

func _load_hosting_mode() -> void:
	if NetworkManager.room_code == "":
		return
	var response: Dictionary = await NetworkManager.fetch_http("/api/rooms/" + NetworkManager.room_code.uri_encode() + "/hosting")
	var data = response.get("data")
	if data is Dictionary:
		var hosting_mode_value = data.get("hosting_mode")
		NetworkManager.hosting_mode = hosting_mode_value if hosting_mode_value is String else "wayfinder_backend"
		var hosting_status_value = data.get("hosting_status")
		NetworkManager.hosting_status = hosting_status_value if hosting_status_value is String else ""
		var hosting_room_url_value = data.get("hosting_room_url")
		NetworkManager.hosting_room_url = hosting_room_url_value if hosting_room_url_value is String else ""
		_update_hosting_mode_ui()

func _on_hosting_mode_selected(index: int) -> void:
	var mode := "archipelago_gg" if index == 1 else "wayfinder_backend"
	hosting_mode_option.disabled = true
	var result: Dictionary = await NetworkManager.set_hosting_mode(mode)
	if result.has("error"):
		_update_hosting_mode_ui()
		status_label.text = "Hosting selection failed: " + str(result.error)
		return
	NetworkManager.hosting_mode = mode

func _get_sorted_players(players: Array) -> Array:
	var sorted_players: Array = []
	var other_players: Array = []
	for player in players:
		if player.get("userId") == NetworkManager.user_id:
			sorted_players.append(player)
		else:
			other_players.append(player)
	sorted_players.append_array(other_players)
	return sorted_players

func _sync_local_player_selected_games(sorted_players: Array) -> void:
	for player in sorted_players:
		if player.get("userId") == NetworkManager.user_id:
			var remote_games: Array = player.get("games", [])
			if local_selected_games != remote_games:
				local_selected_games = remote_games.duplicate()
				for game_name in local_selected_games:
					options_service.prepopulate_default_options(game_name)
			break

# =====================================================================
#                      ADD GAME & OPTIONS MODALS
# =====================================================================

func _on_plus_pressed() -> void:
	var games_list: Array = options_service.all_games
	if games_list.is_empty() and not launcher.launcher_presets.is_empty():
		games_list = launcher.launcher_presets.keys()
	add_game_modal.open(games_list, _is_game_supported, local_selected_games)

func _is_game_supported(game_name: String) -> bool:
	if options_service.has_cached_guided_setup(game_name):
		return true
	if launcher.has_curated_preset(game_name):
		return true
	return false

func _on_game_card_selected(game_name: String) -> void:
	if not local_selected_games.has(game_name):
		local_selected_games.append(game_name)
		await options_service.ensure_remote_guided_setup(game_name)
		await options_service.prepopulate_default_options(game_name)
		_sync_state_to_server()
	_open_config_popup(game_name)

func _open_config_popup(game_name: String) -> void:
	options_service.active_config_game = game_name
	config_modal.set_loading(true)
	config_modal.open(game_name, {}, options_service.get_config(game_name), options_service.is_guided_setup_mode(game_name))
	await options_service.ensure_remote_guided_setup(game_name)
	var schema_dict: Dictionary = await options_service.get_options_schema(game_name)
	config_modal.set_loading(false)
	config_modal.open(game_name, schema_dict, options_service.get_config(game_name), options_service.is_guided_setup_mode(game_name))

func _ensure_remote_guided_setup(game_name: String) -> void:
	await options_service.ensure_remote_guided_setup(game_name)

func _prepopulate_default_options(game_name: String) -> void:
	await options_service.prepopulate_default_options(game_name)

func _get_options_schema(game_name: String) -> Dictionary:
	return await options_service.get_options_schema(game_name)

func _on_config_modal_saved(game_name: String, config: Dictionary) -> void:
	options_service.set_config(game_name, config)
	_sync_state_to_server()

func _on_config_modal_removed(game_name: String) -> void:
	if game_name != "":
		local_selected_games.erase(game_name)
		options_service.remove_config(game_name)
	_sync_state_to_server()

func _on_config_save_pressed() -> void:
	config_modal.close()
	_sync_state_to_server()

func _on_config_remove_pressed() -> void:
	if options_service.active_config_game != "":
		local_selected_games.erase(options_service.active_config_game)
		options_service.remove_config(options_service.active_config_game)
	config_modal.close()
	_sync_state_to_server()

func _sync_state_to_server() -> void:
	var is_ready_state: bool = local_selected_games.size() > 0
	var presets_map: Dictionary = launcher.launcher_presets if is_instance_valid(launcher) else {}
	var compiled_yaml_str: String = YamlBuilder.compile_yaml(
		local_selected_games,
		options_service.active_config_game,
		NetworkManager.player_name,
		NetworkManager.room_code,
		options_service.config_states,
		presets_map
	)
	NetworkManager.update_player_state(local_selected_games, is_ready_state, compiled_yaml_str)

# =====================================================================
#                      NETWORK TEARDOWN & CLEANUP
# =====================================================================

func _on_connection_lost() -> void:
	status_label.text = "Connection Lost!"
	status_label.add_theme_color_override("font_color", COLOR_ERROR_RED)
	await get_tree().create_timer(2.0).timeout
	_go_to_main_menu()

func _disconnect_network_signals() -> void:
	if NetworkManager.generation_log_received.is_connected(_on_generation_log_received):
		NetworkManager.generation_log_received.disconnect(_on_generation_log_received)
	if NetworkManager.room_state_updated.is_connected(_update_players_ui):
		NetworkManager.room_state_updated.disconnect(_update_players_ui)
	if NetworkManager.checks_updated.is_connected(_on_checks_updated):
		NetworkManager.checks_updated.disconnect(_on_checks_updated)
	if NetworkManager.connection_closed.is_connected(_on_connection_lost):
		NetworkManager.connection_closed.disconnect(_on_connection_lost)

func _exit_tree() -> void:
	_disconnect_network_signals()
	if is_instance_valid(launcher):
		launcher.cleanup_running_processes()

func _go_to_main_menu() -> void:
	_disconnect_network_signals()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

# =====================================================================
#                     SEED ACTIONS & GENERATION LOGS
# =====================================================================

func _update_seed_actions_ui(players: Array) -> void:
	var is_host_player: bool = false
	for player_info in players:
		if player_info.get("userId") == NetworkManager.user_id:
			is_host_player = player_info.get("isHost", false)
			break
			
	var all_players_has_games: bool = not players.is_empty()
	for player_info in players:
		var p_games: Array = player_info.get("games", [])
		if p_games.is_empty():
			all_players_has_games = false
			break
			
	match NetworkManager.seed_status:
		"idle":
			generating_overlay.close()
			download_seed_btn.visible = false
			view_spoiler_btn.visible = false
			start_game_btn.visible = is_host_player
			start_game_btn.disabled = not all_players_has_games or NetworkManager.locked_by != ""
		"generating":
			generating_overlay.open("Generating Archipelago Multiworld...")
			download_seed_btn.visible = false
			view_spoiler_btn.visible = false
			start_game_btn.visible = false
		"done":
			generating_overlay.close()
			start_game_btn.visible = false
			var has_seed: bool = (NetworkManager.seed_zip_name != "")
			var has_spoiler: bool = (NetworkManager.seed_spoiler_name != "")
			if is_instance_valid(lobby_setup_view) and lobby_setup_view.has_method("update_seed_status"):
				lobby_setup_view.update_seed_status(has_seed, has_spoiler)
			if current_view_mode == VIEW_MODE_SETUP:
				download_seed_btn.visible = has_seed
				view_spoiler_btn.visible = has_spoiler
			else:
				download_seed_btn.visible = false
				view_spoiler_btn.visible = false

func _on_start_game_pressed() -> void:
	generating_overlay.open("Generating Archipelago Multiworld...")
	_sync_state_to_server()
	NetworkManager.generate_seed()

func _on_download_seed_pressed() -> void:
	if NetworkManager.seed_zip_name != "":
		var seed_download_url: String = NetworkManager.get_http_url() + "/api/seeds/" + NetworkManager.room_code + "/outputs/" + NetworkManager.seed_zip_name.uri_encode()
		OS.shell_open(seed_download_url)

func _on_view_spoiler_pressed() -> void:
	if NetworkManager.seed_spoiler_name != "":
		var spoiler_download_url: String = NetworkManager.get_http_url() + "/api/seeds/" + NetworkManager.room_code + "/outputs/" + NetworkManager.seed_spoiler_name.uri_encode()
		OS.shell_open(spoiler_download_url)

func _on_poptracker_pressed(game_name: String) -> void:
	if game_name == "":
		return
	var server_url := NetworkManager.get_ap_server_url()
	if server_url == "":
		status_label.text = "The Archipelago server address is not ready yet."
		return
	var total_games: int = maxi(local_selected_games.size(), 1)
	var preset: Dictionary = launcher.get_preset(game_name)
	var slot_name := YamlBuilder.get_slot_name(
		NetworkManager.player_name,
		game_name,
		total_games,
		str(preset.get("short_tag", ""))
	)
	_tracker_operation_active = true
	launch_overlay.present_task_status("Opening PopTracker", "Installing and preparing tracker pack...", "Preparing PopTracker")
	launcher.open_poptracker(self, game_name, server_url, slot_name, func(ok: bool, value: String):
		_tracker_operation_active = false
		if ok:
			launch_overlay.close()
			status_label.text = "PopTracker opened for " + game_name + "."
		else:
			launch_overlay.present_task_failed("PopTracker unavailable", value)
	)

func _on_generation_log_received(line: String) -> void:
	generating_overlay.add_log(line)
	if line.to_lower().contains("uploading"):
		generating_overlay.set_status("Uploading seed to Archipelago.gg...")
	elif line.to_lower().contains("room ready"):
		generating_overlay.set_status("Archipelago.gg room ready. Finalizing lobby...")
	elif line.to_lower().contains("room created"):
		generating_overlay.set_status("Archipelago.gg room created. Starting hosted server...")

# =====================================================================
#                     CLOUD SAVES DELEGATION
# =====================================================================

func _on_checkout_save_pressed() -> void:
	SaveManager.checkout_save(self, NetworkManager.room_code, NetworkManager.user_id, checkout_save_btn, func(msg): status_label.text = msg)

func _on_checkin_save_pressed() -> void:
	SaveManager.checkin_save(self, NetworkManager.room_code, NetworkManager.user_id, checkin_save_btn, func(msg): status_label.text = msg)

func _on_force_unlock_pressed() -> void:
	SaveManager.force_unlock_session(self, NetworkManager.room_code, NetworkManager.user_id, force_unlock_btn, func(msg): status_label.text = msg)

# =====================================================================
#                    GAME LAUNCHER ORCHESTRATION
# =====================================================================

func _on_launch_game_pressed() -> void:
	if local_selected_games.is_empty():
		return
	if local_selected_games.size() == 1:
		_check_and_launch_game(local_selected_games[0])
	else:
		_show_multi_game_selector(local_selected_games)

func _check_and_launch_game(game_name: String) -> void:
	print("[Lobby] User initiated launch for game: '", game_name, "'")
	_show_launch_preparing_overlay(game_name)
	launcher.sync_custom_worlds_from_server(self, [], func(success: bool):
		if not success:
			print("[Lobby] Custom Archipelago world refresh failed before launch; using local worlds.")
		launcher.launch_game(self, game_name)
	)

func _show_launch_preparing_overlay(game_name: String) -> void:
	_active_launch_game = game_name
	_active_launch_preset = launcher.get_preset(game_name)
	launch_overlay.set_modding_status("Initializing launch environment for " + game_name + "...", 5)

func _on_launcher_status_updated(_stage: int, message: String, progress_pct: float) -> void:
	launch_overlay.set_modding_status(message, int(progress_pct))

func _on_launcher_download_progress_updated(task: String, pct: float, dl_bytes: int, total_bytes: int, speed: float) -> void:
	if is_instance_valid(launch_overlay):
		launch_overlay.update_download_progress(task, pct, dl_bytes, total_bytes, speed)

func _on_launcher_modding_status_updated(msg: String, pct: int) -> void:
	if is_instance_valid(launch_overlay):
		launch_overlay.set_modding_status(msg, pct)

func _on_launcher_overlay_dismiss_requested() -> void:
	if is_instance_valid(launch_overlay):
		launch_overlay.close()
	_render_play_dashboard()

func _on_launcher_prompt_file_selection(title_text: String, instructions_text: String, filters: PackedStringArray, callback: Callable) -> void:
	_active_prompt_callback = callback
	var current_path: String = launcher.paths_config.get(_active_launch_game, "")
	launch_overlay.present_file_prompt(title_text, instructions_text, current_path, filters)

func _on_launcher_prompt_tool_installation(tool_name: String, download_url: String, subfolder: String, target_file: String, callback: Callable) -> void:
	launch_overlay.present_tool_installation(tool_name)
	launcher.ensure_tool_installed_or_download(self, tool_name, download_url, subfolder, target_file, callback)

func _on_launcher_completed(game_name: String, pid: int) -> void:
	print("[Lobby] Launch completed for ", game_name, " (PID: ", pid, ")")
	launch_overlay.close()
	_render_play_dashboard()

func _on_launcher_failed(game_name: String, error_msg: String) -> void:
	print("[Lobby Error] Launch failed for ", game_name, ": ", error_msg)
	Updater.log_message("ERROR", "Launch failed for " + game_name + ": " + error_msg)
	launch_overlay.present_launch_failure(game_name, error_msg)

func _show_multi_game_selector(games_list: Array) -> void:
	launch_overlay.present_multi_game_selector(games_list)

func _select_game_from_list(game_name: String) -> void:
	_show_launch_overlay_direct(game_name)

func _show_launch_overlay_direct(game_name: String, instructions_text: String = "") -> void:
	_active_launch_game = game_name
	_active_launch_preset = launcher.get_preset(game_name)
	var total_count: int = local_selected_games.size() if not local_selected_games.is_empty() else 1
	launch_overlay.present_game_setup(game_name, _active_launch_preset, launcher, instructions_text, total_count, NetworkManager.player_name)

func _on_launch_steam_pressed() -> void:
	var steam_id: String = str(_active_launch_preset.get("steam_appid", "367520")).strip_edges()
	if steam_id == "":
		steam_id = "367520"
	print("[Lobby] Opening Steam properties for App ID: ", steam_id)
	OS.shell_open("steam://gameproperties/" + steam_id)

func _on_launch_recheck_pressed() -> void:
	if _active_launch_game != "":
		print("[Lobby] Re-checking prerequisites for: ", _active_launch_game)
		_show_launch_overlay_direct(_active_launch_game)

func _on_launch_download_pressed() -> void:
	if _active_launch_game == "":
		return
	var required_rom: String = _active_launch_preset.get("required_rom", "")
	var launch_mode: String = _active_launch_preset.get("launch_mode", "")
	var is_rom_game: bool = (required_rom != "" or launch_mode == "patch_rom" or _active_launch_preset.get("is_rom", false))
	launch_overlay.set_download_button_disabled(true)
	
	if is_rom_game:
		var rom_key: String = required_rom if required_rom != "" else _active_launch_game
		launch_overlay.show_download_card("Downloading Base ROM (" + rom_key + ")")
		launcher.ensure_rom_exists_or_download(self, rom_key, func(success: bool, result_path_or_msg: String):
			launch_overlay.set_download_button_disabled(false)
			if success:
				launch_overlay.set_path_input_text(result_path_or_msg)
				launcher.paths_config[_active_launch_game] = result_path_or_msg
				launcher.save_paths_config()
				_continue_launch_confirm(result_path_or_msg)
			else:
				_on_launcher_failed(_active_launch_game, result_path_or_msg)
		, true)
	else:
		launch_overlay.show_download_card("Downloading Game Files (" + _active_launch_game + ")")
		launcher.ensure_pc_game_installed(self, _active_launch_game, _active_launch_preset, func(success: bool, result_path_or_msg: String):
			launch_overlay.set_download_button_disabled(false)
			if success:
				launch_overlay.set_path_input_text(result_path_or_msg)
				launcher.paths_config[_active_launch_game] = result_path_or_msg
				launcher.save_paths_config()
				_continue_launch_confirm(result_path_or_msg)
			else:
				_on_launcher_failed(_active_launch_game, result_path_or_msg)
		)

func _on_launch_overlay_confirmed(_g_name: String, game_path_str: String, emu_path_str: String) -> void:
	var launch_mode_str: String = _active_launch_preset.get("launch_mode", "")
	
	if launch_mode_str == "patch_rom":
		var emulator_preset_key: String = _active_launch_preset.get("emulator", "snes9x")
		if emu_path_str != "" and FileAccess.file_exists(emu_path_str):
			launcher.paths_config[emulator_preset_key] = emu_path_str
			launcher.save_paths_config()
			
	if _active_prompt_callback.is_valid():
		var prompt_cb: Callable = _active_prompt_callback
		_active_prompt_callback = Callable()
		launch_overlay.close()
		prompt_cb.call(true, game_path_str)
		return
		
	if game_path_str == "" or not FileAccess.file_exists(game_path_str):
		launch_overlay.set_instructions_text("[color=#f87171]Selected file does not exist. Please browse to a valid file.[/color]")
		return
		
	launcher.paths_config[_active_launch_game] = game_path_str
	launcher.save_paths_config()
	_continue_launch_confirm(game_path_str)

func _continue_launch_confirm(_game_path_str: String) -> void:
	var g_name: String = _active_launch_game
	launch_overlay.close()
	_check_and_launch_game(g_name)
