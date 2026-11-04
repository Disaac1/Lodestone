class_name YamlBuilder
extends RefCounted

# --- CONSTANTS ---
const DEFAULT_OPTION_INDENT: int = 4
const SUB_OPTION_INDENT_STEP: int = 2

const YAML_EMPTY_DICT: String = "{}"
const YAML_EMPTY_ARRAY: String = "[]"
const YAML_NULL_VALUE: String = "null"
const YAML_TRUE_VALUE: String = "true"
const YAML_FALSE_VALUE: String = "false"

const YAML_SPECIAL_CHARACTERS: Array[String] = [":", "{", "}", "[", "]", "#", "-", "?"]


# =====================================================================
#                     YAML COMPILATION PIPELINE
# =====================================================================

static func get_short_game_tag(game_name: String, custom_tag: String = "") -> String:
	if custom_tag != "":
		return custom_tag

	var clean_name: String = game_name.strip_edges()
	match clean_name:
		"Symphony of the Night", "Castlevania: Symphony of the Night":
			return "SotN"
		"Pokemon Emerald":
			return "Emerald"
		"Super Mario 64":
			return "SM64"
		"Plants vs. Zombies", "Plants vs Zombies", "Plants vs. Zombies: Replanted":
			return "PvZ"
		"Hollow Knight":
			return "HK"
		"Metroid Fusion":
			return "Fusion"
		"Pokemon Black and White", "Pokemon Black & White", "Pokemon Black and White Version", "Pokemon Black", "Pokemon White":
			return "BW"
		"Luigi's Mansion", "Luigis Mansion":
			return "LM1"
		"Stardew Valley":
			return "Stardew"
		"The Legend of Zelda: A Link to the Past", "A Link to the Past":
			return "ALTTP"
		"The Legend of Zelda: Ocarina of Time", "Ocarina of Time":
			return "OoT" 
		_:
			if clean_name.length() <= 8 and not clean_name.contains(" "):
				return clean_name
			var words: PackedStringArray = clean_name.split(" ", false)
			if words.size() > 1:
				var stop_words: Array[String] = ["of", "the", "a", "an", "and", "in", "to", "for", "on", "at", "by", "with"]
				var acr: String = ""
				for w in words:
					var w_clean: String = w.strip_edges().replace(":", "").replace("-", "").replace("'", "")
					if w_clean.length() > 0:
						if not stop_words.has(w_clean.to_lower()) or words.size() <= 2:
							var c: String = w_clean[0].to_upper()
							var code: int = c.unicode_at(0)
							if (code >= 65 and code <= 90) or (code >= 48 and code <= 57):
								acr += c
				if acr.length() >= 2:
					return acr
			return clean_name.left(8)

static func get_slot_name(player_name: String, game_name: String, total_games: int, custom_tag: String = "") -> String:
	if total_games <= 1:
		return player_name
	var tag: String = get_short_game_tag(game_name, custom_tag)
	return player_name + " (" + tag + ")"

static func compile_yaml(selected_games: Array, active_config_game: String, player_name: String, _room_code: String, config_states: Dictionary, game_presets: Dictionary = {}) -> String:
	if selected_games.is_empty():
		return ""
		
	if selected_games.size() == 1:
		var game_title: String = str(selected_games[0])
		var game_options: Dictionary = config_states.get(game_title, {})
		var output: String = _build_yaml_header(player_name, game_title)
		output += _build_game_options_block(game_title, game_options)
		return output

	var documents: Array[String] = []
	for game_title in selected_games:
		var g_str: String = str(game_title)
		var custom_tag: String = ""
		if game_presets.has(g_str) and game_presets[g_str] is Dictionary:
			custom_tag = str(game_presets[g_str].get("short_tag", ""))
		else:
			for k in game_presets.keys():
				if str(k).to_lower() == g_str.to_lower() and game_presets[k] is Dictionary:
					custom_tag = str(game_presets[k].get("short_tag", ""))
					break
		var slot_name: String = get_slot_name(player_name, g_str, selected_games.size(), custom_tag)
		var doc: String = _build_yaml_header(slot_name, g_str)
		var game_options: Dictionary = config_states.get(g_str, {})
		doc += _build_game_options_block(g_str, game_options)
		documents.append(doc)

	return "\n---\n".join(documents)

static func _determine_primary_active_game(selected_games: Array, active_config_game: String) -> String:
	if selected_games.is_empty():
		return ""
	if active_config_game != "" and active_config_game in selected_games:
		return active_config_game
	return str(selected_games[0])

static func _build_yaml_header(player_name: String, active_game_title: String) -> String:
	var header_lines: String = ""
	header_lines += "description: Compiled options for " + player_name + " via Wayfinder\n"
	header_lines += "name: " + player_name + "\n"
	header_lines += "game: " + active_game_title + "\n"
	return header_lines

static func _build_game_options_block(game_title: String, game_options: Dictionary) -> String:
	var block_output: String = game_title + ":\n"
	if game_options.is_empty():
		block_output += "  " + YAML_EMPTY_DICT + "\n"
		return block_output
		
	for option_name in game_options.keys():
		var raw_option_value: Variant = game_options[option_name]
		if (game_title == "Pokemon Red and Blue" or game_title == "Pokemon Red Blue" or game_title == "Pokemon Red" or game_title == "Pokemon Blue") and str(option_name) == "trainersanity":
			if raw_option_value is bool:
				raw_option_value = 317 if raw_option_value else 0
		block_output += "  " + str(option_name) + ": " + format_yaml_value(raw_option_value, DEFAULT_OPTION_INDENT) + "\n"
		
	return block_output


# =====================================================================
#                     YAML VALUE FORMATTING HELPERS
# =====================================================================

static func format_yaml_value(raw_value: Variant, indent_level: int) -> String:
	if raw_value == null:
		return YAML_NULL_VALUE
		
	var value_type: int = typeof(raw_value)
	match value_type:
		TYPE_BOOL:
			return YAML_TRUE_VALUE if raw_value else YAML_FALSE_VALUE
			
		TYPE_INT, TYPE_FLOAT:
			if value_type == TYPE_FLOAT and raw_value == float(int(raw_value)):
				return str(int(raw_value))
			return str(raw_value)
			
		TYPE_STRING:
			return _format_string_value(str(raw_value))
			
		TYPE_ARRAY:
			return _format_array_value(raw_value, indent_level)
			
		TYPE_DICTIONARY:
			return _format_dictionary_value(raw_value, indent_level)
			
		_:
			return str(raw_value)

static func _format_string_value(text_value: String) -> String:
	if text_value == "":
		return "\"\""
		
	var requires_quotes: bool = false
	for special_char in YAML_SPECIAL_CHARACTERS:
		if special_char in text_value:
			requires_quotes = true
			break
			
	if not requires_quotes and (text_value.begins_with("-") or text_value.begins_with("?")):
		requires_quotes = true
		
	if requires_quotes:
		return "\"" + text_value.replace("\"", "\\\"") + "\""
	return text_value

static func _format_array_value(array_value: Array, indent_level: int) -> String:
	if array_value.is_empty():
		return YAML_EMPTY_ARRAY
		
	var indentation_spaces: String = " ".repeat(indent_level)
	var formatted_result: String = ""
	for item_entry in array_value:
		formatted_result += "\n" + indentation_spaces + "- " + format_yaml_value(item_entry, indent_level + SUB_OPTION_INDENT_STEP)
	return formatted_result

static func _format_dictionary_value(dict_value: Dictionary, indent_level: int) -> String:
	if dict_value.is_empty():
		return YAML_EMPTY_DICT
		
	var indentation_spaces: String = " ".repeat(indent_level)
	var formatted_result: String = ""
	for dict_key in dict_value.keys():
		var entry_val: Variant = dict_value[dict_key]
		formatted_result += "\n" + indentation_spaces + str(dict_key) + ": " + format_yaml_value(entry_val, indent_level + SUB_OPTION_INDENT_STEP)
	return formatted_result
