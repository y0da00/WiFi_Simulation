extends AIController3D

@onready var agent: CharacterBody3D = get_parent()
@onready var raycast_sensor: RayCastSensor3D = $RayCastSensor3D

const MIN_GOAL_DISTANCE := 3.0
const MAX_GOAL_DISTANCE := 15.0
const GOAL_RADIUS := 0.6
const MAX_DROP := 0.5
const MAX_RISE := 0.4

var world = null
var goal_marker: Node3D
var goal: Vector3 = Vector3.ZERO
var previous_distance: float = 0.0
var out_of_floor := false

func _ready() -> void:
	super._ready()
	reset_after = 2000
	raycast_sensor.collision_mask = 1

func start(w) -> void:
	world = w
	goal_marker = world.get_node_or_null("Goal")
	_respawn()

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if world == null:
		return
	var dy = agent.global_position.y - (world.floor_y() + world.AGENT_HALF_HEIGHT)
	if dy < -MAX_DROP or dy > MAX_RISE:
		out_of_floor = true
		done = true
		needs_reset = true
	if needs_reset:
		_respawn()
		reset()

func _distance_to_goal() -> float:
	return Vector2(goal.x - agent.global_position.x, goal.z - agent.global_position.z).length()

func _respawn() -> void:
	world.set_active_level(world.pick_level())
	var agent_pos = Vector3.INF
	var goal_pos = Vector3.INF
	for i in 30:
		agent_pos = world.random_free_point()
		if agent_pos == Vector3.INF:
			continue
		for j in 30:
			var g = world.random_free_point()
			if g == Vector3.INF:
				continue
			var d = Vector2(g.x - agent_pos.x, g.z - agent_pos.z).length()
			if d >= MIN_GOAL_DISTANCE and d <= MAX_GOAL_DISTANCE:
				goal_pos = g
				break
		if goal_pos != Vector3.INF:
			break
	if agent_pos == Vector3.INF:
		push_warning("No free spawn point on floor %d" % (world.active_level + 1))
		return
	if goal_pos == Vector3.INF:
		goal_pos = agent_pos + Vector3(MIN_GOAL_DISTANCE, 0, 0)
	agent.global_position = agent_pos
	agent.velocity = Vector3.ZERO
	agent.requested_movement = Vector2.ZERO
	goal = Vector3(goal_pos.x, world.floor_y(), goal_pos.z)
	if goal_marker:
		goal_marker.global_position = goal + Vector3(0, 0.15, 0)
	previous_distance = _distance_to_goal()

func get_obs() -> Dictionary:
	var obs := []
	obs.append_array(raycast_sensor.get_observation())
	var to_goal = goal - agent.global_position
	to_goal.y = 0
	if to_goal.length() > 0.1:
		to_goal = to_goal.normalized()
	obs.append(to_goal.x)
	obs.append(to_goal.z)
	obs.append(agent.velocity.x / 5.0)
	obs.append(agent.velocity.z / 5.0)
	return {"obs": obs}

func get_reward() -> float:
	if out_of_floor:
		out_of_floor = false
		return -5.0
	var reward := 0.0
	var current_distance = _distance_to_goal()
	reward += (previous_distance - current_distance) * 2
	previous_distance = current_distance
	if current_distance < GOAL_RADIUS:
		reward += 10
		done = true
		needs_reset = true
	reward -= 0.1
	return reward

func get_action_space() -> Dictionary:
	return {
		"move" : {"size": 2, "action_type": "continuous"}
	}

func set_action(action) -> void:
	var move = action["move"]
	agent.requested_movement = Vector2(
		clamp(move[0], -1, 1),
		clamp(move[1], -1, 1)
	)

func get_info() -> Dictionary:
	if world == null:
		return {}
	var p = agent.global_position
	return {"floor": world.active_level + 1, "x": p.x, "y": p.y, "z": p.z, "floor_y": world.floor_y(), "goal_distance": _distance_to_goal()}
