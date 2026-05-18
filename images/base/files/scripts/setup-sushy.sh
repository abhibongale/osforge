#!/bin/bash
# Setup Sushy-Tools for simulating Redfish BMC
# This script runs inside the container
# Container-native alternative to VirtualBMC (which has libvirt permission issues)

set -eo pipefail

echo "[setup-sushy] Setting up virtual baremetal node with Redfish..."

# Check if sushy-tools is installed, install if missing (for dev mode)
if ! command -v sushy-emulator &> /dev/null; then
    echo "[setup-sushy] Sushy-Tools not found, installing..."
    # Use --ignore-installed to avoid conflicts with system packages
    pip3 install --break-system-packages --ignore-installed blinker sushy-tools
    echo "[setup-sushy] Sushy-Tools installed successfully"
fi

# Setup IPA images first (required for deployment)
if [[ -f /usr/local/bin/setup-ipa-images.sh ]]; then
    /usr/local/bin/setup-ipa-images.sh || {
        echo "[setup-sushy] ERROR: Failed to setup IPA images"
        exit 1
    }
fi

# Get HOST_IP from DevStack configuration
if [[ -f /opt/stack/devstack/.stackenv ]]; then
    source /opt/stack/devstack/.stackenv
fi

# Set OpenStack credentials directly (avoid DevStack functions issues)
# Use system scope for Ironic (required by oslo.policy)
export OS_AUTH_URL=http://${SERVICE_HOST:-127.0.0.1}/identity
export OS_USERNAME=admin
export OS_PASSWORD=secret
export OS_REGION_NAME=RegionOne
export OS_IDENTITY_API_VERSION=3
export OS_USER_DOMAIN_NAME=Default
export OS_SYSTEM_SCOPE=all

echo "[setup-sushy] Using SERVICE_HOST: ${SERVICE_HOST:-127.0.0.1}"

# Configuration from environment (set by job config)
IRONIC_VM_COUNT=${IRONIC_VM_COUNT:-1}
IRONIC_VM_SPECS_CPU=${IRONIC_VM_SPECS_CPU:-2}
IRONIC_VM_SPECS_RAM=${IRONIC_VM_SPECS_RAM:-2750}
IRONIC_VM_SPECS_DISK=${IRONIC_VM_SPECS_DISK:-4}
IRONIC_BOOT_MODE=${IRONIC_BOOT_MODE:-bios}
SUSHY_EMULATOR_PORT=${SUSHY_EMULATOR_PORT:-8000}

# Paths
LIBVIRT_DIR="/var/lib/libvirt/images"
SUSHY_CONFIG_DIR="/etc/sushy"

# Ensure directories exist
mkdir -p "$LIBVIRT_DIR"
mkdir -p "$SUSHY_CONFIG_DIR"

# Start libvirtd
echo "[setup-sushy] Starting libvirtd..."
if ! systemctl is-active --quiet libvirtd; then
    systemctl start libvirtd
    sleep 2
fi

# Configure Sushy-Tools emulator
echo "[setup-sushy] Configuring Sushy-Tools emulator..."
cat > "${SUSHY_CONFIG_DIR}/sushy-emulator.conf" << EOF
# Sushy-Tools Redfish BMC Emulator Configuration
# See: https://opendev.org/openstack/sushy-tools

# Network configuration
SUSHY_EMULATOR_LISTEN_IP = u'0.0.0.0'
SUSHY_EMULATOR_LISTEN_PORT = ${SUSHY_EMULATOR_PORT}

# libvirt backend (manages VMs)
SUSHY_EMULATOR_LIBVIRT_URI = u'qemu:///system'

# HTTP Basic Authentication - DISABLED for testing
# Ironic may not be sending credentials correctly, test without auth first
# SUSHY_EMULATOR_AUTH_FILE = u'/etc/sushy/htpasswd'

# Boot configuration
SUSHY_EMULATOR_IGNORE_BOOT_DEVICE = False
SUSHY_EMULATOR_BOOT_LOADER_MAP = {
    u'UEFI': {
        u'x86_64': u'/usr/share/OVMF/OVMF_CODE.fd'
    },
    u'Legacy': {}
}
EOF

echo "[setup-sushy]   Configuration written to ${SUSHY_CONFIG_DIR}/sushy-emulator.conf"

# PHASE 2: Configure HTTP Basic Authentication to match Ironic driver expectations
echo "[setup-sushy] Configuring HTTP Basic Authentication..."

# Install htpasswd utility if needed
if ! command -v htpasswd &> /dev/null; then
    echo "[setup-sushy]   Installing apache2-utils for htpasswd..."
    apt-get update -qq && apt-get install -y apache2-utils >/dev/null 2>&1
fi

# Create htpasswd file with admin:password (matches driver_info)
htpasswd -nbB admin password > "${SUSHY_CONFIG_DIR}/htpasswd"
chmod 600 "${SUSHY_CONFIG_DIR}/htpasswd"

echo "[setup-sushy]   ✓ Authentication file created at ${SUSHY_CONFIG_DIR}/htpasswd"

# Start Sushy-Tools emulator daemon
echo "[setup-sushy] Starting Sushy-Tools emulator daemon..."

# Clean up any existing sushy-emulator processes
echo "[setup-sushy] Cleaning up stale Sushy-Tools processes..."
pkill -9 -f sushy-emulator 2>/dev/null || true
sleep 1

# Start sushy-emulator in background with debug logging enabled
echo "[setup-sushy] Starting sushy-emulator daemon on port ${SUSHY_EMULATOR_PORT}..."
sushy-emulator --debug --config "${SUSHY_CONFIG_DIR}/sushy-emulator.conf" > /var/log/sushy-emulator.log 2>&1 &
SUSHY_PID=$!

# Wait for sushy-emulator to be ready (up to 30 seconds)
echo "[setup-sushy] Waiting for Sushy-Tools daemon to start (PID: $SUSHY_PID)..."
for i in {1..30}; do
    if curl -s http://127.0.0.1:${SUSHY_EMULATOR_PORT}/redfish/v1/ > /dev/null 2>&1; then
        echo "[setup-sushy] ✓ Sushy-Tools daemon is ready"
        break
    fi
    if [[ $i -eq 30 ]]; then
        echo "[setup-sushy] ERROR: Sushy-Tools daemon not responding after 30 seconds"
        echo "[setup-sushy] Checking for issues..."
        ps aux | grep sushy-emulator || true
        echo "[setup-sushy] Sushy-emulator logs:"
        cat /var/log/sushy-emulator.log || true
        exit 1
    fi
    echo "[setup-sushy]   Waiting... ($i/30)"
    sleep 1
done

# Test Redfish API (no authentication for now)
echo "[setup-sushy] Testing Redfish API..."
if curl -s "http://127.0.0.1:${SUSHY_EMULATOR_PORT}/redfish/v1/" | grep -q "ServiceRoot"; then
    echo "[setup-sushy]   ✓ Redfish API responding"
else
    echo "[setup-sushy]   ✗ WARNING: Redfish API not responding"
fi

# Clean up all existing Ironic baremetal nodes (from previous runs)
# This prevents resource conflicts and stale Placement providers
echo "[setup-sushy] Cleaning up existing Ironic baremetal nodes..."
openstack baremetal node list -f value -c UUID 2>/dev/null | while read -r node_uuid; do
    if [[ -n "$node_uuid" ]]; then
        echo "[setup-sushy]   Deleting stale node: $node_uuid"
        openstack baremetal node delete "$node_uuid" 2>/dev/null || true
    fi
done
echo "[setup-sushy]   Cleanup complete"

# Create virtual baremetal nodes
for i in $(seq 0 $((IRONIC_VM_COUNT - 1))); do
    NODE_NAME="baremetal-${i}"
    MAC_ADDRESS="52:54:00:$(printf '%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $i)"
    DISK_PATH="${LIBVIRT_DIR}/${NODE_NAME}.qcow2"

    echo "[setup-sushy] Creating node: $NODE_NAME (MAC: $MAC_ADDRESS)"

    # Create disk image
    if [[ ! -f "$DISK_PATH" ]]; then
        echo "[setup-sushy]   Creating disk: $DISK_PATH (${IRONIC_VM_SPECS_DISK}G)"
        qemu-img create -f qcow2 "$DISK_PATH" "${IRONIC_VM_SPECS_DISK}G"
    else
        echo "[setup-sushy]   Disk already exists: $DISK_PATH"
    fi

    # Create VM XML definition
    cat > "/tmp/${NODE_NAME}.xml" <<EOF
<domain type='kvm'>
  <name>${NODE_NAME}</name>
  <memory unit='MiB'>${IRONIC_VM_SPECS_RAM}</memory>
  <vcpu>${IRONIC_VM_SPECS_CPU}</vcpu>
  <os>
    <type arch='x86_64' machine='pc'>hvm</type>
    <boot dev='network'/>
    <boot dev='hd'/>
    <bootmenu enable='no'/>
EOF

    # Add BIOS or UEFI firmware
    if [[ "$IRONIC_BOOT_MODE" == "uefi" ]]; then
        cat >> "/tmp/${NODE_NAME}.xml" <<EOF
    <loader readonly='yes' type='pflash'>/usr/share/OVMF/OVMF_CODE.fd</loader>
EOF
    fi

    cat >> "/tmp/${NODE_NAME}.xml" <<EOF
  </os>
  <features>
    <acpi/>
    <apic/>
  </features>
  <cpu mode='host-passthrough'/>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='${DISK_PATH}'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <interface type='network'>
      <mac address='${MAC_ADDRESS}'/>
      <source network='default'/>
      <model type='virtio'/>
    </interface>
    <serial type='pty'>
      <target port='0'/>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
    <graphics type='vnc' port='-1' autoport='yes'/>
  </devices>
</domain>
EOF

    # Define the VM in libvirt
    echo "[setup-sushy]   Defining VM in libvirt..."
    if virsh list --all | grep -q "$NODE_NAME"; then
        echo "[setup-sushy]   VM already defined, undefining first..."
        virsh destroy "$NODE_NAME" 2>/dev/null || true
        virsh undefine "$NODE_NAME" 2>/dev/null || true
    fi
    virsh define "/tmp/${NODE_NAME}.xml"

    # Get the libvirt domain UUID
    # Sushy-Tools uses the libvirt UUID as the Redfish system identifier, not the domain name
    DOMAIN_UUID=$(virsh domuuid "$NODE_NAME")
    echo "[setup-sushy]   Libvirt domain UUID: $DOMAIN_UUID"

    # Verify VM is visible to Sushy-Tools
    echo "[setup-sushy]   Verifying VM is visible to Sushy-Tools..."
    sleep 2
    if curl -s "http://127.0.0.1:${SUSHY_EMULATOR_PORT}/redfish/v1/Systems/" | grep -q "$DOMAIN_UUID"; then
        echo "[setup-sushy]   ✓ VM is visible to Redfish API (UUID: $DOMAIN_UUID)"
    else
        echo "[setup-sushy]   ✗ WARNING: VM UUID may not be visible in Redfish API yet"
        echo "[setup-sushy]   Available systems:"
        curl -s "http://127.0.0.1:${SUSHY_EMULATOR_PORT}/redfish/v1/Systems/" | jq -r '.Members[]."@odata.id"' || true
    fi

    # Wait for Ironic API to be ready (only on first node)
    if [[ $i -eq 0 ]]; then
        # Ensure Apache is running (it proxies API requests to uWSGI)
        echo "[setup-sushy] Checking Apache HTTP proxy..."
        if ! systemctl is-active --quiet apache2; then
            echo "[setup-sushy]   Apache not running, starting it..."
            systemctl start apache2
            sleep 3
        fi

        if systemctl is-active --quiet apache2; then
            echo "[setup-sushy]   Apache is running"
        else
            echo "[setup-sushy]   WARNING: Apache failed to start - API may not be accessible"
            systemctl status apache2 --no-pager || true
        fi

        echo "[setup-sushy] Waiting for Ironic API to be ready..."
        max_wait=180  # 3 minutes
        elapsed=0
        while [[ $elapsed -lt $max_wait ]]; do
            if openstack baremetal driver list &>/dev/null; then
                echo "[setup-sushy] ✓ Ironic API is ready"
                break
            fi
            echo "[setup-sushy]   Waiting for API... ($elapsed/$max_wait seconds)"
            sleep 5
            ((elapsed+=5))
        done

        if [[ $elapsed -ge $max_wait ]]; then
            echo "[setup-sushy] ERROR: Ironic API not ready after ${max_wait}s"
            echo "[setup-sushy] Checking Apache (HTTP proxy)..."
            systemctl status apache2 --no-pager || true
            echo ""
            echo "[setup-sushy] Checking Ironic services..."
            systemctl status devstack@ir-api.service --no-pager || true
            systemctl status devstack@ir-cond.service --no-pager || true
            echo ""
            echo "[setup-sushy] Checking RabbitMQ status..."
            systemctl status rabbitmq-server --no-pager || true
            echo ""
            echo "[setup-sushy] Checking recent Ironic API logs..."
            journalctl -u devstack@ir-api.service -n 30 --no-pager || true
            exit 1
        fi

        # Verify Redfish driver is available
        echo "[setup-sushy] Verifying Redfish driver availability..."
        if openstack baremetal driver list -f value -c "Supported driver(s)" | grep -q "redfish"; then
            echo "[setup-sushy]   ✓ Redfish driver is available"
        else
            echo "[setup-sushy]   ✗ WARNING: Redfish driver may not be enabled"
            echo "[setup-sushy]   Available drivers:"
            openstack baremetal driver list | sed 's/^/    /'
        fi
    fi

    # Register node in Ironic with Redfish driver
    echo "[setup-sushy]   Registering node in Ironic with Redfish driver..."

    # Check if node already exists
    if openstack baremetal node list -f value -c Name | grep -q "^${NODE_NAME}$"; then
        echo "[setup-sushy]   Node already exists in Ironic, deleting first..."
        NODE_UUID=$(openstack baremetal node list -f value -c UUID -c Name | grep "$NODE_NAME" | awk '{print $1}')
        openstack baremetal node delete "$NODE_UUID" || true
    fi

    # PHASE 3: Validate Redfish responses before node registration
    echo "[setup-sushy]   Validating Redfish compliance before node registration..."

    SYSTEM_RESPONSE=$(curl -s "http://127.0.0.1:${SUSHY_EMULATOR_PORT}/redfish/v1/Systems/${DOMAIN_UUID}")

    # Check for required fields that sushy library expects
    REQUIRED_FIELDS=("Id" "Name" "PowerState" "ProcessorSummary" "MemorySummary")
    VALIDATION_FAILED=false

    for field in "${REQUIRED_FIELDS[@]}"; do
        if ! echo "$SYSTEM_RESPONSE" | jq -e ".$field" >/dev/null 2>&1; then
            echo "[setup-sushy]     ✗ Missing required field: .$field"
            VALIDATION_FAILED=true
        else
            echo "[setup-sushy]     ✓ Field present: .$field"
        fi
    done

    if [[ "$VALIDATION_FAILED" == "true" ]]; then
        echo "[setup-sushy]   ✗ CRITICAL: Redfish response missing required fields"
        echo "[setup-sushy]   Response received:"
        echo "$SYSTEM_RESPONSE" | jq '.' 2>/dev/null || echo "$SYSTEM_RESPONSE"
        echo "[setup-sushy]   This will cause sushy library to receive None representation"
        exit 1
    fi

    echo "[setup-sushy]   ✓ Redfish validation passed - all required fields present"

    # Create node with Redfish driver
    # This is the KEY difference from IPMI setup
    # IMPORTANT: Use libvirt domain UUID as redfish_system_id, not the domain name
    # Sushy-Tools exposes systems by their libvirt UUID, not by name
    # CRITICAL FIX: redfish_address should be BASE + /redfish/v1, then driver adds /Systems/{id}
    # Driver constructs: {redfish_address}/Systems/{redfish_system_id}
    NODE_UUID=$(openstack baremetal node create \
        --name "$NODE_NAME" \
        --driver redfish \
        --driver-info redfish_address=http://127.0.0.1:${SUSHY_EMULATOR_PORT}/redfish/v1 \
        --driver-info redfish_system_id=${DOMAIN_UUID} \
        --driver-info redfish_verify_ca=false \
        --driver-info deploy_kernel=http://${SERVICE_HOST}:3928/ipa-kernel \
        --driver-info deploy_ramdisk=http://${SERVICE_HOST}:3928/ipa-ramdisk \
        --property cpus="$IRONIC_VM_SPECS_CPU" \
        --property memory_mb="$IRONIC_VM_SPECS_RAM" \
        --property local_gb="$IRONIC_VM_SPECS_DISK" \
        --property cpu_arch=x86_64 \
        --resource-class baremetal \
        -f value -c uuid)

    echo "[setup-sushy]   Node created: $NODE_UUID"

    # Add port (NIC)
    echo "[setup-sushy]   Adding port to node..."
    openstack baremetal port create \
        --node "$NODE_UUID" \
        "$MAC_ADDRESS"

    # Set boot interface and deploy interface
    openstack baremetal node set "$NODE_UUID" \
        --boot-interface ipxe \
        --deploy-interface ${IRONIC_DEFAULT_DEPLOY_INTERFACE:-direct}

    # Debug: Verify Redfish endpoint before setting node to manageable
    echo "[setup-sushy]   Debugging Redfish endpoint..."
    REDFISH_BASE=$(openstack baremetal node show "$NODE_UUID" -f json 2>/dev/null | jq -r '.driver_info.redfish_address')
    SYSTEM_ID=$(openstack baremetal node show "$NODE_UUID" -f json 2>/dev/null | jq -r '.driver_info.redfish_system_id')

    # Check if redfish_address already contains the full system path
    if [[ "$REDFISH_BASE" == */redfish/v1/Systems/* ]]; then
        # Full path already in redfish_address
        REDFISH_ADDR="$REDFISH_BASE"
        echo "[setup-sushy]     Redfish address (full path): $REDFISH_ADDR"
    elif [[ -n "$SYSTEM_ID" ]] && [[ "$SYSTEM_ID" != "null" ]]; then
        # Base URL + system ID
        REDFISH_ADDR="${REDFISH_BASE}/redfish/v1/Systems/${SYSTEM_ID}"
        echo "[setup-sushy]     Redfish base: $REDFISH_BASE"
        echo "[setup-sushy]     System ID: $SYSTEM_ID"
        echo "[setup-sushy]     Full system URL: $REDFISH_ADDR"
    else
        # Just base URL, no system ID
        REDFISH_ADDR="$REDFISH_BASE"
        echo "[setup-sushy]     Redfish address: $REDFISH_ADDR"
    fi

    # Test if Redfish endpoint is accessible (no authentication)
    echo "[setup-sushy]     Testing Redfish system endpoint..."
    if curl -s -o /dev/null -w "%{http_code}" "$REDFISH_ADDR" | grep -q "200"; then
        echo "[setup-sushy]     ✓ Redfish endpoint is accessible (HTTP 200)"
    else
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$REDFISH_ADDR")
        echo "[setup-sushy]     ✗ WARNING: Redfish endpoint returned HTTP $HTTP_CODE"
        echo "[setup-sushy]     Response body:"
        curl -s "$REDFISH_ADDR" | jq '.' 2>/dev/null || curl -s "$REDFISH_ADDR"
    fi

    # PHASE 1: Comprehensive debugging - capture HTTP headers and JSON structure
    echo "[setup-sushy]     === Detailed Redfish Response Analysis ==="

    echo "[setup-sushy]       HTTP Headers:"
    curl -v "$REDFISH_ADDR" 2>&1 | grep -E "< HTTP|< Content-Type|< Content-Length" | sed 's/^/        /'

    echo "[setup-sushy]       Response Body (first 500 chars):"
    RESPONSE_BODY=$(curl -s "$REDFISH_ADDR")
    echo "$RESPONSE_BODY" | head -c 500
    echo ""

    echo "[setup-sushy]       Validating JSON structure:"
    if echo "$RESPONSE_BODY" | jq '.' >/dev/null 2>&1; then
        echo "[setup-sushy]       ✓ Valid JSON response"

        # Check critical Redfish fields that sushy library expects
        echo "[setup-sushy]       Checking required Redfish fields:"
        for field in "@odata.id" "Id" "Name" "PowerState" "ProcessorSummary" "MemorySummary"; do
            if echo "$RESPONSE_BODY" | jq -e ".\"$field\"" >/dev/null 2>&1; then
                FIELD_VALUE=$(echo "$RESPONSE_BODY" | jq -r ".\"$field\"" 2>/dev/null | head -c 100)
                echo "[setup-sushy]         ✓ Contains .$field = $FIELD_VALUE"
            else
                echo "[setup-sushy]         ✗ CRITICAL: Missing .$field (sushy library WILL fail!)"
                if [[ "$field" == "@odata.id" ]]; then
                    echo "[setup-sushy]           This is WHY sushy constructs malformed URLs!"
                fi
            fi
        done

        # If @odata.id is present, verify it contains the full path
        if echo "$RESPONSE_BODY" | jq -e '."@odata.id"' >/dev/null 2>&1; then
            ODATA_ID=$(echo "$RESPONSE_BODY" | jq -r '."@odata.id"')
            if [[ "$ODATA_ID" == /redfish/v1/Systems/* ]]; then
                echo "[setup-sushy]         ✓ @odata.id has correct format: $ODATA_ID"
            else
                echo "[setup-sushy]         ✗ WARNING: @odata.id format may be wrong: $ODATA_ID"
                echo "[setup-sushy]           Expected: /redfish/v1/Systems/{uuid}"
            fi
        fi
    else
        echo "[setup-sushy]       ✗ CRITICAL: INVALID JSON - sushy library will receive None!"
        echo "[setup-sushy]       Raw response:"
        echo "$RESPONSE_BODY" | sed 's/^/        /'
    fi
    echo "[setup-sushy]     === End Response Analysis ==="

    # Check if system is visible in Sushy-Tools
    echo "[setup-sushy]     Checking if system is visible in Redfish API..."
    ALL_SYSTEMS=$(curl -s "http://127.0.0.1:${SUSHY_EMULATOR_PORT}/redfish/v1/Systems/")
    # SYSTEM_ID should be the libvirt domain UUID, not the name
    if echo "$ALL_SYSTEMS" | grep -q "$SYSTEM_ID"; then
        echo "[setup-sushy]     ✓ System $SYSTEM_ID is visible in Redfish API"
    else
        echo "[setup-sushy]     ✗ WARNING: System $SYSTEM_ID NOT found in Redfish API"
        echo "[setup-sushy]     Expected UUID: $DOMAIN_UUID"
        echo "[setup-sushy]     Available systems:"
        echo "$ALL_SYSTEMS" | jq '.Members' 2>/dev/null || echo "$ALL_SYSTEMS"
    fi

    # Check Sushy-Tools logs for errors
    if [[ -f /var/log/sushy-emulator.log ]]; then
        echo "[setup-sushy]     Last 10 lines of Sushy-Tools log:"
        tail -10 /var/log/sushy-emulator.log
    fi

    # Set node to manageable state
    echo "[setup-sushy]   Setting node to manageable state..."
    if ! openstack baremetal node manage "$NODE_UUID" --wait 60; then
        echo "[setup-sushy]   ✗ ERROR: Failed to set node to manageable state"
        echo "[setup-sushy]   Checking node status and errors..."
        openstack baremetal node show "$NODE_UUID" -c provisioning_state -c last_error -f yaml

        echo "[setup-sushy]   Checking Ironic conductor logs for errors..."
        journalctl -u devstack@ir-cond.service --since "2 minutes ago" --no-pager | grep -E "ERROR|redfish|$NODE_UUID" | tail -20 || true

        echo "[setup-sushy]   Node validation status:"
        openstack baremetal node validate "$NODE_UUID" || true

        exit 1
    fi

    # Provide the node (make it available)
    echo "[setup-sushy]   Providing node (making available)..."
    if ! openstack baremetal node provide "$NODE_UUID" --wait 120; then
        echo "[setup-sushy]   ✗ ERROR: Failed to provide node"
        openstack baremetal node show "$NODE_UUID" -c provisioning_state -c last_error -f yaml
        exit 1
    fi

    echo "[setup-sushy]   Node $NODE_NAME ready (UUID: $NODE_UUID)"
done

# Make ironic-provision network shared for Tempest dynamic credentials
# Dynamic credentials create new test projects that need access to this network
echo "[setup-sushy] Configuring ironic-provision network..."
unset OS_SYSTEM_SCOPE
export OS_PROJECT_NAME=admin
export OS_PROJECT_DOMAIN_NAME=Default

if openstack network show ironic-provision >/dev/null 2>&1; then
    echo "[setup-sushy]   Making ironic-provision network shared..."
    openstack network set --share ironic-provision
    echo "[setup-sushy]   ironic-provision network is now shared across all projects"
else
    echo "[setup-sushy]   WARNING: ironic-provision network not found, skipping share configuration"
fi

# Create baremetal flavor for Nova
echo "[setup-sushy] Creating baremetal flavor..."

# Nova operations require project scope, not system scope
echo "[setup-sushy]   Using project-scoped credentials for Nova operations..."

if openstack flavor show baremetal >/dev/null 2>&1; then
    echo "[setup-sushy]   Flavor 'baremetal' already exists, deleting..."
    openstack flavor delete baremetal || true
fi

# Create the flavor with specs matching our virtual baremetal nodes
# Use minimal values since we're using custom resource classes
# Make it public so Tempest's dynamically created projects can use it
openstack flavor create \
    --public \
    --ram ${IRONIC_VM_SPECS_RAM} \
    --disk ${IRONIC_VM_SPECS_DISK} \
    --vcpus ${IRONIC_VM_SPECS_CPU} \
    --property resources:CUSTOM_BAREMETAL=1 \
    --property resources:DISK_GB=0 \
    --property resources:MEMORY_MB=0 \
    --property resources:VCPU=0 \
    --property cpu_arch=x86_64 \
    baremetal

echo "[setup-sushy]   Flavor 'baremetal' created successfully"

# Verify flavor is visible and public
echo "[setup-sushy]   Verifying flavor visibility..."
openstack flavor show baremetal -f value -c name -c "OS-FLV-EXT-DATA:ephemeral" || echo "WARNING: Flavor not visible!"
openstack flavor list --all | grep baremetal || echo "WARNING: Flavor not in list!"

# Switch back to system scope for Ironic operations
export OS_SYSTEM_SCOPE=all
unset OS_PROJECT_NAME
unset OS_PROJECT_DOMAIN_NAME

# Verify nodes are available
echo "[setup-sushy] Verifying nodes..."
openstack baremetal node list

# Show Sushy-Tools status
echo "[setup-sushy] Sushy-Tools emulator status:"
ps aux | grep sushy-emulator | grep -v grep || echo "  WARNING: Process not found"
echo "[setup-sushy] Sushy-Tools listening on: http://127.0.0.1:${SUSHY_EMULATOR_PORT}"
echo "[setup-sushy] Redfish Systems:"
curl -s http://127.0.0.1:${SUSHY_EMULATOR_PORT}/redfish/v1/Systems/ | grep -o '"Name":"[^"]*"' | sed 's/"Name":"/  - /;s/"$//' || echo "  ERROR: Could not list systems"

echo "[setup-sushy] Sushy-Tools setup complete - $IRONIC_VM_COUNT node(s) ready with Redfish"

# Discover and map compute hosts to Nova cells
# This is required for Nova scheduler to find the compute hosts
echo "[setup-sushy] Waiting for Nova compute service to fully register (10 seconds)..."
sleep 10
echo "[setup-sushy] Discovering compute hosts for Nova cells..."
cd /opt/stack/nova && su -s /bin/bash stack -c "nova-manage cell_v2 discover_hosts --verbose 2>&1" || echo "  WARNING: Cell discovery failed"
echo "[setup-sushy] Compute host discovery complete"

# CRITICAL FIX: Restart Nova compute to force resource provider refresh
# Nova compute needs to re-scan Ironic nodes and register them in Placement
# Without this, the nodes won't appear as available resources for scheduling
echo "[setup-sushy] Restarting Nova compute to refresh resource providers..."
systemctl restart devstack@n-cpu.service
sleep 10

# Wait for Nova compute to re-register with updated inventory
echo "[setup-sushy] Waiting for Nova compute to update Placement (30 seconds)..."
sleep 30

# Debug Nova/Placement integration
echo "[setup-sushy] ====== DEBUG: Nova/Placement Integration ======"

echo "[setup-sushy] Nova compute service status:"
systemctl is-active devstack@n-cpu.service && echo "  RUNNING" || echo "  NOT RUNNING!"

echo "[setup-sushy] Placement resource providers:"
openstack resource provider list -f value -c uuid -c name 2>/dev/null || echo "  ERROR: Could not list providers"

echo "[setup-sushy] Nova compute services:"
openstack compute service list -f value -c Binary -c Host -c Status 2>/dev/null || echo "  ERROR: Could not list services"

echo "[setup-sushy] Checking if node is in Placement:"
NODE_UUID=$(openstack baremetal node list -f value -c UUID 2>/dev/null | head -1)
if [[ -n "$NODE_UUID" ]]; then
    echo "  Node UUID: $NODE_UUID"
    if openstack resource provider list -f value -c uuid 2>/dev/null | grep -q "$NODE_UUID"; then
        echo "  ✓ Node IS registered in Placement"
        # Show the node's inventory
        echo "[setup-sushy] Node inventory in Placement:"
        openstack resource provider inventory list "$NODE_UUID" -f table 2>/dev/null | sed 's/^/  /'
    else
        echo "  ✗ Node NOT in Placement - provisioning will FAIL!"
        echo "  This means Nova compute didn't pick up the Ironic node."
        echo "  Check: journalctl -u devstack@n-cpu.service -n 100"
    fi
fi

# Verify resource providers have inventory
echo "[setup-sushy] Verifying resource providers have inventory..."
PROVIDERS_WITH_INVENTORY=0
openstack resource provider list -f value -c uuid 2>/dev/null | while read -r provider_uuid; do
    INVENTORY_COUNT=$(openstack resource provider inventory list "$provider_uuid" -f value 2>/dev/null | wc -l)
    if [[ $INVENTORY_COUNT -gt 0 ]]; then
        echo "  ✓ Provider $provider_uuid has $INVENTORY_COUNT resource class(es)"
        PROVIDERS_WITH_INVENTORY=$((PROVIDERS_WITH_INVENTORY + 1))
    else
        echo "  ✗ Provider $provider_uuid has NO inventory"
    fi
done

exit 0
