#!/bin/bash
# Setup VirtualBMC for simulating IPMI
# This script runs inside the container

set -eo pipefail

echo "[setup-vbmc] Setting up virtual baremetal node..."

# Setup IPA images first (required for deployment)
if [[ -f /usr/local/bin/setup-ipa-images.sh ]]; then
    /usr/local/bin/setup-ipa-images.sh || {
        echo "[setup-vbmc] ERROR: Failed to setup IPA images"
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

echo "[setup-vbmc] Using SERVICE_HOST: ${SERVICE_HOST:-127.0.0.1}"

# Configuration from environment (set by job config)
IRONIC_VM_COUNT=${IRONIC_VM_COUNT:-1}
IRONIC_VM_SPECS_CPU=${IRONIC_VM_SPECS_CPU:-2}
IRONIC_VM_SPECS_RAM=${IRONIC_VM_SPECS_RAM:-2750}
IRONIC_VM_SPECS_DISK=${IRONIC_VM_SPECS_DISK:-4}
IRONIC_BOOT_MODE=${IRONIC_BOOT_MODE:-bios}
VBMC_BASE_PORT=${VBMC_BASE_PORT:-6230}

# Paths
LIBVIRT_DIR="/var/lib/libvirt/images"
VBMC_CONFIG_DIR="/root/.vbmc"

# Ensure directories exist
mkdir -p "$LIBVIRT_DIR"
mkdir -p "$VBMC_CONFIG_DIR"

# Configure libvirt for container environment
if [[ -f /usr/local/bin/configure-libvirt.sh ]]; then
    /usr/local/bin/configure-libvirt.sh || {
        echo "[setup-vbmc] ERROR: Failed to configure libvirt"
        exit 1
    }
fi

# Start libvirtd
echo "[setup-vbmc] Starting libvirtd..."
if ! systemctl is-active --quiet libvirtd; then
    systemctl start libvirtd
    sleep 2
fi

# Start VirtualBMC daemon
echo "[setup-vbmc] Starting VirtualBMC daemon..."

# Clean up any stale VirtualBMC state
# The master.pid file can prevent daemon from starting
echo "[setup-vbmc] Cleaning up stale VirtualBMC state..."
rm -f /root/.vbmc/master.pid
pkill -9 vbmcd 2>/dev/null || true
sleep 1

# Start vbmcd in background without --foreground
# The daemon will fork itself properly
echo "[setup-vbmc] Starting vbmcd daemon..."
vbmcd &
VBMCD_PID=$!

# Wait for vbmcd to be ready (up to 10 seconds)
echo "[setup-vbmc] Waiting for VirtualBMC daemon to start (PID: $VBMCD_PID)..."
for i in {1..10}; do
    if vbmc list &>/dev/null; then
        echo "[setup-vbmc] VirtualBMC daemon ready"
        break
    fi
    echo "[setup-vbmc]   Waiting... ($i/10)"
    sleep 1
done

# Verify daemon is responding
if ! vbmc list &>/dev/null; then
    echo "[setup-vbmc] ERROR: VirtualBMC daemon not responding after 10 seconds"
    echo "[setup-vbmc] Checking for issues..."
    ls -la /root/.vbmc/ 2>/dev/null || true
    ps aux | grep vbmc || true
    exit 1
fi

# Clean up all existing VirtualBMC nodes (from previous runs)
# This prevents port conflicts when we create new nodes
echo "[setup-vbmc] Cleaning up existing VirtualBMC nodes..."
vbmc list --format value -c "Domain name" 2>/dev/null | while read -r domain; do
    if [[ -n "$domain" ]]; then
        echo "[setup-vbmc]   Removing stale node: $domain"
        vbmc stop "$domain" 2>/dev/null || true
        vbmc delete "$domain" 2>/dev/null || true
    fi
done
echo "[setup-vbmc]   Cleanup complete"

# Clean up all existing Ironic baremetal nodes (from previous runs)
# This prevents resource conflicts and stale Placement providers
echo "[setup-vbmc] Cleaning up existing Ironic baremetal nodes..."
openstack baremetal node list -f value -c UUID 2>/dev/null | while read -r node_uuid; do
    if [[ -n "$node_uuid" ]]; then
        echo "[setup-vbmc]   Deleting stale node: $node_uuid"
        openstack baremetal node delete "$node_uuid" 2>/dev/null || true
    fi
done
echo "[setup-vbmc]   Cleanup complete"

# Create virtual baremetal nodes
for i in $(seq 0 $((IRONIC_VM_COUNT - 1))); do
    NODE_NAME="baremetal-${i}"
    MAC_ADDRESS="52:54:00:$(printf '%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $i)"
    VBMC_PORT=$((VBMC_BASE_PORT + i))
    DISK_PATH="${LIBVIRT_DIR}/${NODE_NAME}.qcow2"

    echo "[setup-vbmc] Creating node: $NODE_NAME (MAC: $MAC_ADDRESS, VBMC port: $VBMC_PORT)"

    # Create disk image
    if [[ ! -f "$DISK_PATH" ]]; then
        echo "[setup-vbmc]   Creating disk: $DISK_PATH (${IRONIC_VM_SPECS_DISK}G)"
        qemu-img create -f qcow2 "$DISK_PATH" "${IRONIC_VM_SPECS_DISK}G"
    else
        echo "[setup-vbmc]   Disk already exists: $DISK_PATH"
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
    echo "[setup-vbmc]   Defining VM in libvirt..."
    if virsh list --all | grep -q "$NODE_NAME"; then
        echo "[setup-vbmc]   VM already defined, undefining first..."
        virsh destroy "$NODE_NAME" 2>/dev/null || true
        virsh undefine "$NODE_NAME" 2>/dev/null || true
    fi
    virsh define "/tmp/${NODE_NAME}.xml"

    # Add to VirtualBMC
    echo "[setup-vbmc]   Adding to VirtualBMC..."
    if vbmc list | grep -q "$NODE_NAME"; then
        echo "[setup-vbmc]   Already in VirtualBMC, deleting first..."
        vbmc delete "$NODE_NAME" || true
    fi

    vbmc add "$NODE_NAME" \
        --port "$VBMC_PORT" \
        --username admin \
        --password password \
        --address 127.0.0.1

    vbmc start "$NODE_NAME"
    sleep 1

    # Verify VirtualBMC is running
    if vbmc show "$NODE_NAME" | grep -q "running"; then
        echo "[setup-vbmc]   VirtualBMC running for $NODE_NAME"
    else
        echo "[setup-vbmc]   WARNING: VirtualBMC may not be running for $NODE_NAME"
    fi

    # Wait for Ironic API to be ready (only on first node)
    if [[ $i -eq 0 ]]; then
        # Ensure Apache is running (it proxies API requests to uWSGI)
        echo "[setup-vbmc] Checking Apache HTTP proxy..."
        if ! systemctl is-active --quiet apache2; then
            echo "[setup-vbmc]   Apache not running, starting it..."
            systemctl start apache2
            sleep 3
        fi

        if systemctl is-active --quiet apache2; then
            echo "[setup-vbmc]   Apache is running"
        else
            echo "[setup-vbmc]   WARNING: Apache failed to start - API may not be accessible"
            systemctl status apache2 --no-pager || true
        fi

        echo "[setup-vbmc] Waiting for Ironic API to be ready..."
        max_wait=180  # Increased from 120 to 180 seconds
        elapsed=0
        while [[ $elapsed -lt $max_wait ]]; do
            if openstack baremetal driver list &>/dev/null; then
                echo "[setup-vbmc] Ironic API is ready"
                break
            fi
            echo "[setup-vbmc]   Waiting for API... ($elapsed/$max_wait seconds)"
            sleep 5
            ((elapsed+=5))
        done

        if [[ $elapsed -ge $max_wait ]]; then
            echo "[setup-vbmc] ERROR: Ironic API not ready after ${max_wait}s"
            echo "[setup-vbmc] Checking Apache (HTTP proxy)..."
            systemctl status apache2 --no-pager || true
            echo ""
            echo "[setup-vbmc] Checking Ironic services..."
            systemctl status devstack@ir-api.service --no-pager || true
            systemctl status devstack@ir-cond.service --no-pager || true
            echo ""
            echo "[setup-vbmc] Checking RabbitMQ status..."
            systemctl status rabbitmq-server --no-pager || true
            rabbitmqctl status || true
            echo ""
            echo "[setup-vbmc] Checking listening ports..."
            ss -tlnp | grep -E '6385|:80 ' || echo "No services listening on port 6385 or 80"
            echo ""
            echo "[setup-vbmc] Checking recent Apache logs..."
            journalctl -u apache2 -n 30 --no-pager || true
            echo ""
            echo "[setup-vbmc] Checking recent Ironic API logs..."
            journalctl -u devstack@ir-api.service -n 30 --no-pager || true
            echo ""
            echo "[setup-vbmc] Checking recent Ironic Conductor logs..."
            journalctl -u devstack@ir-cond.service -n 30 --no-pager || true
            echo ""
            echo "[setup-vbmc] Testing direct API access (should be proxied by Apache)..."
            curl -v http://127.0.0.1:6385/ 2>&1 || true
            exit 1
        fi
    fi

    # Register node in Ironic
    echo "[setup-vbmc]   Registering node in Ironic..."

    # Check if node already exists
    if openstack baremetal node list -f value -c Name | grep -q "^${NODE_NAME}$"; then
        echo "[setup-vbmc]   Node already exists in Ironic, deleting first..."
        NODE_UUID=$(openstack baremetal node list -f value -c UUID -c Name | grep "$NODE_NAME" | awk '{print $1}')
        openstack baremetal node delete "$NODE_UUID" || true
    fi

    # Create node
    NODE_UUID=$(openstack baremetal node create \
        --name "$NODE_NAME" \
        --driver ipmi \
        --driver-info ipmi_address=127.0.0.1 \
        --driver-info ipmi_port="$VBMC_PORT" \
        --driver-info ipmi_username=admin \
        --driver-info ipmi_password=password \
        --driver-info deploy_kernel=http://${SERVICE_HOST}:3928/ipa-kernel \
        --driver-info deploy_ramdisk=http://${SERVICE_HOST}:3928/ipa-ramdisk \
        --property cpus="$IRONIC_VM_SPECS_CPU" \
        --property memory_mb="$IRONIC_VM_SPECS_RAM" \
        --property local_gb="$IRONIC_VM_SPECS_DISK" \
        --property cpu_arch=x86_64 \
        --resource-class baremetal \
        -f value -c uuid)

    echo "[setup-vbmc]   Node created: $NODE_UUID"

    # Add port (NIC)
    echo "[setup-vbmc]   Adding port to node..."
    openstack baremetal port create \
        --node "$NODE_UUID" \
        "$MAC_ADDRESS"

    # Set boot interface and deploy interface
    openstack baremetal node set "$NODE_UUID" \
        --boot-interface ipxe \
        --deploy-interface ${IRONIC_DEFAULT_DEPLOY_INTERFACE:-direct}

    # Set node to manageable state
    echo "[setup-vbmc]   Setting node to manageable state..."
    openstack baremetal node manage "$NODE_UUID" --wait 60

    # Provide the node (make it available)
    echo "[setup-vbmc]   Providing node (making available)..."
    openstack baremetal node provide "$NODE_UUID" --wait 120

    echo "[setup-vbmc]   Node $NODE_NAME ready (UUID: $NODE_UUID)"
done

# Make ironic-provision network shared for Tempest dynamic credentials
# Dynamic credentials create new test projects that need access to this network
echo "[setup-vbmc] Configuring ironic-provision network..."
unset OS_SYSTEM_SCOPE
export OS_PROJECT_NAME=admin
export OS_PROJECT_DOMAIN_NAME=Default

if openstack network show ironic-provision >/dev/null 2>&1; then
    echo "[setup-vbmc]   Making ironic-provision network shared..."
    openstack network set --share ironic-provision
    echo "[setup-vbmc]   ironic-provision network is now shared across all projects"
else
    echo "[setup-vbmc]   WARNING: ironic-provision network not found, skipping share configuration"
fi

# Create baremetal flavor for Nova
echo "[setup-vbmc] Creating baremetal flavor..."

# Nova operations require project scope, not system scope
echo "[setup-vbmc]   Using project-scoped credentials for Nova operations..."

if openstack flavor show baremetal >/dev/null 2>&1; then
    echo "[setup-vbmc]   Flavor 'baremetal' already exists, deleting..."
    openstack flavor delete baremetal || true
fi

# Create the flavor with specs matching our virtual baremetal nodes
# Use minimal values since we're using custom resource classes
# Note: Not setting capabilities:boot_mode as it's auto-detected from node firmware
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

echo "[setup-vbmc]   Flavor 'baremetal' created successfully"

# Verify flavor is visible and public
echo "[setup-vbmc]   Verifying flavor visibility..."
openstack flavor show baremetal -f value -c name -c "OS-FLV-EXT-DATA:ephemeral" || echo "WARNING: Flavor not visible!"
openstack flavor list --all | grep baremetal || echo "WARNING: Flavor not in list!"

# Switch back to system scope for Ironic operations
export OS_SYSTEM_SCOPE=all
unset OS_PROJECT_NAME
unset OS_PROJECT_DOMAIN_NAME

# Verify nodes are available
echo "[setup-vbmc] Verifying nodes..."
openstack baremetal node list

# Show VirtualBMC status
echo "[setup-vbmc] VirtualBMC status:"
vbmc list

echo "[setup-vbmc] VirtualBMC setup complete - $IRONIC_VM_COUNT node(s) ready"

# Discover and map compute hosts to Nova cells
# This is required for Nova scheduler to find the compute hosts
echo "[setup-vbmc] Waiting for Nova compute service to fully register (10 seconds)..."
sleep 10
echo "[setup-vbmc] Discovering compute hosts for Nova cells..."
cd /opt/stack/nova && su -s /bin/bash stack -c "nova-manage cell_v2 discover_hosts --verbose 2>&1" || echo "  WARNING: Cell discovery failed"
echo "[setup-vbmc] Compute host discovery complete"

# CRITICAL FIX: Restart Nova compute to force resource provider refresh
# Nova compute needs to re-scan Ironic nodes and register them in Placement
# Without this, the nodes won't appear as available resources for scheduling
echo "[setup-vbmc] Restarting Nova compute to refresh resource providers..."
systemctl restart devstack@n-cpu.service
sleep 10

# Wait for Nova compute to re-register with updated inventory
echo "[setup-vbmc] Waiting for Nova compute to update Placement (30 seconds)..."
sleep 30

# Debug Nova/Placement integration
echo "[setup-vbmc] ====== DEBUG: Nova/Placement Integration ======"

echo "[setup-vbmc] Nova compute service status:"
systemctl is-active devstack@n-cpu.service && echo "  RUNNING" || echo "  NOT RUNNING!"

echo "[setup-vbmc] Placement resource providers:"
openstack resource provider list -f value -c uuid -c name 2>/dev/null || echo "  ERROR: Could not list providers"

echo "[setup-vbmc] Nova compute services:"
openstack compute service list -f value -c Binary -c Host -c Status 2>/dev/null || echo "  ERROR: Could not list services"

echo "[setup-vbmc] Checking if node is in Placement:"
NODE_UUID=$(openstack baremetal node list -f value -c UUID 2>/dev/null | head -1)
if [[ -n "$NODE_UUID" ]]; then
    echo "  Node UUID: $NODE_UUID"
    if openstack resource provider list -f value -c uuid 2>/dev/null | grep -q "$NODE_UUID"; then
        echo "  ✓ Node IS registered in Placement"
        # Show the node's inventory
        echo "[setup-vbmc] Node inventory in Placement:"
        openstack resource provider inventory list "$NODE_UUID" -f table 2>/dev/null | sed 's/^/  /'
    else
        echo "  ✗ Node NOT in Placement - provisioning will FAIL!"
        echo "  This means Nova compute didn't pick up the Ironic node."
        echo "  Check: journalctl -u devstack@n-cpu.service -n 100"
    fi
fi

# Verify resource providers have inventory
echo "[setup-vbmc] Verifying resource providers have inventory..."
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
