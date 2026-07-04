/**
 * lib/picklist/state.js
 * Read/write picklist state files from the shared data directory.
 * State lives in data/picklist/ (volume-mounted, accessible to shell scripts at /app/data/picklist/).
 */

import fs from 'node:fs';
import path from 'node:path';
import { dataDir } from '../paths.js';

export const picklistStateDir = path.join(dataDir, 'picklist');

function ensureDir() {
  fs.mkdirSync(picklistStateDir, { recursive: true });
}

function readJson(filePath, fallback) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch {
    return fallback;
  }
}

/** Get list of printed order IDs */
export function getPrintedOrders() {
  ensureDir();
  return readJson(path.join(picklistStateDir, 'printed-orders.json'), []);
}

/** Add order IDs to the printed list */
export function markOrdersPrinted(orderIds) {
  ensureDir();
  const file = path.join(picklistStateDir, 'printed-orders.json');
  const existing = readJson(file, []);
  const merged = [...new Set([...existing, ...orderIds])].sort((a, b) => a - b);
  fs.writeFileSync(file, JSON.stringify(merged));
}

/** Get the auto-batch timer state */
export function getBatchTimer() {
  ensureDir();
  return readJson(path.join(picklistStateDir, 'timer.json'), null);
}

/** Save a picklist batch to state */
export function saveBatch(batchData) {
  ensureDir();
  const file = path.join(picklistStateDir, `${batchData.batch_id}.json`);
  fs.writeFileSync(file, JSON.stringify(batchData, null, 2));
}

/** Load a picklist batch from state */
export function loadBatch(batchId) {
  ensureDir();
  const file = path.join(picklistStateDir, `${batchId}.json`);
  return readJson(file, null);
}

/** List recent batch IDs, newest first */
export function listBatches(limit = 20) {
  ensureDir();
  const files = fs.readdirSync(picklistStateDir)
    .filter((f) => f.startsWith('PICKLIST-') && f.endsWith('.json'))
    .sort()
    .reverse()
    .slice(0, limit);
  return files.map((f) => f.replace('.json', ''));
}
