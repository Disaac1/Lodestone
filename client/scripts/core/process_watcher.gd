class_name ProcessWatcher
extends RefCounted

## ProcessWatcher
## Tracks, watches, and monitors game and companion processes launched by Wayfinder.
## Prevents duplicate game launches while an instance is running, monitors long startup
## windows (processes taking up to a minute to initialize), and catches early process
## exits or crashes without assuming a process succeeded merely because it was spawned.

signal game_process_started(game_name: String, pid: int)
signal game_process_running(game_name: String, pid: int)
signal game_process_stopped(game_name: String, exit_code: int)
signal game_process_crashed(game_name: String, exit_code: int, reason: String)
signal game_process_updated(game_name: String, is_running: bool, state: String)

enum ProcessState {
	IDLE,
	STARTING,
	RUNNING,
	CRASHED,
	STOPPED
}

# Default grace period during which a game is starting up (up to 45 seconds).
const DEFAULT_STARTUP_GRACE_MSEC: int = 45000
# Initial verification delay right after spawn (1.0 second).
const INITIAL_LIVENESS_DELAY_SEC: float = 1.0
# Polling interval during background watch loop.
const WATCH_POLL_INTERVAL_SEC: float = 1.0

# Tracks active game records:
# key: game_name (String) -> Dictionary
var _tracked_games: Dictionary = {}
var _active_watch_loops: Dictionary = {}


# =====================================================================
#                      REGISTRATION & LIFECYCLE
# =====================================================================

## Registers a game process to be tracked and starts background polling.
func track_game(
	node: Node,
	game_name: String,
	primary_pid: int,
	companion_pids: Array = [],
	executable_path: String = "",
	startup_grace_msec: int = DEFAULT_STARTUP_GRACE_MSEC
) -> Dictionary:
	var clean_pids: Array = []
	for p in companion_pids:
		var int_p: int = int(p)
		if int_p > 0:
			clean_pids.append(int_p)

	var record: Dictionary = {
		"game_name": game_name,
		"primary_pid": primary_pid,
		"companion_pids": clean_pids,
		"executable_path": executable_path,
		"launch_time_msec": Time.get_ticks_msec(),
		"startup_grace_msec": startup_grace_msec,
		"state": "starting",
		"last_exit_code": -1,
		"error_message": "",
		"node": node
	}
	_tracked_games[game_name] = record
	emit_signal("game_process_started", game_name, primary_pid)
	emit_signal("game_process_updated", game_name, true, "starting")

	# Start background watch loop if a valid scene node is provided
	if is_instance_valid(node) and node.is_inside_tree():
		_start_watch_loop(node, game_name)

	return record


## Verifies if the spawned process is actually alive after a short startup delay.
## Returns true if alive, false if it died immediately (failed to launch / crashed).
func verify_initial_liveness(node: Node, game_name: String, primary_pid: int, delay_sec: float = INITIAL_LIVENESS_DELAY_SEC) -> bool:
	if primary_pid <= 0:
		_record_crash(game_name, -1, "Invalid process ID returned during launch.")
		return false

	# If started via URL protocol or shell_open (pseudo PID = 1), attempt to locate by executable name
	if primary_pid == 1:
		if is_instance_valid(node) and node.get_tree():
			await node.get_tree().create_timer(delay_sec).timeout
		var rec: Dictionary = _tracked_games.get(game_name, {})
		var exe_path: String = rec.get("executable_path", "")
		if exe_path != "":
			var found_pid: int = find_pid_by_name(exe_path)
			if found_pid > 1:
				rec["primary_pid"] = found_pid
				_tracked_games[game_name] = rec
				print("[ProcessWatcher] Resolved Steam/URL process PID for ", game_name, ": ", found_pid)
				return true
		# Shell open succeeded and no crash detected
		return true

	# Wait for initial spin-up
	if is_instance_valid(node) and node.get_tree():
		await node.get_tree().create_timer(delay_sec).timeout

	if OS.is_process_running(primary_pid):
		print("[ProcessWatcher] Process verified alive for ", game_name, " (PID: ", primary_pid, ")")
		return true

	# Process died immediately after launch!
	var exit_code: int = OS.get_process_exit_code(primary_pid)
	var reason: String = "Game process exited immediately after launch (exit code: %d)." % exit_code
	print("[ProcessWatcher Error] ", reason)
	_record_crash(game_name, exit_code, reason)
	return false


# =====================================================================
#                      BACKGROUND WATCH LOOP
# =====================================================================

func _start_watch_loop(node: Node, game_name: String) -> void:
	if _active_watch_loops.get(game_name, false):
		return
	_active_watch_loops[game_name] = true
	_run_watch_coroutine(node, game_name)


func _run_watch_coroutine(node: Node, game_name: String) -> void:
	while _tracked_games.has(game_name):
		if not is_instance_valid(node) or not node.is_inside_tree():
			break
		await node.get_tree().create_timer(WATCH_POLL_INTERVAL_SEC).timeout
		if not _tracked_games.has(game_name):
			break

		var still_active: bool = _poll_game_internal(game_name)
		if not still_active:
			break

	_active_watch_loops.erase(game_name)


# =====================================================================
#                      POLLING & STATE LOGIC
# =====================================================================

## Polls a specific game's process status. Returns true if still running, false if stopped/crashed.
func poll_game(game_name: String) -> bool:
	return _poll_game_internal(game_name)


func _poll_game_internal(game_name: String) -> bool:
	if not _tracked_games.has(game_name):
		return false

	var record: Dictionary = _tracked_games[game_name]
	var primary_pid: int = int(record.get("primary_pid", -1))
	var companion_pids: Array = record.get("companion_pids", [])
	var exe_path: String = record.get("executable_path", "")
	var launch_time: int = int(record.get("launch_time_msec", 0))
	var grace_msec: int = int(record.get("startup_grace_msec", DEFAULT_STARTUP_GRACE_MSEC))
	var current_state: String = record.get("state", "starting")

	var is_any_running: bool = false

	# Check primary PID
	if primary_pid > 1:
		if OS.is_process_running(primary_pid):
			is_any_running = true
	elif primary_pid == 1 and exe_path != "":
		# Attempt to detect PID if previously unknown
		var discovered_pid: int = find_pid_by_name(exe_path)
		if discovered_pid > 1:
			record["primary_pid"] = discovered_pid
			primary_pid = discovered_pid
			is_any_running = true

	# Check companion PIDs (BizHawk, client tool, etc.)
	if not is_any_running:
		for cpid in companion_pids:
			var int_cpid: int = int(cpid)
			if int_cpid > 1 and OS.is_process_running(int_cpid):
				is_any_running = true
				break

	var elapsed_msec: int = Time.get_ticks_msec() - launch_time

	if is_any_running:
		# Transition from "starting" to "running" once past 5s or grace window
		if current_state == "starting" and elapsed_msec >= 5000:
			record["state"] = "running"
			_tracked_games[game_name] = record
			emit_signal("game_process_running", game_name, primary_pid)
			emit_signal("game_process_updated", game_name, true, "running")
		return true

	# All processes have terminated!
	var exit_code: int = -1
	if primary_pid > 1:
		exit_code = OS.get_process_exit_code(primary_pid)
	record["last_exit_code"] = exit_code

	# If process terminated prematurely (within startup grace) with non-zero exit code, consider crashed
	var was_in_startup: bool = elapsed_msec < grace_msec
	if was_in_startup and exit_code != 0 and exit_code != -1:
		var reason: String = "Game process exited unexpectedly during startup (exit code: %d)." % exit_code
		_record_crash(game_name, exit_code, reason)
		return false

	# Clean exit / closed by user
	record["state"] = "stopped"
	_tracked_games.erase(game_name)
	print("[ProcessWatcher] Game process for '", game_name, "' stopped normally (exit code: ", exit_code, ")")
	emit_signal("game_process_stopped", game_name, exit_code)
	emit_signal("game_process_updated", game_name, false, "stopped")
	return false


func _record_crash(game_name: String, exit_code: int, reason: String) -> void:
	if _tracked_games.has(game_name):
		var rec: Dictionary = _tracked_games[game_name]
		rec["state"] = "crashed"
		rec["last_exit_code"] = exit_code
		rec["error_message"] = reason
		_tracked_games.erase(game_name)
	emit_signal("game_process_crashed", game_name, exit_code, reason)
	emit_signal("game_process_updated", game_name, false, "crashed")


# =====================================================================
#                      PUBLIC QUERIES & CONTROL
# =====================================================================

## Returns true if the game is currently tracked and running (or starting).
func is_game_running(game_name: String) -> bool:
	if not _tracked_games.has(game_name):
		return false
	# Perform real-time check for immediate accuracy
	return _poll_game_internal(game_name)


## Returns the process state: "starting", "running", "crashed", "stopped", or "idle".
func get_game_state(game_name: String) -> String:
	if not _tracked_games.has(game_name):
		return "idle"
	# Update status immediately
	if not _poll_game_internal(game_name):
		return "idle"
	return str(_tracked_games.get(game_name, {}).get("state", "idle"))


## Returns the primary PID of the tracked game, or -1 if not running.
func get_game_pid(game_name: String) -> int:
	if not _tracked_games.has(game_name):
		return -1
	return int(_tracked_games[game_name].get("primary_pid", -1))


## Returns the last recorded exit code for a game.
func get_last_exit_code(game_name: String) -> int:
	if _tracked_games.has(game_name):
		return int(_tracked_games[game_name].get("last_exit_code", -1))
	return -1


## Returns all running games as a dictionary: game_name -> info dict.
func get_all_running_games() -> Dictionary:
	var active: Dictionary = {}
	var keys: Array = _tracked_games.keys().duplicate()
	for k in keys:
		if _poll_game_internal(k):
			active[k] = _tracked_games[k].duplicate()
	return active


## Stops tracking a game without killing the process.
func stop_watching(game_name: String) -> void:
	_tracked_games.erase(game_name)
	_active_watch_loops.erase(game_name)
	emit_signal("game_process_updated", game_name, false, "stopped")


## Stops tracking all games.
func stop_watching_all() -> void:
	var keys: Array = _tracked_games.keys().duplicate()
	_tracked_games.clear()
	_active_watch_loops.clear()
	for k in keys:
		emit_signal("game_process_updated", k, false, "stopped")


## Kills/terminates the game process and any companion processes.
func terminate_game_process(game_name: String) -> bool:
	if not _tracked_games.has(game_name):
		return false
	var rec: Dictionary = _tracked_games[game_name]
	var p_pid: int = int(rec.get("primary_pid", -1))
	var c_pids: Array = rec.get("companion_pids", [])

	var killed_any: bool = false
	if p_pid > 1 and OS.is_process_running(p_pid):
		var err = OS.kill(p_pid)
		if err == OK:
			killed_any = true

	for cpid in c_pids:
		var int_c: int = int(cpid)
		if int_c > 1 and OS.is_process_running(int_c):
			OS.kill(int_c)

	_tracked_games.erase(game_name)
	_active_watch_loops.erase(game_name)
	emit_signal("game_process_stopped", game_name, 0)
	emit_signal("game_process_updated", game_name, false, "stopped")
	return killed_any


# =====================================================================
#                      STATIC PROCESS HELPERS
# =====================================================================

## Finds a running process PID by executable name on Windows using tasklist.
## Returns the PID if found, or -1 otherwise.
static func find_pid_by_name(exe_path_or_name: String) -> int:
	var clean_name: String = exe_path_or_name.get_file().strip_edges()
	if clean_name == "":
		return -1
	if OS.get_name() != "Windows":
		return -1

	var output: Array = []
	var args: PackedStringArray = ["/FI", "IMAGENAME eq " + clean_name, "/FO", "CSV", "/NH"]
	var exit_code: int = OS.execute("tasklist", args, output, false)
	if exit_code == 0 and not output.is_empty():
		var raw_str: String = str(output[0]).strip_edges()
		for line in raw_str.split("\n"):
			var trimmed: String = line.strip_edges()
			if trimmed != "" and not trimmed.begins_with("INFO:"):
				var parts: PackedStringArray = trimmed.split(",")
				if parts.size() >= 2:
					var pid_str: String = parts[1].replace("\"", "").strip_edges()
					if pid_str.is_valid_int():
						return pid_str.to_int()
	return -1
