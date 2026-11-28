extends SceneTree
## Renders pictures of the agent walking down the stairs (for checking it by eye):
##   godot --rendering-driver opengl3 --fixed-fps 60 --path godot_sim_updated/godot-sim-4 -s res://tests/snapshot_agent_stairs.gd -- <out_prefix>
## (needs a display; opens a window for a few seconds). The agent is sent from the floor
## at 11.6 m to the ground floor (like key G) and paused half way down a flight. Writes:
##   <out_prefix>_side.png    : only flights, landings and floor slabs (no walls), from the side
##   <out_prefix>_cutaway.png : the agent's storey with its walls, nothing above, from above at an angle
## Default prefix: /tmp/agent_stairs. The route line is blue on floors and yellow on stairs.

## Waits for the building, walks the agent onto the stairs, takes the pictures and quits.
func _initialize():
	var args := OS.get_cmdline_user_args()
	var prefix: String = args[0] if args.size() > 0 else "/tmp/agent_stairs"
	var main = load("res://node_3d.tscn").instantiate()
	root.add_child(main)
	await main.nav.ready_to_walk
	var nav = main.nav
	var agent = nav.agent
	nav.set_route(nav.pick_far_ends(11.6)[0], nav.pick_far_ends(0.0)[1])
	# walk until the feet are in the middle of the flight from 8.7 m up to the landing at 10.1 m
	var frames := 0
	while frames < 60 * 300 and not (agent.is_on_stairs() and agent.global_position.y > 9.3 and agent.global_position.y < 9.5):
		await physics_frame
		frames += 1
	agent.set_physics_process(false)   # pause it there for the pictures
	var p: Vector3 = agent.global_position
	print("agent at %s after %.1f s" % [p, frames / 60.0])
	var storey := 8.7   # floor the agent's flight starts from
	for c in main.ceilings:
		c.visible = false
	# 1) side view: flights, landings and floor slabs up to the agent's storey, no walls
	for node in _pieces(main):
		var kind: String = node.get_meta("kind", "")
		node.visible = (kind in ["stairs", "landings"] and _base_y(node) < storey + 3.0) or (kind == "floors" and _base_y(node) < storey + 1.0)
	main.pivot.position = p + Vector3(0, 0.5, 0)
	main.pivot.rotation_degrees = Vector3(-20, 70, 0)
	main.cam.position = Vector3(0, 0, 8)
	await _save(prefix + "_side.png")
	# 2) the agent's storey with walls (nothing above it), from above at an angle
	for node in _pieces(main):
		var kind: String = node.get_meta("kind", "")
		var y := _base_y(node)
		node.visible = kind != "ceilings" and y > storey - 3.0 and y < storey + 1.0
	main.pivot.position = p
	main.pivot.rotation_degrees = Vector3(-60, 20, 0)
	main.cam.position = Vector3(0, 0, 10)
	await _save(prefix + "_cutaway.png")
	quit()


## Every drawn piece (under main.building, plus the ones under the floors/ceilings nodes).
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


## Lowest y of a piece (pieces with holes are combiners at y = 0, so use their first child).
func _base_y(node) -> float:
	if node is CSGCombiner3D and node.get_child_count() > 0:
		return node.get_child(0).global_position.y
	return node.global_position.y


## Renders a few frames and saves the window as a PNG.
func _save(path: String) -> void:
	for i in 10:
		await process_frame
	root.get_texture().get_image().save_png(path)
	print("saved ", path)
