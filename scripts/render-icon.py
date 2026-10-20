# Renders Resources/AppIcon.png (1024px master). Usage: python3 scripts/render-icon.py Resources/AppIcon.png
from PIL import Image, ImageDraw, ImageFilter, ImageChops
import sys
S = 4  # supersample
W = 1024 * S
def px(v): return int(v * S)

# Apple macOS icon grid: 824pt body centred on a 1024 canvas.
bx, by, bw = px(100), px(100), px(824)
radius = px(185)

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

# Background gradient
bg = Image.new("RGB", (W, W))
top, mid, bot = (88, 101, 242), (139, 92, 246), (236, 72, 153)
d = ImageDraw.Draw(bg)
for y in range(W):
    t = min(max((y - by) / bw, 0), 1)
    c = lerp(top, mid, t / 0.6) if t < 0.6 else lerp(mid, bot, (t - 0.6) / 0.4)
    d.line([(0, y), (W, y)], fill=c)

body = Image.new("L", (W, W), 0)
ImageDraw.Draw(body).rounded_rectangle([bx, by, bx + bw, by + bw], radius=radius, fill=255)

# Soft highlight in the lower half
glow = Image.new("L", (W, W), 0)
ImageDraw.Draw(glow).ellipse([px(150), px(560), px(874), px(1100)], fill=90)
glow = glow.filter(ImageFilter.GaussianBlur(px(90)))
bg = Image.composite(Image.new("RGB", (W, W), (255, 255, 255)), bg, glow)

# Bezel strip along the top of the body, with the expanded notch hanging from it
strip_h = px(64)
iw, ih, ear, br = px(540), px(250), px(40), px(110)
ix0 = (W - iw) // 2
ix1 = ix0 + iw
iy0, iy1 = by + strip_h, by + strip_h + ih
island = Image.new("L", (W, W), 0)
di = ImageDraw.Draw(island)
di.rectangle([0, 0, W, iy0], fill=255)
di.rounded_rectangle([ix0, iy0 - br, ix1, iy1], radius=br, fill=255)
ears = Image.new("L", (W, W), 0)
de = ImageDraw.Draw(ears)
de.rectangle([ix0 - ear, iy0, ix0, iy0 + ear], fill=255)
de.rectangle([ix1, iy0, ix1 + ear, iy0 + ear], fill=255)
de.ellipse([ix0 - 2 * ear, iy0, ix0, iy0 + 2 * ear], fill=0)
de.ellipse([ix1, iy0, ix1 + 2 * ear, iy0 + 2 * ear], fill=0)
island = ImageChops.lighter(island, ears)
island = ImageChops.multiply(island, body)

shadow = island.filter(ImageFilter.GaussianBlur(px(30)))
shadow = ImageChops.offset(shadow, 0, px(24))
bg = Image.composite(Image.new("RGB", (W, W), (25, 12, 60)), bg, shadow.point(lambda v: int(v * 0.5)))
bg = Image.composite(Image.new("RGB", (W, W), (8, 8, 12)), bg, island)

d = ImageDraw.Draw(bg)
# Album art tile
asz = px(150)
ax0, ay0 = ix0 + px(56), iy0 + px(8)
art = Image.new("RGB", (asz, asz))
da = ImageDraw.Draw(art)
for y in range(asz):
    da.line([(0, y), (asz, y)], fill=lerp((251, 146, 60), (236, 72, 153), y / asz))
artmask = Image.new("L", (asz, asz), 0)
ImageDraw.Draw(artmask).rounded_rectangle([0, 0, asz - 1, asz - 1], radius=px(32), fill=255)
bg.paste(art, (ax0, ay0), artmask)
nx, ny = ax0 + px(48), ay0 + px(34)
d.rectangle([nx + px(30), ny, nx + px(42), ny + px(70)], fill=(255, 255, 255))
d.polygon([(nx + px(42), ny), (nx + px(72), ny + px(12)), (nx + px(72), ny + px(30)), (nx + px(42), ny + px(20))], fill=(255, 255, 255))
d.ellipse([nx, ny + px(55), nx + px(42), ny + px(85)], fill=(255, 255, 255))

# Equalizer bars at the right, vertically centred on the art
heights = [64, 118, 86, 136]
bar_w, gap = px(20), px(16)
bxs = ix1 - px(60) - (4 * bar_w + 3 * gap)
cy = ay0 + asz // 2
for i, h in enumerate(heights):
    x = bxs + i * (bar_w + gap)
    d.rounded_rectangle([x, cy - px(h / 2), x + bar_w, cy + px(h / 2)], radius=bar_w // 2, fill=(74, 222, 128))

# Progress bar along the bottom of the island
py = ay0 + asz + px(30)
d.rounded_rectangle([ax0, py, ix1 - px(60), py + px(12)], radius=px(6), fill=(64, 64, 76))
d.rounded_rectangle([ax0, py, ax0 + px(250), py + px(12)], radius=px(6), fill=(255, 255, 255))

out = Image.new("RGBA", (W, W), (0, 0, 0, 0))
out.paste(bg, (0, 0), body)
out = out.resize((1024, 1024), Image.LANCZOS)
out.save(sys.argv[1])
