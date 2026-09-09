import base64
import json
import os
import re
from font_definitions import VARIABLE_FONTS

# Define a base URL for all fonts
URL = "https://juniorbay.com/fonts"

# Where the font FILES actually live. `fs=true` (full subset) reads them from here and inlines them
# into the stylesheet as data: URIs, so a page makes ONE request to ONE host instead of loading a
# stylesheet from this origin that points at files on another. That split is what breaks whenever the
# two hosts disagree -- CORS, DNS, an ad-filter rule matching `fonts.*` -- and a data: URI has no
# second request to block.
FONT_BUCKET = os.environ.get("FONT_BUCKET", "jb-homepage-prod-150544707159")
FONT_PREFIX = os.environ.get("FONT_PREFIX", "fonts")

# The font files are served `max-age=31536000, immutable`, so a browser that cached them BEFORE the
# CORS policy was attached to /fonts/* holds a copy with no Access-Control-Allow-Origin header and is
# told never to revalidate it -- for a year. Fixing CORS at the edge cannot reach those copies; only a
# different URL can. Bump this whenever a response header on the files changes, which is the one thing
# `immutable` makes otherwise unfixable.
FONT_URL_VERSION = os.environ.get("FONT_URL_VERSION", "2")

# API Gateway caps a response at 6 MB and base64 costs 4/3, so stay well under: past this, faces fall
# back to url() references instead of the whole request failing.
INLINE_BUDGET_BYTES = int(os.environ.get("INLINE_BUDGET_BYTES", 4 * 1024 * 1024))

MIME_TYPES = {"woff2": "font/woff2", "woff": "font/woff", "ttf": "font/ttf", "otf": "font/otf"}

_s3_client = None
# Warm containers reuse the bytes; font files are immutable and versioned by filename.
_BYTES_CACHE = {}


def font_file_url(font_data):
    """The public URL for one font file, cache-busted by FONT_URL_VERSION."""
    url = f"{URL}/{font_data['folder_name']}/{font_data['file_name']}"
    return f"{url}?v={FONT_URL_VERSION}" if FONT_URL_VERSION else url


def _s3():
    global _s3_client
    if _s3_client is None:
        import boto3
        _s3_client = boto3.client("s3")
    return _s3_client


def font_bytes(font_data):
    """The raw bytes of one font file, or None when it cannot be read."""
    key = f"{FONT_PREFIX}/{font_data['folder_name']}/{font_data['file_name']}"
    if key not in _BYTES_CACHE:
        try:
            _BYTES_CACHE[key] = _s3().get_object(Bucket=FONT_BUCKET, Key=key)["Body"].read()
        except Exception as exc:
            print(f"Could not read s3://{FONT_BUCKET}/{key}: {exc}")
            _BYTES_CACHE[key] = None
    return _BYTES_CACHE[key]


class FontInliner:
    """Turns each face into a data: URI while the budget lasts.

    Every fallback is the ordinary CDN url(): an unreadable file or an exhausted budget costs one
    face, never the whole stylesheet. What was skipped is named in a CSS comment rather than left to
    look like a font that silently failed to apply.
    """

    def __init__(self, budget=INLINE_BUDGET_BYTES):
        self.remaining = budget
        self.notes = []

    def src_for(self, font_data):
        url = font_file_url(font_data)
        raw = font_bytes(font_data)
        if raw is None:
            self.notes.append(f"{font_data['file_name']} (unreadable)")
            return f"url('{url}')"
        encoded_size = ((len(raw) + 2) // 3) * 4
        if encoded_size > self.remaining:
            self.notes.append(f"{font_data['file_name']} (over budget)")
            return f"url('{url}')"
        self.remaining -= encoded_size
        mime = MIME_TYPES.get(font_data["format"], "application/octet-stream")
        return f"url('data:{mime};base64,{base64.b64encode(raw).decode('ascii')}')"

def find_fonts_by_family(family_name):
    """Find all font variants for a given family name"""
    family_fonts = {}
    for key, font_data in VARIABLE_FONTS.items():
        if font_data['font_family_name'] == family_name:
            family_fonts[key] = font_data
    return family_fonts

def find_best_weight_match(requested_weight, available_fonts):
    """Find the best matching font for a requested weight"""
    best_match = None
    best_diff = float('inf')
    
    for key, font_data in available_fonts.items():
        font_weight_str = font_data['weight_range']
        
        # Handle variable fonts (e.g., "100 900")
        if ' ' in font_weight_str:
            min_weight, max_weight = map(int, font_weight_str.split())
            if min_weight <= requested_weight <= max_weight:
                return key  # Perfect match for variable font
        else:
            # Handle static fonts (e.g., "400")
            font_weight = int(font_weight_str)
            diff = abs(font_weight - requested_weight)
            if diff < best_diff:
                best_diff = diff
                best_match = key
    
    return best_match

def parse_font_specification(family_query):
    """
    Parse Google Fonts-style font specifications
    Examples:
    - "Comic Relief" -> family: "Comic Relief", weights: [400], italics: [False]
    - "Comic Relief:400,700" -> family: "Comic Relief", weights: [400, 700], italics: [False, False]
    - "Comic Relief:400,400i,700,700i" -> family: "Comic Relief", weights: [400, 400, 700, 700], italics: [False, True, False, True]
    """
    # Split family name from specifications
    if ':' in family_query:
        family_name, specs = family_query.split(':', 1)
    else:
        family_name = family_query
        specs = None
    
    family_name = family_name.replace('+', ' ')
    requested_variants = []
    
    if specs:
        # Parse weight specifications like "400,700,400i,700i"
        spec_parts = specs.split(',')
        for spec in spec_parts:
            spec = spec.strip()
            if spec.endswith('i'):
                # Italic variant
                weight = int(spec[:-1])
                requested_variants.append({'weight': weight, 'italic': True})
            else:
                # Normal variant
                weight = int(spec)
                requested_variants.append({'weight': weight, 'italic': False})
    else:
        # Default to regular weight
        requested_variants.append({'weight': 400, 'italic': False})
    
    return family_name, requested_variants

def extract_all_family_params(event):
    """
    Extract all 'family' parameters from the event, handling multiple ways they might be provided
    """
    family_params = []
    
    # Check queryStringParameters
    query_params = event.get('queryStringParameters', {}) or {}
    if 'family' in query_params:
        family_value = query_params['family']
        if isinstance(family_value, str):
            family_params.append(family_value)
        elif isinstance(family_value, list):
            family_params.extend(family_value)
    
    # Check multiValueQueryStringParameters (AWS API Gateway v2 format)
    multi_value_params = event.get('multiValueQueryStringParameters', {}) or {}
    if 'family' in multi_value_params:
        family_values = multi_value_params['family']
        if isinstance(family_values, list):
            family_params.extend(family_values)
        elif isinstance(family_values, str):
            family_params.append(family_values)
    
    # If we still don't have any families, try parsing the raw query string
    if not family_params:
        raw_query = event.get('rawQueryString', '')
        if not raw_query:
            # Try to construct from queryStringParameters
            if query_params:
                import urllib.parse
                raw_query = urllib.parse.urlencode(query_params, doseq=True)
        
        if raw_query:
            import urllib.parse
            parsed = urllib.parse.parse_qs(raw_query)
            if 'family' in parsed:
                family_params.extend(parsed['family'])
    
    return family_params

WILDCARD = "*"


def expand_wildcard(all_families):
    """`family=*` -> every family in the catalogue, sorted.

    NOT spelled `all=true`: that already means "every VARIANT of the families you named" (Lato goes from one
    face to ten), so overloading it would make `family=Lato&all=true` ambiguous. The two compose instead --
    `family=*&all=true` is every family and every variant.

    Sorted, because the request URL is a cache key: two orderings of the same set must not be two URLs.

    Worth knowing before pointing a page at this: with `fs=true` the whole catalogue is a single ~2.5 MB
    response and several seconds of Lambda. It exists for the specimen page and for smoke-testing the
    service, not for a landing page, which should ask for the two families it actually renders.
    """
    return sorted({font["font_family_name"] for font in VARIABLE_FONTS.values()})


def parse_multiple_families(event):
    """
    Parse multiple font families from the event
    Handles both single and multiple family specifications:
    - ?family=Lato:400,700
    - ?family=Lato:400,700&family=Open+Sans:200,400
    """
    family_specs = extract_all_family_params(event)

    # A bare `*` anywhere replaces the whole list: asking for everything plus something else is the same
    # request, and de-duplicating afterwards would be doing it twice.
    specs_without_variants = [spec.split(":", 1)[0].strip() for spec in family_specs]
    if WILDCARD in specs_without_variants:
        weights = ""
        for spec in family_specs:
            if spec.split(":", 1)[0].strip() == WILDCARD and ":" in spec:
                weights = ":" + spec.split(":", 1)[1]   # `*:400,700` keeps the weights it was asked for
                break
        family_specs = [f"{name}{weights}" for name in expand_wildcard(VARIABLE_FONTS)]

    all_families = []
    
    for family_spec in family_specs:
        family_name, requested_variants = parse_font_specification(family_spec)
        all_families.append({
            'family_name': family_name,
            'variants': requested_variants
        })
    
    return all_families

def generate_font_css_advanced(family_name, requested_variants, display_value="swap", load_all=False, used_fonts=None, inliner=None):
    """
    Generate CSS for specified font variants or all variants in a family
    Now accepts used_fonts parameter to track fonts across multiple calls
    """
    if used_fonts is None:
        used_fonts = set()
    
    css_rules = ""
    
    # Find all fonts in this family
    family_fonts = find_fonts_by_family(family_name)
    
    if not family_fonts:
        return css_rules
    
    if load_all:
        # Load all available variants for the family
        for font_key, font_data in family_fonts.items():
            if font_key not in used_fonts:
                css_rule = generate_single_font_css(font_data, display_value, inliner)
                css_rules += css_rule
                used_fonts.add(font_key)
    else:
        # Load only requested variants        
        for variant in requested_variants:
            # Separate normal and italic fonts
            normal_fonts = {k: v for k, v in family_fonts.items() 
                           if v['style'] == 'normal'}
            italic_fonts = {k: v for k, v in family_fonts.items() 
                           if v['style'] == 'italic'}
            
            if variant['italic']:
                target_fonts = italic_fonts
            else:
                target_fonts = normal_fonts
            
            # Find best weight match
            best_font_key = find_best_weight_match(variant['weight'], target_fonts)
            
            if best_font_key and best_font_key not in used_fonts:
                font_data = VARIABLE_FONTS[best_font_key]
                css_rule = generate_single_font_css(font_data, display_value, inliner)
                css_rules += css_rule
                used_fonts.add(best_font_key)
    
    return css_rules

def generate_single_font_css(font_data, display_value, inliner=None):
    """Generate CSS for a single font"""
    if inliner is None:
        src = f"url('{font_file_url(font_data)}')"
    else:
        src = inliner.src_for(font_data)

    return f"""
@font-face {{
    font-family: '{font_data['font_family_name']}';
    font-style: {font_data['style']};
    font-weight: {font_data['weight_range']};
    src: {src} format('{font_data['format']}');
    font-display: {display_value};
}}
"""

def lambda_handler(event, context):
    """
    Enhanced Lambda function handler that supports:
    1. Multiple font families in one request (?family=Lato:400,700&family=Open+Sans:200,400)
    2. Google Fonts-style weight specifications (?family=Comic+Relief:400,700)
    3. Loading all variants for families (?family=Comic+Relief&all=true)
    3b. The whole catalogue (?family=*, or ?family=*:400,700 to fix the weights)
    4. Original single font loading
    """
    try:
        # Extract query parameters
        query_params = event.get('queryStringParameters', {}) or {}
        display_value = query_params.get('display', 'swap')
        load_all = query_params.get('all', '').lower() == 'true'
        # fs = "full subset": embed the font bytes in the stylesheet instead of pointing at them.
        full_subset = query_params.get('fs', '').lower() in ('true', '1', 'yes')

        # Parse all requested families using the improved method
        requested_families = parse_multiple_families(event)
        
        if not requested_families:
            return {
                "statusCode": 400,
                "body": "Bad Request: No valid font families specified.",
                "headers": { "Content-Type": "text/plain" }
            }

        # Generate CSS for all requested families
        all_css_content = ""
        missing_families = []
        # Create a single used_fonts set that persists across all families
        used_fonts = set()
        # One inliner across every family so the byte budget is shared, not per-family.
        inliner = FontInliner() if full_subset else None
        
        for family_request in requested_families:
            family_name = family_request['family_name']
            requested_variants = family_request['variants']
            
            # Check if the family exists
            family_fonts = find_fonts_by_family(family_name)
            if not family_fonts:
                missing_families.append(family_name)
                continue
            
            # Generate CSS for this family, passing the shared used_fonts set
            family_css = generate_font_css_advanced(
                family_name, 
                requested_variants, 
                display_value, 
                load_all,
                used_fonts,  # Pass the shared set to prevent duplicates
                inliner
            )
            
            all_css_content += family_css
        
        # Handle missing families
        if missing_families and not all_css_content:
            # All families were missing
            return {
                "statusCode": 404,
                "body": f"Font families not found: {', '.join(missing_families)}",
                "headers": { "Content-Type": "text/plain" }
            }
        elif missing_families:
            # Some families were missing, but we have others
            # Add a CSS comment noting missing families
            comment = f"/* Warning: The following font families were not found: {', '.join(missing_families)} */\n"
            all_css_content = comment + all_css_content
        
        # Say what could not be embedded. A face that fell back to url() still works, but silently
        # mixing the two would hide exactly the cross-origin fetch `fs=true` was asked for.
        if inliner is not None and inliner.notes:
            all_css_content = (
                f"/* Not embedded, served by URL: {', '.join(inliner.notes)} */\n" + all_css_content
            )

        # Return the combined CSS content
        return {
            "statusCode": 200,
            "body": all_css_content,
            "headers": {
                "Content-Type": "text/css; charset=utf-8",
                # The CSS is MUTABLE — this same URL returns different @font-face rules whenever the catalogue
                # changes — so `immutable` for a year was wrong and made every future catalogue change
                # invisible to anyone who had already loaded it. The font FILES are the immutable half;
                # they are versioned by filename and cached for a year by the homepage distribution.
                # Mirrors Google Fonts, which serves its CSS with max-age=86400 + stale-while-revalidate.
                "Cache-Control": "public, max-age=86400, stale-while-revalidate=604800",
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Methods": "GET",
                "Access-Control-Allow-Headers": "Content-Type"
            }
        }
        
    except ValueError as e:
        return {
            "statusCode": 400,
            "body": f"Bad Request: {str(e)}",
            "headers": { "Content-Type": "text/plain" }
        }
    except Exception as e:
        print(f"An error occurred: {e}")
        return {
            "statusCode": 500,
            "body": json.dumps({"error": "An internal server error occurred."}),
            "headers": { "Content-Type": "application/json" }
        }
