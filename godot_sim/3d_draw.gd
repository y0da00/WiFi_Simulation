extends Spatial

var pivot = Spatial.new()
var cam = Camera.new()
var dragging = false

func _ready():
	var light2 = DirectionalLight.new()
	light2.rotation_degrees = Vector3(50, -30, 0)
	light2.light_energy = 0.5
	add_child(light2)
	var f = File.new()
	f.open("res://draw.json", File.READ)
	var data = parse_json(f.get_as_text())
	f.close()

	var center = Vector3.ZERO
	var n = 0
	for s in data:
		var pts = PoolVector2Array()
		for pair in s[0].split(","):
			var xy = pair.strip_edges().split(" ", false)
			pts.append(Vector2(float(xy[0]), float(xy[1])))
			center += Vector3(pts[-1].x, 0, pts[-1].y)
			n += 1

		var wall = CSGPolygon.new()
		wall.polygon = pts
		wall.depth = s[2]            # height
		wall.rotation_degrees.x = 90
		wall.translation.y = s[1]    # elevation
		add_child(wall)

	# camera
	pivot.translation = center / n
	pivot.rotation_degrees.x = -45
	add_child(pivot)
	cam.translation = Vector3(0, 0, 20)
	pivot.add_child(cam)

	var light = DirectionalLight.new()
	light.rotation_degrees = Vector3(-50, 30, 0)
	add_child(light)

func _unhandled_input(event):
	if event is InputEventMouseButton:
		if event.button_index == BUTTON_LEFT:
			dragging = event.pressed
		elif event.button_index == BUTTON_WHEEL_UP and event.pressed:
			cam.translation.z *= 0.9
		elif event.button_index == BUTTON_WHEEL_DOWN and event.pressed:
			cam.translation.z *= 1.1
	elif event is InputEventMouseMotion and dragging:
		pivot.rotation_degrees.y -= event.relative.x * 0.3
		pivot.rotation_degrees.x = clamp(pivot.rotation_degrees.x - event.relative.y * 0.3, -89, 89)
		

const SPEED = 5.0  

func _process(delta):
	var dir = Vector3.ZERO
	if Input.is_action_pressed("ui_up"):
		dir.z -= 1
	if Input.is_action_pressed("ui_down"):
		dir.z += 1
	if Input.is_action_pressed("ui_left"):
		dir.x -= 1
	if Input.is_action_pressed("ui_right"):
		dir.x += 1

	if dir != Vector3.ZERO:
		dir = dir.normalized().rotated(Vector3.UP, deg2rad(pivot.rotation_degrees.y))
		pivot.translation += dir * SPEED * delta * (cam.translation.z / 20)
