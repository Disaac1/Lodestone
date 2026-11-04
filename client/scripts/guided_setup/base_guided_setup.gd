class_name BaseGuidedSetup
extends RefCounted

const UITheme = preload("res://scripts/ui/ui_theme.gd")

signal config_updated
signal mode_toggle_requested(use_raw: bool)

var current_step: int = 1
var current_config: Dictionary = {}
var root_container: VBoxContainer
var change_callback: Callable

# --- Virtual Methods to override in subclass ---

func _get_game_title() -> String:
	return "Game"

func _get_default_config() -> Dictionary:
	return {}

func _get_steps_data() -> Array:
	# Array of Dicts: [{"num": 1, "title": "1. Goal & Pace"}, ...]
	return []

func _get_required_schema_keys() -> Array:
	# Array of String option keys required in backend schema for wizard compatibility
	return []

func _build_step_content(_step_num: int, _container: VBoxContainer) -> void:
	pass

# --- Core Setup Logic & Validation ---

func init_config(existing_config: Dictionary) -> void:
	current_config = _get_default_config().duplicate(true)
	for key in existing_config.keys():
		current_config[key] = existing_config[key]

static func validate_schema_for_keys(schema: Dictionary, required_keys: Array) -> Dictionary:
	if schema.is_empty() or not schema.has("options"):
		return {"valid": false, "reason": "Empty or invalid schema"}
		
	var schema_options = schema.get("options", [])
	var existing_names = {}
	for opt in schema_options:
		var n = opt.get("name", "")
		if n != "":
			existing_names[n] = opt
			
	for req_key in required_keys:
		if not existing_names.has(req_key):
			return {"valid": false, "reason": "Required backend option missing: " + req_key}
			
	return {"valid": true, "reason": ""}

# --- Consistent UI Builder ---

func build_wizard_ui(container: VBoxContainer, on_change_cb: Callable) -> void:
	root_container = container
	change_callback = on_change_cb
	_check_card_title_lbl = null
	_check_card_detail_lbl = null
	_check_card_lobby_pill = null
	_review_card_sub_lbl = null
	
	for child in container.get_children():
		child.queue_free()
		
	# 1. Top Header Bar with Mode Switcher
	var top_bar = HBoxContainer.new()
	top_bar.add_theme_constant_override("separation", 12)
	
	var title_lbl = Label.new()
	title_lbl.text = _get_game_title() + " Guided Setup"
	title_lbl.add_theme_font_size_override("font_size", 16)
	title_lbl.add_theme_color_override("font_color", UITheme.COLOR_ACCENT_CYAN)
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_lbl.clip_text = true
	title_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	top_bar.add_child(title_lbl)
	
	var raw_toggle_btn = Button.new()
	raw_toggle_btn.focus_mode = Control.FOCUS_NONE
	raw_toggle_btn.text = "⚡ Switch to Full Options Editor"
	raw_toggle_btn.tooltip_text = "Switch to the raw/full options view for line-by-line control"
	raw_toggle_btn.pressed.connect(func():
		mode_toggle_requested.emit(true)
	)
	top_bar.add_child(raw_toggle_btn)
	container.add_child(top_bar)
	
	var sep1 = HSeparator.new()
	container.add_child(sep1)
	
	# 2. Step Navigation Bar
	var step_nav = HBoxContainer.new()
	step_nav.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	step_nav.add_theme_constant_override("separation", 6)
	
	const CIRCLED_NUMS = ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧"]
	var steps = _get_steps_data()
	for s in steps:
		var step_num = int(s.get("num", 1))
		var raw_title = str(s.get("title", "Step " + str(step_num)))
		var clean_title = raw_title
		if clean_title.length() > 3 and clean_title[0].is_valid_int() and (clean_title[1] == "." or clean_title[2] == "."):
			var dot_idx = clean_title.find(".")
			clean_title = clean_title.substr(dot_idx + 1).strip_edges()
			
		var num_badge = CIRCLED_NUMS[step_num - 1] if step_num <= CIRCLED_NUMS.size() else str(step_num)
		var display_text = ""
		if step_num < current_step:
			display_text = "✓ " + clean_title
		else:
			display_text = num_badge + " " + clean_title

		var btn = Button.new()
		btn.focus_mode = Control.FOCUS_NONE
		btn.text = display_text
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.custom_minimum_size = Vector2(0, 36)
		btn.clip_text = true
		btn.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		
		var is_active: bool = (step_num == current_step)
		var text_color: Color = Color.WHITE if is_active else UITheme.COLOR_MUTED_TEXT
		btn.add_theme_color_override("font_color", text_color)
		
		var bg_color: Color = UITheme.COLOR_BTN_PRIMARY_BG if is_active else UITheme.COLOR_BTN_SECONDARY_BG
		UITheme.apply_button_styles(btn, bg_color, 6, UITheme.COLOR_BORDER_FOCUS if is_active else Color.TRANSPARENT, 2 if is_active else 0)
			
		btn.pressed.connect(func():
			current_step = step_num
			build_wizard_ui(container, on_change_cb)
		)
		step_nav.add_child(btn)
		
	container.add_child(step_nav)
	
	var sep2 = HSeparator.new()
	container.add_child(sep2)
	
	# 3. Content Area
	var content_panel = VBoxContainer.new()
	content_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_panel.add_theme_constant_override("separation", 16)
	container.add_child(content_panel)
	
	# Step 3 Live Check Pool Banner
	if current_step == 3:
		render_check_count_card(content_panel)
		
	_build_step_content(current_step, content_panel)
	
	# Final Step Review & Summary Card
	if current_step == steps.size() and steps.size() > 1:
		render_review_summary_card(content_panel)
	
	# 4. Standard Footer Navigation
	var footer = HBoxContainer.new()
	footer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_theme_constant_override("separation", 12)
	
	if current_step > 1:
		var prev_btn = Button.new()
		prev_btn.focus_mode = Control.FOCUS_NONE
		prev_btn.text = "◀ Back"
		prev_btn.custom_minimum_size = Vector2(100, 36)
		prev_btn.pressed.connect(func():
			current_step -= 1
			build_wizard_ui(container, on_change_cb)
		)
		footer.add_child(prev_btn)
		
	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(spacer)
	
	if current_step < steps.size():
		var next_btn = Button.new()
		next_btn.focus_mode = Control.FOCUS_NONE
		next_btn.text = "Next Step ▶"
		next_btn.custom_minimum_size = Vector2(120, 36)
		UITheme.apply_button_styles(next_btn, UITheme.COLOR_BTN_SUCCESS_BG, 6)
		next_btn.pressed.connect(func():
			current_step += 1
			build_wizard_ui(container, on_change_cb)
		)
		footer.add_child(next_btn)
		
	container.add_child(footer)

# --- Reusable Component Helpers for Subclasses ---

var _check_card_title_lbl: Label = null
var _check_card_detail_lbl: Label = null
var _check_card_lobby_pill: Label = null
var _review_card_sub_lbl: Label = null

func set_option_value(key: String, val) -> void:
	current_config[key] = val
	if change_callback and change_callback.is_valid():
		change_callback.call(key, val)
	_update_live_cards()

func refresh_ui() -> void:
	if root_container and change_callback:
		build_wizard_ui(root_container, change_callback)

func _get_check_calculator() -> Dictionary:
	return {}

func calculate_current_checks() -> Dictionary:
	var calc = _get_check_calculator()
	if calc.is_empty():
		return {"total": 0, "base": 0, "breakdown": []}
	var total: int = int(calc.get("base_count", 0))
	var breakdown: Array = []
	var base_lbl = str(calc.get("base_label", "Standard Locations"))
	if base_lbl != "":
		breakdown.append({"label": base_lbl, "count": total})
	
	for mod in calc.get("modifiers", []):
		var k = str(mod.get("key", ""))
		var label = str(mod.get("label", k))
		var val = current_config.get(k)
		var delta: int = 0
		if mod.has("multiplier"):
			delta = int(val) * int(mod["multiplier"])
		elif mod.has("values") and mod["values"] is Dictionary:
			var val_dict: Dictionary = mod["values"]
			var v_str = str(val).to_lower()
			if val_dict.has(v_str):
				delta = int(val_dict[v_str])
			elif val_dict.has(str(val)):
				delta = int(val_dict[str(val)])
		if delta != 0:
			total += delta
			breakdown.append({"label": label, "count": delta})
	return {"total": total, "base": int(calc.get("base_count", 0)), "breakdown": breakdown}

func _get_lobby_context_info(local_total: int) -> String:
	var main_loop = Engine.get_main_loop()
	if not main_loop or not ("root" in main_loop) or not main_loop.root:
		return ""
	var nm = main_loop.root.get_node_or_null("/root/NetworkManager")
	if not nm or not ("players" in nm):
		return ""
	var players_arr = nm.players
	if not (players_arr is Array) or players_arr.size() <= 1:
		return ""
	
	var lobby_total: int = 0
	var registry = load("res://scripts/guided_setup/guided_setup_registry.gd")
	for p in players_arr:
		var p_games = p.get("games", [])
		for g in p_games:
			var g_name = str(g) if g is String else str(g.get("game_name", g.get("name", "")))
			if g_name == _get_game_title():
				lobby_total += local_total
			elif registry and registry.has_method("get_estimated_checks"):
				var cfg = g.get("config", {}) if g is Dictionary else {}
				lobby_total += registry.get_estimated_checks(g_name, cfg)
			else:
				lobby_total += 50
				
	if lobby_total <= 0:
		lobby_total = local_total
	var pct: int = int(round((float(local_total) / float(max(1, lobby_total))) * 100.0))
	return "🌐 Lobby Share: ~%d / %d Checks (%d%%)" % [local_total, lobby_total, pct]

func _update_live_cards() -> void:
	var info = calculate_current_checks()
	var total = int(info.get("total", 0))
	var breakdown = info.get("breakdown", [])
	
	if is_instance_valid(_check_card_title_lbl):
		if breakdown.size() > 1:
			_check_card_title_lbl.text = "Local Check Pool: %d Checks" % total
		else:
			_check_card_title_lbl.text = "Fixed Check Pool: %d Checks" % total
			
	if is_instance_valid(_check_card_detail_lbl):
		if breakdown.size() > 1:
			var parts: PackedStringArray = []
			for b in breakdown:
				var cnt = int(b.get("count", 0))
				var sign_str = "+" if cnt > 0 and parts.size() > 0 else ""
				parts.append("%s (%s%d)" % [str(b.get("label")), sign_str, cnt])
			_check_card_detail_lbl.text = " • ".join(parts)
		else:
			_check_card_detail_lbl.text = "All standard locations in this game are active in logic."
			
	if is_instance_valid(_check_card_lobby_pill):
		var lobby_txt = _get_lobby_context_info(total)
		_check_card_lobby_pill.text = lobby_txt
		_check_card_lobby_pill.visible = (lobby_txt != "")

	if is_instance_valid(_review_card_sub_lbl):
		var dl_active = bool(current_config.get("death_link", false))
		var summary_parts: PackedStringArray = []
		if total > 0:
			summary_parts.append("Check Pool: ~%d Locations" % total)
		summary_parts.append("DeathLink: %s" % ("Enabled 💀" if dl_active else "Disabled"))
		var lobby_txt = _get_lobby_context_info(total)
		if lobby_txt != "":
			summary_parts.append(lobby_txt)
		_review_card_sub_lbl.text = "  •  ".join(summary_parts)

func render_check_count_card(container: VBoxContainer) -> void:
	var info = calculate_current_checks()
	var total = int(info.get("total", 0))
	if total <= 0:
		return
	
	var card = PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sb = StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.16, 0.22, 1.0)
	sb.border_color = UITheme.COLOR_BORDER_FOCUS
	sb.border_width_left = 2
	sb.border_width_top = 2
	sb.border_width_right = 2
	sb.border_width_bottom = 2
	sb.corner_radius_top_left = 8
	sb.corner_radius_top_right = 8
	sb.corner_radius_bottom_right = 8
	sb.corner_radius_bottom_left = 8
	sb.content_margin_left = 16
	sb.content_margin_top = 12
	sb.content_margin_right = 16
	sb.content_margin_bottom = 12
	card.add_theme_stylebox_override("panel", sb)
	
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	
	var header_hbox = HBoxContainer.new()
	header_hbox.add_theme_constant_override("separation", 8)
	
	var icon_lbl = Label.new()
	icon_lbl.text = "📍"
	icon_lbl.add_theme_font_size_override("font_size", 18)
	header_hbox.add_child(icon_lbl)
	
	var title_lbl = Label.new()
	title_lbl.add_theme_font_size_override("font_size", 16)
	title_lbl.add_theme_color_override("font_color", Color(0.92, 0.96, 1.0, 1.0))
	header_hbox.add_child(title_lbl)
	
	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_hbox.add_child(spacer)
	
	var lobby_pill = Label.new()
	lobby_pill.add_theme_font_size_override("font_size", 11)
	lobby_pill.add_theme_color_override("font_color", UITheme.COLOR_ACCENT_CYAN)
	header_hbox.add_child(lobby_pill)
	
	vbox.add_child(header_hbox)
	
	var detail_lbl = Label.new()
	detail_lbl.add_theme_font_size_override("font_size", 12)
	detail_lbl.add_theme_color_override("font_color", UITheme.COLOR_MUTED_TEXT)
	detail_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(detail_lbl)
	
	card.add_child(vbox)
	container.add_child(card)
	
	_check_card_title_lbl = title_lbl
	_check_card_detail_lbl = detail_lbl
	_check_card_lobby_pill = lobby_pill
	_update_live_cards()

func render_review_summary_card(container: VBoxContainer) -> void:
	var info = calculate_current_checks()
	var total = int(info.get("total", 0))
	
	var card = PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sb = StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.13, 0.18, 1.0)
	sb.border_color = UITheme.COLOR_BORDER_DEFAULT
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.corner_radius_top_left = 8
	sb.corner_radius_top_right = 8
	sb.corner_radius_bottom_right = 8
	sb.corner_radius_bottom_left = 8
	sb.content_margin_left = 16
	sb.content_margin_top = 12
	sb.content_margin_right = 16
	sb.content_margin_bottom = 12
	card.add_theme_stylebox_override("panel", sb)
	
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	
	var header_lbl = Label.new()
	header_lbl.text = "📋 Setup Summary & Ready to Play"
	header_lbl.add_theme_font_size_override("font_size", 14)
	header_lbl.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0, 1.0))
	vbox.add_child(header_lbl)
	
	var sub_lbl = Label.new()
	sub_lbl.add_theme_font_size_override("font_size", 12)
	sub_lbl.add_theme_color_override("font_color", UITheme.COLOR_MUTED_TEXT)
	vbox.add_child(sub_lbl)
	
	card.add_child(vbox)
	container.add_child(card)
	
	_review_card_sub_lbl = sub_lbl
	_update_live_cards()

func add_step_description(container: VBoxContainer, text: String) -> void:
	var desc = Label.new()
	desc.text = text
	desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.add_theme_font_size_override("font_size", 14)
	desc.add_theme_color_override("font_color", UITheme.COLOR_WARNING_YELLOW)
	container.add_child(desc)

func add_card_grid(container: VBoxContainer, items: Array, columns: int, selected_val, on_select: Callable) -> GridContainer:
	var grid = GridContainer.new()
	grid.columns = columns
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)

	var update_responsive_columns = func():
		if not is_instance_valid(grid):
			return
		var avail_w: float = grid.size.x
		if avail_w <= 20.0 and is_instance_valid(container):
			avail_w = container.size.x
		if avail_w <= 20.0 and is_instance_valid(root_container):
			avail_w = root_container.size.x
		if avail_w > 50.0:
			var target_card_min_w: float = 230.0
			var max_cols: int = max(1, int(floor(avail_w / target_card_min_w)))
			var target_cols: int = clamp(max_cols, 1, columns)
			if grid.columns != target_cols:
				grid.columns = target_cols

	grid.resized.connect(update_responsive_columns)
	container.resized.connect(update_responsive_columns)
	if is_instance_valid(root_container):
		root_container.resized.connect(update_responsive_columns)
	
	for item in items:
		var btn = Button.new()
		btn.focus_mode = Control.FOCUS_NONE
		btn.custom_minimum_size = Vector2(0, 75)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.text = str(item.get("title", item.get("name", ""))) + "\n" + str(item.get("desc", ""))
		btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		
		var item_id = item.get("id", item.get("name", ""))
		var item_val = item.get("val", item_id)
		var is_selected = (str(selected_val) == str(item_id) or str(selected_val) == str(item_val))
		
		var bg_col: Color = UITheme.COLOR_CARD_SELECTED_BG if is_selected else UITheme.COLOR_BG_DARK
		var border_col: Color = UITheme.COLOR_BORDER_FOCUS if is_selected else UITheme.COLOR_BORDER_DEFAULT
		var border_w: int = 2 if is_selected else 1
		UITheme.apply_button_styles(btn, bg_col, 6, border_col, border_w, UITheme.COLOR_BORDER_HOVER)
		
		btn.pressed.connect(func():
			on_select.call(item_id, item)
			refresh_ui()
		)
		grid.add_child(btn)
		
	container.add_child(grid)
	update_responsive_columns.call()
	update_responsive_columns.call()
	return grid

func add_slider_option(container: VBoxContainer, label_text: String, option_key: String, min_v: int, max_v: int, step_v: int = 1, unit_suffix: String = "") -> void:
	var row = HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 12)
	
	var lbl = Label.new()
	lbl.text = label_text
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	
	var slider = HSlider.new()
	slider.scrollable = false
	slider.custom_minimum_size = Vector2(100, 0)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.min_value = min_v
	slider.max_value = max_v
	slider.step = step_v
	slider.value = int(current_config.get(option_key, min_v))
	
	var val_lbl = Label.new()
	val_lbl.text = str(int(slider.value)) + unit_suffix
	val_lbl.custom_minimum_size = Vector2(60, 0)
	slider.value_changed.connect(func(v):
		val_lbl.text = str(int(v)) + unit_suffix
		set_option_value(option_key, int(v))
	)
	row.add_child(lbl)
	row.add_child(slider)
	row.add_child(val_lbl)
	container.add_child(row)

func add_toggle_option(container: VBoxContainer, label_text: String, option_key: String) -> void:
	var check = CheckButton.new()
	check.focus_mode = Control.FOCUS_NONE
	check.text = label_text
	check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	check.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var current_v_str = str(current_config.get(option_key, false)).to_lower()
	check.button_pressed = (current_v_str == "true" or current_v_str == "1" or current_v_str == "completely_random")
	check.toggled.connect(func(pressed):
		set_option_value(option_key, pressed)
	)
	container.add_child(check)

func add_dropdown_option(container: VBoxContainer, label_text: String, option_key: String, choices: Array) -> void:
	var row = HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 12)
	
	var lbl = Label.new()
	lbl.text = label_text
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.size_flags_stretch_ratio = 1.0
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	
	var drop = OptionButton.new()
	drop.focus_mode = Control.FOCUS_NONE
	drop.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	drop.size_flags_stretch_ratio = 1.4
	drop.fit_to_longest_item = false
	drop.clip_text = true
	drop.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	drop.custom_minimum_size = Vector2(0, 36)
	if choices.is_empty():
		return
	var current_val = str(current_config.get(option_key, choices[0].get("id", choices[0].get("name", ""))))
	var selected_idx = 0
	
	for i in range(choices.size()):
		var c = choices[i]
		var c_id = str(c.get("id", c.get("val", c.get("name", ""))))
		var c_title = str(c.get("title", c.get("name", c_id)))
		drop.add_item(c_title, i)
		if c_id == current_val:
			selected_idx = i
			
	drop.selected = selected_idx
	drop.item_selected.connect(func(idx):
		var selected_choice = choices[idx]
		var val = selected_choice.get("val", selected_choice.get("id", selected_choice.get("name", "")))
		set_option_value(option_key, val)
		if selected_choice.has("values") and selected_choice["values"] is Dictionary:
			for k in selected_choice["values"].keys():
				set_option_value(k, selected_choice["values"][k])
		refresh_ui()
	)
	
	row.add_child(lbl)
	row.add_child(drop)
	container.add_child(row)

func add_multi_select_option(container: VBoxContainer, label_text: String, option_key: String, items: Array, columns: int = 3) -> void:
	if label_text != "":
		var lbl = Label.new()
		lbl.text = label_text
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lbl.add_theme_font_size_override("font_size", 14)
		container.add_child(lbl)

	var grid = GridContainer.new()
	grid.columns = columns
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)

	var update_responsive_columns = func():
		if not is_instance_valid(grid):
			return
		var avail_w: float = grid.size.x
		if avail_w <= 20.0 and is_instance_valid(container):
			avail_w = container.size.x
		if avail_w <= 20.0 and is_instance_valid(root_container):
			avail_w = root_container.size.x
		if avail_w > 50.0:
			var target_chip_min_w: float = 170.0
			var max_cols: int = max(1, int(floor(avail_w / target_chip_min_w)))
			var target_cols: int = clamp(max_cols, 1, columns)
			if grid.columns != target_cols:
				grid.columns = target_cols

	grid.resized.connect(update_responsive_columns)
	container.resized.connect(update_responsive_columns)
	if is_instance_valid(root_container):
		root_container.resized.connect(update_responsive_columns)

	var current_arr: Array = []
	var raw_val = current_config.get(option_key, [])
	if raw_val is Array:
		current_arr = raw_val.duplicate()

	for item in items:
		var item_id = item.get("id", item.get("val", item.get("name", "")))
		var item_title = item.get("title", item.get("name", str(item_id)))
		var is_checked: bool = false
		for val in current_arr:
			if str(val) == str(item_id):
				is_checked = true
				break

		var chip_btn = Button.new()
		chip_btn.focus_mode = Control.FOCUS_NONE
		chip_btn.text = ("☑ " if is_checked else "☐ ") + str(item_title)
		chip_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		chip_btn.custom_minimum_size = Vector2(0, 36)
		chip_btn.clip_text = true
		chip_btn.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS

		var bg_col: Color = UITheme.COLOR_BTN_PRIMARY_BG if is_checked else UITheme.COLOR_BTN_SECONDARY_BG
		var border_col: Color = UITheme.COLOR_BORDER_FOCUS if is_checked else UITheme.COLOR_BORDER_DEFAULT
		UITheme.apply_button_styles(chip_btn, bg_col, 6, border_col, 2 if is_checked else 1)

		chip_btn.pressed.connect(func():
			var updated: Array = []
			var already_has: bool = false
			for val in current_arr:
				if str(val) == str(item_id):
					already_has = true
				else:
					updated.append(val)
			if not already_has:
				updated.append(item_id)
			set_option_value(option_key, updated)
			refresh_ui()
		)
		grid.add_child(chip_btn)

	container.add_child(grid)
	update_responsive_columns.call()
