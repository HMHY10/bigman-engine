#!/usr/bin/env bash
# analyse.sh — Phase 2: Strategic analysis for market intelligence.
# Cross-references research data against ArryBarry positioning.
# Uses Claude Sonnet for strategic analysis (one competitor per call).
# Auto-discovers competitors from email intelligence.
#
# Usage: analyse.sh <competitor|supplier|full>
#
# Reads from: /tmp/market-intel/research/*.json, vault (ArryBarry context)
# Writes to: /tmp/market-intel/analysis/competitors.json, suppliers.json, discovered.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SKILL_DIR/../../.." && pwd)"
SYNC="$REPO_ROOT/skills/active/obsidian-sync/sync.sh"
PIPELINE_DIR="/tmp/market-intel"

log() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >&2; }

MODE="${1:?Usage: analyse.sh <competitor|supplier|full>}"
TODAY=$(date -u +"%Y-%m-%d")

# --- Load ArryBarry positioning context (used in every analysis call) ---
ARRYBARRY_CONTEXT=$("$SYNC" get "04-Agent-Knowledge/ArryBarry-Context.md" 2>/dev/null || echo "")
if [ -z "$ARRYBARRY_CONTEXT" ]; then
  log "WARNING: ArryBarry-Context.md not found in vault. Analysis will lack positioning context."
  ARRYBARRY_CONTEXT="ArryBarry Health & Beauty is a UK-based online marketplace for curated health and beauty products."
fi

# Truncate context to avoid blowing Sonnet's input (keep under 3000 chars)
ARRYBARRY_CONTEXT=$(echo "$ARRYBARRY_CONTEXT" | head -c 3000)

# --- LLM call: analyse one competitor via Sonnet ---
analyse_competitor() {
  local research_json="$1"

  local prompt
  prompt=$(jq -n \
    --arg context "$ARRYBARRY_CONTEXT" \
    --arg research "$research_json" \
    '{
      model: "claude-sonnet-4-6",
      max_tokens: 2000,
      temperature: 0,
      messages: [{
        role: "user",
        content: ("You are a strategic market analyst for ArryBarry Health & Beauty, a UK-based online health and beauty marketplace.\n\n## ArryBarry Positioning\n" + $context + "\n\n## Competitor Research Data\n" + $research + "\n\nAnalyse this competitor against ArryBarry. Respond with ONLY valid JSON (no markdown fencing):\n{\n  \"name\": \"competitor name\",\n  \"slug\": \"competitor-slug\",\n  \"threat_level\": \"high|medium|low\",\n  \"positioning_vs_arrybarry\": \"How they compare to ArryBarry in 2-3 sentences\",\n  \"strengths\": [\"strength 1\", \"strength 2\"],\n  \"weaknesses\": [\"weakness 1\", \"weakness 2\"],\n  \"opportunities\": [\"How ArryBarry can capitalise\"],\n  \"threats\": [\"Risks to ArryBarry\"],\n  \"recommendations\": [\"What ArryBarry should do\"]\n}")
      }]
    }')

  local response
  response=$(curl -sf "https://api.anthropic.com/v1/messages" \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "$prompt" 2>/dev/null)

  if [ -z "$response" ]; then
    log "ERROR: Sonnet API call failed"
    return 1
  fi

  local text
  text=$(echo "$response" | jq -r '.content[0].text // empty' | sed '/^```/d')

  if [ -z "$text" ] || ! echo "$text" | jq '.' >/dev/null 2>&1; then
    log "ERROR: Invalid JSON from Sonnet"
    return 1
  fi

  echo "$text"
}

# --- LLM call: analyse supplier data via Sonnet ---
analyse_supplier() {
  local research_json="$1"

  local prompt
  prompt=$(jq -n \
    --arg context "$ARRYBARRY_CONTEXT" \
    --arg research "$research_json" \
    '{
      model: "claude-sonnet-4-6",
      max_tokens: 1500,
      temperature: 0,
      messages: [{
        role: "user",
        content: ("You are a procurement analyst for ArryBarry Health & Beauty.\n\n## Business Context\n" + $context + "\n\n## Supplier Research Data\n" + $research + "\n\nAnalyse this supplier. Respond with ONLY valid JSON (no markdown fencing):\n{\n  \"name\": \"supplier name\",\n  \"slug\": \"supplier-slug\",\n  \"products\": [\"product category 1\"],\n  \"current_pricing\": {\"product_name_unit\": \"£X.XX\", \"last_quoted\": \"date if known\"},\n  \"price_trend\": \"increasing|stable|decreasing|unknown\",\n  \"lead_time\": \"estimated lead time or unknown\",\n  \"payment_terms\": \"terms if known or unknown\",\n  \"alternatives\": [\"alternative supplier (£X.XX/unit, lead time)\"],\n  \"recommendation\": \"procurement recommendation in 1-2 sentences\"\n}\n\nFor current_pricing, use product-specific keys (e.g. kraft_box_unit, tissue_paper_pack) with price values. Include as many products as the data supports.")
      }]
    }')

  local response
  response=$(curl -sf "https://api.anthropic.com/v1/messages" \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "$prompt" 2>/dev/null)

  if [ -z "$response" ]; then
    log "ERROR: Sonnet API call failed for supplier"
    return 1
  fi

  local text
  text=$(echo "$response" | jq -r '.content[0].text // empty' | sed '/^```/d')

  if [ -z "$text" ] || ! echo "$text" | jq '.' >/dev/null 2>&1; then
    log "ERROR: Invalid JSON from Sonnet for supplier"
    return 1
  fi

  echo "$text"
}

# --- Auto-discover competitors from email intel ---
discover_competitors() {
  local known_names="$1"

  log "Auto-discovery: scanning email intel for unknown competitors..."

  local all_content=""

  for category in Marketing Partnerships; do
    local files
    files=$("$SYNC" list "09-Email/${category}/" 2>/dev/null | jq -r '.files[]' 2>/dev/null || echo "")
    [ -z "$files" ] && continue

    while IFS= read -r f; do
      [ -z "$f" ] && continue
      local fname
      fname=$(basename "$f" 2>/dev/null || echo "$f")
      local content
      content=$("$SYNC" get "09-Email/${category}/${fname}" 2>/dev/null || echo "")
      if [ -n "$content" ]; then
        all_content="${all_content}

--- ${category}/${fname} ---
$(echo "$content" | head -c 1000)"
      fi
    done <<< "$files"
  done

  if [ -z "$all_content" ]; then
    log "Auto-discovery: no email intel to scan"
    echo "[]"
    return 0
  fi

  # Truncate to avoid massive prompt
  all_content=$(echo "$all_content" | head -c 6000)

  local prompt
  prompt=$(jq -n \
    --arg known "$known_names" \
    --arg emails "$all_content" \
    --arg today "$TODAY" \
    '{
      model: "claude-haiku-4-5-20251001",
      max_tokens: 500,
      temperature: 0,
      messages: [{
        role: "user",
        content: ("You are scanning email intelligence for ArryBarry Health & Beauty to find potential competitors.\n\nKnown competitors (DO NOT include these):\n" + $known + "\n\nEmail entity notes:\n" + $emails + "\n\nIdentify company names mentioned that are NOT in the known list and appear to be in the health, beauty, wellness, or related market. Only flag companies that seem like genuine competitors, not suppliers or partners.\n\nRespond with ONLY valid JSON (no markdown fencing):\n[\n  {\"name\": \"Company Name\", \"source\": \"09-Email/Category/filename.md\", \"discovered\": \"" + $today + "\", \"reason\": \"Why this appears to be a competitor\", \"reviewed\": false}\n]\n\nIf no new competitors found, respond with: []")
      }]
    }')

  local response
  response=$(curl -sf "https://api.anthropic.com/v1/messages" \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "$prompt" 2>/dev/null)

  if [ -z "$response" ]; then
    log "Auto-discovery: LLM call failed"
    echo "[]"
    return 0
  fi

  local raw_text
  raw_text=$(echo "$response" | jq -r '.content[0].text // empty' | sed '/^```/d')

  # LLM sometimes appends explanation after the JSON — extract just the JSON array
  local text
  text=$(echo "$raw_text" | grep -E '^\[' | head -1)
  [ -z "$text" ] && text="$raw_text"

  if echo "$text" | jq '.' >/dev/null 2>&1; then
    local count
    count=$(echo "$text" | jq 'length')
    log "Auto-discovery: found $count potential new competitor(s)"
    echo "$text"
  else
    log "Auto-discovery: invalid JSON response"
    echo "[]"
  fi
}

# --- Main ---

# --- Analyse competitors ---
competitors_json='{"analysis_date":"'"$TODAY"'","arrybarry_positioning":"","competitors":[],"discovered_competitors":[]}'

if [ "$MODE" = "competitor" ] || [ "$MODE" = "full" ]; then
  # Build positioning summary (first 500 chars)
  positioning_summary=$(echo "$ARRYBARRY_CONTEXT" | head -c 500)
  competitors_json=$(echo "$competitors_json" | jq --arg pos "$positioning_summary" '.arrybarry_positioning = $pos')

  # Analyse each competitor's research file
  for research_file in "$PIPELINE_DIR"/research/*.json; do
    [ ! -f "$research_file" ] && continue

    # Skip supplier research files
    file_type=$(jq -r '.type // "unknown"' "$research_file" 2>/dev/null)
    [ "$file_type" != "competitor" ] && continue

    comp_name=$(jq -r '.name // "Unknown"' "$research_file")
    log "Analyse: competitor '$comp_name'..."

    research_content=$(cat "$research_file")

    analysis=$(analyse_competitor "$research_content")

    if [ -n "$analysis" ]; then
      competitors_json=$(echo "$competitors_json" | jq --argjson a "$analysis" '.competitors += [$a]')
      log "Analyse: $comp_name — done (threat: $(echo "$analysis" | jq -r '.threat_level'))"
    else
      log "WARNING: Analysis failed for $comp_name — skipping"
    fi
  done

  # --- Auto-discover competitors ---
  known_list=$(echo "$competitors_json" | jq -r '.competitors[].name' | tr '\n' ', ' || echo "")
  # Add names from research files too
  for rf in "$PIPELINE_DIR"/research/*.json; do
    [ ! -f "$rf" ] && continue
    n=$(jq -r '.name // empty' "$rf" 2>/dev/null)
    [ -n "$n" ] && known_list="${known_list}${n}, "
  done

  discovered=$(discover_competitors "$known_list")
  if [ "$discovered" != "[]" ] && [ -n "$discovered" ]; then
    competitors_json=$(echo "$competitors_json" | jq --argjson d "$discovered" '.discovered_competitors = $d')
  fi
fi

echo "$competitors_json" > "$PIPELINE_DIR/analysis/competitors.json"

# --- Analyse suppliers ---
suppliers_json='{"analysis_date":"'"$TODAY"'","suppliers":[]}'

if [ "$MODE" = "supplier" ] || [ "$MODE" = "full" ]; then
  for research_file in "$PIPELINE_DIR"/research/*.json; do
    [ ! -f "$research_file" ] && continue

    file_type=$(jq -r '.type // "unknown"' "$research_file" 2>/dev/null)
    [ "$file_type" != "supplier" ] && continue

    supplier_name=$(jq -r '.name // "Unknown"' "$research_file")
    log "Analyse: supplier '$supplier_name'..."

    research_content=$(cat "$research_file")

    analysis=$(analyse_supplier "$research_content")

    if [ -n "$analysis" ]; then
      suppliers_json=$(echo "$suppliers_json" | jq --argjson a "$analysis" '.suppliers += [$a]')
      log "Analyse: supplier $supplier_name — done"
    else
      log "WARNING: Analysis failed for supplier $supplier_name — skipping"
    fi
  done
fi

echo "$suppliers_json" > "$PIPELINE_DIR/analysis/suppliers.json"

# --- Save discovered competitors separately (for state merge) ---
discovered_out=$(echo "$competitors_json" | jq '.discovered_competitors // []')
echo "$discovered_out" > "$PIPELINE_DIR/analysis/discovered.json"

comp_count=$(echo "$competitors_json" | jq '.competitors | length')
supp_count=$(echo "$suppliers_json" | jq '.suppliers | length')
disc_count=$(echo "$discovered_out" | jq 'length')

log "PHASE 2 summary: $comp_count competitors analysed, $supp_count suppliers analysed, $disc_count new competitor(s) discovered"
