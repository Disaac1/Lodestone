class_name BannerService
extends RefCounted

# =====================================================================
#             BANNER SERVICE: TEXTURE CACHE & HTTP LOADER
# =====================================================================
# Manages multi-tier banner lookup (memory cache, local disk cache,
# user runtime drop-in directory, bundled assets, and multi-URL HTTP fallback).
# =====================================================================

const GameIdentityResolver = preload("res://scripts/core/game_identity_resolver.gd")

const CACHE_DIR: String = "user://cache/banners"
const USER_BANNERS_DIR: String = "user://banners"
const BUNDLED_BANNERS_DIR: String = "res://assets/banners"
const DEFAULT_BACKEND_URL: String = "https://lodestone.disaac1.com"

# --- SIGNALS (Instance / Singleton) ---
signal banner_loaded(slug: String, texture: Texture2D)
signal banner_failed(slug: String)

# --- STATIC CACHE & STATE ---
static var _memory_texture_cache: Dictionary = {}
static var _pending_requests: Dictionary = {}
static var _instance = null

# =====================================================================
#                      SINGLETON ACCESSOR
# =====================================================================

static func get_instance():
	if _instance == null:
		_instance = load("res://scripts/core/banner_service.gd").new()
	return _instance

# =====================================================================
#                      CACHE UTILITIES
# =====================================================================

static func get_cached_texture(slug: String) -> Texture2D:
	return _memory_texture_cache.get(slug, null)

static func set_cached_texture(slug: String, texture: Texture2D) -> void:
	if texture != null:
		_memory_texture_cache[slug] = texture

static func has_cached_texture(slug: String) -> bool:
	return _memory_texture_cache.has(slug)

static func clear_cache() -> void:
	_memory_texture_cache.clear()
	_pending_requests.clear()

static func is_request_pending(slug: String) -> bool:
	return _pending_requests.has(slug)

static func get_game_slug(game_name: String, preset: Dictionary = {}) -> String:
	return GameIdentityResolver.resolve_slug(game_name, preset)

static func get_backend_base_url(context_node: Node = null) -> String:
	var net_mgr = null
	if is_instance_valid(context_node) and context_node.is_inside_tree():
		net_mgr = context_node.get_node_or_null("/root/NetworkManager")
	if net_mgr == null:
		var main_loop = Engine.get_main_loop()
		if main_loop is SceneTree and main_loop.root:
			net_mgr = main_loop.root.get_node_or_null("NetworkManager")
	if is_instance_valid(net_mgr) and net_mgr.has_method("get_http_url"):
		return net_mgr.get_http_url()
	return DEFAULT_BACKEND_URL

static func get_candidate_urls(slug: String, context_node: Node = null) -> Array[String]:
	var base_url: String = get_backend_base_url(context_node)
	var urls: Array[String] = [
		base_url + "/data/games/" + slug + "/icon.png",
		base_url + "/api/games/" + slug + "/icon",
		base_url + "/data/" + slug + "/icon.png"
	]
	return urls

# =====================================================================
#                      BANNER LOADING PIPELINE
# =====================================================================

static func load_game_banner(game_name: String, preset: Dictionary = {}, context_node: Node = null, callback: Callable = Callable()) -> Texture2D:
	var slug: String = get_game_slug(game_name, preset)
	return load_banner_by_slug(slug, context_node, callback)

static func load_banner_by_slug(slug: String, context_node: Node = null, callback: Callable = Callable()) -> Texture2D:
	if slug.is_empty():
		return null

	# 1. Check in-memory cache
	if _memory_texture_cache.has(slug):
		return _memory_texture_cache[slug]

	# 2. Check local disk cache (previously downloaded from backend)
	var cache_path: String = CACHE_DIR + "/" + slug + ".png"
	if FileAccess.file_exists(cache_path):
		var img: Image = Image.load_from_file(ProjectSettings.globalize_path(cache_path))
		if img and not img.is_empty():
			var tex: ImageTexture = ImageTexture.create_from_image(img)
			_memory_texture_cache[slug] = tex
			return tex

	# 3. Check user runtime drop-in directory
	var user_path: String = USER_BANNERS_DIR + "/" + slug + ".png"
	if FileAccess.file_exists(user_path):
		var img: Image = Image.load_from_file(ProjectSettings.globalize_path(user_path))
		if img and not img.is_empty():
			var tex: ImageTexture = ImageTexture.create_from_image(img)
			_memory_texture_cache[slug] = tex
			return tex

	# 4. Initiate asynchronous backend fetch
	fetch_banner_from_backend(slug, context_node, callback)

	# 5. Check bundled resources as immediate temporary fallback while downloading
	var res_path: String = BUNDLED_BANNERS_DIR + "/" + slug + ".png"
	if ResourceLoader.exists(res_path):
		var bundled_tex = load(res_path) as Texture2D
		if bundled_tex:
			return bundled_tex

	return null

static func fetch_banner_from_backend(slug: String, context_node: Node = null, callback: Callable = Callable()) -> void:
	if slug.is_empty():
		return

	# Re-check in case another request loaded it concurrently
	if _memory_texture_cache.has(slug):
		var cached_tex: Texture2D = _memory_texture_cache[slug]
		if callback.is_valid():
			_dispatch_callback(callback, slug, cached_tex)
		return

	if _pending_requests.has(slug):
		print("[BannerService] Fetch already pending for '%s'; registering callback." % slug)
		if callback.is_valid():
			_pending_requests[slug].append(callback)
		return

	var req_callbacks: Array = []
	if callback.is_valid():
		req_callbacks.append(callback)
	_pending_requests[slug] = req_callbacks

	var urls_to_try: Array[String] = get_candidate_urls(slug, context_node)
	print("[BannerService] Requesting banner for '%s' from backend: %s" % [slug, urls_to_try[0]])
	try_fetch_next_url(slug, urls_to_try, 0, context_node)

static func try_fetch_next_url(slug: String, urls: Array[String], index: int, context_node: Node = null) -> void:
	if index >= urls.size():
		var callbacks: Array = _pending_requests.get(slug, [])
		_pending_requests.erase(slug)
		print("[BannerService] No banner found on backend for '%s' across %d endpoint(s). Using procedural banner." % [slug, urls.size()])
		for cb in callbacks:
			_dispatch_callback(cb, slug, null)
		if _instance:
			_instance.banner_failed.emit(slug)
		return

	var url: String = urls[index]
	var http: HTTPRequest = HTTPRequest.new()
	if not _attach_http_node(http, context_node):
		print("[BannerService Error] Cannot attach HTTPRequest to scene tree for '%s'" % slug)
		http.queue_free()
		var callbacks: Array = _pending_requests.get(slug, [])
		_pending_requests.erase(slug)
		for cb in callbacks:
			_dispatch_callback(cb, slug, null)
		if _instance:
			_instance.banner_failed.emit(slug)
		return

	http.request_completed.connect(func(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
		http.queue_free()
		if result == HTTPRequest.RESULT_SUCCESS and response_code == 200 and body.size() > 0:
			var img: Image = Image.new()
			var err: Error = img.load_png_from_buffer(body)
			if err != OK:
				err = img.load_jpg_from_buffer(body)
			if err != OK:
				err = img.load_webp_from_buffer(body)
			if err == OK:
				var tex: ImageTexture = ImageTexture.create_from_image(img)
				_memory_texture_cache[slug] = tex

				# Write to disk cache
				DirAccess.make_dir_recursive_absolute(CACHE_DIR)
				var cache_path: String = CACHE_DIR + "/" + slug + ".png"
				var f: FileAccess = FileAccess.open(cache_path, FileAccess.WRITE)
				if f:
					f.store_buffer(body)
					f.close()
					print("[BannerService] Successfully saved banner to disk cache: %s" % cache_path)

				var callbacks: Array = _pending_requests.get(slug, [])
				_pending_requests.erase(slug)
				print("[BannerService] Successfully downloaded banner for '%s' (%d bytes) from: %s" % [slug, body.size(), url])
				for cb in callbacks:
					_dispatch_callback(cb, slug, tex)
				if _instance:
					_instance.banner_loaded.emit(slug, tex)
			else:
				printerr("[BannerService Error] Could not decode image data for '%s' (Format Error: %d)" % [slug, err])
				try_fetch_next_url(slug, urls, index + 1, context_node)
		else:
			print("[BannerService] Endpoint %s returned %d (result: %d). Trying next candidate..." % [url, response_code, result])
			try_fetch_next_url(slug, urls, index + 1, context_node)
	)

	var req_err: Error = http.request(url)
	if req_err != OK:
		print("[BannerService Error] HTTP request failed to start for '%s' -> %s (Error code: %d)" % [slug, url, req_err])
		http.queue_free()
		try_fetch_next_url(slug, urls, index + 1, context_node)

static func _attach_http_node(http: HTTPRequest, context_node: Node = null) -> bool:
	if is_instance_valid(context_node) and context_node.is_inside_tree():
		context_node.add_child(http)
		return true
	var main_loop = Engine.get_main_loop()
	if main_loop is SceneTree and main_loop.root:
		main_loop.root.add_child(http)
		return true
	return false

static func _dispatch_callback(cb: Callable, slug: String, tex: Texture2D) -> void:
	if not cb.is_valid():
		return
	var arg_count: int = cb.get_argument_count()
	if arg_count == 1:
		cb.call(tex)
	elif arg_count == 0:
		cb.call()
	else:
		cb.call(slug, tex)

# =====================================================================
#                ALIASES FOR DIRECT DROP-IN COMPATIBILITY
# =====================================================================

static func _load_game_banner(game_name: String, preset: Dictionary = {}, context_node: Node = null, callback: Callable = Callable()) -> Texture2D:
	return load_game_banner(game_name, preset, context_node, callback)

static func _fetch_banner_from_backend(slug: String, context_node: Node = null, callback: Callable = Callable()) -> void:
	fetch_banner_from_backend(slug, context_node, callback)

static func _try_fetch_next_url(slug: String, urls: Array[String], index: int, context_node: Node = null) -> void:
	try_fetch_next_url(slug, urls, index, context_node)
