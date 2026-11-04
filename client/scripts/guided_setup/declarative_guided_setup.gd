class_name DeclarativeGuidedSetup
extends "res://scripts/guided_setup/base_guided_setup.gd"

var json_definition: Dictionary = {}

func _init(data: Dictionary = {}) -> void:
	json_definition = data
	if json_definition.has("default_config"):
		current_config = json_definition["default_config"].duplicate(true)

func load_from_file(file_path: String) -> bool:
	if not FileAccess.file_exists(file_path):
		return false
	var fa = FileAccess.open(file_path, FileAccess.READ)
	if not fa:
		return false
	var text = fa.get_as_text()
	fa.close()
	var parsed = JSON.parse_string(text)
	if parsed is Dictionary:
		json_definition = parsed
		if json_definition.has("default_config"):
			current_config = json_definition["default_config"].duplicate(true)
		return true
	return false

func _get_game_title() -> String:
	return json_definition.get("game_title", "Game")

func _get_default_config() -> Dictionary:
	return json_definition.get("default_config", {})

func _get_steps_data() -> Array:
	var result: Array = []
	var steps = json_definition.get("steps", [])
	for s in steps:
		result.append({
			"num": s.get("num", 1),
			"title": s.get("title", "Step " + str(s.get("num", 1)))
		})
	return result

func _get_required_schema_keys() -> Array:
	return json_definition.get("required_schema_keys", [])

func _get_check_calculator() -> Dictionary:
	return json_definition.get("check_calculator", {})

static func validate_schema_json(schema: Dictionary, req_keys: Array) -> Dictionary:
	return validate_schema_for_keys(schema, req_keys)

func _build_step_content(step_num: int, container: VBoxContainer) -> void:
	var steps = json_definition.get("steps", [])
	var step_data: Dictionary = {}
	for s in steps:
		if s.get("num") == step_num:
			step_data = s
			break
			
	if step_data.is_empty():
		return
		
	var desc = step_data.get("description", "")
	if desc != "":
		add_step_description(container, desc)
		
	var controls = step_data.get("controls", [])
	for ctrl in controls:
		# Check optional condition
		if ctrl.has("condition"):
			var cond = ctrl["condition"]
			var cond_key = cond.get("option_key", "")
			if cond.has("not_equals"):
				if str(current_config.get(cond_key, "")) == str(cond["not_equals"]):
					continue
			if cond.has("equals"):
				if str(current_config.get(cond_key, "")) != str(cond["equals"]):
					continue

		var c_type = ctrl.get("type", "")
		match c_type:
			"separator":
				var sep = HSeparator.new()
				container.add_child(sep)
				
			"card_grid":
				var opt_key = ctrl.get("option_key", "")
				var cols = ctrl.get("columns", 2)
				var items = ctrl.get("items", [])
				var current_v = current_config.get(opt_key, "")
				add_card_grid(container, items, cols, current_v, func(item_id, item_data):
					var chosen_val = item_data.get("val", item_id)
					set_option_value(opt_key, chosen_val)
				)
				
			"preset_grid":
				var cols = ctrl.get("columns", 3)
				var presets = ctrl.get("presets", [])
				add_card_grid(container, presets, cols, "", func(_id, item_data):
					var values = item_data.get("values", {})
					for k in values.keys():
						set_option_value(k, values[k])
				)
				
			"slider":
				var opt_key = ctrl.get("option_key", "")
				var label = ctrl.get("label", opt_key)
				var min_v = int(ctrl.get("min", 0))
				var max_v = int(ctrl.get("max", 100))
				var step_v = int(ctrl.get("step", 1))
				var suffix = ctrl.get("suffix", "")
				add_slider_option(container, label, opt_key, min_v, max_v, step_v, suffix)
				
			"toggle", "checkbox":
				var opt_key = ctrl.get("option_key", "")
				var label = ctrl.get("label", opt_key)
				add_toggle_option(container, label, opt_key)
				
			"dropdown", "choice":
				var opt_key = ctrl.get("option_key", "")
				var label = ctrl.get("label", opt_key)
				var choices = ctrl.get("choices", ctrl.get("options", []))
				add_dropdown_option(container, label, opt_key, choices)

			"chip_grid", "multi_select":
				var opt_key = ctrl.get("option_key", "")
				var label = ctrl.get("label", opt_key)
				var cols = ctrl.get("columns", 3)
				var items = ctrl.get("items", [])
				add_multi_select_option(container, label, opt_key, items, cols)
