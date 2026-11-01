"""UTUVO Wallpaper — 彩色玻璃圖示方塊（Blender 背景算圖）。

用法（不開視窗、不用 MCP）：
    /Applications/Blender.app/Contents/MacOS/Blender -b -P tools/blender/glass_tiles.py -- <輸出資料夾>

每個顏色輸出：
    <名稱>.png       1024px 主檔（透明背景）
    <名稱>-96.png / -72.png / -48.png   縮小版（App 內用）

材質：有厚度的彩色玻璃（邊緣折射、內側高光、底部柔和色光）。Cycles 固定取樣與種子，重跑結果相同。
"""
import bpy, sys, os, math, time

# STYLE.md 的 13 個顏色（名稱 → #RRGGBB）
TILES = [
    ("all", "0A84FF"), ("favorites", "FF375F"), ("dynamic", "FF9F0A"),
    ("nature", "30D158"), ("minimal", "8E8E93"), ("abstract", "7D5CFF"),
    ("illustration", "FF9F0A"), ("cosmic", "5E5CE6"), ("watercolor", "40C8E0"),
    ("architecture", "C9A26B"), ("animation", "FF6482"), ("other", "636366"),
    ("settings", "8E8E93"),
]
SIZES = [96, 72, 48]
RES = 1024
SAMPLES = 32

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
out_dir = os.path.abspath(argv[0] if argv else "Assets/GlassTiles")
only = set(argv[1].split(",")) if len(argv) > 1 else None
os.makedirs(out_dir, exist_ok=True)


def srgb_to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def hex_color(h, alpha=1.0):
    r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return (srgb_to_linear(r), srgb_to_linear(g), srgb_to_linear(b), alpha)


def mix(a, b, t):
    return tuple(a[i] * (1 - t) + b[i] * t for i in range(4))


# ---------- 場景 ----------
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.engine = "CYCLES"
cycles = scene.cycles
cycles.samples = SAMPLES
cycles.seed = 7
cycles.use_animated_seed = False
cycles.use_denoising = True
cycles.max_bounces = 12
cycles.transmission_bounces = 12
cycles.glossy_bounces = 6
cycles.transparent_max_bounces = 8
try:
    prefs = bpy.context.preferences.addons["cycles"].preferences
    prefs.compute_device_type = "METAL"
    prefs.get_devices()
    # 只用 GPU：CPU＋GPU 混算在忙碌的機器上反而更慢。
    gpus = [device for device in prefs.devices if device.type != "CPU"]
    for device in prefs.devices:
        device.use = device.type != "CPU"
    cycles.device = "GPU" if gpus else "CPU"
    print("[glass_tiles] device:", [d.name for d in gpus] or "CPU")
except Exception as error:  # 沒有 GPU 就用 CPU，結果相同只是比較慢
    print("GPU unavailable, using CPU:", error)
    cycles.device = "CPU"

scene.render.resolution_x = RES
scene.render.resolution_y = RES
scene.render.resolution_percentage = 100
scene.render.film_transparent = True
cycles.film_transparent_glass = True
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_mode = "RGBA"
scene.render.image_settings.color_depth = "8"
scene.view_settings.view_transform = "Standard"
scene.view_settings.look = "None"

# 世界：中性灰漸層，只提供反射與折射，背景本身透明。
world = bpy.data.worlds.new("World")
scene.world = world
world.use_nodes = True
wn = world.node_tree.nodes
wl = world.node_tree.links
wn.clear()
w_out = wn.new("ShaderNodeOutputWorld")
w_bg = wn.new("ShaderNodeBackground")
w_grad = wn.new("ShaderNodeTexGradient")
w_map = wn.new("ShaderNodeMapping")
w_coord = wn.new("ShaderNodeTexCoord")
w_ramp = wn.new("ShaderNodeValToRGB")
w_ramp.color_ramp.elements[0].color = (0.18, 0.19, 0.22, 1)
w_ramp.color_ramp.elements[1].color = (0.9, 0.92, 0.96, 1)
w_map.inputs["Rotation"].default_value = (0, -math.pi / 2, 0)
wl.new(w_coord.outputs["Generated"], w_map.inputs["Vector"])
wl.new(w_map.outputs["Vector"], w_grad.inputs["Vector"])
wl.new(w_grad.outputs["Fac"], w_ramp.inputs["Fac"])
wl.new(w_ramp.outputs["Color"], w_bg.inputs["Color"])
w_bg.inputs["Strength"].default_value = 0.8
wl.new(w_bg.outputs["Background"], w_out.inputs["Surface"])

# 相機：正交、正面，方塊佔畫面約 84%。
cam_data = bpy.data.cameras.new("Camera")
cam_data.type = "ORTHO"
cam_data.ortho_scale = 2.42
cam = bpy.data.objects.new("Camera", cam_data)
scene.collection.objects.link(cam)
cam.location = (0, -0.0, 6)
cam.rotation_euler = (0, 0, 0)
scene.camera = cam


def rounded_rect_curve(name, size, radius, extrude=0.0, bevel=0.0, z=0.0, resolution=12):
    curve = bpy.data.curves.new(name, "CURVE")
    curve.dimensions = "2D"
    curve.fill_mode = "BOTH"
    curve.extrude = extrude
    curve.bevel_depth = bevel
    curve.bevel_resolution = 8
    curve.resolution_u = resolution
    spline = curve.splines.new("POLY")
    half = size / 2
    points = []
    corners = [(half - radius, half - radius, 0), (-(half - radius), half - radius, 90),
               (-(half - radius), -(half - radius), 180), (half - radius, -(half - radius), 270)]
    steps = 16
    for cx, cy, start in corners:
        for i in range(steps + 1):
            angle = math.radians(start + 90 * i / steps)
            points.append((cx + radius * math.cos(angle), cy + radius * math.sin(angle)))
    spline.points.add(len(points) - 1)
    for point, (x, y) in zip(spline.points, points):
        point.co = (x, y, 0, 1)
    spline.use_cyclic_u = True
    obj = bpy.data.objects.new(name, curve)
    obj.location.z = z
    scene.collection.objects.link(obj)
    return obj


SIZE = 2.0
RADIUS = SIZE * 0.26
slab = rounded_rect_curve("Slab", SIZE - 0.12, RADIUS - 0.06, extrude=0.10, bevel=0.06)
core = rounded_rect_curve("Core", SIZE - 0.06, RADIUS - 0.03, z=-0.09)

# 燈光：左上大面光（上緣高光）、右下小面光（邊緣反光）。
def area(name, location, rotation, size, energy, color=(1, 1, 1)):
    data = bpy.data.lights.new(name, "AREA")
    data.size = size
    data.energy = energy
    data.color = color
    obj = bpy.data.objects.new(name, data)
    obj.location = location
    obj.rotation_euler = rotation
    scene.collection.objects.link(obj)
    return obj

area("Key", (-1.6, 2.4, 3.2), (math.radians(-35), math.radians(-25), 0), 2.5, 420)
# 上半部的柔和光澤：正上方一條面光，只在玻璃頂面的反射裡看得到。
sheen = area("Sheen", (-0.15, 0.62, 2.2), (0, 0, math.radians(-8)), 1.0, 9)
sheen.data.shape = "RECTANGLE"
sheen.data.size = 2.8
sheen.data.size_y = 0.62
area("Rim", (2.4, -2.2, 1.4), (math.radians(60), math.radians(40), 0), 1.6, 120)


def glass_material(color):
    mat = bpy.data.materials.new("Glass")
    mat.use_nodes = True
    nodes = mat.node_tree.nodes
    bsdf = next(n for n in nodes if n.type == "BSDF_PRINCIPLED")
    bsdf.inputs["Base Color"].default_value = mix(color, (1, 1, 1, 1), 0.35)
    bsdf.inputs["Roughness"].default_value = 0.14
    bsdf.inputs["IOR"].default_value = 1.5
    for key in ("Transmission Weight", "Transmission"):
        if key in bsdf.inputs:
            bsdf.inputs[key].default_value = 1.0
            break
    for key in ("Coat Weight",):
        if key in bsdf.inputs:
            bsdf.inputs[key].default_value = 0.6
    return mat


def core_material(color):
    """內層色塊：上淺下深的漸層＋很輕的自發光，讓方塊有實心的顏色。"""
    mat = bpy.data.materials.new("Core")
    mat.use_nodes = True
    nodes = mat.node_tree.nodes
    links = mat.node_tree.links
    nodes.clear()
    out = nodes.new("ShaderNodeOutputMaterial")
    emit = nodes.new("ShaderNodeEmission")
    diffuse = nodes.new("ShaderNodeBsdfDiffuse")
    add = nodes.new("ShaderNodeAddShader")
    coord = nodes.new("ShaderNodeTexCoord")
    sep = nodes.new("ShaderNodeSeparateXYZ")
    ramp = nodes.new("ShaderNodeValToRGB")
    links.new(coord.outputs["Generated"], sep.inputs["Vector"])
    links.new(sep.outputs["Y"], ramp.inputs["Fac"])
    # 下緣（Y=0）是柔和的色光，往上回到本色，頂端略亮。
    elements = ramp.color_ramp.elements
    elements[0].position = 0.0
    elements[0].color = mix(color, (1, 1, 1, 1), 0.38)
    elements[1].position = 1.0
    elements[1].color = mix(color, (1, 1, 1, 1), 0.10)
    mid = elements.new(0.32)
    mid.color = mix(color, (0, 0, 0, 1), 0.12)
    links.new(ramp.outputs["Color"], emit.inputs["Color"])
    links.new(ramp.outputs["Color"], diffuse.inputs["Color"])
    emit.inputs["Strength"].default_value = 0.85
    links.new(emit.outputs["Emission"], add.inputs[0])
    links.new(diffuse.outputs["BSDF"], add.inputs[1])
    links.new(add.outputs["Shader"], out.inputs["Surface"])
    return mat


def downscale(src, size):
    image = bpy.data.images.load(src, check_existing=False)
    image.scale(size, size)
    stem = os.path.splitext(src)[0]
    target = f"{stem}-{size}.png"
    image.filepath_raw = target
    image.file_format = "PNG"
    image.save()
    bpy.data.images.remove(image)
    return target


started = time.time()
written = []
for name, hexcode in TILES:
    if only and name not in only:
        continue
    color = hex_color(hexcode)
    for obj, mat in ((slab, glass_material(color)), (core, core_material(color))):
        obj.data.materials.clear()
        obj.data.materials.append(mat)
    path = os.path.join(out_dir, f"{name}.png")
    scene.render.filepath = path
    t0 = time.time()
    bpy.ops.render.render(write_still=True)
    written.append(path)
    for size in SIZES:
        written.append(downscale(path, size))
    print(f"[glass_tiles] {name} #{hexcode} {time.time() - t0:.1f}s")

print(f"[glass_tiles] done {len(written)} files in {time.time() - started:.1f}s → {out_dir}")
