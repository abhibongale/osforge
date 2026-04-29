#!/bin/bash
# Two-stage build for OSForge base image with DevStack
# Stage 1: Build base image with dependencies
# Stage 2: Run DevStack in a container and commit it

set -euo pipefail

# Configuration
IMAGE_NAME="quay.io/osforge/base"
TAG="${1:-latest}"
INTERMEDIATE_IMAGE="${IMAGE_NAME}-intermediate:${TAG}"
FINAL_IMAGE="${IMAGE_NAME}:${TAG}"
CONTAINER_NAME="osforge-devstack-build-$$"

echo "===> Stage 1: Building base image with dependencies"
podman build -t "$INTERMEDIATE_IMAGE" -f Containerfile .

if [[ $? -ne 0 ]]; then
    echo "===> Stage 1 failed!"
    exit 1
fi

echo "===> Stage 1 complete: $INTERMEDIATE_IMAGE"
echo ""

echo "===> Stage 2: Running DevStack installation in container"
echo "This will take 45-60 minutes..."
echo ""

# Start container with systemd
# Using --systemd=always and proper cgroup configuration for systemd
# Mount /lib/modules for OVS kernel module access
podman run -d \
    --name "$CONTAINER_NAME" \
    --privileged \
    --systemd=always \
    --device /dev/kvm \
    --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    -v /lib/modules:/lib/modules:ro \
    "$INTERMEDIATE_IMAGE"

# Wait for systemd to be ready
echo "Waiting for systemd to initialize..."
sleep 10

# Check if systemd is running
if ! podman exec "$CONTAINER_NAME" systemctl is-system-running --wait 2>/dev/null; then
    echo "Warning: systemd may not be fully ready, but continuing..."
fi

# Remove policy-rc.d so services can start during DevStack installation
echo "Removing policy-rc.d to allow service starts..."
podman exec "$CONTAINER_NAME" rm -f /usr/sbin/policy-rc.d

# Mask ovs-vswitchd.service BEFORE DevStack tries to start it
# OVN userspace mode only needs ovsdb-server, not ovs-vswitchd
# ovs-vswitchd tries to load kernel modules which fail in containers
echo "Masking ovs-vswitchd.service (not needed for OVN userspace)..."
podman exec "$CONTAINER_NAME" bash -c "systemctl mask ovs-vswitchd.service 2>/dev/null || true"

# Start VirtualBMC daemon
# VirtualBMC provides IPMI simulation for virtual baremetal nodes
echo "Starting VirtualBMC daemon..."
podman exec "$CONTAINER_NAME" bash -c 'mkdir -p /root/.vbmc && vbmcd'
sleep 2

# Run DevStack installation
echo "Running stack.sh (this takes 45-60 minutes)..."
echo ""

if podman exec -u stack "$CONTAINER_NAME" bash -c 'cd /opt/stack/devstack && ./stack.sh'; then
    echo ""
    echo "===> DevStack installation successful!"
    echo ""

    # Stop all services before committing (Option A: services stopped in base image, started at runtime)
    echo "===> Stopping services before commit..."
    podman exec "$CONTAINER_NAME" systemctl stop 'devstack@*' || true
    podman exec "$CONTAINER_NAME" systemctl stop apache2 || true
    podman exec "$CONTAINER_NAME" systemctl stop rabbitmq-server || true
    podman exec "$CONTAINER_NAME" systemctl stop mysql || true
    echo "===> Services stopped"

    # Commit the container to final image
    echo "===> Committing container to image: $FINAL_IMAGE"
    podman commit "$CONTAINER_NAME" "$FINAL_IMAGE"

    if [[ $? -eq 0 ]]; then
        echo "===> Build complete!"
        echo ""
        echo "Final image: $FINAL_IMAGE"
        echo ""
        echo "Cleaning up intermediate image and container..."
        podman stop "$CONTAINER_NAME"
        podman rm "$CONTAINER_NAME"
        podman rmi "$INTERMEDIATE_IMAGE"

        echo ""
        echo "To test:"
        echo "  podman run --rm -it --privileged --device /dev/kvm $FINAL_IMAGE /bin/bash"
        echo ""
        echo "To push to Quay.io:"
        echo "  podman login quay.io"
        echo "  podman push $FINAL_IMAGE"
        echo ""
        echo "To tag with date:"
        echo "  podman tag $FINAL_IMAGE ${IMAGE_NAME}:$(date +%Y%m%d)"
        echo "  podman push ${IMAGE_NAME}:$(date +%Y%m%d)"
    else
        echo "===> Commit failed!"
        podman stop "$CONTAINER_NAME"
        podman rm "$CONTAINER_NAME"
        exit 1
    fi
else
    echo ""
    echo "===> DevStack installation failed!"
    echo ""
    echo "Container is still running. To debug:"
    echo "  podman exec -it $CONTAINER_NAME bash"
    echo ""
    echo "To view logs:"
    echo "  podman exec $CONTAINER_NAME cat /opt/stack/logs/devstack.log"
    echo ""
    echo "To clean up:"
    echo "  podman stop $CONTAINER_NAME"
    echo "  podman rm $CONTAINER_NAME"
    exit 1
fi
