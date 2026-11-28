extends RefCounted
## Sensors: turns what an agent can perceive into the list of numbers (the
## "observation") that goes into the neural network.
##
## A network only understands a fixed-length list of numbers, roughly between -1 and 1.
## This file builds that list from small independent SENSORS. Each sensor adds its own
## block of numbers; the blocks are glued together in a fixed order:
##
##   block            numbers  what they mean
##   VisionSensor     16       "vision": rays around the agent; for each ray
##                             1 - distance / vision_range to the first wall/obstacle it
##                             hits (0 = nothing within range, 1 = touching it)
##   RouteSensor      7        the hint from route_guide.gd: unit direction to the next
##                             route point (2: right, forward), its distance (1), unit
##                             direction to the point after it (2), walking distance left
##                             to the target (1), 1 if the next point is the start of a
##                             staircase (1)
##   SelfSensor       4        own velocity (2: right, forward, as a fraction of walk_speed),
##                             1 while walking a staircase (1), own walk_speed / 1.4 (1)
##   total            27
##
## All directions are measured in the agent's OWN frame ("x = to my right, z = in front
## of me"), not the world's. That way "wall on my left" always looks the same to the
## network, whichever way the agent faces, and what it learned in one corridor works in
## every corridor and every building.
##
## EXTENSION POINT: to give the agents more senses later, write a new sensor class here
## (with size() and read()) and add it to the list in _init(). Examples:
##   - OtherAgentsSensor: the nearest few agents (relative position, velocity), or put the
##     agents on the rays' collision mask so the vision rays also see people;
##   - a vision cone (vision_fov_deg < 360) for "they can only see in front of them";
##   - smoke / exit-sign sensors.
## Adding or removing numbers changes the network's input size, so retrain afterwards
## (the trained model stores obs_size and mlp_policy.gd checks it).

## Physics layer of the building (walls, floors...). See ml_world.gd.
const WORLD_LAYER := 1
## Physics layer the agents' bodies are on. Not seen by the rays yet (see header).
const AGENT_LAYER := 2


## Base class: every sensor says how many numbers it gives and fills them in.
class Sensor:
	func size(_agent) -> int:
		return 0
	func read(_agent, _out: PackedFloat32Array) -> void:
		pass


## Vision rays: `vision_rays` horizontal rays spread over vision_fov_deg, starting at
## vision_height above the feet. Ray 0 points straight ahead, then they go round
## clockwise seen from above (to the right first). The hit points are also stored in
## agent.ray_hits so ml_agent.gd can draw them.
class VisionSensor extends Sensor:
	var _q: PhysicsRayQueryParameters3D = null   ## one ray query object, re-used for every ray
	var _angles := PackedFloat32Array()          ## angle of each ray (radians), worked out once
	var _for_rays := -1                          ## the ray count / FOV the angles were made for
	var _for_fov := -1.0

	func size(agent) -> int:
		return agent.traits.vision_rays

	## Angle of ray i: spread evenly over the field of view. With 360 degrees the last ray
	## must not lie on top of the first, so the step is fov / rays; with a narrower view
	## the outer rays sit exactly on the edges, so the step is fov / (rays - 1).
	func _make_angles(t) -> void:
		_angles.resize(t.vision_rays)
		var span: float = deg_to_rad(t.vision_fov_deg)
		var full: bool = t.vision_fov_deg >= 360.0
		var step: float = span / (t.vision_rays if full else max(t.vision_rays - 1, 1))
		for i in t.vision_rays:
			_angles[i] = step * i if full else -span / 2.0 + step * i
		_for_rays = t.vision_rays
		_for_fov = t.vision_fov_deg

	func read(agent, out: PackedFloat32Array) -> void:
		var t = agent.traits
		if _q == null:
			_q = PhysicsRayQueryParameters3D.new()
			_q.collision_mask = WORLD_LAYER   # later: WORLD_LAYER | AGENT_LAYER to see people
			_q.exclude = [agent.get_rid()]    # never "see" yourself (also needed once agents are on the mask)
		if _for_rays != t.vision_rays or _for_fov != t.vision_fov_deg:
			_make_angles(t)   # traits changed (or first call)
		var space: PhysicsDirectSpaceState3D = agent.get_world_3d().direct_space_state
		var origin: Vector3 = agent.global_position + Vector3(0, t.vision_height, 0)
		var fwd: Vector3 = agent.forward()
		var rng_m: float = t.vision_range
		agent.ray_hits.resize(t.vision_rays)
		_q.from = origin
		for i in t.vision_rays:
			var dir: Vector3 = fwd.rotated(Vector3.UP, -_angles[i])   # negative = clockwise from above = to the right
			_q.to = origin + dir * rng_m
			var hit := space.intersect_ray(_q)
			var d: float = rng_m
			if not hit.is_empty():
				d = origin.distance_to(hit.position)
			agent.ray_hits[i] = origin + dir * d
			out.append(1.0 - d / rng_m)


## The route hint (see route_guide.gd).
class RouteSensor extends Sensor:
	func size(_agent) -> int:
		return 7
	func read(agent, out: PackedFloat32Array) -> void:
		var g = agent.guide
		var p: Vector3 = agent.global_position
		var a: Vector2 = agent.to_local_flat(g.next_point() - p)
		var b: Vector2 = agent.to_local_flat(g.point_after() - p)
		var an := a.normalized() if a.length() > 0.01 else Vector2.ZERO
		var bn := b.normalized() if b.length() > 0.01 else Vector2.ZERO
		out.append(an.x); out.append(an.y)
		out.append(clampf(a.length() / 5.0, 0.0, 1.0))
		out.append(bn.x); out.append(bn.y)
		out.append(clampf(agent.remaining_distance() / 50.0, 0.0, 1.0))
		out.append(1.0 if g.next_is_stairs() else 0.0)


## The agent's own state.
class SelfSensor extends Sensor:
	func size(_agent) -> int:
		return 4
	func read(agent, out: PackedFloat32Array) -> void:
		var v: Vector2 = agent.to_local_flat(agent.velocity) / agent.traits.walk_speed
		out.append(clampf(v.x, -1.5, 1.5)); out.append(clampf(v.y, -1.5, 1.5))
		out.append(1.0 if agent.on_stairs else 0.0)
		out.append(agent.traits.walk_speed / 1.4)


var sensors: Array = []


## Lists the sensors that make up the observation.
func _init() -> void:
	# the ORDER here is the order of the numbers in the observation (must match training)
	sensors = [VisionSensor.new(), RouteSensor.new(), SelfSensor.new()]


## Total number of observation numbers for this agent.
func size(agent) -> int:
	var n := 0
	for s in sensors:
		n += s.size(agent)
	return n


## Builds the full observation of `agent`.
func observe(agent) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for s in sensors:
		s.read(agent, out)
	return out
