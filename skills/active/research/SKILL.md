---
name: research
description: Web research via Brave Search with synthesis and Obsidian vault output. Use for any research task — market research, competitor analysis, product sourcing, trend analysis.
---

# Research

Conducts web research using Brave Search, synthesises findings with LLM analysis, and saves structured research briefs to the Obsidian vault.

## Workflow

1. **Read context** — Load SOUL.md and ArryBarry-Context.md from Obsidian for brand/business context
2. **Search** — Run one or more Brave Search queries using the search tool
3. **Deep read** — For the most relevant results, fetch full page content
4. **Synthesise** — Analyse findings, cross-reference sources, identify key insights
5. **Write brief** — Format as a research brief and save to Obsidian vault
6. **Summary** — Return a concise summary of findings

## Search Tool

```bash
# Basic search (5 results)
skills/brave-search/search.js "query"

# More results
skills/brave-search/search.js "query" -n 10

# With full page content (slower but more thorough)
skills/brave-search/search.js "query" --content

# Recent results only
skills/brave-search/search.js "query" --freshness pw    # past week
skills/brave-search/search.js "query" --freshness pm    # past month

# UK-focused results
skills/brave-search/search.js "query" --country GB

# Combined
skills/brave-search/search.js "query" -n 8 --content --country GB --freshness pm
```

### Fetch specific page content
```bash
skills/brave-search/content.js https://example.com/article
```

## Convenience Script

```bash
# Quick search with defaults (8 results, GB, content extraction)
skills/active/research/research.sh "query"

# Custom options
skills/active/research/research.sh "query" -n 5 --freshness pw
```

## Reading from Obsidian

```bash
# Get brand voice context
skills/active/obsidian-sync/sync.sh get "04-Agent-Knowledge/SOUL.md"

# Get business context
skills/active/obsidian-sync/sync.sh get "04-Agent-Knowledge/ArryBarry-Context.md"

# Check existing research
skills/active/obsidian-sync/sync.sh list "05-Agent-Outputs/Research/"
```

## Writing Results to Obsidian

Save the research brief to `05-Agent-Outputs/Research/` using the obsidian-sync skill:

```bash
skills/active/obsidian-sync/sync.sh put "05-Agent-Outputs/Research/YYYY-MM-DD-slug-title.md" "content"
```

Or write from a local file:
```bash
skills/active/obsidian-sync/sync.sh put-file "05-Agent-Outputs/Research/YYYY-MM-DD-slug-title.md" /tmp/research-brief.md
```

## Output Format

Every research brief MUST follow this structure:

```markdown
# Research: {title}

**Date:** {YYYY-MM-DD}
**Requested by:** {who asked — user name or "auto"}
**Agent:** bigman-research

## Objective
{What we set out to find and why}

## Key Findings
1. {Finding with specific data points}
2. {Finding with specific data points}
3. {Finding with specific data points}

## Sources
- [{Title}]({URL}) — {brief note on what this source provided}
- [{Title}]({URL}) — {brief note}

## Recommendations
{Actionable next steps based on findings}

## Confidence Level
{High / Medium / Low — explain what is well-supported vs uncertain}

## Related Notes
- [[relevant-vault-note]]
```

## Research Strategy

- **Broad first:** Start with a general query, then narrow based on initial results
- **Multiple angles:** Run 2-3 different queries to triangulate information
- **Verify claims:** Cross-reference key facts across multiple sources
- **UK focus:** Default to `--country GB` for market/product research
- **Freshness matters:** Use `--freshness pm` for trend/market data, skip for evergreen topics
- **Deep read selectively:** Use `--content` or `content.js` only for the most promising results

## Environment Variables

- `BRAVE_API_KEY` — Brave Search API key (set in Doppler bigman-engine/prd)
- `OBSIDIAN_HOST` — Vault REST API URL
- `OBSIDIAN_API_KEY` — Vault auth token

## When to Use

- Market research for new product categories
- Supplier and ingredient research
- Competitor analysis
- Health & beauty trend identification
- Regulatory/compliance research
- Customer sentiment research
- SEO keyword research

## Important Rules

- Follow SOUL.md operating principles — accuracy first, flag uncertainty
- Use British English throughout
- Never fabricate sources — only cite URLs actually found in search results
- Add `⚠️ REVIEW NEEDED` tag if confidence is below 80%
- Always note the research date — health/beauty information changes frequently
- Save ALL research to Obsidian, even if results are inconclusive
