extends RefCounted
## JSON format (written by export_policy.py):
##   {"obs_size": 27, "act_size": 2, "layers": [{"w": [[...], ...], "b": [...], "act": "tanh"}, ...]}
##   w is out x in (one row per output number).

var obs_size := 0
var act_size := 0
var _w: Array = []      ## per layer: PackedFloat32Array, row-major (out x in) - for act_slow()
var _b: Array = []      ## per layer: PackedFloat32Array
var _in: PackedInt32Array = PackedInt32Array()
var _out: PackedInt32Array = PackedInt32Array()
var _tanh: Array = []   ## per layer: true if tanh, false if linear
var _blocks: Array = [] ## per layer: Array of Projection, block (r, c) at index r * in_blocks + c
var _bias4: Array = []  ## per layer: Array of Vector4 (bias, 4 outputs per Vector4)

static var _cache := {} ## file path -> MLPPolicy already loaded (see load_shared())


func _make_blocks(l: int) -> void:
	var w: PackedFloat32Array = _w[l]
	var b: PackedFloat32Array = _b[l]
	var n_in: int = _in[l]
	var n_out: int = _out[l]
	var rb := (n_out + 3) / 4   # blocks down (outputs)
	var cb := (n_in + 3) / 4    # blocks across (inputs)
	var blocks: Array[Projection] = []
	for r in rb:
		for c in cb:
			var cols: Array[Vector4] = []
			for k in 4:
				var i := 4 * c + k
				var v := Vector4.ZERO
				for m in 4:
					var j := 4 * r + m
					if i < n_in and j < n_out:
						v[m] = w[j * n_in + i]
				cols.append(v)
			blocks.append(Projection(cols[0], cols[1], cols[2], cols[3]))
	var bias: Array[Vector4] = []
	for r in rb:
		var v := Vector4.ZERO
		for m in 4:
			if 4 * r + m < n_out:
				v[m] = b[4 * r + m]
		bias.append(v)
	_blocks.append(blocks)
	_bias4.append(bias)


## One forward pass: observation numbers in, clamped action numbers out (fast version).
func act(obs: PackedFloat32Array) -> PackedFloat32Array:
	if obs.size() != obs_size:
		push_error("observation has %d numbers, the network expects %d (retrain?)" % [obs.size(), obs_size])
		return PackedFloat32Array([0.0, 0.0])
	# group the inputs 4 at a time (the last group is padded with zeros)
	var o := obs
	if obs_size % 4 != 0:
		o = obs.duplicate()
		o.resize((obs_size + 3) / 4 * 4)   # pad with zeros
	var x: Array[Vector4] = []
	for c in o.size() / 4:
		x.append(Vector4(o[4 * c], o[4 * c + 1], o[4 * c + 2], o[4 * c + 3]))
	for l in _blocks.size():
		var blocks: Array[Projection] = _blocks[l]
		var bias: Array[Vector4] = _bias4[l]
		var use_tanh: bool = _tanh[l]
		var cb := x.size()
		var y: Array[Vector4] = []
		for r in bias.size():
			var s: Vector4 = bias[r]
			var base := r * cb
			for c in cb:
				s += blocks[base + c] * x[c]   # 16 multiply-adds in C++
			if use_tanh:
				s = Vector4(tanh(s.x), tanh(s.y), tanh(s.z), tanh(s.w))
			y.append(s)
		x = y
	var out := PackedFloat32Array()
	out.resize(act_size)
	for j in act_size:
		out[j] = clampf(x[j / 4][j % 4], -1.0, 1.0)
	return out


## The same forward pass, one multiply-add at a time (slow, easy to read; used to check act()).
func act_slow(obs: PackedFloat32Array) -> PackedFloat32Array:
	var x := obs
	for l in _w.size():
		var w: PackedFloat32Array = _w[l]
		var b: PackedFloat32Array = _b[l]
		var n_in: int = _in[l]
		var n_out: int = _out[l]
		var use_tanh: bool = _tanh[l]
		var y := PackedFloat32Array()
		y.resize(n_out)
		for j in n_out:
			var s: float = b[j]
			var row := j * n_in
			for i in n_in:
				s += w[row + i] * x[i]
			y[j] = tanh(s) if use_tanh else s
		x = y
	for j in x.size():
		x[j] = clampf(x[j], -1.0, 1.0)
	return x
