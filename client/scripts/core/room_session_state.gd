class_name RoomSessionState
extends RefCounted

# =====================================================================
#                        ROOM SESSION STATE
# =====================================================================
# Encapsulates active multiplayer room session variables previously
# stored loosely inside NetworkManager. Provides a typed container and
# a clean reset() method for complete session teardown.
# =====================================================================

var player_name: String = ""
var room_code: String = ""
var user_id: String = ""
var players: Array = []
var seed_status: String = "idle"
var seed_zip_name: String = ""
var seed_spoiler_name: String = ""
var tunnel_url: String = ""
var locked_by: String = ""
var checks: Dictionary = {}
var hosting_mode: String = "wayfinder_backend"
var hosting_status: String = ""
var hosting_room_url: String = ""
var hosting_server_url: String = ""

func reset() -> void:
	player_name = ""
	room_code = ""
	user_id = ""
	players = []
	seed_status = "idle"
	seed_zip_name = ""
	seed_spoiler_name = ""
	tunnel_url = ""
	locked_by = ""
	checks = {}
	hosting_mode = "wayfinder_backend"
	hosting_status = ""
	hosting_room_url = ""
	hosting_server_url = ""

func apply_room_joined(data: Dictionary) -> void:
	room_code = data.get("roomCode", "")
	user_id = data.get("userId", "")
	players = data.get("players", [])
	seed_status = data.get("seedStatus", "idle")
	var sz = data.get("seedZipName")
	seed_zip_name = sz if sz != null else ""
	var ss = data.get("seedSpoilerName")
	seed_spoiler_name = ss if ss != null else ""
	var tu = data.get("tunnelUrl")
	tunnel_url = tu if tu != null else ""
	var hm = data.get("hostingMode")
	hosting_mode = hm if hm is String else "wayfinder_backend"
	var hs = data.get("hostingStatus")
	hosting_status = hs if hs is String else ""
	var hru = data.get("hostingRoomUrl")
	hosting_room_url = hru if hru is String else ""
	var hsu = data.get("hostingServerUrl")
	hosting_server_url = hsu if hsu is String else ""
	var lb = data.get("lockedBy")
	locked_by = lb if lb != null else ""
	var ch = data.get("checks")
	checks = ch if ch is Dictionary else {}
	
	for p in players:
		if p.get("userId") == user_id:
			player_name = p.get("name", "")
			break

func apply_room_state(data: Dictionary) -> void:
	players = data.get("players", [])
	seed_status = data.get("seedStatus", "idle")
	var sz = data.get("seedZipName")
	seed_zip_name = sz if sz != null else ""
	var ss = data.get("seedSpoilerName")
	seed_spoiler_name = ss if ss != null else ""
	var tu = data.get("tunnelUrl")
	tunnel_url = tu if tu != null else ""
	var hm = data.get("hostingMode")
	hosting_mode = hm if hm is String else "wayfinder_backend"
	var hs = data.get("hostingStatus")
	hosting_status = hs if hs is String else ""
	var hru = data.get("hostingRoomUrl")
	hosting_room_url = hru if hru is String else ""
	var hsu = data.get("hostingServerUrl")
	hosting_server_url = hsu if hsu is String else ""
	var lb = data.get("lockedBy")
	locked_by = lb if lb != null else ""
	var ch = data.get("checks")
	if ch is Dictionary:
		checks = ch

func apply_checks(new_checks: Dictionary) -> void:
	checks = new_checks

func is_in_room() -> bool:
	return room_code != "" and user_id != ""

func is_seed_done() -> bool:
	return seed_status == "done"

func is_session_locked() -> bool:
	return locked_by != ""

func get_player_by_id(target_user_id: String) -> Dictionary:
	for p in players:
		if p.get("userId") == target_user_id:
			return p
	return {}

func get_local_player() -> Dictionary:
	return get_player_by_id(user_id)
