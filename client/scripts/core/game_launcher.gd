class_name GameLauncher
extends RefCounted

const LauncherUtils = preload("res://scripts/core/launcher_utils.gd")
const ArchipelagoConfig = preload("res://scripts/core/archipelago_config.gd")
const HostYamlEditorScript = preload("res://scripts/core/host_yaml_editor.gd")
const LauncherConfigStoreScript = preload("res://scripts/core/launcher_config_store.gd")
const GameIdentityResolverScript = preload("res://scripts/core/game_identity_resolver.gd")
const RomCatalogServiceScript = preload("res://scripts/core/rom_catalog_service.gd")
const ExecutableLocatorScript = preload("res://scripts/core/executable_locator.gd")
const ToolManagerScript = preload("res://scripts/core/tool_manager.gd")
const ToolInstallerScript = preload("res://scripts/core/tool_installer.gd")
const FirmwareManagerScript = preload("res://scripts/core/firmware_manager.gd")
const ConfigWriterServiceScript = preload("res://scripts/core/config_writer_service.gd")
const ProcessLauncherScript = preload("res://scripts/core/process_launcher.gd")
const PatchManagerScript = preload("res://scripts/core/patch_manager.gd")
const RomArchiveServiceScript = preload("res://scripts/core/rom_archive_service.gd")
const PackageInstallerScript = preload("res://scripts/core/package_installer.gd")
const PcGameInstallerScript = preload("res://scripts/core/pc_game_installer.gd")
const RomDownloadServiceScript = preload("res://scripts/core/rom_download_service.gd")
const TrackerManagerScript = preload("res://scripts/core/tracker_manager.gd")
const CustomWorldSyncServiceScript = preload("res://scripts/core/custom_world_sync_service.gd")
const ServerUrlHelper = preload("res://scripts/core/server_url_helper.gd")

# --- CONSTANTS ---
const DEFAULT_ARCHIPELAGO_DOWNLOAD_URL: String = "/tools/archipelago.zip"
const DEFAULT_ARCHIPELAGO_FALLBACK_URL: String = "https://github.com/ArchipelagoMW/Archipelago/releases/download/0.6.7/Setup.Archipelago.0.6.7.exe"
const DEFAULT_BIZHAWK_PREREQS_URL: String = "https://github.com/TASEmulators/BizHawk-Prereqs/releases/download/2.4.8_1/bizhawk_prereqs_v2.4.8_1.zip"

const BYTES_PER_MB: float = 1024.0 * 1024.0

const USER_TOOLS_DIR: String = "user://tools"
const USER_BASE_ROMS_DIR: String = "user://base_roms"
const USER_GAMES_DIR: String = "user://games"
const USER_SAVES_DIR: String = "user://saves"
const USER_PATHS_CONFIG_PATH: String = "user://paths_config.json"
const USER_HASH_CACHE_PATH: String = "user://file_hash_cache.json"

# --- LAUNCH PIPELINE ENUM & SIGNALS ---
enum LaunchStage {
	INITIALIZING,
	PREPARING_ROM,
	PREPARING_TOOLS,
	PREPARING_FIRMWARE,
	FETCHING_PATCH,
	SYNCING_CONFIG,
	SPAWNING_PROCESS,
	MODDING_DISC,
	COMPLETED,
	FAILED
}

signal launch_status_updated(stage: int, message: String, progress_pct: float)
signal prompt_file_selection(title: String, instructions: String, filters: PackedStringArray, callback: Callable)
signal prompt_tool_installation(tool_name: String, download_url: String, subfolder: String, target_file: String, callback: Callable)
signal launch_completed(game_name: String, pid: int)
signal launch_failed(game_name: String, error_message: String)
signal config_loaded()
signal download_progress_updated(task: String, pct: float, dl_bytes: int, total_bytes: int, speed: float)
signal modding_status_updated(msg: String, pct: int)
signal overlay_dismiss_requested()

class AsyncCompletion extends RefCounted:
	signal completed(ok: bool, val: String)
	var is_done: bool = false
	var ok: bool = false
	var val: String = ""

	func finish(p_ok: bool = false, p_val: String = "") -> void:
		if is_done:
			return
		ok = p_ok
		val = p_val
		is_done = true
		completed.emit(p_ok, p_val)

	func wait_completed(node: Node = null) -> Array:
		if not is_done:
			if is_instance_valid(node) and node is Node and node.is_inside_tree():
				var cancel_cb = func(): finish(false, "Context destroyed")
				node.tree_exiting.connect(cancel_cb, CONNECT_ONE_SHOT)
				await completed
				if is_instance_valid(node) and node.tree_exiting.is_connected(cancel_cb):
					node.tree_exiting.disconnect(cancel_cb)
			else:
				await completed
		return [ok, val]

class LaunchContext:
	var game_name: String
	var preset: Dictionary
	var node: Node
	var launch_mode: String = "direct"
	var base_rom_path: String = ""
	var client_exe_path: String = ""
	var emulator_exe_path: String = ""
	var patch_path: String = ""
	var server_url: String = ""
	var process_id: int = -1
	var is_cancelled: bool = false
	
	func _init(p_game: String, p_preset: Dictionary, p_node: Node) -> void:
		game_name = p_game
		preset = p_preset
		node = p_node
		launch_mode = preset.get("launch_mode", "direct")

# State attributes
static var _file_hash_cache: Dictionary = {}
var launcher_tools: Dictionary = {}
var launcher_presets: Dictionary = {}
var paths_config: Dictionary = {}
var roms_catalog: Dictionary = {}
var _config_store
var _identity_resolver
var _rom_catalog_service
var _executable_locator
var _tool_manager
var _tool_installer
var _firmware_manager
var _config_writer_service
var _process_launcher
var _patch_manager
var _rom_archive_service
var _package_installer
var _pc_game_installer
var _rom_download_service
var _tracker_manager
var _custom_world_sync_service
var _tool_installation_generation: int = 0

func _init() -> void:
	_config_store = LauncherConfigStoreScript.new()
	_config_store.tools = launcher_tools
	_config_store.games = launcher_presets
	_identity_resolver = GameIdentityResolverScript.new(launcher_presets)
	_rom_catalog_service = RomCatalogServiceScript.new(launcher_presets, _identity_resolver)
	_rom_catalog_service.set_context_references(paths_config, get_supported_rom_extensions)
	_executable_locator = ExecutableLocatorScript.new(USER_GAMES_DIR, USER_TOOLS_DIR)
	_tool_manager = ToolManagerScript.new(paths_config, _executable_locator, save_paths_config)
	_tool_installer = ToolInstallerScript.new(
		_tool_manager,
		find_game_executable,
		find_executable_recursive,
		track_http_download_progress,
		get_progress_bar_str,
		USER_TOOLS_DIR,
		func() -> int: return _tool_installation_generation
	)
	_firmware_manager = FirmwareManagerScript.new(get_game_slug, _inject_emulator_firmware_config, USER_GAMES_DIR)
	_config_writer_service = ConfigWriterServiceScript.new(interpolate_template, _merge_and_interpolate_json)
	_process_launcher = ProcessLauncherScript.new()
	_patch_manager = PatchManagerScript.new(launcher_presets, get_preset, USER_SAVES_DIR)
	_rom_archive_service = RomArchiveServiceScript.new(get_game_slug_for_rom, get_game_dir, get_supported_rom_extensions)
	_rom_archive_service.set_find_executable_callback(find_game_executable)
	_custom_world_sync_service = CustomWorldSyncServiceScript.new(get_custom_world_destinations)
	_package_installer = PackageInstallerScript.new(track_http_download_progress, get_progress_bar_str)
	_pc_game_installer = PcGameInstallerScript.new(resolve_download_url, decrypt_file_aes256, _set_overlay_downloading_state, track_http_download_progress, update_launch_progress_ui)
	_rom_download_service = RomDownloadServiceScript.new(resolve_download_url, decrypt_file_aes256, unpack_rom_zip, _set_overlay_downloading_state, track_http_download_progress, get_progress_bar_str, update_launch_progress_ui)
	_tracker_manager = TrackerManagerScript.new()
	load_local_presets_sync()


# =====================================================================
#                     CONFIG & CATALOG LOADING
# =====================================================================

func load_local_presets_sync() -> void:
	_config_store.load_local()

func load_launcher_config() -> void:
	load_local_presets_sync()
	var remote_loaded: bool = await _config_store.load_remote()
	if remote_loaded:
		GuidedSetupRegistry.refresh_slug_cache()
		print("[Launcher] Loaded ", launcher_presets.size(), " games and ", launcher_tools.size(), " shared tools from backend REST API.")
		config_loaded.emit()
		return

	print("[Launcher] Using cached launcher configuration because the backend was unavailable.")

func normalize_game_slug(name: String) -> String:
	return GameIdentityResolver.normalize(name)

func get_game_slug(game_name: String) -> String:
	if _identity_resolver:
		return _identity_resolver.get_slug(game_name)
	return GameIdentityResolver.slugify(game_name)

func get_game_dir(game_name: String) -> String:
	var slug: String = get_game_slug(game_name)
	var dir_path: String = USER_GAMES_DIR.path_join(slug)
	DirAccess.make_dir_recursive_absolute(dir_path)
	return dir_path

func get_game_slug_for_rom(rom_name: String) -> String:
	if _identity_resolver:
		return _identity_resolver.game_slug_for_rom(rom_name)
	return GameIdentityResolver.slugify(rom_name.get_basename())

func get_game_rom_path(game_name: String, rom_name: String) -> String:
	return get_game_dir(game_name).path_join(rom_name)

func has_preset(game_name: String) -> bool:
	if _identity_resolver:
		return _identity_resolver.has_preset(game_name)
	return false

func has_curated_preset(game_name: String) -> bool:
	if not has_preset(game_name):
		return false
	var preset: Dictionary = get_preset(game_name)
	var tier: int = int(preset.get("support_tier", 4))
	return tier < 4

func get_preset(game_name: String) -> Dictionary:
	if _identity_resolver:
		return _identity_resolver.get_preset(game_name)
	return {
		"game_name": game_name,
		"support_tier": 3,
		"launch_mode": "ap_client",
		"client_tool": "archipelago_client",
		"client_component": "Archipelago Launcher",
		"auto_connect": true,
		"install_instructions": "Community APWorld: Select your clean base ROM or executable if required. Lodestone will open Archipelago Launcher and connect automatically."
	}

func get_tracker_config(game_name: String) -> Dictionary:
	return _tracker_manager.get_tracker_config(get_preset(game_name))

func ensure_poptracker(node: Node, callback: Callable) -> void:
	_tracker_manager.ensure_poptracker(node, launcher_tools, self, callback)

func open_poptracker(node: Node, game_name: String, server_url: String, slot_name: String, callback: Callable) -> void:
	_tracker_manager.open_tracker(node, get_preset(game_name), get_game_slug(game_name), launcher_tools, self, server_url, slot_name, callback)

func get_saved_path(game_name: String, preset: Dictionary = {}) -> String:
	var candidate_keys: Array[String] = [game_name, get_game_slug(game_name)]
	var effective_preset: Dictionary = preset if not preset.is_empty() else get_preset(game_name)
	if not effective_preset.is_empty():
		var canon: String = effective_preset.get("game_name", "")
		if canon != "" and not candidate_keys.has(canon):
			candidate_keys.append(canon)
		for a in effective_preset.get("aliases", []):
			var a_str: String = str(a)
			if a_str != "" and not candidate_keys.has(a_str):
				candidate_keys.append(a_str)
	for k in candidate_keys:
		var p: String = paths_config.get(k, "")
		if p != "" and FileAccess.file_exists(p):
			return p
	var target_norm: String = GameIdentityResolver.normalize(game_name)
	for k in paths_config.keys():
		if GameIdentityResolver.normalize(str(k)) == target_norm:
			var p: String = paths_config.get(k, "")
			if p != "" and FileAccess.file_exists(p):
				return p
	return ""

func load_roms_catalog() -> void:
	_rom_catalog_service.load_catalog()
	roms_catalog = _rom_catalog_service.catalog
	print("[Launcher] Loaded ROMs catalog (", roms_catalog.size(), " entries)")

func get_rom_download_entry(identifier: String) -> Dictionary:
	_rom_catalog_service.catalog = roms_catalog
	return _rom_catalog_service.get_download_entry(identifier)

func resolve_download_url(raw_url: String) -> String:
	return LauncherUtils.resolve_download_url(raw_url)

func decrypt_file_aes256(encrypted_path: String, output_path: String, passphrase: String, progress_callback: Callable = Callable()) -> bool:
	return LauncherUtils.decrypt_file_aes256(encrypted_path, output_path, passphrase, progress_callback)


func load_paths_config() -> void:
	if FileAccess.file_exists(USER_PATHS_CONFIG_PATH):
		var file_access: FileAccess = FileAccess.open(USER_PATHS_CONFIG_PATH, FileAccess.READ)
		if file_access:
			var parsed_json: Variant = JSON.parse_string(file_access.get_as_text())
			if parsed_json is Dictionary:
				paths_config = parsed_json
				# Sanitize: remove any tools erroneously saved under game keys
				var dirty: bool = false
				for k in paths_config.keys():
					var val: String = str(paths_config[k])
					if val.to_lower().ends_with("archipelagolauncher.exe") or val.to_lower().ends_with("launcher.exe"):
						var p: Dictionary = get_preset(k)
						if not p.is_empty() and (p.get("required_rom", "") != "" or p.get("launch_mode", "") in ["ap_client", "patch_rom"]):
							paths_config.erase(k)
							dirty = true
				if dirty:
					save_paths_config()
				print("[Launcher] Loaded user paths configuration.")
			file_access.close()
	sync_custom_worlds_to_archipelago()

func save_paths_config() -> void:
	var file_access: FileAccess = FileAccess.open(USER_PATHS_CONFIG_PATH, FileAccess.WRITE)
	if file_access:
		file_access.store_string(JSON.stringify(paths_config, "  "))
		file_access.close()
		print("[Launcher] Saved user paths configuration.")


# =====================================================================
#                   ROM UNPACKING & AUTO-DISCOVERY
# =====================================================================

func get_supported_rom_extensions() -> Array[String]:
	var exts: Array[String] = []
	for game_name in launcher_presets.keys():
		var preset: Dictionary = launcher_presets[game_name]
		var req_rom: String = preset.get("required_rom", "")
		var ext: String = req_rom.get_extension().to_lower()
		if ext != "" and not exts.has(ext):
			exts.append(ext)
		for alias in preset.get("rom_aliases", []):
			var a_ext: String = str(alias).get_extension().to_lower()
			if a_ext != "" and not exts.has(a_ext):
				exts.append(a_ext)
	return exts

func unpack_rom_zip(zip_file_path: String, rom_name: String, callback: Callable) -> void:
	_rom_archive_service.unpack(zip_file_path, rom_name, callback)
func find_existing_base_rom(rom_name: String) -> String:
	return _rom_catalog_service.find_existing_base_rom(rom_name)

func migrate_all_legacy_base_roms() -> void:
	_rom_catalog_service.migrate_all_legacy_base_roms()

func _cleanup_legacy_base_roms_dir() -> void:
	_rom_catalog_service.cleanup_legacy_base_roms_dir()

func _fuzzy_search_matching_rom(candidate_directories: Array[String], rom_name: String, target_extension: String) -> String:
	return _rom_catalog_service._fuzzy_search_matching_rom(candidate_directories, rom_name, target_extension)

func ensure_rom_exists_or_download(node: Node, rom_name: String, callback: Callable = Callable(), force_redownload: bool = false) -> Dictionary:
	if rom_name.strip_edges() == "":
		print("[Launcher] Game specifies no required ROM. Skipping ROM download/check.")
		if callback.is_valid():
			callback.call(true, "")
		return {"success": true, "path": "", "error": ""}
		
	var game_slug: String = get_game_slug_for_rom(rom_name)
	var target_game_dir: String = get_game_dir(game_slug)
	var target_rom_path: String = target_game_dir.path_join(rom_name)
	
	var existing_rom: String = "" if force_redownload else find_existing_base_rom(rom_name)
	var comp = AsyncCompletion.new()
	var internal_cb = func(ok: bool, val: String):
		if callback.is_valid():
			callback.call(ok, val)
		comp.finish(ok, val)

	if existing_rom != "":
		_handle_existing_base_rom(node, existing_rom, target_rom_path, rom_name, internal_cb)
	else:
		if force_redownload and FileAccess.file_exists(target_rom_path):
			DirAccess.remove_absolute(target_rom_path)
			print("[Launcher] Removed existing ROM file for forced redownload: ", target_rom_path)
		var download_entry: Dictionary = get_rom_download_entry(rom_name)
		if download_entry.is_empty():
			for g_name in launcher_presets.keys():
				var preset: Dictionary = launcher_presets[g_name]
				if preset.get("required_rom", "") == rom_name:
					download_entry = get_rom_download_entry(g_name)
					if download_entry.is_empty():
						var p_url: String = preset.get("rom_download_url", "").strip_edges()
						if p_url != "":
							download_entry = {"url": p_url, "key": "", "encrypted": false}
					break
				for alias in preset.get("rom_aliases", []):
					if str(alias) == rom_name:
						download_entry = get_rom_download_entry(str(alias))
						if download_entry.is_empty():
							download_entry = get_rom_download_entry(g_name)
						break
				if not download_entry.is_empty():
					break

		if download_entry.is_empty() or download_entry.get("url", "") == "":
			internal_cb.call(false, "Base ROM \"" + rom_name + "\" is missing. Please configure a download link in user://roms.json or place the file in user://games/" + game_slug + "/")
		else:
			var catalog_url: String = download_entry.get("url", "")
			var dec_key: String = download_entry.get("key", "")
			
			if catalog_url.begins_with("file://"):
				_handle_local_file_url(node, catalog_url, target_rom_path, rom_name, internal_cb)
			else:
				_download_base_rom_http(node, catalog_url, target_game_dir, rom_name, target_rom_path, internal_cb, dec_key)

	await comp.wait_completed(node)
	return {"success": comp.ok, "path": comp.val if comp.ok else "", "error": comp.val if not comp.ok else ""}

func _handle_existing_base_rom(node: Node, found_rom: String, target_rom_path: String, rom_name: String, callback: Callable) -> void:
	_rom_download_service.process_existing(node, found_rom, target_rom_path, rom_name, callback)

func _handle_local_file_url(node: Node, catalog_url: String, target_rom_path: String, rom_name: String, callback: Callable) -> void:
	_rom_download_service.copy_local_file(node, catalog_url, target_rom_path, rom_name, callback)

func _download_base_rom_http(node: Node, download_url: String, base_roms_dir: String, rom_name: String, target_rom_path: String, callback: Callable, decryption_key: String = "", redirect_depth: int = 0) -> void:
	_rom_download_service.download(node, download_url, base_roms_dir, rom_name, target_rom_path, callback, decryption_key, redirect_depth)

func _set_overlay_downloading_state(_node: Node = null) -> void:
	download_progress_updated.emit("Downloading...", 0.0, 0, 0, 0.0)

func ensure_pc_game_installed(node: Node, game_name: String, preset_config: Dictionary, callback: Callable = Callable()) -> Dictionary:
	var exec_name: String = preset_config.get("client_executable", preset_config.get("executable_name", ""))
	var aliases: Array = preset_config.get("executable_aliases", [])
	
	var download_entry: Dictionary = get_rom_download_entry(game_name)
	if download_entry.is_empty() and exec_name != "":
		download_entry = get_rom_download_entry(exec_name)
	for a in aliases:
		if download_entry.is_empty():
			download_entry = get_rom_download_entry(str(a))
		else:
			break
			
	var comp = AsyncCompletion.new()
	var internal_cb = func(ok: bool, val: String):
		if callback.is_valid():
			callback.call(ok, val)
		comp.finish(ok, val)

	if download_entry.is_empty() or download_entry.get("url", "") == "":
		internal_cb.call(false, "Game files for \"" + game_name + "\" not found on machine, and no download link configured in roms.json.")
	else:
		var download_url: String = download_entry.get("url", "")
		var dec_key: String = download_entry.get("key", "")
		var game_dest_dir: String = get_game_dir(game_name)
		
		print("[Launcher] Downloading standalone PC game (", game_name, ") from: ", download_url)
		_download_and_unpack_game_archive(node, download_url, game_dest_dir, game_name, dec_key, func(success: bool, msg: String):
			if not success:
				internal_cb.call(false, msg)
				return
				
			var found_exe: String = _executable_locator.find_in_directory(game_dest_dir, exec_name, aliases)
			if found_exe != "":
				paths_config[game_name] = found_exe
				save_paths_config()
				print("[Launcher] PC Game auto-installed and executable located: ", found_exe)
				internal_cb.call(true, found_exe)
			else:
				internal_cb.call(false, "Game archive downloaded and extracted, but could not locate " + exec_name + " in " + game_dest_dir)
		)

	await comp.wait_completed(node)
	return {"success": comp.ok, "path": comp.val if comp.ok else "", "error": comp.val if not comp.ok else ""}

func _download_and_unpack_game_archive(node: Node, download_url: String, extract_dir: String, game_name: String, decryption_key: String, callback: Callable, redirect_depth: int = 0) -> void:
	_pc_game_installer.install(node, download_url, extract_dir, game_name, decryption_key, callback, redirect_depth)

# =====================================================================
#                    PROGRESS TRACKING & UI UTILITIES
# =====================================================================

func get_progress_bar_str(pct: int) -> String:
	var filled_count: int = int(clamp(pct, 0, 100) / 5)
	var empty_count: int = 20 - filled_count
	var bar_str: String = ""
	for idx in range(filled_count):
		bar_str += "█"
	for idx in range(empty_count):
		bar_str += "░"
	return "[" + bar_str + "] " + str(pct) + "%"

func update_launch_progress_ui(_node: Node, task_title: String, pct: int, downloaded_bytes: int, total_bytes: int, speed_bps: float = 0.0) -> void:
	download_progress_updated.emit(task_title, float(pct), downloaded_bytes, total_bytes, speed_bps)

func track_http_download_progress(node: Node, http_request: HTTPRequest, task_title: String, is_active_flag: Array) -> void:
	var last_bytes: int = 0
	var last_time: float = float(Time.get_ticks_msec()) / 1000.0
	var current_speed: float = 0.0
	
	while is_active_flag[0] and is_instance_valid(http_request):
		var downloaded_bytes: int = http_request.get_downloaded_bytes()
		var total_bytes: int = http_request.get_body_size()
		var percentage: int = int((float(downloaded_bytes) / float(total_bytes)) * 100.0) if total_bytes > 0 else 0
		
		var now: float = float(Time.get_ticks_msec()) / 1000.0
		var dt: float = now - last_time
		if dt >= 0.4:
			var bytes_diff: int = downloaded_bytes - last_bytes
			if bytes_diff >= 0:
				var measured: float = float(bytes_diff) / dt
				current_speed = (current_speed * 0.4) + (measured * 0.6) if current_speed > 0.0 else measured
			last_bytes = downloaded_bytes
			last_time = now
			
		update_launch_progress_ui(node, task_title, percentage, downloaded_bytes, total_bytes, current_speed)
		if is_instance_valid(node) and node.get_tree():
			await node.get_tree().create_timer(0.15).timeout
		else:
			break

func cancel_tool_installation() -> void:
	_tool_installation_generation += 1
	Updater.log_message("INSTALL", "Tool installation cancelled by user.")

func ensure_tool_installed_or_download(node: Node, tool_name: String, download_url: String, subfolder: String, target_exe: String, callback: Callable = Callable(), fallback_url: String = "", installation_generation: int = -1, expected_sha256: String = "", managed_only: bool = false) -> Dictionary:
	if installation_generation < 0:
		_tool_installation_generation += 1
		installation_generation = _tool_installation_generation
	var comp = AsyncCompletion.new()
	var internal_cb = func(ok: bool, val: String):
		if callback.is_valid():
			callback.call(ok, val)
		comp.finish(ok, val)

	_tool_installer.install(node, tool_name, download_url, subfolder, target_exe, internal_cb, fallback_url, installation_generation, expected_sha256, managed_only)
	await comp.wait_completed(node)
	if comp.ok:
		return _tool_manager.install_success(comp.val)
	return _tool_manager.install_failure(comp.val)

func get_all_tools_status(allow_deep_search: bool = false) -> Dictionary:
	return _tool_manager.get_all_tools_status(launcher_tools, allow_deep_search)

func get_tool_status(tool_key: String, allow_deep_search: bool = false) -> Dictionary:
	var tool_def: Dictionary = launcher_tools.get(tool_key, {})
	return _tool_manager.get_tool_status(tool_key, tool_def, allow_deep_search)

func uninstall_tool(tool_key: String) -> Dictionary:
	var tool_def: Dictionary = launcher_tools.get(tool_key, {})
	return _tool_manager.uninstall_tool(tool_key, tool_def)

func unlink_external_tool(tool_key: String) -> Dictionary:
	return _tool_manager.unlink_external_tool(tool_key)

func set_external_tool_path(tool_key: String, file_path: String) -> Dictionary:
	var tool_def: Dictionary = launcher_tools.get(tool_key, {})
	return _tool_manager.set_external_tool_path(tool_key, tool_def, file_path)

func open_tools_folder() -> void:
	DirAccess.make_dir_recursive_absolute(USER_TOOLS_DIR)
	OS.shell_open(ProjectSettings.globalize_path(USER_TOOLS_DIR))

func open_tool_folder(tool_key: String) -> void:
	var tool_def: Dictionary = launcher_tools.get(tool_key, {})
	var subfolders: Array = tool_def.get("sub_folders", [])
	var sf: String = str(subfolders[0]) if not subfolders.is_empty() else str(tool_def.get("name", tool_key))
	var target_dir: String = USER_TOOLS_DIR.path_join(sf)
	if not DirAccess.dir_exists_absolute(target_dir):
		target_dir = USER_TOOLS_DIR
	OS.shell_open(ProjectSettings.globalize_path(target_dir))

func install_tool(node: Node, tool_key: String, callback: Callable = Callable()) -> Dictionary:
	var tool_def: Dictionary = launcher_tools.get(tool_key, {})
	if tool_def.is_empty():
		return {"success": false, "error": "Unknown tool definition for: " + tool_key}
	var tool_name: String = str(tool_def.get("name", tool_key))
	var download_url: String = str(tool_def.get("download_url", ""))
	var subfolders: Array = tool_def.get("sub_folders", [])
	var subfolder: String = str(subfolders[0]) if not subfolders.is_empty() else tool_name
	var target_exe: String = str(tool_def.get("executable", ""))
	var fallback_url: String = str(tool_def.get("fallback_download_url", ""))
	var sha256_expected: String = str(tool_def.get("sha256", ""))
	return await ensure_tool_installed_or_download(
		node, tool_name, download_url, subfolder, target_exe, callback, fallback_url, -1, sha256_expected, true
	)

func reinstall_tool(node: Node, tool_key: String, callback: Callable = Callable()) -> Dictionary:
	var tool_def: Dictionary = launcher_tools.get(tool_key, {})
	if tool_def.is_empty():
		return {"success": false, "error": "Unknown tool definition for: " + tool_key}
	_tool_manager.uninstall_tool(tool_key, tool_def)
	return await install_tool(node, tool_key, callback)

static var _hash_cache_loaded: bool = false

static func _load_file_hash_cache() -> void:
	if FileAccess.file_exists(USER_HASH_CACHE_PATH):
		var fa := FileAccess.open(USER_HASH_CACHE_PATH, FileAccess.READ)
		if fa:
			var parsed: Variant = JSON.parse_string(fa.get_as_text())
			if parsed is Dictionary:
				_file_hash_cache = parsed
			fa.close()

static func _save_file_hash_cache() -> void:
	var fa := FileAccess.open(USER_HASH_CACHE_PATH, FileAccess.WRITE)
	if fa:
		fa.store_string(JSON.stringify(_file_hash_cache))
		fa.close()

static func clear_file_hash_cache(file_path: String = "") -> void:
	if not _hash_cache_loaded:
		_load_file_hash_cache()
		_hash_cache_loaded = true

	if file_path.is_empty():
		_file_hash_cache.clear()
	else:
		var norm_p := ProjectSettings.globalize_path(file_path)
		for k in _file_hash_cache.keys():
			if k.begins_with(file_path) or k.begins_with(norm_p):
				_file_hash_cache.erase(k)
	_save_file_hash_cache()

static func _get_or_compute_file_hash(file_path: String, algo: String) -> String:
	if not _hash_cache_loaded:
		_load_file_hash_cache()
		_hash_cache_loaded = true

	if file_path.is_empty() or not FileAccess.file_exists(file_path):
		return ""
	var norm_path: String = ProjectSettings.globalize_path(file_path)
	var mtime: int = FileAccess.get_modified_time(norm_path)
	var f_len: int = 0
	var fa := FileAccess.open(norm_path, FileAccess.READ)
	if fa:
		f_len = fa.get_length()
		fa.close()

	var cache_key: String = "%s::%s" % [norm_path, algo]
	if _file_hash_cache.has(cache_key):
		var entry: Dictionary = _file_hash_cache[cache_key]
		if entry.get("mtime", -1) == mtime and entry.get("size", -1) == f_len:
			return entry.get("hash", "")

	var computed_hash: String = ""
	if algo == "md5":
		computed_hash = FileAccess.get_md5(norm_path).to_lower()
	elif algo == "sha256":
		computed_hash = FileAccess.get_sha256(norm_path).to_lower()

	if computed_hash != "":
		_file_hash_cache[cache_key] = {
			"mtime": mtime,
			"size": f_len,
			"hash": computed_hash
		}
		_save_file_hash_cache()
	return computed_hash

func get_game_status(game_name: String, allow_deep_search: bool = false) -> Dictionary:
	var preset: Dictionary = get_preset(game_name)
	var slug: String = get_game_slug(game_name)
	var req_rom: String = str(preset.get("required_rom", ""))
	var target_exe: String = str(preset.get("client_executable", preset.get("executable_name", preset.get("target_exe", ""))))
	var game_dir: String = USER_GAMES_DIR.path_join(slug)

	var dl_entry: Dictionary = get_rom_download_entry(game_name)
	if dl_entry.is_empty() and req_rom != "":
		dl_entry = get_rom_download_entry(req_rom)
	if dl_entry.is_empty() and target_exe != "":
		dl_entry = get_rom_download_entry(target_exe)
	for alias in preset.get("rom_aliases", []):
		if dl_entry.is_empty():
			dl_entry = get_rom_download_entry(str(alias))
		else:
			break
	if dl_entry.is_empty():
		var p_url: String = str(preset.get("rom_download_url", "")).strip_edges()
		if p_url != "":
			dl_entry = {"url": p_url, "key": "", "encrypted": false}

	var download_url: String = str(dl_entry.get("url", "")).strip_edges()
	var has_download_url: bool = download_url != ""

	var resolved_path: String = ""
	if paths_config.has(game_name) and FileAccess.file_exists(paths_config[game_name]):
		resolved_path = paths_config[game_name]
	elif req_rom != "":
		resolved_path = find_existing_base_rom(req_rom)
	elif target_exe != "":
		resolved_path = find_game_executable(target_exe, preset.get("sub_folders", []), preset.get("search_dirs", []), allow_deep_search)
		if resolved_path == "" and DirAccess.dir_exists_absolute(game_dir):
			var local_exe := game_dir.path_join(target_exe)
			if FileAccess.file_exists(local_exe):
				resolved_path = ProjectSettings.globalize_path(local_exe)

	var is_installed: bool = (resolved_path != "" and FileAccess.file_exists(resolved_path))
	var is_managed: bool = false
	var size_bytes: int = 0

	var user_games_base := ProjectSettings.globalize_path(USER_GAMES_DIR).replace("\\", "/").to_lower()
	if is_installed:
		var norm_p := resolved_path.replace("\\", "/").to_lower()
		if norm_p.begins_with(user_games_base) or norm_p.contains("/games/"):
			is_managed = true

		var fa := FileAccess.open(resolved_path, FileAccess.READ)
		if fa:
			size_bytes = fa.get_length()
			fa.close()
	elif DirAccess.dir_exists_absolute(game_dir):
		var dir_sz := ToolManager.get_dir_size_bytes(game_dir)
		if dir_sz > 0:
			size_bytes = dir_sz

	var hash_valid: bool = true
	var expected_hash: String = ""
	var actual_hash: String = ""
	var rom_hashes: Dictionary = preset.get("rom_hashes", {})
	if rom_hashes.has("md5"):
		expected_hash = str(rom_hashes["md5"]).strip_edges().to_lower()
	elif rom_hashes.has("sha256"):
		expected_hash = str(rom_hashes["sha256"]).strip_edges().to_lower()

	if is_installed and expected_hash != "":
		var algo: String = "md5" if rom_hashes.has("md5") else "sha256"
		actual_hash = _get_or_compute_file_hash(resolved_path, algo)
		if actual_hash != expected_hash:
			hash_valid = false

	var status_code: String = "NOT_INSTALLED"
	if is_installed:
		if not hash_valid:
			status_code = "HASH_MISMATCH"
		elif is_managed:
			status_code = "INSTALLED"
		else:
			status_code = "EXTERNAL"
	elif has_download_url:
		status_code = "AVAILABLE"

	return {
		"game_name": game_name,
		"slug": slug,
		"required_rom": req_rom,
		"target_exe": target_exe,
		"preset": preset,
		"download_url": download_url,
		"has_download_url": has_download_url,
		"download_entry": dl_entry,
		"path": resolved_path,
		"installed": is_installed,
		"is_managed": is_managed,
		"size_bytes": size_bytes,
		"formatted_size": ToolManager.format_bytes(size_bytes),
		"hash_valid": hash_valid,
		"expected_hash": expected_hash,
		"actual_hash": actual_hash,
		"status_code": status_code,
		"managed_dir": game_dir
	}

func get_all_games_status() -> Dictionary:
	var result_list: Array[Dictionary] = []
	var total_size_bytes: int = 0
	var installed_count: int = 0
	var seen_games: Dictionary = {}

	for g_name in launcher_presets.keys():
		seen_games[g_name] = true
		var st := get_game_status(g_name, false)
		result_list.append(st)
		if st.installed:
			installed_count += 1
			total_size_bytes += int(st.size_bytes)

	for cat_key in roms_catalog.keys():
		if not seen_games.has(cat_key) and not cat_key.begins_with("default_"):
			var matched_preset := false
			for g_name in launcher_presets.keys():
				if launcher_presets[g_name].get("required_rom", "") == cat_key:
					matched_preset = true
					break
			if not matched_preset:
				seen_games[cat_key] = true
				var st := get_game_status(cat_key, false)
				result_list.append(st)
				if st.installed:
					installed_count += 1
					total_size_bytes += int(st.size_bytes)

	return {
		"games": result_list,
		"total_games_size_bytes": total_size_bytes,
		"formatted_total_size": ToolManager.format_bytes(total_size_bytes),
		"installed_count": installed_count,
		"total_count": result_list.size()
	}

func uninstall_game(game_name: String) -> Dictionary:
	var slug: String = get_game_slug(game_name)
	var game_dir: String = USER_GAMES_DIR.path_join(slug)
	clear_file_hash_cache(game_dir)
	if DirAccess.dir_exists_absolute(game_dir):
		ToolManager.remove_dir_recursive(game_dir)

	if paths_config.has(game_name):
		var configured_path: String = str(paths_config[game_name])
		clear_file_hash_cache(configured_path)
		var norm_c := configured_path.replace("\\", "/").to_lower()
		var norm_g := game_dir.replace("\\", "/").to_lower()
		if norm_c.begins_with(norm_g) or norm_c.contains("/games/" + slug + "/"):
			if FileAccess.file_exists(configured_path):
				DirAccess.remove_absolute(configured_path)
		paths_config.erase(game_name)
		save_paths_config()

	return {"success": true, "error": ""}

func download_game(node: Node, game_name: String, callback: Callable = Callable(), force_redownload: bool = false) -> Dictionary:
	var preset: Dictionary = get_preset(game_name)
	var req_rom: String = str(preset.get("required_rom", ""))
	var client_exe: String = str(preset.get("client_executable", preset.get("executable_name", "")))

	if req_rom != "":
		return await ensure_rom_exists_or_download(node, req_rom, callback, force_redownload)
	elif client_exe != "" or str(preset.get("launch_mode", "")) == "direct":
		if force_redownload:
			uninstall_game(game_name)
		return await ensure_pc_game_installed(node, game_name, preset, callback)
	else:
		return await ensure_rom_exists_or_download(node, game_name, callback, force_redownload)

func redownload_game(node: Node, game_name: String, callback: Callable = Callable()) -> Dictionary:
	return await download_game(node, game_name, callback, true)

func set_game_path(game_name: String, file_path: String) -> Dictionary:
	var trimmed: String = file_path.strip_edges()
	if trimmed == "" or not FileAccess.file_exists(trimmed):
		return {"success": false, "error": "Selected file does not exist: " + file_path}

	clear_file_hash_cache(trimmed)
	paths_config[game_name] = trimmed
	save_paths_config()
	return {"success": true, "path": trimmed, "error": ""}

func unlink_game_path(game_name: String) -> Dictionary:
	if paths_config.has(game_name):
		clear_file_hash_cache(str(paths_config[game_name]))
		paths_config.erase(game_name)
		save_paths_config()
	return {"success": true, "error": ""}

func open_games_folder() -> void:
	DirAccess.make_dir_recursive_absolute(USER_GAMES_DIR)
	OS.shell_open(ProjectSettings.globalize_path(USER_GAMES_DIR))

func open_game_folder(game_name: String) -> void:
	var dir: String = get_game_dir(game_name)
	OS.shell_open(ProjectSettings.globalize_path(dir))

func set_rom_download_url(identifier: String, url: String, key: String = "") -> bool:
	var success: bool = _rom_catalog_service.set_download_url(identifier, url, key)
	if success:
		roms_catalog = _rom_catalog_service.catalog
	return success

func download_and_extract_zip_to_dir(node: Node, download_url: String, target_dir: String, display_name: String, callback: Callable = Callable(), backup_files: Array = []) -> Dictionary:
	var comp = AsyncCompletion.new()
	var internal_cb = func(ok: bool, err: String):
		if callback.is_valid():
			callback.call(ok, err)
		comp.finish(ok, err)

	_package_installer.install(node, download_url, target_dir, display_name, internal_cb, backup_files)
	await comp.wait_completed(node)
	return {"success": comp.ok, "error": comp.val if not comp.ok else ""}

func ensure_emulator_firmware(node: Node, preset_config: Dictionary, emulator_exe_path: String, rom_path: String, callback: Callable = Callable()) -> Dictionary:
	var comp = AsyncCompletion.new()
	var internal_cb = func(ok: bool, val: String):
		if callback.is_valid():
			callback.call(ok, val)
		comp.finish(ok, val)

	_firmware_manager.ensure(node, preset_config, emulator_exe_path, rom_path, internal_cb)
	await comp.wait_completed(node)
	return {"success": comp.ok, "error": comp.val if not comp.ok else ""}

func _inject_emulator_firmware_config(emulator_dir: String, emu_cfg: Dictionary) -> void:
	ArchipelagoConfig.inject_emulator_firmware_config(emulator_dir, emu_cfg)


# =====================================================================
#                ARCHIPELAGO CONFIG SYNC (host.yaml)
# =====================================================================

func sync_archipelago_host_yaml(rom_path: String, bizhawk_path: String = "", dolphin_path: String = "", server_url: String = "") -> void:
	ArchipelagoConfig.sync_archipelago_host_yaml(
		rom_path,
		bizhawk_path,
		dolphin_path,
		server_url,
		launcher_presets,
		paths_config,
		USER_TOOLS_DIR,
		find_executable_recursive,
		sync_custom_worlds_to_archipelago
	)

func _get_archipelago_host_yaml_paths() -> Array[String]:
	return ArchipelagoConfig.get_archipelago_host_yaml_paths(USER_TOOLS_DIR)

func _write_synced_host_yaml_file(target_yaml_path: String, absolute_rom_path: String, absolute_bizhawk_path: String, absolute_dolphin_path: String = "", server_url: String = "") -> void:
	ArchipelagoConfig.write_synced_host_yaml_file(target_yaml_path, absolute_rom_path, absolute_bizhawk_path, absolute_dolphin_path, server_url, launcher_presets)

func _resolve_host_yaml_tree(node: Variant, rom_path: String, bizhawk_path: String, dolphin_path: String, server_url: String, clean_server_addr: String, rom_filename_lower: String, req_audio: String) -> Variant:
	return ArchipelagoConfig.resolve_host_yaml_tree(node, rom_path, bizhawk_path, dolphin_path, server_url, clean_server_addr, rom_filename_lower, req_audio)

func _find_supplemental_rom_path(rom_path: String, target_filename: String) -> String:
	return ArchipelagoConfig.find_supplemental_rom_path(rom_path, target_filename)

func _evaluate_yaml_template(raw_str: String, rom_path: String, bizhawk_path: String, dolphin_path: String, server_url: String, clean_server_addr: String, audio_path: String = "") -> String:
	return ArchipelagoConfig.evaluate_yaml_template(raw_str, rom_path, bizhawk_path, dolphin_path, server_url, clean_server_addr, audio_path)

func update_yaml_value(yaml_content: String, section_key: String, option_path: String, val: Variant, extra_lines: Array[String] = []) -> String:
	return ArchipelagoConfig.update_yaml_value(yaml_content, section_key, option_path, val, extra_lines)

func patch_yaml_section(yaml_content: String, section_key: String, patches: Dictionary) -> String:
	return ArchipelagoConfig.patch_yaml_section(yaml_content, section_key, patches)


# =====================================================================
#                CUSTOM APWORLD SYNC & DOWNLOAD
# =====================================================================

func get_custom_world_destinations() -> Array[String]:
	var dests: Array[String] = ArchipelagoConfig.get_custom_world_destinations(USER_TOOLS_DIR)
	var launcher_exe: String = find_game_executable("ArchipelagoLauncher.exe", ["Archipelago"], [], false)
	if launcher_exe != "":
		var exe_dir: String = launcher_exe.get_base_dir()
		var candidate_custom: String = exe_dir.path_join("custom_worlds")
		if not dests.has(candidate_custom):
			dests.append(candidate_custom)
		pass


	return dests

func sync_custom_worlds_to_archipelago() -> void:
	if _custom_world_sync_service:
		_custom_world_sync_service.sync_to_archipelago()

func sync_custom_worlds_from_server(node: Node, target_games: Array = [], callback: Callable = Callable()) -> void:
	if _custom_world_sync_service:
		_custom_world_sync_service.sync_from_server(node, target_games, callback)
	elif callback.is_valid():
		callback.call(false)

# =====================================================================
#                EXECUTABLE RECURSIVE DISCOVERY
# =====================================================================

func find_executable_recursive(dir_path: String, executable_name: String, current_depth: int = 0, max_depth: int = 4) -> String:
	return _executable_locator.find_recursive(dir_path, executable_name, current_depth, max_depth)

func find_game_executable(executable_name: String, sub_folders: Array, executable_aliases: Array = [], allow_deep_search: bool = true) -> String:
	return _executable_locator.find(executable_name, sub_folders, executable_aliases, allow_deep_search)

func check_hollow_knight_modding_status(exe_or_game_dir: String) -> Dictionary:
	return LauncherUtils.check_hollow_knight_modding_status(exe_or_game_dir)

func _get_platform_search_roots() -> Array[String]:
	return LauncherUtils.get_platform_search_roots()


# =====================================================================
#                PROCESS EXECUTION & LOGGING
# =====================================================================

func interpolate_template(template_str: String, context: Dictionary) -> String:
	return LauncherUtils.interpolate_template(template_str, context)

func build_launch_context(game_path: String, patch_path: String = "", rom_path: String = "", game_name: String = "", total_games: int = 1) -> Dictionary:
	var player_name: String = ""
	for player_info in NetworkManager.players:
		if player_info.get("userId") == NetworkManager.user_id:
			player_name = player_info.get("name", "")
			break
	if player_name == "":
		player_name = NetworkManager.player_name

	var server_url: String = NetworkManager.get_ap_server_url()
	var server_clean_url: String = ServerUrlHelper.format_ap_address(server_url, "localhost:38000")
	var hp: Dictionary = ServerUrlHelper.extract_host_port(server_url)
	var server_host: String = hp.host
	var server_port: String = hp.port

	var slot_name: String = player_name
	if game_name != "":
		var custom_tag: String = get_preset(game_name).get("short_tag", "")
		slot_name = YamlBuilder.get_slot_name(player_name, game_name, total_games, custom_tag)

	var user_profile: String = OS.get_environment("USERPROFILE").replace("\\", "/")
	var local_appdata: String = OS.get_environment("LOCALAPPDATA").replace("\\", "/")
	var appdata_locallow: String = (OS.get_environment("USERPROFILE") + "/AppData/LocalLow").replace("\\", "/")
	var appdata_roaming: String = OS.get_environment("APPDATA").replace("\\", "/")

	var context: Dictionary = {
		"player_name": player_name,
		"slot_name": slot_name,
		"server_url": server_url,
		"server_clean_url": server_clean_url,
		"server_host": server_host,
		"server_port": server_port,
		"room_code": NetworkManager.room_code,
		"patch_path": ProjectSettings.globalize_path(patch_path) if patch_path != "" else "",
		"rom_path": ProjectSettings.globalize_path(rom_path) if rom_path != "" else "",
		"game_path": ProjectSettings.globalize_path(game_path) if game_path != "" else "",
		"game_dir": ProjectSettings.globalize_path(game_path.get_base_dir()) if game_path != "" else "",
		"user_profile": user_profile,
		"local_appdata": local_appdata,
		"appdata_locallow": appdata_locallow,
		"appdata_roaming": appdata_roaming,
		"user_tools_dir": ProjectSettings.globalize_path(USER_TOOLS_DIR),
		"user_saves_dir": ProjectSettings.globalize_path(USER_SAVES_DIR)
	}
	return context

func apply_config_writer(preset_config: Dictionary, context: Dictionary) -> bool:
	return _config_writer_service.apply(preset_config, context)

func _merge_and_interpolate_json(base: Dictionary, updates: Dictionary, context: Dictionary) -> Dictionary:
	return LauncherUtils.merge_and_interpolate_json(base, updates, context)

func launch_process_with_logging(node: Node, executable_path: String, args: Array, tag: String = "Client") -> int:
	return _process_launcher.launch(node, executable_path, args, tag)

func _read_pipe_logs(stdout_pipe: FileAccess, stderr_pipe: FileAccess, tag: String) -> void:
	_process_launcher._read_pipe_logs(stdout_pipe, stderr_pipe, tag)

func inject_server_into_ap_patch(patch_path: String, clean_url: String) -> void:
	ArchipelagoConfig.inject_server_into_ap_patch(patch_path, clean_url)

func update_archipelago_persistent_storage(clean_url: String) -> void:
	ArchipelagoConfig.update_archipelago_persistent_storage(clean_url, USER_TOOLS_DIR)

# =====================================================================
#             STREAMLINED ASYNC LAUNCH PIPELINE
# =====================================================================

func _report_status(ctx: LaunchContext, stage: LaunchStage, message: String, pct: float) -> void:
	Updater.log_message("LAUNCH", "[" + str(stage) + " - " + str(int(pct)) + "%] " + message)
	emit_signal("launch_status_updated", int(stage), message, pct)
	if is_instance_valid(ctx.node):
		_update_modding_status(ctx.node, message, int(pct))

func launch_game(node: Node, game_name: String) -> bool:
	Updater.log_message("LAUNCH", "Initiating launch pipeline for game: " + game_name)
	if game_name.strip_edges() == "":
		var err_msg: String = "Game name cannot be empty."
		Updater.log_message("ERROR", err_msg)
		emit_signal("launch_failed", game_name, err_msg)
		if is_instance_valid(node):
			_update_modding_status(node, err_msg, 0)
		return false

	var preset: Dictionary = get_preset(game_name)
	if preset.is_empty():
		var err_msg: String = "No preset configuration found for " + game_name
		Updater.log_message("ERROR", err_msg)
		emit_signal("launch_failed", game_name, err_msg)
		if is_instance_valid(node):
			_update_modding_status(node, err_msg, 0)
		return false
		
	var ctx: LaunchContext = LaunchContext.new(game_name, preset, node)
	_report_status(ctx, LaunchStage.INITIALIZING, "Preparing " + game_name + "...", 5)
	
	if not await _pipeline_prepare_base_assets(ctx):
		return false
	if not await _pipeline_prepare_tools(ctx):
		return false
	if not await _pipeline_prepare_firmware(ctx):
		return false
	if not await _pipeline_prepare_session_payload(ctx):
		return false
	if not await _pipeline_sync_environment(ctx):
		return false
	if not await _pipeline_spawn_process(ctx):
		return false
	await _pipeline_monitor_post_launch(ctx)
	
	emit_signal("launch_completed", game_name, ctx.process_id)
	return true

func _pipeline_prepare_base_assets(ctx: LaunchContext) -> bool:
	_report_status(ctx, LaunchStage.PREPARING_ROM, "Verifying game assets for " + ctx.game_name + "...", 15)
	var req_rom: String = ctx.preset.get("required_rom", "")
	var is_rom_game: bool = (req_rom != "" or ctx.launch_mode in ["ap_client", "patch_rom"])
	
	if is_rom_game and req_rom != "":
		_report_status(ctx, LaunchStage.PREPARING_ROM, "Verifying base ROM: " + req_rom + "...", 15)
		
		# 1. Check paths_config via get_saved_path
		var stored_path: String = get_saved_path(ctx.game_name, ctx.preset)
		if stored_path != "" and FileAccess.file_exists(stored_path) and not stored_path.to_lower().ends_with(".exe"):
			ctx.base_rom_path = stored_path
			return true
			
		# 2. Check local games folder or legacy locations
		var found_rom: String = find_existing_base_rom(req_rom)
		if found_rom != "":
			ctx.base_rom_path = found_rom
			paths_config[ctx.game_name] = found_rom
			save_paths_config()
			return true
			
		# 3. Check automated download in roms_catalog
		var dl_entry: Dictionary = get_rom_download_entry(req_rom)
		if dl_entry.is_empty():
			dl_entry = get_rom_download_entry(ctx.game_name)
		if not dl_entry.is_empty() and dl_entry.get("url", "") != "":
			_report_status(ctx, LaunchStage.PREPARING_ROM, "Downloading base ROM for " + ctx.game_name + "...", 20)
			var rom_res: Dictionary = await _async_ensure_rom(ctx.node, req_rom)
			if rom_res.get("success", false) and rom_res.get("path", "") != "":
				ctx.base_rom_path = rom_res.get("path")
				paths_config[ctx.game_name] = ctx.base_rom_path
				save_paths_config()
				return true
				
		# 4. Prompt user to select file
		_report_status(ctx, LaunchStage.PREPARING_ROM, "Base ROM required: " + req_rom, 15)
		var comp = AsyncCompletion.new()
		var filters: PackedStringArray = PackedStringArray(["*.bin, *.iso, *.cue, *.gba, *.smc, *.sfc, *.z64, *.n64 ; ROM Files", "*.* ; All Files"])
		emit_signal("prompt_file_selection", "Base ROM Required for " + ctx.game_name, "Please select your vanilla base ROM file (" + req_rom + ").", filters, func(chosen: String):
			comp.finish(chosen != "", chosen)
		)
		await comp.wait_completed(ctx.node)
		var user_selected_path: String = comp.val
		if user_selected_path == "" or not FileAccess.file_exists(user_selected_path):
			emit_signal("launch_failed", ctx.game_name, "Base ROM selection was cancelled or file does not exist.")
			return false
			
		var game_dir: String = get_game_dir(ctx.game_name)
		var target_dest: String = game_dir.path_join(req_rom)
		if user_selected_path != target_dest:
			var copy_err: Error = DirAccess.copy_absolute(user_selected_path, target_dest)
			ctx.base_rom_path = target_dest if copy_err == OK else user_selected_path
		else:
			ctx.base_rom_path = user_selected_path
		paths_config[ctx.game_name] = ctx.base_rom_path
		save_paths_config()
		return true

	else:
		# Direct executable game
		var stored_exe: String = get_saved_path(ctx.game_name, ctx.preset)
		if stored_exe != "" and FileAccess.file_exists(stored_exe):
			ctx.base_rom_path = stored_exe
			return true
			
		var exec_name: String = ctx.preset.get("client_executable", ctx.preset.get("executable_name", ""))
		var sub_folders: Array = ctx.preset.get("sub_folders", [])
		var aliases: Array = ctx.preset.get("executable_aliases", [])
		if exec_name != "" or not aliases.is_empty():
			var discovered: String = find_game_executable(exec_name, sub_folders, aliases, true)
			if discovered != "":
				ctx.base_rom_path = discovered
				paths_config[ctx.game_name] = discovered
				save_paths_config()
				return true
				
		# Check if download link is available in roms_catalog for PC game
		var pc_dl_entry: Dictionary = get_rom_download_entry(ctx.game_name)
		if pc_dl_entry.is_empty() and exec_name != "":
			pc_dl_entry = get_rom_download_entry(exec_name)
		for a in aliases:
			if pc_dl_entry.is_empty():
				pc_dl_entry = get_rom_download_entry(str(a))
			else:
				break
		if not pc_dl_entry.is_empty() and pc_dl_entry.get("url", "") != "":
			_report_status(ctx, LaunchStage.PREPARING_ROM, "Downloading PC game files for " + ctx.game_name + "...", 20)
			var pc_res: Dictionary = await _async_ensure_pc_game(ctx.node, ctx.game_name, ctx.preset)
			if pc_res.get("success", false) and pc_res.get("path", "") != "":
				ctx.base_rom_path = pc_res.get("path")
				paths_config[ctx.game_name] = ctx.base_rom_path
				save_paths_config()
				return true
				
		# Prompt executable selection
		var comp = AsyncCompletion.new()
		var filters: PackedStringArray = PackedStringArray(["*.exe ; Executables", "*.* ; All Files"])
		emit_signal("prompt_file_selection", "Executable Required for " + ctx.game_name, "Please locate where " + ctx.game_name + " is installed.", filters, func(chosen: String):
			comp.finish(chosen != "", chosen)
		)
		await comp.wait_completed(ctx.node)
		var user_exe: String = comp.val
		if user_exe == "" or not FileAccess.file_exists(user_exe):
			emit_signal("launch_failed", ctx.game_name, "Executable selection was cancelled or file does not exist.")
			return false
		ctx.base_rom_path = user_exe
		paths_config[ctx.game_name] = user_exe
		save_paths_config()
		return true

func _pipeline_prepare_tools(ctx: LaunchContext) -> bool:
	_report_status(ctx, LaunchStage.PREPARING_TOOLS, "Preparing tools and dependencies...", 30)
	# Client Tool (e.g. Archipelago Launcher)
	var client_tool_key: String = ctx.preset.get("client_tool", "")
	if client_tool_key != "":
		_report_status(ctx, LaunchStage.PREPARING_TOOLS, "Verifying client tool...", 30)
		var client_tool: Dictionary = launcher_tools.get(client_tool_key, {})
		var client_path: String = _resolve_tool_path(client_tool_key, client_tool)
		if client_path != "":
			ctx.client_exe_path = client_path
		else:
			var c_url: String = client_tool.get("download_url", DEFAULT_ARCHIPELAGO_DOWNLOAD_URL)
			var c_fallback: String = client_tool.get("fallback_download_url", DEFAULT_ARCHIPELAGO_FALLBACK_URL)
			var subs_arr: Array = client_tool.get("sub_folders", ["Archipelago"])
			var c_sub: String = subs_arr[0] if not subs_arr.is_empty() else "Archipelago"
			var c_exe: String = client_tool.get("executable", "ArchipelagoLauncher.exe")
			var tool_res: Dictionary = await _async_ensure_tool(ctx.node, client_tool.get("name", "Archipelago Client"), c_url, c_sub, c_exe, c_fallback)
			if tool_res.get("success", false) and tool_res.get("path", "") != "":
				ctx.client_exe_path = tool_res.get("path")
				paths_config[client_tool_key] = ctx.client_exe_path
				save_paths_config()
			else:
				var detail: String = tool_res.get("error", "Unknown error")
				emit_signal("launch_failed", ctx.game_name, "Failed to install client tool (" + client_tool_key + "): " + detail)
				return false
				
	# Emulator Tool (e.g. BizHawk / SNES9x)
	var emu_tool_key: String = ctx.preset.get("emulator_tool", "")
	if emu_tool_key != "":
		_report_status(ctx, LaunchStage.PREPARING_TOOLS, "Verifying emulator...", 40)
		var emu_tool: Dictionary = launcher_tools.get(emu_tool_key, {})
		var emu_cfg_key: String = emu_tool_key + "_emulator"
		var emu_path: String = _resolve_tool_path(emu_tool_key, emu_tool, emu_cfg_key)
		if emu_path != "":
			ctx.emulator_exe_path = emu_path
		else:
			var e_url: String = emu_tool.get("download_url", "")
			var e_fallback: String = emu_tool.get("fallback_download_url", "")
			var e_subs_arr: Array = emu_tool.get("sub_folders", ["BizHawk"])
			var e_sub: String = e_subs_arr[0] if not e_subs_arr.is_empty() else "BizHawk"
			var e_exe: String = emu_tool.get("executable", "EmuHawk.exe")
			var emu_res: Dictionary = await _async_ensure_tool(ctx.node, emu_tool.get("name", "Emulator"), e_url, e_sub, e_exe, e_fallback)
			if emu_res.get("success", false) and emu_res.get("path", "") != "":
				ctx.emulator_exe_path = emu_res.get("path")
				paths_config[emu_cfg_key] = ctx.emulator_exe_path
				save_paths_config()
			else:
				var detail: String = emu_res.get("error", "Unknown error")
				emit_signal("launch_failed", ctx.game_name, "Failed to install emulator (" + emu_tool_key + "): " + detail)
				return false
				
	# 1. Declarative Steam Beta Requirement Check (Agnostic)
	if ctx.preset.has("required_steam_beta"):
		var steam_id: String = str(ctx.preset.get("steam_appid", "")).strip_edges()
		var beta_cfg: Dictionary = ctx.preset.get("required_steam_beta", {})
		if steam_id != "" and not beta_cfg.is_empty():
			var steam_res: Dictionary = LauncherUtils.check_steam_beta_status(ctx.base_rom_path, steam_id, beta_cfg, ctx.game_name)
			if steam_res.get("needs_downgrade", false):
				var target_branch: String = steam_res.get("target_beta", "required")
				emit_signal("launch_failed", ctx.game_name, ctx.game_name + " must be set to the " + target_branch + " Steam Beta branch before launching.")
				return false

	# 2. Declarative Mod File Activation Check (Agnostic)
	if ctx.preset.has("mod_activation"):
		var act_cfg: Dictionary = ctx.preset.get("mod_activation", {})
		if not act_cfg.is_empty() and act_cfg.get("auto_activate", true):
			var act_info: Dictionary = LauncherUtils.check_mod_activation_status(ctx.base_rom_path, act_cfg)
			if act_info.get("state", "") == "disabled_in_lumafly":
				_report_status(ctx, LaunchStage.PREPARING_TOOLS, "Activating modded game files...", 35)
				LauncherUtils.activate_mod_file(ctx.base_rom_path, act_cfg)

	# Custom Mod Packages (e.g. Modding API, Archipelago Mods)
	var packages: Array = _get_preset_packages(ctx.preset)
	var packages_installed: bool = false
	if not packages.is_empty() and ctx.base_rom_path != "":
		var game_dir: String = ctx.base_rom_path.get_base_dir()
		for pkg_idx in range(packages.size()):
			var pkg = packages[pkg_idx]
			if pkg is Dictionary:
				var check_rel: String = pkg.get("check_file", "")
				var needs_install: bool = false
				if check_rel != "":
					var full_check: String = game_dir.path_join(check_rel)
					if not FileAccess.file_exists(full_check):
						needs_install = true
				var pkg_url: String = pkg.get("download_url", "")
				if needs_install and pkg_url != "":
					var resolved_url: String = pkg_url.replace("{backend_url}", NetworkManager.get_http_url())
					if resolved_url.begins_with("http://localhost:8080"):
						resolved_url = resolved_url.replace("http://localhost:8080", NetworkManager.get_http_url())
					var pkg_name: String = pkg.get("name", "Package " + str(pkg_idx + 1))
					var target_rel: String = pkg.get("extract_target", "")
					var target_extract_dir: String = game_dir if target_rel == "" else game_dir.path_join(target_rel)
					var backups: Array = pkg.get("backup_files", [])
					_report_status(ctx, LaunchStage.PREPARING_TOOLS, "Installing " + pkg_name + "...", 42)
					var pkg_res: Dictionary = await _async_download_package(ctx.node, resolved_url, target_extract_dir, pkg_name, backups)
					if not pkg_res.get("success", false):
						emit_signal("launch_failed", ctx.game_name, "Failed to install " + pkg_name + ": " + pkg_res.get("error", ""))
						return false
					packages_installed = true
						

		if packages_installed and ctx.preset.has("mod_importer"):
			var imp_cfg: Dictionary = ctx.preset.get("mod_importer", {})
			var imp_rel: String = imp_cfg.get("executable", "Content/modimporter.exe")
			var full_imp_path: String = game_dir.path_join(imp_rel)
			if FileAccess.file_exists(full_imp_path):
				_report_status(ctx, LaunchStage.PREPARING_TOOLS, "Importing mods via ModImporter...", 48)
				var imp_dir: String = full_imp_path.get_base_dir()
				var cmd_str: String = "cd /d \"" + ProjectSettings.globalize_path(imp_dir) + "\" && echo. | \"" + ProjectSettings.globalize_path(full_imp_path) + "\""
				print("[Launcher] Running ModImporter: ", cmd_str)
				OS.execute("cmd.exe", ["/c", cmd_str], [], true)

	# 3. RVZ decompression if ROM is RVZ or target ISO requires RVZ conversion
	var is_dolphin_game: bool = ctx.preset.get("emulator_tool", "") == "dolphin"
	var req_rom_name: String = ctx.preset.get("required_rom", "")
	var base_is_rvz: bool = ctx.base_rom_path.to_lower().ends_with(".rvz")
	if is_dolphin_game and (base_is_rvz or req_rom_name.to_lower().ends_with(".iso")):
		var target_iso_name: String = req_rom_name if req_rom_name.to_lower().ends_with(".iso") else ctx.base_rom_path.get_file().get_basename() + ".iso"
		var game_dir: String = get_game_dir(ctx.game_name)
		var target_iso_path: String = game_dir.path_join(target_iso_name)
		
		if not FileAccess.file_exists(target_iso_path):
			var source_rvz: String = ctx.base_rom_path if base_is_rvz else ""
			if source_rvz == "":
				var rvz_candidate: String = find_existing_base_rom(target_iso_name.get_basename() + ".rvz")
				if rvz_candidate != "":
					source_rvz = rvz_candidate
			if source_rvz != "":
				var dolphin_tool: String = _find_dolphin_tool_path(ctx.emulator_exe_path)
				if dolphin_tool != "":
					_report_status(ctx, LaunchStage.PREPARING_ROM, "Decompressing RVZ to vanilla ISO...", 45)
					var conv_res: Dictionary = convert_rvz_to_iso(source_rvz, target_iso_path, dolphin_tool, true)
					if not conv_res.get("success", false):
						emit_signal("launch_failed", ctx.game_name, conv_res.get("error", "RVZ decompression failed."))
						return false
					ctx.base_rom_path = target_iso_path
					paths_config[ctx.game_name] = target_iso_path
					save_paths_config()
				else:
					print("[Launcher Warning] Found RVZ ( " + source_rvz + " ) but DolphinTool.exe not found to extract ISO.")
		elif base_is_rvz:
			var global_user_dir: String = ProjectSettings.globalize_path("user://").replace("\\", "/").trim_suffix("/")
			var global_base: String = ProjectSettings.globalize_path(ctx.base_rom_path).replace("\\", "/")
			if ctx.base_rom_path.begins_with("user://") or global_base.begins_with(global_user_dir):
				DirAccess.remove_absolute(ctx.base_rom_path)
				print("[Launcher] Removed redundant RVZ since ISO already exists: ", ctx.base_rom_path)
			ctx.base_rom_path = target_iso_path
			paths_config[ctx.game_name] = target_iso_path
			save_paths_config()

	return true


func _find_dolphin_tool_path(dolphin_exe_path: String) -> String:
	return _rom_archive_service.find_dolphin_tool_path(dolphin_exe_path)

func convert_rvz_to_iso(rvz_path: String, output_iso_path: String, dolphin_tool_path: String, delete_source: bool = false) -> Dictionary:
	return _rom_archive_service.convert_rvz_to_iso(rvz_path, output_iso_path, dolphin_tool_path, delete_source)

func _pipeline_prepare_firmware(ctx: LaunchContext) -> bool:
	if not ctx.preset.has("required_firmware") or ctx.emulator_exe_path == "":
		return true
	_report_status(ctx, LaunchStage.PREPARING_FIRMWARE, "Configuring emulator firmware & BIOS...", 50)
	var fw_ok: bool = await _async_ensure_firmware(ctx.node, ctx.preset, ctx.emulator_exe_path, ctx.base_rom_path)
	if not fw_ok:
		print("[Launcher Warning] Firmware setup returned false; proceeding with launch.")
	return true

func _pipeline_prepare_session_payload(ctx: LaunchContext) -> bool:
	if ctx.launch_mode in ["ap_client", "patch_rom", "native_cli"]:
		var patch_ext: String = ctx.preset.get("patch_extension", "")
		if patch_ext != "":
			_report_status(ctx, LaunchStage.FETCHING_PATCH, "Retrieving multiworld seed patch...", 65)
			var patch_res: Dictionary = await _async_ensure_patch(ctx.node, ctx.game_name, patch_ext)
			if not patch_res.get("success", false) or patch_res.get("path", "") == "":
				emit_signal("launch_failed", ctx.game_name, "Could not retrieve seed patch: " + patch_res.get("error", ""))
				return false
			ctx.patch_path = patch_res.get("path")
		
		# Server connection URL
		var ap_url: String = NetworkManager.get_ap_server_url()
		var clean_url: String = ServerUrlHelper.format_ap_address(ap_url, "localhost:38000")
		ctx.server_url = clean_url
		DisplayServer.clipboard_set(clean_url)
		
		if ctx.launch_mode == "ap_client":
			inject_server_into_ap_patch(ctx.patch_path, clean_url)
			update_archipelago_persistent_storage(clean_url)
			
			var req_audio: String = ctx.preset.get("required_audio_rom", "")
			if req_audio != "":
				var patch_dir: String = ctx.patch_path.get_base_dir()
				var patch_audio_dest: String = patch_dir.path_join(req_audio)
				if not FileAccess.file_exists(patch_audio_dest):
					var t2_src: String = ArchipelagoConfig.find_supplemental_rom_path("", req_audio)
					if t2_src != "":
						DirAccess.copy_absolute(t2_src, patch_audio_dest)
						print("[Launcher] Copied required audio track to patch folder: ", patch_audio_dest)
	return true

func _pipeline_sync_environment(ctx: LaunchContext) -> bool:
	_report_status(ctx, LaunchStage.SYNCING_CONFIG, "Syncing configuration...", 78)
	if ctx.preset.has("host_yaml") or ctx.launch_mode == "ap_client":
		sync_custom_worlds_to_archipelago()
		var is_dolphin_emu = ctx.preset.get("emulator_tool", "") == "dolphin"
		var b_path = "" if is_dolphin_emu else ctx.emulator_exe_path
		var d_path = ctx.emulator_exe_path if is_dolphin_emu else ""
		sync_archipelago_host_yaml(ctx.base_rom_path, b_path, d_path, ctx.server_url)
	if ctx.launch_mode in ["direct", "mod_injector"]:
		var total_games: int = 1
		if is_instance_valid(ctx.node) and "local_selected_games" in ctx.node and not ctx.node.local_selected_games.is_empty():
			total_games = ctx.node.local_selected_games.size()
		var context: Dictionary = build_launch_context(ctx.base_rom_path, "", "", ctx.game_name, total_games)
		apply_config_writer(ctx.preset, context)
	return true

func _pipeline_spawn_process(ctx: LaunchContext) -> bool:
	_report_status(ctx, LaunchStage.SPAWNING_PROCESS, "Starting game process...", 88)
	if ctx.launch_mode == "ap_client":
		var launch_args: Array = []
		if ctx.patch_path != "":
			launch_args.append(ProjectSettings.globalize_path(ctx.patch_path))
		elif ctx.preset.get("client_component", "") != "":
			launch_args.append(ctx.preset.get("client_component"))
		if ctx.preset.get("auto_connect", false) and ctx.server_url != "":
			launch_args.append("--")
			launch_args.append("--connect")
			launch_args.append(ctx.server_url)
			
		var target_client: String = ctx.client_exe_path
		if target_client != "" and FileAccess.file_exists(target_client):
			var abs_client: String = ProjectSettings.globalize_path(target_client)
			print("[Launcher] Spawning Archipelago with patch: ", abs_client, " args: ", launch_args)
			ctx.process_id = OS.create_process(abs_client, launch_args)
		else:
			if ctx.patch_path != "":
				var global_patch_path: String = ProjectSettings.globalize_path(ctx.patch_path)
				print("[Launcher] Opening patch file directly via OS: ", global_patch_path)
				var shell_err = OS.shell_open(global_patch_path)
				if shell_err == OK:
					ctx.process_id = 1
				
		if ctx.process_id <= 0:
			emit_signal("launch_failed", ctx.game_name, "Failed to spawn Archipelago process: " + target_client)
			return false
		print("[Launcher] Archipelago Client spawned successfully (PID: ", ctx.process_id, ")")
		if ctx.preset.get("auto_launch_emulator", false) or ctx.preset.get("client_component", "") == "SNI Client":
			_spawn_sni_emulator_companion(ctx)
		return true

	elif ctx.launch_mode in ["direct", "steam", "mod_injector"]:
		var abs_game_path: String = ProjectSettings.globalize_path(ctx.base_rom_path)
		var steam_appid: String = str(ctx.preset.get("steam_appid", "")).strip_edges()
		if steam_appid != "":
			var appid_path: String = abs_game_path.get_base_dir().path_join("steam_appid.txt")
			if not FileAccess.file_exists(appid_path):
				var fa: FileAccess = FileAccess.open(appid_path, FileAccess.WRITE)
				if fa:
					fa.store_string(steam_appid)
					fa.close()
			OS.set_environment("SteamAppId", steam_appid)
			OS.set_environment("SteamGameId", steam_appid)

		var prefer_steam: bool = ctx.preset.get("prefer_steam_protocol", false) or ctx.launch_mode == "steam"
		var is_steam_path: bool = abs_game_path.to_lower().contains("steamapps") or abs_game_path.to_lower().contains("steam")
		if steam_appid != "" and (ctx.launch_mode == "steam" or (prefer_steam and is_steam_path)):
			print("[Launcher] Launching via Steam protocol: steam://rungameid/", steam_appid)
			OS.shell_open("steam://rungameid/" + steam_appid)
			ctx.process_id = 1
			_spawn_companion_client_tool_if_needed(ctx)
			return true

		var total_games: int = 1
		if is_instance_valid(ctx.node) and "local_selected_games" in ctx.node and not ctx.node.local_selected_games.is_empty():
			total_games = ctx.node.local_selected_games.size()
		var context: Dictionary = build_launch_context(abs_game_path, "", "", ctx.game_name, total_games)
		var custom_args: Array = []
		if ctx.preset.has("cli") and ctx.preset["cli"] is Dictionary:
			var cli_cfg: Dictionary = ctx.preset["cli"]
			if cli_cfg.has("environment_variables") and cli_cfg["environment_variables"] is Dictionary:
				var envs: Dictionary = cli_cfg["environment_variables"]
				for env_k in envs.keys():
					OS.set_environment(str(env_k), interpolate_template(str(envs[env_k]), context))
			for arg in cli_cfg.get("args_template", []):
				custom_args.append(interpolate_template(str(arg), context))

		ctx.process_id = launch_process_with_logging(ctx.node, abs_game_path, custom_args, ctx.game_name)
		if ctx.process_id <= 0:
			emit_signal("launch_failed", ctx.game_name, "Failed to launch game executable: " + abs_game_path)
			return false
		_spawn_companion_client_tool_if_needed(ctx)
		return true

	elif ctx.launch_mode == "patch_rom":
		var abs_emu: String = ProjectSettings.globalize_path(ctx.emulator_exe_path)
		var abs_patch: String = ProjectSettings.globalize_path(ctx.patch_path)
		print("[Launcher] Spawning emulator: ", abs_emu, " with ROM patch: ", abs_patch)
		ctx.process_id = OS.create_process(abs_emu, [abs_patch])
		if ctx.process_id <= 0:
			emit_signal("launch_failed", ctx.game_name, "Failed to launch emulator: " + abs_emu)
			return false
		return true

	elif ctx.launch_mode == "native_cli":
		var abs_native: String = ProjectSettings.globalize_path(ctx.base_rom_path)
		var final_args: Array = []
		var context: Dictionary = build_launch_context(abs_native, ctx.patch_path)
		if ctx.preset.has("cli") and ctx.preset["cli"] is Dictionary:
			var cli_cfg: Dictionary = ctx.preset["cli"]
			if cli_cfg.has("environment_variables") and cli_cfg["environment_variables"] is Dictionary:
				var envs: Dictionary = cli_cfg["environment_variables"]
				for env_k in envs.keys():
					OS.set_environment(str(env_k), interpolate_template(str(envs[env_k]), context))
			for arg_item in cli_cfg.get("args_template", []):
				final_args.append(interpolate_template(str(arg_item), context))
			if ctx.patch_path != "" and cli_cfg.has("patch_arg"):
				final_args.append(cli_cfg["patch_arg"])
				final_args.append(ProjectSettings.globalize_path(ctx.patch_path))
		else:
			if ctx.patch_path != "":
				final_args.append(ProjectSettings.globalize_path(ctx.patch_path))
		ctx.process_id = OS.create_process(abs_native, final_args)
		if ctx.process_id <= 0:
			ctx.process_id = launch_process_with_logging(ctx.node, abs_native, final_args, ctx.game_name)
		if ctx.process_id <= 0:
			emit_signal("launch_failed", ctx.game_name, "Failed to spawn native CLI process: " + abs_native)
			return false
		return true

	return false

func _pipeline_monitor_post_launch(ctx: LaunchContext) -> void:
	var tracking_cfg: Dictionary = ctx.preset.get("patch_progress_tracking", {})
	var has_tracking: bool = not tracking_cfg.is_empty()
	if has_tracking and ctx.patch_path != "":
		var custom_msg: String = tracking_cfg.get("status_message", "Modding game files...\nPlease wait...")
		_report_status(ctx, LaunchStage.MODDING_DISC, custom_msg, 50)
		await _track_client_modding_and_finish(ctx.node, ctx.patch_path, true, tracking_cfg)
	else:
		_report_status(ctx, LaunchStage.COMPLETED, "Game launched successfully!", 100)
		if is_instance_valid(ctx.node) and ctx.node.get_tree():
			await ctx.node.get_tree().create_timer(0.8).timeout
		_dismiss_modding_overlay(ctx.node)

func _async_ensure_rom(node: Node, rom_name: String, force_redownload: bool = false) -> Dictionary:
	return await ensure_rom_exists_or_download(node, rom_name, Callable(), force_redownload)

func _async_ensure_pc_game(node: Node, game_name: String, preset_config: Dictionary) -> Dictionary:
	return await ensure_pc_game_installed(node, game_name, preset_config)

func _async_ensure_tool(node: Node, tool_name: String, download_url: String, subfolder: String, target_file: String, fallback_url: String = "") -> Dictionary:
	_tool_installation_generation += 1
	var request = _tool_manager.create_install_request(
		node,
		tool_name,
		download_url,
		subfolder,
		target_file,
		fallback_url,
		_tool_installation_generation
	)
	return await ensure_tool_installed_or_download(node, tool_name, download_url, subfolder, target_file, Callable(), request.fallback_url, request.generation)

func _async_ensure_firmware(node: Node, preset: Dictionary, emu_path: String, rom_path: String) -> bool:
	var res: Dictionary = await ensure_emulator_firmware(node, preset, emu_path, rom_path)
	return res.get("success", false)

func _async_ensure_patch(node: Node, game_name: String, patch_ext: String) -> Dictionary:
	return await ensure_patch_file_exists_or_download(node, game_name, patch_ext)

func _async_download_package(node: Node, url: String, target_dir: String, label: String, backups: Array) -> Dictionary:
	return await download_and_extract_zip_to_dir(node, url, target_dir, label, Callable(), backups)

func _get_preset_packages(preset_config: Dictionary) -> Array:
	return _tool_manager.get_preset_packages(preset_config)

func _resolve_tool_path(tool_key: String, tool_def: Dictionary, fallback_cfg_key: String = "") -> String:
	return _tool_manager.resolve_path(tool_key, tool_def, fallback_cfg_key)

func execute_preset_launch(node: Node, game_name: String, preset_config: Dictionary, game_path: String, active_launch_game: String) -> void:
	var effective_game: String = game_name if game_name != "" else active_launch_game
	if game_path != "" and effective_game != "":
		paths_config[effective_game] = game_path
		save_paths_config()
	launch_game(node, effective_game)


# =====================================================================
#                GAME LAUNCH STATUS & DETECTION
# =====================================================================

func get_game_launch_status(game_name: String) -> Dictionary:
	var preset: Dictionary = get_preset(game_name)
	var launch_mode: String = preset.get("launch_mode", "direct")
	var req_rom: String = preset.get("required_rom", "")
	var is_rom_game: bool = (req_rom != "" or launch_mode == "patch_rom" or preset.get("is_rom", false))

	var stored_path: String = get_saved_path(game_name, preset)

	if stored_path != "" and FileAccess.file_exists(stored_path):
		var is_invalid_for_rom: bool = is_rom_game and (stored_path.to_lower().ends_with(".exe"))
		if not is_invalid_for_rom:
			if not paths_config.has(game_name) or paths_config[game_name] != stored_path:
				paths_config[game_name] = stored_path
				save_paths_config()
			if preset.has("required_steam_beta"):
				var steam_id: String = str(preset.get("steam_appid", "")).strip_edges()
				var beta_cfg: Dictionary = preset.get("required_steam_beta", {})
				if steam_id != "" and not beta_cfg.is_empty():
					var steam_res: Dictionary = LauncherUtils.check_steam_beta_status(stored_path, steam_id, beta_cfg, game_name)
					if steam_res.get("needs_downgrade", false):
						return {
							"is_configured": false,
							"path": stored_path,
							"is_default_location": false,
							"status_text": "⚠️ Steam Beta Required",
							"status_color": Color(0.95, 0.65, 0.15),
							"steam_beta_status": steam_res
						}
			return {
				"is_configured": true,
				"path": stored_path,
				"is_default_location": false,
				"status_text": "● Configured",
				"status_color": Color(0.2, 0.85, 0.45)
			}
	
	if not is_rom_game:
		var target_exe: String = preset.get("default_executable", preset.get("client_executable", preset.get("executable_name", preset.get("target_exe", ""))))
		var sub_folders: Array = preset.get("common_folders", preset.get("sub_folders", []))
		var aliases: Array = preset.get("executable_aliases", [])
		if target_exe != "" or not aliases.is_empty():
			# Fast direct candidate check only - do not deep search during status queries
			var found_exe: String = find_game_executable(target_exe, sub_folders, aliases, false)
			if found_exe != "" and FileAccess.file_exists(found_exe):
				paths_config[game_name] = found_exe
				save_paths_config()
			if preset.has("required_steam_beta"):
				var steam_id: String = str(preset.get("steam_appid", "")).strip_edges()
				var beta_cfg: Dictionary = preset.get("required_steam_beta", {})
				if steam_id != "" and not beta_cfg.is_empty():
					var steam_res: Dictionary = LauncherUtils.check_steam_beta_status(found_exe, steam_id, beta_cfg, game_name)
					if steam_res.get("needs_downgrade", false):
						return {
							"is_configured": false,
							"path": found_exe,
							"is_default_location": true,
							"status_text": "⚠️ Steam Beta Required",
							"status_color": Color(0.95, 0.65, 0.15),
							"steam_beta_status": steam_res
						}
				return {
					"is_configured": true,
					"path": found_exe,
					"is_default_location": true,
					"status_text": "● Installed (Auto-Detected)",
					"status_color": Color(0.2, 0.85, 0.45)
				}
	else:
		if req_rom != "":
			var found_rom: String = find_existing_base_rom(req_rom)
			if found_rom != "" and FileAccess.file_exists(found_rom):
				paths_config[game_name] = found_rom
				save_paths_config()
				return {
					"is_configured": true,
					"path": found_rom,
					"is_default_location": true,
					"status_text": "● ROM Ready (Auto-Detected)",
					"status_color": Color(0.2, 0.85, 0.45)
				}
				
	var dl_check: Dictionary = get_rom_download_entry(game_name)
	if dl_check.is_empty() and req_rom != "":
		dl_check = get_rom_download_entry(req_rom)
	if not dl_check.is_empty() and dl_check.get("url", "") != "":
		return {
			"is_configured": false,
			"path": "",
			"is_default_location": false,
			"status_text": "○ Download Available",
			"status_color": Color(0.2, 0.75, 1.0)
		}

	return {
		"is_configured": false,
		"path": "",
		"is_default_location": false,
		"status_text": "○ Setup / Path Required",
		"status_color": Color(0.9, 0.6, 0.15)
	}

func is_game_configured(game_name: String) -> bool:
	return get_game_launch_status(game_name).get("is_configured", false)


# =====================================================================
#                PATCH FILE DOWNLOAD & DISCOVERY
# =====================================================================

func is_matching_patch_file(filename: String, patch_extension: String, game_name: String = "") -> bool:
	return _patch_manager.is_matching_file(filename, patch_extension, game_name)

func ensure_patch_file_exists_or_download(node: Node, active_launch_game: String, patch_extension: String, callback: Callable = Callable()) -> Dictionary:
	var comp = AsyncCompletion.new()
	var internal_cb = func(ok: bool, val: String):
		if callback.is_valid():
			callback.call(ok, val)
		comp.finish(ok, val)

	_patch_manager.ensure(node, active_launch_game, patch_extension, internal_cb)
	await comp.wait_completed(node)
	return {"success": comp.ok, "path": comp.val if comp.ok else "", "error": comp.val if not comp.ok else ""}

func fallback_download_seed_zip(node: Node, active_launch_game: String, patch_extension: String, callback: Callable) -> void:
	_patch_manager.fallback(node, active_launch_game, patch_extension, callback)
# =====================================================================
#             MODDING STATUS & PROGRESS TRACKING
# =====================================================================

func _update_modding_status(_node: Node = null, message: String = "", pct: int = 0) -> void:
	modding_status_updated.emit(message, pct)

func _dismiss_modding_overlay(_node: Node = null) -> void:
	overlay_dismiss_requested.emit()

func _check_extension_exists_in_dir(dir_path: String, target_ext: String) -> bool:
	var da: DirAccess = DirAccess.open(dir_path)
	if not da:
		da = DirAccess.open(ProjectSettings.globalize_path(dir_path))
	if not da:
		return false
	da.list_dir_begin()
	var f: String = da.get_next()
	var ext_lower: String = target_ext.to_lower()
	while f != "":
		if not da.current_is_dir() and f.to_lower().ends_with(ext_lower):
			return true
		f = da.get_next()
	return false

func _track_client_modding_and_finish(node: Node, patch_path: String, has_tracking: bool, tracking_cfg: Dictionary = {}) -> void:
	if not has_tracking:
		if is_instance_valid(node) and node.get_tree():
			await node.get_tree().create_timer(1.2).timeout
		_dismiss_modding_overlay(node)
		return
		
	var patch_base: String = patch_path.get_basename()
	var comp_ext: String = tracking_cfg.get("completion_extension", "")
	var prog_ext: String = tracking_cfg.get("progress_extension", "")
	var exp_bytes: float = float(tracking_cfg.get("expected_bytes", 0.0))
	var expected_comp: String = (patch_base + comp_ext) if comp_ext != "" else ""
	var expected_prog: String = (patch_base + prog_ext) if prog_ext != "" else ""
	var total_mb_str: String = String.num(exp_bytes / (1024.0 * 1024.0), 0) if exp_bytes > 0.0 else ""
	
	var elapsed_ticks: int = 0
	var max_wait_ticks: int = 120 # up to 60 seconds (120 * 0.5s)
	var highest_pct: int = 50
	
	while elapsed_ticks < max_wait_ticks:
		if not is_instance_valid(node) or not node.get_tree():
			break
		await node.get_tree().create_timer(0.5).timeout
		elapsed_ticks += 1
		
		var comp_exists: bool = false
		if expected_comp != "":
			comp_exists = FileAccess.file_exists(expected_comp) or FileAccess.file_exists(ProjectSettings.globalize_path(expected_comp))
			if not comp_exists:
				comp_exists = _check_extension_exists_in_dir(expected_comp.get_base_dir(), comp_ext)
			
		if comp_exists:
			var done_msg: String = "Patch modification complete" + ((" (" + total_mb_str + " MB)") if total_mb_str != "" else "") + "!\n\nClient starting up..."
			_update_modding_status(node, done_msg, 100)
			if is_instance_valid(node) and node.get_tree():
				await node.get_tree().create_timer(1.2).timeout
			_dismiss_modding_overlay(node)
			return
			
		var prog_exists: bool = false
		if expected_prog != "":
			prog_exists = FileAccess.file_exists(expected_prog) or FileAccess.file_exists(ProjectSettings.globalize_path(expected_prog))
		if prog_exists and exp_bytes > 0.0:
			var check_prog_path: String = expected_prog if FileAccess.file_exists(expected_prog) else ProjectSettings.globalize_path(expected_prog)
			var cur_fa: FileAccess = FileAccess.open(check_prog_path, FileAccess.READ)
			var cur_sz: int = 0
			if cur_fa:
				cur_sz = cur_fa.get_length()
				cur_fa.close()
			if cur_sz > 0:
				var mb_val: float = float(cur_sz) / (1024.0 * 1024.0)
				var pct_calc: int = int(clamp(50.0 + (float(cur_sz) / max(exp_bytes, 1.0)) * 45.0, 50, 95))
				highest_pct = max(highest_pct, pct_calc)
				_update_modding_status(node, "Modding image in progress...\n\nWriting patched output: " + String.num(mb_val, 1) + " MB / " + total_mb_str + " MB\nCalculating multiworld data...", highest_pct)
			else:
				var smooth_pct: int = int(clamp(50.0 + (float(elapsed_ticks) / float(max_wait_ticks)) * 42.0, 50, 92))
				highest_pct = max(highest_pct, smooth_pct)
				_update_modding_status(node, "Archipelago patcher active...\nModding game files, please wait...", highest_pct)
		else:
			# Monotonic smooth progress from 50% up to 92% (NEVER jumps backward)
			var smooth_pct: int = int(clamp(50.0 + (float(elapsed_ticks) / float(max_wait_ticks)) * 42.0, 50, 92))
			highest_pct = max(highest_pct, smooth_pct)
			_update_modding_status(node, "Archipelago patcher active...\nModding game files, please wait...", highest_pct)

	_dismiss_modding_overlay(node)

func _spawn_companion_client_tool_if_needed(ctx: LaunchContext) -> void:
	var client_tool_key: String = ctx.preset.get("client_tool", "")
	if client_tool_key != "" and ctx.client_exe_path != "" and FileAccess.file_exists(ctx.client_exe_path):
		var abs_client: String = ProjectSettings.globalize_path(ctx.client_exe_path)
		var client_args: Array = []
		var comp: String = ctx.preset.get("client_component", "")
		if comp != "":
			client_args.append(comp)
		if ctx.preset.get("auto_connect", false) and ctx.server_url != "":
			client_args.append("--")
			client_args.append("--connect")
			client_args.append(ctx.server_url)
		print("[Launcher] Spawning companion client tool: ", abs_client, " args: ", client_args)
		OS.create_process(abs_client, client_args)

func _spawn_sni_emulator_companion(ctx: LaunchContext) -> void:
	if ctx.emulator_exe_path == "" or not FileAccess.file_exists(ctx.emulator_exe_path):
		print("[Launcher] No emulator configured or found for companion launch.")
		return

	var base_patch: String = ctx.patch_path.get_basename()
	var sfc_path: String = base_patch + ".sfc"
	if not FileAccess.file_exists(sfc_path):
		for attempt in range(12):
			if is_instance_valid(ctx.node) and ctx.node.get_tree():
				await ctx.node.get_tree().create_timer(0.5).timeout
			if FileAccess.file_exists(sfc_path):
				break

	if not FileAccess.file_exists(sfc_path):
		var patch_dir: String = ctx.patch_path.get_base_dir()
		var da: DirAccess = DirAccess.open(patch_dir)
		if da:
			da.list_dir_begin()
			var fn: String = da.get_next()
			while fn != "":
				if not da.current_is_dir() and (fn.ends_with(".sfc") or fn.ends_with(".smc")):
					sfc_path = patch_dir.path_join(fn)
					break
				fn = da.get_next()

	var emu_core: String = ctx.preset.get("emulator_core", "BSNESv115+")
	if emu_core != "":
		ArchipelagoConfig.configure_bizhawk_preferred_core(ctx.emulator_exe_path, "SNES", emu_core)

	var lua_template: String = ctx.preset.get("emulator_lua", "")
	var resolved_lua: String = ""
	if lua_template != "":
		resolved_lua = lua_template.replace("{tools_dir}", ProjectSettings.globalize_path(USER_TOOLS_DIR).replace("\\", "/"))
	if resolved_lua == "" or not FileAccess.file_exists(resolved_lua):
		var default_sni_lua: String = USER_TOOLS_DIR.path_join("Archipelago/SNI/lua/Connector.lua")
		if FileAccess.file_exists(default_sni_lua):
			resolved_lua = ProjectSettings.globalize_path(default_sni_lua)

	var emu_args: Array = []
	if resolved_lua != "" and FileAccess.file_exists(resolved_lua):
		emu_args.append("--lua=" + ProjectSettings.globalize_path(resolved_lua))

	if FileAccess.file_exists(sfc_path):
		emu_args.append(ProjectSettings.globalize_path(sfc_path))

	var abs_emu: String = ProjectSettings.globalize_path(ctx.emulator_exe_path)
	print("[Launcher] Auto-launching companion emulator (BizHawk) for SNI: ", abs_emu, " args: ", emu_args)
	OS.create_process(abs_emu, emu_args)
