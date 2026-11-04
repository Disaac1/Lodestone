extends SceneTree

# =====================================================================
#             SUITE 11: ROOM SESSION STATE & SERVER URL HELPER
# =====================================================================
# Validates typed RoomSessionState encapsulation, clean room reset(),
# NetworkManager session delegation, and standardized ServerUrlHelper
# transformations (ws:// vs wss://, /ap/ stripping, host/port extraction).
# =====================================================================

const RoomSessionState = preload("res://scripts/core/room_session_state.gd")
const ServerUrlHelper = preload("res://scripts/core/server_url_helper.gd")

var test_passed: bool = true

func _init() -> void:
	_run_suite.call_deferred()

func _fail(reason: String) -> void:
	printerr("  ❌ [FAIL] ", reason)
	test_passed = false

func _assert_true(cond: bool, msg: String) -> void:
	if not cond:
		_fail(msg)

func _assert_equal(val, expected, msg: String) -> void:
	if val != expected:
		_fail("%s: expected '%s', got '%s'" % [msg, str(expected), str(val)])

func _run_suite() -> void:
	print("==================================================================")
	print("  SUITE 11: ROOM SESSION STATE & SERVER URL HELPER                ")
	print("==================================================================")

	# -------------------------------------------------------------
	# 1. RoomSessionState Default & Field Typing
	# -------------------------------------------------------------
	print("\n[Test 1] Verifying RoomSessionState defaults & typing...")
	var state = RoomSessionState.new()
	_assert_equal(state.player_name, "", "Default player_name")
	_assert_equal(state.room_code, "", "Default room_code")
	_assert_equal(state.user_id, "", "Default user_id")
	_assert_equal(state.players.size(), 0, "Default players array empty")
	_assert_equal(state.seed_status, "idle", "Default seed_status")
	_assert_equal(state.seed_zip_name, "", "Default seed_zip_name")
	_assert_equal(state.seed_spoiler_name, "", "Default seed_spoiler_name")
	_assert_equal(state.tunnel_url, "", "Default tunnel_url")
	_assert_equal(state.locked_by, "", "Default locked_by")
	_assert_equal(state.checks.size(), 0, "Default checks dict empty")
	_assert_equal(state.hosting_mode, "wayfinder_backend", "Default hosting_mode")
	_assert_equal(state.hosting_status, "", "Default hosting_status")
	_assert_equal(state.hosting_room_url, "", "Default hosting_room_url")
	_assert_equal(state.hosting_server_url, "", "Default hosting_server_url")
	_assert_true(not state.is_in_room(), "Not in room initially")
	print("  -> Passed: Default state verified.")

	# -------------------------------------------------------------
	# 2. RoomSessionState apply_room_joined & apply_room_state
	# -------------------------------------------------------------
	print("\n[Test 2] Verifying apply_room_joined & apply_room_state...")
	var mock_joined = {
		"roomCode": "ABCDEF",
		"userId": "usr_123",
		"players": [
			{"userId": "usr_123", "name": "PlayerOne", "isReady": true},
			{"userId": "usr_456", "name": "PlayerTwo", "isReady": false}
		],
		"seedStatus": "generating",
		"seedZipName": "seed_ABCDEF.zip",
		"seedSpoilerName": "spoiler_ABCDEF.txt",
		"tunnel_url": "wss://lodestone.disaac1.com/ap/ABCDEF",
		"hostingMode": "archipelago_gg",
		"hostingStatus": "running",
		"hostingRoomUrl": "https://archipelago.gg/room/123",
		"hostingServerUrl": "archipelago.gg:38281",
		"lockedBy": "PlayerOne",
		"checks": {"locations_checked": 5}
	}
	state.apply_room_joined(mock_joined)
	_assert_equal(state.room_code, "ABCDEF", "Room code populated")
	_assert_equal(state.user_id, "usr_123", "User ID populated")
	_assert_equal(state.player_name, "PlayerOne", "Player name resolved from players list")
	_assert_equal(state.players.size(), 2, "Players list count")
	_assert_equal(state.seed_status, "generating", "Seed status populated")
	_assert_equal(state.seed_zip_name, "seed_ABCDEF.zip", "Seed zip populated")
	_assert_equal(state.hosting_mode, "archipelago_gg", "Hosting mode populated")
	_assert_equal(state.hosting_server_url, "archipelago.gg:38281", "Hosting server url populated")
	_assert_equal(state.locked_by, "PlayerOne", "Locked by populated")
	_assert_true(state.is_in_room(), "is_in_room() returns true")
	_assert_true(state.is_session_locked(), "is_session_locked() returns true")
	_assert_equal(state.get_local_player().get("name"), "PlayerOne", "get_local_player resolves correctly")

	# apply_room_state updates
	var mock_state_update = {
		"players": [
			{"userId": "usr_123", "name": "PlayerOne", "isReady": true},
			{"userId": "usr_456", "name": "PlayerTwo", "isReady": true}
		],
		"seedStatus": "done",
		"lockedBy": "",
		"checks": {"locations_checked": 10}
	}
	state.apply_room_state(mock_state_update)
	_assert_equal(state.seed_status, "done", "Seed status updated to done")
	_assert_true(state.is_seed_done(), "is_seed_done() returns true")
	_assert_equal(state.locked_by, "", "Session lock released")
	_assert_true(not state.is_session_locked(), "is_session_locked() returns false")
	_assert_equal(state.checks.get("locations_checked"), 10, "Checks updated")
	print("  -> Passed: Message payload application verified.")

	# -------------------------------------------------------------
	# 3. RoomSessionState Clean reset() Teardown
	# -------------------------------------------------------------
	print("\n[Test 3] Verifying clean room teardown via reset()...")
	state.reset()
	_assert_equal(state.player_name, "", "reset() cleared player_name")
	_assert_equal(state.room_code, "", "reset() cleared room_code")
	_assert_equal(state.user_id, "", "reset() cleared user_id")
	_assert_equal(state.players.size(), 0, "reset() cleared players")
	_assert_equal(state.seed_status, "idle", "reset() restored seed_status to idle")
	_assert_equal(state.seed_zip_name, "", "reset() cleared seed_zip_name")
	_assert_equal(state.seed_spoiler_name, "", "reset() cleared seed_spoiler_name")
	_assert_equal(state.tunnel_url, "", "reset() cleared tunnel_url")
	_assert_equal(state.locked_by, "", "reset() cleared locked_by")
	_assert_equal(state.checks.size(), 0, "reset() cleared checks")
	_assert_equal(state.hosting_mode, "wayfinder_backend", "reset() restored hosting_mode")
	_assert_equal(state.hosting_status, "", "reset() cleared hosting_status")
	_assert_equal(state.hosting_room_url, "", "reset() cleared hosting_room_url")
	_assert_equal(state.hosting_server_url, "", "reset() cleared hosting_server_url")
	_assert_true(not state.is_in_room(), "reset() left room state clean")
	print("  -> Passed: reset() completely teardowns session state.")

	# -------------------------------------------------------------
	# 4. NetworkManager Session Delegation & Property Forwarders
	# -------------------------------------------------------------
	print("\n[Test 4] Verifying NetworkManager session delegation...")
	var net_script = load("res://scripts/core/network_manager.gd")
	var nm = net_script.new()
	_assert_true(nm.session is RoomSessionState, "NetworkManager holds typed RoomSessionState")
	_assert_equal(nm.room_code, "", "Forwarded room_code initially empty")
	
	# Modify via forwarded property
	nm.room_code = "TEST01"
	_assert_equal(nm.session.room_code, "TEST01", "Setting nm.room_code updates nm.session.room_code")
	
	nm.seed_status = "generating"
	_assert_equal(nm.session.seed_status, "generating", "Setting nm.seed_status updates nm.session")

	# Teardown via leave_room
	nm.leave_room()
	_assert_equal(nm.room_code, "", "leave_room() cleared room_code via session.reset()")
	_assert_equal(nm.seed_status, "idle", "leave_room() restored seed_status via session.reset()")
	nm.queue_free()
	print("  -> Passed: NetworkManager session forwarders and teardown verified.")

	# -------------------------------------------------------------
	# 5. ServerUrlHelper: WebSocket to HTTP Transformations
	# -------------------------------------------------------------
	print("\n[Test 5] Verifying ServerUrlHelper.ws_to_http & http_to_ws...")
	_assert_equal(
		ServerUrlHelper.ws_to_http("ws://localhost:8080"),
		"http://localhost:8080",
		"ws:// converts to http://"
	)
	_assert_equal(
		ServerUrlHelper.ws_to_http("wss://lodestone.disaac1.com"),
		"https://lodestone.disaac1.com",
		"wss:// converts to https://"
	)
	_assert_equal(
		ServerUrlHelper.ws_to_http("wss://lodestone.disaac1.com/ap/ROOM123"),
		"https://lodestone.disaac1.com",
		"ws_to_http strips /ap/ routing path"
	)
	_assert_equal(
		ServerUrlHelper.ws_to_http("ws://relay.domain:8080/ap/XYZ"),
		"http://relay.domain:8080",
		"ws_to_http strips /ap/ while keeping port"
	)
	_assert_equal(
		ServerUrlHelper.ws_to_http(""),
		ServerUrlHelper.DEFAULT_HTTP_FALLBACK,
		"Empty URL falls back to default HTTP"
	)
	_assert_equal(
		ServerUrlHelper.http_to_ws("http://localhost:8080"),
		"ws://localhost:8080",
		"http:// converts to ws://"
	)
	_assert_equal(
		ServerUrlHelper.http_to_ws("https://lodestone.disaac1.com"),
		"wss://lodestone.disaac1.com",
		"https:// converts to wss://"
	)
	_assert_equal(
		ServerUrlHelper.http_to_ws(""),
		ServerUrlHelper.DEFAULT_WS_FALLBACK,
		"Empty URL falls back to default WebSocket"
	)
	print("  -> Passed: Protocol conversions verified.")

	# -------------------------------------------------------------
	# 6. ServerUrlHelper: Stripping /ap/ Routes
	# -------------------------------------------------------------
	print("\n[Test 6] Verifying ServerUrlHelper.strip_ap & strip_ap_path...")
	_assert_equal(
		ServerUrlHelper.strip_ap("wss://lodestone.disaac1.com/ap/ROOM42"),
		"wss://lodestone.disaac1.com",
		"strip_ap strips /ap/room"
	)
	_assert_equal(
		ServerUrlHelper.strip_ap("ws://localhost:8080/ap"),
		"ws://localhost:8080",
		"strip_ap strips trailing /ap"
	)
	_assert_equal(
		ServerUrlHelper.strip_ap("https://example.com/api/rooms"),
		"https://example.com/api/rooms",
		"strip_ap leaves /api/ intact"
	)
	print("  -> Passed: /ap/ path stripping verified.")

	# -------------------------------------------------------------
	# 7. ServerUrlHelper: Cloud Relay Detection & Format AP Address
	# -------------------------------------------------------------
	print("\n[Test 7] Verifying is_cloud_relay & format_ap_address...")
	_assert_true(ServerUrlHelper.is_cloud_relay("wss://lodestone.disaac1.com/ap/ROOM"), "wss:// is cloud relay")
	_assert_true(ServerUrlHelper.is_cloud_relay("ws://proxy.net/ap/ROOM"), "ws with /ap/ is cloud relay")
	_assert_true(not ServerUrlHelper.is_cloud_relay("ws://localhost:38281"), "direct ws is not cloud relay")
	_assert_true(not ServerUrlHelper.is_cloud_relay("archipelago.gg:38281"), "direct host:port is not cloud relay")

	_assert_equal(
		ServerUrlHelper.format_ap_address("wss://lodestone.disaac1.com/ap/ROOM"),
		"wss://lodestone.disaac1.com/ap/ROOM",
		"format_ap_address preserves cloud relay wss"
	)
	_assert_equal(
		ServerUrlHelper.format_ap_address("ws://localhost:38281"),
		"localhost:38281",
		"format_ap_address strips ws:// on direct server"
	)
	_assert_equal(
		ServerUrlHelper.format_ap_address("ws://relay.net/ap/ROOM"),
		"ws://relay.net/ap/ROOM",
		"format_ap_address preserves ws:// with /ap/"
	)
	_assert_equal(
		ServerUrlHelper.format_ap_address("", "localhost:38000"),
		"localhost:38000",
		"format_ap_address returns fallback when empty"
	)
	print("  -> Passed: Cloud relay detection and address formatting verified.")

	# -------------------------------------------------------------
	# 8. ServerUrlHelper: Host & Port Extraction
	# -------------------------------------------------------------
	print("\n[Test 8] Verifying extract_host_port...")
	var hp1 = ServerUrlHelper.extract_host_port("ws://127.0.0.1:38281")
	_assert_equal(hp1.host, "127.0.0.1", "extract_host ws://127.0.0.1:38281")
	_assert_equal(hp1.port, "38281", "extract_port ws://127.0.0.1:38281")

	var hp2 = ServerUrlHelper.extract_host_port("wss://lodestone.disaac1.com/ap/ROOM")
	_assert_equal(hp2.host, "lodestone.disaac1.com", "extract_host wss relay")
	_assert_equal(hp2.port, "443", "extract_port wss relay default 443")

	var hp3 = ServerUrlHelper.extract_host_port("wss://relay.net:8443/ap/ROOM")
	_assert_equal(hp3.host, "relay.net", "extract_host wss explicit port")
	_assert_equal(hp3.port, "8443", "extract_port wss explicit port")

	var hp4 = ServerUrlHelper.extract_host_port("archipelago.gg:38281")
	_assert_equal(hp4.host, "archipelago.gg", "extract_host bare host:port")
	_assert_equal(hp4.port, "38281", "extract_port bare host:port")

	var hp5 = ServerUrlHelper.extract_host_port("archipelago.gg")
	_assert_equal(hp5.host, "archipelago.gg", "extract_host bare host")
	_assert_equal(hp5.port, "38000", "extract_port default 38000")

	var hp6 = ServerUrlHelper.extract_host_port("")
	_assert_equal(hp6.host, "localhost", "extract_host empty default")
	_assert_equal(hp6.port, "38000", "extract_port empty default")
	print("  -> Passed: Host/port extraction across schemes verified.")

	# -------------------------------------------------------------
	# 9. ServerUrlHelper: resolve_ap_server_url
	# -------------------------------------------------------------
	print("\n[Test 9] Verifying resolve_ap_server_url...")
	_assert_equal(
		ServerUrlHelper.resolve_ap_server_url("", "wss://lodestone.disaac1.com", "archipelago.gg:38281"),
		"archipelago.gg:38281",
		"hosting_server_url takes precedence"
	)
	_assert_equal(
		ServerUrlHelper.resolve_ap_server_url("ws://localhost:38281", "wss://remote.server.org:8080"),
		"ws://remote.server.org:38281",
		"localhost tunnel replaces host with server_url host"
	)
	_assert_equal(
		ServerUrlHelper.resolve_ap_server_url("wss://cloud.relay.com/ap/ROOM", "wss://lodestone.disaac1.com"),
		"wss://cloud.relay.com:443/ap/ROOM",
		"wss:// without explicit port injects :443"
	)
	print("  -> Passed: AP server URL resolution verified.")

	# -------------------------------------------------------------
	# Finish Suite
	# -------------------------------------------------------------
	_finish()

func _finish() -> void:
	print("\n==================================================================")
	if test_passed:
		print("  SUITE 11: ALL SESSION & URL HELPER TESTS PASSED! [OK]           ")
	else:
		printerr("  SUITE 11: COMPLETED WITH FAILURES!                             ")
	print("==================================================================")
	quit(0 if test_passed else 1)
