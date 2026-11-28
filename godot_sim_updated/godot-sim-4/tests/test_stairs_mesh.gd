extends SceneTree
## Headless check of the sloped stairs built from res://draw.json:
##   godot --headless --fixed-fps 60 --path godot_sim_updated/godot-sim-4 -s res://tests/test_stairs_mesh.gd
## Exit code: 0 = PASS, 1 = FAIL, 2 = timeout (60 s).
##
## PASS needs:
##   - draw.json has the new "stairs" and "elevators" keys and at least one flight;
##   - every flight's mesh is a thin tilted slab: its highest point is z1, its top at the
##     bottom end is z0, and its lowest point is z0 - STAIR_THICKNESS (nothing solid
##     underneath) (all within 5 cm);
##   - no flight or landing goes through a wall: less than 1 % of its plan area overlaps
##     the walls/railings standing at its height;
##   - every stairwell climbs a whole storey: on every floor that has stairs, the highest
##     flight top equals the walking level of the next floor (or the top floor + one storey);
##   - the default route (two far ends of the biggest patch) is still on one floor: the
##     navmesh itself does not join the floors (that is done by the stair links, tested
##     in test_agent_stairs.gd).

const TOL := 0.05   # m

## Entry point of a SceneTree script (run with -s).
func _initialize():
	create_timer(60).timeout.connect(func(): print("RESULT: TIMEOUT"); quit(2))
	var main = load("res://node_3d.tscn").instantiate()
	root.add_child(main)
	await main.nav.ready_to_walk
	var f := FileAccess.open("res://server_data/draw.json", FileAccess.READ)
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	var ok := true
	var flights := []
	var n_elev := 0
	var levels := {}   # walking levels = tops of the floor slabs, rounded to cm
	for apt in data["apartments"]:
		if not apt.has("stairs") or not apt.has("elevators"):
			print("FAIL: draw.json has no stairs/elevators keys (re-run analyze.py)")
			ok = false
			break
		flights += apt["stairs"]
		n_elev += apt["elevators"].size()
		for p in apt["floors"]:
			levels[snappedf(p[1] + p[2], 0.01)] = true
	var lv: Array = levels.keys()
	lv.sort()
	print("building %d: %d flights, %d elevators, floor levels %s" % [data["building_id"], flights.size(), n_elev, lv])
	if flights.is_empty():
		ok = false
	# 1) each flight's mesh: lowest = base, highest = z1, top at the low end = z0
	for fl in flights:
		var node: CSGShape3D = main.make_stair(fl)
		root.add_child(node)
		await process_frame   # let the CSG shape build
		# the collision faces are in the node's own axes: move them into world space
		var faces: PackedVector3Array = node.global_transform * node.bake_collision_shape().get_faces()
		var lo := INF
		var hi := -INF
		var top_at_low := -INF   # highest vertex within 10 cm (plan) of the bottom end's edge
		var a := Vector2(fl["low"][0][0], fl["low"][0][1])
		var b := Vector2(fl["low"][1][0], fl["low"][1][1])
		for v in faces:
			lo = min(lo, v.y)
			hi = max(hi, v.y)
			if Geometry2D.get_closest_point_to_segment(Vector2(v.x, v.z), a, b).distance_to(Vector2(v.x, v.z)) < 0.1:
				top_at_low = max(top_at_low, v.y)
		var want_lo: float = fl["z0"] - main.STAIR_THICKNESS
		var good: bool = abs(lo - want_lo) < TOL and abs(hi - fl["z1"]) < TOL and abs(top_at_low - fl["z0"]) < TOL
		print("flight z0 %.2f z1 %.2f -> mesh min %.2f (want %.2f) max %.2f top at bottom end %.2f %s" % [fl["z0"], fl["z1"], lo, want_lo, hi, top_at_low, "ok" if good else "BAD"])
		ok = ok and good
		node.queue_free()
	# 2) flights and landings stay out of the walls
	var walls := []   # [outline, bottom, top] of every wall and railing piece
	var landings := []
	for apt in data["apartments"]:
		for kind in ["walls", "railings"]:
			for p in apt[kind]:
				walls.append([_poly(p[0]), p[1], p[1] + p[2]])
		landings += apt.get("landings", [])
	for fl in flights:
		var z: float = (fl["z0"] + fl["z1"]) / 2.0   # half way up the flight
		var share := _wall_share(_poly(fl["outline"]), z, walls)
		print("flight at %.2f: %.2f %% in walls %s" % [z, share * 100, "ok" if share < 0.01 else "BAD"])
		ok = ok and share < 0.01
	for l in landings:
		var share := _wall_share(_poly(l[0]), l[1] + l[2] / 2.0, walls)
		print("landing at %.2f (%.2f m2): %.2f %% in walls %s" % [l[1] + l[2], _area(_poly(l[0])), share * 100, "ok" if share < 0.01 else "BAD"])
		ok = ok and share < 0.01
	# 3) each floor's stairs reach the next floor level
	var storey: float = lv[1] - lv[0] if lv.size() > 1 else 0.0
	var top_by_base := {}
	for fl in flights:
		var k = snappedf(fl["base"], 0.01)
		top_by_base[k] = max(top_by_base.get(k, -INF), fl["z1"])
	for base in top_by_base:
		var i := lv.find(base)
		var want: float = lv[i + 1] if i >= 0 and i + 1 < lv.size() else base + storey
		var good: bool = abs(top_by_base[base] - want) < TOL
		print("stairs from %.2f reach %.2f (next floor %.2f) %s" % [base, top_by_base[base], want, "ok" if good else "BAD"])
		ok = ok and good
	# 4) the default route stays on one floor
	await physics_frame
	var start: Vector3 = main.nav.agent.global_position
	var goal: Vector3 = main.nav.agent.target_position
	var same_floor: bool = abs(start.y - goal.y) < 0.5
	print("agent route %s -> %s, same floor: %s" % [start, goal, same_floor])
	ok = ok and same_floor
	print("RESULT: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)


## [[x, y], ...] from draw.json -> PackedVector2Array
func _poly(points) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in points:
		out.append(Vector2(p[0], p[1]))
	return out


## Area of a polygon (shoelace formula).
func _area(p: PackedVector2Array) -> float:
	var a := 0.0
	for i in p.size():
		a += p[i].cross(p[(i + 1) % p.size()])
	return abs(a) / 2.0


## Share (0..1) of polygon `p`'s area that lies inside the walls standing at height z.
func _wall_share(p: PackedVector2Array, z: float, walls: Array) -> float:
	var inside := 0.0
	for w in walls:
		if z < w[1] or z > w[2]:
			continue
		for part in Geometry2D.intersect_polygons(p, w[0]):
			inside += _area(part)
	return inside / max(_area(p), 1e-6)
