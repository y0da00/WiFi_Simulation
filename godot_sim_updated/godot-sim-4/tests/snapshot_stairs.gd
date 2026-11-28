extends SceneTree
## Renders pictures of the sloped stairs (for checking them by eye):
##   godot --rendering-driver opengl3 --path godot_sim_updated/godot-sim-4 -s res://tests/snapshot_stairs.gd -- <out_prefix>
## (needs a display; opens a window for a few seconds). Writes two pictures:
##   <out_prefix>_stairs.png  : only the flights and landings of all floors, from the side
##   <out_prefix>_cutaway.png : ground floor + 1st floor without ceilings, nothing above
##   <out_prefix>_topdown.png : the same cut-away seen straight from above, zoomed on the
##                              stairwell (to check the landings stay inside the walls)
## Default prefix: /tmp/stairs.

## Waits for the building, then takes the two pictures and quits.
func _initialize():
	var args := OS.get_cmdline_user_args()
	var prefix: String = args[0] if args.size() > 0 else "/tmp/stairs"
	var main = load("res://node_3d.tscn").instantiate()
	root.add_child(main)
	await main.nav.ready_to_walk
	main.nav.agent.visible = false
	# centre of all stair flights = where the camera looks
	var c := Vector3.ZERO
	var k := 0
	var top := 0.0
	for node in _pieces(main):
		if node.get_meta("kind", "") == "stairs":
			c += node.global_position
			k += 1
			top = max(top, node.global_position.y)
	c /= max(k, 1)
	# 1) only stairs and landings
	for node in _pieces(main):
		node.visible = node.get_meta("kind", "") in ["stairs", "landings"]
	for c in main.ceilings:
		c.visible = false
	main.pivot.position = c + Vector3(0, top / 2 - c.y + 1.5, 0)   # middle of the stair tower
	main.pivot.rotation_degrees = Vector3(-15, 75, 0)
	main.cam.position = Vector3(0, 0, 22)
	await _save(prefix + "_stairs.png")
	# 2) whole building cut away: no ceilings, nothing above the second floor
	for node in _pieces(main):
		node.visible = node.get_meta("kind", "") != "ceilings" and _base_y(node) < 2.9 + 1.0
	main.pivot.position = c + Vector3(0, 1.5, 0)
	main.pivot.rotation_degrees = Vector3(-35, 30, 0)
	main.cam.position = Vector3(0, 0, 12)
	await _save(prefix + "_cutaway.png")
	# 3) same pieces from straight above
	main.pivot.position = c + Vector3(0, 3, 0)
	main.pivot.rotation_degrees = Vector3(-89, 0, 0)
	main.cam.position = Vector3(0, 0, 9)
	await _save(prefix + "_topdown.png")
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
