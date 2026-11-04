class_name ArchipelagoConfig
extends RefCounted

const HostYamlEditorScript = preload("res://scripts/core/host_yaml_editor.gd")

const USER_TOOLS_DIR: String = "user://tools"
const USER_BASE_ROMS_DIR: String = "user://base_roms"
const USER_GAMES_DIR: String = "user://games"



## Injects emulator firmware configuration into an emulator INI/config file
static func inject_emulator_firmware_config(emulator_dir: String, emu_cfg: Dictionary) -> void:
	if emu_cfg.is_empty():
		return
	var cfg_file: String = emu_cfg.get("file", "config.ini")
	var section: String = emu_cfg.get("section", "")
	var key: String = emu_cfg.get("key", "")
	var val: String = emu_cfg.get("value", "")
	if section == "" or key == "" or val == "":
		return

	var cfg_path: String = emulator_dir.path_join(cfg_file)
	if not FileAccess.file_exists(cfg_path):
		return
	var fa_in: FileAccess = FileAccess.open(cfg_path, FileAccess.READ)
	if not fa_in:
		return
	var cfg_text: String = fa_in.get_as_text()
	fa_in.close()

	var quote_key: String = "\"" + key + "\""
	if cfg_text.contains(quote_key):
		return

	var sec_open: String = "\"" + section + "\": {"
	var sec_bare: String = "\"" + section + "\":"
	if cfg_text.contains(sec_open):
		cfg_text = cfg_text.replace(
			sec_open,
			sec_open + "\n    \"" + key + "\": \"" + val + "\","
		)
	elif cfg_text.contains(sec_bare):
		cfg_text = cfg_text.replace(
			sec_bare,
			sec_bare + " {\n    \"" + key + "\": \"" + val + "\"\n  },"
		)

	var fa_out: FileAccess = FileAccess.open(cfg_path, FileAccess.WRITE)
	if fa_out:
		fa_out.store_string(cfg_text)
		fa_out.close()
		print("[ArchipelagoConfig] Updated ", cfg_file, " with [", section, "] ", key, " = ", val)

## Configures BizHawk preferred core in config.ini (e.g. SNES -> BSNESv115+)
static func configure_bizhawk_preferred_core(bizhawk_exe_path: String, system: String, core_name: String) -> void:
	if bizhawk_exe_path.strip_edges() == "":
		return
	var emu_dir: String = ProjectSettings.globalize_path(bizhawk_exe_path).get_base_dir()
	var cfg_path: String = emu_dir.path_join("config.ini")
	if not FileAccess.file_exists(cfg_path):
		return
	var fa_in: FileAccess = FileAccess.open(cfg_path, FileAccess.READ)
	if not fa_in:
		return
	var content: String = fa_in.get_as_text()
	fa_in.close()

	var regex = RegEx.new()
	regex.compile("\"" + system + "\"\\s*:\\s*\"[^\"]*\"")
	if regex.search(content):
		content = regex.sub(content, "\"" + system + "\": \"" + core_name + "\"")
	elif content.contains("\"PreferredCores\": {"):
		content = content.replace(
			"\"PreferredCores\": {",
			"\"PreferredCores\": {\n    \"" + system + "\": \"" + core_name + "\","
		)

	var fa_w: FileAccess = FileAccess.open(cfg_path, FileAccess.WRITE)
	if fa_w:
		fa_w.store_string(content)
		fa_w.close()
		print("[ArchipelagoConfig] Configured BizHawk preferred core for " + system + " -> " + core_name)

## Injects server URL into archipelago.json inside an .ap* patch archive
static func inject_server_into_ap_patch(patch_path: String, clean_url: String) -> void:
	if clean_url == "" or patch_path == "" or not FileAccess.file_exists(patch_path):
		return
	var reader: ZIPReader = ZIPReader.new()
	var err: Error = reader.open(patch_path)
	if err != OK:
		return
	var files: PackedStringArray = reader.get_files()
	if not "archipelago.json" in files:
		reader.close()
		return
		
	var arch_bytes: PackedByteArray = reader.read_file("archipelago.json")
	var parsed: Variant = JSON.parse_string(arch_bytes.get_string_from_utf8())
	if not (parsed is Dictionary):
		reader.close()
		return
		
	if str(parsed.get("server", "")) == clean_url:
		reader.close()
		return
		
	parsed["server"] = clean_url
	var updated_arch_bytes: PackedByteArray = JSON.stringify(parsed, "  ").to_utf8_buffer()
	
	var temp_dest: String = patch_path + ".tmp"
	var packer: ZIPPacker = ZIPPacker.new()
	if packer.open(temp_dest) != OK:
		reader.close()
		return
		
	for f in files:
		if f.ends_with("/"):
			continue
		packer.start_file(f)
		if f == "archipelago.json":
			packer.write_file(updated_arch_bytes)
		else:
			packer.write_file(reader.read_file(f))
		packer.close_file()
		
	reader.close()
	packer.close()
	
	DirAccess.copy_absolute(temp_dest, patch_path)
	DirAccess.remove_absolute(temp_dest)
	print("[ArchipelagoConfig] Injected server address '", clean_url, "' into patch: ", patch_path)

## Updates Archipelago _persistent_storage.yaml with the active server address
static func update_archipelago_persistent_storage(clean_url: String, tools_dir: String = USER_TOOLS_DIR) -> void:
	if clean_url == "":
		return
	var possible_paths: Array[String] = [
		tools_dir.path_join("Archipelago/_persistent_storage.yaml"),
		ProjectSettings.globalize_path(tools_dir).path_join("Archipelago/_persistent_storage.yaml")
	]
	if OS.get_name() == "Windows":
		var appdata: String = OS.get_environment("APPDATA")
		if appdata != "":
			possible_paths.append(appdata.path_join("Archipelago/_persistent_storage.yaml"))
			
	for p in possible_paths:
		var norm_p: String = ProjectSettings.globalize_path(p).replace("\\", "/")
		var dir_p: String = norm_p.get_base_dir()
		if not DirAccess.dir_exists_absolute(dir_p):
			continue
			
		var content: String = ""
		if FileAccess.file_exists(norm_p):
			var fa: FileAccess = FileAccess.open(norm_p, FileAccess.READ)
			if fa:
				content = fa.get_as_text()
				fa.close()
				
		if "client:" in content:
			var lines: PackedStringArray = content.split("\n")
			var new_lines: Array[String] = []
			var in_client: bool = false
			var updated_addr: bool = false
			for line in lines:
				var stripped: String = line.strip_edges()
				if stripped == "client:":
					in_client = true
					new_lines.append(line)
					continue
				if in_client and (stripped.begins_with("last_server_address:") or stripped.begins_with("server_address:")):
					new_lines.append("  last_server_address: " + clean_url)
					updated_addr = true
					continue
				if in_client and not line.begins_with(" ") and not line.begins_with("\t") and stripped != "":
					in_client = false
					if not updated_addr:
						new_lines.insert(new_lines.size() - 1, "  last_server_address: " + clean_url)
						updated_addr = true
				new_lines.append(line)
			if in_client and not updated_addr:
				new_lines.append("  last_server_address: " + clean_url)
			content = "\n".join(new_lines)
		else:
			content = "client:\n  last_server_address: " + clean_url + "\n" + content
			
		var out_fa: FileAccess = FileAccess.open(norm_p, FileAccess.WRITE)
		if out_fa:
			out_fa.store_string(content)
			out_fa.close()
			print("[ArchipelagoConfig] Updated Archipelago persistent storage with server address: ", clean_url)

## Returns destinations for Archipelago custom worlds
static func get_custom_world_destinations(tools_dir: String = USER_TOOLS_DIR) -> Array[String]:
	var dests: Array[String] = [
		tools_dir.path_join("Archipelago/custom_worlds")
	]
	if OS.get_name() == "Windows":
		var local_appdata: String = OS.get_environment("LOCALAPPDATA")
		if local_appdata != "":
			var local_dest: String = local_appdata.path_join("Archipelago/custom_worlds")
			if not dests.has(local_dest):
				dests.append(local_dest)
	elif OS.get_environment("HOME") != "":
		var home_dest: String = OS.get_environment("HOME").path_join("Archipelago/custom_worlds")
		if not dests.has(home_dest):
			dests.append(home_dest)
	return dests

## Updates an individual key in a YAML section or subsection cleanly.
## option_path can be a simple key ("rom_file") or dot-separated ("dolphin_settings.path").
## val can be a String, bool, int, float, or Array/Dictionary.
static func update_yaml_value(yaml_content: String, section_key: String, option_path: String, val: Variant, extra_lines: Array[String] = []) -> String:
	var editor = HostYamlEditorScript.new(yaml_content)
	var full_path: String = section_key + "." + option_path
	editor.set_value_at_path(full_path, val)
	for extra in extra_lines:
		var parts: PackedStringArray = extra.split(":")
		if parts.size() == 2:
			var extra_k: String = parts[0].strip_edges()
			var extra_v: String = parts[1].strip_edges()
			if extra_v == "true":
				editor.set_value_at_path(section_key + "." + extra_k, true)
			elif extra_v == "false":
				editor.set_value_at_path(section_key + "." + extra_k, false)
			else:
				editor.set_value_at_path(section_key + "." + extra_k, extra_v)
	return editor.to_string_content()

## Updates an individual key in a YAML section cleanly (backwards-compatible wrapper)
static func update_yaml_section_key(yaml_content: String, section_key: String, option_key: String, option_val: String, extra_lines: Array[String] = []) -> String:
	return update_yaml_value(yaml_content, section_key, option_key, option_val, extra_lines)

## Applies a dictionary of key-value patches to a given section
static func patch_yaml_section(yaml_content: String, section_key: String, patches: Dictionary) -> String:
	var editor = HostYamlEditorScript.new(yaml_content)
	for opt_path in patches.keys():
		editor.set_value_at_path(section_key + "." + str(opt_path), patches[opt_path])
	return editor.to_string_content()

## Updates bizhawkclient_options block in host.yaml
static func update_yaml_bizhawk_block(yaml_content: String, absolute_bizhawk_path: String) -> String:
	var editor = HostYamlEditorScript.new(yaml_content)
	editor.set_value_at_path("bizhawkclient_options.emuhawk_path", absolute_bizhawk_path)
	editor.set_value_at_path("bizhawkclient_options.rom_start", true)
	return editor.to_string_content()

## Updates Dolphin settings in host.yaml for Luigi's Mansion and GameCube titles
static func update_yaml_dolphin_block(yaml_content: String, absolute_dolphin_path: String) -> String:
	var editor = HostYamlEditorScript.new(yaml_content)
	editor.set_value_at_path("luigismansion_options.dolphin_settings.path", absolute_dolphin_path)
	editor.set_value_at_path("luigismansion_options.dolphin_settings.auto_start", true)
	return editor.to_string_content()

## Synchronizes host.yaml across all candidate locations for Archipelago
static func sync_archipelago_host_yaml(
	rom_path: String,
	bizhawk_path: String = "",
	dolphin_path: String = "",
	server_url: String = "",
	launcher_presets: Dictionary = {},
	paths_config: Dictionary = {},
	tools_dir: String = USER_TOOLS_DIR,
	find_exec_cb: Callable = Callable(),
	sync_custom_worlds_cb: Callable = Callable()
) -> void:
	if bizhawk_path == "":
		bizhawk_path = paths_config.get("bizhawk_emulator", "")
		if (bizhawk_path == "" or not FileAccess.file_exists(bizhawk_path)) and find_exec_cb.is_valid():
			bizhawk_path = str(find_exec_cb.call(tools_dir, "EmuHawk.exe"))
	if dolphin_path == "":
		dolphin_path = paths_config.get("dolphin_emulator", "")
		if (dolphin_path == "" or not FileAccess.file_exists(dolphin_path)) and find_exec_cb.is_valid():
			dolphin_path = str(find_exec_cb.call(tools_dir, "Dolphin.exe"))

	var possible_host_yaml_paths: Array[String] = get_archipelago_host_yaml_paths(tools_dir)
	var absolute_rom_path: String = ProjectSettings.globalize_path(rom_path).replace("\\", "/")
	var absolute_bizhawk_path: String = ProjectSettings.globalize_path(bizhawk_path).replace("\\", "/") if bizhawk_path != "" else ""
	var absolute_dolphin_path: String = ProjectSettings.globalize_path(dolphin_path).replace("\\", "/") if dolphin_path != "" else ""

	cleanup_legacy_archipelago_rom_copies(tools_dir)
	if sync_custom_worlds_cb.is_valid():
		sync_custom_worlds_cb.call()

	if server_url == "" and Engine.has_singleton("NetworkManager"):
		var nm = Engine.get_singleton("NetworkManager")
		if nm and nm.has_method("get_ap_server_url"):
			server_url = nm.get_ap_server_url()

	for target_yaml_path in possible_host_yaml_paths:
		write_synced_host_yaml_file(target_yaml_path, absolute_rom_path, absolute_bizhawk_path, absolute_dolphin_path, server_url, launcher_presets)

static func get_archipelago_host_yaml_paths(tools_dir: String = USER_TOOLS_DIR) -> Array[String]:
	var possible_paths: Array[String] = [
		tools_dir.path_join("Archipelago/host.yaml")
	]
	if OS.get_name() == "Windows":
		var appdata_dir: String = OS.get_environment("APPDATA")
		if appdata_dir != "":
			possible_paths.append(appdata_dir.path_join("Archipelago").path_join("host.yaml"))
		var local_appdata_dir: String = OS.get_environment("LOCALAPPDATA")
		if local_appdata_dir != "":
			possible_paths.append(local_appdata_dir.path_join("Archipelago").path_join("host.yaml"))
		possible_paths.append("C:/ProgramData/Archipelago/host.yaml")
	if OS.get_environment("HOME") != "":
		possible_paths.append(OS.get_environment("HOME").path_join("Archipelago").path_join("host.yaml"))
	return possible_paths

static func cleanup_legacy_archipelago_rom_copies(tools_dir: String = USER_TOOLS_DIR) -> void:
	var ap_base_roms_dir: String = tools_dir.path_join("Archipelago/base_roms")
	if DirAccess.dir_exists_absolute(ap_base_roms_dir):
		var da: DirAccess = DirAccess.open(ap_base_roms_dir)
		if da:
			da.list_dir_begin()
			var fn: String = da.get_next()
			while fn != "":
				if not da.current_is_dir() and not fn.begins_with("."):
					DirAccess.remove_absolute(ap_base_roms_dir.path_join(fn))
				fn = da.get_next()
		DirAccess.remove_absolute(ap_base_roms_dir)
		print("[ArchipelagoConfig] Cleaned up legacy tools/Archipelago/base_roms directory")

	var ap_dir: String = tools_dir.path_join("Archipelago")
	if DirAccess.dir_exists_absolute(ap_dir):
		var ap_da: DirAccess = DirAccess.open(ap_dir)
		if ap_da:
			var rom_extensions: PackedStringArray = [
				"iso", "rvz", "bin", "cue", "gba", "gbc", "gb",
				"sfc", "smc", "z64", "n64", "nds", "gcm", "cso",
				"chd", "wbfs"
			]
			ap_da.list_dir_begin()
			var f: String = ap_da.get_next()
			while f != "":
				if not ap_da.current_is_dir() and not f.begins_with("."):
					var f_ext: String = f.get_extension().to_lower()
					if rom_extensions.has(f_ext):
						DirAccess.remove_absolute(ap_dir.path_join(f))
						print("[ArchipelagoConfig] Cleaned up redundant ROM from tools/Archipelago: ", f)
				f = ap_da.get_next()

static func write_synced_host_yaml_file(target_yaml_path: String, absolute_rom_path: String, absolute_bizhawk_path: String, absolute_dolphin_path: String = "", server_url: String = "", launcher_presets: Dictionary = {}) -> void:
	var dir_path: String = target_yaml_path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(dir_path)

	var yaml_content: String = ""
	if FileAccess.file_exists(target_yaml_path):
		var file_access: FileAccess = FileAccess.open(target_yaml_path, FileAccess.READ)
		if file_access:
			yaml_content = file_access.get_as_text()
			file_access.close()

	var editor = HostYamlEditorScript.new(yaml_content)

	var rom_ext: String = absolute_rom_path.get_extension().to_lower()
	var rom_filename_lower: String = absolute_rom_path.get_file().to_lower()
	var clean_server_addr: String = server_url.replace("wss://", "").replace("ws://", "").trim_suffix("/")
	if clean_server_addr == "" and Engine.has_singleton("NetworkManager"):
		var nm = Engine.get_singleton("NetworkManager")
		if nm and nm.has_method("get_ap_server_url"):
			clean_server_addr = nm.get_ap_server_url().replace("wss://", "").replace("ws://", "").trim_suffix("/")

	var matched_dolphin: bool = false
	var matched_bizhawk: bool = false

	for game_key in launcher_presets.keys():
		var preset: Dictionary = launcher_presets[game_key]
		if not (preset.has("host_yaml") and preset["host_yaml"] is Dictionary):
			continue

		var req_rom: String = preset.get("required_rom", "")
		var req_ext: String = req_rom.get_extension().to_lower()
		var is_matching_rom: bool = false

		if req_ext != "" and req_ext == rom_ext:
			is_matching_rom = true
		else:
			for alias in preset.get("rom_aliases", []):
				if str(alias).get_extension().to_lower() == rom_ext:
					is_matching_rom = true
					break

		if not is_matching_rom and rom_ext == "exe":
			var client_exec: String = preset.get("client_executable", preset.get("executable_name", "")).to_lower()
			if client_exec != "" and (rom_filename_lower == client_exec or client_exec.get_file() == rom_filename_lower):
				is_matching_rom = true
			else:
				for exec_alias in preset.get("executable_aliases", []):
					if str(exec_alias).to_lower() == rom_filename_lower:
						is_matching_rom = true
						break

		if is_matching_rom:
			var host_cfg: Dictionary = preset["host_yaml"]
			var req_audio: String = preset.get("required_audio_rom", "")
			
			var resolved_cfg: Dictionary = resolve_host_yaml_tree(
				host_cfg,
				absolute_rom_path,
				absolute_bizhawk_path,
				absolute_dolphin_path,
				server_url,
				clean_server_addr,
				rom_filename_lower,
				req_audio
			)
			editor.apply_dictionary(resolved_cfg)

			if resolved_cfg.has("luigismansion_options") or resolved_cfg.has("dolphin_settings"):
				matched_dolphin = true
			if resolved_cfg.has("bizhawkclient_options"):
				matched_bizhawk = true

	if absolute_dolphin_path != "" and not matched_dolphin:
		editor.set_value_at_path("luigismansion_options.dolphin_settings.path", absolute_dolphin_path)
		editor.set_value_at_path("luigismansion_options.dolphin_settings.auto_start", true)

	if absolute_bizhawk_path != "" and not matched_bizhawk:
		editor.set_value_at_path("bizhawkclient_options.emuhawk_path", absolute_bizhawk_path)
		editor.set_value_at_path("bizhawkclient_options.rom_start", true)

	var writer_file: FileAccess = FileAccess.open(target_yaml_path, FileAccess.WRITE)
	if writer_file:
		writer_file.store_string(editor.to_string_content())
		writer_file.close()
		print("[ArchipelagoConfig] Synced Archipelago host.yaml at: ", target_yaml_path)

static func resolve_host_yaml_tree(node: Variant, rom_path: String, bizhawk_path: String, dolphin_path: String, server_url: String, clean_server_addr: String, rom_filename_lower: String, req_audio: String) -> Variant:
	if typeof(node) == TYPE_DICTIONARY:
		var dict: Dictionary = node as Dictionary
		if dict.has("when_filename_matches"):
			var pattern: String = str(dict["when_filename_matches"]).to_lower().trim_prefix("*").trim_suffix("*")
			if pattern != "" and not rom_filename_lower.contains(pattern):
				return null
			return resolve_host_yaml_tree(dict.get("value", "{rom_path}"), rom_path, bizhawk_path, dolphin_path, server_url, clean_server_addr, rom_filename_lower, req_audio)

		var resolved_dict: Dictionary = {}
		for k in dict.keys():
			var child_res = resolve_host_yaml_tree(dict[k], rom_path, bizhawk_path, dolphin_path, server_url, clean_server_addr, rom_filename_lower, req_audio)
			if child_res != null:
				resolved_dict[k] = child_res
		return resolved_dict

	if typeof(node) == TYPE_STRING:
		var audio_path: String = ""
		if req_audio != "":
			audio_path = find_supplemental_rom_path(rom_path, req_audio)
		return evaluate_yaml_template(str(node), rom_path, bizhawk_path, dolphin_path, server_url, clean_server_addr, audio_path)

	return node

static func evaluate_yaml_template(raw_str: String, rom_path: String, bizhawk_path: String, dolphin_path: String, server_url: String, clean_server_addr: String, audio_path: String = "") -> String:
	var res: String = raw_str
	res = res.replace("{rom_path}", rom_path)
	res = res.replace("{game_dir}", rom_path.get_base_dir() if rom_path.get_extension() != "" else rom_path)
	res = res.replace("{bizhawk_path}", bizhawk_path)
	res = res.replace("{dolphin_path}", dolphin_path)
	res = res.replace("{audio_path}", audio_path)
	res = res.replace("{server_url}", server_url)
	res = res.replace("{server_address}", clean_server_addr)
	res = res.replace("{server_host}", clean_server_addr.split(":")[0] if clean_server_addr.contains(":") else clean_server_addr)
	res = res.replace("{server_port}", clean_server_addr.split(":")[1] if clean_server_addr.contains(":") else "38000")
	return res

static func find_supplemental_rom_path(rom_path: String, target_filename: String) -> String:
	if target_filename == "":
		return ""
	var game_slug: String = target_filename.get_basename().to_lower().replace(" ", "_").replace("-", "_")
	var game_folder: String = USER_GAMES_DIR.path_join(game_slug)
	var candidate_paths: Array[String] = [
		game_folder.path_join(target_filename),
		ProjectSettings.globalize_path(game_folder).path_join(target_filename),
		USER_BASE_ROMS_DIR.path_join(target_filename),
		ProjectSettings.globalize_path(USER_BASE_ROMS_DIR).path_join(target_filename)
	]
	if rom_path != "":
		var base_dir: String = rom_path.get_base_dir()
		candidate_paths.append(base_dir.path_join(target_filename))
		if "Track 1" in rom_path and "Track 2" in target_filename:
			candidate_paths.append(rom_path.replace("Track 1", "Track 2"))
		elif "track 1" in rom_path and "track 2" in target_filename.to_lower():
			candidate_paths.append(rom_path.replace("track 1", "track 2"))
		elif "Disc 1" in rom_path and "Disc 2" in target_filename:
			candidate_paths.append(rom_path.replace("Disc 1", "Disc 2"))
		elif "disc 1" in rom_path and "disc 2" in target_filename.to_lower():
			candidate_paths.append(rom_path.replace("disc 1", "disc 2"))
	
	for c_path in candidate_paths:
		var norm_path: String = ProjectSettings.globalize_path(c_path).replace("\\", "/")
		if FileAccess.file_exists(norm_path):
			return norm_path
	return ""
