extends Node3D
## TrainEnv: the scene Godot runs while the Python trainer (ml/train.py) learns.
##
## Started by Python (through the wrapper ~/WiFi_Simulation/ml/godot_env.x86_64) with
## command line options such as  --port=11008 --env_seed=3 --speedup=30 --agents=16.
## What it does:
##   1. loads a building: ml/buildings/<id>.json; which one = --building=<id>, or else
##      picked by env_seed, so every parallel Godot window trains on another building;
##   2. builds it with the normal simulation.gd + pathfinding.gd (navmesh, stair links),
##      stops the scripted agent and switches on collision (ml_world.gd);
##   3. spawns --agents ML agents (16 by default; train.py asks for 24), each with an ml_controller.gd. They are
##      independent "copies" of the same exercise (they don't see or bump into each other
##      yet), which simply gives the trainer N times more experience per second;
##   4. adds the addon's Sync node, which connects to Python and runs the loop.
## Every episode: random floor and start point, random target (half of the time on
## another floor, so it has to use the stairs), random walk_speed 1.0-1.8 m/s.

const MLAgent = preload("res://ml/ml_agent.gd")
const MLController = preload("res://ml/ml_controller.gd")
const MLWorld = preload("res://ml/ml_world.gd")
const SyncScript = preload("res://addons/godot_rl_agents/sync.gd")

var rng := RandomNumberGenerator.new()
var world          ## ml_world.gd helper
var main           ## the simulation.gd node (the building)
var agents: Array = []


## Reads the command line, loads one building, waits for its navmesh, spawns the agents
## and adds the Sync node that talks to Python.
func _ready() -> void:
	var args := _args()
	rng.seed = int(args.get("env_seed", "1")) * 7919 + 13   # different (but repeatable) random numbers per copy
	var files := _building_files()
	if files.is_empty() and not args.has("building"):
		push_error("TrainEnv: no buildings in res://ml/buildings (run ml/make_buildings.py)")
		get_tree().quit(1)
		return
	# the brain decides every action_repeat frames in training and every
	# MLAgent.DECISION_FRAMES frames in the game: they must be the same number
	var rep := int(args.get("action_repeat", str(MLAgent.DECISION_FRAMES)))
	if rep != MLAgent.DECISION_FRAMES:
		push_error("TrainEnv: action_repeat=%d but ml_agent.gd DECISION_FRAMES=%d - the game would behave differently from training" % [rep, MLAgent.DECISION_FRAMES])
	var path: String
	if args.has("building"):
		path = "res://ml/buildings/%s.json" % args["building"]
	else:
		path = files[int(args.get("env_seed", "0")) % files.size()]   # copy i trains on building i (wraps around)
	print("TrainEnv: building ", path)
	main = load("res://node_3d.tscn").instantiate()
	main.draw_path = path
	add_child(main)
	await main.nav.ready_to_walk
	main.nav.agent.moving = false   # the scripted agent just stands still here
	main.nav.agent.visible = false
	world = MLWorld.new(main.nav)
	await world.enable_collision()
	world.sample_points(150, rng)   # 150 random standable points per floor for starts / targets
	print("TrainEnv: floors ", world.levels, " points ", world.levels.map(func(l): return world.points[l].size()))
	var n := int(args.get("agents", "16"))
	for i in n:
		var a = MLAgent.new()
		a.show_debug = false
		add_child(a)
		var c = MLController.new()   # the link to Python: observations, actions, reward
		c.agent = a
		c.env = self
		a.add_child(c)
		agents.append(a)
		new_episode(a, c)
	# Sync must be the child of a node that is not "ready" yet (it waits for its parent's
	# ready signal), so it goes into a fresh holder node that is added afterwards
	var holder := Node.new()
	holder.name = "SyncHolder"
	var sync := Node.new()
	sync.set_script(SyncScript)
	sync.name = "Sync"
	holder.add_child(sync)
	add_child(holder)


## Starts a new episode for one agent: new speed, start point, facing and target.
func new_episode(agent, ctrl) -> void:
	agent.traits.walk_speed = rng.randf_range(1.0, 1.8)
	for attempt in 20:   # retry until the trip has a route of a useful length
		var start: Vector3 = world.random_point(rng)
		var goal: Vector3
		var other_floors: Array = world.levels.filter(func(l): return abs(l - start.y) > 0.5 and not world.points[l].is_empty())
		if not other_floors.is_empty() and rng.randf() < 0.5:   # half the trips go to another floor
			goal = world.random_point(rng, other_floors[rng.randi() % other_floors.size()])
		else:
			goal = world.random_point(rng, _level_of(start.y))
		var ang := rng.randf() * TAU
		agent.teleport(start, Vector3(sin(ang), 0, cos(ang)))
		agent.go_to(goal)
		var rem: float = agent.guide.remaining()
		if agent.guide.has_route and rem > 2.0 and rem < 70.0:   # not trivial, not huge
			break
	ctrl.episode_started()   # resets the controller's counters and time limit


## The known walking height closest to y (which floor a point is on).
func _level_of(y: float) -> float:
	var best: float = world.levels[0]
	for l in world.levels:
		if abs(l - y) < abs(best - y):
			best = l
	return best


## All res://ml/buildings/*.json files, sorted, so env_seed always picks the same one.
func _building_files() -> Array:
	var out := []
	for f in DirAccess.get_files_at("res://ml/buildings"):
		if f.ends_with(".json"):
			out.append("res://ml/buildings/" + f)
	out.sort()
	return out


## "--key=value" command line options -> {"key": "value"}.
func _args() -> Dictionary:
	var d := {}
	for a in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if a.begins_with("--") and a.find("=") > 0:
			var kv := a.substr(2).split("=", true, 1)
			d[kv[0]] = kv[1]
	return d
