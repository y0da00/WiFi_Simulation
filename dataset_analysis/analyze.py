import pandas as pd
import numpy as np
import os 
from collections import defaultdict
import json
import re

def wkt_to_points(s):
    return re.sub(r'POLYGON\s*\(\(|\)\)', '', s).strip()

print()
if os.path.exists("../Swiss_Buildings_Data/data.parquet"):
    dataset = pd.read_parquet("../Swiss_Buildings_Data/data.parquet")
    print("loaded from parquet")
else:
    dataset = pd.read_csv("../Swiss_Buildings_Data/geometries.csv.zip")
    dataset.to_parquet("../Swiss_Buildings_Data/data.parquet")
    print("loaded from")
#dataset = pd.read_csv('../Swiss_Buildings_Data/geometries.csv.zip')
walls = dataset[dataset['entity_subtype'] == 'WALL'].fillna({'elevation': 0, 'height': 0})
apartments_walls = walls.groupby(walls['apartment_id'].astype(str))
print(dataset['entity_subtype'].value_counts())
print(dataset['entity_type'].value_counts())
if not os.path.exists("../godot_sim/draw.json"):
    open("../godot_sim/draw.json",'x')

for k, g in apartments_walls:
    temp = [[wkt_to_points(p), float(e), float(h)] for p, e, h in zip(g['geometry'], g['elevation'], g['height'])]
    with open("../godot_sim/draw.json", "w") as f:
        json.dump(temp, f)
    input()


