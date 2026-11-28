extends Node3D

const Main = preload("res://main.gd")
const SOLID_KINDS = ["walls", "railings", "windows", "elevators", "floors"]
const DRAWN_KINDS = ["walls", "railings", "windows", "elevators", "floors", "ceilings", "doors", "stairs", "landings"]
const ACTIVE_LAYER = 1
const IDLE_LAYER = 2
const STAIR_MARGIN = 0.25
const STAIR_HEIGHT = 2.4
const AGENT_HALF_HEIGHT = 0.9
const CLEARANCE = 0.8
const STAIR_THICKNESS := 0.15
const COLORS = {
	"walls": Color(0.9, 0.9, 0.9), "railings": Color(0.3, 0.3, 0.3),
	"stairs": Color(0.6, 0.6, 0.65), "landings": Color(0.6, 0.6, 0.65),
	"stairs_elevators": Color(0.6, 0.6, 0.65),
	"elevators": Color(0.45, 0.45, 0.55), "floors": Color(0.55, 0.5, 0.45),
	"ceilings": Color(0.8, 0.8, 0.75), "doors": Color(0.45, 0.28, 0.12), "windows": Color(0.2, 0.5, 1.0)}

var builder
var levels = [0.0]
var level_nodes = []
var ceiling_nodes = []
var colliders = []
var floor_areas = []
var active_level = 0
var fixed_level = -1
var ready_to_run = false
var _query: PhysicsShapeQueryParameters3D

@onready var agent: CharacterBody3D = $Agent
@onready var controller = $Agent/AIController3D
@onready var camera_pivot = $CameraPivot
@onready var label: Label = $HUD/Label

func _ready() -> void:
	var args = _args()
	var path = args.get("building", Main.BUILDING_FILE)
	fixed_level = args.get("floor", "0").to_int() - 1
	builder = Main.new()
	var text = FileAccess.get_file_as_string(path)
	if text == "":
		var error = "Cannot open %s" % path
		push_error(error)
		label.text = error
		return
	var error = builder.load_building(text)
	if error != "":
		push_error(error)
		label.text = error
		return
	levels = builder.levels
	_build()
	var shape = BoxShape3D.new()
	shape.size = Vector3(CLEARANCE, 1.1, CLEARANCE)
	_query = PhysicsShapeQueryParameters3D.new()
	_query.shape = shape
	_query.collision_mask = ACTIVE_LAYER
	_query.exclude = [agent.get_rid()]
	camera_pivot.target = agent
	set_active_level(pick_level())
	await get_tree().physics_frame
	await get_tree().physics_frame
	ready_to_run = true
	controller.start(self)

func _args() -> Dictionary:
	var result = {}
	for a in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if a.begins_with("--") and a.find("=") > -1:
			var kv = a.trim_prefix("--").split("=", true, 1)
			result[kv[0]] = kv[1]
	return result

func _build() -> void:
	for i in levels.size():
		var level = Node3D.new()
		var ceiling = Node3D.new()
		level.add_child(ceiling)
		add_child(level)
		level_nodes.append(level)
		ceiling_nodes.append(ceiling)
		floor_areas.append([])
	for kind in DRAWN_KINDS:
		var mat = StandardMaterial3D.new()
		mat.albedo_color = COLORS[kind]
		if kind == "doors":
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.albedo_color.a = 0.35
		for apt in builder.data.apartments:
			for piece in apt.get(kind, []):
				var node = _make_stair(piece) if kind == "stairs" else builder.make_piece(piece)
				node.material_override = mat
				var mid
				if kind == "stairs":
					mid = (piece["z0"] + piece["z1"]) / 2
				elif kind == "floors":
					mid = piece[1] + piece[2]
				else:
					mid = piece[1] + piece[2] / 2
				var i = builder.level_of(mid)
				if kind == "ceilings":
					ceiling_nodes[i].add_child(node)
				else:
					level_nodes[i].add_child(node)
				if kind in SOLID_KINDS:
					node.use_collision = true
					node.collision_mask = 0
					colliders.append({"node": node, "level": i})
				if kind == "floors":
					_add_floor_area(i, piece)
	for apt in builder.data.apartments:
		for f in apt.get("stairs", []):
			var quad = [f["low"][0], f["low"][1], f["high"][1], f["high"][0]]
			var i = builder.level_of(f["base"])
			_add_stair_blocker(quad, i)
			_add_stair_blocker(quad, i + 1)
		for piece in apt.get("landings", []):
			var i = builder.level_of(piece[1])
			_add_stair_blocker(piece[0], i)
			_add_stair_blocker(piece[0], i + 1)
		for piece in apt.get("stairs_elevators", []):
			_add_stair_blocker(piece[0], builder.level_of(piece[1] + 0.01))
	for prop in builder.get_script().get_script_property_list():
		var v = builder.get(prop.name)
		if v is Node and is_instance_valid(v) and v.get_parent() == null:
			v.free()
	builder.free()
	builder = null


func _make_stair(f):
	var l0 := Vector2(f["low"][0][0], f["low"][0][1])
	var l1 := Vector2(f["low"][1][0], f["low"][1][1])
	var h0 := Vector2(f["high"][0][0], f["high"][0][1])
	var h1 := Vector2(f["high"][1][0], f["high"][1][1])
	var base: float = f["base"]
	var z0: float = f["z0"]
	var z1: float = f["z1"]
	var run := (h0 + h1) / 2 - (l0 + l1) / 2
	var length := run.length()
	var u := run / length
	var across := Vector2(u.y, -u.x)
	var width := l0.distance_to(l1)
	var start := l0 if (l1 - l0).dot(across) > 0 else l1
	var c := CSGPolygon3D.new()
	var th := STAIR_THICKNESS
	c.polygon = PackedVector2Array([Vector2(0, z0 - base - th), Vector2(length, z1 - base - th),
		Vector2(length, z1 - base), Vector2(0, z0 - base)])
	c.depth = width
	c.transform = Transform3D(Basis(Vector3(u.x, 0, u.y), Vector3.UP, Vector3(-u.y, 0, u.x)),
		Vector3(start.x, base, start.y))
	if not f.get("clip", false):
		return c
	var combiner = CSGCombiner3D.new()
	combiner.add_child(c)
	var cut = builder.prism(f["outline"], z0 - th - 0.02, z1 - z0 + th + 0.04)
	cut.operation = CSGShape3D.OPERATION_INTERSECTION
	combiner.add_child(cut)
	return combiner

func _add_floor_area(i: int, piece) -> void:
	var poly = _plan(piece[0])
	if poly.size() < 3:
		return
	var holes = []
	for h in piece[3]:
		holes.append(_plan(h))
	var rect = Rect2(poly[0], Vector2.ZERO)
	for p in poly:
		rect = rect.expand(p)
	floor_areas[i].append({"poly": poly, "holes": holes, "rect": rect, "area": rect.get_area()})

func _plan(points) -> PackedVector2Array:
	var pts = PackedVector2Array()
	for p in points:
		pts.append(Vector2(p[0], p[1]))
	return pts

func _add_stair_blocker(points, i: int) -> void:
	if i < 0 or i >= levels.size():
		return
	var poly = _plan(points)
	if poly.size() < 3:
		return
	var grown = Geometry2D.offset_polygon(poly, STAIR_MARGIN)
	if not grown.is_empty():
		poly = grown[0]
	var y = levels[i]
	var pts = PackedVector3Array()
	for p in poly:
		pts.append(Vector3(p.x, y + 0.05, p.y))
		pts.append(Vector3(p.x, y + STAIR_HEIGHT, p.y))
	var shape = ConvexPolygonShape3D.new()
	shape.points = pts
	var body = StaticBody3D.new()
	body.collision_mask = 0
	var cs = CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	body.set_meta("stair_blocker", true)
	add_child(body)
	colliders.append({"node": body, "level": i})

func pick_level() -> int:
	if fixed_level >= 0 and fixed_level < levels.size():
		return fixed_level
	var usable = []
	for i in levels.size():
		if not floor_areas[i].is_empty():
			usable.append(i)
	if usable.is_empty():
		return 0
	return usable[randi() % usable.size()]

func set_active_level(i: int) -> void:
	active_level = i
	for c in colliders:
		c.node.collision_layer = ACTIVE_LAYER if c.level == i else IDLE_LAYER
	for k in level_nodes.size():
		level_nodes[k].visible = k <= i
		ceiling_nodes[k].visible = k < i
	label.text = "Floor %d of %d" % [i + 1, levels.size()]

func floor_y() -> float:
	return levels[active_level]

func random_free_point() -> Vector3:
	var areas = floor_areas[active_level]
	var space = get_world_3d().direct_space_state
	var y = floor_y()
	var total = 0.0
	for a in areas:
		total += a.area
	for attempt in 400:
		var r = randf() * total
		var area = areas[0]
		for a in areas:
			r -= a.area
			if r <= 0:
				area = a
				break
		var p = Vector2(randf_range(area.rect.position.x, area.rect.end.x), randf_range(area.rect.position.y, area.rect.end.y))
		if not Geometry2D.is_point_in_polygon(p, area.poly):
			continue
		var in_hole = false
		for h in area.holes:
			if Geometry2D.is_point_in_polygon(p, h):
				in_hole = true
		if in_hole:
			continue
		_query.transform = Transform3D(Basis(), Vector3(p.x, y + 0.95, p.y))
		if not space.intersect_shape(_query, 1).is_empty():
			continue
		var ray = PhysicsRayQueryParameters3D.create(Vector3(p.x, y + 0.5, p.y), Vector3(p.x, y - 0.3, p.y), ACTIVE_LAYER, [agent.get_rid()])
		var hit = space.intersect_ray(ray)
		if hit.is_empty() or hit.collider.has_meta("stair_blocker"):
			continue
		return Vector3(p.x, y + AGENT_HALF_HEIGHT, p.y)
	return Vector3.INF
