extends Control

signal closed()

const UITheme = preload("res://scripts/ui/ui_theme.gd")

@onready var title_label: Label = %ItemBrowserTitle
@onready var close_btn: Button = %ItemBrowserCloseBtn
@onready var search_input: LineEdit = %ItemSearchInput
@onready var item_list_container: VBoxContainer = %ItemBrowserList

var active_text_edit: TextEdit = null
var is_location_mode: bool = false
var available_items: Array = []
var search_query: String = ""

const COLOR_SELECTED: Color = UITheme.COLOR_SELECTED

func _ready() -> void:
	close_btn.pressed.connect(close)
	search_input.text_changed.connect(_on_search_changed)

func open(title_text: String, target_text_edit: TextEdit, is_location: bool, available_list: Array) -> void:
	active_text_edit = target_text_edit
	is_location_mode = is_location
	available_items = available_list
	search_query = ""
	search_input.text = ""
	title_label.text = title_text
	visible = true
	_update_list_ui()
	search_input.grab_focus()

func close() -> void:
	visible = false
	closed.emit()

func _on_search_changed(query: String) -> void:
	search_query = query.to_lower().strip_edges()
	_update_list_ui()

func _update_list_ui() -> void:
	for child in item_list_container.get_children():
		child.queue_free()

	if active_text_edit == null:
		return

	var current_selections: Array = []
	var raw_lines: PackedStringArray = active_text_edit.text.split("\n")
	for line in raw_lines:
		var cleaned: String = line.strip_edges()
		if cleaned != "":
			if ":" in cleaned:
				cleaned = cleaned.split(":")[0].strip_edges()
			current_selections.append(cleaned)

	for item_entry in available_items:
		var item_str: String = str(item_entry)
		if search_query != "" and not search_query in item_str.to_lower():
			continue

		var is_selected: bool = item_str in current_selections
		var btn: Button = Button.new()
		btn.text = ("[✓] " if is_selected else "[  ] ") + item_str
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.focus_mode = Control.FOCUS_NONE
		btn.custom_minimum_size = Vector2(0, 32)
		
		if is_selected:
			btn.add_theme_color_override("font_color", COLOR_SELECTED)

		btn.pressed.connect(func():
			_toggle_item(item_str, is_selected)
		)
		item_list_container.add_child(btn)

func _toggle_item(item_name: String, currently_selected: bool) -> void:
	if active_text_edit == null:
		return

	var raw_lines: PackedStringArray = active_text_edit.text.split("\n")
	var new_lines: Array = []
	var found_item: bool = false

	for line in raw_lines:
		var cleaned: String = line.strip_edges()
		if cleaned == "":
			continue
		var key_name: String = cleaned
		if ":" in cleaned:
			key_name = cleaned.split(":")[0].strip_edges()

		if key_name == item_name:
			found_item = true
			if currently_selected:
				continue # Remove item
			else:
				new_lines.append(cleaned)
		else:
			new_lines.append(cleaned)

	if not found_item and not currently_selected:
		if ":" in active_text_edit.placeholder_text:
			new_lines.append(item_name + ": 1")
		else:
			new_lines.append(item_name)

	active_text_edit.text = "\n".join(new_lines)
	active_text_edit.text_changed.emit()
	_update_list_ui()
