extends Node3D

const COLORS = {
	"walls": Color(0.9, 0.9, 0.9), "railings": Color(0.3, 0.3, 0.3),
	"stairs_elevators": Color(0.6, 0.6, 0.65), "floors": Color(0.55, 0.5, 0.45),
	"ceilings": Color(0.8, 0.8, 0.75), "doors": Color(0.45, 0.28, 0.12), "windows": Color(0.2, 0.5, 1.0)}

var pivot = Node3D.new()
var cam = Camera3D.new()
var ceilings = Node3D.new()
var floors = Node3D.new()
var dragging = false
var center = Vector3.ZERO
var n = 0

func _ready():
	var light = DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50, 30, 0)
	add_child(light)

	# extra lights from the other sides (and from below) so no face stays dark
	for rot in [Vector3(-50, 210, 0), Vector3(-30, 120, 0), Vector3(-30, -60, 0), Vector3(60, 0, 0)]:
		var fill = DirectionalLight3D.new()
		fill.rotation_degrees = rot
		fill.light_energy = 0.5
		add_child(fill)

	# ambient light: lights every surface evenly, from all directions
	var env = Environment.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 0.4
	var world_env = WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	reload_data()

	pivot.position = center / max(n, 1)
	pivot.rotation_degrees.x = -45
	add_child(pivot)
	cam.position = Vector3(0, 0, 40)
	pivot.add_child(cam)


func make_piece(piece):
	var shape = prism(piece[0], piece[1], piece[2])
	if piece[3].is_empty():
		return shape
	var combiner = CSGCombiner3D.new()          # piece with holes: cut them out
	combiner.add_child(shape)
	for hole in piece[3]:
		var cut = prism(hole, piece[1] - 0.02, piece[2] + 0.04)
		cut.operation = CSGShape3D.OPERATION_SUBTRACTION
		combiner.add_child(cut)
	return combiner


func prism(points, elevation, height):
	var pts = PackedVector2Array()
	for p in points:
		pts.append(Vector2(p[0], p[1]))
	var c = CSGPolygon3D.new()
	c.polygon = pts
	c.depth = height
	c.rotation_degrees.x = 90      # extrude upwards; plan y becomes world z
	c.position.y = elevation
	return c


func clear_building():
	for child in get_children():
		if child != pivot and not child is DirectionalLight3D and not child is WorldEnvironment:
			child.queue_free()


func reload_data():
	clear_building()
	var f = FileAccess.open("res://draw.json", FileAccess.READ)
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	ceilings = Node3D.new()
	floors = Node3D.new()
	add_child(floors)
	add_child(ceilings)
	center = Vector3.ZERO
	n = 0
	for apt in data["apartments"]:
		for kind in COLORS:
			var mat = StandardMaterial3D.new()
			mat.albedo_color = COLORS[kind]
			for piece in apt[kind]:
				var node = make_piece(piece)
				node.material_override = mat
				if kind == "ceilings":
					ceilings.add_child(node)
				elif kind == "floors":
					floors.add_child(node)
				else:
					add_child(node)
				if kind == "walls":
					center += Vector3(piece[0][0][0], piece[1], piece[0][0][1])
					n += 1


func _unhandled_input(event):
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			dragging = event.pressed
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			cam.position.z *= 0.9
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			cam.position.z *= 1.1
	elif event is InputEventMouseMotion and dragging:
		pivot.rotation_degrees.y -= event.relative.x * 0.3
		pivot.rotation_degrees.x = clamp(pivot.rotation_degrees.x - event.relative.y * 0.3, -89, 89)
	elif event is InputEventKey and event.pressed and event.keycode == KEY_C:
		ceilings.visible = not ceilings.visible
	elif event is InputEventKey and event.pressed and event.keycode == KEY_R:
		reload_data()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_F:
		floors.visible = not floors.visible


func _process(delta):
	var dir = Vector3(
		int(Input.is_action_pressed("ui_right")) - int(Input.is_action_pressed("ui_left")), int(Input.is_action_pressed("y_down")) - int(Input.is_action_pressed("y_up")),
		int(Input.is_action_pressed("ui_down")) - int(Input.is_action_pressed("ui_up")))
	if dir != Vector3.ZERO:
		dir = dir.normalized().rotated(Vector3.UP, deg_to_rad(pivot.rotation_degrees.y))
		pivot.position += dir * 5.0 * delta * (cam.position.z / 20)
