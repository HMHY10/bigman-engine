#!/usr/bin/env node
/**
 * Vault Sync Service — syncs job outputs from GitHub to Obsidian vault.
 * Runs on VPS port 3005, called by GitHub Actions after job completion.
 * Auth: x-webhook-secret header must match WEBHOOK_SECRET env var.
 */

import { createServer } from 'http';

const PORT = process.env.VAULT_SYNC_PORT || 3005;
const WEBHOOK_SECRET = process.env.WEBHOOK_SECRET;
const GH_TOKEN = process.env.GH_TOKEN;
const GH_OWNER = process.env.GH_OWNER;
const GH_REPO = process.env.GH_REPO;
const OBSIDIAN_HOST = process.env.OBSIDIAN_HOST;
const OBSIDIAN_API_KEY = process.env.OBSIDIAN_API_KEY;

const SKIP_FILES = new Set([
  'claude-session.jsonl', 'claude-stderr.log', 'system-prompt.md', 'job.config.json',
]);

async function ghApi(path) {
  const res = await fetch(`https://api.github.com${path}`, {
    headers: { 'Authorization': `Bearer ${GH_TOKEN}`, 'Accept': 'application/vnd.github+json' },
  });
  if (!res.ok) throw new Error(`GitHub API ${res.status}: ${path}`);
  return res.json();
}

async function syncToVault(jobId, commitSha) {
  const files = await ghApi(`/repos/${GH_OWNER}/${GH_REPO}/contents/logs/${jobId}?ref=${commitSha}`);
  if (!Array.isArray(files)) return { synced: 0, reason: 'no log directory' };

  const outputs = files.filter(f => f.name.endsWith('.md') && !SKIP_FILES.has(f.name));
  if (outputs.length === 0) return { synced: 0, reason: 'no output files' };

  const synced = [];
  for (const file of outputs) {
    const data = await ghApi(`/repos/${GH_OWNER}/${GH_REPO}/contents/logs/${jobId}/${file.name}?ref=${commitSha}`);
    const content = Buffer.from(data.content, 'base64').toString('utf-8');

    // Check frontmatter for explicit vault path
    let vaultPath = `05-Agent-Outputs/${file.name}`;
    const match = content.match(/^---\n[\s\S]*?vault-path:\s*(.+)\n[\s\S]*?---/);
    if (match) vaultPath = match[1].trim();

    const res = await fetch(`${OBSIDIAN_HOST}/vault/${vaultPath}`, {
      method: 'PUT',
      headers: { 'Authorization': `Bearer ${OBSIDIAN_API_KEY}`, 'Content-Type': 'text/markdown' },
      body: content,
    });

    if (res.ok || res.status === 204) {
      synced.push({ file: file.name, vault_path: vaultPath });
      console.log(`[vault-sync] ${file.name} → ${vaultPath}`);
    } else {
      console.error(`[vault-sync] Failed: ${vaultPath} HTTP ${res.status}`);
    }
  }

  return { synced: synced.length, files: synced };
}

const server = createServer(async (req, res) => {
  // Health check
  if (req.method === 'GET' && req.url === '/ping') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ ok: true }));
  }

  // Only accept POST /vault-sync
  if (req.method !== 'POST' || req.url !== '/vault-sync') {
    res.writeHead(404, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ error: 'Not found' }));
  }

  // Auth check
  if (!WEBHOOK_SECRET || req.headers['x-webhook-secret'] !== WEBHOOK_SECRET) {
    res.writeHead(401, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ error: 'Unauthorized' }));
  }

  // Parse body
  let body = '';
  for await (const chunk of req) body += chunk;
  let payload;
  try {
    payload = JSON.parse(body);
  } catch {
    res.writeHead(400, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ error: 'Invalid JSON' }));
  }

  const { job_id, commit_sha } = payload;
  if (!job_id || !commit_sha) {
    res.writeHead(400, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ error: 'Missing job_id or commit_sha' }));
  }

  try {
    const result = await syncToVault(job_id, commit_sha);
    console.log(`[vault-sync] Job ${job_id.slice(0, 8)}: ${result.synced} files synced`);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, ...result }));
  } catch (err) {
    console.error(`[vault-sync] Error:`, err.message);
    res.writeHead(500, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: err.message }));
  }
});

server.listen(PORT, () => {
  console.log(`[vault-sync] Listening on port ${PORT}`);
});
