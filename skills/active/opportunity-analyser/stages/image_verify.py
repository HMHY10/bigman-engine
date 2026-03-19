"""Image & listing verification stage.

Runs post-scoring on Buy/Review products. Uses Claude Vision (Haiku) for:
- Age-restriction warning detection
- Counterfeit indicators
- Listing mismatch detection
- Pack size identification from images

Also detects pack sizes from product titles.
Does NOT change Buy/Review/Skip classification — adds image_flags and pack_size.
"""
import base64
import json
import os
import re
from datetime import datetime

import anthropic
import requests as http_requests

import config
from vault import log, strip_json_fences

SKILL = "opportunity-analyser"

VISION_PROMPT = """Analyse this product image for an e-commerce compliance check.

Product: {product_name}
EAN: {ean}

Check for:
1. AGE RESTRICTION: Does the packaging show age-restriction warnings (18+, alcohol, etc.)?
2. COUNTERFEIT: Are there signs of counterfeit/fake product (misaligned labels, wrong fonts, low quality)?
3. LISTING MISMATCH: Does the image match the product name and EAN description?
4. CONDITION: Is the packaging damaged, opened, or not "new" condition?
5. PACK SIZE: How many individual units are shown in the image? (1 = single, >1 = multipack)

Return ONLY a JSON object:
{{
  "pass": true/false,
  "confidence": 0.0-1.0,
  "flags": ["list", "of", "issues"],
  "pack_size_detected": number,
  "notes": "brief explanation"
}}"""




def detect_pack_size(title):
    """Detect pack size from product title string."""
    if not title:
        return 1
    title_lower = title.lower()

    # "Pack of N", "N pack", "xN", "×N"
    match = re.search(r'(?:pack\s*(?:of\s*)?|x\s*|×\s*)(\d+)', title_lower)
    if match:
        return int(match.group(1))

    # Named packs
    if "twin pack" in title_lower or "duo pack" in title_lower or "double pack" in title_lower:
        return 2
    if "triple pack" in title_lower:
        return 3
    if "multipack" in title_lower:
        return 2  # Conservative default

    return 1


def download_image(url):
    """Download image and return base64-encoded bytes."""
    try:
        resp = http_requests.get(url, timeout=15)
        if resp.status_code == 200:
            content_type = resp.headers.get("content-type", "image/jpeg")
            media_type = content_type.split(";")[0].strip()
            if media_type not in ("image/jpeg", "image/png", "image/gif", "image/webp"):
                media_type = "image/jpeg"
            return base64.b64encode(resp.content).decode(), media_type
        log(f"image download failed: {resp.status_code}")
        return None, None
    except Exception as e:
        log(f"image download error: {e}")
        return None, None


def call_vision(image_b64, media_type, product_name, ean):
    """Call Claude Vision to analyse product image."""
    client = anthropic.Anthropic()
    try:
        resp = client.messages.create(
            model="claude-haiku-4-5-20251001",
            max_tokens=500,
            messages=[{
                "role": "user",
                "content": [
                    {
                        "type": "image",
                        "source": {"type": "base64", "media_type": media_type, "data": image_b64},
                    },
                    {
                        "type": "text",
                        "text": VISION_PROMPT.format(product_name=product_name, ean=ean),
                    },
                ],
            }],
        )
        raw = strip_json_fences(resp.content[0].text)
        return json.loads(raw)
    except Exception as e:
        log(f"vision call failed: {e}")
        return None


def verify_image(image_url, product_name, ean):
    """Verify a product image. Returns dict with pass/flags/pack_size or None."""
    if not image_url:
        return None

    image_b64, media_type = download_image(image_url)
    if not image_b64:
        return None

    result = call_vision(image_b64, media_type, product_name, ean)
    if not result:
        return {"pass": False, "confidence": 0.0, "flags": ["vision_call_failed"], "pack_size_detected": 1}

    return result


def run(product, amazon_match, recommendation):
    """Run image & listing verification on a recommendation.

    Updates recommendation.image_flags and recommendation.pack_size in-place.
    Only runs on Buy/Review classifications.
    """
    if not recommendation or recommendation.classification not in ("buy", "review"):
        return recommendation

    # ── Title-based pack size detection ────────────────
    title_pack_size = detect_pack_size(product.name)
    alt_pack_size = 1

    # Check alternate ASINs for pack listings
    if amazon_match and amazon_match.alternate_asins:
        for alt in amazon_match.alternate_asins:
            if alt.get("is_bundle") and alt.get("pack_size", 1) > 1:
                alt_pack_size = alt["pack_size"]
                log(f"alternate ASIN {alt['asin']} is a {alt_pack_size}-pack")
                break

    # ── Image verification ────────────────────────────
    image_url = None
    if amazon_match:
        image_url = getattr(amazon_match, "image_url", None)

    image_result = verify_image(image_url, product.name, product.ean)

    if image_result:
        recommendation.image_flags = image_result.get("flags", [])
        img_pack = image_result.get("pack_size_detected", 1)

        # Use highest detected pack size (most conservative)
        final_pack_size = max(title_pack_size, alt_pack_size, img_pack)

        if image_result.get("confidence", 1.0) < config.IMAGE_VERIFY_CONFIDENCE_THRESHOLD:
            recommendation.image_flags.append("low_confidence_review")
            log(f"low confidence ({image_result['confidence']}) — flagged for review")
    else:
        final_pack_size = max(title_pack_size, alt_pack_size)

    recommendation.pack_size = final_pack_size
    if final_pack_size > 1:
        recommendation.unit_cost = round(product.buy_price / final_pack_size, 2)
        log(f"pack size {final_pack_size} detected — unit cost £{recommendation.unit_cost}")

    return recommendation
