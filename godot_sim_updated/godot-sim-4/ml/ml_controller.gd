extends "res://addons/godot_rl_agents/controller/ai_controller_3d.gd"
## MLController: connects ONE ml_agent.gd to the Python trainer (Godot RL Agents) and
## decides the REWARD - the score that teaches the network what "good walking" is.
##
## Only used for training (ml/train_env.gd puts one under every agent). In the game the
## agent drives itself with its loaded network and has no controller.
##
## How training talks to Godot (done by the addon's sync.gd, nothing to do here):
##   every 6 physics frames Sync collects get_obs(), get_reward(), get_done() and
##   get_info() from every controller, sends them to Python over a TCP socket, waits for
##   the next actions and hands each controller its action through set_action().
##
## The reward, added up every physics frame in _physics_process():
##   + 1.0 per metre the agent gets closer to the target along the route
##         (- 1.0 per metre it goes back), so walking the right way pays off at once.
##         Per frame it is clamped to what the agent can really walk (1.5 x walk_speed x
##         frame time): when the route hint moves on to its next point (or is re-planned)
##         the "distance left" can jump by up to ~1 m without the agent moving, and that
##         jump must not be paid out as progress.
##   - 0.2 per second, so that dawdling costs something (faster = better)
##   - 0.6 per second while touching a wall (walk in the middle, don't scrape along walls)
##   + 10  for reaching the target (episode ends, success)
##   - 10  for falling (e.g. into a stairwell; episode ends, failure)
##   time limit: 20 s + 2.5x the time the route needs at walk_speed (episode ends, failure).
##         This is reported to Python as a TIME-OUT ("TimeLimit.truncated" plus the last
##         observation), not as a real ending: PPO then still counts the reward the agent
##         would have got afterwards, instead of learning "time-outs are worth 0".
## When an episode ends, the agent stands still until the next decision, and the new
## episode (new start, target and speed, see train_env.gd new_episode()) starts exactly
## when Sync reads the next observation. So PPO sees the last step of the old episode
## with its final reward, and the very first frame of the new one.
##
## FUTURE: rewards for the planned features go here too, e.g. a penalty for bumping into
## other agents or for pushing someone over.

const PROGRESS_REWARD := 1.0      ## per metre of progress
const TIME_PENALTY := 0.2         ## per second
const WALL_PENALTY := 0.6         ## per second of wall contact
const GOAL_REWARD := 10.0
const FALL_PENALTY := 10.0

var agent      ## the ml_agent.gd this controller drives
var env        ## train_env.gd (starts new episodes)
var prev_remaining := 0.0   ## route distance left at the previous frame
var frames := 0             ## physics frames since the episode started
var max_frames := 0         ## time limit of this episode, in frames
var success := false        ## result of the episode that just ended (sent to Python as is_success)
var _ended := false         ## episode over, waiting for the next decision to start a new one
var _ended_ok := false
var _timed_out := false     ## the episode that just ended hit the time limit
var _last_obs := []         ## observation at the moment of the time-out (sent to Python)


## Called when the node enters the scene (the addon's AIController3D does its setup).
func _ready() -> void:
	super._ready()
	reset_after = 1 << 30   # the addon's own step limit is not used; this script has its own


## The observation (see sensors.gd), as a plain Array so it can be sent as JSON.
func get_obs() -> Dictionary:
	if _ended:   # Sync asks for the observation first, then reward/done: start the new episode now
		_ended = false
		env.new_episode(agent, self)
		success = _ended_ok   # get_info() (called right after) still reports the old episode
	return {"obs": Array(agent.observe())}


## Tells Python how many observation numbers there are (27 now), as one "box" (a list
## of real numbers).
func get_obs_space() -> Dictionary:
	return {"obs": {"size": [agent.sensors.size(agent)], "space": "box"}}


## 2 continuous numbers in -1..1: velocity to the right and forwards (see ml_agent.gd).
func get_action_space() -> Dictionary:
	return {"move": {"size": 2, "action_type": "continuous"}}


## Python sends the network's output here; the agent uses it until the next decision.
func set_action(a) -> void:
	agent.set_action(Vector2(a["move"][0], a["move"][1]))


## Reward collected since the last decision (the addon resets it to 0 after sending).
func get_reward() -> float:
	return reward


## Lets Stable-Baselines3 log the success rate (rollout/success_rate in TensorBoard).
func get_info() -> Dictionary:
	if not done:
		return {}
	if _timed_out:
		# Stable-Baselines3 reads these two keys: bootstrap the value from the last observation
		return {"is_success": false, "TimeLimit.truncated": true, "terminal_observation": {"obs": _last_obs}}
	return {"is_success": success}


## Called by train_env.gd after it placed the agent for a new episode.
func episode_started() -> void:
	prev_remaining = agent.remaining_distance()
	frames = 0
	max_frames = int((20.0 + 2.5 * prev_remaining / agent.traits.walk_speed) * 60.0)
	success = false


## Every physics frame: reset if Python asked; otherwise add up this frame's reward
## (progress, time, walls) and end the episode on arrival, fall or time limit.
func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if needs_reset:   # Python asked for a reset (start of training)
		_ended = false
		env.new_episode(agent, self)
		reset()
		return
	if _ended:
		return            # standing still, waiting for the next decision (see get_obs())
	if agent.has_arrived:
		_end(GOAL_REWARD, true)
		return
	if agent.has_fallen:
		_end(-FALL_PENALTY, false)
		return
	var rem: float = agent.remaining_distance()
	# progress since last frame; clamped because a re-plan can make the route jump a bit
	var max_step: float = 1.5 * agent.traits.walk_speed * delta   # most the agent can really walk in one frame
	reward += clampf(prev_remaining - rem, -max_step, max_step) * PROGRESS_REWARD
	prev_remaining = rem
	reward -= TIME_PENALTY * delta
	if agent.touching_wall and not agent.on_stairs:
		reward -= WALL_PENALTY * delta
	frames += 1
	if frames > max_frames:
		_last_obs = Array(agent.observe())   # the agent stands still from now on, so this IS the last state
		_end(0.0, false)
		_timed_out = true


## Ends the episode: final reward and done flag for Python. The agent stops; the new
## episode starts in get_obs() at the next decision.
func _end(final_reward: float, ok: bool) -> void:
	reward += final_reward
	done = true
	_timed_out = false
	_ended = true
	_ended_ok = ok
	success = ok
	agent.moving = false
