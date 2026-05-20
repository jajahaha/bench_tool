#!/bin/bash
#
# Test suite for db_shell_bench.sh
#

set -e

# Test configuration
SCRIPT="./db_shell_bench.sh"
DB_HOST="127.0.0.1"
DB_PORT="5432"
DB_NAME="postgres"
DB_USER="lcj"
TEST_PREFIX="testbench"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

# Log functions
log_test() {
    echo -e "${BLUE}[TEST]${NC} $1"
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

log_skip() {
    echo -e "${YELLOW}[SKIP]${NC} $1"
}

# Cleanup function
cleanup() {
    echo ""
    echo -e "${GREEN}[INFO]${NC} Cleaning up test tables..."
    psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -c "DROP TABLE IF EXISTS ${TEST_PREFIX}_accounts, ${TEST_PREFIX}_branches, ${TEST_PREFIX}_tellers, ${TEST_PREFIX}_history CASCADE;" 2>/dev/null || true
    psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -c "DROP TABLE IF EXISTS ${TEST_PREFIX}5_accounts, ${TEST_PREFIX}5_branches, ${TEST_PREFIX}5_tellers, ${TEST_PREFIX}5_history CASCADE;" 2>/dev/null || true
    psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -c "DROP TABLE IF EXISTS custombench_accounts, custombench_branches, custombench_tellers, custombench_history CASCADE;" 2>/dev/null || true
}

# ============================================
# Test Cases
# ============================================

# Test 1: Help/Usage display
test_help() {
    log_test "Test 1: Help/Usage display"

    if $SCRIPT --help 2>&1 | grep -q "Usage:"; then
        log_pass "Help message displayed correctly"
    else
        log_fail "Help message not displayed"
    fi
}

# Test 2: Invalid option handling
test_invalid_option() {
    log_test "Test 2: Invalid option handling"

    if $SCRIPT -x 2>&1 | grep -q "Usage:"; then
        log_pass "Invalid option rejected with usage message"
    else
        log_fail "Invalid option not handled properly"
    fi
}

# Test 3: Database connection
test_connection() {
    log_test "Test 3: Database connection"

    if $SCRIPT -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -P conn_test -t 1 benchmark 2>&1 | grep -q "connection successful"; then
        log_pass "Database connection successful"
    else
        log_fail "Database connection failed"
    fi
}

# Test 4: Initialization with scale factor 1
test_init_scale1() {
    log_test "Test 4: Initialization (scale=1)"

    local output=$($SCRIPT -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -P $TEST_PREFIX -s 1 init 2>&1)

    if echo "$output" | grep -q "Initialization complete"; then
        log_pass "Initialization completed successfully"

        # Verify tables exist and have correct row counts
        local branches=$(psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -c "SELECT count(*) FROM ${TEST_PREFIX}_branches;" | tr -d '[:space:]')
        local tellers=$(psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -c "SELECT count(*) FROM ${TEST_PREFIX}_tellers;" | tr -d '[:space:]')
        local accounts=$(psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -c "SELECT count(*) FROM ${TEST_PREFIX}_accounts;" | tr -d '[:space:]')

        if [ "$branches" -eq 1 ] && [ "$tellers" -eq 10 ] && [ "$accounts" -eq 100000 ]; then
            log_pass "Correct row counts: branches=1, tellers=10, accounts=100000"
        else
            log_fail "Incorrect row counts: branches=$branches, tellers=$tellers, accounts=$accounts"
        fi
    else
        log_fail "Initialization failed"
    fi
}

# Test 5: Initialization with scale factor 5
test_init_scale5() {
    log_test "Test 5: Initialization (scale=5)"

    local output=$($SCRIPT -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -P ${TEST_PREFIX}5 -s 5 init 2>&1)

    if echo "$output" | grep -q "Initialization complete"; then
        log_pass "Scale=5 initialization completed"

        local accounts=$(psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -c "SELECT count(*) FROM ${TEST_PREFIX}5_accounts;" | tr -d '[:space:]')

        if [ "$accounts" -eq 500000 ]; then
            log_pass "Correct accounts count: 500000"
            # Cleanup
            psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -c "DROP TABLE IF EXISTS ${TEST_PREFIX}5_accounts, ${TEST_PREFIX}5_branches, ${TEST_PREFIX}5_tellers, ${TEST_PREFIX}5_history CASCADE;" 2>/dev/null
        else
            log_fail "Incorrect accounts count: $accounts"
        fi
    else
        log_fail "Scale=5 initialization failed"
    fi
}

# Test 6: Benchmark without init (should fail)
test_benchmark_no_init() {
    log_test "Test 6: Benchmark without initialization (should fail)"

    if $SCRIPT -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -P nonexistent -t 1 benchmark 2>&1 | grep -q "Test tables not found"; then
        log_pass "Correctly rejected benchmark without init"
    else
        log_fail "Did not reject benchmark without init"
    fi
}

# Test 7: Single client transaction-based benchmark
test_single_client_txn() {
    log_test "Test 7: Single client transaction-based benchmark"

    local output=$($SCRIPT -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -P $TEST_PREFIX -c 1 -t 10 benchmark 2>&1)

    if echo "$output" | grep -q "TPS"; then
        log_pass "Single client benchmark completed with TPS result"

        # Extract TPS value and verify it's a number
        local tps=$(echo "$output" | grep "TPS" | grep -oE '[0-9]+\.[0-9]+')
        if [ -n "$tps" ]; then
            log_pass "Valid TPS value: $tps"
        else
            log_fail "Invalid TPS value"
        fi
    else
        log_fail "Single client benchmark failed"
    fi
}

# Test 8: Multi-client transaction-based benchmark
test_multi_client_txn() {
    log_test "Test 8: Multi-client transaction-based benchmark (4 clients)"

    local output=$($SCRIPT -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -P $TEST_PREFIX -c 4 -t 20 benchmark 2>&1)

    if echo "$output" | grep -q "Clients:.*4" && echo "$output" | grep -q "TPS"; then
        log_pass "Multi-client benchmark completed"

        local total_txns=$(echo "$output" | grep "Total transactions" | grep -oE '[0-9]+')
        if [ "$total_txns" -eq 80 ]; then
            log_pass "Correct total transactions: 80 (4 clients * 20 txns)"
        else
            log_fail "Incorrect total transactions: $total_txns"
        fi
    else
        log_fail "Multi-client benchmark failed"
    fi
}

# Test 9: Time-based benchmark
test_time_based() {
    log_test "Test 9: Time-based benchmark (5 clients, 10 seconds)"

    local output=$($SCRIPT -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -P $TEST_PREFIX -c 5 -T 10 benchmark 2>&1)

    if echo "$output" | grep -q "Clients:.*5" && echo "$output" | grep -q "Duration:.*10" && echo "$output" | grep -q "TPS"; then
        log_pass "Time-based benchmark completed"

        local duration=$(echo "$output" | grep "Duration:" | grep -oE '[0-9]+')
        if [ "$duration" -ge 10 ] && [ "$duration" -le 12 ]; then
            log_pass "Correct duration: ~10 seconds ($duration)"
        else
            log_fail "Incorrect duration: $duration"
        fi
    else
        log_fail "Time-based benchmark failed"
    fi
}

# Test 10: Missing required benchmark parameters
test_missing_benchmark_params() {
    log_test "Test 10: Missing benchmark parameters (should fail)"

    if $SCRIPT -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -P $TEST_PREFIX benchmark 2>&1 | grep -q "specify either"; then
        log_pass "Correctly rejected benchmark without -t or -T"
    else
        log_fail "Did not reject benchmark without parameters"
    fi
}

# Test 11: Connection parameters display
test_connection_display() {
    log_test "Test 11: Connection parameters display"

    local output=$($SCRIPT -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -P $TEST_PREFIX -t 1 benchmark 2>&1)

    if echo "$output" | grep -q "Host: $DB_HOST" && \
       echo "$output" | grep -q "Port: $DB_PORT" && \
       echo "$output" | grep -q "Database: $DB_NAME" && \
       echo "$output" | grep -q "User: $DB_USER"; then
        log_pass "All connection parameters displayed correctly"
    else
        log_fail "Connection parameters not displayed correctly"
    fi
}

# Test 12: Transaction correctness (verify data changes)
test_transaction_correctness() {
    log_test "Test 12: Transaction correctness"

    # Get initial balance sum
    local initial_sum=$(psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -c "SELECT sum(abalance) FROM ${TEST_PREFIX}_accounts;" | tr -d '[:space:]')

    # Run some transactions
    $SCRIPT -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -P $TEST_PREFIX -c 1 -t 5 benchmark > /dev/null 2>&1

    # Get final balance sum (should be different since transactions add random deltas)
    local final_sum=$(psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -c "SELECT sum(abalance) FROM ${TEST_PREFIX}_accounts;" | tr -d '[:space:]')

    # Check history records were created
    local history_count=$(psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -c "SELECT count(*) FROM ${TEST_PREFIX}_history;" | tr -d '[:space:]')

    if [ "$history_count" -ge 5 ]; then
        log_pass "History records created: $history_count"
    else
        log_fail "Insufficient history records: $history_count"
    fi
}

# Test 13: Different table prefix
test_table_prefix() {
    log_test "Test 13: Different table prefix"

    local prefix="custombench"

    # Initialize with custom prefix
    $SCRIPT -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -P $prefix -s 1 init > /dev/null 2>&1

    # Check tables exist with custom prefix
    local tables=$(psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -c "SELECT count(*) FROM information_schema.tables WHERE table_name LIKE '${prefix}%';" | tr -d '[:space:]')

    if [ "$tables" -eq 4 ]; then
        log_pass "Custom prefix tables created: 4 tables"

        # Cleanup
        psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -c "DROP TABLE IF EXISTS ${prefix}_accounts, ${prefix}_branches, ${prefix}_tellers, ${prefix}_history CASCADE;" 2>/dev/null
    else
        log_fail "Custom prefix tables not created correctly: $tables tables"
    fi
}

# Test 14: Invalid host connection
test_invalid_host() {
    log_test "Test 14: Invalid host connection (should fail)"

    if $SCRIPT -h invalid_host -p 9999 -U invalid -d invalid -P test -t 1 benchmark 2>&1 | grep -q "Cannot connect"; then
        log_pass "Correctly handled invalid connection"
    else
        log_fail "Did not handle invalid connection properly"
    fi
}

# Test 15: Long duration benchmark
test_long_duration() {
    log_test "Test 15: Long duration benchmark (5 clients, 30 seconds)"

    local start_time=$(date +%s)
    local output=$($SCRIPT -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -P $TEST_PREFIX -c 5 -T 30 benchmark 2>&1)
    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))

    if echo "$output" | grep -q "TPS"; then
        log_pass "Long duration benchmark completed in ${elapsed}s"

        local total_txns=$(echo "$output" | grep "Total transactions" | grep -oE '[0-9]+')
        if [ "$total_txns" -gt 0 ]; then
            log_pass "Transactions executed: $total_txns"
        else
            log_fail "No transactions executed"
        fi
    else
        log_fail "Long duration benchmark failed"
    fi
}

# ============================================
# Main Test Runner
# ============================================

echo ""
echo "============================================"
echo "   db_shell_bench.sh Test Suite"
echo "============================================"
echo "Database: $DB_HOST:$DB_PORT/$DB_NAME"
echo "User: $DB_USER"
echo "Test Prefix: $TEST_PREFIX"
echo "============================================"
echo ""

# Check psql availability
if ! command -v psql &> /dev/null; then
    log_fail "psql not found, cannot run tests"
    exit 1
fi

# Check script exists
if [ ! -f "$SCRIPT" ]; then
    log_fail "Script not found: $SCRIPT"
    exit 1
fi

# Run tests
echo -e "${BLUE}Starting tests...${NC}"
echo ""

test_help
test_invalid_option
test_connection
test_init_scale1
test_init_scale5
test_benchmark_no_init
test_single_client_txn
test_multi_client_txn
test_time_based
test_missing_benchmark_params
test_connection_display
test_transaction_correctness
test_table_prefix
test_invalid_host
test_long_duration

# Cleanup
cleanup

# Summary
echo ""
echo "============================================"
echo "   Test Results Summary"
echo "============================================"
echo -e "Total tests:  ${BLUE}$TESTS_TOTAL${NC}"
echo -e "Passed:       ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed:       ${RED}$TESTS_FAILED${NC}"
echo "============================================"

if [ "$TESTS_FAILED" -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed.${NC}"
    exit 1
fi