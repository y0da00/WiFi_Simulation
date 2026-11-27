extends Node3D

const DATA_FOLDER = "res://server_data/"
const BUILDING_FILE = DATA_FOLDER + "draw.json"
const BOXES_FILE = DATA_FOLDER + "boxes.json"
const PORT = 9080
var server_address = "127.0.0.1"
const FINE_STEP = 0.01              
const TURN_SPEED = 45.0              
const ORBIT_SPEED = 0.3             
const ZOOM_FACTOR = 0.85             
const ZOOM_MIN = 1.5                 
const ZOOM_MAX = 300.0
const PITCH_MIN = -89.0             
const PITCH_MAX = -5.0               

const COLORS = {
	"walls": Color(0.9, 0.9, 0.9), "railings": Color(0.3, 0.3, 0.3),
	"stairs_elevators": Color(0.6, 0.6, 0.65), "floors": Color(0.55, 0.5, 0.45),
	"ceilings": Color(0.8, 0.8, 0.75), "doors": Color(0.45, 0.28, 0.12), "windows": Color(0.2, 0.5, 1.0)}
const BOX_COLOR = Color(0.2, 0.7, 0.3)
const BOX_SELECTED = Color(1.0, 0.8, 0.1)
const BOX_LOCKED = Color(0.8, 0.3, 0.3)
const GHOST_OK = Color(0.2, 0.8, 0.3, 0.35) 
const GHOST_BAD = Color(0.9, 0.2, 0.2, 0.35) 


enum {SOLID, SLAB, DOOR}
const BLOCKING = {"walls": SOLID, "railings": SOLID, "windows": SOLID, "stairs_elevators": SOLID, "floors": SLAB, "ceilings": SLAB, "doors": DOOR}

#building
var data = {}                     
var obstacles = []                   #{type, kind, poly, holes, rect, y0, y1}
var levels = [0.0]                  

#boxes
var objects = {}                     #{size: Vector3, pos: Vector3, rot: float (radians, around Y), node, mat}
var next_id = 1
var selected = 0                     
var locks = {}
var dragging = false                 
var grab_offset = Vector3.ZERO
var placing = false                
var ghost_rot = 0.0                  
var last_mouse = Vector2.ZERO       

#camera
var pivot = Node3D.new()             
var cam = Camera3D.new()
var orbiting = false                 
var panning = false                 

#scene
var building = Node3D.new()
var level_nodes = []
var ceilings = []
var floors = []
var shown_floors = 1
var ceilings_on = true
var floors_on = true
var boxes = Node3D.new()
var ghost = MeshInstance3D.new()     
var ghost_mat = StandardMaterial3D.new()

#server
var building_bytes = PackedByteArray()
var building_size = 0

#interface
var status = Label.new()
var scale_label = Label.new()
var floor_box = SpinBox.new()
var info = Label.new()
var size_boxes = []                 


func _ready():
	if DisplayServer.get_name() == "headless":
		start_server()
		return
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
	multiplayer.connected_to_server.connect(func(): status.text = "Connected as player %d, loading the building ..." % me())
	multiplayer.connection_failed.connect(func(): status.text = "Could not reach the server")
	multiplayer.server_disconnected.connect(disconnected)
	scale_label.text = "Press Join to load the building"
	update_info()


func start_server():
	set_process(false)
	Engine.max_fps = 60
	var text = FileAccess.get_file_as_string(BUILDING_FILE)
	if text == "":
		print("Cannot open %s" % BUILDING_FILE)
		get_tree().quit(1)
		return
	building_bytes = text.to_utf8_buffer()
	building_size = building_bytes.size()
	building_bytes = building_bytes.compress(FileAccess.COMPRESSION_ZSTD)
	load_boxes()
	var peer = ENetMultiplayerPeer.new()
	if peer.create_server(PORT) != OK:
		print("Could not listen on port %d" % PORT)
		get_tree().quit(1)
		return
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(player_joined)
	multiplayer.peer_disconnected.connect(player_left)
	print("Server listening on port %d" % PORT)


func player_joined(id):
	print("Player %d joined, %d connected" % [id, multiplayer.get_peers().size()])
	load_project.rpc_id(id, building_bytes, building_size)
	for box in objects:
		var o = objects[box]
		add_object.rpc_id(id, box, o.size, o.pos, o.rot, locks.get(box, 0))


func player_left(id):
	print("Player %d left, %d connected" % [id, multiplayer.get_peers().size()])
	for box in locks.keys():
		if locks[box] == id:
			set_lock.rpc(box, 0, objects[box].pos, objects[box].rot)
	save_boxes()


func load_boxes():
	if not FileAccess.file_exists(BOXES_FILE):
		return
	for b in JSON.parse_string(FileAccess.get_file_as_string(BOXES_FILE)):
		add_box(int(b.id), Vector3(b.size[0], b.size[1], b.size[2]), Vector3(b.pos[0], b.pos[1], b.pos[2]), b.rot)
		next_id = max(next_id, int(b.id) + 1)
	print("Loaded %d boxes" % objects.size())


func save_boxes():
	var list = []
	for id in objects:
		var o = objects[id]
		list.append({"id": id, "size": [o.size.x, o.size.y, o.size.z], "pos": [o.pos.x, o.pos.y, o.pos.z], "rot": o.rot})
	DirAccess.make_dir_recursive_absolute(DATA_FOLDER)
	FileAccess.open(BOXES_FILE, FileAccess.WRITE).store_string(JSON.stringify(list, "\t"))


func join():
	var old = multiplayer.multiplayer_peer
	if old is ENetMultiplayerPeer and old.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED:
		if old.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			status.text = "Already connected as player %d" % multiplayer.get_unique_id()
		return
	var peer = ENetMultiplayerPeer.new()
	if peer.create_client(server_address, PORT) != OK:
		status.text = "Bad address"
		return
	multiplayer.multiplayer_peer = peer
	status.text = "Connecting ..."


func disconnected():
	status.text = "Server disconnected"
	unload()


func unload():
	stop_placing()
	for id in objects.keys():
		remove_box(id)
	locks.clear()
	for child in building.get_children():
		child.queue_free()
	level_nodes.clear()
	ceilings.clear()
	floors.clear()
	obstacles.clear()
	levels = [0.0]
	data = {}
	scale_label.text = "Press Join to load the building"


@rpc("authority", "call_remote", "reliable")
func load_project(bytes, size):
	unload()
	var error = load_building(bytes.decompress(size, FileAccess.COMPRESSION_ZSTD).get_string_from_utf8())
	if error != "":
		scale_label.text = error
		return
	build_building()
	floor_box.max_value = levels.size()
	floor_box.set_value_no_signal(levels.size())
	show_floors(levels.size())
	scale_label.text = scale_text()
	place_camera()
	status.text = "Connected as player %d" % me()


func me():
	return multiplayer.get_unique_id()


func held_by_other(id):
	return locks.get(id, 0) not in [0, me()]


func send(id):
	request_move.rpc_id(1, id, objects[id].pos, objects[id].rot)


@rpc("any_peer", "call_local", "reliable")
func request_add(size, pos, rot):
	add_object.rpc(next_id, size, pos, rot, multiplayer.get_remote_sender_id())
	next_id += 1
	save_boxes()


@rpc("any_peer", "call_local", "reliable")
func request_lock(id):
	if objects.has(id):
		var holder = locks.get(id, 0)
		set_lock.rpc(id, multiplayer.get_remote_sender_id() if holder == 0 else holder, objects[id].pos, objects[id].rot)


@rpc("any_peer", "call_local", "reliable")
func release(id):
	if objects.has(id) and locks.get(id, 0) == multiplayer.get_remote_sender_id():
		set_lock.rpc(id, 0, objects[id].pos, objects[id].rot)
		save_boxes()


@rpc("any_peer", "call_local", "reliable")
func request_move(id, pos, rot):
	if locks.get(id, 0) == multiplayer.get_remote_sender_id():
		set_box.rpc(id, pos, rot)


@rpc("any_peer", "call_local", "reliable")
func request_remove(id):
	if locks.get(id, 0) == multiplayer.get_remote_sender_id():
		remove_object.rpc(id)
		save_boxes()


@rpc("authority", "call_local", "reliable")
func add_object(id, size, pos, rot, holder):
	add_box(id, size, pos, rot)
	if holder != 0:
		locks[id] = holder
	color_box(id)
	if holder == me():
		select(id)


@rpc("authority", "call_local", "reliable")
func set_lock(id, holder, pos, rot):
	if not objects.has(id):
		return
	if holder == 0:
		locks.erase(id)
	else:
		locks[id] = holder
	if holder != me():
		place(id, pos, rot)
	if held_by_other(id) and selected == id:
		selected = 0
		dragging = false
		update_info("Box %d is already taken by player %d" % [id, holder])
	color_box(id)


@rpc("authority", "call_local", "reliable")
func set_box(id, pos, rot):
	if objects.has(id) and locks.get(id, 0) != me():
		place(id, pos, rot)


@rpc("authority", "call_local", "reliable")
func remove_object(id):
	if objects.has(id):
		remove_box(id)


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




func load_building(text):                # will return an error if something went wrong
	var parsed = JSON.parse_string(text)
	if parsed == null:
		return "The server sent a broken building file"
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
	var combiner = CSGCombiner3D.new()          # piece with holes, cuts them out
	combiner.add_child(shape)
	for hole in piece[3]:
		var cut = prism(hole, piece[1] - 0.02, piece[2] + 0.04)
		cut.operation = CSGShape3D.OPERATION_SUBTRACTION
		combiner.add_child(cut)
	return combiner


func prism(points, elevation, height): #draws everything
	var c = CSGPolygon3D.new()
	c.polygon = plan(points)
	c.depth = height
	c.rotation_degrees.x = 90      
	c.position.y = elevation
	return c


func build_building():
	for i in levels.size():
		var level = Node3D.new()
		level_nodes.append(level)
		floors.append(Node3D.new())
		ceilings.append(Node3D.new())
		level.add_child(floors[i])
		level.add_child(ceilings[i])
		building.add_child(level)
	for kind in COLORS:
		var mat = StandardMaterial3D.new()
		mat.albedo_color = COLORS[kind]
		for apt in data.apartments:
			for piece in apt.get(kind, []):
				var node = make_piece(piece)
				node.material_override = mat
				var i = level_of(piece[1] + piece[2]) if kind == "floors" else level_of(piece[1] + piece[2] / 2)
				var parent = ceilings[i] if kind == "ceilings" else floors[i] if kind == "floors" else level_nodes[i]
				parent.add_child(node)


func show_floors(value):
	get_viewport().gui_release_focus()
	shown_floors = int(value)
	for i in level_nodes.size():
		level_nodes[i].visible = i < shown_floors
	for id in objects:
		show_box(id)
	if objects.has(selected) and not objects[selected].node.visible:
		select(0)
	if placing:
		move_ghost(last_mouse)
	update_info()


func show_box(id):
	var o = objects[id]
	o.node.visible = level_of(o.pos.y - o.size.y / 2) < shown_floors



func box_y(size, level):                 # y of the box centre when it stands on that floor
	return levels[level] + size.y / 2


func level_of(bottom):                   # the floor at or just below height bottom
	var level = 0
	for i in levels.size():
		if levels[i] <= bottom + 0.01:
			level = i
	return level


func blocks_height(o, y0, y1):           
	if o.type == DOOR:                   
		return y1 > o.y1 + 0.02 and y0 < o.y1
	if o.type == SLAB:                   # a floor or ceiling only blocks a box poking up into it
		return o.y0 > y0 + 0.3 and o.y0 < y1 - 0.02      
	return y1 - 0.02 > o.y0 and y0 + 0.02 < o.y1


func polygon_area(poly):
	var a = 0.0
	for i in poly.size():
		a += poly[i].cross(poly[(i + 1) % poly.size()])
	return abs(a) / 2


func overlaps(box_poly, o):
	var parts = Geometry2D.intersect_polygons(box_poly, o.poly)
	for hole in o.holes:                 # inside a hole of the piece 
		var left = []
		for part in parts:
			left.append_array(Geometry2D.clip_polygons(part, hole))
		parts = left
	for part in parts:
		if polygon_area(part) > 0.0005:
			return true
	return false



func footprint(size, pos, rot):
	var half = Vector2(size.x, size.z) / 2 - Vector2(0.01, 0.01)   # may touch a wall
	var c = Vector2(pos.x, pos.z)
	var poly = PackedVector2Array()
	for corner in [Vector2(-half.x, -half.y), Vector2(half.x, -half.y), half, Vector2(-half.x, half.y)]:
		poly.append(c + corner.rotated(-rot))  
	return poly


func fits(size, pos, rot):
	var y0 = pos.y - size.y / 2
	var y1 = pos.y + size.y / 2
	if y0 < levels[0] - 0.01:            
		return false
	var box_poly = footprint(size, pos, rot)
	var rect = Rect2(box_poly[0], Vector2.ZERO)
	for p in box_poly:
		rect = rect.expand(p)
	for o in obstacles:
		if o.rect.intersects(rect) and blocks_height(o, y0, y1) and overlaps(box_poly, o):
			return false
	return true



func add_box(id, size, pos, rot):
	var node = MeshInstance3D.new()
	node.mesh = BoxMesh.new()
	node.mesh.size = size
	var mat = StandardMaterial3D.new()
	node.material_override = mat
	node.position = pos
	node.rotation.y = rot
	boxes.add_child(node)
	objects[id] = {"size": size, "pos": pos, "rot": rot, "node": node, "mat": mat}
	show_box(id)


func remove_box(id):
	objects[id].node.queue_free()
	objects.erase(id)
	locks.erase(id)
	if selected == id:
		selected = 0
	update_info()


func move_box(id, pos):
	objects[id].pos = pos
	objects[id].node.position = pos
	show_box(id)
	send(id)
	update_info()


func place(id, pos, rot):
	objects[id].pos = pos
	objects[id].rot = rot
	objects[id].node.position = pos
	objects[id].node.rotation.y = rot
	show_box(id)
	update_info()


func select(id):
	if id == selected:
		return
	var old = selected
	selected = id
	if objects.has(old):
		release.rpc_id(1, old)
		color_box(old)
	if objects.has(id):
		request_lock.rpc_id(1, id)
		color_box(id)
	update_info()


func color_box(id):
	objects[id].mat.albedo_color = BOX_SELECTED if id == selected else BOX_LOCKED if held_by_other(id) else BOX_COLOR


func update_info(message = ""):
	if message != "":
		info.text = message
	elif placing:
		info.text = "Click where the new box should go on floor %d    Hold R: turn it    Esc: cancel" % shown_floors
	elif not objects.has(selected):
		info.text = "Click a box to select it"
	else:
		var o = objects[selected]
		var bottom = o.pos.y - o.size.y / 2
		var level = level_of(bottom)
		info.text = "Box %d: %.2f x %.2f x %.2f m, floor %d of %d, %.2f m above it, turned %d°    W/S: floor    Shift+W/S: 1 cm    R: turn    Delete: remove" % [
			selected, o.size.x, o.size.y, o.size.z, level + 1, levels.size(), max(bottom - levels[level], 0.0),
			posmod(roundi(rad_to_deg(o.rot)), 360)]


#moves box along all levels
func change_floor(dir):
	var o = objects[selected]
	var level = level_of(o.pos.y - o.size.y / 2) + dir
	if level < 0 or level >= shown_floors:
		return
	var pos = Vector3(o.pos.x, box_y(o.size, level), o.pos.z)
	if fits(o.size, pos, o.rot):
		move_box(selected, pos)
	else:
		update_info("Box %d does not fit on floor %d at this spot: drag it somewhere else first" % [selected, level + 1])


#small 1cm step limited to the current level
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


# box rotation (TODO: rot in both directions)
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
			send(selected)
			update_info()
		else:
			update_info("Box %d cannot turn further here: it would hit something" % selected)



#box selection with mouse
func box_under_mouse(mouse):            
	var from = cam.project_ray_origin(mouse)
	var dir = cam.project_ray_normal(mouse)
	var best = 0
	var best_dist = INF
	for id in objects:
		var o = objects[id]
		if not o.node.visible:
			continue
		var local_from = (from - o.pos).rotated(Vector3.UP, -o.rot)
		var hit = AABB(-o.size / 2, o.size).intersects_ray(local_from, dir.rotated(Vector3.UP, -o.rot))
		if hit != null and local_from.distance_to(hit) < best_dist:
			best = id
			best_dist = local_from.distance_to(hit)
	return best

#where the mouse ray crosses the horizontal plane at height y
func mouse_on_plane(mouse, y):           
	return Plane(Vector3.UP, y).intersects_ray(cam.project_ray_origin(mouse), cam.project_ray_normal(mouse))


#drag the object, when hitting and obstacle it moves only when the mouse is free again
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


func add_box_pressed():
	get_viewport().gui_release_focus()
	if data.is_empty():
		update_info("Join a server first")
		return
	for box in size_boxes:
		box.apply()
	ghost.mesh.size = Vector3(size_boxes[0].value, size_boxes[1].value, size_boxes[2].value)
	ghost.rotation.y = ghost_rot        
	placing = true
	update_info()


func stop_placing():
	placing = false
	ghost.visible = false
	update_info()

#on the highest shown floor, under the mouse
func placing_position(mouse):     
	var top = levels[shown_floors - 1]
	var p = mouse_on_plane(mouse, top)
	return null if p == null else Vector3(p.x, top + ghost.mesh.size.y / 2, p.z)


func move_ghost(mouse):
	var pos = placing_position(mouse)
	ghost.visible = pos != null
	if pos != null:
		ghost.position = pos
		ghost_mat.albedo_color = GHOST_OK if fits(ghost.mesh.size, pos, ghost_rot) else GHOST_BAD


func place_box(mouse):
	var pos = placing_position(mouse)
	if pos == null or not fits(ghost.mesh.size, pos, ghost_rot):
		return                           
	stop_placing()
	request_add.rpc_id(1, ghost.mesh.size, pos, ghost_rot)


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


func zoom_at(mouse, factor):
	var new_dist = clamp(cam.position.z * factor, ZOOM_MIN, ZOOM_MAX)
	var p = mouse_on_plane(mouse, pivot.position.y)
	if p != null:
		pivot.position += (p - pivot.position) * (1.0 - new_dist / cam.position.z)
	cam.position.z = new_dist


func pan(mouse, relative):
	var before = mouse_on_plane(mouse - relative, pivot.position.y)
	var after = mouse_on_plane(mouse, pivot.position.y)
	if before != null and after != null:
		pivot.position += before - after


func move_camera(delta):
	var dir = Vector3(
		int(Input.is_action_pressed("ui_right")) - int(Input.is_action_pressed("ui_left")),
		int(Input.is_action_pressed("y_down")) - int(Input.is_action_pressed("y_up")),
		int(Input.is_action_pressed("ui_down")) - int(Input.is_action_pressed("ui_up")))
	if dir != Vector3.ZERO:
		pivot.position += dir.normalized().rotated(Vector3.UP, pivot.rotation.y) * cam.position.z / 4 * delta


func make_ui():
	var ui = CanvasLayer.new()
	add_child(ui)
	var rows = VBoxContainer.new()
	rows.position = Vector2(10, 10)
	ui.add_child(rows)

	var net_row = HBoxContainer.new()
	rows.add_child(net_row)
	var join_button = Button.new()
	join_button.text = "Join"
	join_button.focus_mode = Control.FOCUS_NONE
	join_button.pressed.connect(join)
	net_row.add_child(join_button)
	status.text = "Not connected"
	net_row.add_child(status)

	rows.add_child(scale_label)

	var floor_row = HBoxContainer.new()
	rows.add_child(floor_row)
	var floor_label = Label.new()
	floor_label.text = "Floors shown"
	floor_row.add_child(floor_label)
	floor_box.min_value = 1
	floor_box.step = 1
	floor_box.custom_minimum_size.x = 80
	floor_box.value_changed.connect(show_floors)
	floor_row.add_child(floor_box)

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

#input
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
				if id != 0 and held_by_other(id):
					update_info("Box %d is being moved by player %d" % [id, locks[id]])
				elif id != 0:
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
				change_floor(dir)            # one floor per press
		elif event.keycode == KEY_DELETE and objects.has(selected):
			request_remove.rpc_id(1, selected)
		elif event.keycode == KEY_C:
			ceilings_on = not ceilings_on
			for c in ceilings:
				c.visible = ceilings_on
		elif event.keycode == KEY_F:
			floors_on = not floors_on
			for f in floors:
				f.visible = floors_on


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
	if get_viewport().gui_get_focus_owner() != null:     # typing in a field
		return
	if Input.is_physical_key_pressed(KEY_R):
		turn(delta)
	move_camera(delta)
