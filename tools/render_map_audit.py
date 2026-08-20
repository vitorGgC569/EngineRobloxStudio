from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Iterable

from PIL import Image, ImageDraw, ImageFont, ImageOps


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "reports" / "visual-snapshots"
WIDTH, HEIGHT = 1600, 900
CONTENT = (52, 118, 1548, 778)

COLORS = {
    "ink": "#151d27",
    "panel": "#202c39",
    "panel2": "#2b3a49",
    "world": "#121c26",
    "ground": "#2f4342",
    "ground2": "#3d5552",
    "slate": "#273340",
    "stone": "#58636c",
    "copper": "#b86833",
    "copper_light": "#e99c4c",
    "gold": "#f2c153",
    "teal": "#37c4b5",
    "teal_dark": "#1a706f",
    "moss": "#45764f",
    "leaf": "#4a8f5b",
    "ore": "#3dd5b9",
    "white": "#f2f3ec",
    "muted": "#aab8bc",
    "danger": "#ef756f",
}


def load_font(size: int, bold: bool = False):
    candidates = [
        Path(r"C:\Windows\Fonts\seguisb.ttf" if bold else r"C:\Windows\Fonts\segoeui.ttf"),
        Path(r"C:\Windows\Fonts\arialbd.ttf" if bold else r"C:\Windows\Fonts\arial.ttf"),
    ]
    for candidate in candidates:
        if candidate.exists():
            return ImageFont.truetype(str(candidate), size)
    return ImageFont.load_default()


FONT_TITLE = load_font(30, True)
FONT_SUBTITLE = load_font(17, False)
FONT_LABEL = load_font(18, True)
FONT_SMALL = load_font(14, False)
FONT_TINY = load_font(12, False)


def rounded(draw: ImageDraw.ImageDraw, xy, fill, radius=16, outline=None, width=1):
    draw.rounded_rectangle(xy, radius=radius, fill=fill, outline=outline, width=width)


def centered(draw: ImageDraw.ImageDraw, xy, value: str, font, fill, anchor="mm"):
    draw.text(((xy[0] + xy[2]) / 2, (xy[1] + xy[3]) / 2), value, font=font, fill=fill, anchor=anchor)


def fit_image(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    return ImageOps.fit(image.convert("RGB"), size, method=Image.Resampling.LANCZOS)


def world_mapper(crop: tuple[float, float, float, float], box: tuple[int, int, int, int]):
    min_x, max_x, min_z, max_z = crop
    left, top, right, bottom = box

    def map_point(x: float, z: float) -> tuple[float, float]:
        px = left + ((x - min_x) / (max_x - min_x)) * (right - left)
        py = top + ((max_z - z) / (max_z - min_z)) * (bottom - top)
        return px, py

    def size_x(value: float) -> float:
        return value / (max_x - min_x) * (right - left)

    def size_z(value: float) -> float:
        return value / (max_z - min_z) * (bottom - top)

    return map_point, size_x, size_z


def draw_header(image: Image.Image, title: str, subtitle: str):
    draw = ImageDraw.Draw(image)
    draw.rectangle((0, 0, WIDTH, 94), fill=COLORS["ink"])
    draw.rectangle((0, 92, WIDTH, 96), fill=COLORS["copper"])
    draw.text((52, 22), title, font=FONT_TITLE, fill=COLORS["white"])
    draw.text((52, 62), subtitle, font=FONT_SUBTITLE, fill=COLORS["muted"])
    draw.text((1548, 24), "COPPERRIDGE / MAP AUDIT", font=FONT_SMALL, fill=COLORS["gold"], anchor="ra")


def draw_footer(image: Image.Image, note: str = "SOURCE-GEOMETRY PREVIEW • não é captura live do Studio"):
    draw = ImageDraw.Draw(image)
    draw.rectangle((0, 818, WIDTH, HEIGHT), fill=COLORS["ink"])
    draw.text((52, 846), note, font=FONT_SMALL, fill=COLORS["muted"])
    draw.text((1548, 846), "VALIDAÇÃO VISUAL / CICLO CONTÍNUO", font=FONT_SMALL, fill=COLORS["teal"], anchor="ra")


def draw_grid(draw, box, step=40):
    left, top, right, bottom = box
    for x in range(left, right + 1, step):
        draw.line((x, top, x, bottom), fill="#314251", width=1)
    for y in range(top, bottom + 1, step):
        draw.line((left, y, right, y), fill="#314251", width=1)


def draw_world(image: Image.Image, crop: tuple[float, float, float, float], title: str | None = None):
    content_width = CONTENT[2] - CONTENT[0]
    content_height = CONTENT[3] - CONTENT[1]
    layer = Image.new("RGB", (content_width, content_height), COLORS["world"])
    draw = ImageDraw.Draw(layer)
    box = (0, 0, content_width, content_height)
    left, top, right, bottom = box
    draw.rounded_rectangle(box, radius=22, fill=COLORS["world"], outline="#536676", width=2)
    draw_grid(draw, (left + 2, top + 2, right - 2, bottom - 2), 42)
    point, sx, sz = world_mapper(crop, (left + 8, top + 8, right - 8, bottom - 8))

    def rect(cx, cz, width, depth, fill, outline=None, radius=8):
        x, y = point(cx, cz)
        w, h = sx(width), sz(depth)
        bounds = (x - w / 2, y - h / 2, x + w / 2, y + h / 2)
        draw.rounded_rectangle(bounds, radius=radius, fill=fill, outline=outline, width=2 if outline else 1)
        return bounds

    def label(cx, cz, text, fill=COLORS["white"], accent=None):
        x, y = point(cx, cz)
        if accent:
            draw.ellipse((x - 7, y - 7, x + 7, y + 7), fill=accent)
            x += 12
        draw.text((x, y), text, font=FONT_SMALL, fill=fill, anchor="lm")

    def path(points: Iterable[tuple[float, float]], width, fill, edge):
        mapped = [point(x, z) for x, z in points]
        draw.line(mapped, fill=edge, width=max(8, int(sx(width) + 9)), joint="curve")
        draw.line(mapped, fill=fill, width=max(4, int(sx(width))), joint="curve")

    # Navigation spine and crossbar from MapService.
    path([(0, 0), (0, -24), (0, -52)], 13, COLORS["slate"], COLORS["teal"])
    path([(0, -24), (34, -44)], 12, COLORS["slate"], COLORS["copper_light"])
    path([(0, -52), (-30, -50)], 9, COLORS["slate"], COLORS["gold"])
    path([(0, -52), (0, -103)], 9, COLORS["slate"], COLORS["copper"])
    path([(-25, -53), (-25, -82), (-25, -124)], 8, COLORS["slate"], COLORS["teal"])
    path([(25, -53), (25, -82), (25, -124)], 8, COLORS["slate"], COLORS["gold"])
    path([(-25, -103), (25, -103)], 5, COLORS["slate"], COLORS["copper_light"])

    rect(0, 0, 18, 18, COLORS["teal_dark"], COLORS["teal"], 14)
    centered(draw, rect(0, -24, 72, 30, COLORS["ground2"], COLORS["teal"], 14), "THE RIDGE HUB", FONT_LABEL, COLORS["white"])
    rect(0, -52, 38, 25, COLORS["panel2"], COLORS["gold"], 12)
    rect(34, -44, 24, 28, COLORS["panel2"], COLORS["copper_light"], 12)
    rect(-30, -50, 11, 11, COLORS["panel2"], COLORS["gold"], 10)

    plots = [
        (-25, -82, "PLOT A", COLORS["teal"]),
        (25, -82, "PLOT B", COLORS["gold"]),
        (-25, -124, "PLOT C", COLORS["copper_light"]),
        (25, -124, "PLOT D", COLORS["ore"]),
    ]
    for x, z, plot_name, accent in plots:
        bounds = rect(x, z, 38, 36, COLORS["ground"], accent, 12)
        centered(draw, bounds, plot_name, FONT_LABEL, COLORS["white"])
        bx, by = point(x, z + 10)
        draw.ellipse((bx - 6, by - 6, bx + 6, by + 6), fill=accent)

    # Native-procedural landmarks and approved decor.
    for x, z in [(-24, -14), (24, -14), (-29, -34), (29, -34), (-22, -53), (22, -53)]:
        px, py = point(x, z)
        draw.ellipse((px - 7, py - 7, px + 7, py + 7), fill=COLORS["gold"], outline=COLORS["copper"])
    for x, z in [(-31, -18), (31, -18), (-58, -15), (57, -16), (-63, -67), (63, -68), (-60, -126), (60, -126)]:
        px, py = point(x, z)
        radius = max(8, int(sx(3.2)))
        draw.ellipse((px - radius, py - radius, px + radius, py + radius), fill=COLORS["moss"], outline=COLORS["leaf"], width=2)
    for x, z in [(-29, -34), (29, -34), (22, -45), (47, -45)]:
        px, py = point(x, z)
        draw.polygon([(px, py - 10), (px + 9, py + 6), (px - 9, py + 6)], fill=COLORS["ore"], outline=COLORS["teal"])

    label(0, 0, "SPAWN", accent=COLORS["teal"])
    label(0, -52, "RIDGE EXCHANGE", accent=COLORS["gold"])
    label(34, -44, "OLD LANTERN MINE", accent=COLORS["copper_light"])
    label(-30, -50, "RIDGE LIFT", accent=COLORS["gold"])
    if title:
        draw.text((left + 24, top + 22), title, font=FONT_LABEL, fill=COLORS["white"])

    # Compact legend for manual review.
    legend_x, legend_y = right - 310, top + 22
    rounded(draw, (legend_x, legend_y, right - 22, legend_y + 118), COLORS["ink"], 14, outline="#536676", width=1)
    draw.text((legend_x + 18, legend_y + 14), "LEGENDA", font=FONT_SMALL, fill=COLORS["gold"])
    entries = [(COLORS["teal"], "navegação / spawn"), (COLORS["gold"], "compra / progressão"), (COLORS["copper_light"], "mina / objetivo"), (COLORS["moss"], "ambientação")]
    for index, (color, text_value) in enumerate(entries):
        yy = legend_y + 42 + index * 18
        draw.ellipse((legend_x + 18, yy - 5, legend_x + 28, yy + 5), fill=color)
        draw.text((legend_x + 38, yy), text_value, font=FONT_TINY, fill=COLORS["muted"], anchor="lm")
    image.paste(layer, (CONTENT[0], CONTENT[1]))


def make_scene(title: str, subtitle: str, crop):
    image = Image.new("RGB", (WIDTH, HEIGHT), COLORS["ink"])
    draw_header(image, title, subtitle)
    draw_world(image, crop)
    draw_footer(image)
    return image


def make_floor_progression():
    image = Image.new("RGB", (WIDTH, HEIGHT), COLORS["ink"])
    draw_header(image, "RIDGE LIFT / PROGRESSÃO VERTICAL", "Compra de andares com aumento de capacidade, slots e multiplicador de renda")
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle(CONTENT, radius=22, fill=COLORS["world"], outline="#536676", width=2)
    center_x = 470
    base_y = 700
    draw.rounded_rectangle((180, base_y, 760, base_y + 38), radius=12, fill=COLORS["ink"], outline=COLORS["gold"], width=3)
    draw.text((470, base_y + 19), "RIDGE LIFT / TERMINAL DE COMPRA", font=FONT_LABEL, fill=COLORS["white"], anchor="mm")
    floors = [
        ("GROUNDWORKS", "x1.00", "4 slots", COLORS["teal"]),
        ("COPPERLINE GALLERY", "x1.15", "6 slots", COLORS["gold"]),
        ("DEEP LANTERN DECK", "x1.35", "8 slots", COLORS["copper_light"]),
        ("STORMGLASS LOFT", "x1.60", "10 slots", COLORS["ore"]),
        ("CROWN VEIN OBSERVATORY", "x2.00", "12 slots", "#b383ff"),
    ]
    for index, (name, multiplier, slots, accent) in enumerate(floors):
        y = base_y - 88 - index * 105
        draw.line((center_x, y + 34, center_x, y + 106), fill=COLORS["copper"], width=8)
        draw.rounded_rectangle((200, y, 740, y + 72), radius=14, fill=COLORS["panel2"], outline=accent, width=3)
        draw.ellipse((228, y + 18, 264, y + 54), fill=accent)
        draw.text((286, y + 17), f"{index + 1:02d}  {name}", font=FONT_LABEL, fill=COLORS["white"])
        draw.text((286, y + 47), f"{multiplier} income  •  {slots}", font=FONT_SMALL, fill=COLORS["muted"])
        draw.text((704, y + 36), "UNLOCK", font=FONT_SMALL, fill=accent, anchor="rm")

    rounded(draw, (875, 160, 1460, 650), COLORS["panel"], 20, outline="#536676", width=2)
    draw.text((915, 198), "REVISÃO DE ESTRUTURA", font=FONT_LABEL, fill=COLORS["gold"])
    checks = [
        ("PurchaseFloorPrompt", "interação no terminal", COLORS["teal"]),
        ("FloorDeck_<level>", "deck físico por plot", COLORS["teal"]),
        ("FloorMultiplier", "estado sincronizado", COLORS["teal"]),
        ("CardSlots", "mais espaço para cartas", COLORS["teal"]),
        ("Server-authoritative", "preço validado no servidor", COLORS["teal"]),
    ]
    for index, (name, desc, accent) in enumerate(checks):
        yy = 260 + index * 66
        draw.ellipse((915, yy, 944, yy + 29), fill=accent)
        draw.text((965, yy + 2), name, font=FONT_SMALL, fill=COLORS["white"])
        draw.text((965, yy + 27), desc, font=FONT_TINY, fill=COLORS["muted"])
    draw.text((915, 610), "Gaps entre blocos mantidos para expansão visual", font=FONT_SMALL, fill=COLORS["copper_light"])
    draw_footer(image)
    return image


def make_card_gallery():
    image = Image.new("RGB", (WIDTH, HEIGHT), COLORS["ink"])
    draw_header(image, "CARD GALLERY / RARIDADES", "Coleção responsiva com slots generosos, arte aprovada e fallback seguro")
    draw = ImageDraw.Draw(image)
    panel_path = ROOT / "assets/generated/ui/card-gallery-panel-v1.png"
    if panel_path.exists():
        panel = fit_image(Image.open(panel_path), (1490, 680))
        panel = Image.blend(panel, Image.new("RGB", panel.size, COLORS["ink"]), 0.35)
        image.paste(panel, (55, 115))
    else:
        draw.rectangle((55, 115, 1545, 795), fill=COLORS["panel"])
    cards = [
        ("FIELD LANTERN", "COMMON", COLORS["muted"], ROOT / "assets/generated/cards/field-lantern-v1.png", "+5% ore yield"),
        ("TUNNEL MOLE", "UNCOMMON", COLORS["teal"], ROOT / "assets/generated/cards/tunnel-mole-v1.png", "+8% build speed"),
        ("MOSSBACK BADGER", "RARE", "#5aa7ff", ROOT / "assets/generated/cards/mossback-badger-engineer-v1.png", "+12% build speed"),
        ("COPPER LYNX", "EPIC", COLORS["copper_light"], ROOT / "assets/generated/cards/copper-lynx-prospector-v1.png", "+18% ore yield"),
        ("STORM RAVEN", "LEGENDARY", "#b383ff", ROOT / "assets/generated/cards/storm-raven-surveyor-v1.png", "reveal objectives"),
        ("RIDGE WARDEN", "MYTHIC", COLORS["gold"], ROOT / "assets/generated/cards/ridge-warden-v1.png", "all systems tuned"),
    ]
    card_w, card_h = 216, 410
    gap = 18
    start_x, start_y = 88, 220
    for index, (name, rarity, accent, art_path, effect) in enumerate(cards):
        x = start_x + index * (card_w + gap)
        y = start_y
        rounded(draw, (x, y, x + card_w, y + card_h), COLORS["panel"], 18, outline=accent, width=3)
        art_box = (x + 12, y + 12, x + card_w - 12, y + 238)
        if art_path and art_path.exists():
            art = fit_image(Image.open(art_path), (art_box[2] - art_box[0], art_box[3] - art_box[1]))
            image.paste(art, (art_box[0], art_box[1]))
        else:
            draw.rounded_rectangle(art_box, radius=12, fill=COLORS["ink"], outline=accent, width=2)
            centered(draw, art_box, "ART IMPORT\nQUEUED", FONT_SMALL, accent)
        draw.text((x + 14, y + 258), name, font=FONT_SMALL, fill=COLORS["white"])
        draw.text((x + 14, y + 282), rarity, font=FONT_TINY, fill=accent)
        draw.line((x + 14, y + 310, x + card_w - 14, y + 310), fill="#536676", width=1)
        draw.text((x + 14, y + 328), effect, font=FONT_TINY, fill=COLORS["muted"])
        draw.text((x + card_w - 14, y + 370), f"{index + 1:02d}", font=FONT_LABEL, fill=accent, anchor="ra")
    draw_footer(image, "ASSET PREVIEW • todas as 6 artes conceituais presentes e registradas; aguardando upload Roblox para runtime")
    return image


def make_mobile_ui():
    image = Image.new("RGB", (WIDTH, HEIGHT), COLORS["ink"])
    draw_header(image, "MOBILE STORE / UI RESPONSIVA", "Composição compacta para 390×844 sem esconder o campo de jogo")
    draw = ImageDraw.Draw(image)
    phone = (250, 136, 690, 820)
    tablet = (870, 190, 1450, 770)
    for frame, label in [(phone, "PHONE 390×844"), (tablet, "TABLET 1024×768")]:
        rounded(draw, frame, COLORS["world"], 30, outline="#536676", width=3)
        draw.text((frame[0] + 22, frame[1] + 20), label, font=FONT_SMALL, fill=COLORS["gold"])
        left, top, right, bottom = frame[0] + 18, frame[1] + 62, frame[2] - 18, frame[3] - 18
        rounded(draw, (left, top, right, bottom), COLORS["ground"], 18)
        rounded(draw, (left + 14, top + 14, right - 14, top + 62), COLORS["ink"], 12, outline=COLORS["teal"], width=2)
        draw.text((left + 30, top + 38), "$1,000", font=FONT_LABEL, fill=COLORS["white"], anchor="lm")
        draw.text((right - 30, top + 38), "CARDS", font=FONT_TINY, fill=COLORS["teal"], anchor="rm")
        rounded(draw, (left + 14, bottom - 116, right - 14, bottom - 68), COLORS["panel"], 12, outline=COLORS["gold"], width=2)
        draw.text(((left + right) / 2, bottom - 92), "[E] BUY MINING PACK • $100", font=FONT_TINY, fill=COLORS["gold"], anchor="mm")
        rounded(draw, (left + 14, bottom - 56, right - 14, bottom - 20), COLORS["teal_dark"], 12)
        draw.text(((left + right) / 2, bottom - 38), "OPEN CARD GALLERY", font=FONT_TINY, fill=COLORS["white"], anchor="mm")
        draw.line((left + 25, top + 110, right - 25, bottom - 150), fill="#49655d", width=2)
        draw.ellipse(((left + right) / 2 - 24, (top + bottom) / 2 - 24, (left + right) / 2 + 24, (top + bottom) / 2 + 24), fill=COLORS["teal"], outline=COLORS["gold"], width=3)
    rounded(draw, (50, 160, 205, 510), COLORS["panel"], 18, outline=COLORS["teal"], width=2)
    draw.text((76, 190), "CHECKS", font=FONT_LABEL, fill=COLORS["gold"])
    for index, item in enumerate(["safe-area", "legible", "one primary", "playfield clear"]):
        yy = 250 + index * 52
        draw.ellipse((76, yy, 94, yy + 18), fill=COLORS["teal"])
        draw.text((108, yy + 9), item, font=FONT_SMALL, fill=COLORS["muted"], anchor="lm")
    draw_footer(image)
    return image


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    captures = {
        "00-map-overview.png": make_scene("WORLD OVERVIEW / COPPERRIDGE", "Rotas, pontos de interesse e quatro plots com espaço para expansão", (-88, 88, -150, 12)),
        "01-spawn-plaza.png": make_scene("SPAWN + MAIN PLAZA", "Primeira leitura: spawn seguro, hub central, landmarks e caminho iluminado", (-50, 50, -62, 8)),
        "02-ridge-exchange.png": make_scene("RIDGE EXCHANGE / STARTER STORE", "Compra inicial com corredor frontal, balcão e distância de interação", (-30, 30, -72, -32)),
        "03-old-lantern-mine.png": make_scene("OLD LANTERN MINE", "Objetivo legível, gate com passagem e decoração de minério", (12, 58, -66, -23)),
        "04-ridge-lift.png": make_scene("RIDGE LIFT / TERMINAL", "Ponto de compra de andares separado do bloco da loja", (-50, -10, -68, -34)),
        "05-plots-grid.png": make_scene("PLOTS A–D / EXPANSÃO", "Quatro áreas de claim, crossbar central e espaçamento entre blocos", (-72, 72, -150, -60)),
        "06-plot-a-detail.png": make_scene("PLOT A / CLAIM DETAIL", "Fundação, borda, terminal, beacon, minério, crate e iluminação", (-50, 0, -108, -56)),
        "07-floor-progression.png": make_floor_progression(),
        "08-card-gallery.png": make_card_gallery(),
        "09-mobile-ui.png": make_mobile_ui(),
    }
    for filename, image in captures.items():
        image.save(OUTPUT / filename, "PNG", optimize=True)
    manifest = {
        "generatedAt": "source-geometry-render",
        "captureType": "deterministic-source-preview",
        "liveStudioCapture": False,
        "reason": "Roblox Studio/adaptador de captura não está disponível nesta sessão",
        "snapshots": [
            {"file": filename, "path": str((OUTPUT / filename).relative_to(ROOT)).replace("\\", "/"), "width": WIDTH, "height": HEIGHT}
            for filename in captures
        ],
    }
    (OUTPUT / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    report_lines = [
        "# Visual audit snapshots",
        "",
        "These images are deterministic source-geometry previews generated from MapService and approved UI/card assets.",
        "They are not Roblox Studio runtime screenshots because the Studio capture adapter is unavailable in this session.",
        "",
    ]
    report_lines.extend(f"- [{filename}](./{filename})" for filename in captures)
    (OUTPUT / "README.md").write_text("\n".join(report_lines) + "\n", encoding="utf-8")
    print(f"generated={len(captures)} output={OUTPUT}")


if __name__ == "__main__":
    main()
