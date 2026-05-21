#!/bin/bash
#
# test_snapshot_too_old.sh - OpenGauss/GaussDB UStore undo 回收测试
#
# 复现 "snapshot too old" 报错：
#   1. 创建 ustore 表（undo 日志存储引擎）
#   2. 长事务通过游标 FETCH 逐行获取数据
#   3. 并发更新产生大量 undo 记录，undo 回收截断 undo 链
#   4. 游标继续 FETCH 时报 "snapshot too old"（GaussDB）
#   5. 或普通 SELECT 静默返回当前值而非快照值（OpenGauss）
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
SLEEP_SECONDS=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

OpenGauss/GaussDB UStore "snapshot too old" reproduction test.

Uses cursor FETCH to trigger "snapshot too old" error (GaussDB).
Also runs a regular SELECT as fallback to detect silent MVCC corruption (OpenGauss).

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
    $0 -t gaussdb -h localhost -p 8000 -U root -W 'Pass@123'
    $0 -t opengauss -h localhost -p 5433 -U gaussdb -W 'Enmotech@123'
    $0 -t gaussdb -h localhost -p 8000 -U root -W 'Pass@123' -r 50000 -R 200 -C 8
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
echo "Sleep:     ${SLEEP_SECONDS}s"
echo "============================================"
echo ""

# Step 1: Check version
log_step "1/7: Checking database version"
DB_VER=$(db_query "SELECT version();" | head -1)
echo "  $DB_VER"

if ! echo "$DB_VER" | grep -qi "opengauss\|gaussdb"; then
    log_warn "This test requires OpenGauss/GaussDB with UStore."
fi

# Step 2: Check undo config
log_step "2/7: Checking UStore and undo configuration"
ENABLE_USTORE=$(db_query "SHOW enable_ustore;" | tr -d '[:space:]')
UNDO_RETENTION=$(db_query "SHOW undo_retention_time;" | tr -d '[:space:]')
UNDO_SPACE_NUM=$(db_query "SELECT setting FROM pg_settings WHERE name = 'undo_space_limit_size';" | tr -d '[:space:]')
UNDO_SPACE_MB=$(( UNDO_SPACE_NUM * 8 / 1024 ))

echo "  enable_ustore:       $ENABLE_USTORE"
echo "  undo_retention_time: $UNDO_RETENTION s"
echo "  undo_space_limit:    ${UNDO_SPACE_NUM} x 8kB (${UNDO_SPACE_MB}MB)"

[ "$ENABLE_USTORE" != "on" ] && { log_error "UStore not enabled."; exit 1; }

# Step 2b: Reduce undo limit
log_step "2b/7: Reducing undo_space_limit_size to minimum (800MB)"
db_exec "ALTER SYSTEM SET undo_space_limit_size = 102400;" || true
db_exec "SELECT pg_reload_conf();" || true
sleep 1

NEW_UNDO=$(db_query "SELECT setting FROM pg_settings WHERE name = 'undo_space_limit_size';" | tr -d '[:space:]')
echo "  undo_space_limit: ${NEW_UNDO} x 8kB"
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

# --- Cursor-based long transaction (primary: triggers "snapshot too old") ---
CUR_SQL="/tmp/cur_${TABLE_NAME}_$$.sql"
# Fetch rows in batches with delays, so undo recycler runs between fetches
BATCH_SIZE=$(( ROW_COUNT / 20 ))  # 20 fetches to scan all rows
[ "$BATCH_SIZE" -lt 5 ] && BATCH_SIZE=5
FETCH_COUNT=20

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

# Step 6: Heavy concurrent updates
log_step "6/7: Running $UPDATE_ROUNDS rounds x $UPDATE_CLIENTS clients of updates"

for round in $(seq 1 $UPDATE_ROUNDS); do
    for c in $(seq 1 $UPDATE_CLIENTS); do
        start_id=$(( (c-1) * (ROW_COUNT / UPDATE_CLIENTS) + 1 ))
        end_id=$(( c * (ROW_COUNT / UPDATE_CLIENTS) ))
        eval "$(build_conn "-q -c \"UPDATE $TABLE_NAME SET val = val + 1, data = repeat('u', ${DATA_WIDTH}) WHERE id BETWEEN $start_id AND $end_id;\"")" 2>/dev/null &
    done
    wait

    if [ $((round % 10)) -eq 0 ]; then
        UNDO_USED=$(db_query "SELECT curr_used_undo_size FROM gs_stat_undo();" | tr -d '[:space:]')
        log_info "  Round $round/$UPDATE_ROUNDS | undo: ${UNDO_USED} | $(date +%H:%M:%S)"
    fi
done

log_info "  Updates complete. Waiting for long transactions..."

# Wait for both transactions
WAIT_TIMEOUT=$(( SLEEP_SECONDS + 60 ))
for pid in $CUR_PID $SEL_PID; do
    elapsed=0
    while kill -0 $pid 2>/dev/null; do
        [ "$elapsed" -ge "$WAIT_TIMEOUT" ] && { kill $pid 2>/dev/null; wait $pid 2>/dev/null; break; }
        sleep 5; elapsed=$(( elapsed + 5 ))
    done
done

# Step 7: Check results
log_step "7/7: Checking results and cleanup"

SNAPSHOT_TOO_OLD=false
SNAPSHOT_CORRUPT=false
second_val=""

# --- Check cursor output for "snapshot too old" ---
echo "  === Cursor transaction ==="
if [ -f "$CUR_OUT" ]; then
    # Check for error
    if grep -qi "snapshot too old" "$CUR_OUT"; then
        SNAPSHOT_TOO_OLD=true
        log_error "  CURSOR: 'snapshot too old' triggered!"
        grep -i "snapshot too old" "$CUR_OUT"
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
    # Show only key lines (first SELECT result, last SELECT result, any errors)
    head_before=$(grep -n "pg_sleep" "$SEL_OUT" | head -1 | cut -d: -f1)
    if [ -n "$head_before" ]; then
        echo "  Before sleep:"
        head -$((head_before - 1)) "$SEL_OUT" | grep -E "^.*\|.*$" | head -7
        echo "  After sleep:"
        tail +$((head_before + 1)) "$SEL_OUT" | grep -E "^.*\|.*$" | head -7
    fi

    if grep -qi "snapshot too old" "$SEL_OUT"; then
        SNAPSHOT_TOO_OLD=true
        log_error "  SELECT: 'snapshot too old' triggered!"
        grep -i "snapshot too old" "$SEL_OUT"
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
log_info "  Resetting undo_space_limit_size..."
db_exec "ALTER SYSTEM SET undo_space_limit_size = 33554432;" || true
db_exec "SELECT pg_reload_conf();" || true
rm -f "$CUR_SQL" "$CUR_OUT" "$SEL_SQL" "$SEL_OUT"

# Summary
echo ""
echo "============================================"
echo "  Test Result"
echo "============================================"
if [ "$SNAPSHOT_TOO_OLD" = true ]; then
    log_error "'snapshot too old' was triggered!"
    log_info "Cursor FETCH encountered recycled undo records"
    log_info "and correctly raised the error instead of silently"
    log_info "returning wrong data."
    echo "============================================"
    exit 0
elif [ "$SNAPSHOT_CORRUPT" = true ]; then
    log_error "MVCC snapshot corruption detected (no error raised)"
    log_info "Regular SELECT returned val=$second_val instead of 0."
    log_info "Undo records were silently recycled, returning current"
    log_info "data instead of snapshot data. This is worse than"
    log_info "'snapshot too old' -- data is silently wrong."
    echo ""
    log_info "GaussDB (commercial) may raise 'snapshot too old' error"
    log_info "instead of silently returning wrong data. Run this test"
    log_info "on GaussDB with gsql for the proper error behavior."
    echo "============================================"
    exit 1
else
    log_warn "No issue detected. Snapshot data is correct (val=0)."
    log_info "Try: -r 50000 -w 3900 -R 200 -C 8 for more undo pressure"
    echo "============================================"
    exit 2
fi