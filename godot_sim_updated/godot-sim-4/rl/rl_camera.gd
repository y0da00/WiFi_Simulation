extends Node3D

@export var rotation_speed := 0.3
@export var zoom_speed := 1.0
@export var min_zoom := 2.0
@export var max_zoom := 80.0
@export var pan_speed := 0.002
@export var start_pitch := -40.0

var rotating := false
var panning := false
var follow := true
var target: Node3D

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	rotation_degrees.x = start_pitch

func _process(_delta: float) -> void:
	if follow and is_instance_valid(target):
		global_position = target.global_position

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			rotating = event.pressed
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			panning = event.pressed
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			zoom(-zoom_speed)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			zoom(zoom_speed)
	elif event is InputEventMouseMotion and rotating:
		rotation_degrees.y -= event.relative.x * rotation_speed
		rotation_degrees.x = clamp(rotation_degrees.x - event.relative.y * rotation_speed, -80, 80)
	elif event is InputEventMouseMotion and panning:
		follow = false
		var camera = get_node("Camera3D")
		var step = pan_speed * camera.position.z
		var right = global_transform.basis.x
		var forward = Vector3(global_transform.basis.z.x, 0, global_transform.basis.z.z).normalized()
		global_position -= right * event.relative.x * step + forward * event.relative.y * step
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F:
		follow = true

func zoom(amount: float) -> void:
	var camera = get_node("Camera3D")
	camera.position.z = clamp(camera.position.z + amount, min_zoom, max_zoom)
