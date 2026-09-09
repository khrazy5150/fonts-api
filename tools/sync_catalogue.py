"""Keep font_definitions.py in agreement with the fonts actually in the bucket.

The catalogue is hand-maintained and the bucket is uploaded to by hand, so the two drift — and the drift
is SILENT in both directions:

  * an entry with no file  -> the API returns valid CSS whose @font-face 404s, and the page renders in a
    fallback with no console error and no failed publish. On 2026-09-03 twenty-seven of thirty families
    were in this state.
  * a file with no entry   -> the font is paid for in storage and unreachable, and `?family=` 404s even
    though the bytes are right there. Inter was in this state the day it was uploaded.

Worse, app.py's find_best_weight_match() picks the CLOSEST available weight, so a missing 700 silently
serves 400 and the page just looks wrong rather than broken.

Usage:
    python3 tools/sync_catalogue.py              # audit only, exits 1 if the two disagree
    python3 tools/sync_catalogue.py --emit       # print catalogue entries for unregistered files
"""

import argparse
import re
import pathlib
import subprocess
import sys

BUCKET = "jb-homepage-prod-150544707159"
PREFIX = "fonts/"
HERE = pathlib.Path(__file__).resolve().parent
CATALOGUE = HERE.parent / "src" / "font_definitions.py"

# Filename weight words -> CSS numeric weight. Both spellings of 200/600/900 appear in the wild.
WEIGHTS = {
    "thin": 100, "extralight": 200, "ultralight": 200, "light": 300, "regular": 400, "book": 400,
    "medium": 500, "semibold": 600, "demibold": 600, "bold": 700, "extrabold": 800, "ultrabold": 800,
    "black": 900, "heavy": 900,
}
SLUG_WORD = {100: "thin", 200: "ultra-light", 300: "light", 400: "regular", 500: "medium",
             600: "semi-bold", 700: "bold", 800: "extra-bold", 900: "black"}


def bucket_files():
    """Every .woff2 in the bucket, as (folder, filename)."""
    out = subprocess.run(
        ["aws", "s3", "ls", f"s3://{BUCKET}/{PREFIX}", "--recursive"],
        capture_output=True, text=True, check=True,
    ).stdout
    files = []
    for line in out.splitlines():
        key = line.split()[-1]
        if not key.lower().endswith(".woff2"):
            continue
        parts = key.split("/")
        if len(parts) == 3:
            files.append((parts[1], parts[2]))
    return sorted(set(files))


def catalogue_entries():
    """Every (folder, filename) the catalogue declares, plus folder -> family name."""
    src = CATALOGUE.read_text(encoding="utf-8")
    pairs = re.findall(r'"font_family_name":\s*"([^"]+)",\s*\n\s*"folder_name":\s*"([^"]+)",\s*\n\s*"file_name":\s*"([^"]+)"', src)
    declared = {(folder, name) for _, folder, name in pairs}
    families = {}
    for family, folder, _ in pairs:
        families.setdefault(folder, family)
    keys = set(re.findall(r'^    "([^"]+)": \{', src, re.M))
    return declared, families, keys


def parse(folder, filename):
    """(family_guess, weight, style) from a filename, or None when it does not parse.

    Handles the optical-size infix Inter and Merriweather ship (`Inter_18pt-SemiBold.woff2`): the cut is
    kept as part of the family stem so two cuts cannot collide on one slug.
    """
    stem = filename[: -len(".woff2")]
    if "-" not in stem:
        return None
    base, _, suffix = stem.rpartition("-")
    italic = suffix.lower().endswith("italic")
    word = suffix[: -len("Italic")] if italic and len(suffix) > len("Italic") else suffix
    weight = WEIGHTS.get(word.lower().replace(" ", ""))
    if weight is None:
        weight = 400 if italic else None
    if weight is None:
        return None
    return base, weight, ("italic" if italic else "normal")


def slug(family, weight, style, taken):
    stem = re.sub(r"[^a-z0-9]+", "-", family.lower()).strip("-")
    parts = [stem]
    if weight != 400:
        parts.append(SLUG_WORD[weight])
    if style == "italic":
        parts.append("italic")
    key = "-".join(parts)
    n = 2
    while key in taken:
        key = "-".join(parts) + f"-{n}"
        n += 1
    taken.add(key)
    return key


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--emit", action="store_true", help="print entries for unregistered files")
    args = ap.parse_args()

    files = bucket_files()
    declared, families, keys = catalogue_entries()
    present = set(files)

    missing_files = sorted(declared - present)      # entry with no file: the SILENT one
    unregistered = sorted(present - declared)       # file with no entry: unreachable bytes

    print(f"bucket .woff2: {len(files)}    catalogue entries: {len(declared)}")
    print(f"  entries with NO FILE   : {len(missing_files)}  (these 404 behind valid CSS)")
    for folder, name in missing_files:
        print(f"      {folder}/{name}")
    print(f"  files NOT in catalogue : {len(unregistered)}")
    for folder, name in unregistered[:12]:
        print(f"      {folder}/{name}")
    if len(unregistered) > 12:
        print(f"      ... and {len(unregistered) - 12} more")

    if args.emit and unregistered:
        print("\n# --- entries for unregistered files; review family names before pasting ---")
        taken = set(keys)
        for folder, name in unregistered:
            parsed = parse(folder, name)
            if not parsed:
                print(f"    # UNPARSED, add by hand: {folder}/{name}")
                continue
            stem, weight, style = parsed
            family = families.get(folder) or stem.replace("_", " ")
            print(f'    "{slug(stem, weight, style, taken)}": {{')
            print(f'        "format": "woff2",')
            print(f'        "weight_range": "{weight}",')
            print(f'        "style": "{style}",')
            print(f'        "font_family_name": "{family}",')
            print(f'        "folder_name": "{folder}",')
            print(f'        "file_name": "{name}",')
            print(f'    }},')

    return 1 if (missing_files or unregistered) else 0


if __name__ == "__main__":
    sys.exit(main())
