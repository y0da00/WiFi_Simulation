import argparse
import os
from godot_rl.wrappers.stable_baselines_wrapper import StableBaselinesGodotEnv
from stable_baselines3 import PPO

HERE = os.path.dirname(os.path.abspath(__file__))

parser = argparse.ArgumentParser()
parser.add_argument("--model", default=os.path.expanduser("~/Desktop/trained_agent.zip"))
parser.add_argument("--floor", type=int, default=0)
parser.add_argument("--steps", type=int, default=0)
parser.add_argument("--speedup", type=float, default=1)
parser.add_argument("--headless", action="store_true")
args = parser.parse_args()

env = StableBaselinesGodotEnv(env_path=os.path.join(HERE, "godot_env.x86_64"), show_window=not args.headless, speedup=args.speedup, n_parallel=1, floor=args.floor)
model = PPO.load(args.model, env=env, device="cpu")
obs = env.reset()
step = 0
goals = 0
episodes = 0
try:
    while args.steps == 0 or step < args.steps:
        action, _ = model.predict(obs, deterministic=True)
        obs, reward, done, info = env.step(action)
        step += 1
        if done[0]:
            episodes += 1
            if reward[0] > 5:
                goals += 1
            print(f"step {step}: episode {episodes} ended, goals reached {goals}")
        if args.steps and step % 10 == 0:
            print(step, info[0])
finally:
    env.close()
