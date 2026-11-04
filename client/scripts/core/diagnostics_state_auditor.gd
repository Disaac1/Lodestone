class_name DiagnosticsStateAuditor
extends RefCounted

## DiagnosticsStateAuditor
## Audits and validates the runtime state of all games, tools, mod loaders,
## and configuration files in Wayfinder/Lodestone.

const LauncherUtils = preload("res://scripts/core/launcher_utils.gd")
const HostYamlEditor = preload("res://scripts/core/host_yaml_editor.gd")

var launcher
var executable_locator
var tool_manager
var paths_config: Dictionary = {}

func _init(p_launcher, p_paths_config: Dictionary = {}) -> void:
	launcher = p_launcher
	paths_config = p_paths_config if not p_paths_config.is_empty() else (launcher.paths_config if launcher else {})
	if launcher:
		executable_locator = launcher._executable_locator
		tool_manager = launcher._tool_manager

## Audits all available games and tools and returns a unified diagnostic report.
func run_full_audit(sandbox_prefix: String = "") -> Dictionary:
	var games_audit: Dictionary = {}
	var tools_audit: Dictionary = {}

	# Ensure launcher presets and tools are loaded
	var presets: Dictionary = launcher.launcher_presets if launcher else {}
	var tools: Dictionary = launcher.launcher_tools if launcher else {}

	# Fallback if empty: discover directly from repository backend/data
	if presets.is_empty() or tools.is_empty():
		_discover_offline_presets(presets, tools)

	# Audit all games
	for game_name in presets.keys():
		var preset: Dictionary = presets[game_name]
		games_audit[game_name] = audit_game(game_name, preset, sandbox_prefix)

	# Audit all tools
	for tool_key in tools.keys():
		var tool_data: Dictionary = tools[tool_key]
		tools_audit[tool_key] = audit_tool(tool_key, tool_data, sandbox_prefix)

	var summary = {
		"total_games": games_audit.size(),
		"games_ready": 0,
		"games_missing": 0,
		"total_tools": tools_audit.size(),
		"tools_ready": 0,
		"tools_missing": 0,
		"timestamp": Time.get_datetime_string_from_system()
	}

	for g in games_audit.values():
		if g.get("overall_status") == "READY" or g.get("overall_status") == "MOCK_READY":
			summary["games_ready"] += 1
		else:
			summary["games_missing"] += 1

	for t in tools_audit.values():
		if t.get("overall_status") == "READY":
			summary["tools_ready"] += 1
		else:
			summary["tools_missing"] += 1

	return {
		"summary": summary,
		"games": games_audit,
		"tools": tools_audit
	}

## Audits a single game's complete operational state.
func audit_game(game_name: String, preset: Dictionary, sandbox_prefix: String = "") -> Dictionary:
	var slug: String = str(preset.get("slug", "")).strip_edges()
	if slug == "" and launcher:
		slug = launcher.get_game_slug(game_name)
	if slug == "":
		slug = game_name.to_lower().replace(" ", "_").replace("'", "").replace(":", "")

	var req_exe: String = str(preset.get("target_exe", preset.get("executable", "")))
	var req_rom: String = str(preset.get("required_rom", ""))
	var launch_mode: String = str(preset.get("launch_mode", "direct"))
	var client_tool: String = str(preset.get("client_tool", ""))
	var emulator_tool: String = str(preset.get("emulator_tool", ""))

	# 1. Resolve Executable or ROM path
	var resolved_path: String = ""
	var is_mock: bool = false

	# Check sandbox override first if specified
	if sandbox_prefix != "":
		var sb_game_dir: String = sandbox_prefix.path_join("games").path_join(slug)
		if req_exe != "":
			var sb_exe: String = sb_game_dir.path_join(req_exe)
			if FileAccess.file_exists(sb_exe):
				resolved_path = ProjectSettings.globalize_path(sb_exe)
				is_mock = true
		elif req_rom != "":
			var sb_rom: String = sandbox_prefix.path_join("base_roms").path_join(req_rom)
			if FileAccess.file_exists(sb_rom):
				resolved_path = ProjectSettings.globalize_path(sb_rom)
				is_mock = true

	# Standard path check if not found in sandbox
	if resolved_path == "" and launcher:
		if req_exe != "":
			resolved_path = launcher.find_game_executable(req_exe, preset.get("sub_folders", []), preset.get("search_dirs", []))
		elif req_rom != "":
			resolved_path = launcher.find_existing_base_rom(req_rom)

	var has_binary: bool = resolved_path != ""

	# 2. Modding status evaluation
	var mod_status: Dictionary = {"state": "N/A", "label": "No Mods Required", "ready": true}
	var game_dir: String = resolved_path.get_base_dir() if has_binary else ""

	if has_binary and game_dir != "":
		# Check Lumafly / Assembly-CSharp swap mechanics
		if FileAccess.file_exists(game_dir.path_join("hollow_knight_Data/Managed/Assembly-CSharp.dll")):
			var status = LauncherUtils.check_assembly_csharp_status(game_dir)
			var state = status.get("state", "unknown")
			if state == "active":
				mod_status = {"state": "MODDED", "label": "Modded (ModHooks Active)", "ready": true}
			elif state == "disabled_in_lumafly":
				mod_status = {"state": "VANILLA", "label": "Vanilla (Assembly-CSharp.dll.m exists)", "ready": false}
			else:
				mod_status = {"state": "UNMODDED", "label": "Vanilla Only (No Modded Assembly)", "ready": false}
		# Check Slay the Spire mods folder
		elif req_exe.to_lower().contains("slaythespire"):
			var mods_folder = game_dir.path_join("mods")
			if DirAccess.dir_exists_absolute(mods_folder):
				mod_status = {"state": "MODDED", "label": "Mods Directory Present", "ready": true}
			else:
				mod_status = {"state": "UNMODDED", "label": "Mods Directory Missing", "ready": false}
		# Check BepInEx
		elif DirAccess.dir_exists_absolute(game_dir.path_join("BepInEx")):
			mod_status = {"state": "MODDED", "label": "BepInEx Installed", "ready": true}
		# Check SMAPI
		elif FileAccess.file_exists(game_dir.path_join("StardewModdingAPI.exe")):
			mod_status = {"state": "MODDED", "label": "SMAPI Installed", "ready": true}
		# Check Lovely (Balatro)
		elif FileAccess.file_exists(game_dir.path_join("version.dll")):
			mod_status = {"state": "MODDED", "label": "Lovely Mod Loader Injected", "ready": true}

	# 3. Tool dependencies status
	var tools_needed: Array[Dictionary] = []
	if client_tool != "":
		tools_needed.append(_evaluate_tool_dependency(client_tool, sandbox_prefix))
	if emulator_tool != "":
		tools_needed.append(_evaluate_tool_dependency(emulator_tool, sandbox_prefix))

	var tools_all_ready: bool = true
	for t in tools_needed:
		if not t.get("ready", false):
			tools_all_ready = false
			break

	# 4. Config sync status (host.yaml / mod configs)
	var config_status: Dictionary = _evaluate_config_status(game_name, preset, resolved_path, sandbox_prefix)

	# 5. Overall status classification
	var overall_status: String = "MISSING"
	if has_binary:
		if is_mock:
			overall_status = "MOCK_READY" if tools_all_ready else "MOCK_DEGRADED"
		else:
			overall_status = "READY" if (tools_all_ready and mod_status.get("ready", true)) else "DEGRADED"

	return {
		"game_name": game_name,
		"slug": slug,
		"launch_mode": launch_mode,
		"target_exe": req_exe,
		"required_rom": req_rom,
		"has_binary": has_binary,
		"is_mock": is_mock,
		"resolved_path": resolved_path,
		"mod_status": mod_status,
		"tools_needed": tools_needed,
		"tools_ready": tools_all_ready,
		"config_status": config_status,
		"overall_status": overall_status
	}

## Audits a tool or emulator's installation, prereqs, and firmware.
func audit_tool(tool_key: String, tool_data: Dictionary, sandbox_prefix: String = "") -> Dictionary:
	var tool_name: String = str(tool_data.get("name", tool_key))
	var exe_name: String = str(tool_data.get("executable", ""))
	var subfolders: Array = tool_data.get("sub_folders", [tool_name])
	var sha256_expected: String = str(tool_data.get("sha256", ""))

	var resolved_path: String = ""
	var tools_base_dir: String = "user://tools"
	if sandbox_prefix != "":
		tools_base_dir = sandbox_prefix.path_join("tools")

	# Check inside tools_base_dir
	for sf in subfolders:
		var target_candidate: String = tools_base_dir.path_join(sf).path_join(exe_name)
		if FileAccess.file_exists(target_candidate):
			resolved_path = ProjectSettings.globalize_path(target_candidate)
			break

	# Check recursive locator if not found in standard subfolder
	if resolved_path == "" and launcher:
		resolved_path = launcher.find_executable_recursive(tools_base_dir, exe_name)
		if resolved_path == "":
			resolved_path = launcher.find_game_executable(exe_name, subfolders)

	var is_installed: bool = resolved_path != ""

	# Audit Prerequisites (e.g. BizHawk VC++ redist)
	var prereqs_audit: Array[Dictionary] = []
	var prereqs_list: Array = tool_data.get("prerequisites", [])
	var prereqs_all_met: bool = true
	for p in prereqs_list:
		if p is Dictionary:
			var p_name: String = str(p.get("name", "Prerequisite"))
			var check_files: Array = p.get("check_files", [])
			var p_met: bool = false
			for cf in check_files:
				if FileAccess.file_exists(cf):
					p_met = true
					break
			if check_files.is_empty():
				p_met = true
			if not p_met:
				prereqs_all_met = false
			prereqs_audit.append({"name": p_name, "satisfied": p_met})

	# Audit Firmware / BIOS (e.g. ps-30a.bin)
	var firmware_audit: Array[Dictionary] = []
	var firmware_list: Array = tool_data.get("firmware", [])
	var firmware_all_met: bool = true
	if is_installed:
		var emu_dir: String = resolved_path.get_base_dir()
		for fw in firmware_list:
			if fw is Dictionary:
				var fw_name: String = str(fw.get("name", fw.get("file_name", "BIOS")))
				var dest_rel: String = str(fw.get("dest_path", fw.get("file_name", "")))
				var exists: bool = FileAccess.file_exists(emu_dir.path_join(dest_rel))
				if not exists:
					for alias in fw.get("dest_aliases", []):
						if FileAccess.file_exists(emu_dir.path_join(alias)):
							exists = true
							break
				if not exists:
					firmware_all_met = false
				firmware_audit.append({"name": fw_name, "present": exists, "path": dest_rel})

	var overall_status: String = "MISSING"
	if is_installed:
		if not prereqs_all_met:
			overall_status = "PREREQS_MISSING"
		elif not firmware_all_met:
			overall_status = "FIRMWARE_MISSING"
		else:
			overall_status = "READY"

	return {
		"tool_key": tool_key,
		"name": tool_name,
		"executable": exe_name,
		"is_installed": is_installed,
		"resolved_path": resolved_path,
		"sha256": sha256_expected,
		"prerequisites": prereqs_audit,
		"prereqs_all_met": prereqs_all_met,
		"firmware": firmware_audit,
		"firmware_all_met": firmware_all_met,
		"overall_status": overall_status
	}

func _evaluate_tool_dependency(tool_key: String, sandbox_prefix: String = "") -> Dictionary:
	var tool_data: Dictionary = {}
	if launcher and launcher.launcher_tools.has(tool_key):
		tool_data = launcher.launcher_tools[tool_key]
	elif launcher and launcher.launcher_tools.has(tool_key.to_lower()):
		tool_data = launcher.launcher_tools[tool_key.to_lower()]
	else:
		tool_data = {"name": tool_key, "executable": tool_key + ".exe"}

	var audit = audit_tool(tool_key, tool_data, sandbox_prefix)
	return {
		"tool_key": tool_key,
		"name": audit.get("name", tool_key),
		"ready": audit.get("overall_status") == "READY",
		"status": audit.get("overall_status"),
		"path": audit.get("resolved_path", "")
	}

func _evaluate_config_status(game_name: String, preset: Dictionary, game_exe_path: String, sandbox_prefix: String = "") -> Dictionary:
	var host_yaml_path: String = "user://tools/Archipelago/host.yaml"
	if sandbox_prefix != "":
		host_yaml_path = sandbox_prefix.path_join("tools/Archipelago/host.yaml")

	var host_yaml_exists: bool = FileAccess.file_exists(host_yaml_path)
	var synced: bool = false

	if host_yaml_exists and game_exe_path != "":
		var fa = FileAccess.open(host_yaml_path, FileAccess.READ)
		if fa:
			var content = fa.get_as_text()
			fa.close()
			# Check if game executable or directory path is registered in yaml
			if content.contains(game_exe_path.replace("\\", "/")) or content.contains(game_exe_path.get_base_dir().replace("\\", "/")):
				synced = true

	return {
		"host_yaml_path": host_yaml_path,
		"host_yaml_exists": host_yaml_exists,
		"synced": synced
	}

func _discover_offline_presets(out_presets: Dictionary, out_tools: Dictionary) -> void:
	var games_dir_path = ProjectSettings.globalize_path("res://../backend/data/games")
	var dir = DirAccess.open(games_dir_path)
	if dir:
		dir.list_dir_begin()
		var entry = dir.get_next()
		while entry != "":
			if dir.current_is_dir() and not entry.begins_with("."):
				var launch_json_path = games_dir_path.path_join(entry).path_join("launch.json")
				if FileAccess.file_exists(launch_json_path):
					var fa = FileAccess.open(launch_json_path, FileAccess.READ)
					if fa:
						var parsed = JSON.parse_string(fa.get_as_text())
						fa.close()
						if parsed is Dictionary:
							var g_name = parsed.get("game_name", entry.capitalize())
							parsed["slug"] = entry
							out_presets[g_name] = parsed
			entry = dir.get_next()
		dir.list_dir_end()

	var tools_dir_path = ProjectSettings.globalize_path("res://../backend/data/tools")
	var tdir = DirAccess.open(tools_dir_path)
	if tdir:
		tdir.list_dir_begin()
		var tentry = tdir.get_next()
		while tentry != "":
			if tentry.ends_with(".json"):
				var t_path = tools_dir_path.path_join(tentry)
				var fa = FileAccess.open(t_path, FileAccess.READ)
				if fa:
					var parsed = JSON.parse_string(fa.get_as_text())
					fa.close()
					if parsed is Dictionary:
						var t_key = tentry.get_basename()
						out_tools[t_key] = parsed
			tentry = tdir.get_next()
		tdir.list_dir_end()
