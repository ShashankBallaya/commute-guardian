"""Draws the notification small icon: a bell, white on transparent.

    python tool/build_notification_icon.py

WHY THIS IS NOT DERIVED FROM THE APP ICON, which is the obvious idea and the
wrong one. Android renders a notification small icon FROM ITS ALPHA CHANNEL
ONLY, tinted to one colour. `tool/build_app_icons.py` already refuses to ship a
monochrome layer for the same reason, in its own words: "this artwork is a
photographic badge: reduced to one colour it is a grey blob". The app icon is
96 percent opaque, so handing it to `setSmallIcon` draws a solid white square,
which is exactly the bug this file fixes (reported from the 3T, 10 Sep 2026:
"I can't see the logo on the locked screen and on the notifications").

SO THE MARK IS AUTHORED, and it is one shape rather than three. The app icon is
a Mumbai local with a bell and two sound arcs; at 24 dp in a single colour the
train is mush and the arcs close up. The BELL survives, and it is also the
element that means what the notification means: this is the thing that will
wake you. Drawn as geometry, never traced from the badge.

WHY PNGs AND NOT A VECTOR. A framework VectorDrawable is legal as a small icon
at this minSdk, and it is one file instead of five. PNGs are what the repo
already generates for every other density-scaled asset, they cannot be
mis-rendered by an OEM skin, and the 3T is exactly the kind of phone that finds
that sort of difference. Cheap insurance on the one surface a sleeping rider
sees.

Drawn large and downsampled, so the curves are antialiased by the resampler
rather than by hand.
"""

import os

from PIL import Image, ImageDraw

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Android status bar icons are 24 dp square at every density.
DENSITIES = {
    "drawable-mdpi": 24,
    "drawable-hdpi": 36,
    "drawable-xhdpi": 48,
    "drawable-xxhdpi": 72,
    "drawable-xxxhdpi": 96,
}

# The name the manifest points at and `RideServiceClient` names in Dart. All
# three have to agree, and `notification_icon_test.dart` is what keeps them so.
NAME = "ic_stat_travel_mode"

MASTER = 480
WHITE = (255, 255, 255, 255)


def bell(size=MASTER):
    """One bell, centred, filling the canvas with a small breathing margin.

    The proportions are the readable ones rather than the realistic ones: a
    real bell is taller than it is wide, and at 24 dp that reads as a drop.
    This is squatter, with a lip wide enough to survive being scaled to 24 px
    and a clapper big enough not to disappear into it.
    """
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    # Crown: the loop a bell hangs from, read at this size as a knob.
    draw.ellipse((214, 40, 266, 92), fill=WHITE)

    # Dome: the upper half of an ellipse.
    draw.pieslice((146, 74, 334, 286), start=180, end=360, fill=WHITE)

    # Flare: the body widening to the mouth. Overlaps the dome so the two
    # union into one silhouette with no seam.
    draw.polygon([(146, 180), (334, 180), (368, 330), (112, 330)], fill=WHITE)

    # Lip: the rim, drawn wider than the mouth so the bell reads as a bell
    # rather than as a cone.
    draw.rounded_rectangle((100, 322, 380, 368), radius=23, fill=WHITE)

    # Clapper, hung clear of the lip. The gap is what makes it read as a
    # separate part; closed up, the whole thing becomes a pear.
    draw.ellipse((206, 386, 274, 454), fill=WHITE)
    return image


def write(image, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    image.save(path, "PNG")
    print(f"  {os.path.relpath(path, REPO)}  {image.size[0]}x{image.size[1]}")


def main():
    master = bell()
    res = os.path.join(REPO, "android", "app", "src", "main", "res")
    print("Android notification icon (white on transparent, alpha is all that ships):")
    for folder, size in DENSITIES.items():
        icon = master.resize((size, size), Image.LANCZOS)
        write(icon, os.path.join(res, folder, f"{NAME}.png"))

    preview = os.path.join(REPO, "assets", "branding", "notification_icon_preview.png")
    # WHAT IT ACTUALLY LOOKS LIKE ON A PHONE: white on a dark shade, at the
    # sizes that matter, so it can be judged without a device.
    strip = Image.new("RGBA", (300, 120), (18, 27, 41, 255))
    strip.alpha_composite(master.resize((24, 24), Image.LANCZOS), (40, 48))
    strip.alpha_composite(master.resize((72, 72), Image.LANCZOS), (120, 24))
    strip.alpha_composite(master.resize((96, 96), Image.LANCZOS), (200, 12))
    write(strip, preview)
    print("\nDone. Rebuild the app; icons are not hot-reloadable.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
