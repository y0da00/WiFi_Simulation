extends Node3D
# Single-player box editor: the building from draw.json, and boxes you can add, drag,
# turn, move between floors and nudge, which never go into walls, floors or ceilings.
# One file, no networking. Attach it to a Node3D as the root of the main scene.
#
# Units: 1 Godot unit = 1 metre. The draw.json export (and the Swiss dataset it comes
# from) is in metres, so box sizes typed here are real sizes. The scale line at the top
# of the screen shows the building's measured floor and door heights to confirm it.
#
# Controls
#   Add box, then click        place a new box on the top floor (Esc cancels)
#   Click a box, drag          move it; it stops at walls and slides along them
#   W / S                      move the selected box one floor up / down
#   Shift+W / Shift+S          move it 1 cm up / down
#   Hold R / Shift+R           turn the selected box (or the box being placed)
#   Delete                     remove the selected box
#   Left-drag on empty space   orbit the camera around the point in the middle of the screen
#   Right-drag                 pan: the floor under the mouse follows it
#   Wheel                      zoom toward the point under the mouse
#   Arrow keys, Q / E          move the camera (Q / E: the y_up / y_down actions)
#   C / F                      show or hide ceilings / floors

const BUILDING_FILE = "res://draw.json"
const FINE_STEP = 0.01               # metres per Shift+W / Shift+S press
const TURN_SPEED = 45.0              # degrees per second while R is held
const ORBIT_SPEED = 0.3              # degrees per pixel of mouse movement
const ZOOM_FACTOR = 0.85             # each wheel step multiplies the camera distance by this
const ZOOM_MIN = 1.5                 # closest and farthest camera distance in metres
const ZOOM_MAX = 300.0
const PITCH_MIN = -89.0              # straight down
const PITCH_MAX = -5.0               # almost level: the camera never dips below the point it looks at

const COLORS = {
	"walls": Color(0.9, 0.9, 0.9), "railings": Color(0.3, 0.3, 0.3),
	"stairs_elevators": Color(0.6, 0.6, 0.65), "floors": Color(0.55, 0.5, 0.45),
	"ceilings": Color(0.8, 0.8, 0.75), "doors": Color(0.45, 0.28, 0.12), "windows": Color(0.2, 0.5, 1.0)}
const BOX_COLOR = Color(0.2, 0.7, 0.3)
const BOX_SELECTED = Color(1.0, 0.8, 0.1)
const GHOST_OK = Color(0.2, 0.8, 0.3, 0.35)  # preview of a new box: fits here
const GHOST_BAD = Color(0.9, 0.2, 0.2, 0.35) # preview of a new box: does not fit here

# how each kind of building piece stops a box
enum {SOLID, SLAB, DOOR}
const BLOCKING = {"walls": SOLID, "railings": SOLID, "windows": SOLID, "stairs_elevators": SOLID,
	"floors": SLAB, "ceilings": SLAB, "doors": DOOR}

# ---- the building ----
var data = {}                        # draw.json as loaded
var obstacles = []                   # {type, kind, poly, holes, rect, y0, y1} for every building piece
var levels = [0.0]                   # height of each floor's surface, lowest first

# ---- boxes ----
var objects = {}                     # box id -> {size: Vector3, pos: Vector3, rot: float (radians, around Y), node, mat}
var next_id = 1
var selected = 0                     # 0 = no box selected
var dragging = false                 # the left button is down on the selected box
var grab_offset = Vector3.ZERO
var placing = false                  # Add box was pressed: the next click places the new box
var ghost_rot = 0.0                  # rotation of the box being placed
var last_mouse = Vector2.ZERO        # where the mouse was last seen, to update the preview while turning

# ---- camera: it hangs on `pivot` and always looks at it ----
var pivot = Node3D.new()             # the point in the middle of the screen
var cam = Camera3D.new()
var orbiting = false                 # the left button is down on empty space
var panning = false                  # the right button is down

# ---- scene ----
var building = Node3D.new()
var ceilings = Node3D.new()
var floors = Node3D.new()
var boxes = Node3D.new()
var ghost = MeshInstance3D.new()     # see-through preview of a new box
var ghost_mat = StandardMaterial3D.new()

# ---- interface ----
var scale_label = Label.new()
var info = Label.new()
var size_boxes = []                  # the three SpinBoxes: width (x), height (y), depth (z)


func _ready():
	add_lights()
	add_child(building)
	add_child(boxes)
	ghost.mesh = BoxMesh.new()
	ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ghost.material_override = ghost_mat
	ghost.visible = false
	add_child(ghost)
	add_child(pivot)
	pivot.add_child(cam)
	make_ui()

	var error = load_building(BUILDING_FILE)
	if error != "":
		scale_label.text = error
		return
	build_building()
	scale_label.text = scale_text()
	place_camera()
	update_info()


func add_lights():
	var light = DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50, 30, 0)
	add_child(light)
	for rot in [Vector3(-50, 210, 0), Vector3(-30, 120, 0), Vector3(-30, -60, 0), Vector3(60, 0, 0)]:
		var fill = DirectionalLight3D.new()
		fill.rotation_degrees = rot
		fill.light_energy = 0.5
		add_child(fill)
	var env = Environment.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 0.4
	var world_env = WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)


# ============================== loading the building ==============================

func load_building(path):                # returns "" or what went wrong
	var f = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "Cannot open %s" % path
	var parsed = JSON.parse_string(f.get_as_text())
	if not parsed is Dictionary or not parsed.get("apartments") is Array:
		return "%s does not contain building data" % path
	data = parsed
	for apt in data.apartments:
		for kind in BLOCKING:
			for piece in apt.get(kind, []):
				add_obstacle(kind, piece)
	find_levels()
	return ""


func plan(points):
	var pts = PackedVector2Array()
	for p in points:
		pts.append(Vector2(p[0], p[1]))
	return pts


func add_obstacle(kind, piece):
	var poly = plan(piece[0])
	if poly.size() < 3:
		return
	var rect = Rect2(poly[0], Vector2.ZERO)
	for p in poly:
		rect = rect.expand(p)
	var holes = []
	for hole in piece[3]:
		holes.append(plan(hole))
	obstacles.append({"type": BLOCKING[kind], "kind": kind, "poly": poly, "holes": holes, "rect": rect,
		"y0": piece[1], "y1": piece[1] + piece[2]})


# floors = the heights of the floor pieces' top surfaces; pieces less than 1.5 m apart are one floor
func find_levels():
	var heights = []
	for o in obstacles:
		if o.kind == "floors":
			heights.append(o.y1)
	heights.sort()
	levels = []
	for h in heights:
		if levels.is_empty() or h > levels[-1] + 1.5:
			levels.append(h)
	if levels.is_empty():
		levels = [0.0]


# measured from the data, so you can check the world is in metres
func scale_text():
	var walls = []
	var doors = []
	for o in obstacles:
		if o.kind == "walls":
			walls.append(o.y1 - o.y0)
		elif o.kind == "doors":
			doors.append(o.y1 - o.y0)
	var parts = ["1 unit = 1 m", "%d floor(s)" % levels.size()]
	if levels.size() > 1:
		parts.append("floor to floor %.2f m" % (levels[1] - levels[0]))
	if not walls.is_empty():
		parts.append("tallest wall piece %.2f m" % walls.max())
	if not doors.is_empty():
		doors.sort()
		parts.append("typical door %.2f m" % doors[doors.size() / 2])
	return "Scale: " + ", ".join(parts)


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
	var c = CSGPolygon3D.new()
	c.polygon = plan(points)
	c.depth = height
	c.rotation_degrees.x = 90      # extrude upwards; plan y becomes world z
	c.position.y = elevation
	return c


func build_building():
	building.add_child(floors)
	building.add_child(ceilings)
	for kind in COLORS:
		var mat = StandardMaterial3D.new()
		mat.albedo_color = COLORS[kind]
		var parent = ceilings if kind == "ceilings" else floors if kind == "floors" else building
		for apt in data.apartments:
			for piece in apt.get(kind, []):
				var node = make_piece(piece)
				node.material_override = mat
				parent.add_child(node)


# ============================== collision rules ==============================
# Every building piece is a plan polygon plus the height range it fills.
# A box (centre `pos`, size `size`, turned `rot`) fits when it overlaps none of them.

func box_y(size, level):                 # y of the box centre when it stands on that floor
	return levels[level] + size.y / 2


func level_of(bottom):                   # the floor at or just below height `bottom`
	var level = 0
	for i in levels.size():
		if levels[i] <= bottom + 0.01:
			level = i
	return level


func blocks_height(o, y0, y1):           # does this piece reach into the box's height range?
	if o.type == DOOR:                   # a doorway only blocks boxes that stick out above it
		return y1 > o.y1 + 0.02 and y0 < o.y1
	if o.type == SLAB:                   # a floor or ceiling slab only blocks a box poking up into it;
		return o.y0 > y0 + 0.3 and o.y0 < y1 - 0.02      # the slab it stands on never blocks it
	return y1 - 0.02 > o.y0 and y0 + 0.02 < o.y1


func polygon_area(poly):
	var a = 0.0
	for i in poly.size():
		a += poly[i].cross(poly[(i + 1) % poly.size()])
	return abs(a) / 2


func overlaps(box_poly, o):
	var parts = Geometry2D.intersect_polygons(box_poly, o.poly)
	for hole in o.holes:                 # inside a hole of the piece there is nothing to hit
		var left = []
		for part in parts:
			left.append_array(Geometry2D.clip_polygons(part, hole))
		parts = left
	for part in parts:
		if polygon_area(part) > 0.0005:
			return true
	return false


# the box's outline seen from above: its four corners, turned by `rot` around its centre
func footprint(size, pos, rot):
	var half = Vector2(size.x, size.z) / 2 - Vector2(0.01, 0.01)   # may touch a wall
	var c = Vector2(pos.x, pos.z)
	var poly = PackedVector2Array()
	for corner in [Vector2(-half.x, -half.y), Vector2(half.x, -half.y), half, Vector2(-half.x, half.y)]:
		poly.append(c + corner.rotated(-rot))   # Godot turns +Y anticlockwise seen from above; plan y is world z
	return poly


func fits(size, pos, rot):
	var y0 = pos.y - size.y / 2
	var y1 = pos.y + size.y / 2
	if y0 < levels[0] - 0.01:            # never below the ground floor
		return false
	var box_poly = footprint(size, pos, rot)
	var rect = Rect2(box_poly[0], Vector2.ZERO)
	for p in box_poly:
		rect = rect.expand(p)
	for o in obstacles:
		if o.rect.intersects(rect) and blocks_height(o, y0, y1) and overlaps(box_poly, o):
			return false
	return true


# ============================== boxes ==============================

func add_box(size, pos, rot):
	var node = MeshInstance3D.new()
	node.mesh = BoxMesh.new()
	node.mesh.size = size
	var mat = StandardMaterial3D.new()
	node.material_override = mat
	node.position = pos
	node.rotation.y = rot
	boxes.add_child(node)
	objects[next_id] = {"size": size, "pos": pos, "rot": rot, "node": node, "mat": mat}
	select(next_id)
	next_id += 1


func remove_box(id):
	objects[id].node.queue_free()
	objects.erase(id)
	select(0)


func move_box(id, pos):
	objects[id].pos = pos
	objects[id].node.position = pos
	update_info()


func select(id):
	if objects.has(selected):
		objects[selected].mat.albedo_color = BOX_COLOR
	selected = id
	if objects.has(id):
		objects[id].mat.albedo_color = BOX_SELECTED
	update_info()


func update_info(message = ""):
	if message != "":
		info.text = message
	elif placing:
		info.text = "Click where the new box should go on the top floor    Hold R: turn it    Esc: cancel"
	elif not objects.has(selected):
		info.text = "Click a box to select it"
	else:
		var o = objects[selected]
		var bottom = o.pos.y - o.size.y / 2
		var level = level_of(bottom)
		info.text = "Box %d: %.2f x %.2f x %.2f m, floor %d of %d, %.2f m above it, turned %d°    W/S: floor    Shift+W/S: 1 cm    R: turn    Delete: remove" % [
			selected, o.size.x, o.size.y, o.size.z, level + 1, levels.size(), max(bottom - levels[level], 0.0),
			posmod(roundi(rad_to_deg(o.rot)), 360)]


# W / S: the selected box goes to the floor above or below, standing on it
func change_floor(dir):
	var o = objects[selected]
	var level = level_of(o.pos.y - o.size.y / 2) + dir
	if level < 0 or level >= levels.size():
		return
	var pos = Vector3(o.pos.x, box_y(o.size, level), o.pos.z)
	if fits(o.size, pos, o.rot):
		move_box(selected, pos)
	else:
		update_info("Box %d does not fit on floor %d at this spot: drag it somewhere else first" % [selected, level + 1])


# Shift+W / Shift+S: a 1 cm step; never below the floor it stands on or into anything
func nudge(dir):
	var o = objects[selected]
	var bottom = o.pos.y - o.size.y / 2
	var new_bottom = max(bottom + dir * FINE_STEP, levels[level_of(bottom)])
	if is_equal_approx(new_bottom, bottom):
		update_info("Box %d already stands on the floor" % selected)
		return
	var pos = Vector3(o.pos.x, new_bottom + o.size.y / 2, o.pos.z)
	if fits(o.size, pos, o.rot):
		move_box(selected, pos)
	else:
		update_info("Box %d cannot go %s here: something is in the way" % [selected, "higher" if dir > 0 else "lower"])


# R / Shift+R held: turn the box being placed, or the selected box if it still fits
func turn(delta):
	var step = deg_to_rad(TURN_SPEED) * delta * (-1.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	if placing:
		ghost_rot += step
		ghost.rotation.y = ghost_rot
		move_ghost(last_mouse)
	elif objects.has(selected):
		var o = objects[selected]
		if fits(o.size, o.pos, o.rot + step):
			o.rot += step
			o.node.rotation.y = o.rot
			update_info()
		else:
			update_info("Box %d cannot turn further here: it would hit something" % selected)


# ============================== mouse ==============================

func box_under_mouse(mouse):             # nearest box under the mouse, 0 if none
	var from = cam.project_ray_origin(mouse)
	var dir = cam.project_ray_normal(mouse)
	var best = 0
	var best_dist = INF
	for id in objects:
		var o = objects[id]
		# turn the ray into the box's own frame, where the box is an unturned AABB
		var local_from = (from - o.pos).rotated(Vector3.UP, -o.rot)
		var hit = AABB(-o.size / 2, o.size).intersects_ray(local_from, dir.rotated(Vector3.UP, -o.rot))
		if hit != null and local_from.distance_to(hit) < best_dist:
			best = id
			best_dist = local_from.distance_to(hit)
	return best


func mouse_on_plane(mouse, y):           # where the mouse ray crosses the horizontal plane at height y
	return Plane(Vector3.UP, y).intersects_ray(cam.project_ray_origin(mouse), cam.project_ray_normal(mouse))


# the selected box follows the mouse but never into a place where it does not fit:
# it waits at the last allowed place (sliding along the wall if it can) and jumps
# across once the mouse reaches a place that is free again
func drag_to(mouse):
	var o = objects[selected]
	var here = o.pos
	var p = mouse_on_plane(mouse, here.y)
	if p == null:
		return
	var want = Vector3(p.x + grab_offset.x, here.y, p.z + grab_offset.z)
	for pos in [want, Vector3(want.x, here.y, here.z), Vector3(here.x, here.y, want.z)]:
		if pos != here and fits(o.size, pos, o.rot):
			move_box(selected, pos)
			return


# ---- adding a box: press Add box, then click where it should go ----

func add_box_pressed():
	get_viewport().gui_release_focus()
	ghost.mesh.size = Vector3(size_boxes[0].value, size_boxes[1].value, size_boxes[2].value)
	ghost.rotation.y = ghost_rot         # the last turn is kept, handy for several boxes in a row
	placing = true
	update_info()


func stop_placing():
	placing = false
	ghost.visible = false
	update_info()


func placing_position(mouse):            # on the top floor, under the mouse (null if the mouse misses it)
	var p = mouse_on_plane(mouse, levels[-1])
	return null if p == null else Vector3(p.x, levels[-1] + ghost.mesh.size.y / 2, p.z)


func move_ghost(mouse):
	var pos = placing_position(mouse)
	ghost.visible = pos != null
	if pos != null:
		ghost.position = pos
		ghost_mat.albedo_color = GHOST_OK if fits(ghost.mesh.size, pos, ghost_rot) else GHOST_BAD


func place_box(mouse):
	var pos = placing_position(mouse)
	if pos == null or not fits(ghost.mesh.size, pos, ghost_rot):
		return                           # stays in placing mode: try another spot
	stop_placing()
	add_box(ghost.mesh.size, pos, ghost_rot)


# ============================== camera ==============================
# The camera hangs `cam.position.z` metres behind `pivot` and looks at it, so the pivot is
# the point in the middle of the screen: orbiting turns around it, zooming changes the
# distance to it. The pivot stays at the top floor's height, where boxes are placed.

# start looking down at the middle of the building
func place_camera():
	var area = obstacles[0].rect
	for o in obstacles:
		area = area.merge(o.rect)
	pivot.position = Vector3(area.get_center().x, levels[-1], area.get_center().y)
	pivot.rotation_degrees.x = -50
	cam.position.z = clamp(area.size.length(), 10.0, ZOOM_MAX)


func orbit(relative):
	pivot.rotation_degrees.y -= relative.x * ORBIT_SPEED
	pivot.rotation_degrees.x = clamp(pivot.rotation_degrees.x - relative.y * ORBIT_SPEED, PITCH_MIN, PITCH_MAX)


# zoom toward the point under the mouse: that point stays under the mouse while zooming
func zoom_at(mouse, factor):
	var new_dist = clamp(cam.position.z * factor, ZOOM_MIN, ZOOM_MAX)
	var p = mouse_on_plane(mouse, pivot.position.y)
	if p != null:
		pivot.position += (p - pivot.position) * (1.0 - new_dist / cam.position.z)
	cam.position.z = new_dist


# right-drag: the floor point that was under the mouse stays under the mouse
func pan(mouse, relative):
	var before = mouse_on_plane(mouse - relative, pivot.position.y)
	var after = mouse_on_plane(mouse, pivot.position.y)
	if before != null and after != null:
		pivot.position += before - after


# arrows and Q / E: move relative to the way the camera faces, faster when zoomed out
func move_camera(delta):
	var dir = Vector3(
		int(Input.is_action_pressed("ui_right")) - int(Input.is_action_pressed("ui_left")),
		int(Input.is_action_pressed("y_down")) - int(Input.is_action_pressed("y_up")),
		int(Input.is_action_pressed("ui_down")) - int(Input.is_action_pressed("ui_up")))
	if dir != Vector3.ZERO:
		pivot.position += dir.normalized().rotated(Vector3.UP, pivot.rotation.y) * cam.position.z / 4 * delta


# ============================== interface ==============================

func make_ui():
	var ui = CanvasLayer.new()
	add_child(ui)
	var rows = VBoxContainer.new()
	rows.position = Vector2(10, 10)
	ui.add_child(rows)
	rows.add_child(scale_label)

	var add_row = HBoxContainer.new()
	rows.add_child(add_row)
	for axis in ["Width (X)", "Height (Y)", "Depth (Z)"]:
		var label = Label.new()
		label.text = axis
		add_row.add_child(label)
		var box = SpinBox.new()
		box.min_value = 0.05
		box.max_value = 20
		box.step = 0.01
		box.value = 1
		box.suffix = "m"
		box.custom_minimum_size.x = 100
		add_row.add_child(box)
		size_boxes.append(box)
	var add_button = Button.new()
	add_button.text = "Add box"
	add_button.focus_mode = Control.FOCUS_NONE
	add_button.pressed.connect(add_box_pressed)
	add_row.add_child(add_button)

	rows.add_child(info)


# ============================== input and the frame loop ==============================

func _unhandled_input(event):
	if event is InputEventMouse:
		last_mouse = event.position
	if placing and handle_placing(event):
		return
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				get_viewport().gui_release_focus()
				var id = box_under_mouse(event.position) if event.pressed else 0
				if id != 0:
					select(id)
					var p = mouse_on_plane(event.position, objects[id].pos.y)
					grab_offset = objects[id].pos - p if p != null else Vector3.ZERO
					dragging = true
				elif event.pressed:
					select(0)
					orbiting = true
				else:
					orbiting = false
					dragging = false
			MOUSE_BUTTON_RIGHT:
				panning = event.pressed
			MOUSE_BUTTON_WHEEL_UP when event.pressed:
				zoom_at(event.position, ZOOM_FACTOR)
			MOUSE_BUTTON_WHEEL_DOWN when event.pressed:
				zoom_at(event.position, 1.0 / ZOOM_FACTOR)
	elif event is InputEventMouseMotion:
		if dragging:
			drag_to(event.position)
		elif orbiting:
			orbit(event.relative)
		elif panning:
			pan(event.position, event.relative)
	elif event is InputEventKey and event.pressed:
		if event.physical_keycode in [KEY_W, KEY_S] and objects.has(selected):
			var dir = 1 if event.physical_keycode == KEY_W else -1
			if event.shift_pressed:
				nudge(dir)                   # holding the keys repeats the small step
			elif not event.echo:
				change_floor(dir)            # one floor per press, even if the key is held
		elif event.keycode == KEY_DELETE and objects.has(selected):
			remove_box(selected)
		elif event.keycode == KEY_C:
			ceilings.visible = not ceilings.visible
		elif event.keycode == KEY_F:
			floors.visible = not floors.visible


# while placing, a left click places and Esc cancels; returns true if it used the event,
# so everything else (orbiting, panning, zoom) still works
func handle_placing(event):
	if event is InputEventMouseMotion:
		move_ghost(event.position)
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		get_viewport().gui_release_focus()
		place_box(event.position)
		return true
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		stop_placing()
		return true
	return false


func _process(delta):
	if get_viewport().gui_get_focus_owner() != null:     # typing in a field: no keys for the view
		return
	if Input.is_physical_key_pressed(KEY_R):
		turn(delta)
	move_camera(delta)
