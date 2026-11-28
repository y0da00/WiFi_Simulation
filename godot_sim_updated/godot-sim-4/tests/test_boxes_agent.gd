extends SceneTree
## Headless check that the box editor (main.gd) and the walking agent work together:
##   godot --headless --fixed-fps 60 --path godot_sim_updated/godot-sim-4 -s res://tests/test_boxes_agent.gd
## Exit code: 0 = PASS, 1 = FAIL, 2 = timeout (120 s).
##
## 1. a right click (no drag) on the floor sends the agent there;
## 2. a box placed on the agent's route makes the navmesh re-bake and the route go around it;
## 3. removing the box re-bakes again (the route is as short as at the start);
## 4. key G (stairs demo) gives a route that uses the stairs.

## Entry point of a SceneTree script (run with -s).
func _initialize():
	create_timer(120).timeout.connect(func(): print("RESULT: TIMEOUT"); quit(2))
	var main = load("res://node_3d.tscn").instantiate()
	root.add_child(main)
	var nav = main.nav
	await nav.ready_to_walk
	var agent = nav.agent
	var ok := true

	# 1. right click: press and release at the same screen spot, on a walkable point
	main.show_floors(1)
	var ends: Array = nav.pick_far_ends(main.levels[0] + 0.1)
	var target: Vector3 = ends[1]
	main.cam.global_position = target + Vector3(0, 20, 0.01)   # look straight down on the target
	main.cam.look_at(target)
	var screen: Vector2 = main.cam.unproject_position(target)
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_RIGHT
		ev.pressed = pressed
		ev.position = screen
		main._unhandled_input(ev)
	var err: float = agent.target_position.distance_to(target)
	print("right click: agent sent to %s, %.2f m from the clicked point" % [agent.target_position, err])
	ok = ok and err < 0.5

	# 2. box on the route
	nav.set_route(ends[0], ends[1])
	var len1: float = agent.path_length()
	var path: PackedVector3Array = agent.route
	var best := 1   # longest straight piece of the route: put the box in its middle
	for i in range(1, path.size()):
		if path[i].distance_to(path[i - 1]) > path[best].distance_to(path[best - 1]): best = i
	var mid := (path[best] + path[best - 1]) / 2.0
	var size := Vector3(0.6, 1.0, 0.6)
	var id: int = main.next_id
	main.add_box(id, size, Vector3(mid.x, main.levels[0] + size.y / 2, mid.z), 0.0)
	main.next_id = id + 1
	main.selected = id
	await _wait_rebake(main)
	var clear := true   # the walking agent re-planned around the box by itself
	for p in agent.route:
		if abs(p.x - mid.x) < 0.3 and abs(p.z - mid.z) < 0.3: clear = false
	nav.set_route(ends[0], ends[1])   # same trip from the start again, to compare lengths
	var len2: float = agent.path_length()
	print("box %d at %s: route %.2f m -> %.2f m, avoids the box: %s" % [id, mid, len1, len2, clear])
	ok = ok and clear and len2 > len1 + 0.01

	# 3. remove it again
	main.remove_box(id)
	await _wait_rebake(main)
	nav.set_route(ends[0], ends[1])
	var len3: float = agent.path_length()
	print("box removed: route %.2f m" % len3)
	ok = ok and len3 < len2 - 0.01 and abs(len3 - len1) < 0.05

	# 4. key G
	var g := InputEventKey.new()
	g.keycode = KEY_G
	g.pressed = true
	main._unhandled_input(g)
	var n_stairs := 0
	for s in agent.stairs_seg:
		n_stairs += s
	print("G demo: route %.2f m from y %.1f to y %.1f, %d pieces on stairs" % [agent.path_length(), agent.global_position.y, agent.target_position.y, n_stairs])
	ok = ok and n_stairs > 0

	print("RESULT: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)


## waits until main.gd has re-baked the navmesh after a box change
func _wait_rebake(main) -> void:
	await process_frame
	while main.rebake_in >= 0 or main.rebaking:
		await process_frame
	await physics_frame
