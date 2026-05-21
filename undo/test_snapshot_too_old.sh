#!/bin/bash
#
# test_snapshot_too_old.sh - OpenGauss UStore "snapshot too old" 测试用例
#
# 触发条件：
#   1. 创建 ustore 表（使用 undo 日志的存储引擎）
#   2. Session 1 开启长事务，获取快照后 sleep 等待
#   3. Session 2+ 大量并发更新数据，产生大量 undo 记录
#   4. undo 空间回收后，Session 1 的快照版本无法重构
#   5. 报错: "snapshot too old"
#
# 仅适用于 OpenGauss / GaussDB（PostgreSQL 无 undo 机制不会触发此错误）
#

# Default configuration
DB_HOST="localhost"
DB_PORT="5433"
DB_NAME="postgres"
DB_USER="gaussdb"
DB_PASS=""
TABLE_NAME="snap_too_old_test"
ROW_COUNT=5000
DATA_WIDTH=400
UPDATE_ROUNDS=50
UPDATE_CLIENTS=4
SLEEP_SECONDS=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

OpenGauss UStore "snapshot too old" reproduction test.

Options:
    -h HOST     Database host (default: localhost)
    -p PORT     Database port (default: 5433)
    -d DB       Database name (default: postgres)
    -U USER     Database user (default: gaussdb)
    -W PASS     Database password
    -r ROWS     Number of initial rows (default: 5000, wider rows = more undo)
    -R ROUNDS   Number of update rounds (default: 50)
    -C CLIENTS  Concurrent update clients (default: 4)

Examples:
    $0 -h localhost -p 5433 -U gaussdb -W 'Enmotech@123'
    $0 -h localhost -p 8000 -U root -W 'Pass@123' -r 10000 -R 100
EOF
    exit 1
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# URL encode password
url_encode() {
    local str="$1"
    printf '%s' "$str" | sed 's/@/%40/g; s/:/%3A/g; s/\//%2F/g; s/#/%23/g; s/\?/%3F/g; s/&/%26/g; s/=/%3D/g; s/ /%20/g'
}

# Build connection string
get_conn_str() {
    if [ -n "$DB_PASS" ]; then
        local encoded_pass=$(url_encode "$DB_PASS")
        echo "postgresql://${DB_USER}:${encoded_pass}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
    else
        echo ""
    fi
}

# Get psql connection options (no password)
get_conn_opts() {
    echo "-h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME"
}

# Execute SQL (quiet, suppress output)
db_exec() {
    local sql="$1"
    if [ -n "$DB_PASS" ]; then
        psql "$(get_conn_str)" -q -c "$sql" 2>&1 | grep -v "^ALTER SYSTEM\|^pg_reload_conf\|^SET\|^DROP TABLE\|^CREATE TABLE\|^INSERT 0\|^NOTICE:" || true
    else
        psql $(get_conn_opts) -q -c "$sql" 2>&1 | grep -v "^ALTER SYSTEM\|^pg_reload_conf\|^SET\|^DROP TABLE\|^CREATE TABLE\|^INSERT 0\|^NOTICE:" || true
    fi
}

# Execute SQL and return output (for result checking)
db_query() {
    local sql="$1"
    if [ -n "$DB_PASS" ]; then
        psql "$(get_conn_str)" -t -c "$sql" 2>&1
    else
        psql $(get_conn_opts) -t -c "$sql" 2>&1
    fi

}

# Parse arguments
while getopts "h:p:d:U:W:r:R:C:" opt; do
    case $opt in
        h) DB_HOST="$OPTARG" ;;
        p) DB_PORT="$OPTARG" ;;
        d) DB_NAME="$OPTARG" ;;
        U) DB_USER="$OPTARG" ;;
        W) DB_PASS="$OPTARG" ;;
        r) ROW_COUNT="$OPTARG" ;;
        R) UPDATE_ROUNDS="$OPTARG" ;;
        C) UPDATE_CLIENTS="$OPTARG" ;;
        *) usage ;;
    esac
done

# Calculate sleep time: enough for all update rounds + buffer
# Each round ≈ 1-2 seconds, add 50% buffer and 30s for undo recycling
SLEEP_SECONDS=$(( UPDATE_ROUNDS * 3 + 30 ))
if [ "$SLEEP_SECONDS" -lt 120 ]; then
    SLEEP_SECONDS=120
fi

echo ""
echo "============================================"
echo "  UStore Snapshot Too Old Test"
echo "============================================"
echo "Database:  $DB_HOST:$DB_PORT/$DB_NAME"
echo "User:      $DB_USER"
echo "Table:     $TABLE_NAME (ustore)"
echo "Rows:      $ROW_COUNT"
echo "Data width: ${DATA_WIDTH} bytes per row"
echo "Update rounds: $UPDATE_ROUNDS x $UPDATE_CLIENTS clients"
echo "Long txn sleep: ${SLEEP_SECONDS}s"
echo "============================================"
echo ""

# Check psql
if ! command -v psql &> /dev/null; then
    log_error "psql not found"
    exit 1
fi

CONN_STR="$(get_conn_str)"
CONN_OPTS="$(get_conn_opts)"

# Step 1: Check database type (must be opengauss/gaussdb)
log_step "1/6: Checking database version"
DB_VER=$(db_query "SELECT version();" | head -1)
echo "  $DB_VER"

if ! echo "$DB_VER" | grep -qi "opengauss\|gaussdb"; then
    log_warn "This test is designed for OpenGauss/GaussDB with UStore."
    log_warn "PostgreSQL does not have undo mechanism and will NOT trigger 'snapshot too old'."
    log_warn "Proceeding anyway for reference..."
fi

# Step 2: Check ustore support and undo settings
log_step "2/6: Checking UStore and undo configuration"
ENABLE_USTORE=$(db_query "SHOW enable_ustore;" | tr -d '[:space:]')
UNDO_RETENTION=$(db_query "SHOW undo_retention_time;" | tr -d '[:space:]')
UNDO_SPACE_SETTING=$(db_query "SELECT setting, unit FROM pg_settings WHERE name = 'undo_space_limit_size';")
UNDO_SPACE_NUM=$(db_query "SELECT setting FROM pg_settings WHERE name = 'undo_space_limit_size';" | tr -d '[:space:]')
UNDO_SPACE_MB=$(( UNDO_SPACE_NUM * 8 / 1024 ))

echo "  enable_ustore:       $ENABLE_USTORE"
echo "  undo_retention_time: $UNDO_RETENTION seconds"
echo "  undo_space_limit:    $UNDO_SPACE_SETTING (${UNDO_SPACE_MB}MB)"

if [ "$ENABLE_USTORE" != "on" ]; then
    log_error "UStore is not enabled (enable_ustore=$ENABLE_USTORE). Set enable_ustore=on first."
    exit 1
fi

# Step 2b: Try to reduce undo_space_limit_size for easier triggering
log_step "2b/6: Attempting to reduce undo_space_limit_size to minimum (800MB)"
ALTER_RESULT=$(db_exec "ALTER SYSTEM SET undo_space_limit_size = 102400;" 2>&1)
RELOAD_RESULT=$(db_exec "SELECT pg_reload_conf();" 2>&1)
sleep 1

NEW_UNDO_SPACE=$(db_query "SELECT setting FROM pg_settings WHERE name = 'undo_space_limit_size';" | tr -d '[:space:]')
echo "  New undo_space_limit: $NEW_UNDO_SPACE × 8kB"

if [ "$NEW_UNDO_SPACE" = "102400" ]; then
    log_info "  Successfully reduced undo_space_limit_size to 800MB (102400 × 8kB)"
else
    log_warn "  undo_space_limit_size unchanged (current: $NEW_UNDO_SPACE × 8kB, may need superuser or restart)"
    log_warn "  To trigger 'snapshot too old', consider manually setting undo_space_limit_size in postgresql.conf"
fi

# Step 3: Create ustore table with wide rows
log_step "3/6: Creating UStore table with $ROW_COUNT wide rows"

db_exec "DROP TABLE IF EXISTS $TABLE_NAME CASCADE;" || true
db_exec "CREATE TABLE $TABLE_NAME (id INT PRIMARY KEY, val INT, data VARCHAR(${DATA_WIDTH})) WITH (storage_type = ustore);"

log_info "  Inserting $ROW_COUNT rows with ${DATA_WIDTH}-byte data column..."
db_exec "INSERT INTO $TABLE_NAME SELECT s, 0, repeat('x', ${DATA_WIDTH}) FROM generate_series(1, $ROW_COUNT) AS s;"

ROW_VERIFY=$(db_query "SELECT count(*) FROM $TABLE_NAME;" | tr -d '[:space:]')
echo "  Inserted: $ROW_VERIFY rows"

# Step 4: Start long transaction (Session 1) using pg_sleep
log_step "4/6: Starting long transaction in Session 1 (pg_sleep ${SLEEP_SECONDS}s)"

# Write the long-transaction SQL script to a temp file
LONG_TXN_SQL="/tmp/long_txn_${TABLE_NAME}_$$.sql"
LONG_TXN_OUT="/tmp/long_txn_${TABLE_NAME}_$$.out"

cat > "$LONG_TXN_SQL" << SQL_EOF
BEGIN;
SELECT count(*) FROM $TABLE_NAME;
SELECT pg_sleep(${SLEEP_SECONDS});
SELECT count(*) FROM $TABLE_NAME;
COMMIT;
SQL_EOF

if [ -n "$DB_PASS" ]; then
    psql "$CONN_STR" -f "$LONG_TXN_SQL" > "$LONG_TXN_OUT" 2>&1 &
else
    psql $CONN_OPTS -f "$LONG_TXN_SQL" > "$LONG_TXN_OUT" 2>&1 &
fi
LONG_TXN_PID=$!

log_info "  Long transaction started (PID=$LONG_TXN_PID), sleeping ${SLEEP_SECONDS}s"

# Wait a moment for the transaction to begin and establish snapshot
sleep 2

# Step 5: Heavy concurrent updates (Session 2+) to exhaust undo space
log_step "5/6: Running $UPDATE_ROUNDS rounds x $UPDATE_CLIENTS clients of heavy updates"

for round in $(seq 1 $UPDATE_ROUNDS); do
    for c in $(seq 1 $UPDATE_CLIENTS); do
        start_id=$(( (c-1) * (ROW_COUNT / UPDATE_CLIENTS) + 1 ))
        end_id=$(( c * (ROW_COUNT / UPDATE_CLIENTS) ))
        if [ -n "$DB_PASS" ]; then
            psql "$CONN_STR" -q -c "UPDATE $TABLE_NAME SET val = val + 1, data = repeat('u', ${DATA_WIDTH}) WHERE id BETWEEN $start_id AND $end_id;" 2>/dev/null &
        else
            psql $CONN_OPTS -q -c "UPDATE $TABLE_NAME SET val = val + 1, data = repeat('u', ${DATA_WIDTH}) WHERE id BETWEEN $start_id AND $end_id;" 2>/dev/null &
        fi
    done
    wait
    log_info "  Round $round/$UPDATE_ROUNDS complete ($(date +%H:%M:%S))"
done

log_info "  All update rounds complete. Waiting for long transaction to wake up..."

# Wait for the long transaction to finish (it needs to wake up from pg_sleep)
WAIT_TIMEOUT=$(( SLEEP_SECONDS + 60 ))
elapsed=0
while kill -0 $LONG_TXN_PID 2>/dev/null; do
    if [ "$elapsed" -ge "$WAIT_TIMEOUT" ]; then
        log_warn "  Long transaction did not finish within ${WAIT_TIMEOUT}s, killing it"
        kill $LONG_TXN_PID 2>/dev/null
        wait $LONG_TXN_PID 2>/dev/null
        break
    fi
    sleep 5
    elapsed=$(( elapsed + 5 ))
done

# Step 6: Check results and cleanup
log_step "6/6: Checking results and cleanup"

# Check the long transaction output for "snapshot too old"
SNAPSHOT_TOO_OLD=false

if [ -f "$LONG_TXN_OUT" ]; then
    echo "  Long transaction output:"
    cat "$LONG_TXN_OUT"
    if grep -qi "snapshot too old" "$LONG_TXN_OUT"; then
        SNAPSHOT_TOO_OLD=true
        log_error "  'snapshot too old' was triggered!"
    fi
fi

# Cleanup table
db_exec "DROP TABLE IF EXISTS $TABLE_NAME CASCADE;" || true

# Reset undo_space_limit_size to original value
log_info "  Resetting undo_space_limit_size to original value..."
db_exec "ALTER SYSTEM SET undo_space_limit_size = 33554432;" || true
db_exec "SELECT pg_reload_conf();" || true

# Cleanup temp files
rm -f "$LONG_TXN_SQL" "$LONG_TXN_OUT"

# Summary
echo ""
echo "============================================"
echo "  Test Result"
echo "============================================"
if [ "$SNAPSHOT_TOO_OLD" = true ]; then
    log_error "'snapshot too old' was successfully triggered!"
    log_info "This confirms that UStore undo records can be recycled"
    log_info "before a long-running transaction's snapshot needs them."
    echo "============================================"
    exit 0
else
    log_warn "'snapshot too old' was NOT triggered."
    log_info "Possible reasons:"
    log_info "  1. undo_space_limit_size is too large (minimum is 800MB)"
    log_info "  2. Not enough update rounds to exhaust undo space"
    log_info "  3. undo_retention_time is too high"
    log_info ""
    log_info "Suggestions:"
    log_info "  - Increase ROW_COUNT (-r) or UPDATE_ROUNDS (-R)"
    log_info "  - Manually decrease undo_space_limit_size in postgresql.conf"
    log_info "  - Set undo_retention_time=0"
    echo "============================================"
    exit 2
fi