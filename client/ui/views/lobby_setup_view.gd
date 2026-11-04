extends VBoxContainer

# --- DEPENDENCIES ---
const PlayerCardScene = preload("res://scenes/components/player_card.tscn")

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
