"""Data models for the opportunity pipeline."""
from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional

@dataclass
class VolumePrice:
    qty: int
    price: float

@dataclass
class Product:
    ean: str
    name: str
    brand: str = ""
    buy_price: float = 0.0
    currency: str = "GBP"
    moq: int = 1
    volume_prices: list[VolumePrice] = field(default_factory=list)
    delivery_days: int = 0
    source_ref: str = ""
    supplier: str = ""

@dataclass
class Opportunity:
    id: str
    source: str
    supplier: str
    received_at: str
    products: list[Product]
    retry_count: int = 0

@dataclass
class AmazonMatch:
    asin: str
    title: str
    brand: str
    confidence: float
    is_variation: bool = False
    parent_asin: str = ""
    brand_mismatch: bool = False

@dataclass
class ComplianceResult:
    eligible: bool
    hazmat: str = "unknown"        # "none", "review", "blocked"
    ip_risk: str = "unknown"       # "clear", "review", "blocked"
    regulatory: list[str] = field(default_factory=list)  # flags
    reason: str = ""

@dataclass
class MarketData:
    buy_box_price: float = 0.0
    seller_count_fba: int = 0
    seller_count_fbm: int = 0
    seller_count_total: int = 0
    bsr: int = 0
    bsr_category: str = ""
    category_rank: int = 0
    review_count: int = 0
    review_rating: float = 0.0
    est_monthly_sales: int = 0
    data_source: str = ""          # "sp_api", "rainforest", "bsr_estimate"
    internal_velocity: dict = field(default_factory=dict)  # BaseLinker sales data

@dataclass
class MarginResult:
    sell_price: float = 0.0
    buy_price: float = 0.0
    referral_fee: float = 0.0
    fba_fee: float = 0.0
    vat: float = 0.0
    shipping_fba: float = 0.0
    profit_per_unit: float = 0.0
    roi_pct: float = 0.0
    margin_pct: float = 0.0
    break_even_units: int = 0
    calculable: bool = False       # True if sell/buy prices were available

@dataclass
class VolumeResult:
    recommended_qty: int = 0
    reasoning: str = ""
    fallback_used: str = ""        # which fallback in the chain was used
    coverage_days: int = 0

@dataclass
class Recommendation:
    product: Product
    amazon_match: Optional[AmazonMatch] = None
    compliance: Optional[ComplianceResult] = None
    market: Optional[MarketData] = None
    margin: Optional[MarginResult] = None
    volume: Optional[VolumeResult] = None
    classification: str = "skip"   # "buy", "review", "skip"
    score: float = 0.0
    reasons: list[str] = field(default_factory=list)
    analysed_at: str = ""
    raw_predictors: dict = field(default_factory=dict)  # all data for algo training
