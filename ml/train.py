"""Trains the ML evacuation agent with PPO (Stable-Baselines3) through Godot RL Agents.

How the pieces fit together
---------------------------
* This script is the "teacher". It starts N copies of the Godot simulation in the
  background (headless, sped up), through the wrapper godot_env.x86_64.
* Each copy runs ml/train_env.tscn: one building, A agents (default 16) walking to
  random targets. Every 6 physics frames (10x per second of game time) every agent
  sends Python its observation (27 numbers: vision rays, route hint, own velocity - see
  godot-sim-4/ml/sensors.gd) and the reward it collected (see ml_controller.gd).
* PPO (Proximal Policy Optimization) runs a neural network on all those observations,
  sends back an action per agent (2 numbers: desired velocity right/forwards), and
  every `n_steps` decisions it updates the network so that actions which led to more
  reward than expected become more likely. That loop repeats until total_timesteps.
* Two networks are trained: the "policy" (observation -> action, this is the brain we
  keep) and the "value" network (observation -> expected future reward, only needed
  to judge actions during training).
* At the end the policy is exported to godot-sim-4/ml/models/ml_agent_policy.json
  (export_policy.py), which ml/mlp_policy.gd runs inside the game.

Usage (from ~/WiFi_Simulation, fish or bash):
    ml/.venv/bin/python ml/train.py                      # default: 8M steps, 10 Godot copies x 24 agents (~11 min on mains power; about twice as long on battery)
    ml/.venv/bin/python ml/train.py --timesteps 500000   # short run
    ml/.venv/bin/python ml/train.py --resume ml/runs/<run>/model.zip
Watch the curves:  ml/.venv/bin/tensorboard --logdir ml/runs
"""
import argparse
import os
import time

import torch
from stable_baselines3 import PPO
from stable_baselines3.common.callbacks import CheckpointCallback
from stable_baselines3.common.logger import configure
from stable_baselines3.common.vec_env import VecMonitor

from godot_rl.wrappers.stable_baselines_wrapper import StableBaselinesGodotEnv

HERE = os.path.dirname(os.path.abspath(__file__))
ENV_PATH = os.path.join(HERE, "godot_env.x86_64")
MODEL_JSON = os.path.join(os.path.dirname(HERE), "godot_sim_updated", "godot-sim-4", "ml", "models", "ml_agent_policy.json")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--timesteps", type=float, default=8e6, help="total agent decisions to train for")
    ap.add_argument("--n_parallel", type=int, default=10, help="Godot copies (each one building)")
    ap.add_argument("--agents", type=int, default=24, help="agents per Godot copy")
    ap.add_argument("--speedup", type=int, default=40, help="game-time speed-up of each copy")
    ap.add_argument("--resume", default=None, help="continue from a saved model.zip")
    ap.add_argument("--run_name", default=time.strftime("ppo_%Y%m%d_%H%M%S"))
    ap.add_argument("--port", type=int, default=11008)
    args = ap.parse_args()

    torch.set_num_threads(4)   # leave the other CPU cores to the Godot copies
    run_dir = os.path.join(HERE, "runs", args.run_name)
    os.makedirs(run_dir, exist_ok=True)

    # N Godot copies, each started as:  godot_env.x86_64 --port=P --env_seed=i --headless
    #   --speedup=S --action_repeat=6 --agents=A   (env_seed i picks the building)
    env = StableBaselinesGodotEnv(
        env_path=ENV_PATH, n_parallel=args.n_parallel, seed=0, port=args.port,
        show_window=False, speedup=args.speedup, action_repeat=6, agents=args.agents)
    # action_repeat must equal MLAgent.DECISION_FRAMES in ml_agent.gd (train_env.gd checks it)
    env = VecMonitor(env)   # records episode rewards/lengths for the logs
    print(f"{env.num_envs} agents in total, observation {env.observation_space}, action {env.action_space}")

    if args.resume:
        model = PPO.load(args.resume, env=env, device="cpu")
    else:
        model = PPO(
            "MultiInputPolicy", env,   # the observation is a dict {"obs": [...]} -> MultiInput
            n_steps=128,               # decisions per agent before each update (240 agents x 128 = 30720)
            batch_size=2048,           # minibatch size for the gradient steps
            n_epochs=8,                # passes over each batch of experience
            gamma=0.99,                # how much future reward counts (0.99 ~ the next 10 s)
            gae_lambda=0.95,           # how far to trust the value net vs. real rewards when judging an action
            learning_rate=3e-4,        # step size of the network updates
            clip_range=0.2,            # PPO: don't change the policy too much in one update
            ent_coef=0.001,            # small bonus for keeping some randomness (exploration)
            policy_kwargs=dict(net_arch=dict(pi=[64, 64], vf=[64, 64]), activation_fn=torch.nn.Tanh),
            verbose=1, device="cpu")   # (no seed=: the Godot copies are seeded by env_seed)
    model.set_logger(configure(run_dir, ["stdout", "csv", "tensorboard"]))   # progress.csv = reward curve
    ckpt = CheckpointCallback(save_freq=max(200_000 // env.num_envs, 1), save_path=run_dir, name_prefix="ckpt")
    t0 = time.time()
    try:
        model.learn(total_timesteps=int(args.timesteps), callback=ckpt, reset_num_timesteps=not args.resume)
    except KeyboardInterrupt:
        print("stopped by hand, saving what we have")
    model.save(os.path.join(run_dir, "model.zip"))
    print(f"training time {(time.time() - t0) / 60:.1f} min, model in {run_dir}/model.zip")
    env.close()

    # write the policy as JSON for the game (ml/mlp_policy.gd); this file sits next to train.py
    from export_policy import export
    export(os.path.join(run_dir, "model.zip"), MODEL_JSON)


if __name__ == "__main__":
    main()
