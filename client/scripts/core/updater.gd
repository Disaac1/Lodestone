class_name Updater
extends RefCounted

const BASE_VERSION: String = "1.2.0"
static var active_version: String = BASE_VERSION
static var pending_base_pck_path: String = ""
static var pending_base_pck_target: String = ""

static func is_bridge_version() -> bool:
	return BASE_VERSION == "1.0.9"

static func _get_logger() -> Node:
	if Engine.get_main_loop() and Engine.get_main_loop() is SceneTree:
		var tree := Engine.get_main_loop() as SceneTree
		var logger := tree.root.get_node_or_null("LodestoneLogger")
		if not logger:
			logger = tree.root.get_node_or_null("WayfinderLogger")
		return logger
	return null

static func _diagnostic(message: String) -> void:
	print("[Updater] ", message)
	var logger := _get_logger()
	if logger and logger.has_method("log_message"):
		logger.log_message("UPDATER", message)

static func log_message(source: String, message: String) -> void:
	print("[", source, "] ", message)
	if Engine.get_main_loop() and Engine.get_main_loop() is SceneTree:
		var tree := Engine.get_main_loop() as SceneTree
		var logger := _get_logger()
		if logger and logger.has_method("log_message"):
			logger.log_message(source, message)

static func generate_diagnostic_report(custom_context: Dictionary = {}) -> String:
	if Engine.get_main_loop() and Engine.get_main_loop() is SceneTree:
		var tree := Engine.get_main_loop() as SceneTree
		var logger := _get_logger()
		if logger and logger.has_method("generate_diagnostic_report"):
			return logger.generate_diagnostic_report(custom_context)
	return JSON.stringify(custom_context, "  ")

static func send_logs_to_server(http_node: Node, server_base_url: String, error_summary: String = "", callback: Callable = Callable()) -> void:
	if Engine.get_main_loop() and Engine.get_main_loop() is SceneTree:
		var tree := Engine.get_main_loop() as SceneTree
		var logger := _get_logger()
		if logger and logger.has_method("send_logs_to_server"):
			logger.send_logs_to_server(http_node, server_base_url, error_summary, callback)
			return
	if callback.is_valid():
		callback.call(false, "Diagnostic logging is unavailable in this client version.")

const UPDATE_PCK_PATH: String = "user://update.pck"
const UPDATE_META_PATH: String = "user://update_meta.json"
const UPDATE_TEMP_PATH: String = "user://update.pck.tmp"
const UPDATE_META_TEMP_PATH: String = "user://update_meta.json.tmp"

# Embedded RSA-2048 public key for cryptographic signature verification.
# Only packages signed by the corresponding private key can be mounted.
const PUBLIC_KEY_PEM: String = """-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAlks8vqYcFTLFNRlrTPup
L3lV7YCz9EVDCJmigVorirTMTKzBJucp7zqlca+62Wx5DpCcymV7JY+CdAvcEVTQ
HkNuiDUv4YPwzvzafMeJg62/cnAatleANXD79ef1kBB7rKe4OgEkRW6b5YHxzCi4
QsickiX+K7WEhYyICeKT9BthwzNgyGa8XEhMZyly/7NL7cbWKTPrs9sMbmffVH8j
Qj9lmkqZp1LeLxH5/pOFNQets7wS2esfAY1gGWAhk+h8l14nqyNAngxb28j+LhWj
5b/ON6uEYKzsmAITMR0B711tlksakK6kTnnpp/dYv5ZdkDxrelyAcQbTvBgBL+HH
JQIDAQAB
-----END PUBLIC KEY-----"""

# Static helper to compare semantic versions (e.g., "1.0.1" > "1.0.0")
static func is_version_newer(remote: String, local: String = "") -> bool:
	if local.is_empty():
		local = active_version
	var r_parts = remote.split(".")
	var l_parts = local.split(".")
	var max_len = max(r_parts.size(), l_parts.size())
	for i in range(max_len):
		var r_num = int(r_parts[i]) if i < r_parts.size() else 0
		var l_num = int(l_parts[i]) if i < l_parts.size() else 0
		if r_num > l_num:
			return true
		elif r_num < l_num:
			return false
	return false

# Helper to detect whether the client is running in the editor or has explicitly
# disabled updates. Exported debug builds must still be able to receive updates.
static func is_dev_environment() -> bool:
	# 1. Running inside the Godot Editor
	if OS.has_feature("editor"):
		return true
	# 2. Explicit environment variable override for local development
	if (OS.has_environment("LODESTONE_DEV") and OS.get_environment("LODESTONE_DEV") == "1") or \
	   (OS.has_environment("WAYFINDER_DEV") and OS.get_environment("WAYFINDER_DEV") == "1"):
		return true
	if (OS.has_environment("LODESTONE_DISABLE_UPDATES") and OS.get_environment("LODESTONE_DISABLE_UPDATES") == "1") or \
	   (OS.has_environment("WAYFINDER_DISABLE_UPDATES") and OS.get_environment("WAYFINDER_DISABLE_UPDATES") == "1"):
		return true
	return false

# Migrates user data (profiles, saves, cached ROMs) from Wayfinder to Lodestone
static func migrate_legacy_userdata() -> void:
	var new_dir := ProjectSettings.globalize_path("user://")
	var old_dir := new_dir.replace("Lodestone", "Wayfinder")
	if old_dir == new_dir:
		return

	var marker_file := new_dir.path_join(".migrated_from_wayfinder")
	if FileAccess.file_exists(marker_file):
		var ap_exe := new_dir.path_join("tools/Archipelago/ArchipelagoLauncher.exe")
		var ap_old := old_dir.path_join("tools/Archipelago")
		if FileAccess.file_exists(ap_exe) and DirAccess.dir_exists_absolute(ap_old):
			var ap_dir := DirAccess.open(new_dir.path_join("tools/Archipelago"))
			var has_py := false
			if ap_dir:
				ap_dir.list_dir_begin()
				var f := ap_dir.get_next()
				while f != "":
					if not ap_dir.current_is_dir() and f.to_lower().begins_with("python") and f.to_lower().ends_with(".dll"):
						has_py = true
						break
					f = ap_dir.get_next()
				ap_dir.list_dir_end()
			if not has_py:
				print("[Migration] Incomplete Archipelago detected in migrated directory; completing migration...")
				_copy_directory_recursive(ap_old, new_dir.path_join("tools/Archipelago"))
		return

	if not DirAccess.dir_exists_absolute(old_dir):
		return

	print("[Migration] Detected legacy Wayfinder userdata directory at: ", old_dir)
	print("[Migration] Migrating existing saves, profiles, and data to Lodestone...")
	_copy_directory_recursive(old_dir, new_dir)

	var marker := FileAccess.open(marker_file, FileAccess.WRITE)
	if marker:
		marker.store_string("Migration completed on " + Time.get_datetime_string_from_system() + "\n")
		marker.close()
	print("[Migration] Migration to Lodestone complete.")

static func _copy_directory_recursive(src: String, dst: String) -> void:
	DirAccess.make_dir_recursive_absolute(dst)
	var dir := DirAccess.open(src)
	if not dir:
		return
	dir.list_dir_begin()
	var item_name := dir.get_next()
	while item_name != "":
		if item_name != "." and item_name != "..":
			var src_item := src.path_join(item_name)
			var dst_item := dst.path_join(item_name)
			if dir.current_is_dir():
				_copy_directory_recursive(src_item, dst_item)
			else:
				if not FileAccess.file_exists(dst_item):
					DirAccess.copy_absolute(src_item, dst_item)
		item_name = dir.get_next()
	dir.list_dir_end()

# Early boot verification: mounts verified updates on engine startup
static func bootstrap_early_updates() -> void:
	migrate_legacy_userdata()
	if is_dev_environment():
		print("[Updater] Update bootstrap disabled by development guard.")
		return

	if not FileAccess.file_exists(UPDATE_PCK_PATH) or not FileAccess.file_exists(UPDATE_META_PATH):
		print("[Updater] No staged update found.")
		return
		
	var meta_file = FileAccess.open(UPDATE_META_PATH, FileAccess.READ)
	if not meta_file:
		return
	var meta_text = meta_file.get_as_text()
	meta_file.close()
	
	var meta = JSON.parse_string(meta_text)
	if not (meta is Dictionary) or not meta.has("version"):
		push_warning("[Updater] Staged update metadata is invalid.")
		_cleanup_update_files()
		return
		
	var patch_ver = meta.get("version", "")
	# If base installer was updated to match or exceed this patch, remove obsolete patch
	if not is_version_newer(patch_ver, BASE_VERSION):
		print("[Updater] Base version (v", BASE_VERSION, ") supersedes patch (v", patch_ver, "). Cleaning up patch.")
		_cleanup_update_files()
		return
		
	var expected_sha = meta.get("sha256", "")
	var sig_b64 = meta.get("signature", "")
	
	var check = verify_pck(UPDATE_PCK_PATH, expected_sha, sig_b64)
	if not check.get("valid", false):
		push_warning("[Updater] Stored update.pck failed security verification: " + str(check.get("error", "")))
		_cleanup_update_files()
		return
		
	var success = ProjectSettings.load_resource_pack(UPDATE_PCK_PATH, true)
	if success:
		active_version = patch_ver
		print("[Updater] Successfully mounted verified patch: v", active_version)
	else:
		push_error("[Updater] Failed to mount verified update.pck for v" + str(patch_ver))

static func _cleanup_update_files() -> void:
	if FileAccess.file_exists(UPDATE_PCK_PATH):
		DirAccess.remove_absolute(UPDATE_PCK_PATH)
	if FileAccess.file_exists(UPDATE_META_PATH):
		DirAccess.remove_absolute(UPDATE_META_PATH)
	if FileAccess.file_exists(UPDATE_TEMP_PATH):
		DirAccess.remove_absolute(UPDATE_TEMP_PATH)
	if FileAccess.file_exists(UPDATE_META_TEMP_PATH):
		DirAccess.remove_absolute(UPDATE_META_TEMP_PATH)

# Verifies SHA-256 and cryptographic RSA signature against the embedded public key
static func verify_pck(pck_path: String, expected_sha256: String, signature_b64: String) -> Dictionary:
	var file = FileAccess.open(pck_path, FileAccess.READ)
	if not file:
		return {"valid": false, "error": "Unable to read package file"}
		
	var ctx = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	while not file.eof_reached():
		var chunk = file.get_buffer(65536)
		if chunk.size() > 0:
			ctx.update(chunk)
	file.close()
	
	var raw_hash: PackedByteArray = ctx.finish()
	var computed_hex: String = raw_hash.hex_encode()
	
	if expected_sha256 != "" and computed_hex.to_lower() != expected_sha256.to_lower():
		return {
			"valid": false,
			"error": "Checksum mismatch! Expected: " + expected_sha256 + " Computed: " + computed_hex
		}
		
	if signature_b64.is_empty():
		return {"valid": false, "error": "Package is unsigned"}
		
	var sig_bytes = Marshalls.base64_to_raw(signature_b64)
	if sig_bytes.is_empty():
		return {"valid": false, "error": "Invalid base64 signature"}
		
	var pub_key = CryptoKey.new()
	var err = pub_key.load_from_string(PUBLIC_KEY_PEM, true)
	if err != OK:
		return {"valid": false, "error": "Internal error loading public key"}
		
	var crypto = Crypto.new()
	var is_verified = crypto.verify(HashingContext.HASH_SHA256, raw_hash, sig_bytes, pub_key)
	if not is_verified:
		return {"valid": false, "error": "Digital signature verification failed! Package may be modified or untrusted."}
		
	return {"valid": true, "error": ""}

static func get_server_base_url(node: Node = null) -> String:
	if node and is_instance_valid(node) and node.is_inside_tree():
		var nm = node.get_tree().root.get_node_or_null("NetworkManager")
		if nm and nm.has_method("get_http_url"):
			return nm.get_http_url()
	return "https://lodestone.disaac1.com"

# Check if an update is available on the backend server
static func check_for_update(node: Node, callback: Callable) -> void:
	if is_dev_environment():
		_diagnostic("Auto-update check disabled by development guard.")
		callback.call(false, {})
		return

	var http = HTTPRequest.new()
	http.timeout = 3.0
	node.add_child(http)
	
	var url = get_server_base_url(node) + "/api/client/version?client_version=" + BASE_VERSION.uri_encode()
	_diagnostic("Checking update: base=" + BASE_VERSION + " active=" + active_version + " bridge=" + str(is_bridge_version()) + " url=" + url)
	http.request_completed.connect(func(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
		http.queue_free()
		if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
			_diagnostic("Update check failed: result=" + str(result) + " HTTP=" + str(response_code) + " body=" + body.get_string_from_utf8().left(300))
			callback.call(false, {})
			return
			
		var parsed = JSON.parse_string(body.get_string_from_utf8())
		if parsed is Dictionary and parsed.has("version"):
			var remote_version = parsed.get("version", "1.0.0")
			var has_update = is_version_newer(remote_version, active_version)
			_diagnostic("Update response: remote=" + str(remote_version) + " active=" + active_version + " mode=" + str(parsed.get("update_mode", "")) + " force_restart=" + str(parsed.get("force_restart", false)) + " has_update=" + str(has_update))
			callback.call(has_update, parsed)
		else:
			_diagnostic("Update response missing version: " + body.get_string_from_utf8().left(300))
			callback.call(false, {})
	)
	
	var err = http.request(url)
	if err != OK:
		http.queue_free()
		_diagnostic("Update request could not start: " + str(err))
		callback.call(false, {})

# Download new .pck file from server, verify signature, and load dynamically
static func apply_update(node: Node, update_info: Dictionary, progress_callback: Callable, completed_callback: Callable) -> void:
	if is_dev_environment():
		completed_callback.call(false, "Update mounting is disabled by the development guard")
		return

	var http = HTTPRequest.new()
	http.use_threads = true
	http.download_chunk_size = 1048576 # 1 MB buffer for fast downloads
	node.add_child(http)
	
	var download_url_rel = update_info.get("download_url", "/api/client/download-pck")
	var target_version = update_info.get("version", "")
	var expected_sha256 = update_info.get("sha256", "")
	var signature_b64 = update_info.get("signature", "")
	var replaces_base_pck: bool = update_info.get("update_mode", "") == "finalize"
	
	var download_url = get_server_base_url(node) + download_url_rel
	_diagnostic("Starting update download: target=" + str(target_version) + " mode=" + str(update_info.get("update_mode", "")) + " replace_base=" + str(replaces_base_pck) + " url=" + download_url)
	http.download_file = UPDATE_TEMP_PATH
	
	# Cleanup any previous partial temp file
	if FileAccess.file_exists(UPDATE_TEMP_PATH):
		DirAccess.remove_absolute(UPDATE_TEMP_PATH)
		
	http.request_completed.connect(func(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray):
		http.queue_free()
		if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
			if FileAccess.file_exists(UPDATE_TEMP_PATH):
				DirAccess.remove_absolute(UPDATE_TEMP_PATH)
			completed_callback.call(false, "Download failed with HTTP " + str(response_code))
			_diagnostic("Update download failed: result=" + str(result) + " HTTP=" + str(response_code))
			return
			
		if not FileAccess.file_exists(UPDATE_TEMP_PATH):
			completed_callback.call(false, "Downloaded file not found on disk")
			return
			
		# Step 1: Verify cryptographic signature and SHA-256
		var verify_result = verify_pck(UPDATE_TEMP_PATH, expected_sha256, signature_b64)
		if not verify_result.get("valid", false):
			DirAccess.remove_absolute(UPDATE_TEMP_PATH)
			var err_msg = str(verify_result.get("error", "Signature verification failed"))
			push_error("[Updater] " + err_msg)
			completed_callback.call(false, err_msg)
			_diagnostic("Update verification failed: " + err_msg)
			return
			
		# Stage the final bridge package beside the installed base pack. The
		# loaded base pack cannot be replaced until this process exits.
		var destination_pck := ProjectSettings.globalize_path(UPDATE_PCK_PATH)
		if replaces_base_pck:
			destination_pck = ProjectSettings.globalize_path(get_base_pck_path()) + ".update"
		if FileAccess.file_exists(destination_pck):
			DirAccess.remove_absolute(destination_pck)
		var rename_err = DirAccess.rename_absolute(ProjectSettings.globalize_path(UPDATE_TEMP_PATH), destination_pck)
		if rename_err != OK:
			completed_callback.call(false, "Failed to stage update PCK at " + destination_pck)
			return

		if replaces_base_pck:
			pending_base_pck_path = destination_pck
			pending_base_pck_target = get_base_pck_path()
			active_version = target_version
			print("[Updater] Base PCK replacement staged for v", target_version, ": ", pending_base_pck_target)
			_diagnostic("Base PCK replacement staged: source=" + destination_pck + " target=" + pending_base_pck_target)
			completed_callback.call(true, "Base update staged. Restarting...")
			return
			
		# Step 3: Record update metadata before reporting success. The next
		# process must mount this package before the main scene is loaded.
		var meta_data = {
			"version": target_version,
			"sha256": expected_sha256,
			"signature": signature_b64,
			"installed_at": Time.get_datetime_string_from_system()
		}
		var meta_file = FileAccess.open(UPDATE_META_TEMP_PATH, FileAccess.WRITE)
		if not meta_file:
			DirAccess.remove_absolute(UPDATE_PCK_PATH)
			completed_callback.call(false, "Failed to write update metadata")
			return
		meta_file.store_string(JSON.stringify(meta_data, "  "))
		meta_file.close()

		if FileAccess.file_exists(UPDATE_META_PATH):
			DirAccess.remove_absolute(UPDATE_META_PATH)
		var meta_rename_err := DirAccess.rename_absolute(UPDATE_META_TEMP_PATH, UPDATE_META_PATH)
		if meta_rename_err != OK:
			DirAccess.remove_absolute(UPDATE_META_TEMP_PATH)
			DirAccess.remove_absolute(UPDATE_PCK_PATH)
			completed_callback.call(false, "Failed to finalize update metadata")
			return

		active_version = target_version
		print("[Updater] Update staged successfully: v", active_version)
		_diagnostic("Overlay update staged successfully: v" + active_version)
		completed_callback.call(true, "Update staged successfully. Restarting...")
	)
	
	var err = http.request(download_url)
	if err != OK:
		http.queue_free()
		completed_callback.call(false, "Could not start download request")

static func restart_application(node: Node) -> bool:
	if is_dev_environment():
		return false
	if not node or not is_instance_valid(node) or not node.get_tree():
		return false

	var executable_path := OS.get_executable_path()
	if executable_path.is_empty() or not FileAccess.file_exists(executable_path):
		push_error("[Updater] Cannot restart: executable path is unavailable")
		return false

	if pending_base_pck_path != "" and pending_base_pck_target != "":
		return _restart_with_base_pck_replacement(node, executable_path)

	var process_id := OS.create_process(executable_path, [])
	if process_id <= 0:
		push_error("[Updater] Cannot restart: failed to launch replacement process")
		return false

	print("[Updater] Replacement process started (PID ", process_id, "). Exiting current process.")
	node.get_tree().quit()
	return true

static func get_base_pck_path() -> String:
	var executable_path := OS.get_executable_path()
	return executable_path.get_base_dir().path_join(executable_path.get_file().get_basename() + ".pck")

static func _restart_with_base_pck_replacement(node: Node, executable_path: String) -> bool:
	var script_path := ProjectSettings.globalize_path("user://replace_base_pck.cmd")
	var log_path := ProjectSettings.globalize_path("user://replace_base_pck.log")
	var script_file := FileAccess.open(script_path, FileAccess.WRITE)
	if not script_file:
		push_error("[Updater] Cannot create base PCK replacement helper.")
		return false

	script_file.store_string("@echo off\r\n")
	script_file.store_string("set \"LOG=" + log_path + "\"\r\n")
	script_file.store_string("echo Replacement helper started %date% %time% > \"%LOG%\"\r\n")
	script_file.store_string("set /a ATTEMPTS=0\r\n")
	script_file.store_string(":replace\r\n")
	script_file.store_string("set /a ATTEMPTS+=1\r\n")
	script_file.store_string("move /Y \"" + pending_base_pck_path + "\" \"" + pending_base_pck_target + "\" >> \"%LOG%\" 2>&1\r\n")
	script_file.store_string("if exist \"" + pending_base_pck_path + "\" goto retry\r\n")
	script_file.store_string("echo Replacement succeeded on attempt %ATTEMPTS% >> \"%LOG%\"\r\n")
	script_file.store_string("start \"\" \"" + executable_path + "\"\r\n")
	script_file.store_string("del \"%~f0\"\r\n")
	script_file.store_string("exit /b 0\r\n")
	script_file.store_string(":retry\r\n")
	script_file.store_string("if %ATTEMPTS% GEQ 30 goto failed\r\n")
	script_file.store_string("timeout /t 1 /nobreak >nul\r\n")
	script_file.store_string("goto replace\r\n")
	script_file.store_string(":failed\r\n")
	script_file.store_string("echo Replacement failed after %ATTEMPTS% attempts >> \"%LOG%\"\r\n")
	script_file.close()

	var process_id := OS.create_process("cmd.exe", ["/C", script_path])
	if process_id <= 0:
		push_error("[Updater] Cannot start base PCK replacement helper.")
		return false

	print("[Updater] Base PCK replacement helper started (PID ", process_id, "). Exiting current process.")
	node.get_tree().quit()
	return true
