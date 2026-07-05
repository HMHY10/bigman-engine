import cron from 'node-cron';
import fs from 'fs';
import path from 'path';
import { cronsFile, cronDir } from './paths.js';
import { executeAction } from './actions.js';

function getInstalledVersion() {
  const pkgPath = path.join(process.cwd(), 'node_modules', 'thepopebot', 'package.json');
  return JSON.parse(fs.readFileSync(pkgPath, 'utf8')).version;
}

// In-memory flag for available update (read by sidebar, written by cron)
let _updateAvailable = null;

/**
 * Get the in-memory update-available version (or null).
 * @returns {string|null}
 */
function getUpdateAvailable() {
  return _updateAvailable;
}

/**
 * Set the in-memory update-available version.
 * @param {string|null} v
 */
function setUpdateAvailable(v) {
  _updateAvailable = v;
}

/**
 * Compare two semver strings numerically.
 * @param {string} candidate - e.g. "1.2.40"
 * @param {string} baseline  - e.g. "1.2.39"
 * @returns {boolean} true if candidate > baseline
 */
function isVersionNewer(candidate, baseline) {
  // Pre-release candidate is never "newer" for upgrade purposes
  if (candidate.includes('-')) return false;

  const a = candidate.split('.').map(Number);
  const b = baseline.replace(/-.*$/, '').split('.').map(Number);
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const av = a[i] || 0;
    const bv = b[i] || 0;
    if (av > bv) return true;
    if (av < bv) return false;
  }
  return false;
}

/**
 * Check if a version string is a pre-release (contains '-').
 * @param {string} v
 * @returns {boolean}
 */
function isPrerelease(v) {
  return v.includes('-');
}

/**
 * Compare two semver strings (including pre-release).
 * Returns positive if a > b, negative if a < b, 0 if equal.
 * Ordering: 1.2.71-beta.0 < 1.2.71-beta.1 < 1.2.71 (stable) < 1.2.72-beta.0
 * @param {string} a
 * @param {string} b
 * @returns {number}
 */
function compareVersions(a, b) {
  const [aCore, aPre] = a.split('-');
  const [bCore, bPre] = b.split('-');

  const aParts = aCore.split('.').map(Number);
  const bParts = bCore.split('.').map(Number);

  // Compare major.minor.patch
  for (let i = 0; i < Math.max(aParts.length, bParts.length); i++) {
    const av = aParts[i] || 0;
    const bv = bParts[i] || 0;
    if (av !== bv) return av - bv;
  }

  // Same core version: stable beats pre-release
  if (!aPre && bPre) return 1;   // a is stable, b is pre-release
  if (aPre && !bPre) return -1;  // a is pre-release, b is stable
  if (!aPre && !bPre) return 0;  // both stable, same core

  // Both pre-release with same core: compare pre-release number
  const aNum = parseInt(aPre.split('.').pop(), 10) || 0;
  const bNum = parseInt(bPre.split('.').pop(), 10) || 0;
  return aNum - bNum;
}

/**
 * Fetch release notes from GitHub for the target version.
 * @param {string} target - Target upgrade version
 */
async function fetchAndStoreReleaseNotes(target) {
  try {
    const ghRes = await fetch(
      `https://api.github.com/repos/stephengpope/thepopebot/releases/tags/v${target}`
    );
    if (!ghRes.ok) return;
    const release = await ghRes.json();
    if (release.body) {
      const { setReleaseNotes } = await import('./db/update-check.js');
      setReleaseNotes(release.body);
    }
  } catch {}
}

/**
 * Check npm registry for a newer version of thepopebot.
 */
async function runVersionCheck() {
  try {
    const installed = getInstalledVersion();

    if (isPrerelease(installed)) {
      // Beta path: check both stable and beta dist-tags
      const results = await Promise.allSettled([
        fetch('https://registry.npmjs.org/thepopebot/latest'),
        fetch('https://registry.npmjs.org/thepopebot/beta'),
      ]);

      const candidates = [];
      for (const result of results) {
        if (result.status !== 'fulfilled') continue;
        const res = result.value;
        if (!res.ok) continue;
        const data = await res.json();
        if (data.version && compareVersions(data.version, installed) > 0) {
          candidates.push(data.version);
        }
      }

      if (candidates.length > 0) {
        // Pick the best candidate (highest version)
        candidates.sort(compareVersions);
        const best = candidates[candidates.length - 1];
        console.log(`[version check] update available: ${installed} → ${best}`);
        setUpdateAvailable(best);
        const { setAvailableVersion } = await import('./db/update-check.js');
        setAvailableVersion(best);
        await fetchAndStoreReleaseNotes(best);
      } else {
        setUpdateAvailable(null);
        const { clearAvailableVersion, clearReleaseNotes } = await import('./db/update-check.js');
        clearAvailableVersion();
        clearReleaseNotes();
      }
    } else {
      // Stable path: check latest, and optionally beta if opted in
      const { getConfig } = await import('./config.js');
      const checkBeta = getConfig('UPGRADE_INCLUDE_BETA') === 'true';

      if (checkBeta) {
        // Fetch both latest and beta, pick the best candidate
        const results = await Promise.allSettled([
          fetch('https://registry.npmjs.org/thepopebot/latest'),
          fetch('https://registry.npmjs.org/thepopebot/beta'),
        ]);

        const candidates = [];
        for (const result of results) {
          if (result.status !== 'fulfilled') continue;
          const res = result.value;
          if (!res.ok) continue;
          const data = await res.json();
          if (data.version && compareVersions(data.version, installed) > 0) {
            candidates.push(data.version);
          }
        }

        if (candidates.length > 0) {
          candidates.sort(compareVersions);
          const best = candidates[candidates.length - 1];
          console.log(`[version check] update available: ${installed} → ${best}`);
          setUpdateAvailable(best);
          const { setAvailableVersion } = await import('./db/update-check.js');
          setAvailableVersion(best);
          await fetchAndStoreReleaseNotes(best);
        } else {
          setUpdateAvailable(null);
          const { clearAvailableVersion, clearReleaseNotes } = await import('./db/update-check.js');
          clearAvailableVersion();
          clearReleaseNotes();
        }
      } else {
        // Default: only check stable releases
        const res = await fetch('https://registry.npmjs.org/thepopebot/latest');
        if (!res.ok) {
          console.warn(`[version check] npm registry returned ${res.status}`);
          return;
        }
        const data = await res.json();
        const latest = data.version;

        if (isVersionNewer(latest, installed)) {
          console.log(`[version check] update available: ${installed} → ${latest}`);
          setUpdateAvailable(latest);
          const { setAvailableVersion } = await import('./db/update-check.js');
          setAvailableVersion(latest);
          await fetchAndStoreReleaseNotes(latest);
        } else {
          setUpdateAvailable(null);
          const { clearAvailableVersion, clearReleaseNotes } = await import('./db/update-check.js');
          clearAvailableVersion();
          clearReleaseNotes();
        }
      }
    }
  } catch (err) {
    console.warn(`[version check] failed: ${err.message}`);
    // Leave existing flag untouched on error
  }
}

/**
 * Start picklist auto-batch built-in cron.
 * - Every 30 seconds during the day: run the daytime auto-batch check.
 * - Every day at 07:00 (UK warehouse open): run the overnight batch (all pending orders).
 */
async function startPicklistCrons() {
  try {
    const { runAutoBatch, runOvernightBatch } = await import('./picklist/batcher.js');

    // Daytime auto-batch: every 30 seconds
    cron.schedule('*/30 * * * * *', async () => {
      try {
        const pl = await runAutoBatch();
        if (pl) console.log(`[picklist] Auto-batch created: ${pl.id.slice(0, 8)} (${pl.orderCount} orders)`);
      } catch (err) {
        console.error('[picklist] Auto-batch error:', err.message);
      }
    }, { scheduled: true });

    // Overnight batch: every day at 07:00
    cron.schedule('0 7 * * *', async () => {
      try {
        const pl = await runOvernightBatch();
        if (pl) console.log(`[picklist] Overnight batch created: ${pl.id.slice(0, 8)} (${pl.orderCount} orders)`);
        else console.log('[picklist] Overnight batch: no pending orders');
      } catch (err) {
        console.error('[picklist] Overnight batch error:', err.message);
      }
    });

    console.log('[picklist] Batch crons started (auto: */30s, overnight: 07:00)');
  } catch (err) {
    // Picklist module not available — skip silently
  }
}

/**
 * Start built-in crons (version check). Called from instrumentation.
 */
function startBuiltinCrons() {
  // Schedule hourly
  cron.schedule('0 * * * *', runVersionCheck);
  // Run once immediately
  runVersionCheck();
  // Picklist automation
  startPicklistCrons();
}

/**
 * Load and schedule crons from CRONS.json
 * @returns {Array} - Array of scheduled cron tasks
 */
function loadCrons() {
  const cronFile = cronsFile;

  console.log('\n--- Cron Jobs ---');

  if (!fs.existsSync(cronFile)) {
    console.log('No CRONS.json found');
    console.log('-----------------\n');
    return [];
  }

  const crons = JSON.parse(fs.readFileSync(cronFile, 'utf8'));
  const tasks = [];

  for (const cronEntry of crons) {
    const { name, schedule, type = 'agent', enabled } = cronEntry;
    if (enabled === false) continue;

    if (!cron.validate(schedule)) {
      console.error(`Invalid schedule for "${name}": ${schedule}`);
      continue;
    }

    const task = cron.schedule(schedule, async () => {
      try {
        const result = await executeAction(cronEntry, { cwd: cronDir });
        console.log(`[CRON] ${name}: ${result || 'ran'}`);
        console.log(`[CRON] ${name}: completed!`);
      } catch (err) {
        console.error(`[CRON] ${name}: error - ${err.message}`);
      }
    });

    tasks.push({ name, schedule, type, task });
  }

  if (tasks.length === 0) {
    console.log('No active cron jobs');
  } else {
    for (const { name, schedule, type } of tasks) {
      console.log(`  ${name}: ${schedule} (${type})`);
    }
  }

  console.log('-----------------\n');

  return tasks;
}

export { loadCrons, startBuiltinCrons, getUpdateAvailable, setUpdateAvailable, getInstalledVersion, isPrerelease };
