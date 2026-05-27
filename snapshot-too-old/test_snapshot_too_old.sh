#!/bin/bash
#
# test_snapshot_too_old.sh - OpenGauss/GaussDB UStore undo 回收测试
#
# 复现 "snapshot is stale" / "snapshot too old" 报错：
#   1. 创建 ustore 表（undo 日志存储引擎）
#   2. 长事务通过游标 FETCH 逐行获取数据
#   3. undo 压力事务并发更新全表 + pg_sleep 保持事务不提交，积累 undo
#   4. undo_used 超过 undo_threshold → 强制回收绕过 oldest_xmin
#   5. 游标 FETCH 时 undo 链已被截断 → 报 "snapshot is stale"
#   6. 或普通 SELECT 静默返回当前值而非快照值（OpenGauss 6.0 bug）
#
# 适用于 GaussDB / OpenGauss（PostgreSQL 无 undo 机制）
# 自动选择客户端：gaussdb/opengauss 优先 gsql，回退 psql
#

DB_TYPE="gaussdb"
DB_HOST="localhost"
DB_PORT=""
DB_NAME="postgres"
DB_USER=""
DB_PASS=""
DB_CLIENT=""
TABLE_NAME="snap_too_old_test"
ROW_COUNT=10000
DATA_WIDTH=3900
UPDATE_ROUNDS=100
UPDATE_CLIENTS=8
PRESSURE_CLIENTS=20
PRESSURE_SLEEP=5
SLEEP_SECONDS=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

OpenGauss/GaussDB UStore "snapshot is stale" reproduction test.

Strategy: concurrent "undo pressure" transactions (BEGIN + UPDATE + pg_sleep + COMMIT)
accumulate undo past the threshold, triggering force recycling that bypasses oldest_xmin,
reclaiming undo records needed by a cursor's snapshot → cursor FETCH raises error.

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
    -C CLIENTS  Concurrent update clients per round (default: 8)
    -P PRESSURE Undo pressure transaction concurrency (default: 20)
    -S SLEEP    Undo pressure transaction pg_sleep seconds (default: 5)

Examples:
    $0 -t gaussdb -h localhost -p 8000 -U root -W 'Pass@123'
    $0 -t opengauss -h localhost -p 5433 -U gaussdb -W 'Enmotech@123'
    $0 -t opengauss -h localhost -p 5433 -U gaussdb -W 'Enmotech@123' -r 50000 -R 200 -C 16 -P 30 -S 10
EOF
    exit 1
}

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }

url_encode() {
    printf '%s' "$1" | sed 's/@/%40/g; s/:/%3A/g; s/\//%2F/g; s/#/%23/g; s/\?/%3F/g; s/&/%26/g; s/=/%3D/g; s/ /%20/g'
}

detect_client() {
    case $DB_TYPE in
        gaussdb|opengauss)
            if command -v gsql &> /dev/null; then
                DB_CLIENT="gsql"
            elif command -v psql &> /dev/null; then
                DB_CLIENT="psql"
            else
                log_error "Neither gsql nor psql found."; exit 1
            fi ;;
        *) log_error "Unsupported type: $DB_TYPE"; exit 1 ;;
    esac
}

set_defaults() {
    case $DB_TYPE in
        gaussdb)  DB_PORT=${DB_PORT:-8000}; DB_USER=${DB_USER:-root} ;;
        opengauss) DB_PORT=${DB_PORT:-5433}; DB_USER=${DB_USER:-gaussdb} ;;
    esac
}

# Build connection command for gsql or psql
build_conn() {
    local extra="$1"
    if [ "$DB_CLIENT" = "gsql" ]; then
        if [ -n "$DB_PASS" ]; then
            echo "gsql -h $DB_HOST -p $DB_PORT -U $DB_USER -W '$DB_PASS' -d $DB_NAME $extra"
        else
            echo "gsql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME $extra"
        fi
    else
        if [ -n "$DB_PASS" ]; then
            local ep=$(url_encode "$DB_PASS")
            echo "psql postgresql://${DB_USER}:${ep}@${DB_HOST}:${DB_PORT}/${DB_NAME} $extra"
        else
            echo "psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME $extra"
        fi
    fi
}

db_exec() {
    local sql="$1"
    eval "$(build_conn "-q -c \"$sql\"")" 2>&1 | grep -v "^ALTER\|^pg_reload\|^SET\|^DROP\|^CREATE\|^INSERT\|^NOTICE\|^gsql:" || true
}

db_query() {
    local sql="$1"
    eval "$(build_conn "-t -c \"$sql\"")" 2>&1
}

while getopts "t:h:p:d:U:W:r:w:R:C:P:S:" opt; do
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
        P) PRESSURE_CLIENTS="$OPTARG" ;;
        S) PRESSURE_SLEEP="$OPTARG" ;;
        *) usage ;;
    esac
done

set_defaults
detect_client

SLEEP_SECONDS=$(( UPDATE_ROUNDS * 2 + 30 ))
[ "$SLEEP_SECONDS" -lt 120 ] && SLEEP_SECONDS=120

echo ""
echo "============================================"
echo "  UStore Snapshot Too Old Test"
echo "============================================"
echo "Database:  $DB_TYPE ($DB_HOST:$DB_PORT/$DB_NAME)"
echo "User:      $DB_USER"
echo "Client:    $DB_CLIENT"
echo "Table:     $TABLE_NAME (ustore)"
echo "Rows:      $ROW_COUNT, width: ${DATA_WIDTH} bytes"
echo "Updates:   $UPDATE_ROUNDS rounds x $UPDATE_CLIENTS clients"
echo "Pressure:  $PRESSURE_CLIENTS clients x ${PRESSURE_SLEEP}s sleep"
echo "Sleep:     ${SLEEP_SECONDS}s (long txn)"
echo "============================================"
echo ""

# Step 1: Check version
log_step "1/7: Checking database version"
DB_VER=$(db_query "SELECT version();" | head -1)
echo "  $DB_VER"

if ! echo "$DB_VER" | grep -qi "opengauss\|gaussdb"; then
    log_warn "This test requires OpenGauss/GaussDB with UStore."
fi

# Step 2: Check undo config (including undo_snapshot_stale_check)
log_step "2/7: Checking UStore and undo configuration"
ENABLE_USTORE=$(db_query "SHOW enable_ustore;" | tr -d '[:space:]')
UNDO_RETENTION=$(db_query "SHOW undo_retention_time;" | tr -d '[:space:]')
UNDO_SPACE_NUM=$(db_query "SELECT setting FROM pg_settings WHERE name = 'undo_space_limit_size';" | tr -d '[:space:]')
UNDO_SPACE_MB=$(( UNDO_SPACE_NUM * 8 / 1024 ))
UNDO_THRESHOLD_MB=$(( UNDO_SPACE_MB * 80 / 100 ))

# Check undo_snapshot_stale_check (controls "snapshot is stale" error)
STALE_CHECK=$(db_query "SHOW undo_snapshot_stale_check;" 2>&1 | tr -d '[:space:]')

echo "  enable_ustore:          $ENABLE_USTORE"
echo "  undo_retention_time:    $UNDO_RETENTION s"
echo "  undo_space_limit:       ${UNDO_SPACE_NUM} x 8kB (${UNDO_SPACE_MB}MB)"
echo "  undo_threshold:         ~${UNDO_THRESHOLD_MB}MB (80%, force recycling trigger)"
echo "  undo_snapshot_stale_check: ${STALE_CHECK}"

[ "$ENABLE_USTORE" != "on" ] && { log_error "UStore not enabled."; exit 1; }

# Enable undo_snapshot_stale_check if off
if [ "$STALE_CHECK" != "on" ]; then
    log_warn "undo_snapshot_stale_check is off, enabling it..."
    db_exec "ALTER SYSTEM SET undo_snapshot_stale_check = on;" || true
    db_exec "SELECT pg_reload_conf();" || true
    sleep 1
    STALE_CHECK=$(db_query "SHOW undo_snapshot_stale_check;" 2>&1 | tr -d '[:space:]')
    echo "  undo_snapshot_stale_check: ${STALE_CHECK} (after change)"
fi

# Step 2b: Reduce undo limit
log_step "2b/7: Reducing undo_space_limit_size to minimum (800MB)"
db_exec "ALTER SYSTEM SET undo_space_limit_size = 102400;" || true
db_exec "SELECT pg_reload_conf();" || true
sleep 1

NEW_UNDO=$(db_query "SELECT setting FROM pg_settings WHERE name = 'undo_space_limit_size';" | tr -d '[:space:]')
UNDO_THRESHOLD_MB=$(( NEW_UNDO * 8 / 1024 * 80 / 100 ))
echo "  undo_space_limit: ${NEW_UNDO} x 8kB"
echo "  undo_threshold:   ~${UNDO_THRESHOLD_MB}MB (force recycling trigger)"
[ "$NEW_UNDO" = "102400" ] && log_info "  Set to 800MB" || log_warn "  Unchanged (${NEW_UNDO} x 8kB)"

# Step 3: Create ustore table
log_step "3/7: Creating UStore table ($ROW_COUNT rows, ${DATA_WIDTH} bytes)"
db_exec "DROP TABLE IF EXISTS $TABLE_NAME CASCADE;" || true
db_exec "CREATE TABLE $TABLE_NAME (id INT PRIMARY KEY, val INT, data VARCHAR(${DATA_WIDTH})) WITH (storage_type = ustore);"
log_info "  Inserting $ROW_COUNT rows..."
db_exec "INSERT INTO $TABLE_NAME SELECT s, 0, repeat('x', ${DATA_WIDTH}) FROM generate_series(1, $ROW_COUNT) AS s;"
ROW_VERIFY=$(db_query "SELECT count(*) FROM $TABLE_NAME;" | tr -d '[:space:]')
echo "  Inserted: $ROW_VERIFY rows"

# Step 4: Verify initial val
log_step "4/7: Verifying initial val=0"
INIT_VAL=$(db_query "SELECT val FROM $TABLE_NAME WHERE id = 1;" | tr -d '[:space:]')
echo "  Initial val: $INIT_VAL"
[ "$INIT_VAL" != "0" ] && { log_error "Initial val != 0!"; exit 1; }

# Step 5: Start two long transactions in background
log_step "5/7: Starting long transactions (cursor + select)"

CUR_OUT="/tmp/cur_${TABLE_NAME}_$$.out"
SEL_OUT="/tmp/sel_${TABLE_NAME}_$$.out"

# --- Cursor-based long transaction (primary: triggers "snapshot is stale") ---
CUR_SQL="/tmp/cur_${TABLE_NAME}_$$.sql"
BATCH_SIZE=$(( ROW_COUNT / 20 ))
[ "$BATCH_SIZE" -lt 5 ] && BATCH_SIZE=5

cat > "$CUR_SQL" << SQL_EOF
\set ON_ERROR_STOP off
BEGIN;
DECLARE snap_cur CURSOR FOR SELECT id, val FROM $TABLE_NAME ORDER BY id;
FETCH $BATCH_SIZE FROM snap_cur;
SELECT pg_sleep(${SLEEP_SECONDS});
FETCH $BATCH_SIZE FROM snap_cur;
FETCH $BATCH_SIZE FROM snap_cur;
FETCH $BATCH_SIZE FROM snap_cur;
FETCH $BATCH_SIZE FROM snap_cur;
FETCH $BATCH_SIZE FROM snap_cur;
FETCH $BATCH_SIZE FROM snap_cur;
FETCH $BATCH_SIZE FROM snap_cur;
FETCH $BATCH_SIZE FROM snap_cur;
FETCH $BATCH_SIZE FROM snap_cur;
FETCH $BATCH_SIZE FROM snap_cur;
FETCH $BATCH_SIZE FROM snap_cur;
FETCH $BATCH_SIZE FROM snap_cur;
FETCH $BATCH_SIZE FROM snap_cur;
FETCH $BATCH_SIZE FROM snap_cur;
FETCH $BATCH_SIZE FROM snap_cur;
FETCH $BATCH_SIZE FROM snap_cur;
FETCH $BATCH_SIZE FROM snap_cur;
FETCH $BATCH_SIZE FROM snap_cur;
CLOSE snap_cur;
COMMIT;
SQL_EOF

# --- Regular SELECT long transaction (fallback: detects val mismatch) ---
SEL_SQL="/tmp/sel_${TABLE_NAME}_$$.sql"
CHECK_ROWS=5

cat > "$SEL_SQL" << SQL_EOF
\set ON_ERROR_STOP off
BEGIN;
SELECT id, val FROM $TABLE_NAME WHERE id <= ${CHECK_ROWS};
SELECT pg_sleep(${SLEEP_SECONDS});
SELECT id, val FROM $TABLE_NAME WHERE id <= ${CHECK_ROWS};
COMMIT;
SQL_EOF

eval "$(build_conn "-f $CUR_SQL")" > "$CUR_OUT" 2>&1 &
CUR_PID=$!

eval "$(build_conn "-f $SEL_SQL")" > "$SEL_OUT" 2>&1 &
SEL_PID=$!

log_info "  Cursor txn PID=$CUR_PID, Select txn PID=$SEL_PID"
sleep 3

# Step 6: Run undo pressure + concurrent updates
log_step "6/7: Running undo pressure transactions + concurrent updates"

# --- Undo pressure transactions: BEGIN + UPDATE all + pg_sleep + COMMIT ---
# Each pressure transaction updates ALL rows with wide data, holds open via pg_sleep.
# N concurrent such transactions accumulate N × ~39MB undo ≈ 780MB, exceeding 640MB threshold.
PRESSURE_SQL="/tmp/pressure_${TABLE_NAME}_$$.sql"
PRESSURE_PIDS=""

cat > "$PRESSURE_SQL" << SQL_EOF
\set ON_ERROR_STOP off
BEGIN;
UPDATE $TABLE_NAME SET val = val + 1, data = repeat('p', ${DATA_WIDTH});
SELECT pg_sleep(${PRESSURE_SLEEP});
COMMIT;
SQL_EOF

log_info "  Starting $PRESSURE_CLIENTS undo pressure transactions (pg_sleep ${PRESSURE_SLEEP}s)..."

# Launch pressure transactions in waves until long transactions finish
pressure_round=0
while kill -0 $CUR_PID 2>/dev/null; do
    pressure_round=$(( pressure_round + 1 ))
    wave_pids=""
    for i in $(seq 1 $PRESSURE_CLIENTS); do
        eval "$(build_conn "-f $PRESSURE_SQL")" 2>/dev/null &
        pid=$!
        wave_pids="$wave_pids $pid"
    done
    PRESSURE_PIDS="$PRESSURE_PIDS $wave_pids"

    # Also run quick partitioned updates during this wave
    for c in $(seq 1 $UPDATE_CLIENTS); do
        start_id=$(( (c-1) * (ROW_COUNT / UPDATE_CLIENTS) + 1 ))
        end_id=$(( c * (ROW_COUNT / UPDATE_CLIENTS) ))
        eval "$(build_conn "-q -c \"UPDATE $TABLE_NAME SET val = val + 1, data = repeat('u', ${DATA_WIDTH}) WHERE id BETWEEN $start_id AND $end_id;\"")" 2>/dev/null &
    done

    # Monitor undo usage
    UNDO_USED=$(db_query "SELECT curr_used_undo_size FROM gs_stat_undo();" 2>/dev/null | tr -d '[:space:]')
    UNDO_USED_MB=""
    if [ -n "$UNDO_USED" ] && [ "$UNDO_USED" != "" ]; then
        UNDO_USED_MB=$(( UNDO_USED * 8 / 1024 ))
        log_info "  Pressure wave $pressure_round | undo_used: ${UNDO_USED} (${UNDO_USED_MB}MB) vs threshold ~${UNDO_THRESHOLD_MB}MB | $(date +%H:%M:%S)"
        if [ "$UNDO_USED_MB" -ge "$UNDO_THRESHOLD_MB" ]; then
            log_warn "  undo_used (${UNDO_USED_MB}MB) >= threshold (${UNDO_THRESHOLD_MB}MB) — force recycling should be active!"
        fi
    fi

    # Wait for this wave to finish before launching next
    for pid in $wave_pids; do
        wait $pid 2>/dev/null || true
    done
    wait 2>/dev/null || true

    # Brief pause between waves
    sleep 1
done

log_info "  Long transactions finished. Waiting for remaining pressure transactions..."

# Wait for remaining pressure transactions
for pid in $PRESSURE_PIDS; do
    kill -0 $pid 2>/dev/null && wait $pid 2>/dev/null || true
done

# Wait for remaining update processes
wait 2>/dev/null || true

# Step 7: Check results
log_step "7/7: Checking results and cleanup"

SNAPSHOT_STALE=false
SNAPSHOT_CORRUPT=false
second_val=""

# --- Check cursor output for "snapshot is stale" / "snapshot too old" ---
echo "  === Cursor transaction ==="
if [ -f "$CUR_OUT" ]; then
    # Check for both error strings: "snapshot is stale" (OpenGauss) and "snapshot too old" (GaussDB/Oracle)
    if grep -qi "snapshot.*too.*old\|snapshot.*stale" "$CUR_OUT"; then
        SNAPSHOT_STALE=true
        log_error "  CURSOR: snapshot stale/too-old error triggered!"
        grep -i "snapshot.*too.*old\|snapshot.*stale" "$CUR_OUT"
    fi

    # Check cursor returned val values (should be 0 at snapshot)
    cur_nonzero=$(grep -E '^\s+[0-9]+\s+\|\s+[0-9]+' "$CUR_OUT" | awk -F'|' '{gsub(/[[:space:]]/, "", $2); if ($2 != "0") print $2}' | sort -u)
    if [ -n "$cur_nonzero" ]; then
        log_warn "  CURSOR: returned val=$cur_nonzero (expected 0)"
    else
        CUR_ROWS=$(grep -cE '^\s+[0-9]+\s+\|\s+[0-9]+' "$CUR_OUT" || echo 0)
        log_info "  CURSOR: $CUR_ROWS rows returned, all val=0 (correct snapshot)"
    fi
fi

# --- Check select output for val mismatch ---
echo ""
echo "  === Select transaction ==="
if [ -f "$SEL_OUT" ]; then
    head_before=$(grep -n "pg_sleep" "$SEL_OUT" | head -1 | cut -d: -f1)
    if [ -n "$head_before" ]; then
        echo "  Before sleep:"
        head -$((head_before - 1)) "$SEL_OUT" | grep -E "^.*\|.*$" | head -7
        echo "  After sleep:"
        tail +$((head_before + 1)) "$SEL_OUT" | grep -E "^.*\|.*$" | head -7
    fi

    if grep -qi "snapshot.*too.*old\|snapshot.*stale" "$SEL_OUT"; then
        SNAPSHOT_STALE=true
        log_error "  SELECT: snapshot stale/too-old error triggered!"
        grep -i "snapshot.*too.*old\|snapshot.*stale" "$SEL_OUT"
    fi

    second_val=$(sed -n '/pg_sleep/,$ p' "$SEL_OUT" | grep -E '^\s+[0-9]+\s+\|\s+[0-9]+' | head -1 | awk -F'|' '{gsub(/[[:space:]]/, "", $2); print $2}')

    if [ -n "$second_val" ] && [ "$second_val" != "0" ]; then
        SNAPSHOT_CORRUPT=true
        log_error "  SELECT: snapshot corruption val=$second_val (expected 0)"
    else
        log_info "  SELECT: val=0 (correct snapshot)"
    fi
fi

# Cleanup
db_exec "DROP TABLE IF EXISTS $TABLE_NAME CASCADE;" || true
log_info "  Resetting undo config..."
db_exec "ALTER SYSTEM SET undo_space_limit_size = 33554432;" || true
db_exec "ALTER SYSTEM SET undo_snapshot_stale_check = on;" || true
db_exec "SELECT pg_reload_conf();" || true
rm -f "$CUR_SQL" "$CUR_OUT" "$SEL_SQL" "$SEL_OUT" "$PRESSURE_SQL"

# Summary
echo ""
echo "============================================"
echo "  Test Result"
echo "============================================"
if [ "$SNAPSHOT_STALE" = true ]; then
    log_error "'snapshot is stale' / 'snapshot too old' was triggered!"
    log_info "Undo records needed by the long transaction's snapshot"
    log_info "were forcibly recycled (bypassing oldest_xmin),"
    log_info "and the stale check correctly raised the error."
    echo "============================================"
    exit 0
elif [ "$SNAPSHOT_CORRUPT" = true ]; then
    log_error "MVCC snapshot corruption detected (no error raised)"
    log_info "Regular SELECT returned val=$second_val instead of 0."
    log_info "Undo records were recycled, returning current data"
    log_info "instead of snapshot data. This is worse than"
    log_info "'snapshot is stale' — data is silently wrong."
    echo ""
    log_info "To trigger the actual error, increase undo pressure:"
    log_info "  -P 30 -S 10  (more pressure clients, longer sleep)"
    log_info "  -r 50000      (more rows = more undo per transaction)"
    echo "============================================"
    exit 1
else
    log_warn "No issue detected. Snapshot data is correct (val=0)."
    log_info "Try increasing undo pressure:"
    log_info "  -P 30 -S 10 -r 50000 -R 200 -C 16"
    echo "============================================"
    exit 2
fi