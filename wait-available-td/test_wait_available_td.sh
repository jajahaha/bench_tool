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
#   因此在高并发但页面仍有空闲空间时，TD 扩展成功，不会出现此等待事件。
#
#   但 TD 的引入带来了新的死锁风险：同页并发 UPDATE 可能形成行锁循环。
#   Astore 每行独立存事务信息，同一页的行锁死锁只影响参与的事务；
#   Ustore TD 机制下，4 个 TD 被死锁事务占满后，该页上所有新事务都无法获取 TD，
#   死锁影响范围从参与事务扩大到整个页面（page-level starvation）。
#
# 测试流程：
#   Phase 1: TD contention — 并发事务占满初始 TD 槽位，检测 TD 扩展或 "wait available td"
#   Phase 2: Deadlock — 交叉 UPDATE 同页行 → 行锁死锁循环
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
HOLD_SECS=30
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

Phase 1: Concurrent transactions on same page — detect TD expansion or "wait available td".
         "wait available td" only appears when page free space is exhausted (TD expansion fails).
Phase 2: Cross-update pattern on same-page rows → row lock deadlock.

Options:
    -t TYPE     Database type: opengauss/gaussdb (default: opengauss)
    -h HOST     Database host (default: localhost)
    -p PORT     Database port (default: 5433 for opengauss, 8000 for gaussdb)
    -d DB       Database name (default: postgres)
    -U USER     Database user (default: gaussdb for opengauss, root for gaussdb)
    -W PASS     Database password
    -T TABLE    Table name (default: td_test)
    -V           Verbose: print each SQL statement before execution
    -H SECS     Seconds to hold TD slots in Phase 1 (default: 30)
    -D SECS     Deadlock detection timeout in Phase 2 (default: 15)

Examples:
    $0 -t opengauss -h localhost -p 5433 -U gaussdb -W 'Enmotech@123'
    $0 -t gaussdb -h localhost -p 8000 -U root -W 'Pass@123'
    $0 -t opengauss -h localhost -p 5433 -U gaussdb -W 'Enmotech@123' -H 60 -V
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
    # pg_thread_wait_status (OpenGauss thread model) — has wait_event but NOT query
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
        # Fall back to pg_stat_activity
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
detect_wait_view

echo ""
echo "============================================================"
echo "  Ustore TD Contention & Deadlock Reproduction Test"
echo "============================================================"
echo "Database:       $DB_TYPE ($DB_HOST:$DB_PORT/$DB_NAME)"
echo "User:           $DB_USER"
echo "Client:         $DB_CLIENT"
echo "Table:          $TABLE_NAME (ustore)"
echo "Hold TD secs:   $HOLD_SECS"
echo "DL timeout:     $DL_TIMEOUT"
echo "Wait event view: $WAIT_VIEW (query col: $WAIT_QUERY_COL)"
echo "============================================================"
echo ""

# ── Phase 0: Setup ──
log_step "Phase 0: Setup — Create Ustore table and find same-page rows"

db_exec "DROP TABLE IF EXISTS ${TABLE_NAME} CASCADE;"
db_exec "CREATE TABLE ${TABLE_NAME} (id INT PRIMARY KEY, val INT) WITH (STORAGE_TYPE = USTORE);"
db_exec "INSERT INTO ${TABLE_NAME} SELECT g, 0 FROM generate_series(1, 200) g;"
db_exec "VACUUM ANALYZE ${TABLE_NAME};"

ROW_COUNT=$(db_query "SELECT count(*) FROM ${TABLE_NAME};" | head -1 | tr -d ' ')
log_info "  Inserted $ROW_COUNT rows"

# Verify Ustore
STORAGE=$(db_query "SELECT setting FROM pg_settings WHERE name = 'enable_ustore';" | head -1 | tr -d ' ')
if [ "$STORAGE" != "on" ]; then
    log_warn "enable_ustore='$STORAGE', setting to 'on'..."
    db_exec "ALTER SYSTEM SET enable_ustore = on;"
    db_exec "SELECT pg_reload_conf();"
    sleep 1
fi
log_info "  enable_ustore = on"

# Find rows on same page via ctid
CTID_INFO=$(db_query "SELECT id || ',' || ctid FROM ${TABLE_NAME} ORDER BY ctid LIMIT 10;")
echo "  Rows by physical order (ctid):"
echo "$CTID_INFO" | while IFS=, read id ctid; do echo "    id=$id  ctid=$ctid"; done

# Pick 8 rows on same page
ROW_IDS_STR=$(db_query "SELECT string_agg(id::text, ',' ORDER BY id) FROM (SELECT id FROM ${TABLE_NAME} ORDER BY ctid LIMIT 8) s;")
IFS=',' read -ra IDS <<< "$ROW_IDS_STR"

# Verify same page
BLOCK_NUMS=$(db_query "SELECT DISTINCT substring(ctid::text from '^\((\d+)') FROM ${TABLE_NAME} WHERE id IN (${ROW_IDS_STR});")
PAGE_COUNT=$(echo "$BLOCK_NUMS" | grep -c '.' 2>/dev/null || echo "0")
if [ "$PAGE_COUNT" -gt 1 ]; then
    log_warn "Target rows span $PAGE_COUNT pages. TD contention may be reduced."
else
    log_info "  Target rows ${IDS[*]} all on same page (block $(echo $BLOCK_NUMS | head -1))"
fi

# ── Phase 1: TD contention ──
echo ""
log_step "Phase 1: TD contention — concurrent UPDATEs on same page"
echo "  Principle: Ustore page has 4 initial TD slots."
echo "  When >4 transactions UPDATE same page, TD expansion allocates more TDs from"
echo "  page free space. 'wait available td' only appears when expansion fails"
echo "  (page free space exhausted). In OpenGauss 6.0+, TD expansion is efficient"
echo "  so this wait event is rare under normal conditions."
echo ""

TEST_START_S=$(date +%s)

# Launch 4 background transactions: each UPDATE a row + pg_sleep to hold TD
BG_PIDS=""
for i in 0 1 2 3; do
    PID=$(bg_sql "BEGIN; UPDATE ${TABLE_NAME} SET val=val+1 WHERE id=${IDS[$i]}; SELECT pg_sleep(${HOLD_SECS}); COMMIT;" "bg${i}")
    BG_PIDS="$BG_PIDS $PID"
    echo "  BG$i: UPDATE id=${IDS[$i]} + pg_sleep(${HOLD_SECS}), PID=$PID"
done

echo "  Waiting 5s for background transactions to acquire TDs..."
sleep 5

# Check background sessions via pg_stat_activity (more reliable for query identification)
BG_ACTIVE=$(db_query "SELECT count(*) FROM pg_stat_activity WHERE state != 'idle' AND ${WAIT_QUERY_COL} LIKE '%pg_sleep%${TABLE_NAME}%';" 2>/dev/null | head -1 | tr -d ' ')
log_info "  Background sessions holding TDs on same page: ${BG_ACTIVE:-unknown}"

# Launch foreground transaction — test whether it waits or gets expanded TD
echo "  Launching FG5: UPDATE id=${IDS[4]} (should get TD via expansion or wait)"
FG_START_NS=$(date +%s%N)
FG_PID=$(bg_sql "BEGIN; UPDATE ${TABLE_NAME} SET val=val+1 WHERE id=${IDS[4]}; COMMIT;" "fg5")

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
        echo "  [${abs_elapsed}s] 'wait available td' sessions: 0 (TD expansion likely working)"
    fi

    # Check if FG completed — if quickly, TD expansion succeeded; if slowly, TD wait
    if ! kill -0 $FG_PID 2>/dev/null; then
        FG_END_NS=$(date +%s%N)
        FG_ELAPSED_MS=$(( (FG_END_NS - FG_START_NS) / 1000000 ))
        if [ $FG_ELAPSED_MS -lt 1000 ]; then
            TD_EXPANDED=1
            echo "  FG5 completed in ${FG_ELAPSED_MS}ms — TD expansion succeeded (no TD wait)"
        else
            echo "  FG5 completed in ${FG_ELAPSED_MS}ms — may have waited for available TD"
        fi
        break
    fi

    sleep $SCAN_GAP
    elapsed=$((elapsed + SCAN_GAP))
done

# If FG still running, wait for BG to commit (releasing TDs)
if kill -0 $FG_PID 2>/dev/null; then
    echo "  FG5 still running — waiting for background transactions to commit..."
    for pid in $BG_PIDS; do wait $pid 2>/dev/null || true; done
    wait $FG_PID 2>/dev/null || true
    FG_END_NS=$(date +%s%N)
    FG_ELAPSED_MS=$(( (FG_END_NS - FG_START_NS) / 1000000 ))
    echo "  FG5 completed after BG commit: ${FG_ELAPSED_MS}ms"
fi

if [ $FOUND_TD -eq 1 ]; then
    echo ""
    echo -e "${GREEN}✓ Phase 1: 'wait available td' REPRODUCED${NC}"
    echo "  Page free space was insufficient for TD expansion → transaction had to wait"
elif [ $TD_EXPANDED -eq 1 ]; then
    echo ""
    echo -e "${YELLOW}✗ Phase 1: 'wait available td' NOT REPRODUCED${NC}"
    echo "  TD expansion succeeded — page had enough free space for dynamic TD allocation."
    echo "  'wait available td' only appears when page free space is exhausted (rare)."
    echo "  To reproduce: fill the page completely (large inline data + STORAGE PLAIN)"
    echo "  so TD expansion has no free space to allocate new TD slots."
else
    echo ""
    echo -e "${YELLOW}✗ Phase 1: 'wait available td' NOT REPRODUCED${NC}"
    echo "  FG5 completed but timing unclear. Check above for details."
fi

# ── Phase 2: Deadlock ──
echo ""
log_step "Phase 2: Reproduce deadlock on same-page concurrent UPDATEs"
echo "  Principle: T1 UPDATE row_A → UPDATE row_B; T2 UPDATE row_B → UPDATE row_A"
echo "  Same page → row lock cycle → deadlock."
echo "  Ustore TD amplifies impact: deadlocked transactions hold TDs, blocking"
echo "  ALL new transactions on the same page (page-level starvation)."
echo ""

# Reset val for clean deadlock test
db_exec "UPDATE ${TABLE_NAME} SET val = 0 WHERE id IN (${IDS[0]}, ${IDS[1]});"

# T1: UPDATE row_A → pg_sleep(3) → UPDATE row_B (waits for T2's lock on row_B)
DL1_PID=$(bg_sql "BEGIN; UPDATE ${TABLE_NAME} SET val=val+1 WHERE id=${IDS[0]}; SELECT pg_sleep(3); UPDATE ${TABLE_NAME} SET val=val+1 WHERE id=${IDS[1]}; COMMIT;" "dl1")
# T2: UPDATE row_B → pg_sleep(3) → UPDATE row_A (waits for T1's lock on row_A)
DL2_PID=$(bg_sql "BEGIN; UPDATE ${TABLE_NAME} SET val=val+1 WHERE id=${IDS[1]}; SELECT pg_sleep(3); UPDATE ${TABLE_NAME} SET val=val+1 WHERE id=${IDS[0]}; COMMIT;" "dl2")

echo "  T1: id=${IDS[0]}→${IDS[1]}, PID=$DL1_PID"
echo "  T2: id=${IDS[1]}→${IDS[0]}, PID=$DL2_PID"
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

# If still alive after timeout, kill them
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
    echo "  Ustore TD impact: deadlocked transactions hold TDs on page,"
    echo "  blocking ALL new transactions on the same page (page-level starvation)"
else
    echo ""
    echo -e "${YELLOW}✗ Phase 2: Deadlock NOT REPRODUCED${NC}"
    echo "  Possible reasons:"
    echo "    - Rows not on same page (less contention)"
    echo "    - Deadlock detection timeout too short"
    echo "    - Transactions completed before cross-update (timing issue)"
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
else
    if [ $TD_EXPANDED -eq 1 ]; then
        echo -e "  TD contention:      ${YELLOW}TD expansion succeeded ✗${NC}"
        echo "  ('wait available td' requires page free space exhaustion)"
    else
        echo -e "  'wait available td': ${YELLOW}NOT REPRODUCED ✗${NC}"
    fi
fi
if [ $FOUND_DL -eq 1 ]; then
    echo -e "  Deadlock:           ${GREEN}REPRODUCED ✓${NC} (victim: $DL_VICTIM)"
else
    echo -e "  Deadlock:           ${YELLOW}NOT REPRODUCED ✗${NC}"
fi
echo "============================================================"