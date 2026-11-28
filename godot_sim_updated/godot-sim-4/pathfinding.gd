extends NavigationRegion3D
## Navigation for the building drawn by main.gd.
##
## Walkable: the "floors" slabs. Obstacles: walls, railings, stair flights, landings,
## elevators and anything added with add_box(). Doors, windows and ceilings are ignored, so the
## agent walks through doorways. Elevators stay plain obstacles (they don't carry anyone).
##
## Use from main.gd:
##   register(body, category)   for every CSG body it creates
##   add_flight(dict) / add_landing(piece)   for every stair flight / landing from draw.json
##   await build()              once everything is added; bakes, joins the floors by the
##                              stairs and starts the agent
##   add_box(center, size, yaw) user-placed object (parallelepiped), then rebake()
##
## How it works: every registered CSG body (and every add_box() box) is turned into
## triangles and handed to the NavigationServer3D, which voxelises them (5 cm cells)
## and keeps the top surfaces where an agent of agent_radius x agent_height fits. The
## tops of the floor slabs become walkable, and walls etc. take away walkable area
## (plus agent_radius around them). All floors go into this one navmesh, but the navmesh
## itself does not connect them. The stair flights are thin tilted slabs; in building 320
## they are 25-27 degrees, under agent_max_slope (30), so small pieces of their tops do
## become walkable, but only as loose patches that never join the floor at either end
## (the voxels at the ends and the agent_radius margin along the walls/railings cut them
## off; steeper flights, 33-42 degrees in other buildings, are not walkable at all). The
## landings are too small for the agent. So each floor is a separate island of the
## navmesh (test_stairs_mesh.gd checks this) and walkable surfaces float about 5-10 cm
## above the slab tops because of the 5 cm voxels.
##
## The floors are joined with stair LINKS instead (build_stair_links()): for every
## staircase that climbs one storey (one or more flights joined by landings), a
## NavigationLink3D goes from a point just in front of the bottom of the first flight
## to a point just past the top of the last flight. A link tells the path finder "you
## can get from here to there", so paths can now go from any floor to any other. The
## link also stores the real walking line over the stairs ("stair_points"), which the
## agent (path_agent.gd) follows so it really climbs the slope instead of jumping.
## Tops of thick obstacles can also become small stray walkable patches, which is why
## pick_far_ends() only uses the biggest connected patch.

const PathAgent = preload("res://path_agent.gd")   # script of the walking capsule

## Categories from main.gd that go into the navmesh bake (doors, windows and
## ceilings are left out).
const SOURCE_CATEGORIES := ["walls", "railings", "stairs", "landings", "elevators", "floors"]

@export var agent_radius := 0.25   # m; the walkable area keeps this far away from obstacles
@export var agent_height := 1.7   # m; needs this much free height above the floor

var agent: Node3D   # the path_agent.gd walker; added as a sibling of this node
var sources: Array[Node3D] = []      # CSG bodies and boxes that feed the bake
var flights: Array = []    # draw.json "stairs" dicts (see make_stair() in main.gd)
var landings: Array = []   # draw.json "landings" pieces: [outline, elevation, thickness, holes]
var stair_links: Array[NavigationLink3D] = []   # one per staircase, made by build_stair_links()
var box_material := StandardMaterial3D.new()   # blue material for add_box() obstacles

## Emitted by build() once the navmesh is baked and the agent has its first route.
signal ready_to_walk


## Runs when main.gd creates this node with .new().
func _init():
	name = "Navigation"
	box_material.albedo_color = Color(0.3, 0.5, 0.9)


## Called by main.gd for every piece it draws; keeps only the bake categories.
func register(body: Node3D, category: String) -> void:
	if category in SOURCE_CATEGORIES:
		sources.append(body)


## Called by main.gd for every stair flight (dict from draw.json "stairs").
func add_flight(f: Dictionary) -> void:
	flights.append(f)


## Called by main.gd for every landing piece (from draw.json "landings").
func add_landing(piece: Array) -> void:
	landings.append(piece)


## Forgets all bake sources, flights and landings (main.gd calls this on reload).
func clear_sources() -> void:
	sources.clear()
	flights.clear()
	landings.clear()


## Adds a box obstacle (width x height x length, metres) standing on y = center.y - size.y / 2.
## Call (and await) rebake() afterwards so the navmesh and the agent's path update.
func add_box(center: Vector3, size: Vector3, yaw_degrees := 0.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = box_material
	mi.position = center
	mi.rotation_degrees.y = yaw_degrees
	add_child(mi)
	sources.append(mi)
	return mi


## Removes a box made by add_box(). Call rebake() afterwards.
func remove_box(box: MeshInstance3D) -> void:
	sources.erase(box)
	box.queue_free()


## Creates the navmesh settings, bakes, then spawns a fresh agent and sends it between
## the two farthest points of the biggest walkable area. It is a coroutine (use
## `await build()` to wait for it) and emits ready_to_walk at the end.
func build() -> void:
	var nm := NavigationMesh.new()
	nm.cell_size = 0.05   # 5 cm voxels horizontally...
	nm.cell_height = 0.05   # ...and vertically (same as the [navigation] defaults in project.godot)
	nm.agent_radius = agent_radius
	nm.agent_height = agent_height
	nm.agent_max_climb = 0.2   # steps up to 20 cm still count as walkable
	nm.agent_max_slope = 30.0   # slopes up to 30 degrees still count as walkable
	navigation_mesh = nm
	await get_tree().process_frame   # let CSG shapes finish building
	await rebake()
	await build_stair_links()   # join the floors (needs the baked navmesh to find the stair ends)
	if is_instance_valid(agent):
		agent.queue_free()   # agent from the previous build / reload
	agent = PathAgent.new()
	agent.radius = agent_radius
	agent.height = agent_height
	get_parent().add_child(agent)   # sibling of Navigation, under the main scene node
	var ends := pick_far_ends()
	if ends.is_empty():
		push_warning("No walkable floor found for the agent.")
	else:
		set_route(ends[0], ends[1])
	ready_to_walk.emit()


## Re-bakes from the current geometry and waits until the map uses it.
## Faces are taken on the CPU (CSG collision faces / primitive mesh arrays), so it's fast.
func rebake() -> void:
	var src := NavigationMeshSourceGeometryData3D.new()
	for s in sources:
		if not is_instance_valid(s) or not s.is_inside_tree():   # freed bodies are skipped; hidden ones still count (hiding floors with F must not delete the walkable area)
			continue
		if s is CSGShape3D:
			var shape: ConcavePolygonShape3D = s.bake_collision_shape()   # triangles of the finished CSG shape
			if shape:
				src.add_faces(shape.get_faces(), s.global_transform)
		# BoxMesh and other primitives: read the generated triangles (indexed or not)
		elif s is MeshInstance3D and s.mesh is PrimitiveMesh:
			var arr: Array = s.mesh.get_mesh_arrays()
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
			var faces := PackedVector3Array()
			if idx.is_empty():
				faces = verts
			else:
				for i in idx:
					faces.append(verts[i])
			src.add_faces(faces, s.global_transform)
	var nm := navigation_mesh
	# bake into nm right now, on this thread
	NavigationServer3D.bake_from_source_geometry_data(nm, src)
	# assigning the resource again makes the region send the new polygons to the server
	navigation_mesh = null
	navigation_mesh = nm
	# wait until the navigation map has synced the new region data (on a physics frame)
	var map := get_world_3d().navigation_map
	var before := NavigationServer3D.map_get_iteration_id(map)
	while NavigationServer3D.map_get_iteration_id(map) == before:
		await get_tree().physics_frame
	if agent and agent.moving:
		agent.go_to(agent.target_position)   # re-plan around the change


# ---------------------------------------------------------------------------------------
# Stairs: joining the floors
# ---------------------------------------------------------------------------------------

const STAIR_TOL := 0.05   # m; two heights closer than this count as the same
const STEP_OFF := 0.45   # m; how far in front of the first step / past the last step the link ends are
const SNAP_XZ := 0.6   # m; a link end may be moved at most this far sideways to reach the navmesh...
const SNAP_Y := 0.3    # m; ...and at most this far up/down (so it never snaps onto another floor)


## Makes one NavigationLink3D per staircase (replacing the old ones) and waits until the
## navigation map uses them. Coroutine: `await build_stair_links()`.
## For each staircase (see _stair_chains()):
##   1. _stair_line() makes the walking line: in front of the first step, up the middle of
##      each flight, across the landings, past the last step;
##   2. both ends of the line are snapped onto the navmesh (the floor below and the floor
##      above); a staircase whose end has no floor nearby (e.g. the last flight to the
##      roof) gets no link;
##   3. a bidirectional link joins the two ends (so it works up AND down). Its
##      travel_cost is set so that the path finder counts the stairs as long as the real
##      walk over them, not as the short straight line between the two ends.
func build_stair_links() -> void:
	for l in stair_links:
		if is_instance_valid(l):
			l.queue_free()
	stair_links.clear()
	var map := get_world_3d().navigation_map
	for chain in _stair_chains():
		var pts := _stair_line(chain)
		var foot = _snap(map, pts[0])
		var top = _snap(map, pts[pts.size() - 1])
		if foot == null or top == null:
			print("stairs from %.2f m to %.2f m: no floor at one end, no link" % [chain[0]["z0"], chain[-1]["z1"]])
			continue
		# start/end exactly on the navmesh; the walking line starts/ends there too, so the
		# agent goes floor -> stairs without a jump
		pts[0] = foot
		pts[pts.size() - 1] = top
		var walk := 0.0   # length of the real walk over the stairs
		for i in range(1, pts.size()):
			walk += pts[i - 1].distance_to(pts[i])
		var link := NavigationLink3D.new()
		link.name = "StairLink%.1f" % chain[0]["base"]
		link.bidirectional = true   # usable in both directions: up and down
		# this node is a child of the region at the origin, so local = world positions
		link.start_position = foot
		link.end_position = top
		# the path finder's cost of a link = straight distance between its ends * travel_cost;
		# make it equal to the real walk (and a bit more, since stairs are slower)
		link.travel_cost = walk / max(foot.distance_to(top), 0.01) * 1.5
		link.set_meta("stair_points", pts)   # read by path_agent.gd
		add_child(link)
		stair_links.append(link)
	# wait until the navigation map has synced the new links (on a physics frame)
	var before := NavigationServer3D.map_get_iteration_id(map)
	while NavigationServer3D.map_get_iteration_id(map) == before:
		await get_tree().physics_frame


## Groups the flights into staircases. A staircase = a chain of flights on the same floor
## ("base") where each next flight starts at the height the previous one ends (they are
## joined by a landing), starting at the floor level. Returns an Array of Arrays of
## flight dicts, each sorted from the bottom flight to the top one.
func _stair_chains() -> Array:
	var chains := []
	var used := {}   # index in `flights` -> already in a chain
	for i in flights.size():
		var f: Dictionary = flights[i]
		if used.has(i) or abs(f["z0"] - f["base"]) > STAIR_TOL:
			continue   # not a first flight (it starts above the floor) or already taken
		used[i] = true
		var chain := [f]
		while true:
			var last: Dictionary = chain[-1]
			var best := -1
			var best_d := INF
			# the next flight starts where `last` ends: same floor, z0 == last z1,
			# and of those the one whose bottom end is nearest in plan to last's top end
			for j in flights.size():
				var g: Dictionary = flights[j]
				if used.has(j) or abs(g["base"] - last["base"]) > STAIR_TOL or abs(g["z0"] - last["z1"]) > STAIR_TOL:
					continue
				var d := _mid(last["high"]).distance_to(_mid(g["low"]))
				if d < best_d:
					best = j
					best_d = d
			if best < 0:
				break
			used[best] = true
			chain.append(flights[best])
		chains.append(chain)
	return chains


## The walking line over one staircase, as world points (x, height, z):
##   foot  : STEP_OFF in front of the middle of the first flight's bottom edge, at floor level
##   for every flight: the middle of its bottom edge (height z0) and of its top edge (z1);
##          between two flights the agent walks on the landing: a point a little way
##          onto the landing past the top edge, then a point on the landing in front of
##          the next flight (U-shaped turn, height = top of the landing)
##   top   : STEP_OFF past the middle of the last flight's top edge, at the upper floor
## The agent walks straight from point to point, so on a flight its height goes evenly
## from z0 to z1: that is the slope of the stair surface.
func _stair_line(chain: Array) -> PackedVector3Array:
	var pts := PackedVector3Array()
	for k in chain.size():
		var f: Dictionary = chain[k]
		var lo := _mid(f["low"])
		var hi := _mid(f["high"])
		var u := (hi - lo).normalized()   # plan direction of this flight (bottom -> top)
		if k == 0:
			pts.append(_v3(lo - u * STEP_OFF, f["z0"]))   # on the floor in front of the first step
		else:
			pts.append(_v3(lo - u * _landing_depth(chain[k - 1], f["z0"]), f["z0"]))   # on the landing, in line with this flight
		pts.append(_v3(lo, f["z0"]))   # first step
		pts.append(_v3(hi, f["z1"]))   # last step
		if k == chain.size() - 1:
			pts.append(_v3(hi + u * STEP_OFF, f["z1"]))   # on the upper floor, past the last step
		else:
			pts.append(_v3(hi + u * _landing_depth(f, f["z1"]), f["z1"]))   # step onto the landing
	return pts


## How far to walk onto the landing at height `z` past flight f's top edge: half the
## landing's depth (its centre line), measured along f's direction. 0.3 m if there is
## no landing at that height.
func _landing_depth(f: Dictionary, z: float) -> float:
	var hi := _mid(f["high"])
	var lo := _mid(f["low"])
	var u := (hi - lo).normalized()
	for l in landings:
		if abs(l[1] + l[2] - z) > STAIR_TOL:
			continue   # landing top (elevation + thickness) is not at this height
		var c := Vector2.ZERO
		for p in l[0]:
			c += Vector2(p[0], p[1])
		c /= l[0].size()   # landing centre
		var d := (c - hi).dot(u)   # how far the centre is past the top edge
		if d > 0.05 and d < 1.5:
			return d
	return 0.3


## Middle of a two-corner edge [[x, y], [x, y]] (plan coordinates).
func _mid(edge) -> Vector2:
	return (Vector2(edge[0][0], edge[0][1]) + Vector2(edge[1][0], edge[1][1])) / 2.0


## Plan point (x, y) at height h -> Godot world point (x, h, y).
func _v3(p: Vector2, h: float) -> Vector3:
	return Vector3(p.x, h, p.y)


## Closest navmesh point to p, or null if it is more than SNAP_XZ sideways or SNAP_Y
## up/down away (no floor there).
func _snap(map: RID, p: Vector3):
	var q := NavigationServer3D.map_get_closest_point(map, p)
	if Vector2(q.x - p.x, q.z - p.z).length() > SNAP_XZ or abs(q.y - p.y) > SNAP_Y:
		return null
	return q


## Two far-apart points: one on the biggest walkable patch of the floor at height
## `from_y` and one on the biggest patch at `to_y`, for routes between floors (key G).
func pick_floor_route(from_y: float, to_y: float) -> Array:
	var a := pick_far_ends(from_y)
	var b := pick_far_ends(to_y)
	if a.is_empty() or b.is_empty():
		return []
	return [a[0], b[1]]



## Teleports the agent to `from` and starts it walking to `to`.
func set_route(from: Vector3, to: Vector3) -> void:
	agent.global_position = from
	agent.go_to(to)


## Closest walkable point under a screen position, or null.
func pick(cam: Camera3D, screen_pos: Vector2):
	var o := cam.project_ray_origin(screen_pos)
	var d := cam.project_ray_normal(screen_pos)
	var map := get_world_3d().navigation_map
	# point on the navmesh closest to the mouse ray (1 km long)
	var p := NavigationServer3D.map_get_closest_point_to_segment(map, o, o + d * 1000.0)
	# (0, 0, 0) together with an empty navmesh means "nothing found"
	return null if p == Vector3.ZERO and not navigation_mesh.get_polygon_count() else p


## Two far-apart points on the biggest connected walkable patch ("one side to the other").
## With `level` given, only patches lying at that height (within 0.5 m) count, i.e. the
## biggest patch of that floor. Patches are found on the navmesh alone, so the stair
## links don't join them: every floor is still its own patch here.
## Steps: 1) group the navmesh polygons into connected patches (union-find; two
## polygons are connected when they share an edge, i.e. the same two vertex indices);
## 2) add up each patch's floor area; 3) on the biggest patch take two vertices that
## are far apart in a straight line (approximate); 4) snap both onto the navmesh.
func pick_far_ends(level := NAN) -> Array:
	var nm := navigation_mesh
	var verts := nm.get_vertices()
	var n := nm.get_polygon_count()
	if n == 0:
		return []
	var parent := range(n)   # union-find: parent[i] == i means polygon i is the root of its patch
	# root of x, halving the path on the way so the trees stay flat
	var find := func(x):
		while parent[x] != x:
			parent[x] = parent[parent[x]]
			x = parent[x]
		return x
	var edge_owner := {}   # edge (sorted vertex index pair) -> first polygon seen with it
	for i in n:
		var poly := nm.get_polygon(i)
		for k in poly.size():
			var a := poly[k]
			var b := poly[(k + 1) % poly.size()]
			var key := Vector2i(min(a, b), max(a, b))
			if edge_owner.has(key):
				parent[find.call(i)] = find.call(edge_owner[key])   # second polygon on the same edge: merge the two patches
			else:
				edge_owner[key] = i
	var comps := {}   # root -> {area, verts} for every connected patch
	for i in n:
		var r = find.call(i)
		if not comps.has(r):
			comps[r] = {"area": 0.0, "verts": [], "y": 0.0}
		var c = comps[r]
		var poly := nm.get_polygon(i)
		# polygon area as a fan of triangles from vertex 0, measured on the horizontal xz plane
		for k in range(1, poly.size() - 1):
			var a := verts[poly[0]]; var b := verts[poly[k]]; var d := verts[poly[k + 1]]
			c.area += abs((b - a).cross(d - a).y) / 2.0
		for vi in poly:
			c.verts.append(verts[vi])
			c.y += verts[vi].y
	var best = null
	for c in comps.values():
		if not is_nan(level) and abs(c.y / c.verts.size() - level) > 0.5:
			continue   # average height of the patch is not on the wanted floor
		if best == null or c.area > best.area:
			best = c
	if best == null:
		return []
	# two-sweep farthest pair: farthest from any point, then farthest from that
	var a: Vector3 = best.verts[0]
	for v in best.verts:
		if v.distance_squared_to(best.verts[0]) > a.distance_squared_to(best.verts[0]): a = v
	var b: Vector3 = a
	for v in best.verts:
		if v.distance_squared_to(a) > b.distance_squared_to(a): b = v
	var map := get_world_3d().navigation_map
	return [NavigationServer3D.map_get_closest_point(map, a), NavigationServer3D.map_get_closest_point(map, b)]
