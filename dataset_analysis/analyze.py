import os
import json
from collections import defaultdict

import numpy as np
import pandas as pd
import shapely

SLAB = 0.15       
SNAP = 0.02        
OUTDOOR = {"BALCONY", "TERRACE", "PATIO", "GARDEN", "OUTDOOR_VOID", "LIGHTWELL"}   
OPENINGS = {"DOOR", "ENTRANCE_DOOR", "WINDOW"}
FEATURES = {"STAIRS", "RAMP", "ELEVATOR"}   



def union(geoms):
    geoms = list(geoms)
    return shapely.union_all(geoms) if geoms else shapely.Polygon()


def polys(geom):
    out = []
    for g in shapely.get_parts(geom):
        if g.geom_type in ("MultiPolygon", "GeometryCollection"):
            out += polys(g)
        elif g.geom_type == "Polygon":
            g = shapely.make_valid(g.simplify(0.0005))
            out += [p for p in shapely.get_parts(g) if p.geom_type == "Polygon" and p.area > 1e-4]
    return out


def ring(r):
    return [[round(x, 4), round(y, 4)] for x, y in list(r.coords)[:-1]]


def entries(geom, elevation, height):
    return [[ring(p.exterior), round(float(elevation), 4), round(float(height), 4),
             [ring(h) for h in p.interiors]] for p in polys(geom)]



def rect(c, u, length, width):
    v = np.array([-u[1], u[0]])
    return shapely.Polygon([c + u * a * length / 2 + v * b * width / 2
                            for a, b in ((-1, -1), (1, -1), (1, 1), (-1, 1))])


def opening_shapes(openings, walls):
    wall_union = {f: union(w.g) for f, w in walls.groupby("floor_id")}
    cuts, panels = [], []
    for g, floor_id in zip(openings.g, openings.floor_id):
        W = wall_union.get(floor_id, shapely.Polygon())
        c = np.asarray(shapely.minimum_rotated_rectangle(g).exterior.coords)[:4]
        centre = c.mean(axis=0)
        a, b = c[1] - c[0], c[2] - c[1]

        def score(side):
            u = side / np.linalg.norm(side)
            L = np.linalg.norm(side)
            ends = [shapely.Point(centre + s * u * (L / 2 + 0.03)).buffer(0.01) for s in (1, -1)]
            return (sum(W.intersects(e) for e in ends), L)

        along, across = (a, b) if score(a) >= score(b) else (b, a)
        u = along / np.linalg.norm(along)
        length, width = np.linalg.norm(along), np.linalg.norm(across)
        cuts.append(rect(centre, u, length, width + 0.6))
        panels.append(rect(centre, u, length, max(width * 0.3, 0.02)))
    openings = openings.copy()
    openings["cut"], openings["panel"] = cuts, panels
    return openings


def carve(walls, openings):
    out = []
    by_floor = {f: o for f, o in openings.groupby("floor_id")}
    for wg, we, wh, fl in zip(walls.g, walls.elevation, walls.height, walls.floor_id):
        ops = by_floor.get(fl, openings.iloc[:0])
        ops = ops[shapely.intersects(ops.cut.values, wg)]
        out += entries(wg.difference(union(ops.cut)), we, wh)
        for cut, oe, oh in zip(ops.cut, ops.elevation, ops.height):
            part = wg.intersection(cut)
            top = min(oe + oh, we + wh)
            if oe > we + 1e-3:
                out += entries(part, we, oe - we)           
            if we + wh > top + 1e-3:
                out += entries(part, top, we + wh - top)     
    return out



def floors_and_ceilings(rows, stairs_by_floor, floor_below):
    floors, ceilings = [], []
    for floor_id, r in rows.groupby("floor_id"):
        areas = r[r.entity_type == "area"]
        if areas.empty:
            continue
        base, top = areas.elevation.median(), areas.elevation.median() + areas.height.median()
        parts = r[r.entity_type.isin(["area", "separator", "opening"])]
        shape = union(parts.g).buffer(SNAP, join_style="mitre").buffer(-SNAP, join_style="mitre")
        indoor = parts[~parts.entity_subtype.isin(OUTDOOR | {"RAILING"})]
        ceil = union(indoor.g).buffer(SNAP, join_style="mitre").buffer(-SNAP, join_style="mitre")

        stairs_here = stairs_by_floor.get(floor_id, shapely.Polygon())
        stairs_below = stairs_by_floor.get(floor_below.get(floor_id), shapely.Polygon())
        floors += entries(shape.difference(stairs_below), base - SLAB, SLAB)
        ceilings += entries(ceil.difference(stairs_here), top, SLAB)
    return floors, ceilings



def build_apartment(apt_id, rows, openings, stairs_by_floor, floor_below):
    walls = rows[rows.entity_subtype.isin(["WALL", "COLUMN"])]
    own = openings[openings.apartment_id == apt_id]
    floors, ceilings = floors_and_ceilings(rows, stairs_by_floor, floor_below)

    def plain(df, col="g"):
        return [e for g, el, h in zip(df[col], df.elevation, df.height) for e in entries(g, el, h)]

    return {
        "apartment_id": apt_id,
        "walls": carve(walls, openings),
        "railings": plain(rows[rows.entity_subtype == "RAILING"]),
        "doors": plain(own[own.entity_subtype != "WINDOW"], "panel"),
        "windows": plain(own[own.entity_subtype == "WINDOW"], "panel"),
        "stairs_elevators": plain(rows[rows.entity_subtype.isin(FEATURES)]),
        "floors": floors,
        "ceilings": ceilings,
    }



if __name__ == "__main__":
    if os.path.exists("../Swiss_Buildings_Data/data.parquet"):
        dataset = pd.read_parquet("../Swiss_Buildings_Data/data.parquet")
    else:
        dataset = pd.read_csv("../Swiss_Buildings_Data/geometries.csv.zip")
        dataset.to_parquet("../Swiss_Buildings_Data/data.parquet")

    
    cols = ["apartment_id", "building_id", "floor_id", "entity_type", "entity_subtype",
            "geometry", "elevation", "height"]
    data = dataset.loc[dataset.entity_type.isin(["area", "separator", "opening"]) | dataset.entity_subtype.isin(FEATURES), cols].reset_index(drop=True)
    del dataset
    data = data.fillna({"elevation": 0, "height": 0, "apartment_id": "public"})

  
    buildings = defaultdict(list)
    for (building_id, apt_id), idx in data.groupby(["building_id", "apartment_id"]).indices.items():
        buildings[building_id].append({"id": apt_id, "idx": idx})
    building_ids = list(buildings)
    print(len(building_ids), "buildings")

    os.makedirs("../godot_sim", exist_ok=True)
    i = 0
    while i < len(building_ids):                                    
        building_id = building_ids[i]
        apartments = buildings[building_id]

        rows_b = data.iloc[np.concatenate([a["idx"] for a in apartments])].copy()
        rows_b["g"] = shapely.make_valid(shapely.from_wkt(rows_b.geometry.values))
        walls_b = rows_b[rows_b.entity_subtype.isin(["WALL", "COLUMN"])]
        openings = opening_shapes(rows_b[rows_b.entity_subtype.isin(OPENINGS)], walls_b)

        
        stairs_by_floor = {f: union(s.g) for f, s in rows_b[rows_b.entity_subtype == "STAIRS"].groupby("floor_id")}
        order = rows_b.groupby("floor_id").elevation.min().sort_values().index.tolist()
        floor_below = dict(zip(order[1:], order[:-1]))

        b = {"building_id": int(building_id), "apartments": []}
        for apt in apartments:                                       
            rows = rows_b[rows_b.apartment_id == apt["id"]]
            b["apartments"].append(build_apartment(apt["id"], rows, openings, stairs_by_floor, floor_below))

        with open("../godot_sim/draw.json", "w") as f:
            json.dump(b, f)
        print(f"building {i + 1}/{len(building_ids)} (id {building_id}): {len(apartments)} apartments written")

        cmd = input("Enter = next, number = go to building, q = quit: ").strip()
        if cmd.lower() == "q":
            break
        i = int(cmd) - 1 if cmd.isdigit() else i + 1