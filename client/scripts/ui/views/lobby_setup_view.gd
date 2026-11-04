extends VBoxContainer

# --- DEPENDENCIES ---
const PlayerCardScene = preload("res://scenes/components/player_card.tscn")
const GuidedSetupRegistry = preload("res://scripts/guided_setup/guided_setup_registry.gd")
const UITheme = preload("res://scripts/ui/ui_theme.gd")

# --- SIGNALS ---
signal game_clicked(game_name: String)
signal add_game_clicked()
signal kick_player_requested(target_id: String, target_name: String)
signal download_seed_requested()
signal view_spoiler_requested()

# --- SETUP VIEW NODES ---
@onready var seed_ready_card: PanelContainer = get_node_or_null("%SeedReadyCard")
@onready var setup_download_seed_btn: Button = get_node_or_null("%SetupDownloadSeedBtn")
@onready var setup_view_spoiler_btn: Button = get_node_or_null("%SetupViewSpoilerBtn")
@onready var player_list: VBoxContainer = %PlayerList

func _ready() -> void:
	if is_instance_valid(setup_download_seed_btn):
		setup_download_seed_btn.pressed.connect(func(): download_seed_requested.emit())
	if is_instance_valid(setup_view_spoiler_btn):
		setup_view_spoiler_btn.pressed.connect(func(): view_spoiler_requested.emit())

# =====================================================================
#                      PLAYER LIST RENDERING
# =====================================================================

func update_players_ui(players: Array = [], local_user_id: String = "", is_local_host: bool = false) -> void:
	if players.is_empty():
		players = NetworkManager.players
	if local_user_id == "":
		local_user_id = NetworkManager.user_id

	for child in player_list.get_children():
		child.queue_free()

	var sorted_players: Array = get_sorted_players(players, local_user_id)

	var summary_bar = _render_seed_summary_bar(sorted_players)
	if is_instance_valid(summary_bar):
		player_list.add_child(summary_bar)

	for player_info in sorted_players:
		var player_row: Control = render_player_row(player_info, local_user_id, is_local_host)
		if is_instance_valid(player_row) and player_row.get_parent() != player_list:
			player_list.add_child(player_row)

func update_players(players: Array = [], local_user_id: String = "", is_local_host: bool = false) -> void:
	update_players_ui(players, local_user_id, is_local_host)

func get_sorted_players(players: Array, local_user_id: String) -> Array:
	var sorted_players: Array = []
	var other_players: Array = []
	for player in players:
		if player.get("userId") == local_user_id:
			sorted_players.append(player)
		else:
			other_players.append(player)
	sorted_players.append_array(other_players)
	return sorted_players

func render_player_row(player_info: Dictionary, local_user_id: String, is_local_host: bool) -> Control:
	var card = PlayerCardScene.instantiate()
	if is_instance_valid(player_list) and not card.is_inside_tree():
		player_list.add_child(card)
	card.setup(player_info, local_user_id, is_local_host)
	card.game_clicked.connect(func(g_name: String):
		if NetworkManager.seed_status == "done":
			return
		game_clicked.emit(g_name)
	)
	card.add_game_clicked.connect(func():
		add_game_clicked.emit()
	)
	card.kick_clicked.connect(func(target_id: String, target_name: String):
		kick_player_requested.emit(target_id, target_name)
	)
	return card

func update_seed_status(has_seed: bool, has_spoiler: bool) -> void:
	if is_instance_valid(seed_ready_card):
		seed_ready_card.visible = has_seed
	if is_instance_valid(setup_download_seed_btn):
		setup_download_seed_btn.visible = has_seed
	if is_instance_valid(setup_view_spoiler_btn):
		setup_view_spoiler_btn.visible = has_spoiler

func _render_seed_summary_bar(players: Array) -> Control:
	var total_checks: int = 0
	var game_parts: PackedStringArray = []
	for p in players:
		var p_name = str(p.get("name", "Player"))
		var games = p.get("games", [])
		for g in games:
			var g_name = str(g) if g is String else str(g.get("game_name", g.get("name", "")))
			var est = GuidedSetupRegistry.get_estimated_checks(g_name)
			total_checks += est
			game_parts.append("%s (%d)" % [g_name, est])
			
	if game_parts.is_empty():
		return null
		
	var panel = PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sb = StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.13, 0.18, 1.0)
	sb.border_color = UITheme.COLOR_BORDER_DEFAULT
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.corner_radius_top_left = 6
	sb.corner_radius_top_right = 6
	sb.corner_radius_bottom_right = 6
	sb.corner_radius_bottom_left = 6
	sb.content_margin_left = 14
	sb.content_margin_top = 8
	sb.content_margin_right = 14
	sb.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", sb)
	
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 10)
	
	var title = Label.new()
	title.text = "🌐 Seed Check Pool: ~%d Total Locations" % total_checks
	title.add_theme_font_size_override("font_size", 13)
	title.add_theme_color_override("font_color", UITheme.COLOR_ACCENT_CYAN)
	hbox.add_child(title)
	
	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(spacer)
	
	var detail = Label.new()
	detail.text = " • ".join(game_parts)
	detail.add_theme_font_size_override("font_size", 11)
	detail.add_theme_color_override("font_color", UITheme.COLOR_MUTED_TEXT)
	hbox.add_child(detail)
	
	panel.add_child(hbox)
	return panel
