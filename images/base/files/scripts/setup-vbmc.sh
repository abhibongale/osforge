#!/bin/bash
# Setup VirtualBMC for simulating IPMI
# This script runs inside the container

set -eo pipefail

echo "[setup-vbmc] Setting up virtual baremetal node..."

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

# Start libvirtd
echo "[setup-vbmc] Starting libvirtd..."
if ! systemctl is-active --quiet libvirtd; then
    systemctl start libvirtd
    sleep 2
fi

# Start VirtualBMC daemon
echo "[setup-vbmc] Starting VirtualBMC daemon..."
if pgrep -f vbmcd > /dev/null; then
    echo "[setup-vbmc] VirtualBMC daemon already running"
else
    vbmcd --foreground &
    sleep 2
fi

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
        --driver-info deploy_kernel=http://${SERVICE_HOST}/ipa-kernel \
        --driver-info deploy_ramdisk=http://${SERVICE_HOST}/ipa-ramdisk \
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

# Verify nodes are available
echo "[setup-vbmc] Verifying nodes..."
openstack baremetal node list

# Show VirtualBMC status
echo "[setup-vbmc] VirtualBMC status:"
vbmc list

echo "[setup-vbmc] VirtualBMC setup complete - $IRONIC_VM_COUNT node(s) ready"
exit 0
