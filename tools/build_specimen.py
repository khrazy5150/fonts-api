"""Render every catalogued family, through the service itself, as one page.

A specimen page is the only check that answers "does this actually LOOK right?". The catalogue can be
internally consistent and still be wrong in ways nothing else reports:

  * Themify was catalogued as a text family for months. It is an icon font -- 0 of 62 Latin letters and
    digits are mapped -- so any page setting body text in it renders glyph soup. One glance here shows it.
  * A subset that accidentally drops `fvar` flattens a variable font to static. Nothing errors; headings
    just render faux-bold. Side by side with the other weights, it is obvious.
  * A family with no real 700 face gets browser-synthesised bold, which looks subtly wrong rather than
    broken. Those are flagged below rather than left to the eye.

It loads through `fonts.juniorbay.com` with `fs=true`, NOT from Google, so what you see is what the service
actually serves -- the bytes, the subsets, the weights. If a family is broken in the bucket it is broken
here too, which is the point.

Usage:
    python3 tools/build_specimen.py                 # -> build/specimen.html
    python3 tools/build_specimen.py --open          # and open it
    python3 tools/build_specimen.py --out /tmp/x.html
    python3 tools/build_specimen.py --publish     # -> https://juniorbay.com/font-specimen.html
"""

import argparse
import html
import os
import subprocess
import sys
import urllib.parse

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))
from font_definitions import VARIABLE_FONTS  # noqa: E402

SERVICE = "https://fonts.juniorbay.com"
HOMEPAGE_BUCKET = "jb-homepage-prod-150544707159"
PUBLISHED_NAME = "font-specimen.html"
PANGRAM = "Sphinx of black quartz, judge my vow"
SAMPLE = ("Every preset carries a pairing, and a page downloads only its own. "
          "The quick brown fox jumps over the lazy dog. 0123456789 — $24.22 · £19 · €31")


def families() -> dict[str, dict]:
    """family -> {weights, styles, files, has_real_bold, variable}."""
    out: dict[str, dict] = {}
    for entry in VARIABLE_FONTS.values():
        name = entry["font_family_name"]
        row = out.setdefault(name, {"weights": set(), "styles": set(), "files": [], "variable": False})
        spec = str(entry["weight_range"])
        row["files"].append(entry["file_name"])
        row["styles"].add(entry["style"])
        if " " in spec:
            low, high = (int(n) for n in spec.split())
            row["weights"].update(range(low, high + 1, 100))
            row["variable"] = True
        else:
            row["weights"].add(int(spec))
    for row in out.values():
        row["has_real_bold"] = 700 in row["weights"]
    return out


def build(rows: dict[str, dict]) -> str:
    names = sorted(rows)
    query = "&".join(f"family={urllib.parse.quote(n)}:400,700" for n in names)
    link = f"{SERVICE}/?{query}&fs=true"

    cards = []
    for name in names:
        row = rows[name]
        stack = f"'{name}'" if " " in name else name
        kind = "variable" if row["variable"] else "static"
        span = (f"{min(row['weights'])}–{max(row['weights'])}" if row["variable"]
                else ", ".join(str(w) for w in sorted(row["weights"])))
        warn = ("" if row["has_real_bold"] else
                '<p class="warn">No 700 face — bold here is synthesised by the browser</p>')
        cards.append(f"""    <section class="card">
      <header>
        <h2 style="font-family:{stack},sans-serif">{html.escape(name)}</h2>
        <p class="meta">{kind} · weights {span} · {len(row['files'])} file(s) · {', '.join(sorted(row['styles']))}</p>
      </header>
      <p class="display" style="font-family:{stack},sans-serif">{html.escape(PANGRAM)}</p>
      <p class="body" style="font-family:{stack},sans-serif">{html.escape(SAMPLE)}</p>
      <p class="body bold" style="font-family:{stack},sans-serif">{html.escape(PANGRAM)}</p>
      {warn}
    </section>""")

    return f"""<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Font service specimen — {len(names)} families</title>
<!-- Hosted on juniorbay.com so it can load from fonts.juniorbay.com (a claude.ai artifact cannot: its CSP
     admits stylesheets from Google Fonts only). It is an internal tool on a marketing domain, so it must
     never be indexed. -->
<meta name="robots" content="noindex,nofollow">
<link rel="stylesheet" href="{html.escape(link)}">
<style>
  :root {{ --ground:#fbfbfa; --panel:#fff; --ink:#16181d; --muted:#6b7280; --line:#e5e7eb; --warn:#9a3412; --warn-bg:#fff4ec; }}
  @media (prefers-color-scheme: dark) {{ :root:not([data-theme=light]) {{
    --ground:#0e1014; --panel:#171a20; --ink:#e9ecf2; --muted:#9aa2b1; --line:#272c35; --warn:#fdba74; --warn-bg:#2a1a10; }} }}
  :root[data-theme=dark] {{ --ground:#0e1014; --panel:#171a20; --ink:#e9ecf2; --muted:#9aa2b1; --line:#272c35; --warn:#fdba74; --warn-bg:#2a1a10; }}
  * {{ box-sizing:border-box; }}
  body {{ margin:0; background:var(--ground); color:var(--ink); line-height:1.5;
    font-family:system-ui,-apple-system,sans-serif; -webkit-font-smoothing:antialiased; }}
  .wrap {{ max-width:64rem; margin:0 auto; padding:3rem 1.25rem 5rem; }}
  h1 {{ font-size:1.75rem; margin:0 0 .4rem; font-weight:600; }}
  .lede {{ color:var(--muted); margin:0 0 2.5rem; max-width:62ch; }}
  .card {{ background:var(--panel); border:1px solid var(--line); border-radius:.6rem;
    padding:1.4rem 1.5rem; margin-bottom:1rem; }}
  .card h2 {{ margin:0; font-size:1.5rem; font-weight:700; }}
  .meta {{ margin:.2rem 0 1rem; font-size:.75rem; color:var(--muted);
    font-family:ui-monospace,SFMono-Regular,Menlo,monospace; }}
  .display {{ font-size:1.9rem; line-height:1.25; margin:0 0 .8rem; font-weight:400; }}
  .body {{ font-size:1rem; margin:0 0 .5rem; color:var(--ink); }}
  .bold {{ font-weight:700; }}
  .warn {{ margin:.7rem 0 0; padding:.5rem .75rem; background:var(--warn-bg);
    border-left:3px solid var(--warn); border-radius:0 .3rem .3rem 0; font-size:.82rem; color:var(--warn); }}
</style></head><body>
<div class="wrap">
  <h1>Font service specimen</h1>
  <p class="lede">{len(names)} families, every one rendered by <code>{SERVICE}</code> itself rather than by
  Google — so what you see is the bytes the service actually serves. Each shows the family name set in
  itself, a display line, body text with numerals and currency, and the same line at 700 so a missing bold
  face is visible rather than merely synthesised.</p>
{chr(10).join(cards)}
</div></body></html>
"""


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", default="build/specimen.html")
    parser.add_argument("--open", action="store_true", help="open it when written")
    parser.add_argument("--publish", action="store_true",
                        help="upload to juniorbay.com/font-specimen.html (noindex, short cache)")
    args = parser.parse_args()

    rows = families()
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as handle:
        handle.write(build(rows))

    faux = sorted(n for n, r in rows.items() if not r["has_real_bold"])
    print(f"  {args.out}: {len(rows)} families, "
          f"{sum(1 for r in rows.values() if r['variable'])} variable")
    if faux:
        print(f"  no real 700 face (flagged in the page): {', '.join(faux)}")
    if args.publish:
        # A SHORT cache, unlike the fonts themselves: this page is regenerated whenever the catalogue
        # changes, and `immutable` would strand the old one at every edge for a year.
        subprocess.run([
            "aws", "s3", "cp", args.out, f"s3://{HOMEPAGE_BUCKET}/{PUBLISHED_NAME}",
            "--content-type", "text/html; charset=utf-8",
            "--cache-control", "public, max-age=300",
        ], check=True)
        print(f"  published: https://juniorbay.com/{PUBLISHED_NAME}")

    if args.open:
        target = f"https://juniorbay.com/{PUBLISHED_NAME}" if args.publish else args.out
        subprocess.run(["open", target], check=False)


if __name__ == "__main__":
    main()
