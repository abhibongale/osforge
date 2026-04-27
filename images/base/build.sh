#!/bin/bash
# Build OSForge base image

set -euo pipefail

# Configuration
IMAGE_NAME="quay.io/osforge/base"
TAG="${1:-latest}"
FULL_IMAGE="${IMAGE_NAME}:${TAG}"

echo "===> Building OSForge base image: $FULL_IMAGE"

# Build image
podman build -t "$FULL_IMAGE" -f Containerfile .

if [[ $? -eq 0 ]]; then
    echo "===> Build successful!"
    echo ""
    echo "Image: $FULL_IMAGE"
    echo ""
    echo "To test:"
    echo "  podman run --rm -it --privileged --device /dev/kvm $FULL_IMAGE /bin/bash"
    echo ""
    echo "To push to Quay.io:"
    echo "  podman login quay.io"
    echo "  podman push $FULL_IMAGE"
    echo ""
    echo "To tag with date:"
    echo "  podman tag $FULL_IMAGE ${IMAGE_NAME}:$(date +%Y%m%d)"
    echo "  podman push ${IMAGE_NAME}:$(date +%Y%m%d)"
else
    echo "===> Build failed!"
    exit 1
fi
