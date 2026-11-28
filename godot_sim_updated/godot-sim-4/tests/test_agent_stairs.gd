extends SceneTree
## Headless check that the agent can go between floors over the stairs:
##   godot --headless --fixed-fps 60 --path godot_sim_updated/godot-sim-4 -s res://tests/test_agent_stairs.gd
## Exit code: 0 = PASS, 1 = FAIL, 2 = timeout.
##
## Three trips are tested: DOWN from the biggest patch of the floor at FROM_Y to the far
## side of the ground floor (like an evacuation), back UP to the start, and a TURN-BACK
## trip: going down, the agent gets a new target (back upstairs) while it is in the
## middle of a flight; it must finish that staircase, re-plan, and still never jump.
## PASS needs, for each trip:
##   - the planned route ends within 0.3 m of the goal (so a path between the floors
##     exists) and has stair pieces (it really goes over the stairs);
##   - simulated frame by frame, the agent arrives within 0.3 m of the goal;
##   - it never jumps: it moves at most MAX_STEP metres per physics frame (in 3D), so the
##     height changes smoothly along the flights;
##   - on the way it passes the height of every storey in between (it walked every flight);
##   - no piece of the route is steeper than MAX_SLOPE degrees (the stair line follows the
##     flights, it never cuts through the air from one floor to the next).

var FROM_Y := 0.0   # m, upper floor to start on: the highest floor the stairs reach (set from the stair links)
var STOREYS := []   # walking heights of every floor the stairs join (set from the stair links)
const MAX_STEP := 0.5   # m per frame; anything more would be a teleport
const MAX_SLOPE := 45.0   # degrees; the flights in the dataset are 33-42 degrees

## Entry point of a SceneTree script (run with -s).
func _initialize():
	create_timer(900).timeout.connect(func(): print("RESULT: TIMEOUT"); quit(2))
	var main = load("res://node_3d.tscn").instantiate()
	root.add_child(main)
	var nav = main.nav
	await nav.ready_to_walk
	print("stair links: %d" % nav.stair_links.size())
	for l in nav.stair_links:
		print("  %s %s -> %s, %d line points, travel_cost %.2f" % [l.name, l.start_position, l.end_position, l.get_meta("stair_points").size(), l.travel_cost])
	for l in nav.stair_links:
		for y in [l.start_position.y, l.end_position.y]:
			var h := snappedf(y, 0.01)
			if not STOREYS.any(func(o): return abs(o - h) < 0.3): STOREYS.append(h)
	STOREYS.sort()
	if STOREYS.size() < 2:
		print("no stairs between floors"); print("RESULT: FAIL"); quit(1); return
	FROM_Y = STOREYS[-1]
	print("storeys joined by stairs: ", STOREYS)
	var up_end: Array = nav.pick_far_ends(FROM_Y)
	var ground: Array = nav.pick_far_ends(0.0)
	if up_end.is_empty() or ground.is_empty():
		print("no walkable patch on floor %.1f or on the ground floor" % FROM_Y)
		print("RESULT: FAIL")
		quit(1)
		return
	var a: Vector3 = up_end[0]
	var b: Vector3 = ground[1]
	var ok_down: bool = await _trip(main, a, b, "down")
	var ok_up: bool = await _trip(main, b, a, "up")
	var ok_turn: bool = await _trip(main, a, b, "turn back", a)
	var ok := ok_down and ok_up and ok_turn
	print("RESULT: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)


## Sends the agent from `from` to `to`, simulates until it arrives (at most 300 s of game
## time) and checks everything listed in the header. Returns true if all is fine.
## With `turn_back_to` given, the target changes to it the first time the agent is on a
## flight below FROM_Y - 1 m (the route checks then apply to the first route, the
## arrival check to the new target, and the storey check is skipped).
func _trip(main, from: Vector3, to: Vector3, label: String, turn_back_to = null) -> bool:
	var nav = main.nav
	var agent = nav.agent
	nav.set_route(from, to)
	var route: PackedVector3Array = agent.route
	var n_stairs := 0
	for s in agent.stairs_seg:
		n_stairs += s
	var steepest := 0.0   # steepest route piece, degrees
	for i in range(1, route.size()):
		var d: Vector3 = route[i] - route[i - 1]
		var flat := Vector2(d.x, d.z).length()
		if d.length() > 0.01:
			steepest = max(steepest, rad_to_deg(atan2(abs(d.y), flat)))
	var end_err: float = route[route.size() - 1].distance_to(to) if route.size() > 0 else INF
	print("[%s] %s -> %s: route %.2f m, %d points, %d on stairs, steepest piece %.1f deg, route end %.2f m from goal" % [label, from, to, agent.path_length(), route.size(), n_stairs, steepest, end_err])
	var done := [false]   # an array, so the lambda below can change it
	var cb := func(): done[0] = true
	agent.arrived.connect(cb)
	var frames := 0
	var max_step := 0.0
	var max_dy := 0.0
	var stair_frames := 0
	var seen := {}   # storey heights (rounded) the agent's feet passed within 5 cm
	var prev: Vector3 = agent.global_position
	while not done[0] and frames < 60 * 300:
		await physics_frame
		frames += 1
		var p: Vector3 = agent.global_position
		max_step = max(max_step, p.distance_to(prev))
		max_dy = max(max_dy, abs(p.y - prev.y))
		if agent.is_on_stairs():
			stair_frames += 1
			if turn_back_to != null and p.y < FROM_Y - 1.0 and agent.target_position != turn_back_to:
				print("[%s] new target %s while on the stairs at %s" % [label, turn_back_to, p])
				agent.go_to(turn_back_to)
				to = turn_back_to
		for h in STOREYS:
			if abs(p.y - h) < 0.1: seen[h] = true
		prev = p
	agent.arrived.disconnect(cb)
	var err: float = agent.global_position.distance_to(to)
	var lo := minf(from.y, to.y)
	var hi := maxf(from.y, to.y)
	var all_storeys := true
	for h in ([] if turn_back_to != null else STOREYS):   # skipped for the turn-back trip
		if h > lo - 0.1 and h < hi + 0.1 and not seen.has(h): all_storeys = false
	print("[%s] arrived=%s after %.1f s (%.1f s on stairs), %.2f m from goal; biggest move per frame %.3f m (height %.3f m); passed every storey: %s" % [label, done[0], frames / 60.0, stair_frames / 60.0, err, max_step, max_dy, all_storeys])
	return steepest < MAX_SLOPE and end_err < 0.3 and n_stairs > 0 and done[0] and err < 0.3 and max_step < MAX_STEP and all_storeys
