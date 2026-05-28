#!/bin/bash
#
# test_wait_available_td.sh — Progressive TD contention degradation test
#
# 原理：
#   Ustore 将 Astore 中每行 tuple 上的事务信息 (xmin/xmax) 统一移到页面级，
#   存储在 Transaction Directory (TD) 中。默认每页只有 4 个 TD 槽位。
#
#   TD 动态扩展：当 4 个 TD 不够时，OpenGauss 会从页面空闲空间分配更多 TD。
#   "wait available td" 只在页面空闲空间耗尽、TD 扩展失败时才会出现。
#
#   STORAGE PLAIN + 大行宽 → 页面空闲空间极小 → TD 扩展受限。
#   随着并发事务增加，TD 槽位被占用 + 行锁级联阻塞 → SQL 执行从毫秒级退化到 10s+。
#
#   测试方法：逐轮增加并发（0 到 MAX_CONCURRENCY）。
#   FG 与部分 BG 共享同页同行 → 行锁级联阻塞（每波 +HOLD_SECS 延迟）。
#   随并发增加，共享行的 BG 数增多 → 级联层数增加 → FG 延迟递增。
#   同时监控 "wait available td" 等待事件（TD 扩展失败时出现）。
#
# 适用于 OpenGauss / GaussDB（PostgreSQL 无 Ustore）
#

DB_TYPE="opengauss"
DB_HOST="localhost"
DB_PORT=""
DB_NAME="postgres"
DB_USER=""
DB_PASS=""
DB_CLIENT=""
VERBOSE=0
TABLE_NAME="td_test"
HOLD_SECS=5
MAX_CONCURRENCY=12
SCAN_GAP=1
ROUND_TIMEOUT=120

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

OpenGauss/GaussDB Ustore TD progressive contention degradation test.

Shows how increasing concurrent transactions on a nearly-full Ustore page
causes SQL latency to degrade from ms to 10s+ due to TD/row-lock cascading.

Options:
    -t TYPE     Database type: opengauss/gaussdb (default: opengauss)
    -h HOST     Database host (default: localhost)
    -p PORT     Database port (default: 5433 for opengauss, 8000 for gaussdb)
    -d DB       Database name (default: postgres)
    -U USER     Database user
    -W PASS     Database password
    -T TABLE    Table name (default: td_test)
    -V          Verbose: print each SQL statement before execution
    -H SECS     Seconds for BG transactions to hold locks (default: 5)
    -C N        Max BG concurrency to test, rounds 0..N (default: 12)

Examples:
    $0 -t opengauss -h localhost -p 5433 -U gaussdb -W 'Enmotech@123'
    $0 -t gaussdb -h localhost -p 8000 -U root -W 'Pass@123'
    $0 -t opengauss -h localhost -p 5433 -U gaussdb -W 'Enmotech@123' -H 10 -C 8 -V
EOF
    exit 1
}

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }
log_sql() {
    [ "$VERBOSE" -eq 1 ] && echo -e "${CYAN}[SQL]${NC} $1" >&2
}
log_sql_err() {
    local caller_fn="$1" caller_line="$2" err_msg="$3" sql="$4"
    echo -e "${RED}[SQL ERROR]${NC} ${caller_fn}() line ${caller_line}: ${err_msg}"
    echo -e "${RED}[SQL]${NC} ${sql}"
}

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
        *) log_error "Unsupported type: $DB_TYPE. This test requires OpenGauss/GaussDB with Ustore."; exit 1 ;;
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
    local stop="-v ON_ERROR_STOP=1"
    if [ "$DB_CLIENT" = "gsql" ]; then
        if [ -n "$DB_PASS" ]; then
            echo "gsql ${stop} -h $DB_HOST -p $DB_PORT -U $DB_USER -W '$DB_PASS' -d $DB_NAME $extra"
        else
            echo "gsql ${stop} -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME $extra"
        fi
    else
        if [ -n "$DB_PASS" ]; then
            local ep=$(url_encode "$DB_PASS")
            echo "psql ${stop} postgresql://${DB_USER}:${ep}@${DB_HOST}:${DB_PORT}/${DB_NAME} $extra"
        else
            echo "psql ${stop} -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME $extra"
        fi
    fi
}

db_exec() {
    local sql="$1"
    local caller_fn="${FUNCNAME[1]}"
    local caller_line="${BASH_LINENO[0]}"
    log_sql "db_exec (line $caller_line): $sql"
    local err_file="/tmp/watd_exec_err_$$_${caller_line}"
    eval "$(build_conn "-q -c \"$sql\"")" > /dev/null 2>"$err_file"
    if [ -s "$err_file" ]; then
        local err_msg=$(grep -v "^Password\|^You\|^NOTICE\|^ALTER\|^SET\|^pg_reload\|^DO\|^gsql:" "$err_file" 2>/dev/null)
        if [ -n "$err_msg" ]; then
            log_sql_err "db_exec" "$caller_line" "$err_msg" "$sql"
        fi
    fi
    rm -f "$err_file"
}

db_query() {
    local sql="$1"
    local caller_fn="${FUNCNAME[1]}"
    local caller_line="${BASH_LINENO[0]}"
    log_sql "db_query (line $caller_line): $sql"
    local out_file="/tmp/watd_query_out_$$_${caller_line}"
    local err_file="/tmp/watd_query_err_$$_${caller_line}"
    eval "$(build_conn "-t -A -c \"$sql\"")" > "$out_file" 2>"$err_file"
    if [ -s "$err_file" ]; then
        local err_msg=$(grep -v "^Password\|^You\|^NOTICE\|^gsql:" "$err_file" 2>/dev/null)
        if [ -n "$err_msg" ]; then
            log_sql_err "db_query" "$caller_line" "$err_msg" "$sql"
        fi
    fi
    rm -f "$err_file"
    cat "$out_file" | grep -v "^Password\|^You\|^Line\|^gsql:\|^gaussdb\|^$\|^NOTICE\|^WARNING\|^ALTER\|^SET\|^DROP\|^CREATE\|^INSERT\|^VACUUM\|^DO\|^HINT\|^DETAIL\|^CONTEXT\|^timestamp\|^Time\|^Format\|^Server"
    rm -f "$out_file"
}

bg_sql() {
    local sql="$1" tag="$2"
    local caller_line="${BASH_LINENO[0]}"
    log_sql "bg_sql (line $caller_line): bg-$tag: $sql"
    eval "$(build_conn "-c \"$sql\"")" >"/tmp/watd_${tag}.out" 2>"/tmp/watd_${tag}.err" &
    echo $!
}

detect_wait_view() {
    local has_tw=$(db_query "SELECT count(*) FROM information_schema.columns WHERE table_name='pg_thread_wait_status' AND column_name='wait_event';" 2>/dev/null | head -1 | tr -d ' ')
    if [ "$has_tw" -gt 0 ] 2>/dev/null; then
        WAIT_VIEW="pg_thread_wait_status"
    else
        WAIT_VIEW="pg_stat_activity"
    fi
}

setup_table() {
    db_exec "DROP TABLE IF EXISTS ${TABLE_NAME} CASCADE;"
    db_exec "CREATE TABLE ${TABLE_NAME} (id INT PRIMARY KEY, val INT, data VARCHAR(2000)) WITH (STORAGE_TYPE = USTORE, FILLFACTOR = 100);"
    db_exec "ALTER TABLE ${TABLE_NAME} ALTER COLUMN data SET STORAGE PLAIN;"
    db_exec "INSERT INTO ${TABLE_NAME} SELECT g, 0, repeat('x', 1540) FROM generate_series(1, 30) g;"
    db_exec "VACUUM ANALYZE ${TABLE_NAME};"

    local row_count=$(db_query "SELECT count(*) FROM ${TABLE_NAME};" | grep -E '^[0-9]+$' | head -1 | tr -d ' ')
    log_info "  Inserted $row_count rows"

    PAGE0_IDS=$(db_query "SELECT string_agg(id::text, ',' ORDER BY id) FROM (SELECT id FROM ${TABLE_NAME} WHERE ctid::text LIKE '(0,%' ORDER BY ctid LIMIT 8) s;" | grep -E '^[0-9,]+$' | head -1 | tr -d ' ')
    if [ -z "$PAGE0_IDS" ]; then
        log_error "No rows on page 0. Diagnostic:"
        diag=$(db_query "SELECT id, ctid FROM ${TABLE_NAME} ORDER BY id LIMIT 10;" 2>/dev/null)
        if [ -n "$diag" ]; then
            echo "  First 10 rows (id, ctid):"
            echo "$diag" | while read line; do echo "    $line"; done
        else
            echo "  Table may be empty or ctid format differs"
        fi
        db_exec "DROP TABLE IF EXISTS ${TABLE_NAME} CASCADE;"
        exit 1
    fi
    IFS=',' read -ra IDS <<< "$PAGE0_IDS"
    PAGE0_COUNT=${#IDS[@]}

    local ctid_info=$(db_query "SELECT id, ctid FROM ${TABLE_NAME} WHERE id IN (${PAGE0_IDS}) ORDER BY ctid;")
    echo "  Rows on page 0 ($PAGE0_COUNT rows):"
    echo "$ctid_info" | while read line; do echo "    $line"; done

    if [ "$PAGE0_COUNT" -lt 2 ]; then
        log_error "Need at least 2 rows on page 0 for row lock cascading test."
        db_exec "DROP TABLE IF EXISTS ${TABLE_NAME} CASCADE;"
        exit 1
    fi

    # FG shares row with first BG (IDS[0]) → row lock cascading
    FG_ROW=${IDS[0]}
    ALL_ROWS=(${IDS[@]})
    ALL_ROW_COUNT=${#ALL_ROWS[@]}
    log_info "  FG row: id=$FG_ROW (shared with BG0, BG5, BG10... → row lock cascading)"
    log_info "  All rows: ids=${ALL_ROWS[*]} ($ALL_ROW_COUNT rows, cycled for BG)"
}

fmt_elapsed() {
    local ms="$1"
    if [ "$ms" -lt 1000 ]; then
        echo "${ms}ms"
    else
        local s=$((ms / 1000))
        local frac=$((ms % 1000))
        printf "%d.%03ds" $s $frac
    fi
}

while getopts "t:h:p:d:U:W:T:VH:C:" opt; do
    case $opt in
        t) DB_TYPE="$OPTARG" ;;
        h) DB_HOST="$OPTARG" ;;
        p) DB_PORT="$OPTARG" ;;
        d) DB_NAME="$OPTARG" ;;
        U) DB_USER="$OPTARG" ;;
        W) DB_PASS="$OPTARG" ;;
        T) TABLE_NAME="$OPTARG" ;;
        V) VERBOSE=1 ;;
        H) HOLD_SECS="$OPTARG" ;;
        C) MAX_CONCURRENCY="$OPTARG" ;;
        *) usage ;;
    esac
done

set_defaults
detect_client

echo ""
echo "============================================================"
echo "  Ustore TD Progressive Contention Degradation Test"
echo "============================================================"
echo "Database:        $DB_TYPE ($DB_HOST:$DB_PORT/$DB_NAME)"
echo "User:            $DB_USER"
echo "Client:          $DB_CLIENT"
echo "Table:           $TABLE_NAME (ustore, STORAGE PLAIN)"
echo "Hold TD secs:    $HOLD_SECS"
echo "Max concurrency: $MAX_CONCURRENCY"
echo "============================================================"
echo ""

# ── Pre-check ──
log_step "Pre-check: Database version and key parameters"
DB_VER=$(db_query "SELECT version();" | head -1)
echo "  Version: $DB_VER"

MAX_CONN=$(db_query "SELECT setting FROM pg_settings WHERE name='max_connections';" | head -1 | tr -d ' ')
echo "  max_connections: ${MAX_CONN:-unknown}"
if [ -n "$MAX_CONN" ] && [ "$MAX_CONCURRENCY" -gt "$((MAX_CONN - 5))" ]; then
    log_warn "MAX_CONCURRENCY=$MAX_CONCURRENCY may exceed available connections (max=$MAX_CONN, need $MAX_CONCURRENCY+5)"
fi

STORAGE=$(db_query "SELECT setting FROM pg_settings WHERE name = 'enable_ustore';" | head -1 | tr -d ' ')
if [ "$STORAGE" != "on" ]; then
    log_warn "enable_ustore='$STORAGE', setting to 'on'..."
    db_exec "ALTER SYSTEM SET enable_ustore = on;"
    db_exec "SELECT pg_reload_conf();"
    sleep 1
fi
log_info "  enable_ustore = on"

# ── Initial setup ──
log_step "Setup: Create Ustore table (STORAGE PLAIN) and fill page"
setup_table

detect_wait_view
log_info "  Wait event view: $WAIT_VIEW"

# ── Progressive concurrency test ──
echo ""
log_step "Progressive concurrency test: rounds 0 to $MAX_CONCURRENCY"
echo "  Mechanism: FG shares row IDS[0] with BG0, BG5, BG10... → row lock cascading"
echo "  Each cascade wave adds ~HOLD_SECS to FG wait time"
echo "  BG: UPDATE row + pg_sleep($HOLD_SECS) → hold TD+row lock for $HOLD_SECS seconds"
echo "  FG: UPDATE IDS[0] → must wait for all prior holders → measure elapsed time"
echo ""

declare -a RES_CONCURRENCY
declare -a RES_ELAPSED_MS
declare -a RES_TD_FOUND
declare -a RES_TD_MAX
declare -a RES_CASCADES

TEST_START_S=$(date +%s)

for round in $(seq 0 $MAX_CONCURRENCY); do
    echo ""
    log_step "Round $round / $MAX_CONCURRENCY: $round BG holders + 1 FG"

    # Recreate table each round for consistent conditions
    setup_table

    # Count how many BGs share FG's row (IDS[0])
    # BGs at indices 0, ALL_ROW_COUNT, 2*ALL_ROW_COUNT, ... use IDS[0]
    cascade_count=0
    if [ $round -gt 0 ]; then
        for i in $(seq 0 $((round - 1))); do
            bg_row_idx=$((i % ALL_ROW_COUNT))
            if [ "${ALL_ROWS[$bg_row_idx]}" = "$FG_ROW" ]; then
                cascade_count=$((cascade_count + 1))
            fi
        done
    fi
    echo "  Cascade depth: $cascade_count BGs on FG row (IDS[0]) → expected ~$((cascade_count * HOLD_SECS))s wait"

    # Launch BG transactions
    BG_PIDS=""
    if [ $round -gt 0 ]; then
        for i in $(seq 0 $((round - 1))); do
            bg_row_idx=$((i % ALL_ROW_COUNT))
            bg_row=${ALL_ROWS[$bg_row_idx]}
            PID=$(bg_sql "BEGIN; UPDATE ${TABLE_NAME} SET val=val+1 WHERE id=${bg_row}; SELECT pg_sleep(${HOLD_SECS}); COMMIT;" "r${round}_bg${i}")
            BG_PIDS="$BG_PIDS $PID"
        done
        echo "  Launched $round BG transactions"

        # Wait for BGs to settle (use pg_stat_activity.query)
        settle=0
        settle_max=8
        while [ $settle -lt $settle_max ]; do
            bg_active=$(db_query "SELECT count(*) FROM pg_stat_activity WHERE state != 'idle' AND query LIKE '%pg_sleep%';" 2>/dev/null | head -1 | tr -d ' ')
            bg_active=${bg_active:-0}
            if [ "$bg_active" -ge "$round" ] 2>/dev/null; then
                log_info "  BG settled: $bg_active/$round pg_sleep sessions"
                break
            fi
            sleep 1
            settle=$((settle + 1))
        done
        if [ $settle -ge $settle_max ]; then
            log_warn "  BG settle timeout: $bg_active/$round active (proceeding anyway)"
        fi
    fi

    # Launch FG and measure elapsed time
    FG_START_NS=$(date +%s%N)
    FG_PID=$(bg_sql "BEGIN; UPDATE ${TABLE_NAME} SET val=val+1 WHERE id=${FG_ROW}; COMMIT;" "r${round}_fg")

    # Monitor FG completion and wait events
    FOUND_TD=0
    WAITS_MAX=0
    fg_done=0
    elapsed=0

    while [ $elapsed -lt $ROUND_TIMEOUT ]; do
        if ! kill -0 $FG_PID 2>/dev/null; then
            FG_END_NS=$(date +%s%N)
            fg_done=1
            break
        fi

        # Monitor wait events
        waits=$(db_query "SELECT count(*) FROM ${WAIT_VIEW} WHERE wait_event='wait available td';" 2>/dev/null | head -1 | tr -d ' ')
        waits=${waits:-0}
        if [ "$waits" -gt 0 ] 2>/dev/null; then
            FOUND_TD=1
            [ "$waits" -gt "$WAITS_MAX" ] && WAITS_MAX=$waits
            now_s=$(date +%s)
            abs_elapsed=$((now_s - TEST_START_S))
            echo "  [${abs_elapsed}s] 'wait available td' sessions: $waits"
        fi

        sleep $SCAN_GAP
        elapsed=$((elapsed + SCAN_GAP))
    done

    if [ $fg_done -eq 0 ]; then
        FG_END_NS=$(date +%s%N)
        log_warn "  FG timed out after $ROUND_TIMEOUT seconds"
        kill $FG_PID 2>/dev/null || true
        for pid in $BG_PIDS; do kill $pid 2>/dev/null || true; done
    fi

    FG_ELAPSED_MS=$(( (FG_END_NS - FG_START_NS) / 1000000 ))

    # Record results
    RES_CONCURRENCY[$round]=$round
    RES_ELAPSED_MS[$round]=$FG_ELAPSED_MS
    RES_TD_FOUND[$round]=$FOUND_TD
    RES_TD_MAX[$round]=$WAITS_MAX
    RES_CASCADES[$round]=$cascade_count

    echo "  FG elapsed: $(fmt_elapsed $FG_ELAPSED_MS)"
    if [ $FOUND_TD -eq 1 ]; then
        echo -e "  ${GREEN}'wait available td' observed (max: $WAITS_MAX)${NC}"
    else
        echo "  'wait available td' not observed (TD expansion succeeded or initial TDs available)"
    fi

    # Wait for all BG and FG to complete before next round
    for pid in $BG_PIDS; do wait $pid 2>/dev/null || true; done
    wait $FG_PID 2>/dev/null || true

    rm -f /tmp/watd_r${round}_bg*.out /tmp/watd_r${round}_bg*.err
    rm -f /tmp/watd_r${round}_fg.out /tmp/watd_r${round}_fg.err
done

# ── Cleanup ──
echo ""
log_step "Cleanup"
db_exec "DROP TABLE IF EXISTS ${TABLE_NAME} CASCADE;"
rm -f /tmp/watd_*.out /tmp/watd_*.err /tmp/watd_exec_err_* /tmp/watd_query_out_* /tmp/watd_query_err_*

# ── Degradation Report ──
echo ""
echo "============================================================"
echo "  Degradation Report"
echo "============================================================"
echo ""
printf "  %-4s | %-12s | %-6s | %-17s | %-10s\n" "BG#" "FG Elapsed" "Casc#" "wait avail td" "Max TD #"
printf "  %-4s | %-12s | %-6s | %-17s | %-10s\n" "----" "------------" "------" "---------------" "----------"

for round in $(seq 0 $MAX_CONCURRENCY); do
    conc=${RES_CONCURRENCY[$round]}
    ms=${RES_ELAPSED_MS[$round]}
    casc=${RES_CASCADES[$round]}
    td_found=${RES_TD_FOUND[$round]}
    td_max=${RES_TD_MAX[$round]}
    elapsed_str=$(fmt_elapsed $ms)
    td_str=$([ "$td_found" -eq 1 ] && echo "YES" || echo "NO")
    printf "  %-4s | %-12s | %-6s | %-17s | %-10s\n" "$conc" "$elapsed_str" "$casc" "$td_str" "$td_max"
done

# ── Summary ──
echo ""
echo "============================================================"
echo "  Summary"
echo "============================================================"

baseline_ms=${RES_ELAPSED_MS[0]}
peak_ms=${RES_ELAPSED_MS[$MAX_CONCURRENCY]}
baseline_str=$(fmt_elapsed $baseline_ms)
peak_str=$(fmt_elapsed $peak_ms)

if [ "$baseline_ms" -gt 0 ]; then
    deg_factor=$((peak_ms * 100 / baseline_ms))
    deg_x=$((deg_factor / 100))
fi

echo "  Baseline (0 concurrent):  $baseline_str"
echo "  Peak ($MAX_CONCURRENCY concurrent): $peak_str"
echo "  Degradation factor:       ${deg_x}x"

# Threshold milestones
first_1s=-1; first_5s=-1; first_10s=-1
for round in $(seq 0 $MAX_CONCURRENCY); do
    ms=${RES_ELAPSED_MS[$round]}
    if [ "$first_1s" -eq -1 ] && [ "$ms" -ge 1000 ]; then first_1s=$round; fi
    if [ "$first_5s" -eq -1 ] && [ "$ms" -ge 5000 ]; then first_5s=$round; fi
    if [ "$first_10s" -eq -1 ] && [ "$ms" -ge 10000 ]; then first_10s=$round; fi
done

echo ""
echo "  Threshold milestones:"
if [ "$first_1s" -ge 0 ]; then
    echo "    1s+ at round $first_1s ($(fmt_elapsed ${RES_ELAPSED_MS[$first_1s]}))"
else
    echo "    1s+ not reached"
fi
if [ "$first_5s" -ge 0 ]; then
    echo "    5s+ at round $first_5s ($(fmt_elapsed ${RES_ELAPSED_MS[$first_5s]}))"
else
    echo "    5s+ not reached"
fi
if [ "$first_10s" -ge 0 ]; then
    echo "    10s+ at round $first_10s ($(fmt_elapsed ${RES_ELAPSED_MS[$first_10s]}))"
else
    echo "    10s+ not reached"
fi

# TD events
td_rounds=0
first_td_round=-1
for round in $(seq 0 $MAX_CONCURRENCY); do
    if [ "${RES_TD_FOUND[$round]}" -eq 1 ]; then
        td_rounds=$((td_rounds + 1))
        [ "$first_td_round" -eq -1 ] && first_td_round=$round
    fi
done

echo ""
echo "  'wait available td' events:"
echo "    Observed in $td_rounds of $((MAX_CONCURRENCY + 1)) rounds"
if [ "$first_td_round" -ge 0 ]; then
    echo "    First observed at round $first_td_round"
else
    echo "    Not observed — TD expansion succeeded (page has free space)"
fi

echo ""
if [ "$peak_ms" -ge 10000 ]; then
    echo -e "  ${GREEN}RESULT: Degradation from $baseline_str to $peak_str (10s+ achieved) ✓${NC}"
elif [ "$peak_ms" -ge 5000 ]; then
    echo -e "  ${YELLOW}RESULT: Degradation from $baseline_str to $peak_str (5s+ achieved)${NC}"
    echo "  Tip: increase -H or -C to amplify"
else
    echo -e "  ${RED}RESULT: Insufficient degradation ✗${NC}"
    echo "  Tip: increase -H or -C, or test on GaussDB"
fi

echo "============================================================"