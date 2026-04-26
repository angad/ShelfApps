#!/usr/bin/env python3
import io
import pathlib
import urllib.request

try:
    from PIL import Image
except ImportError:
    Image = None


STATE_CODES = [
    "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "FL", "GA",
    "HI", "ID", "IL", "IN", "IA", "KS", "KY", "LA", "ME", "MD",
    "MA", "MI", "MN", "MS", "MO", "MT", "NE", "NV", "NH", "NJ",
    "NM", "NY", "NC", "ND", "OH", "OK", "OR", "PA", "RI", "SC",
    "SD", "TN", "TX", "UT", "VT", "VA", "WA", "WV", "WI", "WY",
]

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUTPUT_DIR = ROOT / "CityCams" / "StateFlags"


def render_avatar_flag(image):
    if Image is None:
        return None
    image = image.convert("RGBA")
    target = 120
    scale = max(target / image.width, target / image.height)
    resized = image.resize((round(image.width * scale), round(image.height * scale)), Image.LANCZOS)
    left = (resized.width - target) // 2
    top = (resized.height - target) // 2
    square = resized.crop((left, top, left + target, top + target))

    canvas = Image.new("RGBA", (target, target), (255, 255, 255, 255))
    canvas.alpha_composite(square)
    return canvas


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    for code in STATE_CODES:
        url = f"https://flagcdn.com/160x120/us-{code.lower()}.png"
        with urllib.request.urlopen(url, timeout=30) as response:
            data = response.read()
        output = OUTPUT_DIR / f"StateFlag_{code}.png"
        if Image is None:
            output.write_bytes(data)
        else:
            image = Image.open(io.BytesIO(data))
            avatar = render_avatar_flag(image)
            avatar.save(output)
        print(output.relative_to(ROOT))


if __name__ == "__main__":
    main()
