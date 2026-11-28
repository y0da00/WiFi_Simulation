"""Exports the policy network of a trained PPO model to JSON for Godot.

Godot (normal, non-.NET build) can't run .onnx files, so the weights are written as
plain numbers and godot-sim-4/ml/mlp_policy.gd does the maths. Only the policy part
is exported: observation -> 64 tanh -> 64 tanh -> 2 (the action mean). The script
checks that its own numpy re-implementation gives the same actions as SB3's
model.predict(deterministic=True) before writing the file.

Usage:  ml/.venv/bin/python ml/export_policy.py ml/runs/<run>/model.zip [out.json]
"""
import json
import os
import sys

import numpy as np
import torch
from stable_baselines3 import PPO

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUT = os.path.join(os.path.dirname(HERE), "godot_sim_updated", "godot-sim-4", "ml", "models", "ml_agent_policy.json")


def export(model_zip, out_json=DEFAULT_OUT):
    """Writes the policy layers of model_zip as JSON: {"obs_size", "act_size", "layers":
    [{"w": rows of weights (out x in), "b": biases, "act": "tanh" or "linear"}, ...]}."""
    model = PPO.load(model_zip, device="cpu")
    pol = model.policy
    layers = []
    # mlp_extractor.policy_net = [Linear, Tanh, Linear, Tanh]; action_net = Linear (the mean)
    mods = list(pol.mlp_extractor.policy_net) + [pol.action_net]
    for i, m in enumerate(mods):
        if isinstance(m, torch.nn.Linear):
            # a Linear layer followed by a Tanh module -> "tanh", the last one -> "linear"
            act = "tanh" if i + 1 < len(mods) and isinstance(mods[i + 1], torch.nn.Tanh) else "linear"
            # round(7): 7 decimals is plenty for float32 and keeps the file small
            layers.append({"w": m.weight.detach().numpy().astype(float).round(7).tolist(),
                           "b": m.bias.detach().numpy().astype(float).round(7).tolist(), "act": act})
    obs_size = int(np.prod(model.observation_space["obs"].shape))
    data = {"obs_size": obs_size, "act_size": int(layers[-1]["b"].__len__()), "layers": layers,
            "source": os.path.abspath(model_zip), "timesteps": int(model.num_timesteps)}

    # self-check against SB3 on random observations
    def forward(x):   # what mlp_policy.gd does: x = act(W x + b) per layer, then clip to -1..1
        for l in layers:
            x = np.asarray(l["w"]) @ x + np.asarray(l["b"])
            if l["act"] == "tanh":
                x = np.tanh(x)
        return np.clip(x, -1, 1)
    rng = np.random.default_rng(0)
    worst = 0.0
    for _ in range(50):
        o = rng.uniform(-1, 1, obs_size).astype(np.float32)
        # deterministic=True: the action mean without the random exploration noise
        a, _ = model.predict({"obs": o}, deterministic=True)
        worst = max(worst, float(np.abs(forward(o) - a).max()))
    assert worst < 1e-4, f"export mismatch {worst}"   # stop before writing a wrong file
    os.makedirs(os.path.dirname(out_json), exist_ok=True)
    with open(out_json, "w") as f:
        json.dump(data, f)
    print(f"exported {model_zip} -> {out_json} (max diff vs SB3 {worst:.2e})")


if __name__ == "__main__":
    export(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else DEFAULT_OUT)
