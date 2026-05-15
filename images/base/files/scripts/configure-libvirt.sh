#!/bin/bash
# Configure libvirt to work in container environments
# Disables security features that require host device access

set -eo pipefail

echo "[configure-libvirt] Configuring libvirt for container environment..."

# Create qemu.conf with container-friendly settings
cat > /etc/libvirt/qemu.conf << 'EOF'
# Security driver disabled - can't manage ownership of host devices in containers
security_driver = "none"

# Run QEMU as root - we're already in a privileged container
user = "root"
group = "root"

# Don't try to change file ownership
dynamic_ownership = 0
remember_owner = 0

# Don't drop capabilities
clear_emulator_capabilities = 0

# Minimal device ACL - only devices that exist and are accessible in containers
cgroup_device_acl = [
    "/dev/null", "/dev/full", "/dev/zero",
    "/dev/random", "/dev/urandom",
    "/dev/ptmx", "/dev/kvm"
]
EOF

echo "[configure-libvirt] Libvirt configuration updated"
echo "[configure-libvirt]   security_driver = none"
echo "[configure-libvirt]   dynamic_ownership = 0"
echo "[configure-libvirt]   user/group = root"

# If libvirtd is running, restart it to apply changes
if systemctl is-active --quiet libvirtd; then
    echo "[configure-libvirt] Restarting libvirtd to apply configuration..."
    systemctl restart libvirtd
    sleep 2

    if systemctl is-active --quiet libvirtd; then
        echo "[configure-libvirt] ✓ Libvirtd restarted successfully"
    else
        echo "[configure-libvirt] ✗ WARNING: Libvirtd failed to restart"
        systemctl status libvirtd --no-pager || true
        exit 1
    fi
else
    echo "[configure-libvirt] Libvirtd not running yet, configuration will apply on start"
fi

echo "[configure-libvirt] Libvirt configuration complete"
