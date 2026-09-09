"""Pre-generate one static stylesheet per family, so no page waits on a Lambda to render CSS.

`fonts.juniorbay.com` is an edge-optimized API Gateway domain with no stage caching, so EVERY page load
invoked a Lambda for a render-blocking resource: `x-cache: Miss` on every request, including identical
repeats, at ~110ms in front of First Contentful Paint. The bytes were never the issue -- the stylesheet is
478 bytes -- the round trip was.

ONE FILE PER FAMILY, not per pairing. A page picks any two or three of 31 families, so pre-generating
combinations means 465+ files; per-family is 31 and covers every combination. It also caches better: a
family's CSS is shared by every page using it, rather than only by pages with that exact pairing.

They live in the same bucket and under the same /fonts/ path as the font files, so they inherit the CORS
behaviour already configured there -- and the CSS finally sits on the same origin as the fonts it points
at, which is the two-host split that produced the 2026-09-08 CORS hunt.

Usage:
    python3 tools/build_family_css.py                 # write to build/css
    python3 tools/build_family_css.py --publish       # and upload
"""

import argparse
import os
import subprocess
import sys
import urllib.parse

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))
from app import find_fonts_by_family, generate_single_font_css  # noqa: E402
from font_definitions import VARIABLE_FONTS  # noqa: E402

BUCKET = "jb-homepage-prod-150544707159"
PREFIX = "fonts/css"
# The weights a page renders. Matches REQUEST_WEIGHTS in stripe-link's domain/fonts.py: body text is 400 and
# every heading weight the template uses resolves to the 700 face.
WEIGHTS = [400, 700]


def slug(family: str) -> str:
    return urllib.parse.quote(family.replace(" ", "-").lower(), safe="-")


def css_for(family: str) -> str:
    """The @font-face rules for one family at the weights pages actually ask for.

    Built with the SERVICE's own generator, so a static file and a live `?family=` response cannot drift
    into saying different things about the same font.
    """
    from app import find_best_weight_match

    fonts = find_fonts_by_family(family)
    normal = {k: v for k, v in fonts.items() if v["style"] == "normal"}
    seen, out = set(), []
    for weight in WEIGHTS:
        key = find_best_weight_match(weight, normal)
        if key and key not in seen:
            seen.add(key)
            out.append(generate_single_font_css(VARIABLE_FONTS[key], "swap"))
    return "".join(out).strip() + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", default="build/css")
    parser.add_argument("--publish", action="store_true")
    args = parser.parse_args()

    families = sorted({f["font_family_name"] for f in VARIABLE_FONTS.values()})
    os.makedirs(args.out, exist_ok=True)
    written = []
    for family in families:
        body = css_for(family)
        if "@font-face" not in body:
            print(f"  {family:<22} SKIPPED — no servable face")
            continue
        name = f"{slug(family)}.css"
        with open(os.path.join(args.out, name), "w", encoding="utf-8") as handle:
            handle.write(body)
        written.append((family, name, len(body)))
        print(f"  {family:<22} {name:<26} {len(body):>5} B  {body.count('@font-face')} face(s)")

    print(f"\n  {len(written)} files in {args.out}")
    if not args.publish:
        return

    for _family, name, _size in written:
        subprocess.run([
            "aws", "s3", "cp", os.path.join(args.out, name), f"s3://{BUCKET}/{PREFIX}/{name}",
            "--content-type", "text/css; charset=utf-8",
            # SHORT, deliberately. These are regenerated whenever the catalogue changes -- a subset, a
            # variable upgrade, a repointed file -- and `immutable` would strand the old ones at every edge
            # for a year. That trap cost hours on 2026-09-08.
            "--cache-control", "public, max-age=3600",
        ], check=True, capture_output=True)
    print(f"  published {len(written)} stylesheets to {PREFIX}/")


if __name__ == "__main__":
    main()
