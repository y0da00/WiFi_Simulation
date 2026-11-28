extends SceneTree
## Renders pictures of the ML agent with its vision rays (for checking it by eye):
##   godot --rendering-driver opengl3 --fixed-fps 60 --path godot_sim_updated/godot-sim-4 -s res://tests/snapshot_ml_agent.gd -- <out_prefix>
## (needs a display; opens a window for a few seconds). Like key M: the ML agent (green)
## and the scripted agent (red) start on the top floor and go to the exit. Writes:
##   <out_prefix>_floor.png  : ML agent walking on a floor, its storey only, seen from straight above
##   <out_prefix>_stairs.png : ML agent on a staircase
## Vision rays: green = nothing close, red = wall close. Blue line = route hint
## (next route point and the one after), yellow = the stair line it is walking.

func _initialize():
	var args := OS.get_cmdline_user_args()
	var prefix: String = args[0] if args.size() > 0 else "/tmp/ml_agent"
	var main = load("res://node_3d.tscn").instantiate()
	root.add_child(main)
	await main.nav.ready_to_walk
	await main.ml_evacuate_demo()
	var ml = main.ml_agent
	var nav = main.nav
	var start_y: float = ml.global_position.y
	# 1) on the top floor, a few seconds after the start
	var frames := 0
	while frames < 60 * 6:
		await physics_frame
		frames += 1
	await _shot(main, ml, prefix + "_floor.png", Vector3(-85, 0, 0), 11.0)
	# 2) on the stairs
	while frames < 60 * 300 and not (ml.on_stairs and ml.global_position.y < start_y - 1.0):
		await physics_frame
		frames += 1
	await _shot(main, ml, prefix + "_stairs.png", Vector3(-35, 60, 0), 7.0)
	quit()


## Pauses both agents, shows only the ML agent's storey and saves a picture.
func _shot(main, ml, path: String, rot: Vector3, dist: float) -> void:
	ml.set_physics_process(false)
	main.nav.agent.set_physics_process(false)
	ml.observe()          # fresh vision rays for the drawing
	ml._draw_debug()
	var y: float = ml.global_position.y
	for node in _pieces(main):
		var by := _base_y(node)
		node.visible = node.get_meta("kind", "") != "ceilings" and by > y - 3.0 and by < y + 0.5
	main.pivot.position = ml.global_position
	main.pivot.rotation_degrees = rot
	main.cam.position = Vector3(0, 0, dist)
	for i in 10:
		await process_frame
	root.get_texture().get_image().save_png(path)
	print("saved ", path, " agent at ", ml.global_position)
	ml.set_physics_process(true)
	main.nav.agent.set_physics_process(true)


## Every building piece (including floors/ceilings, which sit under their own parents).
func _pieces(main) -> Array:
	# main.gd keeps them all under main.building (floors and ceilings one level deeper)
	var out := []
	for level in main.level_nodes:
		for ch in level.get_children():
			if ch in main.floors or ch in main.ceilings:
				out += ch.get_children()
			elif ch.has_meta("kind"):
				out.append(ch)
	return out


## Height a piece starts at (for a piece with holes: its first child, the solid itself).
func _base_y(node) -> float:
	if node is CSGCombiner3D and node.get_child_count() > 0:
		return node.get_child(0).global_position.y
	return node.global_position.y
