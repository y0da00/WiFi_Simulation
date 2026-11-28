extends SceneTree
## Headless evaluation of the trained ML agent (evacuation to the exit):
##   godot --headless --fixed-fps 60 --path godot_sim_updated/godot-sim-4 -s res://tests/test_ml_agent.gd
##   ... -s res://tests/test_ml_agent.gd -- --building=320 --trips=30     (other building / count)
##   ... -- --file=res://ml/buildings_eval/1234.json   (any building file, e.g. one never trained on)
## Exit code: 0 = PASS (ML success rate >= 90 %, never fell, never jumped), 1 = FAIL, 2 = timeout.
##
## For every trip a random start point is picked on a random floor (fixed seed, so every
## run tests the same trips). Three walkers start there AT THE SAME TIME and go to the
## exit (ml_world.gd default_exit(): the far side of the ground floor, the same point key
## G uses). They don't touch each other, so this is a fair race:
##   ML       ml_agent.gd driven by the trained network (models/ml_agent_policy.json)
##   SCRIPTED path_agent.gd, the old agent that slides exactly along the shortest route
##   HEAD     ml_agent.gd with a hand-written brain that walks straight at the next route
##            point (no learning; shows what the network adds)
## Measured per walker: arrived or not, time to the exit, and for the two physical ones
## how often they bumped into walls ("bumps" = times a wall contact started) and the
## total time touching a wall. Also: the ML agent never moves more than 0.5 m in one frame.

const MLAgent = preload("res://ml/ml_agent.gd")
const MLWorld = preload("res://ml/ml_world.gd")
const MAX_TIME := 180.0   ## s of game time per trip


## The "no learning" brain: same interface as MLPPolicy (act(obs) -> 2 numbers).
class HeadToPoint:
	var agent
	func act(_obs: PackedFloat32Array) -> PackedFloat32Array:
		# straight at the next route point, full speed, in the agent's own frame
		var d: Vector2 = agent.to_local_flat(agent.guide.next_point() - agent.global_position).normalized()
		return PackedFloat32Array([d.x, d.y])


## Runs all trips, prints one line per trip and a summary, exits with the result code.
func _initialize():
	var building := ""
	var trips := 30
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--building="): building = a.split("=")[1]
		if a.begins_with("--trips="): trips = int(a.split("=")[1])
		if a.begins_with("--file="): building = a.split("=")[1]
	# with --fixed-fps timers count game time: allow every trip its full time, plus margin
	create_timer(trips * MAX_TIME + 600).timeout.connect(func(): print("RESULT: TIMEOUT"); quit(2))
	var main = load("res://node_3d.tscn").instantiate()
	if building.begins_with("res://"):
		main.draw_path = building
	elif building != "":
		main.draw_path = "res://ml/buildings/%s.json" % building
	root.add_child(main)
	await main.nav.ready_to_walk
	var nav = main.nav
	var world = MLWorld.new(nav)
	await world.enable_collision()
	var rng := RandomNumberGenerator.new()
	rng.seed = 2026
	world.sample_points(100, rng)
	var exit_p: Vector3 = world.default_exit()
	print("building %s, floors %s, exit %s, stair links %d" % [main.draw_path, world.levels, exit_p, nav.stair_links.size()])

	var ml = MLAgent.new()
	ml.show_debug = false
	main.add_child(ml)
	if not ml.load_policy():
		print("RESULT: FAIL (no trained model)")
		quit(1)
		return
	var head = MLAgent.new()
	head.show_debug = false
	main.add_child(head)
	head.policy = HeadToPoint.new()
	head.policy.agent = head
	var scripted = nav.agent   # the red path_agent.gd that pathfinding.gd already made

	var res := {"ml": [], "scripted": [], "head": []}
	var max_step := 0.0
	var fell := 0
	for t in trips:
		var start: Vector3 = world.random_point(rng)
		var face := Vector3(1, 0, 0).rotated(Vector3.UP, rng.randf() * TAU)
		ml.teleport(start, face); ml.go_to(exit_p)
		head.teleport(start, face); head.go_to(exit_p)
		nav.set_route(start, exit_p)   # puts the scripted agent at start and sends it to the exit
		var route_len: float = scripted.path_length()
		var walkers := {"ml": ml, "head": head}
		var stat := {}
		for k in walkers:
			stat[k] = {"time": -1.0, "bumps": 0, "contact": 0, "was": false}
		var s_time := -1.0
		var frames := 0
		var prev: Vector3 = ml.global_position
		while frames < int(MAX_TIME * 60):
			await physics_frame
			frames += 1
			for k in walkers:
				var w = walkers[k]
				var st = stat[k]
				if st.time < 0 and w.has_arrived:
					st.time = frames / 60.0
				if w.moving:
					if w.touching_wall and not st.was: st.bumps += 1
					if w.touching_wall: st.contact += 1
					st.was = w.touching_wall
			if s_time < 0 and not scripted.moving:
				s_time = frames / 60.0
			# a huge move in one frame would mean a teleport / physics glitch, not walking
			max_step = max(max_step, ml.global_position.distance_to(prev))
			prev = ml.global_position
			if not ml.moving and not head.moving and s_time >= 0:
				break
		if ml.has_fallen: fell += 1
		res.ml.append(stat.ml); res.head.append(stat.head); res.scripted.append({"time": s_time})
		print("trip %2d from %s (floor %.1f), route %5.1f m | ML %s bumps %d | SCRIPTED %s | HEAD %s bumps %d" % [
			t, start, start.y, route_len, _fmt(stat.ml.time), stat.ml.bumps, _fmt(s_time), _fmt(stat.head.time), stat.head.bumps])

	print("")
	print("summary over %d trips (exit %s):" % [trips, exit_p])
	var ml_rate := 0.0
	for k in ["ml", "scripted", "head"]:
		var arr: Array = res[k]
		var ok := arr.filter(func(s): return s.time >= 0)
		var avg := 0.0
		for s in ok: avg += s.time
		avg = avg / max(ok.size(), 1)
		var line := "  %-8s success %d/%d (%.0f %%), average time %.1f s" % [k.to_upper(), ok.size(), arr.size(), 100.0 * ok.size() / arr.size(), avg]
		if k != "scripted":
			var bumps := 0
			var contact := 0
			for s in arr: bumps += s.bumps; contact += s.contact
			line += ", wall bumps %.2f per trip, wall contact %.1f s per trip" % [float(bumps) / arr.size(), contact / 60.0 / arr.size()]
		print(line)
		if k == "ml": ml_rate = float(ok.size()) / arr.size()
	# time ratio on the trips that both finished
	var ratio_sum := 0.0
	var n := 0
	for i in trips:
		if res.ml[i].time > 0 and res.scripted[i].time > 0:
			ratio_sum += res.ml[i].time / res.scripted[i].time
			n += 1
	print("  ML time / SCRIPTED time on the same trips: %.2f (1.00 = as fast as the exact shortest route)" % (ratio_sum / max(n, 1)))
	print("  ML fell %d times, biggest move in one frame %.3f m" % [fell, max_step])
	var ok_all := ml_rate >= 0.9 and fell == 0 and max_step < 0.5
	print("RESULT: ", "PASS" if ok_all else "FAIL")
	quit(0 if ok_all else 1)


## Trip time for the result table, or FAIL for a negative (= failed) time.
func _fmt(t: float) -> String:
	return ("%5.1f s" % t) if t >= 0 else "  FAIL "
