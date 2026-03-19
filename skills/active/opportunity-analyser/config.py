"""Opportunity analyser configuration. All thresholds tunable without code changes."""
import os

# ── Margin thresholds ──────────────────────────────────────────────
MIN_ROI_PCT = float(os.getenv("OPP_MIN_ROI_PCT", "20"))
MIN_PROFIT_PER_UNIT = float(os.getenv("OPP_MIN_PROFIT", "1.00"))
MIN_MONTHLY_SALES = int(os.getenv("OPP_MIN_MONTHLY_SALES", "50"))
MAX_SELLER_COUNT = int(os.getenv("OPP_MAX_SELLERS", "30"))
MIN_CONFIDENCE_SCORE = float(os.getenv("OPP_MIN_CONFIDENCE", "0.6"))

# ── Margin calculation ────────────────────────────────────────────
SHIPPING_TO_FBA_PER_UNIT = float(os.getenv("OPP_SHIPPING_FBA", "0.50"))
DEFAULT_VAT_RATE = 0.20  # Standard rate — overridden per product where known

# VAT rates by Amazon product category (UK)
# Standard: 20%, Reduced: 5%, Zero: 0%
VAT_RATES_BY_CATEGORY = {
    # Zero-rated (0%)
    "baby_product": 0.0,         # children's clothing & shoes
    "book": 0.0,
    "newspaper": 0.0,
    # Reduced rate (5%)
    "child_car_seat": 0.05,
    "mobility_aid": 0.05,
    # Standard rate (20%) — most categories
    "health_beauty": 0.20,
    "beauty": 0.20,
    "health_personal_care": 0.20,
    "electronics": 0.20,
    "home": 0.20,
    "kitchen": 0.20,
    "toy": 0.20,
    "sports": 0.20,
    "pet_products": 0.20,
}

# VAT rate keyword overrides — checked against product name/title
# These catch specific zero/reduced rated items within standard-rated categories
VAT_RATE_KEYWORDS = {
    0.0: [
        "nappy", "nappies", "diaper",          # zero-rated baby products
        "sanitary pad", "tampon", "menstrual",  # zero-rated since Jan 2021
    ],
    0.05: [
        "nicotine replacement", "nicotine patch", "nicotine gum",  # smoking cessation
    ],
}

# ── Volume estimation ──────────────────────────────────────────────
DEFAULT_COVERAGE_DAYS = 30
SEASONALITY_LOOKBACK_MONTHS = 12

# ── API cost control ──────────────────────────────────────────────
SP_API_DAILY_BUDGET = int(os.getenv("OPP_SP_API_BUDGET", "1500"))
RAINFOREST_DAILY_BUDGET = int(os.getenv("OPP_RAINFOREST_BUDGET", "100"))
RAINFOREST_PRIORITY = "backup"  # "primary" or "backup"
CLAUDE_PDF_MAX_PAGES = 10
CLAUDE_PDF_MAX_PER_CYCLE = 5

# ── Compliance auto-skip ──────────────────────────────────────────
AUTO_SKIP_CATEGORIES = ["prescription", "weapons", "tobacco"]
HAZMAT_REVIEW_REQUIRED = True

# ── Category-specific overrides ───────────────────────────────────
CATEGORY_THRESHOLDS = {
    "health_beauty": {"min_roi": 15, "min_profit": 1.00},
    "electronics": {"min_roi": 25, "min_profit": 5.00},
}

# ── Paths ─────────────────────────────────────────────────────────
REPO_ROOT = os.getenv("REPO_ROOT", "/opt/bigman-engine")
DATA_ROOT = f"{REPO_ROOT}/data/opportunities"
INTEL_ROOT = f"{REPO_ROOT}/data/product-intel"
STATE_DIR = f"{REPO_ROOT}/state/opportunity-analyser"
SYNC_SCRIPT = f"{REPO_ROOT}/skills/active/obsidian-sync/sync.sh"

QUEUE_INBOX = f"{DATA_ROOT}/inbox"
QUEUE_PENDING = f"{DATA_ROOT}/pending"
QUEUE_PROCESSING = f"{DATA_ROOT}/processing"
QUEUE_PROCESSED = f"{DATA_ROOT}/processed"
QUEUE_FAILED = f"{DATA_ROOT}/failed"
QUEUE_ARCHIVE = f"{DATA_ROOT}/archive"

DEDUP_INDEX = f"{DATA_ROOT}/dedup-index.json"
DEDUP_WINDOW_DAYS = 7
DEDUP_PRUNE_DAYS = 30

# ── Retry ─────────────────────────────────────────────────────────
MAX_RETRIES = 3
PROCESSING_STALE_HOURS = 2

# ── Brand mismatch rule ──────────────────────────────────────────
BRAND_MISMATCH_ACTION = "ignore"  # "ignore" or "review"
