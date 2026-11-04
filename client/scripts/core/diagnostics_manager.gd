extends Node

## DiagnosticsManager
## Autoload service providing global F12 access to the DiagnosticsOverlay.
## Attaches to the root SceneTree canvas layer to ensure instant availability
## on any screen (Main Menu, Lobby, Dashboard).

const DiagnosticsOverlayScene = preload("res://scenes/modals/diagnostics_overlay.tscn")

var overlay: Node = null
var current_launcher = null

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F12:
			toggle_overlay()
			get_viewport().set_input_as_handled()

func register_launcher(p_launcher) -> void:
	current_launcher = p_launcher
	if overlay and is_instance_valid(overlay):
		overlay.set_launcher(p_launcher)

func get_or_create_overlay() -> Node:
	if not overlay or not is_instance_valid(overlay):
		overlay = DiagnosticsOverlayScene.instantiate()
		overlay.set_launcher(current_launcher)
		var root = get_tree().root
		root.add_child(overlay)
	return overlay

func toggle_overlay() -> void:
	var ov = get_or_create_overlay()
	ov.toggle()

func open_overlay() -> void:
	var ov = get_or_create_overlay()
	ov.open()

func close_overlay() -> void:
	if overlay and is_instance_valid(overlay):
		overlay.close()
