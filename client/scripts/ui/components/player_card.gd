extends PanelContainer

signal game_clicked(game_name: String)
signal add_game_clicked()
signal kick_clicked(user_id: String, user_name: String)

const UITheme = preload("res://scripts/ui/ui_theme.gd")
const GuidedSetupRegistry = preload("res://scripts/guided_setup/guided_setup_registry.gd")

@onready var name_label: Label = %NameLabel
@onready var host_badge: Label = %HostBadge
@onready var status_badge: Label = %StatusBadge
@onready var games_container: HBoxContainer = %GamesContainer
@onready var kick_btn: Button = %KickBtn

var player_data: Dictionary = {}
var local_user_id: String = ""
var local_is_host: bool = false
var is_local: bool = false
var is_host: bool = false

func _ready() -> void:
	if not player_data.is_empty():
		_bind_ui()

func setup(p_data: Dictionary, p_local_user_id: String, p_local_is_host: bool) -> void:
	player_data = p_data
	local_user_id = p_local_user_id
	local_is_host = p_local_is_host
	var p_id: String = p_data.get("userId", "")
	is_local = (p_id == local_user_id)
	is_host = p_data.get("isHost", false)

	if is_node_ready():
		_bind_ui()

func _bind_ui() -> void:
	var p_name: String = player_data.get("name", "Unknown")
	var is_connected: bool = player_data.get("isConnected", true)
	var games: Array = player_data.get("games", [])

	# 1. Name and Host badge
	name_label.text = p_name + (" (You)" if is_local else "")
	if is_local:
		name_label.add_theme_color_override("font_color", UITheme.COLOR_LOCAL_PLAYER)
	else:
		name_label.remove_theme_color_override("font_color")

	host_badge.visible = is_host
	
	# 2. Status Badge
	if not is_connected:
		status_badge.text = "OFFLINE"
		status_badge.add_theme_color_override("font_color", UITheme.COLOR_STATUS_OFFLINE)
	elif games.size() > 0:
		status_badge.text = "READY (" + str(games.size()) + ")"
		status_badge.add_theme_color_override("font_color", UITheme.COLOR_STATUS_READY)
	else:
		status_badge.text = "NO GAMES"
		status_badge.add_theme_color_override("font_color", UITheme.COLOR_STATUS_NOT_READY)

	# 3. Games Badges
	for child in games_container.get_children():
		child.queue_free()

	for g_name in games:
		var badge: Button = Button.new()
		badge.custom_minimum_size = Vector2(44, 32)
		badge.focus_mode = Control.FOCUS_NONE
		var est_checks: int = GuidedSetupRegistry.get_estimated_checks(str(g_name))
		badge.tooltip_text = "%s (~%d checks)%s" % [str(g_name), est_checks, " (Click to configure)" if is_local else ""]
		
		# Abbreviation / short tag
		var words: PackedStringArray = str(g_name).split(" ")
		var short_tag: String = ""
		for w in words:
			if w.length() > 0:
				var c = w[0].to_upper()
				if (c >= "A" and c <= "Z") or (c >= "0" and c <= "9"):
					short_tag += c
		badge.text = short_tag.left(3) if short_tag != "" else str(g_name).left(3)
		
		# Color styling from hash
		var hash_val: int = str(g_name).hash()
		var r: float = float((hash_val & 0xFF0000) >> 16) / 255.0
		var g: float = float((hash_val & 0x00FF00) >> 8) / 255.0
		var b: float = float(hash_val & 0x0000FF) / 255.0
		var col: Color = Color(r, g, b).lerp(Color(0.2, 0.2, 0.25), 0.45)
		
		var sb: StyleBoxFlat = UITheme.create_button_style(col, 6)
		badge.add_theme_stylebox_override("normal", sb)
		
		var sb_hover: StyleBoxFlat = UITheme.create_hover_style(sb, 0.2)
		badge.add_theme_stylebox_override("hover", sb_hover)
		
		if is_local:
			badge.pressed.connect(_on_game_badge_pressed.bind(str(g_name)))
		games_container.add_child(badge)

	# 4. Add Game Button (only for local player)
	if is_local:
		var add_btn: Button = Button.new()
		add_btn.text = "+ Add Game"
		add_btn.custom_minimum_size = Vector2(90, 32)
		add_btn.focus_mode = Control.FOCUS_NONE
		add_btn.pressed.connect(func():
			add_game_clicked.emit()
		)
		games_container.add_child(add_btn)

	# 5. Kick button (only for host viewing someone else)
	if local_is_host and not is_local:
		kick_btn.visible = true
		if not kick_btn.pressed.is_connected(_on_kick_pressed):
			kick_btn.pressed.connect(_on_kick_pressed)
	else:
		kick_btn.visible = false

func _on_game_badge_pressed(g_name: String) -> void:
	print("[PlayerCard] Game badge clicked: '", g_name, "'")
	game_clicked.emit(g_name)

func _on_kick_pressed() -> void:
	kick_clicked.emit(player_data.get("userId", ""), player_data.get("name", "Player"))
