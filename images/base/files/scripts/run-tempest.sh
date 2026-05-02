#!/bin/bash
# Run Tempest tests
# This script runs inside the container

set -eo pipefail

JOB_NAME="${1:-unknown}"
LOG_DIR="${2:-/opt/stack/logs}"

echo "[run-tempest] Running tempest test for job: $JOB_NAME"

# Get HOST_IP from DevStack configuration
if [[ -f /opt/stack/devstack/.stackenv ]]; then
    source /opt/stack/devstack/.stackenv
fi

# Set OpenStack credentials directly (avoid DevStack functions issues)
export OS_AUTH_URL=http://${SERVICE_HOST:-127.0.0.1}/identity
export OS_PROJECT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=secret
export OS_REGION_NAME=RegionOne
export OS_IDENTITY_API_VERSION=3
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_DOMAIN_NAME=Default

echo "[run-tempest] Using SERVICE_HOST: ${SERVICE_HOST:-127.0.0.1}"

# Activate DevStack virtualenv (where tempest is installed)
source /opt/stack/data/venv/bin/activate

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

# Initialize tempest workspace - always reinitialize to avoid oslo_config errors
echo "[run-tempest] Initializing tempest workspace..."
rm -rf .testrepository .stestr 2>/dev/null || true
tempest init /opt/stack/tempest 2>/dev/null || true

# Configure tempest
echo "[run-tempest] Configuring tempest..."

# Get dynamic values
IMAGE_ID=$(openstack image list -f value -c ID | head -1)
PUBLIC_NETWORK_ID=$(openstack network list --external -f value -c ID | head -1)

echo "[run-tempest] Using image: $IMAGE_ID"
echo "[run-tempest] Using public network: $PUBLIC_NETWORK_ID"

# Create or update tempest.conf
cat > etc/tempest.conf <<EOF
[DEFAULT]
debug = true
log_file = ${LOG_DIR}/tempest.log

[auth]
use_dynamic_credentials = true
admin_username = admin
admin_password = secret
admin_project_name = admin
admin_domain_name = Default

[identity]
uri = http://${SERVICE_HOST}/identity
uri_v3 = http://${SERVICE_HOST}/identity/v3
auth_version = v3
region = RegionOne
v3_endpoint_type = public

[identity-feature-enabled]
api_v2 = false
api_v3 = true

[compute]
image_ref = ${IMAGE_ID}
image_ref_alt = ${IMAGE_ID}
flavor_ref = baremetal
min_compute_nodes = 1
max_microversion = latest

[compute-feature-enabled]
console_output = false
rescue = false
resize = false
suspend = false

[network]
public_network_id = ${PUBLIC_NETWORK_ID}
project_networks_reachable = false

[network-feature-enabled]
ipv6 = false

[validation]
run_validation = false
connect_method = fixed

[baremetal]
driver = ipmi
enabled_drivers = ipmi
min_microversion = 1.1
max_microversion = latest
deployment_timeout = 900

[baremetal-feature-enabled]
adoption = false

[service_available]
cinder = false
glance = true
neutron = true
nova = true
swift = true
ironic = true

[object-storage]
operator_role = Member
reseller_admin_role = ResellerAdmin

[object-storage-feature-enabled]
discoverability = true
container_sync = false
object_versioning = true
bulk_upload = true
EOF

# Discover Tempest plugins
echo "[run-tempest] Discovering tempest plugins..."
tempest list-plugins

# Verify configuration
echo "[run-tempest] Verifying tempest configuration..."
tempest verify-config -r compute,network,baremetal || {
    echo "[run-tempest] WARNING: Configuration verification had warnings (continuing anyway)"
}

# Create log directory
mkdir -p "$LOG_DIR"

# List available tests matching the regex (for debugging)
echo "[run-tempest] Checking for tests matching regex: $TEST_REGEX"
TEST_COUNT=$(tempest run --list-tests --regex "$TEST_REGEX" 2>/dev/null | grep -c "^[a-z]" || echo "0")
echo "[run-tempest] Found $TEST_COUNT tests matching the regex"

# Convert to integer and check
TEST_COUNT=$(echo "$TEST_COUNT" | tr -d '[:space:]')
if [[ "$TEST_COUNT" -eq 0 ]]; then
    echo "[run-tempest] ERROR: No tests match the regex: $TEST_REGEX"
    echo "[run-tempest] Listing available Ironic tests..."
    tempest run --list-tests --regex "ironic" 2>/dev/null | head -20 || true
    exit 1
fi

# Run the tests
echo "[run-tempest] Starting test execution..."
echo "[run-tempest] This may take 20-30 minutes..."

# Run tempest with timeout
TEMPEST_EXIT_CODE=0
timeout "$TEST_TIMEOUT" tempest run \
    --regex "$TEST_REGEX" \
    --concurrency "$TEST_CONCURRENCY" \
    --black-regex '(?!^\s*$)' 2>&1 | tee "${LOG_DIR}/tempest-output.log" || TEMPEST_EXIT_CODE=$?

# Handle timeout
if [[ $TEMPEST_EXIT_CODE -eq 124 ]]; then
    echo "[run-tempest] ERROR: Test execution timed out after ${TEST_TIMEOUT} seconds"
    exit 124
fi

# Generate test results
echo "[run-tempest] Generating test results..."

# Get test results summary
# Check if any tests were run by checking stestr repository
if stestr last &>/dev/null; then
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
    if stestr last --subunit | subunit-stats | grep -q "Ran 0 tests"; then
        echo "[run-tempest] ERROR: No tests were run (test regex may be incorrect)"
        exit 1
    fi

    if stestr last --subunit | subunit-stats | grep -qE "(Failed|Error): [1-9]"; then
        echo "[run-tempest] ERROR: Some tests failed"
        stestr last --subunit | subunit-stats
        exit 1
    fi

    echo "[run-tempest] All tests passed!"
else
    echo "[run-tempest] ERROR: No test results found"
    exit 1
fi

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
