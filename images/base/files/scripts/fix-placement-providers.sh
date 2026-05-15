#!/bin/bash
# Fix script to force Nova compute to refresh Placement resource providers
# This is useful when Ironic nodes are created but not appearing in Placement

set -eo pipefail

echo "[fix-placement] Force refreshing Placement resource providers..."

# Set credentials
export OS_AUTH_URL=http://${SERVICE_HOST:-127.0.0.1}/identity
export OS_USERNAME=admin
export OS_PASSWORD=secret
export OS_REGION_NAME=RegionOne
export OS_IDENTITY_API_VERSION=3
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_NAME=admin
export OS_PROJECT_DOMAIN_NAME=Default

# Check current state
echo "[fix-placement] Current Placement resource providers:"
openstack resource provider list -f table 2>/dev/null || echo "  ERROR: Could not list providers"

echo ""
echo "[fix-placement] Current Ironic nodes:"
export OS_SYSTEM_SCOPE=all
unset OS_PROJECT_NAME
unset OS_PROJECT_DOMAIN_NAME
openstack baremetal node list -f table 2>/dev/null || echo "  ERROR: Could not list nodes"

# Restart Nova compute to force resource refresh
echo ""
echo "[fix-placement] Restarting Nova compute service..."
systemctl restart devstack@n-cpu.service
sleep 5

# Wait for service to stabilize
echo "[fix-placement] Waiting for Nova compute to stabilize (20 seconds)..."
sleep 20

# Run cell discovery
echo "[fix-placement] Running Nova cell discovery..."
cd /opt/stack/nova && su -s /bin/bash stack -c "nova-manage cell_v2 discover_hosts --verbose 2>&1"

# Wait for Placement update
echo "[fix-placement] Waiting for Placement to update (10 seconds)..."
sleep 10

# Check results
echo ""
echo "[fix-placement] ====== VERIFICATION ======"
echo ""

unset OS_SYSTEM_SCOPE
export OS_PROJECT_NAME=admin
export OS_PROJECT_DOMAIN_NAME=Default

echo "Resource providers after refresh:"
openstack resource provider list -f table 2>/dev/null

echo ""
echo "Resource provider inventory:"
openstack resource provider list -f value -c uuid 2>/dev/null | while read -r uuid; do
    echo ""
    echo "Provider: $uuid"
    openstack resource provider inventory list "$uuid" -f table 2>/dev/null | sed 's/^/  /'
done

echo ""
echo "[fix-placement] Done! If nodes still not in Placement, check logs:"
echo "  journalctl -u devstack@n-cpu.service -n 100 --no-pager"
