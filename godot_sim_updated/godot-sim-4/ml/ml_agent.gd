extends CharacterBody3D
## MLAgent: one person in the simulation whose walking is decided by a neural network.
##
## The parts (each in its own file, so new features only touch one place):
##   traits  (agent_traits.gd)  speed, size, senses... of THIS person
##   guide   (route_guide.gd)   sense of direction: the next point of the route to the target
##   sensors (sensors.gd)       turns vision rays + route hint + own speed into 27 numbers
##   policy  (mlp_policy.gd)    the trained network: 27 numbers in -> 2 numbers out
##
## What happens every physics frame (60 per second), see _physics_process():
##   1. ON A FLOOR: every DECISION_FRAMES frames (10 times a second) the brain looks at
##      the observation and picks an ACTION = 2 numbers between -1 and 1: how fast to go
##      to the right and forwards, as a fraction of walk_speed, in the agent's own frame
##      (the frame it faced at the moment of the decision, so the action means the same
##      thing during the 6 frames it is used, even while the body turns).
##      The body then speeds up / slows down towards that velocity (acceleration limit),
##      turns to face where it walks (turn speed limit) and moves with move_and_slide():
##      the physics engine stops it at walls and keeps it on the floor (gravity).
##      Touching a wall is counted in wall_hits (training punishes it).
##   2. AT A STAIRCASE: when the route says "the stairs start here" and the agent is within
##      0.6 m of that point, it walks the stair line (up the flights, across the landing)
##      at stair_speed, like path_agent.gd, and then the brain takes over again on the
##      new floor. So: the NETWORK steers on floors, the stairs are SCRIPTED (a hybrid).
##      The network still knows a staircase is coming (an input says so) and walks to it.
##      (A later version could make the stairs physical and let the network climb too.)
##   3. Checks: arrived (within 0.5 m of the target, same floor) -> signal `arrived`;
##      dropped more than 1 m below the floor it stood on -> signal `fell`.
##
## Who decides the action:
##   * in the game/tests: `policy` (the trained network, loaded from a JSON file);
##   * during training: the Python trainer, through ml_controller.gd (then policy == null).
##
## Collisions: the body is on physics layer 2 (AGENT_LAYER) and only collides with layer 1
## (the building). So agents walk THROUGH each other for now. For "they can't go through
## one another": add AGENT_LAYER to collision_mask in _ready() (one line), add the other
## agents to the sensors (see sensors.gd) and retrain with many agents in one scene.

const AgentTraits = preload("res://ml/agent_traits.gd")
const RouteGuide = preload("res://ml/route_guide.gd")
const Sensors = preload("res://ml/sensors.gd")
const MLPPolicy = preload("res://ml/mlp_policy.gd")

signal arrived   ## reached the target
signal fell      ## fell down (e.g. into a stairwell)

const WORLD_LAYER := 1
const AGENT_LAYER := 2
const DECISION_FRAMES := 6   ## the brain decides every 6 physics frames (= action_repeat in training)
const GRAVITY := 9.8         ## m/s^2
const ARRIVE_DIST := 0.5     ## m

var traits: AgentTraits      ## this person's settings (created in _init if none given)
var guide: RouteGuide
var sensors: Sensors
var policy = null           ## the brain: anything with act(obs) -> 2 numbers (normally an MLPPolicy); null while training from Python
var action := Vector2.ZERO   ## last action: x = to the right, y = forwards (each -1..1)
var facing := Vector3(0, 0, -1)   ## unit vector (horizontal) the agent looks/walks towards
var moving := false          ## true between go_to() and arriving / falling
var on_stairs := false       ## true while walking the stair line
var has_arrived := false
var has_fallen := false
var floor_y := 0.0           ## height of the floor it last stood on (for the fall check)
var wall_hits := 0           ## frames in which it touched a wall (a statistic; reset it yourself)
var touching_wall := false   ## touched a wall in the latest frame
var ray_hits := PackedVector3Array()   ## end points of the vision rays (filled by sensors.gd)
var show_debug := true       ## draw vision rays and the route hint
var color := Color(0.2, 0.8, 0.3)

var _stair_pts := PackedVector3Array()   ## the stair line being walked
var _stair_i := 0                        ## index of the stair point walked to now
var _frame := 0                          ## physics frames since the last decision (0 = decide now)
var _act_fwd := Vector3(0, 0, -1)        ## facing at the last decision: the frame the action is in
var _debug := MeshInstance3D.new()
var _im := ImmediateMesh.new()   ## the debug drawing, re-filled each frame (not re-created)
var _body_mesh := MeshInstance3D.new()


## Makes the agent with its traits (speed, size...; default AgentTraits if none given),
## its route hint and its sensors.
func _init(t: AgentTraits = null) -> void:
	traits = t if t != null else AgentTraits.new()
	guide = RouteGuide.new(self)
	sensors = Sensors.new()


## Builds the capsule (collision + green mesh) and the debug drawing.
func _ready() -> void:
	collision_layer = AGENT_LAYER
	collision_mask = WORLD_LAYER   # FUTURE: WORLD_LAYER | AGENT_LAYER -> agents block each other
	floor_max_angle = deg_to_rad(40.0)
	floor_snap_length = 0.3        # stick to the floor over small bumps instead of flying off
	var cs := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = traits.radius
	shape.height = traits.height
	cs.shape = shape
	cs.position.y = traits.height / 2.0   # the node's origin is at the feet
	add_child(cs)
	var cap := CapsuleMesh.new()
	cap.radius = traits.radius
	cap.height = traits.height
	_body_mesh.mesh = cap
	_body_mesh.position.y = traits.height / 2.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	_body_mesh.material_override = mat
	add_child(_body_mesh)
	# a small "nose" so you can see which way it faces
	var nose := MeshInstance3D.new()
	var nm := BoxMesh.new()
	nm.size = Vector3(0.12, 0.12, 0.2)
	nose.mesh = nm
	nose.material_override = mat
	_body_mesh.add_child(nose)
	nose.position = Vector3(0, traits.height * 0.35, -traits.radius)   # relative to the capsule centre
	_debug.top_level = true   # world coordinates
	var lm := StandardMaterial3D.new()
	lm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lm.vertex_color_use_as_albedo = true
	_debug.material_override = lm
	add_child(_debug)


## Loads the trained network from a JSON file (made by ml/export_policy.py).
func load_policy(path := "res://ml/models/ml_agent_policy.json") -> bool:
	var p = MLPPolicy.load_shared(path)   # parsed once, shared by all agents
	if p == null:
		return false
	if p.obs_size != sensors.size(self):
		push_warning("The network expects %d inputs but the sensors give %d: retrain it." % [p.obs_size, sensors.size(self)])
		return false
	policy = p
	return true


## Sends the agent to `target` (may be on another floor).
func go_to(target: Vector3) -> void:
	has_arrived = false
	if on_stairs:
		guide.target = target   # finish the staircase first; the route is planned when it is done
	else:
		guide.set_target(target)
		_frame = 0              # new target: let the brain decide at once
	moving = true


## Puts the agent at `pos` standing still (used to start an episode / a demo).
func teleport(pos: Vector3, face := Vector3.ZERO) -> void:
	global_position = pos
	velocity = Vector3.ZERO
	floor_y = pos.y
	on_stairs = false
	has_fallen = false
	has_arrived = false
	touching_wall = false
	action = Vector2.ZERO
	_frame = 0
	if face.length() > 0.01:
		facing = Vector3(face.x, 0, face.z).normalized()
	_act_fwd = facing
	_apply_facing()


## The direction the agent faces (flat, unit length). Sensors use it for "in front of me".
func forward() -> Vector3:
	return facing


## World vector -> (to my right, in front of me), ignoring height.
func to_local_flat(v: Vector3) -> Vector2:
	var right := facing.cross(Vector3.UP)
	return Vector2(v.dot(right), v.dot(facing))


## The observation (27 numbers) for the network, see sensors.gd.
func observe() -> PackedFloat32Array:
	return sensors.observe(self)


## Sets the action (from the network or from Python). Longer than 1 is scaled down, so
## the agent never goes faster than walk_speed.
func set_action(a: Vector2) -> void:
	action = a.limit_length(1.0)
	_act_fwd = facing   # the action is relative to where the agent faces NOW


## Walking distance left to the target. On the stairs it is measured along the rest of
## the stair line (route_guide.gd alone would measure a straight line to the stair end).
## Used by the reward (ml_controller.gd) and the route sensor (sensors.gd).
func remaining_distance() -> float:
	if not on_stairs or _stair_i >= _stair_pts.size():
		return guide.remaining()
	var d := global_position.distance_to(_stair_pts[_stair_i])
	for k in range(_stair_i + 1, _stair_pts.size()):
		d += _stair_pts[k - 1].distance_to(_stair_pts[k])
	# from the stair end on: the guide's route (its index is already at the stair end)
	return d + _route_after_stairs()


## Route length from the end of the staircase to the target.
func _route_after_stairs() -> float:
	return guide.left_from(guide.index)


## Every physics frame (60 per second): on a stair link walk the scripted stair line;
## otherwise update the route hint, ask the brain for a new action every DECISION_FRAMES
## frames, move with that action and check arrived / fallen.
func _physics_process(delta: float) -> void:
	if moving:
		if on_stairs:
			_walk_stairs(delta)
		else:
			guide.update(delta)
			if guide.should_enter_stairs():
				_stair_pts = guide.take_stairs()
				_stair_i = 0
				on_stairs = true
				_walk_stairs(delta)
			else:
				if policy != null and _frame % DECISION_FRAMES == 0:
					var a: PackedFloat32Array = policy.act(observe())
					set_action(Vector2(a[0], a[1]))
				_walk_floor(delta)
				_frame += 1
		_check_end()
	else:
		velocity = Vector3.ZERO
	if show_debug and is_visible_in_tree():
		_draw_debug()


## Step 1 in the header: turn the action into movement on a floor.
func _walk_floor(delta: float) -> void:
	var right := _act_fwd.cross(Vector3.UP)
	var desired := (right * action.x + _act_fwd * action.y) * traits.walk_speed
	var hv := Vector3(velocity.x, 0, velocity.z).move_toward(desired, traits.acceleration * delta)
	velocity.x = hv.x
	velocity.z = hv.z
	velocity.y = 0.0 if is_on_floor() else velocity.y - GRAVITY * delta
	move_and_slide()
	touching_wall = false
	for i in get_slide_collision_count():
		if get_slide_collision(i).get_normal().y < 0.7:   # steep surface = wall (floors have normal.y ~ 1)
			touching_wall = true
	if touching_wall:
		wall_hits += 1
	if is_on_floor():
		floor_y = global_position.y
	# turn towards the walking direction, at most turn_speed_deg per second
	var flat := Vector3(velocity.x, 0, velocity.z)
	if flat.length() > 0.05:
		var ang := facing.signed_angle_to(flat.normalized(), Vector3.UP)
		var max_turn := deg_to_rad(traits.turn_speed_deg) * delta
		facing = facing.rotated(Vector3.UP, clampf(ang, -max_turn, max_turn)).normalized()
		_apply_facing()


## Step 2 in the header: walk the stair line point by point at stair_speed (the height
## follows the line, so the feet go smoothly up/down the slope). No physics here: the
## body just moves along the line, like path_agent.gd.
func _walk_stairs(delta: float) -> void:
	var start := global_position
	touching_wall = false   # no physics on the stairs
	var budget := traits.stair_speed * delta   # metres left to walk in this frame
	while budget > 0.0 and _stair_i < _stair_pts.size():
		var to_next := _stair_pts[_stair_i] - global_position
		var d := to_next.length()
		if d <= budget:
			global_position = _stair_pts[_stair_i]
			budget -= d
			_stair_i += 1
		else:
			global_position += to_next / d * budget
			budget = 0.0
	velocity = (global_position - start) / delta   # so the sensors see the real speed
	var flat := Vector3(velocity.x, 0, velocity.z)
	if flat.length() > 0.01:
		facing = flat.normalized()
		_apply_facing()
	if _stair_i >= _stair_pts.size():
		# off the stairs: stand on the new floor and let the brain steer again
		on_stairs = false
		floor_y = global_position.y
		velocity = Vector3.ZERO
		guide.set_target(guide.target)   # plan from the new floor (also picks up a target set meanwhile)
		_frame = 0                       # and let the brain decide at once


## Step 3 in the header.
func _check_end() -> void:
	if not on_stairs and global_position.y < floor_y - 1.0:
		has_fallen = true
		moving = false
		fell.emit()
		return
	var t := guide.target
	if not on_stairs and Vector2(global_position.x - t.x, global_position.z - t.z).length() < ARRIVE_DIST and abs(global_position.y - t.y) < 0.6:
		has_arrived = true
		moving = false
		velocity = Vector3.ZERO
		arrived.emit()


## Rotates the visible body so its nose points along `facing`.
func _apply_facing() -> void:
	if _body_mesh.is_inside_tree():
		_body_mesh.global_basis = Basis.looking_at(facing, Vector3.UP)


## Draws the vision rays (green = far, red = close) and a blue line to the route point
## the agent is heading for (yellow while on the stairs).
func _draw_debug() -> void:
	var im := _im
	im.clear_surfaces()
	_debug.mesh = im
	if ray_hits.is_empty() and not moving:
		return
	var origin := global_position + Vector3(0, traits.vision_height, 0)
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for h in ray_hits:
		var closeness := 1.0 - clampf(origin.distance_to(h) / traits.vision_range, 0.0, 1.0)
		var c := Color(0.2, 1.0, 0.2).lerp(Color(1.0, 0.1, 0.1), closeness)
		im.surface_set_color(c)
		im.surface_add_vertex(origin)
		im.surface_set_color(c)
		im.surface_add_vertex(h)
	var guide_c := Color(1.0, 0.85, 0.1) if on_stairs else Color(0.1, 0.6, 1.0)
	var pts := PackedVector3Array([global_position, guide.next_point(), guide.point_after()])
	if on_stairs:
		pts = PackedVector3Array([global_position])
		pts.append_array(_stair_pts.slice(_stair_i))
	for i in range(1, pts.size()):
		im.surface_set_color(guide_c)
		im.surface_add_vertex(pts[i - 1] + Vector3(0, 0.08, 0))
		im.surface_set_color(guide_c)
		im.surface_add_vertex(pts[i] + Vector3(0, 0.08, 0))
	im.surface_end()
