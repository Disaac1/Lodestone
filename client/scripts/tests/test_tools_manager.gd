extends SceneTree

# =====================================================================
#             TEST SUITE: TOOL & DEPENDENCY MANAGER
# =====================================================================
# Validates ToolManager status calculation, disk usage auditing,
# recursive directory deletion, uninstallation, external linking,
# and ToolsManagerModal UI rendering.
# =====================================================================

var test_passed: bool = true
var lobby: Node

func _init() -> void:
	_run_suite.call_deferred()

func _fail(reason: String) -> void:
	printerr("  ❌ [FAIL] ", reason)
	test_passed = false

func _assert_true(cond: bool, msg: String) -> void:
	if not cond:
		_fail(msg)

func _finish() -> void:
	print("\n==================================================================")
	if test_passed:
		print("  ALL TOOLS MANAGER TESTS PASSED! [OK]                           ")
	else:
		print("  TOOLS MANAGER TESTS ENCOUNTERED FAILURES! [ERROR]              ")
	print("==================================================================")
	quit(0 if test_passed else 1)

func _run_suite() -> void:
	print("==================================================================")
	print("  TEST SUITE: TOOL & DEPENDENCY MANAGER                          ")
	print("==================================================================")

	var lobby_scene = load("res://scenes/lobby.tscn")
	if not lobby_scene:
		_fail("Failed to load res://scenes/lobby.tscn")
		_finish()
		return

	lobby = lobby_scene.instantiate()
	root.add_child(lobby)

	_test_format_bytes()
	_test_dir_size_and_recursive_removal()
	_test_tool_status_and_lifecycle()
	_test_uninstall_and_cleanup()
	_test_external_path_linking()
	_test_modal_ui()

	_finish()

func _test_format_bytes() -> void:
	print("\n[Test 1] Verifying format_bytes formatting...")
	_assert_true(ToolManager.format_bytes(0) == "0 B", "0 bytes should be '0 B'")
	_assert_true(ToolManager.format_bytes(512) == "512 B", "512 bytes should be '512 B'")
	_assert_true(ToolManager.format_bytes(1024) == "1.0 KB", "1024 bytes should be '1.0 KB'")
	_assert_true(ToolManager.format_bytes(2048 * 1024) == "2.0 MB", "2048 KB should be '2.0 MB'")
	_assert_true(ToolManager.format_bytes(int(1.5 * 1024 * 1024 * 1024)) == "1.50 GB", "1.5 GB should be '1.50 GB'")
	print("  -> Passed: format_bytes produces expected human-readable sizes.")

func _test_dir_size_and_recursive_removal() -> void:
	print("\n[Test 2] Verifying recursive directory size and removal...")
	var test_dir := "user://test_tools_dir"
	var sub_dir := test_dir.path_join("nested_folder")
	DirAccess.make_dir_recursive_absolute(sub_dir)

	var f1 := FileAccess.open(test_dir.path_join("file1.bin"), FileAccess.WRITE)
	f1.store_buffer(PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8])) # 8 bytes
	f1.close()

	var f2 := FileAccess.open(sub_dir.path_join("file2.bin"), FileAccess.WRITE)
	f2.store_buffer(PackedByteArray([10, 20, 30, 40])) # 4 bytes
	f2.close()

	var measured_size := ToolManager.get_dir_size_bytes(test_dir)
	_assert_true(measured_size == 12, "Measured directory size should be 12 bytes, got " + str(measured_size))

	var removed := ToolManager.remove_dir_recursive(test_dir)
	_assert_true(removed, "remove_dir_recursive should report success")
	_assert_true(not DirAccess.dir_exists_absolute(test_dir), "test_tools_dir should be deleted")
	print("  -> Passed: Recursive directory size calculation and cleanup verified.")

func _test_tool_status_and_lifecycle() -> void:
	print("\n[Test 3] Verifying tool status resolution and integrity checks...")
	var mock_config: Dictionary = {}
	var launcher = lobby.launcher
	var locator = launcher._executable_locator
	var save_called := [false]
	var tm := ToolManager.new(mock_config, locator, func(): save_called[0] = true)

	var mock_tool_def := {
		"name": "Mock Tool Unique",
		"executable": "MockToolUnique.exe",
		"sub_folders": ["MockToolUniqueFolder"]
	}

	var status_not_inst := tm.get_tool_status("mock_tool_unique", mock_tool_def)
	_assert_true(status_not_inst.installed == false, "Mock tool should initially be not installed")
	_assert_true(status_not_inst.status_code == "NOT_INSTALLED", "Status code should be NOT_INSTALLED")

	# Create a mock corrupt Dolphin missing Qt
	var mock_dolphin_dir := "user://tools/MockDolphinFolder"
	DirAccess.make_dir_recursive_absolute(mock_dolphin_dir)
	var exe_file := FileAccess.open(mock_dolphin_dir.path_join("dolphin.exe"), FileAccess.WRITE)
	exe_file.store_string("mock dolphin binary")
	exe_file.close()

	var dolphin_tool_def := {
		"name": "Mock Dolphin",
		"executable": "dolphin.exe",
		"sub_folders": ["MockDolphinFolder"]
	}

	var status_corrupt := tm.get_tool_status("dolphin", dolphin_tool_def)
	_assert_true(status_corrupt.installed == true, "Tool exe exists so installed is true")
	_assert_true(status_corrupt.status_code == "CORRUPT", "Dolphin missing qwindows.dll should be marked CORRUPT")

	# Add Qt plugin to satisfy integrity
	var qt_dir := mock_dolphin_dir.path_join("QtPlugins/platforms")
	DirAccess.make_dir_recursive_absolute(qt_dir)
	var qt_file := FileAccess.open(qt_dir.path_join("qwindows.dll"), FileAccess.WRITE)
	qt_file.store_string("mock qt plugin")
	qt_file.close()

	var status_valid := tm.get_tool_status("dolphin", dolphin_tool_def)
	_assert_true(status_valid.status_code == "INSTALLED", "Dolphin with qwindows.dll should be INSTALLED")
	_assert_true(status_valid.is_managed == true, "Tool in user://tools should be managed")
	_assert_true(status_valid.size_bytes > 0, "Tool size should be greater than 0")

	# Clean up
	ToolManager.remove_dir_recursive(mock_dolphin_dir)
	print("  -> Passed: Tool status calculation and integrity auditing verified.")

func _test_uninstall_and_cleanup() -> void:
	print("\n[Test 4] Verifying uninstall_tool cleans disk and paths_config...")
	var mock_config: Dictionary = {
		"test_tool": "user://tools/TestToolFolder/TestTool.exe",
		"test_tool_emulator": "user://tools/TestToolFolder/TestTool.exe"
	}
	var save_called := [false]
	var tm := ToolManager.new(mock_config, null, func(): save_called[0] = true)

	var tool_dir := "user://tools/TestToolFolder"
	DirAccess.make_dir_recursive_absolute(tool_dir)
	var f := FileAccess.open(tool_dir.path_join("TestTool.exe"), FileAccess.WRITE)
	f.store_string("mock binary")
	f.close()

	var temp_f := FileAccess.open("user://tools/temp_test_tool.zip", FileAccess.WRITE)
	temp_f.store_string("mock temp zip")
	temp_f.close()

	var tool_def := {
		"name": "Test Tool",
		"executable": "TestTool.exe",
		"sub_folders": ["TestToolFolder"],
		"download_url": "/tools/testtool.zip"
	}

	var res := tm.uninstall_tool("test_tool", tool_def)
	_assert_true(res.success == true, "uninstall_tool should report success")
	_assert_true(not DirAccess.dir_exists_absolute(tool_dir), "Tool directory should be deleted")
	_assert_true(not FileAccess.file_exists("user://tools/temp_test_tool.zip"), "Temp zip should be deleted")
	_assert_true(not mock_config.has("test_tool"), "paths_config should clear test_tool")
	_assert_true(not mock_config.has("test_tool_emulator"), "paths_config should clear test_tool_emulator")
	_assert_true(save_called[0] == true, "save_paths_callback should be triggered")
	print("  -> Passed: Tool uninstallation and workspace cleanup verified.")

func _test_external_path_linking() -> void:
	print("\n[Test 5] Verifying external tool path linking and unlinking...")
	var mock_config: Dictionary = {}
	var save_called := [false]
	var tm := ToolManager.new(mock_config, null, func(): save_called[0] = true)

	var ext_dir := "user://external_tool_test"
	DirAccess.make_dir_recursive_absolute(ext_dir)
	var ext_exe := ext_dir.path_join("EmuHawk.exe")
	var f := FileAccess.open(ext_exe, FileAccess.WRITE)
	f.store_string("mock emuhawk")
	f.close()

	var tool_def := {
		"name": "BizHawk",
		"executable": "EmuHawk.exe",
		"sub_folders": ["BizHawk"]
	}

	var link_res := tm.set_external_tool_path("bizhawk", tool_def, ext_exe)
	_assert_true(link_res.success == true, "set_external_tool_path should report success")
	_assert_true(mock_config.get("bizhawk") == ext_exe, "bizhawk config key set")
	_assert_true(mock_config.get("bizhawk_emulator") == ext_exe, "bizhawk_emulator config key set")

	var status := tm.get_tool_status("bizhawk", tool_def)
	_assert_true(status.installed == true, "Tool should be resolved as installed")
	_assert_true(status.is_managed == false, "External tool should NOT be managed")
	_assert_true(status.status_code == "EXTERNAL", "Status code should be EXTERNAL")

	# Unlink
	var unlink_res := tm.unlink_external_tool("bizhawk")
	_assert_true(unlink_res.success == true, "unlink_external_tool should succeed")
	_assert_true(not mock_config.has("bizhawk"), "bizhawk should be erased")
	_assert_true(not mock_config.has("bizhawk_emulator"), "bizhawk_emulator should be erased")

	# Clean up
	ToolManager.remove_dir_recursive(ext_dir)
	print("  -> Passed: External path linking and unlinking verified.")

func _test_modal_ui() -> void:
	print("\n[Test 6] Verifying ToolsManagerModal scene instantiation and filtering...")
	var modal_scene = load("res://scenes/modals/tools_manager_modal.tscn")
	_assert_true(modal_scene != null, "tools_manager_modal.tscn should load")

	var modal = modal_scene.instantiate()
	root.add_child(modal)

	var launcher = lobby.launcher
	modal.open(launcher)

	_assert_true(modal.visible == true, "Modal should be visible when opened")
	_assert_true(modal.tools_container != null, "ToolsContainer should exist")

	# Verify filter buttons
	modal._set_filter("installed")
	_assert_true(modal._active_filter == "installed", "Filter should be set to installed")

	modal._set_filter("not_installed")
	_assert_true(modal._active_filter == "not_installed", "Filter should be set to not_installed")

	modal._set_filter("all")
	_assert_true(modal._active_filter == "all", "Filter should be set to all")

	# Verify search
	modal.search_input.text = "dolphin"
	modal._render_tools()

	modal.close()
	_assert_true(modal.visible == false, "Modal should be hidden on close")

	modal.queue_free()
	print("  -> Passed: ToolsManagerModal UI rendering and filtering verified.")
