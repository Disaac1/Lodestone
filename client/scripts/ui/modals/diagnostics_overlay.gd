class_name DiagnosticsOverlay
extends Control

## DiagnosticsOverlay
## In-app real-time developer visualizer & diagnostic dashboard for Wayfinder / Lodestone.
## Triggerable globally via F12. Inspects games, tools, mod loaders, configs on BOTH
## Live Real Disk and Isolated Test Sandbox.

const DiagnosticsStateAuditor = preload("res://scripts/core/diagnostics_state_auditor.gd")
const MockGameScaffolder = preload("res://scripts/core/mock_game_scaffolder.gd")
const InstallTestRunner = preload("res://scripts/core/install_test_runner.gd")
const UITheme = preload("res://scripts/ui/ui_theme.gd")

const SANDBOX_DIR: String = "user://e2e_sandbox"

var launcher = null
var auditor: DiagnosticsStateAuditor = null
var current_audit: Dictionary = {}
var selected_item_name: String = ""
var selected_item_type: String = "game" # "game" or "tool"
var live_downloads: bool = false
var view_mode: String = "live" # "live" or "sandbox"

# UI References
var dimmer: ColorRect
var main_panel: PanelContainer
var filter_input: LineEdit
var summary_label: Label
var items_list_container: VBoxContainer
var target_title: Label
var target_meta_label: RichTextLabel
var mod_status_label: Label
var tools_needed_container: VBoxContainer
var config_status_label: Label
var scaffold_btn: Button
var run_test_btn: Button
var purge_btn: Button
var mode_toggle_btn: Button
var env_mode_btn: Button
var open_folder_btn: Button
var diff_text_label: RichTextLabel
var log_text_label: RichTextLabel
var active_tab: int = 0
var tab_buttons: Array[Button] = []

func _init(p_launcher = null) -> void:
	launcher = p_launcher
	z_index = 200
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false

func _ready() -> void:
	anchors_preset = Control.PRESET_FULL_RECT
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()
	_init_auditor()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F12:
			toggle()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_ESCAPE and visible:
			close()
			get_viewport().set_input_as_handled()

func set_launcher(p_launcher) -> void:
	launcher = p_launcher
	_init_auditor()

func _init_auditor() -> void:
	auditor = DiagnosticsStateAuditor.new(launcher)

func toggle() -> void:
	if visible:
		close()
	else:
		open()

func open() -> void:
	visible = true
	if current_audit.is_empty():
		run_batch_audit()
	else:
		_refresh_items_list()
		if selected_item_name != "":
			_display_selected_target()
		_refresh_diff_view()

func close() -> void:
	visible = false

func toggle_environment_mode() -> void:
	if view_mode == "live":
		view_mode = "sandbox"
	else:
		view_mode = "live"
	_update_env_mode_ui()
	run_batch_audit()

func _update_env_mode_ui() -> void:
	if is_instance_valid(env_mode_btn):
		if view_mode == "live":
			env_mode_btn.text = "🌐 View: LIVE DISK"
			env_mode_btn.tooltip_text = "Currently inspecting live filesystem and real user directories. Click to switch to sandbox."
		else:
			env_mode_btn.text = "📦 View: SANDBOX"
			env_mode_btn.tooltip_text = "Currently inspecting isolated test sandbox (user://e2e_sandbox). Click to switch to live disk."

	if is_instance_valid(open_folder_btn):
		open_folder_btn.text = "📁 Open Live Folder" if view_mode == "live" else "📁 Open Sandbox Folder"

	if is_instance_valid(scaffold_btn):
		scaffold_btn.text = "🛠️ Scaffold Mock in Sandbox"

	if is_instance_valid(purge_btn):
		purge_btn.visible = (view_mode == "sandbox")

func run_batch_audit() -> void:
	if not auditor:
		_init_auditor()
	var env_label: String = "LIVE DISK" if view_mode == "live" else "SANDBOX"
	_append_log("INFO", "Running batch audit of " + env_label + " for all games and tools...")

	var audit_prefix: String = "" if view_mode == "live" else SANDBOX_DIR
	current_audit = auditor.run_full_audit(audit_prefix)

	_update_summary_header()
	_refresh_items_list()

	if selected_item_name == "" and not current_audit.get("games", {}).is_empty():
		var first_game: String = current_audit["games"].keys()[0]
		select_target(first_game, "game")
	elif selected_item_name != "":
		_display_selected_target()

	_refresh_diff_view()
	_append_log("INFO", "Batch audit complete (" + env_label + "). Games: " + str(current_audit.get("games", {}).size()) + ", Tools: " + str(current_audit.get("tools", {}).size()))

func select_target(target_name: String, target_type: String) -> void:
	selected_item_name = target_name
	selected_item_type = target_type
	_display_selected_target()
	_refresh_diff_view()

func scaffold_selected_mock() -> void:
	if selected_item_name == "":
		return
	_append_log("INFO", "Scaffolding mock sandbox files for: " + selected_item_name)
	if selected_item_type == "game":
		var preset: Dictionary = current_audit.get("games", {}).get(selected_item_name, {})
		var slug: String = str(preset.get("slug", selected_item_name.to_lower()))
		var res: Dictionary = MockGameScaffolder.scaffold_mock_game(slug, preset, SANDBOX_DIR)
		_append_log("INFO", "Scaffolded " + str(res.get("created_files", []).size()) + " files for " + selected_item_name)
	else:
		var tool_data: Dictionary = current_audit.get("tools", {}).get(selected_item_name, {})
		var res: Dictionary = MockGameScaffolder.scaffold_mock_tool(selected_item_name, tool_data, SANDBOX_DIR)
		_append_log("INFO", "Scaffolded mock tool: " + selected_item_name)

	# If currently viewing live disk, auto switch to sandbox mode so user can see what was created!
	if view_mode == "live":
		view_mode = "sandbox"
		_update_env_mode_ui()

	current_audit = auditor.run_full_audit(SANDBOX_DIR)
	_display_selected_target()
	_refresh_diff_view()

func run_e2e_install_test() -> void:
	if selected_item_name == "":
		return

	run_test_btn.disabled = true
	_append_log("INFO", ">>> Initiating E2E Install Test for [" + selected_item_name + "] (Live: " + str(live_downloads) + ") <<<")
	_switch_tab(1) # Switch to Live Log tab

	var runner := InstallTestRunner.new(launcher, live_downloads)
	runner.log_event.connect(func(level: String, msg: String):
		_append_log(level, msg)
	)
	runner.step_completed.connect(func(step_name: String, ok: bool, details: String):
		var icon: String = "✅" if ok else "❌"
		_append_log("INFO" if ok else "ERROR", icon + " Step [" + step_name + "]: " + details)
	)

	var report: Dictionary = {}
	if selected_item_type == "game":
		var preset: Dictionary = current_audit.get("games", {}).get(selected_item_name, {})
		report = runner.test_game_install_pipeline(selected_item_name, preset, SANDBOX_DIR)
	else:
		var tool_data: Dictionary = current_audit.get("tools", {}).get(selected_item_name, {})
		report = runner.test_tool_install_pipeline(selected_item_name, tool_data, SANDBOX_DIR)

	run_test_btn.disabled = false

	# After test completes, switch to sandbox view mode to inspect the resulting tree diff
	view_mode = "sandbox"
	_update_env_mode_ui()
	current_audit = auditor.run_full_audit(SANDBOX_DIR)
	_display_selected_target()
	_update_diff_view_from_report(report.get("diff", {}))

	var status: String = report.get("status", "UNKNOWN")
	if status == "PASSED":
		_append_log("INFO", "🎉 E2E Install Test PASSED 100% in " + str(report.get("duration_ms", 0)) + "ms")
	else:
		_append_log("ERROR", "❌ E2E Install Test FAILED! Check missing files or error steps above.")

func purge_sandbox() -> void:
	_append_log("WARN", "Purging sandbox directory: " + SANDBOX_DIR)
	MockGameScaffolder.purge_sandbox(SANDBOX_DIR)
	current_audit = auditor.run_full_audit(SANDBOX_DIR)
	_display_selected_target()
	_refresh_diff_view()
	_append_log("INFO", "Sandbox purged cleanly.")

func open_current_environment_folder() -> void:
	var path_to_open: String = ""
	if view_mode == "live":
		# If a game or tool is selected and resolved, open its parent folder
		var target_dict = current_audit.get("games" if selected_item_type == "game" else "tools", {}).get(selected_item_name, {})
		var r_path = str(target_dict.get("resolved_path", "")).strip_edges()
		if r_path != "" and not target_dict.get("is_mock", false):
			path_to_open = ProjectSettings.globalize_path(r_path.get_base_dir())
		else:
			path_to_open = ProjectSettings.globalize_path("user://")
	else:
		path_to_open = ProjectSettings.globalize_path(SANDBOX_DIR)

	DirAccess.make_dir_recursive_absolute(path_to_open)
	_append_log("INFO", "Opening folder in Windows Explorer: " + path_to_open)
	OS.shell_open(path_to_open)

# =========================================================================
# UI BUILDING & RENDERING
# =========================================================================

func _build_ui() -> void:
	# 1. Background Dimmer
	dimmer = ColorRect.new()
	dimmer.anchors_preset = Control.PRESET_FULL_RECT
	dimmer.color = Color(0.04, 0.05, 0.08, 0.88)
	dimmer.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dimmer)

	# 2. Main Window Panel
	main_panel = PanelContainer.new()
	main_panel.anchors_preset = Control.PRESET_FULL_RECT
	main_panel.anchor_left = 0.02
	main_panel.anchor_top = 0.02
	main_panel.anchor_right = 0.98
	main_panel.anchor_bottom = 0.98

	var style_panel = StyleBoxFlat.new()
	style_panel.bg_color = Color(0.1, 0.12, 0.17, 0.98)
	style_panel.border_width_left = 2
	style_panel.border_width_top = 2
	style_panel.border_width_right = 2
	style_panel.border_width_bottom = 2
	style_panel.border_color = Color(0.2, 0.7, 1.0, 0.6)
	style_panel.corner_radius_top_left = 10
	style_panel.corner_radius_top_right = 10
	style_panel.corner_radius_bottom_right = 10
	style_panel.corner_radius_bottom_left = 10
	main_panel.add_theme_stylebox_override("panel", style_panel)
	add_child(main_panel)

	var outer_margin = MarginContainer.new()
	outer_margin.add_theme_constant_override("margin_left", 16)
	outer_margin.add_theme_constant_override("margin_top", 12)
	outer_margin.add_theme_constant_override("margin_right", 16)
	outer_margin.add_theme_constant_override("margin_bottom", 12)
	main_panel.add_child(outer_margin)

	var root_vbox = VBoxContainer.new()
	root_vbox.add_theme_constant_override("separation", 10)
	outer_margin.add_child(root_vbox)

	# --- TOP HEADER BAR ---
	var header_hbox = HBoxContainer.new()
	header_hbox.add_theme_constant_override("separation", 10)
	root_vbox.add_child(header_hbox)

	var title_vbox = VBoxContainer.new()
	var main_title = Label.new()
	main_title.text = "🧪 1-CLICK INSTALL & STATE VISUALIZER"
	main_title.add_theme_font_size_override("font_size", 18)
	main_title.add_theme_color_override("font_color", Color(0.3, 0.85, 1.0))
	title_vbox.add_child(main_title)

	var sub_title = Label.new()
	sub_title.text = "F12 Diagnostic Overlay | Real-Time Internal State, Live Disk & Mock Sandbox Inspection"
	sub_title.add_theme_font_size_override("font_size", 11)
	sub_title.add_theme_color_override("font_color", Color(0.6, 0.7, 0.8))
	title_vbox.add_child(sub_title)
	header_hbox.add_child(title_vbox)

	header_hbox.add_spacer(false)

	# Environment View Mode Toggle Button
	env_mode_btn = Button.new()
	env_mode_btn.text = "🌐 View: LIVE DISK"
	env_mode_btn.pressed.connect(toggle_environment_mode)
	header_hbox.add_child(env_mode_btn)

	# Batch Audit Button
	var audit_btn = Button.new()
	audit_btn.text = "🔄 Batch Audit"
	audit_btn.pressed.connect(run_batch_audit)
	header_hbox.add_child(audit_btn)

	mode_toggle_btn = Button.new()
	mode_toggle_btn.text = "⚡ Test: Fast Mock"
	mode_toggle_btn.pressed.connect(func():
		live_downloads = not live_downloads
		mode_toggle_btn.text = "🌐 Test: Live DL" if live_downloads else "⚡ Test: Fast Mock"
		_append_log("INFO", "Switched download test mode to: " + ("LIVE" if live_downloads else "FAST MOCK"))
	)
	header_hbox.add_child(mode_toggle_btn)

	open_folder_btn = Button.new()
	open_folder_btn.text = "📁 Open Live Folder"
	open_folder_btn.pressed.connect(open_current_environment_folder)
	header_hbox.add_child(open_folder_btn)

	var close_btn = Button.new()
	close_btn.text = " ✕ "
	close_btn.pressed.connect(close)
	header_hbox.add_child(close_btn)

	# --- SUMMARY BADGE BAR ---
	summary_label = Label.new()
	summary_label.text = "Auditing runtime system state..."
	summary_label.add_theme_font_size_override("font_size", 12)
	summary_label.add_theme_color_override("font_color", Color(0.8, 0.85, 0.9))
	root_vbox.add_child(summary_label)

	# --- MAIN SPLIT BODY ---
	var body_split = HSplitContainer.new()
	body_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body_split.split_offset = 320
	root_vbox.add_child(body_split)

	# --- LEFT SIDE: TARGETS LIST ---
	var left_vbox = VBoxContainer.new()
	left_vbox.custom_minimum_size = Vector2(280, 0)
	left_vbox.add_theme_constant_override("separation", 6)
	body_split.add_child(left_vbox)

	filter_input = LineEdit.new()
	filter_input.placeholder_text = "🔍 Filter games or tools..."
	filter_input.text_changed.connect(func(_t): _refresh_items_list())
	left_vbox.add_child(filter_input)

	var list_scroll = ScrollContainer.new()
	list_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_vbox.add_child(list_scroll)

	items_list_container = VBoxContainer.new()
	items_list_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	items_list_container.add_theme_constant_override("separation", 4)
	list_scroll.add_child(items_list_container)

	# --- RIGHT SIDE: DETAILED INSPECTOR & TABS ---
	var right_vbox = VBoxContainer.new()
	right_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_vbox.add_theme_constant_override("separation", 8)
	body_split.add_child(right_vbox)

	# Top Inspector Card
	var inspector_panel = PanelContainer.new()
	var insp_style = StyleBoxFlat.new()
	insp_style.bg_color = Color(0.14, 0.16, 0.22, 0.9)
	insp_style.border_width_left = 1
	insp_style.border_width_top = 1
	insp_style.border_width_right = 1
	insp_style.border_width_bottom = 1
	insp_style.border_color = Color(0.25, 0.3, 0.42, 0.8)
	insp_style.corner_radius_top_left = 6
	insp_style.corner_radius_top_right = 6
	insp_style.corner_radius_bottom_right = 6
	insp_style.corner_radius_bottom_left = 6
	inspector_panel.add_theme_stylebox_override("panel", insp_style)
	right_vbox.add_child(inspector_panel)

	var insp_margin = MarginContainer.new()
	insp_margin.add_theme_constant_override("margin_left", 12)
	insp_margin.add_theme_constant_override("margin_top", 10)
	insp_margin.add_theme_constant_override("margin_right", 12)
	insp_margin.add_theme_constant_override("margin_bottom", 10)
	inspector_panel.add_child(insp_margin)

	var insp_vbox = VBoxContainer.new()
	insp_vbox.add_theme_constant_override("separation", 6)
	insp_margin.add_child(insp_vbox)

	target_title = Label.new()
	target_title.text = "Select a Game or Tool to Inspect"
	target_title.add_theme_font_size_override("font_size", 16)
	target_title.add_theme_color_override("font_color", Color(0.3, 0.85, 1.0))
	insp_vbox.add_child(target_title)

	target_meta_label = RichTextLabel.new()
	target_meta_label.bbcode_enabled = true
	target_meta_label.fit_content = true
	target_meta_label.text = "[color=#8fa0b5]No target selected.[/color]"
	insp_vbox.add_child(target_meta_label)

	mod_status_label = Label.new()
	mod_status_label.text = "Mod Status: -"
	mod_status_label.add_theme_font_size_override("font_size", 12)
	insp_vbox.add_child(mod_status_label)

	tools_needed_container = VBoxContainer.new()
	insp_vbox.add_child(tools_needed_container)

	config_status_label = Label.new()
	config_status_label.text = "Config Status: -"
	config_status_label.add_theme_font_size_override("font_size", 12)
	insp_vbox.add_child(config_status_label)

	# Inspector Action Buttons
	var insp_btn_hbox = HBoxContainer.new()
	insp_btn_hbox.add_theme_constant_override("separation", 8)
	insp_vbox.add_child(insp_btn_hbox)

	scaffold_btn = Button.new()
	scaffold_btn.text = "🛠️ Scaffold Mock in Sandbox"
	scaffold_btn.pressed.connect(scaffold_selected_mock)
	insp_btn_hbox.add_child(scaffold_btn)

	run_test_btn = Button.new()
	run_test_btn.text = "▶ Run 1-Click Install Test"
	run_test_btn.pressed.connect(run_e2e_install_test)
	insp_btn_hbox.add_child(run_test_btn)

	purge_btn = Button.new()
	purge_btn.text = "🗑️ Purge Sandbox"
	purge_btn.pressed.connect(purge_sandbox)
	purge_btn.visible = false
	insp_btn_hbox.add_child(purge_btn)

	# Bottom Tabs (File Browser / Diff vs Logger)
	var tab_bar_hbox = HBoxContainer.new()
	tab_bar_hbox.add_theme_constant_override("separation", 6)
	right_vbox.add_child(tab_bar_hbox)

	var tab1_btn = Button.new()
	tab1_btn.text = "📁 Filesystem & State Tree"
	tab1_btn.pressed.connect(func(): _switch_tab(0))
	tab_bar_hbox.add_child(tab1_btn)
	tab_buttons.append(tab1_btn)

	var tab2_btn = Button.new()
	tab2_btn.text = "📜 Live Stage & Event Log"
	tab2_btn.pressed.connect(func(): _switch_tab(1))
	tab_bar_hbox.add_child(tab2_btn)
	tab_buttons.append(tab2_btn)

	var tabs_panel = PanelContainer.new()
	tabs_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var tab_style = StyleBoxFlat.new()
	tab_style.bg_color = Color(0.08, 0.09, 0.12, 0.95)
	tab_style.border_width_left = 1
	tab_style.border_width_top = 1
	tab_style.border_width_right = 1
	tab_style.border_width_bottom = 1
	tab_style.border_color = Color(0.2, 0.24, 0.32, 0.8)
	tab_style.corner_radius_top_left = 6
	tab_style.corner_radius_top_right = 6
	tab_style.corner_radius_bottom_right = 6
	tab_style.corner_radius_bottom_left = 6
	tabs_panel.add_theme_stylebox_override("panel", tab_style)
	right_vbox.add_child(tabs_panel)

	var tab_margin = MarginContainer.new()
	tab_margin.add_theme_constant_override("margin_left", 8)
	tab_margin.add_theme_constant_override("margin_top", 8)
	tab_margin.add_theme_constant_override("margin_right", 8)
	tab_margin.add_theme_constant_override("margin_bottom", 8)
	tabs_panel.add_child(tab_margin)

	diff_text_label = RichTextLabel.new()
	diff_text_label.bbcode_enabled = true
	diff_text_label.scroll_following = true
	diff_text_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	diff_text_label.text = "[color=#708090]Inspecting runtime state...[/color]"
	tab_margin.add_child(diff_text_label)

	log_text_label = RichTextLabel.new()
	log_text_label.bbcode_enabled = true
	log_text_label.scroll_following = true
	log_text_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_text_label.visible = false
	tab_margin.add_child(log_text_label)

func _switch_tab(index: int) -> void:
	active_tab = index
	diff_text_label.visible = (index == 0)
	log_text_label.visible = (index == 1)

func _update_summary_header() -> void:
	var s: Dictionary = current_audit.get("summary", {})
	var g_ready = s.get("games_ready", 0)
	var g_tot = s.get("total_games", 0)
	var t_ready = s.get("tools_ready", 0)
	var t_tot = s.get("total_tools", 0)

	var env_badge = "[color=#00ffff][LIVE REAL DISK][/color]" if view_mode == "live" else "[color=#ffa500][ISOLATED SANDBOX][/color]"
	var txt = env_badge + "  🎮 Games: " + str(g_ready) + "/" + str(g_tot) + " Ready | "
	txt += "🔧 Tools: " + str(t_ready) + "/" + str(t_tot) + " Ready | "
	txt += "🕒 Audited: " + str(s.get("timestamp", "-"))
	summary_label.text = txt

func _refresh_items_list() -> void:
	for child in items_list_container.get_children():
		child.queue_free()

	var filter_text = filter_input.text.to_lower().strip_edges()

	# Section 1: Games
	var games_header = Label.new()
	games_header.text = "— GAMES —"
	games_header.add_theme_font_size_override("font_size", 10)
	games_header.add_theme_color_override("font_color", Color(0.5, 0.6, 0.7))
	items_list_container.add_child(games_header)

	var games: Dictionary = current_audit.get("games", {})
	for g_name in games.keys():
		if filter_text != "" and not g_name.to_lower().contains(filter_text):
			continue
		var g_info: Dictionary = games[g_name]
		_add_list_item_button(g_name, "game", g_info.get("overall_status", "MISSING"))

	# Section 2: Shared Tools
	var tools_header = Label.new()
	tools_header.text = "— TOOLS & EMULATORS —"
	tools_header.add_theme_font_size_override("font_size", 10)
	tools_header.add_theme_color_override("font_color", Color(0.5, 0.6, 0.7))
	items_list_container.add_child(tools_header)

	var tools: Dictionary = current_audit.get("tools", {})
	for t_name in tools.keys():
		if filter_text != "" and not t_name.to_lower().contains(filter_text):
			continue
		var t_info: Dictionary = tools[t_name]
		_add_list_item_button(t_name, "tool", t_info.get("overall_status", "MISSING"))

func _add_list_item_button(item_name: String, item_type: String, status: String) -> void:
	var btn = Button.new()
	var icon: String = "🟢"
	if status == "MOCK_READY": icon = "🔵"
	elif status == "DEGRADED" or status == "MOCK_DEGRADED": icon = "🟡"
	elif status == "PREREQS_MISSING" or status == "FIRMWARE_MISSING": icon = "🟠"
	elif status == "MISSING": icon = "🔴"

	btn.text = icon + " " + item_name
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.pressed.connect(func(): select_target(item_name, item_type))
	items_list_container.add_child(btn)

func _display_selected_target() -> void:
	if selected_item_name == "":
		return

	if selected_item_type == "game":
		var g_info: Dictionary = current_audit.get("games", {}).get(selected_item_name, {})
		target_title.text = "🎮 " + selected_item_name + " (" + str(g_info.get("slug", "-")) + ")"

		var meta = "[b]Launch Mode:[/b] " + str(g_info.get("launch_mode", "direct")) + "\n"
		var target_file = g_info.get("target_exe", g_info.get("required_rom", "-"))
		meta += "[b]Target File:[/b] " + str(target_file) + "\n"
		var r_path = str(g_info.get("resolved_path", "")).strip_edges()
		if r_path != "":
			var mock_tag = " [color=#20b2aa](Sandbox Mock)[/color]" if g_info.get("is_mock", false) else " [color=#32cd32](Live Disk Detected)[/color]"
			meta += "[b]Resolved Path:[/b] " + r_path + mock_tag
		else:
			meta += "[b]Resolved Path:[/b] [color=#ff6347]NOT DETECTED ON SYSTEM[/color]"
		target_meta_label.text = meta

		var mod_info: Dictionary = g_info.get("mod_status", {})
		mod_status_label.text = "Modding: " + str(mod_info.get("label", "N/A"))
		mod_status_label.add_theme_color_override("font_color", Color(0.2, 0.85, 0.5) if mod_info.get("ready", true) else Color(0.9, 0.6, 0.2))

		# Tools needed
		for c in tools_needed_container.get_children(): c.queue_free()
		var tools_needed: Array = g_info.get("tools_needed", [])
		if not tools_needed.is_empty():
			var t_label = Label.new()
			t_label.text = "Required Tools:"
			t_label.add_theme_font_size_override("font_size", 12)
			tools_needed_container.add_child(t_label)
			for tn in tools_needed:
				var t_row = Label.new()
				var t_ready: bool = tn.get("ready", false)
				t_row.text = ("  • " + ("✅ " if t_ready else "❌ ") + str(tn.get("name", "")) + ": " + str(tn.get("status", "")))
				t_row.add_theme_font_size_override("font_size", 11)
				tools_needed_container.add_child(t_row)

		var cfg_info: Dictionary = g_info.get("config_status", {})
		var synced: bool = cfg_info.get("synced", false)
		var yaml_status: String = "✅ host.yaml Synced" if synced else "⚠️ host.yaml Not Synced / Missing"
		config_status_label.text = yaml_status + " (" + str(cfg_info.get("host_yaml_path", "")) + ")"

	else:
		var t_info: Dictionary = current_audit.get("tools", {}).get(selected_item_name, {})
		target_title.text = "🔧 " + selected_item_name
		var meta = "[b]Executable:[/b] " + str(t_info.get("executable", "-")) + "\n"
		var r_path = str(t_info.get("resolved_path", "")).strip_edges()
		if r_path != "":
			meta += "[b]Installed At:[/b] " + r_path + " [color=#32cd32](Live Disk Installed)[/color]"
		else:
			meta += "[b]Installed At:[/b] [color=#ff6347]NOT INSTALLED IN TOOLS FOLDER[/color]"
		target_meta_label.text = meta

		mod_status_label.text = "Prerequisites Met: " + ("✅ Yes" if t_info.get("prereqs_all_met", true) else "❌ Missing DLLs")
		for c in tools_needed_container.get_children(): c.queue_free()

		var fw_list: Array = t_info.get("firmware", [])
		if not fw_list.is_empty():
			var fw_lbl = Label.new()
			fw_lbl.text = "Firmware Status:"
			fw_lbl.add_theme_font_size_override("font_size", 12)
			tools_needed_container.add_child(fw_lbl)
			for fw in fw_list:
				var f_row = Label.new()
				var p = fw.get("present", false)
				f_row.text = ("  • " + ("✅ " if p else "❌ ") + str(fw.get("name", "")) + ": " + ("Present" if p else "Missing"))
				f_row.add_theme_font_size_override("font_size", 11)
				tools_needed_container.add_child(f_row)

		config_status_label.text = "Status: " + str(t_info.get("overall_status", "-"))

func _refresh_diff_view() -> void:
	if view_mode == "live":
		_render_live_filesystem_tree()
	else:
		_render_sandbox_tree()

func _render_live_filesystem_tree() -> void:
	var bb = "[b][color=#00ffff]🌐 LIVE FILESYSTEM STATUS (Real Disk & User Directory):[/color][/b]\n"
	bb += "[color=#708090]User Base: " + ProjectSettings.globalize_path("user://") + "[/color]\n\n"

	# 1. user://tools inspection
	var live_tools = MockGameScaffolder.get_sandbox_file_tree("user://tools")
	bb += "🔧 [b]Installed Tools Directory (user://tools - " + str(live_tools.size()) + " files):[/b]\n"
	if live_tools.is_empty():
		bb += "   [color=#808080](Empty - no tools installed in user://tools yet)[/color]\n"
	else:
		for f in live_tools:
			bb += "   📁 [color=#98fb98]tools/" + f + "[/color]\n"
	bb += "\n"

	# 2. user://games inspection
	var live_games = MockGameScaffolder.get_sandbox_file_tree("user://games")
	bb += "🎮 [b]Installed Games Directory (user://games - " + str(live_games.size()) + " files):[/b]\n"
	if live_games.is_empty():
		bb += "   [color=#808080](Empty - games may be located in Steam or custom install paths)[/color]\n"
	else:
		for f in live_games:
			bb += "   📁 [color=#87ceeb]games/" + f + "[/color]\n"
	bb += "\n"

	# 3. Selected target specific inspection
	if selected_item_name != "":
		var target_dict = current_audit.get("games" if selected_item_type == "game" else "tools", {}).get(selected_item_name, {})
		var r_path = str(target_dict.get("resolved_path", "")).strip_edges()
		if r_path != "" and not target_dict.get("is_mock", false):
			bb += "🔍 [b]Inspecting Live Selected Directory (" + r_path.get_base_dir() + "):[/b]\n"
			bb += "   [color=#32cd32]✔ Executable / Asset Verified:[/color] " + r_path.get_file() + "\n"
			var game_dir = r_path.get_base_dir()
			var local_tree = MockGameScaffolder.get_sandbox_file_tree(game_dir)
			bb += "   Found " + str(local_tree.size()) + " total files in game directory.\n"
		else:
			bb += "🔍 [b]Selected Target Live Status:[/b] [color=#ff6347]Not present on live filesystem.[/color]\n"

	diff_text_label.text = bb

func _render_sandbox_tree() -> void:
	var actual: Array[String] = MockGameScaffolder.get_sandbox_file_tree(SANDBOX_DIR)
	var bb = "[b][color=#ffa500]📦 TEST SANDBOX TREE (" + str(actual.size()) + " files):[/color][/b]\n"
	bb += "[color=#607d8b]" + ProjectSettings.globalize_path(SANDBOX_DIR) + "[/color]\n\n"
	if actual.is_empty():
		bb += "[color=#808080]Sandbox is empty. Click 'Scaffold Mock' or 'Run 1-Click Install Test'.[/color]"
	else:
		for f in actual:
			bb += "  📁 [color=#98fb98]" + f + "[/color]\n"
	diff_text_label.text = bb

func _update_diff_view_from_report(diff: Dictionary) -> void:
	var matched: Array = diff.get("matched", [])
	var missing: Array = diff.get("missing", [])
	var unexpected: Array = diff.get("unexpected", [])

	var bb = "[b]Expected vs Actual File Tree Diff (Sandbox):[/b]\n"
	bb += "[color=#607d8b]Sandbox: " + ProjectSettings.globalize_path(SANDBOX_DIR) + "[/color]\n\n"

	if matched.is_empty() and missing.is_empty() and unexpected.is_empty():
		bb += "[color=#808080]No diff entries.[/color]"
	else:
		for m in matched:
			bb += "  [color=#32cd32]✔ MATCHED:[/color] " + str(m) + "\n"
		for mis in missing:
			bb += "  [color=#ff4500]✘ MISSING (Expected):[/color] " + str(mis) + "\n"
		for un in unexpected:
			bb += "  [color=#87cefa]ℹ EXTRA/UNEXPECTED:[/color] " + str(un) + "\n"

	diff_text_label.text = bb

func _append_log(level: String, message: String) -> void:
	var col: String = "#ffffff"
	if level == "INFO": col = "#87ceeb"
	elif level == "WARN": col = "#ffd700"
	elif level == "ERROR": col = "#ff6347"

	var time_str: String = Time.get_time_string_from_system()
	var line: String = "[color=#808080][" + time_str + "][/color] [color=" + col + "][" + level + "][/color] " + message + "\n"
	log_text_label.append_text(line)
