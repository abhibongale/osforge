#!/bin/bash
# Nova (compute service) configuration for Tempest tests

get_nova_config() {
    # Get baremetal flavor UUID (requires project scope, not system scope)
    unset OS_SYSTEM_SCOPE
    export OS_PROJECT_NAME=admin
    export OS_PROJECT_DOMAIN_NAME=Default

    FLAVOR_ID=$(openstack flavor show baremetal -f value -c id 2>/dev/null)

    echo "[nova-config] Flavor: $FLAVOR_ID (baremetal)"
    export TEMPEST_FLAVOR_ID="$FLAVOR_ID"
}

generate_nova_tempest_config() {
    cat <<EOF
[compute]
image_ref = ${TEMPEST_IMAGE_ID}
image_ref_alt = ${TEMPEST_IMAGE_ID}
flavor_ref = ${TEMPEST_FLAVOR_ID}
fixed_network_name = ironic-provision
min_compute_nodes = 1
max_microversion = latest

[compute-feature-enabled]
console_output = false
rescue = false
resize = false
suspend = false
interface_attach = false
EOF
}
