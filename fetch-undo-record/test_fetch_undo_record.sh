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
#   1. 创建 ustore 表 (20000行 × 3KB宽度)，插入初始数据
#   2. 启动后台 updater：BEGIN → 逐轮 UPDATE val+1 → pg_sleep 保持事务
#   3. 每轮 UPDATE 后测量全表扫描耗时
#   4. 随着更新轮次增加，SELECT 耗时从 ~1.6s 逐步增长到 ~10s+
#   5. COMMIT 后 undo chain 截断，扫描恢复基线 (~1.6s)
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
ROW_COUNT=20000
DATA_WIDTH=3000
UPDATE_ROUNDS=35
SCAN_INTERVAL=5

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

Demonstrates progressive query degradation caused by undo chain traversal
in Ustore's undo-based MVCC. Default parameters produce ~10s peak scan time.

Options:
    -t TYPE     Database type: gaussdb/opengauss (default: opengauss)
    -h HOST     Database host (default: localhost)
    -p PORT     Database port (default: 8000 for gaussdb, 5433 for opengauss)
    -d DB       Database name (default: postgres)
    -U USER     Database user (default: root for gaussdb, gaussdb for opengauss)
    -W PASS     Database password
    -r ROWS     Number of rows (default: 20000)
    -w WIDTH    Data width in bytes per row (default: 3000)
    -R ROUNDS   Update rounds in long transaction (default: 35)
    -I INTERVAL Seconds between scan measurements (default: 5)

Examples:
    $0 -t opengauss -h localhost -p 5433 -U gaussdb -W 'Enmotech@123'
    $0 -t gaussdb -h localhost -p 8000 -U root -W 'Pass@123'
    $0 -t opengauss -h localhost -p 5433 -U gaussdb -W 'Enmotech@123' -r 50000 -R 30 -w 3000
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
    eval "$(build_conn "-q -c \"$sql\"")" 2>&1 \
        | grep -v "^ALTER\|^pg_reload\|^SET\|^DROP\|^CREATE\|^INSERT\|^NOTICE\|^gsql:\|^DO\|^Password\|^You\|^Line\|^UPDATE" || true
}

db_query() {
    local sql="$1"
    eval "$(build_conn "-t -A -c \"$sql\"")" 2>&1 \
        | grep -v "^Password\|^You\|^Line\|^gsql:" || true
}

measure_scan_ms() {
    local start_ns end_ns elapsed_ms
    start_ns=$(date +%s%N)
    db_exec "SELECT * FROM $TABLE_NAME;" > /dev/null 2>&1
    end_ns=$(date +%s%N)
    elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
    echo "$elapsed_ms"
}

while getopts "t:h:p:d:U:W:r:w:R:I:" opt; do
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
        I) SCAN_INTERVAL="$OPTARG" ;;
        *) usage ;;
    esac
done

set_defaults
detect_client

RESULT_FILE="/tmp/fur_results_$$.csv"
UPDATER_SQL="/tmp/fur_updater_$$.sql"

echo ""
echo "============================================================"
echo "  UStore 'fetch undo record' Wait Event Reproduction Test"
echo "============================================================"
echo "Database:      $DB_TYPE ($DB_HOST:$DB_PORT/$DB_NAME)"
echo "User:          $DB_USER"
echo "Client:        $DB_CLIENT"
echo "Table:         $TABLE_NAME (ustore, $ROW_COUNT rows × ${DATA_WIDTH}B)"
echo "Update rounds: $UPDATE_ROUNDS (in single long transaction, ~10s peak expected)"
echo "Scan interval: $SCAN_INTERVAL seconds"
echo "============================================================"
echo ""

# ── Step 1 ──
log_step "1/6: Checking database version"
DB_VER=$(db_query "SELECT version();" | head -1)
echo "  $DB_VER"

# ── Step 2 ──
log_step "2/6: Checking UStore configuration"
ENABLE_USTORE=$(db_query "SELECT setting FROM pg_settings WHERE name = 'enable_ustore';" | head -1 | tr -d ' ')
if [ "$ENABLE_USTORE" != "on" ]; then
    log_warn "enable_ustore='$ENABLE_USTORE', setting to 'on'..."
    db_exec "ALTER SYSTEM SET enable_ustore = on; SELECT pg_reload_conf();"
    sleep 2
fi
log_info "  enable_ustore = $ENABLE_USTORE"

# ── Step 3 ──
log_step "3/6: Creating ustore test table ($ROW_COUNT rows × ${DATA_WIDTH}B)"
db_exec "DROP TABLE IF EXISTS $TABLE_NAME CASCADE;"
db_exec "CREATE TABLE $TABLE_NAME (id INT PRIMARY KEY, val INT, data TEXT) WITH (STORAGE_TYPE = USTORE);"
db_exec "INSERT INTO $TABLE_NAME SELECT g, 0, repeat('x', $DATA_WIDTH) FROM generate_series(1, $ROW_COUNT) g;"
db_exec "VACUUM ANALYZE $TABLE_NAME;"
ROW_ACTUAL=$(db_query "SELECT count(*) FROM $TABLE_NAME;" | head -1 | tr -d ' ')
log_info "  Created $ROW_ACTUAL rows"

# ── Step 4 ──
log_step "4/6: Baseline scan (3 samples)"
BASELINE_SAMPLES=""
for i in 1 2 3; do
    MS=$(measure_scan_ms)
    BASELINE_SAMPLES="$BASELINE_SAMPLES $MS"
    log_info "  Sample $i: ${MS}ms"
    sleep 1
done
BASELINE_AVG=$(echo $BASELINE_SAMPLES | awk '{s=0; for(i=1;i<=NF;i++) s+=$i; print int(s/NF)}')
BASELINE_SEC=$(echo "scale=1; $BASELINE_AVG / 1000" | bc 2>/dev/null || echo "?")
log_info "  Average baseline: ${BASELINE_AVG}ms (${BASELINE_SEC}s)"

echo "round,scan_ms,baseline_ms,ratio" > "$RESULT_FILE"

# ── Step 5 ──
log_step "5/6: Long transaction UPDATE + concurrent scan"

echo ""
echo -e "${CYAN}  Strategy:${NC}"
echo -e "${CYAN}    Background session: BEGIN → $UPDATE_ROUNDS UPDATEs → pg_sleep → COMMIT${NC}"
echo -e "${CYAN}    Main script: measures SELECT * after each UPDATE round${NC}"
echo -e "${CYAN}    Expected: scan time grows from ~${BASELINE_SEC}s to ~10s${NC}"
echo ""

# Build updater SQL
{
    echo "BEGIN;"
    for R in $(seq 1 $UPDATE_ROUNDS); do
        echo "UPDATE $TABLE_NAME SET val = val + 1;"
        echo "SELECT pg_sleep($SCAN_INTERVAL);"
    done
    echo "SELECT pg_sleep(10);"
    echo "COMMIT;"
} > "$UPDATER_SQL"

UPDATER_TIMEOUT=$(( UPDATE_ROUNDS * SCAN_INTERVAL * 4 + 120 ))

log_info "  Starting updater (timeout: ${UPDATER_TIMEOUT}s)"

if [ "$DB_CLIENT" = "gsql" ]; then
    if [ -n "$DB_PASS" ]; then
        timeout "$UPDATER_TIMEOUT" gsql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -W "$DB_PASS" -d "$DB_NAME" -q -f "$UPDATER_SQL" > /dev/null 2>&1 &
    else
        timeout "$UPDATER_TIMEOUT" gsql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -q -f "$UPDATER_SQL" > /dev/null 2>&1 &
    fi
else
    local_ep=$(url_encode "${DB_PASS}")
    timeout "$UPDATER_TIMEOUT" psql "postgresql://${DB_USER}:${local_ep}@${DB_HOST}:${DB_PORT}/${DB_NAME}" -q -f "$UPDATER_SQL" > /dev/null 2>&1 &
fi
UPDATER_PID=$!
log_info "  Updater PID: $UPDATER_PID"

# Wait for first UPDATE + first pg_sleep
sleep $((SCAN_INTERVAL + 2))

echo ""

for ROUND in $(seq 1 $UPDATE_ROUNDS); do
    # Measure
    SCAN_MS=$(measure_scan_ms)
    SCAN_SEC=$(echo "scale=1; $SCAN_MS / 1000" | bc 2>/dev/null || echo "?")
    RATIO=$(echo "scale=1; $SCAN_MS / $BASELINE_AVG" | bc 2>/dev/null || echo "?")

    # Check updater after measurement
    if ! kill -0 "$UPDATER_PID" 2>/dev/null; then
        echo -e "  ${GREEN}Round $ROUND (COMMITTED)${NC}: scan=${SCAN_MS}ms (${SCAN_SEC}s) | base=${BASELINE_AVG}ms (${BASELINE_SEC}s) | ${RATIO}x"
        echo "$ROUND,$SCAN_MS,$BASELINE_AVG,$RATIO" >> "$RESULT_FILE"
        log_info "  Updater COMMITTED — undo chains truncated, scan recovering"
        break
    fi

    echo -e "  ${CYAN}Round $ROUND/$UPDATE_ROUNDS${NC}: scan=${SCAN_MS}ms (${SCAN_SEC}s) | base=${BASELINE_AVG}ms (${BASELINE_SEC}s) | ${RATIO}x"
    echo "$ROUND,$SCAN_MS,$BASELINE_AVG,$RATIO" >> "$RESULT_FILE"

    sleep "$SCAN_INTERVAL"
done

# Wait for updater COMMIT
log_info "  Waiting for updater COMMIT..."
wait "$UPDATER_PID" 2>/dev/null
sleep 5

POST_MS=$(measure_scan_ms)
POST_SEC=$(echo "scale=1; $POST_MS / 1000" | bc 2>/dev/null || echo "?")
POST_RATIO=$(echo "scale=1; $POST_MS / $BASELINE_AVG" | bc 2>/dev/null || echo "?")
log_info "  Post-commit: ${POST_MS}ms (${POST_SEC}s, ${POST_RATIO}x baseline)"

# Wait for undo cleanup
log_info "  Waiting 15s for undo cleanup..."
sleep 15
CLEANUP_MS=$(measure_scan_ms)
CLEANUP_SEC=$(echo "scale=1; $CLEANUP_MS / 1000" | bc 2>/dev/null || echo "?")
CLEANUP_RATIO=$(echo "scale=1; $CLEANUP_MS / $BASELINE_AVG" | bc 2>/dev/null || echo "?")
log_info "  After cleanup: ${CLEANUP_MS}ms (${CLEANUP_SEC}s, ${CLEANUP_RATIO}x baseline)"

# ── Step 6 ──
log_step "6/6: Checking wait events"

echo ""
echo -e "${CYAN}  Undo-related wait events (pg_thread_wait_status):${NC}"
db_query "
    SELECT wait_event, count(*)
    FROM pg_thread_wait_status
    WHERE wait_event LIKE '%undo%'
      AND db_name = '$DB_NAME'
    GROUP BY wait_event;
" 2>/dev/null | head -5

echo ""
echo -e "${CYAN}  Non-none wait events (pg_thread_wait_status):${NC}"
db_query "
    SELECT wait_status, wait_event, count(*)
    FROM pg_thread_wait_status
    WHERE wait_status != 'none'
      AND db_name = '$DB_NAME'
    GROUP BY wait_status, wait_event
    ORDER BY count(*) DESC;
" 2>/dev/null | head -5

# ── Cleanup ──
db_exec "DROP TABLE IF EXISTS $TABLE_NAME CASCADE;" 2>/dev/null

# ── Summary ──
echo ""
echo "============================================================"
echo "  Test Summary"
echo "============================================================"
echo ""

echo -e "${CYAN}  Scan time trend (baseline → peak → recovery):${NC}"
echo ""
printf "  %-8s %-12s %-10s %-8s\n" "Round" "Scan(ms)" "Scan(s)" "Ratio"
printf "  %-8s %-12s %-10s %-8s\n" "------" "--------" "------" "------"
printf "  %-8s %-12s %-10s %-8s\n" "base" "${BASELINE_AVG}" "${BASELINE_SEC}" "1.0x"

while IFS=',' read -r round scan base ratio; do
    [ "$round" = "round" ] && continue
    sec=$(echo "scale=1; $scan / 1000" | bc 2>/dev/null || echo "?")
    printf "  %-8s %-12s %-10s %-8s\n" "$round" "$scan" "$sec" "${ratio}x"
done < "$RESULT_FILE"

printf "  %-8s %-12s %-10s %-8s\n" "commit" "$POST_MS" "$POST_SEC" "${POST_RATIO}x"
printf "  %-8s %-12s %-10s %-8s\n" "cleanup" "$CLEANUP_MS" "$CLEANUP_SEC" "${CLEANUP_RATIO}x"

PEAK_SCAN=$(grep -v "^round" "$RESULT_FILE" | cut -d',' -f2 | sort -n | tail -1)
PEAK_ROUND=$(grep -v "^round" "$RESULT_FILE" | awk -F',' -v peak="$PEAK_SCAN" '$2 == peak {print $1}')
if [ -n "$PEAK_SCAN" ] && [ "$PEAK_SCAN" -gt "$((BASELINE_AVG * 2))" ]; then
    PEAK_SEC=$(echo "scale=1; $PEAK_SCAN / 1000" | bc 2>/dev/null || echo "?")
    PEAK_RATIO=$(echo "scale=1; $PEAK_SCAN / $BASELINE_AVG" | bc 2>/dev/null || echo "?")
    echo ""
    log_info "SUCCESS: Scan degraded from ${BASELINE_AVG}ms (${BASELINE_SEC}s) → ${PEAK_SCAN}ms (${PEAK_SEC}s) at round ${PEAK_ROUND}"
    log_info "  Peak ratio: ${PEAK_RATIO}x baseline"
    log_info "  Root cause: long-txn UPDATE extends undo chain →"
    log_info "  SELECT traverses undo chain for consistent read →"
    log_info "  'fetch undo record' wait, scan time increases"
    if [ "$CLEANUP_MS" -lt "$PEAK_SCAN" ]; then
        CLEANUP_SEC=$(echo "scale=1; $CLEANUP_MS / 1000" | bc 2>/dev/null || echo "?")
        log_info "  After undo cleanup: recovered to ${CLEANUP_MS}ms (${CLEANUP_SEC}s)"
    fi
else
    echo ""
    log_warn "Scan time did not significantly increase (peak ${PEAK_SCAN}ms < 2x baseline ${BASELINE_AVG}ms)."
    log_warn "Try: increase -R (rounds), -r (rows), or -w (data width)"
fi

rm -f "$UPDATER_SQL"