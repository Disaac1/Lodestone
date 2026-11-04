extends Control

signal saved(game_name: String, config: Dictionary)
signal removed(game_name: String)
signal closed()
signal browse_items_requested(title: String, target_text_edit: TextEdit, is_location: bool, available_pool: Array)

const UITheme = preload("res://scripts/ui/ui_theme.gd")
const GuidedSetupRegistry = preload("res://scripts/guided_setup/guided_setup_registry.gd")

@onready var config_title: Label = %ConfigTitle
@onready var close_btn: Button = %ConfigCloseBtn
@onready var config_spinner: Control = %ConfigSpinner
@onready var options_container: VBoxContainer = %ConfigPopupOptionsContainer
@onready var remove_btn: Button = %ConfigRemoveBtn
@onready var save_btn: Button = %ConfigSaveBtn
@onready var popup_panel: PanelContainer = $Center/PopupPanel
@onready var scroll: ScrollContainer = $Center/PopupPanel/Margin/VBox/Scroll

const COLOR_HOST_PURPLE: Color = UITheme.COLOR_HOST_PURPLE
const COLOR_ERROR_RED: Color = UITheme.COLOR_ERROR_RED
const COLOR_MUTED_TEXT: Color = UITheme.COLOR_MUTED_TEXT
const COLOR_GUIDED_GREEN: Color = UITheme.COLOR_GUIDED_GREEN

var active_game_name: String = ""
var active_schema: Dictionary = {}
var current_config: Dictionary = {}
var use_guided_setup: bool = true

func _ready() -> void:
	close_btn.pressed.connect(close)
	save_btn.pressed.connect(_on_save_pressed)
	remove_btn.pressed.connect(_on_remove_pressed)
	if is_instance_valid(scroll):
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_update_modal_bounds()
	if get_viewport():
		get_viewport().size_changed.connect(_update_modal_bounds)

func _update_modal_bounds() -> void:
	if not is_instance_valid(popup_panel):
		return
	var vp = get_viewport_rect().size
	if vp.x <= 0 or vp.y <= 0:
		return
	var target_w = clampf(vp.x - 48.0, 480.0, 960.0)
	var target_h = clampf(vp.y - 36.0, 360.0, 680.0)
	popup_panel.custom_minimum_size = Vector2(target_w, target_h)
	if is_instance_valid(scroll):
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

func open(game_name: String, schema_dict: Dictionary, config_data: Dictionary, guided_setup_enabled: bool = true) -> void:
	_update_modal_bounds()
	active_game_name = game_name
	active_schema = schema_dict
	current_config = config_data.duplicate(true)
	use_guided_setup = guided_setup_enabled
	
	config_title.text = "Configure Options: " + game_name
	visible = true
	build_options_ui()

func close() -> void:
	visible = false
	closed.emit()

func set_loading(is_loading: bool) -> void:
	if is_instance_valid(config_spinner):
		config_spinner.visible = is_loading

func build_options_ui() -> void:
	for child in options_container.get_children():
		child.queue_free()

	# Check for Guided Setup Wizard
	var has_guided_wizard: bool = GuidedSetupRegistry.has_guided_setup(active_game_name)
	if has_guided_wizard and use_guided_setup:
		var setup_result: Dictionary = GuidedSetupRegistry.validate_and_create(active_game_name, active_schema)
		if not setup_result.get("valid", false):
			print("[GuidedSetup] Failed to create guided setup for '%s': %s" % [
				active_game_name,
				str(setup_result.get("reason", "unknown reason"))
			])
			use_guided_setup = false
		else:
			var wizard: RefCounted = setup_result.get("wizard")
			wizard.init_config(current_config)
			if wizard.has_signal("mode_toggle_requested"):
				wizard.mode_toggle_requested.connect(func(use_raw_editor: bool):
					use_guided_setup = not use_raw_editor
					build_options_ui()
				)
			wizard.build_wizard_ui(options_container, func(opt_key: String, opt_val: Variant):
				current_config[opt_key] = opt_val
			)
			return

	if active_schema.is_empty() or active_schema.has("error"):
		print("[GuidedSetup] Cannot display guided setup or options for '%s': options schema is unavailable." % active_game_name)
		var err_label = Label.new()
		err_label.text = "Failed to load options definitions."
		err_label.add_theme_color_override("font_color", COLOR_ERROR_RED)
		options_container.add_child(err_label)
		return

	if has_guided_wizard and not use_guided_setup:
		var switch_btn: Button = Button.new()
		switch_btn.text = "🪄 Switch to Guided Setup Wizard"
		switch_btn.add_theme_color_override("font_color", COLOR_GUIDED_GREEN)
		switch_btn.pressed.connect(func():
			use_guided_setup = true
			build_options_ui()
		)
		options_container.add_child(switch_btn)
		options_container.add_child(HSeparator.new())

	var options_list: Array = active_schema.get("options", [])
	if options_list.is_empty():
		var empty_label = Label.new()
		empty_label.text = "No configurable options available for " + active_game_name + "."
		empty_label.add_theme_color_override("font_color", COLOR_MUTED_TEXT)
		options_container.add_child(empty_label)
		return

	var categories = _categorize_options(options_list)
	_render_option_categories(categories)

func _categorize_options(options_list: Array) -> Dictionary:
	var categories: Dictionary = {
		"Lobby & Core Settings": [],
		"Item & Location Pools": [],
		"Traps Settings": [],
		"Game Settings": []
	}
	for opt in options_list:
		var opt_name: String = opt.get("name", "")
		var opt_lower: String = opt_name.to_lower()
		if opt_name in ["progression_balancing", "accessibility", "death_link", "energy_link"]:
			categories["Lobby & Core Settings"].append(opt)
		elif opt_name in ["local_items", "non_local_items", "start_inventory", "start_hints", "start_location_hints", "exclude_locations", "priority_locations", "item_links", "start_inventory_from_pool", "plando_items"]:
			categories["Item & Location Pools"].append(opt)
		elif "trap" in opt_lower:
			categories["Traps Settings"].append(opt)
		else:
			categories["Game Settings"].append(opt)
	return categories

func _render_option_categories(categories: Dictionary) -> void:
	for cat_title in categories.keys():
		var cat_options: Array = categories[cat_title]
		if cat_options.is_empty():
			continue

		var cat_label = Label.new()
		cat_label.text = cat_title if cat_title != "Game Settings" else (active_game_name + " Gameplay Settings")
		cat_label.add_theme_color_override("font_color", COLOR_HOST_PURPLE)
		cat_label.add_theme_font_size_override("font_size", 14)
		options_container.add_child(cat_label)
		options_container.add_child(HSeparator.new())

		for opt_def in cat_options:
			var row = _create_option_row(opt_def)
			options_container.add_child(row)

func _create_option_row(opt_def: Dictionary) -> VBoxContainer:
	var opt_name: String = opt_def.get("name", "")
	var opt_display: String = opt_def.get("display_name", opt_name)
	var opt_desc: String = opt_def.get("description", "")
	var opt_type: String = opt_def.get("type", "toggle")
	var default_val: Variant = opt_def.get("default")

	if not current_config.has(opt_name):
		current_config[opt_name] = default_val

	var current_val: Variant = current_config[opt_name]
	var row: VBoxContainer = VBoxContainer.new()
	row.add_theme_constant_override("separation", 4)

	var label = Label.new()
	label.text = opt_display
	label.tooltip_text = opt_desc
	label.add_theme_font_size_override("font_size", 13)
	row.add_child(label)

	match opt_type:
		"toggle":
			var check_btn = CheckButton.new()
			check_btn.button_pressed = bool(current_val)
			check_btn.toggled.connect(func(pressed: bool): current_config[opt_name] = pressed)
			row.add_child(check_btn)
		"range":
			var range_ctrl = _create_range_ctrl(opt_name, current_val, opt_def)
			row.add_child(range_ctrl)
		"choice":
			var choice_ctrl = _create_choice_ctrl(opt_name, current_val, opt_def)
			row.add_child(choice_ctrl)
		"list":
			var list_ctrl = _create_list_ctrl(opt_name, current_val)
			row.add_child(list_ctrl)
		"dict":
			var dict_ctrl = _create_dict_ctrl(opt_name, current_val)
			row.add_child(dict_ctrl)

	return row

func _create_range_ctrl(opt_name: String, current_val: Variant, opt_def: Dictionary) -> HBoxContainer:
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)

	var slider = HSlider.new()
	slider.scrollable = false
	slider.size_flags_horizontal = SIZE_EXPAND_FILL
	slider.min_value = int(opt_def.get("min", 0))
	slider.max_value = int(opt_def.get("max", 100))
	slider.value = int(current_val)

	var val_label = Label.new()
	val_label.text = str(current_val)
	val_label.custom_minimum_size = Vector2(36, 0)

	slider.value_changed.connect(func(val: float):
		val_label.text = str(int(val))
		current_config[opt_name] = int(val)
	)
	hbox.add_child(slider)
	hbox.add_child(val_label)
	return hbox

func _create_choice_ctrl(opt_name: String, current_val: Variant, opt_def: Dictionary) -> OptionButton:
	var dropdown = OptionButton.new()
	dropdown.size_flags_horizontal = SIZE_EXPAND_FILL
	dropdown.fit_to_longest_item = false
	dropdown.clip_text = true
	dropdown.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	dropdown.custom_minimum_size = Vector2(0, 36)
	var choices: Array = opt_def.get("choices", [])
	var sel_idx: int = -1

	for idx in range(choices.size()):
		var choice = choices[idx]
		dropdown.add_item(choice)
		if choice == str(current_val):
			sel_idx = idx

	if sel_idx != -1:
		dropdown.selected = sel_idx

	dropdown.item_selected.connect(func(idx: int):
		current_config[opt_name] = dropdown.get_item_text(idx)
	)
	return dropdown

func _create_list_ctrl(opt_name: String, current_val: Variant) -> HBoxContainer:
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)

	var text_edit = TextEdit.new()
	text_edit.custom_minimum_size = Vector2(0, 80)
	text_edit.size_flags_horizontal = SIZE_EXPAND_FILL
	text_edit.placeholder_text = "Enter entries (one per line)..."
	var array_val: Array = current_val if typeof(current_val) == TYPE_ARRAY else []
	text_edit.text = "\n".join(array_val)

	text_edit.text_changed.connect(func():
		var lines = text_edit.text.split("\n")
		var clean: Array = []
		for l in lines:
			var cl = l.strip_edges()
			if cl != "":
				clean.append(cl)
		current_config[opt_name] = clean
	)
	hbox.add_child(text_edit)

	var opt_lower = opt_name.to_lower()
	var is_loc = "location" in opt_lower
	var is_item = "item" in opt_lower or "inventory" in opt_lower or "hints" in opt_lower or "pool" in opt_lower

	if is_loc or is_item:
		var browse_btn = Button.new()
		browse_btn.text = "Browse..."
		browse_btn.custom_minimum_size = Vector2(80, 0)
		browse_btn.pressed.connect(func():
			var title = "Select Locations" if is_loc else "Select Items"
			var pool = active_schema.get("location_names", []) if is_loc else active_schema.get("item_names", [])
			browse_items_requested.emit(title, text_edit, is_loc, pool)
		)
		hbox.add_child(browse_btn)

	return hbox

func _create_dict_ctrl(opt_name: String, current_val: Variant) -> HBoxContainer:
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)

	var text_edit = TextEdit.new()
	text_edit.custom_minimum_size = Vector2(0, 80)
	text_edit.size_flags_horizontal = SIZE_EXPAND_FILL
	text_edit.placeholder_text = "Key: Count (one per line)\nExample:\nItemName: 1"

	var dict_val: Dictionary = current_val if typeof(current_val) == TYPE_DICTIONARY else {}
	var lines: Array = []
	for k in dict_val.keys():
		lines.append(str(k) + ": " + str(dict_val[k]))
	text_edit.text = "\n".join(lines)

	text_edit.text_changed.connect(func():
		var parsed: Dictionary = {}
		for l in text_edit.text.split("\n"):
			var parts = l.split(":")
			if parts.size() == 2:
				var pk = parts[0].strip_edges()
				var pv = parts[1].strip_edges()
				if pk != "" and pv != "":
					parsed[pk] = pv.to_int() if pv.is_valid_int() else pv
		current_config[opt_name] = parsed
	)
	hbox.add_child(text_edit)

	var opt_lower = opt_name.to_lower()
	var is_loc = "location" in opt_lower
	var is_item = "item" in opt_lower or "inventory" in opt_lower or "hints" in opt_lower or "pool" in opt_lower

	if is_loc or is_item:
		var browse_btn = Button.new()
		browse_btn.text = "Browse..."
		browse_btn.custom_minimum_size = Vector2(80, 0)
		browse_btn.pressed.connect(func():
			var title = "Select Locations" if is_loc else "Select Items"
			var pool = active_schema.get("location_names", []) if is_loc else active_schema.get("item_names", [])
			browse_items_requested.emit(title, text_edit, is_loc, pool)
		)
		hbox.add_child(browse_btn)

	return hbox

func _on_save_pressed() -> void:
	visible = false
	saved.emit(active_game_name, current_config)

func _on_remove_pressed() -> void:
	visible = false
	removed.emit(active_game_name)
