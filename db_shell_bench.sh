#!/bin/bash
#
# db_shell_bench - Database Benchmark Tool
# Supports PostgreSQL, OpenGauss and compatible databases
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
    -t TYPE     Database type: postgres, opengauss (default: postgres)
    -P PREFIX   Table name prefix (default: dbbench)
    -s SCALE    Scaling factor for initialization (default: 1)
    -c CLIENTS  Number of concurrent clients (default: 1)
    -n TXNS     Number of transactions per client (default: 0)
    -T SECS     Duration in seconds for time-based test (default: 0)

Examples:
    # PostgreSQL
    $0 -h localhost -p 5432 -U postgres init -s 10
    $0 -h localhost -p 5432 -U postgres -W mypass -c 4 -n 100 benchmark

    # OpenGauss
    $0 -t opengauss -h localhost -p 5433 -U gaussdb -W Enmotech@123 init -s 1
    $0 -t opengauss -h localhost -p 5433 -U gaussdb -W Enmotech@123 -c 4 -T 60 benchmark
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

# Get database client command
get_db_client() {
    case $DB_TYPE in
        postgres|opengauss)
            echo "psql"
            ;;
        *)
            log_error "Unsupported database type: $DB_TYPE"
            exit 1
            ;;
    esac
}

# Build connection options
get_conn_opts() {
    local client=$(get_db_client)
    local opts="-h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME"
    echo "$opts"
}

# Build connection string with password (for password auth)
get_conn_str() {
    if [ -n "$DB_PASS" ]; then
        local encoded_pass=$(url_encode "$DB_PASS")
        echo "postgresql://${DB_USER}:${encoded_pass}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
    else
        echo ""
    fi
}

# Execute SQL
db_exec() {
    local sql="$1"
    local client=$(get_db_client)

    if [ -n "$DB_PASS" ]; then
        # Use connection string with password
        $client "$(get_conn_str)" -t -c "$sql" 2>/dev/null
    else
        # Use standard connection options
        $client $(get_conn_opts) -t -c "$sql" 2>/dev/null
    fi
}

# Check database client availability
check_client() {
    local client=$(get_db_client)
    if ! command -v $client &> /dev/null; then
        log_error "$client not found. Please install database client tools."
        exit 1
    fi
}

# Check database connection
check_connection() {
    if ! db_exec "SELECT 1" &> /dev/null; then
        log_error "Cannot connect to database. Check your connection parameters."
        exit 1
    fi
    log_info "Database connection successful ($DB_TYPE)"
}

# Initialize test tables
init_database() {
    log_info "Initializing database with scale factor: $INIT_SCALE"

    local ACCOUNT_ROWS=$((INIT_SCALE * 100000))
    local BRANCH_ROWS=$INIT_SCALE
    local TELLER_ROWS=$((INIT_SCALE * 10))

    log_info "Creating tables..."
    log_info "  - ${TABLE_PREFIX}_accounts: $ACCOUNT_ROWS rows"
    log_info "  - ${TABLE_PREFIX}_branches: $BRANCH_ROWS rows"
    log_info "  - ${TABLE_PREFIX}_tellers:  $TELLER_ROWS rows"

    # Drop existing tables
    db_exec "DROP TABLE IF EXISTS ${TABLE_PREFIX}_accounts, ${TABLE_PREFIX}_branches, ${TABLE_PREFIX}_tellers, ${TABLE_PREFIX}_history CASCADE;"

    # Create tables
    db_exec "CREATE TABLE ${TABLE_PREFIX}_branches (bid INT PRIMARY KEY, bbalance INT, filler CHAR(88));"
    db_exec "CREATE TABLE ${TABLE_PREFIX}_tellers (tid INT PRIMARY KEY, bid INT, tbalance INT, filler CHAR(84));"
    db_exec "CREATE TABLE ${TABLE_PREFIX}_accounts (aid INT PRIMARY KEY, bid INT, abalance INT, filler CHAR(84));"
    db_exec "CREATE TABLE ${TABLE_PREFIX}_history (tid INT, bid INT, aid INT, delta INT, mtime TIMESTAMP, filler CHAR(22));"

    log_info "Inserting data using generate_series..."

    # Insert data
    db_exec "INSERT INTO ${TABLE_PREFIX}_branches SELECT s, 0, '' FROM generate_series(1, $BRANCH_ROWS) AS s;"
    db_exec "INSERT INTO ${TABLE_PREFIX}_tellers SELECT s, ((s-1) % $BRANCH_ROWS + 1), 0, '' FROM generate_series(1, $TELLER_ROWS) AS s;"

    log_info "  Generating $ACCOUNT_ROWS account records..."
    db_exec "INSERT INTO ${TABLE_PREFIX}_accounts SELECT s, ((s-1) % $BRANCH_ROWS + 1), 0, '' FROM generate_series(1, $ACCOUNT_ROWS) AS s;"

    # Create indexes
    log_info "Creating indexes..."
    db_exec "CREATE INDEX idx_${TABLE_PREFIX}_accounts_bid ON ${TABLE_PREFIX}_accounts(bid);"
    db_exec "CREATE INDEX idx_${TABLE_PREFIX}_tellers_bid ON ${TABLE_PREFIX}_tellers(bid);"

    # Vacuum analyze
    log_info "Running VACUUM ANALYZE..."
    db_exec "VACUUM ANALYZE ${TABLE_PREFIX}_branches;"
    db_exec "VACUUM ANALYZE ${TABLE_PREFIX}_tellers;"
    db_exec "VACUUM ANALYZE ${TABLE_PREFIX}_accounts;"

    log_info "Initialization complete!"
    log_info "Total data size:"
    db_exec "SELECT 'branches: ' || count(*) FROM ${TABLE_PREFIX}_branches; SELECT 'tellers: ' || count(*) FROM ${TABLE_PREFIX}_tellers; SELECT 'accounts: ' || count(*) FROM ${TABLE_PREFIX}_accounts;"
}

# Run single transaction - TPC-B like
run_transaction() {
    local scale=$1
    local prefix=$2
    local client=$(get_db_client)

    local aid=$((RANDOM % (scale * 100000) + 1))
    local bid=$((RANDOM % scale + 1))
    local tid=$((RANDOM % (scale * 10) + 1))
    local delta=$(((RANDOM % 10000) - 5000))

    # Run transaction
    if [ -n "$DB_PASS" ]; then
        $client "$(get_conn_str)" -q -t > /dev/null 2>&1 << EOF
BEGIN;
UPDATE ${prefix}_accounts SET abalance = abalance + $delta WHERE aid = $aid;
SELECT abalance FROM ${prefix}_accounts WHERE aid = $aid;
UPDATE ${prefix}_tellers SET tbalance = tbalance + $delta WHERE tid = $tid;
UPDATE ${prefix}_branches SET bbalance = bbalance + $delta WHERE bid = $bid;
INSERT INTO ${prefix}_history (tid, bid, aid, delta, mtime) VALUES ($tid, $bid, $aid, $delta, CURRENT_TIMESTAMP);
COMMIT;
EOF
    else
        $client $(get_conn_opts) -q -t > /dev/null 2>&1 << EOF
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

# Run benchmark with single client
run_benchmark_single() {
    local scale=$1
    local txns=$2

    log_info "Running benchmark: $txns transactions with 1 client"

    local start_time=$(date +%s.%N)

    for i in $(seq 1 $txns); do
        run_transaction $scale $TABLE_PREFIX
    done

    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)
    local tps=$(echo "scale=2; $txns / $duration" | bc)

    echo ""
    log_info "Benchmark Results:"
    echo "============================================"
    echo "  Database:            $DB_TYPE"
    echo "  Transactions:        $txns"
    echo "  Duration:            ${duration}s"
    echo "  TPS (transactions/s): ${tps}"
    echo "============================================"
}

# Run benchmark with multiple concurrent clients
run_benchmark_multi() {
    local scale=$1
    local txns=$2
    local clients=$3

    log_info "Running benchmark: $txns transactions per client, $clients concurrent clients"

    local start_time=$(date +%s.%N)
    local pids=()

    for c in $(seq 1 $clients); do
        (
            for i in $(seq 1 $txns); do
                run_transaction $scale $TABLE_PREFIX
            done
        ) &
        pids+=($!)
    done

    for pid in "${pids[@]}"; do
        wait $pid
    done

    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)
    local total_txns=$((txns * clients))
    local tps=$(echo "scale=2; $total_txns / $duration" | bc)

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

# Run benchmark with multiple concurrent clients for specified duration
run_benchmark_time() {
    local scale=$1
    local clients=$2
    local duration_secs=$3
    local prefix=$TABLE_PREFIX
    local client=$(get_db_client)

    log_info "Running benchmark: $clients concurrent clients for $duration_secs seconds"

    local start_time=$(date +%s)
    local end_time=$((start_time + duration_secs))
    local pids=()
    local tmp_dir=$(mktemp -d)

    for c in $(seq 1 $clients); do
        (
            local count=0
            while [ $(date +%s) -lt $end_time ]; do
                local aid=$((RANDOM % (scale * 100000) + 1))
                local bid=$((RANDOM % scale + 1))
                local tid=$((RANDOM % (scale * 10) + 1))
                local delta=$(((RANDOM % 10000) - 5000))

                if [ -n "$DB_PASS" ]; then
                    $client "$(get_conn_str)" -q -t > /dev/null 2>&1 << EOF
BEGIN;
UPDATE ${prefix}_accounts SET abalance = abalance + $delta WHERE aid = $aid;
SELECT abalance FROM ${prefix}_accounts WHERE aid = $aid;
UPDATE ${prefix}_tellers SET tbalance = tbalance + $delta WHERE tid = $tid;
UPDATE ${prefix}_branches SET bbalance = bbalance + $delta WHERE bid = $bid;
INSERT INTO ${prefix}_history (tid, bid, aid, delta, mtime) VALUES ($tid, $bid, $aid, $delta, CURRENT_TIMESTAMP);
COMMIT;
EOF
                else
                    $client $(get_conn_opts) -q -t > /dev/null 2>&1 << EOF
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
            done
            echo $count > "$tmp_dir/txn_$c"
        ) &
        pids+=($!)
    done

    for pid in "${pids[@]}"; do
        wait $pid
    done

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

# Parse arguments
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

shift $((OPTIND-1))

# Determine mode
if [ $# -gt 0 ]; then
    case $1 in
        init) MODE="init" ;;
        benchmark) MODE="benchmark" ;;
        *) usage ;;
    esac
fi

# Main execution
check_client

echo ""
echo "=========================================="
echo "   db_shell_bench - Database Benchmark"
echo "=========================================="
echo "Database Type: $DB_TYPE"
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