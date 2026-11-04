class_name RomCatalogModal
extends Control

signal closed()
signal catalog_updated(info: Dictionary)
signal game_status_changed(game_name: String, new_status: Dictionary)

const RomCatalogManager = preload("res://scripts/core/rom_catalog_manager.gd")
const UITheme = preload("res://scripts/ui/ui_theme.gd")

# --- UI NODES ---
@onready var close_btn: Button = %CloseBtn
@onready var done_btn: Button = %DoneBtn
@onready var refresh_btn: Button = %RefreshBtn
@onready var open_folder_btn: Button = %OpenFolderBtn
@onready var toggle_sync_btn: Button = %ToggleSyncBtn

# Sync drawer nodes (rom.json URL / import)
@onready var sync_drawer: VBoxContainer = %SyncDrawer
@onready var url_input: LineEdit = %UrlInput
@onready var download_btn: Button = %DownloadBtn
@onready var load_local_btn: Button = %LoadLocalBtn
@onready var feedback_label: Label = %FeedbackLabel

# Badges
@onready var total_size_badge: Label = %TotalSizeBadge
@onready var installed_count_badge: Label = %InstalledCountBadge
@onready var configured_badge: Label = %ConfiguredBadge

# Filter & Search
@onready var search_input: LineEdit = %SearchInput
@onready var filter_all_btn: Button = %FilterAllBtn
@onready var filter_installed_btn: Button = %FilterInstalledBtn
@onready var filter_not_installed_btn: Button = %FilterNotInstalledBtn
@onready var filter_downloadable_btn: Button = %FilterDownloadableBtn

# Entries list
@onready var entries_container: VBoxContainer = %EntriesContainer
@onready var empty_label: Label = %EmptyLabel
@onready var path_info_label: Label = %PathInfoLabel

# Dialogs
@onready var local_file_dialog: FileDialog = %LocalFileDialog
@onready var game_file_dialog: FileDialog = %GameFileDialog
@onready var confirm_dialog: ConfirmationDialog = %ConfirmDialog
@onready var set_url_dialog: ConfirmationDialog = %SetUrlDialog
@onready var set_url_input: LineEdit = %SetUrlInput
@onready var set_url_label: Label = %SetUrlLabel

var launcher = null
var _all_games: Array[Dictionary] = []
var _active_filter: String = "all" # "all", "installed", "not_installed", "downloadable"
var _locating_game_name: String = ""
var _setting_url_game_name: String = ""
var _confirm_action: Callable = Callable()
var _downloading_games: Dictionary = {}

func _ready() -> void:
	visible = false
	close_btn.pressed.connect(close)
	done_btn.pressed.connect(close)
	refresh_btn.pressed.connect(refresh)
	open_folder_btn.pressed.connect(_on_open_folder_pressed)
	toggle_sync_btn.pressed.connect(_toggle_sync_drawer)

	download_btn.pressed.connect(_on_download_pressed)
	load_local_btn.pressed.connect(func(): local_file_dialog.popup_centered(Vector2i(650, 450)))
	local_file_dialog.file_selected.connect(_on_local_file_selected)

	search_input.text_changed.connect(func(_t): _render_games())
	filter_all_btn.pressed.connect(func(): _set_filter("all"))
	filter_installed_btn.pressed.connect(func(): _set_filter("installed"))
	filter_not_installed_btn.pressed.connect(func(): _set_filter("not_installed"))
	filter_downloadable_btn.pressed.connect(func(): _set_filter("downloadable"))

	game_file_dialog.file_selected.connect(_on_game_file_selected)
	confirm_dialog.confirmed.connect(_on_dialog_confirmed)
	set_url_dialog.confirmed.connect(_on_set_url_confirmed)

	_update_filter_buttons()

func open(p_arg = null) -> void:
	if p_arg is String and p_arg.strip_edges() != "":
		url_input.text = p_arg.strip_edges()
	elif p_arg != null and not p_arg is String:
		launcher = p_arg

	if not launcher and Engine.get_main_loop():
		var root = Engine.get_main_loop().root
		var lobby = root.get_node_or_null("Lobby")
		if lobby and "launcher" in lobby and lobby.launcher:
			launcher = lobby.launcher

	visible = true
	feedback_label.text = ""

	if url_input.text.strip_edges() == "":
		url_input.text = RomCatalogManager.get_default_catalog_url()

	if launcher and launcher.has_signal("download_progress_updated"):
		if not launcher.download_progress_updated.is_connected(_on_download_progress_updated):
			launcher.download_progress_updated.connect(_on_download_progress_updated)

	var games_dir_path: String = ProjectSettings.globalize_path("user://games")
	path_info_label.text = "Games directory: " + games_dir_path

	refresh()

func close() -> void:
	visible = false
	if launcher and launcher.has_signal("download_progress_updated"):
		if launcher.download_progress_updated.is_connected(_on_download_progress_updated):
			launcher.download_progress_updated.disconnect(_on_download_progress_updated)
	closed.emit()

func _toggle_sync_drawer() -> void:
	sync_drawer.visible = not sync_drawer.visible
	toggle_sync_btn.text = "▲ Hide Sync" if sync_drawer.visible else "⚙️ Sync rom.json"

func refresh() -> void:
	if not launcher:
		_refresh_legacy_catalog_only()
		return

	var overview: Dictionary = launcher.get_all_games_status()
	var games_arr: Array = overview.get("games", [])
	_all_games.clear()
	for g in games_arr:
		if g is Dictionary:
			_all_games.append(g)

	var total_size_str: String = str(overview.get("formatted_total_size", "0 B"))
	var installed_cnt: int = int(overview.get("installed_count", 0))
	var total_cnt: int = int(overview.get("total_count", _all_games.size()))

	var cat_info: Dictionary = RomCatalogManager.get_catalog_info()
	var configured_cnt: int = int(cat_info.get("configured_count", 0))

	total_size_badge.text = "💾 Space: " + total_size_str
	installed_count_badge.text = "🎮 " + str(installed_cnt) + "/" + str(total_cnt) + " Installed"
	configured_badge.text = "🌐 " + str(configured_cnt) + " in rom.json"

	_render_games()

func _refresh_legacy_catalog_only() -> void:
	var info: Dictionary = RomCatalogManager.get_catalog_info()
	var entries: Dictionary = info.get("entries", {})
	_all_games.clear()
	for k in entries.keys():
		var val = entries[k]
		var url_str: String = ""
		if val is String:
			url_str = val.strip_edges()
		elif val is Dictionary:
			url_str = str(val.get("url", "")).strip_edges()
		_all_games.append({
			"game_name": str(k),
			"required_rom": str(k),
			"installed": false,
			"has_download_url": url_str != "",
			"download_url": url_str,
			"size_bytes": 0,
			"formatted_size": "0 B",
			"status_code": "AVAILABLE" if url_str != "" else "NOT_INSTALLED"
		})
	_render_games()

func _set_filter(filter_name: String) -> void:
	_active_filter = filter_name
	_update_filter_buttons()
	_render_games()

func _update_filter_buttons() -> void:
	filter_all_btn.flat = (_active_filter != "all")
	filter_installed_btn.flat = (_active_filter != "installed")
	filter_not_installed_btn.flat = (_active_filter != "not_installed")
	filter_downloadable_btn.flat = (_active_filter != "downloadable")

func _get_game_icon(game_name: String) -> String:
	var l_name: String = game_name.to_lower()
	if l_name.contains("pokemon"):
		return "⚡"
	elif l_name.contains("luigi"):
		return "👻"
	elif l_name.contains("mario"):
		return "🍄"
	elif l_name.contains("metroid"):
		return "🚀"
	elif l_name.contains("zelda") or l_name.contains("past") or l_name.contains("ocarina"):
		return "🗡️"
	elif l_name.contains("hollow") or l_name.contains("knight"):
		return "🕷️"
	elif l_name.contains("spire"):
		return "🃏"
	elif l_name.contains("isaac"):
		return "😭"
	elif l_name.contains("zombie") or l_name.contains("plant"):
		return "🌻"
	elif l_name.contains("symphony") or l_name.contains("castlevania"):
		return "🦇"
	elif l_name.contains("stardew"):
		return "🌾"
	elif l_name.contains("factorio"):
		return "🏭"
	return "🎮"

func _render_games() -> void:
	for child in entries_container.get_children():
		child.queue_free()

	var query: String = search_input.text.strip_edges().to_lower()
	var visible_count: int = 0

	for game in _all_games:
		var name: String = str(game.get("game_name", ""))
		var rom: String = str(game.get("required_rom", ""))
		var installed: bool = bool(game.get("installed", false))
		var has_dl: bool = bool(game.get("has_download_url", false))
		var status_code: String = str(game.get("status_code", "NOT_INSTALLED"))

		if query != "":
			var matches: bool = name.to_lower().contains(query) or rom.to_lower().contains(query)
			if not matches:
				continue

		if _active_filter == "installed" and not installed:
			continue
		elif _active_filter == "not_installed" and installed:
			continue
		elif _active_filter == "downloadable" and not has_dl:
			continue

		visible_count += 1
		var card: PanelContainer = _build_game_card(game)
		entries_container.add_child(card)

	empty_label.visible = (visible_count == 0)

func _build_game_card(game: Dictionary) -> PanelContainer:
	var name: String = str(game.get("game_name", ""))
	var rom: String = str(game.get("required_rom", ""))
	var target_exe: String = str(game.get("target_exe", ""))
	var installed: bool = bool(game.get("installed", false))
	var is_managed: bool = bool(game.get("is_managed", false))
	var has_dl: bool = bool(game.get("has_download_url", false))
	var dl_url: String = str(game.get("download_url", ""))
	var status_code: String = str(game.get("status_code", "NOT_INSTALLED"))
	var size_str: String = str(game.get("formatted_size", "0 B"))
	var path: String = str(game.get("path", ""))
	var managed_dir: String = str(game.get("managed_dir", ""))
	var is_downloading: bool = _downloading_games.has(name) or _downloading_games.has(rom)
	var expected_hash: String = str(game.get("expected_hash", ""))
	var actual_hash: String = str(game.get("actual_hash", ""))

	var panel: PanelContainer = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.14, 0.19, 1.0)
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	if status_code == "HASH_MISMATCH":
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
	icon_label.text = _get_game_icon(name)
	icon_label.add_theme_font_size_override("font_size", 20)
	header_hbox.add_child(icon_label)

	var name_label: Label = Label.new()
	name_label.text = name
	name_label.add_theme_font_size_override("font_size", 15)
	name_label.add_theme_color_override("font_color", Color(0.92, 0.95, 1.0))
	header_hbox.add_child(name_label)

	var file_display_name: String = rom if rom != "" else target_exe
	if file_display_name != "":
		var rom_label: Label = Label.new()
		rom_label.text = "(" + file_display_name + ")"
		rom_label.add_theme_font_size_override("font_size", 12)
		rom_label.add_theme_color_override("font_color", Color(0.55, 0.6, 0.7))
		rom_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		rom_label.clip_text = true
		header_hbox.add_child(rom_label)

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

	if is_downloading:
		badge.text = "⏳ Downloading..."
		badge_sb.bg_color = Color(0.2, 0.5, 0.8, 0.3)
		badge.add_theme_color_override("font_color", Color(0.4, 0.8, 1.0))
	elif status_code == "INSTALLED":
		badge.text = "● Installed (" + size_str + ")"
		badge_sb.bg_color = Color(0.1, 0.4, 0.2, 0.3)
		badge.add_theme_color_override("font_color", Color(0.3, 0.9, 0.5))
	elif status_code == "EXTERNAL":
		badge.text = "🔗 External (" + size_str + ")"
		badge_sb.bg_color = Color(0.1, 0.3, 0.5, 0.3)
		badge.add_theme_color_override("font_color", Color(0.4, 0.75, 1.0))
	elif status_code == "HASH_MISMATCH":
		badge.text = "⚠️ Hash Mismatch (Corrupt)"
		badge_sb.bg_color = Color(0.5, 0.15, 0.15, 0.3)
		badge.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
	elif has_dl:
		badge.text = "○ Auto-Download Available"
		badge_sb.bg_color = Color(0.15, 0.35, 0.4, 0.3)
		badge.add_theme_color_override("font_color", Color(0.3, 0.85, 1.0))
	else:
		badge.text = "○ No Download Link"
		badge_sb.bg_color = Color(0.2, 0.2, 0.25, 0.3)
		badge.add_theme_color_override("font_color", Color(0.6, 0.65, 0.7))

	badge.add_theme_stylebox_override("normal", badge_sb)
	header_hbox.add_child(badge)

	# --- Middle Row: Details / Hashes / Links ---
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

	if status_code == "HASH_MISMATCH":
		var hash_warn := Label.new()
		hash_warn.text = "• Hash Mismatch: Expected " + expected_hash + " (Current file: " + actual_hash + "). Redownload to fix."
		hash_warn.add_theme_font_size_override("font_size", 11)
		hash_warn.add_theme_color_override("font_color", Color(0.95, 0.4, 0.4))
		hash_warn.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		hash_warn.clip_text = true
		hash_warn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_child(hash_warn)

	# Source URL label
	if has_dl:
		var url_lbl := Label.new()
		url_lbl.text = "🔗 " + dl_url
		url_lbl.tooltip_text = dl_url
		url_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		url_lbl.clip_text = true
		url_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		url_lbl.add_theme_font_size_override("font_size", 11)
		url_lbl.add_theme_color_override("font_color", Color(0.35, 0.75, 0.55))
		vbox.add_child(url_lbl)

	# --- Live Progress Row (during download) ---
	if is_downloading:
		var prog_key: String = name if _downloading_games.has(name) else rom
		var prog_info: Dictionary = _downloading_games.get(prog_key, {})
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
		prog_msg.text = str(prog_info.get("message", "Downloading game files..."))
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

	if not is_downloading:
		if not installed:
			if has_dl:
				var dl_btn: Button = Button.new()
				dl_btn.text = "⬇ Download Automatically"
				dl_btn.custom_minimum_size = Vector2(170, 28)
				dl_btn.add_theme_color_override("font_color", Color(0.3, 0.85, 1.0))
				dl_btn.pressed.connect(func(): _on_download_game_clicked(name))
				actions_hbox.add_child(dl_btn)

			var locate_btn: Button = Button.new()
			locate_btn.text = "🔗 Locate File..."
			locate_btn.custom_minimum_size = Vector2(110, 28)
			locate_btn.pressed.connect(func(): _on_locate_game_clicked(name))
			actions_hbox.add_child(locate_btn)

			var set_url_btn: Button = Button.new()
			set_url_btn.text = "🌐 Set URL" if not has_dl else "🌐 Edit URL"
			set_url_btn.custom_minimum_size = Vector2(85, 28)
			set_url_btn.pressed.connect(func(): _on_set_url_clicked(name, dl_url))
			actions_hbox.add_child(set_url_btn)

		if installed:
			if has_dl:
				var redownload_btn: Button = Button.new()
				redownload_btn.text = "🔄 Redownload"
				redownload_btn.custom_minimum_size = Vector2(110, 28)
				redownload_btn.tooltip_text = "Force redownload clean copy and overwrite existing file"
				redownload_btn.add_theme_color_override("font_color", Color(0.95, 0.8, 0.3))
				redownload_btn.pressed.connect(func(): _on_redownload_game_clicked(name))
				actions_hbox.add_child(redownload_btn)

			var delete_btn: Button = Button.new()
			delete_btn.text = "🗑 Delete / Uninstall"
			delete_btn.custom_minimum_size = Vector2(140, 28)
			delete_btn.tooltip_text = "Delete files from disk to free up space"
			delete_btn.add_theme_color_override("font_color", Color(0.95, 0.4, 0.4))
			delete_btn.pressed.connect(func(): _on_delete_game_clicked(name))
			actions_hbox.add_child(delete_btn)

			var change_btn: Button = Button.new()
			change_btn.text = "🔗 Change..."
			change_btn.custom_minimum_size = Vector2(85, 28)
			change_btn.pressed.connect(func(): _on_locate_game_clicked(name))
			actions_hbox.add_child(change_btn)

			var folder_btn: Button = Button.new()
			folder_btn.text = "📂 Folder"
			folder_btn.custom_minimum_size = Vector2(85, 28)
			folder_btn.pressed.connect(func(): _on_open_game_folder(name))
			actions_hbox.add_child(folder_btn)

	return panel

func _on_download_progress_updated(task: String, pct: float, dl_bytes: int, total_bytes: int, speed: float) -> void:
	for game in _all_games:
		var name: String = str(game.get("game_name", ""))
		var rom: String = str(game.get("required_rom", ""))
		var slug: String = str(game.get("slug", ""))
		var t_lower := task.to_lower()
		var matched := t_lower.contains(name.to_lower()) \
			or (rom != "" and t_lower.contains(rom.to_lower())) \
			or (slug != "" and t_lower.contains(slug.to_lower()))

		if matched:
			var speed_str: String = "%.1f MB/s" % (speed / (1024.0 * 1024.0)) if speed > 0 else ""
			var dl_mb: String = "%.1f" % (dl_bytes / (1024.0 * 1024.0))
			var tot_mb: String = "%.1f" % (total_bytes / (1024.0 * 1024.0))
			var msg: String = "Downloading: " + dl_mb + " / " + tot_mb + " MB" + (" (" + speed_str + ")" if speed_str != "" else "")
			_downloading_games[name] = {
				"pct": pct,
				"message": msg
			}
			_render_games()
			break

func _on_download_game_clicked(game_name: String) -> void:
	if not launcher:
		return
	_downloading_games[game_name] = {"pct": 0.0, "message": "Initiating download..."}
	_render_games()

	var result: Dictionary = await launcher.download_game(self, game_name, Callable(), false)
	_downloading_games.erase(game_name)
	refresh()
	game_status_changed.emit(game_name, launcher.get_game_status(game_name))

func _on_redownload_game_clicked(game_name: String) -> void:
	var status: Dictionary = launcher.get_game_status(game_name) if launcher else {}
	var rom_name: String = str(status.get("required_rom", game_name))

	_prompt_confirm(
		"Redownload " + game_name + "?",
		"This will delete the existing file (" + rom_name + ") and re-download a fresh copy.\n\nThis is recommended if the current file has a hash mismatch or was corrupted.",
		func():
			_downloading_games[game_name] = {"pct": 0.0, "message": "Starting fresh download..."}
			_render_games()
			var res: Dictionary = await launcher.redownload_game(self, game_name)
			_downloading_games.erase(game_name)
			refresh()
			game_status_changed.emit(game_name, launcher.get_game_status(game_name))
	)

func _on_delete_game_clicked(game_name: String) -> void:
	var status: Dictionary = launcher.get_game_status(game_name) if launcher else {}
	var size_str: String = str(status.get("formatted_size", ""))

	_prompt_confirm(
		"Delete " + game_name + "?",
		"This will delete the game files (" + size_str + ") from user://games/ to reclaim disk space.\n\nYou can re-download or link the game at any time.",
		func():
			if launcher:
				launcher.uninstall_game(game_name)
				refresh()
				game_status_changed.emit(game_name, launcher.get_game_status(game_name))
	)

func _on_locate_game_clicked(game_name: String) -> void:
	_locating_game_name = game_name
	var status: Dictionary = launcher.get_game_status(game_name) if launcher else {}
	var req_file: String = str(status.get("required_rom", status.get("target_exe", "*.*")))
	game_file_dialog.title = "Locate File for " + game_name
	game_file_dialog.filters = PackedStringArray([
		req_file + " ; Required File",
		"*.gba, *.rvz, *.iso, *.nds, *.bin, *.cue, *.sfc, *.smc, *.z64, *.n64, *.exe ; Supported Game Formats",
		"*.* ; All Files"
	])
	game_file_dialog.popup_centered(Vector2i(700, 500))

func _on_game_file_selected(path: String) -> void:
	if _locating_game_name == "" or not launcher:
		return
	var res: Dictionary = launcher.set_game_path(_locating_game_name, path)
	if not res.get("success", false):
		var err: String = str(res.get("error", "Failed to link path"))
		_prompt_confirm("Link Failed", err, Callable())
	_locating_game_name = ""
	refresh()

func _on_set_url_clicked(game_name: String, current_url: String) -> void:
	_setting_url_game_name = game_name
	var status: Dictionary = launcher.get_game_status(game_name) if launcher else {}
	var req_rom: String = str(status.get("required_rom", game_name))
	set_url_label.text = "Enter direct download URL for: " + game_name + "\n(" + req_rom + ")"
	set_url_input.text = current_url
	set_url_dialog.popup_centered(Vector2i(550, 180))

func _on_set_url_confirmed() -> void:
	if _setting_url_game_name == "" or not launcher:
		return
	var new_url: String = set_url_input.text.strip_edges()
	var status: Dictionary = launcher.get_game_status(_setting_url_game_name)
	var rom_key: String = str(status.get("required_rom", _setting_url_game_name))
	if rom_key == "":
		rom_key = _setting_url_game_name

	launcher.set_rom_download_url(rom_key, new_url)
	_setting_url_game_name = ""
	refresh()
	catalog_updated.emit(RomCatalogManager.get_catalog_info())

func _on_open_game_folder(game_name: String) -> void:
	if launcher:
		launcher.open_game_folder(game_name)

func _on_open_folder_pressed() -> void:
	if launcher:
		launcher.open_games_folder()
	else:
		OS.shell_open(ProjectSettings.globalize_path("user://"))

# --- LEGACY ROM.JSON DOWNLOAD & IMPORT HANDLERS ---
func _on_download_pressed() -> void:
	var target_url: String = url_input.text.strip_edges()
	if target_url == "":
		if is_instance_valid(url_input) and url_input.placeholder_text.strip_edges() != "":
			target_url = url_input.placeholder_text.strip_edges()
		elif RomCatalogManager.DEFAULT_FALLBACK_URL != "":
			target_url = RomCatalogManager.DEFAULT_FALLBACK_URL
		if target_url != "" and is_instance_valid(url_input):
			url_input.text = target_url

	if target_url == "":
		feedback_label.add_theme_color_override("font_color", Color(1, 0.4, 0.4))
		feedback_label.text = "Please enter a valid URL."
		return

	download_btn.disabled = true
	download_btn.text = "Downloading..."
	feedback_label.remove_theme_color_override("font_color")
	feedback_label.text = "Fetching rom.json from server..."

	RomCatalogManager.download_catalog_from_url(self, target_url, func(success: bool, msg: String, _count: int, _data: Dictionary):
		download_btn.disabled = false
		download_btn.text = "Download & Update"

		if success:
			feedback_label.add_theme_color_override("font_color", Color(0.3, 0.9, 0.5))
			feedback_label.text = "✅ " + msg
			if launcher and "load_rom_catalog" in launcher:
				launcher.load_rom_catalog()
			refresh()
			catalog_updated.emit(RomCatalogManager.get_catalog_info())
		else:
			feedback_label.add_theme_color_override("font_color", Color(1, 0.4, 0.4))
			feedback_label.text = "❌ " + msg
	)

func _on_local_file_selected(path: String) -> void:
	var res = RomCatalogManager.load_from_local_file(path)
	if res.get("success", false):
		feedback_label.add_theme_color_override("font_color", Color(0.3, 0.9, 0.5))
		feedback_label.text = "✅ Successfully imported %d entries from %s" % [res.get("configured_count", 0), path.get_file()]
		if launcher and "load_rom_catalog" in launcher:
			launcher.load_rom_catalog()
		refresh()
		catalog_updated.emit(RomCatalogManager.get_catalog_info())
	else:
		feedback_label.add_theme_color_override("font_color", Color(1, 0.4, 0.4))
		feedback_label.text = "❌ " + res.get("error", "Failed to load local file.")

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
