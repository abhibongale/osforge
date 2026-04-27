#!/bin/bash
# Health check for container services
# This script runs inside the container

set -euo pipefail

echo "[health-check] Running container health checks..."

# Check if systemd is running
if ! systemctl is-system-running --quiet; then
    echo "[health-check] WARNING: systemd not fully operational"
fi

# Check critical paths
for path in /opt/stack /opt/stack/logs; do
    if [[ ! -d "$path" ]]; then
        echo "[health-check] ERROR: Missing directory: $path"
        exit 1
    fi
done

# Check if KVM is available
if [[ ! -e /dev/kvm ]]; then
    echo "[health-check] WARNING: /dev/kvm not available (nested virtualization may not work)"
fi

echo "[health-check] Health check passed"
exit 0
