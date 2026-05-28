#!/bin/bash
#
# test_wait_available_td.sh — Reproduce Ustore TD contention and deadlock
#
# 原理：
#   Ustore 将 Astore 中每行 tuple 上的事务信息 (xmin/xmax) 统一移到页面级，
#   存储在 Transaction Directory (TD) 中。默认每页只有 4 个 TD 槽位。
#
#   TD 动态扩展：当 4 个 TD 不够时，OpenGauss 会从页面空闲空间分配更多 TD。
#   "wait available td" 只在页面空闲空间耗尽、TD 扩展失败时才会出现。
#
#   Phase 1 策略：创建 STORAGE PLAIN 大行宽表，使每页只剩极小空闲空间。
#   先插入小行，再 UPDATE 增大 data 列消耗页面空闲空间，使 TD 扩展无法分配。
#   4 个后台事务占满初始 TD → 第 5 个事务无法扩展 → "wait available td"。
#
#   但 TD 的引入带来了新的死锁风险：同页并发 UPDATE 可能形成行锁循环。
#   Ustore TD 机制下，4 个 TD 被死锁事务占满后，该页上所有新事务都无法获取 TD，
#   死锁影响范围从参与事务扩大到整个页面（page-level starvation）。
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
HOLD_SECS=15
DL_TIMEOUT=15
SCAN_GAP=2

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

OpenGauss/GaussDB Ustore TD contention and deadlock reproduction test.

Phase 1: STORAGE PLAIN + large rows to fill page → TD expansion fails → "wait available td"
Phase 2: Cross-update pattern on same-page rows → row lock deadlock

Options:
    -t TYPE     Database type: opengauss/gaussdb (default: opengauss)
    -h HOST     Database host (default: localhost)
    -p PORT     Database port (default: 5433 for opengauss, 8000 for gaussdb)
    -d DB       Database name (default: postgres)
    -U USER     Database user (default: gaussdb for opengauss, root for gaussdb)
    -W PASS     Database password
    -T TABLE    Table name (default: td_test)
    -V           Verbose: print each SQL statement before execution
    -H SECS     Seconds to hold TD slots in Phase 1 (default: 15)
    -D SECS     Deadlock detection timeout in Phase 2 (default: 15)

Examples:
    $0 -t opengauss -h localhost -p 5433 -U gaussdb -W 'Enmotech@123'
    $0 -t gaussdb -h localhost -p 8000 -U root -W 'Pass@123'
    $0 -t opengauss -h localhost -p 5433 -U gaussdb -W 'Enmotech@123' -H 30 -V
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
    cat "$out_file" | grep -v "^Password\|^You\|^Line\|^gsql:"
    rm -f "$out_file"
}

bg_sql() {
    local sql="$1" tag="$2"
    local caller_line="${BASH_LINENO[0]}"
    log_sql "bg_sql (line $caller_line): bg-$tag: $sql"
    eval "$(build_conn "-c \"$sql\"")" >"/tmp/watd_${tag}.out" 2>"/tmp/watd_${tag}.err" &
    echo $!
}

# Detect which view has wait_event column, and its query column name
detect_wait_view() {
    local has_tw=$(db_query "SELECT count(*) FROM information_schema.columns WHERE table_name='pg_thread_wait_status' AND column_name='wait_event';" 2>/dev/null | head -1 | tr -d ' ')
    local has_q_tw=$(db_query "SELECT count(*) FROM information_schema.columns WHERE table_name='pg_thread_wait_status' AND column_name='query';" 2>/dev/null | head -1 | tr -d ' ')
    local has_qid_tw=$(db_query "SELECT count(*) FROM information_schema.columns WHERE table_name='pg_thread_wait_status' AND column_name='query_id';" 2>/dev/null | head -1 | tr -d ' ')

    if [ "$has_tw" -gt 0 ] 2>/dev/null; then
        WAIT_VIEW="pg_thread_wait_status"
        if [ "$has_q_tw" -gt 0 ] 2>/dev/null; then
            WAIT_QUERY_COL="query"
        elif [ "$has_qid_tw" -gt 0 ] 2>/dev/null; then
            WAIT_QUERY_COL="query_id"
        else
            WAIT_QUERY_COL="tid"
        fi
    else
        WAIT_VIEW="pg_stat_activity"
        local has_q_sa=$(db_query "SELECT count(*) FROM information_schema.columns WHERE table_name='pg_stat_activity' AND column_name='query';" 2>/dev/null | head -1 | tr -d ' ')
        if [ "$has_q_sa" -gt 0 ] 2>/dev/null; then
            WAIT_QUERY_COL="query"
        else
            WAIT_QUERY_COL="pid"
        fi
    fi
}

while getopts "t:h:p:d:U:W:T:VH:D:" opt; do
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
        D) DL_TIMEOUT="$OPTARG" ;;
        *) usage ;;
    esac
done

set_defaults
detect_client

echo ""
echo "============================================================"
echo "  Ustore TD Contention & Deadlock Reproduction Test"
echo "============================================================"
echo "Database:     $DB_TYPE ($DB_HOST:$DB_PORT/$DB_NAME)"
echo "User:         $DB_USER"
echo "Client:       $DB_CLIENT"
echo "Table:        $TABLE_NAME (ustore, STORAGE PLAIN)"
echo "Hold TD secs: $HOLD_SECS"
echo "DL timeout:   $DL_TIMEOUT"
echo "============================================================"
echo ""

# ── Pre-check ──
log_step "Pre-check: Database version and key parameters"
DB_VER=$(db_query "SELECT version();" | head -1)
echo "  Version: $DB_VER"

DL_TIMEOUT_SETTING=$(db_query "SELECT setting FROM pg_settings WHERE name='deadlock_timeout';" 2>/dev/null | head -1 | tr -d ' ')
echo "  deadlock_timeout: ${DL_TIMEOUT_SETTING:-unknown}"

STORAGE=$(db_query "SELECT setting FROM pg_settings WHERE name = 'enable_ustore';" | head -1 | tr -d ' ')
if [ "$STORAGE" != "on" ]; then
    log_warn "enable_ustore='$STORAGE', setting to 'on'..."
    db_exec "ALTER SYSTEM SET enable_ustore = on;"
    db_exec "SELECT pg_reload_conf();"
    sleep 1
fi
log_info "  enable_ustore = on"

# ── Phase 0: Setup — STORAGE PLAIN + fill page ──
log_step "Phase 0: Setup — Create Ustore table (STORAGE PLAIN) and fill page"

# Strategy: INSERT directly with large data (not short→UPDATE grow),
# because UPDATE to grow data causes row migration on GaussDB (rows leave page 0).
# STORAGE PLAIN + 1540-byte data packs ~5 rows per page, minimal free space.
db_exec "DROP TABLE IF EXISTS ${TABLE_NAME} CASCADE;"
db_exec "CREATE TABLE ${TABLE_NAME} (id INT PRIMARY KEY, val INT, data VARCHAR(2000)) WITH (STORAGE_TYPE = USTORE, FILLFACTOR = 100);"
db_exec "ALTER TABLE ${TABLE_NAME} ALTER COLUMN data SET STORAGE PLAIN;"

# Insert rows directly with large data — rows stay on their assigned pages
db_exec "INSERT INTO ${TABLE_NAME} SELECT g, 0, repeat('x', 1540) FROM generate_series(1, 30) g;"
db_exec "VACUUM ANALYZE ${TABLE_NAME};"

ROW_COUNT=$(db_query "SELECT count(*) FROM ${TABLE_NAME};" | head -1 | tr -d ' ')
log_info "  Inserted $ROW_COUNT rows"

# Find rows on page 0 via ctid
PAGE0_IDS=$(db_query "SELECT string_agg(id::text, ',' ORDER BY id) FROM (SELECT id FROM ${TABLE_NAME} WHERE substring(ctid::text from '^\((\d+)') = '0' ORDER BY ctid LIMIT 8) s;")
if [ -z "$PAGE0_IDS" ]; then
    log_error "No rows on page 0. Test cannot proceed."
    db_exec "DROP TABLE IF EXISTS ${TABLE_NAME} CASCADE;"
    exit 1
fi
IFS=',' read -ra IDS <<< "$PAGE0_IDS"
PAGE0_COUNT=${#IDS[@]}

CTID_INFO=$(db_query "SELECT id, ctid FROM ${TABLE_NAME} WHERE id IN (${PAGE0_IDS}) ORDER BY ctid;")
echo "  Rows on page 0 ($PAGE0_COUNT rows):"
echo "$CTID_INFO" | while read line; do echo "    $line"; done
log_info "  Target rows for test: ${IDS[*]} (${PAGE0_COUNT} rows on page 0)"

# Re-select IDS from page 0 rows only
IFS=',' read -ra IDS <<< "$PAGE0_IDS"
IDS_LEN=${#IDS[@]}
if [ "$IDS_LEN" -lt 5 ]; then
    log_warn "Only $IDS_LEN rows on page 0 — need 5 for TD contention test."
    log_warn "'wait available td' may not reproduce. Deadlock test will use available rows."
fi

detect_wait_view
log_info "  Wait event view: $WAIT_VIEW (query col: $WAIT_QUERY_COL)"

# ── Phase 1: TD contention — fill page + hold TDs → no expansion space ──
echo ""
log_step "Phase 1: TD contention — page filled, TD expansion should fail"
echo "  Strategy: STORAGE PLAIN + 1540-byte data → page nearly full → TD expansion"
echo "  has no free space → 5th transaction must wait for 'wait available td'"
echo ""

TEST_START_S=$(date +%s)

# Launch 4 background transactions on page 0 rows
BG_PIDS=""
BG_COUNT=$((IDS_LEN > 4 ? 4 : IDS_LEN - 1))
for i in $(seq 0 $((BG_COUNT - 1))); do
    PID=$(bg_sql "BEGIN; UPDATE ${TABLE_NAME} SET val=val+1 WHERE id=${IDS[$i]}; SELECT pg_sleep(${HOLD_SECS}); COMMIT;" "bg${i}")
    BG_PIDS="$BG_PIDS $PID"
    echo "  BG$i: UPDATE id=${IDS[$i]} + pg_sleep(${HOLD_SECS}), PID=$PID"
done

echo "  Waiting 5s for background transactions to acquire TDs..."
sleep 5

# Verify BG sessions are active
BG_ACTIVE=$(db_query "SELECT count(*) FROM pg_stat_activity WHERE state != 'idle' AND ${WAIT_QUERY_COL} LIKE '%pg_sleep%';" 2>/dev/null | head -1 | tr -d ' ')
log_info "  Background sessions active: ${BG_ACTIVE:-unknown}"

# Launch FG transaction — the 5th on same page
FG_ID=${IDS[$BG_COUNT]}
echo "  Launching FG: UPDATE id=$FG_ID (TD expansion should fail → 'wait available td')"
FG_START_NS=$(date +%s%N)
FG_PID=$(bg_sql "BEGIN; UPDATE ${TABLE_NAME} SET val=val+1 WHERE id=${FG_ID}; COMMIT;" "fg5")

# Monitor wait events
FOUND_TD=0
TD_EXPANDED=0
elapsed=0
echo "  Monitoring wait events every ${SCAN_GAP}s..."
while [ $elapsed -lt $HOLD_SECS ]; do
    WAITS=$(db_query "SELECT count(*) FROM ${WAIT_VIEW} WHERE wait_event='wait available td';" 2>/dev/null | head -1 | tr -d ' ')
    WAITS=${WAITS:-0}
    now_s=$(date +%s)
    abs_elapsed=$((now_s - TEST_START_S))

    if [ "$WAITS" -gt 0 ] 2>/dev/null; then
        FOUND_TD=1
        echo -e "  [${abs_elapsed}s] ${GREEN}'wait available td' sessions: $WAITS${NC}"
        DETAIL=$(db_query "SELECT tid || ' | ' || wait_event FROM ${WAIT_VIEW} WHERE wait_event='wait available td' LIMIT 3;" 2>/dev/null)
        if [ -n "$DETAIL" ]; then
            echo "$DETAIL" | while read line; do echo "    $line"; done
        fi
    else
        echo "  [${abs_elapsed}s] 'wait available td' sessions: 0"
    fi

    # Check if FG completed
    if ! kill -0 $FG_PID 2>/dev/null; then
        FG_END_NS=$(date +%s%N)
        FG_ELAPSED_MS=$(( (FG_END_NS - FG_START_NS) / 1000000 ))
        if [ $FG_ELAPSED_MS -lt 1000 ]; then
            TD_EXPANDED=1
            echo "  FG completed in ${FG_ELAPSED_MS}ms — TD expansion succeeded (page still has free space)"
        else
            echo "  FG completed in ${FG_ELAPSED_MS}ms — may have waited for available TD"
        fi
        break
    fi

    sleep $SCAN_GAP
    elapsed=$((elapsed + SCAN_GAP))
done

# Wait for remaining processes
if kill -0 $FG_PID 2>/dev/null; then
    echo "  FG still running — waiting for background to commit..."
    for pid in $BG_PIDS; do wait $pid 2>/dev/null || true; done
    wait $FG_PID 2>/dev/null || true
    FG_END_NS=$(date +%s%N)
    FG_ELAPSED_MS=$(( (FG_END_NS - FG_START_NS) / 1000000 ))
    echo "  FG completed after BG commit: ${FG_ELAPSED_MS}ms"
fi
for pid in $BG_PIDS; do wait $pid 2>/dev/null || true; done

if [ $FOUND_TD -eq 1 ]; then
    echo ""
    echo -e "${GREEN}✓ Phase 1: 'wait available td' REPRODUCED${NC}"
    echo "  Page free space exhausted → TD expansion failed → transaction waited"
elif [ $TD_EXPANDED -eq 1 ]; then
    echo ""
    echo -e "${YELLOW}✗ Phase 1: 'wait available td' NOT REPRODUCED${NC}"
    echo "  TD expansion succeeded even with STORAGE PLAIN + 1540-byte data."
    echo "  Page still has enough free space for dynamic TD allocation."
    echo "  Possible: in-place UPDATE of val (INT) doesn't grow row, free space unchanged."
    echo "  'wait available td' needs page free space ≈ 0 (very rare in practice)."
else
    echo ""
    echo -e "${YELLOW}✗ Phase 1: 'wait available td' NOT REPRODUCED${NC}"
fi

# ── Phase 2: Deadlock ──
echo ""
log_step "Phase 2: Reproduce deadlock on same-page concurrent UPDATEs"
echo "  Principle: T1 UPDATE row_A → UPDATE row_B; T2 UPDATE row_B → UPDATE row_A"
echo "  Same page → row lock cycle → deadlock + page-level starvation"
echo ""

if [ ${#IDS[@]} -lt 2 ]; then
    log_error "Not enough rows on page 0 for deadlock test. Need at least 2."
else
    # Reset val
    db_exec "UPDATE ${TABLE_NAME} SET val = 0 WHERE id IN (${IDS[0]}, ${IDS[1]});"

    DL1_PID=$(bg_sql "BEGIN; UPDATE ${TABLE_NAME} SET val=val+1 WHERE id=${IDS[0]}; SELECT pg_sleep(3); UPDATE ${TABLE_NAME} SET val=val+1 WHERE id=${IDS[1]}; COMMIT;" "dl1")
    DL2_PID=$(bg_sql "BEGIN; UPDATE ${TABLE_NAME} SET val=val+1 WHERE id=${IDS[1]}; SELECT pg_sleep(3); UPDATE ${TABLE_NAME} SET val=val+1 WHERE id=${IDS[0]}; COMMIT;" "dl2")

    echo "  T1: id=${IDS[0]}→${IDS[1]}, PID=$DL1_PID"
    echo "  T2: id=${IDS[1]}→${IDS[0]}, PID=$DL2_PID"
    echo "  deadlock_timeout: ${DL_TIMEOUT_SETTING}"
    echo "  Waiting for deadlock detection (timeout: ${DL_TIMEOUT}s)..."

    FOUND_DL=0
    DL_VICTIM=""
    elapsed=0

    while [ $elapsed -lt $DL_TIMEOUT ]; do
        alive1=0; alive2=0
        kill -0 $DL1_PID 2>/dev/null && alive1=1
        kill -0 $DL2_PID 2>/dev/null && alive2=1

        if [ $alive1 -eq 0 ] || [ $alive2 -eq 0 ]; then
            now_s=$(date +%s)
            abs_elapsed=$((now_s - TEST_START_S))
            echo "  [${abs_elapsed}s] Transaction terminated — deadlock victim detected"

            DL1_ERR=$(cat /tmp/watd_dl1.err 2>/dev/null | grep -vi "password\|notice\|gsql:" || echo "")
            DL2_ERR=$(cat /tmp/watd_dl2.err 2>/dev/null | grep -vi "password\|notice\|gsql:" || echo "")

            if echo "$DL1_ERR" | grep -qi "deadlock"; then
                echo -e "  ${RED}T1 was aborted as deadlock victim${NC}"
                echo "  Error: $(echo "$DL1_ERR" | grep -i 'deadlock' | head -3)"
                FOUND_DL=1; DL_VICTIM="T1"
            elif echo "$DL2_ERR" | grep -qi "deadlock"; then
                echo -e "  ${RED}T2 was aborted as deadlock victim${NC}"
                echo "  Error: $(echo "$DL2_ERR" | grep -i 'deadlock' | head -3)"
                FOUND_DL=1; DL_VICTIM="T2"
            else
                echo "  Process exited but not with deadlock error:"
                if [ $alive1 -eq 0 ]; then echo "    dl1.err: $(echo $DL1_ERR | head -2)"; fi
                if [ $alive2 -eq 0 ]; then echo "    dl2.err: $(echo $DL2_ERR | head -2)"; fi
            fi
            break
        fi

        sleep 1
        elapsed=$((elapsed + 1))
    done

    if kill -0 $DL1_PID 2>/dev/null; then
        log_warn "T1 still alive after ${DL_TIMEOUT}s, stopping..."
        kill $DL1_PID 2>/dev/null || true
    fi
    if kill -0 $DL2_PID 2>/dev/null; then
        log_warn "T2 still alive after ${DL_TIMEOUT}s, stopping..."
        kill $DL2_PID 2>/dev/null || true
    fi
    wait $DL1_PID 2>/dev/null || true
    wait $DL2_PID 2>/dev/null || true

    if [ $FOUND_DL -eq 1 ]; then
        echo ""
        echo -e "${GREEN}✓ Phase 2: Deadlock REPRODUCED${NC}"
        echo "  $DL_VICTIM was aborted as deadlock victim"
        echo "  Same-page cross UPDATE → row lock cycle → deadlock"
        echo "  Ustore TD: deadlocked transactions hold TDs → page-level starvation"
    else
        echo ""
        echo -e "${YELLOW}✗ Phase 2: Deadlock NOT REPRODUCED${NC}"
        echo "  Diagnostic info:"
        echo "    Rows on page 0: $PAGE0_IDS"
        echo "    deadlock_timeout: ${DL_TIMEOUT_SETTING}"
        echo "    T1/DL2 output files: check /tmp/watd_dl1.out /tmp/watd_dl2.out"
        echo "  Possible reasons:"
        echo "    - Rows not on same page (cross-page UPDATE no TD contention)"
        echo "    - pg_sleep timing: transactions completed before cross-update"
        echo "    - deadlock_timeout too large (adjust with -D)"
    fi
fi

# ── Cleanup ──
echo ""
log_step "Cleanup"
db_exec "DROP TABLE IF EXISTS ${TABLE_NAME} CASCADE;"
rm -f /tmp/watd_bg*.out /tmp/watd_bg*.err /tmp/watd_fg*.out /tmp/watd_fg*.err
rm -f /tmp/watd_dl*.out /tmp/watd_dl*.err /tmp/watd_exec_err_* /tmp/watd_query_out_* /tmp/watd_query_err_*

# ── Summary ──
echo ""
echo "============================================================"
echo "  Summary"
echo "============================================================"
if [ $FOUND_TD -eq 1 ]; then
    echo -e "  'wait available td': ${GREEN}REPRODUCED ✓${NC}"
elif [ $TD_EXPANDED -eq 1 ]; then
    echo -e "  'wait available td': ${YELLOW}TD expansion succeeded ✗${NC}"
    echo "  (page free space not exhausted; needs near-zero free space)"
else
    echo -e "  'wait available td': ${YELLOW}NOT REPRODUCED ✗${NC}"
fi
if [ $FOUND_DL -eq 1 ]; then
    echo -e "  Deadlock:           ${GREEN}REPRODUCED ✓${NC} (victim: $DL_VICTIM)"
elif [ ${#IDS[@]} -lt 2 ]; then
    echo -e "  Deadlock:           ${RED}SKIPPED — not enough rows on page 0${NC}"
else
    echo -e "  Deadlock:           ${YELLOW}NOT REPRODUCED ✗${NC}"
fi
echo "============================================================"