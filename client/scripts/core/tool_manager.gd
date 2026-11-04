class_name ToolManager
extends RefCounted

const DEFAULT_ARCHIPELAGO_DOWNLOAD_URL: String = "/tools/archipelago.zip"
const DEFAULT_ARCHIPELAGO_FALLBACK_URL: String = "https://github.com/ArchipelagoMW/Archipelago/releases/download/0.6.7/Setup.Archipelago.0.6.7.exe"

var paths_config: Dictionary
var locator
var save_paths_callback: Callable

class InstallRequest:
	var node: Node
	var tool_name: String
	var download_url: String
	var subfolder: String
	var target_executable: String
	var fallback_url: String
	var generation: int

	func _init(
		p_node: Node,
		p_tool_name: String,
		p_download_url: String,
		p_subfolder: String,
		p_target_executable: String,
		p_fallback_url: String,
		p_generation: int
	) -> void:
		node = p_node
		tool_name = p_tool_name
		download_url = p_download_url
		subfolder = p_subfolder
		target_executable = p_target_executable
		fallback_url = p_fallback_url
		generation = p_generation

static func install_success(path: String) -> Dictionary:
	return {"success": true, "path": path, "error": ""}

static func install_failure(error: String) -> Dictionary:
	return {"success": false, "path": "", "error": error}

func create_install_request(
	node: Node,
	tool_name: String,
	download_url: String,
	subfolder: String,
	target_executable: String,
	fallback_url: String,
	generation: int
) -> InstallRequest:
	return InstallRequest.new(node, tool_name, download_url, subfolder, target_executable, fallback_url, generation)

func _init(p_paths_config: Dictionary, p_locator, p_save_paths_callback: Callable) -> void:
	paths_config = p_paths_config
	locator = p_locator
	save_paths_callback = p_save_paths_callback

func get_preset_packages(preset_config: Dictionary) -> Array:
	if preset_config.get("packages") is Array:
		return preset_config["packages"]

	var packages: Array = []
	if str(preset_config.get("modding_api_url", "")) != "":
		packages.append({
			"name": "Modding API",
			"download_url": preset_config.get("modding_api_url", ""),
			"check_file": preset_config.get("modding_api_check_file", ""),
			"extract_target": preset_config.get("modding_api_extract_target", ""),
			"backup_files": preset_config.get("modding_api_backup_files", ["Assembly-CSharp.dll"])
		})
	if str(preset_config.get("mods_url", "")) != "":
		packages.append({
			"name": "Archipelago Mods",
			"download_url": preset_config.get("mods_url", ""),
			"check_file": preset_config.get("mods_check_file", ""),
			"extract_target": preset_config.get("mods_extract_target", ""),
			"backup_files": preset_config.get("mods_backup_files", [])
		})
	return packages

func resolve_path(tool_key: String, tool_def: Dictionary, fallback_config_key: String = "", allow_deep_search: bool = false) -> String:
	var config_key: String = tool_key if fallback_config_key == "" else fallback_config_key
	var stored: String = str(paths_config.get(config_key, ""))
	if stored != "" and FileAccess.file_exists(stored):
		if validate_tool_integrity(tool_key, stored):
			return stored
		else:
			paths_config.erase(config_key)
			if save_paths_callback.is_valid():
				save_paths_callback.call()

	var executable: String = str(tool_def.get("executable", ""))
	var sub_folders: Array = tool_def.get("sub_folders", [])
	var aliases: Array = tool_def.get("executable_aliases", []).duplicate()
	if executable != "" and not aliases.has(executable):
		aliases.push_front(executable)

	var found: String = locator.find(executable, sub_folders, aliases, false) if locator else ""
	if found == "" and allow_deep_search and locator:
		found = locator.find(executable, sub_folders, aliases, true)
	if found == "" or not FileAccess.file_exists(found):
		return ""

	if not validate_tool_integrity(tool_key, found):
		return ""

	paths_config[config_key] = found
	if save_paths_callback.is_valid():
		save_paths_callback.call()
	return found

func validate_tool_integrity(tool_key: String, exe_path: String) -> bool:
	if not FileAccess.file_exists(exe_path):
		return false
	var file_name: String = exe_path.get_file().to_lower()
	if tool_key == "archipelago_client" or file_name.begins_with("archipelago"):
		var base_dir: String = exe_path.get_base_dir()
		var dir := DirAccess.open(base_dir)
		if dir:
			dir.list_dir_begin()
			var item := dir.get_next()
			var found_python := false
			while item != "":
				if not dir.current_is_dir() and item.to_lower().begins_with("python") and item.to_lower().ends_with(".dll"):
					found_python = true
					break
				item = dir.get_next()
			dir.list_dir_end()
			if not found_python:
				print("[ToolManager] Archipelago integrity check failed: missing python DLL in ", base_dir)
				return false

	if tool_key == "dolphin" or file_name == "dolphin.exe":
		var base_dir: String = exe_path.get_base_dir()
		var has_qt: bool = FileAccess.file_exists(base_dir.path_join("QtPlugins/platforms/qwindows.dll")) \
			or FileAccess.file_exists(base_dir.path_join("platforms/qwindows.dll")) \
			or FileAccess.file_exists(base_dir.path_join("qwindows.dll"))
		if not has_qt:
			print("[ToolManager] Dolphin integrity check failed: missing Qt platform plugin (qwindows.dll) in ", base_dir)
			return false

	return true

static func format_bytes(bytes: int) -> String:
	if bytes <= 0:
		return "0 B"
	if bytes < 1024:
		return "%d B" % bytes
	elif bytes < 1024 * 1024:
		return "%.1f KB" % (bytes / 1024.0)
	elif bytes < 1024 * 1024 * 1024:
		return "%.1f MB" % (bytes / (1024.0 * 1024.0))
	else:
		return "%.2f GB" % (bytes / (1024.0 * 1024.0 * 1024.0))

const USER_DIR_SIZE_CACHE_PATH: String = "user://dir_size_cache.json"
static var _dir_size_cache_loaded: bool = false
static var _dir_size_cache: Dictionary = {}

static func _load_dir_size_cache() -> void:
	if FileAccess.file_exists(USER_DIR_SIZE_CACHE_PATH):
		var fa := FileAccess.open(USER_DIR_SIZE_CACHE_PATH, FileAccess.READ)
		if fa:
			var parsed: Variant = JSON.parse_string(fa.get_as_text())
			if parsed is Dictionary:
				_dir_size_cache = parsed
			fa.close()

static func _save_dir_size_cache() -> void:
	var fa := FileAccess.open(USER_DIR_SIZE_CACHE_PATH, FileAccess.WRITE)
	if fa:
		fa.store_string(JSON.stringify(_dir_size_cache))
		fa.close()

static func get_dir_size_bytes(dir_path: String, use_cache: bool = true) -> int:
	if not _dir_size_cache_loaded:
		_load_dir_size_cache()
		_dir_size_cache_loaded = true

	var norm_path: String = ProjectSettings.globalize_path(dir_path)
	if use_cache and DirAccess.dir_exists_absolute(norm_path):
		var mtime: int = FileAccess.get_modified_time(norm_path)
		if _dir_size_cache.has(norm_path):
			var entry: Dictionary = _dir_size_cache[norm_path]
			if entry.get("mtime", -1) == mtime:
				return int(entry.get("size", 0))

	var total_size := _calculate_dir_size_bytes(dir_path)
	if use_cache and DirAccess.dir_exists_absolute(norm_path):
		_dir_size_cache[norm_path] = {
			"mtime": FileAccess.get_modified_time(norm_path),
			"size": total_size
		}
		_save_dir_size_cache()
	return total_size

static func _calculate_dir_size_bytes(dir_path: String) -> int:
	var total_size: int = 0
	var dir := DirAccess.open(dir_path)
	if not dir:
		return 0
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name != "." and file_name != "..":
			var full_path := dir_path.path_join(file_name)
			if dir.current_is_dir():
				total_size += _calculate_dir_size_bytes(full_path)
			else:
				var fa := FileAccess.open(full_path, FileAccess.READ)
				if fa:
					total_size += fa.get_length()
					fa.close()
		file_name = dir.get_next()
	dir.list_dir_end()
	return total_size

static func clear_dir_size_cache(dir_path: String = "") -> void:
	if not _dir_size_cache_loaded:
		_load_dir_size_cache()
		_dir_size_cache_loaded = true

	if dir_path.is_empty():
		_dir_size_cache.clear()
	else:
		_dir_size_cache.erase(ProjectSettings.globalize_path(dir_path))
	_save_dir_size_cache()

static func remove_dir_recursive(dir_path: String) -> bool:
	clear_dir_size_cache(dir_path)
	if not DirAccess.dir_exists_absolute(dir_path):
		return true
	var dir := DirAccess.open(dir_path)
	if not dir:
		return false
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name != "." and file_name != "..":
			var full_path := dir_path.path_join(file_name)
			if dir.current_is_dir():
				remove_dir_recursive(full_path)
			else:
				DirAccess.remove_absolute(full_path)
		file_name = dir.get_next()
	dir.list_dir_end()
	var err := DirAccess.remove_absolute(dir_path)
	return err == OK

func get_tool_status(tool_key: String, tool_def: Dictionary, allow_deep_search: bool = false) -> Dictionary:
	var tool_name: String = str(tool_def.get("name", tool_key))
	var exe_name: String = str(tool_def.get("executable", ""))
	var subfolders: Array = tool_def.get("sub_folders", [])
	if subfolders.is_empty():
		subfolders = [tool_name]
	var primary_subfolder: String = str(subfolders[0])
	var fallback_cfg_key: String = tool_key + "_emulator" if tool_key.to_lower().contains("hawk") or tool_key.to_lower().contains("dolphin") or tool_key.to_lower().contains("snes") or tool_def.has("emulator") else ""

	var resolved_path: String = resolve_path(tool_key, tool_def, fallback_cfg_key, allow_deep_search)
	var is_installed: bool = resolved_path != "" and FileAccess.file_exists(resolved_path)
	var is_managed: bool = false
	var size_bytes: int = 0
	var managed_dir: String = ""

	var user_tools_base := ProjectSettings.globalize_path("user://tools").replace("\\", "/").to_lower()
	var user_tools_dir := "user://tools"

	for sf in subfolders:
		var sf_dir: String = user_tools_dir.path_join(sf)
		if DirAccess.dir_exists_absolute(sf_dir):
			managed_dir = sf_dir
			break

	if managed_dir != "":
		size_bytes = get_dir_size_bytes(managed_dir)
	elif is_installed:
		var fa := FileAccess.open(resolved_path, FileAccess.READ)
		if fa:
			size_bytes = fa.get_length()
			fa.close()

	# If resolve_path returned empty because integrity failed, check if the binary exists in managed directory
	var has_unverified_file: bool = false
	var unverified_path: String = ""
	if not is_installed and managed_dir != "":
		var candidate := managed_dir.path_join(exe_name)
		if FileAccess.file_exists(candidate):
			has_unverified_file = true
			unverified_path = ProjectSettings.globalize_path(candidate)

	if is_installed:
		var norm_res := resolved_path.replace("\\", "/").to_lower()
		if norm_res.begins_with(user_tools_base) or norm_res.contains("/tools/"):
			is_managed = true
	elif has_unverified_file:
		resolved_path = unverified_path
		is_installed = true
		is_managed = true

	var integrity_valid := true
	var integrity_error := ""
	if is_installed:
		if not validate_tool_integrity(tool_key, resolved_path):
			integrity_valid = false
			integrity_error = "Integrity check failed (missing required files or dependencies)"

	var status_code: String = "NOT_INSTALLED"
	if is_installed:
		if not integrity_valid:
			status_code = "CORRUPT"
		elif is_managed:
			status_code = "INSTALLED"
		else:
			status_code = "EXTERNAL"

	return {
		"key": tool_key,
		"name": tool_name,
		"executable": exe_name,
		"subfolders": subfolders,
		"primary_subfolder": primary_subfolder,
		"managed_dir": managed_dir if managed_dir != "" else user_tools_dir.path_join(primary_subfolder),
		"download_url": tool_def.get("download_url", ""),
		"fallback_download_url": tool_def.get("fallback_download_url", ""),
		"path": resolved_path,
		"installed": is_installed,
		"is_managed": is_managed,
		"size_bytes": size_bytes,
		"formatted_size": format_bytes(size_bytes),
		"integrity_valid": integrity_valid,
		"integrity_error": integrity_error,
		"status_code": status_code,
		"tool_def": tool_def
	}

func get_all_tools_status(tools_dict: Dictionary, allow_deep_search: bool = false) -> Dictionary:
	var result_list: Array[Dictionary] = []
	var total_size_bytes: int = 0
	var installed_count: int = 0

	for key in tools_dict.keys():
		var t_def: Dictionary = tools_dict[key]
		var status: Dictionary = get_tool_status(key, t_def, allow_deep_search)
		result_list.append(status)
		if status.installed:
			installed_count += 1
			total_size_bytes += int(status.size_bytes)

	return {
		"tools": result_list,
		"total_managed_size_bytes": total_size_bytes,
		"formatted_total_size": format_bytes(total_size_bytes),
		"installed_count": installed_count,
		"total_count": result_list.size()
	}

func uninstall_tool(tool_key: String, tool_def: Dictionary) -> Dictionary:
	var subfolders: Array = tool_def.get("sub_folders", [])
	var tool_name: String = str(tool_def.get("name", tool_key))
	if subfolders.is_empty():
		subfolders = [tool_name]

	var user_tools_dir := "user://tools"
	var removed_dirs: Array[String] = []
	for sf in subfolders:
		var target_dir: String = user_tools_dir.path_join(sf)
		if DirAccess.dir_exists_absolute(target_dir):
			remove_dir_recursive(target_dir)
			removed_dirs.append(target_dir)

	# Clean temp download archives
	var download_url: String = str(tool_def.get("download_url", ""))
	if download_url != "":
		var temp_path: String = get_temp_download_path(tool_name, download_url)
		if FileAccess.file_exists(temp_path):
			DirAccess.remove_absolute(temp_path)

	var dir := DirAccess.open(user_tools_dir)
	if dir:
		dir.list_dir_begin()
		var item := dir.get_next()
		var tool_clean_name := tool_name.validate_filename().to_lower().replace(" ", "")
		var tool_clean_raw := tool_name.validate_filename().to_lower()
		var tool_key_clean := tool_key.to_lower().replace("_", "")
		while item != "":
			var item_lower := item.to_lower().replace(" ", "").replace("_", "")
			if not dir.current_is_dir() and item.to_lower().begins_with("temp_"):
				if item_lower.contains(tool_clean_raw.replace(" ", "").replace("_", "")) or item_lower.contains(tool_clean_name) or item_lower.contains(tool_key_clean):
					DirAccess.remove_absolute(user_tools_dir.path_join(item))
			item = dir.get_next()
		dir.list_dir_end()

	# Clear from paths_config
	var config_keys_to_clear: Array[String] = [
		tool_key,
		tool_key + "_emulator",
		tool_name
	]
	var cleared_any := false
	for ck in config_keys_to_clear:
		if paths_config.has(ck):
			paths_config.erase(ck)
			cleared_any = true

	if cleared_any and save_paths_callback.is_valid():
		save_paths_callback.call()

	return {
		"success": true,
		"removed_dirs": removed_dirs,
		"error": ""
	}

func set_external_tool_path(tool_key: String, tool_def: Dictionary, file_path: String) -> Dictionary:
	var trimmed: String = file_path.strip_edges()
	if trimmed == "" or not FileAccess.file_exists(trimmed):
		return {"success": false, "error": "Specified file does not exist: " + file_path}

	if not validate_tool_integrity(tool_key, trimmed):
		return {"success": false, "error": "Selected executable failed integrity validation."}

	paths_config[tool_key] = trimmed
	if tool_def.has("emulator") or tool_key.to_lower().contains("hawk") or tool_key.to_lower().contains("dolphin") or tool_key.to_lower().contains("snes"):
		paths_config[tool_key + "_emulator"] = trimmed

	if save_paths_callback.is_valid():
		save_paths_callback.call()

	return {"success": true, "path": trimmed, "error": ""}

func unlink_external_tool(tool_key: String) -> Dictionary:
	var cleared := false
	if paths_config.has(tool_key):
		paths_config.erase(tool_key)
		cleared = true
	var emu_key := tool_key + "_emulator"
	if paths_config.has(emu_key):
		paths_config.erase(emu_key)
		cleared = true
	if cleared and save_paths_callback.is_valid():
		save_paths_callback.call()
	return {"success": true, "error": ""}

func _get_network_manager():
	if Engine.has_singleton("NetworkManager"):
		return Engine.get_singleton("NetworkManager")
	var main_loop = Engine.get_main_loop()
	if main_loop and "root" in main_loop and main_loop.root and main_loop.root.has_node("NetworkManager"):
		return main_loop.root.get_node("NetworkManager")
	return null

func resolve_download_url(download_url: String) -> String:
	var resolved_url: String = download_url
	var base_url: String = "http://localhost:8080"
	var nm = _get_network_manager()
	if nm and nm.has_method("get_http_url"):
		base_url = nm.get_http_url()

	if resolved_url.contains("{backend_url}"):
		return resolved_url.replace("{backend_url}", base_url)
	if not resolved_url.begins_with("http://") and not resolved_url.begins_with("https://"):
		return base_url + (resolved_url if resolved_url.begins_with("/") else "/" + resolved_url)
	if resolved_url.contains("releases/latest"):
		return DEFAULT_ARCHIPELAGO_DOWNLOAD_URL
	return resolved_url

func get_temp_download_path(tool_name: String, download_url: String) -> String:
	var is_executable: bool = download_url.get_file().strip_edges().to_lower().ends_with(".exe") or download_url.to_lower().contains(".exe")
	var is_7z: bool = download_url.get_file().strip_edges().to_lower().ends_with(".7z") or download_url.to_lower().contains(".7z")
	var extension: String = ".exe" if is_executable else (".7z" if is_7z else ".zip")
	return "user://tools".path_join("temp_" + tool_name.validate_filename() + extension)

func validate_download_file(file_path: String, expected_sha256: String = "") -> Dictionary:
	if not FileAccess.file_exists(file_path):
		return {"valid": false, "error": "Downloaded file does not exist on disk: " + file_path}

	if expected_sha256 != "":
		var actual_sha256 := FileAccess.get_sha256(file_path).to_lower()
		if actual_sha256 != expected_sha256.to_lower():
			return {
				"valid": false,
				"error": "Downloaded file checksum mismatch. Expected: " + expected_sha256 + " Computed: " + actual_sha256
			}

	var file_access: FileAccess = FileAccess.open(file_path, FileAccess.READ)
	if not file_access:
		return {"valid": false, "error": "Cannot open downloaded file for verification: " + file_path}

	var file_size: int = file_access.get_length()
	var header: PackedByteArray = file_access.get_buffer(4)
	file_access.close()
	if file_size < 1024:
		return {"valid": false, "error": "Downloaded file is too small (" + str(file_size) + " bytes). Expected archive or installer; got error page."}

	var is_zip: bool = header.size() >= 2 and header[0] == 0x50 and header[1] == 0x4B
	var is_7z: bool = header.size() >= 4 and header[0] == 0x37 and header[1] == 0x7A and header[2] == 0xBC and header[3] == 0xAF
	var is_executable: bool = header.size() >= 2 and header[0] == 0x4D and header[1] == 0x5A
	if not is_zip and not is_7z and not is_executable:
		return {"valid": false, "error": "Downloaded file is not a ZIP archive, 7z archive, or Windows installer."}
	return {
		"valid": true,
		"format": "exe" if is_executable else ("7z" if is_7z else "zip"),
		"error": ""
	}
