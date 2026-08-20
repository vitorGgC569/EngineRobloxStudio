"""
Advanced Procedural Card Art Generator for Miner's Ridge
Generates high-fidelity, beautifully shaded 1:1 card illustrations:
- Field Lantern (Common)
- Tunnel Mole (Uncommon)
- Ridge Warden (Mythic)
"""

import math
import random
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageChops

ROOT = Path(__file__).resolve().parent.parent
OUTPUT_DIR = ROOT / "assets" / "generated" / "cards"
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

SIZE = 1254


def linear_gradient(size, start_color, end_color, vertical=True):
    """Creates smooth linear gradient image."""
    w, h = size
    base = Image.new("RGBA", (w, h))
    draw = ImageDraw.Draw(base)
    steps = h if vertical else w
    for i in range(steps):
        t = i / float(steps)
        r = int(start_color[0] * (1 - t) + end_color[0] * t)
        g = int(start_color[1] * (1 - t) + end_color[1] * t)
        b = int(start_color[2] * (1 - t) + end_color[2] * t)
        a = int(start_color[3] * (1 - t) + end_color[3] * t)
        if vertical:
            draw.line([(0, i), (w, i)], fill=(r, g, b, a))
        else:
            draw.line([(i, 0), (i, h)], fill=(r, g, b, a))
    return base


def add_radial_light(base_img, center, radius, color, max_alpha=180):
    cx, cy = center
    glow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    gdraw = ImageDraw.Draw(glow)
    steps = 30
    for i in range(steps, 0, -1):
        r = radius * (i / float(steps))
        t = i / float(steps)
        alpha = int(max_alpha * (1.0 - t ** 1.5))
        gdraw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(color[0], color[1], color[2], alpha))
    glow = glow.filter(ImageFilter.GaussianBlur(radius / 15))
    return Image.alpha_composite(base_img, glow)


def draw_shaded_polygon(draw, points, base_color, highlight_side=True):
    draw.polygon(points, fill=base_color)


def draw_faceted_gem(draw, x, y, w, h, c_dark, c_mid, c_light):
    top = (x, y - h // 2)
    bot = (x, y + h // 2)
    left = (x - w // 2, y)
    right = (x + w // 2, y)
    center = (x, y - h // 6)
    
    draw.polygon([top, left, center], fill=c_mid)
    draw.polygon([top, right, center], fill=c_light)
    draw.polygon([bot, left, center], fill=c_dark)
    draw.polygon([bot, right, center], fill=c_mid)


def draw_particles(draw, count, bounds, color_list, seed=42):
    rng = random.Random(seed)
    min_x, min_y, max_x, max_y = bounds
    for _ in range(count):
        px = rng.uniform(min_x, max_x)
        py = rng.uniform(min_y, max_y)
        r = rng.uniform(1.5, 6.5)
        c = rng.choice(color_list)
        alpha = rng.randint(90, 240)
        draw.ellipse([px - r, py - r, px + r, py + r], fill=(c[0], c[1], c[2], alpha))


# -------------------------------------------------------------
# 1. FIELD LANTERN (COMMON)
# -------------------------------------------------------------
def render_field_lantern():
    # Background: Dark atmospheric slate cavern
    img = linear_gradient((SIZE, SIZE), (16, 20, 28, 255), (8, 10, 15, 255))
    draw = ImageDraw.Draw(img)

    # Cavern stalactites and backdrop rock textures
    cx, cy = SIZE // 2, SIZE // 2 - 10

    # Back wall arches
    draw.ellipse([cx - 520, cy - 420, cx + 520, cy + 620], fill=(22, 28, 40, 255))
    draw.ellipse([cx - 440, cy - 360, cx + 440, cy + 540], fill=(18, 24, 34, 255))

    # Cavern ore crystal formations
    for ox, oy, scale in [(180, 860, 1.2), (1050, 880, 1.3), (260, 360, 0.8), (980, 340, 0.9)]:
        draw_faceted_gem(draw, int(ox), int(oy), int(70 * scale), int(160 * scale), (90, 65, 25, 255), (180, 135, 55, 255), (245, 200, 100, 255))
        draw_faceted_gem(draw, int(ox - 30 * scale), int(oy + 20 * scale), int(45 * scale), int(100 * scale), (80, 55, 20, 255), (160, 115, 45, 255), (225, 175, 80, 255))
        draw_faceted_gem(draw, int(ox + 30 * scale), int(oy + 20 * scale), int(45 * scale), int(100 * scale), (80, 55, 20, 255), (160, 115, 45, 255), (225, 175, 80, 255))

    # Ambient radial warm lantern glow in background
    img = add_radial_light(img, (cx, cy), 580, (255, 175, 50), max_alpha=160)
    img = add_radial_light(img, (cx, cy), 320, (255, 220, 110), max_alpha=200)
    draw = ImageDraw.Draw(img)

    # Cavern floor / stone altar pedestal
    ped_top = 840
    # Shaded stone altar
    draw.polygon([(cx - 360, SIZE), (cx + 360, SIZE), (cx + 260, ped_top + 100), (cx - 260, ped_top + 100)], fill=(28, 34, 46, 255))
    draw.polygon([(cx - 260, ped_top + 100), (cx + 260, ped_top + 100), (cx + 220, ped_top + 40), (cx - 220, ped_top + 40)], fill=(38, 46, 60, 255))
    draw.rounded_rectangle([cx - 210, ped_top, cx + 210, ped_top + 50], radius=14, fill=(50, 60, 78, 255), outline=(130, 145, 170, 255), width=3)
    # Pedestal brass plate
    draw.rounded_rectangle([cx - 170, ped_top - 18, cx + 170, ped_top + 10], radius=10, fill=(120, 80, 42, 255), outline=(220, 160, 80, 255), width=4)

    # 3. Lantern Main Body
    lan_top = 260
    lan_bot = ped_top - 18
    lan_w = 230

    # Lantern interior glass chamber glow
    chamber_rect = [cx - lan_w + 25, lan_top + 120, cx + lan_w - 25, lan_bot - 35]
    draw.rounded_rectangle(chamber_rect, radius=24, fill=(40, 26, 15, 235), outline=(140, 90, 45, 255), width=5)

    # Radiant floating crystal core
    core_y = (lan_top + 120 + lan_bot - 35) // 2
    draw_faceted_gem(draw, cx, core_y, 110, 220, (210, 130, 30, 255), (255, 195, 70, 255), (255, 250, 190, 255))
    draw_faceted_gem(draw, cx - 60, core_y + 20, 60, 140, (190, 110, 25, 255), (245, 170, 50, 255), (255, 230, 140, 255))
    draw_faceted_gem(draw, cx + 60, core_y + 20, 60, 140, (190, 110, 25, 255), (245, 170, 50, 255), (255, 230, 140, 255))

    # Glass reflection sheen
    draw.polygon([
        (cx - lan_w + 40, lan_top + 140),
        (cx - lan_w + 85, lan_top + 140),
        (cx - lan_w + 55, lan_bot - 55),
        (cx - lan_w + 35, lan_bot - 55)
    ], fill=(255, 255, 255, 75))

    # Brass protective rib pillars (with 3D gradient look)
    ribs = [cx - lan_w + 10, cx - 80, cx + 80, cx + lan_w - 10]
    for rx in ribs:
        draw.rounded_rectangle([rx - 12, lan_top + 110, rx + 12, lan_bot - 20], radius=8, fill=(110, 70, 35, 255), outline=(230, 175, 90, 255), width=3)
        draw.line([(rx - 4, lan_top + 120), (rx - 4, lan_bot - 30)], fill=(255, 220, 140, 200), width=3)
        for ry in range(lan_top + 150, lan_bot - 30, 75):
            draw.ellipse([rx - 5, ry - 5, rx + 5, ry + 5], fill=(255, 225, 140, 255))

    # Lantern base collar
    draw.rounded_rectangle([cx - lan_w - 15, lan_bot - 45, cx + lan_w + 15, lan_bot], radius=12, fill=(130, 85, 45, 255), outline=(245, 190, 100, 255), width=5)

    # Lantern Top Roof / Hood & Crown
    draw.polygon([
        (cx - lan_w - 30, lan_top + 125),
        (cx + lan_w + 30, lan_top + 125),
        (cx + lan_w - 60, lan_top + 35),
        (cx - lan_w + 60, lan_top + 35)
    ], fill=(120, 75, 40, 255), outline=(240, 185, 95, 255))
    
    # Roof bevel highlight
    draw.line([(cx - lan_w + 55, lan_top + 40), (cx + lan_w - 55, lan_top + 40)], fill=(255, 225, 140, 220), width=4)
    draw.rounded_rectangle([cx - lan_w - 35, lan_top + 110, cx + lan_w + 35, lan_top + 130], radius=8, fill=(150, 100, 55, 255), outline=(255, 205, 115, 255), width=4)

    # Chimney & Top Dome
    draw.rounded_rectangle([cx - 100, lan_top - 15, cx + 100, lan_top + 38], radius=10, fill=(105, 65, 35, 255), outline=(230, 170, 85, 255), width=4)
    draw.ellipse([cx - 75, lan_top - 45, cx + 75, lan_top], fill=(135, 90, 48, 255), outline=(250, 195, 105, 255), width=5)

    # Heavy Brass Suspension Ring
    ring_r = 75
    draw.ellipse([cx - ring_r, lan_top - 155, cx + ring_r, lan_top - 5], fill=None, outline=(100, 65, 35, 255), width=24)
    draw.ellipse([cx - ring_r, lan_top - 155, cx + ring_r, lan_top - 5], fill=None, outline=(245, 190, 95, 255), width=12)
    draw.ellipse([cx - ring_r, lan_top - 155, cx + ring_r, lan_top - 5], fill=None, outline=(255, 240, 175, 255), width=3)

    # Floating ember sparks & light motes
    draw_particles(draw, 140, (cx - 450, cy - 350, cx + 450, cy + 450), [(255, 225, 120), (255, 185, 60), (255, 250, 200)])

    # Ornate Common Border
    border = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    bdraw = ImageDraw.Draw(border)
    bdraw.rectangle([0, 0, SIZE, SIZE], fill=None, outline=(174, 188, 192, 240), width=16)
    bdraw.rectangle([20, 20, SIZE - 20, SIZE - 20], fill=None, outline=(90, 105, 115, 180), width=4)
    # Corner filigree accents
    for x_c, y_c in [(35, 35), (SIZE - 35, 35), (35, SIZE - 35), (SIZE - 35, SIZE - 35)]:
        bdraw.rectangle([x_c - 12, y_c - 12, x_c + 12, y_c + 12], fill=(174, 188, 192, 255))
    img = Image.alpha_composite(img, border)

    output_path = OUTPUT_DIR / "field-lantern-v1.png"
    img.convert("RGB").save(output_path, "PNG", quality=95)
    print(f"Generated {output_path}")


# -------------------------------------------------------------
# 2. TUNNEL MOLE (UNCOMMON)
# -------------------------------------------------------------
def render_tunnel_mole():
    # Background: Lush emerald cavern tunnel
    img = linear_gradient((SIZE, SIZE), (12, 28, 22, 255), (6, 14, 11, 255))
    draw = ImageDraw.Draw(img)

    cx, cy = SIZE // 2, SIZE // 2

    # Cavern rock arches with mossy highlights
    draw.ellipse([cx - 540, cy - 480, cx + 540, cy + 580], fill=(16, 38, 30, 255))
    draw.ellipse([cx - 460, cy - 420, cx + 460, cy + 500], fill=(22, 48, 38, 255))

    # Timber beam supports
    draw.polygon([(80, 0), (180, 0), (140, SIZE), (40, SIZE)], fill=(42, 30, 22, 255))
    draw.polygon([(SIZE - 180, 0), (SIZE - 80, 0), (SIZE - 40, SIZE), (SIZE - 140, SIZE)], fill=(42, 30, 22, 255))
    draw.polygon([(80, 160), (SIZE - 80, 160), (SIZE - 80, 245), (80, 245)], fill=(52, 38, 28, 255))
    # Iron beam brackets
    for bx in [120, SIZE - 220]:
        draw.rectangle([bx, 155, bx + 100, 250], fill=(65, 70, 75, 255), outline=(125, 135, 140, 255), width=3)
        draw.ellipse([bx + 15, 175, bx + 35, 195], fill=(200, 205, 210, 255))
        draw.ellipse([bx + 65, 175, bx + 85, 195], fill=(200, 205, 210, 255))
        draw.ellipse([bx + 15, 215, bx + 35, 235], fill=(200, 205, 210, 255))
        draw.ellipse([bx + 65, 215, bx + 85, 235], fill=(200, 205, 210, 255))

    # Emerald Ore clusters
    for ox, oy, scale in [(170, 890, 1.3), (1070, 870, 1.4), (250, 380, 0.7), (990, 360, 0.8)]:
        draw_faceted_gem(draw, int(ox), int(oy), int(75 * scale), int(170 * scale), (15, 95, 55, 255), (45, 185, 110, 255), (140, 255, 190, 255))
        draw_faceted_gem(draw, int(ox - 30 * scale), int(oy + 25 * scale), int(50 * scale), int(110 * scale), (10, 80, 45, 255), (35, 160, 95, 255), (120, 240, 170, 255))
        draw_faceted_gem(draw, int(ox + 30 * scale), int(oy + 25 * scale), int(50 * scale), int(110 * scale), (10, 80, 45, 255), (35, 160, 95, 255), (120, 240, 170, 255))

    # Emerald ambient radial glow
    img = add_radial_light(img, (cx, cy - 40), 520, (40, 210, 120), max_alpha=140)
    img = add_radial_light(img, (cx, cy - 40), 280, (110, 245, 170), max_alpha=170)
    draw = ImageDraw.Draw(img)

    # 2. Mole Body & Miner Gear
    # Heavy dark fur torso
    draw.ellipse([cx - 290, cy - 30, cx + 290, cy + 560], fill=(36, 32, 38, 255))
    draw.ellipse([cx - 270, cy - 10, cx + 270, cy + 540], fill=(48, 42, 50, 255))

    # Forest-green miner's jacket
    draw.polygon([
        (cx - 230, cy + 70),
        (cx + 230, cy + 70),
        (cx + 280, cy + 540),
        (cx - 280, cy + 540)
    ], fill=(28, 78, 52, 255), outline=(50, 130, 85, 255))
    # Jacket lapels
    draw.polygon([(cx - 180, cy + 70), (cx, cy + 260), (cx - 75, cy + 420), (cx - 250, cy + 200)], fill=(38, 105, 70, 255))
    draw.polygon([(cx + 180, cy + 70), (cx, cy + 260), (cx + 75, cy + 420), (cx + 250, cy + 200)], fill=(34, 95, 64, 255))

    # Cross-body leather harness and bronze gear buckle
    draw.line([(cx - 190, cy + 110), (cx + 190, cy + 350)], fill=(70, 48, 30, 255), width=36)
    draw.line([(cx + 190, cy + 110), (cx - 190, cy + 350)], fill=(60, 40, 25, 255), width=36)
    draw.line([(cx - 190, cy + 110), (cx + 190, cy + 350)], fill=(120, 80, 45, 255), width=6)
    draw.rounded_rectangle([cx - 40, cy + 205, cx + 40, cy + 265], radius=10, fill=(165, 115, 52, 255), outline=(245, 190, 95, 255), width=5)
    draw.ellipse([cx - 12, cy + 223, cx + 12, cy + 247], fill=(245, 190, 95, 255))

    # 3. Mole Head & Charismatic Face
    head_y = cy - 135
    # Head fur shape
    draw.ellipse([cx - 200, head_y - 170, cx + 200, head_y + 170], fill=(52, 46, 54, 255))
    # Cheek pads
    draw.ellipse([cx - 150, head_y - 30, cx + 150, head_y + 160], fill=(68, 60, 70, 255))
    # Snout muzzle
    draw.ellipse([cx - 90, head_y + 20, cx + 90, head_y + 135], fill=(85, 75, 88, 255))
    # Pink velvety digging nose
    draw.ellipse([cx - 55, head_y + 55, cx + 55, head_y + 115], fill=(235, 145, 155, 255), outline=(180, 95, 105, 255), width=4)
    draw.ellipse([cx - 28, head_y + 80, cx - 10, head_y + 102], fill=(120, 50, 60, 255))
    draw.ellipse([cx + 10, head_y + 80, cx + 28, head_y + 102], fill=(120, 50, 60, 255))

    # Cheerful expressive eyes
    draw.ellipse([cx - 100, head_y - 35, cx - 55, head_y + 15], fill=(22, 20, 26, 255))
    draw.ellipse([cx + 55, head_y - 35, cx + 100, head_y + 15], fill=(22, 20, 26, 255))
    # Highlights
    draw.ellipse([cx - 88, head_y - 28, cx - 72, head_y - 12], fill=(255, 255, 255, 255))
    draw.ellipse([cx + 68, head_y - 28, cx + 84, head_y - 12], fill=(255, 255, 255, 255))

    # Miner whiskers
    for dy in [-15, 5, 25]:
        draw.line([(cx - 65, head_y + 85 + dy), (cx - 210, head_y + 75 + dy * 1.6)], fill=(220, 220, 230, 220), width=4)
        draw.line([(cx + 65, head_y + 85 + dy), (cx + 210, head_y + 75 + dy * 1.6)], fill=(220, 220, 230, 220), width=4)

    # 4. Steampunk Brass Mining Goggles on Forehead
    gog_y = head_y - 125
    draw.line([(cx - 210, gog_y + 20), (cx + 210, gog_y + 20)], fill=(45, 30, 20, 255), width=28)
    for gx in [cx - 95, cx + 95]:
        draw.ellipse([gx - 80, gog_y - 68, gx + 80, gog_y + 68], fill=(130, 85, 40, 255), outline=(245, 190, 95, 255), width=8)
        # Lenses
        draw.ellipse([gx - 60, gog_y - 50, gx + 60, gog_y + 50], fill=(25, 165, 100, 255), outline=(160, 255, 200, 255), width=4)
        draw.line([(gx - 38, gog_y - 25), (gx + 18, gog_y - 25)], fill=(255, 255, 255, 220), width=6)
    # Bridge
    draw.rounded_rectangle([cx - 28, gog_y - 14, cx + 28, gog_y + 14], radius=6, fill=(195, 135, 65, 255), outline=(255, 205, 110, 255), width=3)

    # 5. Heavy Excavator Claws & Gauntlets
    claw_y = cy + 340
    for cx_side, flip in [(cx - 230, -1), (cx + 230, 1)]:
        draw.polygon([
            (cx_side - 110 * flip, claw_y + 110),
            (cx_side + 20 * flip, claw_y - 30),
            (cx_side + 110 * flip, claw_y + 80)
        ], fill=(110, 75, 42, 255), outline=(190, 135, 75, 255))
        # 3 Curved Bronze Claws
        for i, offset in enumerate([-45, 0, 45]):
            draw.polygon([
                (cx_side + offset, claw_y + 20),
                (cx_side + int(offset * 1.3), claw_y + 175),
                (cx_side + offset + 25 * flip, claw_y + 50)
            ], fill=(215, 165, 85, 255), outline=(255, 230, 140, 255))

    # Sparks & motes
    draw_particles(draw, 120, (cx - 450, cy - 350, cx + 450, cy + 450), [(80, 240, 150), (140, 255, 190), (220, 255, 230)])

    # Ornate Uncommon Green Border
    border = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    bdraw = ImageDraw.Draw(border)
    bdraw.rectangle([0, 0, SIZE, SIZE], fill=None, outline=(105, 224, 156, 240), width=16)
    bdraw.rectangle([20, 20, SIZE - 20, SIZE - 20], fill=None, outline=(35, 125, 75, 180), width=4)
    for x_c, y_c in [(35, 35), (SIZE - 35, 35), (35, SIZE - 35), (SIZE - 35, SIZE - 35)]:
        bdraw.rectangle([x_c - 12, y_c - 12, x_c + 12, y_c + 12], fill=(105, 224, 156, 255))
    img = Image.alpha_composite(img, border)

    output_path = OUTPUT_DIR / "tunnel-mole-v1.png"
    img.convert("RGB").save(output_path, "PNG", quality=95)
    print(f"Generated {output_path}")


# -------------------------------------------------------------
# 3. RIDGE WARDEN (MYTHIC)
# -------------------------------------------------------------
def render_ridge_warden():
    # Background: Dramatic crimson sunset and aurora over Copperridge peaks
    img = linear_gradient((SIZE, SIZE), (34, 12, 22, 255), (14, 6, 10, 255))
    draw = ImageDraw.Draw(img)

    cx, cy = SIZE // 2, SIZE // 2

    # Jagged mountain peaks silhouette in background
    draw.polygon([(0, int(SIZE * 0.72)), (230, 310), (490, int(SIZE * 0.76))], fill=(48, 18, 30, 255))
    draw.polygon([(int(SIZE * 0.48), int(SIZE * 0.76)), (int(SIZE * 0.76), 280), (SIZE, int(SIZE * 0.70))], fill=(42, 15, 26, 255))
    
    # Molten ruby ore veins cascading down the peaks
    draw.line([(230, 310), (310, 490), (270, 680)], fill=(255, 80, 95, 220), width=8)
    draw.line([(int(SIZE * 0.76), 280), (int(SIZE * 0.71), 470), (int(SIZE * 0.75), 660)], fill=(255, 80, 95, 220), width=8)

    # Giant Mythic Ruby Crystal Clusters
    for ox, oy, scale in [(170, 870, 1.4), (1070, 850, 1.5), (270, 380, 0.8), (980, 360, 0.9)]:
        draw_faceted_gem(draw, int(ox), int(oy), int(80 * scale), int(190 * scale), (140, 18, 38, 255), (230, 40, 68, 255), (255, 140, 155, 255))
        draw_faceted_gem(draw, int(ox - 35 * scale), int(oy + 30 * scale), int(55 * scale), int(120 * scale), (110, 12, 28, 255), (200, 30, 55, 255), (255, 115, 130, 255))
        draw_faceted_gem(draw, int(ox + 35 * scale), int(oy + 30 * scale), int(55 * scale), int(120 * scale), (110, 12, 28, 255), (200, 30, 55, 255), (255, 115, 130, 255))

    # Mythic radiant crimson aurora glow in background
    img = add_radial_light(img, (cx, cy - 100), 580, (240, 40, 70), max_alpha=160)
    img = add_radial_light(img, (cx, cy - 100), 320, (255, 110, 130), max_alpha=190)
    draw = ImageDraw.Draw(img)

    # 2. Mythic Ram Paladin Armor & Torso
    # Flowing Imperial Crimson Paladin Cloak
    draw.polygon([
        (cx - 410, cy + 490),
        (cx - 260, cy + 70),
        (cx + 260, cy + 70),
        (cx + 410, cy + 490),
        (cx, cy + 560)
    ], fill=(135, 18, 34, 255), outline=(245, 190, 85, 255))
    draw.line([(cx - 390, cy + 470), (cx - 250, cy + 80)], fill=(255, 220, 130, 220), width=5)
    draw.line([(cx + 390, cy + 470), (cx + 250, cy + 80)], fill=(255, 220, 130, 220), width=5)

    # Massive Ornate Golden Pauldrons
    for px, flip in [(cx - 250, -1), (cx + 250, 1)]:
        draw.polygon([
            (px - 120, cy + 130),
            (px, cy - 30),
            (px + 120, cy + 130),
            (px, cy + 240)
        ], fill=(205, 150, 55, 255), outline=(255, 225, 125, 255))
        draw.polygon([(px - 90, cy + 120), (px, cy), (px + 90, cy + 120), (px, cy + 200)], fill=(235, 180, 75, 255))
        # Gilded Ruby socket
        draw.ellipse([px - 26, cy + 55, px + 26, cy + 107], fill=(225, 25, 48, 255), outline=(255, 235, 150, 255), width=4)

    # Ornate Crimson & Gold Chestplate
    draw.polygon([
        (cx - 190, cy + 110),
        (cx + 190, cy + 110),
        (cx + 140, cy + 450),
        (cx - 140, cy + 450)
    ], fill=(42, 18, 26, 255), outline=(235, 175, 70, 255))
    
    # Mythic Ridgeheart Ruby Chest Crest
    draw_faceted_gem(draw, cx, cy + 270, 85, 150, (180, 20, 42, 255), (245, 45, 75, 255), (255, 175, 190, 255))

    # 3. Majestic Ram Warden Head & Sweeping Golden Horns
    head_y = cy - 95

    # Sweeping Golden Spiral Horns (Multi-layer 3D arches)
    # Left Horn
    draw.arc([cx - 440, head_y - 300, cx - 70, head_y + 140], start=100, end=330, fill=(195, 140, 50, 255), width=58)
    draw.arc([cx - 440, head_y - 300, cx - 70, head_y + 140], start=100, end=330, fill=(245, 190, 85, 255), width=32)
    draw.arc([cx - 440, head_y - 300, cx - 70, head_y + 140], start=100, end=330, fill=(255, 235, 155, 255), width=10)
    # Right Horn
    draw.arc([cx + 70, head_y - 300, cx + 440, head_y + 140], start=210, end=440, fill=(195, 140, 50, 255), width=58)
    draw.arc([cx + 70, head_y - 300, cx + 440, head_y + 140], start=210, end=440, fill=(245, 190, 85, 255), width=32)
    draw.arc([cx + 70, head_y - 300, cx + 440, head_y + 140], start=210, end=440, fill=(255, 235, 155, 255), width=10)

    # Ram Head & Face Structure
    draw.polygon([
        (cx - 120, head_y - 130),
        (cx + 120, head_y - 130),
        (cx + 75, head_y + 130),
        (cx, head_y + 160),
        (cx - 75, head_y + 130)
    ], fill=(52, 38, 45, 255))
    
    # Noble facial markings
    draw.polygon([(cx - 55, head_y + 35), (cx + 55, head_y + 35), (cx, head_y + 145)], fill=(72, 54, 62, 255))
    draw.ellipse([cx - 32, head_y + 118, cx + 32, head_y + 150], fill=(28, 18, 22, 255))

    # Fiery Glowing Eyes of the Apex Warden
    draw.ellipse([cx - 80, head_y - 5, cx - 35, head_y + 22], fill=(255, 195, 55, 255))
    draw.ellipse([cx + 35, head_y - 5, cx + 80, head_y + 22], fill=(255, 195, 55, 255))
    draw.ellipse([cx - 65, head_y, cx - 50, head_y + 15], fill=(255, 255, 230, 255))
    draw.ellipse([cx + 50, head_y, cx + 65, head_y + 15], fill=(255, 255, 230, 255))

    # 4. Radiant Mythic Crown & Crest
    crown_y = head_y - 160
    draw.polygon([
        (cx - 100, crown_y + 45),
        (cx - 130, crown_y - 65),
        (cx - 50, crown_y - 25),
        (cx, crown_y - 105),
        (cx + 50, crown_y - 25),
        (cx + 130, crown_y - 65),
        (cx + 100, crown_y + 45)
    ], fill=(225, 170, 65, 255), outline=(255, 235, 150, 255))
    # Crown Apex Ruby
    draw_faceted_gem(draw, cx, crown_y - 15, 55, 105, (190, 20, 45, 255), (255, 45, 80, 255), (255, 190, 205, 255))

    # 5. Golden Warden Halberd / Sun Pickaxe
    staff_x = cx + 330
    draw.line([(staff_x, 120), (staff_x - 45, SIZE)], fill=(175, 125, 50, 255), width=26)
    draw.line([(staff_x, 120), (staff_x - 45, SIZE)], fill=(255, 220, 120, 255), width=8)
    draw.polygon([(staff_x - 15, 170), (staff_x + 140, 105), (staff_x + 25, 245)], fill=(235, 185, 80, 255), outline=(255, 240, 170, 255))
    draw_faceted_gem(draw, staff_x + 45, 185, 45, 90, (190, 25, 50, 255), (250, 45, 75, 255), (255, 190, 205, 255))

    # Floating Mythic Embers & Flare particles
    draw_particles(draw, 160, (cx - 480, cy - 380, cx + 480, cy + 480), [(255, 85, 100), (255, 185, 75), (255, 235, 160)], seed=77)

    # Ornate Mythic Crimson & Gold Border
    border = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    bdraw = ImageDraw.Draw(border)
    bdraw.rectangle([0, 0, SIZE, SIZE], fill=None, outline=(255, 113, 105, 245), width=18)
    bdraw.rectangle([22, 22, SIZE - 22, SIZE - 22], fill=None, outline=(242, 193, 83, 200), width=6)
    for x_c, y_c in [(40, 40), (SIZE - 40, 40), (35, SIZE - 40), (SIZE - 40, SIZE - 40)]:
        bdraw.rectangle([x_c - 14, y_c - 14, x_c + 14, y_c + 14], fill=(242, 193, 83, 255))
    img = Image.alpha_composite(img, border)

    output_path = OUTPUT_DIR / "ridge-warden-v1.png"
    img.convert("RGB").save(output_path, "PNG", quality=95)
    print(f"Generated {output_path}")


def main():
    print("Generating enhanced card illustrations...")
    render_field_lantern()
    render_tunnel_mole()
    render_ridge_warden()
    print("All 3 cards rendered successfully!")


if __name__ == "__main__":
    main()
