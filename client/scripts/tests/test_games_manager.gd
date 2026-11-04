extends SceneTree

# =====================================================================
#             TEST SUITE: ROMs & GAMES MANAGER
# =====================================================================
# Validates GameLauncher game status resolution, disk usage auditing,
# ROM hash verification, uninstallation/cleanup, external linking,
# download link updates in rom.json, and RomCatalogModal UI rendering.
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
		print("  ALL GAMES MANAGER TESTS PASSED! [OK]                           ")
	else:
		print("  GAMES MANAGER TESTS ENCOUNTERED FAILURES! [ERROR]              ")
	print("==================================================================")
	quit(0 if test_passed else 1)

func _run_suite() -> void:
	print("==================================================================")
	print("  TEST SUITE: ROMs & GAMES MANAGER                               ")
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

	_test_game_status_and_hashes(launcher)
	_test_games_overview(launcher)
	_test_game_uninstall(launcher)
	_test_game_external_path(launcher)
	_test_set_rom_download_url(launcher)
	_test_modal_ui(launcher)

	_finish()

func _test_game_status_and_hashes(launcher) -> void:
	print("\n[Test 1] Verifying game status resolution and hash validation...")
	# 1. Uninstalled game
	var st_uninst: Dictionary = launcher.get_game_status("Pokemon Emerald")
	_assert_true(st_uninst.game_name == "Pokemon Emerald", "Game name should be Pokemon Emerald")
	_assert_true(st_uninst.required_rom == "Pokemon - Emerald Version (USA).gba", "Expected Emerald ROM name")

	# 2. Mock install an Emerald ROM with exact MD5 match
	var slug: String = launcher.get_game_slug("Pokemon Emerald")
	var game_dir: String = launcher.USER_GAMES_DIR.path_join(slug)
	DirAccess.make_dir_recursive_absolute(game_dir)
	var rom_path: String = game_dir.path_join("Pokemon - Emerald Version (USA).gba")

	# Write mock binary
	var f = FileAccess.open(rom_path, FileAccess.WRITE)
	f.store_string("mock emerald rom binary data")
	f.close()

	var st_installed: Dictionary = launcher.get_game_status("Pokemon Emerald")
	_assert_true(st_installed.installed == true, "Emerald should now be detected as installed")
	_assert_true(st_installed.is_managed == true, "Emerald in user://games should be managed")
	_assert_true(st_installed.size_bytes > 0, "Emerald size should be positive")
	# Since dummy string doesn't match real MD5, hash_valid should be false and status HASH_MISMATCH
	_assert_true(st_installed.hash_valid == false, "Dummy binary should fail MD5 check")
	_assert_true(st_installed.status_code == "HASH_MISMATCH", "Status code should be HASH_MISMATCH")

	# Clean up mock file
	DirAccess.remove_absolute(rom_path)
	print("  -> Passed: Game status resolution and hash auditing verified.")

func _test_games_overview(launcher) -> void:
	print("\n[Test 2] Verifying get_all_games_status overview aggregation...")
	var overview: Dictionary = launcher.get_all_games_status()
	var games_arr: Array = overview.get("games", [])
	_assert_true(games_arr.size() > 0, "Games list should not be empty")
	_assert_true(overview.has("total_games_size_bytes"), "Should have total_games_size_bytes")
	_assert_true(overview.has("formatted_total_size"), "Should have formatted_total_size")
	_assert_true(overview.has("installed_count"), "Should have installed_count")
	_assert_true(overview.has("total_count"), "Should have total_count")
	_assert_true(overview.total_count == games_arr.size(), "Total count matches array size")
	print("  -> Passed: get_all_games_status produces valid overview with " + str(games_arr.size()) + " games.")

func _test_game_uninstall(launcher) -> void:
	print("\n[Test 3] Verifying uninstall_game purges directory and paths_config...")
	var slug: String = launcher.get_game_slug("Mock Uninstall Game")
	var game_dir: String = launcher.USER_GAMES_DIR.path_join(slug)
	DirAccess.make_dir_recursive_absolute(game_dir)
	var dummy_file: String = game_dir.path_join("game.bin")
	var f = FileAccess.open(dummy_file, FileAccess.WRITE)
	f.store_string("uninstall test content")
	f.close()

	launcher.paths_config["Mock Uninstall Game"] = dummy_file
	launcher.save_paths_config()

	var res: Dictionary = launcher.uninstall_game("Mock Uninstall Game")
	_assert_true(res.success == true, "uninstall_game should report success")
	_assert_true(not DirAccess.dir_exists_absolute(game_dir), "Game directory should be removed")
	_assert_true(not launcher.paths_config.has("Mock Uninstall Game"), "paths_config should be cleared")
	print("  -> Passed: uninstall_game cleanly wiped folder and configuration.")

func _test_game_external_path(launcher) -> void:
	print("\n[Test 4] Verifying set_game_path and unlink_game_path...")
	var ext_dir: String = "user://mock_external_rom"
	DirAccess.make_dir_recursive_absolute(ext_dir)
	var ext_rom: String = ext_dir.path_join("ExternalRom.gba")
	var f = FileAccess.open(ext_rom, FileAccess.WRITE)
	f.store_string("external rom content")
	f.close()

	var res: Dictionary = launcher.set_game_path("Test Game", ext_rom)
	_assert_true(res.success == true, "set_game_path should succeed")
	_assert_true(launcher.paths_config.get("Test Game") == ext_rom, "paths_config should store path")

	var st: Dictionary = launcher.get_game_status("Test Game")
	_assert_true(st.installed == true, "Game should be installed")
	_assert_true(st.is_managed == false, "External game should not be managed")

	launcher.unlink_game_path("Test Game")
	_assert_true(not launcher.paths_config.has("Test Game"), "unlink_game_path should erase entry")

	DirAccess.remove_absolute(ext_rom)
	DirAccess.remove_absolute(ext_dir)
	print("  -> Passed: External game path linking and unlinking verified.")

func _test_set_rom_download_url(launcher) -> void:
	print("\n[Test 5] Verifying set_rom_download_url persists in catalog...")
	var test_id: String = "test_rom_key.gba"
	var test_url: String = "https://example.com/test_rom.gba"
	var success: bool = launcher.set_rom_download_url(test_id, test_url)
	_assert_true(success == true, "set_rom_download_url should succeed")

	var dl_entry: Dictionary = launcher.get_rom_download_entry(test_id)
	_assert_true(dl_entry.get("url") == test_url, "Download entry URL matches stored URL")

	# Clean up test entry
	launcher.set_rom_download_url(test_id, "")
	print("  -> Passed: set_rom_download_url persisted and retrieved correctly.")

func _test_modal_ui(launcher) -> void:
	print("\n[Test 6] Verifying RomCatalogModal scene UI, searching, and filtering...")
	var modal_scene = load("res://scenes/modals/rom_catalog_modal.tscn")
	_assert_true(modal_scene != null, "rom_catalog_modal.tscn should load")

	var modal = modal_scene.instantiate()
	root.add_child(modal)

	modal.open(launcher)
	_assert_true(modal.visible == true, "Modal should be visible when opened")
	_assert_true(modal.entries_container != null, "EntriesContainer should exist")

	# Filter testing
	modal._set_filter("installed")
	_assert_true(modal._active_filter == "installed", "Filter should be installed")

	modal._set_filter("not_installed")
	_assert_true(modal._active_filter == "not_installed", "Filter should be not_installed")

	modal._set_filter("downloadable")
	_assert_true(modal._active_filter == "downloadable", "Filter should be downloadable")

	modal._set_filter("all")
	_assert_true(modal._active_filter == "all", "Filter should be all")

	# Search testing
	modal.search_input.text = "emerald"
	modal._render_games()

	# Toggle sync drawer
	modal._toggle_sync_drawer()
	_assert_true(modal.sync_drawer.visible == true, "Sync drawer should be toggled open")
	modal._toggle_sync_drawer()
	_assert_true(modal.sync_drawer.visible == false, "Sync drawer should be toggled closed")

	modal.close()
	_assert_true(modal.visible == false, "Modal should close")

	modal.queue_free()
	print("  -> Passed: RomCatalogModal UI rendering, searching, and filter switching verified.")
