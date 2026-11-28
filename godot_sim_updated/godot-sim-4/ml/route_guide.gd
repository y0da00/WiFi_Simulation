extends RefCounted
## RouteGuide: tells an ML agent "which way is the exit" - its sense of direction.
##
## The neural network does NOT plan the whole route through the building (that would
## need a huge network and very long training). Instead it gets a hint, like a person
## who roughly knows the way: "the next corner to go round is over there". The network
## decides HOW to walk there: steering round walls, door frames and (later) other people.
##
## How the hint is made (the same idea as path_agent.gd):
##   1. NavigationServer3D.query_path() gives the shortest path from the agent to the
##      target over the navmesh. Floors are joined by the stair links (NavigationLink3D,
##      made in pathfinding.gd), so the target can be on another floor.
##   2. Every stair link in that path is replaced by the real walking line over the
##      stairs (the link's "stair_points" meta), so we know where each staircase starts.
##   3. `route` = list of 3D points, `stairs_seg[i]` = 1 if the piece route[i] -> route[i+1]
##      is on stairs. `index` = the point the agent is heading for right now.
## While the agent walks, update() moves `index` on when a point is reached and
## re-plans every REPLAN_TIME seconds, because the network does not follow the path
## exactly (re-planning from where the agent really is keeps the hint correct).
##
## FUTURE (route_knowledge in agent_traits.gd): an agent that knows the building less
## well would get a worse hint here: e.g. a noisy direction, only the next exit sign it
## can see, or nothing at all (then it must explore using its vision). Only next_point()
## and the values handed to sensors.gd would change; the network inputs stay the same.

const REACH := 0.5         ## m (horizontal): a route point counts as reached this close
const REPLAN_TIME := 1.0   ## s between re-plans
const STAIR_ENTER := 0.6   ## m: this close to the foot/top of a staircase the agent starts climbing

var agent: Node3D              ## the ml_agent.gd node (used for its position and world)
var target := Vector3.ZERO     ## where the agent wants to go (an exit, a clicked point...)
var route := PackedVector3Array()
var stairs_seg := PackedByteArray()
var index := 0
var has_route := false         ## false if the target can't be reached (no path)
var _since_plan := 0.0         ## seconds since the last plan()
var _left := PackedFloat32Array()   ## _left[i] = route length from route[i] to the end (for remaining())
var _params := NavigationPathQueryParameters3D.new()   ## re-used for every query (no new objects per plan)
var _result := NavigationPathQueryResult3D.new()


## Sets up the path query once (it is reused for every plan, no new objects per plan).
func _init(owner_agent: Node3D) -> void:
	agent = owner_agent
	_params.path_postprocessing = NavigationPathQueryParameters3D.PATH_POSTPROCESSING_CORRIDORFUNNEL
	_params.simplify_path = false   # keep every point so both ends of a stair link are in the path
	_params.metadata_flags = NavigationPathQueryParameters3D.PATH_METADATA_INCLUDE_ALL   # also say which region/link each point belongs to


## Sets a new target and plans a route to it at once. If the target can't be reached
## (e.g. a click on a closed-off room), the target becomes the closest point that can.
func set_target(t: Vector3) -> void:
	target = t
	route = PackedVector3Array()
	has_route = false
	plan()
	if not has_route and route.size() > 0:
		target = route[route.size() - 1]
		has_route = true
		_update_left()
	# random phase for the 1-second re-plans, so that many agents that got a target in
	# the same frame don't all re-plan in the same later frames (spreads the CPU load)
	_since_plan = randf() * REPLAN_TIME


## Plans the route from the agent's feet to `target` (steps 1-3 in the header).
## If the new path does NOT reach the target but the old route did, the old route is
## kept: that happens when the agent's feet are snapped onto a tiny separate navmesh
## patch (a niche next to a door, say) - the old route is still the better hint.
func plan() -> void:
	_since_plan = 0.0
	var old_route := route
	var old_seg := stairs_seg
	var old_ok := has_route
	_params.map = agent.get_world_3d().navigation_map
	_params.start_position = agent.global_position
	_params.target_position = target
	NavigationServer3D.query_path(_params, _result)
	var path := _result.get_path()
	var owners := _result.get_path_owner_ids()   # which region / link node each point belongs to
	route = PackedVector3Array()
	stairs_seg = PackedByteArray()
	var i := 0
	while i < path.size():
		route.append(path[i])
		if i + 1 < path.size():
			var link := _stair_link_between(path[i], path[i + 1], owners[i], owners[i + 1])
			if link:
				# swap the straight "jump" between the link's ends for the real stair line
				var pts: PackedVector3Array = link.get_meta("stair_points").duplicate()
				if path[i].distance_to(link.start_position) > path[i].distance_to(link.end_position):
					pts.reverse()   # entering at the top: walk the line backwards (downstairs)
				for k in range(1, pts.size()):
					stairs_seg.append(1)
					route.append(pts[k])
				i += 2
				if i < path.size():
					stairs_seg.append(0)
				continue
			stairs_seg.append(0)
		i += 1
	stairs_seg.append(0)   # padding: piece "after the last point" (keeps index lookups simple)
	index = 1 if route.size() > 1 else route.size()
	has_route = route.size() > 0 and route[route.size() - 1].distance_to(target) < 0.5
	if not has_route and old_ok:
		route = old_route
		stairs_seg = old_seg
		has_route = true
		index = _nearest_ahead()
	_update_left()


## Fills _left from the end of the route backwards, so remaining() doesn't have to add
## up the whole route every frame.
func _update_left() -> void:
	_left.resize(route.size())
	var acc := 0.0
	for k in range(route.size() - 1, -1, -1):
		if k < route.size() - 1:
			acc += route[k].distance_to(route[k + 1])
		_left[k] = acc


## Index of the route point to head for after keeping an old route: the point after the
## route piece closest to the agent on its floor.
func _nearest_ahead() -> int:
	var p := agent.global_position
	var best := 1
	var best_d := INF
	for i in range(1, route.size()):
		if abs(route[i].y - p.y) > 1.0 and abs(route[i - 1].y - p.y) > 1.0:
			continue
		var c := Geometry3D.get_closest_point_to_segment(p, route[i - 1], route[i])
		var d := c.distance_to(p)
		if d < best_d:
			best_d = d
			best = i
	return mini(best, route.size() - 1)


## Called every physics frame while the agent walks on a floor: moves `index` past
## reached points and re-plans now and then.
func update(delta: float) -> void:
	_since_plan += delta
	if _since_plan >= REPLAN_TIME:
		plan()
	var p := agent.global_position
	# skip every point that is already reached (horizontal distance, and on this floor)
	while index < route.size() - 1 and _flat_dist(p, route[index]) < REACH and abs(p.y - route[index].y) < 1.0 and stairs_seg[index] == 0:
		index += 1


## The point the agent should walk to now (what sensors.gd shows the network).
func next_point() -> Vector3:
	if route.is_empty():
		return target
	return route[mini(index, route.size() - 1)]


## The point after that one (lets the network prepare for a corner).
func point_after() -> Vector3:
	if route.is_empty():
		return target
	return route[mini(index + 1, route.size() - 1)]


## True if the piece that starts at the next point is a staircase (the agent is walking
## to the foot or the top of the stairs).
func next_is_stairs() -> bool:
	return index < route.size() - 1 and stairs_seg[index] == 1


## True when the agent stands at the start of a staircase on its route and should start
## climbing (ml_agent.gd then walks the stair line, see its header).
func should_enter_stairs() -> bool:
	return next_is_stairs() and _flat_dist(agent.global_position, route[index]) < STAIR_ENTER \
		and abs(agent.global_position.y - route[index].y) < 0.6


## The stair line starting at the next point: the points the agent walks over the
## stairs, ending at the floor on the other side. Moves `index` to the end of it.
func take_stairs() -> PackedVector3Array:
	var pts := PackedVector3Array()
	pts.append(route[index])
	while index < route.size() - 1 and stairs_seg[index] == 1:
		index += 1
		pts.append(route[index])
	return pts


## Walking distance left to the target: to the next point, then along the route.
## Used for the training reward ("did the agent get closer?").
func remaining() -> float:
	if route.is_empty():
		return agent.global_position.distance_to(target)
	var i := mini(index, route.size() - 1)
	return agent.global_position.distance_to(route[i]) + _left[i]


## Route length from point i to the end (used by ml_agent.gd on the stairs).
func left_from(i: int) -> float:
	return _left[clampi(i, 0, _left.size() - 1)] if not _left.is_empty() else 0.0


## The stair link that the path piece a -> b goes through, or null (same as path_agent.gd).
func _stair_link_between(a: Vector3, b: Vector3, owner_a: int, owner_b: int) -> NavigationLink3D:
	for id in [owner_b, owner_a]:
		var o = instance_from_id(id) if id != 0 else null
		if o is NavigationLink3D and o.has_meta("stair_points"):
			var s: Vector3 = o.start_position
			var e: Vector3 = o.end_position
			if (a.distance_to(s) < 0.3 and b.distance_to(e) < 0.3) or (a.distance_to(e) < 0.3 and b.distance_to(s) < 0.3):
				return o
	return null


## Distance between two points seen from above (height ignored).
static func _flat_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
