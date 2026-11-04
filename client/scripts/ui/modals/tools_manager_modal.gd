class_name ToolsManagerModal
extends Control

signal closed()
signal tool_status_changed(tool_key: String, new_status: Dictionary)

const UITheme = preload("res://scripts/ui/ui_theme.gd")

@onready var close_btn: Button = %CloseBtn
@onready var done_btn: Button = %DoneBtn
@onready var refresh_btn: Button = %RefreshBtn
@onready var open_folder_btn: Button = %OpenFolderBtn
@onready var search_input: LineEdit = %SearchInput
@onready var filter_all_btn: Button = %FilterAllBtn
@onready var filter_installed_btn: Button = %FilterInstalledBtn
@onready var filter_not_installed_btn: Button = %FilterNotInstalledBtn
@onready var total_size_badge: Label = %TotalSizeBadge
@onready var installed_count_badge: Label = %InstalledCountBadge
@onready var tools_container: VBoxContainer = %ToolsContainer
@onready var empty_label: Label = %EmptyLabel
@onready var file_dialog: FileDialog = %ToolFileDialog
@onready var confirm_dialog: ConfirmationDialog = %ConfirmDialog
@onready var path_info_label: Label = %PathInfoLabel

var launcher = null
var _active_filter: String = "all" # "all", "installed", "not_installed"
var _all_tools: Array[Dictionary] = []
var _locating_tool_key: String = ""
var _confirm_action: Callable = Callable()
var _installing_tools: Dictionary = {}

func _ready() -> void:
	visible = false
	close_btn.pressed.connect(close)
	done_btn.pressed.connect(close)
	refresh_btn.pressed.connect(refresh)
	open_folder_btn.pressed.connect(_on_open_tools_folder_pressed)
	search_input.text_changed.connect(func(_t): _render_tools())

	filter_all_btn.pressed.connect(func(): _set_filter("all"))
	filter_installed_btn.pressed.connect(func(): _set_filter("installed"))
	filter_not_installed_btn.pressed.connect(func(): _set_filter("not_installed"))

	file_dialog.file_selected.connect(_on_file_selected)
	confirm_dialog.confirmed.connect(_on_dialog_confirmed)

	_update_filter_buttons()

func open(p_launcher = null) -> void:
	if p_launcher:
		launcher = p_launcher
	visible = true

	if launcher and launcher.has_signal("download_progress_updated"):
		if not launcher.download_progress_updated.is_connected(_on_download_progress_updated):
			launcher.download_progress_updated.connect(_on_download_progress_updated)

	var tools_dir_path: String = ProjectSettings.globalize_path("user://tools")
	path_info_label.text = "Tools location: " + tools_dir_path

	refresh()

func close() -> void:
	visible = false
	if launcher and launcher.has_signal("download_progress_updated"):
		if launcher.download_progress_updated.is_connected(_on_download_progress_updated):
			launcher.download_progress_updated.disconnect(_on_download_progress_updated)
	closed.emit()

func refresh() -> void:
	if not launcher:
		return

	var overview: Dictionary = launcher.get_all_tools_status()
	var tools_arr: Array = overview.get("tools", [])
	_all_tools.clear()
	for t in tools_arr:
		if t is Dictionary:
			_all_tools.append(t)

	var total_size_str: String = str(overview.get("formatted_total_size", "0 B"))
	var installed_cnt: int = int(overview.get("installed_count", 0))
	var total_cnt: int = int(overview.get("total_count", _all_tools.size()))

	total_size_badge.text = "💾 Space: " + total_size_str
	installed_count_badge.text = "📦 " + str(installed_cnt) + "/" + str(total_cnt) + " Installed"

	_render_tools()

func _set_filter(filter_name: String) -> void:
	_active_filter = filter_name
	_update_filter_buttons()
	_render_tools()

func _update_filter_buttons() -> void:
	filter_all_btn.flat = (_active_filter != "all")
	filter_installed_btn.flat = (_active_filter != "installed")
	filter_not_installed_btn.flat = (_active_filter != "not_installed")

func _get_tool_icon(tool_key: String) -> String:
	var l_key: String = tool_key.to_lower()
	if l_key.contains("dolphin"):
		return "🐬"
	elif l_key.contains("bizhawk") or l_key.contains("hawk"):
		return "🦅"
	elif l_key.contains("archipelago"):
		return "🌐"
	elif l_key.contains("poptracker"):
		return "🗺️"
	elif l_key.contains("snes"):
		return "🕹️"
	elif l_key.contains("sm64") or l_key.contains("mario"):
		return "🍄"
	return "⚙️"

func _render_tools() -> void:
	for child in tools_container.get_children():
		child.queue_free()

	var search_text: String = search_input.text.strip_edges().to_lower()
	var visible_count: int = 0

	for tool in _all_tools:
		var key: String = str(tool.get("key", ""))
		var name: String = str(tool.get("name", key))
		var exe_name: String = str(tool.get("executable", ""))
		var installed: bool = bool(tool.get("installed", false))
		var is_managed: bool = bool(tool.get("is_managed", false))
		var status_code: String = str(tool.get("status_code", "NOT_INSTALLED"))
		var size_formatted: String = str(tool.get("formatted_size", "0 B"))
		var path: String = str(tool.get("path", ""))
		var managed_dir: String = str(tool.get("managed_dir", ""))
		var integrity_error: String = str(tool.get("integrity_error", ""))

		# Filter by search
		if search_text != "":
			var matches: bool = name.to_lower().contains(search_text) \
				or key.to_lower().contains(search_text) \
				or exe_name.to_lower().contains(search_text)
			if not matches:
				continue

		# Filter by category
		if _active_filter == "installed" and not installed:
			continue
		elif _active_filter == "not_installed" and installed:
			continue

		visible_count += 1
		var card: PanelContainer = _build_tool_card(tool)
		tools_container.add_child(card)

	empty_label.visible = (visible_count == 0)

func _build_tool_card(tool: Dictionary) -> PanelContainer:
	var key: String = str(tool.get("key", ""))
	var name: String = str(tool.get("name", key))
	var exe_name: String = str(tool.get("executable", ""))
	var installed: bool = bool(tool.get("installed", false))
	var is_managed: bool = bool(tool.get("is_managed", false))
	var status_code: String = str(tool.get("status_code", "NOT_INSTALLED"))
	var size_formatted: String = str(tool.get("formatted_size", "0 B"))
	var path: String = str(tool.get("path", ""))
	var managed_dir: String = str(tool.get("managed_dir", ""))
	var integrity_error: String = str(tool.get("integrity_error", ""))
	var is_installing: bool = _installing_tools.has(key)

	var panel: PanelContainer = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.14, 0.19, 1.0)
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	if status_code == "CORRUPT":
		sb.border_color = Color(0.9, 0.3, 0.3, 0.8)
	elif installed:
		sb.border_color = Color(0.25, 0.35, 0.5, 0.7)
	else:
		sb.border_color = Color(0.2, 0.22, 0.3, 0.7)
	sb.corner_radius_top_left = 8
	sb.corner_radius_top_right = 8
	sb.corner_radius_bottom_right = 8
	sb.corner_radius_bottom_left = 8
	panel.add_theme_stylebox_override("panel", sb)

	var margin: MarginContainer = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_bottom", 12)
	panel.add_child(margin)

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	# --- Header Row ---
	var header_hbox: HBoxContainer = HBoxContainer.new()
	header_hbox.add_theme_constant_override("separation", 10)
	vbox.add_child(header_hbox)

	var icon_label: Label = Label.new()
	icon_label.text = _get_tool_icon(key)
	icon_label.add_theme_font_size_override("font_size", 20)
	header_hbox.add_child(icon_label)

	var name_label: Label = Label.new()
	name_label.text = name
	name_label.add_theme_font_size_override("font_size", 15)
	name_label.add_theme_color_override("font_color", Color(0.92, 0.95, 1.0))
	header_hbox.add_child(name_label)

	var exe_label: Label = Label.new()
	exe_label.text = "(" + exe_name + ")"
	exe_label.add_theme_font_size_override("font_size", 12)
	exe_label.add_theme_color_override("font_color", Color(0.55, 0.6, 0.7))
	header_hbox.add_child(exe_label)

	var spacer: Control = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_hbox.add_child(spacer)

	# Status Badge
	var badge: Label = Label.new()
	badge.add_theme_font_size_override("font_size", 12)
	var badge_sb := StyleBoxFlat.new()
	badge_sb.corner_radius_top_left = 4
	badge_sb.corner_radius_top_right = 4
	badge_sb.corner_radius_bottom_right = 4
	badge_sb.corner_radius_bottom_left = 4
	badge_sb.content_margin_left = 8
	badge_sb.content_margin_right = 8
	badge_sb.content_margin_top = 3
	badge_sb.content_margin_bottom = 3

	if is_installing:
		badge.text = "⏳ Installing..."
		badge_sb.bg_color = Color(0.2, 0.5, 0.8, 0.3)
		badge.add_theme_color_override("font_color", Color(0.4, 0.8, 1.0))
	elif status_code == "INSTALLED":
		badge.text = "● Installed (" + size_formatted + ")"
		badge_sb.bg_color = Color(0.1, 0.4, 0.2, 0.3)
		badge.add_theme_color_override("font_color", Color(0.3, 0.9, 0.5))
	elif status_code == "EXTERNAL":
		badge.text = "🔗 External (" + size_formatted + ")"
		badge_sb.bg_color = Color(0.1, 0.3, 0.5, 0.3)
		badge.add_theme_color_override("font_color", Color(0.4, 0.75, 1.0))
	elif status_code == "CORRUPT":
		badge.text = "⚠️ Corrupt / Incomplete"
		badge_sb.bg_color = Color(0.5, 0.15, 0.15, 0.3)
		badge.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
	else:
		badge.text = "○ Not Installed"
		badge_sb.bg_color = Color(0.2, 0.2, 0.25, 0.3)
		badge.add_theme_color_override("font_color", Color(0.6, 0.65, 0.7))

	badge.add_theme_stylebox_override("normal", badge_sb)
	header_hbox.add_child(badge)

	# --- Middle Row: Path or Error ---
	var path_box: HBoxContainer = HBoxContainer.new()
	path_box.add_theme_constant_override("separation", 6)
	path_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(path_box)

	var path_desc_label: Label = Label.new()
	path_desc_label.add_theme_font_size_override("font_size", 11)
	path_desc_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	path_desc_label.clip_text = true
	path_desc_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if installed:
		path_desc_label.text = "Path: " + path
		path_desc_label.tooltip_text = path
		path_desc_label.add_theme_color_override("font_color", Color(0.65, 0.7, 0.8))
	else:
		var target_loc: String = ProjectSettings.globalize_path(managed_dir)
		path_desc_label.text = "Target directory: " + target_loc
		path_desc_label.tooltip_text = target_loc
		path_desc_label.add_theme_color_override("font_color", Color(0.45, 0.5, 0.6))
	path_box.add_child(path_desc_label)

	if integrity_error != "":
		var err_label: Label = Label.new()
		err_label.text = "• " + integrity_error
		err_label.add_theme_font_size_override("font_size", 11)
		err_label.add_theme_color_override("font_color", Color(0.95, 0.4, 0.4))
		err_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		err_label.clip_text = true
		err_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_child(err_label)

	# --- Live Progress Row (during installation) ---
	if is_installing:
		var prog_info: Dictionary = _installing_tools.get(key, {})
		var prog_vbox: VBoxContainer = VBoxContainer.new()
		prog_vbox.add_theme_constant_override("separation", 4)
		vbox.add_child(prog_vbox)

		var prog_bar: ProgressBar = ProgressBar.new()
		prog_bar.custom_minimum_size = Vector2(0, 14)
		prog_bar.max_value = 100.0
		prog_bar.value = float(prog_info.get("pct", 0.0))
		prog_bar.show_percentage = true
		prog_vbox.add_child(prog_bar)

		var prog_msg: Label = Label.new()
		prog_msg.text = str(prog_info.get("message", "Processing installation..."))
		prog_msg.add_theme_font_size_override("font_size", 11)
		prog_msg.add_theme_color_override("font_color", Color(0.4, 0.8, 1.0))
		prog_vbox.add_child(prog_msg)

	# --- Actions Row ---
	var actions_hbox: HBoxContainer = HBoxContainer.new()
	actions_hbox.add_theme_constant_override("separation", 8)
	vbox.add_child(actions_hbox)

	var act_spacer: Control = Control.new()
	act_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions_hbox.add_child(act_spacer)

	if not is_installing:
		if not installed or status_code == "CORRUPT":
			# Install Button
			var inst_btn: Button = Button.new()
			inst_btn.text = "⬇ Install" if status_code != "CORRUPT" else "🔧 Repair / Install"
			inst_btn.custom_minimum_size = Vector2(100, 28)
			inst_btn.add_theme_color_override("font_color", Color(0.3, 0.85, 1.0))
			inst_btn.pressed.connect(func(): _on_install_clicked(key))
			actions_hbox.add_child(inst_btn)

			# Locate external executable
			var locate_btn: Button = Button.new()
			locate_btn.text = "🔗 Locate .exe..."
			locate_btn.custom_minimum_size = Vector2(110, 28)
			locate_btn.pressed.connect(func(): _on_locate_clicked(key))
			actions_hbox.add_child(locate_btn)

		if installed:
			# Reinstall Button
			var reinstall_btn: Button = Button.new()
			reinstall_btn.text = "🔄 Reinstall"
			reinstall_btn.custom_minimum_size = Vector2(95, 28)
			reinstall_btn.tooltip_text = "Completely delete and redownload clean official version"
			reinstall_btn.add_theme_color_override("font_color", Color(0.95, 0.8, 0.3))
			reinstall_btn.pressed.connect(func(): _on_reinstall_clicked(key))
			actions_hbox.add_child(reinstall_btn)

			if is_managed:
				# Uninstall Button
				var uninstall_btn: Button = Button.new()
				uninstall_btn.text = "🗑 Uninstall"
				uninstall_btn.custom_minimum_size = Vector2(95, 28)
				uninstall_btn.tooltip_text = "Delete files from disk to free space"
				uninstall_btn.add_theme_color_override("font_color", Color(0.95, 0.4, 0.4))
				uninstall_btn.pressed.connect(func(): _on_uninstall_clicked(key))
				actions_hbox.add_child(uninstall_btn)
			else:
				# External Unlink Button
				var unlink_btn: Button = Button.new()
				unlink_btn.text = "❌ Unlink"
				unlink_btn.custom_minimum_size = Vector2(85, 28)
				unlink_btn.tooltip_text = "Remove custom path link from Wayfinder"
				unlink_btn.pressed.connect(func(): _on_unlink_clicked(key))
				actions_hbox.add_child(unlink_btn)

				var change_btn: Button = Button.new()
				change_btn.text = "🔗 Change..."
				change_btn.custom_minimum_size = Vector2(85, 28)
				change_btn.pressed.connect(func(): _on_locate_clicked(key))
				actions_hbox.add_child(change_btn)

			# Open Folder Button
			var folder_btn: Button = Button.new()
			folder_btn.text = "📂 Folder"
			folder_btn.custom_minimum_size = Vector2(85, 28)
			folder_btn.pressed.connect(func(): _on_open_tool_folder(key))
			actions_hbox.add_child(folder_btn)

	return panel

func _on_download_progress_updated(task: String, pct: float, dl_bytes: int, total_bytes: int, speed: float) -> void:
	for tool in _all_tools:
		var name: String = str(tool.get("name", ""))
		var key: String = str(tool.get("key", ""))
		if task.to_lower().contains(name.to_lower()) or task.to_lower().contains(key.to_lower()):
			var speed_str: String = "%.1f MB/s" % (speed / (1024.0 * 1024.0)) if speed > 0 else ""
			var dl_mb: String = "%.1f" % (dl_bytes / (1024.0 * 1024.0))
			var tot_mb: String = "%.1f" % (total_bytes / (1024.0 * 1024.0))
			var msg: String = "Downloading: " + dl_mb + " / " + tot_mb + " MB" + (" (" + speed_str + ")" if speed_str != "" else "")
			_installing_tools[key] = {
				"pct": pct,
				"message": msg
			}
			_render_tools()
			break

func _on_install_clicked(tool_key: String) -> void:
	if not launcher:
		return
	_installing_tools[tool_key] = {"pct": 0.0, "message": "Initiating download..."}
	_render_tools()

	var result: Dictionary = await launcher.install_tool(self, tool_key)
	_installing_tools.erase(tool_key)
	refresh()
	tool_status_changed.emit(tool_key, launcher.get_tool_status(tool_key))

func _on_reinstall_clicked(tool_key: String) -> void:
	var tool_def: Dictionary = launcher.launcher_tools.get(tool_key, {})
	var tool_name: String = str(tool_def.get("name", tool_key))
	_prompt_confirm(
		"Reinstall " + tool_name + "?",
		"This will delete the existing files in user://tools and re-download a fresh, clean copy. This is recommended if files became corrupted or missing.",
		func():
			_installing_tools[tool_key] = {"pct": 0.0, "message": "Reinstalling clean copy..."}
			_render_tools()
			var result: Dictionary = await launcher.reinstall_tool(self, tool_key)
			_installing_tools.erase(tool_key)
			refresh()
			tool_status_changed.emit(tool_key, launcher.get_tool_status(tool_key))
	)

func _on_uninstall_clicked(tool_key: String) -> void:
	var tool_def: Dictionary = launcher.launcher_tools.get(tool_key, {})
	var tool_name: String = str(tool_def.get("name", tool_key))
	var status: Dictionary = launcher.get_tool_status(tool_key)
	var size_str: String = str(status.get("formatted_size", ""))

	_prompt_confirm(
		"Uninstall " + tool_name + "?",
		"This will permanently delete " + tool_name + " (" + size_str + ") from your computer to reclaim disk space.\n\nYou can reinstall it at any time.",
		func():
			launcher.uninstall_tool(tool_key)
			refresh()
			tool_status_changed.emit(tool_key, launcher.get_tool_status(tool_key))
	)

func _on_unlink_clicked(tool_key: String) -> void:
	if launcher:
		launcher.unlink_external_tool(tool_key)
		refresh()
		tool_status_changed.emit(tool_key, launcher.get_tool_status(tool_key))

func _on_locate_clicked(tool_key: String) -> void:
	_locating_tool_key = tool_key
	var tool_def: Dictionary = launcher.launcher_tools.get(tool_key, {})
	var exe_name: String = str(tool_def.get("executable", "*.exe"))
	file_dialog.title = "Locate " + str(tool_def.get("name", tool_key))
	file_dialog.filters = PackedStringArray([exe_name + " ; Target Executable", "*.exe ; Windows Executable", "*.* ; All Files"])
	file_dialog.popup_centered(Vector2i(700, 500))

func _on_file_selected(path: String) -> void:
	if _locating_tool_key == "" or not launcher:
		return
	var res: Dictionary = launcher.set_external_tool_path(_locating_tool_key, path)
	if not res.get("success", false):
		var err: String = str(res.get("error", "Failed to link path"))
		_prompt_confirm("Link Failed", err, Callable())
	_locating_tool_key = ""
	refresh()

func _on_open_tool_folder(tool_key: String) -> void:
	if launcher:
		launcher.open_tool_folder(tool_key)

func _on_open_tools_folder_pressed() -> void:
	if launcher:
		launcher.open_tools_folder()

func _prompt_confirm(title: String, message: String, action: Callable) -> void:
	_confirm_action = action
	confirm_dialog.title = title
	confirm_dialog.dialog_text = message
	confirm_dialog.ok_button_text = "Confirm"
	confirm_dialog.cancel_button_text = "Cancel"
	confirm_dialog.popup_centered(Vector2i(450, 180))

func _on_dialog_confirmed() -> void:
	if _confirm_action.is_valid():
		_confirm_action.call()
	_confirm_action = Callable()
