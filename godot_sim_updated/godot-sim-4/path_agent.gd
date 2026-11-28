extends Node3D
## A capsule that walks the shortest route to a target, also up and down the stairs,
## and draws that route as a blue line.
##
## Created by pathfinding.gd. The node's origin is at the feet (the capsule mesh is
## lifted by height / 2).
##
## How a route is made (see go_to() and _plan()):
##   1. The NavigationServer3D is asked for the shortest path from the feet to the target
##      (NavigationServer3D.query_path). The navmesh has one flat "island" per floor; the
##      islands are joined by one NavigationLink3D per staircase (made by pathfinding.gd,
##      see build_stair_links()). A link is a "shortcut" the path finder may use: it
##      knows only the link's two ends, so in the returned path a staircase shows up as
##      just two points, the foot of the stairs on one floor and the top on the other.
##   2. Every such pair of points is replaced by the real walking line over the stairs
##      (the link remembers it in its "stair_points" meta: up the middle of each flight,
##      across the landing, up the next flight). Going down, the same line is used in
##      reverse.
##   3. The result is `route`: a list of 3D points, plus `stairs_seg` which says for each
##      piece of the route (point i -> point i + 1) whether it is on stairs.
##
## How it walks (_physics_process()): every physics frame it moves up to speed * delta
## metres (stair_speed on the stairs) straight towards the next route point, in 3D. Since
## the stair points are at the height of the stair surface, moving straight between them
## makes the feet slide smoothly up/down the slope: the height is interpolated along the
## flight, the agent never teleports between floors.

## Emitted once the agent reaches its target.
signal arrived

@export var speed := 1.4          # m/s, normal walking pace on a floor
@export var stair_speed := 0.7    # m/s along the slope, people are slower on stairs
@export var radius := 0.25   # m, capsule radius
@export var height := 1.7   # m, capsule height

var target_position := Vector3.ZERO   # where the agent was last sent (go_to())
var route := PackedVector3Array()   # the points to walk through, stairs already expanded
var stairs_seg := PackedByteArray()   # stairs_seg[i] == 1: the piece route[i] -> route[i + 1] is on stairs
var index := 0   # route[index] is the point the agent is walking to right now
var moving := false   # true from go_to() until arrival
var pending_target = null   # a new target that arrived while on the stairs (used once the stairs are done)
var line := MeshInstance3D.new()   # blue line showing the current route


## Builds the red capsule and the route line.
func _ready():
	var body := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = radius
	cap.height = height
	body.mesh = cap
	body.position.y = height / 2
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.9, 0.3, 0.2)
	body.material_override = mat
	add_child(body)

	line.top_level = true   # the line uses world coordinates (the route is global), not the agent's transform
	var lm := StandardMaterial3D.new()
	lm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lm.vertex_color_use_as_albedo = true   # colour per vertex: blue on floors, yellow on stairs
	line.material_override = lm
	add_child(line)


## Sends the agent to `target` (can be on another floor). If the agent is in the middle
## of a staircase, it first finishes that staircase and then plans the new route from
## the floor it lands on (planning from the middle of a flight would snap it onto a
## floor, i.e. teleport it).
func go_to(target: Vector3):
	target_position = target
	moving = true
	if is_on_stairs():
		pending_target = target
		return
	_plan()


## True while the agent is walking a stair piece of its route.
func is_on_stairs() -> bool:
	return moving and index > 0 and index < route.size() and stairs_seg[index - 1] == 1


## Asks the navigation server for a path from the feet to target_position and turns it
## into `route` (step 2 in the header: links -> real stair lines).
func _plan():
	pending_target = null
	var params := NavigationPathQueryParameters3D.new()
	params.map = get_world_3d().navigation_map
	params.start_position = global_position
	params.target_position = target_position
	# shortest straight-line path through the corridor of navmesh polygons
	params.path_postprocessing = NavigationPathQueryParameters3D.PATH_POSTPROCESSING_CORRIDORFUNNEL
	params.simplify_path = false   # keep every point, so the link's two ends are surely in the path
	params.metadata_flags = NavigationPathQueryParameters3D.PATH_METADATA_INCLUDE_ALL   # also return what each point belongs to (region or link)
	var res := NavigationPathQueryResult3D.new()
	NavigationServer3D.query_path(params, res)
	var path := res.get_path()
	var owners := res.get_path_owner_ids()   # per point: instance id of the region/link node it belongs to
	route = PackedVector3Array()
	stairs_seg = PackedByteArray()
	var i := 0
	while i < path.size():
		route.append(path[i])
		if i + 1 < path.size():
			var link := _stair_link_between(path[i], path[i + 1], owners[i], owners[i + 1])
			if link:
				# replace the straight jump between the link ends by the real stair line
				# duplicate(): packed arrays are shared by reference, so reversing the link's
				# own array would turn it around for every later route too
				var pts: PackedVector3Array = link.get_meta("stair_points").duplicate()
				if path[i].distance_to(link.start_position) > path[i].distance_to(link.end_position):
					pts.reverse()   # entering at the top end: walk the line backwards (downstairs)
				# the line starts and ends exactly on the link ends, which are path[i] and
				# path[i + 1]: skip its first point (already added) and keep the rest
				for k in range(1, pts.size()):
					stairs_seg.append(1)
					route.append(pts[k])
				i += 2   # path[i + 1] == last stair point, already added
				if i < path.size():
					stairs_seg.append(0)   # the piece from the stair top to the next path point is floor
				continue
			stairs_seg.append(0)
		i += 1
	index = 1 if route.size() > 1 else route.size()   # route[0] is where the agent already stands
	_draw_path()


## The stair link that the path piece a -> b goes through, or null for a normal floor
## piece. A piece is a stair crossing when one of its points belongs to a
## NavigationLink3D that has "stair_points" and a and b are that link's two ends.
func _stair_link_between(a: Vector3, b: Vector3, owner_a: int, owner_b: int) -> NavigationLink3D:
	for id in [owner_b, owner_a]:
		var o = instance_from_id(id) if id != 0 else null
		if o is NavigationLink3D and o.has_meta("stair_points"):
			var s: Vector3 = o.start_position
			var e: Vector3 = o.end_position
			var tol := 0.3   # m; the path's link points are (almost) exactly the link ends
			if (a.distance_to(s) < tol and b.distance_to(e) < tol) or (a.distance_to(e) < tol and b.distance_to(s) < tol):
				return o
	return null


## Length of the current route in metres (sum of its pieces, stairs included).
func path_length() -> float:
	var d := 0.0
	for i in range(1, route.size()):
		d += route[i - 1].distance_to(route[i])
	return d


## The current route (kept under this name for the tests and older code).
func get_current_navigation_path() -> PackedVector3Array:
	return route


## Every physics frame: move up to speed * delta metres (stair_speed on stairs) straight
## towards route[index], in 3D, so on a flight the feet follow the slope. When a point is
## reached, the next one becomes the goal; the leftover distance of this frame is used
## on the next piece, so the speed stays even at corners.
func _physics_process(delta: float):
	if not moving:
		return
	var budget := delta   # seconds of walking left in this frame
	while budget > 0.0 and index < route.size():
		var on_stairs := stairs_seg[index - 1] == 1
		var v := stair_speed if on_stairs else speed
		var to_next := route[index] - global_position
		var dist := to_next.length()
		var flat := Vector3(to_next.x, 0, to_next.z)   # walking direction without the height part
		if flat.length() > 0.001:
			look_at(global_position + flat, Vector3.UP)   # face the walking direction (stay upright on slopes)
		if dist <= v * budget:
			# reaches the point in this frame: snap onto it and keep the unused time
			global_position = route[index]
			budget -= dist / v
			index += 1
			if on_stairs and pending_target != null and (index >= route.size() or stairs_seg[index - 1] == 0):
				_plan()   # stairs finished: now use the target that came in meanwhile
				return
		else:
			global_position += to_next / dist * v * budget   # part of the way, height included
			budget = 0.0
	if index >= route.size():
		moving = false
		arrived.emit()


## Rebuilds the line mesh from the route, 5 cm above the floor so the floor doesn't hide
## it. Floor pieces are blue, stair pieces yellow.
func _draw_path():
	var im := ImmediateMesh.new()
	if route.size() >= 2:
		im.surface_begin(Mesh.PRIMITIVE_LINES)   # pairs of points: one short line per route piece
		for i in range(1, route.size()):
			var c := Color(1.0, 0.85, 0.1) if stairs_seg[i - 1] == 1 else Color(0.1, 0.6, 1.0)
			im.surface_set_color(c)
			im.surface_add_vertex(route[i - 1] + Vector3(0, 0.05, 0))
			im.surface_set_color(c)
			im.surface_add_vertex(route[i] + Vector3(0, 0.05, 0))
		im.surface_end()
	line.mesh = im
