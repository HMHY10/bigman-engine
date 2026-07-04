CREATE TABLE `order_items` (
	`id` text PRIMARY KEY NOT NULL,
	`order_id` text NOT NULL,
	`sku` text NOT NULL,
	`product_name` text DEFAULT '' NOT NULL,
	`quantity` integer DEFAULT 1 NOT NULL,
	`bin_location` text,
	`created_at` integer NOT NULL
);
--> statement-breakpoint
CREATE TABLE `orders` (
	`id` text PRIMARY KEY NOT NULL,
	`external_id` text NOT NULL,
	`external_ref` text,
	`source` text DEFAULT 'shopify' NOT NULL,
	`customer_name` text DEFAULT '' NOT NULL,
	`customer_email` text,
	`shipping_address` text,
	`status` text DEFAULT 'pending' NOT NULL,
	`notes` text,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL
);
--> statement-breakpoint
CREATE TABLE `picklist_orders` (
	`id` text PRIMARY KEY NOT NULL,
	`picklist_id` text NOT NULL,
	`order_id` text NOT NULL
);
--> statement-breakpoint
CREATE TABLE `picklists` (
	`id` text PRIMARY KEY NOT NULL,
	`type` text DEFAULT 'manual' NOT NULL,
	`status` text DEFAULT 'pending' NOT NULL,
	`order_count` integer DEFAULT 0 NOT NULL,
	`created_at` integer NOT NULL,
	`printed_at` integer,
	`completed_at` integer
);
