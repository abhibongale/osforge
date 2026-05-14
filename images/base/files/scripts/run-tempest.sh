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

# Set OpenStack credentials (required for tempest config generation)
export OS_AUTH_URL=http://${SERVICE_HOST:-127.0.0.1}/identity
export OS_PROJECT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=secret
export OS_REGION_NAME=RegionOne
export OS_IDENTITY_API_VERSION=3
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_DOMAIN_NAME=Default

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

# Get dynamic values
IMAGE_ID=$(openstack image list -f value -c ID 2>/dev/null | head -1)
PUBLIC_NETWORK_ID=$(openstack network list --external -f value -c ID 2>/dev/null | head -1)

# Get baremetal flavor UUID (must use project-scoped credentials)
unset OS_SYSTEM_SCOPE
export OS_PROJECT_NAME=admin
export OS_PROJECT_DOMAIN_NAME=Default
FLAVOR_ID=$(openstack flavor show baremetal -f value -c id 2>/dev/null)

echo "[run-tempest] Using image: $IMAGE_ID"
echo "[run-tempest] Using public network: $PUBLIC_NETWORK_ID"
echo "[run-tempest] Using flavor: $FLAVOR_ID (baremetal)"

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
flavor_ref = ${FLAVOR_ID}
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
