import pandas as pd
import numpy as np
from collections import defaultdict


dataset = pd.read_csv('../Swiss_Buildings_Data/geometries.csv.zip')
types = defaultdict(int)
buildings = defaultdict(list)
apartaments = defaultdict(int)
for x in dataset.itertuples(index=False):
    types[str(x.entity_subtype)] += 1
    buildings[str(x.building_id)].append(str(x.apartment_id))

print(len(buildings))
for y,apts in buildings.items():
    #print(y ,len(apts))
    for z in apts:
        apartaments[z] += 1
print(len(apartaments))
for k in apartaments.keys():
    print(k + " " + str(apartaments[k]))
    break