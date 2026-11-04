class_name CustomWorldSyncService
extends RefCounted

const USER_TOOLS_DIR: String = "user://tools"

var get_destinations_callback: Callable

func _init(p_get_destinations_callback: Callable = Callable()) -> void:
	get_destinations_callback = p_get_destinations_callback

## Validates whether a file is a non-empty, well-formed ZIP (.apworld) archive.
static func is_valid_apworld(file_path: String) -> bool:
	if not FileAccess.file_exists(file_path):
		return false
	var fa := FileAccess.open(file_path, FileAccess.READ)
	if not fa:
		return false
	var file_size: int = fa.get_length()
	if file_size < 22:
		fa.close()
		return false
	var magic: PackedByteArray = fa.get_buffer(4)
	fa.close()
	if magic.size() < 4 or magic[0] != 0x50 or magic[1] != 0x4B or magic[2] != 0x03 or magic[3] != 0x04:
		return false
	var zr := ZIPReader.new()
	var err := zr.open(file_path)
	if err != OK:
		return false
	var files := zr.get_files()
	zr.close()
	if files.is_empty():
		return false
	return true

func sync_to_archipelago() -> void:
	var source_apworlds: Dictionary = {}
	var source_dirs: Array[String] = [
		"res://custom_worlds",
		"user://custom_worlds"
	]
	
	for s_dir in source_dirs:
		if not DirAccess.dir_exists_absolute(s_dir):
			continue
		var dir: DirAccess = DirAccess.open(s_dir)
		if dir:
			dir.list_dir_begin()
			var fn: String = dir.get_next()
			while fn != "":
				if not dir.current_is_dir() and fn.ends_with(".apworld"):
					var full_src: String = s_dir.path_join(fn)
					if is_valid_apworld(full_src):
						source_apworlds[fn] = full_src
					else:
						print("[CustomWorldSyncService Warning] Ignoring corrupt source apworld: ", full_src)
				fn = dir.get_next()
			dir.list_dir_end()

	var dest_dirs: Array[String] = []
	if get_destinations_callback.is_valid():
		var res = get_destinations_callback.call()
		if res is Array:
			for d in res:
				dest_dirs.append(str(d))

	for dest_dir in dest_dirs:
		var parent_dir: String = dest_dir.get_base_dir()
		if not DirAccess.dir_exists_absolute(parent_dir) and not dest_dir.begins_with(USER_TOOLS_DIR):
			continue
			
		DirAccess.make_dir_recursive_absolute(dest_dir)
		for fn in source_apworlds.keys():
			var src_path: String = source_apworlds[fn]
			var dst_path: String = dest_dir.path_join(fn)
			
			var should_copy: bool = false
			if not FileAccess.file_exists(dst_path):
				should_copy = true
			elif not is_valid_apworld(dst_path):
				print("[CustomWorldSyncService Warning] Corrupt apworld detected at '", dst_path, "'; restoring from valid source.")
				DirAccess.remove_absolute(dst_path)
				should_copy = true
			else:
				var src_fa: FileAccess = FileAccess.open(src_path, FileAccess.READ)
				var dst_fa: FileAccess = FileAccess.open(dst_path, FileAccess.READ)
				if src_fa and dst_fa:
					if src_fa.get_length() != dst_fa.get_length():
						should_copy = true
				if src_fa: src_fa.close()
				if dst_fa: dst_fa.close()

			if should_copy:
				var copy_err: Error = DirAccess.copy_absolute(src_path, dst_path)
				if copy_err == OK:
					print("[CustomWorldSyncService] Synced custom world: ", fn, " to: ", dst_path)
				else:
					print("[CustomWorldSyncService Warning] Failed to copy custom world: ", fn, " to: ", dst_path, " (Error: ", copy_err, ")")

		# Sanitize destination folder to remove any corrupted or non-loadable .apworld files
		_sanitize_destination_dir(dest_dir, source_apworlds)

func _sanitize_destination_dir(dest_dir: String, source_apworlds: Dictionary) -> void:
	if not DirAccess.dir_exists_absolute(dest_dir):
		return
	var dir := DirAccess.open(dest_dir)
	if not dir:
		return
	dir.list_dir_begin()
	var item_name := dir.get_next()
	while item_name != "":
		if not dir.current_is_dir() and item_name.ends_with(".apworld"):
			var target_file := dest_dir.path_join(item_name)
			if not is_valid_apworld(target_file):
				if source_apworlds.has(item_name):
					print("[CustomWorldSyncService] Re-copying valid apworld over corrupted destination: ", target_file)
					DirAccess.remove_absolute(target_file)
					DirAccess.copy_absolute(source_apworlds[item_name], target_file)
				else:
					print("[CustomWorldSyncService Warning] Removing unrepairable corrupt apworld from destination: ", target_file)
					DirAccess.remove_absolute(target_file)
		item_name = dir.get_next()
	dir.list_dir_end()

static func _get_backend_url(node: Node = null) -> String:
	if is_instance_valid(node) and node.get_tree() and node.get_tree().root:
		var nm = node.get_tree().root.get_node_or_null("NetworkManager")
		if nm and nm.has_method("get_http_url"):
			return nm.get_http_url()
	if Engine.get_main_loop() and Engine.get_main_loop() is SceneTree:
		var tree := Engine.get_main_loop() as SceneTree
		var nm = tree.root.get_node_or_null("NetworkManager")
		if nm and nm.has_method("get_http_url"):
			return nm.get_http_url()
	return "http://localhost:8080"

func sync_from_server(node: Node, target_games: Array = [], callback: Callable = Callable()) -> void:
	if not is_instance_valid(node):
		if callback.is_valid():
			callback.call(false)
		return
		
	var http: HTTPRequest = HTTPRequest.new()
	http.use_threads = true
	http.download_chunk_size = 1048576 # 1 MB buffer for maximum download throughput
	node.add_child(http)
	
	http.request_completed.connect(func(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
		http.queue_free()
		if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
			print("[CustomWorldSyncService] Failed to list custom worlds from backend. Result: ", result, ", HTTP status: ", response_code)
			sync_to_archipelago()
			if callback.is_valid():
				callback.call(false)
			return
			
		var parsed = JSON.parse_string(body.get_string_from_utf8())
		if not (parsed is Dictionary) or not parsed.has("worlds"):
			print("[CustomWorldSyncService] Backend returned an invalid custom worlds list.")
			sync_to_archipelago()
			if callback.is_valid():
				callback.call(false)
			return
			
		var worlds: Array = parsed.get("worlds", [])
		if not target_games.is_empty():
			var filtered: Array = []
			var targets: Array[String] = []
			for tg in target_games:
				var n: String = str(tg).to_lower().replace(" ", "").replace("_", "").replace("-", "").replace(":", "")
				if n != "" and not targets.has(n):
					targets.append(n)
			for w in worlds:
				var w_game: String = str(w.get("game", "")).to_lower().replace(" ", "").replace("_", "").replace("-", "").replace(":", "")
				var w_fn: String = str(w.get("filename", "")).to_lower().replace(".apworld", "").replace("_", "").replace("-", "")
				var is_match: bool = false
				for t in targets:
					if (w_game != "" and (t in w_game or w_game in t)) or (w_fn != "" and (t in w_fn or w_fn in t)):
						is_match = true
						break
				if is_match:
					filtered.append(w)
			worlds = filtered
		_download_next_custom_world(node, worlds, 0, callback)
	)
	
	var list_url: String = _get_backend_url(node) + "/api/custom-worlds"
	var err: Error = http.request(list_url)
	if err != OK:
		print("[CustomWorldSyncService] Failed to start custom worlds list request. Error: ", err)
		http.queue_free()
		sync_to_archipelago()
		if callback.is_valid():
			callback.call(false)

func _download_next_custom_world(node: Node, worlds: Array, index: int, finish_cb: Callable) -> void:
	if index >= worlds.size():
		sync_to_archipelago()
		if finish_cb.is_valid():
			finish_cb.call(true)
		return

	var world_info: Dictionary = worlds[index]
	var fn: String = world_info.get("filename", "")
	var server_size: int = int(world_info.get("size", 0))
	if fn == "":
		_download_next_custom_world(node, worlds, index + 1, finish_cb)
		return

	var user_cw_dir: String = "user://custom_worlds"
	DirAccess.make_dir_recursive_absolute(user_cw_dir)
	var local_file: String = user_cw_dir.path_join(fn)
	var local_bundle_file: String = "res://custom_worlds".path_join(fn)

	var need_download: bool = true
	if FileAccess.file_exists(local_file):
		if is_valid_apworld(local_file):
			var fa = FileAccess.open(local_file, FileAccess.READ)
			if fa:
				if server_size <= 0 or fa.get_length() == server_size:
					need_download = false
				fa.close()
		else:
			print("[CustomWorldSyncService] Local apworld '", fn, "' is corrupt; removing and redownloading...")
			DirAccess.remove_absolute(local_file)
	elif FileAccess.file_exists(local_bundle_file):
		if is_valid_apworld(local_bundle_file):
			var fa = FileAccess.open(local_bundle_file, FileAccess.READ)
			if fa:
				if server_size <= 0 or fa.get_length() == server_size:
					need_download = false
				fa.close()

	if not need_download:
		_download_next_custom_world(node, worlds, index + 1, finish_cb)
		return

	var temp_download_file: String = user_cw_dir.path_join("temp_" + fn)
	if FileAccess.file_exists(temp_download_file):
		DirAccess.remove_absolute(temp_download_file)

	var http: HTTPRequest = HTTPRequest.new()
	http.use_threads = true
	http.download_chunk_size = 1048576 # 1 MB buffer for maximum download throughput
	node.add_child(http)
	http.download_file = temp_download_file
	http.request_completed.connect(func(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray):
		http.queue_free()
		if result == HTTPRequest.RESULT_SUCCESS and response_code == 200:
			if is_valid_apworld(temp_download_file):
				if FileAccess.file_exists(local_file):
					DirAccess.remove_absolute(local_file)
				var move_err := DirAccess.copy_absolute(temp_download_file, local_file)
				if move_err == OK:
					DirAccess.remove_absolute(temp_download_file)
					print("[CustomWorldSyncService] Downloaded and verified custom world: ", fn)
				else:
					print("[CustomWorldSyncService Error] Failed to promote verified custom world: ", fn)
			else:
				print("[CustomWorldSyncService Error] Downloaded custom world '", fn, "' failed ZIP verification; removing corrupt download.")
		else:
			print("[CustomWorldSyncService] Failed to download custom world '", fn, "'. Result: ", result, ", HTTP status: ", response_code)

		if FileAccess.file_exists(temp_download_file):
			DirAccess.remove_absolute(temp_download_file)

		_download_next_custom_world(node, worlds, index + 1, finish_cb)
	)
	var dl_url: String = _get_backend_url(node) + "/api/custom-worlds/" + fn.uri_encode()
	var err: Error = http.request(dl_url)
	if err != OK:
		print("[CustomWorldSyncService] Failed to start custom world download for '", fn, "'. Error: ", err)
		http.queue_free()
		if FileAccess.file_exists(temp_download_file):
			DirAccess.remove_absolute(temp_download_file)
		_download_next_custom_world(node, worlds, index + 1, finish_cb)
