import path from 'path';

/**
 * Central path resolver for thepopebot.
 * All paths resolve from process.cwd() (the user's project root).
 */

const PROJECT_ROOT = process.cwd();

export {
  PROJECT_ROOT,
};

// config/ files
export const configDir = path.join(PROJECT_ROOT, 'config');
export const cronsFile = path.join(PROJECT_ROOT, 'config', 'CRONS.json');
export const triggersFile = path.join(PROJECT_ROOT, 'config', 'TRIGGERS.json');
export const jobPlanningMd = path.join(PROJECT_ROOT, 'config', 'JOB_PLANNING.md');
export const codePlanningMd = path.join(PROJECT_ROOT, 'config', 'CODE_PLANNING.md');
export const jobSummaryMd = path.join(PROJECT_ROOT, 'config', 'JOB_SUMMARY.md');
export const soulMd = path.join(PROJECT_ROOT, 'config', 'SOUL.md');
export const claudeMd = path.join(PROJECT_ROOT, 'CLAUDE.md');
export const skillGuidePath = path.join(PROJECT_ROOT, 'config', 'SKILL_BUILDING_GUIDE.md');

// Skills directory
export const skillsDir = path.join(PROJECT_ROOT, 'skills');

// Working directories for command-type actions
export const cronDir = path.join(PROJECT_ROOT, 'cron');
export const triggersDir = path.join(PROJECT_ROOT, 'triggers');

// Logs
export const logsDir = path.join(PROJECT_ROOT, 'logs');

// Data (SQLite memory, etc.)
export const dataDir = path.join(PROJECT_ROOT, 'data');

// Database
export const thepopebotDb = process.env.DATABASE_PATH || path.join(PROJECT_ROOT, 'data', 'thepopebot.sqlite');

// Cluster data (bind-mount root for cluster containers)
export const clusterDataDir = process.env.CLUSTER_DATA_PATH || path.join(PROJECT_ROOT, 'data', 'clusters');

// .env
export const envFile = path.join(PROJECT_ROOT, '.env');
