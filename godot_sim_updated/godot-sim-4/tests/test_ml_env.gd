extends SceneTree
## Sanity check of the ML environment WITHOUT a trained network:
##   godot --headless --path godot_sim_updated/godot-sim-4 -s res://tests/test_ml_env.gd [-- --building=172]
## The agents get a hand-written "brain" (HeadToPoint: always walk straight at the next
## route point at full speed). If the physics, colliders, route hint and stairs work,
## most of these trips succeed. It is also the "no learning" baseline for the ML agent.

const MLAgent = preload("res://ml/ml_agent.gd")
const MLWorld = preload("res://ml/ml_world.gd")
const TRIPS := 20
const MIN_SUCCESS := 0.5   ## below this share of arrivals the test FAILS (exit code 1)


## Walks straight at the next route point (the same hint the network gets, see sensors.gd).
## Hand-written brain with the same act(obs) interface as the trained network.
class HeadToPoint:
	var agent
	func act(_obs: PackedFloat32Array) -> PackedFloat32Array:
		var d: Vector2 = agent.to_local_flat(agent.guide.next_point() - agent.global_position).normalized()
		return PackedFloat32Array([d.x, d.y])


## Loads the building, turns on collision, then walks TRIPS random trips one after another.
func _initialize():
	create_timer(1200).timeout.connect(func(): print("RESULT: TIMEOUT"); quit(2))
	var building := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--building="):
			building = a.split("=")[1]
	var main = load("res://node_3d.tscn").instantiate()
	if building != "":
		main.draw_path = "res://ml/buildings/%s.json" % building
	root.add_child(main)
	await main.nav.ready_to_walk
	main.nav.agent.moving = false   # the red scripted agent is not part of this test
	var world = MLWorld.new(main.nav)
	await world.enable_collision()
	var rng := RandomNumberGenerator.new()
	rng.seed = 42   # fixed seed: every run tests the same trips
	world.sample_points(100, rng)
	print("floors: ", world.levels)
	var agent = MLAgent.new()
	agent.show_debug = false
	main.add_child(agent)
	agent.policy = HeadToPoint.new()
	agent.policy.agent = agent
	var ok := 0
	for t in TRIPS:
		var start: Vector3 = world.random_point(rng)
		var goal: Vector3 = world.random_point(rng)
		agent.teleport(start, Vector3(1, 0, 0))
		agent.go_to(goal)
		var frames := 0
		while agent.moving and frames < 60 * 120:   # at most 120 s of game time per trip
			await physics_frame
			frames += 1
		print("trip %d: %s -> %s  arrived=%s fell=%s  %.1f s  wall-contact frames=%d" % [t, start, goal, agent.has_arrived, agent.has_fallen, frames / 60.0, agent.wall_hits])
		agent.wall_hits = 0
		if agent.has_arrived:
			ok += 1
	print("success %d / %d" % [ok, TRIPS])
	# The straight-line walker gets stuck behind corners sometimes, so 100% is not expected;
	# but if fewer than half the trips arrive, the colliders/route/stairs are broken.
	if ok >= int(ceil(MIN_SUCCESS * TRIPS)):
		print("RESULT: PASS")
		quit(0)
	else:
		print("RESULT: FAIL (need at least %d)" % int(ceil(MIN_SUCCESS * TRIPS)))
		quit(1)
