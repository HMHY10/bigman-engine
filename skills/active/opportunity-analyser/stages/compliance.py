"""Stage 2: Compliance checks — restrictions, hazmat, IP, regulatory."""
from clients import sp_api
from config import AUTO_SKIP_CATEGORIES, HAZMAT_REVIEW_REQUIRED
from models import AmazonMatch, ComplianceResult, Product
from vault import log


def run(product: Product, match: AmazonMatch) -> ComplianceResult:
    """Run all compliance checks. Returns ComplianceResult."""
    result = ComplianceResult(eligible=True)

    # 1. SP-API Restrictions check
    restrictions = sp_api.get_restrictions(match.asin)
    _check_restrictions(restrictions, result)

    # 2. Regulatory flags (rule-based for Health & Beauty)
    _check_regulatory(product, match, result)

    # 3. IP infringement signals
    _check_ip(match, result)

    log(f"stage2: {match.asin} — eligible={result.eligible}, hazmat={result.hazmat}, ip={result.ip_risk}, flags={result.regulatory}")
    return result


def _check_restrictions(restrictions: dict, result: ComplianceResult):
    """Check SP-API restrictions response."""
    if restrictions.get("status") == "error":
        result.hazmat = "review"
        result.reason += "Restrictions check failed. "
        return

    restriction_list = restrictions.get("restrictions", [])
    for r in restriction_list:
        reason_list = r.get("reasons", [])
        for reason in reason_list:
            msg = reason.get("message", "").lower()
            if "approval required" in msg:
                result.eligible = False
                result.reason += f"Approval required: {reason.get('message', '')}. "
            if "restricted" in msg:
                result.eligible = False
                result.reason += f"Restricted: {reason.get('message', '')}. "

    # If no restrictions found, eligible
    if not restriction_list:
        result.eligible = True


def _check_regulatory(product: Product, match: AmazonMatch, result: ComplianceResult):
    """Rule-based regulatory checks for UK market."""
    name_lower = (product.name + " " + match.title).lower()

    # Auto-skip categories
    for cat in AUTO_SKIP_CATEGORIES:
        if cat in name_lower:
            result.eligible = False
            result.regulatory.append(f"auto_skip:{cat}")
            result.reason += f"Auto-skip category: {cat}. "
            return

    # Health & Beauty specific
    cosmetics_keywords = ["cream", "moisturis", "serum", "cleanser", "lotion",
                          "shampoo", "conditioner", "sunscreen", "spf", "foundation",
                          "lipstick", "mascara", "perfume", "fragrance", "deodorant"]
    if any(kw in name_lower for kw in cosmetics_keywords):
        result.regulatory.append("cosmetics_notification_required")

    # UKCA marking
    electrical_keywords = ["electric", "battery", "charger", "plug", "adapter", "led"]
    if any(kw in name_lower for kw in electrical_keywords):
        result.regulatory.append("ukca_marking_required")

    # Age-restricted
    age_keywords = ["alcohol", "vape", "nicotine", "cbd", "knife", "blade"]
    if any(kw in name_lower for kw in age_keywords):
        result.regulatory.append("age_restricted")
        result.eligible = False
        result.reason += "Age-restricted product. "


def _check_ip(match: AmazonMatch, result: ComplianceResult):
    """Check for IP infringement signals."""
    # Brand mismatch already handled in Stage 1 (filtered out)
    # Additional IP signals from listing data
    if match.brand_mismatch:
        result.ip_risk = "review"
        result.reason += "Brand mismatch on listing — potential IP risk. "
        return

    result.ip_risk = "clear"
