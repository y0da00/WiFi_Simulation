# ML evacuation agent (basic version: one agent)

The green agent in the simulation walks with a small neural network that was trained
with reinforcement learning (PPO). The old scripted agent (red, `path_agent.gd`) still
works and you can race them (key **M**).

## What is where

| File | What it does |
|---|---|
| `godot-sim-4/ml/ml_agent.gd` | the agent: a physical body (CharacterBody3D), runs the network on floors, walks the stair line on stairs |
| `godot-sim-4/ml/agent_traits.gd` | per-agent settings: speed, size, vision, and the future ones (route_knowledge, fall_chance) |
| `godot-sim-4/ml/sensors.gd` | builds the network input (27 numbers) from separate sensors: vision rays, route hint, own state |
| `godot-sim-4/ml/route_guide.gd` | the agent's sense of direction: next point of the navmesh route (incl. stairs) |
| `godot-sim-4/ml/mlp_policy.gd` | runs the trained network in GDScript (loads `ml/models/ml_agent_policy.json`) |
| `godot-sim-4/ml/ml_world.gd` | switches on collision for the building, picks start points / the exit |
| `godot-sim-4/ml/ml_controller.gd` | training only: the reward, and the link to Python (Godot RL Agents) |
| `godot-sim-4/ml/train_env.gd/.tscn` | training only: the scene Python starts (one building, many agents) |
| `godot-sim-4/ml/buildings/*.json` | 10 buildings used for training (same format as draw.json) |
| `godot-sim-4/addons/godot_rl_agents/` | Godot RL Agents plugin (the Sync node that talks to Python) |
| `ml/train.py` | trains (PPO, Stable-Baselines3), then exports the model |
| `ml/export_policy.py` | trained model.zip -> JSON for Godot |
| `ml/make_buildings.py` | writes more training buildings from the dataset (doesn't touch draw.json) |
| `ml/godot_env.x86_64` | small script that starts Godot headless for training |
| `ml/runs/<run>/` | training logs (`progress.csv` = reward curve, TensorBoard files), `model.zip` |

## How it works (short)

* **Observation (input, 27 numbers):** 16 vision rays all around (how close is the wall
  in each direction), the direction and distance of the next route point and the point
  after it, how far the target still is, "a staircase starts at the next point", own
  velocity, "I'm on stairs", own walk speed. All directions are in the agent's own frame
  (right / forwards), so it works the same in any corridor of any building.
* **Action (output, 2 numbers):** the velocity the agent wants: to the right and
  forwards, each -1..1 times walk_speed. The body accelerates towards it, turns to face
  where it walks, and the physics engine stops it at walls.
* **Stairs (hybrid):** the network steers on floors and walks to the staircase; on the
  stairs the agent follows the stair line (like the scripted agent), then the network
  takes over again.
* **Reward:** +1 per metre closer to the target (along the route; per frame at most
  what the agent can really walk, so jumps of the route hint don't pay), -0.2 per second,
  -0.6 per second touching a wall, +10 at the target, -10 for falling. Running out of
  time is sent to PPO as a time-out (truncation), not as a real ending.
* **Training:** 10 Godot copies (one per building) x 24 agents = 240 agents walking to
  random targets at the same time (half of the targets on another floor), random walk
  speeds 1.0-1.8 m/s, 40x faster than real time.

## Run it in the game

Open the project, press F5, then:
* **M** - ML demo: green ML agent + red scripted agent start on the top floor and go to the exit
* **Ctrl + right-click** - send the ML agent somewhere (any floor)
* **V** - show / hide the vision rays (green = free, red = wall close) and the route hint (blue)
* G, right-click, Shift + right-click - the old scripted agent as before

## Tests (headless)

```
cd ~/WiFi_Simulation/godot_sim_updated/godot-sim-4
godot --headless --fixed-fps 60 --path . -s res://tests/test_ml_agent.gd                 # 30 evacuations, ML vs scripted
godot --headless --fixed-fps 60 --path . -s res://tests/test_ml_agent.gd -- --building=320 --trips=30
godot --headless --fixed-fps 60 --path . -s res://tests/test_ml_env.gd                   # environment check without the network
```

## Retrain

```
cd ~/WiFi_Simulation
ml/.venv/bin/python ml/train.py                            # 8M steps, ~12 min on the MSI
ml/.venv/bin/python ml/train.py --timesteps 2e6            # shorter
ml/.venv/bin/python ml/train.py --resume ml/runs/ppo_main/model.zip --timesteps 2e6   # continue
ml/.venv/bin/tensorboard --logdir ml/runs                  # curves in the browser
```
At the end it writes `godot-sim-4/ml/models/ml_agent_policy.json`, which the game loads.
The venv (`ml/.venv`, Python 3.12) has torch (CPU), stable-baselines3, godot-rl. To make
it again: `uv venv --python 3.12 ml/.venv && uv pip install --python ml/.venv/bin/python --index-url https://download.pytorch.org/whl/cpu torch && uv pip install --python ml/.venv/bin/python godot-rl==0.8.2 onnx`

More training buildings: `.venv/bin/python ml/make_buildings.py <building_id> ...`
(the project's normal venv; writes to `godot-sim-4/ml/buildings/`).

## Adding the planned features later

| Feature | Where |
|---|---|
| many agents | spawn more `ml_agent.gd` nodes (each with its own traits); training already runs 24 per scene |
| can't walk through each other | `ml_agent.gd` `_ready()`: `collision_mask = WORLD_LAYER \| AGENT_LAYER`; add a reward penalty in `ml_controller.gd`; retrain with agents on the same floors |
| seeing other agents / vision cone | new sensor class in `sensors.gd` (or add `AGENT_LAYER` to the rays' mask); `vision_fov_deg` in traits; retrain |
| slower / faster people | `traits.walk_speed`, `stair_speed` (the network already knows its own speed and was trained with 1.0-1.8 m/s) |
| knowing the way better or worse | `traits.route_knowledge` -> change what `route_guide.gd` hands out (noisy / partial hint); retrain |
| falling over | `traits.fall_chance`, `get_up_time` -> a "fallen" state in `ml_agent.gd` (stop, obstacle for others) |

Changing the number of input numbers (new sensors, more rays) needs a retrain; the game
refuses a model whose input size doesn't match.

## Results of the trained model (run `ml/runs/ppo_v3`, 17.11.2026)

Retrained after the code review (reward clamp + time-out fix). Training: 8.0M decisions,
21.3 min (the MSI was on battery, ~6,000 decisions/s; on mains power the same run took
~10 min at ~13,000/s). Success rate 0.14 -> 0.88 -> 0.99 in the first 340k decisions,
then 1.00; mean episode reward ~25-26.

`tests/test_ml_agent.gd`, 30 evacuations per building from random floors to the exit:

| building | ML success | ML time vs scripted | ML wall bumps / trip (ppo_v2 before) | hand-written baseline bumps |
|---|---|---|---|---|
| 172 (current draw.json, trained on) | 30/30 | 1.01x | 4.0 (7.1) | 9.7 |
| 320 (trained on) | 30/30 | 1.04x | 3.9 (6.7) | 16.9 |
| 2331 (never seen) | 30/30 | 0.99x | 5.7 (7.1) | 13.1 |
| 5499 (never seen) | 30/30 | 1.03x | 4.1 (3.6) | 6.2 |
| 2143 (never seen) | 30/30 | 1.01x | 5.2 (3.9) | 6.5 |
| 17074 (never seen) | 30/30 | 1.01x | 2.9 (4.0) | 5.0 |

The start points come from the navmesh's random points, so each run tests slightly
different trips.

## Speed (tests/bench_ml.gd)

`godot --headless --fixed-fps 60 --path . -s res://tests/bench_ml.gd -- --agents=100`
prints the cost of one network decision, one observation, one route plan and the
frame time with N agents. After the review/optimisation pass (same MSI, same session):
network decision 250 us -> 33 us (4x4 Projection blocks, see mlp_policy.gd), frame time
with 100 agents 11.3 -> 8.1-8.5 ms, with 300 agents 30.9 -> 22.1 ms (worst frame 128 -> 61 ms).
