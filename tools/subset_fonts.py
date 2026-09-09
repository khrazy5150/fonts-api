"""Subset a catalogued font to the characters pages actually render.

The catalogue's WOFF2 files are unsubset originals: Merriweather carries 1,508 glyphs of Cyrillic, Greek,
Vietnamese and Latin-Extended for pages that render none of them. Because `fs=true` embeds the bytes in the
stylesheet, that weight lands directly on the critical path -- one preset shipped an 848 KB render-blocking
stylesheet. Subsetting to Latin cut every pairing 3-4x (4,228 KB -> 1,344 KB weighted by preset usage) and
moved a real page +18 PageSpeed points on 2026-09-08.

Three things this encodes that are easy to get wrong:

  * KEEP fvar/gvar/HVAR. A careless subset silently flattens a variable font to static. Nothing errors --
    it shows up only as faux-bold headings on a published page, so the axes are verified after every write.
  * PRUNE layout features, but not all of them. Keeping every feature left Merriweather at 200 KB; pruning
    to the ones our CSS can actually invoke got it to 93 KB, matching Google's own Latin cut. Dropping
    `kern` or `liga` would visibly change text, so they stay.
  * NEW filename, never in place. These files are served `immutable` for a year, so overwriting one keeps
    every warm CloudFront edge serving the old bytes. `Foo-Variable.woff2` -> `Foo-Variable-latin.woff2`,
    and the original stays in the bucket so a repoint is the whole revert.

The output is not uploaded and the catalogue is not edited: this prints the two commands so the change is
deliberate. Emoji are NOT in these ranges and never were -- they render from the system emoji font by normal
fallback.

Requires fontTools (`pip install fonttools brotli`); it is a build-time tool, not Lambda code.

Usage:
    python3 tools/subset_fonts.py --family Merriweather
    python3 tools/subset_fonts.py --family "Source Sans 3" --charset latin-ext
    python3 tools/subset_fonts.py --all --out build/subset
"""

import argparse
import os
import string
import sys
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))
from font_definitions import VARIABLE_FONTS  # noqa: E402

CDN = "https://juniorbay.com/fonts"

# Google's own unicode-ranges, so our cuts line up with what the rest of the web assumes.
# `latin` covers Latin-1: English, French, German, Spanish, Portuguese, Italian, Dutch, Nordic.
# `latin-ext` adds Latin Extended-A/B: Polish, Czech, Turkish, Hungarian, Romanian, Croatian, Baltic.
CHARSETS = {
    "latin": (
        "U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,U+02DA,U+02DC,U+0304,U+0308,U+0329,"
        "U+2000-206F,U+2074,U+20AC,U+2122,U+2191,U+2193,U+2212,U+2215,U+FEFF,U+FFFD"
    ),
}
CHARSETS["latin-ext"] = (
    CHARSETS["latin"] + ",U+0100-02AF,U+0300-0301,U+0303,U+0309,U+0323,U+1E00-1EFF,U+2020,"
    "U+20A0-20AB,U+20AD-20CF,U+2113,U+2C60-2C7F,U+A720-A7FF"
)

# Kerning, ligatures and mark positioning are what make text look right. Swashes, small caps, oldstyle
# figures and the rest are never invoked by our CSS and only cost bytes.
FEATURES = ["kern", "liga", "clig", "calt", "ccmp", "locl", "mark", "mkmk", "rlig"]

# A page renders prices, punctuation and quotes as readily as letters; a subset missing any of these would
# show tofu on a published page rather than fail here.
REQUIRED = set(string.ascii_letters + string.digits + " .,!?'\"()-–—:;/&%$€£@#*+=…‘’“”")


def entries_for(family: str | None) -> list[dict]:
    rows = [f for f in VARIABLE_FONTS.values() if family is None or f["font_family_name"] == family]
    if family is not None and not rows:
        known = sorted({f["font_family_name"] for f in VARIABLE_FONTS.values()})
        sys.exit(f"No such family: {family!r}\nKnown: {', '.join(known)}")
    return rows


def subset_one(entry: dict, charset: str, out_dir: str) -> tuple[str, int, int] | None:
    from fontTools import subset
    from fontTools.ttLib import TTFont

    name = entry["file_name"]
    if "-latin" in name:
        print(f"  {name:<44} already a subset, skipped")
        return None

    url = f"{CDN}/{entry['folder_name']}/{name}"
    raw = urllib.request.urlopen(url, timeout=120).read()
    src = os.path.join(out_dir, f".{name}")
    os.makedirs(out_dir, exist_ok=True)
    with open(src, "wb") as handle:
        handle.write(raw)

    before = TTFont(src)
    axes_before = ({a.axisTag: (a.minValue, a.maxValue) for a in before["fvar"].axes}
                   if "fvar" in before else {})

    options = subset.Options()
    options.flavor = "woff2"
    options.notdef_outline = True
    options.drop_tables = []          # fvar/gvar/HVAR must survive
    options.layout_features = FEATURES
    options.hinting = False           # WOFF2 on modern rasterisers does not need TT hinting
    options.glyph_names = False
    options.name_IDs = [1, 2, 3, 4, 6]

    font = subset.load_font(src, options)
    subsetter = subset.Subsetter(options=options)
    subsetter.populate(unicodes=subset.parse_unicodes(CHARSETS[charset]))
    subsetter.subset(font)

    suffix = "-latin" if charset == "latin" else f"-{charset}"
    out_name = name.replace(".woff2", f"{suffix}.woff2")
    out_path = os.path.join(out_dir, out_name)
    subset.save_font(font, out_path, options)
    os.remove(src)

    after = TTFont(out_path)
    axes_after = ({a.axisTag: (a.minValue, a.maxValue) for a in after["fvar"].axes}
                  if "fvar" in after else {})
    covered = set()
    for table in after["cmap"].tables:
        covered |= {chr(c) for c in table.cmap}
    missing = sorted(REQUIRED - covered)

    if axes_after != axes_before:
        sys.exit(f"REFUSING {out_name}: variable axes changed {axes_before} -> {axes_after}. "
                 "A flattened variable font renders faux-bold and nothing would report it.")
    if missing:
        sys.exit(f"REFUSING {out_name}: missing characters a page renders: {missing}")

    b, a = len(raw), os.path.getsize(out_path)
    kind = "variable" if axes_after else "static"
    print(f"  {name:<44} {b/1024:>7.1f} -> {a/1024:>6.1f} KB  {b/a:>4.1f}x  {kind}  "
          f"{before['maxp'].numGlyphs} -> {after['maxp'].numGlyphs} glyphs")
    return out_name, b, a


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--family", help="one catalogued family, e.g. Merriweather")
    group.add_argument("--all", action="store_true", help="every catalogued family")
    parser.add_argument("--charset", choices=sorted(CHARSETS), default="latin")
    parser.add_argument("--out", default="build/subset", help="output directory (default: build/subset)")
    args = parser.parse_args()

    rows = entries_for(None if args.all else args.family)
    print(f"\n  {len(rows)} file(s), charset={args.charset}\n")
    done, total_before, total_after = [], 0, 0
    for entry in rows:
        result = subset_one(entry, args.charset, args.out)
        if result:
            out_name, before, after = result
            done.append((entry, out_name))
            total_before += before
            total_after += after

    if not done:
        print("\n  nothing to do\n")
        return

    print(f"\n  {total_before/1024:.0f} KB -> {total_after/1024:.0f} KB  ({total_before/total_after:.1f}x)\n")
    print("  Upload (new filenames -- never overwrite, these are served immutable for a year):\n")
    for entry, out_name in done:
        print(f"    aws s3 cp {args.out}/{out_name} \\\n"
              f"      s3://jb-homepage-prod-150544707159/fonts/{entry['folder_name']}/{out_name} \\\n"
              f"      --content-type font/woff2 --cache-control 'public, max-age=31536000, immutable'")
    print("\n  Then repoint src/font_definitions.py and deploy:\n")
    for entry, out_name in done:
        print(f"    {entry['font_family_name']:<18} \"{entry['file_name']}\" -> \"{out_name}\"")
    print()


if __name__ == "__main__":
    main()
