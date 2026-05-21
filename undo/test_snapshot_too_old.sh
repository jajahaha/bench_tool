#!/bin/bash
#
# test_snapshot_too_old.sh - OpenGauss/GaussDB UStore undo 回收测试
#
# 触发原理：
#   1. 创建 ustore 表（使用 undo 日志的存储引擎）
#   2. Session 1 开启长事务，查询 val=0 建立快照
#   3. Session 2+ 大量并发更新数据（val = val + 1），产生大量 undo 记录
#   4. undo 空间回收后，Session 1 再次查询 val
#   5. 如果 val ≠ 0，说明 undo 被回收，快照语义被破坏：
#      - 报 "snapshot too old" 错误 → 快照版本无法重构（正确行为）
#      - 静默返回当前值 → MVCC 数据损坏（更严重问题）
#
# 适用于 OpenGauss / GaussDB（PostgreSQL 无 undo 机制不会触发此问题）
# 自动选择客户端：gaussdb/opengauss 优先 gsql，回退 psql
#

# Default configuration
DB_TYPE="gaussdb"
DB_HOST="localhost"
DB_PORT="8000"
DB_NAME="postgres"
DB_USER="root"
DB_PASS=""
DB_CLIENT=""
TABLE_NAME="snap_too_old_test"
ROW_COUNT=10000
DATA_WIDTH=3900
UPDATE_ROUNDS=100
UPDATE_CLIENTS=8
CHECK_ROWS=5
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

OpenGauss/GaussDB UStore undo recycling test.
Auto-selects client: gaussdb/opengauss prefer gsql, fallback psql.

Options:
    -t TYPE     Database type: gaussdb/opengauss (default: gaussdb)
    -h HOST     Database host (default: localhost)
    -p PORT     Database port (default: 8000 for gaussdb, 5433 for opengauss)
    -d DB       Database name (default: postgres)
    -U USER     Database user (default: root for gaussdb, gaussdb for opengauss)
    -W PASS     Database password
    -r ROWS     Number of initial rows (default: 10000)
    -w WIDTH    Data column width in bytes (default: 3900)
    -R ROUNDS   Number of update rounds (default: 100)
    -C CLIENTS  Concurrent update clients (default: 8)

Examples:
    # GaussDB (auto gsql)
    $0 -t gaussdb -h localhost -p 8000 -U root -W 'Pass@123'
    $0 -t gaussdb -h localhost -p 8000 -U root -W 'Pass@123' -r 50000 -R 200

    # OpenGauss (auto gsql or psql)
    $0 -t opengauss -h localhost -p 5433 -U gaussdb -W 'Enmotech@123'

    # OpenGauss with psql fallback
    $0 -t opengauss -h localhost -p 5433 -U gaussdb -W 'Enmotech@123' -r 10000 -R 100 -C 8
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

# URL encode password (for psql connection string)
url_encode() {
    local str="$1"
    printf '%s' "$str" | sed 's/@/%40/g; s/:/%3A/g; s/\//%2F/g; s/#/%23/g; s/\?/%3F/g; s/&/%26/g; s/=/%3D/g; s/ /%20/g'
}

# Auto-select client: gaussdb/opengauss prefer gsql, fallback psql
detect_client() {
    case $DB_TYPE in
        gaussdb|opengauss)
            if command -v gsql &> /dev/null; then
                DB_CLIENT="gsql"
            elif command -v psql &> /dev/null; then
                DB_CLIENT="psql"
            else
                log_error "Neither gsql nor psql found. Install database client tools."
                exit 1
            fi
            ;;
        *)
            log_error "Unsupported database type: $DB_TYPE (use gaussdb or opengauss)"
            exit 1
            ;;
    esac
}

# Set default port/user based on DB_TYPE
set_defaults() {
    case $DB_TYPE in
        gaussdb)
            DB_PORT=${DB_PORT:-8000}
            DB_USER=${DB_USER:-root}
            ;;
        opengauss)
            DB_PORT=${DB_PORT:-5433}
            DB_USER=${DB_USER:-gaussdb}
            ;;
    esac
}

# Build full connection command (gsql uses -W for password, psql uses connection string)
build_conn_cmd() {
    local extra_opts="$1"
    if [ "$DB_CLIENT" = "gsql" ]; then
        if [ -n "$DB_PASS" ]; then
            echo "gsql -h $DB_HOST -p $DB_PORT -U $DB_USER -W '$DB_PASS' -d $DB_NAME $extra_opts"
        else
            echo "gsql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME $extra_opts"
        fi
    else
        # psql: password via URL-encoded connection string
        if [ -n "$DB_PASS" ]; then
            local encoded_pass=$(url_encode "$DB_PASS")
            echo "psql postgresql://${DB_USER}:${encoded_pass}@${DB_HOST}:${DB_PORT}/${DB_NAME} $extra_opts"
        else
            echo "psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME $extra_opts"
        fi
    fi
}

# Execute SQL (quiet, suppress output noise)
db_exec() {
    local sql="$1"
    local cmd=$(build_conn_cmd "-q -c \"$sql\"")
    eval "$cmd" 2>&1 | grep -v "^ALTER SYSTEM\|^pg_reload_conf\|^SET\|^DROP TABLE\|^CREATE TABLE\|^INSERT 0\|^NOTICE:\|^gsql:" || true
}

# Execute SQL and return raw output
db_query() {
    local sql="$1"
    local cmd=$(build_conn_cmd "-t -c \"$sql\"")
    eval "$cmd" 2>&1
}

# Parse arguments
while getopts "t:h:p:d:U:W:r:w:R:C:" opt; do
    case $opt in
        t) DB_TYPE="$OPTARG" ;;
        h) DB_HOST="$OPTARG" ;;
        p) DB_PORT="$OPTARG" ;;
        d) DB_NAME="$OPTARG" ;;
        U) DB_USER="$OPTARG" ;;
        W) DB_PASS="$OPTARG" ;;
        r) ROW_COUNT="$OPTARG" ;;
        w) DATA_WIDTH="$OPTARG" ;;
        R) UPDATE_ROUNDS="$OPTARG" ;;
        C) UPDATE_CLIENTS="$OPTARG" ;;
        *) usage ;;
    esac
done

# Set type-specific defaults
set_defaults

# Detect client
detect_client
log_info "Using client: $DB_CLIENT"

# Calculate sleep time
SLEEP_SECONDS=$(( UPDATE_ROUNDS * 2 + 30 ))
if [ "$SLEEP_SECONDS" -lt 120 ]; then
    SLEEP_SECONDS=120
fi

echo ""
echo "============================================"
echo "  UStore Undo Recycling Test"
echo "============================================"
echo "Database:  $DB_TYPE ($DB_HOST:$DB_PORT/$DB_NAME)"
echo "User:      $DB_USER"
echo "Client:    $DB_CLIENT"
echo "Table:     $TABLE_NAME (ustore)"
echo "Rows:      $ROW_COUNT"
echo "Data width: ${DATA_WIDTH} bytes per row"
echo "Update rounds: $UPDATE_ROUNDS x $UPDATE_CLIENTS clients"
echo "Long txn sleep: ${SLEEP_SECONDS}s"
echo "============================================"
echo ""

# Step 1: Check database version
log_step "1/7: Checking database version"
DB_VER=$(db_query "SELECT version();" | head -1)
echo "  $DB_VER"

if ! echo "$DB_VER" | grep -qi "opengauss\|gaussdb"; then
    log_warn "This test is designed for OpenGauss/GaussDB with UStore."
    log_warn "PostgreSQL does not have undo mechanism."
    log_warn "Proceeding anyway for reference..."
fi

# Step 2: Check ustore support and undo settings
log_step "2/7: Checking UStore and undo configuration"
ENABLE_USTORE=$(db_query "SHOW enable_ustore;" | tr -d '[:space:]')
UNDO_RETENTION=$(db_query "SHOW undo_retention_time;" | tr -d '[:space:]')
UNDO_SPACE_NUM=$(db_query "SELECT setting FROM pg_settings WHERE name = 'undo_space_limit_size';" | tr -d '[:space:]')
UNDO_SPACE_MB=$(( UNDO_SPACE_NUM * 8 / 1024 ))

echo "  enable_ustore:       $ENABLE_USTORE"
echo "  undo_retention_time: $UNDO_RETENTION seconds"
echo "  undo_space_limit:    ${UNDO_SPACE_NUM} × 8kB (${UNDO_SPACE_MB}MB)"

if [ "$ENABLE_USTORE" != "on" ]; then
    log_error "UStore is not enabled. Set enable_ustore=on first."
    exit 1
fi

# Step 2b: Reduce undo_space_limit_size
log_step "2b/7: Reducing undo_space_limit_size to minimum (800MB)"
db_exec "ALTER SYSTEM SET undo_space_limit_size = 102400;" 2>&1 || true
db_exec "SELECT pg_reload_conf();" 2>&1 || true
sleep 1

NEW_UNDO_SPACE=$(db_query "SELECT setting FROM pg_settings WHERE name = 'undo_space_limit_size';" | tr -d '[:space:]')
echo "  undo_space_limit: ${NEW_UNDO_SPACE} × 8kB"

if [ "$NEW_UNDO_SPACE" = "102400" ]; then
    log_info "  Successfully set undo_space_limit_size to 800MB"
else
    log_warn "  undo_space_limit_size unchanged (${NEW_UNDO_SPACE} × 8kB)"
fi

# Step 3: Create ustore table with wide rows
log_step "3/7: Creating UStore table with $ROW_COUNT wide rows (${DATA_WIDTH} bytes)"

db_exec "DROP TABLE IF EXISTS $TABLE_NAME CASCADE;" || true
db_exec "CREATE TABLE $TABLE_NAME (id INT PRIMARY KEY, val INT, data VARCHAR(${DATA_WIDTH})) WITH (storage_type = ustore);"

log_info "  Inserting $ROW_COUNT rows with val=0, data=${DATA_WIDTH} bytes..."
db_exec "INSERT INTO $TABLE_NAME SELECT s, 0, repeat('x', ${DATA_WIDTH}) FROM generate_series(1, $ROW_COUNT) AS s;"

ROW_VERIFY=$(db_query "SELECT count(*) FROM $TABLE_NAME;" | tr -d '[:space:]')
echo "  Inserted: $ROW_VERIFY rows"

# Step 4: Verify initial snapshot value
log_step "4/7: Verifying initial val=0"
INIT_VAL=$(db_query "SELECT val FROM $TABLE_NAME WHERE id = 1;" | tr -d '[:space:]')
echo "  Initial val: $INIT_VAL (expected: 0)"

if [ "$INIT_VAL" != "0" ]; then
    log_error "Initial val is not 0!"
    exit 1
fi

# Step 5: Start long transaction (Session 1)
log_step "5/7: Starting long transaction in Session 1 (pg_sleep ${SLEEP_SECONDS}s)"

LONG_TXN_SQL="/tmp/long_txn_${TABLE_NAME}_$$.sql"
LONG_TXN_OUT="/tmp/long_txn_${TABLE_NAME}_$$.out"

cat > "$LONG_TXN_SQL" << SQL_EOF
\set ON_ERROR_STOP off
BEGIN;
SELECT id, val FROM $TABLE_NAME WHERE id <= ${CHECK_ROWS};
SELECT pg_sleep(${SLEEP_SECONDS});
SELECT id, val FROM $TABLE_NAME WHERE id <= ${CHECK_ROWS};
COMMIT;
SQL_EOF

LONG_TXN_CMD=$(build_conn_cmd "-f $LONG_TXN_SQL")
eval "$LONG_TXN_CMD" > "$LONG_TXN_OUT" 2>&1 &
LONG_TXN_PID=$!

log_info "  Long transaction started (PID=$LONG_TXN_PID)"
sleep 3

# Step 6: Heavy concurrent updates
log_step "6/7: Running $UPDATE_ROUNDS rounds x $UPDATE_CLIENTS clients of heavy updates"

UPDATE_SQL="UPDATE $TABLE_NAME SET val = val + 1, data = repeat('u', ${DATA_WIDTH}) WHERE id BETWEEN $start_id AND $end_id;"

for round in $(seq 1 $UPDATE_ROUNDS); do
    for c in $(seq 1 $UPDATE_CLIENTS); do
        start_id=$(( (c-1) * (ROW_COUNT / UPDATE_CLIENTS) + 1 ))
        end_id=$(( c * (ROW_COUNT / UPDATE_CLIENTS) ))
        UPDATE_CMD=$(build_conn_cmd "-q -c \"UPDATE $TABLE_NAME SET val = val + 1, data = repeat('u', ${DATA_WIDTH}) WHERE id BETWEEN $start_id AND $end_id;\"")
        eval "$UPDATE_CMD" 2>/dev/null &
    done
    wait

    # Every 10 rounds, show undo stats
    if [ $((round % 10)) -eq 0 ]; then
        UNDO_USED=$(db_query "SELECT curr_used_undo_size FROM gs_stat_undo();" | tr -d '[:space:]')
        log_info "  Round $round/$UPDATE_ROUNDS | undo_used: ${UNDO_USED} | $(date +%H:%M:%S)"
    fi
done

log_info "  All update rounds complete. Waiting for long transaction to wake up..."

# Wait for long transaction
WAIT_TIMEOUT=$(( SLEEP_SECONDS + 60 ))
elapsed=0
while kill -0 $LONG_TXN_PID 2>/dev/null; do
    if [ "$elapsed" -ge "$WAIT_TIMEOUT" ]; then
        log_warn "  Long transaction did not finish, killing it"
        kill $LONG_TXN_PID 2>/dev/null
        wait $LONG_TXN_PID 2>/dev/null
        break
    fi
    sleep 5
    elapsed=$(( elapsed + 5 ))
done

# Step 7: Check results and cleanup
log_step "7/7: Checking results and cleanup"

SNAPSHOT_TOO_OLD=false
SNAPSHOT_CORRUPT=false
second_val=""

if [ -f "$LONG_TXN_OUT" ]; then
    echo "  Long transaction output:"
    cat "$LONG_TXN_OUT"

    # Check for "snapshot too old" error
    if grep -qi "snapshot too old" "$LONG_TXN_OUT"; then
        SNAPSHOT_TOO_OLD=true
        log_error "  'snapshot too old' error was triggered!"
    fi

    # Check for val mismatch (MVCC corruption)
    second_val=$(sed -n '/pg_sleep/,$ p' "$LONG_TXN_OUT" | grep -E '^\s+[0-9]+\s+\|\s+[0-9]+' | head -1 | awk -F'|' '{gsub(/[[:space:]]/, "", $2); print $2}')

    if [ -n "$second_val" ] && [ "$second_val" != "0" ]; then
        SNAPSHOT_CORRUPT=true
        log_error "  Snapshot corruption: second SELECT returned val=$second_val (expected 0)"
    fi
fi

# Cleanup table
db_exec "DROP TABLE IF EXISTS $TABLE_NAME CASCADE;" || true

# Reset undo_space_limit_size
log_info "  Resetting undo_space_limit_size..."
db_exec "ALTER SYSTEM SET undo_space_limit_size = 33554432;" || true
db_exec "SELECT pg_reload_conf();" || true

rm -f "$LONG_TXN_SQL" "$LONG_TXN_OUT"

# Summary
echo ""
echo "============================================"
echo "  Test Result"
echo "============================================"
if [ "$SNAPSHOT_TOO_OLD" = true ]; then
    log_error "'snapshot too old' was triggered!"
    log_info "The undo records needed by the long transaction's snapshot"
    log_info "were recycled before the snapshot could use them."
    echo "============================================"
    exit 0
elif [ "$SNAPSHOT_CORRUPT" = true ]; then
    log_error "MVCC snapshot corruption detected!"
    log_info "The query returned the CURRENT data instead of the snapshot data."
    log_info "The undo records were silently recycled, breaking MVCC semantics:"
    log_info "  - Expected: val=0 (value at snapshot time)"
    log_info "  - Got: val=$second_val (undo chain truncated, returned nearest available version)"
    log_info "  - This is WORSE than 'snapshot too old' -- data is silently wrong."
    echo "============================================"
    exit 1
else
    log_warn "No issue detected. Snapshot returned correct data (val=0)."
    log_info "The undo system correctly preserved the snapshot."
    log_info ""
    log_info "To trigger the issue, try:"
    log_info "  - Increase data: -r 50000 -w 3900 -R 200 -C 8"
    log_info "  - Manually decrease undo_space_limit_size in postgresql.conf"
    echo "============================================"
    exit 2
fi