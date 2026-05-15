#!/bin/bash
# Run Tempest tests
# This script runs inside the container
# Replicates how Zuul runs tempest tests using tox

set -eo pipefail

JOB_NAME="${1:-unknown}"
LOG_DIR="${2:-/opt/stack/logs}"

echo "[run-tempest] Running tempest test for job: $JOB_NAME"

# Get HOST_IP from DevStack configuration
if [[ -f /opt/stack/devstack/.stackenv ]]; then
    source /opt/stack/devstack/.stackenv
fi

# Source component configuration scripts
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
CONFIG_DIR="$SCRIPT_DIR/config"

source "$CONFIG_DIR/auth-config.sh"
source "$CONFIG_DIR/glance-config.sh"
source "$CONFIG_DIR/nova-config.sh"
source "$CONFIG_DIR/neutron-config.sh"
source "$CONFIG_DIR/ironic-config.sh"
source "$CONFIG_DIR/swift-config.sh"

# Set up OpenStack authentication
set_auth_credentials

echo "[run-tempest] Using SERVICE_HOST: ${SERVICE_HOST:-127.0.0.1}"

# Change to tempest directory
cd /opt/stack/tempest || {
    echo "[run-tempest] ERROR: Tempest directory not found"
    exit 1
}

# Job configuration (can be passed via environment or read from job config)
TEST_REGEX="${TEST_REGEX:-ironic_tempest_plugin.tests.scenario.test_baremetal_server_ops_wholedisk_image}"
TEST_CONCURRENCY="${TEST_CONCURRENCY:-1}"
TEST_TIMEOUT="${TEST_TIMEOUT:-2600}"

echo "[run-tempest] Test configuration:"
echo "[run-tempest]   Regex: $TEST_REGEX"
echo "[run-tempest]   Concurrency: $TEST_CONCURRENCY"
echo "[run-tempest]   Timeout: $TEST_TIMEOUT seconds"

# Activate virtualenv first (stestr and openstack commands need it)
echo "[run-tempest] Activating Python virtualenv..."
source /opt/stack/data/venv/bin/activate

# Initialize stestr repository (Zuul's run-tempest role does this)
echo "[run-tempest] Initializing stestr repository..."
rm -rf .testrepository .stestr 2>/dev/null || true
stestr init

# Ensure etc directory exists
mkdir -p etc

# Configure tempest
echo "[run-tempest] Configuring tempest..."

# Activate virtualenv for OpenStack commands
source /opt/stack/data/venv/bin/activate

# Get component-specific configurations
echo "[run-tempest] Retrieving component configurations..."
get_glance_config
get_nova_config
get_neutron_config
get_ironic_config

# Generate tempest.conf from component configurations
cat > etc/tempest.conf <<EOF
[DEFAULT]
debug = true
log_file = ${LOG_DIR}/tempest.log

$(generate_auth_tempest_config)

$(generate_nova_tempest_config)

$(generate_neutron_tempest_config)

[validation]
run_validation = false
connect_method = fixed

$(generate_ironic_tempest_config)

[service_available]
cinder = false
glance = true
neutron = true
nova = true
swift = true
ironic = true

$(generate_swift_tempest_config)
EOF

# Create log directory
mkdir -p "$LOG_DIR"

# Verify ironic-tempest-plugin is installed in the virtualenv
echo "[run-tempest] Verifying ironic-tempest-plugin installation..."
if ! pip show ironic-tempest-plugin >/dev/null 2>&1; then
    echo "[run-tempest] ERROR: ironic-tempest-plugin not installed in virtualenv"
    echo "[run-tempest] Installing from /opt/stack/ironic-tempest-plugin..."
    pip install -e /opt/stack/ironic-tempest-plugin || {
        echo "[run-tempest] ERROR: Failed to install ironic-tempest-plugin"
        exit 1
    }
fi

# List plugins
echo "[run-tempest] Tempest plugins:"
pip list | grep tempest || true
echo ""

# Run tests using stestr directly (this is what Zuul's run-tempest role does)
echo "[run-tempest] Starting test execution using stestr..."
echo "[run-tempest] This may take 20-30 minutes..."
echo "[run-tempest] Command: stestr run --concurrency $TEST_CONCURRENCY $TEST_REGEX"

# Run stestr directly (matching Zuul's run-tempest Ansible role behavior)
# stestr handles test discovery and execution
TEMPEST_EXIT_CODE=0
timeout "$TEST_TIMEOUT" stestr run \
    --concurrency "$TEST_CONCURRENCY" \
    "$TEST_REGEX" 2>&1 | tee "${LOG_DIR}/tempest-output.log" || TEMPEST_EXIT_CODE=$?

# Handle timeout
if [[ $TEMPEST_EXIT_CODE -eq 124 ]]; then
    echo "[run-tempest] ERROR: Test execution timed out after ${TEST_TIMEOUT} seconds"
    exit 124
fi

# Generate test results
echo "[run-tempest] Generating test results..."

# stestr stores results in .stestr directory
if [[ ! -d ".stestr" ]]; then
    echo "[run-tempest] ERROR: No test results found (.stestr directory missing)"
    echo "[run-tempest] Check tempest-output.log for errors"
    exit 1
fi

# Get test results summary
echo "[run-tempest] Test summary:"
stestr last --subunit | subunit-stats | tee "${LOG_DIR}/test-summary.txt"

# Generate HTML report
echo "[run-tempest] Generating HTML report..."
stestr last --subunit | subunit2html "${LOG_DIR}/tempest-results.html" || {
    echo "[run-tempest] WARNING: Could not generate HTML report"
}

# Generate JUnit XML
echo "[run-tempest] Generating JUnit XML..."
stestr last --subunit | subunit2junitxml --output-to="${LOG_DIR}/tempest-results.xml" || {
    echo "[run-tempest] WARNING: Could not generate JUnit XML"
}

# Check if tests passed
TEST_SUMMARY=$(stestr last --subunit | subunit-stats 2>&1)
echo "$TEST_SUMMARY"

if echo "$TEST_SUMMARY" | grep -q "Ran 0 tests"; then
    echo "[run-tempest] ERROR: No tests were run (test regex may be incorrect)"
    echo "[run-tempest] Listing available tests matching pattern..."
    stestr list "$TEST_REGEX" | head -20 || true
    exit 1
fi

if echo "$TEST_SUMMARY" | grep -qE "(Failed|Error): [1-9]"; then
    echo "[run-tempest] ERROR: Some tests failed"
    exit 1
fi

echo "[run-tempest] All tests passed!"

# Save tempest configuration for debugging
cp etc/tempest.conf "${LOG_DIR}/tempest.conf"

# Show final summary
echo "[run-tempest] ========================================="
echo "[run-tempest] Test execution complete"
echo "[run-tempest] ========================================="
echo "[run-tempest] Results saved to: $LOG_DIR"
echo "[run-tempest]   - tempest-output.log (full output)"
echo "[run-tempest]   - tempest-results.html (HTML report)"
echo "[run-tempest]   - tempest-results.xml (JUnit XML)"
echo "[run-tempest]   - test-summary.txt (summary)"
echo "[run-tempest]   - tempest.conf (configuration used)"
echo "[run-tempest] ========================================="

exit 0
