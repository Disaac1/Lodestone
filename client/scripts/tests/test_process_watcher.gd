extends SceneTree

# =====================================================================
#             TEST SUITE: PROCESS WATCHER & RUNNING GAME TRACKING
# =====================================================================

const ProcessWatcherScript = preload("res://scripts/core/process_watcher.gd")
const DashboardGameCardScene = preload("res://scenes/components/dashboard_game_card.tscn")

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
	print("  TEST SUITE: PROCESS WATCHER & RUNNING GAME TRACKING             ")
	print("==================================================================")

	var dummy_node: Node = Node.new()
	root.add_child(dummy_node)

	# -------------------------------------------------------------
	# Test 1: Basic tracking, states, and PID queries
	# -------------------------------------------------------------
	print("\n[Test 1] Verifying ProcessWatcher registration and state queries...")
	var watcher = ProcessWatcherScript.new()
	var test_game = "Test Adventure"

	_assert_true(not watcher.is_game_running(test_game), "Game should not be running before tracking")
	_assert_true(watcher.get_game_state(test_game) == "idle", "Initial state should be idle")

	var started_signals: Array = []
	watcher.game_process_started.connect(func(g, p): started_signals.append({"game": g, "pid": p}))

	# Track dummy process ID
	watcher.track_game(dummy_node, test_game, 999999, [], "", 30000)
	_assert_true(started_signals.size() == 1, "Expected game_process_started signal")
	_assert_true(started_signals[0]["game"] == test_game, "Expected test_game in started signal")
	_assert_true(started_signals[0]["pid"] == 999999, "Expected PID 999999 in started signal")

	# PID 999999 is not a real running process, so poll should detect it's not running
	var is_alive = watcher.poll_game(test_game)
	_assert_true(not is_alive, "Dummy process 999999 should not be running")
	_assert_true(not watcher.is_game_running(test_game), "Game should be marked not running after poll")
	print("  -> Passed: Registration, state queries, and non-running detection verified.")

	# -------------------------------------------------------------
	# Test 2: Real process liveness check and watching
	# -------------------------------------------------------------
	print("\n[Test 2] Verifying real process lifecycle and liveness check...")
	# Spawn a real short-lived command process
	var real_pid: int = OS.create_process("cmd.exe", ["/C", "timeout /T 3 /NOBREAK"])
	_assert_true(real_pid > 0, "Failed to spawn real test process")

	var running_signals: Array = []
	var stopped_signals: Array = []
	watcher.game_process_running.connect(func(g, p): running_signals.append({"game": g, "pid": p}))
	watcher.game_process_stopped.connect(func(g, c): stopped_signals.append({"game": g, "code": c}))

	watcher.track_game(dummy_node, "CmdGame", real_pid, [], "", 20000)
	_assert_true(watcher.is_game_running("CmdGame"), "CmdGame should be active and running")
	_assert_true(watcher.get_game_pid("CmdGame") == real_pid, "CmdGame PID should match spawned PID")

	# Verify initial liveness with short delay
	var verified_alive = await watcher.verify_initial_liveness(dummy_node, "CmdGame", real_pid, 0.2)
	_assert_true(verified_alive, "Real process should be verified alive by liveness check")

	# Terminate the process cleanly using watcher
	var terminated = watcher.terminate_game_process("CmdGame")
	_assert_true(terminated, "terminate_game_process should return true for active process")
	_assert_true(not watcher.is_game_running("CmdGame"), "CmdGame should not be running after termination")
	_assert_true(stopped_signals.size() > 0, "Expected game_process_stopped signal upon termination")
	print("  -> Passed: Real process tracking, liveness check, and termination verified.")

	# -------------------------------------------------------------
	# Test 3: Dead/failed process detection without assuming success
	# -------------------------------------------------------------
	print("\n[Test 3] Verifying dead process detection (preventing false success assumption)...")
	# Spawn a process that exits immediately with failure code
	var dead_pid: int = OS.create_process("cmd.exe", ["/C", "exit 42"])
	await dummy_node.get_tree().create_timer(0.4).timeout

	var crashed_signals: Array = []
	watcher.game_process_crashed.connect(func(g, c, r): crashed_signals.append({"game": g, "code": c, "reason": r}))

	watcher.track_game(dummy_node, "FailingGame", dead_pid, [], "", 20000)
	var liveness_result = await watcher.verify_initial_liveness(dummy_node, "FailingGame", dead_pid, 0.2)
	_assert_true(not liveness_result, "verify_initial_liveness must fail when process exits immediately")
	_assert_true(crashed_signals.size() == 1, "Expected game_process_crashed signal for immediately failed process")
	_assert_true(crashed_signals[0]["code"] == 42, "Expected exit code 42, got: " + str(crashed_signals[0]["code"]))
	_assert_true(not watcher.is_game_running("FailingGame"), "FailingGame must not be tracked as running")
	print("  -> Passed: Immediate crash detection verified.")

	# -------------------------------------------------------------
	# Test 4: GameLauncher integration & duplicate launch prevention
	# -------------------------------------------------------------
	print("\n[Test 4] Verifying GameLauncher duplicate launch prevention...")
	var lobby_scene = load("res://scenes/lobby.tscn")
	var lobby = lobby_scene.instantiate()
	root.add_child(lobby)
	var launcher = lobby.launcher
	var test_target_game = "Duplicate Guard Game"

	# Register game as running in launcher
	var active_pid: int = OS.create_process("cmd.exe", ["/C", "timeout /T 4 /NOBREAK"])
	launcher._process_watcher.track_game(dummy_node, test_target_game, active_pid, [], "", 30000)

	_assert_true(launcher.is_game_running(test_target_game), "Launcher must report game is running")
	_assert_true(launcher.get_game_pid(test_target_game) == active_pid, "Launcher PID must match")

	var failed_results: Array = []
	launcher.launch_failed.connect(func(g, msg):
		if g == test_target_game:
			failed_results.append(msg)
	)

	# Try launching while already running
	var launch_result = await launcher.launch_game(dummy_node, test_target_game)
	_assert_true(not launch_result, "launch_game must return false when game is already running")
	_assert_true(failed_results.size() > 0, "launch_failed signal must be emitted when game is already running")
	_assert_true(failed_results.size() > 0 and failed_results[0].contains("already running"), "Failure message must state game is already running")

	launcher.terminate_game_process(test_target_game)
	lobby.queue_free()
	print("  -> Passed: Duplicate launch prevention and status reporting verified.")

	# -------------------------------------------------------------
	# Test 5: DashboardGameCard UI state presentation
	# -------------------------------------------------------------
	print("\n[Test 5] Verifying DashboardGameCard UI reaction to running states...")
	var card = DashboardGameCardScene.instantiate()
	dummy_node.add_child(card)

	# 5a. Ready state
	var ready_status: Dictionary = {
		"is_configured": true,
		"is_running": false,
		"status_text": "● Configured"
	}
	card.setup("Test RPG", "Player1", {}, ready_status, {})
	_assert_true(card.status_label.text == "Ready", "Status label should be Ready")
	_assert_true(card.main_action_btn.text == "Launch", "Main button text should be Launch")
	_assert_true(not card.main_action_btn.disabled, "Main button should be enabled in Ready state")

	# 5b. Starting state (within startup window)
	var starting_status: Dictionary = {
		"is_configured": true,
		"is_running": true,
		"process_state": "starting",
		"status_text": "● Launching..."
	}
	card.update_launch_status(starting_status)
	_assert_true(card.status_label.text == "Launching...", "Status label should be Launching...")
	_assert_true(card.main_action_btn.text == "Launching...", "Main button should say Launching...")
	_assert_true(card.main_action_btn.disabled, "Main button must be disabled while Launching")

	# Test that pressing main button while running does not trigger launch signal
	var launch_pressed_fired: bool = false
	card.launch_pressed.connect(func(_g): launch_pressed_fired = true)
	card._on_main_action_pressed()
	_assert_true(not launch_pressed_fired, "launch_pressed must not fire while running")

	# 5c. Running state
	var running_status: Dictionary = {
		"is_configured": true,
		"is_running": true,
		"process_state": "running",
		"status_text": "● Running"
	}
	card.update_launch_status(running_status)
	_assert_true(card.status_label.text == "Running", "Status label should be Running")
	_assert_true(card.main_action_btn.text == "Game Running", "Main button should say Game Running")
	_assert_true(card.main_action_btn.disabled, "Main button must be disabled while Running")

	# 5d. Returned to Ready after game closes
	card.update_launch_status(ready_status)
	_assert_true(card.status_label.text == "Ready", "Status label should return to Ready")
	_assert_true(card.main_action_btn.text == "Launch", "Main button should return to Launch")
	_assert_true(not card.main_action_btn.disabled, "Main button should be re-enabled")
	print("  -> Passed: DashboardGameCard UI states (Ready -> Launching -> Running -> Ready) verified.")

	card.queue_free()

	# -------------------------------------------------------------
	# Test 6: Blank roms.json URL placeholder fallback on Main Menu
	# -------------------------------------------------------------
	print("\n[Test 6] Verifying blank roms.json URL uses placeholder fallback on Main Menu...")
	var menu_scene = load("res://scenes/main_menu.tscn")
	var menu = menu_scene.instantiate()
	root.add_child(menu)

	# Ensure url input is blank and has placeholder
	menu.rom_url_input.text = ""
	_assert_true(menu.rom_url_input.placeholder_text == "https://lodestone.disaac1.com/roms.json", "Expected placeholder text to be https://lodestone.disaac1.com/roms.json")

	menu._on_rom_download_pressed()
	# Verify that it did not fail with blank url error, but populated and used the placeholder
	_assert_true(menu.rom_url_input.text == "https://lodestone.disaac1.com/roms.json", "rom_url_input text should be populated with placeholder")
	_assert_true(not menu.error_label.text.contains("Please enter a valid URL"), "Must not fail due to blank input")
	print("  -> Passed: Blank roms.json URL downloaded via placeholder without blank error.")

	menu.queue_free()
	dummy_node.queue_free()
	_finish()

func _finish() -> void:
	print("\n==================================================================")
	if test_passed:
		print("  ALL PROCESS WATCHER & RUNNING TESTS PASSED! [OK]                ")
	else:
		printerr("  PROCESS WATCHER TESTS COMPLETED WITH FAILURES!                ")
	print("==================================================================")
	quit(0 if test_passed else 1)
