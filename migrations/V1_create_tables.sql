-- =============================================================================
-- Migration V1: Create Core Tables
-- =============================================================================
-- Description: Initial schema — users, products, and orders tables
-- Author:      DBA Team
-- Date:        2025-01-15
-- Rollback:    V1_rollback_drop_tables.sql
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Migration tracking table (created once, used by deploy_database.sh)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS schema_migrations (
    version         VARCHAR(50)  PRIMARY KEY,
    description     TEXT         NOT NULL,
    applied_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    applied_by      VARCHAR(100) NOT NULL DEFAULT current_user,
    execution_time  INTERVAL
);

-- ---------------------------------------------------------------------------
-- Users table
-- ---------------------------------------------------------------------------
CREATE TABLE users (
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    email           VARCHAR(255)    NOT NULL UNIQUE,
    username        VARCHAR(100)    NOT NULL UNIQUE,
    password_hash   VARCHAR(255)    NOT NULL,
    first_name      VARCHAR(100),
    last_name       VARCHAR(100),
    status          VARCHAR(20)     NOT NULL DEFAULT 'active'
                                    CHECK (status IN ('active', 'inactive', 'suspended', 'deleted')),
    email_verified  BOOLEAN         NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT now()
);

COMMENT ON TABLE users IS 'Core user accounts table';
COMMENT ON COLUMN users.status IS 'Account status: active, inactive, suspended, or deleted';

-- ---------------------------------------------------------------------------
-- Products table
-- ---------------------------------------------------------------------------
CREATE TABLE products (
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    sku             VARCHAR(50)     NOT NULL UNIQUE,
    name            VARCHAR(255)    NOT NULL,
    description     TEXT,
    price_cents     INTEGER         NOT NULL CHECK (price_cents >= 0),
    currency        VARCHAR(3)      NOT NULL DEFAULT 'USD',
    stock_quantity  INTEGER         NOT NULL DEFAULT 0 CHECK (stock_quantity >= 0),
    category        VARCHAR(100),
    is_active       BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT now()
);

COMMENT ON TABLE products IS 'Product catalog with inventory tracking';
COMMENT ON COLUMN products.price_cents IS 'Price stored in cents to avoid floating-point issues';

-- ---------------------------------------------------------------------------
-- Orders table
-- ---------------------------------------------------------------------------
CREATE TABLE orders (
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID            NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    status          VARCHAR(30)     NOT NULL DEFAULT 'pending'
                                    CHECK (status IN ('pending', 'confirmed', 'processing',
                                                      'shipped', 'delivered', 'cancelled', 'refunded')),
    total_cents     INTEGER         NOT NULL CHECK (total_cents >= 0),
    currency        VARCHAR(3)      NOT NULL DEFAULT 'USD',
    shipping_address JSONB,
    notes           TEXT,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT now()
);

COMMENT ON TABLE orders IS 'Customer orders with status lifecycle tracking';

-- ---------------------------------------------------------------------------
-- Order items (line items within an order)
-- ---------------------------------------------------------------------------
CREATE TABLE order_items (
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id        UUID            NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    product_id      UUID            NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
    quantity        INTEGER         NOT NULL CHECK (quantity > 0),
    unit_price_cents INTEGER        NOT NULL CHECK (unit_price_cents >= 0),
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT now()
);

COMMENT ON TABLE order_items IS 'Individual line items within an order';

-- ---------------------------------------------------------------------------
-- Updated_at trigger function (reusable across tables)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply trigger to tables with updated_at
CREATE TRIGGER trg_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER trg_products_updated_at
    BEFORE UPDATE ON products
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER trg_orders_updated_at
    BEFORE UPDATE ON orders
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ---------------------------------------------------------------------------
-- Record this migration
-- ---------------------------------------------------------------------------
INSERT INTO schema_migrations (version, description)
VALUES ('V1', 'Create core tables: users, products, orders, order_items');

COMMIT;
