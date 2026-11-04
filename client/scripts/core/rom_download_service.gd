class_name RomDownloadService
extends RefCounted

const ZIP_HEADER_BYTE_1: int = 0x50
const ZIP_HEADER_BYTE_2: int = 0x4B

var resolve_url_callback: Callable
var decrypt_callback: Callable
var unpack_callback: Callable
var set_overlay_callback: Callable
var track_progress_callback: Callable
var progress_bar_callback: Callable
var update_progress_callback: Callable

func _init(
	p_resolve_url_callback: Callable,
	p_decrypt_callback: Callable,
	p_unpack_callback: Callable,
	p_set_overlay_callback: Callable,
	p_track_progress_callback: Callable,
	p_progress_bar_callback: Callable,
	p_update_progress_callback: Callable = Callable()
) -> void:
	resolve_url_callback = p_resolve_url_callback
	decrypt_callback = p_decrypt_callback
	unpack_callback = p_unpack_callback
	set_overlay_callback = p_set_overlay_callback
	track_progress_callback = p_track_progress_callback
	progress_bar_callback = p_progress_bar_callback
	update_progress_callback = p_update_progress_callback

func download(
	node: Node,
	download_url: String,
	download_dir: String,
	rom_name: String,
	target_rom_path: String,
	callback: Callable,
	decryption_key: String = "",
	redirect_depth: int = 0
) -> void:
	if redirect_depth > 5:
		callback.call(false, "Exceeded maximum HTTP redirect depth (5).")
		return

	var resolved_url: String = str(resolve_url_callback.call(download_url))
	print("[Launcher] Downloading base ROM from: ", resolved_url)
	set_overlay_callback.call(node)

	var encrypted: bool = resolved_url.to_lower().contains(".enc") or decryption_key != ""
	var zip_url: bool = resolved_url.to_lower().contains(".zip") or encrypted
	var extension: String = ".enc" if encrypted else (".zip" if zip_url else ".rom")
	var temp_download_path: String = download_dir.path_join("temp_download_" + rom_name.validate_filename() + extension)
	var http_request: HTTPRequest = HTTPRequest.new()
	http_request.use_threads = true
	http_request.download_chunk_size = 1048576
	http_request.download_file = temp_download_path
	node.add_child(http_request)

	var is_downloading: Array = [true]
	http_request.request_completed.connect(func(result: int, response_code: int, headers: PackedStringArray, _body: PackedByteArray):
		is_downloading[0] = false
		http_request.queue_free()

		if response_code in [301, 302, 303, 307, 308]:
			var redirect_location: String = _get_redirect_location(headers)
			if redirect_location != "":
				print("[Launcher] Following HTTP redirect (", response_code, ") to: ", redirect_location)
				_cleanup(temp_download_path)
				download(node, redirect_location, download_dir, rom_name, target_rom_path, callback, decryption_key, redirect_depth + 1)
				return

		if result == HTTPRequest.RESULT_SUCCESS and (response_code == 200 or response_code == 0):
			_process_downloaded_file(node, temp_download_path, target_rom_path, rom_name, zip_url, callback, decryption_key)
		else:
			print("[Launcher Error] Failed to download base ROM. HTTP Status: ", response_code)
			_cleanup(temp_download_path)
			callback.call(false, "Failed to download ROM from configured URL. Response code: " + str(response_code))
	)

	track_progress_callback.call(node, http_request, "Base ROM (" + rom_name + ")", is_downloading)
	var request_error: Error = http_request.request(resolved_url)
	if request_error != OK:
		is_downloading[0] = false
		http_request.queue_free()
		callback.call(false, "Failed to start ROM download HTTP request.")

func process_existing(
	node: Node,
	found_rom: String,
	target_rom_path: String,
	rom_name: String,
	callback: Callable
) -> void:
	var verified_path: String = found_rom
	if found_rom != target_rom_path and not FileAccess.file_exists(target_rom_path):
		var src_ext: String = found_rom.get_extension().to_lower()
		var dst_ext: String = target_rom_path.get_extension().to_lower()
		if src_ext != dst_ext and src_ext != "zip":
			print("[Launcher Error] Refusing to copy ROM with mismatching extension: ", found_rom, " -> ", target_rom_path)
			callback.call(false, "Found ROM extension (." + src_ext + ") does not match required extension (." + dst_ext + ").")
			return
		DirAccess.make_dir_recursive_absolute(target_rom_path.get_base_dir())
		var copy_error: Error = DirAccess.copy_absolute(found_rom, target_rom_path)
		if copy_error == OK:
			print("[Launcher] Cached ROM copy from ", found_rom, " to ", target_rom_path)
			verified_path = target_rom_path
		else:
			print("[Launcher Warning] Could not copy ROM to unified game path, using existing: ", found_rom)

	var test_file: FileAccess = FileAccess.open(verified_path, FileAccess.READ)
	if test_file:
		var header_bytes: PackedByteArray = test_file.get_buffer(2)
		test_file.close()
		if header_bytes.size() >= 2 and header_bytes[0] == ZIP_HEADER_BYTE_1 and header_bytes[1] == ZIP_HEADER_BYTE_2:
			print("[Launcher] Found ZIP header in existing ROM file. Unpacking...")
			unpack_callback.call(verified_path, rom_name, callback)
			return

	print("[Launcher] Base ROM verified and ready: ", verified_path)
	callback.call(true, verified_path)

func copy_local_file(
	node: Node,
	source_url: String,
	target_rom_path: String,
	rom_name: String,
	callback: Callable
) -> void:
	var source_path: String = source_url.replace("file://", "")
	if OS.get_name() == "Windows" and (source_path.begins_with("/") or source_path.begins_with("\\")):
		source_path = source_path.substr(1)
	var copy_error: Error = DirAccess.copy_absolute(source_path, target_rom_path)
	if copy_error == OK:
		print("[Launcher] Local ROM copy succeeded: ", target_rom_path)
		process_existing(node, target_rom_path, target_rom_path, rom_name, callback)
	else:
		callback.call(false, "Failed to copy local ROM file from: " + source_path + " (Error: " + str(copy_error) + ")")

func _process_downloaded_file(
	node: Node,
	temp_download_path: String,
	target_rom_path: String,
	rom_name: String,
	is_zip_url: bool,
	callback: Callable,
	decryption_key: String
) -> void:
	print("[Launcher] Base ROM download completed. Checking format...")
	var working_path: String = temp_download_path
	if decryption_key != "" or working_path.ends_with(".enc"):
		var decrypted_path: String = working_path.get_basename() + "_decrypted.tmp"
		var dec_progress_callback: Callable = func(pct: int, done_bytes: int, total_bytes: int):
			_update_decrypt_progress(node, rom_name, pct, done_bytes, total_bytes)
		_update_decrypt_progress(node, rom_name, 0, 0, 1)
		var decrypted_ok: bool = bool(decrypt_callback.call(working_path, decrypted_path, decryption_key, dec_progress_callback))
		_cleanup(working_path)
		if not decrypted_ok:
			callback.call(false, "Failed to decrypt game archive with provided key.")
			return
		working_path = decrypted_path

	var finish_callback: Callable = func(final_path: String):
		if is_instance_valid(node) and "launch_instructions" in node and is_instance_valid(node.launch_instructions):
			node.launch_instructions.text = "Base ROM Ready: " + rom_name + "!"
		callback.call(true, final_path)

	var has_zip: bool = _has_zip_header(working_path)
	if is_zip_url and has_zip:
		unpack_callback.call(working_path, rom_name, func(unpack_success: bool, unpack_result: String):
			if unpack_success:
				finish_callback.call(unpack_result)
			else:
				callback.call(false, unpack_result)
		)
		return

	# If target is an uncompressed ISO but downloaded file has RVZ magic (RVZ\x01), save as .rvz
	var final_dest_path: String = target_rom_path
	if _has_rvz_header(working_path) and target_rom_path.to_lower().ends_with(".iso"):
		final_dest_path = target_rom_path.get_basename() + ".rvz"

	DirAccess.make_dir_recursive_absolute(final_dest_path.get_base_dir())
	var copy_error: Error = DirAccess.copy_absolute(working_path, final_dest_path)
	_cleanup(working_path)
	if copy_error != OK:
		callback.call(false, "Failed to store downloaded ROM at: " + final_dest_path + " (Error: " + str(copy_error) + ")")
		return
	print("[Launcher] Base ROM stored successfully at: ", final_dest_path)
	finish_callback.call(final_dest_path)

func _has_rvz_header(path: String) -> bool:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if not file:
		return false
	var header: PackedByteArray = file.get_buffer(4)
	file.close()
	return header.size() >= 4 and header[0] == 0x52 and header[1] == 0x56 and header[2] == 0x5A and header[3] == 0x01

func _has_zip_header(path: String) -> bool:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if not file:
		return false
	var header: PackedByteArray = file.get_buffer(2)
	file.close()
	return header.size() >= 2 and header[0] == ZIP_HEADER_BYTE_1 and header[1] == ZIP_HEADER_BYTE_2

func _get_redirect_location(headers: PackedStringArray) -> String:
	for header in headers:
		if header.to_lower().begins_with("location:"):
			return header.substr(9).strip_edges()
	return ""

func _cleanup(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)

func _update_decrypt_progress(node: Node, rom_name: String, pct: int, done_bytes: int, total_bytes: int) -> void:
	if update_progress_callback.is_valid():
		update_progress_callback.call(node, "Decrypting " + rom_name, pct, done_bytes, total_bytes, 0.0)