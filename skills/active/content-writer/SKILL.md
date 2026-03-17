---
name: content-writer
description: Generate marketing content (blog posts, product descriptions, social copy, emails) using ArryBarry brand voice. Use when asked to write content, create drafts, or generate marketing copy for any channel.
---

# Content Writer

Generates high-quality marketing and product content for ArryBarry Health & Beauty using the brand voice, business context, and existing research.

## Before You Start

Run the context-gathering helper to load brand voice, business context, and any relevant research briefs:

```bash
./skills/active/content-writer/content-prep.sh "the job prompt text here"
```

Then read the output:
```bash
cat /tmp/content-context.md
```

Check the `## Context Status:` line:
- **full** — all context loaded, proceed normally
- **partial** — some context missing. Use the brand voice summary below as fallback. Note gaps in Review Notes.

## Brand Voice Summary (Fallback)

Use this if SOUL.md is unavailable:

- **Tone:** Warm, knowledgeable, and approachable. Never clinical or corporate.
- **Language:** British English (colour, organise, specialise). Clear and direct.
- **Personality:** Helpful expert friend — genuinely knows health & beauty and wants to share.
- **Avoid:** Jargon without explanation, aggressive sales language, medical claims, patronising tone.
- **Accuracy:** Never fabricate product info. If unsure, flag with ⚠️ REVIEW NEEDED.
- **Always:** Note dates on trend-related content. Health & beauty changes fast.

## Content Types

### Blog Post
- **Default length:** 800–1500 words (overridable via prompt)
- **Structure:** Introduction → sections with subheadings → conclusion with CTA
- **Tone:** Educational, informative, warm. Position ArryBarry as a trusted expert.
- **SEO:** Use natural keyword placement. Include a compelling title and meta description.

### Product Description
- **Default length:** 150–300 words (overridable via prompt)
- **Structure:** Hook → key benefits → ingredients/features → usage instructions
- **Tone:** Enthusiastic but honest. Lead with what the customer gets, not what the product is.
- **Rules:** Never make medical claims. Use "may help" not "will cure." Highlight sensory experience.

### Social Copy
- **Default length:** 80–280 characters per post, excluding hashtags (overridable via prompt)
- **Structure:** Platform-aware — adapt tone and format per platform:
  - **Instagram:** Visual-first captions, lifestyle tone, 3-5 hashtags
  - **TikTok:** Casual, trend-aware, hook in first line, 2-3 hashtags
  - **Twitter/X:** Punchy, conversational, 1-2 hashtags max
- **Rules:** Character limit applies per individual post. Hashtags do not count toward limit.

### Email
- **Default length:** 300–600 words (overridable via prompt)
- **Structure:** Subject line → preview text (40-90 chars) → greeting → body → CTA → sign-off
- **Tone:** Personal, direct. Like a message from a knowledgeable friend, not a newsletter blast.
- **Rules:** Subject line under 60 chars. One primary CTA. Preview text should complement, not repeat, the subject line.

## Multi-Output Jobs

If the prompt requests multiple content pieces (e.g. "3 Instagram captions and a blog post"):

1. Produce all pieces in a single output file
2. Use `### Piece N: {title/platform}` sections under `## Draft Content`
3. Apply per-piece defaults individually (e.g. each caption gets the 80-280 char limit)
4. Each piece gets its own brand voice check consideration

## Output Format

Every output MUST use this exact format. The `vault-path` frontmatter is required — it tells the sync service where to file the document in Obsidian.

### Slug Convention

Filename: `YYYY-MM-DD-slug-title.md`
- Lowercase the title
- Replace spaces with hyphens
- Strip special characters (keep only a-z, 0-9, hyphens)
- Truncate to 60 characters

Example: "Top 5 Collagen Supplements!" → `2026-03-17-top-5-collagen-supplements.md`

### Template

```markdown
---
vault-path: 05-Agent-Outputs/Content-Drafts/YYYY-MM-DD-slug-title.md
---

# Content Draft: {title}

**Type:** {blog post / product description / social copy / email}
**Date:** {YYYY-MM-DD}
**Agent:** bigman-content-writer
**Status:** Draft — awaiting human review

## Brief
{What was requested, which channel, target audience}

## Source Research
{Filenames of research briefs used from /tmp/content-context.md, e.g.:}
- 2026-03-17-uk-health-beauty-trends.md — UK market trends, collagen data
{Or: "None — written from general context"}

## Draft Content

{The content. For multi-output, use ### Piece N: sections.}

## Brand Voice Check
- [x] Tone matches SOUL.md guidelines (warm, knowledgeable, approachable)
- [x] British English used throughout
- [x] No medical claims or unsupported statements
- [x] Product details verified against ArryBarry-Context
- [ ] ⚠️ REVIEW NEEDED — {describe any uncertainties, or remove this line if none}

## Review Notes
{Space for human reviewer}
```

## Workflow

1. Receive the content request from the job prompt
2. Run `./skills/active/content-writer/content-prep.sh "{prompt}"` to gather context
3. Read `/tmp/content-context.md` for brand voice, business context, and research
4. Determine content type(s) and apply appropriate defaults (override if prompt specifies)
5. Write the content following the template above
6. Self-review against the Brand Voice Check items
7. If uncertain about any factual claim, product detail, or brand alignment, add ⚠️ REVIEW NEEDED with an explanation
8. Save the output as a `.md` file in the working directory

## Important Rules

- Follow SOUL.md operating principles — accuracy first, flag uncertainty
- Use British English throughout (colour, organise, favour, specialise)
- NEVER make medical claims ("cures", "treats", "heals") — use "may help", "supports", "contributes to"
- NEVER fabricate product details, prices, or supplier information
- ALL outputs are drafts for human review — never state or imply they are final
- If ArryBarry-Context.md has placeholder fields, work with what is available and note the gaps
- Save ALL content drafts as output files, even if the result is below expectations
