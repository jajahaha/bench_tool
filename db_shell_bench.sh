#!/bin/bash
#
# db_shell_bench - Database Benchmark Tool
# Supports PostgreSQL, OpenGauss, GaussDB
#

set -e

# Default configuration
DB_HOST="localhost"
DB_PORT="5432"
DB_NAME="postgres"
DB_USER="postgres"
DB_PASS=""
DB_TYPE="postgres"
TABLE_PREFIX="dbbench"
INIT_SCALE=1
CLIENTS=1
TRANSACTIONS=0
DURATION=0
MODE="benchmark"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

usage() {
    cat << EOF
Usage: $0 [OPTIONS] [COMMAND]

Commands:
    init        Initialize database with test data
    benchmark   Run benchmark test (default)

Options:
    -h HOST     Database host (default: localhost)
    -p PORT     Database port (default: 5432)
    -d DB       Database name (default: postgres)
    -U USER     Database user (default: postgres)
    -W PASS     Database password
    -t TYPE     Database type: postgres, opengauss, gaussdb (default: postgres)
    -P PREFIX   Table name prefix (default: dbbench)
    -s SCALE    Scaling factor for initialization (default: 1)
    -c CLIENTS  Number of concurrent clients (default: 1)
    -n TXNS     Number of transactions per client (default: 0)
    -T SECS     Duration in seconds for time-based test (default: 0)

Examples:
    # PostgreSQL
    $0 -h localhost -p 5432 -U postgres init -s 10
    $0 -h localhost -p 5432 -U postgres -c 4 -n 100 benchmark

    # OpenGauss / GaussDB
    $0 -t opengauss -h localhost -p 5433 -U gaussdb -W 'Enmotech@123' init -s 1
    $0 -t gaussdb -h localhost -p 8000 -U root -W 'Pass@123' -c 4 -T 60 benchmark
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

# URL encode password for connection string
url_encode() {
    local str="$1"
    printf '%s' "$str" | sed 's/@/%40/g; s/:/%3A/g; s/\//%2F/g; s/#/%23/g; s/\?/%3F/g; s/&/%26/g; s/=/%3D/g; s/ /%20/g'
}

# Select database client: opengauss/gaussdb prefer gsql, fallback to psql
DB_CLIENT=""
detect_client() {
    case $DB_TYPE in
        postgres)
            DB_CLIENT="psql"
            ;;
        opengauss|gaussdb)
            # Prefer gsql, fallback to psql
            if command -v gsql &> /dev/null; then
                DB_CLIENT="gsql"
            elif command -v psql &> /dev/null; then
                DB_CLIENT="psql"
            else
                log_error "Neither gsql nor psql found. Please install database client tools."
                exit 1
            fi
            ;;
        *)
            log_error "Unsupported database type: $DB_TYPE"
            exit 1
            ;;
    esac
}

# Build connection string with password
get_conn_str() {
    if [ -n "$DB_PASS" ]; then
        local encoded_pass=$(url_encode "$DB_PASS")
        echo "postgresql://${DB_USER}:${encoded_pass}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
    else
        echo ""
    fi
}

# Build connection options (no password)
get_conn_opts() {
    echo "-h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME"
}

# Execute SQL (with output)
db_exec() {
    local sql="$1"

    if [ -n "$DB_PASS" ]; then
        $DB_CLIENT "$(get_conn_str)" -t -c "$sql" 2>/dev/null
    else
        $DB_CLIENT $(get_conn_opts) -t -c "$sql" 2>/dev/null
    fi
}

# Execute SQL (quiet, suppress command feedback)
db_exec_quiet() {
    local sql="$1"

    if [ -n "$DB_PASS" ]; then
        $DB_CLIENT "$(get_conn_str)" -q -c "$sql" 2>/dev/null
    else
        $DB_CLIENT $(get_conn_opts) -q -c "$sql" 2>/dev/null
    fi
}

# Check database client availability
check_client() {
    detect_client
    if ! command -v $DB_CLIENT &> /dev/null; then
        log_error "$DB_CLIENT not found. Please install database client tools."
        exit 1
    fi
    log_info "Using client: $DB_CLIENT"
}

# Check database connection
check_connection() {
    if ! db_exec "SELECT 1" &> /dev/null; then
        log_error "Cannot connect to database. Check your connection parameters."
        exit 1
    fi
    log_info "Database connection successful ($DB_TYPE via $DB_CLIENT)"
}

# Initialize test tables
init_database() {
    log_info "Initializing database with scale factor: $INIT_SCALE"

    local ACCOUNT_ROWS=$((INIT_SCALE * 100000))
    local BRANCH_ROWS=$INIT_SCALE
    local TELLER_ROWS=$((INIT_SCALE * 10))
    local BATCH_SIZE=100000

    log_info "Creating tables..."
    log_info "  - ${TABLE_PREFIX}_accounts: $ACCOUNT_ROWS rows"
    log_info "  - ${TABLE_PREFIX}_branches: $BRANCH_ROWS rows"
    log_info "  - ${TABLE_PREFIX}_tellers:  $TELLER_ROWS rows"

    db_exec_quiet "DROP TABLE IF EXISTS ${TABLE_PREFIX}_accounts, ${TABLE_PREFIX}_branches, ${TABLE_PREFIX}_tellers, ${TABLE_PREFIX}_history CASCADE;"

    db_exec_quiet "CREATE TABLE ${TABLE_PREFIX}_branches (bid INT PRIMARY KEY, bbalance INT, filler CHAR(88));"
    db_exec_quiet "CREATE TABLE ${TABLE_PREFIX}_tellers (tid INT PRIMARY KEY, bid INT, tbalance INT, filler CHAR(84));"
    db_exec_quiet "CREATE TABLE ${TABLE_PREFIX}_accounts (aid INT PRIMARY KEY, bid INT, abalance INT, filler CHAR(84));"
    db_exec_quiet "CREATE TABLE ${TABLE_PREFIX}_history (tid INT, bid INT, aid INT, delta INT, mtime TIMESTAMP, filler CHAR(22));"

    # Insert branches and tellers (small data, single batch)
    log_info "Inserting branches ($BRANCH_ROWS rows)..."
    local t_start=$(date +%s.%N)
    db_exec_quiet "INSERT INTO ${TABLE_PREFIX}_branches SELECT s, 0, '' FROM generate_series(1, $BRANCH_ROWS) AS s;"
    local t_end=$(date +%s.%N)
    local t_dur=$(echo "$t_end - $t_start" | bc)
    echo "  done, ${t_dur}s"

    log_info "Inserting tellers ($TELLER_ROWS rows)..."
    t_start=$(date +%s.%N)
    db_exec_quiet "INSERT INTO ${TABLE_PREFIX}_tellers SELECT s, ((s-1) % $BRANCH_ROWS + 1), 0, '' FROM generate_series(1, $TELLER_ROWS) AS s;"
    t_end=$(date +%s.%N)
    t_dur=$(echo "$t_end - $t_start" | bc)
    echo "  done, ${t_dur}s"

    # Insert accounts in batches with progress
    local total_batches=$((ACCOUNT_ROWS / BATCH_SIZE))
    log_info "Inserting accounts ($ACCOUNT_ROWS rows, $total_batches batches of $BATCH_SIZE)..."

    t_start=$(date +%s.%N)
    local done_rows=0
    for batch in $(seq 1 $total_batches); do
        local batch_start=$(( (batch - 1) * BATCH_SIZE + 1 ))
        local batch_end=$(( batch * BATCH_SIZE ))

        db_exec_quiet "INSERT INTO ${TABLE_PREFIX}_accounts SELECT s, ((s-1) % $BRANCH_ROWS + 1), 0, '' FROM generate_series($batch_start, $batch_end) AS s;"

        done_rows=$((done_rows + BATCH_SIZE))
        local now=$(date +%s.%N)
        local elapsed=$(echo "$now - $t_start" | bc)
        local rows_per_sec=$(echo "scale=1; $done_rows / $elapsed" | bc)
        local remaining=$(echo "scale=1; ($ACCOUNT_ROWS - $done_rows) / $rows_per_sec" | bc)
        echo "  batch $batch/$total_batches: $done_rows/$ACCOUNT_ROWS rows, ${elapsed}s elapsed, ~${remaining}s remaining, ${rows_per_sec} rows/s"
    done

    t_end=$(date +%s.%N)
    t_dur=$(echo "$t_end - $t_start" | bc)
    echo "  accounts done, total ${t_dur}s"

    # Create indexes with timing
    log_info "Creating indexes..."
    t_start=$(date +%s.%N)
    db_exec_quiet "CREATE INDEX idx_${TABLE_PREFIX}_accounts_bid ON ${TABLE_PREFIX}_accounts(bid);"
    t_end=$(date +%s.%N)
    t_dur=$(echo "$t_end - $t_start" | bc)
    echo "  idx_accounts_bid done, ${t_dur}s"

    t_start=$(date +%s.%N)
    db_exec_quiet "CREATE INDEX idx_${TABLE_PREFIX}_tellers_bid ON ${TABLE_PREFIX}_tellers(bid);"
    t_end=$(date +%s.%N)
    t_dur=$(echo "$t_end - $t_start" | bc)
    echo "  idx_tellers_bid done, ${t_dur}s"

    # Vacuum analyze with timing
    log_info "Running VACUUM ANALYZE..."
    t_start=$(date +%s.%N)
    db_exec_quiet "VACUUM ANALYZE ${TABLE_PREFIX}_branches;"
    db_exec_quiet "VACUUM ANALYZE ${TABLE_PREFIX}_tellers;"
    db_exec_quiet "VACUUM ANALYZE ${TABLE_PREFIX}_accounts;"
    t_end=$(date +%s.%N)
    t_dur=$(echo "$t_end - $t_start" | bc)
    echo "  vacuum analyze done, ${t_dur}s"

    log_info "Initialization complete!"
    log_info "Total data size:"
    db_exec "SELECT 'branches: ' || count(*) FROM ${TABLE_PREFIX}_branches; SELECT 'tellers: ' || count(*) FROM ${TABLE_PREFIX}_tellers; SELECT 'accounts: ' || count(*) FROM ${TABLE_PREFIX}_accounts;"
}

# Run single transaction - TPC-B like
run_transaction() {
    local scale=$1
    local prefix=$2

    local aid=$((RANDOM % (scale * 100000) + 1))
    local bid=$((RANDOM % scale + 1))
    local tid=$((RANDOM % (scale * 10) + 1))
    local delta=$(((RANDOM % 10000) - 5000))

    if [ -n "$DB_PASS" ]; then
        $DB_CLIENT "$(get_conn_str)" -q -t > /dev/null 2>&1 << EOF
BEGIN;
UPDATE ${prefix}_accounts SET abalance = abalance + $delta WHERE aid = $aid;
SELECT abalance FROM ${prefix}_accounts WHERE aid = $aid;
UPDATE ${prefix}_tellers SET tbalance = tbalance + $delta WHERE tid = $tid;
UPDATE ${prefix}_branches SET bbalance = bbalance + $delta WHERE bid = $bid;
INSERT INTO ${prefix}_history (tid, bid, aid, delta, mtime) VALUES ($tid, $bid, $aid, $delta, CURRENT_TIMESTAMP);
COMMIT;
EOF
    else
        $DB_CLIENT $(get_conn_opts) -q -t > /dev/null 2>&1 << EOF
BEGIN;
UPDATE ${prefix}_accounts SET abalance = abalance + $delta WHERE aid = $aid;
SELECT abalance FROM ${prefix}_accounts WHERE aid = $aid;
UPDATE ${prefix}_tellers SET tbalance = tbalance + $delta WHERE tid = $tid;
UPDATE ${prefix}_branches SET bbalance = bbalance + $delta WHERE bid = $bid;
INSERT INTO ${prefix}_history (tid, bid, aid, delta, mtime) VALUES ($tid, $bid, $aid, $delta, CURRENT_TIMESTAMP);
COMMIT;
EOF
    fi
}

# Print progress line (append, not overwrite)
print_progress() {
    local elapsed=$1
    local total_done=$2
    local tps=$3
    echo "  [${elapsed}s] txns: ${total_done}, tps: ${tps}"
}

# Run benchmark with single client (transaction count mode)
run_benchmark_single() {
    local scale=$1
    local txns=$2

    log_info "Running benchmark: $txns transactions with 1 client"

    local start_time=$(date +%s.%N)
    local start_sec=$(date +%s)
    local count=0
    local last_report=$((start_sec))

    for i in $(seq 1 $txns); do
        run_transaction $scale $TABLE_PREFIX
        count=$((count + 1))

        local now=$(date +%s)
        if [ $((now - last_report)) -ge 3 ]; then
            local elapsed=$((now - start_sec))
            local tps=$(echo "scale=0; $count / $elapsed" | bc)
            print_progress $elapsed $count $tps
            last_report=$now
        fi
    done

    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)
    local tps=$(echo "scale=2; $txns / $duration" | bc)

    echo ""
    log_info "Benchmark Results:"
    echo "============================================"
    echo "  Database:            $DB_TYPE"
    echo "  Clients:             1"
    echo "  Transactions:        $txns"
    echo "  Duration:            ${duration}s"
    echo "  TPS (transactions/s): ${tps}"
    echo "============================================"
}

# Run benchmark with multiple concurrent clients (transaction count mode)
run_benchmark_multi() {
    local scale=$1
    local txns=$2
    local clients=$3

    log_info "Running benchmark: $txns transactions per client, $clients concurrent clients"

    local start_time=$(date +%s.%N)
    local start_sec=$(date +%s)
    local tmp_dir=$(mktemp -d)
    local pids=()

    # Export connection info for sub-processes
    local export_client="$DB_CLIENT"
    local export_pass="$DB_PASS"
    local export_conn_opts="$(get_conn_opts)"
    local export_conn_str="$(get_conn_str)"

    for c in $(seq 1 $clients); do
        (
            local count=0
            for i in $(seq 1 $txns); do
                local aid=$((RANDOM % (scale * 100000) + 1))
                local bid=$((RANDOM % scale + 1))
                local tid=$((RANDOM % (scale * 10) + 1))
                local delta=$(((RANDOM % 10000) - 5000))

                if [ -n "$export_pass" ]; then
                    $export_client "$export_conn_str" -q -t > /dev/null 2>&1 << EOF
BEGIN;
UPDATE ${TABLE_PREFIX}_accounts SET abalance = abalance + $delta WHERE aid = $aid;
SELECT abalance FROM ${TABLE_PREFIX}_accounts WHERE aid = $aid;
UPDATE ${TABLE_PREFIX}_tellers SET tbalance = tbalance + $delta WHERE tid = $tid;
UPDATE ${TABLE_PREFIX}_branches SET bbalance = bbalance + $delta WHERE bid = $bid;
INSERT INTO ${TABLE_PREFIX}_history (tid, bid, aid, delta, mtime) VALUES ($tid, $bid, $aid, $delta, CURRENT_TIMESTAMP);
COMMIT;
EOF
                else
                    $export_client $export_conn_opts -q -t > /dev/null 2>&1 << EOF
BEGIN;
UPDATE ${TABLE_PREFIX}_accounts SET abalance = abalance + $delta WHERE aid = $aid;
SELECT abalance FROM ${TABLE_PREFIX}_accounts WHERE aid = $aid;
UPDATE ${TABLE_PREFIX}_tellers SET tbalance = tbalance + $delta WHERE tid = $tid;
UPDATE ${TABLE_PREFIX}_branches SET bbalance = bbalance + $delta WHERE bid = $bid;
INSERT INTO ${TABLE_PREFIX}_history (tid, bid, aid, delta, mtime) VALUES ($tid, $bid, $aid, $delta, CURRENT_TIMESTAMP);
COMMIT;
EOF
                fi
                count=$((count + 1))
                echo $count > "$tmp_dir/txn_$c"
            done
        ) &
        pids+=($!)
    done

    # Print progress every second
    local last_report=$((start_sec))
    while true; do
        local all_done=true
        for pid in "${pids[@]}"; do
            if kill -0 $pid 2>/dev/null; then
                all_done=false
                break
            fi
        done

        local now=$(date +%s)
        if [ $((now - last_report)) -ge 1 ] || [ "$all_done" = true ]; then
            local total_done=0
            for c in $(seq 1 $clients); do
                local c_count=$(cat "$tmp_dir/txn_$c" 2>/dev/null || echo 0)
                total_done=$((total_done + c_count))
            done
            local elapsed=$((now - start_sec))
            local tps=$(echo "scale=0; $total_done / $elapsed" | bc)
            print_progress $elapsed $total_done $tps
            last_report=$now
        fi

        if [ "$all_done" = true ]; then
            break
        fi

        sleep 0.2
    done

    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)
    local total_txns=$((txns * clients))
    local tps=$(echo "scale=2; $total_txns / $duration" | bc)

    rm -rf "$tmp_dir"

    echo ""
    log_info "Benchmark Results:"
    echo "============================================"
    echo "  Database:            $DB_TYPE"
    echo "  Clients:             $clients"
    echo "  Transactions/client: $txns"
    echo "  Total transactions:  $total_txns"
    echo "  Duration:            ${duration}s"
    echo "  TPS (transactions/s): ${tps}"
    echo "============================================"
}

# Run benchmark with multiple concurrent clients (time-based mode)
run_benchmark_time() {
    local scale=$1
    local clients=$2
    local duration_secs=$3
    local prefix=$TABLE_PREFIX

    log_info "Running benchmark: $clients concurrent clients for $duration_secs seconds"

    local start_time=$(date +%s)
    local end_time=$((start_time + duration_secs))
    local tmp_dir=$(mktemp -d)
    local pids=()

    # Export connection info for sub-processes
    local export_client="$DB_CLIENT"
    local export_pass="$DB_PASS"
    local export_conn_opts="$(get_conn_opts)"
    local export_conn_str="$(get_conn_str)"

    for c in $(seq 1 $clients); do
        (
            local count=0
            while [ $(date +%s) -lt $end_time ]; do
                local aid=$((RANDOM % (scale * 100000) + 1))
                local bid=$((RANDOM % scale + 1))
                local tid=$((RANDOM % (scale * 10) + 1))
                local delta=$(((RANDOM % 10000) - 5000))

                if [ -n "$export_pass" ]; then
                    $export_client "$export_conn_str" -q -t > /dev/null 2>&1 << EOF
BEGIN;
UPDATE ${prefix}_accounts SET abalance = abalance + $delta WHERE aid = $aid;
SELECT abalance FROM ${prefix}_accounts WHERE aid = $aid;
UPDATE ${prefix}_tellers SET tbalance = tbalance + $delta WHERE tid = $tid;
UPDATE ${prefix}_branches SET bbalance = bbalance + $delta WHERE bid = $bid;
INSERT INTO ${prefix}_history (tid, bid, aid, delta, mtime) VALUES ($tid, $bid, $aid, $delta, CURRENT_TIMESTAMP);
COMMIT;
EOF
                else
                    $export_client $export_conn_opts -q -t > /dev/null 2>&1 << EOF
BEGIN;
UPDATE ${prefix}_accounts SET abalance = abalance + $delta WHERE aid = $aid;
SELECT abalance FROM ${prefix}_accounts WHERE aid = $aid;
UPDATE ${prefix}_tellers SET tbalance = tbalance + $delta WHERE tid = $tid;
UPDATE ${prefix}_branches SET bbalance = bbalance + $delta WHERE bid = $bid;
INSERT INTO ${prefix}_history (tid, bid, aid, delta, mtime) VALUES ($tid, $bid, $aid, $delta, CURRENT_TIMESTAMP);
COMMIT;
EOF
                fi
                count=$((count + 1))
                echo $count > "$tmp_dir/txn_$c"
            done
        ) &
        pids+=($!)
    done

    # Print progress every second
    local last_report=$((start_time))
    while [ $(date +%s) -lt $end_time ]; do
        local now=$(date +%s)
        if [ $((now - last_report)) -ge 3 ]; then
            local total_done=0
            for c in $(seq 1 $clients); do
                local c_count=$(cat "$tmp_dir/txn_$c" 2>/dev/null || echo 0)
                total_done=$((total_done + c_count))
            done
            local elapsed=$((now - start_time))
            local tps=$(echo "scale=0; $total_done / $elapsed" | bc)
            print_progress $elapsed $total_done $tps
            last_report=$now
        fi
        sleep 0.2
    done

    # Wait for all clients to finish
    for pid in "${pids[@]}"; do
        wait $pid
    done

    # Final count
    local total_txns=0
    for c in $(seq 1 $clients); do
        local count=$(cat "$tmp_dir/txn_$c")
        total_txns=$((total_txns + count))
    done

    rm -rf "$tmp_dir"

    local actual_duration=$(echo "$(date +%s) - $start_time" | bc)
    local tps=$(echo "scale=2; $total_txns / $actual_duration" | bc)

    echo ""
    log_info "Benchmark Results:"
    echo "============================================"
    echo "  Database:            $DB_TYPE"
    echo "  Clients:             $clients"
    echo "  Duration:            ${actual_duration}s"
    echo "  Total transactions:  $total_txns"
    echo "  TPS (transactions/s): ${tps}"
    echo "============================================"
}

# Extract command word from arguments first, then parse options
# This supports both: "init -s 10" and "-s 10 init"
CMD=""
for arg in "$@"; do
    case $arg in
        init|benchmark) CMD="$arg" ;;
    esac
done

if [ -n "$CMD" ]; then
    case $CMD in
        init) MODE="init" ;;
        benchmark) MODE="benchmark" ;;
    esac
fi

# Rebuild positional args without the command word for getopts
NEW_ARGS=()
for arg in "$@"; do
    case $arg in
        init|benchmark) ;;
        *) NEW_ARGS+=("$arg") ;;
    esac
done
set -- "${NEW_ARGS[@]}"
OPTIND=1

while getopts "h:p:d:U:W:t:P:s:c:n:T:" opt; do
    case $opt in
        h) DB_HOST="$OPTARG" ;;
        p) DB_PORT="$OPTARG" ;;
        d) DB_NAME="$OPTARG" ;;
        U) DB_USER="$OPTARG" ;;
        W) DB_PASS="$OPTARG" ;;
        t) DB_TYPE="$OPTARG" ;;
        P) TABLE_PREFIX="$OPTARG" ;;
        s) INIT_SCALE="$OPTARG" ;;
        c) CLIENTS="$OPTARG" ;;
        n) TRANSACTIONS="$OPTARG" ;;
        T) DURATION="$OPTARG" ;;
        *) usage ;;
    esac
done

# Main execution
check_client

echo ""
echo "=========================================="
echo "   db_shell_bench - Database Benchmark"
echo "=========================================="
echo "Database Type: $DB_TYPE"
echo "Client:        $DB_CLIENT"
echo "Host: $DB_HOST"
echo "Port: $DB_PORT"
echo "Database: $DB_NAME"
echo "User: $DB_USER"
echo "Table Prefix: $TABLE_PREFIX"
echo "=========================================="
echo ""

check_connection

case $MODE in
    init)
        init_database
        ;;
    benchmark)
        # Get scale factor from existing data
        SCALE=$(db_exec "SELECT count(*) FROM ${TABLE_PREFIX}_branches;" | tr -d '[:space:]')
        if [ -z "$SCALE" ] || [ "$SCALE" -eq 0 ]; then
            log_error "Test tables not found. Run '$0 init -P $TABLE_PREFIX' first."
            exit 1
        fi

        # Time-based test
        if [ "$DURATION" -gt 0 ]; then
            if [ "$CLIENTS" -eq 1 ]; then
                log_warn "Time-based test with 1 client: using txn count mode"
                run_benchmark_single $SCALE $TRANSACTIONS
            else
                run_benchmark_time $SCALE $CLIENTS $DURATION
            fi
        # Transaction-based test
        elif [ "$TRANSACTIONS" -gt 0 ]; then
            if [ "$CLIENTS" -eq 1 ]; then
                run_benchmark_single $SCALE $TRANSACTIONS
            else
                run_benchmark_multi $SCALE $TRANSACTIONS $CLIENTS
            fi
        else
            log_error "Please specify either -n TXNS or -T SECS for benchmark"
            usage
        fi
        ;;
esac