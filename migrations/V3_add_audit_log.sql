-- =============================================================================
-- Migration V3: Add Audit Log and Enhance Schema
-- =============================================================================
-- Description: Adds an audit_log table for tracking data changes,
--              a payment_method column on orders, and a product tags array.
-- Author:      DBA Team
-- Date:        2025-02-05
-- Rollback:    DROP TABLE IF EXISTS audit_log;
--              ALTER TABLE orders DROP COLUMN IF EXISTS payment_method;
--              ALTER TABLE products DROP COLUMN IF EXISTS tags;
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Audit log table — captures INSERT, UPDATE, DELETE on tracked tables
-- ---------------------------------------------------------------------------
CREATE TABLE audit_log (
    id              BIGSERIAL       PRIMARY KEY,
    table_name      VARCHAR(100)    NOT NULL,
    record_id       UUID            NOT NULL,
    action          VARCHAR(10)     NOT NULL CHECK (action IN ('INSERT', 'UPDATE', 'DELETE')),
    old_data        JSONB,
    new_data        JSONB,
    changed_by      VARCHAR(100)    NOT NULL DEFAULT current_user,
    changed_at      TIMESTAMPTZ     NOT NULL DEFAULT now()
);

COMMENT ON TABLE audit_log IS 'Immutable audit trail for data changes on tracked tables';

-- Partition-friendly index on timestamp (for archival queries)
CREATE INDEX idx_audit_log_changed_at ON audit_log (changed_at DESC);

-- Lookup by table + record (for viewing history of a specific row)
CREATE INDEX idx_audit_log_record ON audit_log (table_name, record_id, changed_at DESC);

-- ---------------------------------------------------------------------------
-- Generic audit trigger function
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit_trigger_func()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO audit_log (table_name, record_id, action, new_data)
        VALUES (TG_TABLE_NAME, NEW.id, 'INSERT', to_jsonb(NEW));
        RETURN NEW;

    ELSIF TG_OP = 'UPDATE' THEN
        INSERT INTO audit_log (table_name, record_id, action, old_data, new_data)
        VALUES (TG_TABLE_NAME, NEW.id, 'UPDATE', to_jsonb(OLD), to_jsonb(NEW));
        RETURN NEW;

    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO audit_log (table_name, record_id, action, old_data)
        VALUES (TG_TABLE_NAME, OLD.id, 'DELETE', to_jsonb(OLD));
        RETURN OLD;
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Attach audit triggers to core tables
CREATE TRIGGER trg_audit_users
    AFTER INSERT OR UPDATE OR DELETE ON users
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func();

CREATE TRIGGER trg_audit_orders
    AFTER INSERT OR UPDATE OR DELETE ON orders
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func();

CREATE TRIGGER trg_audit_products
    AFTER INSERT OR UPDATE OR DELETE ON products
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func();

-- ---------------------------------------------------------------------------
-- Schema enhancements
-- ---------------------------------------------------------------------------

-- Payment method on orders
ALTER TABLE orders
    ADD COLUMN payment_method VARCHAR(30) DEFAULT 'credit_card'
    CHECK (payment_method IN ('credit_card', 'debit_card', 'paypal', 'bank_transfer', 'crypto'));

COMMENT ON COLUMN orders.payment_method IS 'Payment method used for this order';

-- Tags array on products (for flexible categorization)
ALTER TABLE products
    ADD COLUMN tags TEXT[] DEFAULT '{}';

CREATE INDEX idx_products_tags ON products USING GIN (tags);

COMMENT ON COLUMN products.tags IS 'Flexible tag array for filtering and search (e.g., {sale, featured, new})';

-- ---------------------------------------------------------------------------
-- Record this migration
-- ---------------------------------------------------------------------------
INSERT INTO schema_migrations (version, description)
VALUES ('V3', 'Add audit_log table, payment_method on orders, tags on products');

COMMIT;
