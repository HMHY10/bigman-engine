#!/usr/bin/env bash
# market-intel.sh — Market intelligence orchestrator for ArryBarry.
# Three modes: competitor, supplier, full
# Three phases: research (Haiku) → analyse (Sonnet) → write (Haiku)
#
# Usage:
#   market-intel.sh competitor "Name1" ["Name2" ...]
#   market-intel.sh supplier
#   market-intel.sh full
#
# Env: BRAVE_API_KEY, ANTHROPIC_API_KEY, OBSIDIAN_HOST, OBSIDIAN_API_KEY (via Doppler)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SYNC="$REPO_ROOT/skills/active/obsidian-sync/sync.sh"
STATE_FILE="$SCRIPT_DIR/market-intel-state.json"
PIPELINE_DIR="/tmp/market-intel"
LOCK_FILE="/tmp/market-intel.lock"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

log() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >&2; }

# --- Lockfile (prevent concurrent runs) ---
exec 200>"$LOCK_FILE"
flock -n 200 || { log "Another instance running. Exiting."; exit 0; }

# --- Mode ---
MODE="${1:?Usage: market-intel.sh <competitor|supplier|full> [names...]}"
shift

log "START mode=$MODE"

# --- Clean pipeline dir (clean-at-start pattern) ---
rm -rf "$PIPELINE_DIR"
mkdir -p "$PIPELINE_DIR/research" "$PIPELINE_DIR/analysis"

# --- Vault connectivity check ---
if ! "$SYNC" list "09-Email/" >/dev/null 2>&1; then
  log "ERROR: Obsidian vault unreachable. Exiting."
  exit 1
fi

# --- Initialise state file on first run ---
if [ ! -f "$STATE_FILE" ]; then
  echo '{"last_full_run":"","last_competitor_run":"","last_supplier_run":"","discovered_competitors":[]}' > "$STATE_FILE"
  log "Created initial state file"
fi

# --- Determine targets based on mode ---
COMPETITOR_NAMES=()
DO_COMPETITORS=false
DO_SUPPLIERS=false

case "$MODE" in
  competitor)
    DO_COMPETITORS=true
    if [ $# -eq 0 ]; then
      log "ERROR: competitor mode requires at least one name."
      exit 1
    fi
    COMPETITOR_NAMES=("$@")
    log "Targeting ${#COMPETITOR_NAMES[@]} specific competitor(s): ${COMPETITOR_NAMES[*]}"
    ;;

  supplier)
    DO_SUPPLIERS=true
    log "Running supplier pricing analysis"
    ;;

  full)
    DO_COMPETITORS=true
    DO_SUPPLIERS=true

    # Load competitor list from vault
    competitor_list=$("$SYNC" get "03-Resources/Competitors/competitor-list.md" 2>/dev/null || echo "")
    if [ -z "$competitor_list" ]; then
      log "ERROR: competitor-list.md empty or not found in vault. Exiting."
      exit 1
    fi

    # Extract names from markdown list (lines starting with "- ")
    while IFS= read -r line; do
      name=$(echo "$line" | sed 's/^- //' | xargs)
      [ -n "$name" ] && COMPETITOR_NAMES+=("$name")
    done < <(echo "$competitor_list" | grep '^- ' )

    if [ ${#COMPETITOR_NAMES[@]} -eq 0 ]; then
      log "ERROR: No competitors found in competitor-list.md. Exiting."
      exit 1
    fi

    log "Loaded ${#COMPETITOR_NAMES[@]} competitors from competitor-list.md"
    ;;

  *)
    log "ERROR: Unknown mode: $MODE. Use competitor, supplier, or full."
    exit 1
    ;;
esac

# --- Phase 1: Research ---
log "PHASE 1 (Research) starting..."

if $DO_COMPETITORS; then
  for name in "${COMPETITOR_NAMES[@]}"; do
    "$SCRIPT_DIR/phases/research.sh" competitor "$name" || {
      log "WARNING: Research failed for competitor '$name' — skipping"
    }
  done
fi

if $DO_SUPPLIERS; then
  "$SCRIPT_DIR/phases/research.sh" supplier || {
    log "WARNING: Supplier research failed"
  }
fi

# Check Phase 1 produced output
research_count=$(find "$PIPELINE_DIR/research" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
log "PHASE 1 complete: $research_count research files produced"

if [ "$research_count" -eq 0 ]; then
  log "ERROR: Phase 1 produced no output. Nothing to analyse. Exiting."
  rm -rf "$PIPELINE_DIR"
  exit 1
fi

# --- Phase 2: Analyse ---
log "PHASE 2 (Analyse) starting..."
"$SCRIPT_DIR/phases/analyse.sh" "$MODE"
log "PHASE 2 complete"

# --- Check Phase 2 produced analysable data ---
comp_analysed=$(jq '.competitors | length' "$PIPELINE_DIR/analysis/competitors.json" 2>/dev/null || echo "0")
supp_analysed=$(jq '.suppliers | length' "$PIPELINE_DIR/analysis/suppliers.json" 2>/dev/null || echo "0")
if [ "$comp_analysed" -eq 0 ] && [ "$supp_analysed" -eq 0 ]; then
  log "ERROR: Phase 2 produced no analysed data. Exiting."
  rm -rf "$PIPELINE_DIR"
  exit 1
fi

# --- Phase 3: Write ---
log "PHASE 3 (Write) starting..."
"$SCRIPT_DIR/phases/write.sh" "$MODE"
log "PHASE 3 complete"

# --- Update state ---
case "$MODE" in
  competitor)
    jq --arg ts "$NOW" '.last_competitor_run = $ts' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    ;;
  supplier)
    jq --arg ts "$NOW" '.last_supplier_run = $ts' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    ;;
  full)
    jq --arg ts "$NOW" '.last_full_run = $ts | .last_competitor_run = $ts | .last_supplier_run = $ts' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    ;;
esac

# --- Merge discovered competitors into state ---
disc_count=0
if [ -f "$PIPELINE_DIR/analysis/discovered.json" ]; then
  discovered=$(cat "$PIPELINE_DIR/analysis/discovered.json")
  if [ "$discovered" != "[]" ] && [ "$discovered" != "null" ] && [ -n "$discovered" ]; then
    jq --argjson new "$discovered" \
      '.discovered_competitors += $new | .discovered_competitors |= unique_by(.name)' \
      "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    disc_count=$(echo "$discovered" | jq 'length')
    log "Added $disc_count newly discovered competitor(s) to state"
  fi
fi

# --- Cleanup ---
rm -rf "$PIPELINE_DIR"
log "END: $comp_analysed competitors, $supp_analysed suppliers analysed, $disc_count discovered, mode=$MODE"
