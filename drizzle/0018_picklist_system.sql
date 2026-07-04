CREATE TABLE `orders` (
	`id` text PRIMARY KEY NOT NULL,
	`order_number` text NOT NULL,
	`customer_name` text,
	`sku` text NOT NULL,
	`product_name` text NOT NULL,
	`quantity` integer DEFAULT 1 NOT NULL,
	`bin_location` text,
	`status` text DEFAULT 'pending' NOT NULL,
	`picklist_id` text,
	`source` text DEFAULT 'manual' NOT NULL,
	`notes` text,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL
);
--> statement-breakpoint
CREATE TABLE `picklists` (
	`id` text PRIMARY KEY NOT NULL,
	`status` text DEFAULT 'pending' NOT NULL,
	`batch_type` text DEFAULT 'manual' NOT NULL,
	`order_count` integer DEFAULT 0 NOT NULL,
	`notes` text,
	`printed_at` integer,
	`completed_at` integer,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL
);
--> statement-breakpoint
CREATE TABLE `picklist_items` (
	`id` text PRIMARY KEY NOT NULL,
	`picklist_id` text NOT NULL,
	`order_id` text NOT NULL,
	`sku` text NOT NULL,
	`product_name` text NOT NULL,
	`quantity` integer DEFAULT 1 NOT NULL,
	`bin_location` text,
	`created_at` integer NOT NULL
);
