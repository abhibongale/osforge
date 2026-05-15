#!/bin/bash
# Debug script to check Nova/Ironic/Placement integration

set -e

# Setup credentials
export OS_AUTH_URL=http://${SERVICE_HOST:-127.0.0.1}/identity
export OS_USERNAME=admin
export OS_PASSWORD=secret
export OS_REGION_NAME=RegionOne
export OS_IDENTITY_API_VERSION=3
export OS_USER_DOMAIN_NAME=Default

echo "============================================================"
echo "  IRONIC PROVISIONING DIAGNOSTICS"
echo "============================================================"
echo ""

# 1. System Services Status
echo "====== 1. SYSTEM SERVICES STATUS ======"
echo ""
echo "RabbitMQ:"
systemctl is-active rabbitmq-server && echo "  ✓ RUNNING" || echo "  ✗ NOT RUNNING"

echo "MySQL:"
systemctl is-active mysql && echo "  ✓ RUNNING" || echo "  ✗ NOT RUNNING"

echo "Apache (HTTP Proxy):"
systemctl is-active apache2 && echo "  ✓ RUNNING" || echo "  ✗ NOT RUNNING"

echo "Keystone:"
systemctl is-active devstack@keystone.service && echo "  ✓ RUNNING" || echo "  ✗ NOT RUNNING"

echo "Nova Compute:"
systemctl is-active devstack@n-cpu.service && echo "  ✓ RUNNING" || echo "  ✗ NOT RUNNING"

echo "Nova Scheduler:"
systemctl is-active devstack@n-sch.service && echo "  ✓ RUNNING" || echo "  ✗ NOT RUNNING"

echo "Placement:"
systemctl is-active devstack@placement-api.service && echo "  ✓ RUNNING" || echo "  ✗ NOT RUNNING"

echo "Ironic API:"
systemctl is-active devstack@ir-api.service && echo "  ✓ RUNNING" || echo "  ✗ NOT RUNNING"

echo "Ironic Conductor:"
systemctl is-active devstack@ir-cond.service && echo "  ✓ RUNNING" || echo "  ✗ NOT RUNNING"

echo ""

# 2. Nova Configuration
echo "====== 2. NOVA COMPUTE CONFIGURATION ======"
echo ""
if [[ -f /etc/nova/nova-cpu.conf ]]; then
    echo "Compute driver:"
    grep "^compute_driver" /etc/nova/nova-cpu.conf || echo "  Not configured"
    echo ""
    echo "Host:"
    grep "^host" /etc/nova/nova-cpu.conf || echo "  Not configured"
else
    echo "  WARNING: /etc/nova/nova-cpu.conf not found"
fi
echo ""

# 3. OpenStack Service Endpoints
export OS_PROJECT_NAME=admin
export OS_PROJECT_DOMAIN_NAME=Default

echo "====== 3. OPENSTACK SERVICE ENDPOINTS ======"
echo ""
openstack endpoint list -f value -c "Service Name" -c "Service Type" -c "Enabled" | grep -E "nova|placement|ironic|keystone" || echo "  No endpoints found"
echo ""

# 4. Nova Compute Services
echo "====== 4. NOVA COMPUTE SERVICES ======"
echo ""
openstack compute service list -f table || echo "  Failed to list compute services"
echo ""

# 5. Placement Resource Providers
echo "====== 5. PLACEMENT RESOURCE PROVIDERS ======"
echo ""
PROVIDERS=$(openstack resource provider list -f value -c uuid -c name 2>/dev/null)
if [[ -z "$PROVIDERS" ]]; then
    echo "  ✗ NO RESOURCE PROVIDERS FOUND!"
    echo "  This is the likely cause of provisioning failures."
    echo "  Baremetal nodes must be registered in Placement."
else
    echo "$PROVIDERS"
fi
echo ""

# 6. Resource Provider Details
if [[ -n "$PROVIDERS" ]]; then
    echo "====== 6. RESOURCE PROVIDER INVENTORY ======"
    echo ""
    echo "$PROVIDERS" | while read uuid name; do
        echo "Provider: $name ($uuid)"
        echo "  Inventory:"
        openstack resource provider inventory list "$uuid" -f table 2>/dev/null | sed 's/^/    /' || echo "    No inventory"
        echo "  Traits (first 10):"
        openstack resource provider trait list "$uuid" -f value -c name 2>/dev/null | head -10 | sed 's/^/    /' || echo "    No traits"
        echo ""
    done
fi

# 7. Baremetal Nodes
export OS_SYSTEM_SCOPE=all
unset OS_PROJECT_NAME
unset OS_PROJECT_DOMAIN_NAME

echo "====== 7. BAREMETAL NODES ======"
echo ""
NODES=$(openstack baremetal node list -f value -c UUID -c Name -c "Provisioning State" -c "Power State" 2>/dev/null)
if [[ -z "$NODES" ]]; then
    echo "  ✗ NO BAREMETAL NODES FOUND!"
    echo "  VirtualBMC setup may have failed."
else
    echo "$NODES"

    # Check first node details
    FIRST_NODE=$(echo "$NODES" | head -1 | awk '{print $1}')
    if [[ -n "$FIRST_NODE" ]]; then
        echo ""
        echo "First node details ($FIRST_NODE):"
        openstack baremetal node show "$FIRST_NODE" -f value -c uuid -c name -c resource_class -c provision_state -c power_state -c last_error | sed 's/^/  /'
    fi
fi
echo ""

# 8. Flavors
unset OS_SYSTEM_SCOPE
export OS_PROJECT_NAME=admin
export OS_PROJECT_DOMAIN_NAME=Default

echo "====== 8. NOVA FLAVORS ======"
echo ""
FLAVORS=$(openstack flavor list -f value -c Name -c RAM -c VCPUs 2>/dev/null)
if [[ -z "$FLAVORS" ]]; then
    echo "  ✗ NO FLAVORS FOUND!"
else
    echo "$FLAVORS"

    # Check baremetal flavor
    if echo "$FLAVORS" | grep -q "baremetal"; then
        echo ""
        echo "Baremetal flavor properties:"
        openstack flavor show baremetal -f table 2>/dev/null | sed 's/^/  /'
    fi
fi
echo ""

# 9. Nova Cell Discovery
echo "====== 9. NOVA CELL MAPPING ======"
echo ""
su -s /bin/bash stack -c "cd /opt/stack/nova && nova-manage cell_v2 list_hosts" 2>/dev/null | sed 's/^/  /' || echo "  Failed to list cell hosts"
echo ""

# 10. Recent Errors in Logs
echo "====== 10. RECENT ERRORS IN LOGS ======"
echo ""
echo "Nova Scheduler (NoValidHost errors):"
journalctl -u devstack@n-sch.service --since "5 minutes ago" --no-pager 2>/dev/null | grep -i "NoValidHost" | tail -5 | sed 's/^/  /' || echo "  No recent NoValidHost errors"
echo ""

echo "Nova Compute (Placement errors):"
journalctl -u devstack@n-cpu.service --since "5 minutes ago" --no-pager 2>/dev/null | grep -iE "placement|error|failed" | tail -10 | sed 's/^/  /' || echo "  No recent placement errors"
echo ""

echo "Ironic Conductor (Provisioning errors):"
journalctl -u devstack@ir-cond.service --since "5 minutes ago" --no-pager 2>/dev/null | grep -iE "error|failed" | tail -10 | sed 's/^/  /' || echo "  No recent errors"
echo ""

# 11. Placement API Connectivity
echo "====== 11. PLACEMENT API CONNECTIVITY ======"
echo ""
if curl -s http://127.0.0.1/placement/ >/dev/null 2>&1; then
    echo "  ✓ Placement API is responding"
else
    echo "  ✗ Placement API is NOT responding"
fi
echo ""

# 12. Summary and Recommendations
echo "============================================================"
echo "  SUMMARY & RECOMMENDATIONS"
echo "============================================================"
echo ""

ISSUES_FOUND=0

# Check for resource providers
if [[ -z "$PROVIDERS" ]]; then
    echo "❌ CRITICAL: No resource providers in Placement"
    echo "   → Baremetal nodes are not registered with Placement"
    echo "   → This will cause 'No valid host' errors"
    echo "   → Check: Nova compute service logs and cell discovery"
    ISSUES_FOUND=1
fi

# Check for baremetal nodes
if [[ -z "$NODES" ]]; then
    echo "❌ CRITICAL: No baremetal nodes found in Ironic"
    echo "   → VirtualBMC setup failed or nodes were not created"
    echo "   → Check: setup-vbmc.sh script and Ironic conductor logs"
    ISSUES_FOUND=1
fi

# Check for flavors
if [[ -z "$FLAVORS" ]]; then
    echo "❌ CRITICAL: No flavors found"
    echo "   → Cannot provision instances without flavors"
    ISSUES_FOUND=1
fi

# Check Nova compute service
if ! systemctl is-active --quiet devstack@n-cpu.service; then
    echo "❌ CRITICAL: Nova compute service not running"
    echo "   → Resource providers won't be registered in Placement"
    echo "   → Check: systemctl status devstack@n-cpu.service"
    ISSUES_FOUND=1
fi

if [[ $ISSUES_FOUND -eq 0 ]]; then
    echo "✅ All critical components appear healthy"
    echo ""
    echo "If provisioning still fails, check:"
    echo "  1. Nova scheduler logs: journalctl -u devstack@n-sch.service -f"
    echo "  2. Nova compute logs: journalctl -u devstack@n-cpu.service -f"
    echo "  3. Ironic conductor logs: journalctl -u devstack@ir-cond.service -f"
fi

echo ""
