class_name RomCatalogManager
extends RefCounted

const ServerUrlHelper = preload("res://scripts/core/server_url_helper.gd")

const ROMS_JSON_PATH: String = "user://roms.json"
const DEFAULT_FALLBACK_URL: String = "https://lodestone.disaac1.com/roms.json"


static func load_catalog() -> Dictionary:
	var catalog: Dictionary = {}
	if FileAccess.file_exists(ROMS_JSON_PATH):
		var f: FileAccess = FileAccess.open(ROMS_JSON_PATH, FileAccess.READ)
		if f:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			f.close()
			if parsed is Dictionary:
				for k in parsed.keys():
					catalog[k] = parsed[k]

	return catalog

static func save_catalog(data: Dictionary) -> bool:
	var json_text: String = JSON.stringify(data, "  ")
	var success_count: int = 0
		
	var f2: FileAccess = FileAccess.open(ROMS_JSON_PATH, FileAccess.WRITE)
	if f2:
		f2.store_string(json_text)
		f2.close()
		success_count += 1
		
	return success_count > 0

static func get_catalog_info() -> Dictionary:
	var cat: Dictionary = load_catalog()
	var file_found: bool = FileAccess.file_exists(ROMS_JSON_PATH)
	var configured_count: int = 0
	
	for k in cat.keys():
		var val = cat[k]
		if val is String and val.strip_edges() != "":
			configured_count += 1
		elif val is Dictionary and str(val.get("url", "")).strip_edges() != "":
			configured_count += 1
			
	return {
		"exists": file_found,
		"path": ROMS_JSON_PATH,
		"total_count": cat.size(),
		"configured_count": configured_count,
		"entries": cat
	}

static func load_from_local_file(source_path: String) -> Dictionary:
	if not FileAccess.file_exists(source_path):
		return {"success": false, "error": "Selected file does not exist: " + source_path}
		
	var f: FileAccess = FileAccess.open(source_path, FileAccess.READ)
	if not f:
		return {"success": false, "error": "Could not open file for reading: " + source_path}
		
	var text: String = f.get_as_text()
	f.close()
	
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return {"success": false, "error": "File does not contain a valid JSON object/dictionary."}
		
	var ok: bool = save_catalog(parsed)
	if not ok:
		return {"success": false, "error": "Failed to write rom.json to user directory."}
		
	var info: Dictionary = get_catalog_info()
	return {
		"success": true,
		"path": source_path,
		"total_count": info.total_count,
		"configured_count": info.configured_count,
		"entries": parsed
	}

static func download_catalog_from_url(node: Node, url: String, callback: Callable, redirect_depth: int = 0) -> void:
	if redirect_depth > 5:
		callback.call(false, "Exceeded maximum redirect depth (5).", 0, {})
		return
		
	var clean_url: String = url.strip_edges()
	if clean_url == "":
		callback.call(false, "Please enter a valid URL.", 0, {})
		return
		
	if not clean_url.begins_with("http://") and not clean_url.begins_with("https://"):
		callback.call(false, "URL must start with http:// or https://", 0, {})
		return
		
	var http: HTTPRequest = HTTPRequest.new()
	http.timeout = 10.0
	node.add_child(http)
	
	http.request_completed.connect(func(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray):
		http.queue_free()
		
		# Check for HTTP Redirects
		if response_code in [301, 302, 303, 307, 308]:
			var redirect_location: String = ""
			for h in headers:
				if h.to_lower().begins_with("location:"):
					redirect_location = h.substr(9).strip_edges()
					break
			if redirect_location != "":
				if not redirect_location.begins_with("http://") and not redirect_location.begins_with("https://"):
					# Handle relative redirects
					var base_scheme_host: String = clean_url.substr(0, clean_url.find("/", 8))
					redirect_location = base_scheme_host + (redirect_location if redirect_location.begins_with("/") else "/" + redirect_location)
				download_catalog_from_url(node, redirect_location, callback, redirect_depth + 1)
				return
				
		if result != HTTPRequest.RESULT_SUCCESS or (response_code != 200 and response_code != 0):
			callback.call(false, "Download failed (HTTP status %d, result code %d)." % [response_code, result], 0, {})
			return
			
		var body_str: String = body.get_string_from_utf8()
		var parsed: Variant = JSON.parse_string(body_str)
		if not (parsed is Dictionary):
			callback.call(false, "Downloaded response is not a valid JSON dictionary.", 0, {})
			return
			
		var ok: bool = save_catalog(parsed)
		if not ok:
			callback.call(false, "Failed to save downloaded rom.json to disk.", 0, {})
			return
			
		var info: Dictionary = get_catalog_info()
		var msg: String = "Loaded %d ROM entries (%d with URLs)." % [info.total_count, info.configured_count]
		callback.call(true, msg, info.configured_count, parsed)
	)
	
	var err: Error = http.request(clean_url)
	if err != OK:
		http.queue_free()
		callback.call(false, "Failed to initiate HTTP request (Error %d)." % err, 0, {})

static func get_default_catalog_url(server_address: String = "") -> String:
	var raw = server_address.strip_edges()
	if raw == "":
		return DEFAULT_FALLBACK_URL
	return ServerUrlHelper.get_http_origin(raw) + "/roms.json"
