extends SceneTree
## Headless check of the pathfinding on res://draw.json:
##   godot --headless --fixed-fps 60 --path godot_sim_updated/godot-sim-4 -s res://tests/test_pathfinding.gd
## Also places a box on the route and checks the agent re-plans around it.
## Exit code: 0 = PASS, 1 = FAIL, 2 = timeout (120 s).
##
## PASS needs: a non-empty first path, the agent arriving within 0.3 m of the goal, the
## new path staying more than 0.3 m from the box centre on x or z at every path point,
## and the new path not being shorter than the first one.

## Entry point of a SceneTree script (run with -s): loads the main scene and runs the test.
func _initialize():
	# safety net: fail if the whole test takes more than 120 s
	create_timer(120).timeout.connect(func(): print("RESULT: TIMEOUT"); quit(2))
	var main = load("res://node_3d.tscn").instantiate()
	root.add_child(main)
	var nav = main.nav
	await nav.ready_to_walk   # wait for the navmesh bake and the first route
	var agent = nav.agent
	print("navmesh polygons: ", nav.navigation_mesh.get_polygon_count())
	await physics_frame   # give the agent a frame to compute its first path
	var start: Vector3 = agent.global_position
	var goal: Vector3 = agent.target_position
	var len1: float = agent.path_length()
	print("start %s goal %s straight %.2f m path %.2f m (%d points)" % [start, goal, start.distance_to(goal), len1, agent.get_current_navigation_path().size()])
	# drop a 0.6 x 1 x 0.6 m box in the middle of the longest straight leg and re-plan
	var path: PackedVector3Array = agent.get_current_navigation_path()
	# find the longest segment of the path; best = index of its end point
	var best := 1
	for i in range(1, path.size()):
		if path[i].distance_to(path[i - 1]) > path[best].distance_to(path[best - 1]): best = i
	var mid := (path[best] + path[best - 1]) / 2.0
	nav.add_box(mid + Vector3(0, 0.5, 0), Vector3(0.6, 1, 0.6))
	await nav.rebake()
	await physics_frame
	var len2: float = agent.path_length()
	var clear := true
	for p in agent.get_current_navigation_path():
		if abs(p.x - mid.x) < 0.3 and abs(p.z - mid.z) < 0.3: clear = false
	print("with box at %s: path %.2f m, avoids box: %s" % [mid, len2, clear])
	# an array, so the lambda below can change it (lambdas copy plain local variables)
	var done := [false]
	agent.arrived.connect(func(): done[0] = true)
	var frames := 0
	while not done[0] and frames < 60 * 90:   # up to 90 s at 60 fps
		await physics_frame
		frames += 1
	var err: float = agent.global_position.distance_to(goal)
	print("arrived=%s after %.1f s, %.2f m from goal" % [done[0], frames / 60.0, err])
	var ok: bool = len1 > 0.0 and done[0] and err < 0.3 and clear and len2 >= len1 - 0.01
	print("RESULT: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
