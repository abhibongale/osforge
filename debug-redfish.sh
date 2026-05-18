#!/bin/bash
# Debug script for Sushy-Tools/Redfish communication issues

set +e  # Don't exit on errors

echo "======================================================================"
echo "Redfish/Sushy-Tools Debugging"
echo "======================================================================"
echo ""

echo "1. Checking Sushy-Tools Process"
echo "----------------------------------------------------------------------"
if ps aux | grep sushy-emulator | grep -v grep; then
    echo "  ✓ Sushy-Tools process is running"
    SUSHY_PID=$(ps aux | grep sushy-emulator | grep -v grep | awk '{print $2}' | head -1)
    echo "  PID: $SUSHY_PID"
else
    echo "  ✗ Sushy-Tools process NOT running"
    exit 1
fi

echo ""
echo "2. Checking Sushy-Tools Port"
echo "----------------------------------------------------------------------"
if netstat -tlnp 2>/dev/null | grep :8000; then
    echo "  ✓ Port 8000 is listening"
else
    echo "  ✗ Port 8000 is NOT listening"
fi

echo ""
echo "3. Testing Redfish Root API"
echo "----------------------------------------------------------------------"
echo "GET http://127.0.0.1:8000/redfish/v1/"
REDFISH_ROOT=$(curl -s http://127.0.0.1:8000/redfish/v1/)
if [[ -n "$REDFISH_ROOT" ]]; then
    echo "  ✓ Redfish API responding"
    echo "$REDFISH_ROOT" | jq '.' 2>/dev/null || echo "$REDFISH_ROOT"
else
    echo "  ✗ Redfish API NOT responding"
fi

echo ""
echo "4. Listing Redfish Systems"
echo "----------------------------------------------------------------------"
echo "GET http://127.0.0.1:8000/redfish/v1/Systems/"
SYSTEMS=$(curl -s http://127.0.0.1:8000/redfish/v1/Systems/)
if [[ -n "$SYSTEMS" ]]; then
    echo "  Systems found:"
    echo "$SYSTEMS" | jq '.Members' 2>/dev/null || echo "$SYSTEMS"

    # Count systems
    SYSTEM_COUNT=$(echo "$SYSTEMS" | jq '.Members | length' 2>/dev/null)
    echo "  Total systems: $SYSTEM_COUNT"
else
    echo "  ✗ No systems returned"
fi

echo ""
echo "5. Checking Libvirt Domains"
echo "----------------------------------------------------------------------"
echo "Defined domains:"
virsh list --all

echo ""
echo "6. Testing Specific System Endpoint"
echo "----------------------------------------------------------------------"
# Try to get the first system
SYSTEM_ID=$(echo "$SYSTEMS" | jq -r '.Members[0]."@odata.id"' 2>/dev/null | sed 's|/redfish/v1/Systems/||')
if [[ -n "$SYSTEM_ID" ]] && [[ "$SYSTEM_ID" != "null" ]]; then
    echo "Testing system: $SYSTEM_ID"
    echo "GET http://127.0.0.1:8000/redfish/v1/Systems/$SYSTEM_ID"
    SYSTEM_DETAILS=$(curl -s http://127.0.0.1:8000/redfish/v1/Systems/$SYSTEM_ID)
    echo "$SYSTEM_DETAILS" | jq '.' 2>/dev/null || echo "$SYSTEM_DETAILS"
else
    echo "  ✗ No system ID found, trying baremetal-0..."
    echo "GET http://127.0.0.1:8000/redfish/v1/Systems/baremetal-0"
    SYSTEM_DETAILS=$(curl -s http://127.0.0.1:8000/redfish/v1/Systems/baremetal-0)
    if [[ -n "$SYSTEM_DETAILS" ]]; then
        echo "  ✓ baremetal-0 endpoint responding"
        echo "$SYSTEM_DETAILS" | jq '.' 2>/dev/null || echo "$SYSTEM_DETAILS"
    else
        echo "  ✗ baremetal-0 endpoint NOT responding"
    fi
fi

echo ""
echo "7. Checking Sushy-Tools Configuration"
echo "----------------------------------------------------------------------"
if [[ -f /etc/sushy/sushy-emulator.conf ]]; then
    echo "Configuration file exists:"
    cat /etc/sushy/sushy-emulator.conf
else
    echo "  ✗ Configuration file NOT found"
fi

echo ""
echo "8. Checking Sushy-Tools Logs"
echo "----------------------------------------------------------------------"
if [[ -f /var/log/sushy-emulator.log ]]; then
    echo "Last 30 lines of Sushy-Tools log:"
    tail -30 /var/log/sushy-emulator.log
else
    echo "  ✗ Log file NOT found"
    echo "Checking for process output..."
    if [[ -n "$SUSHY_PID" ]]; then
        echo "Process stderr/stdout (if available):"
        ls -la /proc/$SUSHY_PID/fd/
    fi
fi

echo ""
echo "9. Checking Ironic Node Status"
echo "----------------------------------------------------------------------"
export OS_AUTH_URL=http://127.0.0.1/identity
export OS_USERNAME=admin
export OS_PASSWORD=secret
export OS_REGION_NAME=RegionOne
export OS_IDENTITY_API_VERSION=3
export OS_USER_DOMAIN_NAME=Default
export OS_SYSTEM_SCOPE=all

echo "Baremetal nodes:"
openstack baremetal node list 2>&1 | grep -v Eventlet | grep -v "we strongly" | grep -v "framework" | grep -v "https://eventlet" | grep -v "import eventlet" | grep -v "^$"

echo ""
echo "Checking for Redfish nodes:"
REDFISH_NODES=$(openstack baremetal node list -f json 2>&1 | grep -v Eventlet | jq -r '.[] | select(.Driver == "redfish") | .UUID' 2>/dev/null)
if [[ -n "$REDFISH_NODES" ]]; then
    for NODE_UUID in $REDFISH_NODES; do
        echo ""
        echo "Node: $NODE_UUID"
        openstack baremetal node show $NODE_UUID -c driver -c provisioning_state -c driver_info -c last_error -f yaml 2>&1 | grep -v Eventlet | grep -v "we strongly" | grep -v "framework" | grep -v "https://eventlet" | grep -v "import eventlet" | grep -v "^$"
    done
else
    echo "  No Redfish nodes found"
fi

echo ""
echo "10. Testing Power Operations"
echo "----------------------------------------------------------------------"
if [[ -n "$REDFISH_NODES" ]]; then
    NODE_UUID=$(echo "$REDFISH_NODES" | head -1)
    echo "Testing power status for node: $NODE_UUID"

    # Get driver_info to find the Redfish address
    REDFISH_ADDR=$(openstack baremetal node show $NODE_UUID -f json 2>&1 | grep -v Eventlet | jq -r '.driver_info.redfish_address' 2>/dev/null)
    SYSTEM_ID=$(openstack baremetal node show $NODE_UUID -f json 2>&1 | grep -v Eventlet | jq -r '.driver_info.redfish_system_id' 2>/dev/null)

    echo "  Redfish address: $REDFISH_ADDR"
    echo "  System ID: $SYSTEM_ID"

    if [[ -n "$REDFISH_ADDR" ]] && [[ "$REDFISH_ADDR" != "null" ]]; then
        echo ""
        echo "  Testing GET on Redfish endpoint:"
        curl -v "$REDFISH_ADDR" 2>&1 | head -20
    fi
fi

echo ""
echo "11. Checking Ironic Conductor Logs"
echo "----------------------------------------------------------------------"
echo "Last 20 lines with Redfish/power errors:"
journalctl -u devstack@ir-cond.service --since "5 minutes ago" --no-pager | grep -E "ERROR|redfish|power|RedfishError|Traceback" | tail -20 || echo "  (no errors found)"

echo ""
echo "======================================================================"
echo "Debug complete"
echo "======================================================================"
