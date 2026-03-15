"""Generate THRESHOLD game icon — radar sweep with crosshair on dark navy."""
from PIL import Image, ImageDraw
import math, os

SIZES = [256, 128, 64, 48, 32, 16]
BG = (8, 18, 38)          # dark navy
RING = (40, 120, 200)     # steel blue
SWEEP = (60, 200, 120)    # green radar sweep
CONTACT = (255, 80, 60)   # hostile red
CROSS = (100, 180, 255)   # friendly cyan

def draw_icon(size):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    cx, cy = size // 2, size // 2
    r = int(size * 0.44)

    # Background circle
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=BG)

    # Radar range rings (3 concentric)
    for frac in [0.33, 0.66, 1.0]:
        rr = int(r * frac)
        lw = max(1, size // 64)
        d.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], outline=RING + (80,), width=lw)

    # Radar sweep wedge (green, ~60 degrees from north-northeast)
    sweep_start = -75
    sweep_end = -15
    for i in range(30):
        frac = i / 30.0
        alpha = int(120 * (1 - frac))
        angle = sweep_start + (sweep_end - sweep_start) * frac
        a_rad = math.radians(angle)
        x2 = cx + int(r * math.cos(a_rad))
        y2 = cy + int(r * math.sin(a_rad))
        lw = max(1, size // 48)
        d.line([(cx, cy), (x2, y2)], fill=SWEEP[:3] + (alpha,), width=lw)

    # Sweep leading edge (bright)
    a_rad = math.radians(sweep_end)
    x2 = cx + int(r * math.cos(a_rad))
    y2 = cy + int(r * math.sin(a_rad))
    lw = max(1, size // 32)
    d.line([(cx, cy), (x2, y2)], fill=SWEEP + (220,), width=lw)

    # Crosshair lines (thin)
    lw = max(1, size // 64)
    d.line([(cx, cy - r), (cx, cy + r)], fill=CROSS + (60,), width=lw)
    d.line([(cx - r, cy), (cx + r, cy)], fill=CROSS + (60,), width=lw)

    # Center dot
    cd = max(2, size // 32)
    d.ellipse([cx - cd, cy - cd, cx + cd, cy + cd], fill=CROSS)

    # Hostile contact blip (small red diamond)
    bx = cx + int(r * 0.5)
    by = cy - int(r * 0.35)
    bs = max(2, size // 20)
    d.polygon([(bx, by - bs), (bx + bs, by), (bx, by + bs), (bx - bs, by)], fill=CONTACT)

    # Second contact (dimmer, further)
    bx2 = cx - int(r * 0.3)
    by2 = cy + int(r * 0.55)
    bs2 = max(2, size // 24)
    d.polygon([(bx2, by2 - bs2), (bx2 + bs2, by2), (bx2, by2 + bs2), (bx2 - bs2, by2)], fill=CONTACT[:3] + (150,))

    return img

# Generate all sizes and save as .ico
images = [draw_icon(s) for s in SIZES]
ico_path = os.path.join(os.path.dirname(__file__), "threshold.ico")
images[0].save(ico_path, format="ICO", sizes=[(s, s) for s in SIZES], append_images=images[1:])
print(f"Icon saved: {ico_path}")
