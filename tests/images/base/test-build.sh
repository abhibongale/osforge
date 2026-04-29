#!/bin/bash
# OSForge Build Test Script
# Tests the containerized DevStack build for functionality
# Usage: ./test-build.sh [--quick|--full]

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
IMAGE_NAME="quay.io/osforge/base:latest"
TEST_MODE="${1:-full}"

# Functions
log_info() {
    echo -e "${BLUE}==>${NC} $1"
}

log_success() {
    echo -e "${GREEN}✅${NC} $1"
}

log_error() {
    echo -e "${RED}❌${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠️${NC} $1"
}

cleanup_container() {
    if [ -n "${CONTAINER_ID:-}" ]; then
        log_info "Cleaning up test container..."
        podman stop "$CONTAINER_ID" 2>/dev/null || true
        podman rm "$CONTAINER_ID" 2>/dev/null || true
    fi
}

# Trap to ensure cleanup
trap cleanup_container EXIT INT TERM

# Main test execution
main() {
    log_info "OSForge Build Test - Mode: $TEST_MODE"
    echo ""

    # 1. Pre-flight checks
    log_info "Phase 1: Pre-flight checks"

    # Check Podman
    if ! command -v podman &> /dev/null; then
        log_error "Podman not found. Please install Podman."
        exit 1
    fi
    log_success "Podman available"

    # Check /dev/kvm
    if [ ! -e /dev/kvm ]; then
        log_warning "/dev/kvm not found. Container will start but virtualization won't work."
    else
        log_success "/dev/kvm available"
    fi

    # Check image exists
    if ! podman images | grep -q "osforge/base"; then
        log_error "Image 'osforge/base' not found."
        log_info "Please run: ./build-with-devstack.sh"
        exit 1
    fi
    log_success "Image found: $IMAGE_NAME"

    # Check image size
    IMAGE_SIZE=$(podman images --format "{{.Size}}" "$IMAGE_NAME")
    log_info "Image size: $IMAGE_SIZE"
    echo ""

    # 2. Start container
    log_info "Phase 2: Starting container"
    CONTAINER_ID=$(podman run -d \
        --privileged \
        --device /dev/kvm \
        "$IMAGE_NAME")

    log_success "Container started: ${CONTAINER_ID:0:12}"

    # Wait for systemd to initialize
    log_info "Waiting for systemd to initialize (10 seconds)..."
    sleep 10

    # Check container is running
    if ! podman ps | grep -q "${CONTAINER_ID:0:12}"; then
        log_error "Container not running"
        podman logs "$CONTAINER_ID"
        exit 1
    fi
    log_success "Container running"
    echo ""

    # 3. Test systemd services
    log_info "Phase 3: Testing systemd services"

    SERVICES=(
        "devstack@ir-api.service"
        "devstack@ir-cond.service"
        "devstack@n-api.service"
        "devstack@q-svc.service"
        "devstack@g-api.service"
    )

    for service in "${SERVICES[@]}"; do
        if podman exec "$CONTAINER_ID" systemctl is-active --quiet "$service" 2>/dev/null; then
            log_success "$service is active"
        else
            log_warning "$service may not be running (checking...)"
            # Give it some time and retry
            sleep 2
            if podman exec "$CONTAINER_ID" systemctl is-active --quiet "$service" 2>/dev/null; then
                log_success "$service is active (after retry)"
            else
                log_error "$service is not active"
            fi
        fi
    done
    echo ""

    # 4. Test OpenStack CLI
    log_info "Phase 4: Testing OpenStack CLI"

    # Test Keystone (token issue)
    log_info "Testing Keystone..."
    if podman exec "$CONTAINER_ID" bash -c "export OS_CLOUD=devstack-admin && openstack token issue" &>/dev/null; then
        log_success "Keystone authentication works"
    else
        log_error "Keystone authentication failed"
    fi

    # Test Glance (image list)
    log_info "Testing Glance..."
    IMAGE_COUNT=$(podman exec "$CONTAINER_ID" bash -c "export OS_CLOUD=devstack-admin && openstack image list -f value" | wc -l)
    if [ "$IMAGE_COUNT" -ge 2 ]; then
        log_success "Glance has $IMAGE_COUNT images (expected: 2+)"
        podman exec "$CONTAINER_ID" bash -c "export OS_CLOUD=devstack-admin && openstack image list"
    else
        log_error "Glance has only $IMAGE_COUNT images (expected: 2+)"
    fi

    # Test Nova (flavor list)
    log_info "Testing Nova..."
    if podman exec "$CONTAINER_ID" bash -c "export OS_CLOUD=devstack-admin && openstack flavor list" &>/dev/null; then
        log_success "Nova flavor list works"
    else
        log_error "Nova flavor list failed"
    fi

    # Test Ironic (node list)
    log_info "Testing Ironic..."
    NODE_COUNT=$(podman exec "$CONTAINER_ID" bash -c "export OS_CLOUD=devstack-admin && openstack baremetal node list -f value" | wc -l)
    if [ "$NODE_COUNT" -eq 2 ]; then
        log_success "Ironic has $NODE_COUNT nodes (expected: 2)"
        podman exec "$CONTAINER_ID" bash -c "export OS_CLOUD=devstack-admin && openstack baremetal node list"
    else
        log_warning "Ironic has $NODE_COUNT nodes (expected: 2)"
    fi
    echo ""

    # 5. Test VirtualBMC
    log_info "Phase 5: Testing VirtualBMC"

    if podman exec "$CONTAINER_ID" vbmc list &>/dev/null; then
        VBMC_COUNT=$(podman exec "$CONTAINER_ID" vbmc list | grep -c "node-" || true)
        if [ "$VBMC_COUNT" -eq 2 ]; then
            log_success "VirtualBMC has $VBMC_COUNT nodes configured"
            podman exec "$CONTAINER_ID" vbmc list
        else
            log_warning "VirtualBMC has $VBMC_COUNT nodes (expected: 2)"
        fi
    else
        log_error "VirtualBMC not responding"
    fi
    echo ""

    # 6. Test OVS/OVN
    log_info "Phase 6: Testing OVS/OVN networking"

    # Check OVS datapath type
    DATAPATH=$(podman exec "$CONTAINER_ID" ovs-vsctl get Open_vSwitch . datapath_types 2>/dev/null | grep -o netdev || echo "")
    if [ "$DATAPATH" = "netdev" ]; then
        log_success "OVS userspace (netdev) mode enabled"
    else
        log_warning "OVS datapath_types: $(podman exec "$CONTAINER_ID" ovs-vsctl get Open_vSwitch . datapath_types)"
    fi

    # Check OVN
    if podman exec "$CONTAINER_ID" ovn-nbctl show &>/dev/null; then
        log_success "OVN northbound database responding"
    else
        log_warning "OVN northbound database not responding"
    fi

    # Check networks
    NET_COUNT=$(podman exec "$CONTAINER_ID" bash -c "export OS_CLOUD=devstack-admin && openstack network list -f value" | wc -l)
    log_info "OpenStack networks: $NET_COUNT"
    echo ""

    # 7. Quick Tempest test (only in full mode)
    if [ "$TEST_MODE" = "--full" ]; then
        log_info "Phase 7: Running quick Tempest test"
        log_warning "This will take 5-10 minutes..."

        if podman exec "$CONTAINER_ID" bash -c "cd /opt/stack/tempest && tox -e all -- ironic_tempest_plugin.tests.api.admin.test_nodes.TestNodes.test_list_nodes" &>/dev/null; then
            log_success "Tempest quick test passed"
        else
            log_error "Tempest quick test failed"
            log_info "Check logs: podman exec $CONTAINER_ID cat /opt/stack/tempest/.tox/all/log/all-*.log"
        fi
        echo ""
    fi

    # 8. Summary
    log_info "Test Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Image:          $IMAGE_NAME"
    echo "Container ID:   ${CONTAINER_ID:0:12}"
    echo "Image Size:     $IMAGE_SIZE"
    echo "Images:         $IMAGE_COUNT"
    echo "Baremetal Nodes: $NODE_COUNT"
    echo "Networks:       $NET_COUNT"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    log_success "All basic tests completed!"
    echo ""
    log_info "Container is still running for manual testing:"
    echo "  podman exec -it $CONTAINER_ID /bin/bash"
    echo ""
    log_info "To stop and remove:"
    echo "  podman stop $CONTAINER_ID && podman rm $CONTAINER_ID"
    echo ""
    log_info "To run full Tempest test:"
    echo "  podman exec $CONTAINER_ID bash -c 'cd /opt/stack/tempest && tox -e all -- ironic_tempest_plugin.tests.scenario.test_baremetal_basic_ops'"
    echo ""

    # Don't cleanup automatically - let user inspect
    trap - EXIT INT TERM
}

# Show usage
if [ "$TEST_MODE" = "--help" ] || [ "$TEST_MODE" = "-h" ]; then
    echo "Usage: $0 [--quick|--full]"
    echo ""
    echo "Modes:"
    echo "  --quick   Run quick tests only (default, ~2 minutes)"
    echo "  --full    Run full tests including Tempest (~10 minutes)"
    echo ""
    exit 0
fi

# Run tests
main
