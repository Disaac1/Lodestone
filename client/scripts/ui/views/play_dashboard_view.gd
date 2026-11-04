extends VBoxContainer

# --- DEPENDENCIES ---
const UITheme = preload("res://scripts/ui/ui_theme.gd")
const YamlBuilder = preload("res://scripts/core/yaml_builder.gd")
const DashboardGameCardScene = preload("res://scenes/components/dashboard_game_card.tscn")

# Color Palette
const COLOR_MUTED_TEXT: Color = UITheme.COLOR_MUTED_TEXT

# --- SIGNALS ---
signal launch_game_requested(game_name: String)
signal change_path_requested(game_name: String)
signal tracker_requested(game_name: String)
signal view_spoiler_requested()
signal download_seed_requested()

# --- PLAY DASHBOARD VIEW NODES ---
@onready var checks_stats_label: Label = %ChecksStatsLabel
@onready var checks_progress_bar: ProgressBar = %ChecksProgressBar
@onready var server_status_value: Label = %ServerStatusValue
@onready var dash_view_spoiler_btn: Button = get_node_or_null("%DashViewSpoilerBtn")
@onready var dash_download_seed_btn: Button = get_node_or_null("%DashDownloadSeedBtn")
@onready var filter_my_games_btn: Button = %FilterMyGamesBtn
@onready var games_count_label: Label = %GamesCountLabel
@onready var games_grid_container: HFlowContainer = %GamesGridContainer

var launcher: RefCounted = null
var local_selected_games: Array = []

func _ready() -> void:
	if is_instance_valid(filter_my_games_btn):
		filter_my_games_btn.toggled.connect(func(_p: bool): render_play_dashboard())
	if is_instance_valid(dash_view_spoiler_btn):
		dash_view_spoiler_btn.pressed.connect(func(): view_spoiler_requested.emit())
	if is_instance_valid(dash_download_seed_btn):
		dash_download_seed_btn.pressed.connect(func(): download_seed_requested.emit())

# =====================================================================
#                      CARD GRID INSTANTIATION
# =====================================================================

func render_play_dashboard(p_launcher: RefCounted = null, p_local_selected_games: Array = []) -> void:
	if p_launcher != null:
		launcher = p_launcher
	if not p_local_selected_games.is_empty():
		local_selected_games = p_local_selected_games

	for child in games_grid_container.get_children():
		child.queue_free()
		
	if local_selected_games.is_empty():
		for p in NetworkManager.players:
			if p.get("userId") == NetworkManager.user_id:
				local_selected_games = p.get("games", []).duplicate()
				break

	# 1. Collect all games across all players in the multiworld room
	var local_game_entries: Array = []
	var other_game_entries: Array = []

	var players_to_scan: Array = NetworkManager.players
	if players_to_scan.is_empty():
		for g_name in local_selected_games:
			local_game_entries.append({
				"game_name": g_name,
				"player_name": NetworkManager.player_name,
				"is_local": true,
				"user_id": NetworkManager.user_id
			})
	else:
		for p in players_to_scan:
			var p_id: String = p.get("userId", "")
			var p_name: String = p.get("name", "Player")
			var p_games: Array = p.get("games", [])
			var is_local: bool = (p_id == NetworkManager.user_id)
			for g_name in p_games:
				var entry = {
					"game_name": g_name,
					"player_name": p_name,
					"is_local": is_local,
					"user_id": p_id
				}
				if is_local:
					local_game_entries.append(entry)
				else:
					other_game_entries.append(entry)

	# Fallback if local_game_entries is empty
	if local_game_entries.is_empty():
		for g_name in local_selected_games:
			local_game_entries.append({
				"game_name": g_name,
				"player_name": NetworkManager.player_name,
				"is_local": true,
				"user_id": NetworkManager.user_id
			})

	# 2. Sort local player's games first, then other players' games
	var all_player_game_entries: Array = []
	all_player_game_entries.append_array(local_game_entries)
	all_player_game_entries.append_array(other_game_entries)

	# 3. Filter check: "Show Only My Games"
	var show_only_mine: bool = is_instance_valid(filter_my_games_btn) and filter_my_games_btn.button_pressed
	var display_entries: Array = []
	if show_only_mine:
		display_entries = local_game_entries
		games_count_label.text = str(display_entries.size()) + " Games (Mine)"
	else:
		display_entries = all_player_game_entries
		games_count_label.text = str(display_entries.size()) + " Multiworld Games"

	if is_instance_valid(dash_view_spoiler_btn):
		dash_view_spoiler_btn.visible = NetworkManager.seed_spoiler_name != ""
	if is_instance_valid(dash_download_seed_btn):
		dash_download_seed_btn.visible = NetworkManager.seed_zip_name != ""
	
	update_server_status()
	update_checks_progress_ui()
		
	if display_entries.is_empty():
		var empty_label: Label = Label.new()
		empty_label.text = "No games assigned in this multiworld session."
		empty_label.add_theme_color_override("font_color", COLOR_MUTED_TEXT)
		games_grid_container.add_child(empty_label)
		return
		
	for entry in display_entries:
		var card: PanelContainer = create_game_grid_card(entry.game_name, entry.player_name, entry.is_local)
		if is_instance_valid(card) and card.get_parent() != games_grid_container:
			games_grid_container.add_child(card)

func create_game_grid_card(game_name: String, owner_name: String = "", is_local: bool = true) -> PanelContainer:
	var card = DashboardGameCardScene.instantiate()
	if is_instance_valid(games_grid_container) and not card.is_inside_tree():
		games_grid_container.add_child(card)
	var total_games_count: int = local_selected_games.size() if not local_selected_games.is_empty() else 1
	var custom_tag_slot: String = launcher.get_preset(game_name).get("short_tag", "") if launcher else ""
	var p_name: String = owner_name if owner_name != "" else NetworkManager.player_name
	var slot_name_str: String = YamlBuilder.get_slot_name(p_name, game_name, total_games_count, custom_tag_slot)
	var preset = launcher.get_preset(game_name) if launcher else {}
	var status_info = launcher.get_game_launch_status(game_name) if launcher else {}
	var checks_info = NetworkManager.checks.get("games", {}).get(game_name, {})
	
	card.setup(game_name, slot_name_str, preset, status_info, checks_info, p_name, is_local)
	if is_local:
		card.launch_pressed.connect(func(g_name: String):
			print("[PlayDashboardView] Grid card launch_pressed received for: '", g_name, "'")
			launch_game_requested.emit(g_name)
		)
		card.change_path_pressed.connect(func(g_name: String):
			print("[PlayDashboardView] Grid card change_path_pressed received for: '", g_name, "'")
			change_path_requested.emit(g_name)
		)
		card.tracker_pressed.connect(func(g_name: String):
			tracker_requested.emit(g_name)
		)
	return card

func update_server_status() -> void:
	var archipelago_server_url: String = NetworkManager.get_ap_server_url()
	if archipelago_server_url != "":
		server_status_value.text = "Central Server: Active"
	else:
		server_status_value.text = "MultiServer: Initializing..."

# =====================================================================
#                      CHECK PROGRESS BARS
# =====================================================================

func update_checks(checks_data: Dictionary = {}) -> void:
	if checks_data.is_empty():
		checks_data = NetworkManager.checks
	update_checks_progress_ui(checks_data)
	var games_checks: Dictionary = checks_data.get("games", {})
	for child in games_grid_container.get_children():
		if child.has_method("update_checks_progress") and "current_game_name" in child:
			var g_name: String = child.current_game_name
			var g_checks: Dictionary = games_checks.get(g_name, {})
			child.update_checks_progress(g_checks)

func update_checks_progress_ui(checks_data: Dictionary = {}) -> void:
	if checks_data.is_empty():
		checks_data = NetworkManager.checks
	if checks_data.is_empty():
		checks_stats_label.text = "Checks: 0 / 0 (0%)"
		checks_progress_bar.value = 0
		return
		
	var total_checked: int = int(checks_data.get("totalChecked", 0))
	var total_locations: int = int(checks_data.get("totalLocations", 0))
	
	if total_locations > 0:
		var pct: float = (float(total_checked) / float(total_locations)) * 100.0
		checks_stats_label.text = "Checks: %d / %d (%.1f%%)" % [total_checked, total_locations, pct]
		checks_progress_bar.max_value = total_locations
		checks_progress_bar.value = total_checked
	else:
		checks_stats_label.text = "Checks: %d Completed" % total_checked
		checks_progress_bar.value = 0

func refresh_launcher_statuses(p_launcher: RefCounted = null) -> void:
	if p_launcher != null:
		launcher = p_launcher
	if not launcher:
		return
	for child in games_grid_container.get_children():
		if child.has_method("update_launch_status") and "current_game_name" in child:
			var g_name: String = child.current_game_name
			var status_info: Dictionary = launcher.get_game_launch_status(g_name)
			child.update_launch_status(status_info)
			child.update_tracker_support(launcher.get_preset(g_name))
