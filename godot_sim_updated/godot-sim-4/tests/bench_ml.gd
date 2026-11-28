extends SceneTree
## Speed measurements for the ML agent code (no pass/fail, just numbers):
##   godot --headless --fixed-fps 60 --path godot_sim_updated/godot-sim-4 -s res://tests/bench_ml.gd [-- --agents=100]
## Prints:
##   build            time to load draw.json, bake the navmesh and make the stair links
##   collision+points time for ml_world.gd enable_collision() + sample_points(150)
##   mlp act          average microseconds for ONE network decision (mlp_policy.gd act()),
##                    the plain one-by-one version act_slow(), and their biggest difference
##   observe          average microseconds for ONE observation (16 rays + route hint, sensors.gd)
##   plan             average microseconds for ONE route plan (route_guide.gd plan())
##   frame            average wall-clock milliseconds per physics frame with N agents walking
##                    (all physics + agent scripts + debug drawing off), over 600 frames

const MLAgent = preload("res://ml/ml_agent.gd")
const MLWorld = preload("res://ml/ml_world.gd")


## A SceneTree script starts here (godot -s runs it instead of a normal main scene).
func _initialize():
	var n_agents := 100
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--agents="): n_agents = int(a.split("=")[1])
	# 1) load the building and wait until its navmesh is baked
	var t0 := Time.get_ticks_usec()
	var main = load("res://node_3d.tscn").instantiate()
	root.add_child(main)
	await main.nav.ready_to_walk
	var t_build := (Time.get_ticks_usec() - t0) / 1e6
	main.nav.agent.moving = false   # the red scripted agent stays put
	# 2) collision shapes + random spawn/target points
	t0 = Time.get_ticks_usec()
	var world = MLWorld.new(main.nav)
	await world.enable_collision()
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	world.sample_points(150, rng)
	var t_world := (Time.get_ticks_usec() - t0) / 1e6
	# 3) N ML agents; they all share one loaded network (MLPPolicy.load_shared)
	var agents := []
	for i in n_agents:
		var a = MLAgent.new()
		a.show_debug = false
		main.add_child(a)
		if not a.load_policy():
			print("no model"); quit(1); return
		agents.append(a)
	# micro benchmarks on agent 0
	var a0 = agents[0]
	a0.teleport(world.random_point(rng)); a0.go_to(world.random_point(rng))
	var obs: PackedFloat32Array = a0.observe()
	t0 = Time.get_ticks_usec()
	for i in 5000:
		a0.policy.act(obs)
	var t_act := (Time.get_ticks_usec() - t0) / 5000.0
	# the fast act() must give the same numbers as the plain act_slow() (if it exists)
	var max_diff := 0.0
	var t_slow := 0.0
	if a0.policy.has_method("act_slow"):
		t0 = Time.get_ticks_usec()
		for i in 1000:
			a0.policy.act_slow(obs)
		t_slow = (Time.get_ticks_usec() - t0) / 1000.0
		for i in 200:
			var o := PackedFloat32Array()
			for k in obs.size(): o.append(rng.randf_range(-1.0, 1.0))
			var fa: PackedFloat32Array = a0.policy.act(o)
			var sa: PackedFloat32Array = a0.policy.act_slow(o)
			for k in fa.size(): max_diff = max(max_diff, abs(fa[k] - sa[k]))
	t0 = Time.get_ticks_usec()
	for i in 2000:
		obs = a0.observe()
	var t_obs := (Time.get_ticks_usec() - t0) / 2000.0
	t0 = Time.get_ticks_usec()
	for i in 500:
		a0.guide.plan()
	var t_plan := (Time.get_ticks_usec() - t0) / 500.0
	# frame time with all agents walking to random targets (new target when one arrives)
	for a in agents:
		a.teleport(world.random_point(rng), Vector3(1, 0, 0))
		a.go_to(world.random_point(rng))
	for i in 30:   # let the first plans and collisions settle before timing
		await physics_frame
	var total := 0
	var worst := 0
	var prev := Time.get_ticks_usec()
	for f in 600:
		await physics_frame
		var now := Time.get_ticks_usec()
		total += now - prev
		worst = max(worst, now - prev)
		prev = now
		for a in agents:
			if not a.moving:
				a.go_to(world.random_point(rng))
	print("BENCH build %.2f s | collision+points %.2f s | mlp act %.1f us (plain %.1f us, max diff %.7f) | observe %.1f us | plan %.0f us | frame %.2f ms avg, %.2f ms worst (%d agents)" % [
		t_build, t_world, t_act, t_slow, max_diff, t_obs, t_plan, total / 600.0 / 1000.0, worst / 1000.0, n_agents])
	quit(0)
