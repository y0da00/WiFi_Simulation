extends Resource
## AgentTraits: the "personality" and body of ONE agent, kept in one place.
##
## Every ML agent (ml_agent.gd) owns one of these. Today all agents use the defaults
## below, except that training gives each episode a random walk_speed (so the trained
## brain already copes with slower and faster people).
##
## WHY a separate resource: the planned features are all per-agent differences, so they
## become new fields here instead of changes all over the code:
##   - some people slower          -> walk_speed / stair_speed (already used everywhere)
##   - some know the way better    -> route_knowledge (read by route_guide.gd; at 1.0 the
##                                    agent gets the exact navmesh route, see the TODO there)
##   - falling over                -> fall_chance / get_up_time (not used yet)
##   - vision                      -> vision_range / vision_rays / vision_fov_deg
##                                    (read by sensors.gd)
##   - not walking through others  -> radius (the collision capsule; see ml_agent.gd)
## Make one in code with  AgentTraits.new()  or in the editor (New Resource -> this script)
## and save it as a .tres file to make "types" of people.
##
## IMPORTANT: the brain (neural network) was trained with a fixed number of inputs.
## Changing vision_rays or vision_fov_deg changes what the network sees, so it must be
## retrained afterwards (see ~/WiFi_Simulation/ml/README.md). Speeds and route_knowledge
## can be changed freely.

@export_group("Body")
@export var radius := 0.25          ## m, collision capsule radius (same as the navmesh agent_radius)
@export var height := 1.7           ## m, capsule height
@export var walk_speed := 1.4       ## m/s, top speed on a floor (the network's "full throttle")
@export var stair_speed := 0.7      ## m/s along the slope while walking a staircase
@export var acceleration := 4.0     ## m/s^2, how fast the agent can change its velocity
@export var turn_speed_deg := 360.0 ## degrees per second the body can turn

@export_group("Senses")
@export var vision_rays := 16       ## number of "vision" rays (fixed by the trained network!)
@export var vision_fov_deg := 360.0 ## field of view of the rays (fixed by the trained network!)
@export var vision_range := 6.0     ## m, how far the rays reach
@export var vision_height := 0.6    ## m above the feet: low enough to see railings

@export_group("Future features (not used yet)")
@export_range(0.0, 1.0) var route_knowledge := 1.0  ## 1 = knows the exact way out, 0 = knows nothing
@export_range(0.0, 1.0) var fall_chance := 0.0      ## chance per second of falling over
@export var get_up_time := 3.0                      ## s spent on the floor after a fall
