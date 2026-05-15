#!/bin/bash
# Neutron (network service) configuration for Tempest tests

get_neutron_config() {
    # Get public network (external network for floating IPs)
    PUBLIC_NETWORK_ID=$(openstack network list --external -f value -c ID 2>/dev/null | head -1)

    # Get ironic provisioning network (created by DevStack for baremetal)
    # This network has a subnet and is required for baremetal instance scheduling
    PROVISION_NETWORK_ID=$(openstack network show ironic-provision -f value -c id 2>/dev/null)

    echo "[neutron-config] Public network: $PUBLIC_NETWORK_ID"
    echo "[neutron-config] Provisioning network: $PROVISION_NETWORK_ID (ironic-provision)"

    export TEMPEST_PUBLIC_NETWORK_ID="$PUBLIC_NETWORK_ID"
    export TEMPEST_PROVISION_NETWORK_ID="$PROVISION_NETWORK_ID"
}

generate_neutron_tempest_config() {
    cat <<EOF
[network]
public_network_id = ${TEMPEST_PUBLIC_NETWORK_ID}
default_network = ${TEMPEST_PROVISION_NETWORK_ID}
project_networks_reachable = false

[network-feature-enabled]
ipv6 = false
EOF
}
