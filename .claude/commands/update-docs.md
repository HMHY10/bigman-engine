---
description: Analyze user-facing docs against the current codebase and produce an update plan
---

Enter plan mode first. Do NOT edit any files — this command only produces an analysis and a prioritized todo list. The user will decide what to implement.

Follow these steps IN ORDER. The sequence matters — you must understand the product before you can judge the docs.

## Step 1 — Understand the current product

Read the codebase to build a picture of what thepopebot actually does today. Look at features, commands, config options, workflows, integrations, and user-facing behavior. Start from the code, not the docs — you need an independent understanding of the product's current state.

## Step 2 — Find what's changed recently

Use git to find significant changes since the docs were last touched. For each doc file, check when it was last modified and what code has changed in its relevant area since then.

Build a list of:
- **New** — features, commands, config options, integrations that didn't exist before
- **Changed** — behavior, APIs, workflows, defaults that work differently now
- **Removed** — things that no longer exist but might still be documented

## Step 3 — Read all existing docs

Read `README.md` and everything in `docs/`. For each file, judge:
- Is the content still accurate?
- Is this still needed as its own doc, or should it be folded into another?
- Should this be split, merged, renamed, or deleted?
- Does it describe things that no longer exist?
- Is it clear enough for a new user to follow?

**Leave the README hero section alone.** The top of README (tagline, "What You Get", "Why It Works") is stable marketing copy. Only flag changes there if a major new capability was added that genuinely belongs in the highlights.

## Step 4 — Identify gaps

What does the product do that has no documentation at all? What would a new user struggle with? What questions would someone ask that no doc answers? Are there docs that should exist but don't?

## Step 5 — Produce the update plan

Create a prioritized list of changes. Each item says what to do and why. Categories include:
- Update existing docs (with specifics on what's wrong)
- Delete docs that are no longer useful
- Create new docs for uncovered areas
- Merge docs that overlap
- Update README doc links to match any structural changes

Keep the README short — it should sell, install, upgrade, and link to docs. Detailed content belongs in `docs/` files.

If there are $ARGUMENTS, treat them as focus areas for the analysis.
