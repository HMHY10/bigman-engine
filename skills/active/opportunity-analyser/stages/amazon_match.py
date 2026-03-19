"""Stage 1: Match product EAN to Amazon ASIN(s). Discover variations, apply brand rules."""
import re
from thefuzz import fuzz

from clients import sp_api
from config import BRAND_MISMATCH_ACTION
from models import AmazonMatch, Product
from vault import log


def run(product: Product) -> list[AmazonMatch]:
    """Find Amazon listings matching this product. Returns sorted by confidence."""
    matches = []

    # 1. Search by EAN (primary)
    items = sp_api.search_by_ean(product.ean)
    ean_matched = bool(items)

    if not items:
        # 2. Fuzzy fallback by name
        log(f"stage1: no EAN match for {product.ean}, trying keyword search")
        items = sp_api.search_by_keywords(product.name, product.brand)

    for item in items:
        summaries = item.get("summaries", [{}])
        summary = summaries[0] if summaries else {}

        asin = item.get("asin", "")
        title = summary.get("itemName", "")
        listing_brand = summary.get("brand", "")

        # Confidence scoring
        confidence = _score_confidence(product, asin, title, listing_brand, ean_matched)

        # Brand mismatch check
        brand_mismatch = False
        if product.brand and listing_brand:
            if product.brand.lower().strip() != listing_brand.lower().strip():
                brand_mismatch = True
                if BRAND_MISMATCH_ACTION == "ignore":
                    log(f"stage1: brand mismatch for {asin} — product={product.brand}, listing={listing_brand} — skipping")
                    continue

        # Check for variations (parent-child relationships)
        relationships = item.get("relationships", [])
        is_variation = False
        parent_asin = ""
        for rel in relationships:
            if rel.get("type") == "VARIATION":
                is_variation = True
                parent_asin = rel.get("parentAsin", "")

        matches.append(AmazonMatch(
            asin=asin,
            title=title,
            brand=listing_brand,
            confidence=confidence,
            is_variation=is_variation,
            parent_asin=parent_asin,
            brand_mismatch=brand_mismatch,
        ))

    matches.sort(key=lambda m: m.confidence, reverse=True)

    # Enrich best match with image URL and alternate ASINs
    if matches:
        best = matches[0]
        # Get image from the primary match's SP-API data
        for item in items:
            if item.get("asin") == best.asin:
                from clients.sp_api import extract_image_url
                best.image_url = extract_image_url(item)
                break
        # Find alternate ASINs
        best.alternate_asins = find_alternate_asins(product, best, sp_api)
    log(f"stage1: {product.ean} → {len(matches)} matches (best confidence: {matches[0].confidence:.2f})" if matches else f"stage1: {product.ean} → no matches")
    return matches


def _score_confidence(product: Product, asin: str, title: str, brand: str, ean_matched: bool) -> float:
    """Score match confidence 0.0-1.0 based on name similarity and brand match."""
    score = 0.0

    # Name similarity (0-0.6)
    if product.name and title:
        name_ratio = fuzz.token_sort_ratio(product.name.lower(), title.lower()) / 100
        score += name_ratio * 0.6

    # Brand match (0-0.3)
    if product.brand and brand:
        if product.brand.lower().strip() == brand.lower().strip():
            score += 0.3

    # EAN match bonus (0.1) — only if found via EAN search, not keyword fallback
    if ean_matched:
        score += 0.1

    return min(score, 1.0)


def find_alternate_asins(product, primary_match, sp_client):
    """Search by title+brand to find alternate ASINs (bundles, multipacks, wrong-EAN listings)."""
    if not primary_match:
        return []

    try:
        keywords = f"{product.brand} {product.name}"
        results = sp_client.search_by_keywords(keywords)
        alternates = []

        for item in results:
            asin = item.get("asin")
            if asin == primary_match.asin:
                continue  # Skip the primary match

            title = item.get("summaries", [{}])[0].get("itemName", "") if item.get("summaries") else ""
            title_lower = title.lower()

            # Detect pack/bundle using shared pack size detection
            from stages.image_verify import detect_pack_size
            pack_size = detect_pack_size(title)
            is_bundle = pack_size > 1

            # Only include if reasonably related
            similarity = fuzz.token_sort_ratio(product.name.lower(), title_lower)
            if similarity >= 50:
                from clients.sp_api import extract_image_url
                alternates.append({
                    "asin": asin,
                    "title": title,
                    "is_bundle": is_bundle,
                    "pack_size": pack_size,
                    "similarity": similarity,
                    "image_url": extract_image_url(item),
                })

        return sorted(alternates, key=lambda x: x["similarity"], reverse=True)[:5]

    except Exception as e:
        log(f"alternate ASIN search failed: {e}")
        return []
