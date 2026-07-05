CREATE TABLE `orders` (
	`id` text PRIMARY KEY NOT NULL,
	`external_id` text,
	`source` text DEFAULT 'manual' NOT NULL,
	`status` text DEFAULT 'pending' NOT NULL,
	`customer_name` text DEFAULT '' NOT NULL,
	`customer_address` text DEFAULT '{}' NOT NULL,
	`line_items` text DEFAULT '[]' NOT NULL,
	`notes` text DEFAULT '' NOT NULL,
	`received_at` integer NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL
);
--> statement-breakpoint
CREATE TABLE `picklists` (
	`id` text PRIMARY KEY NOT NULL,
	`status` text DEFAULT 'pending' NOT NULL,
	`batch_type` text DEFAULT 'auto' NOT NULL,
	`order_count` integer DEFAULT 0 NOT NULL,
	`printed_at` integer,
	`completed_at` integer,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL
);
--> statement-breakpoint
CREATE TABLE `picklist_orders` (
	`id` text PRIMARY KEY NOT NULL,
	`picklist_id` text NOT NULL,
	`order_id` text NOT NULL,
	`sort_order` integer DEFAULT 0 NOT NULL,
	`created_at` integer NOT NULL
);
