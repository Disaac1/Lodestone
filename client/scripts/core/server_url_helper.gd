class_name ServerUrlHelper
extends RefCounted

# =====================================================================
#                        SERVER URL HELPER
# =====================================================================
# Central utility for WebSocket-to-HTTP URL transformations, relay
# detection, stripping /ap/ routing prefixes, and extracting host/port
# components across UI screens and game launching services.
# =====================================================================

const DEFAULT_HTTP_FALLBACK: String = "https://lodestone.disaac1.com"
const DEFAULT_WS_FALLBACK: String = "wss://lodestone.disaac1.com"

## Strips protocol prefixes (ws://, wss://, http://, https://) from a URL string.
static func strip_protocol(url: String) -> String:
	var trimmed: String = url.strip_edges()
	for prefix in ["wss://", "ws://", "https://", "http://"]:
		if trimmed.begins_with(prefix):
			return trimmed.substr(prefix.length())
	return trimmed

## Strips Archipelago relay path (/ap/ or trailing /ap) from a URL string.
static func strip_ap_path(url: String) -> String:
	var trimmed: String = url.strip_edges()
	var ap_idx: int = trimmed.find("/ap/")
	if ap_idx != -1:
		return trimmed.substr(0, ap_idx)
	if trimmed.ends_with("/ap"):
		return trimmed.substr(0, trimmed.length() - 3)
	return trimmed

## Strips Archipelago relay path (alias for strip_ap_path).
static func strip_ap(url: String) -> String:
	return strip_ap_path(url)

## Transforms a WebSocket URL (ws://, wss://) into its corresponding HTTP/HTTPS URL,
## optionally stripping any /ap/ relay routing components.
static func ws_to_http(url: String, default_fallback: String = DEFAULT_HTTP_FALLBACK, strip_ap_route: bool = true) -> String:
	var target: String = url.strip_edges()
	if target == "":
		return default_fallback
	if strip_ap_route:
		target = strip_ap_path(target)
	target = target.trim_suffix("/")

	if target.begins_with("ws://"):
		return "http://" + target.substr(5)
	elif target.begins_with("wss://"):
		return "https://" + target.substr(6)
	elif target.begins_with("http://") or target.begins_with("https://"):
		return target
	elif not target.contains("://"):
		if target.begins_with("localhost") or target.begins_with("127.0.0.1"):
			return "http://" + target
		return "https://" + target
	return default_fallback

## Extracts base HTTP root origin (scheme://host:port) without subpaths.
static func get_http_origin(url: String, default_fallback: String = DEFAULT_HTTP_FALLBACK) -> String:
	var target: String = url.strip_edges()
	if target == "":
		return default_fallback
	var http_url = ws_to_http(target, default_fallback, true)
	var proto_split = http_url.split("://")
	if proto_split.size() > 1:
		var scheme = proto_split[0]
		var rest = proto_split[1]
		var slash_idx = rest.find("/")
		if slash_idx != -1:
			rest = rest.substr(0, slash_idx)
		return scheme + "://" + rest
	return http_url

## Transforms an HTTP URL (http://, https://) into its corresponding WebSocket URL.
static func http_to_ws(url: String, default_fallback: String = DEFAULT_WS_FALLBACK) -> String:
	var target: String = url.strip_edges()
	if target == "":
		return default_fallback
	target = target.trim_suffix("/")

	if target.begins_with("http://"):
		return "ws://" + target.substr(7)
	elif target.begins_with("https://"):
		return "wss://" + target.substr(8)
	elif target.begins_with("ws://") or target.begins_with("wss://"):
		return target
	elif target.begins_with("localhost") or target.begins_with("127.0.0.1"):
		return "ws://" + target
	return default_fallback

## Detects if an AP server address is routed through a cloud secure WebSocket relay.
static func is_cloud_relay(url: String) -> bool:
	var trimmed: String = url.strip_edges()
	return trimmed.begins_with("wss://") or "/ap/" in trimmed

## Formats an Archipelago server address for display or client argument passing.
## Cloud relays (wss:// or /ap/) preserve their full URI scheme. Direct local/IP servers
## strip the raw ws:// scheme.
static func format_ap_address(url: String, fallback: String = "") -> String:
	var trimmed: String = url.strip_edges()
	if trimmed == "":
		return fallback
	if trimmed.begins_with("wss://"):
		return trimmed
	elif trimmed.begins_with("ws://"):
		if "/ap/" in trimmed:
			return trimmed
		return trimmed.replace("ws://", "").trim_suffix("/")
	return trimmed.trim_suffix("/")

## Alias for format_ap_address with fallback default.
static func get_client_clean_url(url: String, fallback: String = "localhost:38000") -> String:
	return format_ap_address(url, fallback)

## Extracts host and port from any URL, URI, or host:port string.
static func extract_host_port(url: String, default_host: String = "localhost", default_port: String = "38000") -> Dictionary:
	var trimmed: String = url.strip_edges()
	if trimmed == "":
		return {"host": default_host, "port": default_port}

	var is_wss: bool = trimmed.begins_with("wss://")
	var is_ws: bool = trimmed.begins_with("ws://")
	var is_https: bool = trimmed.begins_with("https://")
	var is_http: bool = trimmed.begins_with("http://")

	var without_proto: String = strip_protocol(trimmed)
	var slash_pos: int = without_proto.find("/")
	var host_port_part: String = without_proto.substr(0, slash_pos) if slash_pos != -1 else without_proto

	if host_port_part.contains(":"):
		var parts: PackedStringArray = host_port_part.split(":")
		var h: String = parts[0].strip_edges()
		var p: String = parts[1].strip_edges()
		return {
			"host": h if h != "" else default_host,
			"port": p if p != "" else default_port
		}
	else:
		var h: String = host_port_part.strip_edges() if host_port_part.strip_edges() != "" else default_host
		var p: String = default_port
		if is_wss or is_https:
			p = "443"
		elif is_ws or is_http:
			p = "80"
		return {"host": h, "port": p}

## Extracts just the host string from a URL.
static func extract_host(url: String, default_host: String = "localhost") -> String:
	return str(extract_host_port(url, default_host)["host"])

## Extracts just the port string from a URL.
static func extract_port(url: String, default_port: String = "38000") -> String:
	return str(extract_host_port(url, "localhost", default_port)["port"])

## Resolves the final Archipelago server connection URL from room tunnel,
## server URL, and external hosting values.
static func resolve_ap_server_url(tunnel_url: String, server_url: String, hosting_server_url: String = "") -> String:
	if hosting_server_url.strip_edges() != "":
		return hosting_server_url.strip_edges()
	var trimmed_tunnel: String = tunnel_url.strip_edges()
	if trimmed_tunnel == "":
		return ""
	if "localhost" in trimmed_tunnel or "127.0.0.1" in trimmed_tunnel:
		# Extract server host (remote IP or domain) from lobby connection url
		var parts: PackedStringArray = server_url.split("://")
		if parts.size() > 1:
			var host_part: String = parts[1].split(":")[0].split("/")[0]
			var port: String = trimmed_tunnel.split(":")[-1]
			return "ws://" + host_part + ":" + port

	# If tunnel_url is a wss:// URL without an explicit port, inject :443
	# Archipelago client requires an explicit port, otherwise it defaults to port 38281
	if trimmed_tunnel.begins_with("wss://"):
		var scheme_split: PackedStringArray = trimmed_tunnel.split("://")
		if scheme_split.size() > 1:
			var rest: String = scheme_split[1]
			var slash_idx: int = rest.find("/")
			var host_part: String = rest.substr(0, slash_idx) if slash_idx != -1 else rest
			var path_part: String = rest.substr(slash_idx) if slash_idx != -1 else ""
			if not ":" in host_part:
				return "wss://" + host_part + ":443" + path_part
	return trimmed_tunnel
