"""Writes extra buildings for ML training (does NOT touch the game's draw.json).

Why: the agent should learn to walk in *any* building, not memorise one. So training
uses several buildings from the Swiss Dwellings dataset. This script re-uses the code
in dataset_analysis/analyze.py (the same functions that make draw.json) and writes
each building to godot-sim-4/ml/buildings/<building_id>.json (same format as draw.json).

Run it with the project's normal venv (it has pandas/shapely), from anywhere:
    ~/WiFi_Simulation/.venv/bin/python ~/WiFi_Simulation/ml/make_buildings.py 320 249 172
With no ids it picks buildings automatically: 3..6 floors with STAIRS on at least 2 floors.
    ... make_buildings.py --eval      picks 4 OTHER buildings into ml/buildings_eval/
                                      (never used for training: tests on unseen buildings)
"""
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(REPO, "dataset_analysis"))
import analyze as A  # noqa: E402  (only functions are imported, the main loop is under __main__)

OUT = os.path.join(REPO, "godot_sim_updated", "godot-sim-4", "ml", "buildings")
AUTO_COUNT = 8   # how many automatic picks when no ids are given


def main():
    global OUT
    eval_mode = "--eval" in sys.argv
    if eval_mode:
        sys.argv.remove("--eval")
        OUT = os.path.join(os.path.dirname(OUT), "buildings_eval")
    os.makedirs(OUT, exist_ok=True)
    data = A.load_rows(os.path.join(REPO, "Swiss_Buildings_Data"))   # only the needed rows/columns
    buildings = A.group_buildings(data)   # building_id -> [{"id": apartment_id, "idx": rows}]

    ids = [int(x) for x in sys.argv[1:]]
    if not ids:
        # automatic pick: 3..6 floors and stairs on >= 2 floors, small enough to bake fast
        # (counts only STAIRS, not RAMP, on purpose: keeps the same picks as before)
        st = data[data.entity_subtype == "STAIRS"].groupby("building_id").floor_id.nunique()
        fl = data.groupby("building_id").floor_id.nunique()
        n = data.groupby("building_id").size()
        ok = [b for b in st.index if st[b] >= 2 and 3 <= fl[b] <= 6 and n[b] < 4000]
        rng = np.random.default_rng(7)
        train_ids = [int(b) for b in rng.choice(ok, size=min(AUTO_COUNT, len(ok)), replace=False)]
        ids = train_ids
        if eval_mode:   # different buildings than the training picks (and than 172/249/320)
            rest = [b for b in ok if int(b) not in train_ids + [172, 249, 320]]
            ids = [int(b) for b in np.random.default_rng(99).choice(rest, size=4, replace=False)]
    for bid in ids:
        b = A.build_building(bid, buildings[bid], data)   # exactly what analyze.py writes to draw.json
        with open(os.path.join(OUT, f"{bid}.json"), "w") as f:
            json.dump(b, f, separators=(",", ":"))
        print(f"building {bid}: {len(b['apartments'])} apartments -> {os.path.relpath(OUT, os.path.dirname(OUT))}/{bid}.json", flush=True)


if __name__ == "__main__":
    main()
