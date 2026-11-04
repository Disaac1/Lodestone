extends SceneTree

## Automated Headless Test Suite for 1-Click Install Diagnostics & E2E Testing System
## Validates:
##  1. MockGameScaffolder directory creation, mock ZIP generation, and cleanup
##  2. DiagnosticsStateAuditor state inspection and status categorization
##  3. InstallTestRunner complete sandboxed installation, unzipping, modding, and host.yaml sync
##  4. Expected vs Actual file tree diff engine

const MockGameScaffolder = preload("res://scripts/core/mock_game_scaffolder.gd")
const DiagnosticsStateAuditor = preload("res://scripts/core/diagnostics_state_auditor.gd")
const InstallTestRunner = preload("res://scripts/core/install_test_runner.gd")
const DiagnosticsOverlay = preload("res://scripts/ui/modals/diagnostics_overlay.gd")

const TEST_SANDBOX: String = "user://test_ci_e2e_sandbox"

var test_passed: bool = true
var total_assertions: int = 0
var passed_assertions: int = 0

func _init() -> void:
	_run_all_tests.call_deferred()

func _assert(condition: bool, msg: String) -> void:
	total_assertions += 1
	if condition:
		passed_assertions += 1
		print("  ✔ [PASS] ", msg)
	else:
		test_passed = false
		printerr("  ❌ [FAIL] ", msg)

func _run_all_tests() -> void:
	print("\n==================================================================")
	print("  WAYFINDER 1-CLICK INSTALL E2E & DIAGNOSTICS TEST SUITE          ")
	print("==================================================================")

	var lobby_scene = load("res://scenes/lobby.tscn")
	if not lobby_scene:
		printerr("Failed to load res://scenes/lobby.tscn")
		quit(1)
		return

	var lobby = lobby_scene.instantiate()
	root.add_child(lobby)

	var launcher = lobby.launcher
	await launcher.load_launcher_config()

	var auditor := DiagnosticsStateAuditor.new(launcher)
	var runner := InstallTestRunner.new(launcher, false)

	# -------------------------------------------------------------
	# Test 1: MockGameScaffolder & Mock ZIP Generation
	# -------------------------------------------------------------
	print("\n[Test 1] Testing MockGameScaffolder and valid ZIP creation...")
	MockGameScaffolder.purge_sandbox(TEST_SANDBOX)

	var mock_preset: Dictionary = {
		"target_exe": "TestGame.exe",
		"slug": "test_game"
	}
	var scaffold_res: Dictionary = MockGameScaffolder.scaffold_mock_game("test_game", mock_preset, TEST_SANDBOX)
	_assert(scaffold_res.get("success", false) == true, "Mock game scaffold reported success")

	var tree: Array[String] = MockGameScaffolder.get_sandbox_file_tree(TEST_SANDBOX)
	_assert(tree.has("games/test_game/TestGame.exe"), "Sandbox tree contains games/test_game/TestGame.exe")

	# Test mock ZIP generation
	var test_zip_path: String = TEST_SANDBOX.path_join("test_package.zip")
	var zip_files: Dictionary = {
		"bin/payload.exe": "MOCK_EXECUTABLE_CONTENT",
		"data/config.json": "{\"version\": \"1.0.0\"}"
	}
	var zip_created: bool = MockGameScaffolder.create_mock_zip(test_zip_path, zip_files)
	_assert(zip_created == true, "Mock ZIP was generated on disk")
	_assert(FileAccess.file_exists(test_zip_path), "FileAccess confirms mock ZIP existence")

	# Verify with Godot's ZIPReader
	var zr := ZIPReader.new()
	var zr_err := zr.open(test_zip_path)
	_assert(zr_err == OK, "Godot ZIPReader opened mock ZIP successfully")
	var files_in_zip: PackedStringArray = zr.get_files()
	_assert(files_in_zip.has("bin/payload.exe"), "Mock ZIP contains bin/payload.exe")
	_assert(files_in_zip.has("data/config.json"), "Mock ZIP contains data/config.json")
	zr.close()

	MockGameScaffolder.purge_sandbox(TEST_SANDBOX)
	var cleaned_tree: Array[String] = MockGameScaffolder.get_sandbox_file_tree(TEST_SANDBOX)
	_assert(cleaned_tree.is_empty(), "Sandbox purged cleanly")

	# -------------------------------------------------------------
	# Test 2: DiagnosticsStateAuditor Offline Discovery & Audit
	# -------------------------------------------------------------
	print("\n[Test 2] Testing DiagnosticsStateAuditor inspection...")
	var audit_report: Dictionary = auditor.run_full_audit(TEST_SANDBOX)
	var summary: Dictionary = audit_report.get("summary", {})
	_assert(summary.get("total_games", 0) > 0, "Discovered games in audit (found: " + str(summary.get("total_games", 0)) + ")")
	_assert(summary.get("total_tools", 0) > 0, "Discovered tools in audit (found: " + str(summary.get("total_tools", 0)) + ")")

	# Test mock presence audit
	var hk_preset: Dictionary = {
		"game_name": "Hollow Knight",
		"slug": "hollow_knight",
		"target_exe": "hollow_knight.exe",
		"client_tool": "poptracker"
	}
	MockGameScaffolder.scaffold_mock_game("hollow_knight", hk_preset, TEST_SANDBOX)
	var hk_audit: Dictionary = auditor.audit_game("Hollow Knight", hk_preset, TEST_SANDBOX)
	_assert(hk_audit.get("has_binary", false) == true, "Auditor detected scaffolded Hollow Knight binary")
	_assert(hk_audit.get("is_mock", false) == true, "Auditor correctly flagged binary as mock sandbox")
	_assert(hk_audit.get("mod_status", {}).get("state") == "VANILLA", "Auditor recognized vanilla assembly state with .m backup")

	# -------------------------------------------------------------
	# Test 3: InstallTestRunner Sandboxed Tool Pipeline
	# -------------------------------------------------------------
	print("\n[Test 3] Testing InstallTestRunner for tools (PopTracker & BizHawk)...")
	var poptracker_data: Dictionary = {
		"name": "PopTracker",
		"executable": "PopTracker.exe",
		"sub_folders": ["PopTracker"]
	}
	var pop_report: Dictionary = runner.test_tool_install_pipeline("poptracker", poptracker_data, TEST_SANDBOX)
	_assert(pop_report.get("status") == "PASSED", "PopTracker mock install pipeline PASSED")
	var pop_diff: Dictionary = pop_report.get("diff", {})
	_assert(pop_diff.get("diff_clean", false) == true, "PopTracker file diff is 100% clean")
	_assert(pop_diff.get("matched", []).has("tools/PopTracker/PopTracker.exe"), "PopTracker.exe verified in sandbox")

	# -------------------------------------------------------------
	# Test 4: InstallTestRunner Complete Game Pipeline & host.yaml Sync
	# -------------------------------------------------------------
	print("\n[Test 4] Testing InstallTestRunner complete game pipeline with modding & host.yaml...")
	var game_report: Dictionary = runner.test_game_install_pipeline("Hollow Knight", hk_preset, TEST_SANDBOX)
	_assert(game_report.get("status") == "PASSED", "Hollow Knight E2E install pipeline PASSED")

	var game_diff: Dictionary = game_report.get("diff", {})
	_assert(game_diff.get("diff_clean", false) == true, "Game install file diff is clean")
	_assert(game_diff.get("matched", []).has("tools/Archipelago/host.yaml"), "host.yaml was generated and matched")

	# -------------------------------------------------------------
	# Test 5: DiagnosticsOverlay In-App Visualizer & Toggle (Live & Sandbox)
	# -------------------------------------------------------------
	print("\n[Test 5] Testing DiagnosticsOverlay GUI instantiation, Live & Sandbox dual-view...")
	var diag_overlay := DiagnosticsOverlay.new(launcher)
	root.add_child(diag_overlay)
	_assert(diag_overlay.visible == false, "DiagnosticsOverlay initially hidden")

	diag_overlay.open()
	_assert(diag_overlay.visible == true, "DiagnosticsOverlay opened successfully")
	_assert(diag_overlay.view_mode == "live", "DiagnosticsOverlay defaults to Live Real Disk view mode")

	diag_overlay.select_target("Hollow Knight", "game")
	_assert(diag_overlay.selected_item_name == "Hollow Knight", "DiagnosticsOverlay selected Hollow Knight")

	# Test switching to sandbox mode
	diag_overlay.toggle_environment_mode()
	_assert(diag_overlay.view_mode == "sandbox", "Switched view mode to sandbox")

	# Test switching back to live mode
	diag_overlay.toggle_environment_mode()
	_assert(diag_overlay.view_mode == "live", "Switched view mode back to live disk")

	diag_overlay.close()
	_assert(diag_overlay.visible == false, "DiagnosticsOverlay closed cleanly")
	diag_overlay.queue_free()

	# Cleanup test sandbox
	MockGameScaffolder.purge_sandbox(TEST_SANDBOX)

	# -------------------------------------------------------------
	# Final Results Summary
	# -------------------------------------------------------------
	print("\n==================================================================")
	print("                     TEST SUITE SUMMARY                          ")
	print("==================================================================")
	print("Assertions Passed : %d / %d" % [passed_assertions, total_assertions])
	print("Final Status      : %s" % ["ALL TESTS PASSED ✅" if test_passed else "SOME TESTS FAILED ❌"])
	print("==================================================================\n")

	if test_passed:
		quit(0)
	else:
		quit(1)
