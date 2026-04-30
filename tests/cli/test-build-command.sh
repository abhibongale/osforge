#!/bin/bash
# Test script for osforge build CLI command
# Tests argument parsing, error handling, and command validation
# Does NOT actually build images (too slow for CI)

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Functions
log_test() {
    echo -e "${BLUE}TEST:${NC} $1"
}

log_pass() {
    echo -e "${GREEN}✅ PASS${NC}"
    ((TESTS_PASSED++))
    echo ""
}

log_fail() {
    echo -e "${RED}❌ FAIL:${NC} $1"
    ((TESTS_FAILED++))
    echo ""
}

run_test() {
    ((TESTS_RUN++))
}

# Test: osforge build without arguments shows error
test_build_no_args() {
    run_test
    log_test "osforge build without arguments shows error"

    if output=$(osforge build 2>&1); then
        log_fail "Should exit with error"
        return 1
    fi

    if echo "$output" | grep -q "Build type required"; then
        log_pass
        return 0
    else
        log_fail "Expected 'Build type required' error"
        echo "Got: $output"
        return 1
    fi
}

# Test: osforge build --deps --full shows error
test_build_deps_and_full() {
    run_test
    log_test "osforge build --deps --full shows mutual exclusivity error"

    if output=$(osforge build --deps --full 2>&1); then
        log_fail "Should exit with error"
        return 1
    fi

    if echo "$output" | grep -q "Cannot specify both --deps and --full"; then
        log_pass
        return 0
    else
        log_fail "Expected mutual exclusivity error"
        echo "Got: $output"
        return 1
    fi
}

# Test: osforge build --status works
test_build_status() {
    run_test
    log_test "osforge build --status works without requiring build type"

    if output=$(osforge build --status 2>&1); then
        if echo "$output" | grep -q "Checking build status"; then
            log_pass
            return 0
        else
            log_fail "Expected build status output"
            echo "Got: $output"
            return 1
        fi
    else
        log_fail "Command should succeed"
        return 1
    fi
}

# Test: osforge build --validate works
test_build_validate() {
    run_test
    log_test "osforge build --validate works without requiring build type"

    # This will likely fail because no image exists, but it should run
    output=$(osforge build --validate 2>&1 || true)

    if echo "$output" | grep -q "Validating image"; then
        log_pass
        return 0
    else
        log_fail "Expected validation output"
        echo "Got: $output"
        return 1
    fi
}

# Test: osforge build --invalid-flag shows error
test_build_invalid_flag() {
    run_test
    log_test "osforge build --invalid-flag shows error"

    if output=$(osforge build --invalid-flag 2>&1); then
        log_fail "Should exit with error"
        return 1
    fi

    if echo "$output" | grep -q "Unknown option"; then
        log_pass
        return 0
    else
        log_fail "Expected 'Unknown option' error"
        echo "Got: $output"
        return 1
    fi
}

# Test: osforge build --deps --tag works (doesn't run build, just validates args)
test_build_deps_with_tag() {
    run_test
    log_test "osforge build --deps --tag mytag validates arguments"

    # We'll interrupt this before it actually builds
    # Just check that it gets past argument parsing
    output=$(timeout 2 osforge build --deps --tag mytag 2>&1 || true)

    if echo "$output" | grep -q "Build type required"; then
        log_fail "Should accept --deps argument"
        echo "Got: $output"
        return 1
    elif echo "$output" | grep -q "Unknown option"; then
        log_fail "Should accept --tag argument"
        echo "Got: $output"
        return 1
    else
        # If we get to build configuration or requirements check, args parsed OK
        if echo "$output" | grep -qE "(Build configuration|Checking build requirements)"; then
            log_pass
            return 0
        else
            log_fail "Unexpected output"
            echo "Got: $output"
            return 1
        fi
    fi
}

# Test: osforge build --full --push validates arguments
test_build_full_with_push() {
    run_test
    log_test "osforge build --full --push validates arguments"

    output=$(timeout 2 osforge build --full --push 2>&1 || true)

    if echo "$output" | grep -qE "(Build configuration|Checking build requirements)"; then
        log_pass
        return 0
    else
        log_fail "Arguments should be accepted"
        echo "Got: $output"
        return 1
    fi
}

# Test: osforge build --deps --no-cache validates arguments
test_build_with_no_cache() {
    run_test
    log_test "osforge build --deps --no-cache validates arguments"

    output=$(timeout 2 osforge build --deps --no-cache 2>&1 || true)

    if echo "$output" | grep -q "No cache: true"; then
        log_pass
        return 0
    else
        log_fail "Should show no-cache option"
        echo "Got: $output"
        return 1
    fi
}

# Test: osforge help shows build command
test_help_includes_build() {
    run_test
    log_test "osforge help includes build command documentation"

    output=$(osforge help)

    local errors=0

    if ! echo "$output" | grep -q "build \[options\]"; then
        log_fail "Help should list build command"
        ((errors++))
    fi

    if ! echo "$output" | grep -q "BUILD OPTIONS"; then
        log_fail "Help should have BUILD OPTIONS section"
        ((errors++))
    fi

    if ! echo "$output" | grep -q "\-\-deps"; then
        log_fail "Help should document --deps flag"
        ((errors++))
    fi

    if ! echo "$output" | grep -q "\-\-full"; then
        log_fail "Help should document --full flag"
        ((errors++))
    fi

    if [ $errors -eq 0 ]; then
        log_pass
        return 0
    else
        return 1
    fi
}

# Main test runner
main() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "OSForge Build Command Tests"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Check osforge is available
    if ! command -v osforge &> /dev/null; then
        echo -e "${RED}ERROR:${NC} osforge command not found"
        echo "Please install osforge first: ./scripts/install.sh --dev"
        exit 1
    fi

    echo "Running CLI argument parsing tests..."
    echo ""

    # Run all tests
    test_build_no_args || true
    test_build_deps_and_full || true
    test_build_status || true
    test_build_validate || true
    test_build_invalid_flag || true
    test_build_deps_with_tag || true
    test_build_full_with_push || true
    test_build_with_no_cache || true
    test_help_includes_build || true

    # Summary
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Test Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Tests run:    $TESTS_RUN"
    echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"

    if [ $TESTS_FAILED -gt 0 ]; then
        echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
        echo ""
        exit 1
    else
        echo ""
        echo -e "${GREEN}✅ All tests passed!${NC}"
        echo ""
        exit 0
    fi
}

# Run tests
main
