class_name MockGameScaffolder
extends RefCounted

## MockGameScaffolder
## Creates and manages lightweight sandbox dummy game directories and files
## so that the 1-Click Install System, mod loaders, and config synchronizers
## can be tested realistically without needing live commercial games.

const DEFAULT_SANDBOX_PATH: String = "user://e2e_sandbox"

## Scaffolds a complete mock game environment in the sandbox based on its preset.
static func scaffold_mock_game(game_slug: String, preset: Dictionary, sandbox_path: String = DEFAULT_SANDBOX_PATH) -> Dictionary:
	var created_files: Array[String] = []
	var target_exe: String = str(preset.get("target_exe", preset.get("executable", "")))
	var required_rom: String = str(preset.get("required_rom", ""))

	var game_dir: String = sandbox_path.path_join("games").path_join(game_slug)
	DirAccess.make_dir_recursive_absolute(game_dir)

	# 1. PC Executable Based Game
	if target_exe != "":
		var exe_path: String = game_dir.path_join(target_exe)
		_write_stub_file(exe_path, "MZ_STUB_WAYFINDER_MOCK_EXE_PAYLOAD")
		created_files.append(exe_path)

		# Game specific modding scaffolding
		if game_slug == "hollow_knight" or target_exe.to_lower().contains("hollow"):
			var managed_dir: String = game_dir.path_join("hollow_knight_Data/Managed")
			DirAccess.make_dir_recursive_absolute(managed_dir)

			var active_dll: String = managed_dir.path_join("Assembly-CSharp.dll")
			var modded_dll: String = managed_dir.path_join("Assembly-CSharp.dll.m")
			_write_stub_file(active_dll, "VANILLA_ASSEMBLY_WITHOUT_HOOKS")
			_write_stub_file(modded_dll, "MODDED_ASSEMBLY_CONTAINING_ModHooks_MARKER")
			created_files.append(active_dll)
			created_files.append(modded_dll)

		elif game_slug == "slay_the_spire" or target_exe.to_lower().contains("slaythespire"):
			var mods_dir: String = game_dir.path_join("mods")
			DirAccess.make_dir_recursive_absolute(mods_dir)
			var base_mod: String = mods_dir.path_join("BaseMod.jar")
			_write_stub_file(base_mod, "MOCK_BASE_MOD_PAYLOAD")
			created_files.append(base_mod)

		elif game_slug == "stardew_valley":
			var smapi_exe: String = game_dir.path_join("StardewModdingAPI.exe")
			_write_stub_file(smapi_exe, "MZ_STUB_SMAPI")
			created_files.append(smapi_exe)

		elif game_slug == "balatro":
			var lovely_dll: String = game_dir.path_join("version.dll")
			_write_stub_file(lovely_dll, "MZ_STUB_LOVELY_MOD_LOADER")
			created_files.append(lovely_dll)

	# 2. ROM Based Game
	if required_rom != "":
		var roms_dir: String = sandbox_path.path_join("base_roms")
		DirAccess.make_dir_recursive_absolute(roms_dir)
		var rom_path: String = roms_dir.path_join(required_rom)
		_write_stub_file(rom_path, "WAYFINDER_MOCK_ROM_IMAGE_HEADER_" + required_rom)
		created_files.append(rom_path)

	return {
		"game_slug": game_slug,
		"game_dir": game_dir,
		"created_files": created_files,
		"success": true
	}

## Scaffolds a mock tool or emulator installation in the sandbox.
static func scaffold_mock_tool(tool_key: String, tool_data: Dictionary, sandbox_path: String = DEFAULT_SANDBOX_PATH) -> Dictionary:
	var created_files: Array[String] = []
	var exe_name: String = str(tool_data.get("executable", tool_key + ".exe"))
	var subfolders: Array = tool_data.get("sub_folders", [tool_key])
	var subfolder: String = str(subfolders[0]) if not subfolders.is_empty() else tool_key

	var tool_dir: String = sandbox_path.path_join("tools").path_join(subfolder)
	DirAccess.make_dir_recursive_absolute(tool_dir)

	var exe_path: String = tool_dir.path_join(exe_name)
	_write_stub_file(exe_path, "MZ_STUB_TOOL_EXECUTABLE_" + tool_key)
	created_files.append(exe_path)

	# Firmware / BIOS scaffolding if needed
	var firmware_list: Array = tool_data.get("firmware", [])
	for fw in firmware_list:
		if fw is Dictionary:
			var dest_rel: String = str(fw.get("dest_path", fw.get("file_name", "")))
			if dest_rel != "":
				var fw_full_path: String = tool_dir.path_join(dest_rel)
				DirAccess.make_dir_recursive_absolute(fw_full_path.get_base_dir())
				_write_stub_file(fw_full_path, "MOCK_BIOS_FIRMWARE_PAYLOAD")
				created_files.append(fw_full_path)

	return {
		"tool_key": tool_key,
		"tool_dir": tool_dir,
		"created_files": created_files,
		"success": true
	}

## Creates a minimal valid ZIP archive containing specified mock files.
## This is used for fast local mock downloads without external network.
static func create_mock_zip(output_zip_path: String, files: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(output_zip_path.get_base_dir())
	if FileAccess.file_exists(output_zip_path):
		DirAccess.remove_absolute(output_zip_path)

	var zip_packer := ZIPPacker.new()
	var err := zip_packer.open(output_zip_path)
	if err != OK:
		printerr("[MockGameScaffolder] Failed to open ZIPPacker at: ", output_zip_path, " Error: ", err)
		return false

	for file_rel_path in files.keys():
		var content: String = str(files[file_rel_path])
		zip_packer.start_file(file_rel_path)
		zip_packer.write_file(content.to_utf8_buffer())
		zip_packer.close_file()

	zip_packer.close()
	return FileAccess.file_exists(output_zip_path)

## Completely wipes the sandbox directory.
static func purge_sandbox(sandbox_path: String = DEFAULT_SANDBOX_PATH) -> bool:
	var abs_path: String = ProjectSettings.globalize_path(sandbox_path)
	if DirAccess.dir_exists_absolute(abs_path):
		_delete_recursive(abs_path)
	return true

## Collects a flat list of all relative file paths currently present in sandbox.
static func get_sandbox_file_tree(sandbox_path: String = DEFAULT_SANDBOX_PATH) -> Array[String]:
	var result: Array[String] = []
	var abs_base: String = ProjectSettings.globalize_path(sandbox_path)
	_collect_files_recursive(abs_base, "", result)
	result.sort()
	return result

static func _collect_files_recursive(current_dir: String, rel_prefix: String, out_list: Array[String]) -> void:
	var dir := DirAccess.open(current_dir)
	if not dir:
		return
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if file_name != "." and file_name != "..":
			var full_path = current_dir.path_join(file_name)
			var current_rel = rel_prefix.path_join(file_name) if rel_prefix != "" else file_name
			if dir.current_is_dir():
				_collect_files_recursive(full_path, current_rel, out_list)
			else:
				out_list.append(current_rel.replace("\\", "/"))
		file_name = dir.get_next()
	dir.list_dir_end()

static func _write_stub_file(path: String, content: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var fa := FileAccess.open(path, FileAccess.WRITE)
	if fa:
		fa.store_string(content)
		fa.close()

static func _delete_recursive(path: String) -> void:
	var dir := DirAccess.open(path)
	if not dir:
		return
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if file_name != "." and file_name != "..":
			var full = path.path_join(file_name)
			if dir.current_is_dir():
				_delete_recursive(full)
			else:
				DirAccess.remove_absolute(full)
		file_name = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)
