#!/bin/bash
# Comprehensive diagnostic script for Ironic provisioning issues
# Run this inside the container to check Nova/Placement/Ironic integration

set +e  # Don't exit on errors, we want to see all diagnostics

echo "======================================================================"
echo "Ironic Provisioning Diagnostics"
echo "======================================================================"
echo ""

# Set credentials
export OS_AUTH_URL=http://127.0.0.1/identity
export OS_USERNAME=admin
export OS_PASSWORD=secret
export OS_REGION_NAME=RegionOne
export OS_IDENTITY_API_VERSION=3
export OS_USER_DOMAIN_NAME=Default
export OS_SYSTEM_SCOPE=all

echo "1. Checking Services Status"
echo "----------------------------------------------------------------------"
echo "Nova compute:"
systemctl is-active devstack@n-cpu.service && echo "  ✓ RUNNING" || echo "  ✗ NOT RUNNING"

echo "Ironic conductor:"
systemctl is-active devstack@ir-cond.service && echo "  ✓ RUNNING" || echo "  ✗ NOT RUNNING"

echo "Ironic API:"
systemctl is-active devstack@ir-api.service && echo "  ✓ RUNNING" || echo "  ✗ NOT RUNNING"

echo ""
echo "2. Checking Ironic Nodes"
echo "----------------------------------------------------------------------"
echo "Baremetal nodes:"
openstack baremetal node list -c Name -c "Provisioning State" -c "Power State" -c Driver

NODE_COUNT=$(openstack baremetal node list -f value | wc -l)
echo ""
echo "Total nodes: $NODE_COUNT"

if [[ $NODE_COUNT -eq 0 ]]; then
    echo "  ✗ ERROR: No baremetal nodes found!"
    echo "  This means VirtualBMC/Sushy setup failed or nodes weren't created"
fi

echo ""
echo "3. Checking Placement Resource Providers"
echo "----------------------------------------------------------------------"
echo "Resource providers:"
openstack resource provider list -c uuid -c name

PROVIDER_COUNT=$(openstack resource provider list -f value | wc -l)
echo ""
echo "Total providers: $PROVIDER_COUNT"

if [[ $PROVIDER_COUNT -eq 0 ]]; then
    echo "  ✗ ERROR: No resource providers found!"
    echo "  This means Nova compute hasn't registered with Placement"
fi

echo ""
echo "4. Checking Node → Placement Mapping"
echo "----------------------------------------------------------------------"
NODES=$(openstack baremetal node list -f value -c UUID)
for NODE_UUID in $NODES; do
    echo "Node: $NODE_UUID"

    # Check if node exists as resource provider
    if openstack resource provider list -f value -c uuid | grep -q "$NODE_UUID"; then
        echo "  ✓ Node IS in Placement"

        # Check inventory
        INVENTORY=$(openstack resource provider inventory list "$NODE_UUID" -f value)
        if [[ -n "$INVENTORY" ]]; then
            echo "  ✓ Node HAS inventory:"
            openstack resource provider inventory list "$NODE_UUID" -c "Resource Class" -c Total
        else
            echo "  ✗ Node has NO inventory (this is the problem!)"
        fi
    else
        echo "  ✗ Node NOT in Placement (this is the problem!)"
    fi
    echo ""
done

echo ""
echo "5. Checking Nova Compute Services"
echo "----------------------------------------------------------------------"
unset OS_SYSTEM_SCOPE
export OS_PROJECT_NAME=admin
export OS_PROJECT_DOMAIN_NAME=Default

openstack compute service list -c Binary -c Host -c Status -c State

echo ""
echo "6. Checking Flavor Configuration"
echo "----------------------------------------------------------------------"
echo "Baremetal flavor:"
if openstack flavor show baremetal >/dev/null 2>&1; then
    openstack flavor show baremetal -c name -c ram -c disk -c vcpus -c properties
else
    echo "  ✗ ERROR: Baremetal flavor not found!"
fi

echo ""
echo "7. Checking Recent Nova Compute Logs"
echo "----------------------------------------------------------------------"
echo "Last 20 lines from Nova compute:"
journalctl -u devstack@n-cpu.service -n 20 --no-pager | grep -E "ERROR|WARNING|Traceback|resource.*provider|placement" || echo "  (no errors found)"

echo ""
echo "8. Checking Recent Ironic Conductor Logs"
echo "----------------------------------------------------------------------"
echo "Last 20 lines from Ironic conductor:"
journalctl -u devstack@ir-cond.service -n 20 --no-pager | grep -E "ERROR|WARNING|Traceback" || echo "  (no errors found)"

echo ""
echo "9. Summary & Diagnosis"
echo "----------------------------------------------------------------------"

# Determine the problem
if [[ $NODE_COUNT -eq 0 ]]; then
    echo "DIAGNOSIS: No baremetal nodes exist"
    echo "  → VirtualBMC/Sushy setup failed"
    echo "  → Check: journalctl -u devstack@ir-cond.service -n 100"

elif [[ $PROVIDER_COUNT -eq 0 ]]; then
    echo "DIAGNOSIS: No resource providers in Placement"
    echo "  → Nova compute service not running or not registered"
    echo "  → Fix: systemctl restart devstack@n-cpu.service"

else
    # Check if nodes are in Placement
    NODES_IN_PLACEMENT=0
    NODES_WITH_INVENTORY=0

    for NODE_UUID in $NODES; do
        if openstack resource provider list -f value -c uuid | grep -q "$NODE_UUID"; then
            ((NODES_IN_PLACEMENT++))

            INVENTORY=$(openstack resource provider inventory list "$NODE_UUID" -f value)
            if [[ -n "$INVENTORY" ]]; then
                ((NODES_WITH_INVENTORY++))
            fi
        fi
    done

    if [[ $NODES_IN_PLACEMENT -eq 0 ]]; then
        echo "DIAGNOSIS: Nodes exist but NOT in Placement"
        echo "  → Nova compute hasn't picked up Ironic nodes"
        echo "  → Fix: systemctl restart devstack@n-cpu.service"
        echo "  → Wait: 30 seconds for nova-compute to register nodes"

    elif [[ $NODES_WITH_INVENTORY -eq 0 ]]; then
        echo "DIAGNOSIS: Nodes in Placement but NO inventory"
        echo "  → Resource tracker hasn't set inventory yet"
        echo "  → Check: journalctl -u devstack@n-cpu.service | grep inventory"

    else
        echo "DIAGNOSIS: Everything looks configured correctly!"
        echo "  → Nodes: $NODE_COUNT"
        echo "  → In Placement: $NODES_IN_PLACEMENT"
        echo "  → With Inventory: $NODES_WITH_INVENTORY"
        echo ""
        echo "If provisioning still fails, check:"
        echo "  1. Network connectivity (ironic-provision network)"
        echo "  2. IPA images accessible (curl http://127.0.0.1:3928/ipa-kernel)"
        echo "  3. Power management working (openstack baremetal node power on <node>)"
    fi
fi

echo ""
echo "======================================================================"
echo "Diagnostic complete"
echo "======================================================================"
