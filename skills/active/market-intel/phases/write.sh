#!/usr/bin/env bash
# write.sh — Phase 3: Report generation for market intelligence.
# Formats analysis data into Markdown reports via Claude Haiku.
# Saves reports to Obsidian vault via obsidian-sync.
#
# Usage: write.sh <competitor|supplier|full>
#
# Reads from: /tmp/market-intel/analysis/competitors.json, suppliers.json
# Writes to: vault 05-Agent-Outputs/Research/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SKILL_DIR/../../.." && pwd)"
SYNC="$REPO_ROOT/skills/active/obsidian-sync/sync.sh"
PIPELINE_DIR="/tmp/market-intel"

log() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >&2; }

MODE="${1:?Usage: write.sh <competitor|supplier|full>}"
TODAY=$(date -u +"%Y-%m-%d")
MONTH_YEAR=$(date -u +"%B %Y")

# --- LLM call: generate report via Haiku ---
generate_report() {
  local prompt_text="$1" max_tokens="${2:-2000}"

  local prompt
  prompt=$(jq -n \
    --arg text "$prompt_text" \
    --argjson max "$max_tokens" \
    '{
      model: "claude-haiku-4-5-20251001",
      max_tokens: $max,
      temperature: 0,
      messages: [{
        role: "user",
        content: $text
      }]
    }')

  local response
  response=$(curl -sf "https://api.anthropic.com/v1/messages" \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "$prompt" 2>/dev/null)

  if [ -z "$response" ]; then
    return 1
  fi

  echo "$response" | jq -r '.content[0].text // empty'
}

# --- Save report to vault ---
save_to_vault() {
  local vault_path="$1" content="$2"

  local tmpfile="/tmp/market-intel-report-${RANDOM}.md"
  echo "$content" > "$tmpfile"
  "$SYNC" put-file "$vault_path" "$tmpfile" 2>/dev/null
  local result=$?
  rm -f "$tmpfile"

  if [ $result -eq 0 ]; then
    log "Written: $(basename "$vault_path")"
  else
    log "ERROR: Failed to write $(basename "$vault_path") to vault"
  fi

  return $result
}

# --- Write individual competitor profiles ---
write_competitor_profiles() {
  local competitors_file="$PIPELINE_DIR/analysis/competitors.json"
  [ ! -f "$competitors_file" ] && return 0

  local count
  count=$(jq '.competitors | length' "$competitors_file")
  [ "$count" -eq 0 ] && return 0

  for i in $(seq 0 $((count - 1))); do
    local comp_json
    comp_json=$(jq -c ".competitors[$i]" "$competitors_file")
    local comp_name
    comp_name=$(echo "$comp_json" | jq -r '.name')
    local comp_slug
    comp_slug=$(echo "$comp_json" | jq -r '.slug')

    log "Write: competitor profile for $comp_name..."

    local prompt_text
    prompt_text="You are a business intelligence report writer for ArryBarry Health & Beauty.

Generate a competitor profile report in Markdown format using this analysis data:

${comp_json}

Write the report following this EXACT template. Output ONLY the markdown (no fencing):

---
vault-path: 05-Agent-Outputs/Research/${TODAY}-competitor-${comp_slug}.md
type: competitor-profile
---

# Competitor: ${comp_name}

**Date:** ${TODAY}
**Agent:** bigman-market-intel
**Status:** Draft — awaiting human review

## Executive Summary
(1-2 sentence competitive threat/position overview based on the analysis data)

## Key Findings
1. **Positioning:** (from analysis data)
2. **Product Range:** (from analysis data)
3. **Pricing Strategy:** (from analysis data)
4. **Customer Base:** (from analysis data)
5. **Channels:** (from analysis data)
6. **Brand Voice & Marketing:** (from analysis data)
7. **Strengths:** (from analysis strengths array)
8. **Weaknesses:** (from analysis weaknesses array)
9. **Recent Activity:** (from analysis data)

## Comparison vs ArryBarry
(Use the positioning_vs_arrybarry field)

## Sources
(List any source URLs from the data)

## Recommendations
(Use the recommendations array)

## Confidence Level
(Assess based on data completeness — High if web + email data, Medium if web only, Low if limited data)

## Related Notes
- [[ArryBarry-Context]]
- [[03-Resources/Competitors/]]

IMPORTANT: Use [[wiki-link]] syntax for all cross-references. Write in British English."

    local report
    report=$(generate_report "$prompt_text" 2500)

    if [ -n "$report" ]; then
      save_to_vault "05-Agent-Outputs/Research/${TODAY}-competitor-${comp_slug}.md" "$report"
    else
      log "ERROR: Failed to generate profile for $comp_name"
    fi
  done
}

# --- Write competitive landscape report ---
write_landscape_report() {
  local competitors_file="$PIPELINE_DIR/analysis/competitors.json"
  [ ! -f "$competitors_file" ] && return 0

  local all_competitors
  all_competitors=$(jq -c '.' "$competitors_file")
  local discovered
  discovered=$(jq -c '.discovered_competitors // []' "$competitors_file")

  log "Write: competitive landscape report..."

  local prompt_text
  prompt_text="You are a business intelligence report writer for ArryBarry Health & Beauty.

Generate a competitive landscape report in Markdown format using this analysis data:

${all_competitors}

Write the report following this EXACT template. Output ONLY the markdown (no fencing):

---
vault-path: 05-Agent-Outputs/Research/${TODAY}-competitive-landscape.md
type: competitive-landscape
---

# Competitive Landscape — ${MONTH_YEAR}

**Date:** ${TODAY}
**Agent:** bigman-market-intel
**Status:** Draft — awaiting human review

## Executive Summary
(2-3 sentence market position overview covering all analysed competitors)

## Competitor Comparison

| Competitor | Threat Level | Positioning | Price Tier | Key Channels | Main Strength | Main Weakness |
|-----------|-------------|-------------|-----------|-------------|--------------|--------------|
(One row per competitor from the data)

## Strategic Recommendations
(Top 3-5 actions for ArryBarry based on the combined competitive intelligence)

## Newly Discovered Competitors
(For each entry in discovered_competitors array, include:)
(If none: 'No new competitors discovered this cycle.')
(If any: 'Warning NEW COMPETITOR DETECTED — {name}: {reason}')

## Individual Profiles
(Link to each competitor profile using [[wiki-links]]:)
(- [[05-Agent-Outputs/Research/${TODAY}-competitor-{slug}]])

IMPORTANT: Use [[wiki-link]] syntax for all cross-references. Write in British English."

  local report
  report=$(generate_report "$prompt_text" 3000)

  if [ -n "$report" ]; then
    save_to_vault "05-Agent-Outputs/Research/${TODAY}-competitive-landscape.md" "$report"
  else
    log "ERROR: Failed to generate landscape report"
  fi
}

# --- Write supplier pricing report ---
write_supplier_report() {
  local suppliers_file="$PIPELINE_DIR/analysis/suppliers.json"
  [ ! -f "$suppliers_file" ] && return 0

  local supp_count
  supp_count=$(jq '.suppliers | length' "$suppliers_file")
  [ "$supp_count" -eq 0 ] && {
    log "Write: no supplier data — generating empty report"
    local empty_report="---
vault-path: 05-Agent-Outputs/Research/${TODAY}-supplier-pricing.md
type: supplier-pricing
---

# Supplier Pricing Comparison — ${MONTH_YEAR}

**Date:** ${TODAY}
**Agent:** bigman-market-intel
**Status:** Draft — awaiting human review

## Summary
No supplier data available. Ensure supplier entity notes exist in 09-Email/Suppliers/ for the next run.

## Sources
No email intelligence available for suppliers."

    save_to_vault "05-Agent-Outputs/Research/${TODAY}-supplier-pricing.md" "$empty_report"
    return 0
  }

  local all_suppliers
  all_suppliers=$(jq -c '.' "$suppliers_file")

  log "Write: supplier pricing report ($supp_count suppliers)..."

  local prompt_text
  prompt_text="You are a procurement report writer for ArryBarry Health & Beauty.

Generate a supplier pricing comparison report in Markdown format using this data:

${all_suppliers}

Write the report following this EXACT template. Output ONLY the markdown (no fencing):

---
vault-path: 05-Agent-Outputs/Research/${TODAY}-supplier-pricing.md
type: supplier-pricing
---

# Supplier Pricing Comparison — ${MONTH_YEAR}

**Date:** ${TODAY}
**Agent:** bigman-market-intel
**Status:** Draft — awaiting human review

## Summary
(Overview of pricing trends, notable changes across suppliers)

## Pricing Comparison

| Supplier | Product | Unit Cost | Trend | Lead Time | Terms | Source |
|----------|---------|-----------|-------|-----------|-------|--------|
(One row per supplier/product from the data. Use up/down/right arrows for trends.)

## Price Alerts
(Notable changes: increases >5%, new suppliers, discontinued products. If none: 'No significant price changes detected.')

## Recommendations
(Sourcing strategy advice based on pricing data)

## Sources
(References to email intel using [[wiki-links]] to 09-Email/Suppliers/ notes)

IMPORTANT: Use [[wiki-link]] syntax for all cross-references. Write in British English."

  local report
  report=$(generate_report "$prompt_text" 2500)

  if [ -n "$report" ]; then
    save_to_vault "05-Agent-Outputs/Research/${TODAY}-supplier-pricing.md" "$report"
  else
    log "ERROR: Failed to generate supplier pricing report"
  fi
}

# --- Main ---
PROFILES_WRITTEN=0
LANDSCAPE_WRITTEN=0
SUPPLIER_WRITTEN=0

if [ "$MODE" = "competitor" ] || [ "$MODE" = "full" ]; then
  write_competitor_profiles
  PROFILES_WRITTEN=$(jq '.competitors | length' "$PIPELINE_DIR/analysis/competitors.json" 2>/dev/null || echo "0")
  write_landscape_report
  LANDSCAPE_WRITTEN=1
fi

if [ "$MODE" = "supplier" ] || [ "$MODE" = "full" ]; then
  write_supplier_report
  SUPPLIER_WRITTEN=1
fi

log "PHASE 3 summary: $PROFILES_WRITTEN profiles, $LANDSCAPE_WRITTEN landscape, $SUPPLIER_WRITTEN supplier report"
