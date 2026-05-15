#!/bin/bash
# Glance (image service) configuration for Tempest tests

get_glance_config() {
    IMAGE_ID=$(openstack image list -f value -c ID 2>/dev/null | head -1)

    echo "[glance-config] Image: $IMAGE_ID"
    export TEMPEST_IMAGE_ID="$IMAGE_ID"
}
