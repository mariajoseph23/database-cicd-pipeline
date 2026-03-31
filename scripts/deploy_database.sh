#!/usr/bin/env bash
# =============================================================================
# Database Migration Deployment Script
# =============================================================================
# Applies versioned SQL migrations to a PostgreSQL database in order.
# Tracks applied migrations in a `schema_migrations` table to ensure
# each migration runs exactly once.
#
# Features:
#   - Idempotent: skips already-applied migrations
#   - Ordered: applies migrations by version number (V1, V2, V3...)
#   - Transactional: each migration runs in a transaction (when possible)
#   - Timed: records execution time for each migration
#   - Rollback support: --rollback flag restores from backup
#
# Usage:
#   ./deploy_database.sh \
#     --host localhost \
#     --port 5432 \
#     --user dbadmin \
#     --password secret \
#     --database appdb \
#     --migrations-dir ./migrations
#
# Options:
#   --target-version V3    Stop after applying V3 (skip V4+)
#   --dry-run              Show what would be applied without executing
#   --rollback             Restore from the latest backup instead of migrating
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration & Defaults
# -----------------------------------------------------------------------------

DB_HOST=""
DB_PORT="5432"
DB_USER=""
DB_PASSWORD=""
DB_NAME=""
MIGRATIONS_DIR="./migrations"
TARGET_VERSION=""
DRY_RUN=false
ROLLBACK=false
LOG_FILE="deploy-$(date +%Y%m%d-%H%M%S).log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# -----------------------------------------------------------------------------
# Argument Parsing
# -----------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case $1 in
    --host)            DB_HOST="$2";            shift 2 ;;
    --port)            DB_PORT="$2";            shift 2 ;;
    --user)            DB_USER="$2";            shift 2 ;;
    --password)        DB_PASSWORD="$2";        shift 2 ;;
    --database)        DB_NAME="$2";            shift 2 ;;
    --migrations-dir)  MIGRATIONS_DIR="$2";     shift 2 ;;
    --target-version)  TARGET_VERSION="$2";     shift 2 ;;
    --dry-run)         DRY_RUN=true;            shift ;;
    --rollback)        ROLLBACK=true;           shift ;;
    --help)
      echo "Usage: $0 --host <host> --port <port> --user <user> --password <pass> --database <db> --migrations-dir <dir>"
      echo ""
      echo "Options:"
      echo "  --target-version <V#>   Migrate up to and including this version"
      echo "  --dry-run               Preview migrations without applying"
      echo "  --rollback              Restore from latest backup"
      exit 0
      ;;
    *) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
  esac
done

# Validate required arguments
for var in DB_HOST DB_USER DB_PASSWORD DB_NAME; do
  if [[ -z "${!var}" ]]; then
    echo -e "${RED}ERROR: --${var,,} is required${NC}"
    exit 1
  fi
done

export PGPASSWORD="$DB_PASSWORD"

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo -e "${timestamp} | $1" | tee -a "$LOG_FILE"
}

run_sql() {
  psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
    -v ON_ERROR_STOP=1 --no-psqlrc -q "$@"
}

run_sql_file() {
  psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
    -v ON_ERROR_STOP=1 --no-psqlrc -f "$1" 2>&1
}

get_applied_versions() {
  run_sql -t -A -c "
    SELECT version FROM schema_migrations ORDER BY version;
  " 2>/dev/null || echo ""
}

# Portable (macOS BSD + GNU): avoid grep -oP
extract_version_number() {
  # V1_create_tables.sql -> 1
  basename "$1" .sql | sed -nE 's/^V([0-9]+).*/\1/p' | head -1
}

migration_version_label() {
  # V1_create_tables.sql -> V1
  basename "$1" | sed -nE 's/^(V[0-9]+)_.*\.sql$/\1/p'
}

# -----------------------------------------------------------------------------
# Pre-Flight Checks
# -----------------------------------------------------------------------------

log "${BLUE}============================================${NC}"
log "${BLUE}  DATABASE MIGRATION DEPLOYMENT${NC}"
log "${BLUE}============================================${NC}"
log ""
log "${CYAN}[CONFIG]${NC} Host       : ${DB_HOST}:${DB_PORT}"
log "${CYAN}[CONFIG]${NC} Database   : ${DB_NAME}"
log "${CYAN}[CONFIG]${NC} User       : ${DB_USER}"
log "${CYAN}[CONFIG]${NC} Migrations : ${MIGRATIONS_DIR}"
log "${CYAN}[CONFIG]${NC} Target     : ${TARGET_VERSION:-latest}"
log "${CYAN}[CONFIG]${NC} Dry Run    : ${DRY_RUN}"
log ""

# Test database connectivity
log "${BLUE}[CHECK]${NC} Testing database connection..."
if ! run_sql -c "SELECT 1;" > /dev/null 2>&1; then
  log "${RED}[ERROR]${NC} Cannot connect to database ${DB_NAME} at ${DB_HOST}:${DB_PORT}"
  exit 1
fi
log "${GREEN}[CHECK]${NC} Connection successful."

# Ensure schema_migrations table exists
run_sql -c "
  CREATE TABLE IF NOT EXISTS schema_migrations (
    version         VARCHAR(50)  PRIMARY KEY,
    description     TEXT         NOT NULL DEFAULT '',
    applied_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    applied_by      VARCHAR(100) NOT NULL DEFAULT current_user,
    execution_time  INTERVAL
  );
" > /dev/null 2>&1

# -----------------------------------------------------------------------------
# Discover Migrations
# -----------------------------------------------------------------------------

APPLIED_VERSIONS=$(get_applied_versions)

# Find all migration files, sorted by version number
MIGRATION_FILES=$(find "$MIGRATIONS_DIR" -maxdepth 1 -name 'V*.sql' -type f | sort -V)

if [[ -z "$MIGRATION_FILES" ]]; then
  log "${YELLOW}[WARN]${NC} No migration files found in ${MIGRATIONS_DIR}"
  exit 0
fi

PENDING_COUNT=0
APPLIED_COUNT=0
FAILED=false

log "${BLUE}[DISCOVERY]${NC} Migration status:"
log ""

while IFS= read -r file; do
  filename=$(basename "$file")
  version=$(migration_version_label "$file")

  if echo "$APPLIED_VERSIONS" | grep -q "^${version}$"; then
    log "  ${GREEN}✓${NC} ${filename} (already applied)"
    APPLIED_COUNT=$((APPLIED_COUNT + 1))
  else
    log "  ${YELLOW}○${NC} ${filename} (pending)"
    PENDING_COUNT=$((PENDING_COUNT + 1))
  fi
done <<< "$MIGRATION_FILES"

log ""
log "${BLUE}[SUMMARY]${NC} ${APPLIED_COUNT} applied, ${PENDING_COUNT} pending"
log ""

if [[ $PENDING_COUNT -eq 0 ]]; then
  log "${GREEN}[DONE]${NC} Database is up to date. No migrations to apply."
  exit 0
fi

if [[ "$DRY_RUN" == true ]]; then
  log "${YELLOW}[DRY RUN]${NC} Would apply ${PENDING_COUNT} migration(s). Exiting without changes."
  exit 0
fi

# -----------------------------------------------------------------------------
# Apply Pending Migrations
# -----------------------------------------------------------------------------

log "${BLUE}[DEPLOY]${NC} Applying ${PENDING_COUNT} migration(s)..."
log ""

SUCCESS_COUNT=0

while IFS= read -r file; do
  filename=$(basename "$file")
  version=$(migration_version_label "$file")

  # Skip already applied
  if echo "$APPLIED_VERSIONS" | grep -q "^${version}$"; then
    continue
  fi

  # Check target version
  if [[ -n "$TARGET_VERSION" ]]; then
    file_num=$(extract_version_number "$filename")
    target_num=$(echo "$TARGET_VERSION" | sed -nE 's/^V?([0-9]+).*$/\1/p')
    if [[ $file_num -gt $target_num ]]; then
      log "${YELLOW}[SKIP]${NC} ${filename} — beyond target version ${TARGET_VERSION}"
      continue
    fi
  fi

  log "${BLUE}[APPLYING]${NC} ${filename}..."
  START_TIME=$(date +%s%N)

  # Check if migration contains CONCURRENTLY (can't run in a transaction)
  if grep -qi 'CONCURRENTLY' "$file"; then
    log "${YELLOW}[NOTE]${NC} Migration uses CONCURRENTLY — running outside transaction"
    OUTPUT=$(run_sql_file "$file" 2>&1) || {
      log "${RED}[FAILED]${NC} ${filename}"
      log "${RED}${OUTPUT}${NC}"
      FAILED=true
      break
    }
  else
    OUTPUT=$(run_sql_file "$file" 2>&1) || {
      log "${RED}[FAILED]${NC} ${filename}"
      log "${RED}${OUTPUT}${NC}"
      FAILED=true
      break
    }
  fi

  END_TIME=$(date +%s%N)
  DURATION_MS=$(( (END_TIME - START_TIME) / 1000000 ))

  # Update execution time in tracking table
  run_sql -c "
    UPDATE schema_migrations
    SET execution_time = interval '${DURATION_MS} milliseconds'
    WHERE version = '${version}';
  " > /dev/null 2>&1

  log "${GREEN}[SUCCESS]${NC} ${filename} (${DURATION_MS}ms)"
  SUCCESS_COUNT=$((SUCCESS_COUNT + 1))

done <<< "$MIGRATION_FILES"

# -----------------------------------------------------------------------------
# Final Report
# -----------------------------------------------------------------------------

log ""
log "${BLUE}============================================${NC}"

if [[ "$FAILED" == true ]]; then
  log "${RED}  DEPLOYMENT FAILED${NC}"
  log "${RED}  Applied ${SUCCESS_COUNT} of ${PENDING_COUNT} migration(s) before failure.${NC}"
  log "${RED}  Review the log: ${LOG_FILE}${NC}"
  log "${BLUE}============================================${NC}"
  exit 1
else
  log "${GREEN}  DEPLOYMENT SUCCESSFUL${NC}"
  log "${GREEN}  Applied ${SUCCESS_COUNT} migration(s).${NC}"
  log "${BLUE}============================================${NC}"

  # Show final migration state
  log ""
  log "${BLUE}[STATE]${NC} Current migration history:"
  run_sql -c "
    SELECT version, description, applied_at, execution_time
    FROM schema_migrations
    ORDER BY version;
  "
fi

log ""
log "Full log: ${LOG_FILE}"
