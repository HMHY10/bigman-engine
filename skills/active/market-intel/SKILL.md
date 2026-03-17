---
name: market-intel
description: Research competitors and suppliers, analyse competitive positioning, generate intelligence reports. Runs monthly via cron or on-demand. Use when asked to analyse competitors, compare supplier pricing, or generate market intelligence.
---

# Market Intelligence

Multi-phase pipeline that researches competitors and suppliers, analyses competitive positioning against ArryBarry, and generates intelligence reports to the Obsidian vault.

## How It Works

Three-phase pipeline with different LLM models per phase:

1. **Research (Haiku)** — Brave Search + email intel + vault data → structured JSON
2. **Analyse (Sonnet)** — Cross-reference against ArryBarry positioning → strategic analysis
3. **Write (Haiku)** — Format reports → save to vault via obsidian-sync

### Automatic (Monthly Cron)
Runs at 3am on the 1st of every month in full mode — all known competitors + supplier pricing.

### Manual Trigger

```bash
# Specific competitor(s)
cd /opt/bigman-engine && doppler run --project shared-services --config prd -- ./skills/active/market-intel/market-intel.sh competitor "Lookfantastic"

# Multiple competitors
cd /opt/bigman-engine && doppler run --project shared-services --config prd -- ./skills/active/market-intel/market-intel.sh competitor "Lookfantastic" "Beauty Bay" "Cult Beauty"

# Supplier pricing only
cd /opt/bigman-engine && doppler run --project shared-services --config prd -- ./skills/active/market-intel/market-intel.sh supplier

# Full landscape (all competitors + suppliers)
cd /opt/bigman-engine && doppler run --project shared-services --config prd -- ./skills/active/market-intel/market-intel.sh full
```

## Three Modes

| Mode | Command | What It Does |
|------|---------|-------------|
| competitor | market-intel.sh competitor "Name" | Analyse specific competitor(s) — individual profiles |
| supplier | market-intel.sh supplier | Pricing comparison across known suppliers from email intel |
| full | market-intel.sh full | All known competitors + supplier pricing + aggregated landscape report |

## Vault Output

- **Individual profiles:** 05-Agent-Outputs/Research/YYYY-MM-DD-competitor-{slug}.md
- **Landscape report:** 05-Agent-Outputs/Research/YYYY-MM-DD-competitive-landscape.md
- **Supplier pricing:** 05-Agent-Outputs/Research/YYYY-MM-DD-supplier-pricing.md

## Data Sources

- **Brave Search** — web research (3-4 queries per target)
- **Email intelligence** — 09-Email/ entity notes (from email-triage skill)
- **Competitor list** — 03-Resources/Competitors/competitor-list.md (maintained by user in Obsidian)
- **Supplier list** — Derived from 09-Email/Suppliers/ entity note filenames

## Auto-Discovery

Phase 2 scans email entity notes in 09-Email/Marketing/ and 09-Email/Partnerships/ for company names not in the known competitor list. New competitors are flagged in the landscape report and tracked in market-intel-state.json. They are NOT automatically added to competitor-list.md — human reviews and adds if relevant.

## Configuration

### Secrets (Doppler shared-services)
BRAVE_API_KEY, ANTHROPIC_API_KEY, OBSIDIAN_HOST, OBSIDIAN_API_KEY

### State (on VPS, not in vault)
- market-intel-state.json — run timestamps and discovered competitors

## Important Rules

- All reports use Obsidian wiki-links [[path/to/note]] for cross-references
- All reports include vault-path frontmatter for vault routing
- Competitor list is read LIVE from vault each run — changes take effect automatically
- Supplier list is derived from email entity notes — no separate file to maintain
- Lockfile prevents concurrent runs
- Pipeline dir cleaned at start of each run (not just on success)
- Phase 2 analyses one competitor per Sonnet call (avoids context window limits)
- Brave Search: 1-second delay between queries, retry on HTTP 429
- Estimated cost: ~£0.50 per full run (Sonnet is ~80%)
