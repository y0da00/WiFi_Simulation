extends RefCounted
## MLWorld: prepares a building made by simulation.gd for ML agents, and picks
## start points, targets and exits. Used by training (train_env.gd), the in-game demo
## (simulation.gd, key M) and the test (tests/test_ml_agent.gd).
##
## Why it is needed:
##   * The scripted agent (path_agent.gd) just slides along a line, so the building
##     never needed real collision. ML agents are physical bodies (CharacterBody3D):
##     they stand on floors, are stopped by walls and "see" with physics rays. So
##     enable_collision() switches on collision for every piece that pathfinding.gd
##     uses for the navmesh (walls, railings, stairs, landings, elevators, floors).
##     Doors and windows get no collision, so doorways stay open.
##   * Training needs random start points that are really on a floor where people walk
##     (not on top of a wall or on a loose patch of a stair slab). sample_points() finds
##     them.

const WORLD_LAYER := 1   ## physics layer of the building (see sensors.gd)

var nav            ## the pathfinding.gd node of the building
var levels: Array = []     ## walking heights of the floors (m), lowest first
var points := {}           ## level -> Array of Vector3 good start/target points on that floor


## `navigation` is the pathfinding.gd node of the loaded building.
func _init(navigation) -> void:
	nav = navigation


## Turns on collision for all navmesh source pieces. Await it: CSG makes its collision
## shapes on the next frame.
func enable_collision() -> void:
	for s in nav.sources:
		if not is_instance_valid(s):
			continue
		if s is CSGShape3D:
			s.use_collision = true
			s.collision_layer = WORLD_LAYER
			s.collision_mask = 0   # the building itself never moves, it doesn't need to detect anything
		elif s is MeshInstance3D and s.mesh is BoxMesh and not s.has_node("Collider"):
			# boxes added with nav.add_box(): a static body with a box shape of the same size
			var body := StaticBody3D.new()
			body.name = "Collider"
			body.collision_layer = WORLD_LAYER
			var cs := CollisionShape3D.new()
			var shape := BoxShape3D.new()
			shape.size = s.mesh.size
			cs.shape = shape
			body.add_child(cs)
			s.add_child(body)
	# two frames: CSG builds its collision shapes on the next frame, then physics sees them
	await nav.get_tree().physics_frame
	await nav.get_tree().physics_frame


## Finds the floors (from the stair links: every link joins two floor heights; with no
## stairs, the height of the biggest walkable patch) and `per_level` random walkable
## points on each one. A point is kept only if a path from it reaches the middle of that
## floor's biggest walkable patch, so stray patches (tops of walls...) are skipped.
func sample_points(per_level := 200, rng: RandomNumberGenerator = null) -> void:
	if rng == null:
		rng = RandomNumberGenerator.new()
	var map: RID = nav.get_world_3d().navigation_map
	levels.clear()
	for l in nav.stair_links:
		for y in [l.start_position.y, l.end_position.y]:
			_add_level(y)
	if levels.is_empty():
		var ends: Array = nav.pick_far_ends()
		if not ends.is_empty():
			_add_level(ends[0].y)
	levels.sort()
	points.clear()
	for lv in levels:
		var ends: Array = nav.pick_far_ends(lv)
		points[lv] = []
		if ends.is_empty():
			continue
		var ref: Vector3 = ends[0]   # a point surely on the main walkable area of this floor
		var tries := 0
		while points[lv].size() < per_level and tries < per_level * 30:
			tries += 1
			var p := NavigationServer3D.map_get_random_point(map, 1, true)   # random point anywhere on the navmesh (all floors)
			if abs(p.y - lv) > 0.35:
				continue   # on another floor or on a stair slope
			var path := NavigationServer3D.map_get_path(map, p, ref, true)
			# keep it only if a path really reaches ref (the path ends elsewhere when it can't)
			if path.size() > 0 and path[path.size() - 1].distance_to(ref) < 0.3:
				points[lv].append(p)


## Remembers a walking height, unless one within 0.5 m is already known (same floor).
func _add_level(y: float) -> void:
	for lv in levels:
		if abs(lv - y) < 0.5:
			return
	levels.append(y)


## A random good point on floor `level` (or any floor if level is NAN).
func random_point(rng: RandomNumberGenerator, level := NAN) -> Vector3:
	var lv = level
	if is_nan(level):
		var non_empty := levels.filter(func(l): return not points[l].is_empty())
		if non_empty.is_empty():
			push_error("ml_world: no walkable start points in this building")
			return Vector3.ZERO
		lv = non_empty[rng.randi() % non_empty.size()]
	var arr: Array = points.get(lv, [])
	if arr.is_empty():
		push_error("ml_world: no walkable points on the floor at %.2f m" % lv)
		return Vector3.ZERO
	return arr[rng.randi() % arr.size()]


## Default exit for evacuations: the far end of the ground floor's biggest patch (the
## same point the scripted demo, key G, walks to). Replace with real exit doors later.
func default_exit() -> Vector3:
	var ends: Array = nav.pick_far_ends(levels[0] if not levels.is_empty() else NAN)
	return ends[1] if not ends.is_empty() else Vector3.ZERO
