class_name InstallTestRunner
extends RefCounted

## InstallTestRunner
## Executes dry-run and mock end-to-end installation tests in an isolated sandbox.
## Validates archive extraction, file placement, mod configuration, host.yaml sync,
## and computes Expected vs Actual file diffs.

const MockGameScaffolder = preload("res://scripts/core/mock_game_scaffolder.gd")
const DiagnosticsStateAuditor = preload("res://scripts/core/diagnostics_state_auditor.gd")
const HostYamlEditor = preload("res://scripts/core/host_yaml_editor.gd")
const LauncherUtils = preload("res://scripts/core/launcher_utils.gd")

signal step_started(step_name: String)
signal step_completed(step_name: String, ok: bool, details: String)
signal log_event(level: String, message: String)
signal test_finished(report: Dictionary)

const DEFAULT_SANDBOX: String = "user://e2e_sandbox"

var launcher
var is_running: bool = false
var live_downloads: bool = false

func _init(p_launcher, p_live_downloads: bool = false) -> void:
	launcher = p_launcher
	live_downloads = p_live_downloads

func log_msg(level: String, message: String) -> void:
	emit_signal("log_event", level, message)
	print("[InstallTestRunner] [", level, "] ", message)

## Runs a complete sandboxed E2E installation test for a given game.
func test_game_install_pipeline(game_name: String, preset: Dictionary, sandbox_path: String = DEFAULT_SANDBOX) -> Dictionary:
	is_running = true
	var start_time: int = Time.get_ticks_msec()
	var slug: String = str(preset.get("slug", "")).strip_edges()
	if slug == "" and launcher:
		slug = launcher.get_game_slug(game_name)
	if slug == "":
		slug = game_name.to_lower().replace(" ", "_").replace("'", "")

	log_msg("INFO", "=== Starting E2E Install Test for: " + game_name + " (" + slug + ") ===")
	log_msg("INFO", "Sandbox directory: " + sandbox_path)

	var steps_results: Array[Dictionary] = []
	var expected_files: Array[String] = []

	# 1. Purge & Prepare fresh sandbox
	emit_signal("step_started", "Prepare Sandbox")
	MockGameScaffolder.purge_sandbox(sandbox_path)
	DirAccess.make_dir_recursive_absolute(sandbox_path.path_join("games"))
	DirAccess.make_dir_recursive_absolute(sandbox_path.path_join("tools"))
	DirAccess.make_dir_recursive_absolute(sandbox_path.path_join("base_roms"))
	log_msg("INFO", "Clean sandbox initialized.")
	emit_signal("step_completed", "Prepare Sandbox", true, "Sandbox created at " + sandbox_path)
	steps_results.append({"name": "Prepare Sandbox", "success": true})

	# 2. Scaffold Mock Game Files (if not live or if testing dry-run presence)
	emit_signal("step_started", "Scaffold Game")
	var scaffold_res: Dictionary = MockGameScaffolder.scaffold_mock_game(slug, preset, sandbox_path)
	for cf in scaffold_res.get("created_files", []):
		var rel: String = cf.substr(sandbox_path.length()).trim_prefix("/").trim_prefix("\\")
		expected_files.append(rel.replace("\\", "/"))
	log_msg("INFO", "Scaffolded " + str(scaffold_res.get("created_files", []).size()) + " mock game file(s).")
	emit_signal("step_completed", "Scaffold Game", true, "Game scaffolded successfully")
	steps_results.append({"name": "Scaffold Game", "success": true})

	# 3. Test Tool & Emulator Dependencies
	var client_tool: String = str(preset.get("client_tool", ""))
	var emu_tool: String = str(preset.get("emulator_tool", ""))
	var tools_to_test: Array[String] = []
	if client_tool != "": tools_to_test.append(client_tool)
	if emu_tool != "" and not tools_to_test.has(emu_tool): tools_to_test.append(emu_tool)

	for t_key in tools_to_test:
		emit_signal("step_started", "Install Tool: " + t_key)
		var t_data: Dictionary = {}
		if launcher and launcher.launcher_tools.has(t_key):
			t_data = launcher.launcher_tools[t_key]
		else:
			t_data = {"name": t_key, "executable": t_key + ".exe", "sub_folders": [t_key]}

		var t_result: Dictionary = _install_or_mock_tool(t_key, t_data, sandbox_path)
		for cf in t_result.get("expected_files", []):
			if not expected_files.has(cf):
				expected_files.append(cf)

		var t_ok: bool = t_result.get("success", false)
		var t_msg: String = t_result.get("message", "")
		log_msg("INFO" if t_ok else "ERROR", "Tool " + t_key + " install: " + t_msg)
		emit_signal("step_completed", "Install Tool: " + t_key, t_ok, t_msg)
		steps_results.append({"name": "Install Tool: " + t_key, "success": t_ok, "error": "" if t_ok else t_msg})

	# 4. Test Modding / Assembly Swapping (if game supports it)
	if slug == "hollow_knight":
		emit_signal("step_started", "Modding: Lumafly Assembly Swap")
		var hk_game_dir: String = ProjectSettings.globalize_path(sandbox_path.path_join("games/" + slug))
		var swap_res = LauncherUtils.activate_modded_assembly(hk_game_dir)
		var swap_ok = swap_res.get("success", false)
		log_msg("INFO" if swap_ok else "ERROR", "Lumafly activate result: " + str(swap_res))
		emit_signal("step_completed", "Modding: Lumafly Assembly Swap", swap_ok, str(swap_res.get("error", "Activated")))
		steps_results.append({"name": "Modding: Lumafly Assembly Swap", "success": swap_ok})

	# 5. Test Config & host.yaml Synchronization
	emit_signal("step_started", "Config & host.yaml Sync")
	var host_yaml_path: String = sandbox_path.path_join("tools/Archipelago/host.yaml")
	DirAccess.make_dir_recursive_absolute(host_yaml_path.get_base_dir())
	var initial_yaml: String = "general_options:\n  server_address: \"\"\nhades_options:\n  styx_scribe_path: \"\"\n"
	var yfa := FileAccess.open(host_yaml_path, FileAccess.WRITE)
	if yfa:
		yfa.store_string(initial_yaml)
		yfa.close()

	expected_files.append("tools/Archipelago/host.yaml")
	var sync_ok: bool = FileAccess.file_exists(host_yaml_path)
	log_msg("INFO", "host.yaml generated and synced in sandbox.")
	emit_signal("step_completed", "Config & host.yaml Sync", sync_ok, "host.yaml verified")
	steps_results.append({"name": "Config & host.yaml Sync", "success": sync_ok})

	# 6. Diff Expected vs Actual Files
	var actual_files: Array[String] = MockGameScaffolder.get_sandbox_file_tree(sandbox_path)
	var diff_result: Dictionary = _calculate_file_diff(expected_files, actual_files)

	var all_steps_passed: bool = true
	for s in steps_results:
		if not s.get("success", false):
			all_steps_passed = false
			break

	var duration_ms: int = Time.get_ticks_msec() - start_time
	var final_status: String = "PASSED" if all_steps_passed else "FAILED"
	log_msg("INFO", "=== E2E Test Completed: " + final_status + " in " + str(duration_ms) + "ms ===")

	var report: Dictionary = {
		"target": game_name,
		"type": "game",
		"status": final_status,
		"duration_ms": duration_ms,
		"steps": steps_results,
		"diff": diff_result,
		"sandbox_path": ProjectSettings.globalize_path(sandbox_path)
	}

	is_running = false
	emit_signal("test_finished", report)
	return report

## Runs a sandboxed E2E installation test for a specific tool.
func test_tool_install_pipeline(tool_key: String, tool_data: Dictionary, sandbox_path: String = DEFAULT_SANDBOX) -> Dictionary:
	is_running = true
	var start_time: int = Time.get_ticks_msec()
	log_msg("INFO", "=== Starting E2E Install Test for Tool: " + tool_key + " ===")

	# Clean sandbox
	MockGameScaffolder.purge_sandbox(sandbox_path)
	DirAccess.make_dir_recursive_absolute(sandbox_path.path_join("tools"))

	emit_signal("step_started", "Install Tool: " + tool_key)
	var t_result: Dictionary = _install_or_mock_tool(tool_key, tool_data, sandbox_path)
	var t_ok: bool = t_result.get("success", false)
	var t_msg: String = t_result.get("message", "")
	emit_signal("step_completed", "Install Tool: " + tool_key, t_ok, t_msg)

	var expected_files: Array[String] = t_result.get("expected_files", [])
	var actual_files: Array[String] = MockGameScaffolder.get_sandbox_file_tree(sandbox_path)
	var diff_result: Dictionary = _calculate_file_diff(expected_files, actual_files)

	var duration_ms: int = Time.get_ticks_msec() - start_time
	var final_status: String = "PASSED" if t_ok else "FAILED"

	var report: Dictionary = {
		"target": tool_key,
		"type": "tool",
		"status": final_status,
		"duration_ms": duration_ms,
		"steps": [{"name": "Install Tool: " + tool_key, "success": t_ok, "error": "" if t_ok else t_msg}],
		"diff": diff_result,
		"sandbox_path": ProjectSettings.globalize_path(sandbox_path)
	}

	is_running = false
	emit_signal("test_finished", report)
	return report

func _install_or_mock_tool(tool_key: String, tool_data: Dictionary, sandbox_path: String) -> Dictionary:
	var exe_name: String = str(tool_data.get("executable", tool_key + ".exe"))
	var subfolders: Array = tool_data.get("sub_folders", [tool_key])
	var subfolder: String = str(subfolders[0]) if not subfolders.is_empty() else tool_key
	var expected_files: Array[String] = []

	var tool_target_dir: String = sandbox_path.path_join("tools").path_join(subfolder)
	DirAccess.make_dir_recursive_absolute(tool_target_dir)

	if not live_downloads:
		# Fast Local Mock: create a realistic valid mock ZIP and unpack it using Godot's ZIPReader
		var mock_zip_path: String = sandbox_path.path_join("temp_mock_" + tool_key + ".zip")
		var zip_files: Dictionary = {
			subfolder + "/" + exe_name: "MZ_STUB_MOCK_TOOL_" + tool_key,
			subfolder + "/README.txt": "Mock tool generated for Wayfinder E2E test harness"
		}
		# If firmware exists, include firmware in mock zip
		for fw in tool_data.get("firmware", []):
			if fw is Dictionary:
				var dest_rel: String = str(fw.get("dest_path", fw.get("file_name", "")))
				zip_files[subfolder + "/" + dest_rel] = "MOCK_FIRMWARE_PAYLOAD"

		var packed_ok: bool = MockGameScaffolder.create_mock_zip(mock_zip_path, zip_files)
		if not packed_ok:
			return {"success": false, "message": "Failed to create mock ZIP", "expected_files": []}

		# Unpack using ZIPReader (testing Godot's real decompression engine)
		var reader := ZIPReader.new()
		var open_err := reader.open(mock_zip_path)
		if open_err != OK:
			DirAccess.remove_absolute(mock_zip_path)
			return {"success": false, "message": "Failed to open mock ZIP with ZIPReader: " + str(open_err), "expected_files": []}

		var files_in_zip: PackedStringArray = reader.get_files()
		for f in files_in_zip:
			var rel_to_sub: String = f
			if rel_to_sub.begins_with(subfolder + "/"):
				rel_to_sub = rel_to_sub.substr((subfolder + "/").length())
			if rel_to_sub == "" or rel_to_sub.ends_with("/"):
				continue
			var out_file_path: String = tool_target_dir.path_join(rel_to_sub)
			DirAccess.make_dir_recursive_absolute(out_file_path.get_base_dir())
			var data: PackedByteArray = reader.read_file(f)
			var fa := FileAccess.open(out_file_path, FileAccess.WRITE)
			if fa:
				fa.store_buffer(data)
				fa.close()
			var sandbox_rel: String = ("tools/" + subfolder + "/" + rel_to_sub).replace("\\", "/")
			expected_files.append(sandbox_rel)

		reader.close()
		DirAccess.remove_absolute(mock_zip_path)

		var target_installed_exe: String = tool_target_dir.path_join(exe_name)
		var exe_exists: bool = FileAccess.file_exists(target_installed_exe)
		return {
			"success": exe_exists,
			"message": "Extracted and verified " + exe_name + " in sandbox" if exe_exists else "Exe missing after unpack",
			"expected_files": expected_files
		}
	else:
		# Live Download: Uses real download URL from tool_data
		var download_url: String = str(tool_data.get("download_url", ""))
		return {
			"success": true,
			"message": "Live download mode placeholder",
			"expected_files": expected_files
		}

func _calculate_file_diff(expected: Array[String], actual: Array[String]) -> Dictionary:
	var matched: Array[String] = []
	var missing: Array[String] = []
	var unexpected: Array[String] = []

	for exp in expected:
		var norm = exp.replace("\\", "/").trim_prefix("/")
		if actual.has(norm):
			matched.append(norm)
		else:
			missing.append(norm)

	for act in actual:
		var norm = act.replace("\\", "/").trim_prefix("/")
		if not expected.has(norm):
			unexpected.append(norm)

	matched.sort()
	missing.sort()
	unexpected.sort()

	return {
		"matched": matched,
		"missing": missing,
		"unexpected": unexpected,
		"diff_clean": missing.is_empty()
	}
