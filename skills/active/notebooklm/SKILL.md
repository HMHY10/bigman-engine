---
name: notebooklm
description: Transform vault content into audio, slides, quizzes, flashcards, mind maps, and infographics via Google NotebookLM. Use when asked to create podcasts, presentations, training materials, or visual summaries from vault notes.
---

# NotebookLM — Content Transformation

On-demand skill that feeds Obsidian vault notes into Google NotebookLM and generates different output formats.

## Usage

```bash
# Audio overview (podcast)
cd /opt/bigman-engine && doppler run --project shared-services --config prd -- \
  /opt/bigman-engine/venvs/notebooklm/bin/python3 skills/active/notebooklm/notebooklm-skill.py \
  audio "05-Agent-Outputs/Research/2026-03-17-competitive-landscape.md"

# Slides from multiple sources
cd /opt/bigman-engine && doppler run --project shared-services --config prd -- \
  /opt/bigman-engine/venvs/notebooklm/bin/python3 skills/active/notebooklm/notebooklm-skill.py \
  slides "05-Agent-Outputs/Research/2026-03-17-competitive-landscape.md" \
         "04-Agent-Knowledge/ArryBarry-Context.md"

# Quiz from product data
cd /opt/bigman-engine && doppler run --project shared-services --config prd -- \
  /opt/bigman-engine/venvs/notebooklm/bin/python3 skills/active/notebooklm/notebooklm-skill.py \
  quiz "09-Email/Products/organic-face-serum.md"
```

## Supported Formats

| Format | Arg | Output |
|--------|-----|--------|
| Audio overview | `audio` | MP3 |
| Slide deck | `slides` | PPTX |
| Quiz | `quiz` | JSON |
| Flashcards | `flashcards` | JSON |
| Mind map | `mindmap` | JSON |
| Infographic | `infographic` | PNG |

## Options

- `--topic NAME` — override auto-generated topic (default: derived from first vault path filename)
- `--keep` — don't delete the NotebookLM notebook after generation (for debugging)

## Output

- **Artifacts:** `/opt/bigman-engine/outputs/notebooklm/{format}/`
- **Vault index:** `05-Agent-Outputs/NotebookLM/YYYY-MM-DD-{topic}-{format}.md`

## Auth

Uses Google session cookies stored as `NOTEBOOKLM_AUTH_JSON` in Doppler `shared-services`.

**Cookies expire every 1-2 weeks.** To refresh:
1. On Mac: `source ~/notebooklm-venv/bin/activate && notebooklm login`
2. On Mac: `doppler secrets set NOTEBOOKLM_AUTH_JSON="$(cat ~/.notebooklm/storage_state.json)" -p shared-services -c prd`

A daily health check cron at 8am logs warnings to `/var/log/notebooklm-health.log` when auth is expired.

## Important

- Uses unofficial Google APIs — can break without notice
- Recommended for internal/prototype use, not customer-facing production
- Rate limited: 2-second delay between API operations, exponential backoff on failures
- Generation can take several minutes (especially audio)
