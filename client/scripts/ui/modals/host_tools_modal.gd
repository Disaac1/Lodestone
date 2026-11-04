extends Control

signal closed()

const UITheme = preload("res://scripts/ui/ui_theme.gd")
const ServerUrlHelper = preload("res://scripts/core/server_url_helper.gd")

@onready var close_btn: Button = %CloseBtn
@onready var room_pill_label: Label = %RoomPillLabel
@onready var tab_container: TabContainer = %HostTabContainer

# Tab 1: Quick Actions
@onready var slots_container: VBoxContainer = %SlotsContainer
@onready var quick_feedback_label: Label = %QuickFeedbackLabel
@onready var countdown_btn: Button = %CountdownBtn
@onready var status_btn: Button = %StatusBtn
@onready var players_btn: Button = %PlayersBtn
@onready var save_btn: Button = %SaveBtn
@onready var conn_mode_badge: Label = %ConnModeBadge
@onready var conn_address_label: Label = %ConnAddressLabel
@onready var copy_conn_btn: Button = %CopyConnBtn

# Tab 2: Dispatcher
@onready var slot_option: OptionButton = %SlotOption
@onready var mode_checks_btn: Button = %ModeChecksBtn
@onready var mode_items_btn: Button = %ModeItemsBtn
@onready var mode_hints_btn: Button = %ModeHintsBtn
@onready var checks_section: VBoxContainer = %ChecksSection
@onready var items_section: VBoxContainer = %ItemsSection
@onready var hints_section: VBoxContainer = %HintsSection
@onready var loc_search_input: LineEdit = %LocSearchInput
@onready var loc_item_list: ItemList = %LocItemList
@onready var force_check_btn: Button = %ForceCheckBtn
@onready var item_search_input: LineEdit = %ItemSearchInput
@onready var item_item_list: ItemList = %ItemItemList
@onready var item_quantity_spinbox: SpinBox = %ItemQuantitySpinBox
@onready var send_item_btn: Button = %SendItemBtn
@onready var hint_search_input: LineEdit = %HintSearchInput
@onready var hint_item_list: ItemList = %HintItemList
@onready var hint_send_btn: Button = %HintSendBtn
@onready var dispatch_feedback_label: Label = %DispatchFeedbackLabel

# Tab 3: Live Console
@onready var console_output: RichTextLabel = %ConsoleOutput
@onready var console_input: LineEdit = %ConsoleInput
@onready var console_send_btn: Button = %ConsoleSendBtn
@onready var console_clear_btn: Button = %ConsoleClearBtn
@onready var chip_status_btn: Button = %ChipStatusBtn
@onready var chip_players_btn: Button = %ChipPlayersBtn
@onready var chip_countdown_btn: Button = %ChipCountdownBtn
@onready var chip_save_btn: Button = %ChipSaveBtn
@onready var chip_help_btn: Button = %ChipHelpBtn

var seed_data: Dictionary = {}
var current_dispatcher_mode: String = "checks" # "checks", "items", "hints"
var command_history: Array[String] = []
var history_index: int = -1

func _ready() -> void:
	visible = false
	close_btn.pressed.connect(close)
	
	# Tab 1 signals
	status_btn.pressed.connect(func(): _execute_command("/status"))
	players_btn.pressed.connect(func(): _execute_command("/players"))
	countdown_btn.pressed.connect(func(): _execute_command("/countdown 10"))
	save_btn.pressed.connect(func(): _execute_command("/save"))
	copy_conn_btn.pressed.connect(func():
		var addr = NetworkManager.get_ap_server_url()
		if addr != "":
			DisplayServer.clipboard_set(addr)
			quick_feedback_label.text = "Copied server address to clipboard: " + addr
	)
	
	# Tab 2 signals
	mode_checks_btn.pressed.connect(func(): _switch_dispatcher_mode("checks"))
	mode_items_btn.pressed.connect(func(): _switch_dispatcher_mode("items"))
	mode_hints_btn.pressed.connect(func(): _switch_dispatcher_mode("hints"))
	slot_option.item_selected.connect(_on_slot_selected)
	loc_search_input.text_changed.connect(_on_loc_search_changed)
	item_search_input.text_changed.connect(_on_item_search_changed)
	hint_search_input.text_changed.connect(_on_hint_search_changed)
	force_check_btn.pressed.connect(_on_force_check_pressed)
	send_item_btn.pressed.connect(_on_send_item_pressed)
	hint_send_btn.pressed.connect(_on_send_hint_pressed)
	
	# Tab 3 signals
	console_send_btn.pressed.connect(_on_console_send_pressed)
	console_input.text_submitted.connect(func(_t): _on_console_send_pressed())
	console_clear_btn.pressed.connect(func(): console_output.clear())
	
	chip_status_btn.pressed.connect(func(): _execute_command("/status"))
	chip_players_btn.pressed.connect(func(): _execute_command("/players"))
	chip_countdown_btn.pressed.connect(func(): _execute_command("/countdown 10"))
	chip_save_btn.pressed.connect(func(): _execute_command("/save"))
	chip_help_btn.pressed.connect(func(): _execute_command("/help"))
	
	console_input.gui_input.connect(_on_console_gui_input)

func open() -> void:
	visible = true
	room_pill_label.text = "ROOM: " + NetworkManager.room_code
	quick_feedback_label.text = ""
	dispatch_feedback_label.text = ""
	
	if not NetworkManager.server_log_received.is_connected(_on_server_log_received):
		NetworkManager.server_log_received.connect(_on_server_log_received)
		
	_refresh_quick_actions()
	_fetch_and_populate_seed_data()
	console_input.grab_focus()

func close() -> void:
	visible = false
	if NetworkManager.server_log_received.is_connected(_on_server_log_received):
		NetworkManager.server_log_received.disconnect(_on_server_log_received)
	closed.emit()

# =====================================================================
#                      TAB 1: QUICK ACTIONS
# =====================================================================

func _refresh_quick_actions() -> void:
	var ap_url: String = NetworkManager.get_ap_server_url()
	if ap_url != "":
		conn_address_label.text = ap_url
		if ServerUrlHelper.is_cloud_relay(ap_url):
			conn_mode_badge.text = "🔒 Cloud Relay (15s Heartbeat Active)"
			conn_mode_badge.add_theme_color_override("font_color", UITheme.COLOR_GUIDED_GREEN)
		else:
			conn_mode_badge.text = "🌐 Direct Server IP"
			conn_mode_badge.add_theme_color_override("font_color", UITheme.COLOR_PRIMARY_BLUE)
	else:
		conn_address_label.text = "Server not yet started (generate seed to launch)"
		conn_mode_badge.text = "⚪ Standby"
		conn_mode_badge.add_theme_color_override("font_color", UITheme.COLOR_MUTED_TEXT)

	for child in slots_container.get_children():
		child.queue_free()
		
	# Gather players in room
	var players_list = NetworkManager.players
	if players_list.is_empty():
		var empty_lbl = Label.new()
		empty_lbl.text = "No players currently in room."
		empty_lbl.add_theme_color_override("font_color", UITheme.COLOR_MUTED_TEXT)
		slots_container.add_child(empty_lbl)
		return
		
	for p in players_list:
		var p_name: String = p.get("name", "Player")
		var p_games: Array = p.get("games", [])
		var games_str: String = ", ".join(p_games) if not p_games.is_empty() else "No Game"
		
		var row: PanelContainer = PanelContainer.new()
		var row_style: StyleBoxFlat = UITheme.create_card_style()
		row.add_theme_stylebox_override("panel", row_style)
		
		var hbox: HBoxContainer = HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 12)
		
		var name_lbl: Label = Label.new()
		name_lbl.text = "👤 " + p_name + " (" + games_str + ")"
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.add_theme_color_override("font_color", UITheme.COLOR_TEXT_LIGHT)
		hbox.add_child(name_lbl)
		
		# Release button
		var rel_btn: Button = Button.new()
		rel_btn.text = "Release Checks"
		rel_btn.tooltip_text = "Send out all remaining items for " + p_name + " (/release " + p_name + ")"
		rel_btn.add_theme_color_override("font_color", UITheme.COLOR_SUCCESS_GREEN)
		rel_btn.pressed.connect(_show_confirm_command.bind(
			"Release Checks for " + p_name,
			"Are you sure you want to release all checks for " + p_name + "? All remaining items in their world will be sent to the multiworld.",
			"/release " + p_name
		))
		hbox.add_child(rel_btn)
		
		# Collect button
		var col_btn: Button = Button.new()
		col_btn.text = "Collect Items"
		col_btn.tooltip_text = "Collect all remaining items for " + p_name + " (/collect " + p_name + ")"
		col_btn.add_theme_color_override("font_color", UITheme.COLOR_PRIMARY_BLUE)
		col_btn.pressed.connect(_show_confirm_command.bind(
			"Collect Items for " + p_name,
			"Are you sure you want to collect all items for " + p_name + "?",
			"/collect " + p_name
		))
		hbox.add_child(col_btn)
		
		row.add_child(hbox)
		slots_container.add_child(row)

func _show_confirm_command(title: String, prompt: String, cmd: String) -> void:
	var dlg: ConfirmationDialog = ConfirmationDialog.new()
	dlg.title = title
	dlg.dialog_text = prompt
	dlg.ok_button_text = "Confirm"
	dlg.cancel_button_text = "Cancel"
	add_child(dlg)
	dlg.popup_centered()
	dlg.confirmed.connect(func():
		dlg.queue_free()
		_execute_command(cmd)
	)
	dlg.canceled.connect(func():
		dlg.queue_free()
	)

# =====================================================================
#                TAB 2: LOCATION & ITEM DISPATCHER
# =====================================================================

func _fetch_and_populate_seed_data() -> void:
	if seed_data.is_empty():
		var res: Dictionary = await NetworkManager.fetch_seed_data()
		if not res.has("error") and res.get("data") is Dictionary:
			seed_data = res.data
			print("[HostTools] Loaded seed data with %d players." % seed_data.get("players", []).size())
	_populate_dispatcher_slots()

func _populate_dispatcher_slots() -> void:
	slot_option.clear()
	var players = seed_data.get("players", [])
	if players.is_empty():
		for p in NetworkManager.players:
			players.append(p.get("name", "Player"))
			
	for p_name in players:
		slot_option.add_item(p_name)
		
	if slot_option.item_count > 0:
		slot_option.select(0)
		_on_slot_selected(0)

func _on_slot_selected(_index: int) -> void:
	_filter_locations()
	_filter_items()
	_filter_hints()

func _switch_dispatcher_mode(mode: String) -> void:
	current_dispatcher_mode = mode
	mode_checks_btn.button_pressed = (mode == "checks")
	mode_items_btn.button_pressed = (mode == "items")
	mode_hints_btn.button_pressed = (mode == "hints")
	
	checks_section.visible = (mode == "checks")
	items_section.visible = (mode == "items")
	hints_section.visible = (mode == "hints")

func _on_loc_search_changed(_text: String) -> void:
	_filter_locations()

func _filter_locations() -> void:
	loc_item_list.clear()
	if slot_option.item_count == 0:
		return
	var selected_player: String = slot_option.get_item_text(slot_option.selected)
	var locs: Array = seed_data.get("locations", {}).get(selected_player, [])
	var query: String = loc_search_input.text.strip_edges().to_lower()
	
	for loc in locs:
		var loc_str: String = str(loc)
		if query == "" or query in loc_str.to_lower():
			loc_item_list.add_item(loc_str)
			
	if loc_item_list.item_count > 0:
		loc_item_list.select(0)

func _on_item_search_changed(_text: String) -> void:
	_filter_items()

func _filter_items() -> void:
	item_item_list.clear()
	if slot_option.item_count == 0:
		return
	var selected_player: String = slot_option.get_item_text(slot_option.selected)
	var items: Array = seed_data.get("items", {}).get(selected_player, [])
	if items.is_empty():
		items = seed_data.get("allItems", [])
		
	var query: String = item_search_input.text.strip_edges().to_lower()
	for it in items:
		var it_str: String = str(it)
		if query == "" or query in it_str.to_lower():
			item_item_list.add_item(it_str)
			
	if item_item_list.item_count > 0:
		item_item_list.select(0)

func _on_hint_search_changed(_text: String) -> void:
	_filter_hints()

func _filter_hints() -> void:
	hint_item_list.clear()
	if slot_option.item_count == 0:
		return
	var selected_player: String = slot_option.get_item_text(slot_option.selected)
	var items: Array = seed_data.get("items", {}).get(selected_player, [])
	if items.is_empty():
		items = seed_data.get("allItems", [])
		
	var query: String = hint_search_input.text.strip_edges().to_lower()
	for it in items:
		var it_str: String = str(it)
		if query == "" or query in it_str.to_lower():
			hint_item_list.add_item(it_str)
			
	if hint_item_list.item_count > 0:
		hint_item_list.select(0)

func _on_force_check_pressed() -> void:
	if slot_option.item_count == 0:
		return
	var player_name: String = slot_option.get_item_text(slot_option.selected)
	var loc_name: String = ""
	if loc_item_list.get_selected_items().size() > 0:
		loc_name = loc_item_list.get_item_text(loc_item_list.get_selected_items()[0])
	elif loc_search_input.text.strip_edges() != "":
		loc_name = loc_search_input.text.strip_edges()
		
	if loc_name == "":
		dispatch_feedback_label.text = "Please select or type a location check to complete."
		return
		
	var cmd: String = "/send_location %s %s" % [player_name, loc_name]
	_execute_command(cmd)
	dispatch_feedback_label.text = "Sent check trigger: " + loc_name

func _on_send_item_pressed() -> void:
	if slot_option.item_count == 0:
		return
	var player_name: String = slot_option.get_item_text(slot_option.selected)
	var item_name: String = ""
	if item_item_list.get_selected_items().size() > 0:
		item_name = item_item_list.get_item_text(item_item_list.get_selected_items()[0])
	elif item_search_input.text.strip_edges() != "":
		item_name = item_search_input.text.strip_edges()
		
	if item_name == "":
		dispatch_feedback_label.text = "Please select or type an item to send."
		return
		
	var qty: int = int(item_quantity_spinbox.value)
	var cmd: String = ""
	if qty > 1:
		cmd = "/send_multiple %d %s %s" % [qty, player_name, item_name]
	else:
		cmd = "/send %s %s" % [player_name, item_name]
		
	_execute_command(cmd)
	dispatch_feedback_label.text = "Sent %d x %s to %s" % [qty, item_name, player_name]

func _on_send_hint_pressed() -> void:
	if slot_option.item_count == 0:
		return
	var player_name: String = slot_option.get_item_text(slot_option.selected)
	var hint_target: String = ""
	if hint_item_list.get_selected_items().size() > 0:
		hint_target = hint_item_list.get_item_text(hint_item_list.get_selected_items()[0])
	elif hint_search_input.text.strip_edges() != "":
		hint_target = hint_search_input.text.strip_edges()
		
	if hint_target == "":
		dispatch_feedback_label.text = "Please select or type an item/location to hint."
		return
		
	var cmd: String = "/hint %s %s" % [player_name, hint_target]
	_execute_command(cmd)
	dispatch_feedback_label.text = "Sent hint request for: " + hint_target

# =====================================================================
#                   TAB 3: LIVE SERVER CONSOLE
# =====================================================================

func _on_console_send_pressed() -> void:
	var cmd: String = console_input.text.strip_edges()
	if cmd == "":
		return
		
	if not cmd.begins_with("/"):
		cmd = "/" + cmd
		
	command_history.append(cmd)
	history_index = command_history.size()
	console_input.text = ""
	_execute_command(cmd)

func _on_console_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.is_pressed():
		if event.keycode == KEY_UP:
			if not command_history.is_empty():
				history_index = max(0, history_index - 1)
				console_input.text = command_history[history_index]
				console_input.caret_column = console_input.text.length()
				get_viewport().set_input_as_handled()
		elif event.keycode == KEY_DOWN:
			if not command_history.is_empty():
				history_index = min(command_history.size(), history_index + 1)
				if history_index < command_history.size():
					console_input.text = command_history[history_index]
				else:
					console_input.text = ""
				console_input.caret_column = console_input.text.length()
				get_viewport().set_input_as_handled()

func _on_server_log_received(line: String) -> void:
	_append_console_line(line)

func _append_console_line(line: String) -> void:
	var col_hex: String = "#94a3b8"
	if line.begins_with("[ERROR]"):
		col_hex = "#f87171"
	elif "sent " in line or "found their" in line:
		col_hex = "#34d399"
	elif line.begins_with("Player Status") or "connection" in line:
		col_hex = "#38bdf8"
	elif line.begins_with(">"):
		col_hex = "#c084fc"
		
	console_output.append_text("[color=" + col_hex + "]" + line + "[/color]\n")

func _execute_command(cmd: String) -> void:
	_append_console_line("> " + cmd)
	quick_feedback_label.text = "Executing: " + cmd
	dispatch_feedback_label.text = "Executing: " + cmd
	var res: Dictionary = await NetworkManager.send_server_command(cmd)
	if res.has("error"):
		_append_console_line("[ERROR] " + str(res.get("error")))
		quick_feedback_label.text = "Error: " + str(res.get("error"))
		dispatch_feedback_label.text = "Error: " + str(res.get("error"))
	else:
		quick_feedback_label.text = "Success: " + cmd
		dispatch_feedback_label.text = "Success: " + cmd
