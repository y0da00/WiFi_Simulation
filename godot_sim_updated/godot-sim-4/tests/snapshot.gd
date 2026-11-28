extends SceneTree
## Renders a top-down picture after the agent arrives:
## xvfb-run godot --rendering-driver opengl3 --path godot_sim_updated/godot-sim-4 -s res://tests/snapshot.gd -- <data> <out.png>
## Note: only the second argument (the PNG path, /tmp/snap.png by default) is read; the
## building always comes from res://draw.json. With a third argument, the camera is
## centred on the agent's start point.

## Loads the main scene, waits for the agent to arrive (at most 1200 frames) and saves
## a screenshot.
func _initialize():
	var args := OS.get_cmdline_user_args()
	var main = load("res://node_3d.tscn").instantiate()
	pass   # does nothing (leftover)
	root.add_child(main)
	await main.nav.ready_to_walk
	for c in main.building.get_children():
		# hide the ceilings and every directly drawn piece above the agent's floor so you can
		# see into it (pieces with holes sit in a CSGCombiner3D at y = 0, and the upper floor
		# slabs live under the "floors" node, so those stay visible)
		if String(c.name).begins_with("ceilings") or (c is CSGShape3D and c.position.y > main.nav.agent.global_position.y + 0.5): c.visible = false
	main.pivot.rotation_degrees = Vector3(-89, 0, 0)   # look straight down
	if args.size() > 2: main.pivot.position = main.nav.agent.global_position
	var done := [false]
	main.nav.agent.arrived.connect(func(): done[0] = true)
	var t := 0
	while not done[0] and t < 1200:
		await process_frame
		t += 1
	# a few more frames so the final position is rendered
	for i in 5:
		await process_frame
	root.get_texture().get_image().save_png(args[1] if args.size() > 1 else "/tmp/snap.png")
	quit()
