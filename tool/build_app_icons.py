"""Generates every app-icon asset for both platforms from one artwork file.

Run it, do not hand-edit the PNGs it writes, for the same reason
`tool/build_stations.py` owns the station JSON: there are 26 of them across two
platforms and five densities, and a hand-touched one is a difference nobody
will ever find.

    python tool/build_app_icons.py assets/branding/app_icon_source.png

WHAT THE SOURCE NEEDS. A square image, any size from about 1024 up. It may sit
on a black or transparent surround: this script finds the artwork inside it,
crops to it, and EXTENDS the artwork's own edge colours into the corners, so
what reaches the platforms is a full-bleed square with no dead corners. That
matters because both platforms apply their OWN rounded mask. Shipping artwork
that already has rounded corners on a black ground gives a rounded icon inside
a rounded icon, with black in the gap, which is the single most common way a
good logo becomes a bad app icon.

ANDROID GETS TWO THINGS, and it needs both. Adaptive icons (API 26 and up) are
two layers the launcher masks to whatever shape the phone uses, so the artwork
goes in the foreground scaled into the safe zone, over a background built from
the artwork's own gradient. The legacy PNGs are the fallback below API 26, and
they carry a rounded-rect mask of their own because nothing else will round
them.

NO MONOCHROME LAYER, deliberately. Android 13 themed icons want a single-colour
silhouette, and this artwork is a photographic badge: reduced to one colour it
is a grey blob. An absent monochrome layer means the launcher uses the normal
icon, which is the right outcome; a bad one would ship a grey blob.
"""

import json
import os
import sys

from PIL import Image, ImageFilter

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The five legacy Android densities, in dp-independent pixels.
ANDROID_LEGACY = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}

# Adaptive layers are 108 dp square at each density.
ANDROID_ADAPTIVE = {
    "mipmap-mdpi": 108,
    "mipmap-hdpi": 162,
    "mipmap-xhdpi": 216,
    "mipmap-xxhdpi": 324,
    "mipmap-xxxhdpi": 432,
}

# How much of the 108 dp adaptive canvas the artwork may fill.
#
# The guaranteed-visible area is the centre 72 dp, which is 66.7%. This sits a
# little over it because the artwork is a rounded SQUARE: the only thing outside
# the safe circle is its own corner gradient, and holding it at 66.7% would make
# the train noticeably smaller than every other icon on the launcher.
ADAPTIVE_SCALE = 0.72

# The legacy PNG's corner radius, as a fraction of its width. Roughly the
# platform's own pre-adaptive convention.
LEGACY_RADIUS = 0.20


def artwork_box(image, threshold=60, inset=0.02):
    """The artwork's bounds inside a black or transparent surround.

    CROPS INSIDE THE RIM, and the inset is the whole reason this is not a plain
    `getbbox`. This badge has a soft outer glow that fades to black over a few
    pixels. A bbox taken at the first non-black pixel therefore ENDS on a nearly
    black one, and [extend_edges] would then smear that black outward: the first
    run produced an icon with a dark fringe down its right and bottom edges,
    caught in a preview render rather than on a phone.
    """
    rgba = image.convert("RGBA")
    # A pixel counts as artwork if it is opaque AND clearly not the surround.
    # Either test alone misses one of the two ways a designer exports a badge.
    mask = Image.new("L", rgba.size, 0)
    pixels = mask.load()
    source = rgba.load()
    width, height = rgba.size
    for y in range(height):
        for x in range(width):
            r, g, b, a = source[x, y]
            if a > 8 and (r + g + b) > threshold * 3:
                pixels[x, y] = 255
    box = mask.getbbox()
    if not box:
        return (0, 0, width, height)
    left, top, right, bottom = box
    bite = int(min(right - left, bottom - top) * inset)
    return (left + bite, top + bite, right - bite, bottom - bite)


def extend_edges(image):
    """Fills the surround by extending the artwork's own edge colours outward.

    A rounded rectangle leaves colour on every row it occupies, so running the
    rows first fills all four corners; the few rows above and below the artwork
    are then filled down the columns. The result is a full-bleed square whose
    corners carry the local gradient rather than a flat guess at it.
    """
    rgb = image.convert("RGB")
    width, height = rgb.size
    pixels = rgb.load()

    # Higher than the crop's own threshold on purpose: whatever seeds the
    # extension is repeated across every filled pixel, so a dim rim pixel here
    # costs a whole dark edge. See the note in [artwork_box].
    def is_art(x, y):
        r, g, b = pixels[x, y]
        return (r + g + b) > 240

    filled_rows = []
    for y in range(height):
        first = next((x for x in range(width) if is_art(x, y)), None)
        if first is None:
            continue
        last = next(x for x in range(width - 1, -1, -1) if is_art(x, y))
        left, right = pixels[first, y], pixels[last, y]
        for x in range(first):
            pixels[x, y] = left
        for x in range(last + 1, width):
            pixels[x, y] = right
        filled_rows.append(y)

    if filled_rows:
        top, bottom = filled_rows[0], filled_rows[-1]
        for y in range(top):
            for x in range(width):
                pixels[x, y] = pixels[x, top]
        for y in range(bottom + 1, height):
            for x in range(width):
                pixels[x, y] = pixels[x, bottom]
    return rgb


def master_square(source_path, size=1024):
    """The artwork as a full-bleed opaque square, ready for either platform."""
    image = Image.open(source_path)
    cropped = image.crop(artwork_box(image))
    # Square it before extending, so the extension is symmetric and the artwork
    # is not stretched by a source that is a pixel or two off square.
    side = max(cropped.size)
    canvas = Image.new("RGB", (side, side), (0, 0, 0))
    canvas.paste(
        cropped.convert("RGB"),
        ((side - cropped.width) // 2, (side - cropped.height) // 2),
    )
    return extend_edges(canvas).resize((size, size), Image.LANCZOS)


def gradient_background(master, size):
    """The artwork's colour field with its subject blurred out of it.

    Downscaled to almost nothing and blown back up: what survives is the
    purple-to-orange wash the badge is painted on, with the train and the bell
    gone. That is what an adaptive background layer wants, because the launcher
    may mask it to any shape and a subject in it would be cut in half.
    """
    tiny = master.resize((6, 6), Image.LANCZOS)
    field = tiny.resize((size, size), Image.BICUBIC)
    return field.filter(ImageFilter.GaussianBlur(radius=size / 12))


def rounded(image, radius_fraction=LEGACY_RADIUS):
    """The image with rounded corners, as RGBA."""
    size = image.size[0]
    mask = Image.new("L", (size * 4, size * 4), 0)
    from PIL import ImageDraw

    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, size * 4 - 1, size * 4 - 1),
        radius=int(size * 4 * radius_fraction),
        fill=255,
    )
    mask = mask.resize((size, size), Image.LANCZOS)
    out = image.convert("RGBA")
    out.putalpha(mask)
    return out


def write(image, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    image.save(path, "PNG")
    print(f"  {os.path.relpath(path, REPO)}  {image.size[0]}x{image.size[1]}")


def build_android(master):
    res = os.path.join(REPO, "android", "app", "src", "main", "res")
    print("Android legacy (below API 26):")
    for folder, size in ANDROID_LEGACY.items():
        icon = rounded(master.resize((size, size), Image.LANCZOS))
        write(icon, os.path.join(res, folder, "ic_launcher.png"))
        # The round variant, for launchers that ask for one by name.
        circle = master.resize((size, size), Image.LANCZOS)
        write(rounded(circle, 0.5), os.path.join(res, folder, "ic_launcher_round.png"))

    print("Android adaptive (API 26 and up):")
    for folder, size in ANDROID_ADAPTIVE.items():
        write(
            gradient_background(master, size),
            os.path.join(res, folder, "ic_launcher_background.png"),
        )
        inner = int(size * ADAPTIVE_SCALE)
        layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        art = rounded(master.resize((inner, inner), Image.LANCZOS), 0.16)
        offset = (size - inner) // 2
        layer.paste(art, (offset, offset), art)
        write(layer, os.path.join(res, folder, "ic_launcher_foreground.png"))

    anydpi = os.path.join(res, "mipmap-anydpi-v26")
    os.makedirs(anydpi, exist_ok=True)
    xml = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@mipmap/ic_launcher_background" />\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
        "</adaptive-icon>\n"
    )
    for name in ("ic_launcher.xml", "ic_launcher_round.xml"):
        with open(os.path.join(anydpi, name), "w", encoding="utf-8") as handle:
            handle.write(xml)
        print(f"  {os.path.join('mipmap-anydpi-v26', name)}")


def build_ios(master):
    """Every size Contents.json asks for, opaque, with no alpha channel.

    NO ALPHA IS NOT A STYLE CHOICE. App Store Connect rejects an icon with a
    transparency channel outright, and it is the rejection that arrives after
    the build has already uploaded.
    """
    appicon = os.path.join(
        REPO, "ios", "Runner", "Assets.xcassets", "AppIcon.appiconset"
    )
    with open(os.path.join(appicon, "Contents.json"), encoding="utf-8") as handle:
        contents = json.load(handle)

    print("iOS:")
    for entry in contents["images"]:
        filename = entry.get("filename")
        if not filename:
            continue
        points = float(entry["size"].split("x")[0])
        scale = int(entry["scale"].rstrip("x"))
        pixels = int(round(points * scale))
        icon = master.resize((pixels, pixels), Image.LANCZOS).convert("RGB")
        write(icon, os.path.join(appicon, filename))


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 1
    source = sys.argv[1]
    master = master_square(source)
    branding = os.path.join(REPO, "assets", "branding")
    os.makedirs(branding, exist_ok=True)
    write(master, os.path.join(branding, "app_icon_master.png"))
    # Google Play wants its own 512 square, and it is the one icon a REVIEWER
    # sees before any device does. Generated here rather than exported by hand
    # for the same reason as every other size: a hand-resized copy drifts from
    # the master and nobody notices until the listing looks wrong beside the
    # installed app.
    write(
        master.resize((512, 512), Image.LANCZOS),
        os.path.join(branding, "play_store_icon_512.png"),
    )
    build_android(master)
    build_ios(master)
    print("\nDone. Rebuild both apps; icons are not hot-reloadable.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
