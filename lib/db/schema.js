import { sqliteTable, text, integer } from 'drizzle-orm/sqlite-core';

export const users = sqliteTable('users', {
  id: text('id').primaryKey(),
  email: text('email').notNull().unique(),
  passwordHash: text('password_hash').notNull(),
  role: text('role').notNull().default('admin'),
  createdAt: integer('created_at').notNull(),
  updatedAt: integer('updated_at').notNull(),
});

export const chats = sqliteTable('chats', {
  id: text('id').primaryKey(),
  userId: text('user_id').notNull(),
  title: text('title').notNull().default('New Chat'),
  starred: integer('starred').notNull().default(0),
  codeWorkspaceId: text('code_workspace_id'),
  createdAt: integer('created_at').notNull(),
  updatedAt: integer('updated_at').notNull(),
});

export const messages = sqliteTable('messages', {
  id: text('id').primaryKey(),
  chatId: text('chat_id').notNull(),
  role: text('role').notNull(),
  content: text('content').notNull(),
  createdAt: integer('created_at').notNull(),
});

export const notifications = sqliteTable('notifications', {
  id: text('id').primaryKey(),
  notification: text('notification').notNull(),
  payload: text('payload').notNull(),
  read: integer('read').notNull().default(0),
  createdAt: integer('created_at').notNull(),
});

export const subscriptions = sqliteTable('subscriptions', {
  id: text('id').primaryKey(),
  platform: text('platform').notNull(),
  channelId: text('channel_id').notNull(),
  createdAt: integer('created_at').notNull(),
});

export const codeWorkspaces = sqliteTable('code_workspaces', {
  id: text('id').primaryKey(),
  userId: text('user_id').notNull(),
  containerName: text('container_name').unique(),
  repo: text('repo'),
  branch: text('branch'),
  featureBranch: text('feature_branch'),
  title: text('title').notNull().default('Code Workspace'),
  codingAgent: text('coding_agent').notNull().default('claude-code'),
  lastInteractiveCommit: text('last_interactive_commit'),
  starred: integer('starred').notNull().default(0),
  createdAt: integer('created_at').notNull(),
  updatedAt: integer('updated_at').notNull(),
});

export const clusters = sqliteTable('clusters', {
  id: text('id').primaryKey(),
  userId: text('user_id').notNull(),
  name: text('name').notNull().default('New Cluster'),
  systemPrompt: text('system_prompt').notNull().default(''),
  folders: text('folders'),
  enabled: integer('enabled').notNull().default(0),
  starred: integer('starred').notNull().default(0),
  createdAt: integer('created_at').notNull(),
  updatedAt: integer('updated_at').notNull(),
});

export const clusterRoles = sqliteTable('cluster_roles', {
  id: text('id').primaryKey(),
  clusterId: text('cluster_id').notNull(),
  roleName: text('role_name').notNull(),
  role: text('role').notNull().default(''),
  prompt: text('prompt').notNull().default('Execute your role.'),
  triggerConfig: text('trigger_config'),
  maxConcurrency: integer('max_concurrency').notNull().default(1),
  cleanupWorkerDir: integer('cleanup_worker_dir').notNull().default(0),
  planMode: integer('plan_mode').notNull().default(0),
  folders: text('folders'),
  sortOrder: integer('sort_order').notNull().default(0),
  createdAt: integer('created_at').notNull(),
  updatedAt: integer('updated_at').notNull(),
});

export const settings = sqliteTable('settings', {
  id: text('id').primaryKey(),
  type: text('type').notNull(),
  key: text('key').notNull(),
  value: text('value').notNull(),
  createdBy: text('created_by'),
  lastUsedAt: integer('last_used_at'),
  createdAt: integer('created_at').notNull(),
  updatedAt: integer('updated_at').notNull(),
});

// ─────────────────────────────────────────────────────────────────────────────
// Picklist / Warehouse
// ─────────────────────────────────────────────────────────────────────────────

export const orders = sqliteTable('orders', {
  id: text('id').primaryKey(),
  externalId: text('external_id'),
  source: text('source').notNull().default('manual'),
  status: text('status').notNull().default('pending'), // pending | batched | picked | shipped | cancelled
  customerName: text('customer_name').notNull().default(''),
  customerAddress: text('customer_address').notNull().default('{}'), // JSON
  lineItems: text('line_items').notNull().default('[]'), // JSON [{sku,name,quantity,binLocation}]
  notes: text('notes').notNull().default(''),
  receivedAt: integer('received_at').notNull(),
  createdAt: integer('created_at').notNull(),
  updatedAt: integer('updated_at').notNull(),
});

export const picklists = sqliteTable('picklists', {
  id: text('id').primaryKey(),
  status: text('status').notNull().default('pending'), // pending | printing | printed | completed
  batchType: text('batch_type').notNull().default('auto'), // overnight | auto | manual
  orderCount: integer('order_count').notNull().default(0),
  printedAt: integer('printed_at'),
  completedAt: integer('completed_at'),
  createdAt: integer('created_at').notNull(),
  updatedAt: integer('updated_at').notNull(),
});

export const picklistOrders = sqliteTable('picklist_orders', {
  id: text('id').primaryKey(),
  picklistId: text('picklist_id').notNull(),
  orderId: text('order_id').notNull(),
  sortOrder: integer('sort_order').notNull().default(0),
  createdAt: integer('created_at').notNull(),
});
