#!/bin/bash
#
# test_fetch_undo_record.sh - OpenGauss/GaussDB "fetch undo record" 等待事件复现
#
# 原理：
#   Ustore 引擎采用 undo-based MVCC，每次 UPDATE 产生一条 undo record，
#   形成 undo chain。当查询需要读取旧版本数据时，必须沿 undo chain
#   逐条 fetch undo record 来重构一致读视图。
#
#   如果一个会话开启长事务，不断更新同一批行，undo chain 会越来越长。
#   其他会话全表扫描时，需要遍历这些 undo chain 来找到可见版本，
#   遍历开销随 undo chain 增长而增加，查询越来越慢，
#   同时出现 "fetch undo record" 等待事件。
#
# 测试流程：
#   1. 创建 ustore 表，插入初始数据
#   2. Session 1：开启长事务，循环 UPDATE 全表（每轮 val=val+1）
#   3. 并发扫描：每轮 UPDATE 后，测量全表扫描耗时
#   4. 随着更新轮次增加，SELECT 耗时逐步增长
#   5. 检查 "fetch undo record" 等待事件
#   6. COMMIT 后，undo chain 截断，扫描恢复
#
# 适用于 GaussDB / OpenGauss（PostgreSQL 无 undo 机制）
#

DB_TYPE="opengauss"
DB_HOST="localhost"
DB_PORT=""
DB_NAME="postgres"
DB_USER=""
DB_PASS=""
DB_CLIENT=""
TABLE_NAME="fur_test"
ROW_COUNT=1000
UPDATE_ROUNDS=20
SCAN_CLIENTS=2
SCAN_INTERVAL=3

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

OpenGauss/GaussDB "fetch undo record" wait event reproduction test.

Principle: A long transaction continuously updates rows, extending the undo chain.
Other sessions doing full table scans must traverse the undo chain for consistent
read, causing "fetch undo record" wait events and progressively slower queries.

Options:
    -t TYPE     Database type: gaussdb/opengauss (default: opengauss)
    -h HOST     Database host (default: localhost)
    -p PORT     Database port (default: 8000 for gaussdb, 5433 for opengauss)
    -d DB       Database name (default: postgres)
    -U USER     Database user (default: root for gaussdb, gaussdb for opengauss)
    -W PASS     Database password
    -r ROWS     Number of initial rows (default: 1000)
    -R ROUNDS   Number of update rounds in long transaction (default: 20)
    -C CLIENTS  Concurrent scan clients per round (default: 2)
    -I INTERVAL Seconds between scans (default: 3)

Examples:
    $0 -t opengauss -h localhost -p 5433 -U gaussdb -W 'Enmotech@123'
    $0 -t gaussdb -h localhost -p 8000 -U root -W 'Pass@123' -r 5000 -R 30
    $0 -t opengauss -h localhost -p 5433 -U gaussdb -W 'Enmotech@123' -r 10000 -R 50 -C 4 -I 5
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
        gaussdb)   DB_PORT=${DB_PORT:-8000}; DB_USER=${DB_USER:-root} ;;
        opengauss) DB_PORT=${DB_PORT:-5433}; DB_USER=${DB_USER:-gaussdb} ;;
    esac
}

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

# Measure scan time in milliseconds using shell timing
measure_scan_ms() {
    local start_ns end_ns elapsed_ms
    start_ns=$(date +%s%N)
    db_exec "SELECT * FROM $TABLE_NAME;" > /dev/null 2>&1
    end_ns=$(date +%s%N)
    elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
    echo "$elapsed_ms"
}

# Check "fetch undo record" wait event count in pg_stat_activity
check_fur_wait_count() {
    db_query "
        SELECT count(*)
        FROM pg_stat_activity
        WHERE wait_event = 'fetch undo record';
    " | head -1 | tr -d ' \n'
}

# Check historical undo-related wait events from dbe_perf
check_wait_history() {
    db_query "
        SELECT event_name, total_waits
        FROM dbe_perf.wait_events
        WHERE event_name LIKE '%undo%'
        ORDER BY total_waits DESC;
    " 2>/dev/null | head -5
}

while getopts "t:h:p:d:U:W:r:R:C:I:" opt; do
    case $opt in
        t) DB_TYPE="$OPTARG" ;;
        h) DB_HOST="$OPTARG" ;;
        p) DB_PORT="$OPTARG" ;;
        d) DB_NAME="$OPTARG" ;;
        U) DB_USER="$OPTARG" ;;
        W) DB_PASS="$OPTARG" ;;
        r) ROW_COUNT="$OPTARG" ;;
        R) UPDATE_ROUNDS="$OPTARG" ;;
        C) SCAN_CLIENTS="$OPTARG" ;;
        I) SCAN_INTERVAL="$OPTARG" ;;
        *) usage ;;
    esac
done

set_defaults
detect_client

RESULT_FILE="/tmp/fur_results_$$.csv"

echo ""
echo "============================================================"
echo "  UStore 'fetch undo record' Wait Event Reproduction Test"
echo "============================================================"
echo "Database:      $DB_TYPE ($DB_HOST:$DB_PORT/$DB_NAME)"
echo "User:          $DB_USER"
echo "Client:        $DB_CLIENT"
echo "Table:         $TABLE_NAME (ustore)"
echo "Rows:          $ROW_COUNT"
echo "Update rounds: $UPDATE_ROUNDS (in single long transaction)"
echo "Scan clients:  $SCAN_CLIENTS concurrent"
echo "Scan interval: $SCAN_INTERVAL seconds"
echo "============================================================"
echo ""

# ── Step 1: Check version ──
log_step "1/6: Checking database version"
DB_VER=$(db_query "SELECT version();" | head -1)
echo "  $DB_VER"

if ! echo "$DB_VER" | grep -qi "opengauss\|gaussdb"; then
    log_warn "This test requires OpenGauss/GaussDB with UStore."
fi

# ── Step 2: Check UStore config ──
log_step "2/6: Checking UStore and undo configuration"
ENABLE_USTORE=$(db_query "SELECT setting FROM pg_settings WHERE name = 'enable_ustore';" | head -1 | tr -d ' ')
if [ "$ENABLE_USTORE" != "on" ]; then
    log_warn "enable_ustore is '$ENABLE_USTORE', attempting to set 'on'..."
    db_exec "ALTER SYSTEM SET enable_ustore = on;"
    db_exec "SELECT pg_reload_conf();"
    sleep 2
    ENABLE_USTORE=$(db_query "SELECT setting FROM pg_settings WHERE name = 'enable_ustore';" | head -1 | tr -d ' ')
    if [ "$ENABLE_USTORE" != "on" ]; then
        log_error "Failed to enable UStore. Aborting."
        exit 1
    fi
fi
log_info "  enable_ustore = $ENABLE_USTORE"

UNDO_ZONES=$(db_query "SELECT setting FROM pg_settings WHERE name = 'undo_zones';" | head -1 | tr -d ' ')
log_info "  undo_zones = $UNDO_ZONES"

# ── Step 3: Create test table ──
log_step "3/6: Creating ustore test table"

db_exec "DROP TABLE IF EXISTS $TABLE_NAME CASCADE;"
db_exec "CREATE TABLE $TABLE_NAME (id INT PRIMARY KEY, val INT, data TEXT) WITH (STORAGE_TYPE = USTORE);"

# Insert initial data
BATCH_SIZE=500
REMAINING=$ROW_COUNT
BATCH_NUM=0
while [ "$REMAINING" -gt 0 ]; do
    BATCH_NUM=$((BATCH_NUM + 1))
    INSERT_COUNT=$(( REMAINING > BATCH_SIZE ? BATCH_SIZE : REMAINING ))
    START_ID=$(( (BATCH_NUM - 1) * BATCH_SIZE + 1 ))

    VALUES=""
    for i in $(seq $START_ID $((START_ID + INSERT_COUNT - 1))); do
        [ -n "$VALUES" ] && VALUES="$VALUES, "
        VALUES="$VALUES($i, 0, 'data_$i')"
    done

    db_exec "INSERT INTO $TABLE_NAME VALUES $VALUES;"
    REMAINING=$((REMAINING - INSERT_COUNT))
    log_info "  Batch $BATCH_NUM: inserted $INSERT_COUNT rows (total: $((ROW_COUNT - REMAINING))/$ROW_COUNT)"
done

db_exec "VACUUM ANALYZE $TABLE_NAME;"
ROW_ACTUAL=$(db_query "SELECT count(*) FROM $TABLE_NAME;" | head -1 | tr -d ' ')
log_info "  Table created with $ROW_ACTUAL rows"

# ── Step 4: Baseline scan measurement ──
log_step "4/6: Measuring baseline scan performance (3 samples)"

BASELINE_SAMPLES=""
for i in 1 2 3; do
    MS=$(measure_scan_ms)
    BASELINE_SAMPLES="$BASELINE_SAMPLES $MS"
    log_info "  Sample $i: ${MS}ms"
    sleep 1
done

# Calculate average baseline
BASELINE_AVG=$(echo $BASELINE_SAMPLES | awk '{s=0; for(i=1;i<=NF;i++) s+=$i; print s/NF}')
log_info "  Baseline average: ${BASELINE_AVG}ms"

echo "round,scan_ms,baseline_ms,ratio,fur_wait_count" > "$RESULT_FILE"

# ── Step 5: Long-txn update + concurrent scan ──
log_step "5/6: Running long-txn update + concurrent scan test"

echo ""
echo -e "${CYAN}  ┌─────────────────────────────────────────────────────────┐"
echo -e "  │ Long transaction: BEGIN → UPDATE val+1 × $UPDATE_ROUNDS rounds     │"
echo -e "  │ Concurrent scans: measure SELECT * each round                     │"
echo -e "  │ Expected: scan time increases as undo chain grows                │"
echo -e "  └─────────────────────────────────────────────────────────────────┘${NC}"
echo ""

# Start the long transaction updater as a background process
# We use a separate session: BEGIN, then repeatedly UPDATE
UPDATER_PIPE="/tmp/fur_updater_pipe_$$"
rm -f "$UPDATER_PIPE"
mkfifo "$UPDATER_PIPE"

# Start updater session reading from pipe
(eval "$(build_conn "-q")" < "$UPDATER_PIPE" 2>&1 | grep -v "^gsql:" > /dev/null) &
UPDATER_PID=$!

# Open pipe for writing
exec 3>"$UPDATER_PIPE"

# Send BEGIN
echo "BEGIN;" >&3
sleep 1

# Verify transaction is active
TXN_STATUS=$(db_query "
    SELECT state FROM pg_stat_activity
    WHERE pid != pg_backend_pid() AND query LIKE '%BEGIN%' AND usename = '$DB_USER'
    ORDER BY state_change DESC LIMIT 1;
" | head -1 | tr -d ' \n')
log_info "  Long transaction started (updater PID: $UPDATER_PID)"

echo ""

for ROUND in $(seq 1 $UPDATE_ROUNDS); do
    # ── Updater: UPDATE all rows ──
    echo "UPDATE $TABLE_NAME SET val = val + 1;" >&3
    sleep 0.5

    # ── Wait for update to process ──
    sleep "$SCAN_INTERVAL"

    # ── Measure scan performance ──
    SCAN_MS=$(measure_scan_ms)

    # ── Check "fetch undo record" wait events ──
    FUR_COUNT=$(check_fur_wait_count)

    # ── Calculate slowdown ratio ──
    RATIO=$(echo "scale=1; $SCAN_MS / $BASELINE_AVG" | bc 2>/dev/null || echo "?")

    echo -e "  ${CYAN}Round $ROUND/${UPDATE_ROUNDS}${NC}: scan=${SCAN_MS}ms | baseline=${BASELINE_AVG}ms | ${RATIO}x | fur_wait=${FUR_COUNT}"
    echo "$ROUND,$SCAN_MS,$BASELINE_AVG,$RATIO,$FUR_COUNT" >> "$RESULT_FILE"

    # ── Additional concurrent scans ──
    if [ "$SCAN_CLIENTS" -gt 1 ]; then
        for CID in $(seq 2 $SCAN_CLIENTS); do
            ( db_exec "SELECT * FROM $TABLE_NAME;" > /dev/null 2>&1 ) &
        done
        wait
    fi
done

# ── Commit the long transaction ──
echo "COMMIT;" >&3
sleep 1
exec 3>&-

# ── Post-commit measurement ──
log_info "  Long transaction COMMITTED"
sleep 2

POST_MS=$(measure_scan_ms)
POST_RATIO=$(echo "scale=1; $POST_MS / $BASELINE_AVG" | bc 2>/dev/null || echo "?")
log_info "  Post-commit scan: ${POST_MS}ms (baseline: ${BASELINE_AVG}ms, ${POST_RATIO}x)"

# ── Step 6: Check wait events ──
log_step "6/6: Checking wait event statistics"

echo ""
echo -e "${CYAN}  pg_stat_activity undo wait events:${NC}"
FUR_CURRENT=$(check_fur_wait_count)
if [ "$FUR_CURRENT" != "0" ] && [ -n "$FUR_CURRENT" ]; then
    log_info "  Current 'fetch undo record' wait count: $FUR_CURRENT"
else
    log_info "  No active 'fetch undo record' waits (expected after COMMIT)"
fi

echo ""
echo -e "${CYAN}  dbe_perf.wait_events historical stats:${NC}"
WAIT_HIST=$(check_wait_history)
if [ -n "$WAIT_HIST" ]; then
    echo "$WAIT_HIST"
else
    log_warn "  dbe_perf.wait_events not available or no undo events recorded"
fi

# ── Cleanup background process ──
[ -n "$UPDATER_PID" ] && kill "$UPDATER_PID" 2>/dev/null
rm -f "$UPDATER_PIPE"

# ── Summary ──
echo ""
echo "============================================================"
echo "  Test Summary"
echo "============================================================"
echo ""

echo -e "${CYAN}  Scan time trend:${NC}"
echo ""
printf "  %-8s %-12s %-12s %-8s %-10s\n" "Round" "Scan(ms)" "Baseline(ms)" "Ratio" "FUR_wait"
printf "  %-8s %-12s %-12s %-8s %-10s\n" "------" "--------" "------------" "------" "--------"
printf "  %-8s %-12s %-12s %-8s %-10s\n" "base" "${BASELINE_AVG}" "${BASELINE_AVG}" "1.0" "0"

while IFS=',' read -r round scan base ratio fur; do
    [ "$round" = "round" ] && continue
    printf "  %-8s %-12s %-12s %-8s %-10s\n" "$round" "$scan" "$base" "${ratio}x" "$fur"
done < "$RESULT_FILE"

printf "  %-8s %-12s %-12s %-8s %-10s\n" "post" "$POST_MS" "${BASELINE_AVG}" "${POST_RATIO}x" "0"

# Determine result
LAST_SCAN=$(tail -1 "$RESULT_FILE" | cut -d',' -f2)
if [ -n "$LAST_SCAN" ] && [ "$LAST_SCAN" -gt "$BASELINE_AVG" ]; then
    echo ""
    log_info "SUCCESS: Scan degraded from ${BASELINE_AVG}ms → ${LAST_SCAN}ms during long-txn updates"
    log_info "  Root cause: each UPDATE adds undo record → undo chain grows"
    log_info "  → SELECT must traverse undo chain for consistent read"
    log_info "  → 'fetch undo record' wait event appears, scan time increases"
    if [ "$POST_MS" -lt "$LAST_SCAN" ]; then
        log_info "  After COMMIT: scan recovered to ${POST_MS}ms (undo chain truncated)"
    fi
else
    echo ""
    log_warn "Scan time did not significantly increase."
    log_warn "Try: increase -R (update rounds) or -r (rows) for more undo chain depth"
fi

rm -f "$RESULT_FILE"