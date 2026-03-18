#!/usr/bin/env bash
# marketplace-lib/cache.sh — Local cache helpers
# Requires: config.sh sourced first

# ── cache_write <domain> <key> <json> ──────────────────────────────────
# Write JSON data to cache file and update last-sync timestamp.
cache_write() {
  local domain="$1" key="$2" json="$3"
  local dir="${CACHE_BASE}/${domain}"
  local file="${dir}/${key}.json"

  mkdir -p "$dir"
  printf '%s' "$json" > "$file"

  # Update last-sync metadata
  printf '{"domain":"%s","key":"%s","synced_at":"%s","epoch":%d}\n' \
    "$domain" "$key" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(date +%s)" \
    > "${dir}/last-sync.json"

  log "cache_write: ${domain}/${key} ($(printf '%s' "$json" | wc -c | tr -d ' ') bytes)"
}

# ── _file_mtime <filepath> ────────────────────────────────────────────
# Return file modification epoch. Linux stat first, macOS fallback.
_file_mtime() {
  stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null || echo 0
}

# ── cache_read <domain> <key> [max_age_hours] ─────────────────────────
# Print cached JSON to stdout. Returns empty string if expired or missing.
cache_read() {
  local domain="$1" key="$2" max_age="${3:-$CACHE_DEFAULT_MAX_AGE}"
  local file="${CACHE_BASE}/${domain}/${key}.json"

  if [[ ! -f "$file" ]]; then
    return 0
  fi

  local mtime now age_hours
  mtime=$(_file_mtime "$file")
  now=$(date +%s)
  age_hours=$(( (now - mtime) / 3600 ))

  if (( age_hours >= max_age )); then
    log "cache_read: ${domain}/${key} expired (${age_hours}h >= ${max_age}h)"
    return 0
  fi

  cat "$file"
}

# ── cache_fresh <domain> <key> [max_age_hours] ────────────────────────
# Return 0 if cache entry is fresh, 1 if stale or missing.
cache_fresh() {
  local domain="$1" key="$2" max_age="${3:-$CACHE_DEFAULT_MAX_AGE}"
  local file="${CACHE_BASE}/${domain}/${key}.json"

  if [[ ! -f "$file" ]]; then
    return 1
  fi

  local mtime now age_hours
  mtime=$(_file_mtime "$file")
  now=$(date +%s)
  age_hours=$(( (now - mtime) / 3600 ))

  if (( age_hours >= max_age )); then
    return 1
  fi
  return 0
}

# ── cache_rotate [days] ───────────────────────────────────────────────
# Delete cache files older than N days.
cache_rotate() {
  local days="${1:-$CACHE_ROTATION_DAYS}"
  local count
  count=$(find "$CACHE_BASE" -type f -name '*.json' -mtime +"$days" 2>/dev/null | wc -l | tr -d ' ')
  if (( count > 0 )); then
    find "$CACHE_BASE" -type f -name '*.json' -mtime +"$days" -delete
    log "cache_rotate: removed ${count} files older than ${days} days"
  else
    log "cache_rotate: nothing to purge (threshold ${days} days)"
  fi
}
