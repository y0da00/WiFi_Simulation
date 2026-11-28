import argparse
import os
import time
import torch
from godot_rl.core.godot_env import GodotEnv
from godot_rl.wrappers.stable_baselines_wrapper import StableBaselinesGodotEnv
from stable_baselines3 import PPO
from stable_baselines3.common.callbacks import BaseCallback, CallbackList, CheckpointCallback

HERE = os.path.dirname(os.path.abspath(__file__))

parser = argparse.ArgumentParser()
parser.add_argument("--model", default=os.path.expanduser("~/Desktop/trained_agent.zip"))
parser.add_argument("--save", default=os.path.expanduser("~/Desktop/trained_agent_building.zip"))
parser.add_argument("--steps", type=int, default=2_000_000)
parser.add_argument("--envs", type=int, default=16)
parser.add_argument("--watch", type=int, default=1)
parser.add_argument("--floor", type=int, default=0)
parser.add_argument("--fresh", action="store_true")
parser.add_argument("--minutes", type=float, default=None)
parser.add_argument("--port", type=int, default=GodotEnv.DEFAULT_PORT)
parser.add_argument("--checkpoint-dir", default=os.path.expanduser("~/Desktop/rl_checkpoints"))
args = parser.parse_args()

PORT = args.port

_launch = GodotEnv._launch_env


def _launch_some_visible(self, env_path, port, show_window, *a, **kw):
    return _launch(self, env_path, port, port < PORT + args.watch, *a, **kw)


GodotEnv._launch_env = _launch_some_visible


class TimeLimitCallback(BaseCallback):
    def __init__(self, minutes, verbose=0):
        super().__init__(verbose)
        self.limit = None if minutes is None or minutes <= 0 else minutes * 60.0
        self._start = None

    def _on_training_start(self):
        self._start = time.monotonic()

    def _on_step(self):
        if self.limit is None:
            return True
        if (time.monotonic() - self._start) >= self.limit:
            print(f"Time limit of {self.limit / 60.0:.1f} minutes reached, stopping.")
            return False
        return True


if __name__ == "__main__":
    torch.set_num_threads(4)
    torch.backends.cudnn.benchmark = True
    device = "cuda" if torch.cuda.is_available() else "cpu"
    env = StableBaselinesGodotEnv(env_path=os.path.join(HERE, "godot_env.x86_64"), show_window=False, speedup=40, n_parallel=args.envs, port=PORT, floor=args.floor)
    if args.fresh:
        model = PPO("MultiInputPolicy", env, verbose=1, learning_rate=3e-4, n_steps=512, batch_size=1024, n_epochs=10, tensorboard_log=os.path.expanduser("~/Desktop/logs/"), device=device)
    elif os.path.exists(args.save):
        model = PPO.load(args.save, env=env, device=device, tensorboard_log=os.path.expanduser("~/Desktop/logs/"))
        print(f"Continuing from {args.save}")
    elif os.path.exists(args.model):
        model = PPO.load(args.model, env=env, device=device, tensorboard_log=os.path.expanduser("~/Desktop/logs/"))
        print(f"Continuing from {args.model}")
    else:
        model = PPO("MultiInputPolicy", env, verbose=1, learning_rate=3e-4, n_steps=512, batch_size=1024, n_epochs=10, tensorboard_log=os.path.expanduser("~/Desktop/logs/"), device=device)
    os.makedirs(args.checkpoint_dir, exist_ok=True)
    callbacks = [
        CheckpointCallback(save_freq=max(100_000 // args.envs, 1), save_path=args.checkpoint_dir, name_prefix="rl_building"),
    ]
    if args.minutes is not None and args.minutes > 0:
        callbacks.append(TimeLimitCallback(args.minutes))
        if args.steps == 2_000_000:
            args.steps = 100_000_000
    print("Starting training in the WiFi building...")
    try:
        model.learn(total_timesteps=args.steps, reset_num_timesteps=False, tb_log_name="PPO_building", callback=CallbackList(callbacks))
    except KeyboardInterrupt:
        print("Interrupted, saving...")
    finally:
        model.save(args.save)
        env.close()
        print(f"Saved to {args.save}")
