#!/bin/bash
# Run all OSForge tests

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "OSForge Test Suite"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

FAILED_TESTS=0

# CLI Tests
echo -e "${BLUE}Running CLI tests...${NC}"
echo ""
if ./cli/test-build-command.sh; then
    echo -e "${GREEN}✅ CLI tests passed${NC}"
else
    echo -e "${RED}❌ CLI tests failed${NC}"
    ((FAILED_TESTS++))
fi
echo ""

# Add more test suites here as they are created
# Example:
# echo -e "${BLUE}Running integration tests...${NC}"
# if ./integration/test-job-runner.sh; then
#     echo -e "${GREEN}✅ Integration tests passed${NC}"
# else
#     echo -e "${RED}❌ Integration tests failed${NC}"
#     ((FAILED_TESTS++))
# fi

# Summary
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ $FAILED_TESTS -eq 0 ]; then
    echo -e "${GREEN}✅ All test suites passed!${NC}"
    exit 0
else
    echo -e "${RED}❌ $FAILED_TESTS test suite(s) failed${NC}"
    exit 1
fi
