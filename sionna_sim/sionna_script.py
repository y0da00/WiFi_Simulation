import os
import json
import numpy as np
import matplotlib
matplotlib.use("Agg") #Agg = Anti-Grain Geometry, a high-quality raster (PNG/JPG) renderer.
import matplotlib.pyplot as plt
import sionna.rt as rt

HERE = os.path.dirname(os.path.abspath(__file__))

SCENE_XML = os.path.join(HERE, "scene", "scene.xml")

scene = rt.load_scene(SCENE_XML, merge_shapes=False)
scene.frequency = 3.5e9
floor = scene.get("floor")

scene.tx_array = rt.PlanarArray(num_rows=1, num_cols=1, pattern="iso", polarization="V")
scene.rx_array = scene.tx_array
print("Loaded objects:", list(scene.objects.keys())) 

bbox = scene.objects["walls"].mi_mesh.bbox() 
xmin, ymin, zmin = bbox.min.x, bbox.min.y, bbox.min.z
xmax, ymax = bbox.max.x, bbox.max.y
cx, cy = (xmin + xmax) / 2, (ymin + ymax) / 2

scene.add(rt.Transmitter("router", position=[cx, cy, zmin + 2.0], power_dbm=20.0))

rm = rt.RadioMapSolver()(scene, center=[cx, cy, zmin + 1.0], orientation=[0, 0, 0],
                         size=[xmax - xmin, ymax - ymin], cell_size=[0.25, 0.25],
                         samples_per_tx=10**6, max_depth=5)
rss = 10 * np.log10(rm.rss.numpy()[0] + 1e-30) + 30
print(f"Radio map {rss.shape}, area above -70 dBm: {np.mean(rss > -70) * 100:.1f}%")

plt.imshow(np.clip(rss, -110, -20), origin="lower", cmap="viridis",
           extent=[xmin, xmax, ymin, ymax])
plt.colorbar(label="RSS [dBm]")
plt.plot(cx, cy, "r^", label="router")
plt.legend()
plt.savefig(os.path.join(HERE, "coverage.png"), dpi=150)
print("Saved sionna_sim/coverage.png")
