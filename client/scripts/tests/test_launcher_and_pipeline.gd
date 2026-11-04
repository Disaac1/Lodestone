extends SceneTree

# =====================================================================
#             SUITE 3: LAUNCH PIPELINE & CONFIG GENERATION
# =====================================================================
# Validates game-agnostic architecture, async pipeline execution stages,
# dynamic config writers (host.yaml & mod templates), Lumafly assembly
# swapping mechanics, and multi-game patch discrimination.
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

func _run_suite() -> void:
	print("==================================================================")
	print("  SUITE 3: LAUNCH PIPELINE & CONFIG GENERATION                   ")
	print("==================================================================")

	var lobby_scene = load("res://scenes/lobby.tscn")
	if not lobby_scene:
		_fail("Failed to load res://scenes/lobby.tscn")
		_finish()
		return

	lobby = lobby_scene.instantiate()
	root.add_child(lobby)

	var launcher = lobby.launcher
	await launcher.load_launcher_config()

	# -------------------------------------------------------------
	# 1. Architectural Audit: Zero Hardcoded Game Strings
	# -------------------------------------------------------------
	print("\n[Test 1] Auditing game_launcher.gd and lobby.gd for zero hardcoded game strings...")
	var launcher_code = FileAccess.open("res://scripts/core/game_launcher.gd", FileAccess.READ).get_as_text()
	var lobby_code = FileAccess.open("res://scripts/ui/lobby.gd", FileAccess.READ).get_as_text()

	var banned_game_strings = [
		"\"Pokemon Emerald\"",
		"\"Pokemon - Emerald Version\"",
		"\"Castlevania - Symphony of the Night\"",
		"\"Super Mario 64\"",
		"\"Slay the Spire\"",
		"\"Plants vs. Zombies\""
	]

	for pat in banned_game_strings:
		_assert_true(not pat in launcher_code, "game_launcher.gd contains hardcoded game string: " + pat)
		_assert_true(not pat in lobby_code, "lobby.gd contains hardcoded game string: " + pat)
	print("  -> Passed: Core launcher and lobby scripts are 100% data-driven and game-agnostic.")

	# -------------------------------------------------------------
	# -------------------------------------------------------------
	# 2. Dynamic Config Writers & Template Interpolation
	# -------------------------------------------------------------
	print("\n[Test 2] Verifying host.yaml sync and mod template interpolation...")
	# Slay the Spire config template
	var sts_template = "ConnectAddress={server_clean_url}\nConnectSlot={slot_name}\n"
	var mock_context = {
		"game_dir": "C:/Games/SlayTheSpire",
		"server_clean_url": "127.0.0.1:38000",
		"slot_name": "HeroTester"
	}
	var interpolated = launcher.interpolate_template(sts_template, mock_context)
	_assert_true("ConnectAddress=127.0.0.1:38000" in interpolated, "Missing ConnectAddress in interpolated config")
	_assert_true("ConnectSlot=HeroTester" in interpolated, "Missing ConnectSlot in interpolated config")

	# Host.yaml synchronization
	var test_yaml_path = ProjectSettings.globalize_path("res://test_suite_host.yaml")
	var initial_yaml = "hades_options:\n  styx_scribe_path: \"\"\ntboir_options:\n  game_folder: \"\"\n"
	var yfa = FileAccess.open("res://test_suite_host.yaml", FileAccess.WRITE)
	yfa.store_string(initial_yaml)
	yfa.close()

	launcher._write_synced_host_yaml_file(test_yaml_path, "C:/Steam/Hades/Hades.exe", "", "", "localhost:38000")
	var rfa = FileAccess.open("res://test_suite_host.yaml", FileAccess.READ)
	var synced = rfa.get_as_text()
	rfa.close()
	DirAccess.remove_absolute(test_yaml_path)

	_assert_true("C:/Steam/Hades/StyxScribe.py" in synced, "host.yaml missing synced styx_scribe_path")

	# Luigi's Mansion nested host_yaml sync
	var lm_yaml_path = ProjectSettings.globalize_path("res://test_suite_lm_host.yaml")
	var lm_initial = "luigismansion_options:\n  iso_file: \"\"\n"
	var lm_fa = FileAccess.open("res://test_suite_lm_host.yaml", FileAccess.WRITE)
	lm_fa.store_string(lm_initial)
	lm_fa.close()

	launcher._write_synced_host_yaml_file(lm_yaml_path, "C:/Games/Luigi.iso", "", "C:/Tools/Dolphin/Dolphin.exe", "localhost:38000")
	var lm_rfa = FileAccess.open("res://test_suite_lm_host.yaml", FileAccess.READ)
	var lm_synced = lm_rfa.get_as_text()
	lm_rfa.close()
	DirAccess.remove_absolute(lm_yaml_path)

	_assert_true("C:/Games/Luigi.iso" in lm_synced, "host.yaml missing synced Luigi iso_file")
	_assert_true("C:/Tools/Dolphin/Dolphin.exe" in lm_synced, "host.yaml missing synced Dolphin path")
	print("  -> Passed: Config template interpolation and host.yaml synchronization verified.")

	# -------------------------------------------------------------
	# 3. Lumafly Assembly-CSharp Swap Mechanics
	# -------------------------------------------------------------
	print("\n[Test 3] Verifying Lumafly modded assembly swap and restoration...")
	var mock_hk_dir = "user://test_lumafly_env"
	var mock_managed = mock_hk_dir.path_join("hollow_knight_Data/Managed")
	DirAccess.make_dir_recursive_absolute(mock_managed)

	var mock_active = mock_managed.path_join("Assembly-CSharp.dll")
	var mock_m = mock_managed.path_join("Assembly-CSharp.dll.m")
	var mock_v = mock_managed.path_join("Assembly-CSharp.dll.v")

	var vfa = FileAccess.open(mock_active, FileAccess.WRITE)
	vfa.store_string("VANILLA_CODE_PAYLOAD_WITHOUT_HOOKS")
	vfa.close()

	var mfa = FileAccess.open(mock_m, FileAccess.WRITE)
	mfa.store_string("MODDED_CODE_PAYLOAD_WITH_ModHooks_INSIDE")
	mfa.close()

	var state1 = LauncherUtils.check_assembly_csharp_status(mock_hk_dir)
	_assert_true(state1.get("state") == "disabled_in_lumafly", "Expected initial state disabled_in_lumafly, got " + str(state1.get("state")))

	var act = LauncherUtils.activate_modded_assembly(mock_hk_dir)
	_assert_true(act.get("success") == true, "Failed activating modded assembly")
	var state2 = LauncherUtils.check_assembly_csharp_status(mock_hk_dir)
	_assert_true(state2.get("state") == "active", "Expected active state after activation")
	_assert_true(FileAccess.file_exists(mock_v), "Vanilla backup .v not created")

	var rest = LauncherUtils.restore_vanilla_assembly(mock_hk_dir)
	_assert_true(rest.get("success") == true, "Failed restoring vanilla assembly")
	var state3 = LauncherUtils.check_assembly_csharp_status(mock_hk_dir)
	_assert_true(state3.get("state") == "disabled_in_lumafly", "Expected disabled_in_lumafly after restoration")

	DirAccess.remove_absolute(mock_active)
	DirAccess.remove_absolute(mock_m)
	DirAccess.remove_absolute(mock_v)
	print("  -> Passed: Lumafly assembly swap, backup, and restoration verified.")

	# -------------------------------------------------------------
	# 4. Patch File Completion Detection
	# -------------------------------------------------------------
	print("\n[Test 4] Verifying async patch completion detection...")
	var mock_patch_dir = "user://test_patch_detect"
	DirAccess.make_dir_recursive_absolute(mock_patch_dir)
	var mock_cue = mock_patch_dir.path_join("AP_TestSeed_P1_Hero.cue")
	var cfa = FileAccess.open(mock_cue, FileAccess.WRITE)
	cfa.store_string("FILE \"test.bin\" BINARY\n  TRACK 01 MODE2/2352\n")
	cfa.close()

	var detected_cue = launcher._check_extension_exists_in_dir(mock_patch_dir, ".cue")
	var detected_fake = launcher._check_extension_exists_in_dir(mock_patch_dir, ".fakeext")
	_assert_true(detected_cue == true, "Expected .cue file to be detected in target directory")
	_assert_true(detected_fake == false, "Expected .fakeext file to NOT be detected in target directory")
	DirAccess.remove_absolute(mock_cue)
	print("  -> Passed: Directory completion detection verified.")

	# -------------------------------------------------------------
	# 5. Structured Signal Decoupling & LaunchModal Reaction
	# -------------------------------------------------------------
	print("\n[Test 5] Verifying GameLauncher structured signals and LaunchModal decoupling...")
	_assert_true(launcher.has_signal("download_progress_updated"), "Missing download_progress_updated signal")
	_assert_true(launcher.has_signal("modding_status_updated"), "Missing modding_status_updated signal")
	_assert_true(launcher.has_signal("overlay_dismiss_requested"), "Missing overlay_dismiss_requested signal")

	_assert_true(not "%LaunchOverlay" in launcher_code, "game_launcher.gd must not contain %LaunchOverlay lookups")
	_assert_true(not "has_node(\"%DownloadProgressCard\")" in launcher_code, "game_launcher.gd must not contain scene tree lookups for DownloadProgressCard")

	var launch_overlay = lobby.launch_overlay
	_assert_true(launch_overlay != null, "launch_overlay should exist on lobby")

	# Test download_progress_updated signal reaction
	launcher.download_progress_updated.emit("Core Asset", 50.0, 5000000, 10000000, 1048576.0)
	_assert_true(launch_overlay.visible == true, "launch_overlay should be visible after download_progress_updated")
	_assert_true(launch_overlay.download_progress_card.visible == true, "download_progress_card should be visible")

	# Test modding_status_updated signal reaction
	launcher.modding_status_updated.emit("Modding test payload...", 80)
	_assert_true(launch_overlay.visible == true, "launch_overlay should be visible after modding_status_updated")

	# Test overlay_dismiss_requested signal reaction
	launcher.overlay_dismiss_requested.emit()
	_assert_true(launch_overlay.visible == false, "launch_overlay should be closed after overlay_dismiss_requested")
	print("  -> Passed: Structured signals and LaunchModal reactive binding verified.")

	# -------------------------------------------------------------
	# 6. Tool Integrity & Archipelago Python DLL Verification
	# -------------------------------------------------------------
	print("\n[Test 6] Verifying tool integrity validation (detecting missing python DLL)...")
	var test_dir = "user://test_tool_integrity"
	DirAccess.make_dir_recursive_absolute(test_dir)
	var test_ap_exe = test_dir.path_join("ArchipelagoLauncher.exe")
	var f_ap = FileAccess.open(test_ap_exe, FileAccess.WRITE)
	if f_ap:
		f_ap.store_string("mock_binary")
		f_ap.close()

	var is_valid_incomplete = launcher._tool_manager.validate_tool_integrity("archipelago_client", test_ap_exe)
	_assert_true(is_valid_incomplete == false, "validate_tool_integrity must fail when python DLL is missing")

	var test_py_dll = test_dir.path_join("python313.dll")
	var f_py = FileAccess.open(test_py_dll, FileAccess.WRITE)
	if f_py:
		f_py.store_string("mock_dll")
		f_py.close()

	var is_valid_complete = launcher._tool_manager.validate_tool_integrity("archipelago_client", test_ap_exe)
	_assert_true(is_valid_complete == true, "validate_tool_integrity must succeed when python DLL is present")

	# Cleanup
	DirAccess.remove_absolute(test_py_dll)
	DirAccess.remove_absolute(test_ap_exe)
	DirAccess.remove_absolute(test_dir)
	print("  -> Passed: Tool integrity validation verified.")

	_finish()

func _finish() -> void:
	print("\n==================================================================")
	if test_passed:
		print("  SUITE 3: ALL LAUNCH PIPELINE TESTS PASSED! [OK]                ")
	else:
		printerr("  SUITE 3: COMPLETED WITH FAILURES!                              ")
	print("==================================================================")
	if lobby:
		lobby.queue_free()
	quit(0 if test_passed else 1)
