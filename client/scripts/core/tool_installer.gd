class_name ToolInstaller
extends RefCounted

var tool_manager
var find_game_executable_callback: Callable
var find_recursive_callback: Callable
var track_progress_callback: Callable
var progress_bar_callback: Callable
var user_tools_dir: String
var current_generation_callback: Callable

func _init(
	p_tool_manager,
	p_find_game_executable_callback: Callable,
	p_find_recursive_callback: Callable,
	p_track_progress_callback: Callable,
	p_progress_bar_callback: Callable,
	p_user_tools_dir: String,
	p_current_generation_callback: Callable
) -> void:
	tool_manager = p_tool_manager
	find_game_executable_callback = p_find_game_executable_callback
	find_recursive_callback = p_find_recursive_callback
	track_progress_callback = p_track_progress_callback
	progress_bar_callback = p_progress_bar_callback
	user_tools_dir = p_user_tools_dir
	current_generation_callback = p_current_generation_callback

func _is_current(generation: int) -> bool:
	return int(current_generation_callback.call()) == generation

func _find_game_executable(target_exe: String, subfolders: Array) -> String:
	return str(find_game_executable_callback.call(target_exe, subfolders))

func _find_recursive(target_exe: String) -> String:
	return str(find_recursive_callback.call(user_tools_dir, target_exe))

func _set_progress(node: Node, text: String) -> void:
	if is_instance_valid(node) and "launch_instructions" in node and is_instance_valid(node.launch_instructions):
		node.launch_instructions.text = text

func _progress_bar(value: int) -> String:
	return str(progress_bar_callback.call(value))

func _cleanup(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)

func install(
	node: Node,
	tool_name: String,
	download_url: String,
	subfolder: String,
	target_exe: String,
	callback: Callable,
	fallback_url: String,
	generation: int,
	expected_sha256: String = "",
	managed_only: bool = false
) -> void:
	if not _is_current(generation):
		return

	Updater.log_message("INSTALL", "Checking tool installation: " + tool_name + " (exe: " + target_exe + ", folder: " + subfolder + ")")
	var tools_dir: String = user_tools_dir.path_join(subfolder)
	DirAccess.make_dir_recursive_absolute(tools_dir)
	var discovered_path := ""
	var managed_path := tools_dir.path_join(target_exe)
	if FileAccess.file_exists(managed_path):
		discovered_path = ProjectSettings.globalize_path(managed_path)
	elif not managed_only:
		discovered_path = _find_game_executable(target_exe, [subfolder])
	if discovered_path != "":
		if _is_current(generation):
			Updater.log_message("INSTALL", "Tool already installed and verified at: " + discovered_path)
			callback.call(true, discovered_path)
		return

	var resolved_url: String = tool_manager.resolve_download_url(download_url)
	var http: HTTPRequest = HTTPRequest.new()
	http.use_threads = true
	http.download_chunk_size = 1048576
	node.add_child(http)
	var temp_filename: String = tool_manager.get_temp_download_path(tool_name, resolved_url)
	http.download_file = temp_filename
	var downloading: Array = [true]
	http.request_completed.connect(func(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray):
		downloading[0] = false
		http.queue_free()
		if not _is_current(generation):
			_cleanup(temp_filename)
			return
		Updater.log_message("INSTALL", "Download completed for " + tool_name + " (Result: " + str(result) + ", HTTP: " + str(response_code) + ")")
		if result != HTTPRequest.RESULT_SUCCESS or (response_code != 200 and response_code != 0):
			_cleanup(temp_filename)
			if fallback_url != "" and fallback_url != download_url:
				install(node, tool_name, fallback_url, subfolder, target_exe, callback, "", generation)
				return
			var error_message: String = "Download failed for " + tool_name + " (HTTP " + str(response_code) + ", Result: " + str(result) + ")"
			Updater.log_message("ERROR", error_message)
			callback.call(false, error_message)
			return

		var validation: Dictionary = tool_manager.validate_download_file(temp_filename, expected_sha256)
		if not validation.get("valid", false):
			_cleanup(temp_filename)
			var validation_error: String = str(validation.get("error", "Downloaded tool failed validation."))
			Updater.log_message("ERROR", validation_error)
			callback.call(false, validation_error)
			return

		var fmt: String = validation.get("format", "zip")
		if fmt == "exe":
			await _install_executable(node, tool_name, subfolder, target_exe, tools_dir, temp_filename, callback, generation, managed_only)
		elif fmt == "7z":
			await _extract_7z(node, tool_name, subfolder, target_exe, tools_dir, temp_filename, callback, generation, managed_only)
		else:
			await _extract_archive(node, tool_name, subfolder, target_exe, tools_dir, temp_filename, callback, generation, managed_only)
	)
	track_progress_callback.call(node, http, tool_name, downloading)
	var request_error: Error = http.request(resolved_url)
	if request_error != OK:
		downloading[0] = false
		http.queue_free()
		var init_error: String = "Failed to initiate download HTTP request for " + tool_name + " (Error: " + str(request_error) + ")"
		Updater.log_message("ERROR", init_error)
		callback.call(false, init_error)

func _install_executable(
	node: Node,
	tool_name: String,
	subfolder: String,
	target_exe: String,
	tools_dir: String,
	temp_filename: String,
	callback: Callable,
	generation: int,
	managed_only: bool
) -> void:
	_set_progress(node, "Installing " + tool_name + "...\n\nRunning setup installer...\n" + _progress_bar(90))
	var installer_path: String = ProjectSettings.globalize_path(temp_filename).replace("/", "\\")
	var destination: String = ProjectSettings.globalize_path(tools_dir).replace("/", "\\")
	var process_id: int = OS.create_process(installer_path, ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/DIR=" + destination])
	if process_id <= 0:
		process_id = OS.create_process(installer_path, [])
	var attempts_left: int = 60
	while attempts_left > 0:
		if not _is_current(generation):
			_cleanup(temp_filename)
			return
		if is_instance_valid(node) and node.get_tree():
			await node.get_tree().create_timer(1.0).timeout
		var executable_path: String = _find_recursive(target_exe)
		if executable_path == "" and not managed_only:
			executable_path = _find_game_executable(target_exe, [subfolder])
		if executable_path != "":
			_cleanup(temp_filename)
			await _show_completion(node, tool_name, executable_path, callback, generation)
			return
		attempts_left -= 1
	var error_message: String = "Installer ran (PID " + str(process_id) + ") but " + target_exe + " was not detected after 60s. Windows SmartScreen or UAC may have blocked the installation."
	Updater.log_message("ERROR", error_message)
	callback.call(false, error_message)

func _extract_7z(
	node: Node,
	tool_name: String,
	subfolder: String,
	target_exe: String,
	tools_dir: String,
	temp_filename: String,
	callback: Callable,
	generation: int,
	managed_only: bool
) -> void:
	_set_progress(node, "Installing " + tool_name + "...\n\nExtracting 7z archive...\n" + _progress_bar(95))
	if is_instance_valid(node) and node.get_tree():
		await node.get_tree().process_frame
	var global_temp: String = ProjectSettings.globalize_path(temp_filename).replace("/", "\\")
	var global_dest: String = ProjectSettings.globalize_path(tools_dir).replace("/", "\\")
	var exit_code: int = OS.execute("tar.exe", ["-xf", global_temp, "-C", global_dest])
	_cleanup(temp_filename)
	if not _is_current(generation):
		return
	var executable_path: String = _find_recursive(target_exe)
	if executable_path == "" and not managed_only:
		executable_path = _find_game_executable(target_exe, [subfolder])
	if executable_path != "":
		await _show_completion(node, tool_name, executable_path, callback, generation)
		return
	var missing_error: String = "Extracted 7z archive for " + tool_name + ", but could not find executable: " + target_exe + " (tar exit code: " + str(exit_code) + ")"
	Updater.log_message("ERROR", missing_error)
	callback.call(false, missing_error)

func _extract_archive(
	node: Node,
	tool_name: String,
	subfolder: String,
	target_exe: String,
	tools_dir: String,
	temp_filename: String,
	callback: Callable,
	generation: int,
	managed_only: bool
) -> void:
	Updater.log_message("INSTALL", "Extracting archive for " + tool_name + "...")
	_set_progress(node, "Installing " + tool_name + "...\n\nPreparing archive extraction...\n" + _progress_bar(95))
	if is_instance_valid(node) and node.get_tree():
		await node.get_tree().process_frame

	# On Windows, try system tar.exe first for instantaneous native decompression
	if OS.get_name() == "Windows":
		var global_temp: String = ProjectSettings.globalize_path(temp_filename).replace("/", "\\")
		var global_dest: String = ProjectSettings.globalize_path(tools_dir).replace("/", "\\")
		var tar_code: int = OS.execute("tar.exe", ["-xf", global_temp, "-C", global_dest])
		if tar_code == 0:
			_cleanup(temp_filename)
			if not _is_current(generation):
				return
			var direct_exe: String = tools_dir.path_join(target_exe)
			var exec_found: String = ""
			if FileAccess.file_exists(direct_exe):
				exec_found = ProjectSettings.globalize_path(direct_exe)
			else:
				exec_found = _find_recursive(target_exe)
				if exec_found == "" and not managed_only:
					exec_found = _find_game_executable(target_exe, [subfolder])
			if exec_found != "":
				Updater.log_message("INSTALL", "Extracted and verified " + tool_name + " at: " + exec_found)
				await _show_completion(node, tool_name, exec_found, callback, generation)
				return
	var zip_reader: ZIPReader = ZIPReader.new()
	var open_error: Error = zip_reader.open(temp_filename)
	if open_error != OK:
		_cleanup(temp_filename)
		var error_message: String = "Failed to open ZIP archive for " + tool_name + " (Error: " + str(open_error) + ")"
		Updater.log_message("ERROR", error_message)
		callback.call(false, error_message)
		return
	var archive_files: PackedStringArray = zip_reader.get_files()
	var root_prefix: String = _get_common_root(archive_files)
	var total_files: int = archive_files.size()
	var processed_files: int = 0
	for archive_path in archive_files:
		if not _is_current(generation):
			zip_reader.close()
			_cleanup(temp_filename)
			return
		processed_files += 1
		var relative_path: String = archive_path
		if root_prefix != "" and relative_path.begins_with(root_prefix):
			relative_path = relative_path.substr(root_prefix.length())
		if relative_path == "":
			continue
		var output_path: String = tools_dir.path_join(relative_path)
		if archive_path.ends_with("/"):
			DirAccess.make_dir_recursive_absolute(output_path)
		else:
			DirAccess.make_dir_recursive_absolute(output_path.get_base_dir())
			var output_file: FileAccess = FileAccess.open(output_path, FileAccess.WRITE)
			if output_file:
				output_file.store_buffer(zip_reader.read_file(archive_path))
				output_file.close()
		if processed_files % 15 == 0 or processed_files == total_files:
			_set_progress(node, "Installing " + tool_name + "...\n\nExtracting files (" + str(processed_files) + " / " + str(total_files) + ")...\n" + _progress_bar(int(float(processed_files) / float(max(total_files, 1)) * 100.0)))
			if is_instance_valid(node) and node.get_tree():
				await node.get_tree().process_frame
	zip_reader.close()
	_cleanup(temp_filename)
	if not _is_current(generation):
		return
	var executable_path: String = _find_recursive(target_exe)
	if executable_path == "" and not managed_only:
		executable_path = _find_game_executable(target_exe, [subfolder])
	if executable_path != "":
		await _show_completion(node, tool_name, executable_path, callback, generation)
		return
	var missing_error: String = "Extracted " + str(total_files) + " files for " + tool_name + ", but could not find executable: " + target_exe
	Updater.log_message("ERROR", missing_error)
	callback.call(false, missing_error)

func _get_common_root(files: PackedStringArray) -> String:
	if files.is_empty():
		return ""
	var slash_index: int = files[0].find("/")
	if slash_index == -1:
		return ""
	var candidate: String = files[0].substr(0, slash_index + 1)
	for file_path in files:
		if not file_path.begins_with(candidate):
			return ""
	return candidate

func _show_completion(node: Node, tool_name: String, path: String, callback: Callable, generation: int) -> void:
	if not _is_current(generation):
		return
	_set_progress(node, "Installation Complete for " + tool_name + "!\n" + _progress_bar(100))
	if _is_current(generation):
		callback.call(true, path)
