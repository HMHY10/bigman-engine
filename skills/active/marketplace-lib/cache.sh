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

# ── _cache_age_hours <domain> <key> ───────────────────────────────────
# Return age in hours of a cache entry, or -1 if missing.
_cache_age_hours() {
  local file="${CACHE_BASE}/${1}/${2}.json"
  [[ ! -f "$file" ]] && { echo -1; return; }
  local mtime now
  mtime=$(_file_mtime "$file")
  now=$(date +%s)
  echo $(( (now - mtime) / 3600 ))
}

# ── cache_fresh <domain> <key> [max_age_hours] ────────────────────────
# Return 0 if cache entry is fresh, 1 if stale or missing.
cache_fresh() {
  local max_age="${3:-$CACHE_DEFAULT_MAX_AGE}"
  local age
  age=$(_cache_age_hours "$1" "$2")
  (( age >= 0 && age < max_age ))
}

# ── cache_read <domain> <key> [max_age_hours] ─────────────────────────
# Print cached JSON to stdout. Returns empty string if expired or missing.
cache_read() {
  local domain="$1" key="$2" max_age="${3:-$CACHE_DEFAULT_MAX_AGE}"
  local file="${CACHE_BASE}/${domain}/${key}.json"

  if ! cache_fresh "$domain" "$key" "$max_age"; then
    local age
    age=$(_cache_age_hours "$domain" "$key")
    (( age >= 0 )) && log "cache_read: ${domain}/${key} expired (${age}h >= ${max_age}h)"
    return 0
  fi

  cat "$file"
}

# ── cache_rotate [days] ───────────────────────────────────────────────
# Delete cache files older than N days.
cache_rotate() {
  local days="${1:-$CACHE_ROTATION_DAYS}"
  local count=0
  while IFS= read -r f; do
    rm -f "$f"
    count=$((count + 1))
  done < <(find "$CACHE_BASE" -type f -name '*.json' -mtime +"$days" 2>/dev/null)

  if (( count > 0 )); then
    log "cache_rotate: removed ${count} files older than ${days} days"
  else
    log "cache_rotate: nothing to purge (threshold ${days} days)"
  fi
}
