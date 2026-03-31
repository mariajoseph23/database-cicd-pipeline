-- =============================================================================
-- Migration V2: Add Performance Indexes
-- =============================================================================
-- Description: Adds indexes for common query patterns — lookups, filtering,
--              sorting, and foreign key joins.
-- Author:      DBA Team
-- Date:        2025-01-22
-- Rollback:    DROP INDEX IF EXISTS idx_*;
--
-- Impact:      CREATE INDEX CONCURRENTLY does NOT lock the table for writes.
--              Safe to run during normal traffic. Each index build may take
--              a few minutes on large tables.
-- =============================================================================

-- NOTE: CONCURRENTLY cannot run inside a transaction block.
-- Each statement is executed individually by the deploy script.

-- ---------------------------------------------------------------------------
-- Users indexes
-- ---------------------------------------------------------------------------

-- Email lookup (login, password reset, duplicate check)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_users_email
    ON users (email);

-- Status filtering (admin dashboards, batch jobs)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_users_status
    ON users (status)
    WHERE status != 'deleted';

-- Full name search (customer support lookups)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_users_name
    ON users (last_name, first_name);

-- Recently created users (onboarding funnels, analytics)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_users_created_at
    ON users (created_at DESC);

-- ---------------------------------------------------------------------------
-- Products indexes
-- ---------------------------------------------------------------------------

-- SKU lookup (inventory systems, barcode scanners)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_products_sku
    ON products (sku);

-- Category browsing (storefront, filtering)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_products_category
    ON products (category)
    WHERE is_active = TRUE;

-- Price range queries (storefront filters)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_products_price
    ON products (price_cents)
    WHERE is_active = TRUE;

-- Stock monitoring (low-stock alerts, reorder triggers)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_products_stock
    ON products (stock_quantity)
    WHERE is_active = TRUE AND stock_quantity < 50;

-- ---------------------------------------------------------------------------
-- Orders indexes
-- ---------------------------------------------------------------------------

-- User's order history (account page, support lookups)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_orders_user_id
    ON orders (user_id, created_at DESC);

-- Status filtering (fulfillment dashboard, batch processing)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_orders_status
    ON orders (status)
    WHERE status NOT IN ('delivered', 'cancelled', 'refunded');

-- Date range queries (reporting, analytics)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_orders_created_at
    ON orders (created_at DESC);

-- Shipping address search (GIN index on JSONB)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_orders_shipping_address
    ON orders USING GIN (shipping_address);

-- ---------------------------------------------------------------------------
-- Order items indexes
-- ---------------------------------------------------------------------------

-- Order lookup (order detail page)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_order_items_order_id
    ON order_items (order_id);

-- Product sales analytics (which products sell most)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_order_items_product_id
    ON order_items (product_id);

-- ---------------------------------------------------------------------------
-- Record this migration
-- ---------------------------------------------------------------------------

-- This runs in its own implicit transaction since we can't use BEGIN/COMMIT
-- with CONCURRENTLY. The deploy script handles this.
INSERT INTO schema_migrations (version, description)
VALUES ('V2', 'Add performance indexes for users, products, orders, order_items');
