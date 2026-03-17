#!/usr/bin/env bash
# Content-Prep — gathers context for the content-writer skill.
# Reads SOUL.md, ArryBarry-Context.md, and discovers relevant research briefs.
# All reads are LOCAL (no network calls). Output: /tmp/content-context.md
# EXIT CODE: Always 0 (never fails the job). Status communicated via Context Status header.
#
# Usage: content-prep.sh "job prompt text"

# Trap: ensure exit 0 no matter what
trap 'exit 0' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CONTEXT_DIR="$REPO_ROOT/skills/context"
LOGS_DIR="$REPO_ROOT/logs"
OUTPUT="/tmp/content-context.md"

PROMPT="${1:-}"
if [ -z "$PROMPT" ]; then
  echo "[content-prep] Usage: content-prep.sh \"job prompt text\"" >&2
  echo "## Context Status: partial" > "$OUTPUT"
  exit 0
fi

# Stopwords to strip from prompt before keyword matching
STOPWORDS="the a an is are was were for about with from this that and or but in on to of write create draft generate produce make blog post email content copy description"

status="full"

# --- Read SOUL.md ---
soul_content=""
if [ -f "$CONTEXT_DIR/SOUL.md" ]; then
  soul_content="$(cat "$CONTEXT_DIR/SOUL.md")"
else
  echo "[content-prep] WARNING: SOUL.md not found at $CONTEXT_DIR/SOUL.md" >&2
  soul_content="Not available"
  status="partial"
fi

# --- Read ArryBarry-Context.md ---
biz_content=""
if [ -f "$CONTEXT_DIR/ArryBarry-Context.md" ]; then
  biz_content="$(cat "$CONTEXT_DIR/ArryBarry-Context.md")"
else
  echo "[content-prep] WARNING: ArryBarry-Context.md not found at $CONTEXT_DIR/ArryBarry-Context.md" >&2
  biz_content="Not available"
  status="partial"
fi

# --- Discover research briefs ---
research_content="No matching research found"

if [ -d "$LOGS_DIR" ]; then
  # Extract keywords from prompt (lowercase, strip stopwords, min 4 chars to avoid false positives)
  keywords=""
  for word in $(echo "$PROMPT" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' ' '); do
    skip=false
    for stop in $STOPWORDS; do
      if [ "$word" = "$stop" ]; then
        skip=true
        break
      fi
    done
    if [ "$skip" = false ] && [ ${#word} -gt 3 ]; then
      keywords="$keywords $word"
    fi
  done
  keywords="$(echo "$keywords" | xargs)"  # trim

  if [ -n "$keywords" ]; then
    # Find research briefs in logs — .md files with "# Research:" heading
    # Format: score<TAB>filepath (tab-delimited to handle spaces in paths)
    matches=""
    while IFS= read -r file; do
      # Check if file contains a Research heading
      if head -5 "$file" 2>/dev/null | grep -q "^# Research:"; then
        # Score by keyword overlap with filename slug
        fname="$(basename "$file" | tr '[:upper:]' '[:lower:]')"
        score=0
        for kw in $keywords; do
          if echo "$fname" | grep -q "$kw"; then
            score=$((score + 1))
          fi
        done
        if [ "$score" -gt 0 ]; then
          matches="${matches}${score}	${file}"$'\n'
        fi
      fi
    done < <(find "$LOGS_DIR" -name "*.md" -type f 2>/dev/null)

    if [ -n "$matches" ]; then
      # Sort by score desc (k1), then by filepath desc for date tiebreak (k2), take top 3
      # Tab-delimited to handle spaces in paths
      top_files="$(echo "$matches" | sort -t'	' -k1 -rn -k2 -r | head -3 | cut -f2)"
      research_content=""
      while IFS= read -r brief; do
        if [ -n "$brief" ] && [ -f "$brief" ]; then
          research_content="$research_content
---
**Source:** $(basename "$brief")

$(cat "$brief")
"
        fi
      done <<< "$top_files"
    fi
  fi
fi

# --- Write output ---
cat > "$OUTPUT" << CONTEXT_EOF
## Context Status: $status

## Brand Voice (SOUL.md)
$soul_content

## Business Context (ArryBarry-Context.md)
$biz_content

## Related Research
$research_content
CONTEXT_EOF

echo "[content-prep] Context written to $OUTPUT (status: $status)"
